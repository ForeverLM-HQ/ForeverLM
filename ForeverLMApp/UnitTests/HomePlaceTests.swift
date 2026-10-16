import Foundation
import Testing
@testable import ForeverLM

/// Home, Codex's first icon (2026-10-16), which took the strip's + place: a
/// blank chat with Home's sidebar beside it. The Space lists no chats and
/// starts none.
@Suite("Home place")
struct HomePlaceTests {
    @Test("Home is the strip's first row and has replaced the +; New chat is Home's sidebar's row")
    func homeLeadsTheStrip() {
        #expect(StudioRailItem.home.rawValue == "home")
        #expect(StudioRailItem.home.title == "Home")
        #expect(StudioRailItem.home.systemImage == "house")
        #expect(StudioRailHiddenItems.railOrder.first == .home)
        #expect(StudioRailHiddenItems().railItems().first == .home)
        #expect(!StudioRailHiddenItems.railOrder.contains(.newChat), "no + on the strip")
        #expect(!StudioRailHiddenItems.sidebarOrder.contains(.home), "Home's sidebar has New chat; the Home row is only on the strip")
    }

    @Test("A learner may take Home off the strip, and Home is no center tab")
    func hidingAndStoring() {
        let hidden = StudioRailHiddenItems().setting(.home, hidden: true)
        #expect(hidden.storage == "home")
        #expect(hidden.railItems() == [.space, .memory, .library, .plugins])
        #expect(StudioCenterTab(rawValue: "home") == nil, "a stored layout naming it falls out")
    }

    @Test("The Space lists no chats: no place, no shortcut, and a remembered Chats place opens All")
    func spaceHasNoChats() {
        #expect(!SpaceDestination.places.contains(.chats))
        #expect(!SpaceDestination.sidebarPlaces(listsCanvases: true).contains(.chats))
        #expect(!StudioRailShortcut.offered(listsCanvases: true).map(\.key).contains("chats"))
        #expect(SpaceDestination(key: "chats") == .all)
        #expect(StudioRailShortcut(key: "chats") == nil, "a kept Chats shortcut is dropped, not drawn as a phantom")
        #expect(!ShellCommands.spacePlaces.contains(.chats))
    }
}
