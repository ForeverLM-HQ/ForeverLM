import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// The quick assistant's shortcut as it is written down (Settings, MCP and
/// this Mac's defaults all hold `ctrl+option+space`), read back, and recorded
/// from a key press. docs/quick-assistant-design.md.
@Suite("Quick assistant shortcut")
struct QuickAssistantShortcutTests {

    @Test("every written form reads back as the shortcut it names")
    func roundTrip() throws {
        for text in ["ctrl+option+space", "shift+cmd+k", "f5", "ctrl+option+shift+cmd+/", "option+return", "cmd+-", "ctrl+f19"] {
            let shortcut = try #require(try QuickAssistantShortcut.parse(text))
            #expect(shortcut.serialized == text)
            #expect(try QuickAssistantShortcut.parse(shortcut.serialized) == shortcut)
        }
    }

    @Test("symbols, aliases, case and spaces read as the same shortcut")
    func lenientForms() throws {
        #expect(try QuickAssistantShortcut.parse("⌃⌥Space") == .productionDefault)
        #expect(try QuickAssistantShortcut.parse("Control + Alt + SPACE") == .productionDefault)
        #expect(try QuickAssistantShortcut.parse(" ctrl+opt+space ") == .productionDefault)
        #expect(try QuickAssistantShortcut.parse("⌘⇧K")?.serialized == "shift+cmd+k")
        #expect(try QuickAssistantShortcut.parse("command+shift+k")?.serialized == "shift+cmd+k")
    }

    @Test("the default is ⌃⌥Space, ⌃⌥⇧Space in a development build, drawn in menu order")
    func display() throws {
        #expect(QuickAssistantShortcut.productionDefault.displayString == "⌃⌥Space")
        #expect(QuickAssistantShortcut.productionDefault.serialized == "ctrl+option+space")
        #expect(QuickAssistantShortcut.developmentDefault.displayString == "⌃⌥⇧Space")
        #expect(QuickAssistantShortcut.default == (ForeverLMRuntimeIdentity.isDevelopment ? .developmentDefault : .productionDefault))
        #expect(try QuickAssistantShortcut.parse("cmd+shift+option+ctrl+k")?.displayString == "⌃⌥⇧⌘K")
    }

    @Test("off, none and nothing turn the shortcut off")
    func off() throws {
        for text in ["off", "OFF", "none", "", "  "] {
            #expect(try QuickAssistantShortcut.parse(text) == nil)
        }
    }

    @Test("a shortcut that would take typing, or names no single key, is refused")
    func refusals() {
        for text in ["k", "shift+k", "space", "ctrl+option", "ctrl+a+b", "ctrl+escape", "hyper+k", "ctrl+delete"] {
            #expect(throws: QuickAssistantShortcut.ParseError.self, "\(text) should be refused") {
                _ = try QuickAssistantShortcut.parse(text)
            }
        }
    }

    @Test("never chosen is the default; off is off; a value this build cannot read is off, not a guess")
    func stored() throws {
        let defaults = try #require(UserDefaults(suiteName: "QuickAssistantShortcutTests-\(UUID().uuidString)"))
        #expect(QuickAssistantShortcut.stored(in: defaults) == .default)

        let chosen = try #require(try QuickAssistantShortcut.parse("shift+cmd+k"))
        QuickAssistantShortcut.store(chosen, in: defaults)
        #expect(QuickAssistantShortcut.stored(in: defaults) == chosen)

        QuickAssistantShortcut.store(nil, in: defaults)
        #expect(defaults.string(forKey: QuickAssistantShortcut.storageKey) == "off")
        #expect(QuickAssistantShortcut.stored(in: defaults) == nil)

        defaults.set("hyper+k", forKey: QuickAssistantShortcut.storageKey)
        #expect(QuickAssistantShortcut.stored(in: defaults) == nil)
    }

    @Test("a key press in the recorder spells its shortcut, whatever lock keys are on")
    func recordedPress() {
        let pressed = QuickAssistantShortcut(keyCode: UInt16(kVK_Space), modifierFlags: [.control, .option, .capsLock, .numericPad])
        #expect(pressed == .productionDefault)
        #expect(pressed?.isUsable == true)

        let bare = QuickAssistantShortcut(keyCode: UInt16(kVK_ANSI_K), modifierFlags: [.shift])
        #expect(bare?.serialized == "shift+k")
        #expect(bare?.isUsable == false, "⇧K is typing, not a shortcut")

        #expect(QuickAssistantShortcut(keyCode: UInt16(kVK_F5), modifierFlags: [])?.isUsable == true)
        #expect(QuickAssistantShortcut(keyCode: UInt16(kVK_Escape), modifierFlags: [.command]) == nil)
    }

    @Test("Markdown answers become paragraphs: headings in bold, bullets drawn, fences and rules dropped")
    func answerParagraphs() {
        let paragraphs = QuickAssistantAnswerText.paragraphs("""
        ## Added to your calendar

        I put **Read: GDF15** at 15:00.
        - one
          - nested
        ---
        ```
        code
        ```
        """)
        #expect(paragraphs == [
            .init(text: "Added to your calendar", isHeading: true),
            .init(text: "I put **Read: GDF15** at 15:00.\n• one\n    • nested", isHeading: false),
            .init(text: "code", isHeading: false),
        ])
    }
}

#endif
