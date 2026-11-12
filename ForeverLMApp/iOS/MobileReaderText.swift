import Foundation

// Pure text plumbing for the iOS plain-text reader: paragraph reflow, selection
// cleanup, chat context blocks, and the reader's HTML document. Everything here is
// synchronous, non-throwing, and free of I/O so it is safe anywhere and testable
// without a WebView.

/// A passage the reader user selected, carried to the chat composer as a chip.
struct MobileReaderSelection: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Already whitespace-cleaned via `MobileReaderText.cleanedSelection`.
    let text: String
}

enum MobileReaderText {
    /// Source types whose text comes out of a PDF extractor, one hard line break per
    /// visual line. Everything else (articles, transcripts) already has real paragraphs.
    private static let reflowableSourceTypes: Set<String> = ["paper", "book", "course"]

    /// Source types whose text is a conversation. Their stored transcript carries
    /// the speaker labels ForeverLM's own import wrote, and the reader lays those
    /// out as turns (`MobileTranscriptText`) instead of printing the labels.
    private static let transcriptSourceTypes: Set<String> = ["podcast"]

    private static let baseFontSize = 18.0
    struct ReadingSections: Equatable, Sendable {
        let main: String
        let supplementary: String?
        let supplementaryTitle: String?
    }

    // MARK: - Text shaping

    /// Rejoins soft-wrapped PDF lines into flowing paragraphs. Copied from
    /// `MobileReviewSpeechService.reflowedForSpeech` so the reader lays out extracted
    /// text exactly as the narrator reads it. Unlike the narration pipeline this does
    /// *not* strip markdown or citations — the reader must show the real text.
    static func reflowed(_ raw: String, sourceType: String) -> String {
        guard reflowableSourceTypes.contains(normalizedSourceType(sourceType)) else { return raw }

        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var paragraphs: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if isMarkdownStructuralLine(line) {
                flush()
                paragraphs.append(line)
            } else if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"),
                      let previous = current.dropLast().last, previous.isLetter,
                      let first = line.first, first.isLowercase {
                // A word hyphenated across the line break (e.g. "abroga-\ntion"):
                // drop the trailing hyphen and join tight so it reads as one word.
                current.removeLast()
                current += line
            } else {
                current += " " + line
            }
        }
        flush()

        return paragraphs.joined(separator: "\n\n")
    }

    /// Reader presentation is lossless. Meaning-sensitive cleanup happens in the
    /// configurable AI import task, never in this synchronous renderer.
    static func readingSections(
        in body: String,
        sourceType: String,
        sourceTitle: String
    ) -> ReadingSections {
        return ReadingSections(main: body, supplementary: nil, supplementaryTitle: nil)
    }

    /// Mirrors `StudioViewModel.cleanedReaderSelection`. Note this collapses every
    /// newline into a single space, so a cleaned selection is always one line.
    static func cleanedSelection(_ raw: String) -> String {
        raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mirrors `InternalReviewPanel.readerSelectionContextBlock` byte for byte
    /// so a selection quoted on iPhone reads identically to one quoted on the Mac.
    /// The per-line quoting is a practical no-op after `cleanedSelection`, but stays
    /// so any path that skips the cleaner still produces the same output.
    static func contextBlock(selection: String, sourceTitle: String) -> String {
        let selectedText = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else { return "" }
        let quotedText = selectedText
            .components(separatedBy: .newlines)
            .map { "> \($0)" }
            .joined(separator: "\n")
        let trimmedTitle = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceLine = trimmedTitle.isEmpty ? "" : "\n\nSource: \(trimmedTitle)"
        return "\(quotedText)\(sourceLine)"
    }

    // MARK: - Reader document

    /// The full HTML document for the reader WebView. `body` is untrusted plain text
    /// and is fully escaped — a source must never be able to inject markup or script.
    static func html(
        body: String,
        sourceType: String,
        sourceTitle: String,
        fontScale: Double,
        truncated: Bool
    ) -> String {
        let bodySize = String(format: "%.2f", bodyFontSize(for: fontScale))
        let sections = readingSections(in: body, sourceType: sourceType, sourceTitle: sourceTitle)

        let readingHTML: String
        if transcriptSourceTypes.contains(normalizedSourceType(sourceType)),
           let transcript = MobileTranscriptText.parse(sections.main) {
            readingHTML = renderedTranscript(transcript)
        } else {
            readingHTML = renderedBlocks(in: sections.main)
        }
        let supplementaryHTML: String
        if let supplementary = sections.supplementary,
           let title = sections.supplementaryTitle {
            supplementaryHTML = """
            <details class="flm-supplementary">
              <summary>\(escapingHTML(title))</summary>
              <div class="flm-supplementary-content">\(renderedBlocks(in: supplementary))</div>
            </details>
            """
        } else {
            supplementaryHTML = ""
        }

        let notice = truncated ? truncationNotice : ""

        return documentShell(
            bodyContent: "\(readingHTML)\n\(supplementaryHTML)\(notice)",
            bodySize: bodySize
        )
    }

    /// The reader document for a source that synced real markup rather than text:
    /// an EPUB chapter or archived article, published as the `readerHTML` satellite
    /// with every figure inlined as a `data:` URI. Rendering that markup is the whole point —
    /// escaping it would be the plain-text reader again, with the images gone.
    ///
    /// The Mac sanitizes the document before publishing it. `sanitizedBodyHTML` is
    /// the second line of defense, so markup from an older or unexpected producer
    /// still cannot bring script or a network fetch into the reader.
    static func documentHTML(bodyHTML: String, fontScale: Double, truncated: Bool) -> String {
        let bodySize = String(format: "%.2f", bodyFontSize(for: fontScale))
        let notice = truncated ? truncationNotice : ""
        return documentShell(
            bodyContent: sanitizedBodyHTML(bodyHTML) + notice,
            bodySize: bodySize
        )
    }

    /// The body text size, in points, for a reader text scale.
    static func bodyFontSize(for fontScale: Double) -> Double {
        let scale = fontScale.isFinite ? min(max(fontScale, 0.5), 3.0) : 1.0
        return baseFontSize * scale
    }

    // MARK: - Whole book

    /// The page a whole book is read in (`MobileBookPageScript`): the reader's
    /// stylesheet, the chapter break, and the two ends of the book so far — a
    /// spinner, a Try Again line, or nothing where the book begins or ends. It holds
    /// no chapter: each goes in as its own
    /// `<section class="flm-book-chapter" data-flm-chapter="…">`, the opened
    /// chapter first, as `MobileBookDOMState.freshShell` describes.
    static func bookDocumentHTML(fontScale: Double) -> String {
        let bodySize = String(format: "%.2f", bodyFontSize(for: fontScale))
        return documentShell(
            bodyContent: bookEdgeHTML(edge: "start", which: "previous", state: "idle")
                + "\n" + bookEdgeHTML(edge: "end", which: "next", state: "loading"),
            bodySize: bodySize,
            bodyClass: "flm-book",
            extraStyle: bookStyle
        )
    }

    /// One chapter's content for the book page: its synced document when it has
    /// one — the book's own markup, figures and heading included — and otherwise
    /// its synced text as paragraphs, the same fallback the single-chapter reader
    /// takes. The chapter's heading is in either, so the page adds none.
    static func bookChapterBodyHTML(readerBodyHTML: String?, plainText: String) -> String {
        if let readerBodyHTML, !readerBodyHTML.isEmpty {
            return sanitizedBodyHTML(readerBodyHTML)
        }
        return renderedBlocks(in: plainText)
    }

    /// Chrome, not prose: never selectable, and the retry line is its only text.
    private static func bookEdgeHTML(edge: String, which: String, state: String) -> String {
        "<div class=\"flm-book-edge\" data-edge=\"\(edge)\" data-state=\"\(state)\">"
            + "<span class=\"flm-book-spinner\" aria-hidden=\"true\"></span>"
            + "<div class=\"flm-book-retry\" role=\"button\" tabindex=\"0\">Couldn\u{2019}t load the \(which) chapter. "
            + "<span class=\"flm-book-retry-action\">Try Again</span></div>"
            + "</div>"
    }

    /// Each chapter is its own block, so its first heading's margin stays inside it
    /// and a chapter's height is the chapter's. Every chapter but the book's first
    /// opens with the break — a short rule and space — whatever is loaded above it,
    /// so adding the chapter before one never restyles it. The two ends keep one
    /// height through idle, loading and failed, so their spinner and retry line
    /// never move the text.
    private static let bookStyle = """
        section.flm-book-chapter {
            display: flow-root;
            margin: 0;
            padding: 0;
        }
        section.flm-book-chapter:not([data-flm-book-start]) {
            padding-top: 3.2em;
        }
        section.flm-book-chapter:not([data-flm-book-start])::before {
            content: "";
            display: block;
            width: 3.5em;
            margin: 0 auto;
            border-top: 1px solid var(--flm-rule);
        }
        .flm-book-edge {
            display: flex;
            align-items: center;
            justify-content: center;
            height: 4.5em;
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            font-size: 0.82em;
            line-height: 1.4;
            color: var(--flm-muted);
            text-align: center;
            -webkit-user-select: none;
        }
        .flm-book-edge[data-state="end"] { display: none; }
        .flm-book-spinner {
            display: none;
            width: 1.3em;
            height: 1.3em;
            box-sizing: border-box;
            border: 2px solid var(--flm-rule);
            border-top-color: var(--flm-muted);
            border-radius: 50%;
            animation: flm-book-spin 0.8s linear infinite;
        }
        .flm-book-edge[data-state="loading"] .flm-book-spinner { display: block; }
        .flm-book-retry {
            display: none;
            padding: 0.6em 1em;
            cursor: pointer;
        }
        .flm-book-edge[data-state="failed"] .flm-book-retry { display: block; }
        .flm-book-retry-action {
            color: -apple-system-blue;
            font-weight: 600;
        }
        @keyframes flm-book-spin { to { transform: rotate(360deg); } }

        """

    /// The chrome both readers share: one stylesheet, one set of margins, so a
    /// book chapter and an article look like the same app.
    private static func documentShell(
        bodyContent: String,
        bodySize: String,
        bodyClass: String? = nil,
        extraStyle: String = ""
    ) -> String {
        let bodyTag = bodyClass.map { "<body class=\"\($0)\">" } ?? "<body>"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            color-scheme: light dark;
            --flm-text: #1d1d1f;
            --flm-muted: #6e6e73;
            --flm-rule: #d1d1d6;
            --flm-body-size: \(bodySize)px;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --flm-text: #f5f5f7;
                --flm-muted: #a1a1aa;
                --flm-rule: #38383a;
            }
        }
        html {
            margin: 0;
            padding: 0;
            background: transparent;
            -webkit-text-size-adjust: none;
        }
        body {
            font-family: Georgia, 'Times New Roman', serif;
            font-size: var(--flm-body-size);
            line-height: 1.6;
            color: var(--flm-text);
            background: transparent;
            box-sizing: border-box;
            max-width: 34em;
            margin: 0 auto;
            padding:
                calc(20px + env(safe-area-inset-top))
                calc(20px + env(safe-area-inset-right))
                calc(72px + env(safe-area-inset-bottom))
                calc(20px + env(safe-area-inset-left));
            -webkit-font-smoothing: antialiased;
            -webkit-user-select: text;
            /* Long URLs and chemical names must break rather than scroll the page. */
            overflow-wrap: anywhere;
        }
        p {
            margin: 0.82em 0;
            padding: 0;
            text-align: start;
        }
        h1, h2, h3, h4, h5, h6 {
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            line-height: 1.22;
            margin: 1.7em 0 0.55em;
        }
        h1 { font-size: 1.55em; }
        h2 { font-size: 1.32em; }
        h3 { font-size: 1.15em; }
        h4, h5, h6 { font-size: 1em; }
        ul {
            margin: 0.8em 0;
            padding-left: 1.35em;
        }
        li { margin: 0.38em 0; }
        blockquote {
            color: var(--flm-muted);
            margin: 1em 0;
            padding-left: 1em;
            border-left: 2px solid var(--flm-rule);
        }
        /* A conversation: each speaker's turn under a small name line, with a
           mark in that voice's colour so the eye can follow who is talking. The
           name is chrome, not prose, so a selection dragged across turns quotes
           only what was said. */
        .flm-turn { margin: 1.5em 0; }
        .flm-turn p { margin: 0.6em 0; }
        .flm-turn p:first-of-type { margin-top: 0; }
        .flm-turn p:last-of-type { margin-bottom: 0; }
        .flm-speaker {
            display: flex;
            align-items: center;
            gap: 0.55em;
            margin: 0 0 0.45em;
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            font-size: 0.8em;
            font-weight: 600;
            line-height: 1.3;
            color: var(--flm-text);
            -webkit-user-select: none;
        }
        .flm-speaker-mark {
            flex: none;
            width: 3px;
            height: 1.15em;
            border-radius: 1.5px;
            background: var(--flm-accent, var(--flm-muted));
        }
        /* The Mac transcript reader's six speaker colours, in the same order. */
        .flm-accent-0 { --flm-accent: #2f80ed; }
        .flm-accent-1 { --flm-accent: #c2417b; }
        .flm-accent-2 { --flm-accent: #21867a; }
        .flm-accent-3 { --flm-accent: #b45f06; }
        .flm-accent-4 { --flm-accent: #6d5bd0; }
        .flm-accent-5 { --flm-accent: #6c7a00; }
        sup {
            font-size: 0.68em;
            line-height: 0;
        }
        details.flm-supplementary {
            margin-top: 2.2em;
            padding-top: 1em;
            border-top: 1px solid var(--flm-rule);
        }
        details.flm-supplementary summary {
            cursor: pointer;
            color: var(--flm-muted);
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            font-size: 0.88em;
            font-weight: 600;
            -webkit-user-select: none;
        }
        .flm-supplementary-content { margin-top: 1em; }
        /* Synced chapter markup. A publisher's own width and float rules assume
           a page, not a phone, so images are clamped and floats dropped. */
        img, svg, video {
            display: block;
            max-width: 100% !important;
            width: auto !important;
            height: auto !important;
            margin: 1.1em auto;
            float: none !important;
            border-radius: 2px;
        }
        /* A Greek letter or arrow the publisher drew as a picture the height of
           a line, sitting in the sentence. The block rule above would break the
           equation across lines; `ReaderInlineGlyphScript` marks these. */
        img.flm-inline-glyph {
            display: inline;
            max-height: 1.4em;
            margin: 0 0.04em;
            vertical-align: baseline;
            border-radius: 0;
        }
        figure {
            margin: 1.4em 0;
            padding: 0;
        }
        figcaption, .caption {
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            font-size: 0.82em;
            line-height: 1.4;
            color: var(--flm-muted);
            text-align: center;
            margin-top: 0.5em;
        }
        span.flm-image-omitted {
            display: block;
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            font-size: 0.8em;
            color: var(--flm-muted);
            text-align: center;
            margin: 1.1em 0;
        }
        /* A wide table scrolls inside itself rather than the page. */
        table {
            display: block;
            overflow-x: auto;
            max-width: 100%;
            border-collapse: collapse;
            font-size: 0.92em;
            margin: 1.2em 0;
        }
        th, td {
            border: 1px solid var(--flm-rule);
            padding: 0.35em 0.6em;
            text-align: start;
        }
        pre {
            overflow-x: auto;
            font-size: 0.88em;
            line-height: 1.45;
        }
        hr {
            border: 0;
            border-top: 1px solid var(--flm-rule);
            margin: 1.8em 0;
        }
        a { color: inherit; }
        p.flm-truncated {
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            font-size: 0.82em;
            line-height: 1.4;
            color: var(--flm-muted);
            margin-top: 2em;
            padding-top: 1em;
            border-top: 1px solid var(--flm-rule);
            -webkit-user-select: none;
        }
        \(extraStyle)</style>
        </head>
        \(bodyTag)
        \(bodyContent)
        </body>
        </html>
        """
    }

    // MARK: - Helpers

    private static let truncationNotice =
        "\n<p class=\"flm-truncated\">Text truncated — open this source on your Mac for the full text.</p>"

    /// Removes everything a synced chapter document must not be able to do in the
    /// reader: execute, embed, or fetch. Deliberately structural — it matches tags
    /// and attributes, never prose — and deliberately leaves `data:` images alone,
    /// which are the images the whole document exists to carry.
    static func sanitizedBodyHTML(_ html: String) -> String {
        var sanitized = html.repairingUTF8Mojibake()
        let removals = [
            #"<(script|style|iframe|object|embed|form|noscript)\b[\s\S]*?</\1>"#,
            #"<(script|iframe|object|embed|link|meta|base|input|button|source|track)\b[^>]*/?>"#,
            #"\s(on[a-z]+)\s*=\s*("[^"]*"|'[^']*')"#,
            // Remote references: a chapter renders from `data:` URIs alone, so a
            // stray http(s) src would be a tracking pixel, not a figure.
            #"\s(src|data-src|srcset|data-srcset|poster)\s*=\s*("\s*(?:https?:)?//[^"]*"|'\s*(?:https?:)?//[^']*')"#,
            #"\s(href|src)\s*=\s*("\s*javascript:[^"]*"|'\s*javascript:[^']*')"#,
        ]
        for pattern in removals {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized),
                withTemplate: ""
            )
        }
        return sanitized
    }

    /// Splits on blank lines. Single newlines inside a paragraph become spaces —
    /// `reflowed` has already restored real paragraph boundaries for PDF text.
    private static func blocks(in text: String) -> [String] {
        lineBlocks(in: text).compactMap(joinedBlock)
    }

    /// The blank-line-separated blocks of a text as their trimmed, non-empty
    /// lines, before any joining. A heading is a block of its own even when an
    /// extractor left no blank line after it, so the following prose can never
    /// inherit heading styling — and so a transcript label on its own line stays
    /// separable from the words under it.
    static func lineBlocks(in text: String) -> [[String]] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var blocks: [[String]] = []
        var current: [String] = []

        func flush() {
            if !current.isEmpty { blocks.append(current) }
            current.removeAll()
        }

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if markdownHeading(in: line) != nil {
                flush()
                blocks.append([line])
            } else {
                current.append(line)
            }
        }
        flush()

        return blocks
    }

    /// One block's lines as the string `renderedBlock` reads: list and quote
    /// lines keep their breaks, prose lines become one paragraph.
    static func joinedBlock(_ lines: [String]) -> String? {
        let keepLineBreaks = lines.allSatisfy { $0.hasPrefix("- ") || $0.hasPrefix("> ") }
        let joined = lines
            .joined(separator: keepLineBreaks ? "\n" : " ")
            .trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    /// A speaker-turn transcript: every turn is a section headed by the speaker's
    /// name and a mark in that speaker's colour; blocks outside any turn — show
    /// notes, chapter headings — render exactly as they do in an article. With a
    /// single voice the labels say nothing and only the paragraphs are printed.
    private static func renderedTranscript(_ transcript: MobileTranscriptText.Transcript) -> String {
        var accentIndexes: [String: Int] = [:]
        for (offset, speakerID) in transcript.speakerIDs.enumerated() {
            accentIndexes[speakerID] = offset % 6
        }

        return transcript.blocks.map { block -> String in
            switch block {
            case .plain(let text):
                return renderedBlock(text)
            case .turn(let turn):
                let paragraphs = turn.paragraphs
                    .map { "<p>\(inlineHTML($0))</p>" }
                    .joined(separator: "")
                guard transcript.showsSpeakers else { return paragraphs }
                let accent = accentIndexes[turn.speakerID] ?? 0
                return "<section class=\"flm-turn flm-accent-\(accent)\">"
                    + "<div class=\"flm-speaker\"><span class=\"flm-speaker-mark\"></span>"
                    + escapingHTML(turn.speakerLabel)
                    + "</div>\(paragraphs)</section>"
            }
        }.joined(separator: "\n")
    }

    private static func renderedBlocks(in text: String) -> String {
        blocks(in: text)
            .map(renderedBlock)
            .joined(separator: "\n")
    }

    private static func renderedBlock(_ block: String) -> String {
        let lines = block.components(separatedBy: .newlines)
        if lines.allSatisfy({ $0.hasPrefix("- ") }) {
            let items = lines
                .map { "<li>\(inlineHTML(String($0.dropFirst(2))))</li>" }
                .joined(separator: "")
            return "<ul>\(items)</ul>"
        }
        if lines.allSatisfy({ $0.hasPrefix("> ") }) {
            let quote = lines.map { String($0.dropFirst(2)) }.joined(separator: " ")
            return "<blockquote>\(inlineHTML(quote))</blockquote>"
        }
        if let heading = markdownHeading(in: block) {
            return "<h\(heading.level)>\(inlineHTML(heading.text))</h\(heading.level)>"
        }
        return "<p>\(inlineHTML(block))</p>"
    }

    static func markdownHeading(in block: String) -> (level: Int, text: String)? {
        guard !block.contains("\n") else { return nil }
        let markerCount = block.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount) else { return nil }
        let remainder = block.dropFirst(markerCount)
        guard remainder.first == " " else { return nil }
        let text = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (markerCount, text)
    }

    private static func inlineHTML(_ text: String) -> String {
        escapingHTML(text).replacingOccurrences(
            of: #"\^\(([^)\n]+)\)"#,
            with: "<sup>$1</sup>",
            options: .regularExpression
        )
    }

    private static func isMarkdownStructuralLine(_ line: String) -> Bool {
        markdownHeading(in: line) != nil
            || line.hasPrefix("- ")
            || line.hasPrefix("> ")
    }

    private static func normalizedSourceType(_ sourceType: String) -> String {
        let normalized = sourceType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["manual", "unclassified"].contains(normalized) ? "article" : normalized
    }

    private static func escapingHTML(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&#39;")
        return escaped
    }
}

/// Speaker turns read out of a stored podcast transcript.
///
/// Two label forms are honoured, and both are ForeverLM's own writing rather than
/// human prose, which is what makes parsing them here — instead of asking a model
/// — the right call: the TTML extractor puts `[SPEAKER_2]` on a line of its own
/// above the words, and the formatting pass heads a paragraph with `**Name:**`
/// (the AI or manual speaker names land in the same two shapes). A plain
/// `Name: text` line is deliberately not a label; "Note:" and "Example:" in a
/// show's notes look exactly like one.
///
/// The Mac's TTML reader has the same rules for what a turn is: a speaker keeps
/// talking through the paragraph breaks under their label until the next label,
/// consecutive turns by one speaker merge, and names are shown only when there is
/// more than one voice to tell apart.
enum MobileTranscriptText {
    struct Turn: Equatable, Sendable {
        /// Stable identity for colouring and merging: `SPEAKER_2` for both the
        /// extractor's `SPEAKER_2` and the formatting pass's `Speaker 2`.
        let speakerID: String
        /// The name as printed: the first form seen, with `SPEAKER_2` read as
        /// "Speaker 2".
        let speakerLabel: String
        let paragraphs: [String]
    }

    enum Block: Equatable, Sendable {
        case turn(Turn)
        /// A heading, list, quote or paragraph outside any speaker's turn — show
        /// notes, a chapter title — in the form `renderedBlock` already reads.
        case plain(String)
    }

    struct Transcript: Equatable, Sendable {
        let blocks: [Block]
        /// Speaker IDs in order of first appearance; the reader colours by position.
        let speakerIDs: [String]
        /// False for a single voice, whose repeated name would say nothing.
        let showsSpeakers: Bool
    }

    /// A conversation needs more than one voice, and enough labelled turns that a
    /// stray bracketed line cannot pass for one.
    private static let minimumLabeledTurns = 4
    /// One voice labelled this often is a labelled monologue, shown as prose.
    private static let minimumSingleVoiceLabels = 3

    /// nil when the text is not a labelled transcript, so the reader renders it
    /// exactly as before.
    static func parse(_ raw: String) -> Transcript? {
        var blocks: [Block] = []
        var speakerIDs: [String] = []
        var labels: [String: String] = [:]
        var currentSpeakerID: String?
        var labeledTurns = 0

        func appendParagraph(_ text: String, speakerID: String) {
            if case .turn(let last)? = blocks.last, last.speakerID == speakerID {
                blocks[blocks.count - 1] = .turn(Turn(
                    speakerID: speakerID,
                    speakerLabel: last.speakerLabel,
                    paragraphs: last.paragraphs + [text]
                ))
            } else {
                blocks.append(.turn(Turn(
                    speakerID: speakerID,
                    speakerLabel: labels[speakerID] ?? speakerID,
                    paragraphs: [text]
                )))
            }
        }

        for lines in MobileReaderText.lineBlocks(in: raw) {
            guard let joined = MobileReaderText.joinedBlock(lines) else { continue }
            if isStructural(lines) {
                // A heading or list ends whoever was speaking: show notes after
                // the last turn belong to nobody.
                blocks.append(.plain(joined))
                currentSpeakerID = nil
                continue
            }

            guard let parsed = label(in: lines) else {
                if let currentSpeakerID {
                    appendParagraph(joined, speakerID: currentSpeakerID)
                } else {
                    blocks.append(.plain(joined))
                }
                continue
            }

            let speakerID = parsed.speakerID
            if labels[speakerID] == nil {
                labels[speakerID] = parsed.displayLabel
                speakerIDs.append(speakerID)
            }
            currentSpeakerID = speakerID
            // A label with nothing under it — the formatting pass wrote one
            // where the extractor already had — only says who speaks next.
            guard let text = parsed.text else { continue }
            labeledTurns += 1
            appendParagraph(text, speakerID: speakerID)
        }

        if speakerIDs.count >= 2, labeledTurns >= minimumLabeledTurns {
            return Transcript(blocks: blocks, speakerIDs: speakerIDs, showsSpeakers: true)
        }
        if speakerIDs.count == 1, labeledTurns >= minimumSingleVoiceLabels {
            return Transcript(blocks: blocks, speakerIDs: speakerIDs, showsSpeakers: false)
        }
        return nil
    }

    // MARK: - Labels

    private struct Label {
        let speakerID: String
        let displayLabel: String
        /// The words under the label, or nil for a label standing alone.
        let text: String?
    }

    /// `[Name]` alone on the block's first line. The name starts with a letter,
    /// which keeps a show note's `[10:15]` or `[#2 listed above]` a note.
    private static let bracketLabel = try? NSRegularExpression(
        pattern: #"^\[(\p{L}[^\[\]]{0,79})\]$"#
    )
    /// `**Name:**` heading the block's first line, words optionally following.
    private static let boldLabel = try? NSRegularExpression(
        pattern: #"^\*\*(\p{L}[^*\n]{0,79}?):\*\*\s*(.*)$"#
    )

    private static func label(in lines: [String]) -> Label? {
        guard let first = lines.first else { return nil }
        let range = NSRange(first.startIndex..<first.endIndex, in: first)

        if let match = bracketLabel?.firstMatch(in: first, range: range),
           let nameRange = Range(match.range(at: 1), in: first) {
            return makeLabel(String(first[nameRange]), remainder: Array(lines.dropFirst()))
        }
        if let match = boldLabel?.firstMatch(in: first, range: range),
           let nameRange = Range(match.range(at: 1), in: first),
           let restRange = Range(match.range(at: 2), in: first) {
            let rest = String(first[restRange])
            let remainder = (rest.isEmpty ? [] : [rest]) + Array(lines.dropFirst())
            return makeLabel(String(first[nameRange]), remainder: remainder)
        }
        return nil
    }

    private static func makeLabel(_ rawName: String, remainder: [String]) -> Label? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let speakerID = speakerID(for: name)
        guard !speakerID.isEmpty else { return nil }
        let text = remainder
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return Label(
            speakerID: speakerID,
            displayLabel: displayLabel(for: name),
            text: text.isEmpty ? nil : text
        )
    }

    /// `Speaker 2`, `SPEAKER_2` and `speaker-2` are one speaker.
    static func speakerID(for label: String) -> String {
        label
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .uppercased()
    }

    /// The extractor's `SPEAKER_2` reads as "Speaker 2"; a name is printed as written.
    static func displayLabel(for label: String) -> String {
        let normalized = label.replacingOccurrences(of: "_", with: " ")
        if normalized.uppercased().hasPrefix("SPEAKER") {
            return normalized.capitalized
        }
        return normalized
    }

    /// Headings, lists and quotes are never part of a turn.
    private static func isStructural(_ lines: [String]) -> Bool {
        if lines.count == 1, MobileReaderText.markdownHeading(in: lines[0]) != nil { return true }
        return lines.allSatisfy { $0.hasPrefix("- ") || $0.hasPrefix("> ") }
    }
}

/// Marks the images a publisher uses as characters: a delta, an arrow, a
/// Greek letter drawn as a picture a line high and dropped into the sentence,
/// as Profile's EPUB of Nick Lane's *The Vital Question* does for every Δ in
/// ΔG = ΔH − TΔS. Both readers force images to their own centered block, which
/// is right for a figure and splits such an equation across six lines. The
/// script adds `flm-inline-glyph` to an image that sits in running text and is
/// no taller than a couple of lines once its pixels are known; each reader's
/// stylesheet then lets that class flow inline.
///
/// Lives in this file because it is the one reader source both app targets
/// compile; the Mac's EPUB reader and the phone's chapter web view install
/// the same script.
enum ReaderInlineGlyphScript {
    static let className = "flm-inline-glyph"

    static let source = """
    (function() {
        var GLYPH_CLASS = 'flm-inline-glyph';
        var INLINE_WRAPPERS = ['a', 'span', 'i', 'b', 'em', 'strong', 'sub', 'sup', 'small', 'u', 'q', 'abbr', 'cite', 'code', 'font'];
        function isInlineWrapper(node) {
            return !!node && node.nodeType === 1 && INLINE_WRAPPERS.indexOf(node.tagName.toLowerCase()) !== -1;
        }
        function hasVisibleText(node) {
            return (node.textContent || '').trim().length > 0;
        }
        // The element whose line boxes the image shares: its parent, past any
        // inline wrapper such as a link or italics.
        function lineHost(img) {
            var node = img.parentElement;
            while (node && node !== document.body && isInlineWrapper(node)) { node = node.parentElement; }
            return node;
        }
        // Text runs beside the image in the same block: a delta before G, an
        // arrow between reactants and product. A picture alone in its paragraph,
        // or one whose siblings are all blocks, is a figure however small.
        function sitsInText(img) {
            var host = lineHost(img);
            if (!host) { return false; }
            var children = host.childNodes;
            for (var i = 0; i < children.length; i += 1) {
                var node = children[i];
                if (node === img || node.contains(img)) { continue; }
                if (node.nodeType === 3 && hasVisibleText(node)) { return true; }
                if (isInlineWrapper(node) && hasVisibleText(node)) { return true; }
            }
            return false;
        }
        function fontSizeOf(element) {
            var size = parseFloat(window.getComputedStyle(element).fontSize);
            return isFinite(size) && size > 0 ? size : 18;
        }
        function isGlyphSized(img) {
            var width = img.naturalWidth;
            var height = img.naturalHeight;
            if (!width || !height) { return false; }
            var em = fontSizeOf(img.parentElement || document.body);
            return height <= em * 2.5 && width <= em * 12;
        }
        function classify(img) {
            if (img.closest('figure, picture, .figure, .image, .flm-lightbox')) { return; }
            if (!sitsInText(img)) { return; }
            var decide = function() { img.classList.toggle(GLYPH_CLASS, isGlyphSized(img)); };
            if (img.complete) { decide(); } else { img.addEventListener('load', decide, { once: true }); }
        }
        document.querySelectorAll('img').forEach(classify);
    })();
    """
}

/// The scripts the phone's text reader runs on every page it shows, one source or
/// a whole book. A book page (`<body class="flm-book">`) holds each chapter in its
/// own `[data-flm-chapter]` section, and a chapter's highlights are anchored in
/// that chapter's own text — the offset, prefix and suffix are relative to the
/// chapter, as they were when the chapter was the whole page, and the Mac resolves
/// them over the chapter's section too. So on a book page these scripts work
/// within a chapter's section, and on any other page over the whole body, as they
/// always have. They live here, beside `ReaderInlineGlyphScript`, so they can be
/// run outside the app.
enum MobileReaderPageScript {
    /// The selection's text for Chat, and on a book page the chapter it starts in.
    static let selection = """
    (() => {
      const selection = window.getSelection();
      if (!selection) return null;
      let chapter = null;
      if (selection.rangeCount > 0 && document.body.classList.contains('flm-book')) {
        const node = selection.getRangeAt(0).startContainer;
        const element = node.nodeType === 1 ? node : node.parentElement;
        const section = element ? element.closest('[data-flm-chapter]') : null;
        if (section) chapter = section.getAttribute('data-flm-chapter');
      }
      return { text: selection.toString(), chapter };
    })()
    """

    /// The selection as a highlight: its quote and a text-quote anchor over the
    /// page's text — or, on a book page, over the text of the chapter it is in,
    /// with that chapter's id. A mark belongs to one chapter, so a selection
    /// dragged across a chapter break keeps to the chapter it starts in, and the
    /// selection is narrowed to show what will be marked.
    static let selectionAnchor = """
    (() => {
      const selection = window.getSelection();
      if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
      let range = selection.getRangeAt(0);
      if (!document.body.contains(range.commonAncestorContainer)) return null;
      let root = document.body;
      let chapter = null;
      if (document.body.classList.contains('flm-book')) {
        const sectionOf = node => {
          const element = node.nodeType === 1 ? node : node.parentElement;
          return element ? element.closest('[data-flm-chapter]') : null;
        };
        const section = sectionOf(range.startContainer) || sectionOf(range.endContainer);
        if (!section) return null;
        if (!section.contains(range.startContainer) || !section.contains(range.endContainer)) {
          range = range.cloneRange();
          if (!section.contains(range.startContainer)) range.setStart(section, 0);
          if (!section.contains(range.endContainer)) range.setEnd(section, section.childNodes.length);
          selection.removeAllRanges();
          selection.addRange(range);
        }
        root = section;
        chapter = section.getAttribute('data-flm-chapter');
      }
      // ReaderTextAnchor.normalize's projection: no soft hyphens, one space per run.
      const normalize = value => value.replace(/\\u00AD/g, '').replace(/\\s+/g, ' ').trim();
      const quote = normalize(selection.toString());
      if (!quote) return null;
      const head = document.createRange();
      head.selectNodeContents(root);
      head.setEnd(range.startContainer, range.startOffset);
      const body = normalize(root.innerText || root.textContent || '');
      const before = normalize(head.toString());
      let offset = Math.max(0, before.length + (before.length && quote.length ? 1 : 0));
      let located = body.indexOf(quote, Math.max(0, offset - 8));
      if (located < 0) located = body.indexOf(quote);
      if (located >= 0) offset = located;
      return {
        quote,
        prefix: body.slice(Math.max(0, offset - 48), offset),
        suffix: body.slice(offset + quote.length, offset + quote.length + 48),
        offset,
        chapter
      };
    })()
    """

    /// Paints `SourceHighlight`s with the CSS Custom Highlight API and reports a
    /// tap on one to the `foreverlmHighlight` handler. `foreverlmApplyHighlights`
    /// takes the highlights of every chapter on the page and resolves each within
    /// its own chapter's section; `foreverlmRepaintHighlights` paints them again
    /// after chapters come or go.
    ///
    /// A passage is found the way the Mac's reader finds it
    /// (`ReaderWebHighlightSupport`): in the text as `ReaderTextAnchor.normalize`
    /// notebooks it, built in one pass with a map from every character back to its
    /// text node, and scored as `ReaderTextAnchor.resolve` scores it. Its text
    /// nodes are joined without a space its position walk would not count: a
    /// stray space would push the mark later in the text for every span or
    /// footnote link before a passage (a book chapter's markup is full of
    /// them), and a passage with a space after it in the same node would find
    /// no end at all.
    static let highlightPainter = """
    (() => {
      if (window.foreverlmApplyHighlights) return;
      const normalize = value => value.replace(/\\u00AD/g, '').replace(/\\s+/g, ' ').trim();
      const colors = { yellow:'rgba(255,217,77,.48)', green:'rgba(140,224,140,.48)', blue:'rgba(140,201,255,.48)', pink:'rgba(255,168,199,.48)', purple:'rgba(199,176,255,.48)' };
      const CONTEXT_WEIGHT = 2.0;
      const style = document.createElement('style');
      document.head.appendChild(style);
      window.__foreverlmRanges = [];
      window.__foreverlmHighlightItems = [];
      const scopes = items => {
        if (!document.body.classList.contains('flm-book')) return [[document.body, items]];
        return Array.from(document.querySelectorAll('[data-flm-chapter]')).map(section => {
          const chapter = section.getAttribute('data-flm-chapter');
          return [section, items.filter(item => item.sourceID === chapter)];
        });
      };
      // A run of whitespace is one space, and only after something was
      // emitted; a soft hyphen is no character of the text.
      const index = root => {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            const p = node.parentElement;
            return p && !['SCRIPT','STYLE','NOSCRIPT'].includes(p.tagName) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          }
        });
        let text = ''; const map = []; let pending = null; let node;
        while ((node = walker.nextNode())) {
          const value = node.nodeValue || '';
          for (let i = 0; i < value.length; i++) {
            if (value[i] === '\\u00AD') continue;
            if (/\\s/.test(value[i])) {
              if (text.length && !pending) pending = { node, offset: i };
            } else {
              if (pending) { text += ' '; map.push(pending); pending = null; }
              text += value[i];
              map.push({ node, offset: i });
            }
          }
        }
        return { text, map };
      };
      const leadingOverlap = (pattern, candidate) => {
        if (!pattern.length || !candidate.length) return 0;
        let matched = 0;
        while (matched < pattern.length && matched < candidate.length && pattern[matched] === candidate[matched]) matched++;
        return matched / pattern.length;
      };
      const trailingOverlap = (pattern, candidate) => {
        if (!pattern.length || !candidate.length) return 0;
        let matched = 0;
        while (matched < pattern.length && matched < candidate.length
               && pattern[pattern.length - 1 - matched] === candidate[candidate.length - 1 - matched]) matched++;
        return matched / pattern.length;
      };
      // Context agreement dominates; the recorded offset only separates
      // otherwise equal candidates.
      const score = (haystack, start, length, prefix, suffix, expected) => {
        let value = 0;
        if (prefix.length) value += CONTEXT_WEIGHT * trailingOverlap(prefix, haystack.slice(Math.max(0, start - prefix.length), start));
        if (suffix.length) value += CONTEXT_WEIGHT * leadingOverlap(suffix, haystack.slice(start + length, start + length + suffix.length));
        return value + 1 / (1 + Math.abs(start - expected) / 500);
      };
      const resolve = (indexed, item) => {
        const needle = normalize(item.anchor?.exact || item.quote || '');
        if (!needle) return null;
        const prefix = normalize(item.anchor?.prefix || '');
        const suffix = normalize(item.anchor?.suffix || '');
        const expected = Number(item.anchor?.offset || 0);
        let best = -1, bestScore = -1, from = 0, found, seen = 0;
        while ((found = indexed.text.indexOf(needle, from)) !== -1 && seen < 64) {
          const value = score(indexed.text, found, needle.length, prefix, suffix, expected);
          if (value > bestScore) { bestScore = value; best = found; }
          from = found + 1;
          seen++;
        }
        if (best < 0) return null;
        const head = indexed.map[best], tail = indexed.map[best + needle.length - 1];
        if (!head || !tail) return null;
        try {
          const range = document.createRange();
          range.setStart(head.node, head.offset);
          range.setEnd(tail.node, tail.offset + 1);
          return range;
        } catch (_) {
          return null;
        }
      };
      window.foreverlmApplyHighlights = items => {
        window.__foreverlmHighlightItems = items || [];
        if (!window.CSS || !CSS.highlights) return;
        CSS.highlights.clear();
        window.__foreverlmRanges = [];
        let rules = '';
        for (const [root, scoped] of scopes(window.__foreverlmHighlightItems)) {
          if (!scoped.length) continue;
          const indexed = index(root);
          for (const item of scoped) {
            const range = resolve(indexed, item);
            if (!range) continue;
            const name = 'fhl_' + String(item.id).replace(/[^a-zA-Z0-9_-]/g,'_');
            CSS.highlights.set(name, new Highlight(range));
            rules += `::highlight(${name}){background:${colors[item.color] || colors.yellow};}`;
            window.__foreverlmRanges.push({id:item.id,range});
          }
        }
        style.textContent = rules;
      };
      window.foreverlmRepaintHighlights = () => window.foreverlmApplyHighlights(window.__foreverlmHighlightItems);
      document.addEventListener('click', event => {
        const caret = document.caretRangeFromPoint?.(event.clientX,event.clientY);
        if (!caret) return;
        for (const item of window.__foreverlmRanges) {
          try { if (item.range.isPointInRange(caret.startContainer,caret.startOffset)) { window.webkit.messageHandlers.foreverlmHighlight.postMessage(item.id); break; } } catch (_) {}
        }
      });
    })()
    """
}

/// The whole-book page's own script, installed at document end on the page
/// `MobileReaderText.bookDocumentHTML` builds. `window.foreverlmBook.apply` runs the
/// steps `MobileBookPageSync` plans — chapters in and out, the ends' states, the
/// text size, a scroll to a chapter — without moving the words the reader is
/// looking at, and the page reports which chapter is under the reading line
/// (`MobileBookReadingReport`) to the `foreverlmBook` handler as it scrolls.
enum MobileBookPageScript {
    static let messageHandlerName = "foreverlmBook"

    static let source = """
    (function () {
        if (window.foreverlmBook) { return; }
        var READING_LINE = 0.25;
        var NEAR_START_SCREENS = 1.5;
        var NEAR_END_SCREENS = 2.5;
        var REPORT_INTERVAL = 100;
        var SETTLE_TIMEOUT = 4000;

        function post(message) {
            try { window.webkit.messageHandlers.\(messageHandlerName).postMessage(message); } catch (error) {}
        }
        function clamp(value) { return value < 0 ? 0 : (value > 1 ? 1 : value); }
        function screenHeight() { return window.innerHeight || document.documentElement.clientHeight || 1; }
        function sections() { return Array.prototype.slice.call(document.querySelectorAll('section.flm-book-chapter')); }
        function chapterOf(section) { return section.getAttribute('data-flm-chapter'); }
        function sectionFor(id) {
            var all = sections();
            for (var i = 0; i < all.length; i += 1) { if (chapterOf(all[i]) === id) { return all[i]; } }
            return null;
        }
        function edgeElement(edge) { return document.querySelector('.flm-book-edge[data-edge="' + edge + '"]'); }
        // A chapter that joins the page needs its in-sentence pictures marked like
        // the rest of the page's.
        function classifyGlyphs() {
            \(ReaderInlineGlyphScript.source)
        }

        // How far through a chapter the reader is: 0 with its top at the top of the
        // screen, 1 with its end at the bottom, the measure a single chapter's
        // scroll has always saved. A chapter shorter than the screen is as far
        // through as it has come into view.
        function fractionOf(section, height) {
            var rect = section.getBoundingClientRect();
            if (rect.height > height) { return clamp(-rect.top / (rect.height - height)); }
            return clamp((height - rect.top) / Math.max(rect.height, 1));
        }

        // The chapter under the reading line, a quarter of the way down the screen.
        function currentSection(all, height) {
            var line = height * READING_LINE;
            var chosen = null;
            for (var i = 0; i < all.length; i += 1) {
                if (all[i].getBoundingClientRect().top <= line) { chosen = all[i]; } else { break; }
            }
            return chosen || all[0] || null;
        }

        function scrollToChapter(id, fraction) {
            var section = sectionFor(id);
            if (!section) { return false; }
            var height = screenHeight();
            var rect = section.getBoundingClientRect();
            var top = rect.top + window.scrollY;
            var target = rect.height > height ? top + clamp(fraction) * (rect.height - height) : top;
            if (section.hasAttribute('data-flm-book-start') && fraction <= 0.0001) { target = 0; }
            window.scrollTo(0, Math.max(0, target));
            return true;
        }

        // The words at the reading line, to hold still across a reflow — a text
        // size change, a rotation, a split-view resize. The chapter and fraction
        // stand in where no text is under the line.
        function captureAnchor() {
            var height = screenHeight();
            var section = currentSection(sections(), height);
            if (!section) { return null; }
            var line = height * READING_LINE;
            var anchor = { chapter: chapterOf(section), fraction: fractionOf(section, height), range: null, offset: 0 };
            if (!document.caretRangeFromPoint) { return anchor; }
            var rect = section.getBoundingClientRect();
            var caret = document.caretRangeFromPoint(rect.left + Math.min(40, rect.width / 2), line);
            if (!caret || !section.contains(caret.startContainer)) { return anchor; }
            var node = caret.startContainer;
            if (node.nodeType === 3 && caret.startOffset < node.length) { caret.setEnd(node, caret.startOffset + 1); }
            var box = caret.getBoundingClientRect();
            if (box.width || box.height) {
                anchor.range = caret;
                anchor.offset = box.top - line;
            }
            return anchor;
        }
        function restoreAnchor(anchor) {
            if (!anchor) { return; }
            if (anchor.range && anchor.range.startContainer.isConnected) {
                var box = anchor.range.getBoundingClientRect();
                if (box.width || box.height) {
                    window.scrollBy(0, box.top - screenHeight() * READING_LINE - anchor.offset);
                    return;
                }
            }
            scrollToChapter(anchor.chapter, anchor.fraction);
        }

        function reading() {
            var all = sections();
            if (!all.length) { return null; }
            var height = screenHeight();
            var section = currentSection(all, height);
            var visible = [];
            for (var i = 0; i < all.length; i += 1) {
                var rect = all[i].getBoundingClientRect();
                if (rect.bottom > 0 && rect.top < height) {
                    visible.push({ chapter: chapterOf(all[i]), fraction: fractionOf(all[i], height) });
                }
            }
            return {
                type: 'reading',
                chapter: chapterOf(section),
                fraction: fractionOf(section, height),
                visible: visible,
                first: chapterOf(all[0]),
                last: chapterOf(all[all.length - 1]),
                nearStart: all[0].getBoundingClientRect().top > -NEAR_START_SCREENS * height,
                nearEnd: all[all.length - 1].getBoundingClientRect().bottom < height * (1 + NEAR_END_SCREENS)
            };
        }

        // The words last under the reading line at the width they were read at. A
        // scroll the browser makes while it reflows for a new width must not
        // replace them before the resize handler has put them back.
        var heldAnchor = null;
        var heldWidth = window.innerWidth;
        var lastReportAt = 0;
        var reportTimer = null;
        var framePending = false;

        function report() {
            if (reportTimer) { clearTimeout(reportTimer); reportTimer = null; }
            lastReportAt = Date.now();
            var message = reading();
            if (!message) { return; }
            if (window.innerWidth === heldWidth) { heldAnchor = captureAnchor(); }
            post(message);
        }
        function scheduleReport() {
            if (framePending) { return; }
            framePending = true;
            window.requestAnimationFrame(function () {
                framePending = false;
                var wait = REPORT_INTERVAL - (Date.now() - lastReportAt);
                if (wait <= 0) { report(); } else if (!reportTimer) { reportTimer = setTimeout(report, wait); }
            });
        }
        window.addEventListener('scroll', scheduleReport, { passive: true });
        window.addEventListener('resize', function () {
            if (window.innerWidth !== heldWidth) {
                var anchor = heldAnchor;
                heldWidth = window.innerWidth;
                restoreAnchor(anchor);
                window.requestAnimationFrame(function () { restoreAnchor(anchor); });
            }
            scheduleReport();
        });
        ['start', 'end'].forEach(function (edge) {
            var element = edgeElement(edge);
            var retry = element ? element.querySelector('.flm-book-retry') : null;
            if (!retry) { return; }
            retry.addEventListener('click', function () {
                if (element.getAttribute('data-state') === 'failed') { post({ type: 'retry', edge: edge }); }
            });
        });

        function build(step) {
            var section = document.createElement('section');
            section.className = 'flm-book-chapter';
            section.setAttribute('data-flm-chapter', step.id);
            if (step.bookStart) { section.setAttribute('data-flm-book-start', ''); }
            section.innerHTML = step.html;
            var lazy = section.querySelectorAll('img[loading]');
            for (var i = 0; i < lazy.length; i += 1) { lazy[i].removeAttribute('loading'); }
            return section;
        }
        // A chapter joins the page at its final height: its pictures are decoded
        // first, so nothing above the reader grows after the words were put back.
        function settle(section) {
            var waits = Array.prototype.slice.call(section.querySelectorAll('img')).map(function (img) {
                if (img.complete && img.naturalWidth) { return null; }
                var loaded = img.decode ? img.decode() : new Promise(function (resolve) {
                    img.addEventListener('load', resolve);
                    img.addEventListener('error', resolve);
                });
                return loaded.catch(function () {});
            });
            return Promise.race([
                Promise.all(waits),
                new Promise(function (resolve) { setTimeout(resolve, SETTLE_TIMEOUT); })
            ]);
        }

        function apply(steps) {
            steps = steps || [];
            var added = steps.filter(function (step) { return step.op === 'insert' && !sectionFor(step.id); });
            added.forEach(function (step) { step.section = build(step); });
            return Promise.all(added.map(function (step) { return settle(step.section); })).then(function () {
                // Whatever comes or goes sits above or below the chapter under the
                // reading line, and that chapter's words stay where they are.
                var reference = currentSection(sections(), screenHeight());
                var referenceTop = reference ? reference.getBoundingClientRect().top : 0;
                var changed = false;
                steps.forEach(function (step) {
                    if (step.op === 'remove') {
                        var gone = sectionFor(step.id);
                        if (gone && gone !== reference) { gone.parentNode.removeChild(gone); changed = true; }
                    } else if (step.op === 'insert') {
                        if (!step.section || step.section.parentNode || sectionFor(step.id)) { return; }
                        var marker = edgeElement(step.edge === 'start' ? 'start' : 'end');
                        marker.parentNode.insertBefore(step.section, step.edge === 'start' ? marker.nextSibling : marker);
                        changed = true;
                    } else if (step.op === 'edge') {
                        var element = edgeElement(step.edge);
                        if (element && element.getAttribute('data-state') !== step.state) {
                            element.setAttribute('data-state', step.state);
                            changed = true;
                        }
                    }
                });
                if (changed) {
                    classifyGlyphs();
                    if (reference && reference.parentNode) {
                        var shift = reference.getBoundingClientRect().top - referenceTop;
                        if (Math.abs(shift) > 0.5) { window.scrollBy(0, shift); }
                    }
                }
                steps.forEach(function (step) {
                    if (step.op !== 'font') { return; }
                    var anchor = captureAnchor();
                    document.documentElement.style.setProperty('--flm-body-size', step.px + 'px');
                    classifyGlyphs();
                    restoreAnchor(anchor);
                });
                steps.forEach(function (step) {
                    if (step.op === 'scroll') { scrollToChapter(step.id, step.fraction); }
                });
                if (window.foreverlmRepaintHighlights) { window.foreverlmRepaintHighlights(); }
                heldWidth = window.innerWidth;
                report();
                return sections().map(chapterOf);
            });
        }

        window.foreverlmBook = { apply: apply, report: report };
    })();
    """
}
