import AppKit
import SwiftUI
import Testing
@testable import ForeverLM

/// The titlebar band is the window's chrome, and it must read as one strip
/// whatever sits side by side under it (product owner, 2026-10-15, of the chat
/// beside the Review: "this grey and white in the top bar also looks bad").
/// The chat's title row had painted the pane's white across its half of the
/// band while the Review's row stood on the chrome's grey.
///
/// The structure that keeps it from happening: the band is painted in one file
/// (`StudioBandRow`, file-private), every row reaches it through
/// `studioChromeLineHeader` or `studioBandOverlay`, and the window's card puts
/// the panes just under it. These tests lay real shell pieces side by side — the
/// pane host, the inset card, both header entries, panes with their own white
/// backing and scrolled content under the band — render them, and read the
/// band's pixels: the top and bottom edge of the band, where no glyph lands,
/// must be the chrome's color at every x, in light and in dark.
@Suite("Studio titlebar band uniformity")
struct StudioBandUniformityTests {
    // MARK: - The panes a window can put side by side

    /// One pane's header, by the entry it hangs its row through, and what its
    /// body does under the band. Together they are every way a pane in the
    /// app reaches the band.
    enum PaneKind: String, CaseIterable {
        /// A transcript: a row through `studioBandOverlay`, rows scrolled up under the band.
        case chat
        /// The Reader: a row through `studioBandOverlay` over a pane whose own
        /// black backdrop reaches the band (a video).
        case reader
        /// Memory: `studioChromeLineHeader(opaque: true)` over the pane's white.
        case review
        /// A list pane: `studioChromeLineHeader` over a scrolling list.
        case list
        /// A pane with no header of its own, as an empty chat or a loading pane is.
        case bare
        /// The 2026-10-15 bug, kept as a probe: a title row that paints the
        /// pane's color behind itself. Never part of a window; it is here so a
        /// test can prove the pixel check sees such a row.
        case paintedRow

        /// Every kind a window really has.
        static var real: [PaneKind] { allCases.filter { $0 != .paintedRow } }
    }

    static let band: CGFloat = 52
    static let height: CGFloat = 260

    @MainActor
    private static func pane(_ kind: PaneKind) -> some View {
        let window = Color(nsColor: .windowBackgroundColor)
        return Group {
            switch kind {
            case .chat:
                transcript
                    .background(window)
                    .studioBandOverlay(active: true) { headerRow("Question Phrasing Clarification") }
            case .reader:
                Color.black
                    .overlay(Color.white.opacity(0.1))
                    .studioBandOverlay(active: true) { headerRow("Reader") }
            case .review:
                transcript
                    .background(window)
                    .studioChromeLineHeader(opaque: true) { headerRow("Review  To Check  All Cards") }
            case .list:
                transcript
                    .studioChromeLineHeader { headerRow("Library") }
            case .bare:
                Color(nsColor: .windowBackgroundColor)
            case .paintedRow:
                transcript
                    .background(window)
                    .studioBandOverlay(active: true) {
                        headerRow("Question Phrasing Clarification").background(window)
                    }
            }
        }
    }

    /// Rows that run up under the band, as a scrolled list or transcript does.
    private static var transcript: some View {
        // An overlay, so the rows' own height never sizes the pane: the pane
        // is what it is offered, and the rows run past its top edge.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(0..<12, id: \.self) { _ in
                        Rectangle().fill(Color.red.opacity(0.5)).frame(height: 30).padding(.vertical, 4)
                    }
                }
                .offset(y: -20)
            }
    }

    /// A header row in the shape the real ones have: a title, a spacer, two
    /// small controls. It paints no backdrop, as no row may.
    private static func headerRow(_ title: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "ellipsis").imageScale(.small)
            Image(systemName: "xmark").imageScale(.small)
        }
        .padding(.horizontal, 16)
        .frame(height: band)
    }

    /// The shell as a window lays it out: the chrome behind everything, a band
    /// above the card, and the panes side by side in the card, each in the
    /// pane host with its width and the band passing through.
    @MainActor
    private static func window(_ kinds: [PaneKind], width: CGFloat) -> some View {
        let columnWidth = width / CGFloat(kinds.count)
        return HStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                StudioPaneHost(
                    activeTab: .chat,
                    width: columnWidth,
                    leadingReservation: index == 0 ? 80 : 0
                ) {
                    pane(kind)
                }
            }
        }
        .frame(width: width, height: height - band)
        .studioInsetCard()
        .padding(.top, band)
        .frame(width: width + StudioInsetCardStyle.gutterWidth, height: height, alignment: .topLeading)
        .background(StudioInsetCardStyle.chrome)
        .environment(\.studioTitlebarBandHeight, band)
    }

    // MARK: - Reading the pixels

    /// The band's top and bottom edge rows, read as sRGB, at every x.
    @MainActor
    private static func bandEdgeColors(
        _ kinds: [PaneKind],
        dark: Bool,
        width: CGFloat = 900
    ) -> (pixels: [NSColor], chrome: NSColor)? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let hosting = NSHostingView(rootView: window(kinds, width: width))
        hosting.appearance = appearance
        let size = CGSize(width: width + StudioInsetCardStyle.gutterWidth, height: height)
        hosting.frame = CGRect(origin: .zero, size: size)
        let host = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.appearance = appearance
        host.alphaValue = 0
        host.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        // The chrome as this render draws it: the gutter at the trailing edge,
        // where nothing but the window's own chrome paints. Read off the
        // render, not computed, so the display's color handling cancels out.
        let scale = CGFloat(rep.pixelsWide) / size.width
        guard let chrome = rep.colorAt(
            x: Int((width + StudioInsetCardStyle.gutterWidth / 2) * scale),
            y: Int(2 * scale)
        )?.usingColorSpace(.sRGB) else { return nil }

        let rows = [2, Int(band) - 3].map { Int(CGFloat($0) * scale) }
        var pixels: [NSColor] = []
        for row in rows {
            for column in 0..<Int(width * scale) {
                if let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) {
                    pixels.append(color)
                }
            }
        }
        return (pixels, chrome)
    }

    private static func differs(_ a: NSColor, _ b: NSColor, tolerance: CGFloat = 2.0 / 255.0) -> Bool {
        abs(a.redComponent - b.redComponent) > tolerance
            || abs(a.greenComponent - b.greenComponent) > tolerance
            || abs(a.blueComponent - b.blueComponent) > tolerance
    }

    @MainActor
    private static func offChrome(_ kinds: [PaneKind], dark: Bool, width: CGFloat = 900) -> Int? {
        guard let read = bandEdgeColors(kinds, dark: dark, width: width), !read.pixels.isEmpty else { return nil }
        return read.pixels.filter { differs($0, read.chrome) }.count
    }

    // MARK: - Tests

    @MainActor
    @Test("a single pane of any kind leaves the band as the chrome", arguments: PaneKind.real, [false, true])
    func singlePane(kind: PaneKind, dark: Bool) {
        let off = Self.offChrome([kind], dark: dark)
        #expect(off != nil, "\(kind) did not render")
        #expect(off == 0, "\(kind) painted \(off ?? -1) band pixels off the chrome (dark: \(dark))")
    }

    @MainActor
    @Test("any two panes side by side leave one uniform band, in either order", arguments: [false, true])
    func everyPair(dark: Bool) {
        for left in PaneKind.real {
            for right in PaneKind.real {
                let off = Self.offChrome([left, right], dark: dark)
                #expect(off != nil, "\(left) | \(right) did not render")
                #expect(off == 0, "\(left) | \(right): \(off ?? -1) band pixels off the chrome (dark: \(dark))")
            }
        }
    }

    @MainActor
    @Test("three panes side by side leave one uniform band", arguments: [false, true])
    func everyTriple(dark: Bool) {
        for a in PaneKind.real {
            for b in PaneKind.real {
                for c in PaneKind.real {
                    let off = Self.offChrome([a, b, c], dark: dark, width: 1200)
                    #expect(off != nil, "\(a) | \(b) | \(c) did not render")
                    #expect(off == 0, "\(a) | \(b) | \(c): \(off ?? -1) band pixels off the chrome (dark: \(dark))")
                }
            }
        }
    }

    @MainActor
    @Test("the chat beside the Review, the pair that looked wrong, keeps one band at narrow and wide windows")
    func chatBesideReviewAtEveryWidth() {
        for width in [560.0, 720, 900, 1280, 1800] as [CGFloat] {
            for dark in [false, true] {
                let off = Self.offChrome([.chat, .review], dark: dark, width: width)
                #expect(off == 0, "chat | review at \(width)pt: \(off ?? -1) band pixels off the chrome (dark: \(dark))")
            }
        }
    }

    @MainActor
    @Test("the pixel check sees a title row that paints the pane's color, so a clean result means something", arguments: [false, true])
    func detectorSeesAPaintedRow(dark: Bool) {
        let off = Self.offChrome([.paintedRow, .review], dark: dark)
        #expect((off ?? 0) > 0, "a painted row went unseen")
    }

    /// The chrome and the pane's own color must stay distinguishable, or every
    /// test above would pass over a window whose panes and band had become
    /// the same color and say nothing.
    @MainActor
    @Test("the chrome differs from the pane color, so the pixel checks can tell them apart", arguments: [false, true])
    func chromeIsNotThePaneColor(dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var chrome = NSColor.clear
        var pane = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            chrome = NSColor(StudioInsetCardStyle.chrome).usingColorSpace(.sRGB) ?? .clear
            pane = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .clear
        }
        #expect(Self.differs(chrome, pane), "chrome \(chrome) vs pane \(pane)")
    }

    // MARK: - The rule, by source

    /// The band is painted in one file. A second place that hangs a row with
    /// its own backing is how the chat's white row came to sit beside the
    /// Review's grey one.
    @Test("no file but StudioViewSupport draws a band row itself")
    func bandRowIsDrawnInOneFile() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App").resolvingSymlinksInPath()
        let files = try FileManager.default.contentsOfDirectory(at: appDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "StudioViewSupport.swift" }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains("StudioBandRow("), "\(file.lastPathComponent) draws a band row itself; use studioBandOverlay")
        }
    }

    /// A row in the band stands on the band's chrome, so a header closure that
    /// paints the pane's color behind itself turns its half of the band
    /// white. In-flow rows of a window with no band are the pane's color
    /// (`opaque`), and that is the modifier's, not the closure's.
    @Test("no band header closure paints a pane-colored backdrop of its own")
    func headerClosuresPaintNoBackdrop() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App").resolvingSymlinksInPath()
        let files = try FileManager.default.contentsOfDirectory(at: appDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let backdrops = [
            ".background(Color(nsColor: .windowBackgroundColor))",
            ".background(Color(nsColor: .controlBackgroundColor))",
            ".background(Color(nsColor: .textBackgroundColor))",
            ".background(.background)",
            ".background(Color.white)",
            ".background(.white)",
        ]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for opener in ["studioBandOverlay", "studioChromeLineHeader"] {
                var searchStart = source.startIndex
                while let hit = source.range(of: opener, range: searchStart..<source.endIndex) {
                    searchStart = hit.upperBound
                    guard let open = source[hit.upperBound...].firstIndex(of: "{"),
                          source.distance(from: hit.upperBound, to: open) < 40,
                          let close = Self.matchingBrace(in: source, from: open) else { continue }
                    let body = String(source[open...close])
                    for backdrop in backdrops {
                        #expect(!body.contains(backdrop), "\(file.lastPathComponent): a \(opener) closure paints \(backdrop)")
                    }
                }
            }
        }
    }

    /// The chat's title row is a property the band closure only names, so the
    /// closure check above cannot see into it: the white came from there.
    @Test("the chat's title row backs itself only where there is no band")
    func chatTitleRowBacksItselfOnlyWithoutBand() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/InternalReviewPanel.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: "private var chatTitleHeader: some View"))
        let open = try #require(source[start.upperBound...].firstIndex(of: "{"))
        let close = try #require(Self.matchingBrace(in: source, from: open))
        let body = String(source[open...close])
        for line in body.split(separator: "\n") where line.contains("windowBackgroundColor") {
            #expect(line.contains("band == nil"), "the title row paints the pane's color in the band: \(line)")
        }
    }

    /// The chat's band row hangs on the panel inside the host inset, so it is
    /// `hostInset` short of each side; a host backing that reaches into the
    /// band is the white strip beside the lights.
    @Test("the docked chat host's backing stays out of the band")
    func dockedChatHostBackingStaysOutOfBand() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/StudioAssistantBar.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: "struct StudioDockedAssistantPanel: View"))
        let open = try #require(source[start.upperBound...].firstIndex(of: "{"))
        let close = try #require(Self.matchingBrace(in: source, from: open))
        let body = String(source[open...close])
        #expect(!body.contains(".background(Color(nsColor: .windowBackgroundColor))"),
                "the docked chat host's backing reaches up into the titlebar band")
        #expect(body.contains(".background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])"))
    }

    private static func matchingBrace(in source: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
