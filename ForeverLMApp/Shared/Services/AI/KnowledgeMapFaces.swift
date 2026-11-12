import Foundation

/// A source card's written faces on the Canvas (docs/sensemaking-design.md,
/// "Written faces"): `far`, a few words of what it is about, for when the card
/// is small; `mid`, its main finding or claim in a sentence; `near`, two or
/// three short lines (question, approach, finding) for close in. Written in
/// batches by the Canvas Summaries route (`AITask.mapSummaries`) with
/// `Prompts.mapFaces`, from the source's extracted ideas when it has some and
/// else the start of its stored text, and kept in `source_faces` against a
/// fingerprint of that input, so a face is written again only when it changes.
enum KnowledgeMapFaces {
    struct Face: Codable, Equatable, Sendable {
        var far: String
        var mid: String
        var near: [String]
    }

    /// What a source's faces are written from.
    struct SourceText: Equatable, Sendable {
        /// The first `fingerprintCharacters` of its stored text; empty when it
        /// has none yet.
        var start: String
        /// Its extracted ideas, one statement each: better input than the
        /// start of its text when it has some.
        var ideas: [String]

        var isEmpty: Bool {
            start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ideas.isEmpty
        }
    }

    /// One source as the model reads it.
    struct Input: Equatable, Sendable {
        var sourceID: String
        var title: String
        /// Who, when and where: the card's subtitle.
        var byline: String
        var type: String
        var text: SourceText
        var fingerprint: String
    }

    /// Most sources written in one call.
    static let sourcesPerCall = 12
    /// How much of the stored text the fingerprint covers.
    static let fingerprintCharacters = 3000
    /// How much of it the model reads, when the source has no ideas.
    static let promptCharacters = 1500
    static let farWords = 6
    static let midWords = 22
    static let nearLines = 3
    static let nearWords = 16

    // MARK: Fingerprint

    /// SHA-256 of the title and what the faces are written from: the ideas'
    /// statements when there are some, else the first 3,000 characters of the
    /// stored text.
    static func fingerprint(title: String, text: SourceText) -> String {
        let body = text.ideas.isEmpty
            ? String(text.start.prefix(fingerprintCharacters))
            : text.ideas.joined(separator: "\n")
        return (title + "\u{1F}" + body).sha256Hex
    }

    /// The cheap signature a fingerprint is cached against: a source whose
    /// title, length and state are as they were is not read again.
    static func signature(of article: StudioArticle) -> String {
        "\(article.title)\u{1F}\(article.wordCount ?? -1)\u{1F}\(article.state)"
    }

    /// The sources whose faces need writing: those with a fingerprint whose
    /// stored row was written from something else or is missing, leaving out
    /// what the model answered nothing for this session.
    static func needingFaces(
        _ sourceIDs: [String],
        fingerprints: [String: String],
        rows: [String: SourceFacesRow],
        unanswered: Set<String>
    ) -> [String] {
        sourceIDs.filter { id in
            guard let fingerprint = fingerprints[id] else { return false }
            return rows[id]?.fingerprint != fingerprint && !unanswered.contains(fingerprint)
        }
    }

    /// `items` in calls of at most `size`.
    static func batches<T>(_ items: [T], size: Int = sourcesPerCall) -> [[T]] {
        stride(from: 0, to: items.count, by: max(1, size)).map { Array(items[$0 ..< min($0 + max(1, size), items.count)]) }
    }

    // MARK: The call

    /// The sources as the model reads them, each under a short id (`s1`…).
    static func message(_ inputs: [Input]) -> String {
        let sources: [[String: Any]] = inputs.enumerated().map { index, input in
            var entry: [String: Any] = ["id": "s\(index + 1)", "title": input.title, "type": input.type]
            if !input.byline.isEmpty { entry["byline"] = input.byline }
            if input.text.ideas.isEmpty {
                let start = CanvasAskService.normalized(String(input.text.start.prefix(promptCharacters)))
                if !start.isEmpty { entry["text_start"] = start }
            } else {
                entry["ideas"] = Array(input.text.ideas.prefix(12))
            }
            return entry
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["sources": sources], options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    enum ParseError: Error { case unreadable }

    /// The faces the model wrote, by source id. An entry naming an id that was
    /// not asked, or missing its far or mid line, is dropped; lines over their
    /// length are cut at a word.
    static func faces(from response: String, asked: [Input]) throws -> [String: Face] {
        guard let object = CanvasAskService.jsonObject(from: response) as? [String: Any],
              let list = object["faces"] as? [[String: Any]] else { throw ParseError.unreadable }
        var byShortID: [String: Input] = [:]
        for (index, input) in asked.enumerated() { byShortID["s\(index + 1)"] = input }
        var result: [String: Face] = [:]
        for entry in list {
            guard let shortID = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let input = byShortID[shortID], result[input.sourceID] == nil else { continue }
            let far = CanvasAskService.words(entry["far"] as? String, max: farWords, ellipsis: false)
            let mid = CanvasAskService.words(entry["mid"] as? String, max: midWords)
            guard !far.isEmpty, !mid.isEmpty else { continue }
            let near = (entry["near"] as? [Any] ?? [])
                .map { CanvasAskService.words($0 as? String, max: nearWords) }
                .filter { !$0.isEmpty }
                .prefix(nearLines)
            result[input.sourceID] = Face(far: far, mid: mid, near: Array(near))
        }
        return result
    }

    // MARK: This Mac's switch

    /// Written Faces in the Canvas's view controls: remembered on this Mac
    /// only, on until the learner turns it off.
    static var isEnabledOnThisMac: Bool {
        get { Preferences.value(Prefs.KnowledgeMap.writtenFacesEnabled) ?? true }
        set { Preferences.set(newValue, for: Prefs.KnowledgeMap.writtenFacesEnabled) }
    }
}

extension AIService {
    /// One call for up to `KnowledgeMapFaces.sourcesPerCall` sources' faces.
    /// It goes by the Canvas Summaries route (the same family of Canvas text)
    /// with its own prompt.
    func knowledgeMapFaces(
        _ inputs: [KnowledgeMapFaces.Input],
        config: AITaskConfig
    ) async throws -> [String: KnowledgeMapFaces.Face] {
        let response = try await call(
            config: config,
            system: Prompts.mapFaces,
            user: KnowledgeMapFaces.message(inputs),
            maxTokens: inputs.count * 160 + 100,
            temperature: 0.2,
            jsonMode: true,
            validateResponse: { response in _ = try KnowledgeMapFaces.faces(from: response, asked: inputs) },
            sourceTitle: "Canvas",
            subjectID: "map"
        )
        do {
            return try KnowledgeMapFaces.faces(from: response, asked: inputs)
        } catch {
            throw AIError.invalidResponse
        }
    }
}
