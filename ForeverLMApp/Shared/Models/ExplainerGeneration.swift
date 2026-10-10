import Foundation

// MARK: - Generated explainer sources

/// The URL grammar and titles of the source an explainer is saved as.
///
/// An explainer is new text written *about* one paper or article, for the ear,
/// and it is stored as an ordinary text-only source so listening, the audio
/// cache, the iCloud manifest, iPhone playback, search and sync all work with
/// no second code path (explainer-design.md). Its URL is
/// `foreverlm://explainer/<sourceID>`: the id of the source it explains rides in
/// the URL, and `SourceIdentity.stableID` derives the explainer's own id from
/// it, so one source has at most one explainer and a rewrite is an update
/// rather than a second row. The link back to the source is the URL — no
/// relation table, no schema bump.
///
/// The grammar itself, the lengths and the writer's turn live in
/// `ExplainerScript` (ExplainerScript.swift), which the phone compiles too;
/// this type adds what needs `StudioArticle` and `SourceIdentity`.
enum GeneratedExplainer {
    static let scheme = ExplainerScript.scheme
    static let host = ExplainerScript.host
    /// The same prefix `TextToSpeechPreparationPolicy.spokenScriptURLPrefix` names,
    /// kept in step by `ExplainerGenerationTests`; the policy is portable and
    /// cannot import this file.
    static let urlPrefix = ExplainerScript.urlPrefix
    /// Shown where a web source would show its host. The same word course
    /// lessons use, so generated text reads as ForeverLM's in every list.
    static let domain = ExplainerScript.domain

    /// What an explainer can be written about: the two source types whose
    /// text is a written argument. Books and course chapters come later.
    static let explainableSourceTypes: Set<StudioSourceType> = [.paper, .article]

    static func url(explaining sourceID: String) -> String {
        ExplainerScript.url(explaining: sourceID)
    }

    /// The explainer's own source id, from the id of the source it explains.
    static func sourceID(explaining sourceID: String) -> String {
        SourceIdentity.stableID(for: url(explaining: sourceID))
    }

    /// Whether a source URL names an explainer.
    static func isExplainerURL(_ urlString: String) -> Bool {
        ExplainerScript.isExplainerURL(urlString)
    }

    /// Whether a source URL names a spoken script: an explainer or an audio
    /// overview's carrier (`ExplainerScript.isSpokenScriptURL`).
    static func isSpokenScriptURL(_ urlString: String) -> Bool {
        ExplainerScript.isSpokenScriptURL(urlString)
    }

    /// The id of the source an explainer URL explains, or nil for any other URL.
    static func explainedSourceID(from urlString: String) -> String? {
        ExplainerScript.explainedSourceID(from: urlString)
    }

    static func title(for sourceTitle: String) -> String {
        ExplainerScript.title(for: sourceTitle)
    }

    /// Whether the Explain affordances show for a source. Called from view
    /// bodies, so it stays a cheap check on the value: the right type, not an
    /// explainer itself, and text to read — a paper's text arrives with its
    /// ingestion, so a paper still waiting on its PDF cannot be explained yet.
    static func canExplain(_ article: StudioArticle) -> Bool {
        guard explainableSourceTypes.contains(article.sourceType),
              !isSpokenScriptURL(article.url) else { return false }
        if article.sourceType == .paper, !article.isPaperReadyForListenPreparation {
            return false
        }
        return true
    }

    // MARK: Reading

    /// The narration pace the lengths above assume: roughly what a narration
    /// voice speaks, so the Reader's masthead and `ExplainerLength` agree.
    static let spokenWordsPerMinute = 150

    /// The title the Reader sets above the script: the explained source's
    /// title, with the list-only "Explainer:" prefix removed. A title that was
    /// renamed away from the grammar is shown as it stands.
    static func displayTitle(for sourceTitle: String) -> String {
        let trimmed = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Explainer:"
        guard trimmed.hasPrefix(prefix) else { return trimmed }
        let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? trimmed : rest
    }

    /// How long the script takes to hear, in whole minutes a listener can use:
    /// "about 7 minutes", never a decimal.
    static func listeningTimeLabel(wordCount: Int) -> String {
        guard wordCount > 0 else { return "under a minute" }
        let minutes = Int((Double(wordCount) / Double(spokenWordsPerMinute)).rounded())
        switch minutes {
        case 0: return "under a minute"
        case 1: return "about a minute"
        default: return "about \(minutes) minutes"
        }
    }

    /// The masthead's second line: the script's length as words and as time.
    static func lengthLabel(wordCount: Int) -> String {
        let words = NumberFormatter.localizedString(from: NSNumber(value: wordCount), number: .decimal)
        return "\(words) words · \(listeningTimeLabel(wordCount: wordCount)) to listen"
    }
}

// MARK: - Request and result

// `ExplainerLength` and `ExplainerDraft` are in ExplainerScript.swift, which
// both apps compile.

struct ExplainerRequest: Equatable, Sendable {
    /// The paper or article to explain.
    var sourceID: String
    var length: ExplainerLength = .default
}

struct ExplainerGenerationResult: Sendable {
    let explainer: StudioArticle
    /// True when the source already had an explainer and this run replaced it.
    let replacedExisting: Bool
}

enum ExplainerGenerationError: LocalizedError, Equatable {
    case sourceNotFound(String)
    case unsupportedSource(String)
    case noText(String)
    case noModelConfigured
    case emptyScript

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let id):
            return "No source with id \(id) is in the library."
        case .unsupportedSource(let title):
            return "An explainer can be written about a paper or an article, not about \"\(title)\"."
        case .noText(let title):
            return "\"\(title)\" has no text to explain yet."
        case .noModelConfigured:
            return "No model is configured for Explainer Writing. Sign in and check Settings › AI Usage."
        case .emptyScript:
            return "The writer returned no script."
        }
    }
}

/// The model side of the pipeline, behind a protocol so the storage side can
/// be pinned in tests with a canned draft.
protocol ExplainerModelBackend: Sendable {
    /// `truncated` says the text was cut to the character budget, so the writer
    /// can be told the end is missing rather than guess at it. `figureLines`
    /// are the paper's figures as the writer reads them — one line each with
    /// label, page, caption, panels, printed words and what an earlier look
    /// saw (`ExplainerGeneratorService.figureLines`) — empty for an article or
    /// a paper whose PDF could not be read.
    func write(
        request: ExplainerRequest,
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figureLines: [String]
    ) async throws -> ExplainerDraft
}
