import CloudKit
import Foundation
import os

/// Retries the CloudKit failures that pass on their own.
///
/// The phone has no `CKSyncEngine` to do this for it: the catalog, the source
/// text and file stores and the mutation service all call CloudKit directly.
/// Until 2026-09-26 none of them retried, so one dropped connection reached the
/// learner as "Highlights could not be loaded: The operation couldn't be
/// completed. (CKErrorDomain error 4.)" or "Sources could not sync". Error 4 is
/// `networkFailure`, and it is most common exactly when the app refreshes: the
/// first request after a return from the background goes out on a connection
/// iOS tore down while the app was suspended.
///
/// Every call wrapped here must be safe to repeat. Fetches are. A save that
/// may have landed before its reply was lost is too, because the mutation
/// service answers the retry's `serverRecordChanged` by refetching and
/// reapplying, and a repeated delete's `unknownItem` counts as done.
///
/// `MobileModelRouteError.transientRetryDelay` stays separate on purpose: it
/// guards a tap on Listen or a chat send, so it retries once and caps the wait
/// at three seconds, where a sync can afford to wait out a throttle.
enum MobileCloudKitRetry {
    /// CloudKit's documented "try again later" codes. `networkUnavailable` is
    /// here too: iOS reports it for a moment while a connection changes hands
    /// (Wi-Fi to cellular, leaving a lift), not only when the phone is offline.
    static let transientCodes: Set<CKError.Code> = [
        .networkFailure,
        .networkUnavailable,
        .serviceUnavailable,
        .requestRateLimited,
        .zoneBusy,
        .serverResponseLost,
        .accountTemporarilyUnavailable,
    ]

    /// A background sync keeps going through about seven seconds of backoff.
    static let syncAttempts = 4
    /// Something the learner opened and is waiting on gives up sooner, so an
    /// offline phone says so in about three seconds instead of spinning.
    static let interactiveAttempts = 3

    /// The longest wait honoured from a retry-after hint. A throttled container
    /// can ask for tens of seconds; beyond this the call fails and the next
    /// foreground or pull-to-refresh tries again.
    static let maximumDelaySeconds: Double = 30

    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "CloudKitRetry")

    static func isTransient(_ error: Error) -> Bool {
        // A satellite fetch wraps the CloudKit failure in `BlobStoreError.failed`; it is the same
        // failure, and bare it reads "ForeverLM.BlobStoreError error 4" (the numbering puts the
        // cases that carry a value first, which makes `.failed` 4).
        if case .failed(let cloudError) = error as? BlobStoreError { return transientCodes.contains(cloudError.code) }
        guard let ckError = error as? CKError else { return false }
        if transientCodes.contains(ckError.code) { return true }
        // A batch that failed item by item is transient only when every item
        // failed transiently; one permanent failure means repeating it cannot help.
        if ckError.code == .partialFailure,
           let itemErrors = ckError.partialErrorsByItemID?.values,
           !itemErrors.isEmpty {
            return itemErrors.allSatisfy(isTransient)
        }
        return false
    }

    /// How long to wait before attempt `attempt + 1`, or nil when the failure
    /// is not worth repeating. CloudKit's own retry-after hint wins; without
    /// one the wait doubles from a second. The floor keeps a zero hint from
    /// retrying straight back into the same outage.
    static func delay(after error: Error, attempt: Int) -> Duration? {
        guard isTransient(error) else { return nil }
        let backoff = pow(2, Double(max(attempt, 1) - 1))
        let seconds = min(max(retryAfterSeconds(error) ?? backoff, 0.5), maximumDelaySeconds)
        return .milliseconds(Int((seconds * 1000).rounded()))
    }

    /// Runs `operation`, repeating it after a transient CloudKit failure until
    /// it succeeds, fails permanently, or uses up `attempts`. The last error is
    /// thrown unchanged, so callers still see the real code. Cancellation ends
    /// the wait at once.
    static func run<T>(
        _ label: String,
        attempts: Int = syncAttempts,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < attempts, let wait = delay(after: error, attempt: attempt) else {
                    throw error
                }
                let code = (error as? CKError)?.code.rawValue ?? -1
                let seconds = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
                logger.info(
                    "\(label, privacy: .public) hit transient CloudKit error \(code, privacy: .public) on attempt \(attempt, privacy: .public); retrying in \(seconds, privacy: .public)s"
                )
                try await Task.sleep(for: wait)
                attempt += 1
            }
        }
    }

    /// What to tell the learner once the retries are spent. The system text is
    /// "The operation couldn't be completed. (CKErrorDomain error 4.)", with
    /// only the number changing, which names neither the cause nor what to do.
    /// A permanent failure keeps its own description.
    static func describe(_ error: Error) -> String {
        guard isTransient(error) else { return error.localizedDescription }
        var code = (error as? CKError)?.code
        if case .failed(let cloudError) = error as? BlobStoreError { code = cloudError.code }
        switch code {
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud is busy right now. Try again in a moment."
        case .accountTemporarilyUnavailable:
            return "iCloud is not ready on this iPhone right now. Try again in a moment."
        default:
            return "iCloud could not be reached. Check the connection and try again in a moment."
        }
    }

    private static func retryAfterSeconds(_ error: Error) -> Double? {
        guard let ckError = error as? CKError else { return nil }
        if let seconds = ckError.retryAfterSeconds { return seconds }
        return ckError.partialErrorsByItemID?.values
            .compactMap { ($0 as? CKError)?.retryAfterSeconds }
            .max()
    }
}
