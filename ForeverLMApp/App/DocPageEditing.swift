import Foundation

// Editing a Doc from its rendered page (docs/docs-design.md → Edit with AI →
// On the page). The page marks each block with the Markdown lines behind it
// (`data-src`, publishing/markdown.ts); a hover offers **Edit**; the writer
// says what should change; the model answers through the same Edit-with-AI
// route the editor uses; and the page is drawn again with the proposal in
// place under a Keep / Try again / Discard bar. These are the pure parts: the
// session that carries one request to the writer's decision, the messages the
// page posts, the passage a mark names, and the splice that puts the answer
// back. `ArtifactPageWebView` and the doc view own the round trips.

/// One request from the page, through to the writer's decision.
struct DocPageEditSession: Equatable {
    enum Status: Equatable {
        /// The model is working on the instruction.
        case working
        /// `candidate` holds the proposal; the writer decides.
        case proposed
        /// The model could not answer; the page says why.
        case failed(String)
        /// Keep made the candidate the draft; the page offers Undo for a moment.
        case kept
    }

    let id: UUID
    /// The marked block's lines in `original`, end exclusive.
    let start: Int
    let end: Int
    var instruction: String
    /// The words the writer highlighted, when they are only part of the blocks:
    /// the model is told to change nothing else.
    var selection: String?
    /// The Markdown the request was made against. Every retry starts here, so
    /// a second attempt never rewrites the first attempt's answer.
    let original: String
    /// `original` with the proposal spliced in, once one has arrived. The page
    /// shows this while the writer decides, and Keep makes it the draft.
    var candidate: String?
    /// Where the proposal ends in `candidate`.
    var candidateEnd: Int?
    var status: Status

    init(start: Int, end: Int, instruction: String, selection: String? = nil, original: String) {
        id = UUID()
        self.start = start
        self.end = end
        self.instruction = instruction
        self.selection = selection
        self.original = original
        status = .working
    }

    /// The writer's own text for the block, already written: the session
    /// stands as kept so the page can offer Undo.
    static func kept(start: Int, end: Int, original: String, markdown: String) -> DocPageEditSession {
        var session = DocPageEditSession(start: start, end: end, instruction: "", original: original)
        let spliced = DocPagePassage.splice(markdown: original, start: start, end: end, proposal: markdown, literal: true)
        session.candidate = spliced.markdown
        session.candidateEnd = spliced.end
        session.status = .kept
        return session
    }

    /// The proposal arrived: hold the spliced text and show it.
    mutating func propose(_ proposal: String) {
        let spliced = DocPagePassage.splice(markdown: original, start: start, end: end, proposal: proposal)
        candidate = spliced.markdown
        candidateEnd = spliced.end
        status = .proposed
    }

    /// What the page shows for this session (`ForeverLMPage.review`).
    var review: DocPageEditReview {
        switch status {
        case .working:
            // A first attempt marks the block it was asked on; a retry keeps
            // the previous proposal on screen while the next one is made.
            return DocPageEditReview(status: .working, start: start, end: candidateEnd ?? end, instruction: instruction, message: nil)
        case .proposed:
            return DocPageEditReview(status: .proposed, start: start, end: candidateEnd ?? end, instruction: instruction, message: nil)
        case .failed(let message):
            return DocPageEditReview(status: .failed, start: start, end: candidateEnd ?? end, instruction: instruction, message: message)
        case .kept:
            return DocPageEditReview(status: .kept, start: start, end: candidateEnd ?? end, instruction: instruction, message: nil)
        }
    }

    /// Changes whenever the page has to be drawn again for this session: a
    /// new proposal shows different text; a decision shows the draft.
    var renderKey: String { "\(id.uuidString):\(candidate?.hashValue ?? 0)" }
}

/// The review state the page draws: which blocks, in what state, and the words
/// the bar carries.
struct DocPageEditReview: Equatable {
    enum Status: String {
        case working, proposed, failed, kept
    }

    var status: Status
    var start: Int
    var end: Int
    var instruction: String
    var message: String?

    /// The JSON `ForeverLMPage.review` takes.
    var json: String {
        var object: [String: Any] = [
            "status": status.rawValue,
            "start": start,
            "end": end,
            "instruction": instruction,
        ]
        if let message { object["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}

/// What the page can ask of the host.
enum DocPageEditMessage: Equatable {
    /// The writer asked for a change to the blocks at these lines; `selection`
    /// is the words they highlighted when those are only part of the blocks.
    case editRequested(start: Int, end: Int, instruction: String, selection: String?)
    /// Keep the proposal: it becomes the draft.
    case keep
    /// Ask again, with this instruction, against the original text.
    case retry(instruction: String)
    /// Drop the proposal; the page shows the draft again.
    case discard
    /// Put the draft back as it was before Keep.
    case undo
    /// The writer wants the block's own Markdown, to change it by hand.
    case sourceRequested(start: Int, end: Int)
    /// The writer's own text for the block's lines; written as typing is.
    case textEdited(start: Int, end: Int, markdown: String)

    init?(body: Any) {
        guard let dictionary = body as? [String: Any], let type = dictionary["type"] as? String else { return nil }
        switch type {
        case "editRequested":
            guard let start = Self.integer(dictionary["start"]), let end = Self.integer(dictionary["end"]),
                  let instruction = dictionary["instruction"] as? String, start >= 0, end > start else { return nil }
            let selection = (dictionary["selection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .editRequested(start: start, end: end, instruction: instruction, selection: selection.flatMap { $0.isEmpty ? nil : $0 })
        case "reviewKeep": self = .keep
        case "reviewRetry":
            guard let instruction = dictionary["instruction"] as? String else { return nil }
            self = .retry(instruction: instruction)
        case "reviewDiscard": self = .discard
        case "reviewUndo": self = .undo
        case "sourceRequested":
            guard let start = Self.integer(dictionary["start"]), let end = Self.integer(dictionary["end"]), start >= 0, end > start else { return nil }
            self = .sourceRequested(start: start, end: end)
        case "textEdited":
            guard let start = Self.integer(dictionary["start"]), let end = Self.integer(dictionary["end"]),
                  let markdown = dictionary["markdown"] as? String, start >= 0, end > start else { return nil }
            self = .textEdited(start: start, end: end, markdown: markdown)
        default: return nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

/// The Markdown behind a page mark, and putting an answer back in its place.
enum DocPagePassage {
    /// The document as the page's marks count it: one entry per line, line
    /// endings normalised the way the renderer normalises them.
    static func lines(_ markdown: String) -> [String] {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Whether `start..<end` names lines this text has.
    static func isValid(start: Int, end: Int, in lines: [String]) -> Bool {
        start >= 0 && end > start && end <= lines.count
    }

    /// The Edit-with-AI request for the block at `start..<end`: the block as
    /// stored Markdown, a bounded run of the text either side, and the section
    /// it sits in. Nil when the marks no longer describe this text, which can
    /// happen if the draft changed after the page was drawn.
    static func request(
        markdown: String,
        start: Int,
        end: Int,
        instruction: String,
        selection: String? = nil,
        docTitle: String,
        contextLimit: Int = 1200
    ) -> DocPassageEditRequest? {
        let all = lines(markdown)
        guard isValid(start: start, end: end, in: all) else { return nil }
        return DocPassageEditRequest(
            instruction: scopedInstruction(instruction, selection: selection),
            passage: all[start..<end].joined(separator: "\n"),
            before: context(all[..<start], limit: contextLimit, fromEnd: true),
            after: context(all[end...], limit: contextLimit, fromEnd: false),
            inline: false,
            sectionTitle: sectionTitle(in: all, before: start),
            docTitle: docTitle
        )
    }

    /// The block's own Markdown at `start..<end`, or nil when the marks no
    /// longer describe this text.
    static func passage(markdown: String, start: Int, end: Int) -> String? {
        let all = lines(markdown)
        guard isValid(start: start, end: end, in: all) else { return nil }
        return all[start..<end].joined(separator: "\n")
    }

    /// The instruction the model gets when the writer highlighted only part of
    /// the passage: change those words, keep the rest. The passage stays whole
    /// so the answer splices back over the same lines.
    static func scopedInstruction(_ instruction: String, selection: String?) -> String {
        guard let selection = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty else { return instruction }
        return "Change only this part of the passage, and return the whole passage with everything else exactly as it is: “\(selection)”. \(instruction)"
    }

    /// `markdown` with lines `start..<end` replaced by `proposal`, and where
    /// the proposal now ends. A proposal that is nothing removes the block.
    /// A model's answer is normalised (`normalizedProposal`); the writer's own
    /// text (`literal`) is kept as typed, less blank lines at either end.
    static func splice(markdown: String, start: Int, end: Int, proposal: String, literal: Bool = false) -> (markdown: String, end: Int) {
        var all = lines(markdown)
        guard isValid(start: start, end: end, in: all) else { return (markdown, end) }
        let replacement = literal
            ? proposal.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .newlines)
            : normalizedProposal(proposal)
        let replacementLines = replacement.isEmpty ? [] : lines(replacement)
        all.replaceSubrange(start..<end, with: replacementLines)
        return (all.joined(separator: "\n"), start + replacementLines.count)
    }

    /// The answer as the document should hold it: no code fence the model may
    /// have wrapped it in despite the prompt, and no blank lines at either end.
    static func normalizedProposal(_ text: String) -> String {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        body = body.trimmingCharacters(in: .newlines)
        var fenced = lines(body)
        if fenced.count >= 2,
           let first = fenced.first, let last = fenced.last,
           first.range(of: #"^\s{0,3}(`{3,}|~{3,})[^`]*$"#, options: .regularExpression) != nil,
           last.range(of: #"^\s{0,3}(`{3,}|~{3,})\s*$"#, options: .regularExpression) != nil {
            fenced.removeFirst()
            fenced.removeLast()
            body = fenced.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        return body
    }

    /// The nearest heading above `start`: the section the block sits in.
    static func sectionTitle(in lines: [String], before start: Int) -> String {
        guard start > 0 else { return "" }
        for line in lines[..<min(start, lines.count)].reversed() {
            if let match = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                var text = String(line[match.upperBound...])
                text = text.replacingOccurrences(of: #"\s*#+\s*$"#, with: "", options: .regularExpression)
                return text.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// Whole lines from one side of the block, up to about `limit` characters.
    private static func context(_ slice: ArraySlice<String>, limit: Int, fromEnd: Bool) -> String {
        var taken: [String] = []
        var length = 0
        for line in fromEnd ? Array(slice.reversed()) : Array(slice) {
            if length >= limit, !taken.isEmpty { break }
            taken.append(line)
            length += line.count + 1
        }
        if fromEnd { taken.reverse() }
        return taken.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
