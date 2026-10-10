import Foundation

/// What the extraction call answers with: the note operations
/// (`WorkingNoteOps`), the fresh summary and the day's log lines.
struct WorkingNoteExtraction: Decodable, Equatable, Sendable {
    let ops: WorkingNoteOps
    let rightNow: String?
    let log: [String]

    enum CodingKeys: String, CodingKey { case rightNow = "right_now", log }

    init(ops: WorkingNoteOps, rightNow: String?, log: [String]) {
        self.ops = ops
        self.rightNow = rightNow
        self.log = log
    }

    init(from decoder: Decoder) throws {
        ops = try WorkingNoteOps(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rightNow = try container.decodeIfPresent(String.self, forKey: .rightNow)
        log = try container.decodeIfPresent([String].self, forKey: .log) ?? []
    }
}

extension AIService {
    /// Reads the activity and the nearby notes and answers with what to
    /// write. Failure is surfaced to the pass, which leaves everything as it
    /// was: a note missed today is written from tomorrow's activity.
    func extractWorkingNotes(
        activity: String,
        currentSummary: String,
        nearby: [WorkingNote],
        now: Date,
        config: AITaskConfig
    ) async throws -> WorkingNoteExtraction {
        let response = try await call(
            config: config,
            system: Prompts.workingNoteExtractor,
            user: Self.workingNoteExtractionMessage(
                activity: activity, currentSummary: currentSummary, nearby: nearby, now: now
            ),
            maxTokens: 2_500,
            temperature: 0.2
        )
        return try Self.decodeCohortJSON(response)
    }

    static func workingNoteExtractionMessage(
        activity: String,
        currentSummary: String,
        nearby: [WorkingNote],
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let notes = nearby.isEmpty
            ? "(none yet)"
            : nearby.map { note in
                "- id \(note.id) [\(note.kind.rawValue), written \(DailyNote.dayKey(for: note.createdAt, calendar: calendar)), updated \(DailyNote.dayKey(for: note.updatedAt, calendar: calendar))] \(note.text)"
            }.joined(separator: "\n")
        return """
        TODAY: \(DailyNote.dayKey(for: now, calendar: calendar))

        ACTIVITY SINCE THE LAST RUN
        \(activity)

        THE SUMMARY AS IT STANDS
        \(currentSummary.isEmpty ? "(empty)" : currentSummary)

        NEARBY NOTES
        \(notes)
        """
    }
}
