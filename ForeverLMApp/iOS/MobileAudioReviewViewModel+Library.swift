// Notebook changes, source capture and library mutations.

import Foundation
import OSLog

extension MobileAudioReviewViewModel {
    private static let libraryLogger = Logger(subsystem: "com.foreverlm.mobile", category: "LibraryMutations")

    func createNotebook(title: String, instructions: String?, summary: String? = nil) async -> String? {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.createNotebook(
                title: title,
                instructions: instructions,
                summary: summary
            )
        }
    }

    /// New notebook: made at once under the placeholder ("New notebook",
    /// numbered while taken) with the `notebook.naming.<id>` row, so ForeverLM
    /// on the Mac names it, title and card description, once it holds a
    /// source or a chat exchange (`NotebookNaming`).
    func createUnnamedNotebook() async -> String? {
        let placeholder = NotebookNaming.placeholder(existingTitles: notebooks.map(\.title))
        guard let id = await createNotebook(title: placeholder, instructions: nil) else { return nil }
        do {
            let key = NotebookNaming.preferenceKey(notebookID: id)
            let mark = NotebookNaming.Mark.unnamed(title: placeholder).encoded
            try await MobileNotebookRows.write(key, string: mark, writer: MobileRecordWriter.required())
            // Only a notebook with its naming row waits for its name; one without it would be drawn from the placeholder.
            await requestNotebookCover(id)
        } catch {
            // The notebook is made; it keeps the placeholder until renamed.
            errorMessage = "ForeverLM can't name this notebook: \(error.localizedDescription)"
        }
        return id
    }

    /// A notebook made one at a time is drawn a cover by a Mac (D53): a `Job(makeDerived)` a Mac claims
    /// and draws once the notebook has its name, unless Draw notebook covers is off.
    /// Imports and shares never come here.
    private func requestNotebookCover(_ id: String) async {
        guard let writer = await MobileRecordWriter.current() else { return }
        let preferences = MobileModelPreferenceStore.shared
        await MobileNotebookCoverRequest.requestIfWanted(
            notebookID: id,
            writer: writer,
            automatic: { try await preferences.bool(forKey: MobileNotebookCover.automaticSettingKey) }
        )
    }

    /// The phone's New notebook, on Home and the Notebooks screen: an unnamed
    /// notebook (`createUnnamedNotebook`), in `collectionID` when the screen
    /// shows that collection, as the Mac's home files it
    /// (`StudioViewModel.createNotebook`). The caller opens it.
    func createNotebook(inCollection collectionID: String? = nil) async -> String? {
        guard let id = await createUnnamedNotebook() else { return nil }
        if let collectionID {
            await setNotebook(id, inCollection: collectionID, isMember: true)
        }
        return id
    }

    /// `summary` nil keeps the card description; a string (even empty) replaces it.
    func updateNotebook(id: String, title: String, instructions: String, summary: String? = nil) async -> Bool {
        let before = notebooks.first { $0.id == id }
        let updated = await performLibraryMutation {
            try await MobileCloudMutationService.shared.updateNotebook(
                id: id,
                title: title,
                instructions: instructions,
                replaceInstructions: true,
                summary: summary,
                replaceSummary: summary != nil
            )
            return true
        } ?? false
        // A name or description the learner typed: ForeverLM never renames
        // the notebook after it (`NotebookNaming`).
        let renamed = before.map { $0.title != title.trimmingCharacters(in: .whitespacesAndNewlines) } ?? true
        let redescribed = summary.map { NotebookSummary.normalized($0) != before?.summary } ?? false
        if updated, renamed || redescribed {
            let key = NotebookNaming.preferenceKey(notebookID: id)
            if let writer = await MobileRecordWriter.current() {
                do {
                    try await MobileNotebookRows.write(key, string: nil, writer: writer)
                } catch {
                    Self.libraryLogger.error("Clearing a notebook's naming mark failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return updated
    }

    func archiveNotebook(id: String) async -> Bool {
        let archived = await performLibraryMutation {
            try await MobileCloudMutationService.shared.updateNotebook(id: id, status: "archived")
            return true
        } ?? false
        // A notebook put away is not the one the next launch reopens.
        if archived { MobileLastNotebookStore.standard.forget(id) }
        return archived
    }

    /// Links `contextNotebookID` to the notebook `notebookID` as a context
    /// notebook, after its other links. Putting it into the chats is the
    /// member's row (`MobileNotebookContextLinks.add`).
    func linkContextNotebook(_ contextNotebookID: String, toNotebookID notebookID: String) async -> Bool {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.linkContextNotebook(contextNotebookID, toNotebookID: notebookID)
            return true
        } ?? false
    }

    /// Unlinks `contextNotebookID` from the notebook `notebookID`; Take Out of
    /// Context drops it from the chats' row after (`MobileNotebookContextLinks`).
    func unlinkContextNotebook(_ contextNotebookID: String, fromNotebookID notebookID: String) async -> Bool {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.unlinkContextNotebook(contextNotebookID, fromNotebookID: notebookID)
            return true
        } ?? false
    }

    /// The replica's own delete (`MobileWrite.deleteNotebook`) unfiles its Goals,
    /// chats and Pages, or deletes the chats with their exchanges, and releases
    /// the Schedule's tags naming it, all from what the replica holds.
    func deleteNotebook(id: String, deleteLinkedChats: Bool = false) async -> Bool {
        let deleted = await performLibraryMutation {
            try await MobileCloudMutationService.shared.deleteNotebook(id: id, deleteLinkedChats: deleteLinkedChats)
            return true
        } ?? false
        if deleted {
            // Its NotebookState and Entries flip, never delete (§6.4): with the notebook gone they read
            // as nothing, ticks and collections included.
            MobileLastNotebookStore.standard.forget(id)
        }
        return deleted
    }

    func addSources(_ sources: [MobileCloudSource], toNotebookID notebookID: String) async -> Bool {
        let added: Bool = await performLibraryMutation {
            try await MobileCloudMutationService.shared.addSources(sources, toNotebookID: notebookID)
            return true
        } ?? false
        if added {
            await tickNotebookArrivals(sources.map(\.id), notebookID: notebookID)
        }
        return added
    }

    /// A source joining a notebook from the phone, by any route (the
    /// notebook's Sources, Add to Notebook, a capture or a Schedule placement
    /// filed into one), arrives ticked for the notebook's chats: its id leaves
    /// the notebook's `notebook.chatExcluded.<notebookID>` row in the same
    /// action, as the Mac's own adds do, so an untick from when it last left
    /// does not outlive its return. The add stands if this fails, and the
    /// error bar says so; the Mac ticks it when the add reaches it
    /// (`StudioViewModel.tickArrivingNotebookSources`).
    private func tickNotebookArrivals(_ sourceIDs: [String], notebookID: String) async {
        do {
            try await MobileNotebookChatSelection.tickArrivals(
                sourceIDs,
                notebookID: notebookID,
                read: MobileNotebookChatSelectionStore.cloudRead,
                write: MobileNotebookChatSelectionStore.cloudWrite
            )
        } catch {
            errorMessage = "Added to the notebook, but it could not be ticked for its chats: \(error.localizedDescription)"
        }
    }

    func removeSources(_ sourceIDs: Set<String>, fromNotebookID notebookID: String) async -> Bool {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.removeSources(sourceIDs, fromNotebookID: notebookID)
            return true
        } ?? false
    }

    func scheduleSource(
        _ source: MobileCloudSource,
        on date: Date,
        notebookID: String?,
        addToNotebook: Bool
    ) async -> Bool {
        let existing = scheduledPlacement(for: source.id)
        let order = nextScheduleOrder(on: date, excluding: source.id)
        let scheduled: Bool = await performLibraryMutation {
            if addToNotebook, let notebookID {
                try await MobileCloudMutationService.shared.addSources([source], toNotebookID: notebookID)
            }
            try await MobileCloudMutationService.shared.schedule(
                source: source,
                on: date,
                notebookID: notebookID,
                existing: existing,
                order: order
            )
            return true
        } ?? false
        if scheduled, addToNotebook, let notebookID {
            await tickNotebookArrivals([source.id], notebookID: notebookID)
        }
        return scheduled
    }

    func captureSource(url: URL, title: String?, sourceType: String) async -> String? {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.captureSource(
                url: url,
                title: title,
                sourceType: sourceType
            )
        }
    }

    /// `target` files it into a notebook in the same step (D47).
    func captureFile(url: URL, title: String?, capture: String = "pdf", target: MobileCaptureTarget? = nil) async -> String? {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.captureFile(url: url, title: title, capture: capture, target: target)
        }
    }

    /// Links pasted together into a notebook's Add sources, each captured as
    /// `captureSource` captures one, in one library change: the library
    /// loads once after them all, not once a link. Each link answers, in
    /// order, with its source's id or why it could not be added, and a link
    /// that fails does not hold up the ones after it; `onEach` hears each
    /// answer as it comes. Nil when another library change is still saving.
    func captureSources(
        urls: [URL],
        sourceType: String,
        filingInto notebookID: String? = nil,
        onEach: (Int, Result<String, Error>) -> Void
    ) async -> [Result<String, Error>]? {
        await performLibraryMutation {
            var outcomes: [Result<String, Error>] = []
            for (index, url) in urls.enumerated() {
                let outcome: Result<String, Error>
                do {
                    outcome = .success(try await MobileCloudMutationService.shared.captureSource(
                        url: url,
                        title: nil,
                        sourceType: sourceType,
                        target: notebookID.map { MobileCaptureTarget(notebookID: $0) }
                    ))
                } catch {
                    outcome = .failure(error)
                }
                outcomes.append(outcome)
                onEach(index, outcome)
            }
            return outcomes
        }
    }

    /// Captures what the share sheet queued, each item filed into the notebook the sheet chose in the
    /// capture itself (D47): the Job's target before the first complete Catalog pass, the Entry after it.
    /// An item whose notebook is gone by then stays in the library, where its capture put it. Nothing is
    /// drained while another library change holds the library.
    func importPendingSharedSources() async {
        guard !isMutatingLibrary else { return }
        isMutatingLibrary = true
        defer { isMutatingLibrary = false }
        do {
            let pending = try await MobileShareInbox.shared.pending()
            guard !pending.isEmpty else { return }
            var refusedItem: String?
            var queuedItem: String?
            for item in pending {
                let target = item.notebookID.map { MobileCaptureTarget(notebookID: $0, origin: "share") }
                do {
                    if let value = item.url, let url = URL(string: value) {
                        _ = try await MobileCloudMutationService.shared.captureSource(
                            url: url,
                            title: item.title,
                            sourceType: item.sourceType,
                            target: target
                        )
                    } else if let path = item.filePath {
                        _ = try await MobileCloudMutationService.shared.captureFile(
                            url: URL(fileURLWithPath: path),
                            title: item.title,
                            capture: "share",
                            target: target
                        )
                    } else {
                        throw MobileShareInboxError.sqlite("A queued item has no URL or file.")
                    }
                } catch let error where MobileShareDrain.answer(to: error) != nil {
                    // A linked page, an address that is not the web's, or a file that is not a PDF can never
                    // become a source, and a link only a Mac can mint an id for is already a Job for it:
                    // retrying either on every drain would hold up the items behind it. Drop it and say why.
                    try await MobileShareInbox.shared.remove(item)
                    switch MobileShareDrain.answer(to: error) {
                    case .refused(let message)?: refusedItem = message
                    case .queuedForMac(let message)?: queuedItem = message
                    case nil: break
                    }
                    continue
                }
                try await MobileShareInbox.shared.remove(item)
            }
            await load()
            if let refusedItem { errorMessage = refusedItem } else if let queuedItem { errorMessage = queuedItem }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSource(_ source: MobileCloudSource) async -> Bool {
        let notebookSnapshot = notebooks
        let scheduleSnapshot = scheduledSources
        let highlightSnapshot = await sourceCatalog.currentSourceHighlights(sourceID: source.id)
        let deleted = await performLibraryMutation {
            try await MobileCloudMutationService.shared.deleteSource(
                source,
                notebooks: notebookSnapshot,
                scheduledSources: scheduleSnapshot,
                highlights: highlightSnapshot
            )
            return true
        } ?? false
        if deleted {
            // A download outlives the source it came from unless it is released
            // here: nothing else ever revisits it, so it would sit in Offline
            // storage under a title the catalog can no longer resolve.
            await MobileOfflineLibrary.shared.remove(sourceID: source.id)
        }
        return deleted
    }

    func archiveSource(_ source: MobileCloudSource) async -> Bool {
        let notebookSnapshot = notebooks
        let scheduleSnapshot = scheduledSources
        let saved = await performLibraryMutation {
            try await MobileCloudMutationService.shared.archiveSource(
                source,
                notebooks: notebookSnapshot,
                scheduledSources: scheduleSnapshot
            )
            return true
        } ?? false
        if saved {
            // DismissedSource is intentionally not part of the phone's catalog;
            // remove the row now while the Mac archives and republishes Source.
            allSources.removeAll { $0.id == source.id }
            // Archiving discards the source's content on the Mac, so a saved copy
            // here can never be refreshed or reopened from the library again.
            await MobileOfflineLibrary.shared.remove(sourceID: source.id)
        }
        return saved
    }

    func nextScheduleOrder(on date: Date, excluding sourceID: String?) -> Int {
        let calendar = Calendar.current
        return scheduledSources.reduce(into: 0) { count, placement in
            guard placement.sourceID != sourceID,
                  calendar.isDate(placement.plannedAt, inSameDayAs: date) else { return }
            count += 1
        }
    }

    private func performLibraryMutation<T>(_ operation: () async throws -> T) async -> T? {
        guard !isMutatingLibrary else {
            errorMessage = "Another library change is still saving."
            return nil
        }
        isMutatingLibrary = true
        defer { isMutatingLibrary = false }
        do {
            let result = try await operation()
            await load()
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Publishes managed sign-in state read off the main actor. `ManagedAI.isSignedIn`
    /// resolves to synchronous `SecItemCopyMatching` calls, so it can never be read
    /// from `init`, a view body, or any other main-actor path. Same shape as
    /// `MobileChatViewModel.refreshSignInState()`.
    func refreshManagedSignInState() async {
        let signedIn = await Task.detached(priority: .userInitiated) { ManagedAI.isSignedIn }.value
        guard signedIn != hasOpenAIKey || signedIn != hasAnthropicKey else { return }
        hasOpenAIKey = signedIn
        hasAnthropicKey = signedIn
    }
}
