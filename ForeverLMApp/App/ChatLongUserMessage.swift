import AppKit
import SwiftUI

/// A learner turn long enough that drawing it as one selectable `Text` stalls
/// the window.
///
/// `ForeverLMApp.swift` turns `.textSelection(.enabled)` on for the whole Studio
/// window, so a user bubble's `Text` is hosted by SwiftUI's selection overlay
/// rather than drawn directly. That overlay does main-thread work per line of
/// text on every graph update, and on 2026-09-17 an 11 KB meeting transcript
/// pasted into the composer — 166 lines — pinned the main thread in
/// `SelectionOverlay.updateNSView` → `FallbackAlignmentProvider` →
/// `-[NSControl setFont:]` until the app had to be force-quit. No app frame
/// was on the stack: the cost is SwiftUI's, and it grows with the text.
///
/// So a long learner message is drawn the way Claude draws a long paste: folded
/// to its first lines with a count, opening on request — and the open text is
/// an AppKit text view, which lays out a few hundred lines without the overlay.
/// The thresholds are generous on purpose: a typed question or a short list
/// still reads as one bubble, and only a paste folds.
enum ChatLongUserMessage {
    /// A message with more lines than this folds, however short the lines.
    static let lineThreshold = 24
    /// A message with more characters than this folds, however few lines
    /// (a wall of prose wraps into as many rows as a list does).
    static let characterThreshold = 4_000
    /// The lines the folded card shows.
    static let previewLineCount = 6

    static func isLong(_ text: String) -> Bool {
        text.count > characterThreshold || lineCount(text) > lineThreshold
    }

    /// Lines as the bubble lays them out. Blank lines inside the message count,
    /// because they take a row too; the surrounding whitespace does not.
    static func lineCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    /// The first `previewLineCount` non-empty lines, as the folded card shows
    /// them.
    static func preview(_ text: String) -> String {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(previewLineCount)
            .joined(separator: "\n")
    }

    /// "166 lines", "1 line".
    static func summary(lineCount: Int) -> String {
        lineCount == 1 ? "1 line" : "\(lineCount) lines"
    }
}

/// The folded card a long learner turn is drawn as. See `ChatLongUserMessage`.
struct ReviewChatLongUserMessageView: View {
    let content: String

    @Environment(\.uiZoomScale) private var uiZoomScale
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExpanded {
                ReviewChatPlainTextView(
                    text: content,
                    font: .systemFont(ofSize: ChatMarkdownView.baseFontSize * uiZoomScale)
                )
            } else {
                // The fold exists to keep SwiftUI's selection overlay off this
                // text; the open card and the Copy button are where the words
                // are taken from.
                Text(ChatLongUserMessage.preview(content))
                    .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
                    .textSelection(.disabled)
                    .lineLimit(ChatLongUserMessage.previewLineCount)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text(ChatLongUserMessage.summary(lineCount: ChatLongUserMessage.lineCount(content)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                Button(isExpanded ? "Show less" : "Show all") {
                    isExpanded.toggle()
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -3))
                .font(.caption)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.hoverWash)
                .foregroundStyle(.secondary)
                .help("Copy the whole message")
            }
        }
        // A long message fills the column. The hug that keeps a three-word
        // question from stretching into a pill has nothing to protect here, and
        // the text view needs a definite width to lay out against.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A read-only, selectable AppKit text view sized to its text, for message text
/// too long to hand SwiftUI's selection overlay.
struct ReviewChatPlainTextView: NSViewRepresentable {
    let text: String
    let font: NSFont

    final class TextView: NSTextView {
        private var measuredWidth: CGFloat = -1
        private var measuredHeight: CGFloat = 0
        private var appliedFingerprint = ""

        func apply(text: String, font: NSFont) {
            let fingerprint = "\(font.fontName)|\(font.pointSize)|\(text)"
            guard fingerprint != appliedFingerprint, let storage = textStorage else { return }
            appliedFingerprint = fingerprint
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
            storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            typingAttributes = attributes
            measuredWidth = -1
        }

        /// Height of the text laid out at `width`, cached per width: SwiftUI
        /// asks on every layout pass.
        func height(forWidth width: CGFloat) -> CGFloat {
            if abs(width - measuredWidth) < 0.5 { return measuredHeight }
            guard let container = textContainer, let layoutManager else { return 0 }
            container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            measuredWidth = width
            measuredHeight = ceil(layoutManager.usedRect(for: container).height)
            return measuredHeight
        }
    }

    func makeNSView(context: Context) -> TextView {
        // TextKit 1: avoids a macOS 26 TextKit 2 hang where click selection
        // hit-testing loops forever on the main thread (see ReviewChatComposer).
        let view = TextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = false
        view.usesFontPanel = false
        view.isAutomaticLinkDetectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.apply(text: text, font: font)
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        view.apply(text: text, font: font)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TextView, context: Context) -> CGSize? {
        // The card fills its column, so the proposal carries a width; a pass
        // without one is measured at a reading width rather than one line.
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = max(proposed, 1)
        } else {
            width = 480
        }
        return CGSize(width: width, height: view.height(forWidth: width))
    }
}
