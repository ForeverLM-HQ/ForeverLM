#if os(macOS)
import Foundation

// MARK: - Text-to-speech audio generation over MCP
//
// The sidebar's Generate Audio, for an assistant: "generate audio for every
// book in my library" is a selection (explicit sources, whole books, or every
// source of a type), a quote, an explicit yes, and then a queue the learner
// can ask about later. The generation itself is the same headless run the app
// performs — the same voice the learner picked in Settings, the same metered
// route, the same synced audio files — so nothing here bills or stores
// anything the app's own action would not.

extension MCPDataStore {
    /// Source types text-to-speech can narrate. Podcasts, videos, and meetings
    /// already have their own audio and are refused by name so an assistant
    /// learns why rather than seeing them silently skipped.
    static let audioNativeSourceTypes: Set<StudioSourceType> = [.podcast, .video, .meeting]

    /// The selection a generate call resolved, before anything is queued.
    struct SourceAudioGenerationPlan {
        struct Skipped {
            let sourceID: String
            let title: String
            let reason: String
        }

        /// Sources that would generate, in the order they will be queued.
        var pending: [StudioArticle] = []
        var alreadyReady: [StudioArticle] = []
        var alreadyActive: [StudioArticle] = []
        var skipped: [Skipped] = []
        /// Stored text length per pending source; absent when the text has not
        /// been extracted yet, in which case the quote says so instead of
        /// inventing a number.
        var characterCounts: [String: Int] = [:]
        /// Book display titles by group id, so a chapter is reported under its
        /// book's name rather than the group's UUID.
        var bookTitles: [String: String] = [:]

        var estimatedCharacters: Int {
            pending.reduce(0) { $0 + (characterCounts[$1.id] ?? 0) }
        }

        var unsizedCount: Int {
            pending.filter { characterCounts[$0.id] == nil }.count
        }
    }

    private struct BookChapterRow {
        let sourceID: String
        let bookID: String
        let bookTitle: String
        let sortIndex: Int?
    }

    private static let listingCap = 100

    private func bookChapterRows() throws -> [BookChapterRow] {
        try withDB { db in
            try query(db, """
                SELECT id, parent_group, COALESCE(parent_group_title, parent_group) AS group_name,
                       group_sort_index
                FROM source_projection
                WHERE source_type = 'book' AND parent_group IS NOT NULL AND parent_group != ''
            """).compactMap { row in
                guard let id = row["id"] as? String, let bookID = row["parent_group"] as? String else {
                    return nil
                }
                return BookChapterRow(
                    sourceID: id,
                    bookID: bookID,
                    bookTitle: row["group_name"] as? String ?? bookID,
                    sortIndex: row["group_sort_index"] as? Int
                )
            }
        }
    }

    private static func compareChapters(_ lhs: BookChapterRow, _ rhs: BookChapterRow, titles: [String: String]) -> Bool {
        if let l = lhs.sortIndex, let r = rhs.sortIndex, l != r { return l < r }
        if lhs.sortIndex != nil, rhs.sortIndex == nil { return true }
        if lhs.sortIndex == nil, rhs.sortIndex != nil { return false }
        let lt = titles[lhs.sourceID] ?? ""
        let rt = titles[rhs.sourceID] ?? ""
        return lt.localizedStandardCompare(rt) == .orderedAscending
    }

    /// Parses the type filter. Unknown names and audio-native types are
    /// refused with the list of what is accepted.
    static func audioGenerationSourceTypes(from raw: [String]) throws -> [StudioSourceType] {
        var types: [StudioSourceType] = []
        for value in raw {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let type = Self.audioGenerationSourceType(named: trimmed) else {
                throw MCPError.invalidInput(
                    "Unknown source_type \"\(value)\". Use one of: \(acceptedAudioSourceTypeNames)."
                )
            }
            if audioNativeSourceTypes.contains(type) {
                throw MCPError.invalidInput(
                    "\(type.rawValue) sources already have their own audio, so ForeverLM does not generate text-to-speech speech for them. Use one of: \(acceptedAudioSourceTypeNames)."
                )
            }
            if !types.contains(type) { types.append(type) }
        }
        return types
    }

    /// The schema spells the X type `x_post` and the model spells it `xPost`;
    /// both name the same family, in any casing. Every other raw value is
    /// already lowercase, so folding the name is enough for the rest.
    static func audioGenerationSourceType(named name: String) -> StudioSourceType? {
        let folded = name.lowercased()
        if folded == "x_post" || folded == "xpost" { return .xPost }
        return StudioSourceType(rawValue: folded)
    }

    static var acceptedAudioSourceTypeNames: String {
        ["book", "article", "paper", "course", "manual", "x_post"]
            .joined(separator: ", ")
    }

    /// Resolves the selection to concrete sources and sorts them into what will
    /// run, what already has audio, and what cannot be narrated. Pure library
    /// work: nothing is queued and no provider is contacted.
    func planSourceAudioGeneration(
        sourceIDs: [String],
        bookIDs: [String],
        sourceTypes: [StudioSourceType],
        activeSourceIDs: Set<String>,
        hasCachedAudio: (String) -> Bool = ArticleSpeechAudioCache.hasCachedAudio(sourceID:)
    ) throws -> SourceAudioGenerationPlan {
        let store = try knowledgeStore()
        let library = try store.loadSourcesWithoutContent()
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let titles = Dictionary(library.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let chapters = try bookChapterRows()
        let chaptersByBook = Dictionary(grouping: chapters, by: \.bookID)

        var ordered: [StudioArticle] = []
        var seen = Set<String>()
        func take(_ article: StudioArticle) {
            guard !seen.contains(article.id) else { return }
            seen.insert(article.id)
            ordered.append(article)
        }

        // Explicit sources first, in the caller's order.
        var missingSourceIDs: [String] = []
        for rawID in sourceIDs {
            let token = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if let resolved = try store.resolveSourceID(forLinkToken: token), let article = byID[resolved] {
                take(article)
            } else {
                missingSourceIDs.append(token)
            }
        }
        if !missingSourceIDs.isEmpty {
            throw MCPError.notFound(
                "Source not found: \(missingSourceIDs.joined(separator: ", ")). Use list_sources or search_sources_semantic to find source ids."
            )
        }

        // Then whole books, chapters in reading order.
        var missingBookIDs: [String] = []
        for rawBookID in bookIDs {
            let bookID = rawBookID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bookID.isEmpty else { continue }
            let rows: [BookChapterRow]
            if let exact = chaptersByBook[bookID] {
                rows = exact
            } else {
                // A unique title match is accepted so "the Feynman Lectures"
                // works without a second list_sources round trip.
                let titleMatches = chaptersByBook.filter { $0.value.first?.bookTitle.caseInsensitiveCompare(bookID) == .orderedSame }
                guard titleMatches.count == 1, let match = titleMatches.first else {
                    missingBookIDs.append(bookID)
                    continue
                }
                rows = match.value
            }
            for row in rows.sorted(by: { Self.compareChapters($0, $1, titles: titles) }) {
                if let article = byID[row.sourceID] { take(article) }
            }
        }
        if !missingBookIDs.isEmpty {
            throw MCPError.notFound(
                "Book not found: \(missingBookIDs.joined(separator: ", ")). list_sources shows each book's book_id."
            )
        }

        // Then every source of the requested types. Books first, whole and in
        // order; everything else newest first, the way the library lists it.
        if sourceTypes.contains(.book) {
            let bookIDsByName = chaptersByBook.keys.sorted { lhs, rhs in
                let l = chaptersByBook[lhs]?.first?.bookTitle ?? lhs
                let r = chaptersByBook[rhs]?.first?.bookTitle ?? rhs
                return l.localizedStandardCompare(r) == .orderedAscending
            }
            for bookID in bookIDsByName {
                for row in (chaptersByBook[bookID] ?? []).sorted(by: { Self.compareChapters($0, $1, titles: titles) }) {
                    guard let article = byID[row.sourceID], article.state == .ready,
                          !excluded.contains(article.id) else { continue }
                    take(article)
                }
            }
        }
        // A spoken script (an explainer, an audio overview's script) is
        // article-typed but no article: its narration is the Explainers
        // switch's (`SourceAudioAutomation.kind`), and it is narrated by
        // naming it in source_ids, never swept up by `["article"]`.
        for type in sourceTypes {
            for article in library
            where article.sourceType == type && article.state == .ready && !excluded.contains(article.id)
                && !TextToSpeechPreparationPolicy.isSpokenScript(url: article.url) {
                take(article)
            }
        }

        // Readability needs the text; load it only for what was selected.
        let contents = try store.loadSourceContents(for: ordered.map(\.id))
        var plan = SourceAudioGenerationPlan()
        for var article in ordered {
            article.content = contents[article.id]
            guard article.state == .ready else {
                plan.skipped.append(.init(sourceID: article.id, title: article.title, reason: "Content is not ready yet (state: \(article.state.rawValue))."))
                continue
            }
            guard ArticleSpeechContent.canAttemptRead(article) else {
                let reason = Self.audioNativeSourceTypes.contains(article.sourceType)
                    ? "\(article.sourceType.rawValue) sources already have their own audio."
                    : "This source does not have readable text yet."
                plan.skipped.append(.init(sourceID: article.id, title: article.title, reason: reason))
                continue
            }
            if hasCachedAudio(article.id) {
                plan.alreadyReady.append(article)
            } else if activeSourceIDs.contains(article.id) {
                plan.alreadyActive.append(article)
            } else {
                plan.pending.append(article)
            }
        }
        plan.characterCounts = try store.sourceContentLengths(for: plan.pending.map(\.id))
        plan.bookTitles = Dictionary(
            chapters.map { ($0.bookID, $0.bookTitle) },
            uniquingKeysWith: { first, _ in first }
        )
        return plan
    }

    /// `generate_source_audio`.
    func generateSourceAudio(
        sourceIDs: [String],
        bookIDs: [String],
        sourceTypeNames: [String],
        confirmCost: Bool,
        allowUnsupportedLanguages: Bool,
        approvedSpendUSD: Double? = nil
    ) async throws -> String {
        let sourceTypes = try Self.audioGenerationSourceTypes(from: sourceTypeNames)
        let hasSelection = sourceIDs.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            || bookIDs.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            || !sourceTypes.isEmpty
        guard hasSelection else {
            throw MCPError.invalidInput(
                "Say what to generate: source_ids, book_ids (from list_sources), and/or source_types (e.g. [\"book\"] for every book in the library)."
            )
        }

        let activeSourceIDs = await MainActor.run { SourceAudioGenerationQueue.shared.activeSourceIDs }
        let plan = try planSourceAudioGeneration(
            sourceIDs: sourceIDs,
            bookIDs: bookIDs,
            sourceTypes: sourceTypes,
            activeSourceIDs: activeSourceIDs
        )

        var payload: [String: Any] = [
            "selected_source_count": plan.pending.count + plan.alreadyReady.count + plan.alreadyActive.count + plan.skipped.count,
            "already_ready": Self.describe(plan.alreadyReady, bookTitles: plan.bookTitles),
            "already_ready_count": plan.alreadyReady.count,
            "already_generating": Self.describe(plan.alreadyActive, bookTitles: plan.bookTitles),
            "skipped": plan.skipped.prefix(Self.listingCap).map {
                ["source_id": $0.sourceID, "title": $0.title, "reason": $0.reason] as [String: Any]
            },
            "skipped_count": plan.skipped.count,
        ]

        guard !plan.pending.isEmpty else {
            payload["status"] = "nothing_to_generate"
            payload["message"] = plan.alreadyReady.isEmpty && plan.alreadyActive.isEmpty
                ? "None of the selected sources can be narrated; see skipped."
                : "Every narratable source in the selection already has audio or is already generating."
            return try jsonString(payload)
        }

        // The voice is the learner's Settings choice, exactly as the sidebar
        // action uses it. Apple's on-device voice plays live and writes no
        // files, so there is nothing for a generate-only run to produce.
        let provider = MacArticleSpeechSettings.provider
        guard provider.isCloudProvider else {
            throw MCPError.invalidInput(
                "Text to Speech is set to the on-device Apple voice, which plays live and does not produce audio files. Ask the learner to choose a cloud voice in ForeverLM Settings → Text-to-Speech, then call again."
            )
        }
        // The quote reads the model's price from OpenRouter's speech list,
        // which this Mac may not have read yet.
        await OpenRouterAudioDirectory.prepare(.speech)
        // A pick OpenRouter stopped offering is repaired before it is quoted
        // or used, and the answer says so once.
        if provider == .openRouter, let repair = MacArticleSpeechSettings.repairSelectionForUse() {
            payload["selection_repaired"] = repair.message
        }
        let model = MacArticleSpeechSettings.model(for: provider)
        let voice = MacArticleSpeechSettings.voice(for: provider)
        let estimate = ArticleSpeechCostEstimate(
            characters: plan.estimatedCharacters,
            sourceCount: plan.pending.count,
            provider: provider.rawValue,
            model: model
        )
        var estimatePayload: [String: Any] = [
            "provider": provider.rawValue,
            "model": model,
            "voice": voice,
            "source_count": plan.pending.count,
            "characters": estimate.characters,
            "estimated_listening_time": estimate.durationLabel,
            "estimated_cost": estimate.costLabel,
            "summary": "\(model) · \(estimate.summary(countingSourcesAs: "source"))",
            "basis": "Stored text length of every pending source. Narration drops page furniture and references, and characters that already have cached audio are never billed again, so the actual charge is at most this. Papers, articles, and any book chapter whose text carries equations or tables also run one text-model preparation call before narration, billed separately from speech.",
        ]
        if let usd = estimate.usd { estimatePayload["estimated_cost_usd"] = usd }
        if plan.unsizedCount > 0 {
            estimatePayload["unsized_source_count"] = plan.unsizedCount
            estimatePayload["unsized_note"] = "\(plan.unsizedCount) source(s) have no extracted text length yet and add nothing to this estimate."
        }
        payload["estimate"] = estimatePayload
        payload["sources"] = Self.describe(plan.pending, characterCounts: plan.characterCounts, bookTitles: plan.bookTitles)
        payload["source_count"] = plan.pending.count

        let isFree = estimate.usd == 0
        if !isFree && !confirmCost {
            payload["status"] = "awaiting_confirmation"
            payload["message"] = "Nothing was started. This would generate \(estimate.summary(countingSourcesAs: "source")) with \(model). Show the learner the estimate, and only after they explicitly agree call generate_source_audio again with the same selection and confirm_cost: true."
            return try jsonString(payload)
        }
        if confirmCost, let estimated = estimate.usd, let approvedSpendUSD,
           estimated > approvedSpendUSD {
            payload["status"] = "approval_too_low"
            payload["message"] = String(
                format: "Nothing was started. The estimated maximum is $%.2f, above the $%.2f approved ceiling for this operation. Show the learner the estimate and ask before calling again with a larger approved_spend_usd.",
                estimated,
                approvedSpendUSD
            )
            return try jsonString(payload)
        }

        let pending = plan.pending
        let outcome = await MainActor.run {
            SourceAudioGenerationQueue.shared.enqueue(pending, allowsUnsupportedLanguages: allowUnsupportedLanguages)
        }
        payload["status"] = "started"
        payload["queued_source_ids"] = outcome.queued
        payload["queued_count"] = outcome.queued.count
        payload["message"] = "Queued \(outcome.queued.count) source(s). Generation runs in the ForeverLM app, \(SourceAudioGenerationQueue.maxConcurrentSources) sources at a time, and keeps going while the app is open. Call get_source_audio_status to follow progress; a long book takes a while."
        return try jsonString(payload)
    }

    /// `get_source_audio_status`.
    func getSourceAudioStatus(sourceIDs: [String]) async throws -> String {
        let (items, appGenerating) = await MainActor.run {
            (SourceAudioGenerationQueue.shared.items, ArticleSpeechService.shared.backgroundGenerationSourceIDs)
        }
        let formatter = ISO8601DateFormatter()
        let bookTitles = Dictionary(
            try bookChapterRows().map { ($0.bookID, $0.bookTitle) },
            uniquingKeysWith: { first, _ in first }
        )
        func describe(_ item: SourceAudioGenerationItem) -> [String: Any] {
            var entry: [String: Any] = [
                "source_id": item.sourceID,
                "title": item.title,
                "source_type": item.sourceType,
                "status": item.status.label,
                "enqueued_at": formatter.string(from: item.enqueuedAt),
            ]
            if let group = item.group {
                entry["book_id"] = group
                entry["book"] = bookTitles[group] ?? group
            }
            if let detail = item.status.detail { entry["detail"] = detail }
            if let endedAt = item.endedAt { entry["ended_at"] = formatter.string(from: endedAt) }
            return entry
        }
        func section(_ status: String) -> [String: Any] {
            let matching = items.filter { $0.status.label == status }
            var section: [String: Any] = [
                "count": matching.count,
                "items": matching.prefix(Self.listingCap).map(describe),
            ]
            if matching.count > Self.listingCap { section["truncated"] = true }
            return section
        }

        var payload: [String: Any] = [
            "generated_at": formatter.string(from: Date()),
            "is_running": items.contains { $0.status.isActive },
            "generating": section("generating"),
            "queued": section("queued"),
            "ready": section("ready"),
            "failed": section("failed"),
            "skipped": section("skipped"),
            "cancelled": section("cancelled"),
        ]
        // Runs the learner started from the sidebar are not in the queue but
        // are the same work; say so rather than reporting the app idle.
        let outsideQueue = appGenerating.subtracting(items.filter { $0.status == .generating }.map(\.sourceID))
        if !outsideQueue.isEmpty {
            payload["generating_in_app_outside_queue"] = Array(outsideQueue).sorted()
        }

        let requested = sourceIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !requested.isEmpty {
            let store = try knowledgeStore()
            var lookups: [[String: Any]] = []
            for token in requested {
                // An audio overview's script source exists once its script
                // is saved; until then its run says where it is, and once a
                // run has ended without one, or its audio could not start,
                // the coordinator's note for it says why.
                let (writing, note) = await MainActor.run {
                    let coordinator = AudioOverviewGenerationCoordinator.shared
                    return (
                        coordinator.run(writingCarrier: token).map { (overviewID: $0.id, stage: $0.stage.label) },
                        coordinator.note(forCarrier: token)
                    )
                }
                guard let resolved = try store.resolveSourceID(forLinkToken: token) else {
                    var entry: [String: Any] = ["source_id": token, "found": false]
                    if let writing {
                        entry["writing_script"] = true
                        entry["overview_id"] = writing.overviewID
                        entry["stage"] = writing.stage
                    } else if let note {
                        entry["overview_id"] = note.overviewID
                        switch note.kind {
                        case .writingFailed: entry["writing_failed"] = note.message
                        case .writingStopped: entry["writing_stopped"] = note.message
                        case .audioNotStarted: entry["audio_not_started"] = note.message
                        }
                    }
                    lookups.append(entry)
                    continue
                }
                var entry: [String: Any] = [
                    "source_id": resolved,
                    "found": true,
                    "has_audio": ArticleSpeechAudioCache.hasCachedAudio(sourceID: resolved),
                ]
                if let item = items.first(where: { $0.sourceID == resolved }) {
                    entry["queue"] = describe(item)
                } else if appGenerating.contains(resolved) {
                    entry["queue"] = ["status": "generating_in_app"]
                } else if let note, note.kind == .audioNotStarted, entry["has_audio"] as? Bool != true {
                    // The script was saved but its audio was not started (a
                    // script longer than the agreed estimate, say), and nothing
                    // has started it since.
                    entry["overview_id"] = note.overviewID
                    entry["audio_not_started"] = note.message
                }
                lookups.append(entry)
            }
            payload["sources"] = lookups
        }
        return try jsonString(payload)
    }

    /// `cancel_source_audio_generation`.
    func cancelSourceAudioGeneration(sourceIDs: [String], all: Bool) async throws -> String {
        let requested = sourceIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard all || !requested.isEmpty else {
            throw MCPError.invalidInput("Pass source_ids to stop specific sources, or all: true to stop every queued and generating source.")
        }
        var targets: Set<String>? = nil
        if !all {
            // Through the storage actor: this tool is off the store gate
            // (`storeGateExemptToolNames`), so it never reads the cached connection.
            var resolvedIDs = Set<String>()
            for token in requested {
                resolvedIDs.insert(try await notebookFileStorage.resolveSourceID(forLinkToken: token) ?? token)
            }
            targets = resolvedIDs
        }
        let result = await MainActor.run {
            SourceAudioGenerationQueue.shared.cancel(sourceIDs: targets)
        }
        return try jsonString([
            "status": "cancelled",
            "cancelled_source_ids": result.cancelled.sorted(),
            "cancelled_count": result.cancelled.count,
            "not_active_source_ids": result.notActive.sorted(),
            "message": result.cancelled.isEmpty
                ? "Nothing was queued or generating for that selection."
                : "Stopped \(result.cancelled.count) source(s). Audio chunks that had already finished stay cached, so generating them again later costs nothing for those parts.",
        ] as [String: Any])
    }

    private static func describe(
        _ articles: [StudioArticle],
        characterCounts: [String: Int] = [:],
        bookTitles: [String: String] = [:]
    ) -> [[String: Any]] {
        articles.prefix(listingCap).map { article in
            var entry: [String: Any] = [
                "source_id": article.id,
                "title": article.title,
                "source_type": article.sourceType.rawValue,
            ]
            if let group = article.parentGroup {
                entry["book_id"] = group
                entry["book"] = bookTitles[group] ?? group
            }
            if let characters = characterCounts[article.id] { entry["characters"] = characters }
            return entry
        }
    }

    // MARK: - Automatic audio (chat and MCP only; Settings has no pane for it)

    /// The kinds automation covers, in a fixed order — the schema enum for
    /// `kind`. Four source types and `explainer`, which is an article-typed
    /// source with a switch of its own (`SourceAudioAutomation.explainerKind`).
    static let automaticAudioKinds: [String] = SourceAudioAutomation.automatableSourceTypes

    /// Resolves a kind by id (`paper`), by its plural
    /// (`papers`) or by its switch title (`Papers`).
    static func automaticAudioKind(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let choices = automaticAudioKinds.joined(separator: ", ")
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("kind is required. One of: \(choices).")
        }
        if let type = SourceAudioAutomation.automatable.first(where: {
            $0.sourceType == trimmed || $0.plural == trimmed || $0.switchTitle.lowercased() == trimmed
        }) {
            return type.sourceType
        }
        throw MCPError.invalidInput("Unknown kind ‘\(raw)’. One of: \(choices).")
    }

    /// Automatic audio, read: every kind's switch and
    /// rule, what each has waiting, the voice the switches would spend on and
    /// whether automation may run on it, and the paid-voice consent.
    func getAutomaticAudioSettings(selection: AutomaticAudioSelection? = nil) async throws -> String {
        try jsonString(await Self.automaticAudioSettingsPayload(selection: selection ?? .current))
    }

    /// Automatic audio, written. The product owner (2026-09-22) took the Settings pane
    /// out: the switches are set by asking, e.g. "always generate audio for
    /// articles from Martin Picard". `enabled` arms or retires one kind's
    /// switch — armed only when the selection is one automation may spend on.
    /// `filter` is evaluated over the kind's pending sources first, kept only
    /// when that succeeds, and an empty rule clears it. `allow_paid_voices` is
    /// the account's consent; revoking it stops a paid run through
    /// `automaticSourceAudioPreferencesChanged`. Writes go through `PreferenceStore`, so the
    /// choice reaches this Mac's defaults, the row that survives a rebuild and
    /// the learner's other devices, and the pending write is flushed before the
    /// `foreverLMDataDidChange` post re-reads it into the open window.
    func setAutomaticAudioSettings(
        kind rawKind: String?,
        enabled: Bool?,
        filter: String?,
        allowPaidVoices: Bool?,
        selection: AutomaticAudioSelection? = nil
    ) async throws -> String {
        guard enabled != nil || filter != nil || allowPaidVoices != nil else {
            throw MCPError.invalidInput(
                "Pass kind with enabled and/or filter, or allow_paid_voices; nothing to change."
            )
        }
        var kind: String?
        if enabled != nil || filter != nil {
            guard let rawKind, !rawKind.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MCPError.invalidInput(
                    "kind is required with enabled or filter. One of: \(Self.automaticAudioKinds.joined(separator: ", "))."
                )
            }
            kind = try Self.automaticAudioKind(rawKind)
        }

        var effective = selection ?? .current
        var changed: [String] = []
        var payloadExtras: [String: Any] = [:]

        if let allowPaidVoices {
            if allowPaidVoices != MacArticleSpeechSettings.allowsPaidAutomaticVoices {
                MacArticleSpeechSettings.setAllowsPaidAutomaticVoices(allowPaidVoices)
                changed.append("allow_paid_voices")
            }
            effective.allowsPaidVoices = allowPaidVoices
        }

        if let kind {
            let plural = SourceAudioAutomation.noun(forSourceType: kind, count: 2)
            if let filter {
                // A rule is saved only after a successful dry run, so an invalid or failed AI answer never widens
                // what a switch narrates.
                let preview = try await AutomaticSourceAudioGenerationService.shared.previewConstraint(
                    sourceType: kind,
                    constraint: filter
                )
                if preview.constraint != MacArticleSpeechSettings.automaticGenerationConstraint(kind) {
                    MacArticleSpeechSettings.setAutomaticGenerationConstraint(preview.constraint, sourceType: kind)
                    changed.append("filter")
                }
                var previewPayload: [String: Any] = [
                    "filter": preview.constraint,
                    "matching_source_count": preview.matches.count,
                    "matching_titles": preview.matches.prefix(Self.listingCap).map(\.title),
                ]
                if let characters = preview.characterCount {
                    previewPayload["characters"] = characters
                    if let usd = preview.speechCost(ratePerMillionCharacters: effective.ratePerMillionCharacters) {
                        previewPayload["estimated_cost"] = SourceAudioAutomation.costLabel(usd)
                    }
                }
                payloadExtras["filter_preview"] = previewPayload
            }
            if let enabled {
                if enabled, !effective.isAllowed {
                    throw MCPError.invalidInput(
                        "Automatic audio cannot be switched on for \(plural): "
                        + (effective.unavailableReason ?? "the selected voice does not qualify.")
                        + " Choose a free OpenRouter voice in Settings › Text to Speech, or pass allow_paid_voices: true after the learner has agreed to the quote."
                    )
                }
                if enabled != MacArticleSpeechSettings.automaticallyGenerates(kind) {
                    MacArticleSpeechSettings.setAutomaticallyGenerates(enabled, sourceType: kind)
                    changed.append("enabled")
                }
            }
        }

        await PreferenceStore.flushPendingWrites()

        var payload = await Self.automaticAudioSettingsPayload(selection: effective)
        for (key, value) in payloadExtras { payload[key] = value }
        if let kind,
           let kinds = payload["kinds"] as? [[String: Any]],
           let row = kinds.first(where: { $0["kind"] as? String == kind }) {
            payload["kind"] = row
        }
        payload["updated"] = !changed.isEmpty
        payload["changed"] = changed
        return try jsonString(payload)
    }

    private static func automaticAudioSettingsPayload(
        selection: AutomaticAudioSelection
    ) async -> [String: Any] {
        // The rate is the selected model's price on OpenRouter's speech list.
        await OpenRouterAudioDirectory.prepare(.speech)
        let (backlogs, progress) = await MainActor.run {
            (
                AutomaticSourceAudioGenerationService.shared.backlogs,
                AutomaticSourceAudioGenerationService.shared.progress
            )
        }
        let rate = selection.ratePerMillionCharacters
        // Estimates are priced only when generation may run, so an unavailable selection never implies a quote.
        let effectiveRate = selection.isAllowed ? rate : nil

        let kinds: [[String: Any]] = SourceAudioAutomation.automatable.map { type in
            let backlog = backlogs[type.sourceType] ?? SourceAudioAutomation.Backlog()
            var row: [String: Any] = [
                "kind": type.sourceType,
                "title": type.switchTitle,
                "enabled": MacArticleSpeechSettings.automaticallyGenerates(type.sourceType),
                "filter": MacArticleSpeechSettings.automaticGenerationConstraint(type.sourceType),
                "sources_without_audio": backlog.sourceCount,
            ]
            if let characters = backlog.characterCount {
                row["characters_without_audio"] = characters
            }
            if let estimate = SourceAudioAutomation.estimateLabel(
                for: backlog,
                ratePerMillionCharacters: effectiveRate
            ) {
                row["estimate"] = estimate
            }
            if type.sourceType == SourceAudioAutomation.explainerKind {
                row["note"] = "An explainer is an article-typed source with a switch of its own, never under Articles. With it on, generate_explainer and the Mac's Explain button start the explainer's audio with the selected voice without asking about cost."
            }
            return row
        }

        var voice: [String: Any] = [
            "provider": selection.provider.rawValue,
            "model": selection.model,
            "voice": selection.voice,
            "rate": SourceAudioAutomation.rateLabel(ratePerMillionCharacters: rate) ?? "unpriced",
            "requires_paid_consent": selection.requiresPaidVoiceConsent,
        ]
        if let rate { voice["rate_per_million_characters"] = rate }

        var payload: [String: Any] = [
            "reach": "account",
            "voice": voice,
            "allow_paid_voices": selection.allowsPaidVoices,
            "automation_available": selection.isAllowed,
            "kinds": kinds,
            "accepts": "set_automatic_audio_settings takes kind with enabled and/or filter, and allow_paid_voices on its own or alongside them.",
        ]
        if let reason = selection.unavailableReason {
            payload["unavailable_reason"] = reason
        } else if selection.provider == .openRouter {
            payload["disclosure"] = SourceAudioAutomation.costDisclosure(
                ratePerMillionCharacters: rate,
                allowsPaidVoices: selection.allowsPaidVoices
            )
        }
        if selection.requiresPaidVoiceConsent {
            // What granting consent starts, priced for the whole pending
            // library — the number to put to the learner before consenting.
            let preview = await AutomaticSourceAudioGenerationService.shared.libraryCostPreview(
                ratePerMillionCharacters: rate
            )
            payload["paid_consent_quote"] = [
                "lines": preview.lineLabels(),
                "total": preview.totalLabel,
                "message": SourceAudioAutomation.paidVoiceConsentMessage(
                    voiceName: ArticleSpeechCatalog.model(id: selection.model)?.name ?? selection.model,
                    preview: preview
                ),
            ] as [String: Any]
        }
        if let progress {
            var running: [String: Any] = [
                "completed": progress.completedCount,
                "total": progress.totalCount,
            ]
            if let kind = progress.currentSourceType { running["current_kind"] = kind }
            if let title = progress.currentTitle { running["current_title"] = title }
            payload["running"] = running
        }
        return payload
    }
}
#endif
