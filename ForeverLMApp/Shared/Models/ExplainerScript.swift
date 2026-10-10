import Foundation

// MARK: - The explainer both apps share

/// What the Mac and the phone agree on about an explainer: the URL grammar that
/// links a script to the source it explains, the title and domain it is listed
/// under, the lengths, the text budget and the writer's turn.
///
/// Foundation-only, so the iPhone target compiles it; the Mac's
/// `GeneratedExplainer` builds on it and adds the parts that need
/// `StudioArticle` and `SourceIdentity`. The two clients derive the explainer's
/// id from the same URL with the same normalizer and hash, which is what lets
/// one written on the phone be the one the Mac's Explain button opens
/// (explainer-design.md).
enum ExplainerScript {
    static let scheme = "foreverlm"
    static let host = "explainer"
    /// `foreverlm://explainer/`. The same prefix
    /// `TextToSpeechPreparationPolicy.spokenScriptURLPrefix` names, kept in step by
    /// `ExplainerGenerationTests`; the policy is portable and cannot import this.
    static let urlPrefix = "\(scheme)://\(host)/"
    /// Shown where a web source would show its host. The same word course
    /// lessons use, so generated text reads as ForeverLM's in every list.
    static let domain = "ForeverLM"

    /// The raw `source_type` values an explainer can be written about: the two
    /// whose text is a written argument. Books and course chapters come later.
    static let explainableSourceTypeRawValues: Set<String> = ["paper", "article"]

    /// Characters of source text one writing call may carry. A long paper is
    /// cut, not refused, and the writer is told where the text ends.
    static let sourceCharacterBudget = 60_000

    static func url(explaining sourceID: String) -> String {
        urlPrefix + sourceID
    }

    /// Whether a source URL names an explainer.
    static func isExplainerURL(_ urlString: String) -> Bool {
        explainedSourceID(from: urlString) != nil
    }

    /// Whether a source URL names a spoken script ForeverLM wrote: an
    /// explainer, or the carrier of a notebook's audio overview. Neither is
    /// ever a row of its own, explained, walked through, filmed or prepared
    /// for reading aloud, on either app; every such guard asks this.
    static func isSpokenScriptURL(_ urlString: String) -> Bool {
        TextToSpeechPreparationPolicy.isSpokenScript(url: urlString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The id of the source an explainer URL explains, or nil for any other URL.
    static func explainedSourceID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(urlPrefix) else { return nil }
        let id = String(trimmed.dropFirst(urlPrefix.count))
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }

    static func title(for sourceTitle: String) -> String {
        "Explainer: \(sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Whether a source of this type and URL is one an explainer is written
    /// about: the right type, and not an explainer itself. Whether its text
    /// has arrived is the caller's check — the two apps learn that differently.
    static func isExplainable(sourceType: String, url: String?) -> Bool {
        explainableSourceTypeRawValues.contains(sourceType)
            && !isSpokenScriptURL(url ?? "")
    }

    /// The text the writer sees: whole when it fits, else the opening budget
    /// with a flag so the prompt can say the end is missing.
    static func budgeted(_ text: String) -> (text: String, truncated: Bool) {
        guard text.count > sourceCharacterBudget else { return (text, false) }
        return (String(text.prefix(sourceCharacterBudget)), true)
    }

    /// The word count stored on the explainer's row, so both apps count the
    /// same script the same way.
    static func wordCount(of script: String) -> Int {
        script.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// The writer's turn: what the source is, how long to speak, the figures
    /// it prints when the Mac has read them, and its text. Byte-identical on
    /// both apps so one prompt cache serves them: the phone, which reads no
    /// PDF, passes no figure lines and its turn is exactly the Mac's for a
    /// paper whose figures could not be read.
    ///
    /// `figureLines` are the walkthrough writer's figure lines
    /// (`PaperWalkthroughGeneratorService.figureLines`): one per figure with
    /// its label, page, caption, panels, the words printed inside it and what
    /// an earlier look at it saw, so the script can go through the figures
    /// rather than paraphrase their captions (product owner, 2026-09-20: the
    /// explainer "doesn't go through the figures").
    static func writerUserMessage(
        title: String,
        sourceType: String,
        author: String?,
        journal: String?,
        publishedYear: String?,
        text: String,
        truncated: Bool,
        length: ExplainerLength,
        figureLines: [String] = []
    ) -> String {
        var lines: [String] = []
        lines.append("Source: \(title)")
        lines.append("Kind: \(sourceType == "paper" ? "paper" : "article")")
        if let author, !author.isEmpty {
            lines.append("Authors: \(author)")
        }
        var venue: [String] = []
        if let journal, !journal.isEmpty { venue.append(journal) }
        if let publishedYear, !publishedYear.isEmpty { venue.append(publishedYear) }
        if !venue.isEmpty {
            lines.append("Published: \(venue.joined(separator: ", "))")
        }
        let range = length.wordRange
        lines.append("Target length: \(range.lowerBound) to \(range.upperBound) words, \(length.listeningTimeLabel) spoken.")
        lines.append("")
        if !figureLines.isEmpty {
            lines.append("Figures printed in the paper (label · page · caption · panels · the words printed inside the figure in reading order — its axis titles with their units, legend keys, condition labels · what an earlier look at the figure saw). The script goes through them:")
            lines.append(contentsOf: figureLines)
            lines.append("")
        }
        if truncated {
            lines.append("Text (the first \(text.count) characters; the rest was cut, so say nothing about what may follow):")
        } else {
            lines.append("Full text:")
        }
        lines.append(text)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Length and draft

/// How long the spoken explainer should run. Word counts, because that is what
/// the writer can hold to; the listening times assume the roughly 150 words a
/// minute a narration voice speaks.
enum ExplainerLength: String, CaseIterable, Codable, Sendable {
    case brief
    case standard
    case extended

    var wordRange: ClosedRange<Int> {
        switch self {
        case .brief: return 450...650
        case .standard: return 900...1_200
        case .extended: return 1_500...1_900
        }
    }

    var listeningTimeLabel: String {
        switch self {
        case .brief: return "about four minutes"
        case .standard: return "about seven minutes"
        case .extended: return "about twelve minutes"
        }
    }

    var label: String {
        switch self {
        case .brief: return "Brief"
        case .standard: return "Standard"
        case .extended: return "Extended"
        }
    }

    static let `default` = ExplainerLength.standard
}

/// What the writer returns: a short spoken title and the script itself.
struct ExplainerDraft: Codable, Equatable, Sendable {
    var title: String
    var script: String

    var isUsable: Bool {
        !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
