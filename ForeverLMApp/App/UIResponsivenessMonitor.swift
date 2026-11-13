#if os(macOS)
import AppKit
import Darwin
import Foundation
import MachO
import OSLog

/// Logs when the main thread stops responding long enough to feel like a beachball,
/// and samples the main thread's stack *while it is still stalled*.
///
/// Two things about earlier designs made their samples useless or harmful, and
/// both are worth stating because the failure modes are silent.
///
/// **The measurement counted the monitor's own lateness as the main thread's.**
/// The heartbeat timestamp was taken after a round trip through the main queue and
/// *back* onto this monitor's queue. When the machine is loaded — a couple of
/// parallel `xcodebuild`s will do it — that queue is descheduled for seconds, so
/// the timestamp landed late and the next check read the delay as a main-thread
/// stall that never happened. The probe now stamps its own completion time on the
/// main thread under a lock, so what is measured is the main thread's latency and
/// nothing else.
///
/// **The sampler froze the app it sampled.** The capture used to run
/// `/usr/bin/sample`, which suspends the whole process for each snapshot. Usually
/// that costs a millisecond. On 2026-11-12 one run took 5.6 s to collect 45
/// snapshots, and nothing in the app ran in between, this monitor included: a hitch
/// on switching the Library from Articles to Papers became a 5.3 s beachball
/// (product owner, 2026-11-12: "I got a beach ball. And I was shifting from articles
/// to papers"). Three more of that day's nine kept samples held 2, 6 and 30
/// snapshots. The rule since is that the diagnostics may never cause a beachball.
/// The capture is now `MainThreadSampler`, a thread of this process that suspends
/// the main thread alone, for microseconds, every 5 ms while the stall lasts; the
/// rest of the app, this monitor included, runs throughout. So sampling starts as
/// soon as a stall is real (`stallThreshold`), at launch too, and a stall over
/// within a second is never sampled.
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
    /// Symbolicates and writes the reports, and prunes old ones.
    private let sampleQueue = DispatchQueue(label: "com.foreverlm.ui-responsiveness-sampler", qos: .utility)
    private let checkInterval: TimeInterval = 0.1
    /// When a delay becomes a stall worth reporting and sampling.
    private let stallThreshold: TimeInterval = 1.0
    /// Minimum gap between samples that are actually retained.
    private let retainedSampleCooldown: TimeInterval = 30.0
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

    /// The main thread's sampler, handed over by `start()`. Used on `queue` only.
    private var sampler: MainThreadSampler?
    /// When the last report was written. Used on `queue` only.
    private var lastRetainedSampleAt: Date?

    private var isRunning = false
    private var currentStallStart: Date?
    private var lastStallLog: Date?

    private init() {}

    /// Call on the main thread, as early as possible: the sampler is made there,
    /// because it has to keep that thread's port and stack bounds.
    func start() {
        let sampler = MainThreadSampler.shared
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.sampler = sampler
            self.stateLock.lock()
            self.lastProbeRanAt = Date()
            self.probeSentAt = nil
            self.stateLock.unlock()
            self.sampleQueue.async { [weak self] in
                self?.pruneProcessSamples()
            }
            if sampler == nil {
                self.logger.error("UI_STALL_SAMPLER_UNAVAILABLE the monitor was not started on the main thread; stalls are logged but not sampled")
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
                sampler?.end()
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

    // MARK: - Stall sampling

    /// Start sampling a stall that is already real. The stall is logged either way.
    private func beginCapture(now: Date, stalledFor duration: TimeInterval) {
        let skipReason: String?
        if sampler == nil {
            skipReason = "no_sampler"
        } else if let lastRetainedSampleAt, now.timeIntervalSince(lastRetainedSampleAt) < retainedSampleCooldown {
            skipReason = "cooldown"
        } else {
            skipReason = nil
        }
        if let skipReason {
            logger.error("UI_STALL_NOT_SAMPLED stalledFor=\(duration, format: .fixed(precision: 2))s reason=\(skipReason, privacy: .public)")
            return
        }
        let started = sampler?.begin(stalledFor: duration) { [weak self] capture in
            self?.sampleQueue.async { [weak self] in
                self?.writeReport(for: capture, stallDetectedAt: now)
            }
        } ?? false
        if !started {
            logger.error("UI_STALL_NOT_SAMPLED stalledFor=\(duration, format: .fixed(precision: 2))s reason=capturing")
        }
    }

    /// Symbolicate a finished capture and write it beside the earlier ones. Runs
    /// on `sampleQueue`, after the sampling, while the app goes on.
    private func writeReport(for capture: MainThreadSampler.Capture, stallDetectedAt: Date) {
        guard !capture.samples.isEmpty else {
            let reason = capture.failedSamples > 0 ? "sampler_failed" : "ended"
            logger.error("UI_STALL_NOT_SAMPLED stalledFor=\(capture.stalledForAtStart, format: .fixed(precision: 2))s reason=\(reason, privacy: .public)")
            return
        }
        do {
            let directory = try diagnosticsDirectory()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: stallDetectedAt).replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("ui-stall-\(timestamp).sample.txt")
            let report = MainThreadStallReport(capture: capture).render()
            try report.write(to: url, atomically: true, encoding: .utf8)
            queue.async { [weak self] in self?.lastRetainedSampleAt = Date() }
            pruneProcessSamples()
            logger.error("UI_STALL_SAMPLE path=\(url.path, privacy: .public) samples=\(capture.samples.count) longestHold=\(capture.longestHoldNanoseconds / 1000)us")
        } catch {
            logger.error("UI_STALL_SAMPLE_FAILED error=\(error.localizedDescription, privacy: .public)")
        }
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

// MARK: - Main-thread sampler

/// Samples the main thread's stack from a thread of its own while the main thread
/// is stalled, and stops nothing else in the app.
///
/// Each snapshot is `foreverlm_sample_thread_stack` (Shared/MainThreadStackSampler.h):
/// suspend the main thread alone, read its registers, walk its frame pointers,
/// resume it, in microseconds. That routine is C because nothing may allocate or
/// take a lock while the main thread is held (it may hold the malloc lock); this
/// type only passes it a buffer made up front, and does everything else (the
/// arrays, the lock, the symbols) while the main thread runs.
final class MainThreadSampler: @unchecked Sendable {
    /// What one capture saw: return addresses only. Symbols are looked up after
    /// the stall, by `MainThreadStallReport`.
    struct Capture {
        struct Sample {
            /// Where the sample's addresses start in `frames`: the pc first, then
            /// each return address going out.
            let start: Int
            let count: Int
            /// lr (arm64), or 0. The caller of a function that saved no frame of
            /// its own is only here.
            let linkRegister: UInt
        }
        var frames: [UInt] = []
        var samples: [Sample] = []
        var failedSamples = 0
        var longestHoldNanoseconds: UInt64 = 0
        var totalHoldNanoseconds: UInt64 = 0
        /// How long the main thread had not answered when sampling began.
        let stalledForAtStart: TimeInterval
        let startedAt: Date
        var sampledFor: TimeInterval = 0
        /// Sampling stopped at `MainThreadSampler.maximumDuration`, the stall still going.
        var hitTimeLimit = false
        let intervalMilliseconds: Int
        let mainThreadID: UInt64
    }

    /// The main thread's sampler, made on first use, which has to be on the main
    /// thread (`UIResponsivenessMonitor.start()`); nil if it was not.
    static let shared: MainThreadSampler? = MainThreadSampler()

    /// One snapshot this often while a stall lasts.
    static let interval: TimeInterval = 0.005
    /// Sampling stops after this long even when the stall goes on, and the report
    /// is written then, so a stall that ends in a force quit still leaves one.
    static let maximumDuration: TimeInterval = 4.0
    /// Frames kept per snapshot, innermost first.
    static let maximumDepth = 512

    private let mainThreadPort: thread_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let mainThreadID: UInt64
    /// Written while the main thread is suspended, so it exists before any stall.
    private let scratch: UnsafeMutablePointer<UInt>
    private let intervalTicks: UInt64
    private let maximumTicks: UInt64
    private let timebase: mach_timebase_info_data_t
    /// A kqueue for the sampling tick. Its timer is `NOTE_CRITICAL`, which the
    /// kernel does not coalesce: a plain `mach_wait_until(5 ms)` slept 40 ms at a
    /// time in a process at utility QoS (an App Napped app is treated alike) and
    /// then fired the missed ticks in a burst. -1 if kqueue failed.
    private let ticker: Int32

    private struct Request {
        let stalledFor: TimeInterval
        let completion: (Capture) -> Void
    }
    private let lock = AppLock()
    private let wake = DispatchSemaphore(value: 0)
    /// Guarded by `lock`.
    private var pending: Request?
    private var busy = false
    private var stopRequested = false

    private init?() {
        guard pthread_main_np() != 0 else { return nil }
        let main = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(main))
        let size = UInt(pthread_get_stacksize_np(main))
        guard size > 0, top > size else { return nil }
        // A send right to the main thread, kept for the life of the process.
        mainThreadPort = mach_thread_self()
        stackHigh = top
        stackLow = top - size
        var threadID: UInt64 = 0
        pthread_threadid_np(main, &threadID)
        mainThreadID = threadID
        scratch = .allocate(capacity: Self.maximumDepth)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.timebase = timebase
        let ticksPerSecond = 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
        intervalTicks = UInt64(Self.interval * ticksPerSecond)
        maximumTicks = UInt64(Self.maximumDuration * ticksPerSecond)
        ticker = kqueue()

        // Its own thread, not a queue: it must not wait behind other work when a
        // stall starts, and the cooperative pool may be what is stalled.
        let thread = Thread { [self] in
            self.samplerThreadMain()
        }
        thread.name = "com.foreverlm.main-thread-sampler"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Start sampling; `completion` gets the capture on the sampler's thread when
    /// the stall ends (`end()`) or `maximumDuration` passes. False while an
    /// earlier capture is still running.
    func begin(stalledFor: TimeInterval, completion: @escaping (Capture) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        stopRequested = false
        pending = Request(stalledFor: stalledFor, completion: completion)
        wake.signal()
        return true
    }

    /// The stall is over: stop sampling and hand the capture over.
    func end() {
        lock.lock()
        if busy { stopRequested = true }
        lock.unlock()
    }

    private func samplerThreadMain() {
        while true {
            wake.wait()
            lock.lock()
            let request = pending
            pending = nil
            lock.unlock()
            guard let request else { continue }

            let capture = sampleUntilStopped(request)

            lock.lock()
            busy = false
            stopRequested = false
            lock.unlock()
            request.completion(capture)
        }
    }

    private func sampleUntilStopped(_ request: Request) -> Capture {
        var capture = Capture(
            stalledForAtStart: request.stalledFor,
            startedAt: Date(),
            intervalMilliseconds: Int((Self.interval * 1000).rounded()),
            mainThreadID: mainThreadID
        )
        capture.samples.reserveCapacity(Int(Self.maximumDuration / Self.interval) + 64)
        capture.frames.reserveCapacity(128 * 1024)

        let port = mainThreadPort
        let low = stackLow
        let high = stackHigh
        let buffer = scratch
        let depth = Int32(Self.maximumDepth)
        let ticking = setTick(on: true)
        defer { if ticking { _ = setTick(on: false) } }
        let began = mach_absolute_time()
        var deadline = began
        while true {
            lock.lock()
            let stop = stopRequested
            lock.unlock()
            if stop { break }
            if mach_absolute_time() &- began >= maximumTicks {
                capture.hitTimeLimit = true
                break
            }

            var linkRegister: UInt = 0
            var heldTicks: UInt64 = 0
            let count = foreverlm_sample_thread_stack(port, low, high, buffer, depth, &linkRegister, &heldTicks)
            // The main thread runs again from here on; allocating is safe.
            if count > 0 {
                capture.samples.append(.init(start: capture.frames.count, count: Int(count), linkRegister: linkRegister))
                capture.frames.append(contentsOf: UnsafeBufferPointer(start: buffer, count: Int(count)))
                let held = nanoseconds(ticks: heldTicks)
                capture.longestHoldNanoseconds = max(capture.longestHoldNanoseconds, held)
                capture.totalHoldNanoseconds &+= held
            } else {
                capture.failedSamples += 1
            }

            // One sample per tick; ticks missed while this thread was late are
            // dropped, not made up in a burst.
            if ticking {
                var fired = kevent64_s()
                _ = kevent64(ticker, nil, 0, &fired, 1, 0, nil)
            } else {
                deadline &+= intervalTicks
                let now = mach_absolute_time()
                if deadline <= now { deadline = now &+ intervalTicks }
                mach_wait_until(deadline)
            }
        }
        capture.sampledFor = Double(nanoseconds(ticks: mach_absolute_time() &- began)) / 1_000_000_000
        return capture
    }

    /// Starts or stops the periodic tick on `ticker`: every `interval`, with
    /// 100 us of leeway. False if it could not be set.
    private func setTick(on: Bool) -> Bool {
        guard ticker >= 0 else { return false }
        var change = kevent64_s(
            ident: 1,
            filter: Int16(EVFILT_TIMER),
            flags: UInt16(on ? EV_ADD | EV_ENABLE : EV_DELETE),
            fflags: on ? UInt32(NOTE_USECONDS | NOTE_CRITICAL | NOTE_LEEWAY) : 0,
            data: on ? Int64((Self.interval * 1_000_000).rounded()) : 0,
            udata: 0,
            ext: (0, on ? 100 : 0)
        )
        return kevent64(ticker, &change, 1, nil, 0, 0, nil) == 0
    }

    private func nanoseconds(ticks: UInt64) -> UInt64 {
        ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

// MARK: - Report

/// Turns a `MainThreadSampler.Capture` into a report laid out like
/// `/usr/bin/sample`'s (header, call graph, top of stack, binary images), so a
/// stall report reads the way those did: follow the biggest count down the
/// call graph. `beta_stall_gate.py` finds a build's reports by the
/// `Version: … (<build>)` line near the top.
///
/// Symbols come from `dladdr`, which on current macOS names non-exported
/// functions in the system libraries too, and, for the app's own images, from
/// `atos`, which adds the file and line when the debug information is found.
/// An address with no symbol is listed as its image and offset.
struct MainThreadStallReport {
    let capture: MainThreadSampler.Capture

    private final class Image {
        let path: String
        let name: String
        let base: UInt
        let uuid: String?
        let textEnd: UInt?
        var lookups: [UInt] = []

        init(path: String, base: UInt) {
            self.path = path
            self.name = (path as NSString).lastPathComponent
            self.base = base
            let header = MainThreadStallReport.machHeaderFacts(at: base)
            self.uuid = header.uuid
            self.textEnd = header.textSize.map { base + $0 - 1 }
        }
    }

    private struct Symbol {
        var name: String?
        var start: UInt?
        var fileLine: String?
        var image: Image?
    }

    private final class Node {
        let address: UInt
        var count = 0
        var children: [UInt: Node] = [:]
        init(address: UInt) { self.address = address }
    }

    func render() -> String {
        var images: [UInt: Image] = [:]
        var symbols: [UInt: Symbol] = [:]

        // A return address is one past its call; look up the call itself, so a
        // call that ends a function is not filed under the next one.
        func lookupAddress(_ address: UInt, isPC: Bool) -> UInt {
            isPC || address == 0 ? address : address - 1
        }
        func resolve(_ lookup: UInt) {
            guard symbols[lookup] == nil else { return }
            var info = Dl_info()
            guard lookup != 0, dladdr(UnsafeRawPointer(bitPattern: lookup), &info) != 0,
                  let fname = info.dli_fname else {
                symbols[lookup] = Symbol()
                return
            }
            let base = UInt(bitPattern: info.dli_fbase)
            let image = images[base] ?? Image(path: String(cString: fname), base: base)
            images[base] = image
            image.lookups.append(lookup)
            var symbol = Symbol(image: image)
            if let sname = info.dli_sname {
                let raw = String(cString: sname)
                if raw != "<redacted>" {
                    symbol.name = Self.demangle(raw)
                    symbol.start = UInt(bitPattern: info.dli_saddr)
                }
            }
            symbols[lookup] = symbol
        }

        for sample in capture.samples {
            for index in 0..<sample.count {
                resolve(lookupAddress(capture.frames[sample.start + index], isPC: index == 0))
            }
            if sample.linkRegister != 0 {
                resolve(lookupAddress(sample.linkRegister, isPC: false))
            }
        }

        // The app's own code: atos for names and lines.
        let bundlePrefix = Bundle.main.bundlePath + "/"
        for image in images.values where image.path.hasPrefix(bundlePrefix) || image.path == Bundle.main.executablePath {
            let lookups = Array(Set(image.lookups)).sorted()
            guard let lines = Self.atos(image: image, addresses: lookups), lines.count == lookups.count else { continue }
            for (lookup, line) in zip(lookups, lines) {
                guard let parsed = Self.parseAtos(line, imageName: image.name) else { continue }
                var symbol = symbols[lookup] ?? Symbol(image: image)
                if let offset = parsed.offset {
                    symbol.start = lookup - offset
                } else if !Self.namesAgree(full: symbol.name, short: parsed.name) {
                    // dladdr found another symbol (the nearest exported one, in a
                    // binary without local symbols); its start is not this one's.
                    symbol.start = nil
                }
                symbol.name = parsed.name
                symbol.fileLine = parsed.fileLine
                symbols[lookup] = symbol
            }
        }

        // Each sample's stack, outermost first.
        func sameFunction(_ a: Symbol?, _ b: Symbol?) -> Bool {
            guard let a, let b, let imageA = a.image, let imageB = b.image, imageA === imageB else { return false }
            if let startA = a.start, let startB = b.start { return startA == startB }
            if let nameA = a.name, let nameB = b.name { return nameA == nameB }
            return false
        }
        var stacks: [[(address: UInt, lookup: UInt)]] = []
        stacks.reserveCapacity(capture.samples.count)
        for sample in capture.samples {
            var stack: [(address: UInt, lookup: UInt)] = []
            stack.reserveCapacity(sample.count + 1)
            let pc = capture.frames[sample.start]
            stack.append((pc, pc))
            let link = sample.linkRegister
            let firstReturn = sample.count > 1 ? capture.frames[sample.start + 1] : 0
            // lr is a frame of its own only in a function that has not saved it
            // (a leaf, or one still in its prologue); otherwise it repeats the
            // first return address or points back into the same function.
            if link != 0, link != firstReturn,
               !sameFunction(symbols[pc], symbols[lookupAddress(link, isPC: false)]) {
                stack.append((link, lookupAddress(link, isPC: false)))
            }
            for index in 1..<max(sample.count, 1) {
                let address = capture.frames[sample.start + index]
                stack.append((address, lookupAddress(address, isPC: false)))
            }
            stacks.append(stack.reversed())
        }

        // The call graph, aggregated by address the way `sample` does.
        let root = Node(address: 0)
        var lookupOf: [UInt: UInt] = [:]
        for stack in stacks {
            root.count += 1
            var node = root
            for frame in stack {
                lookupOf[frame.address] = lookupOf[frame.address] ?? frame.lookup
                let child = node.children[frame.address] ?? Node(address: frame.address)
                node.children[frame.address] = child
                child.count += 1
                node = child
            }
        }

        func describe(_ address: UInt) -> String {
            let lookup = lookupOf[address] ?? address
            let symbol = symbols[lookup]
            let hex = "0x" + String(address, radix: 16)
            guard let image = symbol?.image else { return "???  [\(hex)]" }
            guard let name = symbol?.name else {
                return "???  (in \(image.name))  load address 0x\(String(image.base, radix: 16)) + 0x\(String(address - image.base, radix: 16))  [\(hex)]"
            }
            var text = "\(name)  (in \(image.name))"
            if let start = symbol?.start, start <= address { text += " + \(address - start)" }
            text += "  [\(hex)]"
            if let fileLine = symbol?.fileLine { text += "  \(fileLine)" }
            return text
        }

        var out = header()
        out += "Call graph:\n"
        out += "    \(root.count) Thread_\(capture.mainThreadID)   DispatchQueue_1: com.apple.main-thread  (serial)\n"
        // Each level of the graph is two columns wide. A level where the graph
        // branches carries a marker on every line under it, cycling `+ ! : |`
        // as `sample` does, so siblings far apart still line up by eye.
        let markers: [Character] = ["+", "!", ":", "|"]
        func emit(_ node: Node, columns: String, markersUsed: Int, branched: Bool) {
            let marker = branched ? String(markers[markersUsed % markers.count]) : " "
            let prefix = columns + marker + " "
            out += "    \(prefix)\(node.count) \(describe(node.address))\n"
            let children = node.children.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.address < $1.address }
            let childBranched = children.count > 1
            let nextUsed = markersUsed + (branched ? 1 : 0)
            for child in children {
                emit(child, columns: prefix, markersUsed: nextUsed, branched: childBranched)
            }
        }
        for child in root.children.values.sorted(by: { $0.count > $1.count }) {
            emit(child, columns: "", markersUsed: 0, branched: true)
        }

        // Where the time went, whatever the path to it.
        var tops: [String: Int] = [:]
        for stack in stacks {
            guard let leaf = stack.last else { continue }
            let symbol = symbols[leaf.lookup]
            let key = "\(symbol?.name ?? "???")  (in \(symbol?.image?.name ?? "???"))"
            tops[key, default: 0] += 1
        }
        let floor = stacks.count >= 100 ? 5 : 1
        out += "\nSort by top of stack, same collapsed (when >= \(floor)):\n"
        for (key, count) in tops.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) where count >= floor {
            out += "        \(key)        \(count)\n"
        }

        out += "\nBinary Images:\n"
        for image in images.values.sorted(by: { $0.base < $1.base }) {
            let start = "0x" + String(image.base, radix: 16)
            let end = image.textEnd.map { "0x" + String($0, radix: 16) } ?? "???"
            let padded = String(repeating: " ", count: max(0, 18 - start.count)) + start
            let paddedEnd = String(repeating: " ", count: max(0, 18 - end.count)) + end
            out += "\(padded) - \(paddedEnd)  \(image.name) <\(image.uuid ?? "?")> \(image.path)\n"
        }
        return out
    }

    private func header() -> String {
        let process = ProcessInfo.processInfo
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let loadAddress = UInt(bitPattern: _dyld_get_image_header(0))
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        #if arch(arm64)
        let codeType = "ARM64"
        #else
        let codeType = "X86-64"
        #endif
        let os = process.operatingSystemVersion
        var osBuildSize = 0
        sysctlbyname("kern.osversion", nil, &osBuildSize, nil, 0)
        var osBuild = [CChar](repeating: 0, count: max(osBuildSize, 1))
        sysctlbyname("kern.osversion", &osBuild, &osBuildSize, nil, 0)
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(String(cString: osBuild)))"
        let holds = capture.samples.isEmpty ? 0 : capture.totalHoldNanoseconds / UInt64(capture.samples.count)
        let ending = capture.hitTimeLimit
            ? "stopped at the \(Int(MainThreadSampler.maximumDuration)) s limit with the stall still going"
            : "until the stall ended"
        return """
        Analysis of sampling \(process.processName) (pid \(process.processIdentifier)) every \(capture.intervalMilliseconds) milliseconds
        Process:         \(process.processName) [\(process.processIdentifier)]
        Path:            \(Bundle.main.executablePath ?? "?")
        Load Address:    0x\(String(loadAddress, radix: 16))
        Identifier:      \(Bundle.main.bundleIdentifier ?? "?")
        Version:         \(shortVersion) (\(build))
        Code Type:       \(codeType)
        Platform:        macOS
        Date/Time:       \(dateFormatter.string(from: capture.startedAt))
        OS Version:      macOS \(osVersion)
        Report Version:  7
        Analysis Tool:   ForeverLM main-thread sampler (UIResponsivenessMonitor), in process
        ----

        Stall:           the main thread had not answered for \(String(format: "%.2f", capture.stalledForAtStart)) s when sampling began; sampled for \(String(format: "%.2f", capture.sampledFor)) s, \(ending)
        Sampler:         the main thread only, every \(capture.intervalMilliseconds) ms: \(capture.samples.count) samples, \(capture.failedSamples) failed; each held the main thread \(holds / 1000) us on average, \(capture.longestHoldNanoseconds / 1000) us at most, and nothing else in the app was stopped


        """
    }

    // MARK: Symbol helpers

    /// The UUID and `__TEXT` size from a loaded image's Mach-O header.
    private static func machHeaderFacts(at base: UInt) -> (uuid: String?, textSize: UInt?) {
        guard let header = UnsafeRawPointer(bitPattern: base),
              header.load(as: UInt32.self) == MH_MAGIC_64 else { return (nil, nil) }
        let commandCount = header.load(fromByteOffset: 16, as: UInt32.self)
        var command = header + MemoryLayout<mach_header_64>.size
        var uuid: String?
        var textSize: UInt?
        for _ in 0..<commandCount {
            let kind = command.load(as: UInt32.self)
            let size = command.load(fromByteOffset: 4, as: UInt32.self)
            if kind == UInt32(LC_UUID) {
                let bytes = (0..<16).map { command.load(fromByteOffset: 8 + $0, as: UInt8.self) }
                let hex = bytes.map { String(format: "%02X", $0) }
                uuid = [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(separator: "-")
            } else if kind == UInt32(LC_SEGMENT_64) {
                let name = (0..<16).map { command.load(fromByteOffset: 8 + $0, as: UInt8.self) }
                if name.prefix(6).elementsEqual("__TEXT".utf8) && name[6] == 0 {
                    textSize = UInt(command.load(fromByteOffset: 32, as: UInt64.self))
                }
            }
            guard size >= 8 else { break }
            command += Int(size)
        }
        return (uuid, textSize)
    }

    /// Whether atos's short Swift name (`closure #1 in foo()`) and dladdr's full
    /// demangled one (`closure #1 () -> () in ForeverLM.foo() -> ()`) name the
    /// same function, judged by the function's own name.
    private static func namesAgree(full: String?, short: String) -> Bool {
        guard let full else { return false }
        if full == short { return true }
        let function = short.components(separatedBy: " in ").last ?? short
        let token = function.prefix { $0 != "(" && $0 != "<" && $0 != " " }
        return !token.isEmpty && full.contains(token)
    }

    /// Swift names through the Swift runtime's demangler, C++ names (Core
    /// Animation's, WebKit's, the Swift runtime's own) through libc++abi's.
    private static func demangle(_ name: String) -> String {
        if name.hasPrefix("$s") || name.hasPrefix("_$s") || name.hasPrefix("$S") || name.hasPrefix("_T0") {
            return name.withCString { mangled in
                guard let demangled = foreverLMSwiftDemangle(mangled, UInt(strlen(mangled)), nil, nil, 0) else { return name }
                defer { free(demangled) }
                return String(cString: demangled)
            }
        }
        if name.hasPrefix("_Z"), let cxaDemangle {
            return name.withCString { mangled in
                var status: Int32 = 0
                guard let demangled = cxaDemangle(mangled, nil, nil, &status) else { return name }
                defer { free(demangled) }
                return status == 0 ? String(cString: demangled) : name
            }
        }
        return name
    }

    private typealias CxaDemangle = @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?
    ) -> UnsafeMutablePointer<CChar>?
    /// libc++abi's `__cxa_demangle`, found at run time (`RTLD_DEFAULT`) so the
    /// app does not have to link libc++abi for it.
    private static let cxaDemangle: CxaDemangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__cxa_demangle")
        .map { unsafeBitCast($0, to: CxaDemangle.self) }

    /// One line per address, in order, or nil when atos failed or took over 20 s.
    private static func atos(image: Image, addresses: [UInt]) -> [String]? {
        guard !addresses.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
        process.arguments = ["-o", image.path, "-l", "0x" + String(image.base, radix: 16)]
            + addresses.map { "0x" + String($0, radix: 16) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let timeout = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(addresses.count)
            .map(String.init)
    }

    /// `name (in Image) (File.swift:12)` or `name (in Image) + 40`; nil for an
    /// address atos could not name.
    private static func parseAtos(_ line: String, imageName: String) -> (name: String, fileLine: String?, offset: UInt?)? {
        guard let marker = line.range(of: " (in \(imageName))") else { return nil }
        let name = String(line[..<marker.lowerBound])
        guard !name.isEmpty, !name.hasPrefix("0x") else { return nil }
        let tail = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix("("), tail.hasSuffix(")") {
            return (name, String(tail.dropFirst().dropLast()), nil)
        }
        if tail.hasPrefix("+ "), let offset = UInt(tail.dropFirst(2)) {
            return (name, nil, offset)
        }
        return (name, nil, nil)
    }
}

/// The Swift runtime's demangler, for names `dladdr` returns mangled.
@_silgen_name("swift_demangle")
private func foreverLMSwiftDemangle(
    _ mangledName: UnsafePointer<CChar>?,
    _ mangledNameLength: UInt,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<UInt>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?
#endif
