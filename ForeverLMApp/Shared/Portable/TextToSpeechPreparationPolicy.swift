/// Which sources get the AI text-to-speech preparation pass before narration, and
/// which are read as they stand.
///
/// Every paper, article, book and course goes through it, whatever its text
/// looks like: the pass turns tables and figures into a sentence, states what
/// an equation means instead of reciting it, and strips citation markers and
/// the reference list. A book chapter of plain prose carries citations too, so
/// the text is never inspected to decide whether the model is asked.
///
/// Portable and Foundation-free on purpose: this file is compiled into the
/// website's WebAssembly module as well as both apps, and a Foundation string
/// API here once pulled ICU into that module and past Cloudflare's size limit.
public enum TextToSpeechPreparationPolicy {
    /// Source types always prepared, whatever their text looks like.
    public static let alwaysPreparedSourceTypes: Set<String> = ["paper", "article", "book", "course"]

    /// Text written to be spoken — an explainer's script (explainer-design.md)
    /// — carries this URL prefix. It is saved as an article so the listen path
    /// reads its own text, but it was written for the ear already, so the pass
    /// is never run on it whatever its source type says. The same prefix is
    /// `GeneratedExplainer.urlPrefix`; this file is portable and cannot import it.
    public static let spokenScriptURLPrefix = "foreverlm://explainer/"

    /// A notebook's audio overview keeps its script on a carrier source under
    /// this prefix (`AudioOverviewScript.urlPrefix`, kept in step by
    /// `AudioOverviewTests`). Written for the ear like an explainer, and like
    /// one never a row of its own.
    public static let audioOverviewURLPrefix = "foreverlm://audio-overview/"

    /// Every kind of spoken script: the one predicate the lists, the
    /// preparation pass, automatic audio and the generators ask, on both apps.
    public static let spokenScriptURLPrefixes = [spokenScriptURLPrefix, audioOverviewURLPrefix]

    public static func isSpokenScript(url: String) -> Bool {
        spokenScriptURLPrefixes.contains { url.hasPrefix($0) }
    }

    /// Whether a source URL is an audio overview's carrier.
    public static func isAudioOverviewScript(url: String) -> Bool {
        url.hasPrefix(audioOverviewURLPrefix)
    }

    /// `usesAIPreparation(sourceType:)` with the source's URL, so a spoken
    /// script is read as it stands.
    public static func usesAIPreparation(sourceType: String, url: String) -> Bool {
        if isSpokenScript(url: url) { return false }
        return usesAIPreparation(sourceType: sourceType)
    }

    /// Whether narration for this source should run through the AI pass.
    /// `sourceType` is the raw `StudioSourceType` value.
    public static func usesAIPreparation(sourceType: String) -> Bool {
        alwaysPreparedSourceTypes.contains(sourceType)
    }
}
