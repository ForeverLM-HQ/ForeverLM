import Foundation

// MARK: - The audio overview both apps share

/// A notebook's audio overview (docs/explainer-design.md, "Audio overviews"):
/// one spoken script written over the notebook's ticked sources, narrated by
/// the learner's text-to-speech voice.
///
/// It is two records. The Artifact (`ArtifactKind.audioOverview`) is homed on
/// the notebook, names the sources it was written from, and carries the
/// recipe in its body. The script itself is a hidden, article-typed carrier
/// source at `foreverlm://audio-overview/<artifactID>` whose id is derived
/// from that URL, the way an explainer's is, so Listen, the price question,
/// the audio cache and its iCloud manifest, iPhone and CarPlay playback and
/// the MCP audio tools all work on it with no second code path. The carrier
/// is never a row of its own, and each record is deleted with the other.
///
/// Foundation-only, like `ExplainerScript`: the grammar, the formats, the
/// recipe and the writer's turn. What needs `StudioArticle` and
/// `SourceIdentity` — the carrier's id and record — is `GeneratedAudioOverview`
/// (AudioOverviewGeneratorService.swift). The iPhone derives the same carrier
/// id from the same URL with its own normalizer and hash
/// (`MobileCloudMutationService.audioOverviewSourceID`), and the portable
/// prefix it reads is `TextToSpeechPreparationPolicy.audioOverviewURLPrefix`.
enum AudioOverviewScript {
    static let scheme = "foreverlm"
    static let host = "audio-overview"
    /// `foreverlm://audio-overview/`. The same prefix
    /// `TextToSpeechPreparationPolicy.audioOverviewURLPrefix` names, kept in step
    /// by `AudioOverviewTests`; the policy is portable and cannot import this.
    static let urlPrefix = "\(scheme)://\(host)/"
    /// Shown where a web source would show its host, as for an explainer.
    static let domain = "ForeverLM"
    /// What a row, the Reader's masthead and Now Playing call one.
    static let kindLabel = "Audio overview"

    /// The carrier's URL, from the id of the Artifact it belongs to.
    static func url(artifactID: String) -> String {
        urlPrefix + artifactID
    }

    /// Whether a source URL names an audio overview's carrier.
    static func isCarrierURL(_ urlString: String) -> Bool {
        artifactID(fromCarrierURL: urlString) != nil
    }

    /// The id of the Artifact a carrier URL belongs to, or nil for any other URL.
    static func artifactID(fromCarrierURL urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(urlPrefix) else { return nil }
        let id = String(trimmed.dropFirst(urlPrefix.count))
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }

    /// The narration pace the lengths assume, the explainer's.
    static let spokenWordsPerMinute = 150

    /// "about 12 minutes", never a decimal.
    static func listeningTimeLabel(wordCount: Int) -> String {
        let minutes = Int((Double(max(0, wordCount)) / Double(spokenWordsPerMinute)).rounded())
        switch minutes {
        case 0: return "under a minute"
        case 1: return "about a minute"
        default: return "about \(minutes) minutes"
        }
    }

    // MARK: Body

    /// A body that starts with this line is an audio overview's, whatever its
    /// record's kind says: an older build that does not know the kind saves
    /// the record back with none, and the body still says what it is. Opening
    /// one never writes the kind back.
    static let markerPrefix = "<!-- foreverlm:audio-overview "
    static let markerSuffix = " -->"

    /// Whether a body is an audio overview's: its first non-empty line is the marker.
    static func isOverviewMarkdown(_ markdown: String) -> Bool {
        firstLine(of: markdown)?.hasPrefix(markerPrefix) == true
    }

    /// Whether a record is an audio overview: its kind says so, or — for a
    /// record an older build saved back without the kind — its body does.
    /// Reading it never writes the kind back.
    static func isOverview(_ artifact: ArtifactRecord, markdown: String?) -> Bool {
        if artifact.kind == .audioOverview { return true }
        guard artifact.kind == nil, !artifact.isLinked, let markdown else { return false }
        return isOverviewMarkdown(markdown)
    }

    /// The recipe a body carries, or nil for a body that is not an overview's
    /// or whose recipe this build cannot read.
    static func settings(fromMarkdown markdown: String) -> AudioOverviewSettings? {
        guard let line = firstLine(of: markdown),
              line.hasPrefix(markerPrefix), line.hasSuffix(markerSuffix) else { return nil }
        let json = line.dropFirst(markerPrefix.count).dropLast(markerSuffix.count)
        return try? decoder.decode(AudioOverviewSettings.self, from: Data(json.utf8))
    }

    /// The Artifact's body: the recipe as one marker line, then one line a
    /// person reads (`read_doc`, an older build's Docs list).
    static func markdown(settings: AudioOverviewSettings) throws -> String {
        let json = String(decoding: try encoder.encode(settings), as: UTF8.self)
        return markerPrefix + json + markerSuffix + "\n\n" + settings.summaryLine + "\n"
    }

    private static func firstLine(of markdown: String) -> String? {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Format and length

/// What kind of overview to write. One narrator in this first pass: Gemini's
/// Deep dive, Brief and Critique, as one voice can speak them. Debate needs
/// two hosts and comes with them.
enum AudioOverviewFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case deepDive = "deep_dive"
    case brief
    case critique

    var id: String { rawValue }

    static let `default` = AudioOverviewFormat.deepDive

    var label: String {
        switch self {
        case .deepDive: return "Deep dive"
        case .brief: return "Brief"
        case .critique: return "Critique"
        }
    }

    /// A brief is one length by definition; the others take one.
    var takesLength: Bool { self != .brief }

    /// Words the script runs to. A brief ignores the length.
    func wordRange(_ length: AudioOverviewLength) -> ClosedRange<Int> {
        switch (self, length) {
        case (.brief, _): return 280...340
        case (.deepDive, .shorter): return 900...1_200
        case (.deepDive, .standard): return 1_600...2_000
        case (.deepDive, .longer): return 2_600...3_100
        case (.critique, .shorter): return 700...900
        case (.critique, .standard): return 1_100...1_400
        case (.critique, .longer): return 1_800...2_200
        }
    }

    /// Whole minutes at the narration pace, from the middle of the range.
    func minutes(_ length: AudioOverviewLength) -> Int {
        let range = wordRange(length)
        let midpoint = Double(range.lowerBound + range.upperBound) / 2
        return max(1, Int((midpoint / Double(AudioOverviewScript.spokenWordsPerMinute)).rounded()))
    }

    /// What the writer is asked to make, in the turn.
    var writerBrief: String {
        switch self {
        case .deepDive:
            return "Deep dive: a thorough spoken tour of what these sources say together — the notebook's through-line, each source's main claims and how it reached them, where the sources agree, where they conflict, and what stays open."
        case .brief:
            return "Brief: the core ideas of these sources in about two minutes — what they add up to and the few points a listener must leave with. No tour of each source."
        case .critique:
            return "Critique: a constructive expert review of these sources — their strengths, their weaknesses, how sound their methods are, what they leave out, and what would settle the open questions. Fair to the authors, specific in its criticism."
        }
    }
}

/// How long the overview runs. Raw values are the MCP words.
enum AudioOverviewLength: String, CaseIterable, Codable, Sendable, Identifiable {
    case shorter
    case standard = "default"
    case longer

    var id: String { rawValue }

    static let `default` = AudioOverviewLength.standard

    var label: String {
        switch self {
        case .shorter: return "Shorter"
        case .standard: return "Default"
        case .longer: return "Longer"
        }
    }
}

/// What the learner asked for: a format, a length (not for a brief) and an
/// optional focus line, which leads the writer's turn.
struct AudioOverviewOptions: Equatable, Sendable {
    var format: AudioOverviewFormat = .default
    var length: AudioOverviewLength = .default
    var focus: String = ""

    init(format: AudioOverviewFormat = .default, length: AudioOverviewLength = .default, focus: String = "") {
        self.format = format
        self.length = length
        self.focus = focus
    }

    /// The length the script is written to; nil for a brief, which has one.
    var effectiveLength: AudioOverviewLength? { format.takesLength ? length : nil }

    var wordRange: ClosedRange<Int> { format.wordRange(length) }
    var minutes: Int { format.minutes(length) }

    /// The focus as the writer reads it; nil when there is none.
    var trimmedFocus: String? {
        let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - The recipe

/// How the writer read one source. A source the model's window cannot take
/// whole is read from the ideas stored for it, or from a condensed account
/// of its whole text — and the prompt, the price sheet and the result say so.
/// Nothing is ever cut. Every notebook writer reads the same way
/// (`NotebookSourceReadAs`, NotebookSourceReading.swift), and the recipe
/// keeps the same words.
typealias AudioOverviewReadAs = NotebookSourceReadAs

struct AudioOverviewSourceReading: Codable, Equatable, Sendable {
    var sourceID: String
    var title: String
    var readAs: AudioOverviewReadAs
}

/// The recipe an overview was made from, kept in its Artifact's body: shown
/// as the outputs row's recipe, returned by `read_doc`, and enough to make
/// the same overview again.
struct AudioOverviewSettings: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var format: AudioOverviewFormat
    /// Nil for a brief.
    var length: AudioOverviewLength?
    var focus: String?
    /// One narrator in the first pass; two hosts come next.
    var hosts: Int = 1
    /// The carrier source the script and its audio live on.
    var audioSourceID: String
    var sources: [AudioOverviewSourceReading]
    /// The model the script was written with, as routed.
    var model: String?
    var madeAt: Date

    var options: AudioOverviewOptions {
        AudioOverviewOptions(format: format, length: length ?? .default, focus: focus ?? "")
    }

    /// "Deep dive · 12 sources · about 12 min": the outputs row's second line.
    var headline: String {
        let count = sources.count == 1 ? "1 source" : "\(sources.count) sources"
        let minutes = format.minutes(length ?? .default)
        return "\(format.label) · \(count) · about \(minutes) min"
    }

    /// The sources read some other way than whole, so a row and an answer
    /// can say so without counting again.
    var notReadWhole: [AudioOverviewSourceReading] {
        sources.filter { $0.readAs != .whole }
    }

    /// "Made from 12 sources · why complex I matters", with what was not read
    /// whole named: the recipe on an outputs row's menu.
    var recipe: String {
        var parts = ["Made from \(sources.count == 1 ? "1 source" : "\(sources.count) sources")"]
        if let focus, !focus.isEmpty { parts.append(focus) }
        let ideas = sources.filter { $0.readAs == .ideas }.count
        let condensed = sources.filter { $0.readAs == .condensed }.count
        if ideas > 0 { parts.append("\(ideas) read from their ideas") }
        if condensed > 0 { parts.append("\(condensed) condensed") }
        return parts.joined(separator: " · ")
    }

    /// The body's line for a person.
    var summaryLine: String {
        var line = "\(format.label) audio overview of \(sources.count == 1 ? "1 source" : "\(sources.count) sources"), about \(format.minutes(length ?? .default)) minutes."
        let ideas = sources.filter { $0.readAs == .ideas }.map(\.title)
        let condensed = sources.filter { $0.readAs == .condensed }.map(\.title)
        if !ideas.isEmpty { line += " Read from their stored ideas: \(ideas.joined(separator: "; "))." }
        if !condensed.isEmpty { line += " Read condensed: \(condensed.joined(separator: "; "))." }
        if let focus, !focus.isEmpty { line += " Focus: \(focus)" }
        return line
    }
}

// MARK: - The writer's turn

/// One source as the writer is handed it.
struct AudioOverviewTurnSource: Equatable, Sendable {
    var title: String
    /// What the source is, in words: "paper", "book chapter", "podcast transcript".
    var kind: String
    var author: String?
    var venue: String?
    var year: String?
    var readAs: AudioOverviewReadAs
    var text: String
}

enum AudioOverviewWriterTurn {
    /// The note every turn carries about how its sources were read.
    static let readingNote = "Each source below is read whole unless its header says otherwise. \"Read: from its ideas\" means only the ideas stored for it were given, each a statement and what a good recall of it holds; \"Read: condensed\" means a condensed account of its whole text, written for this overview, was given. Speak about those sources only as far as what was given."

    /// The writer's turn: the focus first when there is one, then the
    /// notebook, the format and its length, how the sources were read, and
    /// each source with its header and text.
    static func userMessage(
        notebookTitle: String,
        instructions: String?,
        options: AudioOverviewOptions,
        sources: [AudioOverviewTurnSource]
    ) -> String {
        var lines: [String] = []
        if let focus = options.trimmedFocus {
            lines.append("Focus: \(focus)")
        }
        lines.append("Notebook: \(notebookTitle)")
        if let instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            lines.append("Notebook instructions: \(instructions)")
        }
        lines.append("Format: \(options.format.writerBrief)")
        let range = options.wordRange
        lines.append("Target length: \(range.lowerBound) to \(range.upperBound) words, about \(options.minutes) minutes spoken.")
        lines.append("")
        lines.append(sources.count == 1 ? "Sources (1)." : "Sources (\(sources.count)).")
        lines.append(readingNote)
        for (index, source) in sources.enumerated() {
            lines.append("")
            lines.append("=== Source \(index + 1) of \(sources.count) ===")
            lines.append(contentsOf: header(for: source))
            lines.append(source.text)
        }
        return lines.joined(separator: "\n")
    }

    /// A source's header lines, without its text.
    static func header(for source: AudioOverviewTurnSource) -> [String] {
        var lines = ["Title: \(source.title)", "Kind: \(source.kind)"]
        if let author = source.author, !author.isEmpty { lines.append("Authors: \(author)") }
        var venue: [String] = []
        if let journal = source.venue, !journal.isEmpty { venue.append(journal) }
        if let year = source.year, !year.isEmpty { venue.append(year) }
        if !venue.isEmpty { lines.append("Published: \(venue.joined(separator: ", "))") }
        lines.append("Read: \(source.readAs.label)")
        switch source.readAs {
        case .whole: lines.append("Full text:")
        case .ideas: lines.append("Its ideas:")
        case .condensed: lines.append("Condensed account:")
        }
        return lines
    }
}

/// What the writer returns: a short spoken title and the script itself.
struct AudioOverviewDraft: Codable, Equatable, Sendable {
    var title: String
    var script: String

    var isUsable: Bool {
        !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
