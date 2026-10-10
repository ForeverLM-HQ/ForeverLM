import CryptoKit
import Foundation

/// What the learner has made of one source, as prose.
///
/// This is deliberately a markdown file on disk rather than a column: the whole
/// point is that the learner can open it, correct it, and have that correction
/// shape later sessions. Identity, staleness, and relationships stay in SQLite —
/// the same split `source_review_guides` uses.
///
/// The body is lossy and always regenerable. Transcripts remain the immutable
/// record, so a document lost to an iCloud conflict costs nothing permanent.
struct UnderstandingDocument: Equatable, Sendable {
    let sourceID: String
    /// Stable for the life of the source. Stored rather than recomputed, so a
    /// retitled source keeps writing to the file it already has.
    let relativePath: String
    var markdown: String
    /// The last review whose transcript was folded in. Lets the closer skip work
    /// and lets the planner tell fresh understanding from stale.
    var derivedThroughSessionID: String?
    var generatedAt: Date
    var generatorVersion: Int
    /// Digest of the body as the model last wrote it. When the file on disk no
    /// longer matches, the learner has edited it by hand — which is a feature,
    /// and the model is told so rather than quietly overwriting.
    var bodySHA256: String
    /// How many threads the closer left open on this source. The *count* is
    /// structure and lives in SQLite so the cohort query can find unfinished
    /// business without reading every file; *what* is open is meaning and stays
    /// in the prose.
    var openThreadCount: Int
    /// Which of the source's ideas the conversations folded into this document
    /// actually engaged. Structure, so it lives in SQLite beside the index
    /// rather than in the prose: the next review reads it to decide what a
    /// chat-discussed source may be asked about. Empty means nothing is known,
    /// which is every document written before schema 129.
    var discussedIdeaIDs: [String] = []

    static let currentGeneratorVersion = 1

    static func digest(_ markdown: String) -> String {
        let data = Data(markdown.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var hasLearnerEdits: Bool {
        UnderstandingDocument.digest(markdown) != bodySHA256
    }
}

/// The index row without the body, for callers that only need staleness.
struct UnderstandingIndexEntry: Equatable, Sendable {
    let sourceID: String
    let relativePath: String
    let derivedThroughSessionID: String?
    let generatedAt: Date
    let generatorVersion: Int
    let bodySHA256: String
    let openThreadCount: Int
    var discussedIdeaIDs: [String] = []
}

/// Where understanding documents live, and what they are called.
///
/// Deliberately iCloud Drive rather than the app's local content root: these are
/// the one artifact the learner is invited to open in their own editor, so they
/// have to be visible in Finder and present on both Macs without the app
/// running. Everything else the app writes stays under Application Support.
enum UnderstandingDocumentPaths {
    static let directoryName = "Understanding"

    /// Filenames are derived from the portable source key, never from a model's
    /// output and never from the local row id — a CloudKit remap must not orphan
    /// a document. The title is carried only for human readability.
    static func fileName(title: String, portableSourceKey: String) -> String {
        let slug = slugify(title)
        let short = String(portableSourceKey.suffix(8))
        return slug.isEmpty ? "source-\(short).md" : "\(slug)-\(short).md"
    }

    static func relativePath(title: String, portableSourceKey: String) -> String {
        "\(directoryName)/\(fileName(title: title, portableSourceKey: portableSourceKey))"
    }

    /// A conservative, dependency-free slug. This is presentation only — identity
    /// is the hash suffix — so an aggressive transliteration is not needed and a
    /// title of pure punctuation degrades to the hash-only form.
    static func slugify(_ title: String, maxLength: Int = 48) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var out = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
            if out.count >= maxLength { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.lowercased()
    }

    /// iCloud names a conflicting edit `<base> 2.md`, and sometimes
    /// `<base> (Someone's conflicted copy 2026-08-18).md`. Both share the base
    /// stem, which is what makes them findable without parsing either form.
    static func isConflictSibling(fileName: String, of canonicalFileName: String) -> Bool {
        guard fileName != canonicalFileName else { return false }
        guard fileName.hasSuffix(".md"), canonicalFileName.hasSuffix(".md") else { return false }
        let stem = String(canonicalFileName.dropLast(3))
        let candidateStem = String(fileName.dropLast(3))
        guard candidateStem.hasPrefix(stem) else { return false }
        // Only a separator-led suffix counts, so `notes-ab12.md` never claims
        // `notes-ab12-extra.md` written deliberately by the learner.
        let remainder = candidateStem.dropFirst(stem.count)
        return remainder.first == " " || remainder.first == "("
    }
}

/// The header every document carries, so a learner opening the file in an editor
/// knows what it is and that editing it is expected.
enum UnderstandingDocumentTemplate {
    static let editNotice = """
        <!-- ForeverLM keeps this file up to date after each review. Editing it by
        hand is expected and encouraged: corrections you make here are read back
        in and shape later sessions. The record this is derived from lives in your
        review transcripts, so this file can always be rebuilt. -->
        """

    static func blank(title: String) -> String {
        """
        # \(title)

        \(editNotice)

        _No review yet._
        """
    }
}

// MARK: - Think first takes

/// What the learner wrote about a source before ForeverLM showed its summary
/// of it (docs/fences-and-think-first-design.md, "Think first"). A take lives
/// in the source's understanding document, the Markdown the learner already
/// opens and edits and every review already reads, under a dated heading of
/// its own:
///
///     ## Before the summary (2026-10-06)
///
///     *What do you expect this to say?*
///
///     <the take, in the learner's words>
///
/// The heading is what finds a take again, on this Mac or the other one, and
/// what keeps a rewrite of the document from dropping it.
struct ThinkFirstTake: Equatable, Sendable {
    /// The day it was written, as the heading says it (`yyyy-MM-dd`).
    var day: String
    /// What the learner was asked.
    var question: String?
    /// Their words, as written.
    var text: String
    /// The whole section, heading included, as it stands in the document.
    var section: String

    static let heading = "Before the summary"

    /// The section for a take written on `date`. The take goes in as written:
    /// it is the learner's own Markdown, in the learner's own file.
    static func section(question: String, take: String, on date: Date) -> String {
        """
        ## \(heading) (\(dayFormatter.string(from: date)))

        *\(question)*

        \(take.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// Every take in a document, in the order they appear: each runs from its
    /// heading to the next heading of the same or a higher level.
    static func takes(in markdown: String) -> [ThinkFirstTake] {
        let lines = markdown.components(separatedBy: "\n")
        var takes: [ThinkFirstTake] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let day = day(ofHeading: line) else {
                index += 1
                continue
            }
            var body: [String] = []
            var next = index + 1
            while next < lines.count, !isSectionBoundary(lines[next]) {
                body.append(lines[next])
                next += 1
            }
            var rest = body
            while let first = rest.first, first.trimmingCharacters(in: .whitespaces).isEmpty { rest.removeFirst() }
            var question: String?
            if let first = rest.first {
                let trimmed = first.trimmingCharacters(in: .whitespaces)
                if trimmed.count > 2, trimmed.hasPrefix("*"), trimmed.hasSuffix("*") {
                    question = String(trimmed.dropFirst().dropLast())
                    rest.removeFirst()
                }
            }
            let text = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let section = ([line] + body).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                takes.append(ThinkFirstTake(day: day, question: question, text: text, section: section))
            }
            index = next
        }
        return takes
    }

    /// The markdown a rewrite produced, with every take the document held
    /// before it that the rewrite left out put back at its end, word for word.
    /// A take counts as kept when its words still stand in the new text: a
    /// rewrite may move it, never drop it. A take the learner deleted by hand
    /// is gone from `previous` too, so nothing brings it back.
    static func keepingTakes(of previous: String?, in rewritten: String) -> String {
        guard let previous else { return rewritten }
        let missing = takes(in: previous).filter { !rewritten.contains($0.text) }
        guard !missing.isEmpty else { return rewritten }
        let body = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([body] + missing.map(\.section)).joined(separator: "\n\n") + "\n"
    }

    /// `## Before the summary (2026-10-06)` → `2026-10-06`; nil for any other line.
    private static func day(ofHeading line: String) -> String? {
        let prefix = "## \(heading) ("
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(")") else { return nil }
        return String(trimmed.dropFirst(prefix.count).dropLast())
    }

    private static func isSectionBoundary(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension UnderstandingDocument {
    /// The learner's takes on the source, oldest first.
    var thinkFirstTakes: [ThinkFirstTake] {
        ThinkFirstTake.takes(in: markdown)
    }
}
