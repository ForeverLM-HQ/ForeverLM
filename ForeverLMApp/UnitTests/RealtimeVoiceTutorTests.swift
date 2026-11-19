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

    @Test("The session is minted with the voice, tools, patient semantic turn detection, far-field noise reduction, and no transcription")
    func sessionConfiguration() throws {
        let configuration = OpenAIRealtimeWire.sessionConfiguration(
            instructions: "Be brief.",
            tools: [RealtimeVoiceTutor.endTool],
            voice: "cedar"
        )
        let json = try #require(String(data: JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]), encoding: .utf8))
        #expect(json.contains(#""voice":"cedar""#))
        // A pause to think is not the end of an answer, and road noise is not speech.
        #expect(json.contains(#""type":"semantic_vad""#))
        #expect(json.contains(#""eagerness":"low""#))
        #expect(!json.contains("server_vad") && !json.contains("silence_duration_ms"))
        #expect(json.contains(#""noise_reduction":{"type":"far_field"}"#))
        #expect(json.contains(#""interrupt_response":true"#))
        #expect(json.contains(#""transcription":{"model":"gpt-4o-mini-transcribe"}"#))
        #expect(json.contains(#""retention_ratio":0.8"#))
        #expect(!json.contains("transcription"))
        // The proxy sets the type and the model.
        #expect(configuration["type"] == nil && configuration["model"] == nil)
        let body = try RealtimeSessionJSON(configuration)
        let encoded = try #require(String(data: JSONEncoder().encode(body), encoding: .utf8))
        #expect(encoded.contains(#""create_response":true"#))
        #expect(encoded.contains(#""eagerness":"low""#))

        let typedOnly = OpenAIRealtimeWire.sessionConfiguration(
            instructions: "Answer typed questions.",
            tools: [],
            voice: "cedar",
            typedOnly: true
        )
        let typedJSON = try #require(String(
            data: JSONSerialization.data(withJSONObject: typedOnly, options: [.sortedKeys]),
            encoding: .utf8
        ))
        #expect(typedJSON.contains(#""turn_detection":null"#))
        #expect(typedJSON.contains(#""noise_reduction":null"#))
        #expect(!typedJSON.contains("semantic_vad"))
    }

    @Test("A graded card puts what the learner said on their spoken line, without scoring the chat")
    func gradedCardAnswer() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let turns = [
            RealtimeVoiceTurn(id: "1", role: .tutor, text: "What does Kleiber's law say?", spokenAt: start),
            RealtimeVoiceTurn(id: "2", role: .learner, text: RealtimeVoiceTurn.spokenMark, spokenAt: start.addingTimeInterval(6)),
            RealtimeVoiceTurn(id: "3", role: .tutor, text: "Close: it scales to the three-quarters power.", spokenAt: start.addingTimeInterval(9)),
        ]
        #expect(RealtimeVoiceCardReview.answerRecord(question: "Q?", learnerSaid: "  ", remembered: true, at: start) == nil)
        let record = try #require(RealtimeVoiceCardReview.answerRecord(
            question: "What does Kleiber's law say?",
            learnerSaid: "Bigger animals burn more energy.",
            remembered: false,
            at: start.addingTimeInterval(8)
        ))
        let exchanges = RealtimeVoiceExchange.exchanges(from: turns, answers: [record])
        #expect(exchanges.count == 1)
        #expect(exchanges[0].answer == "Bigger animals burn more energy.")
        #expect(exchanges[0].evaluation == "Close: it scales to the three-quarters power.")
        #expect(exchanges[0].score == nil, "the card's schedule holds the grade, not the chat")
        #expect(RealtimeVoiceExchange.overallScore(of: exchanges) == nil)

        let parameters = try #require(RealtimeVoiceCardReview.gradeCardTool["parameters"] as? [String: Any])
        #expect((parameters["required"] as? [String]) == ["card_id", "learner_said", "remembered"])
    }

    @Test("Every source conversation can record answers; a long source adds passage search")
    func sourceTools() {
        let short = RealtimeVoiceSourceToolbox(source: source(text: "Short."))
        #expect(short.toolDefinitions.compactMap { $0["name"] as? String } == ["record_answer"])
        let long = RealtimeVoiceSourceToolbox(source: source(text: String(repeating: "a ", count: RealtimeVoiceTutor.inlineTextBudget)))
        #expect(long.toolDefinitions.compactMap { $0["name"] as? String } == ["search_source", "record_answer"])
        #expect(RealtimeVoiceTutor.instructions(for: source(text: "Short."), opening: .quiz).contains("call record_answer once"))
    }

    @Test("record_answer keeps what the tutor judged, refuses a call missing its parts, and drops a gap on a full answer")
    func recordAnswer() async {
        let toolbox = RealtimeVoiceSourceToolbox(source: source(text: "Short."))
        let refused = await toolbox.run(name: "record_answer", argumentsJSON: #"{"question":"Why?","verdict":"maybe"}"#)
        #expect(refused.contains("error"))
        let ok = await toolbox.run(
            name: "record_answer",
            argumentsJSON: #"{"question":"Why do the cells change?","learner_said":"Because of the voltage.","verdict":"partly","gap":"Did not name the ion channels."}"#
        )
        #expect(ok == #"{"recorded":true}"#)
        _ = await toolbox.run(
            name: "record_answer",
            argumentsJSON: #"{"question":"What grew?","learner_said":"An eye.","verdict":"had_it","gap":"none"}"#
        )
        let answers = await toolbox.recordedAnswers()
        #expect(answers.map(\.verdict) == [.partly, .hadIt])
        #expect(answers[0].gap == "Did not name the ion channels.")
        #expect(answers[1].gap == nil, "a full answer has no gap")
    }

    @Test("Recorded grades land on the learner lines they followed, and the session's score is their mean")
    func gradedExchanges() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let turns = [
            RealtimeVoiceTurn(id: "1", role: .tutor, text: "What grew on the gut?", spokenAt: start),
            RealtimeVoiceTurn(id: "2", role: .learner, text: RealtimeVoiceTurn.spokenMark, spokenAt: start.addingTimeInterval(5)),
            RealtimeVoiceTurn(id: "3", role: .tutor, text: "Yes, an eye. Why there?", spokenAt: start.addingTimeInterval(8)),
            RealtimeVoiceTurn(id: "4", role: .learner, text: RealtimeVoiceTurn.spokenMark, spokenAt: start.addingTimeInterval(15)),
            RealtimeVoiceTurn(id: "5", role: .tutor, text: "Partly: the channels set the voltage.", spokenAt: start.addingTimeInterval(18)),
        ]
        func record(_ json: String, at seconds: Double) throws -> RealtimeVoiceAnswerRecord {
            try #require(RealtimeVoiceAnswerRecord(argumentsJSON: json, recordedAt: start.addingTimeInterval(seconds)))
        }
        let answers = [
            try record(#"{"question":"Why there?","learner_said":"The voltage told them to.","verdict":"partly","gap":"The ion channels set the voltage."}"#, at: 17),
            try record(#"{"question":"What grew on the gut?","learner_said":"An eye.","verdict":"had_it"}"#, at: 7),
        ]
        let exchanges = RealtimeVoiceExchange.exchanges(from: turns, answers: answers)
        #expect(exchanges.count == 2)
        #expect(exchanges[0].answer == "An eye.")
        #expect(exchanges[0].score == 1)
        #expect(exchanges[0].evaluation == "Yes, an eye. Why there?", "the tutor's reply stays the evaluation")
        #expect(exchanges[1].answer == "The voltage told them to.")
        #expect(exchanges[1].score == 0.5)
        #expect(exchanges[1].gap == "The ion channels set the voltage.")
        #expect(RealtimeVoiceExchange.overallScore(of: exchanges) == 0.75)
        #expect(RealtimeVoiceExchange.gradedLine(of: exchanges) == "2 answers graded: 1 had it, 1 partly, 0 missed.")

        // A talk with nothing graded keeps its spoken marks and has no score.
        let talk = RealtimeVoiceExchange.exchanges(from: turns, answers: [])
        #expect(talk.allSatisfy { $0.score == nil })
        #expect(talk.first?.answer == RealtimeVoiceTurn.spokenMark)
        #expect(RealtimeVoiceExchange.overallScore(of: talk) == nil)
        #expect(RealtimeVoiceExchange.gradedLine(of: talk) == nil)
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

    @Test("Gym mode gives one uninterrupted walkthrough, never quizzes, and finishes with a tool")
    func gymInstructions() {
        let text = "Membrane potential falls with age. " + String(repeating: "Body text. ", count: 50)
        let gym = RealtimeVoiceTutor.instructions(for: source(text: text, guide: "Key idea: decline."), opening: .gym)
        #expect(gym.contains(text))
        #expect(gym.contains("at the gym"))
        #expect(gym.contains("one continuous spoken walk-through"))
        #expect(gym.contains("do not stop early"))
        #expect(gym.contains("Never quiz"))
        #expect(gym.contains("call \(RealtimeVoiceTutor.finishWalkthroughToolName)"))
        #expect(!gym.contains(RealtimeVoiceTutor.recordAnswerToolName), "nothing is graded in gym mode")
        #expect(!gym.contains("<review_guide>"))
        let long = RealtimeVoiceTutor.instructions(
            for: source(text: String(repeating: "a", count: RealtimeVoiceTutor.inlineTextBudget) + "THE TAIL"),
            opening: .gym
        )
        #expect(!long.contains("THE TAIL"))
        #expect(long.contains("call \(RealtimeVoiceTutor.searchToolName)"))
        #expect(RealtimeVoiceTutor.kickoffMessage(for: .gym).contains("gym mode"))
        #expect(RealtimeVoiceTutor.finishWalkthroughTool["name"] as? String == "finish_walkthrough")
        #expect(RealtimeVoiceTutor.typedQuestionMessage("Why flies?") == "(Typed by the learner:) Why flies?")
    }

    @Test("A dropped gym-mode call replays the questions the learner typed")
    func gymResume() {
        let turns = [
            RealtimeVoiceTurn(id: "1", role: .tutor, text: "The paper asks why potential falls."),
            RealtimeVoiceTurn(id: "2", role: .learner, text: "What is membrane potential?"),
            RealtimeVoiceTurn(id: "3", role: .tutor, text: "It is the voltage across the inner membrane."),
            RealtimeVoiceTurn(id: "4", role: .learner, text: RealtimeVoiceTurn.spokenMark),
        ]
        let items = RealtimeVoiceTutor.resumeItems(from: turns)
        #expect(items.map(\.role) == ["assistant", "user", "assistant"])
        #expect(items[1].text == "(Typed by the learner:) What is membrane potential?")
        // A typed question is saved as the learner's line, with the reply after it.
        let exchanges = RealtimeVoiceExchange.exchanges(from: Array(turns.prefix(3)))
        #expect(exchanges.first?.answer == "What is membrane potential?")
        #expect(exchanges.first?.evaluation == "It is the voltage across the inner membrane.")
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
        #expect(OpenAIRealtimeWire.decodeServerEvent(["type": "input_audio_buffer.speech_stopped", "item_id": "item_1"]) == .speechStopped(itemID: "item_1"))
        #expect(OpenAIRealtimeWire.decodeServerEvent([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item_1", "transcript": "They make ATP.",
        ]) == .inputTranscriptDone(itemID: "item_1", transcript: "They make ATP."))
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

    @Test("A meeting is found by its series and a spoken day, even with the name misheard")
    func meetingBySeriesAndDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d))!
        }
        let now = day(2026, 11, 8)
        let items = [
            RealtimeVoiceLibraryItem(id: "n25", title: "2026/10/25", sourceType: "meeting", byline: nil,
                                     addedAt: day(2026, 10, 25), lastAttentionAt: nil, group: "Riverbend Group Nexus"),
            RealtimeVoiceLibraryItem(id: "n18", title: "2026/10/18", sourceType: "meeting", byline: nil,
                                     addedAt: day(2026, 10, 18), lastAttentionAt: nil, group: "Riverbend Group Nexus"),
            RealtimeVoiceLibraryItem(id: "s25", title: "Weekly sync", sourceType: "meeting", byline: nil,
                                     addedAt: day(2026, 10, 25), lastAttentionAt: nil, group: "Example Standup"),
            RealtimeVoiceLibraryItem(id: "p", title: "Nexus of Signalling", sourceType: "paper", byline: nil,
                                     addedAt: day(2026, 10, 25), lastAttentionAt: nil),
        ]
        let ranked = RealtimeVoiceLibrarySearch.rank(
            "the Riverbend group session on October 25th", in: items, now: now, calendar: calendar
        )
        #expect(ranked.first?.id == "n25")
        #expect(ranked.contains { $0.id == "n18" })
        // Heard one letter off ("riverbent"), the series still lands.
        let misheard = RealtimeVoiceLibrarySearch.rank("riverbent session 25 october", in: items, now: now, calendar: calendar)
        #expect(misheard.first?.id == "n25")
        // A paper added that day has no day of its own to match.
        #expect(!RealtimeVoiceLibrarySearch.rank("October 25", in: items, now: now, calendar: calendar).contains { $0.id == "p" })
        let output = RealtimeVoiceLibrarySearch.toolOutput([items[0]], now: now, calendar: calendar)
        #expect(output.contains(#""series":"Riverbend Group Nexus""#))
        #expect(output.contains("Sunday 25 October 2026"))
    }

    @Test("A spoken day is read from the words that name it")
    func spokenDates() {
        let date = RealtimeVoiceLibrarySearch.spokenDate(in: "quiz me on the October 25th session")
        #expect(date?.month == 10)
        #expect(date?.day == 25)
        #expect(date?.year == nil)
        #expect(date?.words == ["october", "25th"])
        #expect(RealtimeVoiceLibrarySearch.spokenDate(in: "3 Nov 2026")?.year == 2026)
        #expect(RealtimeVoiceLibrarySearch.spokenDate(in: "the March talk")?.day == nil)
        #expect(RealtimeVoiceLibrarySearch.spokenDate(in: "may I ask about mitochondria") == nil)
        #expect(RealtimeVoiceLibrarySearch.spokenDate(in: "may 4") != nil)
        #expect(RealtimeVoiceLibrarySearch.oneEditApart("land", "lund"))
        #expect(RealtimeVoiceLibrarySearch.oneEditApart("nexus", "nexs"))
        #expect(!RealtimeVoiceLibrarySearch.oneEditApart("land", "land"))
        #expect(!RealtimeVoiceLibrarySearch.oneEditApart("norm", "nexus"))
    }

    #if os(macOS)
    @Test("A meeting series is told by day and talk, and named through a merge")
    func meetingSeriesRows() {
        #expect(RealtimeVoiceReach.talkTitle("2026-10-25 - [Notes] - JC: The Rise of X - A. Speaker")
            == "JC: The Rise of X - A. Speaker")
        #expect(RealtimeVoiceReach.talkTitle("Plain title") == "Plain title")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))!
        let row = RealtimeVoiceReach.meetingSessionRow([
            "source_id": "src_1",
            "title": "2026/10/25",
            "date_added": date.timeIntervalSinceReferenceDate,
            "state": "ready",
            "artifacts": [["kind": "notes", "title": "2026-10-25 - [Notes] - Talk Title - A. Speaker"]],
        ], calendar: calendar)
        #expect(row["source_id"] as? String == "src_1")
        #expect(row["title"] as? String == "Talk Title - A. Speaker")
        #expect(row["date"] as? String == "Sunday 25 October 2026")
        #expect(row["state"] == nil)
        let groups = [
            "old": MeetingMetadata(title: "Old name", mergedIntoGroupID: "new"),
            "new": MeetingMetadata(title: "Riverbend Group Nexus"),
        ]
        #expect(MacRealtimeAssistant.Toolbox.meetingSeriesTitle("old", in: groups) == "Riverbend Group Nexus")
        #expect(MacRealtimeAssistant.Toolbox.meetingSeriesTitle(nil, in: groups) == nil)
    }

    @Test("Voice finds the app's other tools, and only ones that read")
    func appToolCatalog() {
        let catalog = MacRealtimeAssistant.Toolbox.appToolCatalog()
        #expect(!catalog.isEmpty)
        #expect(catalog.allSatisfy { MCPToolRegistry.isReadOnlyTool($0.name) })
        #expect(!catalog.contains { $0.name == "delete_source" })
        #expect(catalog.contains { $0.name == "list_notebook_sources" })
        #expect(MacRealtimeAssistant.Toolbox.findAppTools("notebook sources", catalog: catalog).contains("list_notebook_sources"))
    }

    @Test("Voice starts an audio overview with the recipe and the learner's yes, never a larger ceiling")
    func voiceAudioOverview() {
        let toolNames = MacRealtimeAssistant.Toolbox().toolDefinitions.compactMap { $0["name"] as? String }
        #expect(toolNames.contains("make_audio_overview"))

        let priced = RealtimeVoiceReach.audioOverviewArguments([
            "notebook_id": " nb_1 ",
            "focus": "Where the two papers disagree",
            "format": "critique",
            "length": "",
            "source_ids": ["src_a", " ", "src_b"],
            "approved_spend_usd": 50,
            "generate_audio": false,
        ])
        #expect(priced["notebook_id"] as? String == "nb_1")
        #expect(priced["focus"] as? String == "Where the two papers disagree")
        #expect(priced["format"] as? String == "critique")
        #expect(priced["length"] == nil)
        #expect(priced["source_ids"] as? [String] == ["src_a", "src_b"])
        #expect(priced["confirm_cost"] == nil)
        #expect(priced["approved_spend_usd"] == nil)
        #expect(priced["generate_audio"] == nil)

        let agreed = RealtimeVoiceReach.audioOverviewArguments(["notebook_id": "nb_1", "confirm_cost": true])
        #expect(agreed["confirm_cost"] as? Bool == true)
        #expect(agreed["approved_spend_usd"] == nil)
        // The iPhone's route names the default ceiling with the yes, as the
        // gateway requires; the learner's own number is never forwarded.
        let viaGateway = RealtimeVoiceReach.audioOverviewArguments(
            ["notebook_id": "nb_1", "confirm_cost": true, "approved_spend_usd": 50],
            approvingCeiling: true
        )
        #expect(viaGateway["approved_spend_usd"] as? Double == RealtimeVoiceReach.audioOverviewSpendCeilingUSD)
        #expect(RealtimeVoiceReach.audioOverviewArguments(["notebook_id": "nb_1"], approvingCeiling: true)["approved_spend_usd"] == nil)

        let instructions = RealtimeVoiceAssistant.instructions(sections: [], setting: .mac)
        #expect(instructions.contains("make_audio_overview"))
        #expect(instructions.contains("confirm_cost true"))
    }

    @Test("A background task takes the learner's request, titled, with each source once")
    func backgroundTaskRequest() {
        let request = VoiceBackgroundTasks.Request([
            "task": "  Read the October 25 group session notes and list the open questions.  ",
            "title": " ",
            "source_ids": ["src_a", " src_a ", "", "src_b"],
            "deep_research": true,
        ])
        #expect(request.task == "Read the October 25 group session notes and list the open questions.")
        #expect(request.title == "Read the October 25 group session")
        #expect(request.sourceIDs == ["src_a", "src_b"])
        #expect(request.deepResearch)
        #expect(!VoiceBackgroundTasks.Request(["task": "x", "title": "Short"]).deepResearch)
    }

    @Test("A background task with nothing to do is refused before anything starts")
    @MainActor
    func backgroundTaskEmpty() {
        let answer = VoiceBackgroundTasks.shared.start(VoiceBackgroundTasks.Request(task: "", title: "Nothing"), notify: nil)
        #expect(answer.contains("task is empty"))
        #expect(VoiceBackgroundTasks.shared.check("voice-task-missing").contains("No background task by that id"))
        #expect(VoiceBackgroundTasks.shared.stop("voice-task-missing").contains("No background task by that id"))
    }

    @Test("A finished task's conclusion is its chat's last reply, cut for voice")
    @MainActor
    func backgroundTaskConclusion() {
        let messages = [
            ReviewSessionManager.Message(role: .user, content: "Do the thing"),
            ReviewSessionManager.Message(role: .assistant, content: "First look."),
            ReviewSessionManager.Message(role: .assistant, content: "The two sessions agree on the method."),
        ]
        #expect(VoiceBackgroundTasks.conclusion(from: messages) == "The two sessions agree on the method.")
        #expect(VoiceBackgroundTasks.conclusion(from: [ReviewSessionManager.Message(role: .user, content: "Hi")]) == nil)
        let long = String(repeating: "a", count: VoiceBackgroundTasks.conclusionBudget + 10)
        let cut = VoiceBackgroundTasks.conclusion(from: [ReviewSessionManager.Message(role: .assistant, content: long)])
        #expect(cut?.hasSuffix("the whole reply is in the chat.)") == true)
    }

    @Test("Voice hears how a background task ended, except one it stopped itself")
    func backgroundTaskNotices() {
        let finished = RealtimeVoiceReach.backgroundTaskNotice(
            taskID: "voice-task-1", title: "Open questions", state: "finished",
            conclusion: "Three questions are still open.", failure: nil, stoppedByVoice: false
        )
        #expect(finished?.contains("Three questions are still open.") == true)
        #expect(finished?.contains("\u{201C}Open questions\u{201D}") == true)
        #expect(RealtimeVoiceReach.backgroundTaskNotice(
            taskID: "t", title: "x", state: "failed", conclusion: nil, failure: "Rate limited", stoppedByVoice: false
        )?.contains("Rate limited") == true)
        #expect(RealtimeVoiceReach.backgroundTaskNotice(
            taskID: "t", title: "x", state: "stopped", conclusion: nil, failure: nil, stoppedByVoice: true
        ) == nil)
        #expect(RealtimeVoiceReach.backgroundTaskNotice(
            taskID: "t", title: "x", state: "stopped", conclusion: nil, failure: nil, stoppedByVoice: false
        ) != nil)
        #expect(RealtimeVoiceReach.backgroundTaskNotice(
            taskID: "t", title: "x", state: "running", conclusion: nil, failure: nil, stoppedByVoice: false
        ) == nil)
        #expect(RealtimeVoiceReach.startedTaskID(fromStartAnswer: #"{"task_id":"voice-task-9","state":"running"}"#) == "voice-task-9")
        #expect(RealtimeVoiceReach.startedTaskID(fromStartAnswer: #"{"error":"task is empty"}"#) == nil)
        let row = RealtimeVoiceReach.backgroundTaskRow(fromCheckAnswer: #"{"task":{"task_id":"t","state":"finished"}}"#)
        #expect(row?["state"] as? String == "finished")
    }

    @Test("Voice on the Mac and the iPhone has the same reach, and the iPhone hands it to the Mac")
    func sameReachEverywhere() {
        let reach = Set(RealtimeVoiceReach.toolDefinitions.compactMap { $0["name"] as? String })
        #expect(reach == [
            "list_meetings", "get_meeting_series", "make_audio_overview", "find_app_tools", "use_app_tool",
            "start_background_task", "check_background_tasks", "stop_background_task",
        ])
        let macTools = Set(MacRealtimeAssistant.Toolbox().toolDefinitions.compactMap { $0["name"] as? String })
        #expect(reach.isSubset(of: macTools))
        for setting in [RealtimeVoiceAssistant.Setting.mac, .phone, .car] {
            let instructions = RealtimeVoiceAssistant.instructions(sections: [], setting: setting)
            #expect(instructions.contains("start_background_task"))
            #expect(instructions.contains("make_audio_overview"))
        }
        #expect(RealtimeVoiceAssistant.instructions(sections: [], setting: .phone).contains("open on their Mac"))
        #expect(!RealtimeVoiceAssistant.instructions(sections: [], setting: .mac).contains("open on their Mac"))
        #expect(RealtimeVoiceReach.useAppToolRefusal("delete_source", isReadOnly: false) != nil)
        #expect(RealtimeVoiceReach.useAppToolRefusal("generate_audio_overview", isReadOnly: true) != nil)
        #expect(RealtimeVoiceReach.useAppToolRefusal("list_notebooks", isReadOnly: true) == nil)
        #expect(MacVoiceRelayTools.names.allSatisfy { $0.hasPrefix("voice_") })
        #expect(!MacVoiceRelayTools.names.contains { MCPToolRegistry.shared.tools.map(\.name).contains($0) })
    }

    @Test("A meeting series listing is cut to day, talk and source")
    func meetingSeriesCut() {
        let raw = #"{"title":"Riverbend Group Nexus","sessions":[{"source_id":"src_1","title":"2026/10/25","state":"ready","artifacts":[{"title":"2026-10-25 - [Notes] - A Talk"}]}]}"#
        let cut = RealtimeVoiceReach.meetingSeries(fromGroupListing: raw, groupID: "g1")
        #expect(cut.contains("Riverbend Group Nexus"))
        #expect(cut.contains("A Talk"))
        #expect(!cut.contains("artifacts"))
        #expect(RealtimeVoiceReach.meetingSeries(fromGroupListing: "Error: no group", groupID: "g1") == "Error: no group")
    }
    #endif

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

    @Test("Asked to play a source, voice hands the audio to its narration and comes back from it")
    func listenToSource() {
        // The assistant has the tool and is told how to use it, everywhere.
        let macTools = Set(MacRealtimeAssistant.Toolbox().toolDefinitions.compactMap { $0["name"] as? String })
        #expect(macTools.contains(RealtimeVoiceListen.toolName))
        for setting in [RealtimeVoiceAssistant.Setting.mac, .phone, .car] {
            #expect(RealtimeVoiceAssistant.instructions(sections: [], setting: setting).contains("listen_to_source"))
        }

        // Only an answer that says starting ends the conversation.
        let made = RealtimeVoiceListen.output(.starting(title: "Mitochondria at Rest", isMade: true))
        #expect(RealtimeVoiceListen.isStarting(made))
        #expect(made.contains("Mitochondria at Rest"))
        let toMake = RealtimeVoiceListen.output(.starting(title: "Mitochondria at Rest", isMade: false))
        #expect(RealtimeVoiceListen.isStarting(toMake))
        #expect(toMake.contains("made first"))
        let priced = RealtimeVoiceListen.output(.needsPrice(title: "Mitochondria at Rest", price: "about 42¢"))
        #expect(!RealtimeVoiceListen.isStarting(priced))
        #expect(priced.contains("about 42¢"))
        #expect(priced.contains("confirm_cost"))
        let refused = RealtimeVoiceListen.output(.refused("No source with that id."))
        #expect(!RealtimeVoiceListen.isStarting(refused))
        #expect(refused.contains("No source with that id."))
        #expect(!RealtimeVoiceListen.isStarting("not json"))
        #expect(!RealtimeVoiceListen.isStarting(#"{"starting":"yes"}"#))

        // A recording is not narrated; text is.
        #expect(RealtimeVoiceListen.hasOwnAudio(sourceType: "podcast"))
        #expect(RealtimeVoiceListen.hasOwnAudio(sourceType: "Video"))
        #expect(!RealtimeVoiceListen.hasOwnAudio(sourceType: "paper"))
        #expect(!RealtimeVoiceListen.hasOwnAudio(sourceType: "book"))

        // Coming back from the narration, the assistant opens on it.
        func back(_ outcome: RealtimeVoiceAssistant.NarrationReturn.Outcome) -> String {
            RealtimeVoiceAssistant.kickoff(
                setting: .car,
                returningFrom: .init(sourceID: "s9", title: "Mitochondria at Rest", outcome: outcome)
            )
        }
        #expect(back(.finished).contains("Mitochondria at Rest"))
        #expect(back(.finished).contains("finished playing in the car"))
        #expect(back(.interrupted).contains("s9"))
        #expect(back(.interrupted).contains("listen_to_source"))
        #expect(back(.failed("The voice does not read German.")).contains("The voice does not read German."))
        #expect(!RealtimeVoiceAssistant.kickoff(
            setting: .phone,
            returningFrom: .init(sourceID: "s9", title: "Mitochondria at Rest", outcome: .finished)
        ).contains("in the car"))
        #expect(RealtimeVoiceAssistant.kickoff(setting: .car, returningFrom: nil) == RealtimeVoiceAssistant.kickoff(setting: .car))
    }

    @Test("Asked for a different voice, voice saves the pick and starts over in it")
    func changeVoice() {
        // The assistant has the tool, everywhere it runs.
        let macTools = Set(MacRealtimeAssistant.Toolbox().toolDefinitions.compactMap { $0["name"] as? String })
        #expect(macTools.contains(RealtimeVoiceChange.toolName))

        // A voice that is named is taken; none named takes the next one, and
        // the last comes round to the first.
        #expect(RealtimeVoiceChange.pick(requested: "Cedar ", current: "marin") == .changing(to: "cedar"))
        #expect(RealtimeVoiceChange.pick(requested: nil, current: "marin") == .changing(to: "cedar"))
        #expect(RealtimeVoiceChange.pick(requested: "", current: "verse") == .changing(to: "marin"))
        // The voice it already has, and one OpenAI's realtime models do not
        // speak in, change nothing.
        guard case .refused(let same) = RealtimeVoiceChange.pick(requested: "marin", current: "marin"),
              case .refused(let unknown) = RealtimeVoiceChange.pick(requested: "nova", current: "marin") else {
            Issue.record("A voice that cannot be switched to was accepted.")
            return
        }
        #expect(same.contains("already speaking as Marin"))
        #expect(unknown.contains("Cedar"))

        // Only an answer that says changing ends the conversation.
        let changing = RealtimeVoiceChange.output(.changing(to: "cedar"))
        #expect(RealtimeVoiceChange.isChanging(changing))
        #expect(changing.contains("Cedar"))
        #expect(!RealtimeVoiceChange.isChanging(RealtimeVoiceChange.output(.refused(same))))
        #expect(!RealtimeVoiceChange.isChanging(#"{"error":"Unknown tool."}"#))
        #expect(!RealtimeVoiceListen.isStarting(changing))

        // The new conversation opens on the new voice, whatever else it could open on.
        for setting in [RealtimeVoiceAssistant.Setting.mac, .phone, .car] {
            let kickoff = RealtimeVoiceAssistant.kickoff(setting: setting, voiceChangedTo: "cedar")
            #expect(kickoff.contains("Cedar"))
            #expect(kickoff.contains("how it sounds"))
        }
        #expect(RealtimeVoiceAssistant.kickoff(setting: .phone, voiceChangedTo: nil) == RealtimeVoiceAssistant.kickoff(setting: .phone))
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
        // Voice opens on the learner's own question: it never offers the cards first.
        for setting in [RealtimeVoiceAssistant.Setting.car, .phone] {
            let kickoff = RealtimeVoiceAssistant.kickoff(setting: setting)
            #expect(kickoff.contains("Do not bring up their cards"))
            #expect(!kickoff.contains("offer to go through them"))
        }
        #expect(car.contains("never bring cards up yourself"))
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
        #expect(RealtimeVoiceCardReview.deleteCardTool["name"] as? String == "delete_card")
        let deleteParameters = try #require(RealtimeVoiceCardReview.deleteCardTool["parameters"] as? [String: Any])
        #expect(deleteParameters["required"] as? [String] == ["card_id"])
        let due = RealtimeVoiceCardReview.dueCardsTool(description: "More cards.")
        #expect(due["name"] as? String == "get_due_cards")
        #expect(RealtimeVoiceCardReview.undoDeleteCardTool["name"] as? String == "undo_delete_card")
        #expect(RealtimeVoiceCardReview.cardsByDateTool()["name"] as? String == "get_cards_by_date")
    }

    @Test func cardsMadeOnADayAreFoundByDaysAgoOrDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 18)))
        #expect(RealtimeVoiceCardReview.startOfDay(daysAgo: 1, date: nil, now: now, calendar: calendar) == yesterday)
        #expect(RealtimeVoiceCardReview.startOfDay(daysAgo: nil, date: "2026-11-18", now: now, calendar: calendar) == yesterday)
        #expect(RealtimeVoiceCardReview.startOfDay(daysAgo: nil, date: "soon", now: now, calendar: calendar) == nil)
        #expect(RealtimeVoiceCardReview.startOfDay(daysAgo: nil, date: nil, now: now, calendar: calendar) == nil)

        func card(_ id: String, made: Date?) -> RealtimeVoiceCardReview.LibraryCard {
            .init(card: .init(id: id, question: "Q", answer: "A", source: nil, createdAt: made), dueToday: false)
        }
        let cards = [
            card("evening", made: yesterday.addingTimeInterval(23 * 3600)),
            card("before", made: yesterday.addingTimeInterval(-60)),
            card("today", made: now),
            card("unknown", made: nil),
        ]
        let found = RealtimeVoiceCardReview.made(cards, from: yesterday, calendar: calendar)
        #expect(found.map(\.card.id) == ["evening"])
        #expect(RealtimeVoiceCardReview.made(cards, from: yesterday, days: 2, calendar: calendar).map(\.card.id) == ["evening", "today"])
        let output = RealtimeVoiceCardReview.searchOutput(found, limit: 10)
        #expect(output.contains("2026-11-18") || output.contains("made_on"))
        #expect(RealtimeVoiceCardReview.searchOutput(found, limit: 10, offset: 5).contains("Nothing is left"))
    }
}

/// Voice mode on the learner's own OpenAI key (product owner, 2026-11-08):
/// the key check, the mint body the app sends OpenAI itself, and the list
/// price the Mac records an own-key reply at.
@Suite("Realtime voice on the learner's own OpenAI key")
struct RealtimeVoiceOwnKeyTests {
    @Test("OpenAI's answer about a key: 2xx accepts, 401/403 rejects, anything else says nothing")
    func keyCheck() {
        #expect(ManagedAI.ownOpenAIVoiceKeyCheckResult(statusCode: 200) == .accepted)
        if case .rejected(let reason) = ManagedAI.ownOpenAIVoiceKeyCheckResult(statusCode: 401) {
            #expect(reason.contains("OpenAI"))
        } else {
            Issue.record("401 should reject the key")
        }
        #expect(ManagedAI.ownOpenAIVoiceKeyCheckResult(statusCode: 403) != .accepted)
        #expect(ManagedAI.ownOpenAIVoiceKeyCheckResult(statusCode: 429) == nil)
        #expect(ManagedAI.ownOpenAIVoiceKeyCheckResult(statusCode: 500) == nil)
    }

    @Test("The mint body is the proxy's: the app's session under type and model, a two-minute secret")
    func mintBody() throws {
        let body = ManagedAI.ownKeyRealtimeMintBody(
            model: "gpt-realtime-2.1",
            session: ["instructions": "Be brief.", "type": "transcription", "model": "other"]
        )
        let session = try #require(body["session"] as? [String: Any])
        #expect(session["type"] as? String == "realtime")
        #expect(session["model"] as? String == "gpt-realtime-2.1")
        #expect(session["instructions"] as? String == "Be brief.")
        let expiry = try #require(body["expires_after"] as? [String: Any])
        #expect(expiry["anchor"] as? String == "created_at")
        #expect(expiry["seconds"] as? Int == 120)
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test("A reply's list price matches the proxy's rates, and an unknown model has none")
    func listCost() throws {
        // A usage with no tokens is no usage (the initializer returns nil), so
        // the reply is built from the payload `response.done` carries.
        let usage = try #require(RealtimeVoiceUsage(responseID: "resp_1", usage: [
            "input_token_details": ["text_tokens": 1_000_000],
            "output_token_details": ["audio_tokens": 1_000_000],
        ]))
        #expect(usage.textInputTokens == 1_000_000)
        #expect(usage.audioOutputTokens == 1_000_000)
        #expect(usage.totalTokens == 2_000_000)
        #expect(abs(try #require(usage.listCostUSD(model: "gpt-realtime-2.1")) - 68) < 1e-9)
        #expect(abs(try #require(usage.listCostUSD(model: "gpt-realtime-2.1-mini")) - 20.6) < 1e-9)
        #expect(usage.listCostUSD(model: "not-a-voice-model") == nil)
    }

    @Test("With no key stored, voice keeps ForeverLM's route")
    func noKeyNoDirectRoute() {
        ManagedAI.ownOpenAIVoiceKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownOpenAIVoiceKeyOverrideForTesting = nil }
        #expect(ManagedAI.ownOpenAIVoiceKey == nil)
        #expect(ManagedAI.ownOpenAIVoiceKeySuffix == nil)
        ManagedAI.ownOpenAIVoiceKeyOverrideForTesting = .some("sk-test-abcd1234")
        #expect(ManagedAI.ownOpenAIVoiceKeySuffix == "1234")
    }
}

@Suite("Voice card library search")
struct RealtimeVoiceCardLibraryTests {
    private func entry(_ id: String, _ q: String, _ a: String, _ source: String?, due: Bool = false) -> RealtimeVoiceCardReview.LibraryCard {
        .init(card: .init(id: id, question: q, answer: a, source: source), dueToday: due)
    }

    @Test("search needs every word, in the question, answer or source title, ignoring case and accents")
    func searchMatches() {
        let cards = [
            entry("a", "What does PINK1 do?", "It marks damaged mitochondria", "Mitophagy review"),
            entry("b", "Where is Parkin recruited?", "Onto the outer membrane", "Mitophagy review"),
            entry("c", "Capital of France?", "Paris", "Géographie"),
        ]
        #expect(RealtimeVoiceCardReview.search(cards, query: "pink1").map(\.card.id) == ["a"])
        #expect(RealtimeVoiceCardReview.search(cards, query: "MITOPHAGY membrane").map(\.card.id) == ["b"])
        #expect(RealtimeVoiceCardReview.search(cards, query: "geographie").map(\.card.id) == ["c"])
        #expect(RealtimeVoiceCardReview.search(cards, query: "  ").count == 3)
    }

    @Test("topics count cards per source, biggest first")
    func topicsCount() {
        let cards = [entry("a", "q", "a", "Big"), entry("b", "q", "a", "Big"), entry("c", "q", "a", "Small"), entry("d", "q", "a", nil)]
        let topics = RealtimeVoiceCardReview.topics(cards)
        #expect(topics.first?.title == "Big")
        #expect(topics.first?.count == 2)
        #expect(topics.map(\.title).contains("Other cards"))
    }
}
