import Foundation
import Testing
@testable import ForeverLM

/// Home, Codex's first icon (2026-10-16): every chat as one list, a place of
/// its own on the strip. The Space lists no chats any more.
@Suite("Home place")
struct HomePlaceTests {
    @Test("Home is the strip's first row, ahead of New chat's +, and never in the Space")
    func homeLeadsTheStrip() {
        #expect(StudioRailItem.home.rawValue == "home")
        #expect(StudioRailItem.home.title == "Home")
        #expect(StudioRailItem.home.systemImage == "house")
        #expect(StudioRailHiddenItems.railOrder.first == .home)
        #expect(StudioRailHiddenItems().railItems().first == .home)
        #expect(!StudioRailHiddenItems.sidebarOrder.contains(.home), "Home's sidebar lists chats; the row is only on the strip")
    }

    @Test("A learner may take Home off the strip, and a stored layout names the tab by its raw value")
    func hidingAndStoring() {
        let hidden = StudioRailHiddenItems().setting(.home, hidden: true)
        #expect(hidden.storage == "home")
        #expect(hidden.railItems() == [.newChat, .space, .memory, .library, .plugins])
        #expect(StudioCenterTab(rawValue: "home") == .home)
        #expect(StudioCenterTab.permanentTabs.contains(.home))
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

    @Test("The command menu offers Home as a place, found by chats")
    func commandMenuOffersHome() {
        let places = ShellCommands.places(includingBeta: false)
        let home = places.first { $0.title == "Home" }
        #expect(home != nil)
        #expect(home?.keywords.contains("chats") == true)
    }
}
