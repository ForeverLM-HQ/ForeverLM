#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// JSON-Schema subset used by every ForeverLM tutor transport. Keeping the
/// schema typed lets macOS/iOS adapt it to provider dictionaries while the
/// browser receives the exact same definitions from Swift WebAssembly.
public final class TutorJSONSchema: Codable, Equatable, Sendable {
    public let type: String
    public let description: String?
    public let properties: [String: TutorJSONSchema]?
    public let required: [String]?
    public let allowedValues: [String]?
    public let items: TutorJSONSchema?

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items
        case allowedValues = "enum"
    }

    init(
        type: String,
        description: String?,
        properties: [String: TutorJSONSchema]?,
        required: [String]?,
        allowedValues: [String]?,
        items: TutorJSONSchema?
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.allowedValues = allowedValues
        self.items = items
    }

    public static func == (lhs: TutorJSONSchema, rhs: TutorJSONSchema) -> Bool {
        lhs.type == rhs.type
            && lhs.description == rhs.description
            && lhs.properties == rhs.properties
            && lhs.required == rhs.required
            && lhs.allowedValues == rhs.allowedValues
            && lhs.items == rhs.items
    }

    static func object(
        _ properties: [String: TutorJSONSchema],
        required: [String] = [],
        description: String? = nil
    ) -> Self {
        Self(
            type: "object",
            description: description,
            properties: properties,
            required: required,
            allowedValues: nil,
            items: nil
        )
    }

    static func string(_ description: String, allowed: [String]? = nil) -> Self {
        Self(
            type: "string",
            description: description,
            properties: nil,
            required: nil,
            allowedValues: allowed,
            items: nil
        )
    }

    static func integer(_ description: String) -> Self {
        Self(type: "integer", description: description, properties: nil, required: nil, allowedValues: nil, items: nil)
    }

    static func number(_ description: String) -> Self {
        Self(type: "number", description: description, properties: nil, required: nil, allowedValues: nil, items: nil)
    }

    static func array(_ items: TutorJSONSchema, description: String) -> Self {
        Self(type: "array", description: description, properties: nil, required: nil, allowedValues: nil, items: items)
    }
}

public struct TutorToolDefinition: Codable, Equatable, Sendable {
    public let type: String
    public let name: String
    public let description: String
    public let parameters: TutorJSONSchema

    init(name: String, description: String, parameters: TutorJSONSchema) {
        type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// The deterministic catalog facts used to turn a voice request such as
/// “chapters 1 through 4 of The Beginning of Infinity” into source IDs. The
/// model may understand the request, but it never decides which stored records
/// it means: resolution below is exact and reproducible on every client.
public struct ExternalActivitySourceDescriptor: Equatable, Sendable {
    public let id: String
    public let title: String
    public let sourceType: String
    public let parentGroupID: String?
    public let groupTitle: String?
    public let sequenceNumber: Int?
    public let isAvailable: Bool

    public init(
        id: String,
        title: String,
        sourceType: String,
        parentGroupID: String? = nil,
        groupTitle: String? = nil,
        sequenceNumber: Int? = nil,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.sourceType = sourceType
        self.parentGroupID = parentGroupID
        self.groupTitle = groupTitle
        self.sequenceNumber = sequenceNumber
        self.isAvailable = isAvailable
    }
}

public enum ExternalActivityResolutionError: LocalizedError, Equatable, Sendable {
    case chooseOneIdentityMode
    case missingIdentity
    case invalidChapterRange
    case sourceNotFound(String)
    case sourceUnavailable(String)
    case bookNotFound(String)
    case ambiguousBook(String)
    case missingChapters(String, [Int])
    case ambiguousChapters(String, [Int])

    public var errorDescription: String? {
        switch self {
        case .chooseOneIdentityMode:
            return "Pass source_ids or book_title with a chapter range, not both."
        case .missingIdentity:
            return "Pass source_ids, or an exact book_title with chapter_start and chapter_end."
        case .invalidChapterRange:
            return "Chapter numbers must be positive and chapter_end must be at least chapter_start."
        case .sourceNotFound(let id):
            return "Source \(id) is not in this library or voice session."
        case .sourceUnavailable(let id):
            return "Source \(id) is archived, hidden, or not ready."
        case .bookNotFound(let title):
            return "No available imported book has the exact title “\(title)”. Use search_sources and try its book_title."
        case .ambiguousBook(let title):
            return "More than one imported book is titled “\(title)”. Ask the learner which one they mean."
        case .missingChapters(let title, let chapters):
            return "“\(title)” has no imported chapter \(Self.chapterList(chapters))."
        case .ambiguousChapters(let title, let chapters):
            return "“\(title)” has duplicate imported chapter positions at \(Self.chapterList(chapters)); ask the learner to identify the chapters individually."
        }
    }

    private static func chapterList(_ chapters: [Int]) -> String {
        chapters.map(String.init).joined(separator: ", ")
    }
}

public enum ExternalActivitySourceResolver {
    public static func resolve(
        sourceIDs rawSourceIDs: [String],
        bookTitle rawBookTitle: String?,
        chapterStart: Int?,
        chapterEnd: Int?,
        catalog: [ExternalActivitySourceDescriptor]
    ) throws -> [String] {
        let sourceIDs = rawSourceIDs.reduce(into: [String]()) { result, raw in
            let id = trimmed(raw)
            if !id.isEmpty, !result.contains(id) { result.append(id) }
        }
        let bookTitle = rawBookTitle.map(trimmed) ?? ""
        let hasBookMode = !bookTitle.isEmpty || chapterStart != nil || chapterEnd != nil
        guard sourceIDs.isEmpty || !hasBookMode else {
            throw ExternalActivityResolutionError.chooseOneIdentityMode
        }

        if !sourceIDs.isEmpty {
            let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in sourceIDs {
                guard let source = byID[id] else {
                    throw ExternalActivityResolutionError.sourceNotFound(id)
                }
                guard source.isAvailable else {
                    throw ExternalActivityResolutionError.sourceUnavailable(id)
                }
            }
            return sourceIDs
        }

        guard !bookTitle.isEmpty, let chapterStart, let chapterEnd else {
            throw ExternalActivityResolutionError.missingIdentity
        }
        guard chapterStart > 0, chapterEnd >= chapterStart, chapterEnd - chapterStart < 10_000 else {
            throw ExternalActivityResolutionError.invalidChapterRange
        }

        let normalizedTitle = normalized(bookTitle)
        let matching = catalog.filter {
            $0.isAvailable
                && normalized($0.sourceType) == "book"
                && $0.parentGroupID != nil
                && normalized($0.groupTitle ?? "") == normalizedTitle
        }
        let groupIDs = Set(matching.compactMap { $0.parentGroupID })
        guard !groupIDs.isEmpty else {
            throw ExternalActivityResolutionError.bookNotFound(bookTitle)
        }
        guard groupIDs.count == 1 else {
            throw ExternalActivityResolutionError.ambiguousBook(bookTitle)
        }

        let desired = Array(chapterStart...chapterEnd)
        let bySequence = Dictionary(grouping: matching.compactMap { source -> (Int, String)? in
            guard let sequenceNumber = source.sequenceNumber else { return nil }
            return (sequenceNumber, source.id)
        }, by: { $0.0 })
        let missing = desired.filter { bySequence[$0] == nil }
        if !missing.isEmpty {
            throw ExternalActivityResolutionError.missingChapters(bookTitle, missing)
        }
        let ambiguous = desired.filter { (bySequence[$0]?.count ?? 0) != 1 }
        if !ambiguous.isEmpty {
            throw ExternalActivityResolutionError.ambiguousChapters(bookTitle, ambiguous)
        }
        return desired.compactMap { bySequence[$0]?.first?.1 }
    }

    private static func normalized(_ value: String) -> String {
        trimmed(value).lowercased()
    }

    private static func trimmed(_ value: String) -> String {
        func isWhitespace(_ character: Character) -> Bool {
            character == " " || character == "\t" || character == "\n" || character == "\r"
        }
        guard let start = value.firstIndex(where: { !isWhitespace($0) }),
              let end = value.lastIndex(where: { !isWhitespace($0) }) else { return "" }
        return String(value[start...end])
    }
}

/// One tutor behavior and tool contract for macOS, iOS, and Web Studio.
public enum TutorContract {
    public static let protocolVersion = 3

    public static let coreInstructions = """
    You are ForeverLM's voice tutor and hands-free app operator. Keep every voice turn short, plain, and speakable: one or two sentences, one question at a time, never lists or markdown. In text chat you may use compact markdown when it improves clarity.

    The learner's latest spoken request owns the agenda. Answer it or perform it directly, and never ignore it to finish a greeting or resume a proactive suggestion. You may offer a review exactly once, at the very start of a session, and only when the app has told you one is ready and not already declined today. If they do not take it, drop it: never raise it again inside the same session, and never interrupt an answer with it.

    You work over the learner's saved sources and app state through tools:
    - Schedule and learning activity: ALWAYS call get_schedule for anything about the Schedule, assigned or planned work, yesterday, today, tomorrow, dates, or weekdays. Use date_basis=planned for assigned/planned work. Reading, listening, watching, source chat, and review activity are logged automatically; use date_basis=activity for requests such as "review what I read or listened to yesterday." Use date_basis=completed only when the learner explicitly asks what they finished. Never answer these requests from general knowledge or search_sources.
    - Finding things: use search_sources for author names, titles, journals, years, source types, topics, recent additions, "latest papers", or "last N". Spoken names may be misspelled: inspect approximate matches and recent candidates before claiming a source is absent.
    - Logging outside activity: when the learner says they read, listened to, or watched saved material outside ForeverLM, call log_external_activity. First use search_sources to obtain exact source IDs or the exact book_title and chapter_number values. Never guess which source or chapter a spoken title means; if the tool reports ambiguity or a missing chapter, ask the learner.
    - Discussing: call load_source with a source_id returned by get_schedule or search_sources, then answer only from that source's text: the full_text it returns, or, where the app keeps the text on the device, the passages read_source_passages and read_source_range return. Never reload a source already in context. If the text does not support a claim, say so plainly.
    - Figures: call show_paper_figure whenever the learner asks about a figure, graph, diagram, or subfigure.
    - Today's review: when the learner asks to start their review, today's review, or their daily memory review, call start_memory_review FIRST. If it returns status ready, continue that review from its briefing and transcript and do not call get_memory_review_queue for it. If it returns unavailable, say why in one sentence and only then fall back to get_memory_review_queue.
    - Memory review: ALWAYS call get_memory_review_queue when the learner asks what is due, what they are forgetting, or to start a memory review. Load only identities returned by that tool and record every grade. For an existing item assert its exact memory_item_id. An item that comes with `ask` is a card the learner kept: ask that wording exactly as written, grade against its target, and record that wording as the question asked. For any other item, devise a fresh retrieval question instead of reciting a static flashcard. If loading or recording fails, surface the error and stop; never pretend the attempt was saved.
    - Whole-source review selection: ALWAYS call get_review_queue when the learner asks what they should review or whether a source has already been quizzed. Trust its `reviewed` and `never_reviewed` state. Never claim the learner has or has not reviewed something from memory or a schedule row alone.
    - Whole-source review: ALWAYS call prepare_review before asking the first quiz or review question. It must return a source-grounded guide. If preparation fails, surface the error and do not invent a fallback quiz.

    During a review, ask one focused question at a time. After every learner answer, grade strictly against the prepared guide and loaded source, give concise feedback, and call record_grade. Credit only demonstrated understanding. Never decide that the review is over because a question count was reached or the main concepts were covered. Continue for as many turns or hours as the learner wants; do not proactively suggest ending. Do not say goodbye or call end_session unless the learner explicitly asks to stop or confirms they want to finish. Only then call end_session.

    \(questionQualityInstructions)
    """

    /// What separates a question worth answering from one that merely mentions
    /// the right topic.
    ///
    /// The first block is Matuschak's prompt properties, minus one. The second
    /// exists because models reliably fail on conceptual material in one specific
    /// way — they reinforce what a source *says* rather than what it means — and a
    /// general instruction to "go deeper" does not fix it; naming the question
    /// types does.
    ///
    /// **"Consistent" is deliberately absent, and its opposite is required here.**
    /// That property — a prompt should cue the same answer every time — exists to
    /// protect a *stored* card that will be reviewed unchanged for years. These
    /// rules are for the questions a tutor composes, which live for one turn.
    /// Removing durability removes the constraint, and removes with it the
    /// judgment call models are worst at (whether a prompt will still read
    /// cleanly in six months). Variation is the point, not a defect. Do not
    /// "restore" consistency.
    ///
    /// A card the learner kept (a Memory item with `rubricJSON.card`) is the
    /// exception, and is not composed at all: it is asked in the wording the app
    /// hands over (`ask`: its front or the learner's rewording, and over MCP's
    /// `memory_review` one of its rewordings once it has been remembered twice,
    /// by `MemoryCardWording.asked`) and that wording is recorded as the
    /// attempt's prompt. Its variation is the app's, not the tutor's: rewordings
    /// made and checked once at the day close (`CardVariationPass`), which vary
    /// the question and keep the answer.
    public static let questionQualityInstructions = """
    Every question you compose, in any review, must be:
    - FOCUSED. One thing at a time. A question carrying three clauses produces a vague, partial answer and tells you nothing.
    - PRECISE. It must be unambiguous what is being asked for, so a correct answer cannot be mistaken for a wrong one.
    - TRACTABLE. They should be able to answer it if they understood the material. If they cannot, break it down rather than repeating it louder.
    - EFFORTFUL. It must require retrieval or reasoning. If the answer is contained in the question, or follows from the phrasing, it is worthless.
    - FRESHLY WORDED. Never reuse the wording of a previous question about the same idea, even your own. Identical wording trains recognition of the question rather than knowledge of the answer.

    A question must never stand alone. An idea reviewed in isolation from everything else the learner knows decays and goes stale, so prefer a question that reaches for a second source, an earlier session, or something they already understand, over one that stays inside a single passage.

    Never ask a yes/no question. Never ask a question whose answer is a definition you just supplied. Keep questions short: a long, unusually-worded question is answered by pattern-matching its shape rather than by understanding.

    On conceptual material, do NOT ask what the source says. Ask instead:
    - CLASSIFY: give a case that was not in the source and ask whether the concept applies, and why.
    - CONTRAST: ask how it differs from the neighbouring idea it is most often confused with.
    - CAUSE: ask what breaks, or what follows, if one part of the mechanism changes.
    - PURPOSE: ask why the idea matters, or what it buys you that the simpler alternative does not.
    - APPLY: hand them a concrete situation and ask what they would predict or do.
    - CONNECT: ask them to reconcile it with something else they have read.

    When example questions from this learner's own past reviews are supplied, treat them as the standard to match — they are questions that already worked for this person on this material. Match their grain and difficulty rather than imitating their wording.

    A note the learner wrote on a highlight is their own elaboration — they already did the work of saying what the passage meant to them. Build on what they wrote rather than restating the passage they wrote it about.

    Before a review ends, ask them once what they want brought back next time, in their own words. Deciding what is worth returning to is itself the useful work, and it is work only they can do; what they name is recorded as theirs and outranks anything you would have chosen.
    """

    public static let reviewPreparationInstructions = """
    You prepare a rigorous oral review guide from one source. Work exclusively from the supplied source text; never add facts, interpretations, or expected answers that the source does not support.

    Return a compact plain-text guide with exactly these sections:

    KEY IDEAS
    5-7 numbered concepts that matter most for understanding the source. Prioritize mechanisms, causal relationships, methods, major claims, quantitative results, assumptions, limitations, and trade-offs over terminology or trivia.

    REVIEW QUESTIONS AND ANSWER GUIDES
    For each key idea, provide:
    - Question: one deep, speakable question that makes the learner explain how or why something works. Avoid yes/no questions and shallow recall.
    - Strong answer: the specific reasoning and source-grounded details a strong answer should contain, including important numbers or caveats when the source gives them.
    - Probe: one short follow-up question to use when the learner's answer is vague or incomplete.

    CONNECTION QUESTION
    One final question that asks the learner to connect at least two of the key ideas, plus a source-grounded strong answer.

    Keep the whole guide concise enough for another model to use during a live conversation. Do not address the learner, grade anyone, summarize every section of the source, or wrap the guide in JSON or a Markdown code fence.
    """

    public static let scheduleTool = TutorToolDefinition(
        name: "get_schedule",
        description: "Get the learner's Schedule and automatic source activity for a relative local day or range. Use date_basis=planned for assigned work, activity for reading/listening/source-chat/review activity, and completed only for explicitly finished work. Always use this—not search_sources—for yesterday, today, tomorrow, date, or weekday questions.",
        parameters: .object([
            "start_day_offset": .integer("First local calendar day relative to today; defaults to 0."),
            "day_count": .integer("Number of consecutive days; default 1 and maximum 31."),
            "date_basis": .string("Which timestamp must fall in the range; planned for assigned work, activity for automatic reading/listening/chat/review history, completed for explicitly finished work. Defaults to planned.", allowed: ["planned", "activity", "completed"]),
            "activity_kind": .string("Optional activity-only filter. Use it when the learner specifically says read, listened, watched, chatted, or reviewed.", allowed: ["reading", "listening", "watching", "chat", "review"]),
            "completion": .string("Completion filter; defaults to any.", allowed: ["any", "pending", "completed"]),
            "limit": .integer("Maximum rows; default 12 and maximum 30."),
        ])
    )

    public static let reviewQueueTool = TutorToolDefinition(
        name: "get_review_queue",
        description: "Always use this to choose what needs whole-source review or answer whether something has already been quizzed. Returns recently read or scheduled sources ranked by need, with reviewed/never_reviewed state.",
        parameters: .object([
            "limit": .integer("Maximum rows, from 1 through 15."),
        ])
    )

    public static let searchSourcesTool = TutorToolDefinition(
        name: "search_sources",
        description: "Search saved sources by identifying words from title, author, journal, year, topic, or type. Omit query to list recent sources. Inspect recent_candidates before concluding a spoken or misspelled name is absent.",
        parameters: .object([
            "query": .string("Identifying words only; omit filler such as find, paper, and et al."),
            "source_type": .string("Optional filter such as paper, article, podcast, video, book, or course."),
            "limit": .integer("Maximum results; default 10 and maximum 20."),
        ])
    )

    public static let logExternalActivityTool = TutorToolDefinition(
        name: "log_external_activity",
        description: "Log saved material completed outside ForeverLM and mark it read. Use after search_sources for requests such as ‘I listened to chapters 1–4 of this book.’ Pass exact source_ids, or the exact returned book_title plus an inclusive chapter range. Record identity is resolved deterministically; ambiguity or missing chapters fail instead of guessing.",
        parameters: .object([
            "source_ids": .array(.string("Exact source ID returned by search_sources or get_schedule."), description: "One or more exact standalone source or chapter IDs."),
            "book_title": .string("Exact book_title returned by search_sources."),
            "chapter_start": .integer("First imported chapter_number in the inclusive book range."),
            "chapter_end": .integer("Last imported chapter_number in the inclusive book range."),
            "kind": .string("How the learner consumed the material.", allowed: ["reading", "listening", "watching"]),
            "date": .string("Optional local completion day in YYYY-MM-DD; defaults to today."),
        ], required: ["kind"])
    )

    public static let loadSourceTool = TutorToolDefinition(
        name: "load_source",
        description: "Load a source's canonical full text for discussion. Use an exact source_id returned by get_schedule or search_sources.",
        parameters: .object([
            "source_id": .string("Exact source_id returned by another ForeverLM tool."),
        ], required: ["source_id"])
    )

    public static let showPaperFigureTool = TutorToolDefinition(
        name: "show_paper_figure",
        description: "Show and explain an original figure from a loaded research paper. Call whenever a learner asks about a figure, graph, diagram, or subfigure.",
        parameters: .object([
            "source_id": .string("Source ID; omit for the currently loaded paper."),
            "figure_label": .string("Printed label such as Figure 2 or Fig. 3."),
            "panel_label": .string("Optional subfigure label such as b."),
        ], required: ["figure_label"])
    )

    public static let startMemoryReviewTool = TutorToolDefinition(
        name: "start_memory_review",
        description: "Today's prepared memory review — the plan (briefing) and the transcript so far. Call first when the learner asks to start their review, today's review, or their daily memory review. On status ready, continue that review from where the transcript stands; on unavailable, say why and fall back to get_memory_review_queue only if the learner still wants a memory check.",
        parameters: .object([:])
    )

    public static let memoryReviewQueueTool = TutorToolDefinition(
        name: "get_memory_review_queue",
        description: "Get the bounded concept-memory queue. Existing items return an item_id; first_review entries return a source_id. Use only identities returned by this tool.",
        parameters: .object([
            "limit": .integer("Maximum due items; default 5 and maximum 12."),
        ])
    )

    public static let loadMemoryItemTool = TutorToolDefinition(
        name: "load_memory_item",
        description: "Load one exact memory queue result before asking its first question. Pass either item_id or source_id, never both.",
        parameters: .object([
            "item_id": .string("Exact existing item_id returned by get_memory_review_queue."),
            "source_id": .string("Exact first-review source_id returned by get_memory_review_queue."),
        ])
    )

    public static let prepareReviewTool = TutorToolDefinition(
        name: "prepare_review",
        description: "Always call this before asking quiz or review questions. It loads the source and uses the same model selected for Chat to produce a source-grounded curriculum and answer guide; preparation waits for that source instead of failing while ingestion finishes. Use the guide for sharper source-grounded questions. If it fails, surface the error and do not invent a fallback.",
        parameters: .object([
            "source_id": .string("Exact source_id; omit only when the intended source is already loaded."),
        ])
    )

    public static let recordGradeTool = TutorToolDefinition(
        name: "record_grade",
        description: "Record a strict source-grounded grade after every learner answer before continuing.",
        parameters: .object([
            "question": .string("The question asked."),
            "user_answer": .string("The learner's answer."),
            "evaluation": .string("Concise source-grounded evaluation."),
            "score": .number("Honest credit from 0.0 through 1.0."),
            "memory_item_id": .string("Exact existing memory item ID when reviewing one."),
            "source_id": .string("Exact first-review source ID when creating a memory item."),
            "semantic_target": .string("First review only: one stable source-grounded retrieval target."),
            "rubric": .array(.string("One compact criterion."), description: "First review only: 1 to 12 criteria for a strong answer."),
            "evidence_excerpt": .string("First review only: exact 20 to 2000 character canonical-source excerpt."),
            "retrieval_quality": .string("Memory review retrieval quality.", allowed: ["not_recalled", "hinted", "independent"]),
            "misconception": .string("Optional misconception worth revisiting."),
            "missing_rubric_elements": .array(.string("Missing rubric element."), description: "Rubric elements still missing; empty when none."),
        ], required: ["question", "user_answer", "evaluation", "score"])
    )

    public static func endSessionTool(supportsGaps: Bool) -> TutorToolDefinition {
        var properties: [String: TutorJSONSchema] = [
            "overall_score": .number("Honest overall mastery from 0.0 through 1.0."),
            "summary": .string("One or two sentences on understanding and remaining work."),
        ]
        if supportsGaps {
            properties["gaps"] = .array(
                .object([
                    "summary": .string("Misunderstanding worth revisiting."),
                    "severity": .number("Severity from 0.0 through 1.0."),
                ], required: ["summary", "severity"]),
                description: "Notebook misunderstandings worth revisiting; empty when none."
            )
        }
        return TutorToolDefinition(
            name: "end_session",
            description: "End and save only after the learner explicitly asks to stop or confirms they want to finish. Never call this merely because the planned concepts were covered or a question count was reached.",
            parameters: .object(properties, required: ["overall_score"])
        )
    }

    public static func tools(
        includeWholeSourceReviewQueue: Bool,
        endSessionSupportsGaps: Bool
    ) -> [TutorToolDefinition] {
        var result = [scheduleTool]
        if includeWholeSourceReviewQueue { result.append(reviewQueueTool) }
        result.append(contentsOf: [
            searchSourcesTool,
            logExternalActivityTool,
            loadSourceTool,
            showPaperFigureTool,
            startMemoryReviewTool,
            memoryReviewQueueTool,
            loadMemoryItemTool,
            prepareReviewTool,
            recordGradeTool,
            endSessionTool(supportsGaps: endSessionSupportsGaps),
        ])
        return result
    }

    public static func encodedTools(
        includeWholeSourceReviewQueue: Bool,
        endSessionSupportsGaps: Bool
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(tools(
            includeWholeSourceReviewQueue: includeWholeSourceReviewQueue,
            endSessionSupportsGaps: endSessionSupportsGaps
        )) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
