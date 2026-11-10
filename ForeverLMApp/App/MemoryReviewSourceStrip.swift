// The memory review source strip, its chips and the source turn row.
import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

/// The material a day's memory review covers, pinned above its transcript.
///
/// A memory review is a conversation about specific sources, and the
/// conversation alone never says which ones, nor how far through them the day
/// is. The strip says both: every source the review carries, with its cover,
/// and a check on each one whose contour has been graded.
/// One chip in the day's review strip: a library source, or a chat the
/// review carries under its session id.
struct MemoryReviewStripEntry: Identifiable {
    let id: String
    let title: String
    /// Nil for a chat, which is review material without being a source row.
    let article: StudioArticle?
}

struct MemoryReviewSourceStrip: View {
    let sources: [MemoryReviewStripEntry]
    let statusBySource: [String: MemoryReviewSourceStatus]
    /// The source the tutor is asking about right now; its chip is ringed and
    /// scrolled into view, so the strip reads done, current, upcoming.
    let currentSourceID: String?
    /// True while a turn is in flight; a click then would land mid-reply.
    let isBusy: Bool
    let bookCoverPath: (StudioArticle) -> String?
    let columnMaxWidth: CGFloat
    let gutter: CGFloat
    /// A hairline under the strip, over a scrolling conversation. A card
    /// floats under the strip on its own and needs none.
    let separated: Bool
    /// The learner clicked a source: steer the review to it.
    let steer: (MemoryReviewStripEntry) -> Void
    /// Open the source in the reader, from the chip's context menu.
    let open: (String) -> Void
    /// The learner clicked a chip's ×: take the source out of today's review.
    let remove: (MemoryReviewStripEntry) -> Void

    private var reviewedCount: Int {
        sources.filter { statusBySource[$0.id] != nil }.count
    }

    private var isComplete: Bool { reviewedCount == sources.count }

    /// Says where the day stands, in the terms the review itself uses.
    private var summary: String {
        if reviewedCount == 0 {
            return sources.count == 1 ? "1 source today" : "\(sources.count) sources today"
        }
        if isComplete {
            return sources.count == 1
                ? "Reviewed today"
                : "All \(sources.count) reviewed today"
        }
        return "\(reviewedCount) of \(sources.count) reviewed today"
    }

    /// The chip scrolled to the middle of the strip. Scoped to the strip's own
    /// scroll view: a `ScrollViewReader` jump to the current chip is suspected
    /// of also scrolling the chat column it sits in, which left the pane's
    /// title, controls and this summary under the titlebar on entering a
    /// review (2026-09-25).
    @State private var centeredSourceID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.green)
                            .zoomedSystemFont(size: 10)
                    }
                    Text(summary)
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(isComplete ? Color.green : Color.secondary)
                        .textCase(.uppercase)
                        .kerning(0.6)
                        .lineLimit(1)
                        .fixedSize()
                }
                progressLine
            }
            .padding(.horizontal, gutter)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sources) { source in
                        MemoryReviewSourceChip(
                            source: source,
                            bookCoverPath: source.article.flatMap(bookCoverPath),
                            status: statusBySource[source.id],
                            isCurrent: source.id == currentSourceID,
                            isBusy: isBusy,
                            steer: { steer(source) },
                            // A chat has no reader to open it in.
                            open: source.article == nil ? nil : { open(source.id) },
                            // A graded contour is a record, and stays.
                            remove: statusBySource[source.id] == nil ? { remove(source) } : nil
                        )
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, gutter)
                .padding(.vertical, 2)
            }
            .scrollPosition(id: $centeredSourceID, anchor: .center)
            // Chips running past either end fade out rather than stop at a
            // hard edge mid-word.
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: gutter)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: gutter + 6)
                }
            )
            .onChange(of: currentSourceID, initial: true) { _, current in
                guard let current, sources.contains(where: { $0.id == current }) else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    centeredSourceID = current
                }
            }
        }
        // Follow the transcript's reading column, summary included, so the
        // strip begins on the same leading outline as the card under it.
        .frame(maxWidth: columnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, separated ? 8 : 2)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if separated {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today's review sources, \(summary)")
    }

    /// How far through the day's sources the review is, as a hairline.
    private var progressLine: some View {
        let fraction = sources.isEmpty ? 0 : CGFloat(reviewedCount) / CGFloat(sources.count)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(isComplete ? Color.green : Color.accentColor)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 160)
        .animation(.easeInOut(duration: 0.3), value: reviewedCount)
        .accessibilityHidden(true)
    }
}

/// One source in the review strip. Clicking steers the review to it: a source
/// already checked off gets probed deeper, one still waiting is taken now. The
/// reader is one right-click away, for "what did it actually say?". A source
/// not yet graded also carries a × under the pointer, for material the day
/// should not have picked; it is a sibling of the steer button, not part of
/// its label, so each click has exactly one owner.
private struct MemoryReviewSourceChip: View {
    let source: MemoryReviewStripEntry
    let bookCoverPath: String?
    /// Non-nil once this source's contour has been graded in this review.
    let status: MemoryReviewSourceStatus?
    /// True while the tutor's questions are about this source.
    let isCurrent: Bool
    /// True while a turn is in flight, when a steer would land mid-reply.
    let isBusy: Bool
    let steer: () -> Void
    /// Open the source in the reader; nil for a chat.
    let open: (() -> Void)?
    /// Take the source out of today's review; nil once it has been graded.
    let remove: (() -> Void)?

    @State private var isHovering = false

    private var isReviewed: Bool { status != nil }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 9, style: .continuous) }

    private var helpText: String {
        let state: String
        if let status {
            state = status.recallSummary
        } else {
            state = "not reviewed yet"
        }
        let action = isReviewed ? "Click to go deeper" : "Click to review it now"
        let where_ = isCurrent ? "\(source.title) — reviewing now; \(state)" : "\(source.title) — \(state)"
        return open == nil ? "\(where_). \(action)." : "\(where_). \(action); right-click to open it."
    }

    private var accessibilityText: String {
        let reviewed = isReviewed ? "Reviewed" : "Not reviewed yet"
        return isCurrent ? "Reviewing now, \(reviewed.lowercased()): \(source.title)" : "\(reviewed): \(source.title)"
    }

    private var removeGlyph: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .background(Color.primary.opacity(0.08), in: Circle())
            .contentShape(Circle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let article = source.article {
            SourceThumbnail(source: article, size: 26, bookCoverPath: bookCoverPath)
        } else {
            Image(systemName: "bubble.left.and.bubble.right")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: steer) {
                HStack(spacing: 7) {
                    thumbnail
                        .overlay(alignment: .bottomTrailing) {
                            if isReviewed {
                                Image(systemName: "checkmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.green)
                                    .zoomedSystemFont(size: 11)
                                    .offset(x: 3, y: 3)
                            }
                        }
                    Text(source.title)
                        .zoomedSystemFont(size: 11.5, weight: isCurrent ? .medium : .regular)
                        .foregroundStyle(isReviewed && !isCurrent ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 5)
                .padding(.trailing, remove == nil ? 9 : 4)
                .padding(.vertical, 4)
                .contentShape(shape)
            }
            .buttonStyle(.hoverWash(in: shape, inset: 0))
            .disabled(isBusy)
            .help(helpText)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(isReviewed ? "Go deeper on this source" : "Review this source now")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])

            if let remove {
                // Built only under the pointer, the hidden glyph holding its
                // place: a button at opacity 0 is still a live control, and
                // while an assistive app reads the screen SwiftUI walks every
                // control in the window for each one an update builds
                // (2026-10-03). The right-click and the named action below
                // remove it too.
                Group {
                    if isHovering {
                        Button(action: remove) {
                            removeGlyph
                        }
                        .buttonStyle(.hoverWash(in: Circle()))
                        .disabled(isBusy)
                        .help("Remove \(source.title) from today's review")
                        .accessibilityLabel("Remove \(source.title) from today's review")
                        .accessibilityIdentifier("mac.chatMemoryRemoveSource")
                    } else {
                        removeGlyph
                            .hidden()
                    }
                }
                .padding(.trailing, 6)
            }
        }
        .frame(maxWidth: 190, alignment: .leading)
        .background(
            shape.fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            shape.strokeBorder(
                isCurrent ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.06),
                lineWidth: isCurrent ? 1.5 : 1
            )
        )
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(isReviewed ? "Go deeper on this" : "Review this now", action: steer)
                .disabled(isBusy)
            if let open {
                Button("Open in reader", action: open)
            }
            if let article = source.article {
                OtherWindowSourceMenuItem(article)
            }
            if let remove {
                Divider()
                Button("Remove from today's review", action: remove)
                    .disabled(isBusy)
            }
        }
        .accessibilityElement(children: .contain)
        // The × shows under the pointer; a screen reader has no pointer, so
        // the same removal is a named action on the chip.
        .modifier(MemoryReviewChipRemoveAction(remove: remove))
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }
}

/// "Remove from today's review" as an accessibility action, present only
/// while the chip offers removal; SwiftUI has no optional action modifier.
private struct MemoryReviewChipRemoveAction: ViewModifier {
    let remove: (() -> Void)?

    func body(content: Content) -> some View {
        if let remove {
            content.accessibilityAction(named: "Remove from today's review", remove)
        } else {
            content
        }
    }
}

/// The transcript's heading for a source: "now the review turns to this". A
/// full-width row between the verdict on the last source and the first
/// question about the next, so the switch happens where the eye already is
/// rather than as a checkmark far above. Clicking opens the source, the same
/// answer the chip gives to "what did it actually say?".
struct MemoryReviewSourceTurnRow: View {
    let source: StudioArticle
    let bookCoverPath: String?
    /// This source's place in the day, as (ordinal, count); nil when the
    /// source is not in the strip.
    let position: (Int, Int)?
    let open: () -> Void

    private var positionText: String? {
        guard let position, position.1 > 1 else { return nil }
        return "\(position.0) of \(position.1)"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 18, height: 1)
                SourceThumbnail(source: source, size: 28, bookCoverPath: bookCoverPath)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Now reviewing")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                        .textCase(.uppercase)
                        .kerning(0.6)
                    Text(source.title)
                        .zoomedSystemFont(size: 13, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if let positionText {
                    Text(positionText)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opensInOtherWindow(source)
        .help("Open \(source.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            positionText.map { "Now reviewing \(source.title), source \($0)" }
                ?? "Now reviewing \(source.title)"
        )
        .accessibilityIdentifier("mac.chatMemorySourceTurn")
    }
}
