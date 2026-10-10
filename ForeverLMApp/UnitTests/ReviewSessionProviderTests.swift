import XCTest
@testable import ForeverLM

final class ReviewSessionProviderTests: XCTestCase {
    func testInfersKnownExternalChatProviders() {
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://claude.ai/share/abc"), .claude)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://chatgpt.com/share/abc"), .chatGPT)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://chat.openai.com/share/abc"), .chatGPT)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://gemini.google.com/share/abc"), .gemini)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://aistudio.google.com/prompts/abc"), .gemini)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://grok.com/share/abc"), .grok)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://x.ai/"), .grok)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://platform.edisonscientific.com/tasks/abc"), .edison)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://platform.edisonscientific.com/trajectories/abc"), .edison)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://meta.ai/c/abc"), .metaAI)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://www.meta.ai/c/abc"), .metaAI)
    }

    func testFallsBackToOtherForUnknownExternalChatProvider() {
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://example.com/chat/abc"), .other)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "https://notclaude.ai/share/abc"), .other)
        XCTAssertEqual(ReviewSessionProvider.infer(from: "not a url"), .other)
    }
}
