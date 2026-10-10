import Foundation

/// Speech-only preparation contract for canonical paper and article content.
/// Visual text remains in the stored source so chat, search, and review can
/// reason about it; adaptation happens only in the derivative sent to speech.
enum PaperNarrationFilter {
    /// Written into paper audio manifests so cached audio made before a narration
    /// rule change is not replayed with stale content. The historical prefix is
    /// also the stable cross-device contract for prepared article derivatives.
    static let version = 5
    static let preparationContractPrefix = "paper-narration-v5:"

    /// Preserves its input. Speech adaptation is produced by the configurable
    /// Text-to-Speech Preparation task rather than inferred from prefixes.
    static func removingFigureCaptions(from text: String) -> String {
        text
    }
}
