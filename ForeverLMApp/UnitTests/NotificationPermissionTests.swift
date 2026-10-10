import Foundation
import Testing
import UserNotifications
@testable import ForeverLM

#if os(macOS)

/// macOS's answer about ForeverLM's notifications and the one line Settings ›
/// General draws about it (`NotificationPermission`, `NotificationSettingsNote`;
/// planner-design.md, "When macOS refuses the notifications").
@Suite("Notification permission")
struct NotificationPermissionTests {

    @Test("macOS's answers read as allowed, refused or never asked")
    func statuses() {
        #expect(NotificationPermission(.authorized) == .allowed)
        #expect(NotificationPermission(.provisional) == .allowed)
        #expect(NotificationPermission(.denied) == .refused)
        #expect(NotificationPermission(.notDetermined) == .notAsked)
        // The wire names get_day_settings answers.
        #expect(NotificationPermission.allowed.rawValue == "allowed")
        #expect(NotificationPermission.refused.rawValue == "refused")
        #expect(NotificationPermission.notAsked.rawValue == "not_asked")
    }

    @Test("Nothing is said while macOS allows them, before it has answered, or while nothing switched on needs them")
    func silent() {
        func note(_ permission: NotificationPermission?, prepares: Bool = true) -> NotificationSettingsNote? {
            NotificationSettingsNote.placement(permission: permission, preparesDailyReview: prepares)
        }
        #expect(note(.allowed) == nil)
        #expect(note(nil) == nil, "not read yet")
        #expect(note(.refused, prepares: false) == nil)
        #expect(note(.notAsked, prepares: false) == nil)
    }

    @Test("A refusal, or a Mac never asked, is said under the memory review's switch, the one that needs notifications")
    func placement() {
        for permission in [NotificationPermission.refused, .notAsked] {
            let memory = NotificationSettingsNote(permission: permission, card: .memoryReview)
            #expect(NotificationSettingsNote.placement(permission: permission, preparesDailyReview: true) == memory)
        }
    }

    @Test("Open System Settings opens this app's own entry under Notifications")
    func systemSettingsURL() throws {
        #expect(NotificationPermission.systemSettingsURL(bundleIdentifier: "com.foreverlm")?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.foreverlm")
        #expect(NotificationPermission.systemSettingsURL(bundleIdentifier: "com.foreverlm.dev")?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.foreverlm.dev")
        // No id: the pane's own list.
        #expect(NotificationPermission.systemSettingsURL(bundleIdentifier: nil)?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #expect(NotificationPermission.systemSettingsURL(bundleIdentifier: "")?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        // The running app names itself, so a Dev build opens its own entry.
        let running = try #require(Bundle.main.bundleIdentifier)
        #expect(NotificationPermission.systemSettingsURL()?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(running)")
    }
}

#endif
