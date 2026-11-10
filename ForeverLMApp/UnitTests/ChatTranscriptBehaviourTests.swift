// Chat transcript, stop, request order and stalled stream tests.

import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

@Suite("Source link page anchor")
struct SourceLinkPageAnchorTests {
    @Test("A positive whole number is a page; anything else is none")
    func pageValues() {
        #expect(SourceLinkPageAnchor.page(from: "7") == 7)
        #expect(SourceLinkPageAnchor.page(from: " 12 ") == 12)
        #expect(SourceLinkPageAnchor.page(from: "0") == nil)
        #expect(SourceLinkPageAnchor.page(from: "-3") == nil)
        #expect(SourceLinkPageAnchor.page(from: "7.5") == nil)
        #expect(SourceLinkPageAnchor.page(from: "p7") == nil)
        #expect(SourceLinkPageAnchor.page(from: "") == nil)
        #expect(SourceLinkPageAnchor.page(from: nil) == nil)
    }

    @Test("A citation link carries its page beside the excerpt, and a plain link carries none")
    func linkCarriesPage() throws {
        let paged = try #require(URL(string: "foreverlm://source/src_abc?page=7&q=the+large+negative+value"))
        let link = try #require(ChatMarkdownView.sourceLink(from: paged))
        #expect(link.sourceID == "src_abc")
        #expect(link.page == 7)
        #expect(link.passage == "the large negative value")
        #expect(link.seconds == nil)

        let plain = try #require(URL(string: "foreverlm://source/src_abc"))
        #expect(ChatMarkdownView.sourceLink(from: plain)?.page == nil)

        let timed = try #require(URL(string: "foreverlm://source/src_abc?t=754"))
        let timedLink = try #require(ChatMarkdownView.sourceLink(from: timed))
        #expect(timedLink.seconds == 754)
        #expect(timedLink.page == nil)
    }

    @Test("A PDF's form feeds become numbered page lines for the model; text without them is untouched")
    func pageMarkers() {
        let stored = "First page text.\u{000C}812 Chapter 14\nSecond page text.\u{000C}Third."
        let labeled = PDFPageMarkers.labeled(stored)
        #expect(labeled == "[page 1]\n\nFirst page text.\n\n[page 2]\n\n812 Chapter 14\nSecond page text.\n\n[page 3]\n\nThird.")
        #expect(!labeled.contains("\u{000C}"))

        let article = "No pages here.\n\nJust paragraphs."
        #expect(PDFPageMarkers.labeled(article) == article)
    }

    @Test("A reader passage target may name only a page")
    @MainActor
    func pageOnlyTarget() {
        let vm = StudioViewModel(storageService: StorageService(storeRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("PageAnchor_\(UUID().uuidString)")))
        vm.requestReaderPassage(nil, page: 4, for: "src_x")
        #expect(vm.readerPassageTarget?.passage == nil)
        #expect(vm.readerPassageTarget?.page == 4)

        vm.requestReaderPassage("  ", page: 0, for: "src_y")
        #expect(vm.readerPassageTarget?.sourceID == "src_x")

        vm.requestReaderPassage("some words", page: 9, for: "src_z")
        #expect(vm.readerPassageTarget?.passage == "some words")
        #expect(vm.readerPassageTarget?.page == 9)
    }
}

@Suite("Model picker opens upward")
struct UpwardMenuAnchorTests {
    /// The composer sits at the foot of the chat, so the model menu's bottom
    /// edge goes just above the chip: in a flipped view (y grows down) the
    /// menu's top-left is its height plus the gap above the chip's top.
    @Test("The menu's top-left puts its bottom edge just above the chip")
    func menuEndsAboveTheChip() {
        let chip = NSRect(x: 0, y: 0, width: 120, height: 24)
        let gap = UpwardMenuAnchor.gap
        let flipped = UpwardMenuAnchor.origin(in: chip, isFlipped: true, menuHeight: 342)
        #expect(flipped == NSPoint(x: 0, y: -(gap + 342)))
        let unflipped = UpwardMenuAnchor.origin(in: chip, isFlipped: false, menuHeight: 342)
        #expect(unflipped == NSPoint(x: 0, y: 24 + gap + 342))
    }

    @Test("A press of the picker's key opens one chip's menu, however many chats are listening")
    @MainActor
    func oneChipClaimsAKeyPress() {
        let press = UUID()
        #expect(UpwardMenuAnchor.claim(press))
        #expect(!UpwardMenuAnchor.claim(press))
        #expect(UpwardMenuAnchor.claim(UUID()))
    }
}

/// The model chip leads with Recent models, as Codex's picker does.
@Suite("Recent chat models")
struct ChatRecentModelsTests {
    typealias Entry = ChatRecentModels.Entry

    @Test("A pick goes to the head, replaces its model's older row, and the list stays short")
    func newestFirstOnePerModel() {
        let a = Entry(provider: "openRouter", model: "lab/a", effort: "high")
        let b = Entry(provider: "openRouter", model: "lab/b", effort: nil)
        var list = ChatRecentModels.adding(a, to: [])
        list = ChatRecentModels.adding(b, to: list)
        #expect(list == [b, a])
        let aLow = Entry(provider: "openRouter", model: "lab/a", effort: "low")
        list = ChatRecentModels.adding(aLow, to: list)
        #expect(list == [aLow, b])
        for index in 0..<10 {
            list = ChatRecentModels.adding(Entry(provider: "openRouter", model: "lab/m\(index)", effort: nil), to: list)
        }
        #expect(list.count == ChatRecentModels.limit)
        #expect(list.first?.model == "lab/m9")
    }

    @Test("Recorded picks survive a relaunch in this Mac's defaults")
    func recordsAndLoads() throws {
        let suite = "ChatRecentModelsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ChatRecentModels.load(defaults: defaults).isEmpty)
        let entry = Entry(provider: "openRouter", model: "lab/a", effort: "medium")
        ChatRecentModels.record(entry, defaults: defaults)
        ChatRecentModels.record(Entry(provider: "openRouter", model: "lab/b", effort: nil), defaults: defaults)
        #expect(ChatRecentModels.load(defaults: defaults).map(\.model) == ["lab/b", "lab/a"])
        defaults.set(Data("not json".utf8), forKey: ChatRecentModels.defaultsKey)
        #expect(ChatRecentModels.load(defaults: defaults).isEmpty)
    }
}

/// 2026-09-25: a chat asked to add one compound to a Site called save_site,
/// publish_site and read_site_file some sixty times, each refused with the
/// same sentence, and every refused row read "Saved site".
@Suite("Repeated tool refusals")
struct RepeatedToolRefusalTests {
    typealias Refusals = ReviewSessionManager.RepeatedToolRefusals
    typealias Result = ReviewSessionManager.AppToolResult

    @Test("A failed row says it failed, in the tool's own words")
    @MainActor
    func failedRowsSayTheyFailed() {
        var activity = ReviewSessionManager.Message.ToolActivity(
            toolName: "save_site", detail: nil, state: .succeeded, resultPreview: nil
        )
        #expect(activity.title == "Saved site")
        activity.state = .running
        #expect(activity.title == "Saved site")
        activity.state = .failed
        #expect(activity.title == "Couldn't save site")
        typealias Activity = ReviewSessionManager.Message.ToolActivity
        #expect(Activity.failedTitle(fromDoneTitle: "Read site file") == "Couldn't read site file")
        #expect(Activity.failedTitle(fromDoneTitle: "Wrote walkthrough") == "Couldn't write walkthrough")
        #expect(Activity.failedTitle(fromDoneTitle: "Opened in Browser") == "Couldn't open in Browser")
        #expect(Activity.failedTitle(fromDoneTitle: "Clicked") == "Couldn't click")
        #expect(Activity.failedTitle(fromDoneTitle: "some_new_tool") == "some_new_tool failed")
    }

    @Test("The third identical refusal tells the model to stop, whichever tool gave it")
    @MainActor
    func thirdRefusalStops() {
        var refusals = Refusals()
        let refusal = "Error: ‘Atlas’ has no file companies.html. Its files: index.html."
        #expect(refusals.record(toolName: "save_site", result: Result(text: refusal, isError: true)) == refusal)
        let respaced = "error:  ‘atlas’ has no file companies.html. its files: index.html."
        #expect(refusals.record(toolName: "read_site_file", result: Result(text: respaced, isError: true)) == respaced)
        #expect(refusals.withheldResult(for: "save_site") == nil, "two refusals are not yet a loop")
        let third = refusals.record(toolName: "replace_site_text", result: Result(text: refusal, isError: true))
        #expect(third.hasPrefix(refusal))
        #expect(third.contains("read_site_file, replace_site_text, save_site will not be run again"), "case and spacing did not make the second a new refusal")

        // Every tool that gave it is withheld; others still run.
        let withheld = refusals.withheldResult(for: "read_site_file")
        #expect(withheld?.isError == true)
        #expect(withheld?.text.contains("‘Atlas’ has no file") == true)
        #expect(refusals.withheldResult(for: "list_docs") == nil)
        #expect(refusals.exhaustedRefusal == nil)
        _ = refusals.withheldResult(for: "save_site")
        _ = refusals.withheldResult(for: "replace_site_text")
        #expect(refusals.exhaustedRefusal?.hasPrefix("‘Atlas’ has no file") == true, "three withheld calls end the turn")
    }

    @Test("Successes and different refusals do not count toward a stop")
    @MainActor
    func differentRefusalsDoNotStop() {
        var refusals = Refusals()
        for handle in ["atlas", "mitochondria", "3a7be032"] {
            let text = "No site of yours is named \(handle)."
            #expect(refusals.record(toolName: "save_site", result: Result(text: text, isError: true)) == text)
        }
        for _ in 0..<5 {
            _ = refusals.record(toolName: "list_docs", result: Result(text: "[]", isError: false))
        }
        #expect(refusals.withheldResult(for: "save_site") == nil)
        #expect(refusals.withheldResult(for: "list_docs") == nil)
        #expect(refusals.exhaustedRefusal == nil)
    }

    @Test("The stop is not read as the provider rejecting native tools")
    @MainActor
    func stopIsNotANativeToolRejection() {
        let stop = Refusals.Stopped(refusal: "ForeverLM app tools are not available in this Chat surface.")
        #expect(!AINativeToolSupport.isNativeToolRejection(stop))
        #expect(stop.localizedDescription.contains("kept retrying a tool that refused the same way"))
    }
}

/// Stop ends a turn at once whatever the turn is waiting on (2026-09-27: Stop
/// in a quiz's chat did nothing for two minutes). Nothing here is timed: the
/// stand-in tool runs until the test lets it go, so a wait that ended while it
/// still ran ended without it.
@Suite("Chat Stop ends the wait")
@MainActor
struct ChatStopEndsTheWaitTests {
    /// A tool that takes no notice of cancellation: it says when it has
    /// started, then runs until `release`, cancelled or not.
    private final class StubbornTool: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        var isReleased: Bool { lock.withLock { released } }

        func run() async {
            let starters: [CheckedContinuation<Void, Never>] = lock.withLock {
                started = true
                defer { startWaiters = [] }
                return startWaiters
            }
            starters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                let now: Bool = lock.withLock {
                    if released { return true }
                    releaseWaiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func untilStarted() async {
            await withCheckedContinuation { continuation in
                let now: Bool = lock.withLock {
                    if started { return true }
                    startWaiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func release() {
            let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
                released = true
                defer { releaseWaiters = [] }
                return releaseWaiters
            }
            waiting.forEach { $0.resume() }
        }
    }

    /// Lets the tool go after a while, so a wait that never ends fails the
    /// test instead of hanging the run.
    private func releasing(_ tool: StubbornTool) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            tool.release()
        }
    }

    @Test("Stop ends an app tool call whose tool takes no notice of it")
    func stopEndsAStubbornToolCall() async {
        let tool = StubbornTool()
        let safety = releasing(tool)
        defer { safety.cancel(); tool.release() }
        let call = Task { @MainActor in
            try await ReviewSessionManager.runAppToolCall(
                name: "import_paper_from_url",
                arguments: ["url": "https://example.org/paper"],
                hostSessionID: "chat-1",
                watchdogSeconds: 300
            ) { _, _, _ in
                await tool.run()
                return ReviewSessionManager.AppToolResult(text: "imported", isError: false)
            }
        }
        await tool.untilStarted()
        call.cancel()
        let result = await call.result
        #expect(!tool.isReleased, "the wait lasted as long as the tool")
        guard case .failure(let error) = result else {
            Issue.record("a stopped call returned \(result)")
            return
        }
        #expect(error is CancellationError)
    }

    @Test("The watchdog gives up on a tool that runs past it, without waiting for it")
    func watchdogAbandonsAStubbornTool() async throws {
        let tool = StubbornTool()
        let safety = releasing(tool)
        defer { safety.cancel(); tool.release() }
        let result = try await ReviewSessionManager.runAppToolCall(
            name: "transcribe_meeting_recording",
            arguments: [:],
            hostSessionID: nil,
            watchdogSeconds: 0.2
        ) { _, _, _ in
            await tool.run()
            return ReviewSessionManager.AppToolResult(text: "transcribed", isError: false)
        }
        #expect(!tool.isReleased, "the watchdog waited for the tool")
        #expect(result.isError)
        #expect(result.text.contains("transcribe_meeting_recording tool call timed out"))
    }

    @Test("A tool that answers in time is answered, with the chat's arguments")
    func toolThatAnswersIsAnswered() async throws {
        let result = try await ReviewSessionManager.runAppToolCall(
            name: "list_sources",
            arguments: ["limit": 3],
            hostSessionID: "chat-2",
            watchdogSeconds: 300
        ) { name, arguments, session in
            ReviewSessionManager.AppToolResult(
                text: "\(name) \(arguments["limit"] as? Int ?? 0) \(session ?? "-")",
                isError: false
            )
        }
        #expect(result.text == "list_sources 3 chat-2")
        #expect(!result.isError)
    }

    @Test("Work a stopped caller left behind is cancelled, and a caller stopped before it waits never waits")
    func abandonedWorkIsCancelled() async {
        let tool = StubbornTool()
        let safety = releasing(tool)
        defer { safety.cancel(); tool.release() }
        let sawCancel = AsyncStream<Bool>.makeStream()
        let call = Task {
            try await CancellableWait.run {
                await tool.run()
                sawCancel.continuation.yield(Task.isCancelled)
                sawCancel.continuation.finish()
                return "done"
            }
        }
        await tool.untilStarted()
        call.cancel()
        _ = await call.result
        #expect(!tool.isReleased)
        tool.release()
        var iterator = sawCancel.stream.makeAsyncIterator()
        let workSawCancel = await iterator.next()
        #expect(workSawCancel == true)

        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CancellableWait.run { "never needed" }
        }
        guard case .failure(let error) = await early.result else {
            Issue.record("an already-stopped caller waited")
            return
        }
        #expect(error is CancellationError)
    }
}

/// Every Claude since 4.6 refuses a request that ends on the assistant's own
/// words ("does not support assistant message prefill", 400), and a request may
/// be served by another model than the one it names, so no request ends there.
@Suite("Requests end on a turn the model answers")
struct ChatRequestTurnOrderTests {
    @Test("A closing assistant message is answered with a user turn")
    func closingAssistantMessageGetsAUserTurn() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "You tutor."],
            ["role": "user", "content": "What do cristae do?"],
            ["role": "assistant", "content": "They fold the inner membrane"],
        ]
        let sent = ChatRequestTurnOrder.endingOnAnswerableTurn(messages)
        #expect(sent.count == 4)
        #expect(sent.last?["role"] as? String == "user")
        #expect(sent.last?["content"] as? String == ChatRequestTurnOrder.continueInstruction)
    }

    @Test("A trailing system message does not hide a closing assistant message")
    func trailingSystemMessageIsSkipped() {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Grade me."],
            ["role": "assistant", "content": "Graded."],
            ["role": "system", "content": "Ask the next question."],
        ]
        let sent = ChatRequestTurnOrder.endingOnAnswerableTurn(messages)
        #expect(sent.last?["role"] as? String == "user")
    }

    @Test("A request that already ends on the learner or a tool is sent as it is")
    func answerableEndingsAreUntouched() {
        let user: [[String: Any]] = [["role": "user", "content": "Hello"]]
        #expect(ChatRequestTurnOrder.endingOnAnswerableTurn(user).count == 1)
        let toolRound: [[String: Any]] = [
            ["role": "user", "content": "Find it."],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "type": "function"]]],
            ["role": "tool", "tool_call_id": "c1", "content": "found"],
        ]
        #expect(ChatRequestTurnOrder.endingOnAnswerableTurn(toolRound).count == 3)
        let pendingCalls: [[String: Any]] = [
            ["role": "user", "content": "Find it."],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "type": "function"]]],
        ]
        #expect(ChatRequestTurnOrder.endingOnAnswerableTurn(pendingCalls).count == 2)
    }

    @Test("Every Mac OpenRouter body ends on a user turn")
    func macOpenRouterBodyEndsOnAUserTurn() {
        var payload: [String: Any] = [
            "model": "anthropic/claude-opus-5.5",
            "messages": [
                ["role": "system", "content": "You tutor."],
                ["role": "user", "content": "Quiz me."],
                ["role": "assistant", "content": "Here is your next question"],
            ] as [[String: Any]],
        ]
        AIService.applyOpenRouterPayloadExtras(&payload, provider: .openRouter)
        let messages = payload["messages"] as? [[String: Any]] ?? []
        #expect(messages.last?["role"] as? String == "user")
    }

    @Test("The phone's OpenRouter body ends on a user turn")
    func phoneOpenRouterBodyEndsOnAUserTurn() throws {
        let route = ResolvedAITextRoute(task: .chat, provider: "OpenRouter", model: "anthropic/claude-opus-5.5")
        let request = try MobileOpenRouterChat.request(
            route: route,
            system: "You tutor.",
            messages: [
                (role: "assistant", content: "What do cristae do?"),
                (role: "user", content: "They fold the membrane."),
                (role: "assistant", content: "Right."),
            ],
            maxTokens: 256
        )
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect(messages.last?["role"] as? String == "user")
    }

    @Test("The phone pins Claude and GPT on the learner's own OpenRouter key to their lab's endpoint, so the lab key pays")
    func phoneOwnKeyLabModelsRunOnTheirLabEndpoint() throws {
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        func routing(_ route: ResolvedAITextRoute) throws -> [String: Any] {
            let request = try MobileOpenRouterChat.request(
                route: route,
                system: "You prepare text to be read aloud.",
                messages: [(role: "user", content: "Mitochondria divide by fission.")],
                maxTokens: 256
            )
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return body["provider"] as? [String: Any] ?? [:]
        }
        func route(_ model: String) -> ResolvedAITextRoute {
            ResolvedAITextRoute(task: .paperTextToSpeechPreparation, provider: "OpenRouter", model: model)
        }

        ManagedAI.ownKeyOverrideForTesting = .some(ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key"))
        let gpt = try routing(route("openai/gpt-5.6-luna"))
        #expect(gpt["order"] as? [String] == ["openai"])
        #expect(gpt["allow_fallbacks"] as? Bool == false)
        #expect(gpt["sort"] == nil)
        #expect(try routing(route("anthropic/claude-opus-5.5"))["order"] as? [String] == ["anthropic"])

        // Open weights and other labs' models keep the throughput route.
        for model in ["openai/gpt-oss-120b", "openai/gpt-5.6-luna:nitro", "deepseek/deepseek-v4-flash"] {
            let other = try routing(route(model))
            #expect(other["order"] == nil)
            #expect(other["sort"] as? String == "throughput")
        }

        // A model kept in one region runs on that region's endpoints.
        let confined = try routing(route("openai/gpt-5.6-luna").confined(to: ["azure/us"]))
        #expect(confined["order"] == nil)
        #expect(confined["only"] as? [String] == ["azure/us"])

        // A call ForeverLM pays for goes through the proxy, which pins it there.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        #expect(try routing(route("openai/gpt-5.6-luna"))["order"] == nil)
    }

    @Test("Retry leaves the failed attempt's words out of the request")
    @MainActor func retryLeavesTheFailedAttemptOut() {
        typealias Message = ReviewSessionManager.Message
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var cutOff = Message(role: .assistant, content: "Mitochondrial uncouplers work by", createdAt: start.addingTimeInterval(4))
        cutOff.isFromFailedAttempt = true
        let history = [
            Message(role: .user, content: "Explain uncouplers.", createdAt: start),
            cutOff,
        ]
        let sent = ReviewSessionManager.providerMessagesForTesting(from: history)
        #expect(sent.map(\.role) == ["user"])
    }

    @Test("A safety decline says the model declined, not that the provider stopped")
    func safetyDeclineIsNamed() {
        for reason in ["refusal", "content_filter"] {
            do {
                try AICompletionStopValidator.throwIfStoppedAbnormally(["finish_reason": reason])
                Issue.record("\(reason) passed as a normal stop")
            } catch {
                #expect(error.localizedDescription.contains("declined"))
            }
        }
    }
}

// MARK: - One-page transcript

@Suite("One-page chat transcript")
struct ChatTranscriptPageTests {
    private static func search(_ state: ReviewSessionManager.Message.ToolActivity.State = .succeeded)
        -> ReviewSessionManager.Message.ToolActivity {
        ReviewSessionManager.Message.ToolActivity(
            toolName: "search_sources_semantic", detail: "q", state: state, resultPreview: "Line one"
        )
    }

    private static let thinking = ReviewSessionManager.Message.ToolActivity(
        kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
        resultPreview: nil, reasoning: "First thought.\n\nSecond thought.", thinkingDuration: 8
    )

    @MainActor
    private static func plainChat(extraStep: ReviewSessionManager.Message.ToolActivity? = nil) -> [ReviewSessionManager.Message] {
        var messages = [
            ReviewSessionManager.Message(role: .user, content: "What did the meeting conclude?"),
            ReviewSessionManager.Message(role: .assistant, content: "", toolActivity: thinking),
            ReviewSessionManager.Message(role: .tool, content: "", toolActivity: search()),
        ]
        if let extraStep {
            messages.append(ReviewSessionManager.Message(role: .tool, content: "", toolActivity: extraStep))
        }
        messages.append(ReviewSessionManager.Message(role: .assistant, content: "## The question\n\nIt stayed open."))
        return messages
    }

    @Test("A question with a picture shows the picture over its words, and the words alone in the bubble")
    @MainActor
    func attachedPicturesRideAboveTheWords() throws {
        let picture = "foreverlm://image/attached/0F1E2D3C-4B5A-4C6D-8E7F-0A1B2C3D4E5F"
        let message = ReviewSessionManager.Message(role: .user, content: "What is this?\n\n![figure](\(picture))")
        let blocks = ReviewChatTranscriptBlock.grouping([message])
        let user = ChatTranscriptPage.userBlock(blocks[0], message: try #require(blocks.first?.userMessage), canEdit: false, isFindMatch: false)
        #expect(user.text == "What is this?")
        #expect(user.images?.contains(picture) == true)

        // A message that was only the picture has no bubble.
        let only = ReviewSessionManager.Message(role: .user, content: "![figure](\(picture))")
        let onlyBlocks = ReviewChatTranscriptBlock.grouping([only])
        let pictureOnly = ChatTranscriptPage.userBlock(onlyBlocks[0], message: only, canEdit: false, isFindMatch: false)
        #expect(pictureOnly.text == nil)
        #expect(pictureOnly.images != nil)
    }

    @Test("A browser step's picture and a missing plugin ride the reply's steps")
    @MainActor
    func workCarriesBrowserPreviewAndSetup() {
        var browser = ReviewSessionManager.Message.ToolActivity(
            toolName: "browser_open", detail: "https://example.com", state: .succeeded, resultPreview: nil
        )
        browser.previewImage = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let work = ReviewChatWork(
            id: UUID(),
            steps: [Self.search(), browser],
            pages: [ChatWrittenPage(id: "page-1", title: "Notes")],
            duration: 12,
            answerHasBegun: true
        )
        let part = ChatTranscriptPage.workPart(work, isLive: false) { page in "Now: \(page.title)" }
        #expect(part.previewStep == 1)
        #expect(part.preview?.hasPrefix("data:image/png;base64,") == true)
        #expect(part.pages == [ChatTranscriptPage.PageCard(id: "page-1", title: "Now: Notes")])
        #expect(part.setup == nil)
    }

    @Test("Sources added before a message read as one line that opens onto their names")
    @MainActor
    func addedSourcesSummarise() {
        #expect(ChatTranscriptPage.added([]) == nil)
        let added = ChatTranscriptPage.added([
            ChatContextAdditions.Source(id: "a", title: "", type: "article"),
        ])
        #expect(added?.sources.first?.title == "Untitled source")
    }

    @Test("A reply becomes its steps and its prose, a question its words")
    @MainActor
    func blocksCarryWhatTheNativeRowsShow() throws {
        let messages = Self.plainChat()
        let blocks = ReviewChatTranscriptBlock.grouping(messages)
        #expect(blocks.count == 2)
        let question = try #require(blocks.first?.userMessage)
        let user = ChatTranscriptPage.userBlock(blocks[0], message: question, canEdit: true, isFindMatch: false)
        #expect(user.kind == .user)
        #expect(user.text == "What did the meeting conclude?")
        #expect(user.canEdit == true)
        #expect(user.collapses == nil)

        let items = ReviewChatAnswerLayout.items(blocks[1].answerMessages)
        guard case .work(let work) = items.first, case .entry(let entry) = items.last,
              let reply = entry.message else {
            Issue.record("expected the steps, then the reply")
            return
        }
        let settled = ChatTranscriptPage.workPart(work, isLive: false)
        #expect(settled.kind == .work)
        #expect(settled.settled == true)
        #expect(settled.opensWhileLive == false)
        #expect(settled.steps?.map(\.kind) == ["thinking", "tool"])
        #expect(settled.steps?.first?.paragraphs == ["First thought.", "Second thought."])
        #expect(settled.steps?.last?.summary == "1 line of output")

        let working = ChatTranscriptPage.workPart(work, isLive: true)
        // The answer has begun under these steps, so they are done even live.
        #expect(working.title == settled.title)

        let prose = try #require(ChatTranscriptPage.prosePart(reply, citations: .init()))
        #expect(prose.markdown == "## The question\n\nIt stayed open.")
        #expect(prose.citations == nil)
        #expect(prose.webSources == nil)
    }

    @Test("A long paste folds on the page as it does in the native bubble")
    @MainActor
    func longPasteFolds() throws {
        let paste = (1...40).map { "Line \($0) of a pasted log." }.joined(separator: "\n")
        let messages = [ReviewSessionManager.Message(role: .user, content: paste)]
        let blocks = ReviewChatTranscriptBlock.grouping(messages)
        let message = try #require(blocks.first?.userMessage)
        let user = ChatTranscriptPage.userBlock(blocks[0], message: message, canEdit: false, isFindMatch: true)
        #expect(user.collapses == true)
        #expect(user.canEdit == nil)
        #expect(user.isFindMatch == true)
    }
}

/// A provider that answered a chat with a 408 and then held the body open sent
/// the chat into eleven minutes of "Thinking" (2026-11-08): URLSession hands
/// over no response until its first body byte, and the AI session has no idle
/// deadline. A stream now fails as timed out when nothing arrives in time, and
/// an error body that never ends is reported by its status.
@Suite("A stream that stalls", .serialized)
struct StalledErrorBodyStreamTests {
    @Test("A stream that sends nothing fails as a retryable timeout once the first-byte limit runs out", .timeLimit(.minutes(1)))
    func silentStreamTimesOut() async throws {
        StalledErrorBodyURLProtocol.reset(reply: .nothing)
        let service = AIService(session: StalledErrorBodyURLProtocol.mockSession())
        let request = URLRequest(url: URL(string: "https://router.example.test/v1/chat/completions")!)

        let started = ContinuousClock.now
        let error = await #expect(throws: AIError.self) {
            try await service.streamSSE(
                request: request,
                firstByteLimit: .milliseconds(200),
                onEvent: { _ in nil },
                onDelta: { _ in }
            )
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        guard case .apiError(let message)? = error else {
            Issue.record("Expected a timeout, got \(String(describing: error))")
            return
        }
        #expect(message.contains("timed out"))
        // The chat retries a timeout; that is what ends the endless "Thinking".
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError(message)))
        // The held request was cancelled, not left open on the connection.
        try await StalledErrorBodyURLProtocol.waitUntilStopped()
    }

    @Test("Stopping a stream that has sent nothing reads as a stop, not a timeout", .timeLimit(.minutes(1)))
    func stoppingASilentStreamIsNotATimeout() async throws {
        StalledErrorBodyURLProtocol.reset(reply: .nothing)
        let service = AIService(session: StalledErrorBodyURLProtocol.mockSession())
        let request = URLRequest(url: URL(string: "https://router.example.test/v1/chat/completions")!)

        let turn = Task {
            try await service.streamSSE(
                request: request,
                firstByteLimit: .seconds(30),
                onEvent: { _ in nil },
                onDelta: { _ in }
            )
        }
        try await StalledErrorBodyURLProtocol.waitUntilStarted()
        turn.cancel()
        do {
            try await turn.value
            Issue.record("A stopped stream returned as if it had answered")
        } catch {
            #expect(!error.localizedDescription.contains("timed out"))
        }
    }

    @Test("A 408 whose body never ends fails with its status once the read limit runs out", .timeLimit(.minutes(1)))
    func stalledErrorBodyFailsWithItsStatus() async throws {
        StalledErrorBodyURLProtocol.reset(reply: .heldBody)
        let service = AIService(session: StalledErrorBodyURLProtocol.mockSession())
        var request = URLRequest(url: URL(string: "https://router.example.test/v1/chat/completions")!)
        request.httpMethod = "POST"

        let started = ContinuousClock.now
        do {
            try await service.streamSSE(
                request: request,
                errorBodyReadLimit: .milliseconds(200),
                onEvent: { _ in nil },
                onDelta: { _ in }
            )
            Issue.record("A 408 stream returned as if it had answered")
        } catch let error as AIError {
            guard case .httpError(let status, let message, _) = error else {
                Issue.record("Expected the HTTP status, got \(error)")
                return
            }
            #expect(status == 408)
            #expect(message.contains("(408)"))
            // A 408 is retried, which is the whole point of failing promptly.
            #expect(AITransientErrorClassifier.isTransient(error))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        // The held request was cancelled, not left open on the connection.
        try await StalledErrorBodyURLProtocol.waitUntilStopped()
    }

    @Test("An error body that arrives in time is still read as the provider's message", .timeLimit(.minutes(1)))
    func finishedErrorBodyKeepsTheProvidersMessage() async throws {
        StalledErrorBodyURLProtocol.reset(reply: .body(#"{"error":{"message":"Upstream model took too long"}}"#))
        let service = AIService(session: StalledErrorBodyURLProtocol.mockSession())
        let request = URLRequest(url: URL(string: "https://router.example.test/v1/chat/completions")!)

        let error = await #expect(throws: AIError.self) {
            try await service.streamSSE(
                request: request,
                errorBodyReadLimit: .seconds(5),
                onEvent: { _ in nil },
                onDelta: { _ in }
            )
        }
        guard case .httpError(let status, let message, _)? = error else {
            Issue.record("Expected the HTTP status, got \(String(describing: error))")
            return
        }
        #expect(status == 408)
        #expect(message.contains("Upstream model took too long"))
    }
}

/// Stands in for a provider that stalls: it says nothing at all, or answers
/// with a 408 whose body it holds open, or a 408 with a body it finishes.
private final class StalledErrorBodyURLProtocol: URLProtocol {
    enum Reply {
        case nothing
        case heldBody
        case body(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = Reply.nothing
    nonisolated(unsafe) private static var started = 0
    nonisolated(unsafe) private static var stopped = 0

    static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StalledErrorBodyURLProtocol.self]
        configuration.timeoutIntervalForRequest = 0
        return URLSession(configuration: configuration)
    }

    static func reset(reply: Reply) {
        lock.withLock { self.reply = reply; started = 0; stopped = 0 }
    }

    static func waitUntilStarted() async throws {
        while lock.withLock({ started }) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func waitUntilStopped() async throws {
        while lock.withLock({ stopped }) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.started += 1
            return Self.reply
        }
        if case .nothing = reply { return }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 408, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard case .body(let body) = reply else { return }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.withLock { Self.stopped += 1 }
    }
}
