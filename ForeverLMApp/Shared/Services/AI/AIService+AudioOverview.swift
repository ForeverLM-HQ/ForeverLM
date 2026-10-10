import Foundation

extension AIService {

    /// The response budget the overview writer asks for: the longest script
    /// (a longer Deep dive, about 3,100 words) with room for its JSON.
    static let audioOverviewWriterMaxTokens = 10_000

    /// Write a notebook's audio overview from the turn the generator built.
    /// The turn is sent exactly as given: the generator sized it against the
    /// route's window and checked that nothing would be cut on the way. Never
    /// answered from the response cache: Make again with the same options
    /// asks for a new script, not the one already saved.
    func writeAudioOverview(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        config: AITaskConfig
    ) async throws -> AudioOverviewDraft {
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: Self.audioOverviewWriterMaxTokens,
            temperature: 0.6,
            allowsResponseCache: false,
            jsonMode: true,
            sourceTitle: notebookTitle,
            subjectID: notebookID,
            subjectType: "notebook"
        )
        let draft: AudioOverviewDraft
        do {
            draft = try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
        guard draft.isUsable else {
            throw AudioOverviewGenerationError.emptyScript
        }
        return draft
    }

    /// Condense one part of a source too long for the writer's window. The
    /// part is the source's own consecutive text, never a sample of it, and
    /// it is sent whole: a request the central one-shot trim would cut is
    /// refused before it is sent.
    func condenseForAudioOverview(
        _ part: AudioOverviewCondensePart,
        config: AITaskConfig
    ) async throws -> String {
        struct Account: Decodable { let account: String }
        let routed = KeychainService.routedTextConfig(config)
        let budgeted = Self.budgetedOneShotRequest(
            provider: routed.provider,
            model: routed.model,
            system: Prompts.audioOverviewCondenser,
            user: part.userMessage,
            requestedMaxTokens: part.maxTokens
        )
        guard budgeted.system == Prompts.audioOverviewCondenser, budgeted.user == part.userMessage else {
            throw AudioOverviewGenerationError.partTooLong(model: routed.model, title: part.sourceTitle)
        }
        let response = try await call(
            config: config,
            system: Prompts.audioOverviewCondenser,
            user: part.userMessage,
            maxTokens: part.maxTokens,
            temperature: 0.2,
            jsonMode: true,
            sourceTitle: part.sourceTitle,
            subjectID: part.sourceID,
            subjectType: part.sourceType.rawValue
        )
        let account: Account
        do {
            account = try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
        let text = account.account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AudioOverviewGenerationError.emptyCondensedAccount(part.sourceTitle) }
        return text
    }
}
