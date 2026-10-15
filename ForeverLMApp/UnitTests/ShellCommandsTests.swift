import Foundation
import Testing
@testable import ForeverLM

// The command menu's rules (docs/codex-parity-audit.md, section 6 and lane E):
// how a query ranks rows, how the groups are ordered and cut, what shows
// before anything is typed, and the key table the menu bar and the ⌘/ sheet
// share.

@Suite("The command menu")
struct ShellCommandsTests {
    private func chat(_ id: String, _ title: String, pinned: Bool = false) -> ShellCommand {
        ShellCommands.chat(id: id, title: title, subtitle: "", isPinned: pinned)
    }

    private func page(_ id: String, _ title: String) -> ShellCommand {
        ShellCommands.page(id: id, title: title, subtitle: "")
    }

    @Test("A title that is the query beats one that starts with it, which beats a word match")
    func tiers() {
        let exact = page("a", "Mitochondria")
        let prefix = page("b", "Mitochondria and ageing")
        let word = page("c", "Notes on mitochondria")
        let inside = page("d", "Premitochondrial life")
        #expect(ShellCommands.matchTier(exact, query: "mitochondria") == 0)
        #expect(ShellCommands.matchTier(prefix, query: "Mitochondria") == 1)
        #expect(ShellCommands.matchTier(word, query: "mito") == 2)
        #expect(ShellCommands.matchTier(inside, query: "mitochondria") == 3)
        #expect(ShellCommands.matchTier(page("e", "Ribosomes"), query: "mito") == nil)
    }

    @Test("Case and accents are ignored, and every word of the query must match")
    func foldingAndWords() {
        let row = page("a", "Café Science Notes")
        #expect(ShellCommands.matchTier(row, query: "cafe sci") == 1)
        #expect(ShellCommands.matchTier(row, query: "notes cafe") == 2)
        #expect(ShellCommands.matchTier(row, query: "notes tea") == nil)
    }

    @Test("Keywords find a command by another name, below a title match")
    func keywords() {
        let shortcuts = ShellCommands.command(for: .keyboardShortcuts)
        #expect(ShellCommands.matchTier(shortcuts, query: "hotkeys") == 4)
        #expect(ShellCommands.matchTier(shortcuts, query: "keyboard") == 1)
    }

    @Test("A one-word query matches the title's letters in order")
    func subsequence() {
        #expect(ShellCommands.matchTier(ShellCommands.command(for: .newChat), query: "nwch") == 6)
        #expect(ShellCommands.matchTier(ShellCommands.command(for: .newChat), query: "chnw") == nil)
        #expect(ShellCommands.matchTier(page("a", "Bear"), query: "br") == 6)
        #expect(ShellCommands.matchTier(page("a", "Bear"), query: "rb") == nil)
    }

    @Test("A source the library's index found in its text matches though its title does not")
    func indexedSource() {
        let hit = ShellCommands.source(id: "s", title: "A paper", subtitle: "", matchedByIndex: true)
        let miss = ShellCommands.source(id: "t", title: "A paper", subtitle: "", matchedByIndex: false)
        #expect(ShellCommands.matchTier(hit, query: "gdf15") == 5)
        #expect(ShellCommands.matchTier(miss, query: "gdf15") == nil)
    }

    @Test("Groups are ordered by their best match, then in the menu's order; equal matches keep the order given")
    func sectionOrder() {
        let rows = [
            page("p1", "Sleep notes"),
            chat("c1", "Sleep"),
            chat("c2", "Sleep and memory"),
            page("p2", "Sleep"),
            ShellCommands.notebook(id: "n1", title: "Deep sleep", subtitle: ""),
        ]
        let sections = ShellCommands.sections(for: rows, query: "sleep")
        // Chats and Pages both hold an exact title; Chats come first in the
        // menu's order. Notebooks have only a word match.
        #expect(sections.map(\.group) == [.chats, .pages, .notebooks])
        #expect(sections[0].commands.map(\.id) == ["chat.c1", "chat.c2"])
        #expect(sections[1].commands.map(\.id) == ["page.p2", "page.p1"])
    }

    @Test("A search shows at most each group's limit")
    func limits() {
        let rows = (0..<20).map { chat("c\($0)", "Chat about cells \($0)") }
        let sections = ShellCommands.sections(for: rows, query: "cells")
        #expect(sections.count == 1)
        #expect(sections[0].commands.count == ShellCommandGroup.chats.searchLimit)
        #expect(sections[0].commands.first?.id == "chat.c0")
    }

    @Test("Before anything is typed: Quick actions, Pinned chats, Recent chats, Recent Pages")
    func emptyQuery() {
        let chats = [chat("a", "One", pinned: true)] + (1...8).map { chat("c\($0)", "Chat \($0)") }
        let pages = (1...6).map { page("p\($0)", "Page \($0)") }
        let sections = ShellCommands.emptyQuerySections(chats: chats, pages: pages)
        #expect(sections.map(\.group) == [.quickActions, .pinnedChats, .recentChats, .recentPages])
        #expect(sections[0].commands.map(\.target) == ShellAction.quickActions.map { .action($0) })
        #expect(sections[1].commands.map(\.id) == ["chat.a"])
        #expect(sections[2].commands.count == ShellCommandGroup.recentChats.searchLimit)
        #expect(sections[3].commands.map(\.id) == ["page.p1", "page.p2", "page.p3"])
        // No pinned chats, no Pinned section.
        #expect(!ShellCommands.emptyQuerySections(chats: [chat("c", "C")], pages: []).map(\.group).contains(.pinnedChats))
    }

    @Test("↑ and ↓ move through every section and wrap at the ends")
    func arrowKeys() {
        let sections = [
            ShellCommandSection(group: .chats, commands: [chat("a", "A"), chat("b", "B")]),
            ShellCommandSection(group: .pages, commands: [page("c", "C")]),
        ]
        #expect(ShellCommands.row(after: nil, step: 1, in: sections) == "chat.a")
        #expect(ShellCommands.row(after: "chat.b", step: 1, in: sections) == "page.c")
        #expect(ShellCommands.row(after: "page.c", step: 1, in: sections) == "chat.a")
        #expect(ShellCommands.row(after: "chat.a", step: -1, in: sections) == "page.c")
        #expect(ShellCommands.row(after: "gone", step: 1, in: sections) == "chat.a")
        #expect(ShellCommands.row(after: nil, step: 1, in: []) == nil)
    }

    @Test("A chat or Page with no title reads as Codex names it")
    func untitled() {
        #expect(chat("a", "  ").title == "Untitled chat")
        #expect(page("a", "").title == "Untitled")
    }

    @Test("Chat commands are offered only while the window shows a chat; Add Sources only in a notebook")
    func offeredActions() {
        let bare = ShellCommands.actions(showsChat: false, inNotebook: false).map(\.target)
        #expect(!bare.contains(.action(.renameChat)))
        #expect(!bare.contains(.action(.addSources)))
        #expect(!bare.contains(.action(.commandMenu)))
        let full = ShellCommands.actions(showsChat: true, inNotebook: true).map(\.target)
        #expect(full.contains(.action(.renameChat)))
        #expect(full.contains(.action(.addSources)))
    }

    @Test("Beta places show only where the Canvas does")
    func betaPlaces() {
        let without = ShellCommands.places(includingBeta: false).map(\.target)
        #expect(!without.contains(.place(.knowledgeMap)))
        #expect(!without.contains(.place(.atlas)))
        #expect(without.contains(.place(.memory)))
        #expect(ShellCommands.places(includingBeta: true).map(\.target).contains(.place(.atlas)))
    }

    @Test("Keys read as the menu bar writes them")
    func keyDisplay() {
        #expect(ShellAction.commandMenu.keys.map(\.display) == ["⌘K", "⇧⌘P"])
        #expect(ShellKey(ShellKey.tab, [.control, .shift]).display == "⌃⇧Tab")
        #expect(ShellKey(ShellKey.escape, .shift).display == "⇧Esc")
        #expect(ShellKey("n", [.command, .option]).display == "⌥⌘N")
    }

    @Test("Codex's version wins the five clashes, and each displaced command has a key of its own")
    func clashes() {
        #expect(ShellAction.commandMenu.key == ShellKey("k", .command))
        #expect(ShellAction.openChat.key == ShellKey("k", [.command, .shift]))
        #expect(ShellAction.newChat.key == ShellKey("n", .command))
        #expect(ShellAction.newWindow.key == ShellKey("n", [.command, .control]))
        #expect(ShellAction.hideChat.key == ShellKey("a", [.command, .shift]))
        #expect(ShellAction.addSources.key == ShellKey("i", [.command, .shift]))
        #expect(ShellAction.sideChat.key == ShellKey("s", [.command, .option]))
        #expect(ShellAction.nextUnreadChat.key == ShellKey("a", [.command, .option]))
        let others = ShellKeyboardShortcuts.atlas + ShellKeyboardShortcuts.notebookSources + ShellKeyboardShortcuts.saveCanvasVersion
        #expect(Set(others).isDisjoint(with: ShellAction.allCases.flatMap(\.keys)))
        #expect(Set(others).count == others.count)
    }

    @Test("Copy Conversation is a chat command with a key, so the whole chat is always one press away")
    func copyConversationCommand() {
        #expect(ShellAction.copyConversation.needsChat)
        #expect(ShellAction.copyConversation.key == ShellKey("c", [.command, .shift]))
        #expect(ShellCommands.actions(showsChat: true, inNotebook: false).map(\.target).contains(.action(.copyConversation)))
        #expect(!ShellCommands.actions(showsChat: false, inNotebook: false).map(\.target).contains(.action(.copyConversation)))
    }

    @Test("No two commands share a key")
    func keysAreUnique() {
        let keys = ShellAction.allCases.flatMap(\.keys)
        #expect(Set(keys).count == keys.count)
    }
}
