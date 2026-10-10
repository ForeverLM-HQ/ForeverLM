import AppKit
import PDFKit
import Testing
@testable import ForeverLM

/// Cmd+F and Cmd+=/- dispatch for the surfaces registered in one window.
@Suite("Reader shortcut router")
struct ReaderShortcutRouterTests {
    /// Two surfaces side by side in one window: a reader on the left, a doc
    /// on the right. Each anchor spans its half; `focusView` is a focusable
    /// child the test can make first responder.
    @MainActor
    private final class Fixture {
        let window: NSWindow
        let readerAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let docAnchor = NSView(frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        let readerFocus = NSTextView(frame: NSRect(x: 20, y: 20, width: 200, height: 40))
        let docFocus = NSTextView(frame: NSRect(x: 20, y: 20, width: 200, height: 40))
        let readerID = UUID()
        let docID = UUID()
        var log: [String] = []

        init() {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            // A window made in code releases itself on close; ARC releases it too.
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            window.contentView = content
            content.addSubview(readerAnchor)
            content.addSubview(docAnchor)
            readerAnchor.addSubview(readerFocus)
            docAnchor.addSubview(docFocus)

            ReaderShortcutRouter.shared.register(
                id: readerID,
                window: window,
                anchor: readerAnchor,
                handlers: { [unowned self] in
                    .init(
                        find: { self.log.append("reader.find") },
                        zoomIn: { self.log.append("reader.zoomIn") },
                        zoomOut: { self.log.append("reader.zoomOut") },
                        resetZoom: { self.log.append("reader.resetZoom") },
                        magnify: { _ in self.log.append("reader.magnify") }
                    )
                }
            )
            ReaderShortcutRouter.shared.register(
                id: docID,
                window: window,
                anchor: docAnchor,
                handlers: { [unowned self] in
                    .init(find: { self.log.append("doc.find") })
                }
            )
        }

        func tearDown() {
            ReaderShortcutRouter.shared.unregister(id: readerID)
            ReaderShortcutRouter.shared.unregister(id: docID)
            window.close()
        }
    }

    @Test("Cmd+F with no focused surface goes to the window's primary reader")
    @MainActor
    func findFallsBackToPrimaryReader() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        ReaderShortcutRouter.shared.findHandler(for: fixture.window)?()
        #expect(fixture.log == ["reader.find"])
    }

    @Test("Cmd+F while typing in the doc searches the doc, not the reader beside it")
    @MainActor
    func findPrefersFocusedSurface() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.window.makeFirstResponder(fixture.docFocus)
        #expect(fixture.window.firstResponder === fixture.docFocus)
        ReaderShortcutRouter.shared.findHandler(for: fixture.window)?()
        #expect(fixture.log == ["doc.find"])

        fixture.log.removeAll()
        fixture.window.makeFirstResponder(fixture.readerFocus)
        ReaderShortcutRouter.shared.findHandler(for: fixture.window)?()
        #expect(fixture.log == ["reader.find"])
    }

    @Test("A click on the reader takes Cmd+F even when keyboard focus stayed in the doc")
    @MainActor
    func clickedReaderOutranksFocus() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.window.makeFirstResponder(fixture.docFocus)
        ReaderShortcutRouter.shared.noteMouseDown(at: CGPoint(x: 150, y: 200), in: fixture.window)
        ReaderShortcutRouter.shared.settleClickClaim()
        ReaderShortcutRouter.shared.findHandler(for: fixture.window)?()
        #expect(fixture.log == ["reader.find"])

        // Keyboard focus moving on ends the claim; focus rules again.
        fixture.log.removeAll()
        fixture.window.makeFirstResponder(fixture.readerFocus)
        #expect(ReaderShortcutRouter.shared.clickedHandlers(for: fixture.window) == nil)
        fixture.window.makeFirstResponder(fixture.docFocus)
        ReaderShortcutRouter.shared.findHandler(for: fixture.window)?()
        #expect(fixture.log == ["doc.find"])
    }

    @Test("A click outside every reader ends the click claim")
    @MainActor
    func clickElsewhereEndsClaim() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        ReaderShortcutRouter.shared.noteMouseDown(at: CGPoint(x: 150, y: 200), in: fixture.window)
        ReaderShortcutRouter.shared.settleClickClaim()
        #expect(ReaderShortcutRouter.shared.clickedHandlers(for: fixture.window) != nil)

        ReaderShortcutRouter.shared.noteMouseDown(at: CGPoint(x: 150, y: 450), in: fixture.window)
        #expect(ReaderShortcutRouter.shared.clickedHandlers(for: fixture.window) == nil)
    }

    @Test("Ctrl+F reaches a clicked reader from a list, but stays \"move forward\" in a text field")
    @MainActor
    func controlFindAfterClick() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // A window made in code releases itself on close; ARC releases it too.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let readerAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        // The sources column: a list that keeps focus, and its search field.
        let sourcesList = NSTextView(frame: NSRect(x: 320, y: 20, width: 200, height: 200))
        sourcesList.isEditable = false
        let sourcesSearch = NSTextView(frame: NSRect(x: 320, y: 300, width: 200, height: 40))
        content.addSubview(readerAnchor)
        content.addSubview(sourcesList)
        content.addSubview(sourcesSearch)
        let id = UUID()
        var log: [String] = []
        ReaderShortcutRouter.shared.register(id: id, window: window, anchor: readerAnchor) {
            .init(find: { log.append("reader.find") })
        }
        defer { ReaderShortcutRouter.shared.unregister(id: id) }

        window.makeFirstResponder(sourcesList)
        ReaderShortcutRouter.shared.noteMouseDown(at: CGPoint(x: 150, y: 200), in: window)
        ReaderShortcutRouter.shared.settleClickClaim()
        ReaderShortcutRouter.shared.clickedControlFindHandler(for: window)?()
        #expect(log == ["reader.find"])

        window.makeFirstResponder(sourcesSearch)
        ReaderShortcutRouter.shared.noteMouseDown(at: CGPoint(x: 150, y: 200), in: window)
        ReaderShortcutRouter.shared.settleClickClaim()
        #expect(ReaderShortcutRouter.shared.clickedControlFindHandler(for: window) == nil)
    }

    @Test("A surface without document zoom leaves Cmd+=/- to the app")
    @MainActor
    func focusedDocHasNoZoom() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.window.makeFirstResponder(fixture.docFocus)
        let focused = ReaderShortcutRouter.shared.focusedHandlers(for: fixture.window)
        #expect(focused != nil)
        #expect(focused?.zoomIn == nil)
        #expect(focused?.zoomOut == nil)
        #expect(focused?.resetZoom == nil)
        #expect(focused?.magnify == nil)

        fixture.window.makeFirstResponder(fixture.readerFocus)
        ReaderShortcutRouter.shared.focusedHandlers(for: fixture.window)?.zoomIn?()
        #expect(fixture.log == ["reader.zoomIn"])
    }

    @Test("Handlers are read at dispatch time, so a re-registered entry follows the current surface")
    @MainActor
    func handlersAreLive() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // A window made in code releases itself on close; ARC releases it too.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(anchor)
        let id = UUID()
        defer { ReaderShortcutRouter.shared.unregister(id: id) }

        var current = "first"
        var log: [String] = []
        ReaderShortcutRouter.shared.register(id: id, window: window, anchor: anchor) {
            .init(find: { log.append(current) })
        }

        ReaderShortcutRouter.shared.findHandler(for: window)?()
        current = "second"
        ReaderShortcutRouter.shared.findHandler(for: window)?()
        #expect(log == ["first", "second"])
    }

    @Test("An unknown window has no find handler")
    @MainActor
    func unknownWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // A window made in code releases itself on close; ARC releases it too.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        #expect(ReaderShortcutRouter.shared.findHandler(for: window) == nil)
        #expect(ReaderShortcutRouter.shared.findHandler(for: nil) == nil)
    }
}

/// A trackpad pinch over a chat panel moves chat's own zoom offset; the app
/// step and the offset resolve to one clamped step for the chat subtree.
@Suite("Chat zoom")
struct ChatZoomTests {
    @Test("The resolved step is the app step plus the offset, clamped to the range")
    func resolvedStepClamps() {
        #expect(ChatZoom.step(appStep: 4, offset: 0) == 4)
        #expect(ChatZoom.step(appStep: 4, offset: 2) == 6)
        #expect(ChatZoom.step(appStep: 4, offset: 10) == UIZoom.maxStep)
        #expect(ChatZoom.step(appStep: 4, offset: -10) == UIZoom.minStep)
        #expect(ChatZoom.scale(appStep: 4, offset: 2) == UIZoom.scale(for: 6))
        #expect(ChatZoom.size(appStep: 4, offset: -1) == UIZoom.size(for: 3))
    }

    @Test("A pinch steps the offset and stops at the ends of the range")
    func steppingStopsAtTheEnds() {
        #expect(ChatZoom.offset(stepping: 1, appStep: 4, offset: 0) == 1)
        #expect(ChatZoom.offset(stepping: -1, appStep: 4, offset: 1) == 0)
        // Chat already at the largest step: pinching out does nothing more.
        #expect(ChatZoom.offset(stepping: 1, appStep: 4, offset: UIZoom.maxStep - 4) == nil)
        // The app itself at the smallest step, chat with it: nothing smaller.
        #expect(ChatZoom.offset(stepping: -1, appStep: UIZoom.minStep, offset: 0) == nil)
    }

    @Test("An offset past the range is rewritten from the resolved step, so the way back is one step")
    func offsetNeverDrifts() {
        // The app zoomed in after chat had been pinched to the top: the stored
        // offset now overshoots. The first pinch in must move chat visibly, not
        // burn several steps unwinding an offset the user cannot see.
        let overshoot = UIZoom.maxStep // appStep 6 + 8 resolves to maxStep
        #expect(ChatZoom.step(appStep: 6, offset: overshoot) == UIZoom.maxStep)
        let next = ChatZoom.offset(stepping: -1, appStep: 6, offset: overshoot)
        #expect(next == UIZoom.maxStep - 1 - 6)
        #expect(ChatZoom.step(appStep: 6, offset: next ?? 0) == UIZoom.maxStep - 1)
    }

    @Test("The router answers for the pointer over a registered chat panel only")
    @MainActor
    func routerContainsPointerOverChat() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // A window made in code releases itself on close; ARC releases it too.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let chatAnchor = NSView(frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        window.contentView?.addSubview(chatAnchor)
        let id = UUID()
        ChatZoomShortcutRouter.shared.register(id: id, window: window, anchor: chatAnchor)

        let overChat = CGPoint(x: 450, y: 200)
        let besideChat = CGPoint(x: 150, y: 200)
        #expect(ChatZoomShortcutRouter.shared.contains(windowPoint: overChat, in: window))
        #expect(!ChatZoomShortcutRouter.shared.contains(windowPoint: besideChat, in: window))
        #expect(!ChatZoomShortcutRouter.shared.contains(windowPoint: overChat, in: nil))

        ChatZoomShortcutRouter.shared.unregister(id: id)
        #expect(!ChatZoomShortcutRouter.shared.contains(windowPoint: overChat, in: window))
    }

    /// The product owner (2026-09-10), with a chat window on each of two displays: "I
    /// want only to zoom in on that one, not the other one on the other
    /// display." The pinch reaches the panel under the pointer and no other,
    /// and ⌘0 in a window resets that window's chats alone.
    @Test("A pinch moves the chat under the pointer only, and reset stays in its window")
    @MainActor
    func pinchAndResetAreScopedToOnePanel() {
        func makeWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            return window
        }
        let left = makeWindow(), right = makeWindow()
        defer { left.close(); right.close() }
        let leftAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let rightAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        left.contentView?.addSubview(leftAnchor)
        right.contentView?.addSubview(rightAnchor)

        let leftStore = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let rightStore = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        func handlers(for store: StudioAssistantSessionStore) -> ChatZoomShortcutRouter.Handlers {
            .init(
                step: { delta in
                    guard let next = ChatZoom.offset(stepping: delta, appStep: 4, offset: store.chatZoomOffset) else {
                        return false
                    }
                    store.chatZoomOffset = next
                    return true
                },
                reset: { store.chatZoomOffset = 0 }
            )
        }
        let leftID = UUID(), rightID = UUID()
        ChatZoomShortcutRouter.shared.register(id: leftID, window: left, anchor: leftAnchor) { handlers(for: leftStore) }
        ChatZoomShortcutRouter.shared.register(id: rightID, window: right, anchor: rightAnchor) { handlers(for: rightStore) }
        defer {
            ChatZoomShortcutRouter.shared.unregister(id: leftID)
            ChatZoomShortcutRouter.shared.unregister(id: rightID)
        }

        let point = CGPoint(x: 300, y: 200)
        let overLeft = ChatZoomShortcutRouter.shared.handlers(at: point, in: left)
        #expect(overLeft != nil)
        #expect(overLeft?.step(1) == true)
        #expect(overLeft?.step(1) == true)
        #expect(leftStore.chatZoomOffset == 2)
        #expect(rightStore.chatZoomOffset == 0)

        // Pinching the other window's chat moves that one alone.
        #expect(ChatZoomShortcutRouter.shared.handlers(at: point, in: right)?.step(-1) == true)
        #expect(leftStore.chatZoomOffset == 2)
        #expect(rightStore.chatZoomOffset == -1)

        // ⌘0 in the left window brings only the left chat back.
        ChatZoomShortcutRouter.shared.resetAll(in: left)
        #expect(leftStore.chatZoomOffset == 0)
        #expect(rightStore.chatZoomOffset == -1)
        ChatZoomShortcutRouter.shared.resetAll(in: nil)
        #expect(rightStore.chatZoomOffset == -1)
    }
}

/// A pinch zooms a reader about the words under the pointer rather than the
/// top of the view. The web and SwiftUI transcript readers need WebKit and a
/// SwiftUI layout pass; these cover the two readers AppKit lays out at once.
@Suite("Reader pinch anchor")
struct ReaderPinchAnchorTests {
    @MainActor
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // A window made in code releases itself on close; ARC releases it too.
        window.isReleasedWhenClosed = false
        return window
    }

    /// A long plain-text reader scrolled well into its text, set up the way
    /// `InlineTextReaderView` sets one up.
    @MainActor
    private static func textReader(in window: NSWindow) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.string = (0..<200).map { paragraph in
            (1...60).map { "w\(paragraph * 60 + $0)" }.joined(separator: " ")
        }.joined(separator: "\n\n")
        textView.font = .systemFont(ofSize: 13)
        scroll.documentView = textView
        window.contentView = scroll
        scroll.frame = window.contentLayoutRect
        scroll.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.setFrameOrigin(.zero)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 6000))
        scroll.reflectScrolledClipView(scroll.contentView)
        return (scroll, textView)
    }

    /// The character under a window point, and the characters of its line.
    @MainActor
    private static func character(at windowPoint: CGPoint, in textView: NSTextView) -> (index: Int, line: NSRange) {
        let layoutManager = textView.layoutManager!
        let point = textView.convert(windowPoint, from: nil)
        let origin = textView.textContainerOrigin
        let glyph = layoutManager.glyphIndex(
            for: CGPoint(x: point.x - origin.x, y: point.y - origin.y),
            in: textView.textContainer!
        )
        var lineGlyphs = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        return (
            layoutManager.characterIndexForGlyph(at: glyph),
            layoutManager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        )
    }

    @Test("A pinch on text keeps the line under the pointer as the text grows or shrinks", arguments: [18.0, 10.0])
    @MainActor
    func textKeepsItsLine(to size: Double) {
        let window = Self.makeWindow()
        defer { window.close() }
        let (_, textView) = Self.textReader(in: window)
        let pointer = CGPoint(x: 330, y: 260)
        let before = Self.character(at: pointer, in: textView).index

        ReaderPinchAnchor.note(pointer, in: window, phase: .began)
        let anchor = ReaderPinchAnchor.textAnchor(in: textView)
        #expect(anchor != nil)
        textView.font = .systemFont(ofSize: size)
        anchor?.restore()

        // The text reflows, so the word moves along its line; the line stays.
        #expect(NSLocationInRange(before, Self.character(at: pointer, in: textView).line))
    }

    @Test("Keyboard zoom takes no anchor, so it scrolls nothing")
    @MainActor
    func keyboardZoomTakesNoAnchor() {
        let window = Self.makeWindow()
        defer { window.close() }
        let (_, textView) = Self.textReader(in: window)
        #expect(ReaderPinchAnchor.textAnchor(in: textView) == nil)
    }

    @Test("A pinch on a PDF keeps the spot on the page under the pointer")
    @MainActor
    func pdfKeepsItsSpot() throws {
        let window = Self.makeWindow()
        defer { window.close() }
        let document = PDFDocument()
        for index in 0..<6 {
            let image = NSImage(size: NSSize(width: 612, height: 792), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                return true
            }
            document.insert(try #require(PDFPage(image: image)), at: index)
        }
        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        window.contentView = pdfView
        pdfView.layoutDocumentView()
        pdfView.go(to: NSRect(x: 100, y: 300, width: 10, height: 10), on: try #require(document.page(at: 2)))

        let pointer = CGPoint(x: 460, y: 200)
        func spot() -> (PDFPage?, CGPoint) {
            let point = pdfView.convert(pointer, from: nil)
            guard let page = pdfView.page(for: point, nearest: true) else { return (nil, .zero) }
            return (page, pdfView.convert(point, to: page))
        }
        let (pageBefore, pointBefore) = spot()

        ReaderPinchAnchor.note(pointer, in: window, phase: .began)
        let anchor = ReaderPinchPDFAnchor(pdfView: pdfView)
        #expect(anchor != nil)
        let fitScale = pdfView.scaleFactorForSizeToFit
        pdfView.autoScales = false
        pdfView.scaleFactor = fitScale * 1.5
        anchor?.restore()

        let (pageAfter, pointAfter) = spot()
        #expect(pageAfter === pageBefore)
        #expect(abs(pointAfter.x - pointBefore.x) < 1)
        #expect(abs(pointAfter.y - pointBefore.y) < 1)
    }
}
