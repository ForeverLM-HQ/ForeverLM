import Foundation

// MARK: - save_card_drafts, list_cards, triage_cards, get_due_cards,
// record_card_result, practice_cards, update_card
//
// Memory as cards over MCP (docs/memory-design.md, "Cards to check" and
// "MCP"). An assistant drafts cards from a source and saves them, free, into
// the source's private draft deck; they wait in Memory's To Check until the
// learner — in the app, or through the assistant on their word — keeps, edits
// or skips each one. Only a kept card is ever reviewed: `get_due_cards` deals
// today's, as the app's card review does (`MemoryCardQueue`), with the wording
// to ask, `record_card_result` records each answer by the card review's rules,
// `practice_cards` opens the app's own card review on the cards an assistant
// chose (a topic, a source), and `update_card` rewords, holds, starts over or
// retires a kept card as All Cards does.

extension MCPDataStore {
    /// The most cards one `save_card_drafts` call takes.
    static let maxCardDraftsPerCall = 100

    /// What every tool that takes a `doc_id` answers for a source's draft
    /// deck, which is the learner's own memory state and no Doc.
    static func cardDeckIsNoDocMessage(docID: String, tool: String) -> String {
        "\(docID) holds a source's cards to check, which are the learner's own and not a Doc, so \(tool) does not read or change it. list_cards reads them, triage_cards keeps or skips them, and save_card_drafts adds to them."
    }

    // MARK: save_card_drafts

    func saveCardDrafts(cards rawCards: [[String: Any]], keptByDefault: Bool) async throws -> String {
        guard !rawCards.isEmpty else {
            throw MCPError.invalidInput("cards is required: one object per card, each with source_id, front, back and quote.")
        }
        guard rawCards.count <= Self.maxCardDraftsPerCall else {
            throw MCPError.invalidInput("Nothing was saved. One call takes at most \(Self.maxCardDraftsPerCall) cards; send the rest in another call.")
        }

        // Every source first: an id the library does not hold refuses the
        // whole call, before anything is written.
        let store = try knowledgeStore()
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        var sources: [String: StudioArticle] = [:]
        var unknown: [String] = []
        for entry in rawCards {
            let id = Self.trimmedOrNil(entry["source_id"] as? String) ?? ""
            guard sources[id] == nil, !unknown.contains(id) else { continue }
            if !id.isEmpty, let source = try store.loadSourceWithoutContent(id),
               source.status == .active, !excluded.contains(id) {
                sources[id] = source
            } else {
                unknown.append(id)
            }
        }
        guard unknown.isEmpty else {
            let named = unknown.map { $0.isEmpty ? "(a card without source_id)" : $0 }.joined(separator: ", ")
            throw MCPError.invalidInput(
                "Nothing was saved. No library source answers to \(named). Pass each card's source_id as list_sources (or search_sources_keyword, search_sources_semantic) returns it."
            )
        }

        let now = Date()
        var order: [String] = []
        var bySource: [String: [Flashcard]] = [:]
        var incomplete: [[String: Any]] = []
        for (index, entry) in rawCards.enumerated() {
            let sourceID = Self.trimmedOrNil(entry["source_id"] as? String) ?? ""
            let front = Self.trimmedOrNil(entry["front"] as? String)
            let back = Self.trimmedOrNil(entry["back"] as? String)
            let quote = Self.trimmedOrNil(entry["quote"] as? String)
            guard let front, let back, let quote, let source = sources[sourceID] else {
                var missing: [String] = []
                if front == nil { missing.append("front") }
                if back == nil { missing.append("back") }
                if quote == nil { missing.append("quote") }
                incomplete.append(["index": index, "source_id": sourceID, "missing": missing])
                continue
            }
            let alsoFrom = try Self.cardSourceLinks(entry["also_from"], cardIndex: index, store: store, excluded: excluded) ?? []
            let card = Flashcard.mint(
                front: front,
                back: back,
                why: Self.trimmedOrNil(entry["why"] as? String),
                sourceID: sourceID,
                sourceTitle: source.title,
                quote: quote,
                seed: Self.trimmedOrNil(entry["seed"] as? String),
                origin: .assistant,
                isRequested: keptByDefault,
                frontImages: try Self.cardImages(entry["front_images"], cardIndex: index, field: "front_images", store: store),
                backImages: try Self.cardImages(entry["back_images"], cardIndex: index, field: "back_images", store: store),
                alsoFrom: alsoFrom,
                at: now
            )
            if bySource[sourceID] == nil { order.append(sourceID) }
            bySource[sourceID, default: []].append(card)
        }

        // One deck per source: a source that cannot take cards (no text yet,
        // its deck still downloading) is named and the others are saved.
        // Every card first passes the wording gate (`CardWordingGate`): one
        // that points at its source unnamed is reworded once, or refused with
        // the reason; a source whose cards could not be checked saves none.
        var saved: [(requestedID: String, title: String, result: MemoryCardDraftsSaved)] = []
        var failedSources: [[String: Any]] = []
        var reworded: [String: [[String: Any]]] = [:]
        var notStandalone: [String: [[String: Any]]] = [:]
        let wording = CardWordingGate.backend()
        for sourceID in order {
            let title = sources[sourceID]?.title ?? sourceID
            let given = bySource[sourceID] ?? []
            let cards: [Flashcard]
            do {
                let screened = try await CardWordingGate.screen(
                    drafts: given,
                    sourceTitle: title,
                    usage: AIUsageSource(id: sourceID, type: sources[sourceID]?.sourceType.rawValue ?? "source", title: title),
                    backend: wording
                )
                cards = screened.passed
                let before = Dictionary(given.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                reworded[sourceID] = screened.passed.compactMap { card in
                    guard let was = before[card.id], was.front != card.front || was.back != card.back else { return nil }
                    return ["card_id": card.id, "was": was.front, "front": card.front, "back": card.back]
                }
                notStandalone[sourceID] = screened.refused.map { ["front": $0.front, "reason": $0.reason] }
            } catch {
                failedSources.append([
                    "source_id": sourceID,
                    "source_title": title,
                    "reason": "The cards' wording could not be checked, so none was saved. \(error.localizedDescription)",
                ])
                continue
            }
            guard !cards.isEmpty else { continue }
            do {
                let result = try await notebookFileStorage.saveCardDrafts(cards, sourceID: sourceID, sourceTitle: title)
                saved.append((sourceID, title, result))
            } catch {
                failedSources.append(["source_id": sourceID, "source_title": title, "reason": error.localizedDescription])
            }
        }

        func summary(_ card: Flashcard) -> [String: Any] {
            ["front": card.front, "card_id": card.id]
        }
        let addedCount = saved.reduce(0) { $0 + $1.result.added.count }
        let entries: [[String: Any]] = saved.map { requestedID, title, result in
            var entry: [String: Any] = [
                "source_id": result.sourceID,
                "source_title": title,
                "saved_card_ids": result.added.map(\.id),
            ]
            // A team's copy is drafted onto the learner's own source at its
            // address, where a kept card is anchored.
            if result.sourceID != requestedID { entry["team_copy_id"] = requestedID }
            if !result.alreadyDrafted.isEmpty { entry["already_drafted"] = result.alreadyDrafted.map(summary) }
            if !result.ungrounded.isEmpty {
                entry["not_grounded"] = result.ungrounded.map { card in
                    ["front": card.front, "quote": card.quote ?? "", "reason": "The source's text does not print this quote. Copy the passage word for word from get_source_content."]
                }
            }
            if !result.ungroundedLinks.isEmpty {
                entry["not_grounded_links"] = result.ungroundedLinks.map { missed in
                    [
                        "front": missed.front,
                        "source_id": missed.link.sourceID,
                        "quote": missed.link.quote,
                        "reason": "\(missed.reason) The card was saved without this link; copy the passage word for word from get_source_content and link it with triage_cards also_from.",
                    ]
                }
            }
            if !result.unreadable.isEmpty {
                entry["not_saved"] = result.unreadable.map { card in
                    ["front": card.front, "reason": "A line of the back reads as a heading or as the card's own metadata (Source:, Seed:, …). Reword that line."]
                }
            }
            if let changed = reworded[requestedID], !changed.isEmpty { entry["reworded"] = changed }
            if let refused = notStandalone[requestedID], !refused.isEmpty { entry["not_standalone"] = refused }
            return entry
        }
        // A source whose every card was refused for its wording has no saved
        // entry; it is named all the same.
        let savedIDs = Set(saved.map(\.requestedID))
        let refusedOnly: [[String: Any]] = order.compactMap { sourceID in
            guard !savedIDs.contains(sourceID), let refused = notStandalone[sourceID], !refused.isEmpty else { return nil }
            return ["source_id": sourceID, "source_title": sources[sourceID]?.title ?? sourceID, "not_standalone": refused]
        }
        var payload: [String: Any] = [
            "saved_count": addedCount,
            "sources": entries,
            "kept_by_default": keptByDefault,
            "message": addedCount == 0
                ? "No card was saved."
                : "Saved \(addedCount) card\(addedCount == 1 ? "" : "s") to check. They wait in Memory's To Check until the learner keeps, edits or skips them. Nothing is reviewed before it is kept.",
        ]
        if !incomplete.isEmpty {
            payload["incomplete"] = incomplete
            payload["incomplete_guidance"] = "Each card needs a front, a back and a quote copied from its source."
        }
        if !failedSources.isEmpty {
            payload["sources_not_saved"] = failedSources
        }
        if !refusedOnly.isEmpty {
            payload["not_standalone"] = refusedOnly
        }
        if reworded.values.contains(where: { !$0.isEmpty }) || notStandalone.values.contains(where: { !$0.isEmpty }) {
            payload["wording_guidance"] = "A card is asked weeks later, away from its source: it never points at \u{201C}this lecture\u{201D}, \u{201C}the paper\u{201D} or \u{201C}the speaker\u{201D} without naming it. ForeverLM reworded the cards under reworded, and refused those under not_standalone; ask about the subject itself, or name the source."
        }
        return try jsonString(payload)
    }

    /// A card's `also_from`: the other sources' passages it stands on, each
    /// `{source_id, quote}`, in the order given. Nil when the argument is
    /// absent; `[]` when it is empty (no other source). Every source must be
    /// one the library holds and shows to an assistant; whether its text prints
    /// the quote is checked when the card is saved or kept, as the card's own
    /// quote is. Refuses the whole call for a malformed entry.
    static func cardSourceLinks(
        _ raw: Any?,
        cardIndex: Int,
        store: KnowledgeStore,
        excluded: Set<String>
    ) throws -> [CardSourceLink]? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let entries = raw as? [[String: Any]] else {
            throw MCPError.invalidInput(
                "Nothing was changed. also_from is a list of {source_id, quote}: each other source the card also stands on, with the passage copied word for word from its text."
            )
        }
        guard entries.count <= MemoryCard.maximumLinkedSources else {
            throw MCPError.invalidInput(
                "Nothing was changed. A card stands on at most \(MemoryCard.maximumLinkedSources) other sources; also_from has \(entries.count) (card \(cardIndex))."
            )
        }
        var links: [CardSourceLink] = []
        for entry in entries {
            guard let id = trimmedOrNil(entry["source_id"] as? String), let quote = trimmedOrNil(entry["quote"] as? String) else {
                throw MCPError.invalidInput(
                    "Nothing was changed. Each also_from entry needs a source_id and a quote (card \(cardIndex))."
                )
            }
            guard !excluded.contains(id), let source = try store.loadSourceWithoutContent(id), source.status == .active else {
                throw MCPError.invalidInput(
                    "Nothing was changed. No library source answers to \(id) in also_from (card \(cardIndex)). Pass a source_id as list_sources or a search returns it."
                )
            }
            links.append(CardSourceLink(sourceID: id, quote: quote))
        }
        return links
    }

    /// A card's sources as an assistant reads them: each with its title and
    /// the passage the card stands on there. A source kept from AI is left
    /// out, with its passage.
    static func cardSourcesPayload(
        _ links: [CardSourceLink],
        titles: [String: String],
        excluded: Set<String>
    ) -> [[String: Any]] {
        links.filter { !excluded.contains($0.sourceID) }.map {
            ["source_id": $0.sourceID, "source_title": titles[$0.sourceID] ?? "", "quote": $0.quote]
        }
    }

    /// Card image arguments are the exact Markdown image lines returned by
    /// show_source_image / inspect_paper_figure / generate_image, or objects
    /// with `target` and `alt`. Only durable source and generated references
    /// are accepted; chat attachments and local/web paths would not travel
    /// with a card. One entry per face may instead be a saved animation, by
    /// its `foreverlm-site://<animation_id>/` address (from `save_animation` or
    /// `list_animations`), which the card plays; the record must be an
    /// animation this Mac holds.
    private static func cardImages(
        _ raw: Any?,
        cardIndex: Int,
        field: String,
        store: KnowledgeStore
    ) throws -> [MemoryCardImage] {
        guard let raw, !(raw is NSNull) else { return [] }
        guard let entries = raw as? [Any] else {
            throw MCPError.invalidInput("Nothing was saved. Card \(cardIndex)'s \(field) is an array of ForeverLM image references (one may be a saved animation's address).")
        }
        guard entries.count <= MemoryCard.maximumImagesPerFace else {
            throw MCPError.invalidInput("Nothing was saved. Card \(cardIndex)'s \(field) takes at most \(MemoryCard.maximumImagesPerFace) images.")
        }
        var images: [MemoryCardImage] = []
        for (imageIndex, entry) in entries.enumerated() {
            let image: MemoryCardImage?
            if let text = entry as? String {
                image = MemoryCardImage(reference: text)
            } else if let object = entry as? [String: Any], let target = object["target"] as? String {
                image = MemoryCardImage(target: target, alt: object["alt"] as? String ?? "")
            } else {
                image = nil
            }
            guard let image else {
                throw MCPError.invalidInput("Nothing was saved. Card \(cardIndex)'s \(field)[\(imageIndex)] must be a source or generated ForeverLM image, as an image-tool Markdown line or {target, alt}, or a saved animation's foreverlm-site://<animation_id>/ address.")
            }
            if let animationID = image.animationID {
                guard !images.contains(where: \.isAnimation) else {
                    throw MCPError.invalidInput("Nothing was saved. Card \(cardIndex)'s \(field) takes one animation; \(field)[\(imageIndex)] is a second.")
                }
                let held = try store.loadArtifacts(listing: .everyRecord)
                    .first { $0.id.lowercased() == animationID && $0.isAnimation }
                guard held != nil else {
                    throw MCPError.invalidInput("Nothing was saved. Card \(cardIndex)'s \(field)[\(imageIndex)] names an animation this Mac does not hold; list_animations has the saved ones.")
                }
            } else if let reference = SourceImageReference(urlString: image.target) {
                guard let source = try? store.loadSourceWithoutContent(reference.sourceID), source.status == .active else {
                    throw MCPError.invalidInput("Nothing was saved. Card \(cardIndex)'s \(field)[\(imageIndex)] names a source the library does not hold.")
                }
            } else if let reference = GeneratedImageReference(urlString: image.target), !GeneratedImageStore.holds(id: reference.id) {
                throw MCPError.invalidInput("Nothing was saved. Card \(cardIndex)'s \(field)[\(imageIndex)] names a generated image this device does not hold.")
            }
            images.append(image)
        }
        return images
    }

    // MARK: list_cards

    func listCards(status rawStatus: String?, notebookID: String?, sourceID: String?, limit rawLimit: Int?) async throws -> String {
        let status = Self.trimmedOrNil(rawStatus)?.lowercased() ?? "to_check"
        guard ["to_check", "kept", "all"].contains(status) else {
            throw MCPError.invalidInput("status is to_check, kept or all.")
        }
        let limit = max(1, min(rawLimit ?? 100, 500))
        await MemoryCardStateStore.loaded(defaults: cardStateDefaults)
        let store = try knowledgeStore()
        let scope: MemoryCardScope?
        if let notebookID = Self.trimmedOrNil(notebookID) {
            let notebook = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
            scope = MemoryCardScope(membership: try store.notebookMembership(notebookID: notebook.id))
        } else {
            scope = nil
        }
        let onlySource = Self.trimmedOrNil(sourceID)
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let snapshot = try await notebookFileStorage.memoryCardReviewSnapshot(
            now: Date(),
            budgetMinutes: nil,
            newPerDay: MemoryCardSettings.newCardsPerDay(),
            deadlines: [],
            scope: scope,
            includesListings: status != "to_check",
            includesToCheck: status != "kept",
            stateDefaults: cardStateDefaults
        )
        let titles = try sourceTitles(for: snapshot, store: store)

        var payload: [String: Any] = [:]
        if status != "kept" {
            let cards = snapshot.toCheck.filter { card in
                !excluded.contains(card.sourceID) && (onlySource.map { card.sourceIDs.contains($0) } ?? true)
            }
            payload["to_check_count"] = cards.count
            payload["to_check"] = cards.prefix(limit).map { card in
                var entry: [String: Any] = [
                    "card_id": card.cardID,
                    "kind": card.kind == .draft ? "draft" : "from_before",
                    "source_id": card.sourceID,
                    "source_title": titles[card.sourceID] ?? "",
                    "front": card.face.front,
                    "back": card.face.back,
                    "why": card.face.why.joined(separator: "\n"),
                    "origin": card.face.origin.rawValue,
                    "kept_by_default": card.isKeptByDefault,
                ]
                if !card.face.frontImages.isEmpty { entry["front_images"] = card.face.frontImages.map(\.rubricObject) }
                if !card.face.backImages.isEmpty { entry["back_images"] = card.face.backImages.map(\.rubricObject) }
                if let quote = card.quote { entry["quote"] = quote }
                // Every source the card stands on, its own first, each with its passage.
                entry["sources"] = Self.cardSourcesPayload(card.links, titles: titles, excluded: excluded)
                if let seed = card.seed { entry["seed"] = seed }
                if let draftedAt = card.draftedAt { entry["drafted_at"] = ISO8601DateFormatter().string(from: draftedAt) }
                if let expiresAt = card.expiresAt { entry["expires_at"] = ISO8601DateFormatter().string(from: expiresAt) }
                if let itemID = card.memoryItemID { entry["item_id"] = itemID }
                return entry
            }
            if let line = MemoryCardTriage.summary(cards) { payload["to_check_summary"] = line }
        }
        if status != "to_check" {
            let now = Date()
            let kept = snapshot.cards.filter { card in
                !card.sourceIDs.contains(where: excluded.contains) && (onlySource.map { card.sourceIDs.contains($0) } ?? true)
            }
            payload["kept_count"] = kept.count
            payload["kept"] = kept.prefix(limit).map { card in
                let state = (card.face.deckID ?? card.sourceIDs.first.map(MemoryCard.draftDeckID(sourceID:))).flatMap {
                    MemoryCardStateStore.state(cardID: card.face.cardID, deckID: $0, defaults: cardStateDefaults)
                }
                var entry: [String: Any] = [
                    "card_id": card.face.cardID,
                    "item_id": card.itemID,
                    "ask": card.face.wording(state: state),
                    "front": card.face.front,
                    "back": card.face.back,
                    "why": card.face.why.joined(separator: "\n"),
                    "origin": card.face.origin.rawValue,
                    "source_ids": card.sourceIDs,
                    "source_titles": card.sourceIDs.compactMap { titles[$0] },
                    "sources": Self.cardSourcesPayload(card.links, titles: titles, excluded: excluded),
                ]
                if !card.face.frontImages.isEmpty { entry["front_images"] = card.face.frontImages.map(\.rubricObject) }
                if !card.face.backImages.isEmpty { entry["back_images"] = card.face.backImages.map(\.rubricObject) }
                if card.schedule.isNew {
                    entry["schedule"] = "new"
                } else if card.schedule.dueAt <= now {
                    entry["schedule"] = "due"
                } else {
                    entry["schedule"] = "scheduled"
                    entry["next_due_at"] = ISO8601DateFormatter().string(from: card.schedule.dueAt)
                }
                return entry
            }
        }
        // What `draft_cards` and the app's own Make Cards drafted lately, for
        // the sources asked about: what each run added, and what it did not
        // find in its source.
        if status != "kept" {
            let touching: Set<String>? = onlySource.map { [$0] } ?? scope.map(\.sourceIDs)
            let runs = await cardDraftingRunsPayload(touching: touching)
            if !runs.isEmpty { payload["drafting"] = runs }
        }
        payload["status"] = status
        payload["guidance"] = status == "kept"
            ? "Kept cards are reviewed by the app's card review; ask a card by its ask wording. memory_review lists the ones due now."
            : "A draft is offered for 14 days after it was drafted (expires_at). Keep, edit or skip cards with triage_cards, only on the learner's word."
        return try jsonString(payload)
    }

    /// Titles of the sources a read names, in one pass.
    private func sourceTitles(for snapshot: MemoryCardReviewSnapshot, store: KnowledgeStore) throws -> [String: String] {
        let ids = Set(snapshot.toCheck.flatMap(\.sourceIDs)).union(snapshot.cards.flatMap(\.sourceIDs))
        var titles: [String: String] = [:]
        for id in ids {
            if let source = try store.loadSourceWithoutContent(id) { titles[id] = source.title }
        }
        return titles
    }

    // MARK: find_card_sources

    /// The embedding of a card's words, for `CardSourceLinker`'s retrieval;
    /// no judge is behind it (`find_card_sources` leaves the judging to the
    /// assistant), so `pick` is never asked.
    private struct CardSourceEmbedder: CardSourceLinkBackend {
        let embedder: SourceEmbeddingProvider

        func embed(_ text: String) async throws -> [Float] { try await embedder(text) }

        func pick(user: String, usage: AIUsageSource) async throws -> [CardSourceLinkingVerdict] {
            throw MCPError.invalidInput("find_card_sources judges nothing itself.")
        }
    }

    /// The passages of the library's other sources nearest a card, for an
    /// assistant to judge: which of them state what the card asks, so it can
    /// name them in `also_from`. Reads only; the card is a card to check or a
    /// kept card (`card_id`), or a question and answer an assistant is about
    /// to save as one.
    func findCardSources(
        cardID: String?,
        question: String?,
        answer: String?,
        sourceIDs rawSourceIDs: [String],
        notebookID: String?
    ) async throws -> String {
        let store = try knowledgeStore()
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        var front: String
        var back: String
        var own: Set<String> = []
        var found: [String: Any] = [:]
        if let cardID = Self.trimmedOrNil(cardID) {
            await MemoryCardStateStore.loaded(defaults: cardStateDefaults)
            let snapshot = try await notebookFileStorage.memoryCardReviewSnapshot(
                now: Date(), budgetMinutes: nil, newPerDay: MemoryCardSettings.newCardsPerDay(), deadlines: [],
                scope: nil, includesListings: true, includesToCheck: true, stateDefaults: cardStateDefaults
            )
            if let waiting = snapshot.toCheck.first(where: { $0.cardID == cardID }) {
                front = waiting.face.front
                back = waiting.face.back
                own = Set(waiting.sourceIDs)
            } else if let kept = snapshot.cards.first(where: { $0.face.cardID == cardID || $0.itemID == cardID }) {
                front = kept.face.front
                back = kept.face.back
                own = Set(kept.sourceIDs)
            } else {
                throw MCPError.notFound("No card answers to \(cardID). Pass a card_id list_cards returned, or a question and an answer.")
            }
            found["card_id"] = cardID
        } else if let question = Self.trimmedOrNil(question), let answer = Self.trimmedOrNil(answer) {
            front = question
            back = answer
        } else {
            throw MCPError.invalidInput("Pass card_id (from list_cards), or a question and an answer.")
        }
        own.formUnion(excluded)

        var pool: Set<String>?
        let named = rawSourceIDs.compactMap { Self.trimmedOrNil($0) }
        if !named.isEmpty {
            var scoped = Set<String>()
            for id in named {
                guard !excluded.contains(id), let source = try store.loadSourceWithoutContent(id), source.status == .active else {
                    throw MCPError.invalidInput("No library source answers to \(id). Pass source_ids as list_sources or a search returns them.")
                }
                scoped.insert(id)
            }
            pool = scoped
        }
        if let notebookID = Self.trimmedOrNil(notebookID) {
            let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
            let members = Set(notebookChatPoolSourceIDs(goal: goal, store: store))
            pool = pool.map { $0.intersection(members) } ?? members
        }

        let embedder = sourceEmbeddingProvider ?? liveSourceEmbeddingProvider
        let candidates = await CardSourceLinker.candidates(
            for: [(front, back)],
            excluding: own,
            among: pool,
            storage: notebookFileStorage,
            backend: CardSourceEmbedder(embedder: embedder)
        ).first ?? []
        found["question"] = front
        found["answer"] = back
        found["candidates"] = candidates.map {
            ["source_id": $0.sourceID, "source_title": $0.title, "passage": $0.passage] as [String: Any]
        }
        found["guidance"] = candidates.isEmpty
            ? "No other source of the library has a passage near this card."
            : "These are the nearest passages of other sources, not yet judged. Keep only those that state what the card asks, in substance, not merely its topic. For each, pass its source_id and a quote copied word for word from its passage (or get_source_content) as an also_from entry of the card: in save_card_drafts when you draft it, or in triage_cards when the learner keeps it."
        return try jsonString(found)
    }

    // MARK: triage_cards

    func triageCards(decisions rawDecisions: [[String: Any]], keepSourceIDs: [String], skipSourceIDs: [String]) async throws -> String {
        let keepSources = Set(keepSourceIDs.compactMap { Self.trimmedOrNil($0) })
        let skipSources = Set(skipSourceIDs.compactMap { Self.trimmedOrNil($0) })
        guard !rawDecisions.isEmpty || !keepSources.isEmpty || !skipSources.isEmpty else {
            throw MCPError.invalidInput("Pass decisions (card_id and action keep or skip, from list_cards), keep_source_ids or skip_source_ids.")
        }
        guard keepSources.isDisjoint(with: skipSources) else {
            throw MCPError.invalidInput("Nothing was changed. A source cannot be in both keep_source_ids and skip_source_ids.")
        }
        // Every decision is read before anything is written.
        struct Asked {
            let cardID: String
            let action: String
            let front: String?
            let back: String?
            let why: String?
            let frontImages: Any?
            let backImages: Any?
            let alsoFrom: Any?
        }
        var asked: [Asked] = []
        for (index, entry) in rawDecisions.enumerated() {
            guard let cardID = Self.trimmedOrNil(entry["card_id"] as? String) else {
                throw MCPError.invalidInput("Nothing was changed. Decision \(index) has no card_id.")
            }
            let action = Self.trimmedOrNil(entry["action"] as? String)?.lowercased() ?? ""
            guard action == "keep" || action == "skip" else {
                throw MCPError.invalidInput("Nothing was changed. Decision \(index)'s action is keep or skip.")
            }
            asked.append(Asked(
                cardID: cardID,
                action: action,
                front: entry["front"] as? String,
                back: entry["back"] as? String,
                why: (entry["why"] as? String) ?? (entry["why"] as? [String])?.joined(separator: "\n"),
                frontImages: entry["front_images"],
                backImages: entry["back_images"],
                alsoFrom: entry["also_from"]
            ))
        }

        let store = try knowledgeStore()
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let snapshot = try await notebookFileStorage.memoryCardReviewSnapshot(
            now: Date(),
            budgetMinutes: nil,
            newPerDay: MemoryCardSettings.newCardsPerDay(),
            deadlines: [],
            scope: nil,
            includesListings: false,
            includesToCheck: true,
            stateDefaults: cardStateDefaults
        )
        let pile = snapshot.toCheck.filter { !excluded.contains($0.sourceID) }
        let byID = Dictionary(pile.map { ($0.cardID, $0) }, uniquingKeysWith: { first, _ in first })

        var decisions: [MemoryCardTriageDecision] = []
        var notFound: [String] = []
        var decidedIDs = Set<String>()
        for entry in asked {
            guard let card = byID[entry.cardID] else {
                notFound.append(entry.cardID)
                continue
            }
            decidedIDs.insert(card.cardID)
            if entry.action == "skip" {
                decisions.append(MemoryCardTriageDecision(card: card, action: .skip))
            } else if entry.front != nil || entry.back != nil || entry.why != nil || entry.frontImages != nil || entry.backImages != nil
                        || (entry.alsoFrom != nil && !(entry.alsoFrom is NSNull)) {
                let edit = MemoryCardEdit(
                    front: entry.front?.trimmingCharacters(in: .whitespacesAndNewlines) ?? card.face.front,
                    back: entry.back?.trimmingCharacters(in: .whitespacesAndNewlines) ?? card.face.back,
                    why: entry.why.map { why in
                        why.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    } ?? card.face.why,
                    frontImages: try entry.frontImages.map {
                        try Self.cardImages($0, cardIndex: 0, field: "front_images", store: store)
                    } ?? card.face.frontImages,
                    backImages: try entry.backImages.map {
                        try Self.cardImages($0, cardIndex: 0, field: "back_images", store: store)
                    } ?? card.face.backImages,
                    alsoFrom: try Self.cardSourceLinks(entry.alsoFrom, cardIndex: 0, store: store, excluded: excluded)
                )
                decisions.append(MemoryCardTriageDecision(card: card, action: .keepEdited(edit)))
            } else {
                decisions.append(MemoryCardTriageDecision(card: card, action: .keep))
            }
        }
        var unknownSources = keepSources.union(skipSources)
        for card in pile where !decidedIDs.contains(card.cardID) {
            if keepSources.contains(card.sourceID) {
                decisions.append(MemoryCardTriageDecision(card: card, action: .keep))
                unknownSources.remove(card.sourceID)
            } else if skipSources.contains(card.sourceID) {
                decisions.append(MemoryCardTriageDecision(card: card, action: .skip))
                unknownSources.remove(card.sourceID)
            }
        }
        for card in pile where decidedIDs.contains(card.cardID) { unknownSources.remove(card.sourceID) }

        let result = await MemoryCardTriageWriter.apply(decisions, storage: notebookFileStorage, defaults: cardStateDefaults)
        await PreferenceStore.flushPendingWrites()
        let remaining = pile.count - result.decidedCount

        var payload: [String: Any] = [
            "kept": result.kept.map { ["card_id": $0.cardID, "item_id": $0.memoryItemID] },
            "skipped": result.skipped,
            "to_check_count": max(0, remaining),
            "message": "Kept \(result.kept.count), skipped \(result.skipped.count). A kept card is first asked the day after it is kept.",
        ]
        if !result.failed.isEmpty {
            payload["refused"] = result.failed.map { ["card_id": $0.cardID, "reason": $0.reason] }
        }
        if !notFound.isEmpty {
            payload["not_found"] = notFound
            payload["not_found_guidance"] = "Not among the cards to check: kept or skipped already, expired 14 days after drafting, or not a card id list_cards returned."
        }
        if !unknownSources.isEmpty {
            payload["sources_with_nothing_to_check"] = unknownSources.sorted()
        }
        return try jsonString(payload)
    }

    // MARK: get_due_cards

    /// The most cards one `get_due_cards` call lists.
    static let maxDueCardsPerCall = 200

    /// The sitting a `record_card_result` without `sitting_id` answers in:
    /// one a local day, so an answer sent again is counted once, as the app's
    /// card review counts one answer per card per sitting.
    static func mcpCardSittingKey(day: String) -> String {
        "mcp-cards-\(day)"
    }

    /// What `get_due_cards` tells an assistant about asking the cards.
    static let dueCardsInstructions = "These are today's cards, in the order ForeverLM's own card review asks them (notebooks needed soon first, then due cards most overdue first, then up to the day's new cards), cut to the learner's daily minutes. Ask one card at a time, in its `ask` wording exactly as written: it is the card's own question, the learner's rewording, or a rewording ForeverLM checked that asks for the same answer; a card with `say_first` says that line before the question. Never show back, why or quote before the learner has answered. Then show the back (and why), let the learner say whether they remembered it, or judge it from what they answered and tell them, and call record_card_result with its card_id, remembered, asked (the wording you asked) and this sitting_id, before the next card. Storage counts one answer per card per sitting and only for a card that is due or new, so recording again is harmless. What is left over waits for another day."

    func getDueCards(notebookID: String?, limit rawLimit: Int?) async throws -> String {
        let limit = max(1, min(rawLimit ?? Self.maxDueCardsPerCall, Self.maxDueCardsPerCall))
        await MemoryCardStateStore.loaded(defaults: cardStateDefaults)
        let store = try knowledgeStore()
        var scope: MemoryCardScope?
        var notebookSummary: [String: Any]?
        if let notebookID = Self.trimmedOrNil(notebookID) {
            let notebook = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
            scope = MemoryCardScope(membership: try store.notebookMembership(notebookID: notebook.id))
            notebookSummary = ["notebook_id": notebook.id, "title": notebook.title]
        }
        let now = Date()
        // A Goal ending or a block on today's calendar puts its notebook's
        // cards first, as in the app; the view model knows both.
        let deadlines = await MainActor.run { AppModelBridge.studio?.memoryCardDeadlines(now: now) ?? [] }
        let snapshot = try await notebookFileStorage.memoryCardReviewSnapshot(
            now: now,
            budgetMinutes: MemoryReviewBudget.minutes,
            newPerDay: MemoryCardSettings.newCardsPerDay(),
            deadlines: deadlines,
            scope: scope,
            includesListings: false,
            includesToCheck: false,
            stateDefaults: cardStateDefaults
        )
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let defaults = cardStateDefaults
        var dealt: [(entry: MemoryCardQueue.Entry, card: MemoryCardSitting.Card)] = []
        for entry in snapshot.today.entries where !entry.item.sources.contains(where: { excluded.contains($0.sourceID) }) {
            let card = MemoryCardSitting.Card.dealt(entry, attempts: snapshot.attemptsByItemID[entry.id] ?? []) { face in
                face.stateDeckID(in: entry.item).flatMap {
                    MemoryCardStateStore.state(cardID: face.cardID, deckID: $0, defaults: defaults)
                }
            }
            if let card { dealt.append((entry, card)) }
        }
        var titles: [String: String] = [:]
        for sourceID in dealt.flatMap({ $0.card.links.map(\.sourceID) }) where titles[sourceID] == nil {
            if let source = try store.loadSourceWithoutContent(sourceID) { titles[sourceID] = source.title }
        }
        let iso = ISO8601DateFormatter()
        let cards: [[String: Any]] = dealt.prefix(limit).map { entry, card in
            var payload: [String: Any] = [
                "item_id": card.itemID,
                "card_id": card.cardID,
                "ask": card.prompt,
                "back": card.back,
                "is_new": card.isNew,
                "reason": entry.bucket.rawValue,
            ]
            if !card.frontImages.isEmpty { payload["front_images"] = card.frontImages.map(\.rubricObject) }
            if !card.backImages.isEmpty { payload["back_images"] = card.backImages.map(\.rubricObject) }
            if !card.why.isEmpty { payload["why"] = card.why.joined(separator: "\n") }
            if let sourceID = card.sourceID {
                payload["source_id"] = sourceID
                if let title = titles[sourceID] { payload["source_title"] = title }
            }
            if let quote = card.quote { payload["quote"] = quote }
            payload["sources"] = Self.cardSourcesPayload(card.links, titles: titles, excluded: excluded)
            if entry.daysOverdue > 0 { payload["days_overdue"] = entry.daysOverdue }
            if !card.isNew { payload["due_since"] = iso.string(from: entry.schedule.dueAt) }
            if let notebookID = entry.notebookID { payload["needed_soon_in_notebook_id"] = notebookID }
            if card.isVariant { payload["reworded"] = true }
            if card.isFirstVariedServe { payload["say_first"] = "Worded differently on purpose \u{2014} same answer." }
            return payload
        }
        let day = MemoryReviewGoal.dayKey(for: now)
        var payload: [String: Any] = [
            "date": day,
            "sitting_id": "\(Self.mcpCardSittingKey(day: day))-\(UUID().uuidString.lowercased().prefix(8))",
            "due_count": dealt.filter { !$0.card.isNew }.count,
            "new_count": dealt.filter { $0.card.isNew }.count,
            "due_left_over": snapshot.today.dueLeftOver,
            "new_left_over": snapshot.today.newLeftOver,
            "cards": cards,
            "budget_minutes": MemoryReviewBudget.minutes,
            "instructions": dealt.isEmpty
                ? "No card is due today\(notebookSummary == nil ? "" : " in this Notebook"). New cards are first asked the day after they are kept; list_cards status to_check lists the cards waiting to be kept."
                : Self.dueCardsInstructions,
        ]
        if dealt.count > limit { payload["listed"] = limit }
        if let notebookSummary { payload["notebook"] = notebookSummary }
        return try jsonString(payload)
    }

    // MARK: record_card_result

    /// A true JSON boolean, never a number: `as? Bool` takes 0 and 1 too.
    static func strictBoolArgument(_ value: Any?, _ key: String) throws -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        throw MCPError.invalidInput("\(key) is true or false.")
    }

    /// The longest wording `record_card_result` records as asked.
    static let maxAskedCharacters = 2_000

    func recordCardResult(
        cardID: String?,
        itemID: String?,
        remembered rawRemembered: Any?,
        asked rawAsked: String?,
        sittingID rawSittingID: String?,
        practice rawPractice: Any?
    ) async throws -> String {
        guard let remembered = try Self.strictBoolArgument(rawRemembered, "remembered") else {
            throw MCPError.invalidInput("Nothing was recorded. remembered is required: true when the learner remembered the card, false when they forgot it.")
        }
        let practice = try Self.strictBoolArgument(rawPractice, "practice") ?? false
        await MemoryCardStateStore.loaded(defaults: cardStateDefaults)
        let store = try knowledgeStore()
        let (item, attempts, face) = try keptCard(cardID: cardID, itemID: itemID, store: store)
        let now = Date()
        let state = face.stateDeckID(in: item).flatMap {
            MemoryCardStateStore.state(cardID: face.cardID, deckID: $0, defaults: cardStateDefaults)
        }
        let asked = Self.trimmedOrNil(rawAsked)
            ?? MemoryCardWording.asked(card: face, state: state, attempts: attempts).text
        guard asked.count <= Self.maxAskedCharacters else {
            throw MCPError.invalidInput("Nothing was recorded. asked is the question as you asked it, at most \(Self.maxAskedCharacters) characters.")
        }
        let sittingKey = Self.trimmedOrNil(rawSittingID) ?? Self.mcpCardSittingKey(day: MemoryReviewGoal.dayKey(for: now))
        guard sittingKey.count <= 200 else {
            throw MCPError.invalidInput("Nothing was recorded. sitting_id is the one get_due_cards returned, at most 200 characters.")
        }
        let outcome = try await notebookFileStorage.recordSelfGradedMemoryCardAttempt(
            memoryItemID: item.id,
            prompt: asked,
            remembered: remembered,
            sessionKey: sittingKey,
            practice: practice,
            at: now
        )
        let schedule = MemoryTutorScheduler.schedule(item: item, attempts: try store.loadMemoryAttempts(memoryItemID: item.id))
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "outcome": Self.outcomeName(outcome),
            "item_id": item.id,
            "card_id": face.cardID,
            "asked": asked,
            "remembered": remembered,
            "sitting_id": sittingKey,
        ]
        switch outcome {
        case .recorded:
            payload["next_due_at"] = iso.string(from: schedule.dueAt)
            payload["message"] = "Recorded as \(remembered ? "remembered" : "forgotten"). The card is next asked from \(iso.string(from: schedule.dueAt))."
        case .alreadyRecorded:
            payload["message"] = "This sitting already recorded an answer to this card, so it is counted once."
        case .notCounted:
            payload["next_due_at"] = iso.string(from: schedule.dueAt)
            payload["message"] = schedule.isNew
                ? "Not recorded: the card is new and first asked from \(iso.string(from: schedule.dueAt)). Pass practice true only when the learner asked to practise it now."
                : "Not recorded: the card is not due until \(iso.string(from: schedule.dueAt)), and an early answer never moves its schedule."
        case .retired:
            payload["message"] = "Not recorded: the card is retired and never asked again."
        }
        return try jsonString(payload)
    }

    private static func outcomeName(_ outcome: MemoryCardAnswerOutcome) -> String {
        switch outcome {
        case .recorded: return "recorded"
        case .alreadyRecorded: return "already_recorded"
        case .notCounted: return "not_counted"
        case .retired: return "retired"
        }
    }

    /// A kept card by the id an assistant was given: its item's id, or its
    /// card id — a drafted card's item is `MemoryTutorIdentity.cardItemID`,
    /// and a card kept when it was missed, like an item from before cards,
    /// has its item's own id. Refused: no id, two ids naming two cards, an id
    /// no card answers to (a card still to check among them), an item that
    /// is no card (a first-review target, recorded with end_review_session),
    /// and a card anchored on a source the library no longer shows.
    private func keptCard(
        cardID rawCardID: String?,
        itemID rawItemID: String?,
        store: KnowledgeStore
    ) throws -> (item: MemoryItem, attempts: [MemoryAttempt], face: MemoryCard) {
        let cardID = Self.trimmedOrNil(rawCardID)
        let itemID = Self.trimmedOrNil(rawItemID)
        guard cardID != nil || itemID != nil else {
            throw MCPError.invalidInput("Pass card_id (or item_id) as get_due_cards or list_cards returns it.")
        }
        let byItem = try itemID.flatMap { try store.loadMemoryItem($0) }
        let byCard = try cardID.flatMap { id in
            try store.loadMemoryItem(id) ?? store.loadMemoryItem(MemoryTutorIdentity.cardItemID(cardID: id))
        }
        if let byItem, let byCard, byItem.id != byCard.id {
            throw MCPError.invalidInput("card_id and item_id name two different cards. Pass one of them.")
        }
        guard let item = byItem ?? byCard else {
            throw MCPError.notFound(
                "No kept card answers to \(cardID ?? itemID ?? ""). Pass a card_id or item_id get_due_cards or list_cards status kept returned; a card still to check (list_cards status to_check) is kept, edited or skipped with triage_cards first, on the learner's word."
            )
        }
        let attempts = try store.loadMemoryAttempts(memoryItemID: item.id)
        guard let face = MemoryCard.face(of: item, attempts: attempts) else {
            throw MCPError.invalidInput(
                "\(item.id) is a memory item with no card to ask. memory_review lists such items, and end_review_session records their answers."
            )
        }
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        guard !item.sources.contains(where: { excluded.contains($0.sourceID) }) else {
            throw MCPError.notFound("\(face.cardID) stands on a source the library no longer shows, so it is not asked.")
        }
        return (item, attempts, face)
    }

    // MARK: practice_cards

    /// The most cards one `practice_cards` call deals: `list_cards`' most.
    static let maxPracticeCardsPerCall = 500

    /// The longest `title` `practice_cards` takes.
    static let maxPracticeTitleCharacters = 120

    /// The app's card review over the kept cards an assistant chose
    /// (`StudioViewModel.startChosenCardPractice`), in the window the learner
    /// last used, brought to the front. The cards are dealt there and
    /// answered there; this returns only what was dealt.
    func practiceCards(cardIDs rawCardIDs: Any?, title rawTitle: String?) async throws -> String {
        guard let rawIDs = rawCardIDs as? [Any] else {
            throw MCPError.invalidInput("card_ids is required: the card_id of each kept card to practise, from list_cards status kept.")
        }
        var cardIDs: [String] = []
        var seen = Set<String>()
        for raw in rawIDs {
            guard let id = Self.trimmedOrNil(raw as? String) else {
                throw MCPError.invalidInput("Each card_ids entry is a card_id string from list_cards status kept.")
            }
            if seen.insert(id).inserted { cardIDs.append(id) }
        }
        guard !cardIDs.isEmpty else {
            throw MCPError.invalidInput("card_ids is empty. Choose the kept cards to practise from list_cards status kept.")
        }
        guard cardIDs.count <= Self.maxPracticeCardsPerCall else {
            throw MCPError.invalidInput("One practice takes at most \(Self.maxPracticeCardsPerCall) cards; \(cardIDs.count) were passed.")
        }
        guard let title = Self.trimmedOrNil(rawTitle) else {
            throw MCPError.invalidInput("title is required: what the cards are about, in a few words (Mitochondria).")
        }
        guard title.count <= Self.maxPracticeTitleCharacters else {
            throw MCPError.invalidInput("title is a few words, at most \(Self.maxPracticeTitleCharacters) characters.")
        }
        await MemoryCardStateStore.loaded(defaults: cardStateDefaults)
        let studio = try await MainActor.run { try AppModelBridge.requireStudio() }
        await MainActor.run { Self.bringActiveStudioWindowForward() }
        let started: StudioViewModel.ChosenCardPracticeStart
        do {
            started = try await studio.startChosenCardPractice(cardIDs: cardIDs, title: title)
        } catch let refusal as StudioViewModel.ChosenCardPracticeRefusal {
            throw MCPError.invalidInput(refusal.message)
        }
        var payload: [String: Any] = [
            "opened": "card_review",
            "title": title,
            "cards": started.answerable + started.notDueYet,
            "due_or_new": started.answerable,
            "not_due_yet": started.notDueYet,
            "message": "The card review is open in ForeverLM's window with these cards, as practice: the learner answers each there, the due and new cards first, whose answers count, then the ones not due yet, whose answers never move their schedule.",
        ]
        if !started.unknownCardIDs.isEmpty {
            payload["not_found"] = started.unknownCardIDs
        }
        return try jsonString(payload)
    }

    // MARK: update_card

    func updateCard(
        cardID: String?,
        itemID: String?,
        front rawFront: String?,
        back rawBack: String?,
        why rawWhy: Any?,
        frontImages rawFrontImages: Any? = nil,
        backImages rawBackImages: Any? = nil,
        startOver rawStartOver: Any?,
        alwaysAsk rawAlwaysAsk: Any?,
        retire rawRetire: Any?
    ) async throws -> String {
        let startOverAsked = try Self.strictBoolArgument(rawStartOver, "start_over") ?? false
        let alwaysAsk = try Self.strictBoolArgument(rawAlwaysAsk, "always_ask")
        let retire = try Self.strictBoolArgument(rawRetire, "retire") ?? false
        var front = rawFront.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var back = rawBack.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let why: [String]?
        if rawWhy == nil || rawWhy is NSNull {
            why = nil
        } else if let text = rawWhy as? String {
            why = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else if let lines = rawWhy as? [String] {
            why = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            throw MCPError.invalidInput("Nothing was changed. why is one line, or lines, on why the back is right.")
        }
        let hasFrontImages = rawFrontImages != nil && !(rawFrontImages is NSNull)
        let hasBackImages = rawBackImages != nil && !(rawBackImages is NSNull)
        guard front != nil || back != nil || why != nil || hasFrontImages || hasBackImages || startOverAsked || alwaysAsk != nil || retire else {
            throw MCPError.invalidInput("Nothing was changed. Pass front, back, why, front_images, back_images, start_over, always_ask or retire.")
        }
        guard !retire || (front == nil && back == nil && why == nil && !hasFrontImages && !hasBackImages && !startOverAsked && alwaysAsk == nil) else {
            throw MCPError.invalidInput("Nothing was changed. retire takes no other change: a retired card is never asked again.")
        }
        if front?.isEmpty == true || back?.isEmpty == true {
            throw MCPError.invalidInput("Nothing was changed. A card needs a front and a back; leave out the one you are not changing.")
        }

        await MemoryCardStateStore.loaded(defaults: cardStateDefaults)
        let store = try knowledgeStore()
        let kept: (item: MemoryItem, attempts: [MemoryAttempt], face: MemoryCard)
        do {
            kept = try keptCard(cardID: cardID, itemID: itemID, store: store)
        } catch MCPError.notFound(let message) {
            // Not a kept card: the card to check in front of the learner may
            // be the one meant, and pictures are all that can be put on it.
            if hasFrontImages || hasBackImages, let cardID = Self.trimmedOrNil(cardID), itemID == nil {
                guard front == nil, back == nil, why == nil, !startOverAsked, alwaysAsk == nil, !retire else {
                    throw MCPError.invalidInput("Nothing was changed. \(cardID) is still to check, and only its pictures can be changed here: front_images or back_images. Its words are kept, edited or skipped with triage_cards, on the learner's word.")
                }
                let frontImages = hasFrontImages ? try Self.cardImages(rawFrontImages, cardIndex: 0, field: "front_images", store: store) : nil
                let backImages = hasBackImages ? try Self.cardImages(rawBackImages, cardIndex: 0, field: "back_images", store: store) : nil
                if await Self.holdPicturesOnCardToCheck(cardID: cardID, front: frontImages, back: backImages) {
                    var faces: [String] = []
                    if frontImages != nil { faces.append("the question") }
                    if backImages != nil { faces.append("the answer") }
                    return try jsonString([
                        "card_id": cardID,
                        "held": true,
                        "message": "The card is still to check, so nothing was written: its pictures on \(faces.joined(separator: " and ")) are held with it in the pane, and the learner's Keep carries them (Skip drops them).",
                    ] as [String: Any])
                }
            }
            throw MCPError.notFound(message)
        }
        let (item, attempts, face) = kept
        let frontImages = hasFrontImages
            ? try Self.cardImages(rawFrontImages, cardIndex: 0, field: "front_images", store: store)
            : nil
        let backImages = hasBackImages
            ? try Self.cardImages(rawBackImages, cardIndex: 0, field: "back_images", store: store)
            : nil
        guard let listing = MemoryCardListing(item: item, attempts: attempts) else {
            throw MCPError.invalidInput("\(item.id) is a memory item with no card to change.")
        }
        if retire {
            let wasRetired = item.status == .retired
            if !wasRetired { try await notebookFileStorage.retireMemoryCard(memoryItemID: item.id) }
            return try jsonString([
                "card_id": face.cardID,
                "item_id": item.id,
                "retired": true,
                "message": wasRetired ? "The card was retired already." : "Retired: the card is never asked again. Its answers stay.",
            ])
        }
        guard item.status == .active else {
            throw MCPError.invalidInput("Nothing was changed. \(face.cardID) is retired, and a retired card is never asked.")
        }

        let defaults = cardStateDefaults
        // New words pass the wording gate (`CardWordingGate`) before they are
        // written: words that point at the source unnamed are reworded once,
        // or the change is refused with the reason. A new front alone may
        // change only the front: the card's answer is its identity.
        var rewordedByCheck = false
        if front != nil || back != nil {
            let sourceTitle = try listing.sourceIDs.first.flatMap { try store.loadSourceWithoutContent($0)?.title } ?? "its source"
            let proposed = CardWordingCheck.Face(
                front: front ?? MemoryCardEditWriter.wording(listing, defaults: defaults),
                back: back ?? face.back,
                sourceTitle: sourceTitle
            )
            let outcome: CardWordingCheck.Outcome
            do {
                outcome = try await CardWordingGate.screen(
                    [proposed],
                    answersMayChange: back != nil,
                    usage: AIUsageSource(id: listing.sourceIDs.first ?? item.id, type: "memory_card", title: sourceTitle),
                    backend: CardWordingGate.backend()
                ).first ?? .passed
            } catch {
                throw MCPError.invalidInput("Nothing was changed. The card's wording could not be checked: \(error.localizedDescription)")
            }
            switch outcome {
            case .passed:
                break
            case .reworded(let newFront, let newBack):
                rewordedByCheck = true
                if front != nil || newFront != proposed.front { front = newFront }
                if back != nil { back = newBack }
            case .failed(let reason):
                throw MCPError.invalidInput("Nothing was changed. \(reason) Ask about the subject itself, or name the source.")
            }
        }
        let startsOver = startOverAsked
            || (back.map { $0 != face.back } ?? false)
            || (why.map { $0 != face.why } ?? false)
            || (frontImages.map { $0 != face.frontImages } ?? false)
            || (backImages.map { $0 != face.backImages } ?? false)
        var resultCardID = face.cardID
        var resultItemID = item.id
        var changes: [String] = []
        if startsOver {
            let currentWording = MemoryCardEditWriter.wording(listing, defaults: defaults)
            let edit = MemoryCardEdit(
                front: front ?? currentWording,
                back: back ?? face.back,
                why: why ?? face.why,
                frontImages: frontImages ?? face.frontImages,
                backImages: backImages ?? face.backImages
            )
            let revision = try await MemoryCardEditWriter.startOver(listing, edit: edit, storage: notebookFileStorage, defaults: defaults)
            resultCardID = revision.cardID
            resultItemID = revision.item.id
            changes.append("started over as a new card, first asked tomorrow; its answers so far stay with the old one")
        } else if let front {
            if await MemoryCardEditWriter.reword(listing, front: front, defaults: defaults) {
                changes.append(front == face.front ? "asked in the words it was kept with again" : "reworded: asked in the new front, its schedule untouched")
            }
        }
        if let alwaysAsk, let deckID = MemoryCardEditWriter.stateDeckID(listing) {
            let current = MemoryCardStateStore.state(cardID: resultCardID, deckID: deckID, defaults: defaults)?.alwaysAsk ?? false
            if current != alwaysAsk {
                await MemoryCardStateStore.setAlwaysAsk(
                    alwaysAsk,
                    cardID: resultCardID,
                    memoryItemID: resultItemID,
                    deckID: deckID,
                    isFromBeforeCards: !startsOver && face.origin == .legacy,
                    defaults: defaults
                )
                changes.append(alwaysAsk ? "always asked in its own words" : "its wording may vary again")
            }
        }
        await PreferenceStore.flushPendingWrites()
        await MemoryCardStateStore.settled(defaults: defaults)

        if rewordedByCheck {
            changes.append("reworded by ForeverLM so it names what it is about rather than pointing at its source unnamed")
        }
        var payload: [String: Any] = [
            "card_id": resultCardID,
            "item_id": resultItemID,
            "changed": !changes.isEmpty,
            "message": changes.isEmpty ? "Nothing changed: the card already reads that way." : "The card was \(changes.joined(separator: "; ")).",
        ]
        if startsOver {
            payload["started_over"] = true
            payload["previous_card_id"] = face.cardID
            payload["previous_item_id"] = item.id
        }
        if let deckID = MemoryCardEditWriter.stateDeckID(listing) {
            let state = MemoryCardStateStore.state(cardID: resultCardID, deckID: deckID, defaults: defaults)
            payload["always_ask"] = state?.alwaysAsk ?? false
            if !startsOver { payload["ask"] = face.wording(state: state) }
        }
        if startsOver, let newItem = try store.loadMemoryItem(resultItemID), let newFace = MemoryCard(storedIn: newItem) {
            payload["ask"] = newFace.front
        }
        return try jsonString(payload)
    }
}

// MARK: - Pictures on the card to check in front of the learner

extension MCPDataStore {
    /// Puts pictures on the card to check that a Memory pane shows in front of
    /// the learner, or on one of the others the pane still has waiting: the chat
    /// beside it was asked to ("can you add it to the card?"), and the learner
    /// may have turned to another card since. The card is not decided, so
    /// nothing is written: the pictures are held with the card in the window
    /// (`StudioWindowState.memoryCardPictures`) and a Keep carries them, as it
    /// carries a drawn one. False when no window has that card waiting.
    @MainActor
    static func holdPicturesOnCardToCheck(
        cardID: String,
        front: [MemoryCardImage]?,
        back: [MemoryCardImage]?
    ) -> Bool {
        let shown = StudioWindowRegistry.shared.states.filter {
            $0.memoryPaneSection == .toCheck
                && ($0.memoryCardOnScreen?.id == cardID || $0.memoryCardsWaitingIDs.contains(cardID))
        }
        for state in shown {
            var held = state.memoryCardPictures[cardID] ?? StudioWindowState.MemoryCardPictures()
            if let front { held.front = MemoryCardImage.faceList(front) }
            if let back { held.back = MemoryCardImage.faceList(back) }
            state.memoryCardPictures[cardID] = held
        }
        return !shown.isEmpty
    }
}
