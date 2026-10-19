import Foundation

// MARK: - Changing a Doc's Markdown for the graph (docs/notes-graph-design.md)
//
// The write the graph makes into another Doc — giving a block an id — as a
// pure edit of its Markdown, and the reading of a Doc's references into words
// for a reader outside the app.
// The storage side (`StorageService+DocGraph.swift`) reads the Doc's
// snapshot, edits it here, and saves it with the snapshot's revision.

enum DocGraphEditing {
    struct BlockIDEdit: Equatable, Sendable {
        let markdown: String
        /// The id the block carries now: the proposed one, or the one it had.
        let blockID: String
        /// False when the block already had an id and nothing was changed.
        let changed: Bool
    }

    /// The Markdown with the block at `key` given the id `proposedID`, ` ^id`
    /// appended to the last line of its own text. The block is the one at
    /// `key` when `keyIsCurrent` (the Doc is still at the revision the key
    /// was read from); otherwise, or when no block has that key, the block
    /// whose plain text is `expectedPlainText` — the one at `key` among
    /// several, else the first. A block that already has an id keeps it and
    /// the Markdown is returned unchanged. Nil when no block can be found.
    static func assigningBlockID(
        _ proposedID: String,
        key: String,
        expectedPlainText: String,
        keyIsCurrent: Bool,
        in markdown: String
    ) -> BlockIDEdit? {
        guard DocGraphSyntax.isBlockID(proposedID) else { return nil }
        let parse = DocGraphParser.parse(markdown, docID: "")
        guard let target = locateBlock(in: parse, key: key, plainText: expectedPlainText, keyIsCurrent: keyIsCurrent) else {
            return nil
        }
        if let existing = target.block.blockID {
            return BlockIDEdit(markdown: markdown, blockID: existing, changed: false)
        }
        guard let last = target.segments.last else { return nil }
        let lines = DocGraphLines(markdown)
        let range = lines.range(ofLine: last.line)
        let text = markdown as NSString
        let line = DocGraphSyntax.appendingBlockID(proposedID, to: text.substring(with: range))
        return BlockIDEdit(
            markdown: text.replacingCharacters(in: range, with: line),
            blockID: proposedID,
            changed: true
        )
    }

    /// The block a key and a text name in a Doc's blocks (see `assigningBlockID`).
    static func locateBlock(in parse: DocGraphParse, key: String, plainText: String, keyIsCurrent: Bool) -> DocGraphParsedBlock? {
        if keyIsCurrent, let block = parse.block(atKey: key) { return block }
        let wanted = collapsed(plainText)
        if wanted.isEmpty {
            // An empty block cannot be told from another by its text: only
            // the block still at its key, still empty, is it.
            guard let block = parse.block(atKey: key), collapsed(block.block.plainText).isEmpty else { return nil }
            return block
        }
        let matches = parse.blocks.filter { collapsed($0.block.plainText) == wanted }
        return matches.first { $0.block.key == key } ?? matches.first
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - Resolving references for a reader outside the app

/// A Doc's Markdown as a published page or `read_doc` with resolved
/// references gives it: `((id))` reads as the block's text (a task's box
/// left off), a paragraph that is only an embed becomes the block and what is
/// nested under it (a list item embedded as a list item, a heading as a
/// heading at its level, a quote as a quote), ` ^id` markers go, `[[Title]]`
/// and `#[[Two words]]` read as their words and `#tag` as its word. A
/// reference to a block `lookup` does not know stays as written. Code,
/// display math, HTML blocks and front matter are left exactly as they are,
/// as is every line with nothing to resolve. References inside resolved text
/// are resolved too, four levels deep, and a block is never inside itself.
enum DocGraphResolver {
    static let depthLimit = 4
    private static let titleOpen = Array("[[".utf16)
    private static let escapedTitleOpen = Array(#"\[\["#.utf16)
    private static let referenceOpen = Array("((".utf16)
    private static let address = Array("http".utf16)

    /// `keepingLines` keeps every line where it was: an embed then reads as
    /// its block's own text on the embed's line, without what is nested under
    /// it. For a view that names blocks by their lines in the text it was
    /// given (the Docs pane's Page view and its Edit mode).
    static func resolve(_ markdown: String, keepingLines: Bool = false, lookup: (String) -> DocGraphParsedBlock?) -> String {
        resolve(markdown, depth: 0, inside: [], keepingLines: keepingLines, lookup: lookup)
    }

    private static func resolve(
        _ markdown: String,
        depth: Int,
        inside: Set<String>,
        keepingLines: Bool = false,
        lookup: (String) -> DocGraphParsedBlock?
    ) -> String {
        let lines = DocGraphLines(markdown)
        let parse = DocGraphParser.parse(markdown, docID: "")
        var embeds: [Int: (column: Int, id: String)] = [:]
        for block in parse.blocks where block.isEmbedOnly && block.segments.count == 1 {
            if let id = block.links.embeds.first, let segment = block.segments.first {
                embeds[segment.line] = (segment.column, id)
            }
        }
        let text = markdown as NSString
        var output: [String] = []
        output.reserveCapacity(lines.count)
        for index in 0..<lines.count {
            let line = text.substring(with: lines.range(ofLine: index))
            let ending = lines.carriageReturns[index] ? "\r" : ""
            if parse.verbatimLines.contains(index) {
                output.append(line + ending)
                continue
            }
            if let embed = embeds[index], depth < depthLimit, !inside.contains(embed.id), let block = lookup(embed.id) {
                let prefix = String(decoding: lines.units[index][..<min(embed.column, lines.units[index].count)], as: UTF16.self)
                if keepingLines {
                    if let text = inlineText(embed.id, depth: depth, inside: inside, lookup: lookup) {
                        output.append(prefix + text + ending)
                        continue
                    }
                } else {
                    let rendered = embedLines(block, prefix: prefix, depth: depth, inside: inside.union([embed.id]), lookup: lookup)
                    output.append(contentsOf: rendered.map { $0 + ending })
                    continue
                }
            }
            let resolved = DocGraphText.removingTrailingBlockID(line)
            output.append(resolveInline(resolved, depth: depth, inside: inside, lookup: lookup) + ending)
        }
        return output.joined(separator: "\n")
    }

    /// One line's inline grammar resolved. What the graph does not read as
    /// grammar is never touched: code spans, links and pictures (their text
    /// too, as `DocGraphText.scan` reads them), autolinks, web addresses and
    /// HTML tags. A tag that is only digits keeps its `#`: in prose written
    /// before the grammar, "Show #676" is a number, and a reader should see it
    /// as one.
    static func resolveInline(
        _ line: String,
        depth: Int,
        inside: Set<String>,
        lookup: (String) -> DocGraphParsedBlock?
    ) -> String {
        let units = Array(line.utf16)
        let hasHash = units.contains(35)
        let hasTitle = DocGraphText.contains(units, Self.titleOpen) || DocGraphText.contains(units, Self.escapedTitleOpen)
        let hasReference = DocGraphText.contains(units, Self.referenceOpen)
        guard hasHash || hasTitle || hasReference else { return line }
        var protected = units
        let code = DocGraphText.codeSpans(units)
        for span in code { DocGraphText.blank(&protected, span) }
        for link in DocGraphText.inlineLinks(units, code: code) { DocGraphText.blank(&protected, link.range) }
        if units.contains(60) {
            for match in DocGraphText.matches(DocGraphText.autolinkExpression, in: protected) { DocGraphText.blank(&protected, match.range) }
            for match in DocGraphText.matches(DocGraphText.htmlTagExpression, in: protected) { DocGraphText.blank(&protected, match.range) }
        }
        if DocGraphText.contains(units, Self.address) {
            for match in DocGraphText.matches(DocGraphText.bareAddressExpression, in: protected) { DocGraphText.blank(&protected, match.range) }
        }

        var replacements: [(range: NSRange, text: String)] = []
        if hasReference {
            for match in DocGraphText.matches(DocGraphText.inlineEmbedExpression, in: protected) {
                if let id = DocGraphText.string(units, match.range(at: 1)),
                   let text = inlineText(id, depth: depth, inside: inside, lookup: lookup) {
                    replacements.append((match.range, text))
                }
            }
        }
        if hasHash {
            for match in DocGraphText.matches(DocGraphText.tagExpression, in: protected) {
                if let words = DocGraphText.string(units, match.range(at: 1)) {
                    replacements.append((match.range, words))
                } else if let word = DocGraphText.string(units, match.range(at: 2)), !word.allSatisfy(\.isNumber) {
                    replacements.append((match.range, word))
                }
            }
        }
        if hasTitle {
            for match in DocGraphText.matches(DocGraphText.titleLinkExpression, in: protected) {
                if let words = DocGraphText.string(units, match.range(at: 1)) {
                    replacements.append((match.range, words))
                }
            }
        }
        if hasReference {
            for match in DocGraphText.matches(DocGraphText.blockReferenceExpression, in: protected) {
                if let id = DocGraphText.string(units, match.range(at: 1)),
                   let text = inlineText(id, depth: depth, inside: inside, lookup: lookup) {
                    replacements.append((match.range, text))
                }
            }
        }
        guard !replacements.isEmpty else { return line }
        // Earlier first; of two that start together the longer. One that
        // overlaps a kept one (the `[[…]]` inside `#[[…]]`) is dropped.
        replacements.sort {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length
        }
        var kept: [(range: NSRange, text: String)] = []
        var reach = 0
        for replacement in replacements where replacement.range.location >= reach {
            kept.append(replacement)
            reach = replacement.range.location + replacement.range.length
        }
        let result = NSMutableString(string: line)
        for replacement in kept.reversed() {
            result.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return result as String
    }

    /// A referenced block's text on one line, its own references resolved.
    private static func inlineText(
        _ id: String,
        depth: Int,
        inside: Set<String>,
        lookup: (String) -> DocGraphParsedBlock?
    ) -> String? {
        guard depth < depthLimit, !inside.contains(id), let block = lookup(id) else { return nil }
        var text = block.block.markdown
        if block.block.kind == .listItem { text = DocGraphText.removingTaskBox(text) }
        text = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return resolveInline(text, depth: depth + 1, inside: inside.union([id]), lookup: lookup)
    }

    /// The lines an embed paragraph becomes, each starting with `prefix`
    /// (the indentation, list marker or `>` the embed was written after) or
    /// its continuation.
    private static func embedLines(
        _ block: DocGraphParsedBlock,
        prefix: String,
        depth: Int,
        inside: Set<String>,
        lookup: (String) -> DocGraphParsedBlock?
    ) -> [String] {
        var own = resolveInline(block.block.markdown, depth: depth + 1, inside: inside, lookup: lookup)
            .components(separatedBy: "\n")
        let children = block.block.childrenMarkdown.isEmpty
            ? []
            : resolve(block.block.childrenMarkdown, depth: depth + 1, inside: inside, lookup: lookup).components(separatedBy: "\n")
        let continuation = String(prefix.map { $0 == ">" || $0.isWhitespace ? $0 : " " })
        let inListItem = prefix.contains { !($0 == ">" || $0.isWhitespace) }
        func line(_ lead: String, _ text: String) -> String {
            text.isEmpty ? DocGraphText.trimmingTrailingWhitespace(lead) : lead + text
        }
        let first = own.removeFirst()
        if inListItem {
            return [line(prefix, first)] + own.map { line(continuation, $0) } + children.map { line(continuation, $0) }
        }
        switch block.block.kind {
        case .listItem:
            return [prefix + "- " + first]
                + own.map { line(continuation + "  ", $0) }
                + children.map { line(continuation + "  ", $0) }
        case .heading:
            let level = min(max(block.headingLevel ?? 2, 1), 6)
            return [prefix + String(repeating: "#", count: level) + " " + ([first] + own).joined(separator: " ")]
        case .quote:
            return [line(prefix + "> ", first)] + own.map { line(continuation + "> ", $0) }
        case .paragraph:
            return [line(prefix, first)] + own.map { line(continuation, $0) }
        }
    }
}
