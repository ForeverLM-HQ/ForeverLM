import Foundation
import os

/// Text copied from a PDF comes onto the clipboard one printed line at a time.
/// PDFKit (ForeverLM's Reader, Preview) writes every line as a paragraph of its
/// own and says nothing about where a paragraph ended, so a quotation pasted
/// into a Page came in as twenty one-line paragraphs, and a plain-text paste as
/// one paragraph broken at every line.
///
/// Only a reader can tell a line the page's width broke from one the author
/// ended, so the Pasted Line Joining model says what each break was, and the
/// editor joins the lines itself: no word of the paste is the model's. The
/// editor sends a paste of a few short plain lines (`pastedLinesNeedJoining`)
/// and applies the answer as its own undo step while the pasted words are still
/// as they came (`completePastedLineJoining` in artifact-editor.js).
enum PastedLineJoining {
    /// What a break between two pasted lines was.
    enum Break: String, CaseIterable, Sendable {
        /// The same paragraph goes on: the lines join with a space.
        case space
        /// A new block starts, or the lines stand on their own: kept as pasted.
        case paragraph
        /// A hyphen that only split a word: it goes, and the halves join.
        case hyphenSplit = "hyphen_split"
        /// A hyphen that belongs to the words: the lines join after it.
        case hyphenKept = "hyphen_kept"
        /// The lines join with nothing between them.
        case join

        var removesLineEndHyphen: Bool { self == .hyphenSplit }
        var needsLineEndHyphen: Bool { self == .hyphenSplit || self == .hyphenKept }
    }

    /// The editor asks only about a paste of at least this many lines; fewer
    /// is a sentence or two, not a page's worth of printed lines.
    static let minimumLines = 3
    /// The most lines one request carries: several pages of a book. A longer
    /// paste stays as it came rather than becoming one very long call.
    static let maximumLines = 400
    /// A printed line is short; a line longer than this is a paragraph already.
    static let maximumLineLength = 200

    /// The characters a printed line ends in when a word or a compound
    /// carries on to the next line.
    static let lineEndHyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{00AD}"]

    /// One paste the editor asked about.
    struct Request: Equatable, Sendable {
        let requestID: String
        let lines: [String]

        /// nil for anything the editor would not have sent: no id, too few or
        /// too many lines, or a line too long to be a printed one.
        static func parse(_ payload: [String: Any]) -> Request? {
            guard let requestID = payload["requestID"] as? String, !requestID.isEmpty,
                  let raw = payload["lines"] as? [Any] else { return nil }
            let lines = raw.compactMap { $0 as? String }
            guard lines.count == raw.count,
                  (minimumLines...maximumLines).contains(lines.count),
                  lines.allSatisfy({ $0.count <= maximumLineLength }) else { return nil }
            return Request(requestID: requestID, lines: lines)
        }
    }

    enum AnswerError: Error, Equatable, LocalizedError {
        case unreadable
        case wrongCount(expected: Int, got: Int)
        case unknownBreak(String)
        case hyphenWithoutHyphen(line: Int)
        case joinsEmptyLine(line: Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Pasted line joining did not answer with the JSON it was asked for."
            case let .wrongCount(expected, got):
                return "Pasted line joining answered for \(got) breaks; the paste has \(expected)."
            case .unknownBreak(let value):
                return "Pasted line joining answered “\(value)”, which is not a kind of break."
            case .hyphenWithoutHyphen(let line):
                return "Pasted line joining treated line \(line) as ending in a hyphen, and it does not."
            case .joinsEmptyLine(let line):
                return "Pasted line joining joined line \(line), which is empty."
            }
        }
    }

    /// The lines as the model reads them: numbered from 1, one to a line.
    static func userMessage(_ lines: [String]) -> String {
        lines.enumerated()
            .map { "\($0.offset + 1)| \($0.element)" }
            .joined(separator: "\n")
    }

    /// Reads `{"breaks": [...]}`: one known break for each pair of lines, a
    /// hyphen's break only where the line ends in one, and nothing joined onto
    /// an empty line. Anything else is not an answer, and throws.
    static func breaks(from response: String, lines: [String]) throws -> [Break] {
        struct Reply: Decodable { let breaks: [String] }
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw AnswerError.unreadable
        }
        let expected = max(lines.count - 1, 0)
        guard reply.breaks.count == expected else {
            throw AnswerError.wrongCount(expected: expected, got: reply.breaks.count)
        }
        return try reply.breaks.enumerated().map { index, raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let kind = Break(rawValue: value) else { throw AnswerError.unknownBreak(raw) }
            guard kind != .paragraph else { return kind }
            let before = lines[index].trimmingCharacters(in: .whitespaces)
            let after = lines[index + 1].trimmingCharacters(in: .whitespaces)
            if before.isEmpty { throw AnswerError.joinsEmptyLine(line: index + 1) }
            if after.isEmpty { throw AnswerError.joinsEmptyLine(line: index + 2) }
            if kind.needsLineEndHyphen, let last = before.last, !lineEndHyphens.contains(last) {
                throw AnswerError.hyphenWithoutHyphen(line: index + 1)
            }
            return kind
        }
    }

    private static let logger = Logger(subsystem: "com.foreverlm", category: "PastedLineJoining")

    /// The Pasted Line Joining model's answer for a paste. Without a model
    /// (signed out, no consent to background AI, no balance) nothing is asked
    /// and the paste stays as it came, as it does when the call fails.
    static func liveBreaks(for request: Request, pageTitle: String?) async throws -> [Break] {
        let task = AITask.pastedLineJoining
        guard let config = KeychainService.resolveConfig(for: task) else {
            let reason = KeychainService.backgroundAIUnavailableMessage(for: task) ?? "no Background model is set up"
            logger.notice("Pasted lines left as pasted: \(reason, privacy: .public)")
            throw AIError.apiError(reason)
        }
        return try await AIService().pastedLineBreaks(request.lines, pageTitle: pageTitle, config: config)
    }
}

extension AIService {
    /// Asks what each break between pasted lines was. The answer is read by
    /// `PastedLineJoining.breaks(from:lines:)`; this only asks.
    func pastedLineBreaks(
        _ lines: [String],
        pageTitle: String?,
        config: AITaskConfig
    ) async throws -> [PastedLineJoining.Break] {
        let system = AITask.pastedLineJoining.effectivePrompt ?? Prompts.pastedLineJoining
        let user = PastedLineJoining.userMessage(lines)
        let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A background call: a dropped connection or a busy model is waited
        // out, and a reply that is not an answer moves on to the backup models.
        let response = try await AIBackgroundRetry.run(config: config) { config in
            try await self.call(
                config: config,
                system: system,
                user: user,
                // About a dozen tokens a break, with room for the object around them.
                maxTokens: 200 + lines.count * 12,
                temperature: 0,
                jsonMode: true,
                validateResponse: { _ = try PastedLineJoining.breaks(from: $0, lines: lines) },
                sourceTitle: title?.isEmpty == false ? title : nil
            )
        }
        return try PastedLineJoining.breaks(from: response, lines: lines)
    }
}
