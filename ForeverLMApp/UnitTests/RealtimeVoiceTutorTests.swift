import Foundation
import Testing
@testable import ForeverLM

/// The model-free parts of voice mode (`RealtimeVoiceTutor.swift`,
/// `RealtimeVoiceProtocol.swift`): what the tutor is told, the passage search
/// its tool runs on the device, how a conversation is saved as a chat, and how
/// server errors and response control are handled.
@Suite("Realtime voice tutor")
struct RealtimeVoiceTutorTests {
    private func source(text: String, guide: String? = nil) -> RealtimeVoiceSource {
        RealtimeVoiceSource(
            id: "s1",
            title: "Mitochondrial Membrane Potential in Ageing Flies",
            sourceType: "paper",
            byline: "A. Fictional · Journal of Made-Up Results",
            text: text,
            reviewGuide: guide
        )
    }

    @Test("A source that fits goes in whole, with the opening asked for")
    func instructionsCarryTheWholeSource() {
        let text = "Membrane potential falls with age. " + String(repeating: "Body text. ", count: 100)
        let quiz = RealtimeVoiceTutor.instructions(for: source(text: text), opening: .quiz)
        #expect(quiz.contains(text))
        #expect(quiz.contains("You have the whole paper below"))
        #expect(quiz.contains("ask the first question"))
        #expect(quiz.contains("By: A. Fictional"))
        let talk = RealtimeVoiceTutor.instructions(for: source(text: text, guide: "Key idea: decline."), opening: .talk)
        #expect(talk.contains("what they would like to"))
        #expect(talk.contains("<review_guide>"))
    }

    @Test("A source over the budget keeps its opening and is searched for the rest")
    func longSourceIsSearched() {
        let text = String(repeating: "a", count: RealtimeVoiceTutor.inlineTextBudget) + "THE TAIL"
        let instructions = RealtimeVoiceTutor.instructions(for: source(text: text), opening: .talk)
        #expect(!instructions.contains("THE TAIL"))
        #expect(instructions.contains("call \(RealtimeVoiceTutor.searchToolName)"))
    }

    @Test("Passage search finds the matching passage and says where it is")
    func passageSearch() {
        let text = (0..<40).map { index in
            index == 31
                ? "Complex I inhibition with rotenone restored lifespan in the long-lived strain."
                : "Paragraph \(index) is about something else entirely, like wing morphology."
        }.joined(separator: "\n")
        let passages = RealtimeVoicePassageSearch.chunks(of: text, size: 200, overlap: 40)
        #expect(passages.count > 3)
        let found = RealtimeVoicePassageSearch.search("rotenone complex", in: passages)
        #expect(found.first?.text.contains("rotenone") == true)
        let output = RealtimeVoicePassageSearch.toolOutput(query: "rotenone", passages: passages)
        #expect(output.contains("rotenone"))
        #expect(output.contains("of the way through"))
        let none = RealtimeVoicePassageSearch.toolOutput(query: "quasar", passages: passages)
        #expect(none.contains("Nothing in the source matches"))
    }

    @Test("A conversation is saved as one exchange per learner line")
    func exchanges() {
        let turns = [
            RealtimeVoiceTurn(id: "1", role: .tutor, text: "What is the central claim?"),
            RealtimeVoiceTurn(id: "2", role: .learner, text: "Potential drops with age."),
            RealtimeVoiceTurn(id: "3", role: .tutor, text: "Right."),
            RealtimeVoiceTurn(id: "4", role: .tutor, text: "Why does it matter?"),
            RealtimeVoiceTurn(id: "5", role: .learner, text: "Energy."),
            RealtimeVoiceTurn(id: "6", role: .tutor, text: "Partly, but", wasInterrupted: true),
            RealtimeVoiceTurn(id: "7", role: .learner, text: "  "),
            RealtimeVoiceTurn(id: "8", role: .learner, text: "Bye"),
            RealtimeVoiceTurn(id: "9", role: .tutor, text: "Goodbye!"),
        ]
        let exchanges = RealtimeVoiceExchange.exchanges(from: turns)
        #expect(exchanges.count == 3)
        #expect(exchanges[0].question == "What is the central claim?")
        #expect(exchanges[0].answer == "Potential drops with age.")
        #expect(exchanges[0].evaluation == "Right.\n\nWhy does it matter?")
        #expect(exchanges[1].evaluation == "Partly, but …")
        #expect(exchanges[2].answer == "Bye")
        #expect(exchanges[2].evaluation == "Goodbye!")
    }

    @Test("A tutor line nobody answered is saved as a question alone")
    func unansweredOpening() {
        let exchanges = RealtimeVoiceExchange.exchanges(from: [
            RealtimeVoiceTurn(id: "1", role: .tutor, text: "Hi! Want to be quizzed?"),
        ])
        #expect(exchanges.count == 1)
        #expect(exchanges[0].question == "Hi! Want to be quizzed?")
        #expect(exchanges[0].answer.isEmpty)
    }

    @Test("Benign barge-in races are ignored only once the session is up")
    func errorDisposition() {
        let race = "Only model output audio messages can be truncated"
        #expect(RealtimeVoiceServerErrorDisposition.resolve(isReady: true, message: race) == .ignore)
        #expect(RealtimeVoiceServerErrorDisposition.resolve(isReady: false, message: race) == .failReadiness)
        #expect(RealtimeVoiceServerErrorDisposition.resolve(isReady: true, message: "Rate limit") == .surfaceInline)
    }

    @Test("Response creates are coalesced until the server answers")
    func sequencer() {
        var sequencer = OpenAIRealtimeResponseSequencer()
        guard case .create = sequencer.requestCreate() else {
            Issue.record("first create was not sent")
            return
        }
        #expect(sequencer.requestCreate() == nil)
        sequencer.responseCreated()
        #expect(sequencer.requestCancel() == .cancel)
        guard case .create = sequencer.responseDone() else {
            Issue.record("the pending create was not sent after the response finished")
            return
        }
    }

    @Test("Server events decode to what the controller needs")
    func decoding() {
        let audio = OpenAIRealtimeWire.decodeServerEvent([
            "type": "response.output_audio.delta",
            "delta": Data([1, 2, 3, 4]).base64EncodedString(),
        ])
        if case .audioDelta(let data) = audio {
            #expect(data.count == 4)
        } else {
            Issue.record("audio delta not decoded")
        }
        let call = OpenAIRealtimeWire.decodeServerEvent([
            "type": "response.function_call_arguments.done",
            "call_id": "c1", "name": "search_source", "arguments": #"{"query":"x"}"#,
        ])
        if case .functionCallDone(let id, let name, _) = call {
            #expect(id == "c1")
            #expect(name == "search_source")
        } else {
            Issue.record("function call not decoded")
        }
        // A function call is an output item that owns no speaker audio.
        #expect(OpenAIRealtimeWire.decodeServerEvent([
            "type": "response.output_item.added",
            "item": ["type": "function_call", "id": "i1"],
        ]) == nil)
    }

    @Test("A reply's usage is split into OpenAI's price buckets, cached tokens taken out")
    func usageDecoding() {
        let event = OpenAIRealtimeWire.decodeServerEvent([
            "type": "response.done",
            "response": [
                "id": "resp_1",
                "status": "completed",
                "usage": [
                    "input_token_details": [
                        "text_tokens": 1_000, "audio_tokens": 300,
                        "cached_tokens_details": ["text_tokens": 800, "audio_tokens": 100],
                    ],
                    "output_token_details": ["text_tokens": 40, "audio_tokens": 200],
                ],
            ] as [String: Any],
        ])
        guard case .responseDone(let id, _, let usage?) = event else {
            Issue.record("usage not decoded")
            return
        }
        #expect(id == "resp_1")
        #expect(usage.textInputTokens == 200)
        #expect(usage.cachedTextInputTokens == 800)
        #expect(usage.audioInputTokens == 200)
        #expect(usage.cachedAudioInputTokens == 100)
        #expect(usage.textOutputTokens == 40)
        #expect(usage.audioOutputTokens == 200)
        #expect(RealtimeVoiceUsage(responseID: "", usage: [:]) == nil)
    }

    @Test("The library is ranked by title words, then by recent attention")
    func libraryRanking() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let items = [
            RealtimeVoiceLibraryItem(id: "a", title: "Mitochondria and Ageing", sourceType: "paper", byline: nil,
                                     addedAt: now.addingTimeInterval(-90 * 86_400), lastAttentionAt: nil),
            RealtimeVoiceLibraryItem(id: "b", title: "Mitochondrial Dynamics in Flies", sourceType: "paper", byline: "C. Example",
                                     addedAt: now.addingTimeInterval(-200 * 86_400), lastAttentionAt: now.addingTimeInterval(-86_400)),
            RealtimeVoiceLibraryItem(id: "c", title: "Wing Morphology", sourceType: "article", byline: nil,
                                     addedAt: now, lastAttentionAt: now),
        ]
        let ranked = RealtimeVoiceLibrarySearch.rank("the mitochondria paper", in: items, now: now)
        #expect(ranked.map(\.id) == ["b", "a"])
        let output = RealtimeVoiceLibrarySearch.toolOutput(ranked, now: now)
        #expect(output.contains(#""source_id":"b""#))
        #expect(RealtimeVoiceLibrarySearch.toolOutput([]).contains("Nothing in the library matches"))
    }

    @Test("An opened source is handed over whole, or its opening with a note, and searched")
    func openedSources() {
        let opened = RealtimeVoiceOpenedSources()
        #expect(opened.search(sourceID: nil, query: "x").contains("No source is open"))
        let short = RealtimeVoiceSource(id: "s", title: "Short", sourceType: "article", byline: nil,
                                        text: "Rotenone inhibits complex I.", reviewGuide: nil)
        #expect(opened.open(short).contains("Rotenone inhibits complex I."))
        #expect(opened.search(sourceID: nil, query: "rotenone").contains("Rotenone"))
        let long = RealtimeVoiceSource(id: "l", title: "Long", sourceType: "book", byline: nil,
                                       text: String(repeating: "a ", count: RealtimeVoiceOpenedSources.openTextBudget), reviewGuide: nil)
        #expect(opened.open(long).contains("This is the opening only"))
        #expect(opened.ids == ["s", "l"])
    }

    @Test("The assistant knows the learner's picture and how to talk in the car")
    func assistantInstructions() {
        let sections = [
            RealtimeVoiceAssistant.Section(title: "Quarter plan", text: "Objective: finish the thesis draft."),
            RealtimeVoiceAssistant.Section(title: "Calendar this week", text: ""),
        ]
        let car = RealtimeVoiceAssistant.instructions(sections: sections, setting: .car)
        #expect(car.contains("<quarter_plan>"))
        #expect(car.contains("finish the thesis draft"))
        #expect(!car.contains("<calendar_this_week>"))
        #expect(car.contains("driving"))
        #expect(!RealtimeVoiceAssistant.instructions(sections: sections, setting: .mac).contains("driving"))
        #expect(RealtimeVoiceExchange.assistantChatTitle(firstQuestion: nil) == "Voice chat")
        let long = RealtimeVoiceExchange.assistantChatTitle(firstQuestion: String(repeating: "word ", count: 30))
        #expect(long.hasSuffix("…"))
        #expect(long.count <= 61)
    }
}
