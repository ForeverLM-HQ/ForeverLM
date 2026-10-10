import Foundation

struct MobileVoiceAgentSource: Codable, Equatable {
    let id: String
    let position: Int
    let title: String
    let subtitle: String?
}

struct MobileVoiceAgentState: Codable, Equatable {
    let isPlaying: Bool
    let isSourceReviewActive: Bool
    let currentSourceID: String?
    let currentSourceTitle: String?
    let activeReviewTitle: String?
    let playbackSpeed: Float
    let availableSources: [MobileVoiceAgentSource]
}

struct MobileVoiceAgentDecision: Codable, Equatable {
    let tool: String
    let sourceID: String?
    let seconds: Double?
    let speed: Float?
    let resumeAudio: Bool?
    let message: String?
    let spokenResponse: String?
}

actor MobileVoiceAgentService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        self.session = URLSession(configuration: config)
    }

    func decide(utterance: String, state: MobileVoiceAgentState) async throws -> MobileVoiceAgentDecision {
        guard ManagedAI.isSignedIn else {
            throw MobileVoiceAgentError.missingOpenAIKey
        }
        let stateData = try JSONEncoder().encode(state)
        let stateJSON = String(data: stateData, encoding: .utf8) ?? "{}"

        let system = """
        You are the voice agent inside ForeverLM's iPhone app.
        The user is driving and speaks naturally. Decide what they want and choose exactly one app tool.
        Return only JSON. Do not wrap it in Markdown.

        Available tools:
        - play_source: play a source. Use sourceID when a source is mentioned, otherwise current source or best default.
        - pause_audio: pause playback.
        - resume_audio: resume playback or start the best source if nothing is active.
        - stop_audio: stop or pause playback.
        - pause_for_source_chat: pause playback and prepare the current source so the user can ask questions about it.
        - skip_relative: seek relative to current playback. Use seconds; negative rewinds.
        - set_speed: change playback speed. Use speed between \(MobileAudioPlaybackSpeed.agentRange.lowerBound) and \(MobileAudioPlaybackSpeed.agentRange.upperBound).
        - list_sources: describe available sources from the entire library, not just currently downloaded audio.
        - refresh_library: rescan synced audio.
        - identify_current_source: say what source is active.
        - start_source_review: start voice chat/review for a source so the USER can ask questions about it.
        - start_review_quiz: start a hands-free review where the APP quizzes the user and grades how well they explain a source. Use sourceID when a source is mentioned; put the spoken source/topic description in message.
        - answer_source_question: answer the user's question about the active/current source. Put the user's question in message.
        - end_source_review: leave source review. Use resumeAudio true when the user wants to return to listening.
        - no_op: use only when the utterance is not meant for the app.

        Decision rules:
        - Do not require exact phrases or wake words. Interpret the user's natural intent.
        - When audio is playing and the user wants to stop or pause so they can talk about the text, choose pause_for_source_chat.
        - When audio is playing and the user says a short stop/pause-style utterance without any other context, choose pause_for_source_chat.
        - Choose stop_audio only when the user clearly wants to stop playback without entering a source conversation.
        - When audio is playing and the user asks a substantive question about the text, choose answer_source_question; the app will pause and load the current source context.
        - When the user wants to BE TESTED — "quiz me", "test me", "ask me questions", "review me on", "check my understanding of" a source — choose start_review_quiz.
        - When the user wants the app to explain or answer ("tell me about", "explain", "summarize", "what does X say about") choose start_source_review or answer_source_question.
        - If review is already active, most substantive utterances are answer_source_question unless the user wants to leave review or control audio.
        - Match sources by title, subtitle, or ordinal if the utterance implies one.
        - Use natural spokenResponse only for confirmations or short answers that do not need another service.
        - For listing and discovery:
            - "list sources", "what sources do we have", "what sources do we have for X", and "last N sources/articles" => tool list_sources.
            - If the user asks "list all the sources", include spokenResponse only if the list is empty.
        - For playback by name:
            - "read me X", "play X", and variants where X sounds like a source title => tool play_source.
            - If a title is not explicitly provided, leave sourceID null and rely on app-side matching.

        JSON shape:
        {"tool":"start_source_review","sourceID":"...","seconds":null,"speed":null,"resumeAudio":null,"message":null,"spokenResponse":null}
        """

        let user = """
        Current app state:
        \(stateJSON)

        User utterance:
        \(utterance)
        """

        let route = try await MobileModelPreferenceStore.shared.resolve(.mobileVoiceAgent)
        let request = try MobileOpenRouterChat.request(
            route: route,
            system: system,
            messages: [(role: "user", content: user)],
            maxTokens: 500,
            jsonMode: true
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobileVoiceAgentError.badResponse("OpenRouter did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body."
            throw MobileVoiceAgentError.badResponse("OpenRouter voice agent failed (\(http.statusCode)): \(body)")
        }
        let parsed = try MobileOpenRouterChat.text(from: data)
        guard let contentData = parsed.text.data(using: .utf8) else {
            throw MobileVoiceAgentError.badResponse("OpenAI voice agent response did not include JSON.")
        }
        try MobileOpenRouterChat.requireSelectedModel(parsed.json, route: route)

        return try JSONDecoder().decode(MobileVoiceAgentDecision.self, from: contentData)
    }
}

enum MobileVoiceAgentError: LocalizedError {
    case missingOpenAIKey
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingOpenAIKey:
            return "Sign in with Apple to use the voice agent."
        case .badResponse(let message):
            return message
        }
    }
}
