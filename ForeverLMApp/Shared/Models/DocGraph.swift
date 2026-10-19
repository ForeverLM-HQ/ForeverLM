import Foundation

// MARK: - Notes as a graph (docs/notes-graph-design.md)
//
// Roam Research's way of taking notes, inside Docs: every block of a Doc can
// be referenced from anywhere, every page lists what points at it, and a page
// a day is waiting to be written in. This file is the vocabulary the editor,
// the graph index, the Mac's Docs pane and MCP share:
//
// - A block names itself with ` ^id` at the end of its own text, the way
//   Obsidian marks a block; the editor hides the marker. Only a block that
//   has been referenced carries one.
// - `((id))` references a block inline and reads as that block's text;
//   `{{embed: ((id))}}`, alone in a paragraph, shows the block and what is
//   nested under it.
// - A page is named by id, `[Title](foreverlm://doc/<id>)` as before, or by
//   title, `[[Title]]`, `#tag` or `#[[Two words]]`, which name the Doc with
//   that title in the same library and make it when it is first opened.
// - A daily note is an ordinary Doc whose id is its day, `daily-2026-10-06`,
//   so two Macs that open the same day write the same record.
//
// Everything a reader needs is in the Markdown, so a Doc stays a Doc on every
// client: one that does not know the grammar shows the markers as text.

/// The Markdown forms of the notes graph. The editor's JavaScript reads and
/// writes the same forms (docs/notes-graph-design.md, "Grammar"); a change
/// here is a change there.
enum DocGraphSyntax {
    /// A block id: nine lowercase letters and digits, as Roam's are nine
    /// characters. Lowercase only, so no client ever has to escape one.
    static let blockIDLength = 9
    private static let blockIDAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// The block id marker at the end of a block's own text: ` ^id`.
    static let blockIDMarkerPattern = #"(?:^|[ \t])\^([a-z0-9]{9})[ \t]*$"#
    /// An inline block reference.
    static let blockReferencePattern = #"\(\(([a-z0-9]{9})\)\)"#
    /// A paragraph that is nothing but an embed. `{{[[embed]]: ((id))}}`, the
    /// form Roam itself writes, is read too.
    static let blockEmbedPattern = #"^\{\{\s*(?:\[\[)?embed(?:\]\])?\s*:\s*\(\(([a-z0-9]{9})\)\)\s*\}\}$"#
    /// A title link, `[[Title]]`. The editor's Markdown serializer may store
    /// the brackets escaped, `\[\[Title\]\]`; a reader takes both.
    static let titleLinkPattern = #"\\?\[\\?\[((?:[^\[\]\\\n]|\\[^\n])+?)\\?\]\\?\]"#
    /// A tag: `#word` (letters, digits, `_`, `-`, `/`) or `#[[Two words]]`,
    /// at the start of the text or after whitespace or an opening bracket.
    /// The editor's serializer may store a tag that begins a line as `\#tag`.
    static let tagPattern = #"(?:^|(?<=[\s(]))\\?#(?:\\?\[\\?\[((?:[^\[\]\\\n]|\\[^\n])+?)\\?\]\\?\]|([\p{L}\p{N}_\-/]*[\p{L}\p{N}_][\p{L}\p{N}_\-/]*))"#

    static func newBlockID() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<blockIDLength).map { _ in blockIDAlphabet.randomElement(using: &generator)! })
    }

    static func isBlockID(_ value: String) -> Bool {
        value.count == blockIDLength && value.allSatisfy { blockIDAlphabet.contains($0) }
    }

    static func blockReference(_ blockID: String) -> String { "((\(blockID)))" }

    static func blockEmbed(_ blockID: String) -> String { "{{embed: ((\(blockID)))}}" }

    /// How a block's text carries its id: the marker after its last word.
    static func appendingBlockID(_ blockID: String, to text: String) -> String {
        let trimmed = text.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? "^\(blockID)" : "\(trimmed) ^\(blockID)"
    }

    /// The block id a line of Markdown ends with, if any.
    static func blockID(endingLine line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: blockIDMarkerPattern) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// A line with its block id marker taken off.
    static func removingBlockID(from line: String) -> String {
        line.replacingOccurrences(of: blockIDMarkerPattern, with: "", options: .regularExpression)
    }

    /// How two titles are compared: case, accents and runs of whitespace
    /// do not tell titles apart, as they do not in Roam.
    static func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// A title as written inside a title link or tag: a stored `\]`
    /// unescaped, so `[[A \[draft\]]]` names "A [draft]".
    static func unescapedTitle(_ raw: String) -> String {
        var result = ""
        var escaping = false
        for character in raw {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Working memory

/// What ForeverLM remembers about the learner's work, kept in the background
/// as ChatGPT keeps its memory (product owner, 2026-10-11: "That should not
/// actually be a like explicit page. That should just be kind of saved in the
/// background … not visible to the user, kind of like memory"). Two records
/// hold it: the running log (`WorkingLog`) and the carrier of the working
/// notes (`WorkingNoteMirror`). They are artifact records with fixed ids only
/// so that sync carries them to the learner's other Macs; they are never a
/// Doc. No list, picker, search, Space, notebook or `list_docs` shows them
/// (`ArtifactListing.listed`, `MobileSpaceListing.isSpaceRecord`), the Doc
/// tools refuse their ids, and the learner reads and corrects the notes in
/// Settings › Data & Privacy › Notes about your work.
enum WorkingMemoryRecords {
    static let notesID = "working-notes"
    static let ids: Set<String> = [WorkingLog.id, notesID]

    static func contains(_ id: String) -> Bool { ids.contains(id) }
}

// MARK: - The working log

/// "What I'm working on": the one running summary of the learner's activity
/// (product owner, 2026-10-10: the day should be planned from "a smart and running,
/// updated doc of what I'm working on", not from stored Goal artifacts, and
/// "running summary should often be fed into the context of the agents").
/// A background record (`WorkingMemoryRecords`) with a fixed id, so the same
/// log on two Macs is one record. Its top section, `## Right now`, is
/// rewritten whenever the picture changes: the threads in play, how long since
/// each was touched, what has gone quiet. Below it, `## Log` holds timestamped
/// lines, newest first (`- 2026-10-10 14:05 Read …`). Every chat reads it
/// (`promptExcerpt`); planning the day starts from it.
enum WorkingLog {
    static let id = "working-log"
    static let title = "What I'm working on"

    /// The body of a log nobody has written in yet.
    static let seedMarkdown = """
    ## Right now

    Nothing recorded yet.

    ## Log

    """

    static let rightNowHeading = "## Right now"
    static let logHeading = "## Log"
    static let maximumLogLines = 200

    /// The body of `## Right now`, or "" when the Doc has no such section.
    static func rightNowSection(of markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == rightNowHeading }) else { return "" }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        let body = lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body == "Nothing recorded yet." ? "" : body
    }

    /// The Doc after a run: `## Right now` replaced by `rightNow` (kept as it
    /// was when nil or blank), and `entries` stamped with `now` and put at the
    /// top of `## Log`, newest first. The learner's own lines below the log's
    /// are kept, up to `maximumLogLines`. A Doc the learner rewrote without
    /// the two headings is kept whole under a fresh `## Log`: nothing they
    /// wrote is dropped.
    static func updated(
        markdown: String,
        rightNow: String?,
        entries: [String],
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let lines = markdown.components(separatedBy: "\n")
        let rightIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == rightNowHeading }
        let logIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == logHeading }

        var currentRightNow = ""
        var existingLog = [String]()
        var preface = [String]()
        if let rightIndex, let logIndex, rightIndex < logIndex {
            preface = Array(lines[..<rightIndex])
            currentRightNow = lines[(rightIndex + 1)..<logIndex].joined(separator: "\n")
            existingLog = Array(lines[(logIndex + 1)...])
        } else {
            existingLog = lines
        }

        let newRightNow = rightNow?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? rightNow!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (currentRightNow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Nothing recorded yet."
                : currentRightNow.trimmingCharacters(in: .whitespacesAndNewlines))

        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let stamp = String(
            format: "%04d-%02d-%02d %02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
        let stamped = entries
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .reversed()
            .map { "- \(stamp) \($0)" }

        var log = stamped + existingLog.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if log.count > maximumLogLines { log = Array(log.prefix(maximumLogLines)) }

        var out = preface
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        if !out.isEmpty { out.append("") }
        out += [rightNowHeading, "", newRightNow, "", logHeading, ""]
        out += log
        return out.joined(separator: "\n") + "\n"
    }

    /// How much of the log rides in a chat's prompt. The head is what the
    /// prompt needs (the summary, then the newest entries); the tail of a long
    /// log stays in the Doc for `read_doc`.
    static let promptCharacterLimit = 3_000

    /// The log as a prompt carries it, or nil while it holds nothing but the
    /// seed. A long log is cut at a line boundary.
    static func promptExcerpt(fromMarkdown markdown: String) -> String? {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Untouched: the seed's placeholder and no entry under it.
        let hasEntry = trimmed.contains("\n- ") || trimmed.hasPrefix("- ")
        guard hasEntry || !trimmed.contains("Nothing recorded yet.") else { return nil }
        guard trimmed.count > promptCharacterLimit else { return trimmed }
        let head = String(trimmed.prefix(promptCharacterLimit))
        let cut = head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? head
        return cut + "\n…"
    }
}

// MARK: - Daily notes

/// A page a day, as Roam keeps one (docs/notes-graph-design.md, "Daily
/// Notes"). A daily note is an ordinary Markdown Doc in My Library whose id
/// is its day, so the same day opened on two Macs is one record, and whose
/// title is the day written out, "October 6th, 2026", as Roam titles it.
/// The day is the calendar day where the Mac is.
enum DailyNote {
    static let idPrefix = "daily-"

    /// `2026-10-06` for the day `date` falls on.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func id(forDayKey dayKey: String) -> String { idPrefix + dayKey }

    static func id(for date: Date, calendar: Calendar = .current) -> String {
        id(forDayKey: dayKey(for: date, calendar: calendar))
    }

    static func isDailyNoteID(_ id: String) -> Bool { dayKey(ofID: id) != nil }

    /// The day a daily note's id names; nil for any other id.
    static func dayKey(ofID id: String) -> String? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let key = String(id.dropFirst(idPrefix.count))
        return date(forDayKey: key) == nil ? nil : key
    }

    /// Midnight of the day a key names, where the Mac is.
    static func date(forDayKey dayKey: String, calendar: Calendar = .current) -> Date? {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              Self.dayKey(for: date, calendar: calendar) == dayKey else { return nil }
        return date
    }

    /// "October 6th, 2026".
    static func title(forDayKey dayKey: String, calendar: Calendar = .current) -> String? {
        guard let date = date(forDayKey: dayKey, calendar: calendar) else { return nil }
        return title(for: date, calendar: calendar)
    }

    static func title(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let month = formatter.monthSymbols[(parts.month ?? 1) - 1]
        let day = parts.day ?? 1
        return "\(month) \(day)\(ordinalSuffix(day)), \(parts.year ?? 0)"
    }

    /// The day a title such as "October 6th, 2026" or "October 6, 2026"
    /// names; nil for any other title. How `[[October 6th, 2026]]` finds its
    /// daily note before the note exists.
    static func dayKey(fromTitle title: String, calendar: Calendar = .current) -> String? {
        let pattern = #"^\s*([A-Za-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = title as NSString
        guard let match = regex.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let monthName = ns.substring(with: match.range(at: 1)).lowercased()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let monthIndex = formatter.monthSymbols.firstIndex(where: { $0.lowercased() == monthName })
                ?? formatter.shortMonthSymbols.firstIndex(where: { $0.lowercased() == monthName }),
              let day = Int(ns.substring(with: match.range(at: 2))),
              let year = Int(ns.substring(with: match.range(at: 3))) else { return nil }
        let key = String(format: "%04d-%02d-%02d", year, monthIndex + 1, day)
        return date(forDayKey: key, calendar: calendar) == nil ? nil : key
    }

    static func ordinalSuffix(_ day: Int) -> String {
        switch day % 100 {
        case 11, 12, 13: return "th"
        default:
            switch day % 10 {
            case 1: return "st"
            case 2: return "nd"
            case 3: return "rd"
            default: return "th"
            }
        }
    }
}

// MARK: - What the graph answers with

/// A block of a Doc as the graph reads it from the stored Markdown.
struct DocGraphBlock: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case paragraph, heading, listItem, quote
    }

    let docID: String
    /// Where the block sits in its Doc at the revision it was read from: the
    /// top-level block's index, then the index of each list item it is
    /// nested in, joined by dots ("4", "4.2.0"). Only good for that revision.
    let key: String
    let kind: Kind
    /// The block's own ` ^id`, nil while nothing references it.
    var blockID: String?
    /// The block's own Markdown text (a list item's first paragraph, without
    /// its marker and its nested items), its ` ^id` marker taken off.
    var markdown: String
    /// The text for search, mentions and display: links read as their text,
    /// emphasis and code marks dropped.
    var plainText: String
    /// The plain text of the blocks it sits under, outermost first, as
    /// Roam's breadcrumbs show them: the list items it is nested in, and the
    /// heading of its section when it has one.
    var breadcrumbs: [String]
    /// The Markdown nested under it (a list item's sub-items), unindented to
    /// stand alone; empty when nothing is.
    var childrenMarkdown: String
    /// The line in the Doc's Markdown the block starts on, 0-based.
    var line: Int
}

/// What a page of references is about.
enum DocGraphTarget: Hashable, Sendable {
    case doc(String)
    case idea(String)
    case source(String)
    case block(String)
}

/// One page whose blocks point at a target, the way Roam's Linked
/// References group them: by page, each block with its breadcrumbs.
struct DocGraphReferenceGroup: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case doc, dailyNote, idea
    }

    let kind: Kind
    /// The Doc's or the Idea's id.
    let id: String
    var title: String
    var updatedAt: Date
    /// The blocks that point at the target, in the order they stand in the
    /// page. Empty for an Idea, which points as a whole (`IdeaLink`).
    var blocks: [DocGraphBlock]
}

/// A page's title written in another Doc but not linked: Roam's Unlinked
/// References, which `get_linked_references` lists with `include_unlinked`.
/// The page foot does not draw them (product owner, 2026-10-19).
struct DocGraphMention: Codable, Equatable, Sendable {
    let docID: String
    var docTitle: String
    /// The Doc's revision the block and the range belong to.
    var revision: String
    var block: DocGraphBlock
    /// Where the title stands in `block.markdown`, as UTF-16 offsets.
    var start: Int
    var end: Int
}

/// A block offered under `((`: what the editor shows and what it needs to
/// reference the block, giving it an id first when it has none.
struct DocGraphBlockHit: Codable, Equatable, Sendable {
    let docID: String
    var docTitle: String
    var revision: String
    var block: DocGraphBlock
}

enum DocGraphError: LocalizedError, Equatable {
    case notBuilt(String)
    case blockNotFound(String)
    case blockMoved(String)
    case notMarkdown(String)

    var errorDescription: String? {
        switch self {
        case .notBuilt(let what): return "\(what) is not built yet."
        case .blockNotFound(let id): return "No Page holds the block ((\(id)))."
        case .blockMoved(let title): return "That block changed in “\(title)” before it could be referenced. Try again."
        case .notMarkdown(let title): return "“\(title)” is not a Markdown Page."
        }
    }
}

/// Where a daily note is listed. A daily note is reached by its day — the
/// rail's Daily Notes row, ⇧⌘D, a day's link, the day stepper — so an empty
/// one keeps out of Docs' side list, the Docs home and the home's Docs tab,
/// where a year of days would bury the docs. A day that holds writing is
/// listed like any page: a note the learner titled or edited is their work,
/// and a list that hid it (the 2026-10-07 note, 8 KB of an essay, found in no
/// list) would lose it from sight. A search is the other way in: typing a day
/// ("October 6") into a list's search field finds that day's note, the way
/// Roam's search finds a daily page, because the search is the learner
/// asking for something by name.
enum NotesGraphDocListing {
    /// A daily note is listed when it was searched for, or when it has been
    /// written in: its title is no longer the day written out, or it was
    /// saved after it was made.
    static func isListed(id: String, title: String, createdAt: Date, updatedAt: Date, searchQuery: String) -> Bool {
        guard let dayKey = DailyNote.dayKey(ofID: id) else { return true }
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if title != DailyNote.title(forDayKey: dayKey) { return true }
        return updatedAt > createdAt
    }
}
