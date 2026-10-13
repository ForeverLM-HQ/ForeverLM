import AppKit
import SwiftUI
import Testing
@testable import ForeverLM

/// The Studio window enables text selection for everything inside it, which on
/// macOS hosts every `Text` in an AppKit text element. A `Text` that also carries
/// its own accessibility label then has two owners for that label, and on macOS 27
/// the SwiftUI node and the platform element read it from each other until the
/// stack overflows — or, where it stops short of that, the label is dropped. The
/// answer footer's timestamp was the first casualty (2026-09-03). This walks the
/// hosted footer the way an accessibility client does: every element, every label.
@Suite("Review chat answer footer accessibility")
struct ReviewChatAnswerBlockAccessibilityTests {
    /// The product owner, 2026-10-06: "make the app more slick; kind of like the chatgpt
    /// app … fewer buttons". The footer is Copy, Side question and a ⋯; the
    /// time is Copy's tooltip and the ⋯'s first line, never a selectable
    /// stamp with a label of its own in the row (the 2026-09-03 crash).
    @MainActor
    @Test("the footer is Copy and the ⋯, with the reply's time on Copy's tooltip and no stamp in the row")
    func footerIsCopyAndMore() {
        let unsaved = ReviewChatSaveToNoteControl(savedDocID: nil, save: {}, open: { _ in })
        let labels = Self.footerLabels(skipQuizQuestion: nil, saveToNote: unsaved)

        #expect(labels.contains("Copy answer"), "Copy missing from \(labels)")
        #expect(labels.contains("More actions"), "⋯ missing from \(labels)")
        #expect(labels.contains { $0.hasPrefix("Copy answer — ") }, "time missing from Copy's tooltip in \(labels)")
        #expect(!labels.contains { $0.hasPrefix("Response time,") })
        // Moved into the ⋯, not drawn in the row.
        #expect(!labels.contains("Fork conversation"))
        #expect(!labels.contains("Save to note"))
        #expect(!labels.contains("More details"))
    }

    /// The product owner, 2026-09-27: Skip is "one of the small icons" in the footer,
    /// and the thumbs are gone from it.
    @MainActor
    @Test("the footer draws Skip only when a quiz question offers it, and no thumbs")
    func skipIconJoinsTheFooterWhenOffered() {
        let skipLabel = "Skip this question (no grade, and it counts as not right)"
        let offered = Self.footerLabels(skipQuizQuestion: {})
        let plain = Self.footerLabels(skipQuizQuestion: nil)

        #expect(offered.contains(skipLabel), "skip icon missing from \(offered)")
        #expect(!plain.contains(skipLabel))
        for labels in [offered, plain] {
            #expect(!labels.contains("Like response"))
            #expect(!labels.contains("Dislike response"))
        }
    }

    /// The ⋯ opens with the reply's time, then Save to Note (Open Note once
    /// the answer has its Doc), Branch in New Chat, Discuss in New Chat in a
    /// memory review, and More Details. A topic card keeps More Details only.
    @Test("the ⋯ lists the time, Save to Note or Open Note, Branch in New Chat, Discuss in New Chat and More Details")
    func moreMenuHoldsWhatLeftTheRow() {
        let unsaved = ReviewChatReplyMenu.items(
            timeLine: "Today, 23:05",
            savedDocID: .some(nil),
            offersDiscussInNewChat: false,
            offersMoreDetails: true,
            asideActionsOnly: false
        )
        #expect(unsaved == [.time("Today, 23:05"), .saveToNote, .branch, .moreDetails])
        #expect(unsaved.map(\.title) == ["Today, 23:05", "Save to Note", "Branch in New Chat", "More Details"])

        let saved = ReviewChatReplyMenu.items(
            timeLine: "Today, 23:05",
            savedDocID: .some("doc-1"),
            offersDiscussInNewChat: true,
            offersMoreDetails: true,
            asideActionsOnly: false
        )
        #expect(saved == [.time("Today, 23:05"), .openNote(docID: "doc-1"), .branch, .discussInNewChat, .moreDetails])
        #expect(saved[1].title == "Open Note")

        // A reply still without prose offers no Save to Note.
        let noProse = ReviewChatReplyMenu.items(
            timeLine: nil, savedDocID: nil, offersDiscussInNewChat: false, offersMoreDetails: false, asideActionsOnly: false
        )
        #expect(noProse == [.branch])

        let onTopicCard = ReviewChatReplyMenu.items(
            timeLine: "Today, 23:05",
            savedDocID: .some(nil),
            offersDiscussInNewChat: true,
            offersMoreDetails: true,
            asideActionsOnly: true
        )
        #expect(onTopicCard == [.moreDetails])
    }

    @Test("the reply's time reads Today, Yesterday, or the day, then the time")
    func replyTimeLine() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_GB")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 23, minute: 30)))
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
        }
        #expect(ReviewChatReplyMenu.timeLine(try at(2026, 10, 6, 23, 5), now: now, calendar: calendar, locale: locale) == "Today, 23:05")
        #expect(ReviewChatReplyMenu.timeLine(try at(2026, 10, 5, 10, 12), now: now, calendar: calendar, locale: locale) == "Yesterday, 10:12")
        let earlier = ReviewChatReplyMenu.timeLine(try at(2026, 10, 3, 14, 40), now: now, calendar: calendar, locale: locale)
        #expect(earlier.hasSuffix(", 14:40") && earlier.contains("3") && !earlier.contains("2026"), "\(earlier)")
        let lastYear = ReviewChatReplyMenu.timeLine(try at(2025, 12, 30, 18, 0), now: now, calendar: calendar, locale: locale)
        #expect(lastYear.hasSuffix(", 18:00") && lastYear.contains("2025"), "\(lastYear)")
    }

    /// The suggested questions are buttons a client hears as "Ask: …", once
    /// each, inside a group named for what they are, and automation tells
    /// them apart by their place.
    @MainActor
    @Test("each suggested question is a button labelled with what it asks, once, in a named group")
    func suggestedQuestionsSpeakTheirQuestions() {
        let questions = ["Why do cristae fold?", "What sets their width?"]
        let cards = ChatSuggestedQuestionCards(questions: questions, fontSize: 17, maxWidth: 714, send: { _ in })
        let elements = Self.accessibilityElements(of: cards, size: NSSize(width: 714, height: 200))
        let labels = elements.flatMap(\.spokenStrings)
        #expect(labels.contains("Suggested questions"), "group name missing from \(labels)")
        for question in questions {
            let cardStrings = elements.filter { $0.spokenStrings.contains("Ask: \(question)") }.map(\.spokenStrings)
            #expect(cardStrings.count == 1, "card for \(question) missing or doubled in \(labels)")
            // No tooltip repeating the question after its label.
            #expect(cardStrings.allSatisfy { !$0.contains(question) }, "\(question) spoken twice: \(cardStrings)")
        }
        let identifiers = elements.map(\.identifier)
        #expect(identifiers.contains("mac.chatFollowUp.0"), "card ids: \(identifiers)")
        #expect(identifiers.contains("mac.chatFollowUp.1"))

        // A lone card keeps its own label: a group of one would hand it the
        // group's name.
        let lone = ChatSuggestedQuestionCards(questions: ["Why do cristae fold?"], fontSize: 17, maxWidth: 714, send: { _ in })
        let loneLabels = Self.spokenLabels(of: lone, size: NSSize(width: 714, height: 200))
        #expect(loneLabels.contains("Ask: Why do cristae fold?"), "lone card label missing from \(loneLabels)")
    }

    /// Hosts one finished reply's footer under a selectable window, the way
    /// `StudioWindowRoot` does, and reads every label an assistive client hears.
    @MainActor
    private static func footerLabels(
        skipQuizQuestion: (() -> Void)?,
        saveToNote: ReviewChatSaveToNoteControl? = nil,
        asideActionsOnly: Bool = false
    ) -> [String] {
        let message = ReviewSessionManager.Message(
            role: .assistant,
            content: "Mitochondria set the pace of the cell.",
            createdAt: Date(timeIntervalSince1970: 1_756_900_000)
        )
        let footer = ReviewChatAnswerBlock(
            messages: [message],
            saveToNote: saveToNote,
            canFork: false,
            fork: {},
            skipQuizQuestion: skipQuizQuestion,
            asideActionsOnly: asideActionsOnly
        ) {
            Text(message.content)
        }
        .frame(width: 480)
        return spokenLabels(of: footer, size: NSSize(width: 480, height: 160))
    }

    /// Hosts a view under a selectable window, the way `StudioWindowRoot`
    /// does, and reads every label an assistive client hears.
    @MainActor
    private static func spokenLabels<V: View>(of view: V, size: NSSize) -> [String] {
        accessibilityElements(of: view, size: size).flatMap(\.spokenStrings)
    }

    /// Hosts a view under a selectable window, the way `StudioWindowRoot`
    /// does, and reads every element an assistive client reaches.
    @MainActor
    private static func accessibilityElements<V: View>(of view: V, size: NSSize) -> [AccessibilityWalk.Element] {
        // Mirrors `StudioWindowRoot`, which makes the whole window selectable.
        let hosting = NSHostingView(rootView: view.textSelection(.enabled))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // SwiftUI builds its accessibility tree from a rendered hierarchy, so
        // show the window off every screen and let a few display cycles run.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.displayIfNeeded()
        }

        let elements = AccessibilityWalk.withAssistiveClient {
            AccessibilityWalk.elements(under: hosting)
        }
        window.orderOut(nil)
        window.contentView = nil
        return elements
    }
}

/// Reads an accessibility tree the way the AX server does on behalf of a client:
/// every child, and on each one the title, label, value and help.
enum AccessibilityWalk {
    struct Element {
        let role: String
        let spokenStrings: [String]
        /// What automation finds it by; not spoken.
        let identifier: String
    }

    /// SwiftUI only materialises a hosting view's accessibility tree while an
    /// assistive client is attached, which VoiceOver signals by setting the
    /// application's `AXEnhancedUserInterface` attribute. Set it for the walk.
    @MainActor
    static func withAssistiveClient<T>(_ body: () -> T) -> T {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApplication.shared.accessibilitySetValue(true as CFBoolean, forAttribute: attribute)
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        defer { NSApplication.shared.accessibilitySetValue(false as CFBoolean, forAttribute: attribute) }
        return body()
    }

    /// SwiftUI's `AccessibilityNode` objects answer the `NSAccessibility`
    /// selectors but do not pass a Swift cast to the protocol, so read them the
    /// way the AX server does: by message.
    @MainActor
    static func elements(under root: Any, limit: Int = 2_000) -> [Element] {
        var result: [Element] = []
        var queue: [Any] = [root]
        while !queue.isEmpty, result.count < limit {
            let element = queue.removeFirst() as AnyObject
            var spoken: [String] = []
            for selector in ["accessibilityTitle", "accessibilityLabel", "accessibilityValue", "accessibilityHelp"] {
                let text = string(message(element, selector))
                if !text.isEmpty { spoken.append(text) }
            }
            result.append(Element(
                role: string(message(element, "accessibilityRole")),
                spokenStrings: spoken,
                identifier: string(message(element, "accessibilityIdentifier"))
            ))
            queue.append(contentsOf: (message(element, "accessibilityChildren") as? [Any]) ?? [])
        }
        return result
    }

    private static func message(_ object: AnyObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private static func string(_ value: Any?) -> String {
        (value as? String) ?? (value as? NSAttributedString)?.string ?? ""
    }
}

/// Try again and Edit on the newest turn, as Codex's.
@Suite("Try again and Edit on the newest turn")
@MainActor
struct ChatTryAgainAndEditTests {
    private typealias Message = ReviewSessionManager.Message

    @Test("The newest reply's ⋯ offers Try Again and Try Again With after its time")
    func menuOffersTryAgain() {
        let items = ReviewChatReplyMenu.items(
            timeLine: "Today, 23:05",
            savedDocID: .some(nil),
            offersDiscussInNewChat: false,
            offersMoreDetails: true,
            asideActionsOnly: false,
            offersTryAgain: true
        )
        #expect(items == [.time("Today, 23:05"), .tryAgain, .tryAgainWith, .saveToNote, .branch, .moreDetails])
        #expect(items[1].title == "Try Again")
        #expect(items[2].title == "Try Again With")
    }

    @Test("The settled turn is the newest message with a reply saved on its row")
    func newestSettledTurn() {
        let older = Message(role: .user, content: "what is LTP?", exchangeID: "x1", exchangeField: .userAnswer)
        let olderReply = Message(role: .assistant, content: "Long-term potentiation …", exchangeID: "x1", exchangeField: .evaluation)
        let newest = Message(role: .user, content: "and LTD?", exchangeID: "x2", exchangeField: .userAnswer)
        let tool = Message(role: .tool, content: "", toolActivity: nil)
        let reply = Message(role: .assistant, content: "Long-term depression …", exchangeID: "x2", exchangeField: .evaluation)

        #expect(ReviewSessionManager.newestSettledTurn(in: [older, olderReply, newest, tool, reply])
            == .init(userIndex: 2, exchangeID: "x2"))
        // A reply still being written (not yet saved on the row) is not settled.
        let streaming = Message(role: .assistant, content: "Long-term dep")
        #expect(ReviewSessionManager.newestSettledTurn(in: [older, olderReply, newest, streaming]) == nil)
        // A message whose row was never saved cannot be taken back.
        let unsaved = Message(role: .user, content: "and STDP?")
        #expect(ReviewSessionManager.newestSettledTurn(in: [older, olderReply, unsaved, reply]) == nil)
    }

    @Test("Edit is offered for words and typed quotes, not for pictures, passages, asides or guesses")
    func editableMessages() {
        #expect(ChatEditMessage.isEditable(Message(role: .user, content: "and LTD?", exchangeID: "x2", exchangeField: .userAnswer)))
        #expect(!ChatEditMessage.isEditable(Message(role: .user, content: "and LTD?")))
        #expect(!ChatEditMessage.isEditable(Message(role: .assistant, content: "reply", exchangeID: "x2", exchangeField: .evaluation)))
        let aside = Message(
            role: .user, content: "why?",
            contextualContent: ChatSideQuestion.contextContent(openQuestion: nil, aboutReply: "the reply", referenceContext: nil),
            exchangeID: "x3", exchangeField: .userAnswer
        )
        #expect(!ChatEditMessage.isEditable(aside))
    }
}

/// Find in chat and the jump arrow, as Codex's.
@Suite("Find in chat and Jump to latest")
@MainActor
struct ChatFindTests {
    private typealias Message = ReviewSessionManager.Message

    @Test("Find lands on the newest matching turn, then steps and wraps")
    func stepsThroughMatches() {
        let messages = [
            Message(role: .user, content: "What is calcium doing in LTP?"),
            Message(role: .assistant, content: "Calcium enters through NMDA receptors."),
            Message(role: .user, content: "and dopamine?"),
            Message(role: .assistant, content: "Dopamine gates plasticity."),
            Message(role: .user, content: "Back to CALCIUM: how much?"),
            Message(role: .assistant, content: "Micromolar."),
        ]
        let blocks = ReviewChatTranscriptBlock.grouping(messages)
        let matches = ChatFind.matchingBlockIDs("calcium", in: blocks)
        #expect(matches.count == 3)

        let find = ChatFind()
        find.query = "calcium"
        find.step(in: blocks)
        #expect(find.currentMatchID == matches.last)
        #expect(find.status == "3 of 3")
        find.step(in: blocks)
        #expect(find.currentMatchID == matches.first)
        find.step(in: blocks, backwards: true)
        #expect(find.currentMatchID == matches.last)

        find.query = "serotonin"
        #expect(find.status.isEmpty)
        find.step(in: blocks)
        #expect(find.currentMatchID == nil)
        #expect(find.status == "No matches")
        find.close()
        #expect(!find.isVisible && find.query.isEmpty)
    }

    @Test("The arrow shows once the view is well above the end, past the empty band under the last row")
    func jumpToLatestThreshold() {
        #expect(!ChatJumpToLatest.isScrolledUp(offsetY: 900, visibleHeight: 500, contentHeight: 1400, bottomReserve: 0))
        #expect(!ChatJumpToLatest.isScrolledUp(offsetY: 600, visibleHeight: 500, contentHeight: 1400, bottomReserve: 250))
        #expect(ChatJumpToLatest.isScrolledUp(offsetY: 200, visibleHeight: 500, contentHeight: 1400, bottomReserve: 250))
    }
}
