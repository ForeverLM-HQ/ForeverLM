import Foundation

/// One saved turn of the day's memory review, as every client stores it.
struct MobileMemoryReviewExchange: Equatable, Sendable {
    let sequenceNumber: Int
    let question: String
    let userAnswer: String?
    let evaluation: String?
    let score: Double?
    /// `[MemoryIdeaCoverage]` JSON, present once the contour was graded.
    let ideaCoverage: String?
    let questionVerdict: String?
    let operation: String?
    let steer: String?
    let answeredAt: Date?
    let sourceRefs: [String]

    var isAnswered: Bool {
        !(userAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var graded: MemoryReviewSourceStatus.GradedExchange {
        .init(sequenceNumber: sequenceNumber, ideaCoverage: ideaCoverage, questionVerdict: questionVerdict, answeredAt: answeredAt, operation: operation)
    }
}

/// The day's memory review chat, read from the synced record.
struct MobileMemoryReviewRecord: Equatable, Sendable {
    let id: String
    let topic: String
    let status: String
    let briefing: String?
    let sourceIDs: [String]
    let startedAt: Date
    let exchanges: [MobileMemoryReviewExchange]
    /// Today's topics, when the review was planned by topic (docs/memory-design.md,
    /// "Review by topic"): read off the briefing once, less the ideas of any
    /// source the learner took out. Empty for a review planned source by
    /// source, which keeps the contour grader and the per-exchange cards for it.
    let topics: [MemoryReviewTopic]

    init(
        id: String,
        topic: String,
        status: String,
        briefing: String?,
        sourceIDs: [String],
        startedAt: Date,
        exchanges: [MobileMemoryReviewExchange]
    ) {
        self.id = id
        self.topic = topic
        self.status = status
        self.briefing = briefing
        self.sourceIDs = sourceIDs
        self.startedAt = startedAt
        self.exchanges = exchanges
        self.topics = MemoryReviewTutoring.topics(inBriefing: briefing)
    }

    var isActive: Bool { status == "active" }

    var isByTopic: Bool { !topics.isEmpty }

    /// Which sources have had their contour graded, for the checkmarks, and
    /// which topics their opening, keyed by topic id.
    var sourceStatuses: [String: MemoryReviewSourceStatus] {
        MemoryReviewSourceStatus.statuses(from: exchanges.map(\.graded), topics: topics)
    }

    /// Every idea today's review has graded, with its latest grade and how
    /// often it came back missing: a topic card's ledger, and what tells the
    /// topic grader whether an answer is the opening or a probe.
    var ideaStates: [String: MemoryReviewIdeaState] {
        MemoryReviewIdeaState.states(from: exchanges.map(\.graded))
    }

    /// The question the learner is being asked right now: the newest tutor
    /// text — an unanswered opener, or the reply that ended the last exchange.
    var openQuestion: String? {
        guard let last = exchanges.last else { return nil }
        if !last.isAnswered { return last.question }
        return last.evaluation
    }

    /// The source, or topic, the tutor is on: its last turn line, else its
    /// last grade.
    var currentSourceID: String? {
        MemoryReviewSourceStatus.currentSourceID(
            from: exchanges.map {
                .init(sequenceNumber: $0.sequenceNumber, question: $0.question, ideaCoverage: $0.ideaCoverage, evaluation: $0.evaluation)
            },
            topics: topics
        )
    }

    /// The source under discussion has a graded contour, or the topic its
    /// opening: the chips show, under the graded reply and every reply after
    /// it on that source or topic, the way the Mac shows them.
    var awaitsSteer: Bool {
        MemoryReviewSourceStatus.offersSteer(currentSourceID: currentSourceID, statuses: sourceStatuses)
    }
}

enum MobileMemoryReviewStoreError: LocalizedError {
    case malformedRecord(String)
    case conflict
    case noOpenQuestion

    var errorDescription: String? {
        switch self {
        case .malformedRecord(let id):
            return "Today's review (\(id)) is stored in a shape this app cannot read. Update ForeverLM."
        case .conflict:
            return "Today's review changed on another device while this turn was being saved. Reopen it to continue."
        case .noOpenQuestion:
            return "There is no open question to answer yet."
        }
    }
}

/// The phone's access to the day's memory review: the `Chat` of kind `memory` in the learner's `Library`
/// with one `Exchange` per turn and its briefing a satellite (§3.5.13, §3.5.14), read from the replica
/// and written through `MobileRecordWriter`.
actor MobileMemoryReviewStore {
    static let shared = MobileMemoryReviewStore()

    private let recordWriter: @Sendable () async -> MobileRecordWriter?
    /// Briefings read from their satellites, by hash: a FileRef names the same bytes for good.
    private var briefings: [String: String] = [:]

    init(writer: @escaping @Sendable () async -> MobileRecordWriter? = { await MobileRecordWriter.current() }) {
        recordWriter = writer
    }

    private func requiredWriter() async throws -> MobileRecordWriter {
        guard let writer = await recordWriter() else { throw MobileRecordWriterError.zoneNotHeld }
        return writer
    }

    // MARK: - Reading

    /// The day's review, or nil when no device has prepared one.
    func fetch(sessionID: String) async throws -> MobileMemoryReviewRecord? {
        let writer = try await requiredWriter()
        guard let held = try await writer.read({ try $0.memoryReview(sessionID) }) else { return nil }
        return try await parse(held, sessionID: sessionID, writer: writer)
    }

    // MARK: - Writing

    struct Draft: Sendable {
        let sessionID: String
        let topic: String
        let briefing: String
        let sourceIDs: [String]
        /// Portable identity of each source, so the Mac maps them onto its rows.
        let sourceIdentities: [[String: String]]
        let modelProvider: String
        let modelID: String
        let openingQuestion: String
        let startedAt: Date
    }

    /// Creates the day's review with its opening question. When another device
    /// got there first, its record is what comes back — the day has one chat.
    func create(_ draft: Draft) async throws -> MobileMemoryReviewRecord {
        if let existing = try await fetch(sessionID: draft.sessionID) { return existing }
        let writer = try await requiredWriter()
        // The briefing's bytes before the chat points at them (§3.5.30 rule 2).
        guard let blobs = writer.blobs,
              let zone = try await writer.replica.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        else { throw MobileRecordWriterError.zoneNotHeld }
        let briefing = try await blobs.upload(Data(draft.briefing.utf8), owner: draft.sessionID, ownerType: .chat, role: "briefing",
                                              mime: "text/plain", encoding: .gzip, into: zone)
        briefings[briefing.hash] = draft.briefing
        try await writer.transaction { try $0.createMemoryReview(draft, briefing: briefing) }
        guard let created = try await fetch(sessionID: draft.sessionID) else { throw MobileMemoryReviewStoreError.malformedRecord(draft.sessionID) }
        return created
    }

    /// Records the tutor's opening question on a review that has none yet.
    func recordOpeningQuestion(sessionID: String, question: String) async throws -> MobileMemoryReviewRecord {
        try await requiredWriter().transaction { try $0.recordMemoryReviewOpening(sessionID: sessionID, question: question) }
        guard let review = try await fetch(sessionID: sessionID) else { throw MobileMemoryReviewStoreError.malformedRecord(sessionID) }
        return review
    }

    /// Records one turn: the learner's answer to the open question, the
    /// tutor's reply, and the grade when there was one. The steer the learner
    /// gave before answering lands on the exchange it steered.
    func recordTurn(
        sessionID: String,
        answer: String,
        reply: String,
        grade: MemoryContourGrade?,
        steerBefore: MemoryReviewSteer?,
        answeredAt: Date = Date()
    ) async throws -> MobileMemoryReviewRecord {
        try await requiredWriter().transaction {
            try $0.recordMemoryReviewTurn(sessionID: sessionID, answer: answer, reply: reply, grade: grade,
                                          steerBefore: steerBefore, answeredAt: answeredAt)
        }
        guard let review = try await fetch(sessionID: sessionID) else { throw MobileMemoryReviewStoreError.malformedRecord(sessionID) }
        return review
    }

    /// The same id the Mac derives for an exchange it saves without one.
    static func exchangeID(sessionID: String, sequence: Int) -> String {
        "\(sessionID)::exchange::\(String(format: "%04d", sequence))"
    }

    /// The review as the replica holds it: the Chat (its `title` is the topic, `ended` reads as
    /// `completed`), its explicit sources, its briefing's text, and its exchanges with their grading.
    private func parse(_ held: MobileMemoryReviewHeld, sessionID: String, writer: MobileRecordWriter) async throws -> MobileMemoryReviewRecord {
        let fields = held.chat.fields
        guard fields["kind"]?.stringValue == ChatKind.memory.rawValue || MemoryReviewSession.isMemorySession(sessionID) else {
            throw MobileMemoryReviewStoreError.malformedRecord(sessionID)
        }
        var briefing: String?
        if let file = fields["briefing"].flatMap(FileRef.init(json:)) {
            if let cached = briefings[file.hash] {
                briefing = cached
            } else if let blobs = writer.blobs,
                      let zone = try await writer.replica.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) }) {
                briefing = String(decoding: try await blobs.fetch(file, from: zone), as: UTF8.self)
                briefings[file.hash] = briefing
            }
        }
        let sourceIDs = (fields["contextSourceIDs"]?.objectValue ?? [:]).compactMap { $0.value == .bool(true) ? $0.key : nil }.sorted()
        return MobileMemoryReviewRecord(
            id: sessionID,
            topic: fields["title"]?.stringValue ?? MemoryReviewSession.title(for: Date()),
            status: fields["status"]?.stringValue == "active" ? "active" : "completed",
            briefing: briefing,
            sourceIDs: sourceIDs,
            startedAt: fields["createdAt"]?.int64Value.map(SyncTime.date(milliseconds:)) ?? Date(),
            exchanges: held.exchanges.map(Self.exchange)
        )
    }

    static func exchange(_ envelope: SyncEnvelope) -> MobileMemoryReviewExchange {
        let fields = envelope.fields
        let grading = fields["grading"]?.objectValue
        let coverage = grading?["ideaCoverage"]?.arrayValue.map { entries in
            entries.compactMap { entry -> MemoryIdeaCoverage? in
                guard let idea = entry["ideaID"]?.stringValue, let status = entry["status"]?.stringValue.flatMap(MemoryIdeaCoverage.Status.init(rawValue:))
                else { return nil }
                return MemoryIdeaCoverage(ideaID: idea, status: status)
            }
        }
        return MobileMemoryReviewExchange(
            sequenceNumber: fields["seq"]?.intValue ?? 0,
            question: fields["question"]?.stringValue ?? "",
            userAnswer: fields["userAnswer"]?.stringValue,
            evaluation: fields["evaluation"]?.stringValue,
            score: fields["score"]?.numberValue,
            ideaCoverage: coverage.flatMap(MemoryIdeaCoverage.encode),
            questionVerdict: grading?["questionVerdict"]?.stringValue,
            operation: grading?["operation"]?.stringValue,
            steer: grading?["steer"]?.stringValue,
            answeredAt: fields["answeredAt"]?.int64Value.map(SyncTime.date(milliseconds:)),
            sourceRefs: fields["sourceRefs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }
}

/// Writes the ideas the phone extracted: a source's ideas are its `ideas` satellite, uploaded first, and
/// `Source.derived.ideas` is set with a provisional stamp only when the source has none, so a Mac maker's
/// output beats it (§10).
actor MobileSourceIdeaStore {
    static let shared = MobileSourceIdeaStore()

    private let recordWriter: @Sendable () async -> MobileRecordWriter?

    init(writer: @escaping @Sendable () async -> MobileRecordWriter? = { await MobileRecordWriter.current() }) {
        recordWriter = writer
    }

    /// The active ideas the learner's own sources' `ideas` satellites hold, in their stored order; a
    /// source with none, or whose satellite cannot be read now, is absent.
    func ideas(sourceIDs: [String]) async -> [String: [SourceIdea]] {
        guard let writer = await recordWriter(), let blobs = writer.blobs,
              let zone = try? await writer.replica.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        else { return [:] }
        var result: [String: [SourceIdea]] = [:]
        for sourceID in Set(sourceIDs) {
            guard let file = try? await writer.read({ try $0.ideasFile(sourceID: sourceID) }),
                  let data = try? await blobs.fetch(file, from: zone) else { continue }
            let ideas = MobileSourceIdeasSatellite.decode(data).filter { $0.sourceID == sourceID && $0.status == .active }
                .sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }
            if !ideas.isEmpty { result[sourceID] = ideas }
        }
        return result
    }

    /// Saves a source's ideas, when the source names none yet.
    func save(_ ideas: [SourceIdea], sourceIdentity: [String: String]) async throws {
        guard let writer = await recordWriter(), let blobs = writer.blobs,
              let zone = try await writer.replica.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        else { throw MobileRecordWriterError.zoneNotHeld }
        for (sourceID, ideas) in Dictionary(grouping: ideas, by: \.sourceID) {
            // A source that names ideas already keeps them; one only in a space is not the phone's to write.
            guard try await writer.read({ try $0.held(.source, sourceID, in: MobileWrite.catalogKey) != nil && $0.ideasFile(sourceID: sourceID) == nil })
            else { continue }
            let file = try await blobs.upload(try MobileSourceIdeasSatellite.encode(ideas), owner: sourceID, ownerType: .source,
                                              role: MobileSourceIdeasSatellite.role, mime: "application/json", encoding: .gzip, into: zone)
            try await writer.transaction { try $0.pointAtIdeas(sourceID: sourceID, file: file) }
        }
    }
}
