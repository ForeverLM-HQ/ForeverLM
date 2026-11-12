#if os(macOS)
import AppKit
import Foundation
import OSLog

/// Logs when the main thread stops responding long enough to feel like a beachball,
/// and captures a process sample *while it is still stalled*.
///
/// Two things about the original design made every one of its samples useless, and
/// both are worth stating because the failure mode is silent — it writes a
/// plausible-looking report either way.
///
/// **The measurement counted the monitor's own lateness as the main thread's.**
/// The heartbeat timestamp was taken after a round trip through the main queue and
/// *back* onto this utility-QoS queue. When the machine is loaded — a couple of
/// parallel `xcodebuild`s will do it — that queue is descheduled for seconds, so
/// the timestamp landed late and the next check read the delay as a main-thread
/// stall that never happened. The probe now stamps its own completion time on the
/// main thread under a lock, so what is measured is the main thread's latency and
/// nothing else.
///
/// **The sample always started after the stall ended.** Capture was triggered only
/// once the stall had already run a full second, and `/usr/bin/sample` needs ~45ms
/// to attach and then records for a second. A 1–1.5s beachball — which is what
/// this app actually produces — was over before the first sample was taken. Every
/// one of twenty such reports showed an idle main thread
/// parked in `mach_msg`, which reads exactly like "no stall found". Capture
/// starts speculatively at `suspicionThreshold`, so the sampler is attached and
/// recording while the main thread is still wedged; if the stall never reaches
/// `stallThreshold` the sample is killed and its file deleted, so the speculation
/// costs nothing but a short-lived process.
final class UIResponsivenessMonitor {
    static let shared = UIResponsivenessMonitor()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? ForeverLMRuntimeIdentity.keychainService,
        category: "Responsiveness"
    )
    /// `.userInitiated`, not `.utility`: a watchdog that can itself be starved
    /// cannot tell "the main thread is stuck" from "I was not scheduled". It does
    /// almost no work, so the priority costs nothing.
    private let queue = DispatchQueue(label: "com.foreverlm.ui-responsiveness-monitor", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "com.foreverlm.ui-responsiveness-sampler", qos: .utility)
    private let checkInterval: TimeInterval = 0.1
    /// When to start recording. Well below the stall threshold on purpose — the
    /// sampler has to already be attached when the interesting second happens.
    private let suspicionThreshold: TimeInterval = 0.3
    /// When a delay becomes a stall worth keeping and reporting.
    private let stallThreshold: TimeInterval = 1.0
    /// Minimum gap between speculative capture attempts, most of which are
    /// discarded.
    private let speculativeCooldown: TimeInterval = 5.0
    /// Minimum gap between samples that are actually retained.
    private let retainedSampleCooldown: TimeInterval = 30.0
    private let sampleDuration = 2
    private let sampleIntervalMilliseconds = 2
    private let maximumRetainedSampleCount = 20
    private let maximumRetainedSampleBytes = 50 * 1024 * 1024

    /// Main-thread liveness, written by the probe on the main thread and read by
    /// the watchdog. A lock rather than a queue hop so no background scheduling
    /// delay can contaminate the measurement.
    private let stateLock = AppLock()
    private var probeSentAt: Date?
    private var lastProbeRanAt = Date()
    /// Whether the app was frontmost when the main thread last answered, read
    /// there (`NSApp` belongs to the main thread). A stall in a background app
    /// shows no beachball until the learner comes back to it.
    private var activeAtLastProbe = true

    /// Capture bookkeeping. Guarded by `stateLock` because the sampler queue has
    /// to hand back the process handle while the watchdog may be terminating it.
    private final class StallCapture {
        let url: URL
        var process: Process?
        var confirmed = false
        var discarded = false
        init(url: URL) { self.url = url }
    }
    private var activeCapture: StallCapture?
    private var lastCaptureStartedAt: Date?
    private var lastRetainedSampleAt: Date?

    private var isRunning = false
    private var currentStallStart: Date?
    private var lastStallLog: Date?

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.stateLock.lock()
            self.lastProbeRanAt = Date()
            self.probeSentAt = nil
            self.stateLock.unlock()
            self.sampleQueue.async { [weak self] in
                self?.pruneProcessSamples()
            }
            self.logger.info("UI responsiveness monitor started; stall threshold \(self.stallThreshold, format: .fixed(precision: 1))s")
            self.scheduleCheck()
        }
    }

    private func scheduleCheck() {
        queue.asyncAfter(deadline: .now() + checkInterval) { [weak self] in
            guard let self, self.isRunning else { return }
            self.checkMainThread()
            self.scheduleCheck()
        }
    }

    private func checkMainThread() {
        let now = Date()

        stateLock.lock()
        let outstandingSince = probeSentAt
        let lastRan = lastProbeRanAt
        stateLock.unlock()

        // No probe outstanding means the main thread answered the last one; there
        // is nothing in flight to be late.
        let delay = outstandingSince.map { now.timeIntervalSince($0) } ?? 0

        if delay >= suspicionThreshold {
            beginCaptureIfNeeded(now: now)
        }

        if delay >= stallThreshold, let outstandingSince {
            if currentStallStart == nil {
                currentStallStart = outstandingSince
                lastStallLog = now
                // The load and whether the app was frontmost go on the line, so a
                // reader (`beta_stall_gate.py`, before a promotion) can tell a
                // stall the learner saw from a Mac too busy to run anything.
                stateLock.lock()
                let wasActive = activeAtLastProbe
                stateLock.unlock()
                var load = [Double](repeating: 0, count: 3)
                let loadRead = getloadavg(&load, 3) > 0
                logger.fault("UI_STALL_BEGIN duration=\(delay, format: .fixed(precision: 2))s threshold=\(self.stallThreshold, format: .fixed(precision: 1))s load=\(loadRead ? load[0] : -1, format: .fixed(precision: 1)) cores=\(ProcessInfo.processInfo.activeProcessorCount) active=\(wasActive ? 1 : 0)")
                confirmActiveCapture(stalledFor: delay)
            } else if shouldLogOngoingStall(now: now) {
                lastStallLog = now
                logger.error("UI_STALL_ONGOING duration=\(delay, format: .fixed(precision: 2))s")
            }
        }

        if outstandingSince == nil {
            if let stallStart = currentStallStart {
                logger.error("UI_STALL_END duration=\(lastRan.timeIntervalSince(stallStart), format: .fixed(precision: 2))s")
                currentStallStart = nil
                lastStallLog = nil
            }
            // A capture that never grew into a real stall is noise; drop it.
            discardUnconfirmedCapture()
            sendProbe()
        }
    }

    /// Dispatch one liveness probe. It records the time it ran *on the main
    /// thread*, so the value can never include this monitor's own scheduling
    /// delay.
    private func sendProbe() {
        stateLock.lock()
        probeSentAt = Date()
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ranAt = Date()
            let active = NSApp?.isActive ?? true
            self.stateLock.lock()
            self.probeSentAt = nil
            self.lastProbeRanAt = ranAt
            self.activeAtLastProbe = active
            self.stateLock.unlock()
        }
    }

    private func shouldLogOngoingStall(now: Date) -> Bool {
        guard let lastStallLog else { return true }
        return now.timeIntervalSince(lastStallLog) >= 2.0
    }

    // MARK: - Process sampling

    /// Start recording on suspicion, before the delay is known to be a stall.
    private func beginCaptureIfNeeded(now: Date) {
        stateLock.lock()
        let alreadyCapturing = activeCapture != nil
        stateLock.unlock()
        guard !alreadyCapturing else { return }

        if let lastCaptureStartedAt, now.timeIntervalSince(lastCaptureStartedAt) < speculativeCooldown {
            return
        }
        if let lastRetainedSampleAt, now.timeIntervalSince(lastRetainedSampleAt) < retainedSampleCooldown {
            return
        }
        lastCaptureStartedAt = now

        let directory: URL
        do {
            directory = try diagnosticsDirectory()
        } catch {
            logger.error("UI_STALL_SAMPLE_FAILED error=\(error.localizedDescription, privacy: .public)")
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let capture = StallCapture(url: directory.appendingPathComponent("ui-stall-\(timestamp).sample.txt"))

        stateLock.lock()
        activeCapture = capture
        stateLock.unlock()

        sampleQueue.async { [weak self] in
            self?.runCapture(capture)
        }
    }

    private func runCapture(_ capture: StallCapture) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            "\(ProcessInfo.processInfo.processIdentifier)",
            "\(sampleDuration)",
            "\(sampleIntervalMilliseconds)",
            // Deliberately not `-mayDie`: that reads symbol information up front,
            // which delays the first sample — the opposite of what this needs.
            "-file",
            capture.url.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        stateLock.lock()
        let alreadyDiscarded = capture.discarded
        if !alreadyDiscarded { capture.process = process }
        stateLock.unlock()
        guard !alreadyDiscarded else {
            finishCapture(capture, terminationStatus: nil, errorPipe: nil)
            return
        }

        do {
            try process.run()
            process.waitUntilExit()
            finishCapture(capture, terminationStatus: process.terminationStatus, errorPipe: errorPipe)
        } catch {
            logger.error("UI_STALL_SAMPLE_FAILED error=\(error.localizedDescription, privacy: .public)")
            finishCapture(capture, terminationStatus: nil, errorPipe: nil)
        }
    }

    private func finishCapture(_ capture: StallCapture, terminationStatus: Int32?, errorPipe: Pipe?) {
        stateLock.lock()
        let confirmed = capture.confirmed
        if activeCapture === capture { activeCapture = nil }
        stateLock.unlock()

        guard confirmed else {
            // Speculative capture of a delay that resolved on its own.
            try? FileManager.default.removeItem(at: capture.url)
            return
        }

        if terminationStatus == 0 {
            queue.async { [weak self] in self?.lastRetainedSampleAt = Date() }
            pruneProcessSamples()
            logger.error("UI_STALL_SAMPLE path=\(capture.url.path, privacy: .public)")
        } else {
            let errorText = errorPipe
                .map { String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error" }
                ?? "sample did not run"
            logger.error("UI_STALL_SAMPLE_FAILED status=\(terminationStatus ?? -1) error=\(String(errorText.prefix(300)), privacy: .public)")
            try? FileManager.default.removeItem(at: capture.url)
        }
    }

    /// The delay became a real stall: keep whatever the sampler has recorded.
    private func confirmActiveCapture(stalledFor duration: TimeInterval) {
        stateLock.lock()
        activeCapture?.confirmed = true
        let hasCapture = activeCapture != nil
        stateLock.unlock()
        if !hasCapture {
            logger.error("UI_STALL_NOT_SAMPLED stalledFor=\(duration, format: .fixed(precision: 2))s reason=cooldown")
        }
    }

    /// The main thread recovered before the stall threshold. Stop the sampler and
    /// throw the partial report away.
    private func discardUnconfirmedCapture() {
        stateLock.lock()
        let capture = activeCapture
        var processToTerminate: Process?
        if let capture, !capture.confirmed {
            capture.discarded = true
            processToTerminate = capture.process
            activeCapture = nil
        }
        stateLock.unlock()

        guard let processToTerminate else { return }
        if processToTerminate.isRunning { processToTerminate.terminate() }
    }

    /// Samples are diagnostic snapshots, not user data. Keeping them forever
    /// turned a useful beachball detector into a multi-gigabyte cache after a
    /// noisy run. Retention runs only on the sampler's utility queue and keeps
    /// both a count and byte ceiling so one unusually large sample cannot grow
    /// Application Support without bound.
    private func pruneProcessSamples() {
        do {
            let directory = try diagnosticsDirectory()
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
            let samples = files.compactMap { url -> (url: URL, modified: Date, bytes: Int)? in
                guard url.lastPathComponent.hasPrefix("ui-stall-"),
                      url.pathExtension == "txt",
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else {
                    return nil
                }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            .sorted { $0.modified > $1.modified }

            var retainedBytes = 0
            var removedCount = 0
            for (index, sample) in samples.enumerated() {
                let exceedsCount = index >= maximumRetainedSampleCount
                let exceedsBytes = index > 0
                    && retainedBytes + sample.bytes > maximumRetainedSampleBytes
                if exceedsCount || exceedsBytes {
                    try FileManager.default.removeItem(at: sample.url)
                    removedCount += 1
                } else {
                    retainedBytes += sample.bytes
                }
            }
            if removedCount > 0 {
                logger.info("Pruned \(removedCount) old UI stall sample(s)")
            }
        } catch {
            logger.error("UI_STALL_SAMPLE_PRUNE_FAILED error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func diagnosticsDirectory() throws -> URL {
        let base = ForeverLMRuntimeIdentity.diagnosticsRootURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
#endif
