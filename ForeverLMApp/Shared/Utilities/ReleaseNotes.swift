import Foundation

/// One release's section of the public changelog, `docs-site/changelog.md`.
///
/// That file is bundled into the Mac app so the What's New sheet can show a
/// release's highlights the first time the updated build launches. The sheet
/// shows only the `**Highlights:**` bullets — the rest of a section (the
/// version-bump reasoning, the fix lists) stays on the website.
struct ReleaseNotesEntry: Equatable, Sendable {
    /// The marketing version the section header names, e.g. `0.8.0`.
    var version: String
    /// The build number in the header's `(build N)` parenthetical; older
    /// sections were written before the build rode along and carry none.
    var build: Int?
    /// The `YYYY-MM-DD` date from the header, when present.
    var date: String?
    /// A section whose parenthetical says "withdrawn" describes a build that
    /// was pulled; its notes are never presented.
    var isWithdrawn: Bool
    /// The `- ` bullets under `**Highlights:**`, in order, markdown intact.
    var highlights: [String]
}

/// Parses `docs-site/changelog.md` and picks the sections an updated build
/// should present. Pure functions over strings so the Mac unit tests can pin
/// the format the release workflow now depends on.
enum ReleaseNotesChangelog {
    /// Every `## <version> …` section, in file order (newest first).
    static func parse(_ markdown: String) -> [ReleaseNotesEntry] {
        var entries: [ReleaseNotesEntry] = []
        var current: ReleaseNotesEntry?
        var inHighlights = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("## ") {
                if let finished = current { entries.append(finished) }
                current = parseHeader(String(line.dropFirst(3)))
                inHighlights = false
                continue
            }

            guard current != nil else { continue }

            if line.hasPrefix("**Highlights:**") || line.hasPrefix("**Highlights**") {
                inHighlights = true
                continue
            }

            if inHighlights {
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    let bullet = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if !bullet.isEmpty { current?.highlights.append(bullet) }
                } else if line.isEmpty {
                    // A blank line ends the list; the section's other
                    // paragraphs follow it.
                    inHighlights = false
                }
                // A wrapped continuation line is not a bullet of its own.
            }
        }

        if let finished = current { entries.append(finished) }
        return entries
    }

    /// `0.8.0 (build 48) — 2026-09-04`, `0.5.0 (build 33, withdrawn) — 2026-08-31`,
    /// and the older `0.5.0 — 2026-08-29`. Anything else — an "Unreleased"
    /// heading, prose — is not a release section.
    static func parseHeader(_ header: String) -> ReleaseNotesEntry? {
        var rest = Substring(header.trimmingCharacters(in: .whitespaces))
        let versionEnd = rest.firstIndex(where: { $0 == " " || $0 == "(" }) ?? rest.endIndex
        let version = String(rest[..<versionEnd])
        guard isVersion(version) else { return nil }
        rest = rest[versionEnd...].drop(while: { $0 == " " })

        var build: Int?
        var isWithdrawn = false
        if rest.hasPrefix("(") {
            guard let close = rest.firstIndex(of: ")") else { return nil }
            let parenthetical = rest[rest.index(after: rest.startIndex)..<close]
            let parts = parenthetical.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            for part in parts {
                let lowered = part.lowercased()
                if lowered.hasPrefix("build ") {
                    build = Int(part.dropFirst("build ".count).trimmingCharacters(in: .whitespaces))
                } else if lowered == "withdrawn" {
                    isWithdrawn = true
                }
            }
            rest = rest[rest.index(after: close)...].drop(while: { $0 == " " })
        }

        var date: String?
        for dash in ["—", "–", "-"] where rest.hasPrefix(dash) {
            let candidate = rest.dropFirst(dash.count).trimmingCharacters(in: .whitespaces)
            if isDate(candidate) { date = candidate }
            break
        }

        return ReleaseNotesEntry(
            version: version,
            build: build,
            date: date,
            isWithdrawn: isWithdrawn,
            highlights: []
        )
    }

    /// The section that describes the running build: the one naming both the
    /// version and the build, or — for a section written before build numbers
    /// rode in the header — the one naming the version alone.
    static func entry(forVersion version: String, build: Int, in entries: [ReleaseNotesEntry]) -> ReleaseNotesEntry? {
        if let exact = entries.first(where: { $0.version == version && $0.build == build }) {
            return exact
        }
        return entries.first(where: { $0.version == version && $0.build == nil })
    }

    /// The sections an updated install should be shown, newest first.
    ///
    /// The running build's own section always leads, and is required: without
    /// it there is nothing to say, and the caller records the build as seen.
    /// When the install skipped releases (`lastSeenBuild` is several builds
    /// back), the sections between ride along so a learner who updates weekly
    /// still sees what the intermediate releases added — capped, because a very
    /// long gap is better served by the website than by a scrolling sheet.
    /// Withdrawn builds and sections with no highlights are never shown.
    static func entriesToPresent(
        version: String,
        build: Int,
        lastSeenBuild: Int?,
        in entries: [ReleaseNotesEntry],
        limit: Int = ReleaseNotesPresentation.maximumEntries
    ) -> [ReleaseNotesEntry] {
        guard limit > 0,
              let current = entry(forVersion: version, build: build, in: entries),
              !current.isWithdrawn,
              !current.highlights.isEmpty else {
            return []
        }

        var result = [current]
        guard let lastSeenBuild else { return result }

        for entry in entries where entry != current {
            guard result.count < limit else { break }
            guard let entryBuild = entry.build,
                  entryBuild > lastSeenBuild,
                  entryBuild < build,
                  !entry.isWithdrawn,
                  !entry.highlights.isEmpty else { continue }
            result.append(entry)
        }
        return result
    }

    private static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func isDate(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

/// Whether a launch is the first one after an update, and so should present
/// the sheet at all. Kept separate from the changelog so the two decisions —
/// "is this an update?" and "is there anything to show?" — each have a test.
enum ReleaseNotesPresentation {
    /// The most release sections one sheet shows.
    static let maximumEntries = 4

    /// - `lastSeenBuild == nil` is an install that has never recorded a build.
    ///   For a library that already exists — the app ran before this feature
    ///   shipped — that is an update and the sheet shows. For a fresh install
    ///   it is a first launch: the Getting Started guide owns that moment, and
    ///   "what's new" means nothing to someone who never saw the old version.
    /// - A recorded build older than the running one is an update.
    /// - The same or a newer recorded build (a downgrade, a reinstall) is not.
    static func shouldPresent(currentBuild: Int, lastSeenBuild: Int?, isExistingInstall: Bool) -> Bool {
        guard let lastSeenBuild else { return isExistingInstall }
        return lastSeenBuild < currentBuild
    }
}

/// One highlight bullet, split for display as a card: a short lead, the
/// detail under it, and a symbol that hints at the area it touches.
///
/// The changelog convention is `- **Lead.** Detail…`, which the website
/// renders as a bold opening and the sheet as a card title. Older bullets
/// that were written before the convention split on their first colon when
/// the part before it is short enough to read as a title; anything else is
/// all detail.
struct ReleaseNotesHighlight: Equatable, Sendable {
    var title: String?
    var detail: String
    var symbolName: String

    /// A lead longer than this is a sentence, not a title.
    static let maximumTitleLength = 72

    init(bullet: String) {
        let text = bullet.trimmingCharacters(in: .whitespaces)
        var title: String?
        var detail = text
        // A bullet that is bold from end to end is one sentence, not a title
        // over a detail; it keeps its full stop when it falls back to detail.
        var wholeLead: String?

        if text.hasPrefix("**"),
           let close = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex) {
            let lead = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
            title = Self.tidyTitle(lead)
            wholeLead = lead.trimmingCharacters(in: .whitespaces)
            detail = Self.tidyDetail(String(text[close.upperBound...]))
        } else if let colon = text.firstIndex(of: ":") {
            let lead = String(text[..<colon])
            let rest = String(text[text.index(after: colon)...])
            if lead.count <= Self.maximumTitleLength,
               !lead.contains("\""),
               !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                title = Self.tidyTitle(lead)
                detail = Self.tidyDetail(rest)
            }
        }

        if detail.isEmpty, let lead = title {
            title = nil
            detail = wholeLead ?? lead
        }

        self.title = title
        self.detail = detail
        self.symbolName = Self.symbol(for: text)
    }

    private static func tidyTitle(_ lead: String) -> String {
        var title = lead.trimmingCharacters(in: .whitespaces)
        while let last = title.last, last == "." || last == ":" {
            title.removeLast()
        }
        return title
    }

    /// A bold lead often opens a sentence that carries on past it —
    /// `**Setup asks which model**, and every task…` — so the detail can start
    /// with the comma or conjunction that joined the two. The card sets the
    /// detail on its own line, where that joint reads as a stray `, and`.
    private static func tidyDetail(_ rest: String) -> String {
        var detail = rest.trimmingCharacters(in: .whitespaces)
        var joinedByComma = false
        while let first = detail.first, "—–-:,;".contains(first) {
            if first == "," || first == ";" { joinedByComma = true }
            detail.removeFirst()
            detail = detail.trimmingCharacters(in: .whitespaces)
        }
        if joinedByComma, detail.lowercased().hasPrefix("and ") {
            detail = String(detail.dropFirst("and ".count)).trimmingCharacters(in: .whitespaces)
        }
        if let first = detail.first, first.isLowercase {
            detail = first.uppercased() + detail.dropFirst()
        }
        return detail
    }

    /// Keyword-picked SF Symbol names. The first matching row wins, so the
    /// more specific areas come before the broad ones; an unmatched bullet is
    /// simply "new". A wrong guess costs nothing but a slightly odd glyph.
    static let symbolRules: [(keywords: [String], symbol: String)] = [
        (["deep research", "research"], "text.magnifyingglass"),
        (["google doc", "docs pane", "doc tools", " doc ", " docs ", " doc.", "pages pane", "page tools", " page ", " pages ", " page."], "doc.text"),
        (["memory review", "memory row", "memory", "recall"], "brain.head.profile"),
        (["iphone", "ios", "siri"], "iphone"),
        (["drag", "drop"], "arrow.down.doc"),
        (["context window", "model picker", "gpt", "claude", "gemini", "model"], "cpu"),
        (["podcast", "voice", "audio", "read aloud", "playing", "recording"], "waveform"),
        (["fixed", "crash", "no longer", "stall"], "wrench.and.screwdriver"),
        (["settings", "connector"], "gearshape"),
        (["web", "search"], "globe"),
        (["chat", "composer", "transcript", "tutor"], "bubble.left.and.text.bubble.right"),
        (["reader", "source", "paper", "book", "library"], "book"),
        (["schedule", "day", "morning"], "calendar"),
        (["window", "pane", "sidebar", "rail"], "macwindow"),
    ]

    static func symbol(for text: String) -> String {
        let haystack = " " + text.lowercased() + " "
        for rule in symbolRules where rule.keywords.contains(where: { haystack.contains($0) }) {
            return rule.symbol
        }
        return "sparkles"
    }
}
