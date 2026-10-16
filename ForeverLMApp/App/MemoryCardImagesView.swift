import AppKit
import SwiftUI

/// Pictures attached to one side of a Memory card, and the one animation it
/// may carry (`MemoryCardImage.faceList`). A pair of pictures shares the row;
/// larger sets wrap in two columns. Each picture resolves through the same
/// durable reference and renderer used by chat, including source-page crops
/// and generated images. The animation plays below them in a sandboxed web
/// view. Only a face on screen builds one: the grid is drawn where its side is
/// shown, so an answer's animation stays out of the tree until the back shows,
/// and a view that deals several cards at once passes
/// `animationStartsAtOnce: false` so each holds a poster until it is played.
struct MemoryCardImageGrid: View {
    let images: [MemoryCardImage]
    var animationStartsAtOnce = true

    private func columns(for count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: min(2, max(1, count)))
    }

    var body: some View {
        let split = MemoryCardImage.split(images)
        VStack(alignment: .leading, spacing: 8) {
            if !split.pictures.isEmpty {
                LazyVGrid(columns: columns(for: split.pictures.count), alignment: .leading, spacing: 8) {
                    ForEach(split.pictures, id: \.self) { image in
                        MemoryCardImageTile(image: image)
                    }
                }
                .accessibilityIdentifier("memory.cards.images")
            }
            if let animation = split.animation {
                MemoryCardAnimationTile(image: animation, startsAtOnce: animationStartsAtOnce)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A card's animation, played inline from its library address in the card
/// player's web view: scripts run, nothing loads from the network, and the
/// page keeps its own controls. The web view is built when the tile is
/// played (at once, unless the grid asked for a poster) and torn down when the
/// tile leaves the screen. Enlarge plays it in a sheet.
private struct MemoryCardAnimationTile: View {
    let image: MemoryCardImage
    let startsAtOnce: Bool

    @State private var isPlaying = false
    @State private var isEnlarged = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if isPlaying, let url = image.animationURL {
                    WalkthroughHostedAnimationWebView(url: url, restrictsNetwork: true)
                        .frame(height: 360)
                        .clipShape(shape)
                } else {
                    Button { isPlaying = true } label: {
                        Label("Play \(image.alt)", systemImage: "play.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 96)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 10, inset: 0))
                    .accessibilityIdentifier("memory.cards.animation.play")
                }
            }
            .background(Color.primary.opacity(0.04), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.09)))
            if isPlaying {
                HStack {
                    Spacer()
                    Button { isEnlarged = true } label: {
                        Label("Enlarge", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                    }
                    .buttonStyle(.hoverWash)
                    .help("Play the animation larger")
                    .accessibilityIdentifier("memory.cards.animation.enlarge")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(image.alt)
        .accessibilityIdentifier("memory.cards.animation")
        .onAppear { if startsAtOnce { isPlaying = true } }
        .onDisappear { isPlaying = false }
        .sheet(isPresented: $isEnlarged) {
            if let url = image.animationURL {
                WalkthroughAnimationSheet(title: image.alt, content: .hosted(url: url), restrictsNetwork: true)
            }
        }
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
