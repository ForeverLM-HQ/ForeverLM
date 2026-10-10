import AppKit
import SwiftUI

/// Pictures attached to one side of a Memory card. A pair shares the row;
/// larger sets wrap in two columns. Each picture resolves through the same
/// durable reference and renderer used by chat, including source-page crops
/// and generated images.
struct MemoryCardImageGrid: View {
    let images: [MemoryCardImage]

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: min(2, max(1, images.count)))
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(images, id: \.self) { image in
                MemoryCardImageTile(image: image)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards.images")
    }
}

private struct MemoryCardImageTile: View {
    @Environment(StudioViewModel.self) private var vm

    let image: MemoryCardImage

    @State private var resolved: ChatSourceImage?
    @State private var nsImage: NSImage?
    @State private var didResolve = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        Group {
            if let nsImage {
                Button {
                    guard let resolved else { return }
                    ChatImageLightbox.present(resolved, title: image.alt, over: nil)
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .background(Color.white, in: shape)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(Color.primary.opacity(0.09)))
                }
                .buttonStyle(.plain)
                .help("Open \(image.alt) large")
            } else if didResolve {
                Label("\(image.alt): picture unavailable on this device", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(Color.primary.opacity(0.04), in: shape)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(Color.primary.opacity(0.04), in: shape)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(image.alt)
        .task(id: image.target) {
            let found = await ChatSourceImage.resolved(
                token: image.target,
                articleForSourceID: { sourceID in await vm.persistedArticle(forLinkToken: sourceID) },
                contentForSourceID: { sourceID in await vm.storage.loadSourceContent(sourceID) }
            )
            resolved = found
            nsImage = found.flatMap { NSImage(data: $0.data) }
            didResolve = true
        }
    }
}
