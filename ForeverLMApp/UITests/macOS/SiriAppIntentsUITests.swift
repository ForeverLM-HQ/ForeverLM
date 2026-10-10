import XCTest

// The App Intents Testing framework ships with Xcode 27+ only; this suite
// vanishes when building with older toolchains. It validates the Siri
// integration through the real system pathways (no UI automation): App
// Intents Testing drives a live app process, which is why this lives in the
// UI testing bundle — from a unit test bundle the transport has no launched
// app session to talk to and fails with `transportCancelled`.
#if canImport(AppIntentsTesting)
import AppIntentsTesting

@MainActor
final class SiriAppIntentsUITests: XCTestCase {

    func testEntityQueriesResolveThroughSystemPathways() async throws {
        guard #available(macOS 27.0, *) else {
            throw XCTSkip("App Intents Testing requires macOS 27")
        }

        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let definitions = IntentDefinitions(bundleIdentifier: "com.foreverlm")

        // Executes StudioSourceQuery / StudioNotebookQuery via the real App
        // Intents runtime; throwing here means entity registration or query
        // plumbing is broken (empty results are fine — they depend on the
        // local knowledge base).
        let sources = definitions.entities["StudioSourceEntity"]
        _ = try await sources.entities(matching: "the")
        _ = try await sources.suggestedEntities()

        let notebooks = definitions.entities["StudioNotebookEntity"]
        _ = try await notebooks.entities(matching: "a")
    }
}
#endif
