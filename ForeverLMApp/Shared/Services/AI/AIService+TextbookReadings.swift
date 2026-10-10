import Foundation

extension AIService {

    /// Asks which parts of a textbook this learner reads with each lecture.
    /// The draft is checked by `TextbookReadingPlanning.placements`; this only
    /// asks and decodes.
    func planTextbookReadings(
        _ request: TextbookReadingRequest,
        config: AITaskConfig
    ) async throws -> TextbookReadingDraft {
        let system = AITask.courseTextbookReadings.effectivePrompt ?? Prompts.textbookReadingPlanner
        let response = try await call(
            config: config,
            system: system,
            user: Self.textbookReadingUserMessage(request),
            maxTokens: TextbookReadingPlanning.writerMaxTokens,
            temperature: 0.3,
            jsonMode: true,
            sourceTitle: request.outline.title,
            subjectID: request.outline.bookID,
            subjectType: StudioSourceType.book.rawValue
        )
        do {
            return try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
    }

    /// The learner, the book, then the lectures: what is stable between two
    /// plans of the same book comes first.
    static func textbookReadingUserMessage(_ request: TextbookReadingRequest) -> String {
        var lines: [String] = []
        if let block = request.context.promptBlock {
            lines.append(block)
            lines.append("")
        }

        let outline = request.outline
        var book = "Textbook: \(outline.title)"
        if let edition = outline.edition?.trimmingCharacters(in: .whitespacesAndNewlines), !edition.isEmpty {
            book += " (\(edition))"
        }
        if let author = outline.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            book += " by \(author)"
        }
        lines.append(book)
        lines.append("Chapters and sections, each with its handle:")
        for chapter in outline.chapters {
            var header = "\(chapter.handle) \(chapter.title)"
            if let pages = chapter.pageCount { header += " · \(pages) pages" }
            header += " · \(progressLabel(chapter.progress))"
            lines.append(header)
            if chapter.sections.isEmpty {
                lines.append("  (no sections: read whole, as \(chapter.handle))")
                if !chapter.excerpt.isEmpty { lines.append("  Opens: \(chapter.excerpt)") }
            } else {
                for section in chapter.sections {
                    let count = section.pages.count
                    var line = "  \(section.handle) \(section.title) · \(count) \(count == 1 ? "page" : "pages")"
                    if !section.excerpt.isEmpty { line += " · \(section.excerpt)" }
                    lines.append(line)
                }
            }
        }
        lines.append("")

        var course = "Course: \(request.courseTitle)"
        if let instructors = request.instructors?.trimmingCharacters(in: .whitespacesAndNewlines), !instructors.isEmpty {
            course += ", taught by \(instructors)"
        }
        lines.append(course)
        lines.append("Lectures (\(request.lectures.count)):")
        for lecture in request.lectures {
            lines.append("")
            lines.append("=== Lecture \(lecture.number): \(lecture.title) ===")
            if lecture.material.isEmpty {
                lines.append("[No transcript or notes are stored for this lecture; go by its title.]")
            } else {
                lines.append(lecture.material)
                if lecture.wasCut {
                    lines.append("[Sampled: the lecture is longer than shown.]")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func progressLabel(_ progress: TextbookOutline.Chapter.Progress) -> String {
        switch progress {
        case .unread: return "not read yet"
        case .started: return "started"
        case .read: return "read"
        case .reviewed: return "read and reviewed"
        }
    }
}
