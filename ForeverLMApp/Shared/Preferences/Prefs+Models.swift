import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// Model selection: the provider and model rows, chat and background lists, routes, and the caches of what the model directories said.
    enum Models {
        /// AI model selection. The `<provider>_model` / `*_provider` keys are the
        /// `KeychainService.Key` raw values migrated out of the Keychain vault; see
        /// `KeychainService.preferenceBackedKeys`.
        static let aiProvider = AccountKey<String?>("ai_provider", .modelConfiguration)
        static let anthropicModel = AccountKey<String?>("anthropic_model", .modelConfiguration)
        static let openAIModel = AccountKey<String?>("openai_model", .modelConfiguration)
        static let groqModel = AccountKey<String?>("groq_model", .modelConfiguration)
        static let cerebrasModel = AccountKey<String?>("cerebras_model", .modelConfiguration)
        static let xaiModel = AccountKey<String?>("xai_model", .modelConfiguration)
        static let geminiModel = AccountKey<String?>("gemini_model", .modelConfiguration)
        static let metaModel = AccountKey<String?>("meta_model", .modelConfiguration)
        static let togetherModel = AccountKey<String?>("together_model", .modelConfiguration)
        static let fireworksModel = AccountKey<String?>("fireworks_model", .modelConfiguration)
        static let nvidiaModel = AccountKey<String?>("nvidia_model", .modelConfiguration)
        static let openRouterModel = AccountKey<String?>("openrouter_model", .modelConfiguration)
        static let anthropicModelExplicitlyPicked = AccountKey<Bool?>("anthropic_model_explicitly_picked", .modelConfiguration)
        static let openAIModelExplicitlyPicked = AccountKey<Bool?>("openai_model_explicitly_picked", .modelConfiguration)
        static let chatModelsEnabledIDs = AccountKey<[String]?>("chatModels.enabledIDs", .modelConfiguration)
        static let chatModelsOpenRouterCustom = AccountKey<Data?>("chatModels.openRouterCustom", .modelConfiguration)
        static let chatModelsShortlist = AccountKey<[String]?>("chatModels.shortlist", .modelConfiguration)
        static let backgroundShortlistText = AccountKey<[String]?>("backgroundModels.shortlist.text", .modelConfiguration)
        static let backgroundShortlistImages = AccountKey<[String]?>("backgroundModels.shortlist.images", .modelConfiguration)
        static let defaultChatRoute = AccountKey<Data?>("aiRoute.defaultChat", .modelConfiguration)
        static let defaultChatEffort = AccountKey<String?>("aiRoute.defaultChat.effort", .modelConfiguration)
        static let defaultChatSpeed = AccountKey<String?>("aiRoute.defaultChat.speed", .modelConfiguration)
        static let backgroundRoute = AccountKey<Data?>("aiRoute.background", .modelConfiguration)
        static let backgroundMultimodalRoute = AccountKey<Data?>("aiRoute.background.multimodal", .modelConfiguration)
        static let docsRoute = AccountKey<Data?>("aiRoute.docs", .modelConfiguration)
        static let textRoutingMode = AccountKey<String?>("aiRoute.textRoutingMode", .modelConfiguration)
        /// Speech-to-text and text-to-speech selection. The realtime voice
        /// and live dictation keys (`realtimeVoiceModel`, `realtimeVoice.*`,
        /// `stt_engine`, `stt_model_realtime`) stopped syncing when those went
        /// on 2026-10-01.
        static let sttProvider = AccountKey<String?>("stt_provider", .modelConfiguration)
        static let sttModelOpenAI = AccountKey<String?>("stt_model_openai", .modelConfiguration)
        static let sttModelGroq = AccountKey<String?>("stt_model_groq", .modelConfiguration)
        static let sttModelOpenRouter = AccountKey<String?>("stt_model_openrouter", .modelConfiguration)
        static let sttModelWispr = AccountKey<String?>("stt_model_wispr", .modelConfiguration)
        static let sttModelWhisperKit = AccountKey<String?>("stt_model_whisperkit", .modelConfiguration)
        static let sttModelAssemblyAI = AccountKey<String?>("stt_model_assemblyai", .modelConfiguration)
        static let sttModelCartesia = AccountKey<String?>("stt_model_cartesia", .modelConfiguration)
        static let sttModelTailscale = AccountKey<String?>("stt_model_tailscale", .modelConfiguration)
        static let sttLocalServerURL = AccountKey<String?>("stt_local_server_url", .modelConfiguration)
        static let ttsProvider = AccountKey<String?>("tts_provider", [.modelConfiguration, .phoneWritable])
        static let ttsModelApple = AccountKey<String?>("tts_model_apple", .modelConfiguration)
        static let ttsModelOpenAI = AccountKey<String?>("tts_model_openai", .modelConfiguration)
        static let ttsModelGroq = AccountKey<String?>("tts_model_groq", .modelConfiguration)
        static let ttsModelElevenLabs = AccountKey<String?>("tts_model_elevenlabs", .modelConfiguration)
        static let ttsModelTogetherAI = AccountKey<String?>("tts_model_together", .modelConfiguration)
        static let ttsModelLocalMac = AccountKey<String?>("tts_model_local_mac", .modelConfiguration)
        static let ttsModelXAI = AccountKey<String?>("tts_model_xai", .modelConfiguration)
        static let ttsModelOpenRouter = AccountKey<String?>("tts_model_openrouter", [.modelConfiguration, .phoneWritable])
        static let ttsModelGemini = AccountKey<String?>("tts_model_gemini", .modelConfiguration)
        static let ttsModelCartesia = AccountKey<String?>("tts_model_cartesia", .modelConfiguration)
        static let ttsModelTailscale = AccountKey<String?>("tts_model_tailscale", .modelConfiguration)
        static let ttsLocalServerURL = AccountKey<String?>("tts_local_server_url", .modelConfiguration)
        static let backgroundProvider = AccountKey<String?>("aiBackground.provider", .familyMember)
        /// The single background model row from before one row per provider; only ever cleared.
        static let retiredBackgroundModel = AccountKey<Any?>("aiBackground.model", coding: .any, .familyMember)
        static let backgroundUsageConsented = AccountKey<Bool>("aiBackground.usageConsented", default: false, .familyMember)
        static let meetingsMayUseFree = AccountKey<Bool?>("aiBackground.meetingsMayUseFree", .familyMember)
        /// A chat's pick is the session's; the row is only ever cleared.
        static let chatTaskProvider = AccountKey<Any?>("aiTask.chat.provider", coding: .any, .familyMember)
        /// A chat's pick is the session's; the row is only ever cleared.
        static let chatTaskModel = AccountKey<Any?>("aiTask.chat.model", coding: .any, .familyMember)
        /// A chat's pick is the session's; the row is only ever cleared.
        static let chatTaskEffort = AccountKey<Any?>("aiTask.chat.effort", coding: .any, .familyMember)
        /// A chat's pick is the session's; the row is only ever cleared.
        static let chatTaskSpeed = AccountKey<Any?>("aiTask.chat.speed", coding: .any, .familyMember)
        static let sttModelMedia = DeviceKey<String?>("stt_model_media", reason: "the model this Mac transcribes media files with; never listed as synced")
        static let openRouterVision = DeviceKey<Data?>("aiCapabilities.openRouterVision", reason: "remote capability cache, refetched")
        static let openRouterReleaseDate = DeviceKey<Data?>("aiCapabilities.openRouterReleaseDate", reason: "remote capability cache, refetched")
        static let openRouterReasoningEfforts = DeviceKey<Data?>("aiCapabilities.openRouterReasoningEfforts", reason: "remote capability cache, refetched")
        static let chatRecentModels = DeviceKey<Data?>("chat.recentModels", reason: "the models this Mac's chat picker used last")
        static let qualification = DeviceKey<Data?>("aiModelQualification.v1", reason: "this device's record of the model test runs it made")
        static let priceWatchLastSeen = DeviceKey<Data?>("aiModelPriceWatch.lastSeen.v1", reason: "what this Mac last saw each free model cost")
        static let priceWatchAnnouncedEnded = DeviceKey<[String]?>("aiModelPriceWatch.announcedEnded.v1", reason: "the ended free offers this Mac has already announced")
        static let managedAppAccess = DeviceKey<Data?>("managedAI.appAccess", reason: "cache of server-held account state")
        static let managedServerClockOffset = DeviceKey<Double?>("managedAI.serverClockOffset", reason: "this device's clock against the server's")

        static let all: [AnyPreferenceKey] = [
            aiProvider.erased,
            anthropicModel.erased,
            openAIModel.erased,
            groqModel.erased,
            cerebrasModel.erased,
            xaiModel.erased,
            geminiModel.erased,
            metaModel.erased,
            togetherModel.erased,
            fireworksModel.erased,
            nvidiaModel.erased,
            openRouterModel.erased,
            anthropicModelExplicitlyPicked.erased,
            openAIModelExplicitlyPicked.erased,
            chatModelsEnabledIDs.erased,
            chatModelsOpenRouterCustom.erased,
            chatModelsShortlist.erased,
            backgroundShortlistText.erased,
            backgroundShortlistImages.erased,
            defaultChatRoute.erased,
            defaultChatEffort.erased,
            defaultChatSpeed.erased,
            backgroundRoute.erased,
            backgroundMultimodalRoute.erased,
            docsRoute.erased,
            textRoutingMode.erased,
            sttProvider.erased,
            sttModelOpenAI.erased,
            sttModelGroq.erased,
            sttModelOpenRouter.erased,
            sttModelWispr.erased,
            sttModelWhisperKit.erased,
            sttModelAssemblyAI.erased,
            sttModelCartesia.erased,
            sttModelTailscale.erased,
            sttLocalServerURL.erased,
            ttsProvider.erased,
            ttsModelApple.erased,
            ttsModelOpenAI.erased,
            ttsModelGroq.erased,
            ttsModelElevenLabs.erased,
            ttsModelTogetherAI.erased,
            ttsModelLocalMac.erased,
            ttsModelXAI.erased,
            ttsModelOpenRouter.erased,
            ttsModelGemini.erased,
            ttsModelCartesia.erased,
            ttsModelTailscale.erased,
            ttsLocalServerURL.erased,
            backgroundProvider.erased,
            retiredBackgroundModel.erased,
            backgroundUsageConsented.erased,
            meetingsMayUseFree.erased,
            chatTaskProvider.erased,
            chatTaskModel.erased,
            chatTaskEffort.erased,
            chatTaskSpeed.erased,
            sttModelMedia.erased,
            openRouterVision.erased,
            openRouterReleaseDate.erased,
            openRouterReasoningEfforts.erased,
            chatRecentModels.erased,
            qualification.erased,
            priceWatchLastSeen.erased,
            priceWatchAnnouncedEnded.erased,
            managedAppAccess.erased,
            managedServerClockOffset.erased,
        ]
    }
}
