import Foundation

/// The line that opens a walkthrough step the chat plays.
///
/// A walkthrough is a pre-written record a source carries
/// (`PaperWalkthrough`); since 2026-09-19 the chat beside the Reader plays it,
/// one assistant turn a step, with no model call (walkthrough-design.md, "the
/// panel becomes a chat"). The turn's text is the step's Markdown, and its
/// first line is this tag — `<flm_walk_step source="…" step="…" index="3"
/// count="11"/>` — so the transcript knows which step of which source's record
/// the turn is, and can draw the anchor chip, the panel letters and the
/// animation beside it. The raw text is kept in the exchange, so a reopened
/// chat rebuilds the same row; the model and every client that draws no row
/// read the text with the line removed (`stripped(_:)`), exactly as
/// `MemoryReviewSourceTurn` is handled.
///
/// The app writes this line, never a model, so there is no streaming case
/// and no instruction to a tutor about it.
enum WalkthroughStepTurn: Equatable, Sendable {

    static let tagName = "flm_walk_step"

    /// Which step of which record a turn plays.
    struct Marker: Hashable, Sendable {
        let sourceID: String
        let stepID: String
        /// Zero-based position of the step in the record.
        let index: Int
        /// How many steps the record has.
        let count: Int

        init(sourceID: String, stepID: String, index: Int, count: Int) {
            self.sourceID = sourceID
            self.stepID = stepID
            self.index = index
            self.count = count
        }
    }

    /// The exact line for a step.
    static func line(_ marker: Marker) -> String {
        "<\(tagName) source=\"\(attributeSafe(marker.sourceID))\" step=\"\(attributeSafe(marker.stepID))\" index=\"\(marker.index)\" count=\"\(marker.count)\"/>"
    }

    /// One piece of a played turn, in order: the marker, or prose.
    enum Part: Equatable, Sendable {
        case text(String)
        case step(Marker)
    }

    /// The text split around its step lines. Prose parts are trimmed and never
    /// empty; a tag missing any attribute is dropped as debris; a text with no
    /// tag is one text part (or none, when it is blank).
    static func split(_ text: String) -> [Part] {
        var parts: [Part] = []
        var pending = ""
        var rest = Substring(text)
        let opener = "<\(tagName)"
        let closer = "</\(tagName)>"

        func flushText() {
            let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(.text(trimmed)) }
            pending = ""
        }

        func nextTag() -> Range<Substring.Index>? {
            let candidates = [rest.range(of: opener), rest.range(of: closer)].compactMap { $0 }
            return candidates.min(by: { $0.lowerBound < $1.lowerBound })
        }

        while let open = nextTag() {
            pending += rest[..<open.lowerBound]
            let tagStart = open.lowerBound
            guard let close = rest[tagStart...].firstIndex(of: ">") else {
                rest = ""
                break
            }
            let tag = rest[tagStart...close]
            rest = rest[rest.index(after: close)...]
            if tag.hasPrefix(closer) { continue }
            if let marker = marker(fromTag: tag) {
                flushText()
                parts.append(.step(marker))
            }
        }
        pending += rest
        flushText()
        return parts
    }

    /// The text with every step line removed.
    static func stripped(_ text: String) -> String {
        guard text.contains("<\(tagName)") else { return text }
        return split(text).compactMap { part -> String? in
            if case .text(let prose) = part { return prose }
            return nil
        }.joined(separator: "\n\n")
    }

    /// The first step line in the text, if any.
    static func marker(in text: String) -> Marker? {
        guard text.contains("<\(tagName)") else { return nil }
        for part in split(text) {
            if case .step(let marker) = part { return marker }
        }
        return nil
    }

    private static func marker(fromTag tag: Substring) -> Marker? {
        guard let sourceID = attributeValue(named: "source", in: tag),
              let stepID = attributeValue(named: "step", in: tag),
              let index = attributeValue(named: "index", in: tag).flatMap({ Int($0) }),
              let count = attributeValue(named: "count", in: tag).flatMap({ Int($0) }),
              index >= 0, count > index else { return nil }
        return Marker(sourceID: sourceID, stepID: stepID, index: index, count: count)
    }

    /// The value of `name=` in the tag, quoted or bare. A copy of
    /// `MemoryReviewSourceTurn`'s parser rather than a call to it: that file is
    /// left out of the WebAssembly build (`Package.swift`), and this one ships
    /// in it.
    private static func attributeValue(named name: String, in tag: Substring) -> String? {
        guard let attribute = tag.range(of: "\(name)=") else { return nil }
        var index = attribute.upperBound
        guard index < tag.endIndex else { return nil }
        let quote = tag[index]
        let value: Substring
        if quote == "\"" || quote == "'" {
            index = tag.index(after: index)
            guard let end = tag[index...].firstIndex(of: quote) else { return nil }
            value = tag[index..<end]
        } else {
            let end = tag[index...].firstIndex(where: { $0 == " " || $0 == "/" || $0 == ">" }) ?? tag.endIndex
            value = tag[index..<end]
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Identifiers are UUIDs and `step-n`; anything that could break the tag
    /// is dropped rather than escaped, so the line always parses.
    private static func attributeSafe(_ value: String) -> String {
        value.filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" && $0 != "<" && $0 != ">" && $0 != "/" }
    }
}
