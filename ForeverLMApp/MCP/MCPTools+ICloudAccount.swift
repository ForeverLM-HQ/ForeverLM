#if os(macOS)
import CloudKit
import Foundation

// MARK: - The iCloud account behind get_mcp_status
//
// The web app reads the learner's library from CloudKit as whoever signed in
// on the page, and reaches this Mac through the gateway as whoever signed in
// with Apple for AI. Those can be two Apple Accounts (web design §7, "the two
// identities could differ"), and a page reading one account's library must
// never ask the Mac of another to make things for it. So `get_mcp_status`
// says which account this Mac syncs with — CloudKit's user record name for
// ForeverLM's container, which CloudKit JS gives the page as
// `userIdentity.userRecordName` for the same account, and the container
// environment — and the gateway's `/web/call` compares the two before it
// relays a web request here (`workers/mcp-gateway/src/web-desktop.ts`).

/// CloudKit's user record name for the account this Mac syncs with, looked up
/// once per signed-in iCloud account and kept until the account changes.
actor CloudKitAccountIdentity {
    static let shared = CloudKitAccountIdentity()

    /// The account the kept name belongs to (`ubiquityIdentityToken`).
    private var token: (any NSObjectProtocol)?
    private var recordName: String?
    private var lookup: Task<String?, Never>?
    /// Bumped whenever the account changes, so a lookup started for the
    /// previous account never stores its answer for the next one.
    private var generation = 0

    /// The record name, or nil when this Mac does not sync with iCloud or
    /// CloudKit has not answered within `timeout`. A lookup still running when
    /// the wait ends keeps running, and the next call waits on it again.
    func currentRecordName(timeout: Duration = .seconds(4)) async -> String? {
        guard CloudRuntimeAvailability.isEnabled,
              let current = FileManager.default.ubiquityIdentityToken else {
            forget()
            return nil
        }
        if token?.isEqual(current) != true {
            forget()
            token = current
        }
        if let recordName { return recordName }
        let task = lookup ?? startLookup(generation: generation)
        return await Self.value(of: task, within: timeout)
    }

    private func startLookup(generation: Int) -> Task<String?, Never> {
        let task = Task { () -> String? in
            // Record names are container-scoped: the page signs in to the library container, so that is
            // the account this Mac names (docs/cloudkit-schema-design.md §2.1). `isEnabled` above checked
            // that this build is entitled to it.
            guard let container = ForeverLMRuntimeIdentity.libraryContainerIdentifier else {
                self.finish(nil, generation: generation)
                return nil
            }
            let found = try? await CKContainer(identifier: container)
                .userRecordID()
                .recordName
            // The task runs on this actor, so the answer is kept at once.
            self.finish(found, generation: generation)
            return found
        }
        lookup = task
        return task
    }

    private func finish(_ found: String?, generation: Int) {
        guard generation == self.generation else { return }
        lookup = nil
        if let found, !found.isEmpty { recordName = found }
    }

    private func forget() {
        generation += 1
        token = nil
        recordName = nil
        lookup = nil
    }

    /// `task`'s value, or nil once `timeout` passes first. A task group cannot
    /// bound this wait: a group returns only once every child has, and
    /// CloudKit's call does not end when it is cancelled (the relay's ping
    /// deadline hung that way on 2026-09-29). So the answer and the deadline
    /// race to resume one continuation, and the first one there wins.
    private static func value(of task: Task<String?, Never>, within timeout: Duration) async -> String? {
        let ending = FirstAnswer()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            ending.keep(continuation)
            Task {
                let found = await task.value
                ending.resume(found)
            }
            Task {
                try? await Task.sleep(for: timeout)
                ending.resume(nil)
            }
        }
    }
}

/// One continuation, resumed exactly once by whichever caller reaches it
/// first; the later one finds nothing to resume.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    func keep(_ continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: String?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

extension MCPDataStore {
    /// `get_mcp_status`'s `icloud_account`: whether this Mac syncs with iCloud
    /// at all, the account it syncs with when CloudKit has said, and the
    /// container environment. No record name means the account is not known,
    /// and the gateway treats that as unverified, never as a match.
    static func iCloudAccountStatus(syncs: Bool, userRecordName: String?, environment: String) -> [String: Any] {
        var account: [String: Any] = [
            "syncs_with_icloud": syncs,
            "environment": environment,
        ]
        if syncs, let userRecordName, !userRecordName.isEmpty {
            account["user_record_name"] = userRecordName
        }
        return account
    }
}
#endif
