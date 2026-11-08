import Foundation
import Testing
@testable import ForeverLM

/// The model-free parts of voice mode (`RealtimeVoiceTutor.swift`,
/// `RealtimeVoiceProtocol.swift`): the session it is minted with, what the
/// tutor is told, the passage search its tool runs on the device, how a
/// conversation is saved and resumed, and how server events are read.
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

    @Test("Response-control races are not shown; other errors are")
    func errorDisposition() {
        #expect(RealtimeVoiceServerErrorDisposition.isBenign("Conversation already has an active response in progress"))
        #expect(!RealtimeVoiceServerErrorDisposition.isBenign("Rate limit reached"))
    }

    @Test("The session is minted with the voice, tools and OpenAI's default turn detection, and no transcription")
    func sessionConfiguration() throws {
        let configuration = OpenAIRealtimeWire.sessionConfiguration(
            instructions: "Be brief.",
            tools: [RealtimeVoiceTutor.endTool],
            voice: "cedar"
        )
        let json = try #require(String(data: JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]), encoding: .utf8))
        #expect(json.contains(#""voice":"cedar""#))
        #expect(json.contains(#""type":"server_vad""#))
        #expect(json.contains(#""interrupt_response":true"#))
        #expect(json.contains(#""threshold":0.5"#))
        #expect(json.contains(#""retention_ratio":0.8"#))
        #expect(!json.contains("transcription"))
        // The proxy sets the type and the model.
        #expect(configuration["type"] == nil && configuration["model"] == nil)
        let body = try RealtimeSessionJSON(configuration)
        let encoded = try #require(String(data: JSONEncoder().encode(body), encoding: .utf8))
        #expect(encoded.contains(#""create_response":true"#))
        #expect(encoded.contains(#""prefix_padding_ms":300"#))
    }

    @Test("A source that fits offers no tool; a long one offers passage search")
    func sourceTools() {
        let short = RealtimeVoiceSourceToolbox(source: source(text: "Short."))
        #expect(short.toolDefinitions.isEmpty)
        let long = RealtimeVoiceSourceToolbox(source: source(text: String(repeating: "a ", count: RealtimeVoiceTutor.inlineTextBudget)))
        #expect(long.toolDefinitions.count == 1)
    }

    @Test("A dropped call resumes with what ForeverLM said, and the learner's spoken turns are marked, never transcribed")
    func resume() {
        let turns = [
            RealtimeVoiceTurn(id: "1", role: .tutor, text: "What is the central claim?"),
            RealtimeVoiceTurn(id: "2", role: .learner, text: RealtimeVoiceTurn.spokenMark),
            RealtimeVoiceTurn(id: "3", role: .tutor, text: "Right, and why?"),
        ]
        let items = RealtimeVoiceTutor.resumeItems(from: turns)
        #expect(items.map(\.text) == ["What is the central claim?", "Right, and why?"])
        #expect(items.allSatisfy { $0.role == "assistant" })
        #expect(RealtimeVoiceExchange.assistantChatTitle(firstQuestion: RealtimeVoiceTurn.spokenMark) == "Voice chat")
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
        // Over WebRTC the audio is a media track; the data channel says when
        // it plays, stops, and is cut off.
        #expect(OpenAIRealtimeWire.decodeServerEvent(["type": "output_audio_buffer.started"]) == .outputAudioStarted)
        #expect(OpenAIRealtimeWire.decodeServerEvent(["type": "output_audio_buffer.stopped"]) == .outputAudioStopped)
        #expect(OpenAIRealtimeWire.decodeServerEvent(["type": "output_audio_buffer.cleared"]) == .outputAudioCleared)
        #expect(OpenAIRealtimeWire.decodeServerEvent(["type": "session.created"]) == .sessionReady)
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
        // Card review runs where its tools are: the iPhone and the car.
        #expect(car.contains("get_due_cards"))
        #expect(!RealtimeVoiceAssistant.instructions(sections: sections, setting: .mac).contains("get_due_cards"))
        #expect(RealtimeVoiceExchange.assistantChatTitle(firstQuestion: nil) == "Voice chat")
        let long = RealtimeVoiceExchange.assistantChatTitle(firstQuestion: String(repeating: "word ", count: 30))
        #expect(long.hasSuffix("…"))
        #expect(long.count <= 61)
    }

    @Test("Review by Voice carries today's cards in its instructions and asks the first one")
    func cardReviewInstructions() {
        let cards = [
            RealtimeVoiceCardReview.Card(id: "item-1", question: "What does ATP synthase make?", answer: "ATP, from the proton gradient.", source: "Mitochondria review"),
            RealtimeVoiceCardReview.Card(id: "item-2", question: "Line one\nline two", answer: String(repeating: "a", count: 900), source: nil),
        ]
        let few = RealtimeVoiceCardReview.instructions(cards: cards, dueToday: 2, scopeTitle: "all their notebooks")
        #expect(few.contains("card_id: item-1"))
        #expect(few.contains("question: What does ATP synthase make?"))
        #expect(few.contains("source: Mitochondria review"))
        #expect(few.contains("question: Line one line two"))
        #expect(few.contains("Today's cards, 2 due:"))
        #expect(few.contains("grade_card"))
        #expect(few.contains("end_conversation"))
        // Nothing more is due, so the model is not sent looking for more.
        #expect(!few.contains("call get_due_cards"))
        // A long answer is clipped out loud.
        #expect(few.contains(String(repeating: "a", count: RealtimeVoiceCardReview.fieldBudget) + "…"))
        #expect(!few.contains(String(repeating: "a", count: RealtimeVoiceCardReview.fieldBudget + 1)))

        let more = RealtimeVoiceCardReview.instructions(cards: cards, dueToday: 30, scopeTitle: "the notebook \u{201C}Biology\u{201D}")
        #expect(more.contains("the first 2 of 30 due"))
        #expect(more.contains("call get_due_cards"))
        #expect(more.contains("Biology"))

        #expect(RealtimeVoiceCardReview.kickoff(cardCount: 1).contains("one card"))
        #expect(RealtimeVoiceCardReview.kickoff(cardCount: 12).contains("12 cards"))
    }

    @Test("get_due_cards answers with the cards, or says none are left")
    func cardReviewToolOutput() throws {
        let output = RealtimeVoiceCardReview.dueCardsOutput(
            [RealtimeVoiceCardReview.Card(id: "item-3", question: "Q?", answer: "A.", source: nil)],
            dueToday: 7
        )
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let rows = try #require(object["cards"] as? [[String: Any]])
        #expect(rows.first?["card_id"] as? String == "item-3")
        #expect(rows.first?["source"] == nil)
        #expect(object["due_today"] as? Int == 7)
        #expect(RealtimeVoiceCardReview.dueCardsOutput([], dueToday: 0).contains("No cards are due today"))
        #expect(RealtimeVoiceCardReview.dueCardsOutput([], dueToday: 3).contains("already dealt"))
        #expect(RealtimeVoiceCardReview.gradeCardTool["name"] as? String == "grade_card")
        let due = RealtimeVoiceCardReview.dueCardsTool(description: "More cards.")
        #expect(due["name"] as? String == "get_due_cards")
    }
}
