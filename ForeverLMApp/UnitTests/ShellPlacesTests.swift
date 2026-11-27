import Foundation
import Testing
@testable import ForeverLM

// The place registry (docs/codex-shell-plan.md, Track 1): one descriptor per
// center tab, which the shell's switches read instead of listing places by
// hand. The tables below are what the hand-written switches said before the
// registry replaced them, so a descriptor that drifts fails here.

@Suite("The shell's place registry")
struct ShellPlacesTests {
    /// The titles `StudioCenterTab.title` returned from its own switch, and
    /// Plugins, the place added after it (Track 2).
    private static let titles: [StudioCenterTab: String] = [
        .chat: "Chat", .secondaryChat: "Chat", .secondaryReader: "Reader", .secondaryBrowser: "Browser", .liveMeeting: "Live Meeting", .reader: "Reader", .tasks: "Tasks", .activity: "Day", .activityLog: "Activity",
        .goals: "Goals", .courses: "Courses", .ideas: "Ideas", .notepad: "Pages", .sites: "Sites",
        .browser: "Browser", .videos: "Videos", .animations: "Animations", .artifacts: "Space",
        .memory: "Memory", .library: "Library", .knowledgeMap: "Canvas", .atlas: "Atlas",
        .plugins: "Plugins",
    ]

    /// The glyphs the tab strip's private `systemImage` returned. The Space's
    /// was Codex's grid until Plugins took it (2026-10-13); it is the strip's
    /// Spaces glyph since, so one glyph names one place.
    private static let glyphs: [StudioCenterTab: String] = [
        .chat: "bubble.left.and.bubble.right", .secondaryChat: "bubble.left.and.bubble.right",
        .secondaryReader: "doc.text", .secondaryBrowser: "safari", .liveMeeting: "waveform",
        .reader: "doc.text", .tasks: "clock.arrow.circlepath", .activity: "calendar", .activityLog: "chart.bar.doc.horizontal",
        .goals: "target", .courses: "graduationcap", .ideas: "lightbulb", .notepad: "note.text",
        .sites: "globe", .browser: "safari", .videos: "film", .animations: "sparkles.tv",
        .artifacts: "square.on.square", .memory: "brain", .library: "books.vertical",
        .knowledgeMap: "rectangle.3.group", .atlas: "point.3.connected.trianglepath.dotted",
        .plugins: "square.grid.2x2",
    ]

    @Test("Every center tab has a descriptor, and it names its own tab")
    func everyTabHasADescriptor() {
        for tab in StudioCenterTab.allCases {
            #expect(ShellPlaces.descriptor(for: tab).tab == tab)
        }
        #expect(ShellPlaces.all.map(\.tab) == StudioCenterTab.allCases)
        #expect(Set(Self.titles.keys) == Set(StudioCenterTab.allCases), "the tables below cover every tab")
        #expect(Set(Self.glyphs.keys) == Set(StudioCenterTab.allCases))
    }

    @Test("Titles and glyphs are what the hand-written switches said")
    func titlesAndGlyphsUnchanged() {
        for tab in StudioCenterTab.allCases {
            #expect(tab.title == Self.titles[tab], "\(tab)'s title")
            #expect(ShellPlaces.descriptor(for: tab).glyph == Self.glyphs[tab], "\(tab)'s glyph")
        }
    }

    @Test("The Reader's tab says Video while it holds a video, and nothing else changes")
    func readerTabNamesAVideo() {
        #expect(StudioCenterTab.reader.stripTitle(readerShowsVideo: true) == "Video")
        #expect(StudioCenterTab.reader.stripTitle(readerShowsVideo: false) == "Reader")
        #expect(StudioCenterTab.reader.stripSystemImage(readerShowsVideo: true) == "play.rectangle")
        #expect(StudioCenterTab.reader.stripSystemImage(readerShowsVideo: false) == "doc.text")
        for tab in StudioCenterTab.allCases where tab != .reader {
            #expect(tab.stripTitle(readerShowsVideo: true) == tab.title)
        }
        // A chat's tab draws one round bubble; every other tab its place's glyph.
        #expect(StudioCenterTab.chat.stripSystemImage(readerShowsVideo: false) == "message")
        #expect(StudioCenterTab.secondaryChat.stripSystemImage(readerShowsVideo: false) == "message")
        for tab in StudioCenterTab.allCases where ![.reader, .chat, .secondaryChat].contains(tab) {
            #expect(tab.stripSystemImage(readerShowsVideo: true) == ShellPlaces.descriptor(for: tab).glyph)
        }
    }

    @Test("The Space's tab names the place it shows; no other tab takes that name")
    func spaceTabNamesItsPlace() {
        #expect(StudioCenterTab.artifacts.stripTitle(readerShowsVideo: false, spaceTitle: "Plan") == "Plan")
        #expect(StudioCenterTab.artifacts.stripTitle(readerShowsVideo: false) == "Space")
        #expect(StudioCenterTab.reader.stripTitle(readerShowsVideo: false, spaceTitle: "Plan") == "Reader")
        #expect(StudioCenterTab.notepad.stripTitle(readerShowsVideo: false, spaceTitle: "Plan") == "Pages")
    }

    @Test("A glyph a module also draws elsewhere is the same symbol there")
    @MainActor
    func glyphsAgreeWithTheirModules() {
        #expect(ShellPlaces.descriptor(for: .activity).glyph == DayActivityReaderPane.systemImage)
        #expect(ShellPlaces.descriptor(for: .animations).glyph == ArtifactKind.animation.symbolName)
        #expect(ShellPlaces.descriptor(for: .memory).glyph == MemoryReviewSession.sidebarIcon)
        #expect(ShellPlaces.descriptor(for: .library).glyph == StudioRailItem.library.systemImage)
        #expect(ShellPlaces.descriptor(for: .knowledgeMap).glyph == KnowledgeMap.symbolName)
        #expect(ShellPlaces.descriptor(for: .atlas).glyph == AtlasPane.systemImage)
        // The strip's rows draw their place's glyph.
        #expect(ShellPlaces.descriptor(for: .artifacts).glyph == StudioRailItem.space.systemImage)
        #expect(ShellPlaces.descriptor(for: .plugins).glyph == StudioRailItem.plugins.systemImage)
        #expect(StudioRailItem.plugins.title == StudioCenterTab.plugins.title)
    }

    @Test("A glyph names one place")
    func glyphsAreDistinct() {
        let glyphs = ShellPlaces.all.filter { !StudioCenterTab.transientTabs.contains($0.tab) }.map(\.glyph)
        #expect(Set(glyphs).count == glyphs.count)
    }

    @Test("The shell is Codex's parts; the modules are ForeverLM's")
    func shellAndModules() {
        #expect(ShellModule.allCases.filter(\.isShell) == [.chat, .space, .plugins, .settings, .scheduled])
        #expect(ShellPlaces.tabs(of: .chat) == [.chat, .secondaryChat])
        #expect(ShellPlaces.tabs(of: .canvas) == [.knowledgeMap, .atlas])
        #expect(ShellPlaces.tabs(of: .space) == [.artifacts, .notepad, .sites, .goals, .ideas])
        #expect(ShellPlaces.tabs(of: .plugins) == [.plugins])
        #expect(ShellPlaces.descriptor(for: .plugins).sidebar == nil, "Plugins has the card to itself, as the Library does")
        #expect(ShellPlaces.descriptor(for: .plugins).role == .list)
        // Only the chats are threads: the chat's minimum width follows it.
        #expect(Set(ShellPlaces.all.filter { $0.role == .thread }.map(\.tab)) == [.chat, .secondaryChat])
    }

    @Test("The Canvas gate closes the Canvas module's places")
    func canvasGateIsTheCanvasModule() {
        #expect(BetaFeatures.canvasCenterTabs == [.knowledgeMap, .atlas])
    }

    @Test("Every tab but the transient side panes is permanent, so a stored layout is reconciled to hold it")
    func permanentTabsCoverTheRegistry() {
        #expect(StudioCenterTab.transientTabs == [.secondaryChat, .secondaryReader, .secondaryBrowser, .liveMeeting])
        #expect(Set(StudioCenterTab.permanentTabs) == Set(StudioCenterTab.allCases).subtracting(StudioCenterTab.transientTabs))
        #expect(StudioCenterTab.permanentTabs.count == Set(StudioCenterTab.permanentTabs).count)
    }

    @Test("A pane's minimum width is a chat's for a thread and the ordinary one for the rest")
    func minimumWidthFollowsTheRole() {
        for tab in StudioCenterTab.allCases {
            let width = StudioCenterTabGroupSizing.minimumWidth(for: [.init(tabs: [tab], activeTab: tab)])
            let isChat = tab == .chat || tab == .secondaryChat
            #expect(width == (isChat
                ? StudioCenterTabGroupSizing.minimumChatContentWidth
                : StudioCenterTabGroupSizing.minimumContentWidth), "\(tab)")
        }
    }
}

// MARK: - Home and the Space, read from the registry

/// The window defaults a window's arrangement and an opened notebook write,
/// put back after each test: the unit host's defaults are the real ones.
@MainActor
private func capturingShellWindowDefaults() -> () -> Void {
    let keys = ["studio.centerTabGroups.v1", "studio.navigationRailVisible", NotebookRecency.preferenceKey]
    let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
    let activeNotebookID = ActiveNotebookPreference.notebookID
    return {
        for (key, value) in zip(keys, saved) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        ActiveNotebookPreference.notebookID = activeNotebookID
    }
}

@Suite("Home and the Space, from the place registry")
@MainActor
struct ShellPlacesWindowTests {
    /// The rules `showsSpace` and `isOnHome` spelled out by hand before the
    /// registry, for one pane in front: the Space, Sites, the global Pages and
    /// the Courses list draw the Space's sidebar; the Library, the Canvas, the
    /// Atlas and Memory have the window to themselves, and so do Plugins and
    /// Home, the places added after; everything else is Home's.
    private static func expected(
        _ tab: StudioCenterTab,
        notebookPages: Bool,
        coursePage: Bool
    ) -> (showsSpace: Bool, isOnHome: Bool) {
        let showsSpace: Bool
        switch tab {
        case .artifacts, .sites: showsSpace = true
        case .notepad: showsSpace = !notebookPages
        case .courses: showsSpace = !coursePage
        default: showsSpace = false
        }
        let ownWindow: Set<StudioCenterTab> = [.library, .knowledgeMap, .atlas, .memory, .plugins]
        return (showsSpace, !showsSpace && !ownWindow.contains(tab))
    }

    @Test("Every tab in front of one pane: the same Space and Home answers as the hand-written rules")
    func everyTabAlone() {
        let restore = capturingShellWindowDefaults()
        defer { restore() }
        let window = StudioWindowState()
        for notebookPages in [false, true] {
            for coursePage in [false, true] {
                window.artifactCanvasNotebookID = notebookPages ? "nb-zara" : nil
                window.coursePageID = coursePage ? "course-acme" : nil
                for tab in StudioCenterTab.allCases {
                    window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [tab], activeTab: tab)])
                    let want = Self.expected(tab, notebookPages: notebookPages, coursePage: coursePage)
                    #expect(window.showsSpace == want.showsSpace, "\(tab) showsSpace, notebook page \(notebookPages), course page \(coursePage)")
                    #expect(window.isOnHome == want.isOnHome, "\(tab) isOnHome, notebook page \(notebookPages), course page \(coursePage)")
                }
            }
        }
    }

    @Test("Every pair of tabs side by side: either pane's place decides, as before")
    func everyPairSideBySide() {
        let restore = capturingShellWindowDefaults()
        defer { restore() }
        let window = StudioWindowState()
        for left in StudioCenterTab.allCases {
            for right in StudioCenterTab.allCases where right != left {
                window.centerTabGroups = StudioCenterTabGroups(groups: [
                    .init(tabs: [left], activeTab: left),
                    .init(tabs: [right], activeTab: right),
                ])
                let a = Self.expected(left, notebookPages: false, coursePage: false)
                let b = Self.expected(right, notebookPages: false, coursePage: false)
                let showsSpace = a.showsSpace || b.showsSpace
                #expect(window.showsSpace == showsSpace, "\(left) | \(right)")
                #expect(window.isOnHome == (a.isOnHome && b.isOnHome), "\(left) | \(right)")
            }
        }
    }

    @Test("A window holding a notebook is neither on Home nor showing the Space")
    func notebookWindow() {
        let restore = capturingShellWindowDefaults()
        defer { restore() }
        let window = StudioWindowState()
        window.NotebookID = "nb-zara"
        for tab in StudioCenterTab.allCases {
            window.centerTabGroups = StudioCenterTabGroups(groups: [.init(tabs: [tab], activeTab: tab)])
            #expect(!window.showsSpace, "\(tab)")
            #expect(!window.isOnHome, "\(tab)")
        }
        window.NotebookID = nil
    }
}
