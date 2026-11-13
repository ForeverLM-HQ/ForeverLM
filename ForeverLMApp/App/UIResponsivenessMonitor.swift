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
/// **The sampler can freeze the app it samples.** `/usr/bin/sample` suspends the
/// whole process for each snapshot. Usually that costs a millisecond. On
/// 2026-11-12 (build 297) one run took 5.6 s to collect 45 snapshots, and nothing
/// in the app ran in between, this monitor included: a hitch on switching the
/// Library from Articles to Papers became a 5.3 s beachball (product owner,
/// 2026-11-12: "I got a beach ball. And I was shifting from articles to papers").
/// Three more of that day's nine kept samples held 2, 6 and 30 snapshots, the
/// monitor silent for 5-6.5 s around each, two of them seconds after launch. The
/// sampler used to start speculatively at 0.3 s, so any hitch could become one of
/// these. Now it starts only once a stall is real (`stallThreshold`), never in the
/// first `launchGrace` after launch, and never again in a launch once a capture
/// has stopped this monitor's own checks for `samplerFreezeLimit`. A stall over
/// within a second of starting is then over before the sampler attaches, and its
/// sample shows an idle main thread; a missing diagnosis is the price, where a
/// frozen app was the learner's.
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
    /// When a delay becomes a stall worth reporting and sampling.
    private let stallThreshold: TimeInterval = 1.0
    /// No sampling this soon after the monitor starts: the two launch-time
    /// captures of 2026-11-12 froze the app for 5 s each.
    private let launchGrace: TimeInterval = 30.0
    /// Two checks this far apart while the sampler runs mean it suspended the
    /// process, this monitor's queue with it, for that long.
    private let samplerFreezeLimit: TimeInterval = 1.0
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
    /// to hand back the process handle while the watchdog may be stopping it.
    private final class StallCapture {
        let url: URL
        var process: Process?
        var stopped = false
        init(url: URL) { self.url = url }
    }
    private var activeCapture: StallCapture?
    private var lastRetainedSampleAt: Date?
    /// Set once a capture froze the process; nothing more is sampled until the
    /// app is launched again.
    private var samplingOff = false
    private var startedAt = Date()
    private var lastCheckAt: Date?

    private var isRunning = false
    private var currentStallStart: Date?
    private var lastStallLog: Date?

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.startedAt = Date()
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
        let sinceLastCheck = lastCheckAt.map { now.timeIntervalSince($0) } ?? 0
        lastCheckAt = now

        stateLock.lock()
        let outstandingSince = probeSentAt
        let lastRan = lastProbeRanAt
        let capture = activeCapture
        stateLock.unlock()

        if let capture, sinceLastCheck >= samplerFreezeLimit {
            stopSamplingForThisLaunch(capture, monitorSilentFor: sinceLastCheck)
        }

        // No probe outstanding means the main thread answered the last one; there
        // is nothing in flight to be late.
        let delay = outstandingSince.map { now.timeIntervalSince($0) } ?? 0

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
                beginCapture(now: now, stalledFor: delay)
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

    /// Start the sampler on a stall that is already real, unless sampling is off
    /// for one of the reasons in the type's comment. The stall is logged either way.
    private func beginCapture(now: Date, stalledFor duration: TimeInterval) {
        stateLock.lock()
        let alreadyCapturing = activeCapture != nil
        stateLock.unlock()

        let skipReason: String?
        if samplingOff {
            skipReason = "sampler_froze_app"
        } else if now.timeIntervalSince(startedAt) < launchGrace {
            skipReason = "launch"
        } else if alreadyCapturing {
            skipReason = "capturing"
        } else if let lastRetainedSampleAt, now.timeIntervalSince(lastRetainedSampleAt) < retainedSampleCooldown {
            skipReason = "cooldown"
        } else {
            skipReason = nil
        }
        if let skipReason {
            logger.error("UI_STALL_NOT_SAMPLED stalledFor=\(duration, format: .fixed(precision: 2))s reason=\(skipReason, privacy: .public)")
            return
        }

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
        let alreadyStopped = capture.stopped
        if !alreadyStopped { capture.process = process }
        stateLock.unlock()
        guard !alreadyStopped else {
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
        if activeCapture === capture { activeCapture = nil }
        stateLock.unlock()

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

    /// This monitor's checks stopped for `silence` while the sampler ran: the
    /// sampler suspended the process. Interrupt it, which makes `sample` stop
    /// and write what it has, and sample nothing more until the next launch.
    private func stopSamplingForThisLaunch(_ capture: StallCapture, monitorSilentFor silence: TimeInterval) {
        samplingOff = true
        logger.fault("UI_STALL_SAMPLER_FROZE_APP silent=\(silence, format: .fixed(precision: 2))s; no more samples until relaunch")
        stateLock.lock()
        capture.stopped = true
        let process = capture.process
        stateLock.unlock()
        if let process, process.isRunning { process.interrupt() }
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
