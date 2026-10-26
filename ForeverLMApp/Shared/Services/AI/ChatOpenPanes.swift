import Foundation

/// What the chat's window has open, as the `list_open_panes` chat tool
/// reports it.
///
/// A learner who asks "what does figure 2D show?" with a paper open in the
/// Reader beside the chat means that paper, whether or not they dragged it
/// into the chat's context (product owner, 2026-09-22: "it could be like, oh, I see
/// that this paper is open right now. So probably you're talking about that
/// one."). The manager has no window, so the pane showing it builds this
/// snapshot from its `StudioWindowState` on each call; this type only holds
/// the facts and says them to the model.
struct ChatOpenPanes: Equatable {
    /// One thing a tab holds.
    enum Content: Equatable {
        /// A source in the learner's library, with where the Reader stands in
        /// it ("PDF page 3 of 15") when it knows.
        case source(id: String, title: String, kind: String, position: String?)
        /// A web page that is not a library source: a cited page in the
        /// Reader, or the Browser's tab.
        case webPage(title: String, url: String)
        /// A Doc, Site or animation.
        case artifact(id: String, title: String)
        /// A chat; `isThisChat` when it is the conversation asking.
        case chat(title: String, isThisChat: Bool)
        /// The day the Activity pane is turned to, "2026-09-22".
        case day(String)
        /// The course whose page the Courses tab shows (courses-design.md).
        case course(id: String, title: String)
        /// The flashcard the Memory pane has in front of the learner.
        case card(ChatContextAdditions.CardOnScreen)
    }

    struct Tab: Equatable {
        /// The tab's name as the learner sees it: Reader, Docs, Activity.
        var name: String
        var contents: [Content] = []
    }

    struct Pane: Equatable {
        /// The tab drawn in this pane.
        var onScreen: Tab
        /// Tabs behind it that still hold something the learner opened — a
        /// Reader with a paper loaded behind Docs. Tabs that only show
        /// a list are left out.
        var behind: [Tab] = []
    }

    /// The notebook a window holds, whose workspace draws it.
    struct Notebook: Equatable {
        var id: String
        var title: String
    }

    struct Window: Equatable {
        /// True for the window this chat is shown in.
        var isChatsWindow: Bool
        /// Left to right.
        var panes: [Pane]
        /// Sources and pages on screen in this window that no pane's tab
        /// accounts for: a second Reader, a Site shown inside Artifacts.
        var alsoOnScreen: [Content] = []
        /// Where each video playing or paused in this window stands, by
        /// source id, as its Reader last reported it.
        var videoPlayheads: [String: VideoPlayhead] = [:]
        /// The notebook the window holds; nil for the library workspace.
        var notebook: Notebook? = nil
    }

    /// A video Reader's playhead as the window holds it
    /// (`StudioWindowState.videoPlayheadsOnScreen`): where the player is, and
    /// whether it is playing — nil until the page has said.
    struct VideoPlayhead: Equatable, Sendable {
        var seconds: Double
        var isPlaying: Bool?

        init(seconds: Double, isPlaying: Bool? = nil) {
            self.seconds = max(0, seconds.isFinite ? seconds : 0)
            self.isPlaying = isPlaying
        }

        /// The moment a message sent now is about.
        var moment: ChatContextAdditions.VideoMoment {
            ChatContextAdditions.VideoMoment(at: Int(seconds.rounded(.down)), playing: isPlaying)
        }

        /// What `list_open_panes` says after the video's name: "paused at 26:51".
        var positionLabel: String {
            ChatContextAdditions.playheadPhrase(moment)
        }
    }

    var windows: [Window]

    /// The flashcard this chat was opened about (Ask in Chat on a card to
    /// check). It is the chat's card for as long as the chat lives, whatever
    /// else comes to fill the pane the Memory pane was in.
    var pinnedCard: ChatContextAdditions.CardOnScreen? = nil

    /// "Left", "Right"; "Middle" in a third pane; nil for a lone pane.
    static func positionName(index: Int, count: Int) -> String? {
        guard count > 1 else { return nil }
        if index == 0 { return "Left" }
        if index == count - 1 { return "Right" }
        return "Middle"
    }

    private var windowsChatsFirst: [Window] {
        windows.filter(\.isChatsWindow) + windows.filter { !$0.isChatsWindow }
    }

    /// Every library source the panes show, on-screen panes first, each once.
    var sourceIDs: [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for window in windowsChatsFirst {
            let contents = window.panes.flatMap(\.onScreen.contents)
                + window.alsoOnScreen
                + window.panes.flatMap(\.behind).flatMap(\.contents)
            for case let .source(id, _, _, _) in contents where seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    /// The library sources on screen in any window — each pane's drawn tab,
    /// then what no pane accounts for — each once, the chat's own window
    /// first. Tabs behind a drawn tab are left out. A paper open in the
    /// Reader of a second window is as open as one beside the chat (product
    /// owner, 2026-10-16: the chat "should automatically take into account
    /// into the context whatever is opened"). Every message the learner
    /// sends carries this list (`ChatContextAdditions.onScreen`), a video
    /// with the moment its player is at.
    var sourcesOnScreen: [ChatContextAdditions.OnScreen] {
        var seen = Set<String>()
        var shown: [ChatContextAdditions.OnScreen] = []
        for window in windowsChatsFirst {
            let contents = window.panes.flatMap(\.onScreen.contents) + window.alsoOnScreen
            for case let .source(id, title, kind, _) in contents where seen.insert(id).inserted {
                shown.append(ChatContextAdditions.OnScreen(
                    id: id,
                    title: title,
                    kind: kind,
                    moment: window.videoPlayheads[id]?.moment
                ))
            }
        }
        return shown
    }

    /// The flashcard a Memory pane in any window has in front of the learner,
    /// the chat's own window first. Every message the learner sends carries
    /// it (`ChatContextAdditions.cardFraming`), so "this question is phrased
    /// weird" means that card.
    ///
    /// A chat opened about a card (`pinnedCard`) is told of that card, read
    /// live while the Memory pane still shows it (so a turned-over card says
    /// so) and as it was when asked about once it does not (product owner,
    /// 2026-10-26: Ask in Chat on a card must "ALWAYS" be for that card,
    /// "regardless of whatever else is open on the side").
    var cardOnScreen: ChatContextAdditions.CardOnScreen? {
        var shown: ChatContextAdditions.CardOnScreen?
        search: for window in windowsChatsFirst {
            for case let .card(card) in window.panes.flatMap(\.onScreen.contents) {
                shown = card
                break search
            }
        }
        guard let pinnedCard else { return shown }
        return shown?.id == pinnedCard.id ? shown : pinnedCard
    }

    /// The windows with these sources (and the card, by its id) taken out,
    /// wherever they are shown: what a chat is told once the learner has left
    /// them out of it with the × on their chip over its composer. A Reader showing only a left-out
    /// source reads as an empty Reader, and a left-out video's playhead goes
    /// with it, so typing beside it no longer pauses it.
    func leavingOut(_ sourceIDs: Set<String>) -> ChatOpenPanes {
        guard !sourceIDs.isEmpty else { return self }
        func kept(_ contents: [Content]) -> [Content] {
            contents.filter { content in
                switch content {
                case let .source(id, _, _, _): return !sourceIDs.contains(id)
                // The card chip's × is left out the same way, by the card's id.
                case let .card(card): return !sourceIDs.contains(card.id)
                default: return true
                }
            }
        }
        let pinned = pinnedCard.flatMap { sourceIDs.contains($0.id) ? nil : $0 }
        return ChatOpenPanes(windows: windows.map { window in
            var window = window
            window.panes = window.panes.map { pane in
                var pane = pane
                pane.onScreen.contents = kept(pane.onScreen.contents)
                pane.behind = pane.behind.compactMap { tab in
                    var tab = tab
                    tab.contents = kept(tab.contents)
                    return tab.contents.isEmpty ? nil : tab
                }
                return pane
            }
            window.alsoOnScreen = kept(window.alsoOnScreen)
            window.videoPlayheads = window.videoPlayheads.filter { !sourceIDs.contains($0.key) }
            return window
        }, pinnedCard: pinned)
    }

    /// Whether a pane draws the card with this id.
    private func showsCard(_ id: String) -> Bool {
        windows.contains { window in
            window.panes.flatMap(\.onScreen.contents).contains {
                if case let .card(card) = $0 { return card.id == id }
                return false
            }
        }
    }

    /// The tool result.
    var text: String {
        guard windows.contains(where: { !$0.panes.isEmpty }) else {
            return "No ForeverLM window is showing anything the learner opened."
        }
        var lines: [String] = []
        for window in windowsChatsFirst where !window.panes.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(window.isChatsWindow
                ? "The window this chat is in:"
                : "Another ForeverLM window:")
            if let notebook = window.notebook {
                lines.append("- Notebook open in this window: \u{201C}\(notebook.title)\u{201D} (notebook_id: \(notebook.id)); the window shows its sources beside the panes below.")
            }
            for (index, pane) in window.panes.enumerated() {
                let position = Self.positionName(index: index, count: window.panes.count)
                let label = position.map { "\($0) pane" } ?? "The only pane"
                lines.append("- \(label), on screen: \(Self.describe(pane.onScreen))")
                for tab in pane.behind {
                    lines.append("  - Behind it: \(Self.describe(tab))")
                }
            }
            if !window.alsoOnScreen.isEmpty {
                let shown = window.alsoOnScreen.map(Self.describe).joined(separator: "; ")
                lines.append("- Also on screen in this window: \(shown).")
            }
        }
        if let pinnedCard, cardOnScreen?.id == pinnedCard.id, !showsCard(pinnedCard.id) {
            lines.append("")
            lines.append("This chat was opened about \(Self.describe(.card(pinnedCard))).")
        }
        if !sourceIDs.isEmpty {
            lines.append("")
            lines.append(
                "A source listed here is in the learner's library whether or not it is attached to this chat: "
                + "pass its source_id to inspect_paper_figure, show_source_image or get_source_content. "
                + "When the learner says \"this paper\", \"figure 2D\" or \"what I'm reading\" without naming a source, "
                + "they most likely mean the one on screen in this chat's window; if two on-screen sources could be meant, ask which."
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ tab: Tab) -> String {
        guard !tab.contents.isEmpty else { return tab.name + "." }
        let shown = tab.contents.map(describe).joined(separator: "; ")
        return "\(tab.name) — \(shown)."
    }

    private static func describe(_ content: Content) -> String {
        switch content {
        case let .source(id, title, kind, position):
            var line = "\(kind) \u{201C}\(title)\u{201D} (source_id: \(id))"
            if let position { line += ", \(position)" }
            return line
        case let .webPage(title, url):
            return title.isEmpty ? "web page \(url)" : "web page \u{201C}\(title)\u{201D} (\(url))"
        case let .artifact(id, title):
            return "\u{201C}\(title)\u{201D} (artifact_id: \(id))"
        case let .chat(title, isThisChat):
            return isThisChat ? "this conversation" : "the chat \u{201C}\(title)\u{201D}"
        case let .day(date):
            return "turned to \(date)"
        case let .course(id, title):
            return "the course \u{201C}\(title)\u{201D} (course_id: \(id))"
        case let .card(card):
            var line = "the flashcard \u{201C}\(card.question)\u{201D} (card_id: \(card.id)), answer: \u{201C}\(card.answer)\u{201D}"
            if let sourceID = card.sourceID { line += ", from source_id: \(sourceID)" }
            line += card.answerShown ? "; the learner has turned it over" : "; the learner has not turned it over yet"
            return line
        }
    }
}
