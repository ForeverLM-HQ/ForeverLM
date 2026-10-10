import Foundation
import OSLog

/// The Mac's reads and writes of what the learner did with each card: under generation 2 the cards'
/// `Card` rows (`memory_card_states`, `KnowledgeStore+CardRecords`), read in memory; under generation 1
/// the `cards.state.<deckID>` rows (`MemoryCardDeckState`), through the synced preference path.
///
/// Reading is free and writes nothing. `update` is the one write: the deck's state as stored, the
/// caller's change applied, the result written. Call it only for something the learner did to a card
/// (Keep, Skip, an edit, start over), never to show cards, and never while holding a lock.
///
/// **Generation 2** (an activated store, `KnowledgeStore.recordsMemoryForGeneration2`): the decks' states
/// are read from the Card rows into memory off the main actor, so the card review, All Cards and the
/// Memory pane read them synchronously, as they read the preference rows under generation 1. A write lands
/// in memory at once and in the rows off the main actor, in call order, only for the cards it changed;
/// the rows are then read again. After a sync round brought Cards from another device (`reload`, from
/// `MacRoundHooks.afterFetch`), the surfaces are told when the states changed. A test binds its own
/// `Records` with its own storage (`bound`).
///
/// **Generation 1**: read, merge, write with `PreferenceStore.set`, which queues the row for the other
/// devices; a row arriving from another device is merged with this Mac's on receipt
/// (`PreferenceStore.applyInbound`). A defaults write posts its change notification on the writing
/// thread, and an observer on the main queue then waits for a main thread that may be waiting on a lock.
enum MemoryCardStateStore {
    /// One deck's row as stored; an empty row when there is none.
    static func load(deckID: String, defaults: UserDefaults = .standard) -> MemoryCardDeckState {
        if usesCardRecords(defaults) { return records.decks()[deckID] ?? MemoryCardDeckState() }
        return preferenceRow(deckID: deckID, defaults: defaults)
    }

    /// Generation 1's row for a deck in `defaults`: what storage reads on a store that is not activated
    /// for generation 2 (`StorageService.cardDeckStates`).
    static func preferenceRow(deckID: String, defaults: UserDefaults) -> MemoryCardDeckState {
        defaults.object(forKey: MemoryCardDeckState.preferenceKey(deckID: deckID))
            .flatMap(MemoryCardDeckState.init(preferenceValue:))
            ?? MemoryCardDeckState()
    }

    /// One card's state, read from its deck's row.
    static func state(cardID: String, deckID: String, defaults: UserDefaults = .standard) -> MemoryCardState? {
        load(deckID: deckID, defaults: defaults).cards[cardID]
    }

    /// Every stored row, by deck id: one scan of the defaults dictionary finds
    /// the runtime-built keys.
    static func allDecks(defaults: UserDefaults = .standard) -> [String: MemoryCardDeckState] {
        if usesCardRecords(defaults) { return records.decks() }
        var decks: [String: MemoryCardDeckState] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard let deckID = MemoryCardDeckState.deckID(fromPreferenceKey: key),
                  let deck = MemoryCardDeckState(preferenceValue: value) else { continue }
            decks[deckID] = deck
        }
        return decks
    }

    /// Read, change, write over `defaults`. Returns the row as written. On the main actor, so two of the
    /// learner's actions never interleave their read and write and lose one change.
    ///
    /// Under generation 2 the deck's state in memory is changed, and the cards the change touched are
    /// written into their Card rows off the main actor (`KnowledgeStore.writeCardRecordStates`); `local`
    /// is generation 1's. Under generation 1 the caller's copy is merged in card by card
    /// (`MemoryCardDeckState.updating`); the standard defaults are written through `PreferenceStore.set`,
    /// which queues the row for the other devices, and other defaults (a test's own suite) are written
    /// directly and sync nothing.
    @MainActor
    @discardableResult
    static func update(
        deckID: String,
        local: MemoryCardDeckState? = nil,
        defaults: UserDefaults = .standard,
        _ change: (inout MemoryCardDeckState) -> Void
    ) -> MemoryCardDeckState {
        if usesCardRecords(defaults) {
            let records = records
            let (deck, changed) = records.change(deckID: deckID, change)
            if !changed.isEmpty {
                let now = Date()
                records.enqueue { try $0.writeCardRecordStates(deckID: deckID, changed, at: now) }
            }
            return deck
        }
        return MemoryCardDeckState.updating(
            deckID: deckID,
            local: local,
            read: { defaults.object(forKey: $0) },
            write: { value, key in
                if defaults === UserDefaults.standard {
                    PreferenceStore.set(value, forKey: key)
                } else {
                    defaults.set(value, forKey: key)
                }
            },
            change
        )
    }

    /// "Always ask it this way" on a kept card, or off again: written in its
    /// deck's row, so every device asks it the same way. An item from before
    /// cards that has no row yet gets one that still says draft, so it keeps
    /// its place in To Check until the learner goes through it.
    @MainActor
    @discardableResult
    static func setAlwaysAsk(
        _ on: Bool,
        cardID: String,
        memoryItemID: String,
        deckID: String,
        isFromBeforeCards: Bool,
        at now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> MemoryCardDeckState {
        update(deckID: deckID, defaults: defaults) { row in
            var state = row.cards[cardID] ?? MemoryCardState(
                status: isFromBeforeCards ? .draft : .kept,
                memoryItemID: memoryItemID,
                updatedAt: now
            )
            guard state.alwaysAsk != on else { return }
            state.alwaysAsk = on
            if state.memoryItemID == nil { state.memoryItemID = memoryItemID }
            state.updatedAt = now
            row.cards[cardID] = state
        }
    }

    // MARK: Generation 2

    /// Whether the cards' states are the Card rows: a test's bound `Records`, or the standard defaults of a
    /// generation-2 build whose store is activated. Until the first read of the rows is back, generation 1's
    /// rows answer, and that read is started.
    static func usesCardRecords(_ defaults: UserDefaults) -> Bool {
        if bound != nil { return true }
        guard defaults === UserDefaults.standard, ForeverLMRuntimeIdentity.syncGeneration == .two else { return false }
        return shared.isActive()
    }

    /// Reads the rows again: after a sync round applied Cards, a write outside `update` (a draft saved, a
    /// rewording taken out by "This asks something else"), or the activation.
    static func reload() {
        guard bound != nil || ForeverLMRuntimeIdentity.syncGeneration == .two else { return }
        // Nothing has read the rows yet: the first read will (`isActive`).
        guard records.hasLoaded() else { return }
        records.enqueue(nil)
    }

    /// Once every write and read queued before the call has landed: what a writer awaits before it reads
    /// the cards again from storage (To Check after a Keep), and what an MCP tool awaits before its first
    /// read of the states.
    static func settled(defaults: UserDefaults = .standard) async {
        guard usesCardRecords(defaults) else { return }
        await records.tail()?.value
    }

    /// Once the first read of the rows is back, so the states read next are the rows' (an MCP tool's first
    /// read in a launch). Generation 1 answers at once.
    static func loaded(defaults: UserDefaults = .standard) async {
        guard bound != nil || (defaults === UserDefaults.standard && ForeverLMRuntimeIdentity.syncGeneration == .two) else { return }
        let records = records
        _ = records.isActive()
        await records.tail()?.value
    }

    /// The states the surfaces read and the queue their writes take, one per store.
    final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [String: MemoryCardDeckState] = [:]
        private var loaded = false
        private var activated = false
        private var last: Task<Void, Never>?
        let storage: StorageService

        init(storage: StorageService) {
            self.storage = storage
        }

        func decks() -> [String: MemoryCardDeckState] {
            lock.lock()
            defer { lock.unlock() }
            return states
        }

        /// Whether the store is activated, as the last read of the rows found; the first call starts it.
        func isActive() -> Bool {
            lock.lock()
            let needsLoad = !loaded
            loaded = true
            let active = activated
            lock.unlock()
            if needsLoad { enqueue(nil) }
            return active
        }

        /// Whether a read of the rows was started (bound records always are read).
        func hasLoaded() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return loaded || MemoryCardStateStore.bound === self
        }

        func tail() -> Task<Void, Never>? {
            lock.lock()
            defer { lock.unlock() }
            return last
        }

        /// `change` applied to the deck in memory; the deck and the cards it changed, each as it was and is.
        func change(deckID: String, _ change: (inout MemoryCardDeckState) -> Void) -> (MemoryCardDeckState, [String: KnowledgeStore.CardStateChange]) {
            lock.lock()
            defer { lock.unlock() }
            let before = states[deckID] ?? MemoryCardDeckState()
            var deck = before
            change(&deck)
            states[deckID] = deck
            var changed: [String: KnowledgeStore.CardStateChange] = [:]
            for (key, state) in deck.cards where before.cards[key] != state {
                changed[key] = KnowledgeStore.CardStateChange(before: before.cards[key], after: state)
            }
            return (deck, changed)
        }

        /// Runs `write` on the store, then reads the rows back, after everything enqueued before it. When
        /// what the surfaces read changed (a sync round brought another device's Keep, Skip, rewording or
        /// draft), they are told as a remote change of cards is told under generation 1: the store changed,
        /// naming `CloudKitSyncEntity.memoryItem`.
        func enqueue(_ write: (@Sendable (KnowledgeStore) throws -> Void)?) {
            lock.lock()
            let previous = last
            let storage = storage
            let next = Task.detached(priority: .utility) { [weak self] in
                await previous?.value
                do {
                    let fresh = try await storage.cardRecordStatesWriting(write)
                    guard let self else { return }
                    if self.replace(fresh) {
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .cloudKitSyncRemoteStoreDidChange,
                                object: nil,
                                userInfo: [CloudKitSyncNotificationInfo.affectedEntitiesKey: [CloudKitSyncEntity.memoryItem.rawValue]]
                            )
                        }
                    }
                } catch {
                    MemoryCardStateStore.logger.error("Could not keep a card's state: \(error.localizedDescription, privacy: .public)")
                }
            }
            last = next
            lock.unlock()
        }

        /// Takes what the rows say; whether it differs from what the surfaces read, the times the rows
        /// derive aside.
        private func replace(_ fresh: (activated: Bool, decks: [String: MemoryCardDeckState])) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let changed = fresh.activated != activated || Self.timeless(fresh.decks) != Self.timeless(states)
            activated = fresh.activated
            states = fresh.decks
            return changed
        }

        private static func timeless(_ decks: [String: MemoryCardDeckState]) -> [String: MemoryCardDeckState] {
            decks.mapValues { deck in
                MemoryCardDeckState(cards: deck.cards.mapValues { state in
                    var state = state
                    state.updatedAt = .distantPast
                    return state
                })
            }
        }
    }

    /// A test's own records, bound for the task that runs it, over its own storage.
    @TaskLocal static var bound: Records?

    private static let shared = Records(storage: StorageService())
    private static var records: Records { bound ?? shared }
    fileprivate static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MemoryCardStateStore")
}

extension StorageService {
    /// Runs a card-state write, then reads every deck's states back from the Card rows, on the storage
    /// actor. A store that is not activated for generation 2 writes nothing here and reads nothing:
    /// generation 1's rows still hold the states, and the activation derives the Cards from them.
    func cardRecordStatesWriting(_ write: (@Sendable (KnowledgeStore) throws -> Void)?) throws -> (activated: Bool, decks: [String: MemoryCardDeckState]) {
        let store = try notebookFilesKnowledgeStore()
        guard try store.recordsMemoryForGeneration2() else { return (false, [:]) }
        if let write {
            try write(store)
            scheduleSoonCloudKitSyncForCardDrafts()
        }
        return (true, try store.cardRecordStates())
    }
}
