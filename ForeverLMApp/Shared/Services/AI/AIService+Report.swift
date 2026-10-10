import Foundation

extension AIService {

    /// The response budget the report writer asks for: the longest report (a
    /// study guide, about 2,400 words, or a custom one asked to run longer)
    /// with room for its Markdown, its markers and the JSON around it.
    static let reportWriterMaxTokens = 12_000

    /// Write a notebook's report from the turn the generator built. The turn
    /// is sent exactly as given: the generator sized it against the route's
    /// window and checked that nothing would be cut on the way. Never
    /// answered from the response cache: Make again with the same options
    /// asks for a new report, not the one already saved.
    func writeReport(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        config: AITaskConfig
    ) async throws -> ReportDraft {
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: Self.reportWriterMaxTokens,
            temperature: 0.4,
            allowsResponseCache: false,
            jsonMode: true,
            sourceTitle: notebookTitle,
            subjectID: notebookID,
            subjectType: "notebook"
        )
        let draft: ReportDraft
        do {
            draft = try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
        guard draft.isUsable else {
            throw ReportGenerationError.emptyReport
        }
        return draft
    }

    /// Condense one part of a source too long for the report writer's window.
    /// The part is the source's own consecutive text, never a sample of it,
    /// and it is sent whole: a request the central one-shot trim would cut is
    /// refused before it is sent.
    func condenseForReport(
        _ part: ReportCondensePart,
        config: AITaskConfig
    ) async throws -> String {
        struct Account: Decodable { let account: String }
        let routed = KeychainService.routedTextConfig(config)
        let budgeted = Self.budgetedOneShotRequest(
            provider: routed.provider,
            model: routed.model,
            system: Prompts.reportCondenser,
            user: part.userMessage,
            requestedMaxTokens: part.maxTokens
        )
        guard budgeted.system == Prompts.reportCondenser, budgeted.user == part.userMessage else {
            throw ReportGenerationError.partTooLong(model: routed.model, title: part.sourceTitle)
        }
        let response = try await call(
            config: config,
            system: Prompts.reportCondenser,
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
        guard !text.isEmpty else { throw ReportGenerationError.emptyCondensedAccount(part.sourceTitle) }
        return text
    }
}
