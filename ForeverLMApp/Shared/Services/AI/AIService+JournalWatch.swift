import Foundation

/// What the matching call is told about one Notebook.
struct JournalMatchingNotebook: Equatable, Sendable {
    let id: String
    let title: String
    let instructions: String?
    let researchQuestions: [String]
    let topic: String?
    /// A handful of titles already in the pool, so "belongs here" is judged
    /// against what the researcher actually collected, not the title alone.
    let sampleSourceTitles: [String]
}

/// One feed article as the matching call sees it.
struct JournalMatchingCandidate: Equatable, Sendable {
    /// The article URL — the identity the verdict is keyed back to.
    let id: String
    let title: String
    let summary: String?
    /// Where it was published: the journal when the feed names one, otherwise
    /// the feed's own title (a blog, a newsletter, a preprint listing).
    let source: String?
    let authors: String?
}

struct JournalArticleVerdict: Equatable, Sendable {
    let itemID: String
    let notebookID: String
    let reason: String
}

extension AIService {

    /// Asks the model which of a batch of new journal articles belong in
    /// which Notebooks. One call per `JournalWatch.matchingBatchSize` articles,
    /// every Notebook in each call, so the Notebook descriptions are paid for
    /// once per batch rather than once per article.
    ///
    /// Identity never reaches the model: articles and Notebooks travel under
    /// opaque short handles (`a3`, `p1`) that are mapped back here, and a
    /// verdict naming a handle that was not sent is dropped. A slow or failed
    /// call therefore costs a retry and can never file an article under the
    /// wrong Notebook or invent one.
    func matchJournalArticles(
        notebooks: [JournalMatchingNotebook],
        candidates: [JournalMatchingCandidate],
        config: AITaskConfig
    ) async throws -> [JournalArticleVerdict] {
        guard !notebooks.isEmpty, !candidates.isEmpty else { return [] }
        let system = AITask.journalArticleMatching.effectivePrompt ?? Prompts.journalArticleMatching
        var verdicts: [JournalArticleVerdict] = []
        var index = 0
        while index < candidates.count {
            let end = min(index + JournalWatch.matchingBatchSize, candidates.count)
            let batch = Array(candidates[index..<end])
            index = end
            let request = Self.journalMatchingRequest(notebooks: notebooks, candidates: batch)
            let response = try await call(
                config: config,
                system: system,
                user: request.userMessage,
                maxTokens: max(1_000, min(8_000, batch.count * notebooks.count * 12 + 400)),
                temperature: 0.0,
                jsonMode: true
            )
            verdicts += try Self.parseJournalMatchingResponse(
                response,
                articleHandles: request.articleHandles,
                notebookHandles: request.notebookHandles
            )
        }
        return verdicts
    }

    struct JournalMatchingRequest: Equatable, Sendable {
        let userMessage: String
        /// Handle → article id (URL).
        let articleHandles: [String: String]
        /// Handle → Notebook id.
        let notebookHandles: [String: String]
    }

    nonisolated static func journalMatchingRequest(
        notebooks: [JournalMatchingNotebook],
        candidates: [JournalMatchingCandidate]
    ) -> JournalMatchingRequest {
        var notebookHandles: [String: String] = [:]
        var articleHandles: [String: String] = [:]

        let notebookRows = notebooks.enumerated().map { offset, notebook -> String in
            let handle = "p\(offset + 1)"
            notebookHandles[handle] = notebook.id
            var fields = ["\"id\":\"\(handle)\"", "\"title\":\"\(jsonEscaped(notebook.title))\""]
            if let instructions = notebook.instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
                fields.append("\"instructions\":\"\(jsonEscaped(String(instructions.prefix(1_200))))\"")
            }
            let questions = notebook.researchQuestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !questions.isEmpty {
                fields.append("\"research_questions\":[\(questions.prefix(12).map { "\"\(jsonEscaped($0))\"" }.joined(separator: ","))]")
            }
            if let topic = notebook.topic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty, topic != notebook.title {
                fields.append("\"topic\":\"\(jsonEscaped(topic))\"")
            }
            if !notebook.sampleSourceTitles.isEmpty {
                fields.append("\"existing_sources\":[\(notebook.sampleSourceTitles.prefix(12).map { "\"\(jsonEscaped($0))\"" }.joined(separator: ","))]")
            }
            return "{\(fields.joined(separator: ","))}"
        }

        let articleRows = candidates.enumerated().map { offset, candidate -> String in
            let handle = "a\(offset + 1)"
            articleHandles[handle] = candidate.id
            var fields = ["\"id\":\"\(handle)\"", "\"title\":\"\(jsonEscaped(candidate.title))\""]
            if let source = candidate.source, !source.isEmpty {
                fields.append("\"source\":\"\(jsonEscaped(source))\"")
            }
            if let authors = candidate.authors, !authors.isEmpty {
                fields.append("\"authors\":\"\(jsonEscaped(String(authors.prefix(300))))\"")
            }
            if let summary = candidate.summary, !summary.isEmpty {
                fields.append("\"summary\":\"\(jsonEscaped(String(summary.prefix(1_200))))\"")
            }
            return "{\(fields.joined(separator: ","))}"
        }

        let userMessage = """
        Notebooks:
        [
        \(notebookRows.joined(separator: ",\n"))
        ]

        New articles:
        [
        \(articleRows.joined(separator: ",\n"))
        ]
        """
        return JournalMatchingRequest(
            userMessage: userMessage,
            articleHandles: articleHandles,
            notebookHandles: notebookHandles
        )
    }

    nonisolated static func parseJournalMatchingResponse(
        _ response: String,
        articleHandles: [String: String],
        notebookHandles: [String: String]
    ) throws -> [JournalArticleVerdict] {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"), start <= end else {
            throw AIError.invalidResponse
        }
        let jsonString = String(response[start...end])
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = object["matches"] as? [Any] else {
            throw AIError.invalidResponse
        }
        var verdicts: [JournalArticleVerdict] = []
        var seen = Set<String>()
        for entry in matches {
            guard let match = entry as? [String: Any],
                  let articleHandle = (match["article"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let notebookHandle = (match["notebook"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let itemID = articleHandles[articleHandle],
                  let notebookID = notebookHandles[notebookHandle] else { continue }
            guard seen.insert("\(itemID)|\(notebookID)").inserted else { continue }
            let reason = (match["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            verdicts.append(JournalArticleVerdict(itemID: itemID, notebookID: notebookID, reason: String(reason.prefix(300))))
        }
        return verdicts
    }
}
