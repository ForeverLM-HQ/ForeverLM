// Siri, the voice agent and the source chat.

import AVFoundation
import Combine
import CryptoKit
import MediaPlayer
import OSLog
import SwiftUI
import CloudKit
import SQLite3
import WidgetKit

extension MobileAudioReviewViewModel {
    func beginSiriVoiceSessionIfNeeded() async {
        guard !isSiriVoiceSessionActive else { return }
        isSiriVoiceSessionActive = true
        await voice.start()
    }

    func endSiriVoiceSession() async {
        guard isSiriVoiceSessionActive else { return }
        isSiriVoiceSessionActive = false
        await voice.stop()
    }

    private var acceptsInAppVoiceInput: Bool {
        isSiriVoiceSessionActive || isReviewActive || isSourceChatActive
    }

    func handlePendingSiriCommandIfNeeded() async {
        guard let command = MobileSiriCommandCenter.shared.takePendingCommand() else {
            return
        }

        await handleSiriCommand(command)
    }

    private func handleSiriAskQuery(_ query: String) async {
        let utterance = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }
        lastVoiceCommand = utterance

        guard hasOpenAIKey else {
            speakWithoutListening(
                "Add an OpenAI key in the app to use Ask ForeverLM."
            )
            return
        }

        do {
            let decision = try await voiceAgent.decide(
                utterance: utterance,
                state: voiceAgentState()
            )
            await executeVoiceAgentDecision(decision, originalUtterance: utterance)
        } catch {
            speakWithoutListening(error.localizedDescription)
        }
    }

    func handleVoiceTranscript(_ transcript: String) async {
        let utterance = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty, !isChatResponding, acceptsInAppVoiceInput else { return }
        lastVoiceCommand = utterance

        if isReviewActive {
            await routeReviewUtterance(utterance)
            return
        }

        if isSourceChatActive {
            await sendSourceChatMessage(utterance)
            voice.resetAfterHandledCommand()
            return
        }

        guard hasOpenAIKey else {
            speakAndResumeListening(
                "Add an OpenAI key in the app to ask follow-up questions.",
                pausePlayback: true,
                resumePlaybackAfterSpeech: true
            )
            await endSiriVoiceSession()
            voice.resetAfterHandledCommand()
            return
        }

        do {
            let decision = try await voiceAgent.decide(
                utterance: utterance,
                state: voiceAgentState()
            )
            await executeVoiceAgentDecision(decision, originalUtterance: utterance)
        } catch {
            speakAndResumeListening(error.localizedDescription, pausePlayback: true, resumePlaybackAfterSpeech: true)
        }
        voice.resetAfterHandledCommand()
    }

    private func handleSiriCommand(_ command: MobileSiriCommand) async {
        if allSources.isEmpty && items.isEmpty {
            await load()
        }

        switch command.action {
        case .openToday:
            // Today's plan is a card on Home; the shell goes back to it.
            pendingDeepLink = .today
        case .ask:
            guard let query = command.query else { return }
            await handleSiriAskQuery(query)
        case .askAboutSource:
            if let question = command.query?.trimmingCharacters(in: .whitespacesAndNewlines),
               !question.isEmpty {
                await startSourceChat(sourceID: command.sourceID, announce: false)
                guard isSourceChatActive else { return }
                await sendSourceChatMessage(question)
            } else {
                await startSourceChat(sourceID: command.sourceID, announce: true)
            }
        case .listSources:
            let utterance = command.query.map { "what sources do we have for \($0)" } ?? "list sources"
            speakAndResumeListening(
                naturalListPrompt(for: utterance),
                pausePlayback: true,
                resumePlaybackAfterSpeech: true
            )
        case .playSource:
            if let sourceID = command.sourceID {
                await playVoiceAgentSource(sourceID, utterance: command.query ?? "")
            } else if let query = command.query {
                await playVoiceAgentSource(nil, utterance: "read me \(query) out loud")
            }
        case .playLatestSource:
            await playLatestSource()
        case .playLatestPaper:
            await playLatestSource(sourceType: "paper")
        case .quiz:
            await startReviewQuiz(sourceID: command.sourceID, utterance: command.query ?? "")
        case .memoryReview:
            // Today's card review over every notebook; the shell opens it.
            pendingDeepLink = .review
        case .voiceMemoryCheck:
            // Today's cards, then today's review, out loud. A conversation
            // already on (the assistant in CarPlay) keeps going.
            await MobileRealtimeVoice.startMemoryCheck()
        case .pausePlayback:
            if speech.isSpeaking {
                speech.stop(owner: .voiceTab)
            } else if isPlaying {
                togglePlayback()
            }
        case .resumePlayback:
            if currentItem == nil, let latest = allSources.first {
                await playVoiceAgentSource(latest.id, utterance: "resume playback")
            } else if !isPlaying {
                togglePlayback()
            }
        case .stopPlayback:
            if speech.isSpeaking {
                speech.stop(owner: .voiceTab)
            }
            if isPlaying {
                togglePlayback()
            }
            await endSiriVoiceSession()
        case .stopReview:
            if isReviewActive {
                await cancelReview(speaking: "Review stopped.")
            } else if isSourceChatActive {
                await endSourceChat(resumeAudio: false)
                speakAndResumeListening("Source chat ended.")
            }
            await endSiriVoiceSession()
        }
    }

    private func executeVoiceAgentDecision(
        _ decision: MobileVoiceAgentDecision,
        originalUtterance: String
    ) async {
        switch decision.tool {
        case "play_source":
            await playVoiceAgentSource(decision.sourceID, utterance: originalUtterance)
        case "pause_audio":
            if speech.isSpeaking {
                speech.stop(owner: .voiceTab)
            } else if isPlaying {
                togglePlayback()
            }
            speakIfNeeded(decision.spokenResponse)
        case "resume_audio":
            if currentItem == nil {
                await playVoiceAgentSource(decision.sourceID, utterance: originalUtterance)
            } else if !isPlaying {
                togglePlayback()
            }
            speakIfNeeded(decision.spokenResponse)
        case "stop_audio":
            if speech.isSpeaking {
                speech.stop(owner: .voiceTab)
            } else if isPlaying {
                togglePlayback()
            }
            speakIfNeeded(decision.spokenResponse)
        case "pause_for_source_chat":
            await pauseForSourceChat(
                sourceID: resolveSourceID(decision.sourceID, from: originalUtterance),
                spokenResponse: decision.spokenResponse
            )
        case "skip_relative":
            skip(seconds: decision.seconds ?? 0)
            speakIfNeeded(decision.spokenResponse)
        case "set_speed":
            if let speed = decision.speed {
                setSpeed(speed)
            }
            speakIfNeeded(decision.spokenResponse)
        case "list_sources":
            let response = decision.spokenResponse
                ?? naturalListPrompt(for: originalUtterance)
            speakAndResumeListening(response, pausePlayback: true, resumePlaybackAfterSpeech: true)
        case "refresh_library":
            await load()
            speakAndResumeListening(decision.spokenResponse ?? librarySummary())
        case "identify_current_source":
            speakAndResumeListening(decision.spokenResponse ?? currentSourceDescription(), pausePlayback: true, resumePlaybackAfterSpeech: true)
        case "start_source_review":
            await startSourceChat(
                sourceID: resolveSourceID(decision.sourceID, from: originalUtterance),
                announce: true
            )
        case "start_review_quiz":
            await startReviewQuiz(
                sourceID: decision.sourceID,
                utterance: decision.message ?? originalUtterance
            )
        case "answer_source_question":
            if !isSourceChatActive {
                await startSourceChat(
                    sourceID: resolveSourceID(decision.sourceID, from: originalUtterance),
                    announce: false
                )
            }
            guard isSourceChatActive else { return }
            await sendSourceChatMessage(decision.message ?? originalUtterance)
        case "end_source_review":
            await endSourceChat(resumeAudio: decision.resumeAudio == true)
        case "no_op":
            if let response = decision.spokenResponse, !response.isEmpty {
                speakAndResumeListening(response)
            }
        default:
            speakAndResumeListening("I could not decide what to do with that.")
        }
    }

    private func voiceAgentState() -> MobileVoiceAgentState {
        MobileVoiceAgentState(
            isPlaying: isPlaying,
            isSourceReviewActive: isSourceChatActive,
            currentSourceID: currentItem?.id ?? activeVoiceSourceID,
            currentSourceTitle: currentItem?.title ?? activeVoiceSourceTitle,
            activeReviewTitle: activeChatTitle,
            playbackSpeed: speed,
            availableSources: allSources.enumerated().map { index, source in
                MobileVoiceAgentSource(
                    id: source.id,
                    position: index + 1,
                    title: source.title,
                    subtitle: [
                        source.sourceType,
                        source.hasAudio ? "Ready to play" : "Text voice available"
                    ]
                        .joined(separator: " • ")
                )
            }
        )
    }

    private func speakIfNeeded(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        speakAndResumeListening(text, pausePlayback: true, resumePlaybackAfterSpeech: true)
    }

    private func resolveSourceID(_ sourceID: String?, from utterance: String) -> String? {
        if let sourceID, allSources.contains(where: { $0.id == sourceID }) {
            return sourceID
        }

        return currentItem?.id ?? activeVoiceSourceID
    }

    func playVoiceAgentSource(_ sourceID: String?, utterance: String) async {
        let resolvedSourceID = resolveSourceID(sourceID, from: utterance)
        guard let playableSourceID = resolvedSourceID else {
            speakAndResumeListening("I do not have any synced sources to play yet.")
            return
        }

        if let item = itemForSourceID(playableSourceID) {
            await playWithSpokenLeadIn(item)
            return
        }

        guard let source = source(for: playableSourceID) else {
            speakAndResumeListening("I could not find that source.")
            return
        }

        await readCloudSourceAloud(source)
    }

    private func currentSourceDescription() -> String {
        if let title = currentItem?.title ?? activeVoiceSourceTitle {
            return "The current source is \(title)."
        }
        return "No source is active."
    }

    private func pauseForSourceChat(sourceID: String?, spokenResponse: String?) async {
        await startSourceChat(sourceID: sourceID, announce: false)
        guard isSourceChatActive else { return }

        let response = spokenResponse?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let response, !response.isEmpty {
            speakAndResumeListening(response, pausePlayback: false)
        } else if let activeChatTitle {
            speakAndResumeListening("Paused. Ask me anything about \(activeChatTitle).", pausePlayback: false)
        } else {
            speakAndResumeListening("Paused. Ask me anything about this source.", pausePlayback: false)
        }
    }

    private func startSourceChat(sourceID: String?, announce: Bool) async {
        await beginSiriVoiceSessionIfNeeded()
        guard let sourceContext = await sourceContext(for: sourceID) else {
            return
        }

        if isPlaying {
            player.pause()
            isPlaying = false
            persistPlaybackPosition(force: true)
            updateNowPlayingInfo()
        }
        activeVoiceSourceID = sourceContext.sourceID
        activeVoiceSourceTitle = sourceContext.title
        await sourceChat.start(
            sourceID: sourceContext.sourceID,
            sourceType: sourceContext.sourceType,
            sourceTitle: sourceContext.title,
            sourceText: sourceContext.text
        )
        isSourceChatActive = true
        activeChatTitle = sourceContext.title
        await recordSourceActivity(sourceID: sourceContext.sourceID, kind: .chat)
        if announce {
            speakAndResumeListening("Reviewing \(sourceContext.title). Ask me anything about it.", pausePlayback: false)
        }
    }

    func sourceContext(
        for sourceID: String?
    ) async -> (sourceID: String, sourceType: String, title: String, text: String)? {
        let resolvedID = sourceID ?? currentItem?.id ?? activeVoiceSourceID ?? allSources.first?.id
        guard let resolvedID else {
            speakAndResumeListening("I could not find a source to review. Ask what sources are available or play a source first.")
            return nil
        }
        let title = source(for: resolvedID)?.title
            ?? itemForSourceID(resolvedID)?.title
            ?? activeVoiceSourceTitle
            ?? "Source"

        do {
            if let item = itemForSourceID(resolvedID),
               let text = try? SyncedArticleAudioStore.loadSourceText(for: item.manifest) {
                let sourceType = source(for: resolvedID)?.sourceType ?? "source"
                return (resolvedID, sourceType, item.title, text)
            }

            let text = try await sourceTextStore.loadSourceText(sourceID: resolvedID)
            let sourceType = source(for: resolvedID)?.sourceType ?? "source"
            return (resolvedID, sourceType, title, text)
        } catch {
            speakAndResumeListening(error.localizedDescription, pausePlayback: true, resumePlaybackAfterSpeech: true)
            return nil
        }
    }

    private func sendSourceChatMessage(_ message: String) async {
        let totalStart = Date()
        guard !isChatResponding else { return }
        isChatResponding = true
        if isPlaying {
            player.pause()
            isPlaying = false
            persistPlaybackPosition(force: true)
            updateNowPlayingInfo()
        }
        await voice.stop()

        do {
            let response = try await sourceChat.send(message)
            if let chatBenchmark = await sourceChat.lastBenchmark() {
                lastDrivingBenchmark = MobileDrivingVoiceBenchmark(
                    utterance: message,
                    route: "source_chat",
                    sourceResolutionStrategy: "active_source",
                    sourceResolutionMilliseconds: 0,
                    sourceTextLoadMilliseconds: 0,
                    firstModelTurnMilliseconds: chatBenchmark.llmMilliseconds,
                    totalMilliseconds: MobileBenchmarkClock.milliseconds(since: totalStart),
                    selectedSourceTitle: chatBenchmark.sourceTitle
                )
            }
            isChatResponding = false
            speakAndResumeListening(response)
        } catch {
            isChatResponding = false
            speakAndResumeListening(error.localizedDescription)
        }
    }

    private func endSourceChat(resumeAudio: Bool) async {
        await sourceChat.reset()
        isSourceChatActive = false
        activeChatTitle = nil
        if resumeAudio, currentItem != nil {
            player.playImmediately(atRate: speed)
            isPlaying = true
            updateNowPlayingInfo()
            voice.resetAfterHandledCommand()
        } else {
            speakAndResumeListening("Review stopped.")
        }
    }

    private func playWithSpokenLeadIn(_ item: MobileAudioItem) async {
        speech.stop(owner: .voiceTab)
        voice.resetAfterHandledCommand()
        await play(item)
    }

    func speakWithoutListening(_ text: String) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.configureAudioSession()
            await self.voice.stop()
            self.speech.speak(text, owner: .voiceTab)
        }
    }

    func speakAndResumeListening(
        _ text: String,
        pausePlayback: Bool = false,
        resumePlaybackAfterSpeech: Bool = false
    ) {
        if pausePlayback, isPlaying {
            player.pause()
            isPlaying = false
            shouldResumePlaybackAfterSpeech = resumePlaybackAfterSpeech
            updateNowPlayingInfo()
        } else {
            shouldResumePlaybackAfterSpeech = false
        }
        Task { [weak self] in
            guard let self else { return }
            try? await self.configureAudioSession()
            await self.voice.stop()
            self.speech.speak(text, owner: .voiceTab)
        }
    }

    func resumeAfterSpeech() async {
        if shouldResumePlaybackAfterSpeech {
            shouldResumePlaybackAfterSpeech = false
            if currentItem != nil {
                player.playImmediately(atRate: speed)
                isPlaying = true
                updateNowPlayingInfo()
            }
        }

        guard isSiriVoiceSessionActive || isReviewActive || isSourceChatActive else { return }
        // Our own flags can still say "listening" after another surface took the
        // session mid-sentence; the arbiter is the authority on who may hold a mic.
        guard await MobileAudioSessionArbiter.shared.holds(.voiceTab) else { return }
        await voice.start()
    }

    private func librarySummary() -> String {
        MobileSourceVoiceFormatter.librarySummary(for: allSources)
    }

    private func naturalListPrompt(for utterance: String) -> String {
        MobileSourceVoiceFormatter.listPrompt(for: utterance, sources: allSources)
    }
}
