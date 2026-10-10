import Combine
import Foundation

/// One transcript row of today's review on the phone.
struct MobileMemoryReviewMessage: Identifiable, Equatable {
    enum Role: Equatable { case tutor, learner }

    let id: String
    let role: Role
    var content: String
    var isStreaming: Bool = false
    var rendered: AttributedString?
    /// The last source a tutor turn turns to with a `<flm_source_turn>` line,
    /// read before the line is stripped: what the card it ends names.
    var sourceID: String?
}

/// Today's memory review as a conversation on the phone.
///
/// The Mac's session manager runs a memory review as a chat whose stable
/// briefing is the plan and the material, grades a contour through a tool call,
/// and records every turn on the day's session. This does the same against the
/// same synced record, with one difference of mechanism: the phone's chat stack
/// has no tool plumbing, so the grade is a structured step before the reply —
/// the same fields the Mac's tool asks for, validated by the same
/// `MemoryContourGrade.validate`, acknowledged to the tutor in the same words —
/// and the reply is then streamed with that acknowledgement in hand. The learner
/// sees the same transcript, the same chips, and the same checkmarks either way.
///
/// A review planned by topic (docs/memory-design.md, "Review by topic") runs
/// the same way with the topic grader: the structured step asks for
/// `grade_topic_recall`'s fields, `MemoryContourGrade.validateTopic` checks
/// them against the briefing's topics, and the grade lands on the exchange
/// as a contour grade does. A briefing without topics changes nothing.
@MainActor
final class MobileMemoryReviewViewModel: ObservableObject {
    @Published private(set) var record: MobileMemoryReviewRecord?
    @Published private(set) var messages: [MobileMemoryReviewMessage] = []
    @Published var draft = ""
    @Published private(set) var isResponding = false
    @Published private(set) var isOpening = false
    @Published private(set) var workingLabel = ""
    @Published var errorMessage: String?

    private let store = MobileMemoryReviewStore.shared
    private let catalog = MobileCloudSourceCatalog.shared
    private var ideasBySource: [String: [SourceIdea]] = [:]
    /// Today's topics, off the record's briefing; empty for a review planned
    /// source by source.
    @Published private(set) var topics: [MemoryReviewTopic] = []
    private var depthBySource: [String: MemoryReviewDepth] = [:]
    private var sourceTitles: [String: String] = [:]
    /// Every source and chat the briefing names, by id, so a chat in the day's
    /// material has a name on its card too.
    private var briefingTitles: [String: String] = [:]
    /// The notebooks holding each of the day's sources, for an understanding
    /// probe's analogy partner (`MemoryUnderstandingProbe`).
    private var notebooksBySource: [String: [MemoryUnderstandingProbe.Notebook]] = [:]
    /// The understanding probe Go deeper asked last in this review, so the
    /// next rotates past it; the saved grades say it after a relaunch.
    private var lastProbeKind: MemoryUnderstandingProbe.Kind?
    /// The understanding probe waiting for the learner's answer: the grading
    /// step is told what it was, since the note that asked for it rides only
    /// on the turn it was sent with.
    private var pendingProbe: (kind: MemoryUnderstandingProbe.Kind, ideaID: String)?
    private var pendingSteer: MemoryReviewSteer?
    private var sendTask: Task<Void, Never>?
    /// Ideas, titles and depths for the grader. Loaded beside the transcript
    /// rather than before it: it can wait on a catalog sync, and the learner
    /// needs it only when they answer.
    private var contextTask: Task<Void, Never>?
    private var didFinish = false
    /// Whether opening prepares today's review when no device has: voice's
    /// review does; the card review's Continue Today's Review Chat, which
    /// only resumes a chat already answered in, does not.
    private let preparesIfMissing: Bool

    init(preparesIfMissing: Bool = true) {
        self.preparesIfMissing = preparesIfMissing
    }

    static let usageProvider = "OpenRouter"
    private static let streamPublishInterval: TimeInterval = 0.075

    var title: String { record?.topic ?? MemoryReviewSession.title(for: Date()) }

    var awaitsSteer: Bool { record?.awaitsSteer ?? false }

    var canCompose: Bool { record != nil && !isOpening }

    /// Whether the "working" line is due: while the review opens, and while a
    /// turn is being graded or answered and nothing of the reply has arrived.
    /// The reply's own row is on screen from the send, empty until its first
    /// words, so an empty streaming row is still waiting.
    var showsWorkingLine: Bool {
        if isOpening { return true }
        guard isResponding else { return false }
        guard let last = messages.last, last.isStreaming else { return true }
        return last.content.isEmpty
    }

    var canSend: Bool {
        canCompose && !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The name a card gives the source, or topic, it is about.
    func sourceTitle(_ id: String) -> String? {
        sourceTitles[id] ?? briefingTitles[id]
    }

    /// Whether the review is organized by topic: a card per topic, the topic
    /// grader, the stepper in place of the source count.
    var isTopicReview: Bool { !topics.isEmpty }

    func topic(_ id: String?) -> MemoryReviewTopic? {
        guard let id else { return nil }
        return topics.first { $0.id == id }
    }

    /// "2 of 5 sources" once contours have been graded; empty before, and
    /// empty for a topic review, whose stepper says the same.
    var sourceStatusLine: String {
        guard let record, !isTopicReview else { return "" }
        let graded = record.sourceStatuses.count
        guard graded > 0 else { return "" }
        return "\(graded) of \(record.sourceIDs.count) sources"
    }

    /// Whether the card is waiting for an answer the learner may honestly
    /// not have: the topic's opening, not yet graded, or the probe a Go
    /// deeper just asked. Under a graded reply the tutor asks nothing, so
    /// the button would answer no question.
    var offersDontRemember: Bool {
        guard isTopicReview, canCompose, !isResponding, let record,
              let current = record.currentSourceID else { return false }
        if record.sourceStatuses[current] == nil { return true }
        return record.exchanges.last?.userAnswer == MemoryReviewTutoring.steerMessage(.deeper)
    }

    /// One entry per topic for the stepper: waiting, current, or finished.
    var topicProgress: [MemoryReviewTopicProgress] {
        guard let record else { return [] }
        return MemoryReviewTopicProgress.progress(
            topics: topics,
            statuses: record.sourceStatuses,
            currentID: record.currentSourceID
        )
    }

    /// A topic card's ledger once its opening was graded: a row per cued
    /// idea, veiled while missing. Empty before the grade, and for an id
    /// that is not a topic.
    func ledgerRows(forTopic id: String?) -> [MemoryReviewLedgerRow] {
        guard let record, let topic = self.topic(id) else { return [] }
        return MemoryReviewIdeaState.ledgerRows(topic: topic, states: record.ideaStates, ideasByID: ideasByID)
    }

    private var ideasByID: [String: SourceIdea] {
        var result: [String: SourceIdea] = [:]
        for ideas in ideasBySource.values {
            for idea in ideas { result[idea.id] = idea }
        }
        return result
    }

    // MARK: - Lifecycle

    /// Loads today's review, preparing it here when no device has (unless
    /// this review only resumes one), and asks the tutor for the opening
    /// question when the record has none yet.
    func open(now: Date = Date()) async {
        guard record == nil, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        errorMessage = nil
        let sessionID = MemoryReviewSession.sessionID(for: now)
        do {
            workingLabel = "Opening today's review"
            var loaded = try await store.fetch(sessionID: sessionID)
            if loaded == nil {
                guard preparesIfMissing else {
                    errorMessage = "Today's review chat is no longer on this iPhone."
                    workingLabel = ""
                    return
                }
                workingLabel = "Planning today's review"
                loaded = try await MobileMemoryReviewPreparer.shared.prepare(now: now)
            }
            guard var review = loaded else { return }
            let opened = review
            let context = Task { await self.loadReviewContext(for: opened) }
            contextTask = context
            // A review with its question already in it goes on screen now;
            // the grader's context keeps loading behind it.
            if !review.exchanges.isEmpty { apply(review) }
            if review.exchanges.isEmpty {
                workingLabel = "Thinking"
                let opening = try await MobileManagedTextCall.complete(
                    task: .chat,
                    system: systemPrompt(for: review),
                    messages: [(role: "user", content: MemoryReviewTutoring.openingRequest(forBriefing: review.briefing))],
                    maxTokens: MobileStreamingChat.responseTokenBudget,
                    operation: "mobile_memory_review",
                    sessionID: review.id
                )
                review = try await store.recordOpeningQuestion(sessionID: review.id, question: opening.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            apply(review)
        } catch {
            errorMessage = error.localizedDescription
        }
        workingLabel = ""
    }

    func finish() {
        guard !didFinish else { return }
        didFinish = true
        sendTask?.cancel()
    }

    func clearError() { errorMessage = nil }

    // MARK: - Turns

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty else { return }
        draft = ""
        await respond(to: text, visibleText: text)
    }

    /// A chip: the learner's steer, recorded on the graded exchange and sent
    /// as the word the tutor would have heard.
    func steer(_ steer: MemoryReviewSteer) async {
        guard awaitsSteer, !isResponding else { return }
        pendingSteer = steer
        let word = MemoryReviewTutoring.steerMessage(steer)
        pendingProbe = nil
        var note: String?
        if steer == .deeper {
            // The ideas say whether everything came back; a review reopened
            // with its chips already showing may still be loading them.
            await contextTask?.value
            note = understandingProbeNote()
        }
        await respond(to: word, visibleText: word, note: note)
    }

    /// The Mac's `understandingProbeNote` on the phone: when Go deeper is
    /// pressed on a topic, or a source, whose ideas all came back, the probe
    /// after the last one asked, on the idea probed least (wanted first). The
    /// phone has no vector index, so an analogy's partner is an idea of
    /// another of today's topics that came back and whose source sits in
    /// another notebook; with none the rotation skips the analogy. Nil while
    /// anything there is missing or partial.
    private func understandingProbeNote() -> String? {
        guard let record, let current = record.currentSourceID else { return nil }
        let ideas = ideasByID
        let topic = self.topic(current)
        let ideaIDs = (topic?.ideaIDs ?? (ideasBySource[current] ?? []).map(\.id)).filter { ideas[$0] != nil }
        let states = record.ideaStates
        guard MemoryUnderstandingProbe.isRecalled(ideaIDs: ideaIDs, states: states) else { return nil }
        let recalled = ideaIDs.filter { states[$0]?.status == .produced }
        let wanted = Set(recalled.filter { ideas[$0]?.wanted == true })
        guard let target = MemoryUnderstandingProbe.probeTarget(ideaIDs: recalled, wanted: wanted, states: states) else { return nil }
        let last = lastProbeKind ?? MemoryUnderstandingProbe.lastKind(operations: record.exchanges.map(\.operation))
        var kind = MemoryUnderstandingProbe.next(after: last, includesAnalogy: true)
        var partner: MemoryUnderstandingProbe.AnalogyPartner?
        if kind == .analogy {
            var titles = briefingTitles
            for (id, title) in sourceTitles { titles[id] = title }
            partner = topic.flatMap {
                MemoryUnderstandingProbe.analogyPartner(
                    forTopic: $0,
                    among: topics,
                    ideasByID: ideas,
                    states: states,
                    notebooksBySource: notebooksBySource,
                    titles: titles
                )
            }
            if partner == nil { kind = MemoryUnderstandingProbe.next(after: last, includesAnalogy: false) }
        }
        lastProbeKind = kind
        pendingProbe = topic == nil ? nil : (kind, target)
        return MemoryUnderstandingProbe.reviewNote(kind: kind, ideaID: target, topicID: topic?.id, partner: partner)
    }

    /// The honest miss: sent as an answer, so it is graded like one and costs
    /// no typing.
    func dontRemember() async {
        guard canCompose, !isResponding else { return }
        let words = MemoryReviewTutoring.dontRememberMessage
        await respond(to: words, visibleText: words)
    }

    /// `note` rides beside the learner's words to the tutor on this turn
    /// only, as the grader's acknowledgement does: what Go deeper asks for
    /// once everything came back.
    private func respond(to answer: String, visibleText: String, note: String? = nil) async {
        guard let review = record else { return }
        let isSteer = pendingSteer != nil
        errorMessage = nil
        isResponding = true
        defer { isResponding = false }

        messages.append(.init(id: "learner-\(UUID().uuidString)", role: .learner, content: visibleText))
        let assistantID = "tutor-\(UUID().uuidString)"
        messages.append(.init(id: assistantID, role: .tutor, content: "", isStreaming: true))

        do {
            // 1. Grade, when there is something to grade — against the ideas
            // the context load brings, so an answer sent while it is still
            // loading waits for it.
            workingLabel = "Grading"
            await contextTask?.value
            let grade = try await gradeIfContour(answer: answer, review: review)
            var providerAnswer = grade.map { grade in
                "\(answer)\n\n[ForeverLM grader] \(acknowledgement(for: grade, review: review))"
            } ?? answer
            if let note { providerAnswer += "\n\n\(note)" }

            // 2. Reply, streamed.
            workingLabel = "Thinking"
            var history = Self.providerHistory(from: review)
            history.append((role: "user", content: providerAnswer))
            let batcher = MobileMemoryReviewStreamBatcher(interval: Self.streamPublishInterval) { [weak self] text in
                await self?.applyStreamedText(text, to: assistantID)
            }
            let result = try await MobileStreamingChat.stream(
                system: systemPrompt(for: review),
                messages: history
            ) { delta in await batcher.consume(delta) }
            try MobileOpenRouterChat.requireSelectedModel(report: result.report ?? .empty, route: result.route)
            let reply = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // 3. Record the turn on the day's record.
            workingLabel = "Saving"
            let updated = try await store.recordTurn(
                sessionID: review.id,
                answer: answer,
                reply: reply,
                grade: grade,
                steerBefore: pendingSteer
            )
            pendingSteer = nil
            // An answer was graded against the probe the last Go deeper
            // asked, if it asked one; the next answer is to something else.
            if !isSteer { pendingProbe = nil }
            apply(updated)
        } catch {
            // Never mask: the failure is shown, the answer goes back to the
            // composer, and the transcript stays what the record says it is.
            messages.removeAll { $0.id == assistantID }
            if messages.last?.role == .learner { messages.removeLast() }
            if draft.isEmpty, pendingSteer == nil { draft = visibleText }
            // A Go deeper that failed asked no probe.
            if isSteer { pendingProbe = nil }
            pendingSteer = nil
            errorMessage = error.localizedDescription
        }
        workingLabel = ""
    }

    // MARK: - Grading

    private struct GradingStep: Decodable {
        struct DepthChange: Decodable {
            let depth: String
            let sourceID: String?
            let sourceType: String?
            private enum CodingKeys: String, CodingKey { case depth, sourceID = "source_id", sourceType = "source_type" }
        }
        /// The grader's arguments as JSON, or null when nothing was gradable.
        let grade: [String: AnyDecodable]?
        let setReviewDepth: DepthChange?
        private enum CodingKeys: String, CodingKey { case grade, setReviewDepth = "set_review_depth" }
    }

    /// What the tutor is told once a grade has been accepted: the topic
    /// grader's words for a topic, the contour grader's for a source. The
    /// opening of a topic is the grade that reaches its ideas first.
    private func acknowledgement(for grade: MemoryContourGrade, review: MobileMemoryReviewRecord) -> String {
        if review.isByTopic {
            let topic = self.topic(grade.sourceID)
            let states = review.ideaStates
            let isOpening = Set(states.keys).isDisjoint(with: Set(topic?.ideaIDs ?? []))
            return MemoryReviewTutoring.topicGradeAcknowledgement(grade: grade, topic: topic, isOpening: isOpening, priorStates: states)
        }
        let depth = depthBySource[grade.sourceID] ?? .standard
        return MemoryReviewTutoring.gradeAcknowledgement(grade: grade, depth: depth)
    }

    /// The structured twin of the Mac's `grade_memory_contour` tool call, or
    /// of `grade_topic_recall` in a review planned by topic: the tutor decides
    /// whether the answer was a recall that should be graded and, if so,
    /// grades it against the ideas in the briefing. Validated exactly as the
    /// Mac validates a tool call; an invalid grade is sent back once with the
    /// validator's own words, then surfaced.
    private func gradeIfContour(answer: String, review: MobileMemoryReviewRecord) async throws -> MemoryContourGrade? {
        guard !ideasBySource.isEmpty, let question = review.openQuestion else { return nil }
        let byTopic = review.isByTopic
        let tool = byTopic ? MemoryReviewTutoring.gradeTopicRecallTool : MemoryReviewTutoring.gradeMemoryContourTool
        let toolJSON = tool.requestDictionary
        let toolSchema = (try? JSONSerialization.data(withJSONObject: toolJSON["parameters"] ?? [:], options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // The understanding probe the last Go deeper asked, which the history
        // no longer carries: its note rode only on that turn.
        let probeLine = pendingProbe.map { probe in
            "\nThe question just asked was an understanding probe, \(probe.kind.rawValue), on [\(probe.ideaID)]: an answer to it is graded on that idea alone with operation \"\(probe.kind.operation.rawValue)\".\n"
        } ?? ""
        let instruction = byTopic ? """
        GRADING STEP. The learner has just answered. Decide, as the tutor would before replying, whether this answer is an answer to a topic's opening question or to a Go deeper probe, and so should be graded. "I don't remember" is an answer: grade it, with every idea it was asked about missing.

        If it should be graded, return {"grade": <the grade_topic_recall arguments>, "set_review_depth": null}, where the arguments follow this schema exactly. For a topic's opening question every idea listed under that topic in the briefing appears once in idea_coverage, whichever source it came from; for a Go deeper probe, only the idea or ideas the probe asked about; for an understanding probe (principle, transfer, falsify, analogy), the probed idea alone with the probe's kind as operation, graded on how far the answer gets:
        \(toolSchema)
        \(probeLine)
        If the learner instead steered ("Next", "Go deeper"), asked something, greeted you, or asked for a depth change, return {"grade": null, "set_review_depth": null}, or {"grade": null, "set_review_depth": {"depth": "quick|standard|deep", "source_id": "...", "source_type": "..."}} for a depth request. Return JSON only.
        """ : """
        GRADING STEP. The learner has just answered. Decide, as the tutor would before replying, whether this answer is a recall of one review source's contour or probe that should be graded.

        If it should be graded, return {"grade": <the grade_memory_contour arguments>, "set_review_depth": null}, where the arguments follow this schema exactly and every idea listed under that source in the briefing appears once in idea_coverage:
        \(toolSchema)

        If the learner instead steered ("Next", "Go deeper"), asked something, greeted you, or asked for a depth change, return {"grade": null, "set_review_depth": null}, or {"grade": null, "set_review_depth": {"depth": "quick|standard|deep", "source_id": "...", "source_type": "..."}} for a depth request. Return JSON only.
        """
        var messages = Self.providerHistory(from: review)
        messages.append((role: "user", content: "\(answer)\n\n\(instruction)"))
        var lastError: String?
        for _ in 0..<2 {
            let result = try await MobileManagedTextCall.complete(
                task: .chat,
                system: systemPrompt(for: review),
                messages: messages + (lastError.map { [(role: "user", content: "\($0) Re-emit the JSON.")] } ?? []),
                maxTokens: 1_200,
                jsonMode: true,
                operation: "mobile_memory_review_grade",
                sessionID: review.id
            )
            let step: GradingStep = try MemoryReviewPlanning.decodeJSON(result.text)
            if let change = step.setReviewDepth {
                await applyDepthChange(change, review: review)
            }
            guard let gradeArguments = step.grade else { return nil }
            let arguments = gradeArguments.mapValues(\.value)
            switch validate(arguments: arguments, review: review) {
            case .success(let grade):
                return grade
            case .failure(let failure):
                // The validator speaks for the contour grader; a topic review
                // hears its own tool's name, as on the Mac.
                lastError = byTopic
                    ? failure.message.replacingOccurrences(of: "grade_memory_contour", with: "grade_topic_recall")
                    : failure.message
            }
        }
        _ = question
        throw MobileMemoryReviewError.gradeRejected(lastError ?? "the grade could not be validated")
    }

    /// The Mac's check, on the Mac's rule: a topic grade against the
    /// briefing's topics and the ideas already graded today (which is what
    /// says whether this answer is the topic's opening), a contour grade
    /// against the source's ideas.
    private func validate(arguments: [String: Any], review: MobileMemoryReviewRecord) -> Result<MemoryContourGrade, MemoryContourGrade.ValidationError> {
        if review.isByTopic {
            return MemoryContourGrade.validateTopic(
                arguments: arguments,
                topics: review.topics,
                ideasByID: ideasByID,
                gradedIdeaIDs: Set(review.ideaStates.keys)
            )
        }
        return MemoryContourGrade.validate(arguments: arguments, ideasBySource: ideasBySource)
    }

    private func applyDepthChange(_ change: GradingStep.DepthChange, review: MobileMemoryReviewRecord) async {
        guard let depth = MemoryReviewDepth(rawValue: change.depth.lowercased()) else { return }
        if let sourceID = change.sourceID, review.sourceIDs.contains(sourceID) {
            // Per-source depth lives on the Mac's source row; on the phone it
            // holds for this review.
            depthBySource[sourceID] = depth
        } else if let sourceType = change.sourceType?.lowercased(), !sourceType.isEmpty {
            try? await MobileModelPreferenceStore.shared.setString(
                depth.rawValue,
                forKey: MemoryReviewDepth.typePreferenceKey(sourceType: sourceType)
            )
        }
    }

    // MARK: - Context

    private func loadReviewContext(for review: MobileMemoryReviewRecord) async {
        _ = try? await catalog.loadSources()
        ideasBySource = await catalog.currentSourceIdeas(sourceIDs: review.sourceIDs)
        let sources = await catalog.currentSources(ids: review.sourceIDs)
        sourceTitles = Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        // Which notebooks hold the day's sources, for an analogy's partner.
        let material = Set(review.sourceIDs)
        var holding: [String: [MemoryUnderstandingProbe.Notebook]] = [:]
        for notebook in await catalog.currentNotebooks().sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) {
            for sourceID in Set(notebook.sourceIDs) where material.contains(sourceID) {
                holding[sourceID, default: []].append(MemoryUnderstandingProbe.Notebook(id: notebook.id, title: notebook.title))
            }
        }
        notebooksBySource = holding
        var depths: [String: MemoryReviewDepth] = [:]
        for source in sources {
            let typeDefault = (try? await MobileModelPreferenceStore.shared
                .string(forKey: MemoryReviewDepth.typePreferenceKey(sourceType: source.sourceType)))
                .flatMap { MemoryReviewDepth(rawValue: $0) }
            depths[source.id] = MemoryReviewDepth.effective(sourceDepth: nil, typeDefault: typeDefault)
        }
        depthBySource = depths
    }

    private func systemPrompt(for review: MobileMemoryReviewRecord) -> String {
        MemoryReviewTutoring.systemPrompt(
            briefing: review.briefing ?? "",
            localClockDescription: Self.localClockDescription()
        )
    }

    static func localClockDescription() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, yyyy-MM-dd, HH:mm"
        formatter.timeZone = .current
        return "\(formatter.string(from: Date())) (\(TimeZone.current.identifier))"
    }

    /// The transcript as the model sees it. An exchange's evaluation is the
    /// question of the next one, so it is sent once.
    static func providerHistory(from review: MobileMemoryReviewRecord) -> [(role: String, content: String)] {
        var history: [(role: String, content: String)] = []
        for exchange in review.exchanges {
            if history.last?.content != exchange.question {
                history.append((role: "assistant", content: exchange.question))
            }
            if let answer = exchange.userAnswer, !answer.isEmpty {
                history.append((role: "user", content: answer))
            }
            if let evaluation = exchange.evaluation, !evaluation.isEmpty {
                history.append((role: "assistant", content: evaluation))
            }
        }
        return history
    }

    private func apply(_ review: MobileMemoryReviewRecord) {
        var titles = MemoryReviewTutoring.sourceTitles(inBriefing: review.briefing ?? "")
        // A topic's title rides with the sources' so a card names a topic
        // the way it names a source.
        let topics = review.topics
        for topic in topics { titles[topic.id] = topic.title }
        briefingTitles = titles
        if topics != self.topics { self.topics = topics }
        record = review
        var rows: [MobileMemoryReviewMessage] = []
        for turn in Self.providerHistory(from: review) {
            // The tutor's `<flm_source_turn>` lines are a heading on the Mac;
            // the phone shows no heading yet, so they are removed rather than shown raw.
            let content = turn.role == "user" ? turn.content : MemoryReviewSourceTurn.stripped(turn.content)
            rows.append(.init(
                id: "\(review.id)-\(rows.count)",
                role: turn.role == "user" ? .learner : .tutor,
                content: content,
                rendered: turn.role == "user" ? nil : Self.renderMarkdown(content),
                sourceID: turn.role == "user" ? nil : MemoryReviewSourceTurn.sourceIDs(in: turn.content).last
            ))
        }
        messages = rows
    }

    private func applyStreamedText(_ text: String, to id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].sourceID = MemoryReviewSourceTurn.sourceIDs(in: text).last
        messages[index].content = MemoryReviewSourceTurn.stripped(
            MemoryReviewSourceTurn.strippingTrailingPartialTag(text)
        )
    }

    private nonisolated static func renderMarkdown(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

enum MobileMemoryReviewError: LocalizedError {
    case gradeRejected(String)

    var errorDescription: String? {
        switch self {
        case .gradeRejected(let message):
            return "The grade could not be recorded: \(message)"
        }
    }
}

/// A JSON value as the grader emits it, kept loose so the validator — which
/// takes `[String: Any]` on every client — reads it unchanged.
struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyDecodable].self) { value = array.map(\.value) }
        else if let object = try? container.decode([String: AnyDecodable].self) { value = object.mapValues(\.value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}

/// Coalesces stream deltas so the main actor publishes at most once per
/// interval; `accumulated` is the whole text so far, so a skipped publish is
/// self-healing.
private actor MobileMemoryReviewStreamBatcher {
    private let interval: TimeInterval
    private let publish: @Sendable (String) async -> Void
    private var accumulated = ""
    private var lastPublishedAt = Date.distantPast

    init(interval: TimeInterval, publish: @escaping @Sendable (String) async -> Void) {
        self.interval = interval
        self.publish = publish
    }

    func consume(_ delta: String) async {
        accumulated += delta
        let now = Date()
        guard now.timeIntervalSince(lastPublishedAt) >= interval else { return }
        lastPublishedAt = now
        await publish(accumulated)
    }
}
