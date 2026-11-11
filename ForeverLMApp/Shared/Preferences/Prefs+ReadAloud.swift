import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// Narration and voice: voices, speed, what is narrated without asking.
    enum ReadAloud {
        /// Text-to-speech tuning. Voices and instructions are hand-written; losing them
        /// is the single most annoying thing on this list.
        static let speed = AccountKey<Double?>("macos.tts.speed")
        static let confirmCostBeforeListening = AccountKey<Bool?>("macos.tts.confirmCostBeforeListening")
        static let costConfirmationSuppressedModels = AccountKey<[String]?>("readAloud.costConfirmation.suppressedModels.v1", .phoneWritable)
        static let appleVoiceIdentifier = AccountKey<String?>("macos.tts.apple.voiceIdentifier")
        static let openAIVoice = AccountKey<String?>("macos.tts.openai.voice")
        static let groqVoice = AccountKey<String?>("macos.tts.groq.voice")
        static let elevenLabsVoice = AccountKey<String?>("macos.tts.elevenlabs.voice")
        static let xaiVoice = AccountKey<String?>("macos.tts.xai.voice")
        static let geminiVoice = AccountKey<String?>("macos.tts.gemini.voice")
        static let togetherVoice = AccountKey<String?>("macos.tts.together.voice")
        static let openRouterVoice = AccountKey<String?>("macos.tts.openrouter.voice", .phoneWritable)
        static let localQwen3Voice = AccountKey<String?>("macos.tts.local_qwen3.voice")
        static let openAIInstructions = AccountKey<String?>("macos.tts.openai.instructions")
        static let localQwen3Instructions = AccountKey<String?>("macos.tts.local_qwen3.instructions")
        /// Voice mode's voice: one pick for the Mac, the iPhone and CarPlay.
        static let voiceModeVoice = AccountKey<String?>("voiceMode.voice", .phoneWritable)
        static let autoGenerateArticles = AccountKey<Bool?>("readAloud.autoGenerate.articles", .phoneWritable)
        static let autoGeneratePapers = AccountKey<Bool?>("readAloud.autoGenerate.papers", .phoneWritable)
        static let autoGenerateBooks = AccountKey<Bool?>("readAloud.autoGenerate.books", .phoneWritable)
        static let autoGenerateCourses = AccountKey<Bool?>("readAloud.autoGenerate.courses", .phoneWritable)
        /// Explainers are article-typed sources with a switch of their own
        /// (`SourceAudioAutomation.explainerKind`).
        static let autoGenerateExplainers = AccountKey<Bool?>("readAloud.autoGenerate.explainers", .phoneWritable)
        static let autoGenerateConstraintArticle = AccountKey<String?>("readAloud.autoGenerate.constraint.article")
        static let autoGenerateConstraintPaper = AccountKey<String?>("readAloud.autoGenerate.constraint.paper")
        static let autoGenerateConstraintBook = AccountKey<String?>("readAloud.autoGenerate.constraint.book")
        static let autoGenerateConstraintCourse = AccountKey<String?>("readAloud.autoGenerate.constraint.course")
        static let autoGenerateConstraintExplainer = AccountKey<String?>("readAloud.autoGenerate.constraint.explainer")
        static let autoGenerateAllowPaidVoices = AccountKey<Bool?>("readAloud.autoGenerate.allowPaidVoices")
        static let audioPricesTable = DeviceKey<Data?>("openRouterAudioPrices.table.v1", reason: "remote price cache for speech models")
        static let audioPricesReadAt = DeviceKey<Date?>("openRouterAudioPrices.readAt.v1", reason: "remote price cache for speech models")

        static let all: [AnyPreferenceKey] = [
            speed.erased,
            confirmCostBeforeListening.erased,
            costConfirmationSuppressedModels.erased,
            appleVoiceIdentifier.erased,
            openAIVoice.erased,
            groqVoice.erased,
            elevenLabsVoice.erased,
            xaiVoice.erased,
            geminiVoice.erased,
            togetherVoice.erased,
            openRouterVoice.erased,
            localQwen3Voice.erased,
            openAIInstructions.erased,
            localQwen3Instructions.erased,
            voiceModeVoice.erased,
            autoGenerateArticles.erased,
            autoGeneratePapers.erased,
            autoGenerateBooks.erased,
            autoGenerateCourses.erased,
            autoGenerateExplainers.erased,
            autoGenerateConstraintArticle.erased,
            autoGenerateConstraintPaper.erased,
            autoGenerateConstraintBook.erased,
            autoGenerateConstraintCourse.erased,
            autoGenerateConstraintExplainer.erased,
            autoGenerateAllowPaidVoices.erased,
            audioPricesTable.erased,
            audioPricesReadAt.erased,
        ]
    }
}
