import Foundation
import OSLog

/// The single write path for synced user preferences.
///
/// Every allowlisted preference write goes through `set`/`remove`. They write
/// `UserDefaults` synchronously — cheap and main-actor-safe, since `UserDefaults`
/// serves reads from an in-memory `CFPreferences` cache — and hand persistence to
/// the storage layer off-main.
///
/// **Why a façade rather than observing `UserDefaults.didChangeNotification` and
/// diffing.** Three reasons, each independently disqualifying:
///
/// 1. The notification fires for *every* defaults write in the process, including
///    the ~180 `NSWindow Frame` keys AppKit rewrites on the main thread during
///    ordinary window and splitter drags.
/// 2. Reacting to a write means reconstructing the key and value that the caller
///    already had one stack frame earlier.
/// 3. It makes echo suppression a guessing game. An inbound sync write is
///    indistinguishable from a user edit once it has landed in `UserDefaults`, so
///    an observer must infer intent from value equality — which fails exactly when
///    an inbound change interleaves with a local edit of the same key, re-pushing
///    the remote value with a newer timestamp and clobbering what the user just did.
///
/// Intercepting the write removes the ambiguity instead of managing it: `set` is
/// the only thing that enqueues an outbound change, and `applyInbound` never calls
/// it. No suppression counters, no cross-actor state, no equality heuristics.
enum PreferenceStore {

    /// Posted on the main thread after inbound (remote) preference changes have been
    /// written to `UserDefaults`. The payload is the changed key set under
    /// `changedKeysKey`.
    ///
    /// Readers fall into three classes and need different handling:
    /// - Computed properties that read `UserDefaults` live on every access
    ///   (`MacArticleSpeechSettings`, `AIModelDefaults`, `KeychainService`) already
    ///   see the new value; they only need a UI nudge.
    /// - `StudioViewModel`'s stored properties are seeded once in their property
    ///   initializers and observe nothing, so they need an explicit main-actor
    ///   reseed or the change won't appear until the next launch.
    /// - SwiftUI views reading through the storage wrapper refresh off this.
    static let didChangeRemotely = Notification.Name("foreverlmPreferencesDidChangeRemotely")

    /// Posted on the main thread after this Mac's own write through the façade
    /// changed a preference: `set`, `remove`, and `mirrorExternalWrite` (a
    /// `SyncedStorage` binding). The payload is the changed key set under
    /// `changedKeysKey`, as for `didChangeRemotely`.
    ///
    /// Between them the two notifications name every preference change, so a
    /// reader of one key listens to both and reads its key only when it is named
    /// (`PreferenceKeyWatcher`). `UserDefaults.didChangeNotification` is no
    /// substitute: it fires for every defaults write in the process (window
    /// frames, Sparkle's check dates), and a handler that reads defaults there
    /// makes CFPreferences re-merge and re-diff the whole domain after each one.
    static let didChangeLocally = Notification.Name("foreverlmPreferencesDidChangeLocally")

    /// `userInfo` key holding a `Set<String>` of the keys that changed.
    static let changedKeysKey = "changedKeys"

    /// Whether a `didChangeLocally` or `didChangeRemotely` notification may have
    /// changed `key`. A missing or empty key set means anything may have changed:
    /// the generation-2 projections that cannot name their keys post that.
    static func notification(_ notification: Notification, mayHaveChanged key: String) -> Bool {
        guard let keys = notification.userInfo?[changedKeysKey] as? Set<String>, !keys.isEmpty else { return true }
        return keys.contains(key)
    }

    // MARK: - Local writes

    /// Write a preference and queue it for sync.
    ///
    /// A no-op write is dropped rather than marked dirty — SwiftUI reassigns
    /// bindings freely, and every redundant write would otherwise become a CloudKit
    /// record save and a `userModificationDate` bump that can lose a concurrent
    /// edit on the other Mac.
    static func set(_ value: Any?, forKey key: String) {
        guard let value else {
            remove(forKey: key)
            return
        }
        let defaults = UserDefaults.standard
        if let existing = defaults.object(forKey: key), plistEqual(existing, value) {
            return
        }
        defaults.set(value, forKey: key)
        recordWrite(key, value)
        enqueueSync(key: key, value: value)
        postLocalChange(key)
    }

    /// Clear a preference and queue the deletion for sync.
    static func remove(forKey key: String) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
        recordWrite(key, nil)
        enqueueSync(key: key, value: nil)
        postLocalChange(key)
    }

    /// Announces a local write on the main thread, hopping only when the caller
    /// is elsewhere, for the reason `postRemoteChange` gives.
    private static func postLocalChange(_ key: String) {
        let post = {
            NotificationCenter.default.post(name: didChangeLocally, object: nil, userInfo: [changedKeysKey: Set([key])])
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    // MARK: - Inbound (remote) writes

    /// Apply preference changes that arrived from CloudKit.
    ///
    /// Deliberately does not route through `set`: inbound changes must never be
    /// re-enqueued as outbound saves, or two Macs ping-pong the same record forever.
    /// The one exception is a merged row that holds more than what arrived
    /// (`resolvedInbound`), which settles after one round.
    ///
    /// Takes non-optional values, with removals handled by `applyInboundRemoval`.
    /// A `[String: Any?]` would be a trap here: `dict[key] = nil` *erases the entry*
    /// rather than storing a nil, so tombstones would vanish before they were read.
    static func applyInbound(_ values: [String: Any]) {
        guard !values.isEmpty else { return }
        let defaults = UserDefaults.standard
        var changed: Set<String> = []
        var sendBack: [String: Any] = [:]

        for (key, incoming) in values {
            guard SyncedPreferenceKeys.isSynced(key) else { continue }
            let resolved = resolvedInbound(key: key, incoming: incoming, local: defaults.object(forKey: key))
            if resolved.sendBack { sendBack[key] = resolved.value }
            let value = resolved.value
            if let existing = defaults.object(forKey: key), plistEqual(existing, value) { continue }
            defaults.set(value, forKey: key)
            recordWrite(key, value)
            changed.insert(key)
        }

        // Only a merge that holds more than what arrived goes back out; the
        // other device's merge of it then equals what it receives, so this
        // never ping-pongs.
        for (key, value) in sendBack {
            enqueueSync(key: key, value: value)
        }
        postRemoteChange(changed)
    }

    /// What an inbound row becomes on this device, and whether it goes back
    /// out. A row is taken as it arrives (the newer write wins whole), except a
    /// Map's `map.layout.<mapID>` row (merged entry by entry) and a
    /// `cards.state.<deckID>` row: it holds one entry per card, so it is merged
    /// card by card with this device's copy, and the merge is sent back when it
    /// holds something the incoming row lacks
    /// (`MemoryCardDeckState.mergedOnReceipt`). Two devices that changed
    /// different cards before syncing both keep both changes.
    static func resolvedInbound(key: String, incoming: Any, local: Any?) -> (value: Any, sendBack: Bool) {
        // A Map's layout row holds one entry per placement, region and arrow,
        // merged entry by entry the same way (`KnowledgeMapLayout.merged`).
        if KnowledgeMap.mapID(fromLayoutKey: key) != nil {
            guard let merged = KnowledgeMapLayout.mergedOnReceipt(incoming: incoming, local: local) else {
                return (incoming, false)
            }
            return (merged, true)
        }
        guard MemoryCardDeckState.deckID(fromPreferenceKey: key) != nil,
              let merged = MemoryCardDeckState.mergedOnReceipt(incoming: incoming, local: local) else {
            return (incoming, false)
        }
        return (merged, true)
    }

    /// Apply a preference deletion that arrived from CloudKit.
    static func applyInboundRemoval(forKey key: String) {
        guard SyncedPreferenceKeys.isSynced(key) else { return }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
        recordWrite(key, nil)
        postRemoteChange([key])
    }

    /// Deliver on the main thread, hopping only when the caller is not already there.
    ///
    /// Notification delivery is synchronous on the posting thread, and every reader
    /// of these two names is UI. That is not something an observer can be trusted to
    /// fix on its own: a SwiftUI `onReceive` closure is typed main-actor because it
    /// lives in a view body, so the compiler raises nothing when the closure calls a
    /// main-actor method — the isolation is violated only at runtime, when the
    /// publisher happens to emit off-main. Both inbound paths do exactly that
    /// (`hydrateFromStore` and the CloudKit engine), so posting from them ran
    /// `@Published` mutations on a storage thread. The hop belongs at the single post
    /// site rather than in each present and future observer.
    private static func postRemoteChange(_ changed: Set<String>) {
        guard !changed.isEmpty else { return }
        if Thread.isMainThread {
            deliverRemoteChange(changed)
        } else {
            DispatchQueue.main.async { deliverRemoteChange(changed) }
        }
    }

    private static func deliverRemoteChange(_ changed: Set<String>) {
        NotificationCenter.default.post(
            name: didChangeRemotely,
            object: nil,
            userInfo: [changedKeysKey: changed]
        )
        if changed.contains(where: SyncedPreferenceKeys.isPersistedModelConfiguration) {
            // Model pickers cache their selection in @State for cheap rendering.
            // Rehydrating UserDefaults after a rebuild must refresh those snapshots
            // in the same launch, not require the learner to reopen the app.
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
        if changed.contains(AIDataPolicy.denyDataCollectionKey) {
            // The other device flipped "Don't show models that train on my
            // data": the catalog hides or shows those models on its next read,
            // and a chat sitting on one of them goes back to the default here
            // as it would have on the device that flipped it.
            AIModelCatalog.dataPolicyDidChange()
        }
    }

    // MARK: - Sync hand-off

    /// The storage actor used for preference persistence. `StorageService` has no
    /// singleton — callers construct one freely — but each instance caches its own
    /// `KnowledgeStore`, so holding one here avoids reopening SQLite per write.
    private static let syncStore = StorageService()
    private static let persistenceLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "PreferencePersistence"
    )
    private static let persistenceLock = NSLock()
    private nonisolated(unsafe) static var persistenceTail: Task<Void, Never>?
    private nonisolated(unsafe) static var persistenceGeneration = 0

    private enum PersistenceOperation: Sendable {
        case write(key: String, xml: String)
        case delete(key: String)
    }

    private static func enqueueSync(key: String, value: Any?) {
        guard SyncedPreferenceKeys.isSynced(key) else { return }
        let operation: PersistenceOperation
        if let value, let xml = encodePlist(value) {
            operation = .write(key: key, xml: xml)
        } else {
            operation = .delete(key: key)
        }

        // Preserve call order. Independent detached tasks can reach the storage
        // actor in either order, so two quick picks (A then B) could previously
        // leave B in UserDefaults but stale A in knowledge.db. The next rebuild
        // would hydrate A and look as if the setting had not persisted.
        persistenceLock.lock()
        let predecessor = persistenceTail
        persistenceGeneration += 1
        let generation = persistenceGeneration
        // Journal the key before the write can be lost: UserDefaults already
        // holds the new value, and a quit, rebuild, update relaunch or "database
        // is locked" before the row lands would otherwise let the next launch's
        // hydration restore the old row over it.
        writeJournal.begin(key, generation: generation)
        let next = Task.detached(priority: .utility) {
            await predecessor?.value
            do {
                switch operation {
                case let .write(key, xml):
                    try await syncStore.writePreference(key: key, valuePlistXML: xml)
                case let .delete(key):
                    try await syncStore.deletePreference(key: key)
                }
                confirmPersisted(key, generation: generation)
            } catch {
                persistenceLogger.error(
                    "Could not persist preference to knowledge.db: \(error.localizedDescription, privacy: .public)"
                )
            }
            clearPersistenceTail(ifGeneration: generation)
        }
        persistenceTail = next
        persistenceLock.unlock()
    }

    /// Wait until every preference write enqueued before this call is durable.
    /// Awaiting suspends the caller; SQLite work remains on `StorageService`.
    static func flushPendingWrites() async {
        let tail = pendingWriteTail()
        await tail?.value
    }

    /// Keep lock acquisition in a synchronous function. Swift correctly rejects
    /// holding an `NSLock` directly from an async context across a suspension.
    private static func pendingWriteTail() -> Task<Void, Never>? {
        persistenceLock.lock()
        let tail = persistenceTail
        persistenceLock.unlock()
        return tail
    }

    /// Release the completed task chain once the queue drains. During a burst the
    /// newest task keeps its predecessors alive so it can await them; retaining
    /// that chain after all writes finish would make routine settings changes
    /// accumulate completed tasks for the lifetime of the app.
    private static func clearPersistenceTail(ifGeneration generation: Int) {
        persistenceLock.lock()
        if persistenceGeneration == generation {
            persistenceTail = nil
        }
        persistenceLock.unlock()
    }

    // MARK: - Unconfirmed writes

    /// Guarded by `persistenceLock`. The journal's key set is changed under the
    /// lock but written to `UserDefaults` on `journalWriteQueue`, never while
    /// the lock is held: a `UserDefaults` write posts `didChangeNotification`
    /// on the writing thread, and an observer on the main queue makes that post
    /// wait for the main thread, which may itself be waiting for this lock in
    /// `set`. On 2026-09-25 exactly that deadlocked the unit-test host's main
    /// thread for half an hour in `CoursePersistenceTests`. The serial queue
    /// keeps the snapshots in the order the lock handed them out.
    private nonisolated(unsafe) static var writeJournal = PreferenceWriteJournal(defaults: .standard) { keys in
        journalWriteQueue.async { PreferenceWriteJournal.write(keys, to: .standard) }
    }
    private static let journalWriteQueue = DispatchQueue(label: "com.foreverlm.preference-journal", qos: .utility)

    private static func confirmPersisted(_ key: String, generation: Int) {
        persistenceLock.lock()
        writeJournal.confirm(key, generation: generation)
        persistenceLock.unlock()
    }

    private static func unconfirmedKeys() -> Set<String> {
        persistenceLock.lock()
        let keys = writeJournal.keys
        persistenceLock.unlock()
        return keys
    }

    /// Write every journaled key's current `UserDefaults` value to knowledge.db:
    /// the writes an earlier run queued but never finished. Returns the keys
    /// still unconfirmed afterwards, which hydration must not overwrite.
    private static func persistUnconfirmedWrites() async -> Set<String> {
        let keys = unconfirmedKeys()
        guard !keys.isEmpty else { return [] }
        for key in keys.sorted() {
            // A key a later build stopped syncing has no row to protect.
            guard SyncedPreferenceKeys.isSynced(key) else {
                persistenceLock.lock()
                writeJournal.discard(key)
                persistenceLock.unlock()
                continue
            }
            persistenceLogger.notice(
                "Re-persisting preference '\(key, privacy: .public)': its last write never reached knowledge.db"
            )
            enqueueSync(key: key, value: UserDefaults.standard.object(forKey: key))
        }
        await flushPendingWrites()
        return unconfirmedKeys()
    }

    /// Persist a value that another mechanism has already written to `UserDefaults`.
    ///
    /// Exists for `SyncedStorage`, which delegates the actual write to `AppStorage`
    /// and then calls this to mirror the result onto the sync rail. Reads the value
    /// back rather than taking it as a parameter so the persisted value is exactly
    /// what `AppStorage` stored, including its type bridging.
    static func mirrorExternalWrite(forKey key: String) {
        defer { postLocalChange(key) }
        guard SyncedPreferenceKeys.isSynced(key) else { return }
        let value = UserDefaults.standard.object(forKey: key)
        recordWrite(key, value)
        enqueueSync(key: key, value: value)
    }

    // MARK: - Hydration

    /// Rewrite `UserDefaults` from the synced rows in `knowledge.db`.
    ///
    /// Called after CloudKit lands remote preference changes. Loading every row
    /// rather than only the changed keys keeps the caller from having to thread the
    /// changed set through the sync engine — there are tens of short rows, and
    /// `applyInbound` drops anything that already matches, so the cost of the extra
    /// rows is a dictionary comparison each.
    static func hydrateFromStore() async {
        // Never let an older queued value win merely because hydration raced it.
        await flushPendingWrites()
        // Nor a write an earlier run queued and lost: the model picked just
        // before a rebuild came back as the one before it (2026-09-25).
        let unconfirmed = await persistUnconfirmedWrites()
        // A row this Mac holds but cannot read is not "not synced yet". Repair
        // the one damage seen in the wild first, so the loop below reads the
        // value and the outbox carries the clean row to the other Mac, and
        // name whatever still cannot be read.
        let repairReport: KnowledgeStore.PreferenceRepairReport?
        do {
            repairReport = try await syncStore.repairUnreadablePreferences()
        } catch {
            persistenceLogger.error("Repairing unreadable preference rows failed: \(error.localizedDescription, privacy: .public)")
            repairReport = nil
        }
        if let report = repairReport {
            for key in report.repaired {
                persistenceLogger.notice(
                    "Repaired unreadable preference row '\(key, privacy: .public)': re-encoded and queued for sync"
                )
            }
            for key in report.unreadable {
                persistenceLogger.error(
                    "Preference row '\(key, privacy: .public)' cannot be decoded; it stays as stored and is not applied"
                )
            }
        }
        let stored: [String: String]
        do {
            stored = try await syncStore.allPreferences()
        } catch {
            persistenceLogger.error("Reading the stored preferences failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        var decoded: [String: Any] = [:]
        for (key, xml) in stored {
            guard SyncedPreferenceKeys.isSynced(key) else { continue }
            // Still unwritten (the store is failing): the row is older than
            // UserDefaults, so it stays out until a later pass lands the value.
            guard !unconfirmed.contains(key) else { continue }
            guard let value = decodePlist(xml) else { continue }
            decoded[key] = value
        }
        // Applied off the main actor deliberately: UserDefaults is thread-safe, and
        // the codebase already posts sync notifications from the storage actor.
        // The resulting change notification is posted on main
        // by `postRemoteChange`, so observers need no hop of their own.
        applyInbound(decoded)
    }

    // MARK: - Plist encoding

    /// Encode a preference value as an XML property list.
    ///
    /// Wrapped in a single-key dictionary because a bare scalar root is not
    /// reliably representable, and because it leaves room to carry per-key metadata
    /// later without another schema change.
    static func encodePlist(_ value: Any) -> String? {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: ["v": value],
            format: .xml,
            options: 0
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode a value written by `encodePlist`. Returns nil for a tombstone or
    /// unreadable payload, which `applyInbound` treats as "remove this key".
    static func decodePlist(_ xml: String) -> Any? {
        guard !xml.isEmpty, let data = xml.data(using: .utf8) else { return nil }
        let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return (plist as? [String: Any])?["v"]
    }

    /// `decodePlist`, and for a row it rejects, one more try after undoing the
    /// one damage seen in the wild: the two-character text `\t` or `\n` between
    /// elements, where the encoder writes a real tab or newline. That is what a
    /// `sqlite3` insert typed with escape sequences leaves behind, since SQL
    /// string literals expand nothing. Only whitespace between tags is touched —
    /// a backslash inside a `<string>` is content and stays — and nil means the
    /// row still does not parse.
    static func recoverPlist(_ xml: String) -> Any? {
        if let value = decodePlist(xml) { return value }
        guard let expression = escapedInterElementWhitespace else { return nil }
        let repaired = expression.stringByReplacingMatches(
            in: xml,
            range: NSRange(xml.startIndex..., in: xml),
            withTemplate: "$1 "
        )
        guard repaired != xml else { return nil }
        return decodePlist(repaired)
    }

    /// A run of `\t` / `\n` / `\r` written as text, bounded by a tag or real
    /// whitespace before it and a tag, whitespace, or the end after it — so never
    /// part of a value. Group 1 keeps the character before the run.
    private static let escapedInterElementWhitespace = try? NSRegularExpression(
        pattern: #"([>\s])(?:\\[tnr])+(?=[<\s]|$)"#
    )

    // MARK: - Value comparison

    /// Compare two property-list values. `UserDefaults` hands back Foundation
    /// bridged types, so `isEqual` is the right comparison — `==` on `Any` is not
    /// available and `AnyHashable` would not match across e.g. `Int`/`NSNumber`.
    private static func plistEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as? NSObject)?.isEqual(rhs as? NSObject) ?? false
    }

    // MARK: - Debug backstop

    private static let lastWrittenLock = NSLock()
    private nonisolated(unsafe) static var lastWritten: [String: Any] = [:]

    private static func recordWrite(_ key: String, _ value: Any?) {
        lastWrittenLock.lock()
        defer { lastWrittenLock.unlock() }
        lastWritten[key] = value
    }

    #if DEBUG
    /// Warn when an allowlisted preference is written to `UserDefaults` behind the
    /// façade's back. Such a write reaches the local defaults but never the sync
    /// rail, so the setting silently stops following the account — a failure whose
    /// only symptom is "it didn't show up on my other Mac", weeks later.
    ///
    /// DEBUG-only: this is the observer whose cost ruled out observe-and-diff as
    /// the production mechanism, and it is a development guardrail, not a feature.
    static func startBypassAudit() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in
            let defaults = UserDefaults.standard
            lastWrittenLock.lock()
            let snapshot = lastWritten
            lastWrittenLock.unlock()
            for (key, expected) in snapshot {
                let actual = defaults.object(forKey: key)
                if actual == nil || !plistEqual(expected, actual!) {
                    persistenceLogger.error("'\(key, privacy: .public)' was written outside PreferenceStore — it will not sync. Route it through PreferenceStore.set.")
                    recordWrite(key, actual)
                }
            }
        }
    }
    #endif
}

/// Calls back when one preference's value changes, whoever changed it: this
/// Mac's own writes through `PreferenceStore` (the Settings switch, an MCP
/// `set_app_setting`, a `SyncedStorage` binding), announced as
/// `didChangeLocally`, and another device's, applied by `applyInbound` and
/// announced as `didChangeRemotely`.
///
/// It reads the value only when a notification names its key (or names none,
/// meaning anything may have changed), never on
/// `UserDefaults.didChangeNotification`. That one fires for every defaults write
/// in the process, and the first read after a write makes CFPreferences re-merge
/// the domain and diff it for KVO observers: about 45 ms on the main thread with
/// build 210's 2.4 MB preferences file, paid after every window-frame save and
/// Sparkle check date by the beta sign-up check that used to listen there (137
/// samples across six production stall files, 2026-10-11).
///
/// Whoever reads first after a write pays that diff, and other readers remain
/// (each `SyncedStorageObserver` reads its key on that notification), so what
/// makes the read cheap is a smaller domain (`RetiredDefaultsCleanup`); this
/// keeps the beta check from adding a read of its own to every write.
///
/// Not actor-isolated, like `SyncedStorageObserver`: its observers run on the
/// main queue, and its owner reads `value` there.
final class PreferenceKeyWatcher<Value: Equatable> {
    let key: String
    /// The value as last read.
    private(set) var value: Value

    private let read: () -> Value
    private let onChange: (Value) -> Void
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(
        key: String,
        center: NotificationCenter = .default,
        read: @escaping () -> Value,
        onChange: @escaping (Value) -> Void
    ) {
        self.key = key
        self.center = center
        self.read = read
        self.onChange = onChange
        value = read()
        for name in [PreferenceStore.didChangeLocally, PreferenceStore.didChangeRemotely] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, PreferenceStore.notification(notification, mayHaveChanged: self.key) else { return }
                self.check()
            })
        }
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
    }

    /// Reads the value and calls back when it differs from the one last read.
    func check() {
        let current = read()
        guard current != value else { return }
        value = current
        onChange(current)
    }
}

/// The synced keys whose `UserDefaults` value knowledge.db has not confirmed.
///
/// A preference reaches `UserDefaults` at once and knowledge.db later, through
/// the storage actor. Launch hydration copies knowledge.db back over
/// `UserDefaults`, so a row that never landed — the app quit, rebuilt or
/// updated first, or the write hit "database is locked" — used to bring back
/// the value from before the last change. The journal lives in `UserDefaults`
/// beside the value itself, so it survives exactly what the lost write did
/// not, and it is local: the key matches no synced name or prefix.
struct PreferenceWriteJournal {
    static let defaultsKey = "preferenceStore.unconfirmedWrites"

    /// The unconfirmed keys, read from `UserDefaults` once and kept here, so
    /// a caller holding a lock never has to read or write `UserDefaults`.
    private(set) var keys: Set<String>
    /// The newest write queued per key in this run. An older write finishing
    /// after a newer one was queued confirms nothing.
    private var latestGeneration: [String: Int] = [:]
    /// Saves a changed key set. Writes to `defaults` at once unless the
    /// caller hands the write elsewhere (`PreferenceStore` does, off its lock).
    private let persist: (Set<String>) -> Void

    init(defaults: UserDefaults, persist: ((Set<String>) -> Void)? = nil) {
        self.keys = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        self.persist = persist ?? { Self.write($0, to: defaults) }
    }

    mutating func begin(_ key: String, generation: Int) {
        latestGeneration[key] = generation
        if keys.insert(key).inserted { persist(keys) }
    }

    mutating func confirm(_ key: String, generation: Int) {
        guard latestGeneration[key] == generation else { return }
        discard(key)
    }

    mutating func discard(_ key: String) {
        latestGeneration.removeValue(forKey: key)
        if keys.remove(key) != nil { persist(keys) }
    }

    static func write(_ keys: Set<String>, to defaults: UserDefaults) {
        if keys.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(keys.sorted(), forKey: Self.defaultsKey)
        }
    }
}
