import Foundation

/// Every OpenRouter API address the app calls, spelled once.
enum OpenRouterAPI {
    /// The versioned API root.
    static let base = URL(string: "https://openrouter.ai/api/v1")!
    /// The website's own frontend API root (public catalog and stats).
    static let frontendBase = URL(string: "https://openrouter.ai/api/frontend/v1")!

    private static func v1(_ path: String) -> URL { URL(string: base.absoluteString + path)! }
    private static func frontend(_ path: String) -> URL { URL(string: frontendBase.absoluteString + path)! }

    /// Chat completions.
    static let chatCompletions = v1("/chat/completions")
    /// Text to speech.
    static let audioSpeech = v1("/audio/speech")
    /// Speech to text.
    static let audioTranscriptions = v1("/audio/transcriptions")
    /// Image generation.
    static let images = v1("/images")
    /// Video generation.
    static let videos = v1("/videos")
    /// The calling key's limits and usage.
    static let key = v1("/key")
    /// Where a PKCE sign-in trades its code for a key.
    static let authKeys = v1("/auth/keys")
    /// The provider list.
    static let providers = v1("/providers")
    /// One generation's cost record (add an `id` query item).
    static let generation = v1("/generation")

    /// The model directory, unfiltered.
    static let models = v1("/models")
    /// The model directory sorted by weekly tokens.
    static let modelsMostPopular = v1("/models?sort=most-popular")
    /// The model directory filtered to one output modality (`image`, `speech`, ...).
    static func models(outputModality: String) -> URL {
        v1("/models?output_modalities=\(outputModality)")
    }
    /// The image-model directory.
    static let imageModels = v1("/images/models")
    /// The video-model directory.
    static let videoModels = v1("/videos/models")
    /// One chat model's endpoints; `path` is already percent-encoded.
    static func endpoints(forModel path: String) -> URL? {
        URL(string: base.absoluteString + "/models/\(path)/endpoints")
    }
    /// One image model's endpoints.
    static func imageModelEndpoints(id: String) -> URL? {
        URL(string: base.absoluteString + "/images/models/\(id)/endpoints")
    }

    /// The frontend catalog of models (promotion flags).
    static let frontendCatalogModels = frontend("/catalog/models")
    /// The frontend per-endpoint speed stats (add query items).
    static let frontendEndpointStats = frontend("/stats/endpoint")
}
