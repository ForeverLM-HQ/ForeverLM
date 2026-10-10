import SwiftUI
import AppKit

/// The pictures a learner message carries, drawn above its text bubble.
///
/// Each one resolves through the same store the model reads from, so what is
/// on screen is what was sent. A picture this Mac does not hold — the chat
/// was opened on another device — says so in its frame rather than leaving a
/// hole, the way a source picture that is not on this device does.
struct ReviewChatAttachedImagesRow: View {
    let images: [AttachedImageReference.Occurrence]
    let maxContentWidth: CGFloat

    /// One picture fills the row; two or more share it, capped so a message
    /// of four screenshots stays a strip and not a wall.
    private var thumbnailMaxWidth: CGFloat {
        images.count == 1 ? min(maxContentWidth, 360) : 200
    }

    var body: some View {
        // Trailing-aligned like the bubble under it; wraps when the strip
        // outgrows the column.
        FlowLayout(spacing: 6, alignment: .trailing) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, occurrence in
                ReviewChatAttachedImageThumbnail(
                    occurrence: occurrence,
                    maxWidth: thumbnailMaxWidth,
                    maxHeight: images.count == 1 ? 260 : 150
                )
            }
        }
        .frame(maxWidth: maxContentWidth, alignment: .trailing)
    }
}

struct ReviewChatAttachedImageThumbnail: View {
    let occurrence: AttachedImageReference.Occurrence
    let maxWidth: CGFloat
    let maxHeight: CGFloat

    @State private var image: ChatSourceImage?
    @State private var nsImage: NSImage?
    @State private var didResolve = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        Group {
            if let nsImage {
                // A click opens the picture full-window, as a click on a
                // picture the assistant showed does; the drag and the copy
                // stay on the thumbnail itself.
                Button {
                    guard let image else { return }
                    ChatImageLightbox.present(image, title: occurrence.alt, over: nil)
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                        .contentShape(shape)
                        .onDrag {
                            NSItemProvider(object: nsImage)
                        }
                        .contextMenu {
                            Button {
                                image?.copyToPasteboard()
                            } label: {
                                Label("Copy Image", systemImage: "doc.on.doc")
                            }
                        }
                }
                .buttonStyle(.hoverWash(cornerRadius: 12, inset: -2))
                .accessibilityIdentifier("chat.attachedImage")
            } else if didResolve {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Not on this device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: min(maxWidth, 160), height: 100)
                .background(Color.primary.opacity(0.05), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
            } else {
                shape
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: min(maxWidth, 160), height: 100)
            }
        }
        // Combined, not ignored: ignoring the children left an AXUnknown with
        // no press, so the picture could not be opened from VoiceOver or AX,
        // and it lost chat.attachedImage. The help goes below the element.
        .accessibilityElement(children: .combine)
        .help(occurrence.alt)
        .accessibilityLabel(nsImage == nil && didResolve
            ? "Attached image \(occurrence.alt), not on this device"
            : "Attached image: \(occurrence.alt)")
        .task(id: occurrence.reference.id) {
            let resolved = await ChatSourceImage.resolved(token: occurrence.reference.urlString) { _ in nil }
            image = resolved
            nsImage = resolved.flatMap { NSImage(data: $0.data) }
            didResolve = true
        }
    }
}

/// A picture waiting in the composer, with the control that takes it back out.
struct PendingChatImageChip: View {
    let attachment: ChatImageAttachment
    let remove: () -> Void

    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = NSImage(data: attachment.image.data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
            } else {
                shape
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 56, height: 56)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .padding(3)
            .opacity(isHovering ? 1 : 0.85)
            .help("Remove \(attachment.name)")
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .onHover { isHovering = $0 }
        // The help goes below the group: above it, it replaced the remove
        // button's "Remove …" help.
        .accessibilityElement(children: .contain)
        .help(attachment.name)
        .accessibilityLabel("Attached image: \(attachment.name)")
    }
}

/// Lays children out in rows, wrapping when the next one would overflow.
/// Rows are aligned to `alignment`'s horizontal edge, and a child shorter than
/// its row sits on the row's middle, so a thin bar lines up with text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - row.width
            case .center: x = bounds.minX + (bounds.width - row.width) / 2
            default: x = bounds.minX
            }
            for (index, size) in row.items {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, needed > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
