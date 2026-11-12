import Foundation
import os

/// The app's lock, in place of `NSLock`. Taking it again on the thread that
/// already holds it cannot hang: the second `lock()` goes through, a fault is
/// logged with the call stack, and a Debug build or a test run stops at that
/// line. An `NSLock` waits on itself forever there, and as soon as the main
/// thread wants the same lock the app beachballs until it is force quit, which
/// is how build 291 hung on opening the AI activity list (a model-catalog
/// helper took the release-date lock and then called a loader that took it
/// again).
///
/// Otherwise it is used like `NSLock`: `lock()` and `unlock()` on the same
/// thread, or `withLock`, with no `await` in between. Two locks taken in
/// opposite orders on two threads still deadlock; `scripts/check_lock_reentry.py`
/// looks for that, and for re-entry, on every build.
final class AppLock: NSObject, NSLocking, @unchecked Sendable {
    private let base = NSRecursiveLock()
    /// How many times the holding thread has taken the lock. Read and written
    /// only while holding it.
    private var depth = 0
    private var reportedReentry = false

    override init() {
        super.init()
    }

    func lock() {
        base.lock()
        depth += 1
        if depth > 1 { reportReentry() }
    }

    func unlock() {
        depth -= 1
        base.unlock()
    }

    /// Runs with the lock held. Logs once per lock, so a hot path that
    /// re-enters does not flood the log; a Debug build stops on the first.
    private func reportReentry() {
        guard !reportedReentry else { return }
        reportedReentry = true
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(10).joined(separator: " | ")
        Self.logger.fault("LOCK_REENTRY a lock was taken again on the thread that holds it: \(stack, privacy: .public)")
        assertionFailure("AppLock taken again on the thread that holds it. A release build goes on instead of hanging; fix the caller (see the call stack).")
    }

    private static let logger = Logger(subsystem: "com.foreverlm", category: "Responsiveness")
}
