#if os(macOS)
import Foundation

// MARK: - A source's reading levels over MCP
//
// docs/sensemaking-design.md, "Levels in the Reader". `get_source_levels`
// reads the levels the Reader's Levels panel shows — a source's gist, why it
// matters, its findings, a line a section and a paragraph, and its key terms
// — and says when they were written from an earlier version of its text.
// With write_if_missing it writes them first when none are written for the
// text as it is now: the same run the panel's Write Levels starts, on the
// learner's Reading Levels model, so it is paid work. The levels and the
// sources' text live in the Mac's library, so the tool is the Mac's alone.
// Its reads and writes go through the storage actor and the main actor,
// never the cached connection (`storeGateExemptToolNames`).

extension MCPToolRegistry {
    static var sourceLevelsToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "get_source_levels",
                description: "Read a source zoomed out, as the Levels panel beside ForeverLM's Reader shows it: its gist (its point in one sentence), why it matters, up to 4 key findings with the section that establishes each, every section's title and one line on what it establishes, every paragraph's line (paragraphs numbered 1..N over the source's stored text), and 5 to 12 key terms with plain definitions — names first, the vocabulary a newcomer needs before the rest. Each section, paragraph and term carries opens_with, the source's own first words there, verbatim from its stored text (never written by a model), so you can quote it or find the passage with get_source_content. stale is true when the source's text has changed since the levels were written. level narrows the answer: gist (gist, why, findings, key terms), sections (those and every section's line), or paragraphs and all (the default: those and every paragraph's line). With write_if_missing true and no levels written for the text as it is now (none, or stale ones), ForeverLM writes them first on the learner's Reading Levels model — one request, a few more for a long source, billed to the learner's OpenRouter key — and answers with them; a run already writing the same source's levels is joined, not repeated. Without it nothing is written or spent. cancel_ai_work stops a write; nothing of it is saved.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": [
                            "type": "string",
                            "description": "The source, as list_sources or a search returns it.",
                        ],
                        "level": [
                            "type": "string",
                            "enum": ["gist", "sections", "paragraphs", "all"],
                            "description": "How far to zoom out: gist (gist, why, findings, key terms), sections (those and every section's line), or paragraphs and all (the default: those and every paragraph's line).",
                        ],
                        "write_if_missing": [
                            "type": "boolean",
                            "description": "Write the levels first when none are written for the source's text as it is now. Defaults to false, which reads only and spends nothing.",
                        ],
                    ],
                    "required": ["source_id"],
                ]
            ),
        ]
    }

    static let sourceLevelsToolNames: Set<String> = ["get_source_levels"]
}

extension MCPDataStore {
    func executeSourceLevelsTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "get_source_levels": return try await getSourceLevels(arguments: arguments)
        default: return nil
        }
    }

    /// `get_source_levels`. `backend` stands in for the model in tests,
    /// which then write without the app's coordinator.
    func getSourceLevels(arguments: [String: Any], backend: (any SourceLevelsBackend)? = nil) async throws -> String {
        let sourceID = (arguments["source_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceID.isEmpty else {
            throw MCPError.invalidInput("source_id is required: pass a source id as list_sources or a search returns it.")
        }
        let level = (arguments["level"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "all"
        guard let depth = SourceLevelsDepth(rawValue: level.isEmpty ? "all" : level) else {
            throw MCPError.invalidInput("level is gist, sections, paragraphs or all.")
        }
        let writeIfMissing = arguments["write_if_missing"] as? Bool ?? false

        let storage = notebookFileStorage
        guard let article = try await storage.loadSourceWithoutContent(sourceID) else {
            throw MCPError.notFound("No library source answers to \(sourceID). Pass a source_id as list_sources or a search returns it.")
        }
        let excluded = try await storage.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        guard !KnowledgeStore.isBlockedFromOpening(sourceID, excluded: excluded) else {
            throw MCPError.invalidInput("Source is excluded from knowledge search and AI in ForeverLM Settings. Include its source family there before reading it.")
        }
        var state = try await storage.sourceLevelsState(sourceID: sourceID)
        var wroteNow = false
        let isCurrent = state.levels.map { levels in state.currentSHA256.map { !levels.isStale(currentSHA256: $0) } ?? true } ?? false
        if writeIfMissing, !isCurrent {
            // The writer reads the text as get_source_content does, from its
            // file when none is stored, and says when there is none.
            let result: Result<SourceLevels, Error>
            if let backend {
                do {
                    result = .success(try await SourceLevelsWriter.write(sourceID: sourceID, storage: storage, backend: backend))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = await SourceLevelsCoordinator.shared.write(sourceID: sourceID, storage: storage)
            }
            switch result {
            case .success(let levels):
                state.levels = levels
                wroteNow = true
            case .failure(let error):
                if error is CancellationError { throw error }
                throw MCPError.invalidInput("No levels were written: \(error.localizedDescription)")
            }
        }
        return try jsonString(Self.sourceLevelsPayload(
            sourceID: sourceID,
            title: article.title,
            levels: state.levels,
            currentSHA256: state.currentSHA256,
            depth: depth,
            wroteNow: wroteNow
        ))
    }

    /// What `get_source_levels` answers: the levels at the depth asked for,
    /// with each section's, paragraph's and term's opening words from the
    /// text.
    static func sourceLevelsPayload(
        sourceID: String,
        title: String,
        levels: SourceLevels?,
        currentSHA256: String?,
        depth: SourceLevelsDepth,
        wroteNow: Bool
    ) -> [String: Any] {
        guard let levels else {
            return [
                "source_id": sourceID,
                "title": title,
                "has_levels": false,
                "message": "No levels are written for \u{201C}\(title)\u{201D} yet. Pass write_if_missing true to write them on the learner's Reading Levels model (paid), or the learner can press Write Levels in the Reader's Levels panel.",
            ]
        }
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "source_id": sourceID,
            "title": title,
            "has_levels": true,
            "stale": currentSHA256.map { levels.isStale(currentSHA256: $0) } ?? false,
            "written_now": wroteNow,
            "content_sha256": levels.contentSHA256,
            "written_at": iso.string(from: levels.createdAt),
            "paragraph_count": levels.paragraphCount,
            "gist": levels.gist,
            "why": levels.why,
            "findings": levels.findings.map { finding -> [String: Any] in
                var entry: [String: Any] = ["text": finding.text]
                if let index = finding.sectionIndex, levels.sections.indices.contains(index) {
                    entry["section"] = index + 1
                    entry["section_title"] = levels.sections[index].title
                }
                return entry
            },
            "terms": levels.terms.map { term -> [String: Any] in
                var entry: [String: Any] = ["term": term.term, "definition": term.definition]
                if let paragraph = term.paragraphIndex { entry["paragraph"] = paragraph }
                if let anchor = term.anchor { entry["opens_with"] = anchor }
                return entry
            },
        ]
        if let model = levels.model { payload["model"] = model }
        if depth != .gist {
            payload["sections"] = levels.sections.enumerated().map { index, section -> [String: Any] in
                var entry: [String: Any] = [
                    "section": index + 1,
                    "title": section.title,
                    "line": section.line,
                    "paragraph_count": section.paragraphs.count,
                ]
                if let first = section.firstParagraph { entry["first_paragraph"] = first }
                if let anchor = section.anchor { entry["opens_with"] = anchor }
                if depth.includesParagraphs {
                    entry["paragraphs"] = section.paragraphs.map { paragraph -> [String: Any] in
                        ["n": paragraph.index, "line": paragraph.line, "opens_with": paragraph.anchor]
                    }
                }
                return entry
            }
        }
        return payload
    }
}

/// How far `get_source_levels` zooms out.
enum SourceLevelsDepth: String {
    case gist
    case sections
    case paragraphs
    case all

    var includesParagraphs: Bool { self == .paragraphs || self == .all }
}
#endif
