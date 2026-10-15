import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// `get_day_settings` / `set_day_settings`: Settings › General › Day — the
/// hours of the learner's day, "Plan your day?", and macOS's answer about the
/// notifications — readable and writable from a chat so the pane is never the
/// only place they can be changed. See docs/planner-design.md.
@Suite("MCP day settings tools", .serialized)
struct MCPDaySettingsToolsTests {

    private func payload(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    /// Restores the defaults the tools write, whatever a test did.
    private func restoringDefaults<T>(_ body: () async throws -> T) async throws -> T {
        let defaults = UserDefaults.standard
        let keys = [PlannerDayHours.startKey, PlannerDayHours.endKey, PlanTheDay.settingKey, PlanTheDay.forcedKey]
        let prior = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in prior {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        return try await body()
    }

    @Test("Both tools are registered, the Planner's pair is gone, and the setter takes any of its settings or the Allow Notifications press")
    func registered() throws {
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        #expect(byName["get_planner_settings"] == nil && byName["set_planner_settings"] == nil)
        let get = try #require(byName["get_day_settings"])
        #expect(get.description.contains("notifications_status"))
        let set = try #require(byName["set_day_settings"])
        #expect((set.inputSchema["required"] as? [String]) == [])
        let properties = try #require(set.inputSchema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["day_start_hour", "day_end_hour", "suggest_planning_the_day", "force_planning_the_day", "request_notifications"])
        #expect(set.description.contains("request_notifications"))
    }

    @Test("macOS's answer rides with the switches, and a refusal says only the learner can undo it")
    @MainActor
    func notificationsStatus() async throws {
        try await restoringDefaults {
            let allowed = MCPDataStore.daySettingsPayload(notifications: .allowed)
            #expect(allowed["notifications_status"] as? String == "allowed")
            let refused = MCPDataStore.daySettingsPayload(notifications: .refused)
            #expect(refused["notifications_status"] as? String == "refused")
            let refusedNote = try #require(refused["notifications_note"] as? String)
            #expect(refusedNote.contains("System Settings › Notifications"))
            let notAsked = MCPDataStore.daySettingsPayload(notifications: .notAsked)
            #expect(notAsked["notifications_status"] as? String == "not_asked")
            #expect((notAsked["notifications_note"] as? String)?.contains("request_notifications") == true)
            // The switch reads the same whatever macOS answers.
            #expect(refused["suggest_planning_the_day"] as? Bool == allowed["suggest_planning_the_day"] as? Bool)

            // The live read answers one of the three, whatever this Mac says.
            let store = MCPDataStore()
            let read = try payload(try await store.getDaySettings())
            let status = try #require(read["notifications_status"] as? String)
            #expect(["allowed", "refused", "not_asked"].contains(status))
            let live = try #require(NotificationPermission(rawValue: status))
            #expect(read["notifications_note"] as? String == MCPDataStore.dayNotificationsNote(live))
        }
    }

    @Test("request_notifications false presses nothing, and the answer says whether macOS was asked")
    @MainActor
    func requestNotifications() async throws {
        try await restoringDefaults {
            let store = MCPDataStore()
            // Not a setting: false alone is nothing to do.
            await #expect(throws: MCPError.self) {
                _ = try await store.setDaySettings(dayStartHour: nil, dayEndHour: nil, requestNotifications: false)
            }
            #expect(MCPDataStore.notificationRequestAnswer(before: .notAsked).hasPrefix("Asked"))
            #expect(MCPDataStore.notificationRequestAnswer(before: .refused).hasPrefix("Not asked"))
            #expect(MCPDataStore.notificationRequestAnswer(before: .refused).contains("System Settings › Notifications"))
            #expect(MCPDataStore.notificationRequestAnswer(before: .allowed).hasPrefix("Not asked"))
            // A settings write without the press carries no request answer.
            let written = try payload(try await store.setDaySettings(dayStartHour: nil, dayEndHour: nil, suggestPlanningTheDay: true))
            #expect(written["notifications_request"] == nil)
            #expect((written["notifications_status"] as? String) != nil)
        }
    }

    @Test("The setter flips the same default the pane's switch writes, and says whether it changed")
    @MainActor
    func setAndRead() async throws {
        try await restoringDefaults {
            let store = MCPDataStore()
            let read = try payload(try await store.getDaySettings())
            // The hours read their defaults until set.
            #expect(read["day_start_hour"] as? Int == 6)
            #expect(read["day_end_hour"] as? Int == 24)
            // "Plan your day?" is asked until switched off.
            #expect(read["suggest_planning_the_day"] as? Bool == true)
            var planning = try payload(try await store.setDaySettings(dayStartHour: nil, dayEndHour: nil, suggestPlanningTheDay: false))
            #expect(planning["suggest_planning_the_day"] as? Bool == false && planning["changed"] as? Bool == true)
            #expect(!PlanTheDay.isEnabled)
            planning = try payload(try await store.setDaySettings(dayStartHour: nil, dayEndHour: nil, suggestPlanningTheDay: false))
            #expect(planning["changed"] as? Bool == false)

            // Making the learner plan is off until switched on, and needs the question asked.
            #expect(read["force_planning_the_day"] as? Bool == false)
            #expect(!PlanTheDay.isForced)
            var forcing = try payload(try await store.setDaySettings(dayStartHour: nil, dayEndHour: nil, forcePlanningTheDay: true))
            #expect(forcing["force_planning_the_day"] as? Bool == true && forcing["changed"] as? Bool == true)
            // The question is off (set above), so nothing is forced.
            #expect(!PlanTheDay.isForced)
            _ = try await store.setDaySettings(dayStartHour: nil, dayEndHour: nil, suggestPlanningTheDay: true)
            #expect(PlanTheDay.isForced)
            forcing = try payload(try await store.setDaySettings(dayStartHour: nil, dayEndHour: nil, forcePlanningTheDay: true))
            #expect(forcing["changed"] as? Bool == false)

            await #expect(throws: MCPError.self) {
                _ = try await store.setDaySettings(dayStartHour: nil, dayEndHour: nil)
            }
        }
    }

    @Test("The day's hours are set the way the pane's pickers set them, in order and inside the day")
    @MainActor
    func dayHours() async throws {
        try await restoringDefaults {
            let store = MCPDataStore()

            var written = try payload(try await store.setDaySettings(dayStartHour: 7, dayEndHour: 22))
            #expect(written["day_start_hour"] as? Int == 7)
            #expect(written["day_end_hour"] as? Int == 22)
            #expect(written["changed"] as? Bool == true)
            #expect(PlannerDayHours.window == 7...22)

            // One end at a time.
            written = try payload(try await store.setDaySettings(dayStartHour: nil, dayEndHour: 23))
            #expect(PlannerDayHours.window == 7...23)
            #expect(written["changed"] as? Bool == true)
            written = try payload(try await store.setDaySettings(dayStartHour: 7, dayEndHour: nil))
            #expect(written["changed"] as? Bool == false)

            // A day that ends before it starts, or an hour outside the day, is
            // refused and nothing is written.
            await #expect(throws: MCPError.self) {
                _ = try await store.setDaySettings(dayStartHour: 23, dayEndHour: nil)
            }
            await #expect(throws: MCPError.self) {
                _ = try await store.setDaySettings(dayStartHour: nil, dayEndHour: 7)
            }
            await #expect(throws: MCPError.self) {
                _ = try await store.setDaySettings(dayStartHour: 24, dayEndHour: nil)
            }
            await #expect(throws: MCPError.self) {
                _ = try await store.setDaySettings(dayStartHour: nil, dayEndHour: 25)
            }
            #expect(PlannerDayHours.window == 7...23)

            // Over the wire, the hours arrive as JSON numbers.
            let registry = MCPToolRegistry(store: store)
            let outcome = await registry.callToolDetailed(name: "set_day_settings", arguments: ["day_start_hour": 5.0, "day_end_hour": 24])
            #expect(!outcome.isError, "\(outcome.text)")
            let over = try payload(outcome.text)
            #expect(over["day_start_hour"] as? Int == 5)
            #expect(over["day_end_hour"] as? Int == 24)
        }
    }
}

#endif
