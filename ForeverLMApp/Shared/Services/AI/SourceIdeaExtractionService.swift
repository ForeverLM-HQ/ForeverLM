import Foundation

/// What the extraction model returns for one idea, before the app gives it an
/// identity and anchors it to the learner's highlights.
/// Which sources the model could not turn into ideas, and when.
///
/// Extraction is billed per attempt, and the Memory row extracts for every
/// cohort source that has no ideas — so a source whose text the model keeps
/// answering with malformed JSON (Evo 2: "Invalid AI response"
/// on every click) was billed again on every click and skipped from every
/// review. A hard failure is remembered against the text it failed on, per
/// device, and not retried for a day; a change to the text, or the day
/// passing, clears the way. Transport failures are not remembered: a rate
/// limit at 7:00 says nothing about 7:05.
enum SourceIdeaExtractionFailures {
    static let key = Prefs.Memory.ideaExtractionFailures.name
    static let retryInterval: TimeInterval = MemoryTutorScheduler.secondsPerDay

    struct Record: Equatable, Sendable {
        let contentHash: String
        let failedAt: Date
        let message: String
    }

    /// A failure of the *content*, not of the connection: the model answered and
    /// the answer was unusable, or it found nothing to say.
    static func isHardFailure(_ error: Error) -> Bool {
        if let extraction = error as? SourceIdeaExtractionError {
            if case .noIdeas = extraction { return true }
            return false
        }
        if let ai = error as? AIError {
            if case .invalidResponse = ai { return true }
            return false
        }
        return error is DecodingError
    }

    static func record(
        sourceID: String,
        contentHash: String,
        message: String,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var entries = pruned(entries(from: defaults), now: now)
        entries[sourceID] = [
            "hash": contentHash,
            "at": now.timeIntervalSinceReferenceDate,
            "message": String(message.prefix(300)),
        ]
        defaults.set(entries, forKey: key)
    }

    /// The remembered failure that still applies: same text, within the retry
    /// interval. Nil means try.
    static func recent(
        sourceID: String,
        contentHash: String,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Record? {
        guard let record = record(from: entries(from: defaults)[sourceID]) else { return nil }
        guard record.contentHash == contentHash else { return nil }
        guard now.timeIntervalSince(record.failedAt) < retryInterval else { return nil }
        return record
    }

    static func clear(sourceID: String, defaults: UserDefaults = .standard) {
        var entries = entries(from: defaults)
        guard entries.removeValue(forKey: sourceID) != nil else { return }
        defaults.set(entries, forKey: key)
    }

    // MARK: - Plumbing

    private static func entries(from defaults: UserDefaults) -> [String: [String: Any]] {
        defaults.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
    }

    private static func record(from entry: [String: Any]?) -> Record? {
        guard let entry,
              let hash = entry["hash"] as? String,
              let at = entry["at"] as? Double else { return nil }
        return Record(
            contentHash: hash,
            failedAt: Date(timeIntervalSinceReferenceDate: at),
            message: entry["message"] as? String ?? "extraction failed"
        )
    }

    /// Expired entries are dropped on the next write so the dictionary tracks
    /// today's problems rather than every source that ever failed.
    static func pruned(_ entries: [String: [String: Any]], now: Date) -> [String: [String: Any]] {
        entries.filter { _, entry in
            guard let at = entry["at"] as? Double else { return false }
            return now.timeIntervalSinceReferenceDate - at < retryInterval
        }
    }
}

extension AIService {

    /// The response budget of one extraction request.
    static let sourceIdeaExtractionMaxTokens = 3_000

    /// The source's ideas, as drafts, read from its whole text. The caller
    /// owns identity.
    ///
    /// Nothing of the text is left out (product owner, 2026-09-23: source text is
    /// never truncated). A text the extraction model's window takes whole is
    /// one billed call; a longer one is read in consecutive parts that each
    /// fit (`sourceIdeaTextParts`), one billed call per part, and the parts'
    /// drafts are merged (`SourceIdeaDrafting.mergedDrafts`). A model that
    /// publishes no window is sent the whole text in one request, as the
    /// paper cleanup sends a whole paper (`PaperContentPreparationService.cleanupRequestChunks`),
    /// and answers for its own limit.
    ///
    /// `systemPrompt` replaces the source prompt for material that is not a
    /// source — a chat's transcript reads under `Prompts.chatIdeaExtraction`.
    func extractSourceIdeas(
        source: AIUsageSource,
        sourceText: String,
        highlights: [String],
        config: AITaskConfig,
        systemPrompt: String? = nil
    ) async throws -> [SourceIdeaDraft] {
        let system = systemPrompt ?? AITask.sourceIdeaExtraction.effectivePrompt ?? Prompts.sourceIdeaExtraction
        // The window `call` fits the request to is the routed model's.
        let routed = KeychainService.routedTextConfig(config)
        let parts = try Self.sourceIdeaTextParts(
            title: source.title,
            sourceType: source.type,
            highlightLines: highlights,
            sourceText: sourceText,
            system: system,
            inputBudget: Self.inputCharacterBudget(
                provider: routed.provider,
                model: routed.model,
                requestedMaxTokens: Self.sourceIdeaExtractionMaxTokens
            )
        )
        var drafts: [[SourceIdeaDraft]] = []
        for (index, part) in parts.enumerated() {
            let user = SourceIdeaDrafting.userMessage(
                title: source.title,
                sourceType: source.type,
                highlightLines: highlights,
                sourceText: part,
                part: parts.count > 1 ? SourceIdeaDrafting.Part(index: index, count: parts.count) : nil
            )
            let response = try await AIUsageAttribution.withSource(source) {
                try await call(
                    config: config,
                    system: system,
                    user: user,
                    maxTokens: Self.sourceIdeaExtractionMaxTokens,
                    temperature: 0.2
                )
            }
            let decoded: SourceIdeaExtractionResponse = try Self.decodeCohortJSON(response)
            drafts.append(decoded.ideas)
        }
        return SourceIdeaDrafting.mergedDrafts(drafts)
    }

    /// The text as the extraction requests carry it: whole when the request
    /// fits `inputBudget`, else in consecutive parts sized so that every
    /// part's request fits it exactly as `budgetedOneShotRequest` measures a
    /// request, so `call` never trims one. Together the parts are the whole
    /// text.
    ///
    /// - Parameter inputBudget: request characters the model accepts
    ///   (`inputCharacterBudget`); nil when it publishes no window, and then
    ///   the whole text is one part.
    static func sourceIdeaTextParts(
        title: String,
        sourceType: String,
        highlightLines: [String],
        sourceText: String,
        system: String,
        inputBudget: Int?
    ) throws -> [String] {
        guard let inputBudget else { return [sourceText] }
        func requestCharacters(_ user: String) -> Int {
            system.count + user.count + perMessageOverheadChars
        }
        let whole = SourceIdeaDrafting.userMessage(
            title: title,
            sourceType: sourceType,
            highlightLines: highlightLines,
            sourceText: sourceText
        )
        guard requestCharacters(whole) > inputBudget else { return [sourceText] }
        // Reserve the fixed cost of a part's request with a wider part label
        // than any source reaches; the rest belongs to the text.
        let scaffold = requestCharacters(SourceIdeaDrafting.userMessage(
            title: title,
            sourceType: sourceType,
            highlightLines: highlightLines,
            sourceText: "",
            part: SourceIdeaDrafting.Part(index: 999_998, count: 999_999)
        ))
        let textBudget = inputBudget - scaffold
        guard textBudget > 0 else {
            throw AIError.apiError(
                "Idea Extraction's instructions and highlights exceed this model's context window."
            )
        }
        return SourceIdeaDrafting.sourceTextParts(sourceText, characterBudget: textBudget)
    }
}

/// Extracts a source's ideas once, when a review needs them or a source has
/// just been finished, and never over the library at large. Concurrent
/// requests for one source share a generation; a source whose stored ideas
/// already match its text costs nothing.
actor SourceIdeaExtractionService {
    private let storage: StorageService
    private let aiService: AIService
    private var inFlight: [String: Task<[SourceIdea], Error>] = [:]

    init(storage: StorageService, aiService: AIService) {
        self.storage = storage
        self.aiService = aiService
    }

    /// Start extraction now without waiting for it, and swallow the failure:
    /// the caller is guessing that this source will be reviewed, and a guess
    /// that cannot be prepared must not surface as an error.
    nonisolated func warm(sourceID: String) {
        Task(priority: .utility) { [weak self] in
            _ = try? await self?.prepare(sourceID: sourceID)
        }
    }

    /// The source's active ideas, extracted now if its text has none yet or has
    /// changed since. The old generation is retired by the store, never deleted.
    func prepare(sourceID: String) async throws -> [SourceIdea] {
        if let task = inFlight[sourceID] {
            return try await task.value
        }
        let task = Task { [storage, aiService] in
            try await Self.extract(sourceID: sourceID, storage: storage, aiService: aiService)
        }
        inFlight[sourceID] = task
        defer { inFlight[sourceID] = nil }
        return try await task.value
    }

    private static func extract(
        sourceID: String,
        storage: StorageService,
        aiService: AIService
    ) async throws -> [SourceIdea] {
        let article = try await storage.loadSourceWithoutContent(sourceID)
        // A cohort id that names no source may name a chat the learner had
        // (`ReviewableChat`): its ideas come from its transcript.
        if article == nil, let chat = try await storage.loadReviewableChat(sessionID: sourceID) {
            return try await extractChatIdeas(chat, storage: storage, aiService: aiService)
        }
        let title = article?.title.isEmpty == false ? article!.title : sourceID
        // An audio overview's script retells its notebook's sources; ideas
        // drawn from it would repeat theirs as a source of its own. Reading
        // or hearing it to the end (`setArticleRead` warming this service)
        // must not bill an extraction, and nothing reviews it.
        if let article, TextToSpeechPreparationPolicy.isAudioOverviewScript(url: article.url) {
            throw SourceIdeaExtractionError.retelling(title)
        }
        guard let content = await storage.loadSourceContent(sourceID),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceIdeaExtractionError.noReadableText(title)
        }
        let contentHash = PaperContentPreparationService.sha256(content)
        if try await storage.sourceIdeaContentHash(sourceID: sourceID) == contentHash {
            let existing = try await storage.loadSourceIdeas(sourceIDs: [sourceID])[sourceID] ?? []
            if !existing.isEmpty { return existing }
        }
        if let failure = SourceIdeaExtractionFailures.recent(sourceID: sourceID, contentHash: contentHash) {
            throw SourceIdeaExtractionError.recentlyFailed(title, failure.message)
        }
        guard let config = KeychainService.resolveConfig(for: .sourceIdeaExtraction) else {
            throw SourceIdeaExtractionError.noConfiguredModel
        }

        let highlights = (try? await storage.sourceHighlights(sourceID: sourceID)) ?? []
        let highlightLines = SourceIdeaDrafting.highlightLines(highlights)

        let ideas: [SourceIdea]
        do {
            let drafts = try await aiService.extractSourceIdeas(
                source: AIUsageSource(
                    id: sourceID,
                    type: article?.sourceType.rawValue ?? "unknown",
                    title: title
                ),
                // The whole text, the same text `contentHash` names.
                sourceText: content,
                highlights: highlightLines,
                config: config
            )
            ideas = Self.ideas(
                from: drafts,
                sourceID: sourceID,
                contentHash: contentHash,
                highlights: highlights
            )
            guard !ideas.isEmpty else { throw SourceIdeaExtractionError.noIdeas(title) }
        } catch {
            // Remember what the model could not do with this text, so the next
            // review does not bill the same failing call. A dropped connection
            // is not remembered; it says nothing about the text.
            if SourceIdeaExtractionFailures.isHardFailure(error) {
                SourceIdeaExtractionFailures.record(
                    sourceID: sourceID,
                    contentHash: contentHash,
                    message: error.localizedDescription
                )
            }
            throw error
        }
        SourceIdeaExtractionFailures.clear(sourceID: sourceID)
        try await storage.replaceSourceIdeas(sourceID: sourceID, contentHash: contentHash, ideas: ideas)
        return try await storage.loadSourceIdeas(sourceIDs: [sourceID])[sourceID] ?? ideas
    }

    /// A chat's ideas: the same generation rules as a source's, over the
    /// transcript, under the chat prompt, with the session as every idea's
    /// origin. Stored under the session id, which is what the cohort, the
    /// contour grade and the ladder all key on for a chat.
    private static func extractChatIdeas(
        _ chat: ReviewableChatTranscript,
        storage: StorageService,
        aiService: AIService
    ) async throws -> [SourceIdea] {
        let sessionID = chat.sessionID
        guard !chat.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceIdeaExtractionError.noReadableText(chat.title)
        }
        let contentHash = SourceIdeaDrafting.contentHash(chat.text)
        if try await storage.sourceIdeaContentHash(sourceID: sessionID) == contentHash {
            let existing = try await storage.loadSourceIdeas(sourceIDs: [sessionID])[sessionID] ?? []
            if !existing.isEmpty { return existing }
        }
        if let failure = SourceIdeaExtractionFailures.recent(sourceID: sessionID, contentHash: contentHash) {
            throw SourceIdeaExtractionError.recentlyFailed(chat.title, failure.message)
        }
        guard let config = KeychainService.resolveConfig(for: .sourceIdeaExtraction) else {
            throw SourceIdeaExtractionError.noConfiguredModel
        }

        let ideas: [SourceIdea]
        do {
            let drafts = try await aiService.extractSourceIdeas(
                source: AIUsageSource(id: sessionID, type: ReviewableChat.sourceType, title: chat.title),
                sourceText: chat.text,
                highlights: [],
                config: config,
                systemPrompt: Prompts.chatIdeaExtraction
            )
            ideas = SourceIdeaDrafting.ideas(
                from: drafts,
                sourceID: sessionID,
                contentHash: contentHash,
                highlights: [],
                originSessionID: sessionID
            )
            guard !ideas.isEmpty else { throw SourceIdeaExtractionError.noIdeas(chat.title) }
        } catch {
            if SourceIdeaExtractionFailures.isHardFailure(error) {
                SourceIdeaExtractionFailures.record(
                    sourceID: sessionID,
                    contentHash: contentHash,
                    message: error.localizedDescription
                )
            }
            throw error
        }
        SourceIdeaExtractionFailures.clear(sourceID: sessionID)
        try await storage.replaceSourceIdeas(sourceID: sessionID, contentHash: contentHash, ideas: ideas)
        return try await storage.loadSourceIdeas(sourceIDs: [sessionID])[sessionID] ?? ideas
    }

    /// Identity and weighting live in `SourceIdeaDrafting`, which the phone
    /// compiles too; these forward so the Mac's tests and call sites keep
    /// their names.
    static func ideas(
        from drafts: [SourceIdeaDraft],
        sourceID: String,
        contentHash: String,
        highlights: [SourceHighlight],
        now: Date = Date()
    ) -> [SourceIdea] {
        SourceIdeaDrafting.ideas(from: drafts, sourceID: sourceID, contentHash: contentHash, highlights: highlights, now: now)
    }

    static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        SourceIdeaDrafting.overlaps(lhs, rhs)
    }
}
