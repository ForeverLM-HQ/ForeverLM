import Foundation
import Testing
@testable import ForeverLM

private let liveAPITestsEnabled = {
    let env = ProcessInfo.processInfo.environment
    return env["FOREVERLM_LIVE_API_TESTS"] == "1"
}()

private enum LiveAPIIntegrationError: LocalizedError {
    case missingSession
    case unavailableAccount(String)
    case missingFixture(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Sign in with Apple in the Debug app, or export FOREVERLM_MANAGED_SESSION_TOKEN for this test process."
        case .unavailableAccount(let message):
            return message
        case .missingFixture(let name):
            return "Live API fixture \(name) is missing from the test bundle."
        }
    }
}

private final class LiveAPIFixtureAnchor {}

/// Opt-in, billable smoke tests for the production managed-AI rail.
///
/// These deliberately use the same request builders, proxy rewrite, response
/// validation, metering, and task/model resolution as the app. They are disabled
/// during ordinary test runs because a real managed session, network access, and
/// a small positive credit balance are requirements rather than mocks.
@Suite(
    "Live managed API integration",
    .serialized,
    .enabled(if: liveAPITestsEnabled)
)
struct LiveAPIIntegrationTests {
    private func requireSpendableAccount() async throws -> ManagedAI.Balance {
        guard ManagedAI.isSignedIn else {
            throw LiveAPIIntegrationError.missingSession
        }
        let balance = try await ManagedAI.balance()
        guard !balance.disabled else {
            throw LiveAPIIntegrationError.unavailableAccount(
                "The managed-AI account is disabled; no live request was attempted."
            )
        }
        guard balance.microUSD > 0 else {
            throw LiveAPIIntegrationError.unavailableAccount(
                "The managed-AI balance is empty; live tests need a comped test account or an operator grant."
            )
        }
        return balance
    }

    private func fixtureURL(named name: String, extension extensionName: String) throws -> URL {
        guard let url = Bundle(for: LiveAPIFixtureAnchor.self)
            .url(forResource: name, withExtension: extensionName) else {
            throw LiveAPIIntegrationError.missingFixture("\(name).\(extensionName)")
        }
        return url
    }

    @Test("Managed session authenticates and has spendable credit")
    func managedAccount() async throws {
        let balance = try await requireSpendableAccount()
        #expect(balance.microUSD > 0)
        #expect(!balance.disabled)
    }

    @Test("Every active text-provider route completes a real request")
    func activeTextProviderRoutes() async throws {
        _ = try await requireSpendableAccount()
        let service = AIService()

        for provider in AIProvider.activeChatProviders {
            // Some provider routes are optional in a developer environment.
            guard KeychainService.hasUsableTextProviderCredentials(for: provider) else {
                continue
            }
            let model = KeychainService.model(for: provider)
            var config = AITaskConfig(
                provider: provider,
                apiKey: KeychainService.apiKey(for: provider) ?? "",
                model: model
            )
            config.taskLabel = "live_test_provider_route"
            do {
                let output = try await service.call(
                    config: config,
                    system: "This is a production transport health check.",
                    user: "Reply with OK.",
                    maxTokens: 16,
                    temperature: 0,
                    allowsReasoningInflation: false,
                    disablesReasoning: true,
                    allowsResponseCache: false
                )
                #expect(
                    !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(provider.rawValue) / \(model) returned empty text."
                )
            } catch {
                Issue.record("\(provider.rawValue) / \(model) failed: \(error.localizedDescription)")
            }
        }
    }

    @Test("Chat streams real text through the configured default model")
    func streamingChat() async throws {
        _ = try await requireSpendableAccount()
        guard let resolved = KeychainService.resolveConfig(for: .chat) else {
            throw LiveAPIIntegrationError.missingSession
        }
        var config = resolved
        config.taskLabel = "live_test_streaming_chat"
        let stream = await AIService().streamChat(
            system: "This is a production streaming health check.",
            messages: [(role: "user", content: "Reply with the word STREAMING.")],
            config: config,
            maxTokens: 32
        )
        var output = ""
        for try await delta in stream { output += delta }
        #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Chat can issue a native tool call")
    func nativeToolCalling() async throws {
        _ = try await requireSpendableAccount()
        guard let resolved = KeychainService.resolveConfig(for: .chat) else {
            throw LiveAPIIntegrationError.missingSession
        }
        var config = resolved
        config.taskLabel = "live_test_native_tools"
        let tool = AIToolSpec(
            name: "live_health_check",
            description: "Required transport health check. Call this exactly once.",
            inputSchema: [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false,
            ]
        )
        let result = try await AIService().streamChatWithTools(
            config: config,
            system: "You must call live_health_check exactly once. Do not answer in plain text.",
            turns: [.user("Run the required health check now.")],
            tools: [tool],
            maxTokens: 64,
            onTextDelta: { _ in }
        )
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls.first?.name == "live_health_check")
    }

    @Test("Server-side web search request completes")
    func webSearchChat() async throws {
        _ = try await requireSpendableAccount()
        guard let resolved = KeychainService.resolveConfig(for: .chat) else {
            throw LiveAPIIntegrationError.missingSession
        }
        var config = resolved
        config.taskLabel = "live_test_web_search"
        let stream = await AIService().streamChat(
            system: "Use web search for the requested fact and answer in one short sentence.",
            messages: [(role: "user", content: "What is the title of the example.com home page?")],
            config: config,
            maxTokens: 80,
            webSearch: true
        )
        var output = ""
        for try await delta in stream { output += delta }
        #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Every background task resolves and every unique route answers")
    func backgroundTaskRoutes() async throws {
        _ = try await requireSpendableAccount()
        let service = AIService()
        var routes: [String: (config: AITaskConfig, tasks: [AITask])] = [:]

        for task in AITask.allCases where task.usesBackgroundModelDefault {
            guard let resolved = KeychainService.resolveConfig(for: task) else {
                Issue.record("\(task.rawValue) did not resolve a managed configuration.")
                continue
            }
            let config = resolved
            let key = "\(config.provider.rawValue)|\(config.model)|vision=\(task.requiresVision)"
            if routes[key] == nil {
                routes[key] = (config, [task])
            } else {
                routes[key]?.tasks.append(task)
            }
        }

        let imageData = try Data(contentsOf: fixtureURL(
            named: "slide_cited_paper",
            extension: "jpg"
        ))
        for (_, route) in routes.sorted(by: { $0.key < $1.key }) {
            var config = route.config
            config.taskLabel = "live_test_background"
            let taskNames = route.tasks.map(\.rawValue).joined(separator: ",")
            do {
                let output = try await service.call(
                    config: config,
                    system: "This is a production background-task transport health check.",
                    user: "Tasks: \(taskNames). Reply with OK.",
                    maxTokens: 16,
                    temperature: 0,
                    imageJPEGData: route.tasks.first?.requiresVision == true ? imageData : nil,
                    allowsReasoningInflation: false,
                    disablesReasoning: true,
                    allowsResponseCache: false
                )
                #expect(
                    !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Background route \(config.provider.rawValue) / \(config.model) returned empty text."
                )
            } catch {
                // One interpolation, not a concatenation: `Issue.record` takes a
                // `Comment`, so `+` resolves to `Sequence.+` and fails to compile.
                Issue.record(
                    """
                    Background route \(config.provider.rawValue) / \(config.model) \
                    for [\(taskNames)] failed: \(error.localizedDescription)
                    """
                )
            }
        }
    }

    @Test("Background JSON mode returns parseable JSON")
    func backgroundJSONMode() async throws {
        _ = try await requireSpendableAccount()
        guard let resolved = KeychainService.resolveConfig(for: .sourceClassification) else {
            throw LiveAPIIntegrationError.missingSession
        }
        var config = resolved
        config.taskLabel = "live_test_json_mode"
        let output = try await AIService().call(
            config: config,
            system: "Return only a JSON object with a boolean field named ok.",
            user: "Report success.",
            maxTokens: 40,
            temperature: 0,
            allowsReasoningInflation: false,
            disablesReasoning: true,
            allowsResponseCache: false,
            jsonMode: true
        )
        let data = try #require(output.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["ok"] as? Bool == true)
    }

    @Test("Paper text-to-speech route returns a valid adaptation plan")
    func paperTextToSpeechRoute() async throws {
        _ = try await requireSpendableAccount()
        var config = AITaskConfig(
            provider: .openRouter,
            apiKey: "",
            model: AIModelDefaults.paperTextToSpeechPreparation
        )
        config.taskLabel = AITask.paperTextToSpeechPreparation.rawValue
        let blocks = [
            AIService.PaperContentBlock(
                id: "B000001",
                text: "The experiment compared two treatments."
            ),
            AIService.PaperContentBlock(
                id: "B000002",
                text: "Table 1. Group A: 14.2. Group B: 10.1."
            ),
            AIService.PaperContentBlock(
                id: "B000003",
                text: "The treatment effect remained after adjustment."
            ),
        ]

        _ = try await AIService().paperSpeechAdaptationPlan(
            source: AIUsageSource(
                id: "live-paper-text-to-speech",
                type: "paper",
                title: "Live Paper Text-to-Speech Health Check"
            ),
            blocks: blocks,
            config: config,
            chunkIndex: 0,
            chunkCount: 1
        )
    }

    @Test("Managed transcription returns text and records usage")
    @MainActor
    func transcription() async throws {
        _ = try await requireSpendableAccount()
        let fixture = try fixtureURL(named: "command_skip", extension: "wav")
        let text = try await ReviewDictationService().transcribeProbe(fileURL: fixture)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Managed text-to-speech returns metered playable bytes")
    func textToSpeech() async throws {
        _ = try await requireSpendableAccount()
        let responses = try await CloudArticleTTS.synthesizeProbe(
            "ForeverLM live speech health check."
        )
        let response = try #require(responses.first)
        #expect(response.data.count > 1_000)
        #expect(response.contentType.lowercased().contains("audio"))
        #expect(response.requestID?.isEmpty == false)
    }

}
