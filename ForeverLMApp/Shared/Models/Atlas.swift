import Foundation

// MARK: - Atlas (docs/atlas-design.md)
//
// A topic laid out as a small hierarchy of concepts (field, subtopics,
// concepts, mechanisms, methods, claims), each written at several levels of
// abstraction (a gist, a line, a paragraph, numbered steps), grounded in
// passages from the learner's library, and coloured by what the learner
// already remembers. ForeverLM makes one when asked. It is derived and local:
// one `atlases` row (schema 165), its body stored whole as JSON. It never
// touches the learner's Canvas unless they lay it out there and Keep it.

/// What an Atlas was made over: cards from the Canvas, a notebook, or, with
/// both empty, the whole library.
struct AtlasScope: Codable, Equatable, Hashable, Sendable {
    /// Canvas refs (`source:<id>`, `idea:<id>`, `doc:<id>`), sorted and unique.
    var itemRefs: [String]
    var notebookID: String?

    init(itemRefs: [String] = [], notebookID: String? = nil) {
        let refs = itemRefs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.itemRefs = Array(Set(refs)).sorted()
        let notebook = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notebookID = notebook?.isEmpty == false ? notebook : nil
    }

    var isWholeLibrary: Bool { itemRefs.isEmpty && notebookID == nil }

    private enum CodingKeys: String, CodingKey { case itemRefs, notebookID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            itemRefs: try container.decodeIfPresent([String].self, forKey: .itemRefs) ?? [],
            notebookID: try container.decodeIfPresent(String.self, forKey: .notebookID)
        )
    }
}

/// A word a newcomer must know, with its plain definition. Names first: the
/// vocabulary of a field is the biggest barrier to entering it.
struct AtlasTerm: Codable, Equatable, Hashable, Sendable {
    var term: String
    var definition: String
}

/// How one concept connects to another, by the other's id.
struct AtlasRelation: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// `to` is what to understand first.
        case prerequisite
        case partOf = "part_of"
        case causes
        case measures
        case contrasts
        case related
        case example

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(parsing: raw) ?? .related
        }

        /// The model's word for a kind, forgiving case, spaces and dashes.
        init?(parsing raw: String) {
            let key = AtlasText.token(raw)
            switch key {
            case "partof", "part_of", "is_part_of": self = .partOf
            case "prerequisites", "requires", "needs": self = .prerequisite
            case "cause", "leads_to": self = .causes
            case "measure", "measured_by": self = .measures
            case "contrast", "contrasts_with": self = .contrasts
            case "relates_to", "related_to": self = .related
            case "example_of", "instance_of": self = .example
            default: self.init(rawValue: key)
            }
        }

        /// Read from the concept that holds the relation: "causes" X.
        var outgoingPhrase: String {
            switch self {
            case .prerequisite: return "builds on"
            case .partOf: return "part of"
            case .causes: return "causes"
            case .measures: return "measures"
            case .contrasts: return "contrasts with"
            case .related: return "related to"
            case .example: return "an example of"
            }
        }

        /// Read from the concept it points at: "caused by" X.
        var incomingPhrase: String {
            switch self {
            case .prerequisite: return "needed for"
            case .partOf: return "has part"
            case .causes: return "caused by"
            case .measures: return "measured by"
            case .contrasts: return "contrasts with"
            case .related: return "related to"
            case .example: return "has example"
            }
        }
    }

    var to: String
    var kind: Kind
    /// A short label in ForeverLM's words ("phosphorylates"), when it has one.
    var label: String?
}

/// A passage that bears on a concept, by its id in the Atlas's pool.
struct AtlasEvidence: Codable, Equatable, Hashable, Sendable {
    enum Stance: String, Codable, CaseIterable, Sendable {
        case supports
        case contradicts
        case defines
        case context

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Stance(parsing: raw) ?? .supports
        }

        init?(parsing raw: String) {
            switch AtlasText.token(raw) {
            case "support", "supporting": self = .supports
            case "contradict", "contradicting", "disputes": self = .contradicts
            case "define", "definition": self = .defines
            case "background": self = .context
            case let key: self.init(rawValue: key)
            }
        }

        /// Which stance leads when sources are ranked for a concept.
        var rank: Int {
            switch self {
            case .supports: return 0
            case .defines: return 1
            case .contradicts: return 2
            case .context: return 3
            }
        }
    }

    var passageID: String
    var stance: Stance
}

/// One concept of an Atlas, written at four levels.
struct AtlasConcept: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case field, topic, concept, mechanism, method, measure, claim, debate, entity

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: AtlasText.token(raw)) ?? .concept
        }

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    enum Status: String, Codable, CaseIterable, Sendable {
        /// Textbook consensus.
        case established
        /// The field disagrees, or the passages do.
        case debated
        /// A hypothesis; one paper's proposal.
        case speculative

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(parsing: raw) ?? .established
        }

        init?(parsing raw: String) {
            switch AtlasText.token(raw) {
            case "consensus", "settled": self = .established
            case "contested", "disputed": self = .debated
            case "hypothesis", "hypothetical", "proposed": self = .speculative
            case let key: self.init(rawValue: key)
            }
        }

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    var id: String
    var name: String
    var kind: Kind
    /// At most eight words, for a glance.
    var gist: String
    /// One sentence.
    var line: String
    /// A textbook paragraph: the root's and its children's from the start,
    /// any other concept's once it is deepened.
    var paragraph: String?
    /// The mechanism or method in numbered steps, once deepened.
    var steps: [String]?
    var terms: [AtlasTerm]
    var parentID: String?
    var relations: [AtlasRelation]
    var evidence: [AtlasEvidence]
    var status: Status
    var openQuestions: [String]
    /// Written in depth (paragraph, steps, more terms) on the learner's focus.
    var deepened: Bool

    init(
        id: String,
        name: String,
        kind: Kind = .concept,
        gist: String = "",
        line: String = "",
        paragraph: String? = nil,
        steps: [String]? = nil,
        terms: [AtlasTerm] = [],
        parentID: String? = nil,
        relations: [AtlasRelation] = [],
        evidence: [AtlasEvidence] = [],
        status: Status = .established,
        openQuestions: [String] = [],
        deepened: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.gist = gist
        self.line = line
        self.paragraph = paragraph
        self.steps = steps
        self.terms = terms
        self.parentID = parentID
        self.relations = relations
        self.evidence = evidence
        self.status = status
        self.openQuestions = openQuestions
        self.deepened = deepened
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, gist, line, paragraph, steps, terms, parentID, relations, evidence, status, openQuestions, deepened
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .concept,
            gist: try container.decodeIfPresent(String.self, forKey: .gist) ?? "",
            line: try container.decodeIfPresent(String.self, forKey: .line) ?? "",
            paragraph: try container.decodeIfPresent(String.self, forKey: .paragraph),
            steps: try container.decodeIfPresent([String].self, forKey: .steps),
            terms: try container.decodeIfPresent([AtlasTerm].self, forKey: .terms) ?? [],
            parentID: try container.decodeIfPresent(String.self, forKey: .parentID),
            relations: try container.decodeIfPresent([AtlasRelation].self, forKey: .relations) ?? [],
            evidence: try container.decodeIfPresent([AtlasEvidence].self, forKey: .evidence) ?? [],
            status: try container.decodeIfPresent(Status.self, forKey: .status) ?? .established,
            openQuestions: try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? [],
            deepened: try container.decodeIfPresent(Bool.self, forKey: .deepened) ?? false
        )
    }
}

/// A passage from the learner's library. The app writes `text` from the
/// stored text it retrieved; the model only ever cites a passage by its id.
struct AtlasPassage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sourceID: String
    var title: String
    var year: String?
    var text: String

    /// The passage as the Atlas prints it: a word the PDF broke at a line's
    /// end ("under- standing") reads whole. `text` keeps the break, since
    /// the Reader finds the passage by the stored words.
    var readableText: String { Self.joiningLineBreakHyphens(text) }

    /// Joins "under- standing" into "understanding". A hyphen left hanging
    /// before a conjunction is the writer's own ("pre- and post-synaptic").
    static func joiningLineBreakHyphens(_ text: String) -> String {
        guard text.contains("- ") else { return text }
        return text.replacingOccurrences(
            of: #"(\p{Ll})- (?!(?:and|or|nor|to|than|as)\b)(\p{Ll})"#,
            with: "$1$2",
            options: .regularExpression
        )
    }
}

struct Atlas: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1

    var id: String
    /// The learner's words when they named it; ForeverLM's when it was read
    /// from cards that named nothing.
    var topic: String
    var scope: AtlasScope
    var rootID: String
    /// In reading order: the root, then each child's branch in turn.
    var concepts: [AtlasConcept]
    var passages: [AtlasPassage]
    var createdAt: Date
    var updatedAt: Date
    /// The model that wrote it, as Settings named it then.
    var model: String?
    var version: Int

    init(
        id: String = "atlas:" + UUID().uuidString.lowercased(),
        topic: String,
        scope: AtlasScope,
        rootID: String,
        concepts: [AtlasConcept],
        passages: [AtlasPassage],
        createdAt: Date,
        updatedAt: Date,
        model: String? = nil,
        version: Int = Atlas.currentVersion
    ) {
        self.id = id
        self.topic = topic
        self.scope = scope
        self.rootID = rootID
        self.concepts = concepts
        self.passages = passages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.version = version
    }
}

// MARK: - Limits

enum AtlasLimits {
    /// What the writer is asked for.
    static let minimumConcepts = 8
    static let maximumConcepts = 24
    /// Fewer concepts than this is no map of a topic: the reply is refused.
    static let acceptedMinimumConcepts = 5
    static let maximumDepth = 4

    static let nameCharacters = 80
    static let gistWords = 8
    static let gistCharacters = 72
    static let lineCharacters = 280
    static let paragraphCharacters = 1_800
    static let stepCharacters = 280
    static let maximumSteps = 7
    static let skeletonTerms = 3
    static let maximumTerms = 7
    static let termCharacters = 60
    static let definitionCharacters = 280
    static let skeletonOpenQuestions = 2
    static let maximumOpenQuestions = 4
    static let questionCharacters = 240
    static let labelCharacters = 40
    static let maximumRelations = 8
    static let maximumEvidence = 8

    /// Retrieval: sources read for a build, the best passages taken from
    /// each, and a passage's length.
    static let buildSources = 18
    static let passagesPerSource = 2
    static let passageCharacters = 700
    /// A deepening reads this many sources again for the one concept.
    static let deepenSources = 6

    /// Evidence rows the fisheye shows under a concept, and sources a
    /// concept brings into a Canvas lens.
    static let shownEvidence = 4
    static let lensSourcesPerConcept = 3
    /// Terms drafted into cards by Learn, beside the concept itself.
    static let learnTerms = 3
}

// MARK: - Levels

/// How much of each concept is written out: the ladder of abstraction.
enum AtlasLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case gist
    case line
    case paragraph
    case steps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gist: return "Gist"
        case .line: return "Line"
        case .paragraph: return "Paragraph"
        case .steps: return "Steps"
        }
    }

    /// One rung more concrete, and one more abstract.
    var deeper: AtlasLevel { AtlasLevel.allCases[min(index + 1, AtlasLevel.allCases.count - 1)] }
    var shallower: AtlasLevel { AtlasLevel.allCases[max(index - 1, 0)] }

    private var index: Int { AtlasLevel.allCases.firstIndex(of: self) ?? 0 }
}

/// The two ways the Atlas pane draws one: the focused concept with its
/// neighbours around it, or the whole hierarchy as an outline.
enum AtlasViewMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case fisheye
    case ladder

    var id: String { rawValue }
    var title: String { self == .fisheye ? "Fisheye" : "Ladder" }
}

// MARK: - Text

enum AtlasText {
    /// A model's enum word as a key: lower case, underscores for spaces and dashes.
    static func token(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    /// The text on one line of single spaces, cut at a word under `characters`
    /// with an ellipsis when longer. ForeverLM's own words only: a source's
    /// text is never cut by this.
    static func capped(_ text: String, characters: Int) -> String {
        let flat = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > characters, characters > 1 else { return flat }
        let head = String(flat.prefix(characters - 1))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }

    /// At most `AtlasLimits.gistWords` words.
    static func gist(_ text: String) -> String {
        let words = capped(text, characters: 400).split(separator: " ")
        let kept = words.prefix(AtlasLimits.gistWords).joined(separator: " ")
        let gist = words.count > AtlasLimits.gistWords
            ? kept.trimmingCharacters(in: CharacterSet(charactersIn: ",;:.")) + "…"
            : kept
        return capped(gist, characters: AtlasLimits.gistCharacters)
    }

    /// A paragraph keeps its sentences but not stray line breaks.
    static func paragraph(_ text: String) -> String {
        capped(text, characters: AtlasLimits.paragraphCharacters)
    }
}

// MARK: - Reading the model's reply

enum AtlasResponseError: LocalizedError, Equatable {
    case unreadable
    case tooFewConcepts(Int)
    case emptyDeepening

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The model's answer was not an Atlas."
        case .tooFewConcepts(let count):
            return "The model laid out only \(count) concept\(count == 1 ? "" : "s"); an Atlas needs at least \(AtlasLimits.acceptedMinimumConcepts)."
        case .emptyDeepening:
            return "The model wrote nothing more about this concept."
        }
    }
}

/// What a deepening adds to one concept.
struct AtlasDeepening: Equatable, Sendable {
    var paragraph: String?
    var steps: [String]
    var terms: [AtlasTerm]
    var evidence: [AtlasEvidence]
    var openQuestions: [String]
}

enum AtlasResponse {
    /// The JSON object in a reply, tolerating a fenced block or prose around it.
    static func jsonObject(_ response: String) -> [String: Any]? {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// The skeleton call's answer: its name for the topic, and the concepts
    /// validated (`AtlasValidation`). Evidence may cite only `passageIDs`.
    static func skeleton(
        from response: String,
        passageIDs: Set<String>
    ) throws -> (topic: String?, rootID: String, concepts: [AtlasConcept]) {
        guard let object = jsonObject(response),
              let list = object["concepts"] as? [Any] else { throw AtlasResponseError.unreadable }
        let raw = list.compactMap { ($0 as? [String: Any]).flatMap(concept(from:)) }
        let validated = try AtlasValidation.validated(raw, passageIDs: passageIDs, termsPerConcept: AtlasLimits.skeletonTerms, questionsPerConcept: AtlasLimits.skeletonOpenQuestions)
        let topic = string(object["topic"]).map { AtlasText.capped($0, characters: AtlasLimits.nameCharacters) }
        return (topic, validated.rootID, validated.concepts)
    }

    /// The deepening call's answer for one concept. Its evidence may cite only
    /// `passageIDs`; terms already on the concept are not added twice.
    static func deepening(
        from response: String,
        passageIDs: Set<String>,
        existingTerms: [AtlasTerm]
    ) throws -> AtlasDeepening {
        guard let object = jsonObject(response) else { throw AtlasResponseError.unreadable }
        let paragraph = string(object["paragraph"]).map(AtlasText.paragraph).flatMap { $0.isEmpty ? nil : $0 }
        let steps = strings(object["steps"])
            .map { AtlasText.capped(stripNumbering($0), characters: AtlasLimits.stepCharacters) }
            .filter { !$0.isEmpty }
            .prefix(AtlasLimits.maximumSteps)
        var seenTerms = Set(existingTerms.map { $0.term.lowercased() })
        let terms = (object["terms"] as? [Any] ?? []).compactMap(term(from:)).filter { seenTerms.insert($0.term.lowercased()).inserted }
        let evidence = AtlasValidation.evidence((object["evidence"] as? [Any] ?? []).compactMap(evidence(from:)), passageIDs: passageIDs)
        let questions = strings(object["open_questions"] ?? object["openQuestions"])
            .map { AtlasText.capped($0, characters: AtlasLimits.questionCharacters) }
            .filter { !$0.isEmpty }
        guard paragraph != nil || !steps.isEmpty else { throw AtlasResponseError.emptyDeepening }
        return AtlasDeepening(
            paragraph: paragraph,
            steps: Array(steps),
            terms: Array(terms.prefix(4)),
            evidence: evidence,
            openQuestions: Array(questions.prefix(AtlasLimits.skeletonOpenQuestions))
        )
    }

    // MARK: Fields

    static func concept(from entry: [String: Any]) -> AtlasConcept? {
        guard let name = string(entry["name"]) ?? string(entry["label"]) else { return nil }
        let line = string(entry["line"]) ?? string(entry["sentence"]) ?? ""
        let gist = string(entry["gist"]) ?? ""
        guard !line.isEmpty || !gist.isEmpty else { return nil }
        let steps = strings(entry["steps"]).map(stripNumbering).filter { !$0.isEmpty }
        return AtlasConcept(
            id: string(entry["id"]) ?? "",
            name: name,
            kind: string(entry["kind"]).flatMap { AtlasConcept.Kind(rawValue: AtlasText.token($0)) } ?? .concept,
            gist: gist,
            line: line.isEmpty ? gist : line,
            paragraph: string(entry["paragraph"]),
            steps: steps.isEmpty ? nil : steps,
            terms: (entry["terms"] as? [Any] ?? []).compactMap(term(from:)),
            parentID: string(entry["parent"]) ?? string(entry["parent_id"]) ?? string(entry["parentID"]),
            relations: (entry["relations"] as? [Any] ?? []).compactMap(relation(from:)),
            evidence: (entry["evidence"] as? [Any] ?? []).compactMap(evidence(from:)),
            status: string(entry["status"]).flatMap(AtlasConcept.Status.init(parsing:)) ?? .established,
            openQuestions: strings(entry["open_questions"] ?? entry["openQuestions"]),
            deepened: false
        )
    }

    static func term(from value: Any) -> AtlasTerm? {
        guard let entry = value as? [String: Any],
              let term = string(entry["term"]) ?? string(entry["name"]),
              let definition = string(entry["definition"]) ?? string(entry["meaning"]) else { return nil }
        return AtlasTerm(term: term, definition: definition)
    }

    static func relation(from value: Any) -> AtlasRelation? {
        guard let entry = value as? [String: Any],
              let to = string(entry["to"]) ?? string(entry["target"]) else { return nil }
        let kind = string(entry["kind"]).flatMap(AtlasRelation.Kind.init(parsing:)) ?? .related
        return AtlasRelation(to: to, kind: kind, label: string(entry["label"]))
    }

    static func evidence(from value: Any) -> AtlasEvidence? {
        if let id = string(value) { return AtlasEvidence(passageID: id, stance: .supports) }
        guard let entry = value as? [String: Any],
              let id = string(entry["passage"]) ?? string(entry["passage_id"]) ?? string(entry["id"]) else { return nil }
        let stance = string(entry["stance"]).flatMap(AtlasEvidence.Stance.init(parsing:)) ?? .supports
        return AtlasEvidence(passageID: id, stance: stance)
    }

    static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { string($0) }
    }

    /// "1. PINK1 builds up" → "PINK1 builds up": the app numbers the steps.
    static func stripNumbering(_ step: String) -> String {
        step.replacingOccurrences(of: #"^\s*(step\s*)?\d+\s*[\.\):-]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Validation

enum AtlasValidation {
    /// The concepts as an Atlas holds them: unique ids, one root, parent
    /// chains that reach it, relations and evidence that point at something,
    /// no more than `AtlasLimits.maximumConcepts`, and every text within its
    /// length. Returned in reading order (the root, then each branch).
    static func validated(
        _ raw: [AtlasConcept],
        passageIDs: Set<String>,
        termsPerConcept: Int = AtlasLimits.maximumTerms,
        questionsPerConcept: Int = AtlasLimits.maximumOpenQuestions
    ) throws -> (rootID: String, concepts: [AtlasConcept]) {
        // Unique ids: a missing or repeated id gets the next cN that no
        // concept uses or names.
        let given = Set(raw.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        var used: Set<String> = []
        var next = 1
        func freshID() -> String {
            while used.contains("c\(next)") || given.contains("c\(next)") { next += 1 }
            return "c\(next)"
        }
        var concepts: [AtlasConcept] = []
        for var concept in raw {
            var id = concept.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty || used.contains(id) {
                id = freshID()
            }
            used.insert(id)
            concept.id = id
            concepts.append(cleaned(concept, termsPerConcept: termsPerConcept, questionsPerConcept: questionsPerConcept))
        }
        guard !concepts.isEmpty else { throw AtlasResponseError.tooFewConcepts(0) }

        // Parents that name nothing, or the concept itself, are dropped.
        let ids = Set(concepts.map(\.id))
        for index in concepts.indices {
            if let parent = concepts[index].parentID, !ids.contains(parent) || parent == concepts[index].id {
                concepts[index].parentID = nil
            }
        }
        // One root: the first concept with no parent, else the first concept.
        let rootIndex = concepts.firstIndex { $0.parentID == nil } ?? 0
        let rootID = concepts[rootIndex].id
        concepts[rootIndex].parentID = nil
        for index in concepts.indices where index != rootIndex && concepts[index].parentID == nil {
            concepts[index].parentID = rootID
        }
        // Acyclic: a chain that comes back on itself before the root is cut
        // where the walk started, under the root.
        var parentOf = Dictionary(concepts.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        for index in concepts.indices where concepts[index].id != rootID {
            var seen: Set<String> = [concepts[index].id]
            var cursor = parentOf[concepts[index].id] ?? nil
            while let current = cursor, current != rootID {
                guard seen.insert(current).inserted else {
                    concepts[index].parentID = rootID
                    parentOf[concepts[index].id] = rootID
                    break
                }
                cursor = parentOf[current] ?? nil
            }
        }

        // Past the cap, the deepest and latest go first: breadth first from
        // the root decides who stays, so a kept concept's parent is kept.
        let byID = Dictionary(concepts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenOf: [String: [String]] = [:]
        for concept in concepts where concept.id != rootID {
            childrenOf[concept.parentID ?? rootID, default: []].append(concept.id)
        }
        var keep: Set<String> = []
        var queue = [rootID]
        while !queue.isEmpty, keep.count < AtlasLimits.maximumConcepts {
            let id = queue.removeFirst()
            guard keep.insert(id).inserted else { continue }
            queue.append(contentsOf: childrenOf[id] ?? [])
        }
        // Stored in reading order: depth first from the root.
        var ordered: [AtlasConcept] = []
        var placed: Set<String> = []
        func visit(_ id: String) {
            guard keep.contains(id), let concept = byID[id], placed.insert(id).inserted else { return }
            ordered.append(concept)
            for child in childrenOf[id] ?? [] { visit(child) }
        }
        visit(rootID)
        guard ordered.count >= AtlasLimits.acceptedMinimumConcepts else {
            throw AtlasResponseError.tooFewConcepts(ordered.count)
        }

        // Relations and evidence point at what is kept.
        let kept = Set(ordered.map(\.id))
        for index in ordered.indices {
            let id = ordered[index].id
            var seen: Set<String> = []
            ordered[index].relations = ordered[index].relations.compactMap { relation in
                var relation = relation
                relation.to = relation.to.trimmingCharacters(in: .whitespacesAndNewlines)
                guard kept.contains(relation.to), relation.to != id,
                      seen.insert(relation.kind.rawValue + "\u{1F}" + relation.to).inserted else { return nil }
                relation.label = relation.label.map { AtlasText.capped($0, characters: AtlasLimits.labelCharacters) }.flatMap { $0.isEmpty ? nil : $0 }
                return relation
            }
            .prefix(AtlasLimits.maximumRelations)
            .map { $0 }
            ordered[index].evidence = evidence(ordered[index].evidence, passageIDs: passageIDs)
        }
        return (rootID, ordered)
    }

    /// Evidence that cites a passage the app gave, once each, at most
    /// `AtlasLimits.maximumEvidence`.
    static func evidence(_ list: [AtlasEvidence], passageIDs: Set<String>) -> [AtlasEvidence] {
        var seen: Set<String> = []
        return list.compactMap { entry in
            let id = entry.passageID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard passageIDs.contains(id), seen.insert(id).inserted else { return nil }
            return AtlasEvidence(passageID: id, stance: entry.stance)
        }
        .prefix(AtlasLimits.maximumEvidence)
        .map { $0 }
    }

    /// Every text within its length; empty terms and questions gone.
    static func cleaned(_ concept: AtlasConcept, termsPerConcept: Int, questionsPerConcept: Int) -> AtlasConcept {
        var concept = concept
        concept.name = AtlasText.capped(concept.name, characters: AtlasLimits.nameCharacters)
        concept.line = AtlasText.capped(concept.line, characters: AtlasLimits.lineCharacters)
        concept.gist = AtlasText.gist(concept.gist.isEmpty ? concept.line : concept.gist)
        concept.paragraph = concept.paragraph.map(AtlasText.paragraph).flatMap { $0.isEmpty ? nil : $0 }
        concept.steps = concept.steps.map { steps in
            steps.map { AtlasText.capped($0, characters: AtlasLimits.stepCharacters) }.filter { !$0.isEmpty }.prefix(AtlasLimits.maximumSteps).map { $0 }
        }.flatMap { $0.isEmpty ? nil : $0 }
        var seenTerms: Set<String> = []
        concept.terms = concept.terms.compactMap { term in
            let name = AtlasText.capped(term.term, characters: AtlasLimits.termCharacters)
            let definition = AtlasText.capped(term.definition, characters: AtlasLimits.definitionCharacters)
            guard !name.isEmpty, !definition.isEmpty, seenTerms.insert(name.lowercased()).inserted else { return nil }
            return AtlasTerm(term: name, definition: definition)
        }
        .prefix(termsPerConcept)
        .map { $0 }
        concept.openQuestions = concept.openQuestions
            .map { AtlasText.capped($0, characters: AtlasLimits.questionCharacters) }
            .filter { !$0.isEmpty }
            .prefix(questionsPerConcept)
            .map { $0 }
        concept.parentID = concept.parentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if concept.parentID?.isEmpty == true { concept.parentID = nil }
        return concept
    }
}

// MARK: - Reading an Atlas

/// What surrounds the focused concept in the fisheye.
struct AtlasNeighbourhood: Equatable {
    /// A related concept and how it relates, read from the focus.
    struct Link: Equatable, Identifiable {
        var concept: AtlasConcept
        var kind: AtlasRelation.Kind
        var isOutgoing: Bool
        /// The relation's words: its label when it goes out from the focus
        /// and has one, else the kind's phrase for that direction.
        var phrase: String
        var id: String { concept.id }
    }

    /// The root first, down to the focus's parent.
    var broader: [AtlasConcept]
    var narrower: [AtlasConcept]
    /// What to understand first.
    var knowFirst: [AtlasConcept]
    var related: [Link]
}

extension Atlas {
    func concept(_ id: String) -> AtlasConcept? {
        concepts.first { $0.id == id }
    }

    var root: AtlasConcept? { concept(rootID) }

    func children(of id: String) -> [AtlasConcept] {
        concepts.filter { $0.parentID == id && $0.id != id }
    }

    /// From the root down to `id`'s parent.
    func ancestors(of id: String) -> [AtlasConcept] {
        var chain: [AtlasConcept] = []
        var seen: Set<String> = [id]
        var cursor = concept(id)?.parentID
        while let current = cursor, seen.insert(current).inserted, let parent = concept(current) {
            chain.append(parent)
            cursor = parent.parentID
        }
        return chain.reversed()
    }

    /// `id` and everything under it, in reading order.
    func branch(of id: String) -> [AtlasConcept] {
        var result: [AtlasConcept] = []
        var seen: Set<String> = []
        func visit(_ id: String) {
            guard let concept = concept(id), seen.insert(id).inserted else { return }
            result.append(concept)
            for child in children(of: id) { visit(child.id) }
        }
        visit(id)
        return result
    }

    /// Every concept with its depth below the root, in reading order.
    func outline() -> [(concept: AtlasConcept, depth: Int)] {
        var result: [(concept: AtlasConcept, depth: Int)] = []
        var seen: Set<String> = []
        func visit(_ id: String, depth: Int) {
            guard let concept = concept(id), seen.insert(id).inserted else { return }
            result.append((concept, depth))
            for child in children(of: id) { visit(child.id, depth: depth + 1) }
        }
        visit(rootID, depth: 0)
        for concept in concepts where !seen.contains(concept.id) {
            result.append((concept, 1))
        }
        return result
    }

    func neighbourhood(of id: String) -> AtlasNeighbourhood {
        guard let focus = concept(id) else {
            return AtlasNeighbourhood(broader: [], narrower: [], knowFirst: [], related: [])
        }
        let broader = ancestors(of: id)
        let narrower = children(of: id)
        var shown: Set<String> = Set(broader.map(\.id)).union(narrower.map(\.id)).union([id])
        var knowFirst: [AtlasConcept] = []
        for relation in focus.relations where relation.kind == .prerequisite {
            guard let target = concept(relation.to), shown.insert(target.id).inserted else { continue }
            knowFirst.append(target)
        }
        var related: [AtlasNeighbourhood.Link] = []
        for relation in focus.relations where relation.kind != .prerequisite {
            guard let target = concept(relation.to), shown.insert(target.id).inserted else { continue }
            related.append(.init(concept: target, kind: relation.kind, isOutgoing: true, phrase: relation.label ?? relation.kind.outgoingPhrase))
        }
        for other in concepts where other.id != id {
            for relation in other.relations where relation.to == id {
                guard shown.insert(other.id).inserted else { continue }
                related.append(.init(concept: other, kind: relation.kind, isOutgoing: false, phrase: relation.kind.incomingPhrase))
            }
        }
        return AtlasNeighbourhood(
            broader: broader,
            narrower: narrower,
            knowFirst: knowFirst,
            related: Array(related.prefix(AtlasLimits.maximumRelations))
        )
    }

    func passage(_ id: String) -> AtlasPassage? {
        passages.first { $0.id == id }
    }

    /// A concept's passages with their stances, the strongest first.
    func evidencePassages(of id: String) -> [(passage: AtlasPassage, stance: AtlasEvidence.Stance)] {
        guard let concept = concept(id) else { return [] }
        return concept.evidence
            .enumerated()
            .sorted { ($0.element.stance.rank, $0.offset) < ($1.element.stance.rank, $1.offset) }
            .compactMap { entry in passage(entry.element.passageID).map { ($0, entry.element.stance) } }
    }

    /// The sources a concept's passages come from, the strongest first.
    func evidenceSourceIDs(of id: String) -> [String] {
        var seen: Set<String> = []
        return evidencePassages(of: id).map(\.passage.sourceID).filter { seen.insert($0).inserted }
    }

    /// What grounds a concept: its own passages, else those of the concepts
    /// under it, the strongest first (a field or a subtopic seldom cites a
    /// passage itself, but its branch does). Empty when nothing in its
    /// branch is in the library.
    func groundingPassages(of id: String, limit: Int = AtlasLimits.maximumEvidence) -> [(passage: AtlasPassage, stance: AtlasEvidence.Stance)] {
        let own = evidencePassages(of: id)
        guard own.isEmpty else { return own }
        var seen: Set<String> = []
        var found: [(passage: AtlasPassage, stance: AtlasEvidence.Stance)] = []
        for concept in branch(of: id).dropFirst() {
            for entry in evidencePassages(of: concept.id) where seen.insert(entry.passage.id).inserted {
                found.append(entry)
            }
        }
        return found.enumerated()
            .sorted { ($0.element.stance.rank, $0.offset) < ($1.element.stance.rank, $1.offset) }
            .prefix(limit)
            .map(\.element)
    }

    /// Whether the concept cites passages itself (false when only its branch does).
    func citesItself(_ id: String) -> Bool {
        !evidencePassages(of: id).isEmpty
    }

    /// The sources that ground a concept (`groundingPassages`), the strongest first.
    func groundingSourceIDs(of id: String) -> [String] {
        var seen: Set<String> = []
        return groundingPassages(of: id).map(\.passage.sourceID).filter { seen.insert($0).inserted }
    }

    /// Every source any concept cites.
    var evidenceSourceIDs: [String] {
        var seen: Set<String> = []
        return concepts.flatMap { evidenceSourceIDs(of: $0.id) }.filter { seen.insert($0).inserted }
    }

    /// How many concepts cite at least one passage.
    var groundedConceptCount: Int {
        concepts.filter { concept in concept.evidence.contains { passage($0.passageID) != nil } }.count
    }

    /// The next free passage number: passages are p1, p2, … in the order the
    /// app retrieved them.
    var nextPassageNumber: Int {
        (passages.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
    }

    /// `candidates` given ids after the pool's, leaving out any the pool
    /// already holds (the same source and text).
    func numbering(_ candidates: [AtlasPassage]) -> [AtlasPassage] {
        var held = Set(passages.map { $0.sourceID + "\u{1F}" + $0.text })
        var number = nextPassageNumber
        return candidates.compactMap { candidate in
            guard held.insert(candidate.sourceID + "\u{1F}" + candidate.text).inserted else { return nil }
            var passage = candidate
            passage.id = "p\(number)"
            number += 1
            return passage
        }
    }

    /// The Atlas with one concept written in depth: its paragraph and steps,
    /// more terms, more evidence (the passages it cites from `offered`
    /// joining the pool) and its open questions. Marked deepened.
    func merging(_ deepening: AtlasDeepening, into conceptID: String, offered: [AtlasPassage], at now: Date) -> Atlas {
        guard let index = concepts.firstIndex(where: { $0.id == conceptID }) else { return self }
        var atlas = self
        var concept = atlas.concepts[index]
        let pool = Set(atlas.passages.map(\.id))
        let offeredByID = Dictionary(offered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in deepening.evidence where !concept.evidence.contains(where: { $0.passageID == entry.passageID }) {
            if pool.contains(entry.passageID) {
                concept.evidence.append(entry)
            } else if let passage = offeredByID[entry.passageID], !atlas.passages.contains(where: { $0.id == passage.id }) {
                atlas.passages.append(passage)
                concept.evidence.append(entry)
            }
        }
        concept.evidence = Array(concept.evidence.prefix(AtlasLimits.maximumEvidence))
        if let paragraph = deepening.paragraph, !paragraph.isEmpty { concept.paragraph = paragraph }
        if !deepening.steps.isEmpty { concept.steps = deepening.steps }
        var seenTerms = Set(concept.terms.map { $0.term.lowercased() })
        for term in deepening.terms where concept.terms.count < AtlasLimits.maximumTerms && seenTerms.insert(term.term.lowercased()).inserted {
            concept.terms.append(term)
        }
        var seenQuestions = Set(concept.openQuestions.map { $0.lowercased() })
        for question in deepening.openQuestions where concept.openQuestions.count < AtlasLimits.maximumOpenQuestions && seenQuestions.insert(question.lowercased()).inserted {
            concept.openQuestions.append(question)
        }
        concept.deepened = true
        atlas.concepts[index] = concept
        atlas.updatedAt = now
        return atlas
    }

    /// This Atlas with `conceptID` as `other` has it, and the passages it
    /// cites that this one lacks: a deepening written from an older copy
    /// lands on the newest without undoing another concept's. A passage
    /// whose id was taken meanwhile joins under the next free one.
    func adopting(_ conceptID: String, from other: Atlas, at now: Date) -> Atlas {
        guard let index = concepts.firstIndex(where: { $0.id == conceptID }),
              var concept = other.concept(conceptID) else { return self }
        var atlas = self
        var held = Dictionary(atlas.passages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func freshID() -> String {
            "p\((held.keys.compactMap { Int($0.dropFirst()) }.max() ?? 0) + 1)"
        }
        concept.evidence = concept.evidence.compactMap { entry in
            guard let passage = other.passage(entry.passageID) else { return nil }
            if let same = atlas.passages.first(where: { $0.sourceID == passage.sourceID && $0.text == passage.text }) {
                return AtlasEvidence(passageID: same.id, stance: entry.stance)
            }
            var joining = passage
            if held[joining.id] != nil { joining.id = freshID() }
            atlas.passages.append(joining)
            held[joining.id] = joining
            return AtlasEvidence(passageID: joining.id, stance: entry.stance)
        }
        atlas.concepts[index] = concept
        atlas.updatedAt = now
        return atlas
    }

    // MARK: Lay Out on Canvas

    /// The Atlas, or the branch under `branchID`, as a concepts lens: each
    /// concept a field named after it with its line and the sources its
    /// passages come from (at most three), and an arrow for each causal,
    /// part-of, measuring or must-come-first relation inside it. Concepts
    /// with no source and no arrow are left off the Canvas. Nil when no
    /// concept has a source: a lens of empty fields shows nothing.
    func canvasLensRequest(branch branchID: String? = nil) -> KnowledgeMapLensRequest? {
        let members = branchID.map { branch(of: $0) } ?? outline().map(\.concept)
        guard !members.isEmpty else { return nil }
        let memberIDs = Set(members.map(\.id))
        // Names that repeat get a number: the lens keys its fields by name.
        var used: Set<String> = []
        var labels: [String: String] = [:]
        for concept in members {
            var label = concept.name
            var copy = 2
            while !used.insert(label.lowercased()).inserted {
                label = "\(concept.name) (\(copy))"
                copy += 1
            }
            labels[concept.id] = label
        }
        var links: [KnowledgeMapLensRequest.ConceptLink] = []
        var linked: Set<String> = []
        for concept in members {
            for relation in concept.relations where memberIDs.contains(relation.to) {
                guard let from = labels[concept.id], let to = labels[relation.to] else { continue }
                switch relation.kind {
                case .causes, .partOf, .measures:
                    links.append(.init(from: from, to: to, label: relation.label ?? relation.kind.outgoingPhrase))
                    linked.formUnion([concept.id, relation.to])
                case .prerequisite:
                    // What comes first points at what it is needed for.
                    links.append(.init(from: to, to: from, label: relation.label ?? "needed for"))
                    linked.formUnion([concept.id, relation.to])
                case .contrasts, .related, .example:
                    continue
                }
            }
        }
        let lensConcepts: [KnowledgeMapLensRequest.Concept] = members.compactMap { concept in
            let items = evidenceSourceIDs(of: concept.id)
                .prefix(AtlasLimits.lensSourcesPerConcept)
                .map { KnowledgeMap.ItemRef(kind: .source, id: $0) }
            guard !items.isEmpty || linked.contains(concept.id), let label = labels[concept.id] else { return nil }
            return .init(label: label, note: concept.line, items: Array(items))
        }
        guard lensConcepts.contains(where: { !$0.items.isEmpty }) else { return nil }
        let keptLabels = Set(lensConcepts.map(\.label))
        let title: String
        if let branchID, branchID != rootID, let top = concept(branchID) {
            title = "\(topic): \(top.name)"
        } else {
            title = topic
        }
        var request = KnowledgeMapLensRequest(title: title, layout: .concepts)
        request.concepts = lensConcepts
        request.conceptLinks = links.filter { keptLabels.contains($0.from) && keptLabels.contains($0.to) }
        request.hidesOthers = true
        return request
    }

    // MARK: Learn

    /// What Learn drafts cards from: the concept (its line, with its
    /// paragraph around it) and its first terms, each anchored to the
    /// passages that ground it (its own, else its branch's). Empty when
    /// nothing in its branch is in the library: a card must quote a source.
    func learnAnchors(for id: String) -> [SituatedAnchor] {
        guard let concept = concept(id) else { return [] }
        let grounding = groundingPassages(of: id)
        let sourceIDs = groundingSourceIDs(of: id)
        guard !sourceIDs.isEmpty else { return [] }
        let passages = grounding.map { SituatedPassage(sourceID: $0.passage.sourceID, text: $0.passage.text) }
        let summary = "\(concept.name): \(concept.line)"
        var anchors = [SituatedAnchor(kind: .concept, text: summary, context: concept.paragraph, sourceIDs: sourceIDs, passages: passages)]
        for term in concept.terms.prefix(AtlasLimits.learnTerms) {
            anchors.append(SituatedAnchor(kind: .term, text: "\(term.term): \(term.definition)", context: summary, sourceIDs: sourceIDs, passages: passages))
        }
        return anchors
    }

    // MARK: Storage

    static func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// The row `saveAtlasRow` writes.
    func row() throws -> AtlasRow {
        AtlasRow(
            id: id,
            topic: topic,
            notebookID: scope.notebookID,
            scopeJSON: try Self.encoded(scope),
            payloadJSON: try Self.encoded(self),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    init(row: AtlasRow) throws {
        let decoded = try JSONDecoder().decode(Atlas.self, from: Data(row.payloadJSON.utf8))
        self = decoded
        // The row's columns are what the list sorts and finds by.
        self.id = row.id
    }
}

// MARK: - Memory

/// How the kept cards on a concept's sources stand: its dot and its line.
struct AtlasMemoryStanding: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        /// No kept card yet.
        case none
        /// All holding.
        case solid
        /// Some due today.
        case due
        /// Some being forgotten.
        case fading
    }

    var cards: Int
    var due: Int
    var fading: Int

    var tone: Tone {
        if cards == 0 { return .none }
        if fading > 0 { return .fading }
        if due > 0 { return .due }
        return .solid
    }

    /// "6 cards · 2 due", or "No cards yet".
    var line: String {
        guard cards > 0 else { return "No cards yet" }
        var parts = ["\(cards) card\(cards == 1 ? "" : "s")"]
        if due > 0 { parts.append("\(due) due") }
        if fading > 0 { parts.append("\(fading) fading") }
        return parts.joined(separator: " · ")
    }

    /// Summed over a concept's sources.
    static func of(sourceIDs: [String], marks: [String: KnowledgeMapMemoryMark]) -> AtlasMemoryStanding {
        var standing = AtlasMemoryStanding(cards: 0, due: 0, fading: 0)
        for id in Set(sourceIDs) {
            guard let mark = marks[id] else { continue }
            standing.cards += mark.cards
            standing.due += mark.due
            standing.fading += mark.fading
        }
        return standing
    }
}

/// One stored Atlas in the recent list, read without its body.
struct AtlasListing: Equatable, Identifiable, Sendable {
    var id: String
    var topic: String
    var notebookID: String?
    var scope: AtlasScope
    var updatedAt: Date

    init(row: AtlasRow) {
        id = row.id
        topic = row.topic
        notebookID = row.notebookID
        scope = (try? JSONDecoder().decode(AtlasScope.self, from: Data(row.scopeJSON.utf8))) ?? AtlasScope(notebookID: row.notebookID)
        updatedAt = row.updatedAt
    }

    /// Whether this is the Atlas a request for `topic` over `scope` means: the
    /// same scope, and the same topic when one is named. A request naming no
    /// topic over the whole library means none.
    func answers(topic: String?, scope: AtlasScope) -> Bool {
        guard self.scope == scope else { return false }
        if let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
            return self.topic.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(topic) == .orderedSame
        }
        return !scope.isWholeLibrary
    }
}
