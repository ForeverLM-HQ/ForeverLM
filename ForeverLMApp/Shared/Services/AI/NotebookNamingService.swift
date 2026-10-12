import Foundation

/// The Mac's reads and writes of the `notebook.naming.<notebookID>` rows
/// (`NotebookNaming`).
enum NotebookNamingRows {
    /// A test's own defaults, bound for the task that runs it (as
    /// `NotebookChatSelection.overrideDefaults`). While bound, writes go to
    /// the suite and never to the sync rail.
    @TaskLocal static var overrideDefaults: DefaultsOverride? = nil

    /// A Sendable carrier for `overrideDefaults`; the suite is only ever
    /// touched by the task that bound it.
    struct DefaultsOverride: @unchecked Sendable {
        let defaults: UserDefaults
    }

    private static var defaults: UserDefaults { overrideDefaults?.defaults ?? .standard }

    static func mark(notebookID: String) -> NotebookNaming.Mark? {
        NotebookNaming.Mark.decoded(defaults.object(forKey: NotebookNaming.preferenceKey(notebookID: notebookID)))
    }

    /// Writes a notebook's row; nil removes it, which is a name ForeverLM
    /// leaves alone from then on.
    static func setMark(_ mark: NotebookNaming.Mark?, notebookID: String) {
        let key = NotebookNaming.preferenceKey(notebookID: notebookID)
        if let override = overrideDefaults {
            if let mark {
                override.defaults.set(mark.encoded, forKey: key)
            } else {
                override.defaults.removeObject(forKey: key)
            }
            return
        }
        // `PreferenceStore` drops a write that changes nothing, so the same
        // row written again never becomes a CloudKit save.
        if let mark {
            PreferenceStore.set(mark.encoded, forKey: key)
        } else {
            PreferenceStore.remove(forKey: key)
        }
    }

    /// Every row, by Notebook id, in one scan. The keys are built at runtime,
    /// so one scan of the defaults finds them.
    static func marks() -> [String: NotebookNaming.Mark] {
        var result: [String: NotebookNaming.Mark] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(NotebookNaming.preferenceKeyPrefix) {
            let notebookID = String(key.dropFirst(NotebookNaming.preferenceKeyPrefix.count))
            guard !notebookID.isEmpty, let mark = NotebookNaming.Mark.decoded(value) else { continue }
            result[notebookID] = mark
        }
        return result
    }
}

enum NotebookNamingError: LocalizedError, Equatable {
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): return message
        }
    }
}

/// Reads what a notebook holds and asks the Notebook Naming model for its
/// name. Writing it is the view model's (`StudioViewModel.nameNotebook`),
/// which checks the row again first.
struct NotebookNamingService: Sendable {
    /// Asks the model. The shipped one is `liveNamer`; a test hands in a
    /// canned answer.
    typealias Namer = @Sendable (_ request: NotebookNaming.Request, _ totalSources: Int) async throws -> NotebookNaming.Answer

    /// A chat in the notebook, as the view model lists it.
    struct Chat: Sendable {
        var id: String
        var title: String
    }

    let storage: StorageService
    let name: Namer

    /// The Notebook Naming model from Settings, resolved before any work.
    /// Without one (signed out, no consent to background AI, no balance) the
    /// notebook keeps its placeholder and says why.
    static func liveNamer(aiService: AIService) throws -> Namer {
        let task = AITask.notebookNaming
        guard let config = KeychainService.resolveConfig(for: task) else {
            throw NotebookNamingError.notConfigured(
                KeychainService.backgroundAIUnavailableMessage(for: task)
                    ?? "ForeverLM can't name this notebook until AI is set up in Settings."
            )
        }
        return { request, totalSources in
            try await aiService.nameNotebook(request, totalSources: totalSources, config: config)
        }
    }

    /// The model's name for the notebook, from up to
    /// `NotebookNaming.maximumSources` of `sourceIDs` (in the notebook's
    /// order) with the opening of each one's text, and the first answered
    /// exchange of up to `NotebookNaming.maximumExchanges` of `chats`.
    func answer(
        notebookID: String,
        currentTitle: String,
        instructions: String?,
        sources: [(id: String, title: String, kind: String)],
        chats: [Chat]
    ) async throws -> NotebookNaming.Answer {
        var briefs: [NotebookNaming.Request.Source] = []
        for source in sources.prefix(NotebookNaming.maximumSources) {
            let text = await storage.loadSourceContent(source.id) ?? ""
            briefs.append(.init(
                title: source.title,
                kind: source.kind,
                opening: String(text.prefix(NotebookNaming.sourceOpeningCharacters * 2))
            ))
        }
        var exchanges: [NotebookNaming.Request.Exchange] = []
        for chat in chats where exchanges.count < NotebookNaming.maximumExchanges {
            let recorded = try await storage.loadReviewSessionExchanges(sessionID: chat.id)
                .sorted { $0.sequenceNumber < $1.sequenceNumber }
            guard let first = recorded.first(where: {
                $0.userAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }), let learner = first.userAnswer else { continue }
            let reply = [first.evaluation, first.question]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            exchanges.append(.init(chatTitle: chat.title, learner: learner, reply: reply))
        }
        try Task.checkCancellation()
        let request = NotebookNaming.Request(
            notebookID: notebookID,
            currentTitle: currentTitle,
            instructions: instructions,
            sources: briefs,
            exchanges: exchanges
        )
        return try await name(request, sources.count)
    }
}

extension AIService {
    /// Asks for a notebook's name and card line. The answer is read by
    /// `NotebookNaming.answer(from:)`; this only asks.
    func nameNotebook(
        _ request: NotebookNaming.Request,
        totalSources: Int,
        config: AITaskConfig
    ) async throws -> NotebookNaming.Answer {
        let system = AITask.notebookNaming.effectivePrompt ?? Prompts.notebookNaming
        let user = NotebookNaming.userMessage(request, totalSources: totalSources)
        // A background call: a dropped connection or a busy model is waited
        // out, and a reply that is not a name moves on to the backup models.
        let response = try await AIBackgroundRetry.run(config: config) { config in
            try await self.call(
                config: config,
                system: system,
                user: user,
                maxTokens: 400,
                temperature: 0.3,
                jsonMode: true,
                validateResponse: { _ = try NotebookNaming.answer(from: $0) },
                sourceTitle: request.currentTitle,
                subjectID: request.notebookID
            )
        }
        do {
            return try NotebookNaming.answer(from: response)
        } catch {
            throw AIError.invalidResponse
        }
    }
}
