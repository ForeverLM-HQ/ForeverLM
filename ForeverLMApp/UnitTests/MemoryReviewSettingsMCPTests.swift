import Foundation
import Testing
@testable import ForeverLM

/// Settings › General › Memory review over MCP: the reader says what the pane shows, the
/// writer goes through the pane's own entry points, and the two tools are
/// registered.
@Suite("Memory review settings MCP tools", .serialized)
struct MemoryReviewSettingsMCPTests {

    private func makeStore() throws -> (MCPDataStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-memory-settings-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path), root)
    }

    @Test("get_memory_review_settings and set_memory_review_settings are Settings › General › Memory review")
    func settingsToolsDriveTheMemoryPane() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let keys = [DailyReviewPreparation.hourKey]
        let prior = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in prior {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }

        func payload(_ json: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }

        let initial = try payload(try await store.getMemoryReviewSettings())
        #expect(initial["ready_by_hour"] as? Int == DailyReviewPreparation.defaultHour)
        #expect(initial["budget_minutes"] as? Int == MemoryReviewBudget.minutes)
        #expect(initial["prepare_daily"] as? Bool == DailyReviewPreparation.isEnabled)
        let scope = try #require(initial["scope"] as? [String: String])
        #expect(scope["ready_by_hour"] == "this Mac")

        let changed = try payload(try await store.setMemoryReviewSettings(budgetMinutes: nil, prepareDaily: nil, readyByHour: 6))
        #expect(changed["ready_by_hour"] as? Int == 6)
        #expect(Set(changed["changed"] as? [String] ?? []) == ["ready_by_hour"])
        #expect(DailyReviewPreparation.hour == 6)

        // Writing the same value again changes nothing.
        let same = try payload(try await store.setMemoryReviewSettings(budgetMinutes: nil, prepareDaily: nil, readyByHour: 6))
        #expect((same["changed"] as? [String])?.isEmpty == true)

        await #expect(throws: MCPError.self) {
            _ = try await store.setMemoryReviewSettings(budgetMinutes: nil, prepareDaily: nil, readyByHour: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setMemoryReviewSettings(budgetMinutes: nil, prepareDaily: nil, readyByHour: 24)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setMemoryReviewSettings(budgetMinutes: 1, prepareDaily: nil, readyByHour: nil)
        }

        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        for name in ["get_memory_review_settings", "set_memory_review_settings"] {
            #expect(tools.contains { $0.name == name }, Comment(rawValue: name))
        }
    }

    @Test("The cards' settings round-trip over MCP, through the pane's own setters")
    func cardSettingsRoundTrip() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let keys = [
            MemoryCardSettings.newCardsPerDayKey, MemoryCardSettings.autoDraftKey,
            MemoryCardSettings.draftNudgesKey, MemoryCardSettings.prepareReviewQuestionsKey,
        ]
        let prior = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in prior {
                if let value { PreferenceStore.set(value, forKey: key) } else { PreferenceStore.remove(forKey: key) }
            }
        }
        for key in keys { PreferenceStore.remove(forKey: key) }

        func payload(_ json: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }

        let initial = try payload(try await store.getMemoryReviewSettings())
        #expect(initial["new_cards_per_day"] as? Int == MemoryCardQueue.defaultNewPerDay)
        #expect(initial["auto_draft_cards"] as? Bool == false, "off until the learner turns it on")
        #expect(initial["draft_nudges"] as? Bool == true)
        #expect(initial["prepare_review_questions"] as? Bool == true, "on until the learner turns it off")
        let scope = try #require(initial["scope"] as? [String: String])
        #expect(scope["new_cards_per_day"] == "your account")
        let drafting = try #require(initial["automatic_drafting"] as? [String: Any])
        #expect(drafting["sources_a_day"] as? Int == 3)

        let changed = try payload(try await store.setMemoryReviewSettings(
            budgetMinutes: nil, prepareDaily: nil, readyByHour: nil,
            newCardsPerDay: 20, autoDraftCards: true, draftNudges: false,
            prepareReviewQuestions: false
        ))
        #expect(Set(changed["changed"] as? [String] ?? []) == [
            "new_cards_per_day", "auto_draft_cards", "draft_nudges", "prepare_review_questions",
        ])
        #expect(changed["new_cards_per_day"] as? Int == 20)
        #expect(MemoryCardSettings.newCardsPerDay() == 20)
        #expect(MemoryCardSettings.autoDraftsCards())
        #expect(!MemoryCardSettings.showsDraftNudges())
        #expect(!MemoryCardSettings.preparesReviewQuestions())
        #expect(changed["prepare_review_questions"] as? Bool == false)
        #expect((changed["automatic_drafting"] as? [String: Any])?["sources_a_day"] as? Int == 5)

        let same = try payload(try await store.setMemoryReviewSettings(
            budgetMinutes: nil, prepareDaily: nil, readyByHour: nil, newCardsPerDay: 20
        ))
        #expect((same["changed"] as? [String])?.isEmpty == true)

        for wrong in [0, 101] {
            await #expect(throws: MCPError.self) {
                _ = try await store.setMemoryReviewSettings(
                    budgetMinutes: nil, prepareDaily: nil, readyByHour: nil, newCardsPerDay: wrong
                )
            }
        }

        let tool = try #require(MCPToolRegistry(store: MCPDataStore()).tools.first { $0.name == "set_memory_review_settings" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        for name in ["new_cards_per_day", "auto_draft_cards", "draft_nudges", "prepare_review_questions"] {
            #expect(properties[name] != nil, Comment(rawValue: name))
        }
    }
}
