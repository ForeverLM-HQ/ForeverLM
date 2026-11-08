import Foundation
import Testing
@testable import ForeverLM

/// The chat's Browser tools: their contract, their key table, and how a
/// screenshot reaches each provider.
@Suite("Chat browser tools")
struct ChatBrowserToolsTests {
    @MainActor
    private final class StubAgent: ChatBrowserAgent {
        var hasTab = false
        func run(tool name: String, arguments: [String: Any], onPreview: @escaping @MainActor (Data) -> Void) async -> ChatBrowserToolOutcome {
            ChatBrowserToolOutcome(text: "", isError: false)
        }
        func revealTab() {}
    }

    @Test("The browser tools ride the chat and Deep Research, only with an agent, never a review")
    @MainActor
    func toolsAreOfferedWhereTheBrowserIs() {
        let withAgent = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false,
            mode: .assistant, browserAgent: StubAgent()
        ).map(\.name)
        for name in ChatBrowsing.toolNames {
            #expect(withAgent.contains(name), "\(name) missing from the chat")
        }
        #expect(withAgent.firstIndex(of: "fetch_web_page")! < withAgent.firstIndex(of: "browser_open")!)

        let research = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false,
            mode: .deepResearch, browserAgent: StubAgent()
        ).map(\.name)
        #expect(research.contains("browser_open"))

        let review = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true, appTools: [], hasSynthesisContext: false,
            mode: .review, browserAgent: StubAgent()
        ).map(\.name)
        #expect(!review.contains("browser_open"))

        let withoutAgent = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false, mode: .assistant
        ).map(\.name)
        #expect(!withoutAgent.contains(where: ChatBrowsing.isBrowserTool))
    }

    @Test("Every tool's schema is an object, and the click tool explains a Kindle page turn")
    func toolSpecsAreWellFormed() {
        let specs = ChatBrowsing.toolSpecs()
        #expect(specs.map(\.name) == ChatBrowsing.toolNames)
        for spec in specs {
            #expect(spec.inputSchema["type"] as? String == "object", Comment(rawValue: spec.name))
            #expect(!spec.description.isEmpty)
        }
        let click = specs.first { $0.name == "browser_click" }!
        #expect(click.description.contains("read.amazon.com"))
        #expect(click.description.contains("ArrowRight"))
        let properties = click.inputSchema["properties"] as? [String: Any]
        #expect(properties?["ref"] != nil)
        #expect(properties?["x"] != nil)
        #expect(properties?["y"] != nil)
        let open = specs.first { $0.name == "browser_open" }!
        #expect(open.description.contains("never type a password"))
        #expect((open.inputSchema["required"] as? [String]) == ["url"])
    }

    @Test("Every step but opening can act on the Reader's page; the chat's tab is the default")
    func readerPageChoice() {
        let specs = ChatBrowsing.toolSpecs()
        for spec in specs {
            let properties = spec.inputSchema["properties"] as? [String: Any]
            let page = properties?["page"] as? [String: Any]
            if spec.name == "browser_open" {
                // Opening loads the chat's tab; it never navigates the Reader.
                #expect(page == nil)
            } else {
                #expect((page?["enum"] as? [String]) == ["chat", "reader"], Comment(rawValue: spec.name))
            }
        }
        #expect(ChatBrowsing.Page.parse([:]) == .chat)
        #expect(ChatBrowsing.Page.parse(["page": "chat"]) == .chat)
        #expect(ChatBrowsing.Page.parse(["page": " Reader "]) == .reader)
        // Anything else stays on the chat's own tab rather than guessing.
        #expect(ChatBrowsing.Page.parse(["page": "browser"]) == .chat)
        #expect(ChatBrowsing.Page.parse(["page": 1]) == .chat)
    }

    @Test("A click lands on a handle or on a point, and on nothing half-named")
    func clickTargets() {
        #expect(ChatBrowsing.Target.parse(["ref": " ref_4 "]) == .ref("ref_4"))
        #expect(ChatBrowsing.Target.parse(["x": 1240, "y": 400]) == .point(x: 1240, y: 400))
        #expect(ChatBrowsing.Target.parse(["x": "12.5", "y": "7"]) == .point(x: 12.5, y: 7))
        #expect(ChatBrowsing.Target.parse(["x": 12]) == nil)
        #expect(ChatBrowsing.Target.parse([:]) == nil)
        // A handle outranks coordinates given beside it.
        #expect(ChatBrowsing.Target.parse(["ref": "ref_1", "x": 1, "y": 2]) == .ref("ref_1"))
    }

    @Test("Named keys map to AppKit's function characters and ANSI key codes; a character is itself")
    func keyTable() {
        let right = ChatBrowsing.KeyPress.parse(key: "ArrowRight")
        #expect(right?.characters == "\u{F703}")
        #expect(right?.keyCode == 124)
        #expect(right?.modifiers == [])
        #expect(ChatBrowsing.KeyPress.parse(key: "arrowleft")?.keyCode == 123)
        #expect(ChatBrowsing.KeyPress.parse(key: "Enter")?.characters == "\r")
        #expect(ChatBrowsing.KeyPress.parse(key: "Escape")?.keyCode == 53)
        #expect(ChatBrowsing.KeyPress.parse(key: "PageDown")?.keyCode == 121)

        let find = ChatBrowsing.KeyPress.parse(key: "f", modifierNames: ["command"])
        #expect(find?.characters == "f")
        #expect(find?.keyCode == 0)
        #expect(find?.modifiers == [.command])
        #expect(ChatBrowsing.KeyPress.parse(key: "a", modifierNames: ["cmd", "Shift"])?.modifiers == [.command, .shift])

        #expect(ChatBrowsing.KeyPress.parse(key: "") == nil)
        #expect(ChatBrowsing.KeyPress.parse(key: "hello") == nil)

        let typed = ChatBrowsing.KeyPress.typing("hi\n")
        #expect(typed.map(\.characters) == ["h", "i", "\r"])
        #expect(typed.last?.keyCode == 36)
    }

    @Test("Scroll arguments default to one viewport down and clamp what they take")
    func scrollRequests() {
        #expect(ChatBrowsing.ScrollRequest.parse([:]) == .init(direction: .down, amount: 1))
        #expect(ChatBrowsing.ScrollRequest.parse(["direction": "UP", "amount": 2.5]) == .init(direction: .up, amount: 2.5))
        #expect(ChatBrowsing.ScrollRequest.parse(["direction": "bottom", "amount": 400]) == .init(direction: .bottom, amount: 20))
        #expect(ChatBrowsing.ScrollRequest.parse(["direction": "sideways", "amount": -1]) == .init(direction: .down, amount: 1))
    }

    @Test("Activity rows read as actions with the argument that matters")
    @MainActor
    func activityRows() {
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "browser_open",
            arguments: ["url": "https://read.amazon.com/?asin=B0BLT7BDR2&ref=abc"]
        ) == "read.amazon.com")
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "browser_click", arguments: ["x": 1240, "y": 400]
        ) == "1240, 400")
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "browser_click", arguments: ["ref": "ref_7"]
        ) == "ref_7")
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "browser_press_key", arguments: ["key": "ArrowRight", "times": 10]
        ) == "ArrowRight × 10")
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "browser_type", arguments: ["text": "mitochondrial membrane potential"]
        ) == "“mitochondrial membrane potential”")
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "browser_scroll", arguments: [:]
        ) == "down")
        #expect(ChatBrowsing.activityTitle(toolName: "browser_screenshot") == "Took a screenshot")
        #expect(ChatBrowsing.activityTitle(toolName: "browser_press_key") == "Pressed")

        let activity = ReviewSessionManager.Message.ToolActivity(
            toolName: "browser_open", detail: "read.amazon.com", state: .running, resultPreview: nil
        )
        #expect(activity.isBrowserStep)
        #expect(activity.title == "Opened in Browser")
        let other = ReviewSessionManager.Message.ToolActivity(
            toolName: "fetch_web_page", detail: nil, state: .running, resultPreview: nil
        )
        #expect(!other.isBrowserStep)
    }

    @Test("A screenshot reaches OpenRouter as the user message that follows the result")
    func screenshotsReachTheModel() {
        let image = AIChatImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png")
        let turns: [AIChatTurn] = [
            .user("Show me the page"),
            .assistant(text: "", toolCalls: [
                AIToolCallRequest(id: "call_1", name: "browser_screenshot", argumentsJSON: "{}"),
            ]),
            .toolResults([
                AIToolResultPayload(callID: "call_1", toolName: "browser_screenshot", text: "Screenshot of the page.", isError: false, images: [image]),
            ]),
        ]

        // OpenAI-style chat completions: the tool message stays text, a user message carries the picture.
        let openAI = AIService.openAIStyleToolMessages(system: "s", turns: turns)
        #expect(openAI[openAI.count - 2]["role"] as? String == "tool")
        #expect(openAI[openAI.count - 2]["content"] as? String == "Screenshot of the page.")
        let followUp = openAI.last
        #expect(followUp?["role"] as? String == "user")
        let parts = followUp?["content"] as? [[String: Any]]
        #expect(parts?.first?["type"] as? String == "text")
        #expect((parts?.first?["text"] as? String)?.contains("browser_screenshot") == true)
        #expect(parts?.last?["type"] as? String == "image_url")

        // A result without a picture is unchanged on every route.
        let plain: [AIChatTurn] = [.toolResults([
            AIToolResultPayload(callID: "call_2", toolName: "browser_read_page", text: "outline", isError: false),
        ])]
        #expect(AIService.openAIStyleToolMessages(system: "s", turns: plain).count == 2)
        #expect(AIService.projectedCharacterCount(of: turns) > AIService.projectedCharacterCount(of: plain) + AIChatImage.projectedCharacterCount)
    }
}
