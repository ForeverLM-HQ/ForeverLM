import Foundation

enum DeepResearchMode: String, CaseIterable, Identifiable, Sendable {
    case agentic
    case multiPass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agentic: return "Agentic"
        case .multiPass: return "Multi-pass"
        }
    }

    var stageCount: Int {
        switch self {
        case .agentic: return 1
        case .multiPass: return DeepResearchService.lenses.count
        }
    }
}

struct DeepResearchLens: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let instruction: String
}

struct DeepResearchPass: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let notes: String
    let citations: [AIWebCitation]
}

struct DeepResearchCandidate: Identifiable, Equatable, Sendable {
    /// URL identity is deterministic. The model may describe a source, but it
    /// never decides whether two source records are the same.
    let id: String
    let url: String
    let title: String
    let domain: String
    let foundBy: [String]
}

struct DeepResearchReport: Equatable, Sendable {
    let question: String
    let passes: [DeepResearchPass]
    let candidates: [DeepResearchCandidate]
    let completedAt: Date
}

struct DeepResearchProgress: Equatable, Sendable {
    let completedPasses: Int
    let totalPasses: Int
    let currentLens: String
}

enum DeepResearchError: LocalizedError {
    case emptyQuestion
    case noCitations
    case providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuestion:
            return "Enter a research question."
        case .noCitations:
            return "The research model returned no verifiable web sources."
        case .providerUnavailable(let message):
            return message
        }
    }
}

/// Runs either one bounded provider-agent investigation or complementary
/// web-search passes, then returns cited pages for human review. It never writes
/// to storage; approving a candidate goes through the normal ingestion path.
struct DeepResearchService: Sendable {
    let aiService: AIService

    static let lenses: [DeepResearchLens] = [
        DeepResearchLens(
            id: "overview",
            title: "Landscape",
            instruction: "Map the field, its terminology, and the most authoritative overview sources."
        ),
        DeepResearchLens(
            id: "primary",
            title: "Primary evidence",
            instruction: "Find original research, datasets, standards, official records, or first-party documentation."
        ),
        DeepResearchLens(
            id: "challenge",
            title: "Counterevidence",
            instruction: "Look for credible criticism, conflicting findings, limitations, and unresolved disputes."
        ),
        DeepResearchLens(
            id: "current",
            title: "Current developments",
            instruction: "Find the most recent material that materially changes or updates the answer."
        ),
    ]

    func run(
        question rawQuestion: String,
        config: AITaskConfig,
        mode: DeepResearchMode = .agentic,
        onProgress: @MainActor @Sendable (DeepResearchProgress) -> Void = { _ in }
    ) async throws -> DeepResearchReport {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw DeepResearchError.emptyQuestion }

        let routedConfig = KeychainService.routedTextConfig(config)
        if routedConfig.provider == .gemini {
            throw DeepResearchError.providerUnavailable(
                "Gemini Deep Research is not available through ForeverLM's managed billing yet because Google Search has an account-wide allowance that cannot be assigned exactly to one request. Choose another chat model."
            )
        }

        switch mode {
        case .agentic:
            return try await runAgentic(
                question: question,
                config: routedConfig,
                onProgress: onProgress
            )
        case .multiPass:
            return try await runMultiPass(
                question: question,
                config: routedConfig,
                onProgress: onProgress
            )
        }
    }

    private func runAgentic(
        question: String,
        config: AITaskConfig,
        onProgress: @MainActor @Sendable (DeepResearchProgress) -> Void
    ) async throws -> DeepResearchReport {
        await onProgress(
            DeepResearchProgress(
                completedPasses: 0,
                totalPasses: 1,
                currentLens: "\(config.provider.shortName) research"
            )
        )

        let system = AITask.deepResearch.effectivePrompt ?? Prompts.deepResearch
        let workflowID = "deep-research-\(UUID().uuidString.lowercased())"
        let researchDate = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var notes = ""
        let result = try await AIUsageAttribution.$sessionID.withValue(workflowID) {
            try await AIUsageAttribution.$activityID.withValue(workflowID) {
                try await aiService.streamChatWithTools(
                    config: config,
                    system: system,
                    turns: [
                        .user("""
                        Research question: \(question)
                        Research date: \(researchDate)

                        Conduct a thorough investigation. Build a landscape, seek primary evidence, test the leading answer against credible counterevidence, and check current developments. Follow useful source trails rather than stopping after the first plausible result. The final notes should synthesize what the evidence supports and what remains uncertain.
                        """)
                    ],
                    tools: [],
                    maxTokens: 6_000,
                    webSearch: true,
                    webSearchDepth: .deepResearch,
                    onTextDelta: { notes += $0 }
                )
            }
        }

        let pass = DeepResearchPass(
            id: "agentic",
            title: "\(config.provider.shortName) research",
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            citations: result.webCitations
        )
        await onProgress(
            DeepResearchProgress(
                completedPasses: 1,
                totalPasses: 1,
                currentLens: "Preparing sources"
            )
        )
        return try report(question: question, passes: [pass])
    }

    private func runMultiPass(
        question: String,
        config: AITaskConfig,
        onProgress: @MainActor @Sendable (DeepResearchProgress) -> Void
    ) async throws -> DeepResearchReport {

        let system = AITask.deepResearch.effectivePrompt ?? Prompts.deepResearch
        let workflowID = "deep-research-\(UUID().uuidString.lowercased())"
        let researchDate = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var passes: [DeepResearchPass] = []
        passes.reserveCapacity(Self.lenses.count)

        for (index, lens) in Self.lenses.enumerated() {
            try Task.checkCancellation()
            await onProgress(
                DeepResearchProgress(
                    completedPasses: index,
                    totalPasses: Self.lenses.count,
                    currentLens: lens.title
                )
            )

            var notes = ""
            let result = try await AIUsageAttribution.$sessionID.withValue(workflowID) {
                try await AIUsageAttribution.$activityID.withValue(workflowID) {
                    try await aiService.streamChatWithTools(
                        config: config,
                        system: system,
                        turns: [
                            .user("""
                            Research question: \(question)
                            Research date: \(researchDate)

                            Search angle: \(lens.instruction)
                            Focus on sources that would be worth putting into a long-term learning library.
                            """)
                        ],
                        tools: [],
                        maxTokens: 1_800,
                        webSearch: true,
                        onTextDelta: { notes += $0 }
                    )
                }
            }
            passes.append(
                DeepResearchPass(
                    id: lens.id,
                    title: lens.title,
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                    citations: result.webCitations
                )
            )
        }

        await onProgress(
            DeepResearchProgress(
                completedPasses: Self.lenses.count,
                totalPasses: Self.lenses.count,
                currentLens: "Preparing sources"
            )
        )

        return try report(question: question, passes: passes)
    }

    private func report(question: String, passes: [DeepResearchPass]) throws -> DeepResearchReport {
        let candidates = Self.mergeCandidates(from: passes)
        guard !candidates.isEmpty else { throw DeepResearchError.noCitations }
        return DeepResearchReport(
            question: question,
            passes: passes,
            candidates: candidates,
            completedAt: Date()
        )
    }

    static func mergeCandidates(from passes: [DeepResearchPass]) -> [DeepResearchCandidate] {
        struct Accumulator {
            var url: String
            var title: String
            var domain: String
            var foundBy: [String]
        }

        var order: [String] = []
        var candidatesByID: [String: Accumulator] = [:]

        for pass in passes {
            for citation in pass.citations {
                let rawURL = citation.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }

                let identity = URLNormalizer.normalize(rawURL)
                guard !identity.isEmpty else { continue }
                let domain = Self.displayDomain(for: url)
                let title = citation.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = title.isEmpty ? (domain.isEmpty ? rawURL : domain) : title

                if var existing = candidatesByID[identity] {
                    if existing.title == existing.domain, displayTitle != domain {
                        existing.title = displayTitle
                    }
                    if !existing.foundBy.contains(pass.title) {
                        existing.foundBy.append(pass.title)
                    }
                    candidatesByID[identity] = existing
                } else {
                    order.append(identity)
                    candidatesByID[identity] = Accumulator(
                        url: rawURL,
                        title: displayTitle,
                        domain: domain,
                        foundBy: [pass.title]
                    )
                }
            }
        }

        return order.compactMap { identity in
            guard let candidate = candidatesByID[identity] else { return nil }
            return DeepResearchCandidate(
                id: identity,
                url: candidate.url,
                title: candidate.title,
                domain: candidate.domain,
                foundBy: candidate.foundBy
            )
        }
    }

    private static func displayDomain(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
