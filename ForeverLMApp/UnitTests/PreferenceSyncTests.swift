import Foundation
import Testing
@testable import ForeverLM

@Suite("Preference sync")
struct PreferenceSyncTests {
    @Test("Text-to-speech cost confirmation suppression is model-scoped")
    func textToSpeechCostConfirmationSuppressionIsModelScoped() {
        let gemini = "google/gemini-3.1-flash-tts-preview"
        let kokoro = "hexgrad/kokoro-82m"
        let suppressed = TextToSpeechCostConfirmationPreferences.updatedSuppressedModelIDs(
            [kokoro],
            confirms: false,
            modelID: gemini
        )

        #expect(suppressed == [gemini, kokoro].sorted())
        #expect(
            TextToSpeechCostConfirmationPreferences.updatedSuppressedModelIDs(
                Set(suppressed),
                confirms: true,
                modelID: gemini
            ) == [kokoro]
        )
        #expect(
            SyncedPreferenceKeys.isSynced(
                TextToSpeechCostConfirmationPreferences.suppressedModelIDsKey
            )
        )
    }

    // MARK: - Listening positions

    @Test("A listening position follows the account as one record per source")
    func listeningPositionFollowsTheAccount() throws {
        let key = ListeningPositionSync.preferenceKey(sourceID: "src_abc")
        #expect(key == "listen.position.src_abc")
        // Under generation 2 the position is the source's ReadingState, not a preference row.
        #expect(!SyncedPreferenceKeys.isSynced(key))
        #expect(ListeningPositionSync.sourceID(fromPreferenceKey: key) == "src_abc")
        #expect(ListeningPositionSync.sourceID(fromPreferenceKey: "listen.position.") == nil)
        #expect(ListeningPositionSync.sourceID(fromPreferenceKey: "macos.tts.speed") == nil)

        let position = ArticleSpeechPlaybackPosition(
            globalTime: 1234.5,
            appleCharacterOffset: nil,
            contentSignature: "sig",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoded = try #require(ListeningPositionSync.encode(position))
        #expect(ListeningPositionSync.decode(encoded) == position)
        #expect(ListeningPositionSync.decode("not a position") == nil)
    }

    @Test("The newer of the file and the account copy wins")
    func newestListeningPositionWins() {
        let older = ArticleSpeechPlaybackPosition(
            globalTime: 100,
            appleCharacterOffset: nil,
            contentSignature: "sig",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = ArticleSpeechPlaybackPosition(
            globalTime: 40,
            appleCharacterOffset: nil,
            contentSignature: "sig",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        // The stamp decides, never the larger time: a listener who skipped
        // back on the other device meant it.
        #expect(ListeningPositionSync.newest(older, newer) == newer)
        #expect(ListeningPositionSync.newest(newer, older) == newer)
        #expect(ListeningPositionSync.newest(nil, older) == older)
        #expect(ListeningPositionSync.newest(older, nil) == older)
        #expect(ListeningPositionSync.newest(nil, nil) == nil)
    }

    // MARK: - Value encoding

    /// The reason the `value` column holds a property list and not JSON.
    ///
    /// `UserDefaults` distinguishes a stored `Bool` from a stored `Int`, and several
    /// call sites read via `object(forKey:) as? Bool`, which returns nil for a plain
    /// `NSNumber`. JSON collapses the two, so a round-tripped `true` would come back
    /// as `1`, the cast would fail, and the setting would silently revert to its
    /// `?? true` default.
    @Test("Bool survives a round trip as a Bool, not a number")
    func boolStaysBool() throws {
        let xml = try #require(PreferenceStore.encodePlist(true))
        let decoded = try #require(PreferenceStore.decodePlist(xml))

        #expect(decoded as? Bool == true)
        // The distinguishing check: a JSON round trip would leave an NSNumber here
        // that reads back as Int 1 and fails `as? Bool`.
        let asObject = decoded as AnyObject
        #expect(CFGetTypeID(asObject) == CFBooleanGetTypeID())
    }

    @Test("Int does not decode as Bool")
    func intStaysInt() throws {
        let xml = try #require(PreferenceStore.encodePlist(1))
        let decoded = try #require(PreferenceStore.decodePlist(xml))

        #expect(decoded as? Int == 1)
        let asObject = decoded as AnyObject
        #expect(CFGetTypeID(asObject) != CFBooleanGetTypeID())
    }

    @Test("Every stored preference type round-trips")
    func allTypesRoundTrip() throws {
        let doubleXML = try #require(PreferenceStore.encodePlist(2.5))
        #expect(PreferenceStore.decodePlist(doubleXML) as? Double == 2.5)

        let stringXML = try #require(PreferenceStore.encodePlist("fable"))
        #expect(PreferenceStore.decodePlist(stringXML) as? String == "fable")

        let arrayXML = try #require(PreferenceStore.encodePlist(["a", "b"]))
        #expect(PreferenceStore.decodePlist(arrayXML) as? [String] == ["a", "b"])

        let intArrayXML = try #require(PreferenceStore.encodePlist([1, 2, 7]))
        #expect(PreferenceStore.decodePlist(intArrayXML) as? [Int] == [1, 2, 7])

        let data = Data([0x01, 0x02, 0xFF])
        let dataXML = try #require(PreferenceStore.encodePlist(data))
        #expect(PreferenceStore.decodePlist(dataXML) as? Data == data)
    }

    @Test("Unreadable or empty payloads decode to nil rather than throwing")
    func malformedDecodesToNil() {
        #expect(PreferenceStore.decodePlist("") == nil)
        #expect(PreferenceStore.decodePlist("not a plist") == nil)
    }

    // MARK: - Allowlist boundary

    @Test("Synced keys are recognized, including runtime-built prefixes")
    func syncedKeysMatch() throws {
        #expect(SyncedPreferenceKeys.isSynced("account.displayName"))
        #expect(SyncedPreferenceKeys.isSynced(MacAccountUser.showsCompCrownPreferenceKey))
        #expect(SyncedPreferenceKeys.isSynced("anthropic_model"))
        #expect(SyncedPreferenceKeys.isSynced("studio.hiddenTabs"))
        #expect(SyncedPreferenceKeys.isSynced("studio.excludedKnowledgeSourceTabs"))
        // Which integration tabs Studio already unpinned, and which of those
        // unpins are still its own to undo. Device-local, both were lost with the
        // preferences container on every rebuild, which re-applied the default
        // and then pinned Read AI and Zoom back over a deliberate unpin.
        #expect(SyncedPreferenceKeys.isSynced("studio.integrationTabUnpinDefaultsApplied"))
        #expect(SyncedPreferenceKeys.isSynced("studio.integrationTabsUnpinnedByDefault"))
        // The rail's order and pins travel with the account: as preference rows under generation 1, and
        // as the member's NotebookState (`sidebarKey`, `pinned`) under generation 2, which no row names.
        #expect(!SyncedPreferenceKeys.isSynced("studio.projectOrder"))
        #expect(!SyncedPreferenceKeys.isSynced(NotebookPins.preferenceKey))
        // A hand-arranged chat rail is work, not a window position: it has to
        // reach the other Mac like the Notebook and Course orders beside it.
        #expect(SyncedPreferenceKeys.isSynced(StudioViewModel.chatOrderPreferenceKey))
        #expect(SyncedPreferenceKeys.isSynced("studio.workspaceView.left-monitor"))
        #expect(SyncedPreferenceKeys.isSynced("studio.showMCPStatusLight"))
        // Signing up for beta releases on one Mac signs up the account's other Macs.
        #expect(SyncedPreferenceKeys.isSynced(BetaReleases.preferenceKey))
        #expect(SyncedPreferenceKeys.isSynced("aiTask.chat.model"))
        #expect(SyncedPreferenceKeys.isSynced("aiBackground.model.OpenRouter"))
        #expect(SyncedPreferenceKeys.isSynced("aiRoute.background.multimodal"))
        #expect(SyncedPreferenceKeys.isSynced("aiRoute.textRoutingMode"))
        #expect(SyncedPreferenceKeys.isSynced("podcasts.youtubeFallbackShows"))
        #expect(SyncedPreferenceKeys.isSynced("meetingFolder.image.group-123"))
        // A lecture quiz's score is the learner's, on every Mac they use.
        #expect(SyncedPreferenceKeys.isSynced(LectureQuizScore.preferenceKey(sourceID: "lecture-7")))
        // The boxes a learner unticked in a notebook follow them to every Mac, and so do the context
        // notebooks they put into a notebook's chats: as preference rows under generation 1, as fields of
        // the member's NotebookState under generation 2.
        for key in [NotebookChatSelection.preferenceKey(notebookID: "p1"), NotebookChatContext.preferenceKey(notebookID: "p1")] {
            #expect(!SyncedPreferenceKeys.isSynced(key))
        }
        // The memory review's daily time budget sizes the review wherever it is
        // planned, so the phone and both Macs have to agree on it.
        #expect(SyncedPreferenceKeys.isSynced(MemoryReviewBudget.preferenceKey))
        #expect(SyncedPreferenceKeys.isSynced(
            ArticleSpeechVoiceRating.preferenceKey(
                modelID: "deepgram/flux-tts:free",
                voiceID: "flux-alexis-en"
            )
        ))
        // Every automatable kind's switch and rule — the explainers' included —
        // or a Mac and an iPhone disagree about what the account is paying to
        // narrate.
        for type in SourceAudioAutomation.automatable {
            #expect(SyncedPreferenceKeys.isSynced(type.preferenceKey))
            let constraintKey = try #require(SourceAudioAutomation.constraintPreferenceKey(for: type.sourceType))
            #expect(SyncedPreferenceKeys.isSynced(constraintKey))
        }
    }

    @Test("Durable model configuration excludes session-scoped chat picks")
    func persistedModelConfigurationBoundary() {
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration("ai_provider"))
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration("chatModels.enabledIDs"))
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration("aiBackground.model.OpenRouter"))
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration("aiRoute.background.multimodal"))
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration("aiRoute.textRoutingMode"))
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration("aiTask.paperMetadata.model"))
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration("aiTask.paperMetadata.effort"))
        #expect(!SyncedPreferenceKeys.isPersistedModelConfiguration("aiTask.chat.model"))
        // The effort chosen from the chat bar is the one chat pick that
        // outlives its chat, so it survives a rebuild like the Default Model.
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration(AIModelPreferenceKey.defaultChatEffort))
        #expect(!SyncedPreferenceKeys.isPersistedModelConfiguration("studio.hiddenTabs"))
        #expect(!SyncedPreferenceKeys.isPersistedModelConfiguration("studio.excludedKnowledgeSourceTabs"))
    }

    @Test("Device-local keys are excluded")
    func excludedKeysRejected() {
        #expect(SyncedPreferenceKeys.isSynced("studio.navigationRailWidth") == false)
        #expect(SyncedPreferenceKeys.isSynced("studio.sourcesPanelWidth") == false)
        #expect(SyncedPreferenceKeys.isSynced("trial.startDate") == false)
        #expect(SyncedPreferenceKeys.isSynced("securityBookmark_safariBookmarks") == false)
        #expect(SyncedPreferenceKeys.isSynced("NSWindow Frame StudioWindow") == false)
        #expect(SyncedPreferenceKeys.isSynced("ios.reader.progress.abc123") == false)
        #expect(SyncedPreferenceKeys.isSynced("aiPricing.openRouterRemotePrices") == false)
    }

    @Test("An exclusion beats a synced prefix match")
    func exclusionBeatsPrefix() {
        for key in SyncedPreferenceKeys.excluded.keys {
            #expect(SyncedPreferenceKeys.isSynced(key) == false)
        }
    }

    @Test("The synced and excluded lists do not overlap")
    func listsAreDisjoint() {
        let overlap = SyncedPreferenceKeys.synced.intersection(SyncedPreferenceKeys.excluded.keys)
        #expect(overlap.isEmpty)
    }

    @Test("Unknown keys do not sync by default")
    func unknownKeysRejected() {
        #expect(SyncedPreferenceKeys.isSynced("some.key.nobody.declared") == false)
    }

    // MARK: - Store round trip

    @Test("A written preference round-trips and is queued for sync")
    func writeRoundTrips() throws {
        let store = try KnowledgeStore(inMemory: true)
        let xml = try #require(PreferenceStore.encodePlist(true))

        try store.writePreference(key: "studio.showSearchPanel", valuePlistXML: xml)

        let payload = try #require(try store.preferenceRow("studio.showSearchPanel"))
        #expect(payload.key == "studio.showSearchPanel")
        #expect(PreferenceStore.decodePlist(payload.valuePlistXML) as? Bool == true)
    }

    @Test("The reader layout and the rail's hidden rows follow the account")
    func displayPreferencesFollowTheAccount() {
        // The reader keys are fractions and modes, not the absolute pixel
        // widths beside them in the registry, so they mean the same thing on any
        // display and travel with the rest of the reading preferences.
        for key in [
            "reader.youtubeTranscriptBesideVideo",
            "reader.youtubeVideoPaneFraction",
            "reader.youtubeVideoPaneWidthFraction",
            "reader.meetingVideoPaneFraction",
            "reader.meetingTranscriptBesideVideo",
            "reader.meetingVideoPaneWidthFraction",
        ] {
            #expect(SyncedPreferenceKeys.isSynced(key), "\(key) should follow the account")
        }
        // Hiding a rail row is the same act as hiding a tab or unpinning a
        // Notebook, and a fold is the same act as collapsing a panel. All of them
        // behave the same way.
        for key in [
            StudioRailHiddenItems.storageKey,
            "studio.navigation.chatsExpanded.v1",
            "studio.navigation.hiddenChatsExpanded.v1",
            "studio.navigation.expandedProjectIDs.v1",
            "studio.hiddenTabs",
            NotebookPins.preferenceKey,
            "studio.expandedPanel",
        ] {
            // Under generation 2 the fold and the pins are fields of the member's NotebookState; the
            // rest are still Settings.
            let isRecordField = ["studio.navigation.expandedProjectIDs.v1", NotebookPins.preferenceKey].contains(key)
            #expect(SyncedPreferenceKeys.isSynced(key) == !isRecordField, "\(key) under generation 2")
        }
        // The pixel widths stay local, which is what makes the fractions above a
        // deliberate distinction rather than an inconsistency.
        #expect(!SyncedPreferenceKeys.isSynced("studio.sourcesPanelWidth"))
        #expect(!SyncedPreferenceKeys.isSynced("studio.navigationRailWidth"))
        // The exceptions list the explicit pins replaced is retired, and says so.
        #expect(!SyncedPreferenceKeys.isSynced(StudioViewModel.unpinnedNotebooksPreferenceKey))
        #expect(SyncedPreferenceKeys.excluded[StudioViewModel.unpinnedNotebooksPreferenceKey] != nil)
        // How the Notebooks home draws and orders the notebooks is this Mac's
        // view of the catalog, declared so, with a reason.
        for key in [
            NotebooksHomeLayout.preferenceKey,
            NotebooksHomeOrder.sortPreferenceKey,
            NotebooksHomeOrder.reversedPreferenceKey,
        ] {
            #expect(!SyncedPreferenceKeys.isSynced(key), "\(key) stays on this Mac")
            #expect(SyncedPreferenceKeys.excluded[key] != nil, "\(key) is declared device-local")
        }
    }

    @Test("Rewriting a key updates in place rather than duplicating")
    func rewriteUpdatesInPlace() throws {
        let store = try KnowledgeStore(inMemory: true)

        try store.writePreference(key: "uiZoomStep", valuePlistXML: try #require(PreferenceStore.encodePlist(4)))
        try store.writePreference(key: "uiZoomStep", valuePlistXML: try #require(PreferenceStore.encodePlist(6)))

        #expect(try store.loadAllPreferences().keys.sorted() == ["uiZoomStep"])
        let payload = try #require(try store.preferenceRow("uiZoomStep"))
        #expect(PreferenceStore.decodePlist(payload.valuePlistXML) as? Int == 6)
    }

    /// A model picked just before a rebuild used to come back as the previous
    /// one: its knowledge.db write was lost, and launch hydration restored the
    /// old row. The journal is what tells hydration to keep the newer value.
    @Test("An unfinished write stays journaled across launches until its newest write lands")
    func unfinishedWritesStayJournaled() throws {
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let background = AIModelPreferenceKey.backgroundRoute

        var journal = PreferenceWriteJournal(defaults: defaults)
        journal.begin(background, generation: 1)
        journal.begin(background, generation: 2)
        journal.confirm(background, generation: 1)
        #expect(journal.keys == [background])

        // The app quits before generation 2 lands; the next launch still knows.
        var relaunched = PreferenceWriteJournal(defaults: defaults)
        #expect(relaunched.keys == [background])
        relaunched.begin(background, generation: 1)
        relaunched.confirm(background, generation: 1)
        #expect(relaunched.keys.isEmpty)
        #expect(defaults.object(forKey: PreferenceWriteJournal.defaultsKey) == nil)
        #expect(!SyncedPreferenceKeys.isSynced(PreferenceWriteJournal.defaultsKey))
    }

    /// Preference rows sync whole and the newer write wins. A card-state row
    /// holds one entry per card, so two Macs that changed different cards
    /// before syncing would each lose the other's change; it is merged on
    /// receipt instead, and the merge goes back out only when it holds more
    /// than what arrived, which settles after one round.
    @Test("A card-state row merges on receipt and goes back out only when the merge holds more")
    func cardStateRowsMergeOnReceipt() throws {
        let key = MemoryCardDeckState.preferenceKey(deckID: "carddeck-src-1")
        func card(_ status: MemoryCardStatus, at seconds: TimeInterval, item: String? = nil) -> MemoryCardState {
            MemoryCardState(status: status, memoryItemID: item, updatedAt: Date(timeIntervalSince1970: seconds))
        }
        // This Mac kept card A; the other Mac skipped card B before syncing.
        let here = MemoryCardDeckState(cards: ["A": card(.kept, at: 100, item: "memory-card-v1-a")])
        let there = MemoryCardDeckState(cards: ["B": card(.skipped, at: 200)])

        let onThisMac = PreferenceStore.resolvedInbound(key: key, incoming: there.preferenceValue, local: here.preferenceValue)
        #expect(onThisMac.sendBack)
        let merged = try #require(MemoryCardDeckState(preferenceValue: onThisMac.value))
        #expect(merged == here.merged(with: there))
        #expect(Set(merged.cards.keys) == ["A", "B"])

        // The other Mac receives the merge: it already holds its own change, so
        // it takes the row as it comes and sends nothing back.
        let onTheOtherMac = PreferenceStore.resolvedInbound(key: key, incoming: onThisMac.value, local: there.preferenceValue)
        #expect(!onTheOtherMac.sendBack)
        #expect(MemoryCardDeckState(preferenceValue: onTheOtherMac.value) == merged)

        // A newer copy of the same card simply wins; nothing goes back.
        let newer = MemoryCardDeckState(cards: ["A": card(.kept, at: 300, item: "memory-card-v1-a")])
        let update = PreferenceStore.resolvedInbound(key: key, incoming: newer.preferenceValue, local: here.preferenceValue)
        #expect(!update.sendBack)
        #expect(MemoryCardDeckState(preferenceValue: update.value) == newer)

        // Nothing stored here yet, a value that is not a row, and every other
        // key: the incoming value stands.
        #expect(!PreferenceStore.resolvedInbound(key: key, incoming: there.preferenceValue, local: nil).sendBack)
        #expect(!PreferenceStore.resolvedInbound(key: key, incoming: "not a row", local: here.preferenceValue).sendBack)
        let other = PreferenceStore.resolvedInbound(key: "podcastSortMode", incoming: "title", local: "date")
        #expect(other.value as? String == "title")
        #expect(!other.sendBack)
    }

    @Test("Deleting a preference removes the row")
    func deleteTombstones() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.writePreference(key: "showReadStatus", valuePlistXML: try #require(PreferenceStore.encodePlist(true)))

        try store.deletePreference(key: "showReadStatus")

        #expect(try store.preferenceRow("showReadStatus") == nil)
        #expect(try store.loadAllPreferences().isEmpty)
    }

    // MARK: - Unreadable rows

    /// The exact shape found in `knowledge.db` on 2026-08-31: the two-character
    /// text `\t` where `encodePlist` writes a tab, and no trailing newline — the
    /// row a `sqlite3` insert typed with escape sequences leaves behind.
    private func escapedRow(_ value: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \\t<key>v</key>
        \\t<string>\(value)</string>
        </dict>
        </plist>
        """
    }

    @Test("Escape sequences written as text between tags are recovered, and only there")
    func escapedWhitespaceRecovers() throws {
        let url = "https://images.example.com/favicon.ico?format=300w"
        let row = escapedRow(url)
        // The fixture has to be as broken as the live row, or this proves nothing.
        #expect(PreferenceStore.decodePlist(row) == nil)
        #expect(PreferenceStore.recoverPlist(row) as? String == url)

        // A backslash inside the value is content, not damage, and stays.
        let path = #"C:\temp\notes"#
        #expect(PreferenceStore.recoverPlist(escapedRow(path)) as? String == path)

        // Recovery is plain decoding for a row that needs none, and nil for one
        // it cannot read.
        let sound = try #require(PreferenceStore.encodePlist(url))
        #expect(PreferenceStore.recoverPlist(sound) as? String == url)
        #expect(PreferenceStore.recoverPlist("not a plist") == nil)
        #expect(PreferenceStore.recoverPlist("") == nil)
    }

    @Test("Unreadable rows are re-encoded once, and the rest are named")
    func unreadableRowsRepair() throws {
        let store = try KnowledgeStore(inMemory: true)
        let url = "https://images.example.com/favicon.ico?format=300w"
        let brokenKey = MeetingMetadata.folderImagePreferenceKey(for: "acme")
        let soundKey = "studio.showSearchPanel"
        let garbageKey = "podcastSortMode"
        let emptyKey = "videoSortMode"
        let localKey = "some.key.nobody.declared"
        let soundXML = try #require(PreferenceStore.encodePlist(true))
        // Stored as the live rows were.
        for (key, xml) in [
            brokenKey: escapedRow(url),
            soundKey: soundXML,
            garbageKey: "not a plist",
            emptyKey: "",
            localKey: escapedRow(url),
        ] {
            try store.writePreference(key: key, valuePlistXML: xml, updatedAt: Date(timeIntervalSinceReferenceDate: 1000))
        }

        let report = try store.repairUnreadablePreferences()
        #expect(report.repaired == [brokenKey])
        #expect(report.unreadable == [garbageKey])

        // Canonical now: exactly what encodePlist writes, tabs and newline included.
        let repaired = try #require(try store.preferenceRow(brokenKey))
        #expect(repaired.valuePlistXML == PreferenceStore.encodePlist(url))
        #expect(PreferenceStore.decodePlist(repaired.valuePlistXML) as? String == url)
        // Untouched: the sound row, the empty "no value" row, the garbage it
        // cannot read, and the row for a key nothing hydrates.
        let sound = try store.preferenceRow(soundKey)
        let garbage = try store.preferenceRow(garbageKey)
        let empty = try store.preferenceRow(emptyKey)
        let local = try store.preferenceRow(localKey)
        #expect(sound?.valuePlistXML == soundXML)
        #expect(garbage?.valuePlistXML == "not a plist")
        #expect(empty?.valuePlistXML == "")
        #expect(local?.valuePlistXML == escapedRow(url))

        // Self-retiring: a repaired row decodes, so the next pass rewrites nothing.
        let again = try store.repairUnreadablePreferences()
        #expect(again == KnowledgeStore.PreferenceRepairReport(repaired: [], unreadable: [garbageKey]))
    }

    // MARK: - Escape hatches

    /// The hatch keys are read from both preference domains, but must still fall
    /// through to their default when neither domain has an opinion.
    @Test("An unset escape hatch falls through to its default")
    func escapeHatchDefaults() {
        #expect(DefaultsEscapeHatch.bool(forKey: "foreverlm.test.never.written", default: true))
        #expect(DefaultsEscapeHatch.bool(forKey: "foreverlm.test.never.written", default: false) == false)
        #expect(DefaultsEscapeHatch.string(forKey: "foreverlm.test.never.written") == nil)
    }

    /// Escape hatches are developer affordances with no UI and no sync; they must
    /// stay out of the synced set or the CloudKit copy would fight the local
    /// `defaults write`.
    @Test("Escape hatches are excluded from sync")
    func escapeHatchesNotSynced() {
        for key in ["preferredBrowser", "readingListSafari", "readingListChrome", "readingListBrave"] {
            #expect(SyncedPreferenceKeys.isSynced(key) == false)
        }
    }

    @Test("Each preference gets its own CloudKit record")
    func recordsArePerKey() {
        let a = CloudKitRecordMapper.recordName(for: .preference, logicalKey: "uiZoomStep")
        let b = CloudKitRecordMapper.recordName(for: .preference, logicalKey: "podcastSortMode")

        // Distinct records are what let two Macs change two different settings
        // without one silently losing: last-write-wins is row-level, with no field
        // merge, so a shared record would drop one of the two edits.
        #expect(a != b)
        #expect(CloudKitRecordMapper.recordName(for: .preference, logicalKey: "uiZoomStep") == a)
    }
}

private extension KnowledgeStore {
    /// One `user_preferences` row as it is stored, read through the live reader.
    func preferenceRow(_ key: String) throws -> (key: String, valuePlistXML: String)? {
        try loadAllPreferences()[key].map { (key: key, valuePlistXML: $0) }
    }
}
