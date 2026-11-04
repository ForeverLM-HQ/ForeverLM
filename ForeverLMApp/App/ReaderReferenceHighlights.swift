import AppKit
import SwiftUI

/// Where the words a reference card shows sit on the PDF's pages, so a
/// highlight made on the card is a highlight of those words on the page, and a
/// highlight made on the page shows on the card.
///
/// The card's text is a paragraph made of the entry's lines (words
/// hyphenated across a line closed up, line breaks made spaces); the pages'
/// text is those lines as PDFKit reads them. They differ only in whitespace
/// and hyphens, so the two are lined up on what is left once those are set
/// aside, character by character, and a range of either is carried across.
struct ReferenceTextMap {
    /// The page characters the entry is read from, in reading order, each with
    /// its page of the file and its index in that page's text.
    struct Unit: Equatable {
        let pageIndex: Int
        let index: Int
        let value: UInt16
    }

    private let units: [Unit]
    /// For each kept character of the card's text (its offset), the position
    /// in `units` it was read from; nil for one that could not be lined up.
    private let kept: [(offset: Int, unit: Int?)]

    /// - Parameters:
    ///   - display: the text the card shows.
    ///   - pieces: the page characters it was read from, in reading order: a
    ///     piece is a range of one page's text, with that text.
    init(display: String, pieces: [(pageIndex: Int, range: NSRange, text: String)]) {
        var units: [Unit] = []
        for piece in pieces {
            let text = piece.text as NSString
            for offset in 0..<min(text.length, piece.range.length) {
                units.append(Unit(pageIndex: piece.pageIndex, index: piece.range.location + offset, value: text.character(at: offset)))
            }
        }
        self.units = units
        let keptUnits = units.indices.filter { !Self.isIgnorable(units[$0].value) }
        let shown = display as NSString
        var kept: [(offset: Int, unit: Int?)] = []
        var cursor = 0
        for offset in 0..<shown.length where !Self.isIgnorable(shown.character(at: offset)) {
            let value = shown.character(at: offset)
            // A stray character on the page (a hyphen the card dropped is
            // ignorable; anything else is a rare mismatch) is stepped over, but
            // not for long: a character found nowhere near is left unlined.
            var probe = cursor
            while probe < keptUnits.count, probe - cursor < Self.reach, units[keptUnits[probe]].value != value { probe += 1 }
            if probe < keptUnits.count, probe - cursor < Self.reach {
                kept.append((offset, keptUnits[probe]))
                cursor = probe + 1
            } else {
                kept.append((offset, nil))
            }
        }
        self.kept = kept
    }

    /// How many page characters one card character may skip over to find its
    /// place.
    private static let reach = 8

    /// Whitespace and the hyphens a line break may add or take away.
    private static func isIgnorable(_ value: UInt16) -> Bool {
        if let scalar = Unicode.Scalar(value) {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
            return value == 0x00AD || value == 0x002D || value == 0x2010 || value == 0x2011
        }
        return false
    }

    /// Whether the card's words could be placed on the page at all.
    var isPlaced: Bool {
        kept.contains { $0.unit != nil }
    }

    /// The page ranges the card's `range` is made of, one for each stretch of
    /// page characters that run on (a card's entry can sit in two columns or
    /// on two pages).
    func pageRuns(forDisplayRange range: NSRange) -> [(pageIndex: Int, range: NSRange)] {
        let positions = kept.filter { NSLocationInRange($0.offset, range) }.compactMap(\.unit)
        guard let first = positions.min(), let last = positions.max() else { return [] }
        var runs: [(pageIndex: Int, range: NSRange)] = []
        for unit in units[first...last] {
            if let run = runs.last, run.pageIndex == unit.pageIndex, NSMaxRange(run.range) == unit.index {
                runs[runs.count - 1].range.length += 1
            } else {
                runs.append((unit.pageIndex, NSRange(location: unit.index, length: 1)))
            }
        }
        return runs
    }

    /// The ranges of the card's text that `marks` — ranges of the pages'
    /// text, each with what it stands for — cover, adjacent ones with the same
    /// meaning joined, and the spaces between two words so marked marked too.
    func displayRanges<Value: Equatable>(
        marking marks: [(pageIndex: Int, range: NSRange, value: Value)],
        in display: String
    ) -> [(range: NSRange, value: Value)] {
        guard !marks.isEmpty else { return [] }
        var valueOfKept: [Int: Value] = [:]
        for (position, entry) in kept.enumerated() {
            guard let unit = entry.unit else { continue }
            let character = units[unit]
            if let mark = marks.last(where: { $0.pageIndex == character.pageIndex && NSLocationInRange(character.index, $0.range) }) {
                valueOfKept[position] = mark.value
            }
        }
        guard !valueOfKept.isEmpty else { return [] }
        let shown = display as NSString
        var result: [(range: NSRange, value: Value)] = []
        var open: (start: Int, end: Int, value: Value)?
        func close() {
            if let open { result.append((NSRange(location: open.start, length: open.end - open.start), open.value)) }
            open = nil
        }
        for position in kept.indices {
            let offset = kept[position].offset
            guard let value = valueOfKept[position] else {
                close()
                continue
            }
            if let current = open, current.value == value, onlySpacingBetween(current.end, offset, in: shown) {
                open = (current.start, offset + 1, value)
            } else {
                close()
                open = (offset, offset + 1, value)
            }
        }
        close()
        return result
    }

    private func onlySpacingBetween(_ from: Int, _ to: Int, in text: NSString) -> Bool {
        guard from <= to else { return false }
        return (from..<to).allSatisfy { Self.isIgnorable(text.character(at: $0)) }
    }
}

// MARK: - The card's text

/// A mark on a card's text: where, and what colour.
struct ReaderReferenceMark: Equatable {
    var range: NSRange
    var color: NSColor
}

/// The reference text itself: selectable, with the learner's highlights drawn
/// on it. A press anywhere in it is reported, so a card the pointer merely
/// passed over stays once it is clicked into.
struct ReaderReferenceText: NSViewRepresentable {
    let text: String
    let marks: [ReaderReferenceMark]
    /// The words selected and the box they fill in this view (flipped, from
    /// its top left), or nil once nothing is selected.
    var selectionChanged: ((NSRange, CGRect)?) -> Void = { _ in }
    var pressed: () -> Void = {}
    let handle: ReaderReferenceTextHandle

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReferenceTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 336, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let view = ReferenceTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Reference")
        handle.view = view
        return view
    }

    func updateNSView(_ view: ReferenceTextView, context: Context) {
        context.coordinator.selectionChanged = selectionChanged
        view.pressed = pressed
        handle.view = view
        guard context.coordinator.shown?.text != text || context.coordinator.shown?.marks != marks else { return }
        context.coordinator.shown = (text, marks)
        let selected = view.selectedRange()
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .callout),
            .foregroundColor: NSColor.labelColor,
        ])
        for mark in marks where NSMaxRange(mark.range) <= attributed.length {
            attributed.addAttribute(.backgroundColor, value: mark.color, range: mark.range)
        }
        view.textStorage?.setAttributedString(attributed)
        if NSMaxRange(selected) <= attributed.length { view.setSelectedRange(selected) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ReferenceTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 336
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var shown: (text: String, marks: [ReaderReferenceMark])?
        var selectionChanged: ((NSRange, CGRect)?) -> Void = { _ in }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, let layout = view.layoutManager,
                  let container = view.textContainer else { return }
            let range = view.selectedRange()
            guard range.length > 0,
                  !(view.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                selectionChanged(nil)
                return
            }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += view.textContainerOrigin.x
            rect.origin.y += view.textContainerOrigin.y
            selectionChanged((range, rect))
        }
    }
}

/// Reaches the text view a card entry shows, to clear its selection once the
/// words are highlighted.
final class ReaderReferenceTextHandle {
    weak var view: NSTextView?

    @MainActor
    func clearSelection() {
        view?.setSelectedRange(NSRange(location: 0, length: 0))
    }
}

final class ReferenceTextView: NSTextView {
    var pressed: () -> Void = {}

    /// The card's window is a popover, which a first click would otherwise
    /// only focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed()
        super.mouseDown(with: event)
    }
}

// MARK: - The bar over a selection

/// The colours a highlight can be, over the words selected on a card: one
/// press marks them in that colour (the reader's own bar marks them and then
/// offers the colours, which a card has no room to do).
struct ReaderReferenceHighlightBar: View {
    let choose: (SourceHighlightColor) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SourceHighlightColor.allCases, id: \.self) { option in
                Button { choose(option) } label: {
                    Circle()
                        .fill(Color(.sRGB, red: option.components.red, green: option.components.green, blue: option.components.blue, opacity: 1))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.hoverWash(in: Circle(), inset: -4))
                .help("Highlight \(option.displayName.lowercased())")
                .accessibilityLabel("Highlight \(option.displayName.lowercased())")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .fixedSize()
    }

    /// The bar's width, for placing it over a selection.
    static let width: CGFloat = 5 * 15 + 4 * 6 + 20
    static let height: CGFloat = 15 + 14
}
