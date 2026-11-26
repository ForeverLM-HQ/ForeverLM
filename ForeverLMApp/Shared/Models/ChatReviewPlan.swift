import Foundation

/// The plan a chat is working through when the learner asks to be quizzed on
/// a source: its topics, the points under each and how far each has got, the
/// question waiting for an answer, the detours the chat has taken from it and
/// what was set aside for later.
///
/// A plan written as a Markdown checklist in one reply scrolled away and was
/// never ticked. In a fifty-message chat on a podcast the plan was rewritten
/// three times, a topic was called covered after three of its eleven points,
/// and the learner had to paste the open question back in twice and write
/// "let's stay on track with the plan still" to get back from a run of side
/// questions (product owner, 2026-11-17: "is there a way to visualize that and
/// keep it more front and center? so we don't lose the plot and can go all way
/// back up the stack"). The plan is now state the tutor keeps with
/// `update_review_plan`, drawn beside the composer ("as some kind of popup").
///
/// Tool rows are never stored, so the reply that changed the plan keeps it as
/// one line at its head, `[Review plan · topic 2 of 7](foreverlm://chat-plan?state=…)`,
/// the way a turn's saved cards keep theirs (`ChatSavedCards`). A reopened chat
/// reads the last such line, so the plan syncs with the transcript and needs no
/// column of its own; a client that does not know the line reads a link named
/// after the plan's progress. The line never reaches the model's history: the
/// current plan rides in the turn's volatile context instead (`turnContext`).
///
/// Foundation only, so every client can read the line.
struct ChatReviewPlan: Codable, Equatable, Sendable {

    /// How far a topic or a point has got. A topic is `todo`, `active`,
    /// `done` or `skipped`; a point is `todo`, `partial` or `done`.
    enum Status: String, Codable, Sendable, CaseIterable {
        case todo
        case active
        case partial
        case done
        case skipped
    }

    /// A point and, once the learner has answered it, the answer: the step
    /// of the argument settled in a sentence or three, and a picture from the
    /// chat that shows it. The popover lays the answers out under their
    /// points, so the review reads as the argument it built (product owner,
    /// 2026-11-25: "show the answer underneath there … expandable … add
    /// images in there … I just see the argument laid out").
    struct Point: Codable, Equatable, Sendable {
        var text: String
        var status: Status
        /// The point's answer as the argument now stands, in the tutor's
        /// words from the learner's answer and its corrections. Nil until the
        /// learner has answered it.
        var answer: String?
        /// A picture shown in the chat that captures the point: its
        /// `foreverlm://image/…` address.
        var image: String?

        init(text: String, status: Status, answer: String? = nil, image: String? = nil) {
            self.text = text
            self.status = status
            self.answer = answer
            self.image = image
        }

        /// Whether the popover has anything to open under the point.
        var hasAnswer: Bool { answer != nil || image != nil }
    }

    static let maxAnswerLength = 1200

    /// The picture address a point may carry: a `foreverlm://image/…` URL,
    /// given bare or as the Markdown image line the picture tools return.
    /// Anything else is nil.
    static func imageAddress(_ text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("!["), let open = candidate.range(of: "]("), candidate.hasSuffix(")") {
            candidate = String(candidate[open.upperBound..<candidate.index(before: candidate.endIndex)])
        }
        guard let components = URLComponents(string: candidate),
              components.scheme == StudioEntityLink.productScheme,
              components.host == "image" else { return nil }
        return candidate
    }

    struct Topic: Codable, Equatable, Sendable {
        var title: String
        var status: Status
        var points: [Point]

        init(title: String, status: Status, points: [Point] = []) {
            self.title = title
            self.status = status
            self.points = points
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            status = try container.decode(Status.self, forKey: .status)
            points = try container.decodeIfPresent([Point].self, forKey: .points) ?? []
        }

        /// Points that are done, counting a partial one as not done.
        var donePoints: Int { points.filter { $0.status == .done }.count }

        /// How far the topic has got, 0...1: done points count whole and
        /// partial ones half. A topic with no points is all or nothing.
        var progress: Double {
            if status == .done || status == .skipped { return 1 }
            guard !points.isEmpty else { return 0 }
            let score = points.reduce(0.0) { sum, point in
                sum + (point.status == .done ? 1 : point.status == .partial ? 0.5 : 0)
            }
            return score / Double(points.count)
        }

        /// The title as the plan shows it: the plan numbers its topics, so a
        /// number the model wrote in front ("2. Metformin") is left off.
        var displayTitle: String { ChatReviewPlan.withoutLeadingNumber(title) }
    }

    /// "2. Metformin", "2) Metformin", "2: Metformin" → "Metformin". Only a
    /// number followed by its punctuation and a space is taken, so "5-HT
    /// signalling" and "2024 trials" keep theirs.
    static func withoutLeadingNumber(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"^\d{1,2}[.):]\s+"#, options: .regularExpression) else { return trimmed }
        let rest = String(trimmed[range.upperBound...])
        return rest.isEmpty ? trimmed : rest
    }

    /// What the plan covers: "Chandel episode #416".
    var title: String
    var topics: [Topic]
    /// The question the tutor last asked and the learner has not yet answered.
    var openQuestion: String?
    /// Where the chat has wandered from the plan, outermost first: each a few
    /// words ("Lane on apoptosis", "cytochrome c in Transformer").
    var detours: [String]
    /// What was promised for later and must not be lost.
    var parked: [String]

    enum CodingKeys: String, CodingKey {
        case title
        case topics
        case openQuestion = "open_question"
        case detours
        case parked
    }

    init(
        title: String,
        topics: [Topic],
        openQuestion: String? = nil,
        detours: [String] = [],
        parked: [String] = []
    ) {
        self.title = title
        self.topics = topics
        self.openQuestion = openQuestion
        self.detours = detours
        self.parked = parked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        topics = try container.decode([Topic].self, forKey: .topics)
        openQuestion = try container.decodeIfPresent(String.self, forKey: .openQuestion)
        detours = try container.decodeIfPresent([String].self, forKey: .detours) ?? []
        parked = try container.decodeIfPresent([String].self, forKey: .parked) ?? []
    }

    // MARK: Reading it

    /// The topic being worked on, by index: the first `active` one.
    var activeTopicIndex: Int? { topics.firstIndex { $0.status == .active } }

    var doneTopics: Int { topics.filter { $0.status == .done || $0.status == .skipped }.count }

    var totalPoints: Int { topics.reduce(0) { $0 + $1.points.count } }
    var donePoints: Int { topics.reduce(0) { $0 + $1.donePoints } }

    /// What the chip and the stored line say: "Topic 2 of 7" while one is
    /// being worked on, "3 of 7 done" otherwise.
    var progressLabel: String {
        if let index = activeTopicIndex {
            return "Topic \(index + 1) of \(topics.count)"
        }
        return "\(doneTopics) of \(topics.count) done"
    }

    /// True when the chat has wandered off the plan.
    var isOnDetour: Bool { !detours.isEmpty }

    // MARK: From the tool

    static let toolName = "update_review_plan"
    static let maxTopics = 20
    static let maxPointsPerTopic = 30

    enum ToolError: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case invalid(String)

        var description: String {
            switch self {
            case .malformed(let detail): return "the plan could not be read: \(detail)"
            case .invalid(let detail): return detail
            }
        }
    }

    /// The plan an `update_review_plan` call sends: the whole plan every
    /// time, so a stale tick can never survive a rewrite. Text is trimmed and
    /// empty entries dropped; a plan with no title, no topics, too many of
    /// them, a status in the wrong place or two active topics is refused with
    /// a sentence the model can act on.
    static func fromToolArguments(_ arguments: [String: Any]) throws -> ChatReviewPlan {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments) else {
            throw ToolError.malformed("the arguments are not JSON")
        }
        var plan: ChatReviewPlan
        do {
            plan = try JSONDecoder().decode(ChatReviewPlan.self, from: data)
        } catch {
            throw ToolError.malformed(String(describing: error))
        }
        plan = plan.normalized()
        try plan.validate()
        return plan
    }

    private func normalized() -> ChatReviewPlan {
        func clean(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func cleanList(_ list: [String]) -> [String] {
            list.map(clean).filter { !$0.isEmpty }
        }
        let question = openQuestion.map(clean)
        return ChatReviewPlan(
            title: clean(title),
            topics: topics.map { topic in
                Topic(
                    title: Self.withoutLeadingNumber(clean(topic.title)),
                    status: topic.status,
                    points: topic.points
                        .map { point in
                            let answer = point.answer.map(clean).flatMap { $0.isEmpty ? nil : $0 }
                            return Point(
                                text: clean(point.text),
                                status: point.status,
                                answer: answer,
                                image: point.image.flatMap(Self.imageAddress)
                            )
                        }
                        .filter { !$0.text.isEmpty }
                )
            },
            openQuestion: question?.isEmpty == false ? question : nil,
            detours: cleanList(detours),
            parked: cleanList(parked)
        )
    }

    private func validate() throws {
        guard !title.isEmpty else { throw ToolError.invalid("title is empty: name what the plan covers") }
        guard !topics.isEmpty else { throw ToolError.invalid("topics is empty: a plan has at least one topic") }
        guard topics.count <= Self.maxTopics else {
            throw ToolError.invalid("\(topics.count) topics is more than \(Self.maxTopics): group them")
        }
        let topicStatuses: Set<Status> = [.todo, .active, .done, .skipped]
        let pointStatuses: Set<Status> = [.todo, .partial, .done]
        for (index, topic) in topics.enumerated() {
            guard !topic.title.isEmpty else { throw ToolError.invalid("topic \(index + 1) has no title") }
            guard topicStatuses.contains(topic.status) else {
                throw ToolError.invalid("topic \(index + 1)'s status must be todo, active, done or skipped")
            }
            guard topic.points.count <= Self.maxPointsPerTopic else {
                throw ToolError.invalid("topic \(index + 1) has more than \(Self.maxPointsPerTopic) points: split it")
            }
            for point in topic.points {
                guard pointStatuses.contains(point.status) else {
                    throw ToolError.invalid("a point's status in topic \(index + 1) must be todo, partial or done")
                }
                if let answer = point.answer, answer.count > Self.maxAnswerLength {
                    throw ToolError.invalid("the answer to \"\(point.text)\" is longer than \(Self.maxAnswerLength) characters: settle it in a sentence or three")
                }
            }
        }
        guard topics.filter({ $0.status == .active }).count <= 1 else {
            throw ToolError.invalid("more than one topic is active: only the one being worked on is")
        }
    }

    // MARK: Keeping answers across rewrites

    /// The plan with the answers and pictures of `previous` kept on points
    /// this plan sends without them. The tutor sends the whole plan every
    /// time, and a rewrite that ticks the next point must not drop the
    /// argument the earlier points built. A point is the same point when its
    /// text is, under a topic of the same title first, anywhere else after.
    func keepingAnswers(from previous: ChatReviewPlan?) -> ChatReviewPlan {
        guard let previous else { return self }
        func key(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var byTopic: [String: Point] = [:]
        var anywhere: [String: Point] = [:]
        for topic in previous.topics {
            for point in topic.points where point.hasAnswer {
                byTopic[key(topic.title) + "\u{1F}" + key(point.text)] = point
                if anywhere[key(point.text)] == nil { anywhere[key(point.text)] = point }
            }
        }
        guard !anywhere.isEmpty else { return self }
        var kept = self
        for topicIndex in kept.topics.indices {
            let topicKey = key(kept.topics[topicIndex].title)
            for pointIndex in kept.topics[topicIndex].points.indices {
                var point = kept.topics[topicIndex].points[pointIndex]
                guard point.answer == nil || point.image == nil else { continue }
                guard let earlier = byTopic[topicKey + "\u{1F}" + key(point.text)] ?? anywhere[key(point.text)] else { continue }
                if point.answer == nil { point.answer = earlier.answer }
                if point.image == nil { point.image = earlier.image }
                kept.topics[topicIndex].points[pointIndex] = point
            }
        }
        return kept
    }

    // MARK: The stored line

    static let lineHost = "chat-plan"
    static let stateQueryName = "state"

    private static var linePrefix: String {
        "\(StudioEntityLink.productScheme)://\(lineHost)?\(stateQueryName)="
    }

    /// The JSON, keys sorted so the same plan is the same bytes, in base64url
    /// so nothing in it can end the Markdown link early.
    var markdownLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        let state = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "[Review plan · \(progressLabel)](\(Self.linePrefix)\(state))"
    }

    /// The reply as it is stored: the plan's line first when the turn changed
    /// the plan, then the reply as it was.
    static func storing(_ reply: String, with plan: ChatReviewPlan?) -> String {
        guard let plan else { return reply }
        return plan.markdownLine + "\n\n" + reply
    }

    static let clearedState = "cleared"

    /// The line that says the learner cleared the plan (`Clear Plan`): saved
    /// on the chat's latest reply, so a reopened chat holds no plan from
    /// there on until the tutor sets a new one.
    static var clearedLine: String { "[Review plan cleared](\(linePrefix)\(clearedState))" }

    static func isClearedLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == clearedLine
    }

    /// The plan a line carries, or nil when the line is not a plan line.
    static func parse(line: String) -> ChatReviewPlan? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[Review plan"), trimmed.hasSuffix(")"),
              let open = trimmed.range(of: "](" + linePrefix) else { return nil }
        var state = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while state.count % 4 != 0 { state += "=" }
        guard let data = Data(base64Encoded: state) else { return nil }
        return try? JSONDecoder().decode(ChatReviewPlan.self, from: data)
    }

    /// The last plan a stored reply carries, or nil.
    static func parse(storedReply text: String) -> ChatReviewPlan? {
        guard text.contains(linePrefix) else { return nil }
        var found: ChatReviewPlan?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let plan = parse(line: String(line)) { found = plan }
        }
        return found
    }

    /// The reply without its plan lines, for everything that shows or reads
    /// the reply as prose. A reply that carries none is returned as it was.
    static func prose(of text: String) -> String {
        guard text.contains(linePrefix) else { return text }
        let kept = text
            .components(separatedBy: "\n")
            .filter { parse(line: $0) == nil && !isClearedLine($0) }
            .joined(separator: "\n")
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The plan a chat holds now and the titles of the plans it replaced or
    /// the learner cleared, read off its stored replies in order (oldest
    /// first). A cleared line ends the plan before it.
    static func latest(inStoredReplies replies: [String]) -> (plan: ChatReviewPlan?, earlierTitles: [String]) {
        var current: ChatReviewPlan?
        var earlier: [String] = []
        func retire(_ plan: ChatReviewPlan?, replacedBy next: ChatReviewPlan?) {
            guard let plan, plan.title != next?.title, earlier.last != plan.title else { return }
            earlier.append(plan.title)
        }
        for reply in replies where reply.contains(linePrefix) {
            for line in reply.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                if let plan = parse(line: line) {
                    retire(current, replacedBy: plan)
                    current = plan
                } else if isClearedLine(line) {
                    retire(current, replacedBy: nil)
                    current = nil
                }
            }
        }
        // A plan that came back under a title it had before is not "earlier".
        if let current { earlier.removeAll { $0 == current.title } }
        return (current, earlier)
    }

    // MARK: For the model

    private static func mark(_ status: Status) -> String {
        switch status {
        case .todo: return " "
        case .active: return ">"
        case .partial: return "~"
        case .done: return "x"
        case .skipped: return "-"
        }
    }

    /// The plan as the tutor reads it every turn, outside the cached head.
    var turnContext: String {
        var lines: [String] = [
            "Review plan for this chat (the learner sees it beside the composer; keep it current with \(Self.toolName), sending the whole plan):",
            "Title: \(title)",
        ]
        for (index, topic) in topics.enumerated() {
            lines.append("\(index + 1). [\(Self.mark(topic.status))] \(topic.title)")
            for point in topic.points {
                lines.append("   - [\(Self.mark(point.status))] \(point.text)")
                if let answer = point.answer { lines.append("     answer: \(answer)") }
                if let image = point.image { lines.append("     picture: \(image)") }
            }
        }
        lines.append("Marks: [>] active, [x] done, [~] partly covered, [-] skipped, [ ] not yet.")
        lines.append("Open question: \(openQuestion ?? "none")")
        lines.append("Detours, outermost first: \(detours.isEmpty ? "none — the chat is on the plan" : detours.joined(separator: " › "))")
        lines.append("Parked for later: \(parked.isEmpty ? "none" : parked.joined(separator: "; "))")
        return lines.joined(separator: "\n")
    }

    /// What the learner's "Back to plan" sends.
    static let backToPlanMessage = "Back to the plan."

    /// What picking a topic in the plan's popover sends.
    static func goToTopicMessage(index: Int, title: String) -> String {
        "Let's go to topic \(index + 1) of the plan: \(title)."
    }
}
