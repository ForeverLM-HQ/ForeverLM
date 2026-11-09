#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

/// A cover as this Mac draws it: the picture, and whether its ground was taken away
/// (`NotebookCoverCutout`). A cover that has no flat ground to take stays as drawn.
struct NotebookCoverPicture {
    let image: NSImage
    let isBare: Bool

    /// The picture the stored bytes hold, cut once. Off the main actor: it reads and walks every pixel.
    nonisolated static func make(from data: Data) -> NotebookCoverPicture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let drawn = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return NSImage(data: data).map { NotebookCoverPicture(image: $0, isBare: false) }
        }
        if let bare = NotebookCoverCutout.bare(drawn) {
            return NotebookCoverPicture(image: NSImage(cgImage: bare, size: NSSize(width: bare.width, height: bare.height)), isBare: true)
        }
        return NotebookCoverPicture(image: NSImage(cgImage: drawn, size: NSSize(width: drawn.width, height: drawn.height)), isBare: false)
    }
}

/// The notebook covers this Mac draws as pictures (docs/cloudkit-schema-design.md D53, §5.9): the picture
/// `Notebook.files.cover` names, read from the replica, from this Mac's cache, or fetched once from its
/// satellite. Generation 2 only: generation 1 has no cover, so nothing here reads a store.
@MainActor
final class NotebookCoverImages {
    static let shared = NotebookCoverImages()

    /// The pictures by the hash of their bytes: content-addressed, so never stale.
    private var pictures: [String: NotebookCoverPicture] = [:]
    private var inFlight: [String: Task<NotebookCoverPicture?, Never>] = [:]

    /// The notebook's cover, by the id its row has; nil for none, and until its bytes are here.
    func picture(forNotebook rowID: String) async -> NotebookCoverPicture? {
        guard let covers = NotebookCoverService.current,
              let pointer = await covers.pointer(ofRow: rowID) else { return nil }
        let hash = pointer.file.hash
        if let held = pictures[hash] { return held }
        if let running = inFlight[hash] { return await running.value }
        let task = Task { () -> NotebookCoverPicture? in
            guard let data = await covers.bytes(of: pointer) else { return nil }
            return await Task.detached(priority: .utility) { NotebookCoverPicture.make(from: data) }.value
        }
        inFlight[hash] = task
        let picture = await task.value
        inFlight[hash] = nil
        if let picture { pictures[hash] = picture }
        return picture
    }
}

/// A notebook's icon wherever it is drawn as a picture: its cover once the Mac holds one, the emoji
/// (`fallback`) while the cover is missing or still arriving. Menus and sentences, which are text, keep
/// the emoji and never use this.
///
/// A cover is drawn bare: the icon alone, as large as `size`, with no tile behind it, and in a dark
/// window on a light plate, since its strokes are dark. One with no flat ground to take away is drawn
/// as it was made, filling a rounded square or a circle.
struct NotebookIconView<Fallback: View>: View {
    let notebookID: String
    /// The picture's side in points: the frame the emoji sits in at its place.
    let size: CGFloat
    /// The picture's corner radius; nil for a circle.
    var cornerRadius: CGFloat?
    /// The tile the emoji sits on while there is no cover, such as the notebook's colour. A cover
    /// never sits on it.
    var plate: Color?
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.colorScheme) private var colorScheme
    @State private var cover: NotebookCoverPicture?

    private var shape: AnyShape {
        cornerRadius.map { AnyShape(RoundedRectangle(cornerRadius: $0, style: .continuous)) } ?? AnyShape(Circle())
    }

    var body: some View {
        Group {
            if let cover {
                if cover.isBare {
                    bare(cover.image)
                } else {
                    Image(nsImage: cover.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(shape)
                }
            } else if let plate {
                fallback()
                    .frame(width: size, height: size)
                    .background(plate, in: shape)
            } else {
                fallback()
            }
        }
        .task(id: notebookID) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .notebookCoversDidChange)) { notice in
            if let changed = notice.userInfo?["notebookID"] as? String, changed != notebookID { return }
            Task { await refresh() }
        }
    }

    /// The icon alone. In a dark window its dark strokes would sink into the window, so it sits on a
    /// light plate there. A circle (a token on its notebook's colour, the collections' stack) holds it
    /// inside, so its corners are not cut off.
    @ViewBuilder
    private func bare(_ image: NSImage) -> some View {
        let plated = colorScheme == .dark
        let inset = cornerRadius == nil ? size * 0.17 : (plated ? size * 0.1 : 0)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(inset)
            .frame(width: size, height: size)
            .background {
                if plated { shape.fill(Color(nsColor: NSColor(white: 0.94, alpha: 1))) }
            }
    }

    private func refresh() async {
        let picture = await NotebookCoverImages.shared.picture(forNotebook: notebookID)
        if picture?.image !== cover?.image { cover = picture }
    }
}

/// Draw Cover With ▸ on a notebook's menu: draws its cover again with a chosen image model (the Settings ›
/// Images choice first, then its Suggested list, as Redraw With offers them), over the cover it has. It is
/// also how a notebook gets a cover when Draw notebook covers is off. Generation 2 only, and never in Free
/// mode, which draws no pictures.
struct NotebookCoverMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    let notebookID: String

    var body: some View {
        if NotebookCoverService.current != nil {
            let models = GeneratedImageRedraw.offeredModels(
                settingsChoice: MacImageGenerationSettings.model.id,
                directory: ImageGenerationCatalog.models
            )
            Menu("Draw Cover With", systemImage: "photo") {
                if models.isEmpty {
                    Text("Loading image models…")
                }
                ForEach(models) { model in
                    Button(model.name) { draw(with: model) }
                }
            }
        }
    }

    private func draw(with model: ImageGenerationModel) {
        guard let covers = NotebookCoverService.current else { return }
        vm.showToast("Drawing the cover with \(model.name)…")
        Task {
            do {
                switch try await covers.drawNow(notebookID, model: model) {
                case .drawn: vm.showToast("Drew the cover")
                case .hasCover: break
                case .notActive: vm.showToast("An archived notebook is not drawn a cover")
                case .notHeld: vm.showToast("This notebook has not reached the library yet; try again in a moment")
                }
            } catch {
                vm.showToast("Could not draw the cover: \(error.localizedDescription)")
            }
        }
    }
}
#endif
