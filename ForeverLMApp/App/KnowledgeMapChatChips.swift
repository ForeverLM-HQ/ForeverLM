import SwiftUI

// MARK: - The canvas as chips over the composer (docs/knowledge-map-design.md, "Add to Chat and the chips")
//
// A chat opened from a canvas shows what the model was told of it: the canvas
// as one chip, each card added to the chat as another, in the composer's chip
// style (a wash under the pointer, no outline at rest). Each has an × under
// the pointer; the canvas chip's takes the whole canvas out of the chat, a
// card's takes that card out of the next turn. More than six cards and the
// sixth chip is "+N", which opens the rest. A click on a card chip shows the
// card on the canvas. The empty chat also offers the maps the Canvas can draw
// from its cards (`KnowledgeMapChatOffers`). The numbers and words are
// `KnowledgeMapChatChips`; this file is the drawing.

/// The canvas chip, a chip per card and "+N", as children of the composer's
/// context row, so they wrap with the notebook chip and the "in context" pill.
struct KnowledgeMapChatChipRow: View {
    let context: KnowledgeMapChatContext
    /// A card's glyph: its type's own while the Canvas holds the card.
    let symbol: (KnowledgeMapChatCard) -> String
    let showCanvas: () -> Void
    let showCard: (String) -> Void
    let removeCard: (String) -> Void
    let removeCanvas: () -> Void

    @State private var isOverflowPresented = false

    var body: some View {
        let split = KnowledgeMapChatChips.split(context.cards)
        ComposerRemovableChip(
            symbol: KnowledgeMap.symbolName,
            title: context.name,
            maxTitleWidth: 180,
            help: "This chat is about the canvas \u{201C}\(context.name)\u{201D}: click to open it",
            removeHelp: "Take the canvas and its cards out of this chat",
            accessibilityLabel: "Canvas: \(context.name)",
            open: showCanvas,
            remove: removeCanvas
        )
        .accessibilityIdentifier("chat.canvasChip")
        ForEach(split.shown) { card in
            ComposerRemovableChip(
                symbol: symbol(card),
                title: KnowledgeMapChatChips.title(of: card),
                maxTitleWidth: nil,
                help: "Show \u{201C}\(card.title)\u{201D} on the canvas",
                removeHelp: "Take \u{201C}\(card.title)\u{201D} out of this chat",
                accessibilityLabel: "Canvas card: \(card.title)",
                open: { showCard(card.ref) },
                remove: { removeCard(card.ref) }
            )
        }
        if !split.overflow.isEmpty {
            overflowChip(split.overflow)
        }
    }

    private func overflowChip(_ rest: [KnowledgeMapChatCard]) -> some View {
        Button {
            isOverflowPresented.toggle()
        } label: {
            Text("+\(rest.count)")
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(ComposerChipButtonStyle())
        .help("Show the \(rest.count) more cards in this chat")
        .accessibilityLabel("\(rest.count) more canvas cards")
        .accessibilityIdentifier("chat.canvasCardChip.more")
        .popover(isPresented: $isOverflowPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rest) { card in
                    KnowledgeMapChatOverflowRow(
                        symbol: symbol(card),
                        card: card,
                        open: {
                            isOverflowPresented = false
                            showCard(card.ref)
                        },
                        remove: {
                            removeCard(card.ref)
                            if rest.count == 1 { isOverflowPresented = false }
                        }
                    )
                }
            }
            .padding(8)
            .frame(width: 280)
        }
    }
}

/// One chip over the composer: a glyph and a title that open what it names,
/// and an × that takes it out of the chat. The × is built only under the
/// pointer, its glyph's room kept, so a chip does not shift under the cursor
/// and a row of chips does not read as a row of buttons. The canvas's chips
/// and the chips for what is open beside the chat
/// (`InternalReviewPanel.onScreenChips`) are drawn by it.
struct ComposerRemovableChip: View {
    let symbol: String
    let title: String
    /// The width a long title is cut to; nil lets the title run to its length.
    let maxTitleWidth: CGFloat?
    let help: String
    let removeHelp: String
    let accessibilityLabel: String
    /// Nil for a chip with nothing to open: a source already on screen
    /// beside the chat is in front of the learner.
    let open: (() -> Void)?
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            if let open {
                Button(action: open) {
                    label
                }
                .buttonStyle(.plain)
                .help(help)
            } else {
                label
                    .help(help)
            }
            if isHovering {
                Button(action: remove) {
                    KnowledgeMapChatChipRemoveGlyph()
                }
                .buttonStyle(.plain)
                .help(removeHelp)
            } else {
                KnowledgeMapChatChipRemoveGlyph()
                    .hidden()
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
        .contentShape(Capsule())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // The × for VoiceOver, which has no pointer to bring it out; while the
        // × is built, the combined element carries its press already.
        .accessibilityActions {
            if !isHovering {
                Button("Remove from Chat", action: remove)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxTitleWidth, alignment: .leading)
            // A chip's name is a label, not text to copy; outside a button
            // the window's text selection would otherwise take the drag.
                .textSelection(.disabled)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Capsule())
    }
}

private struct KnowledgeMapChatChipRemoveGlyph: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
            .background(Color.primary.opacity(0.08), in: Circle())
            .contentShape(Circle())
    }
}

/// A card behind "+N": the same click and the same ×, as a row.
private struct KnowledgeMapChatOverflowRow: View {
    let symbol: String
    let card: KnowledgeMapChatCard
    let open: () -> Void
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                    Text(card.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show \u{201C}\(card.title)\u{201D} on the canvas")
            if isHovering {
                Button(action: remove) {
                    KnowledgeMapChatChipRemoveGlyph()
                }
                .buttonStyle(.plain)
                .help("Take \u{201C}\(card.title)\u{201D} out of this chat")
            } else {
                KnowledgeMapChatChipRemoveGlyph()
                    .hidden()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Canvas card: \(card.title)")
        .accessibilityActions {
            if !isHovering {
                Button("Remove from Chat", action: remove)
            }
        }
    }
}

// MARK: - The maps the empty chat offers

/// Under the empty chat's composer, beside the suggested questions: Make a
/// Mind Map, and Break Into Questions when one of the cards is a question.
/// A click runs that Ask on the canvas (`StudioViewModel.startCanvasAsk(_:from:)`)
/// and nothing is typed. Quiet rows, as the empty chat's other starting
/// points are: a glyph and the words, brightening under the pointer.
struct KnowledgeMapChatOffers: View {
    let offersQuestionMap: Bool
    let start: (CanvasAskTool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(.mindMap, symbol: "point.3.connected.trianglepath.dotted", help: "Draw a mind map of these cards on the canvas, for you to keep or put back")
            if offersQuestionMap {
                row(.questionMap, symbol: "questionmark.bubble", help: "Break the question into narrower ones on the canvas, for you to keep or put back")
            }
        }
        .padding(.horizontal, StudioDesign.Spacing.small)
        .accessibilityIdentifier("chat.canvasOffers")
    }

    private func row(_ tool: CanvasAskTool, symbol: String, help: String) -> some View {
        Button {
            start(tool)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .zoomedSystemFont(size: 12, weight: .regular)
                    .frame(width: 18)
                Text(tool.menuTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .help(help)
        .accessibilityIdentifier("chat.canvasOffer.\(tool.rawValue)")
    }
}
