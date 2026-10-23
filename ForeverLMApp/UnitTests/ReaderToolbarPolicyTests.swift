import AppKit
import Testing
@testable import ForeverLM

struct ReaderToolbarPolicyTests {
    @Test("reader toolbar tiers move from richest to narrowest")
    func fitOrderAndWidths() {
        #expect(ReaderToolbarDensity.fitOrder == [.expanded, .standard, .compact])
        #expect(ReaderToolbarDensity.expanded.minimumIdentityWidth
            > ReaderToolbarDensity.standard.minimumIdentityWidth)
        #expect(ReaderToolbarDensity.standard.minimumIdentityWidth
            > ReaderToolbarDensity.compact.minimumIdentityWidth)
    }

    @Test("compact reader toolbar retains only width-safe inline chrome")
    func compactVisibility() {
        let compact = ReaderToolbarDensity.compact
        #expect(!compact.showsSourceIcon)
        #expect(!compact.showsLoadingIndicator)
        #expect(!compact.showsStatusText)
        #expect(compact.pageActionStyle == .hidden)
    }

    @Test("standard tier removes labels before removing commands")
    func standardVisibility() {
        let standard = ReaderToolbarDensity.standard
        #expect(standard.showsSourceIcon)
        #expect(standard.showsLoadingIndicator)
        #expect(!standard.showsStatusText)
        #expect(standard.pageActionStyle == .iconOnly)
    }

    @Test("only the widest tier spells state out")
    func expandedVisibility() {
        let expanded = ReaderToolbarDensity.expanded
        #expect(expanded.showsSourceIcon)
        #expect(expanded.showsStatusText)
        #expect(expanded.pageActionStyle == .labeled)
    }

    @Test("add-page state owns its shared label and enabled behavior")
    func addPageState() {
        let available = ReaderAddPageToolbarState(isAdding: false, isSaved: false)
        let adding = ReaderAddPageToolbarState(isAdding: true, isSaved: false)
        let saved = ReaderAddPageToolbarState(isAdding: false, isSaved: true)

        #expect(available == .available)
        #expect(available.isEnabled)
        #expect(available.activationMessage == "Adding to Sources…")
        #expect(adding == .adding)
        #expect(!adding.isEnabled)
        #expect(adding.activationMessage == "Adding to Sources…")
        #expect(saved == .saved)
        #expect(saved.isEnabled)
        #expect(saved.opensSavedSource)
        #expect(!available.opensSavedSource)
        #expect(saved.title == "View in Sources")
        #expect(saved.activationMessage == "Already in Sources")
        #expect(saved.help == "Open the saved source in the Reader")
    }

    @MainActor
    @Test("titlebar add button owns physical mouse clicks")
    func addPageButtonMousePolicy() {
        var invocationCount = 0
        let representable = ReaderAddPageNativeButton(
            state: .available,
            showsTitle: true,
            action: { invocationCount += 1 }
        )
        let coordinator = representable.makeCoordinator()
        let button = ReaderTitlebarActionButton()
        button.target = coordinator
        button.action = #selector(ReaderAddPageNativeButton.Coordinator.performAction(_:))
        button.configure(state: .available, showsTitle: true)

        #expect(!button.mouseDownCanMoveWindow)
        #expect(button.acceptsFirstMouse(for: nil))
        #expect(button.isEnabled)
        #expect(NSApplication.shared.sendAction(button.action!, to: button.target, from: button))
        #expect(invocationCount == 1)

        button.configure(state: .saved, showsTitle: true)
        #expect(button.isEnabled)
        #expect(NSApplication.shared.sendAction(button.action!, to: button.target, from: button))
        #expect(invocationCount == 2)

        button.configure(state: .adding, showsTitle: true)
        #expect(!button.isEnabled)
    }

    @MainActor
    @Test("reader navigation owns physical titlebar mouse clicks")
    func readerNavigationButtonMousePolicy() {
        var invocationCount = 0
        let representable = ReaderNavigationNativeButton(
            systemImage: "chevron.left",
            help: "Go back",
            isEnabled: true,
            action: { invocationCount += 1 }
        )
        let coordinator = representable.makeCoordinator()
        let button = ReaderTitlebarActionButton()
        button.target = coordinator
        button.action = #selector(ReaderNavigationNativeButton.Coordinator.performAction(_:))
        button.configure(
            systemImage: "chevron.left",
            title: nil,
            help: "Go back",
            isEnabled: true,
            accessibilityIdentifier: "reader.navigation.chevron.left"
        )

        #expect(!button.mouseDownCanMoveWindow)
        #expect(button.acceptsFirstMouse(for: nil))
        #expect(button.isEnabled)
        #expect(NSApplication.shared.sendAction(button.action!, to: button.target, from: button))
        #expect(invocationCount == 1)

        button.configure(
            systemImage: "chevron.left",
            title: nil,
            help: "Go back",
            isEnabled: false,
            accessibilityIdentifier: "reader.navigation.chevron.left"
        )
        #expect(!button.isEnabled)
    }

    @MainActor
    @Test("band-mounted reader actions size their label slot to what is drawn")
    func bandControlWidth() {
        let square = StudioPanelChrome.readerCloseButtonSize
        // A bare symbol shares the chrome square; a titled control grows so the
        // native hit surface still lies under the whole drawn label.
        #expect(ReaderTitlebarActionButton.bandControlWidth(title: nil, controlSize: square) == square)
        #expect(ReaderTitlebarActionButton.bandControlWidth(title: "", controlSize: square) == square)
        let labeled = ReaderTitlebarActionButton.bandControlWidth(
            title: ReaderAddPageToolbarState.available.title,
            controlSize: square
        )
        #expect(labeled > square)
        #expect(labeled == labeled.rounded(.up))
        #expect(ReaderTitlebarActionButton.accessibilityIdentifier(forSystemImage: "chevron.left")
            == "reader.navigation.chevron.left")
    }

    @MainActor
    @Test("reader web pages act on the click that reactivates the window")
    func readerWebViewAcceptsFirstMouse() {
        let webView = ForeverLMWebView()

        #expect(webView.acceptsFirstMouse(for: nil))
    }

    @MainActor
    @Test("titlebar band controls track the whole click themselves")
    func titlebarBandButtonMousePolicy() {
        var invocationCount = 0
        let view = TitlebarBandHitSurfaceView()
        view.frame = NSRect(x: 0, y: 0, width: 36, height: 36)
        view.action = { invocationCount += 1 }

        // AppKit asks the deepest hit view whether the press may move the
        // window. Answering yes is what made a band button lose its click to a
        // window drag the moment the pointer drifted.
        #expect(!view.mouseDownCanMoveWindow)
        #expect(view.acceptsFirstMouse(for: nil))

        view.mouseDown(with: Self.mouseEvent(.leftMouseDown, at: NSPoint(x: 18, y: 18)))
        view.mouseUp(with: Self.mouseEvent(.leftMouseUp, at: NSPoint(x: 18, y: 18)))
        #expect(invocationCount == 1)

        // Hand jitter is still a click. Cancelling on the first pixel of drift
        // is what made a band control feel dead: the press landed, the window
        // shifted under it, and nothing happened.
        view.mouseDown(with: Self.mouseEvent(.leftMouseDown, at: NSPoint(x: 18, y: 18)))
        view.mouseDragged(with: Self.mouseEvent(.leftMouseDragged, at: NSPoint(x: 26, y: 18)))
        view.mouseUp(with: Self.mouseEvent(.leftMouseUp, at: NSPoint(x: 26, y: 18)))
        #expect(invocationCount == 2)

        // Dragging away and releasing there cancels, the way a button does —
        // the press must not fire wherever the pointer ends up.
        view.mouseDown(with: Self.mouseEvent(.leftMouseDown, at: NSPoint(x: 18, y: 18)))
        view.mouseDragged(with: Self.mouseEvent(.leftMouseDragged, at: NSPoint(x: 200, y: 18)))
        view.mouseUp(with: Self.mouseEvent(.leftMouseUp, at: NSPoint(x: 200, y: 18)))
        #expect(invocationCount == 2)
    }

    @MainActor
    @Test("titlebar band routing finds controls drawn above the hosting content")
    func titlebarBandMouseRouting() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let surface = TitlebarBandHitSurfaceView()
        surface.frame = NSRect(x: 240, y: 170, width: 36, height: 36)
        window.contentView?.addSubview(surface)

        #expect(TitlebarBandHitSurfaceView.registeredSurface(
            at: NSPoint(x: 258, y: 188),
            in: window
        ) === surface)
        #expect(TitlebarBandHitSurfaceView.registeredSurface(
            at: NSPoint(x: 220, y: 150),
            in: window
        ) == nil)

        surface.removeFromSuperview()
    }

    @MainActor
    @Test("titlebar band routing hands a press on a source tab to the tab, and a control inside it wins")
    func titlebarBandRoutesTabPresses() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let tab = StudioSourceTabDragHandleView()
        tab.frame = NSRect(x: 20, y: 170, width: 120, height: 26)
        let close = TitlebarBandHitSurfaceView()
        close.frame = NSRect(x: 118, y: 174, width: 18, height: 18)
        window.contentView?.addSubview(tab)
        window.contentView?.addSubview(close)

        // A tab hung in the band is otherwise a window move: AppKit never
        // hit-tests the press to the tab, so the router has to know it.
        #expect(TitlebarBandHitSurfaceView.registeredSurface(
            at: NSPoint(x: 60, y: 183),
            in: window
        ) === tab)
        #expect(TitlebarBandHitSurfaceView.registeredSurface(
            at: NSPoint(x: 126, y: 183),
            in: window
        ) === close)

        tab.removeFromSuperview()
        close.removeFromSuperview()
    }

    @Test("the shared pin clears Reader's wider close target")
    func readerPaneCloseReservation() {
        // Reader draws the larger of the two close controls. Reserving the
        // shared width for it put its hover wash — and so its hit surface —
        // inside the pin's, and the pin then owned part of the visible X.
        #expect(StudioTopBar.readerPaneCloseControlReservedWidth
            == StudioPanelChrome.readerCloseButtonSize + StudioTopBar.paneControlSpacing)
        #expect(StudioTopBar.readerPaneCloseControlReservedWidth
            > StudioTopBar.centerPaneCloseControlReservedWidth)
    }

    @Test("every pane draws its close, a lone Chat included")
    func soleCenterPaneCloseControl() {
        // The product owner: the x in the top right is always there. Chat alone used to
        // draw none, which left an open conversation with no way to close it.
        #expect(StudioTopBar.paneDrawsCloseControl())

        // A review that has taken the window over keeps only its own × in the
        // header, however many panes wait underneath it.
        #expect(!StudioTopBar.paneDrawsCloseControl(memoryReviewFocused: true))
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @Test("pane close leaves the shared chrome line before reserved controls collide")
    func paneCloseCollisionPolicy() {
        #expect(StudioPaneClosePlacement.resolve(
            visibleWidth: 180,
            leadingReservation: 130,
            controlWidth: 22
        ) == .chromeLine)
        #expect(StudioPaneClosePlacement.resolve(
            visibleWidth: 179,
            leadingReservation: 130,
            controlWidth: 22
        ) == .contentTop)
        // A pane that begins after the navigation rail has no window-level
        // leading control to collide with, even when its content is clipped.
        #expect(StudioPaneClosePlacement.resolve(
            visibleWidth: 40,
            leadingReservation: 0,
            controlWidth: 22
        ) == .chromeLine)
        // Once the visible pane cannot hold the controls at all, they are not
        // drawn: anchored to the visible edge they would land over the pane's
        // neighbour, and there is no content row to drop to that fits either.
        #expect(StudioPaneClosePlacement.resolve(
            visibleWidth: 37,
            leadingReservation: 0,
            controlWidth: 22
        ) == .hidden)
        #expect(StudioPaneClosePlacement.resolve(
            visibleWidth: 70,
            leadingReservation: 170,
            controlWidth: 56
        ) == .hidden)
        #expect(StudioPaneClosePlacement.resolve(
            visibleWidth: 0,
            leadingReservation: 170,
            controlWidth: 56
        ) == .hidden)
    }

    @Test("the outer column's clipping reaches only the groups that run past its visible edge")
    func groupClipDistribution() {
        // Chat + Reader laid out at their 570pt minimum inside a 436pt column:
        // the 134pt the column clips comes entirely out of the trailing group.
        // The first pane is fully on screen, so its pin stays at its own
        // corner instead of sliding 134pt left onto the traffic lights.
        #expect(StudioCenterTabGroupSizing.clippedTrailingWidth(
            groupStart: 0, groupWidth: 280, totalWidth: 570, enclosingOverflow: 134
        ) == 0)
        #expect(StudioCenterTabGroupSizing.clippedTrailingWidth(
            groupStart: 290, groupWidth: 280, totalWidth: 570, enclosingOverflow: 134
        ) == 134)
        // Clip past the whole trailing group and the remainder reaches the
        // first one, capped at what the first group has to give.
        #expect(StudioCenterTabGroupSizing.clippedTrailingWidth(
            groupStart: 290, groupWidth: 280, totalWidth: 570, enclosingOverflow: 300
        ) == 280)
        #expect(StudioCenterTabGroupSizing.clippedTrailingWidth(
            groupStart: 0, groupWidth: 280, totalWidth: 570, enclosingOverflow: 300
        ) == 10)
        #expect(StudioCenterTabGroupSizing.clippedTrailingWidth(
            groupStart: 0, groupWidth: 280, totalWidth: 570, enclosingOverflow: 1_000
        ) == 280)
        // Nothing clipped, or a single group: the group's own width is the
        // only overflow there is.
        #expect(StudioCenterTabGroupSizing.clippedTrailingWidth(
            groupStart: 0, groupWidth: 570, totalWidth: 570, enclosingOverflow: 0
        ) == 0)
        #expect(StudioCenterTabGroupSizing.clippedTrailingWidth(
            groupStart: 0, groupWidth: 570, totalWidth: 570, enclosingOverflow: 134
        ) == 134)
        #expect(StudioCenterTabGroupSizing.clippedTrailingWidth(
            groupStart: 0, groupWidth: 280, totalWidth: 570, enclosingOverflow: -5
        ) == 0)
    }

    @Test("the chat header yields to pane chrome only when its column reaches it")
    func chatHeaderTrailingClearance() {
        // A column capped well inside the panel ends left of the reserved
        // line on its own, so the title gives up nothing.
        #expect(StudioChatHeaderClearance.extraTrailingPadding(
            panelWidth: 1_000,
            gutter: 14,
            columnMaxWidth: 700,
            chromeClearance: 72
        ) == 0)
        // A column that fills the panel runs a gutter from the edge, past the
        // reserved line — it gives way by exactly the shortfall.
        #expect(StudioChatHeaderClearance.extraTrailingPadding(
            panelWidth: 600,
            gutter: 14,
            columnMaxWidth: 700,
            chromeClearance: 72
        ) == 58)
        // The borderline case: the column's edge lands on the clearance line.
        #expect(StudioChatHeaderClearance.extraTrailingPadding(
            panelWidth: 800,
            gutter: 14,
            columnMaxWidth: 656,
            chromeClearance: 72
        ) == 0)
        // A host with no chrome over its corner never moves the row.
        #expect(StudioChatHeaderClearance.extraTrailingPadding(
            panelWidth: 600,
            gutter: 14,
            columnMaxWidth: 700,
            chromeClearance: 0
        ) == 0)
        // Before the first layout pass there is no width to reason from.
        #expect(StudioChatHeaderClearance.extraTrailingPadding(
            panelWidth: 0,
            gutter: 14,
            columnMaxWidth: 700,
            chromeClearance: 72
        ) == 0)
    }

    @Test("the chat header's copy button rides the panel edge, not the column")
    func chatHeaderControlInset() {
        // Docked, the button lands on the line the pane chrome leaves it —
        // and stays there however wide the pane grows, which is the whole
        // point: it used to drift inward with the centered reading column.
        #expect(StudioChatHeaderClearance.controlTrailingInset(
            gutter: 14,
            chromeClearance: 72
        ) == 72)
        // A pop-out window has no chrome over its corner, so the button keeps
        // the header's own gutter rather than sitting flush to the edge.
        #expect(StudioChatHeaderClearance.controlTrailingInset(
            gutter: 14,
            chromeClearance: 0
        ) == 14)
        // Chrome closer in than the gutter never pushes the button outward.
        #expect(StudioChatHeaderClearance.controlTrailingInset(
            gutter: 14,
            chromeClearance: 8
        ) == 14)

        // The title has to stop a control gap short of the button.
        #expect(StudioChatHeaderClearance.titleClearance(
            gutter: 14,
            chromeClearance: 72,
            controlSize: 28,
            controlGap: 12
        ) == 112)
        #expect(StudioChatHeaderClearance.titleClearance(
            gutter: 14,
            chromeClearance: 0,
            controlSize: 28,
            controlGap: 12
        ) == 54)

        // Put the two together on the layout from the bug report: a wide
        // split pane, its reading column frozen at 700. The column's own
        // trailing edge is far inside the button's line, so the title needs
        // no help — and the button is out on the panel edge regardless.
        #expect(StudioChatHeaderClearance.extraTrailingPadding(
            panelWidth: 950,
            gutter: 14,
            columnMaxWidth: 700,
            chromeClearance: StudioChatHeaderClearance.titleClearance(
                gutter: 14,
                chromeClearance: 72,
                controlSize: 28,
                controlGap: 12
            )
        ) == 0)
        // Narrow the same pane until the column fills it and the title does
        // start yielding, so a long title truncates instead of sliding under.
        #expect(StudioChatHeaderClearance.extraTrailingPadding(
            panelWidth: 620,
            gutter: 14,
            columnMaxWidth: 700,
            chromeClearance: StudioChatHeaderClearance.titleClearance(
                gutter: 14,
                chromeClearance: 72,
                controlSize: 28,
                controlGap: 12
            )
        ) == 98)
    }

    @Test("window minimum seats the widest supported two-pane center layout")
    func centerPaneWindowMinimum() {
        #expect(StudioCenterTabGroupSizing.minimumWindowContentWidth == 570)
        // Chat beside one ordinary pane, the widest pair.
        let chatBesideReader = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader, .tasks, .notepad, .sites, .browser, .artifacts], activeTab: .reader),
        ])
        #expect(
            StudioCenterTabGroupSizing.minimumWidth(for: chatBesideReader.groups)
                == StudioCenterTabGroupSizing.minimumWindowContentWidth
        )
        // The first-launch layout, the Space alone, fits inside it.
        #expect(
            StudioCenterTabGroupSizing.minimumWidth(for: StudioCenterTabGroups.defaultLayout.groups)
                <= StudioCenterTabGroupSizing.minimumWindowContentWidth
        )
    }
}

// Where the Text to Speech player sits: the reader showing the narrated source, or the window bar.

struct StudioAudiobookPlayerPlacementTests {
    @Test("no narration, no window bar")
    func idle() {
        #expect(!StudioAudiobookPlayerPlacement.showsWindowPlayer(
            narratingSourceID: nil,
            readerSourceIDsOnScreen: ["chapter-2"]
        ))
    }

    @Test("the reader showing the narrated source carries the player, so the window bar stays away")
    func narratedSourceOnScreen() {
        #expect(!StudioAudiobookPlayerPlacement.showsWindowPlayer(
            narratingSourceID: "chapter-2",
            readerSourceIDsOnScreen: ["chapter-2", "paper-7"]
        ))
    }

    @Test("navigating away from the narrated source brings the window bar")
    func narratedSourceOffScreen() {
        #expect(StudioAudiobookPlayerPlacement.showsWindowPlayer(
            narratingSourceID: "chapter-2",
            readerSourceIDsOnScreen: ["chapter-3"]
        ))
        #expect(StudioAudiobookPlayerPlacement.showsWindowPlayer(
            narratingSourceID: "chapter-2",
            readerSourceIDsOnScreen: []
        ))
    }
}
