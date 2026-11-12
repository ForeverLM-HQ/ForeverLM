import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The Library: what is not on this canvas yet
//
// docs/knowledge-map-design.md, "Adding to the canvas (2026-10-10)", part 3.
// A real sidebar on the plane's trailing edge (the plane narrows), closed until
// the learner asks for it with the button after the find field or L. It has no
// search of its own: the find field finds. Each section shows only when it has
// rows and each header folds it. A row is drawn as what it is, drags whole (the
// card itself and its kind's own drag), shows its card in a popover on a click
// and offers Place on the Canvas, Open Beside and Open on a right-click.

// MARK: The sidebar

struct KnowledgeMapLibrarySidebar: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let onClose: () -> Void

    /// The sections folded up; the notebooks start folded.
    @State private var folded: Set<String> = ["notebooks"]
    @State private var showsAllIdeas = false
    /// The card or notebook whose popover shows, one at a time.
    @State private var popoverRef: String?

    private var map: KnowledgeMapModel { vm.knowledgeMap(in: windowState) }

    /// The Ideas that show before Show All.
    private static let ideasShown = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Library")
                    .zoomedSystemFont(size: 13, weight: .semibold)
                    .textSelection(.disabled)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .zoomedSystemFont(size: 11)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .help("Hide the Library (L)")
                .accessibilityLabel("Hide the Library")
                .accessibilityIdentifier("knowledgeMap.library.close")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sections
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
        .accessibilityIdentifier("knowledgeMap.library")
    }

    // MARK: What each section holds

    /// What the sections list, worked out once per drawing: Related first, then
    /// what the notebook of a notebook's canvas holds, then the clips and the
    /// Ideas that are in none of those above them.
    private struct Contents {
        var relatedTitle: String
        var related: [String]
        var notebookTitle: String?
        var notebookRefs: [String]
        var clips: [String]
        var ideas: [String]
        var notebooks: [KnowledgeMapNotebook]
    }

    private var contents: Contents {
        let map = map
        let placed = Set(map.layout.placements.keys)
        let anchors = KnowledgeMapAddSearch.anchors(selection: map.selection, placed: placed, content: map.content)
        let related = KnowledgeMapAddSearch.related(anchors: anchors, content: map.content, placed: placed)
        var listed = Set(related)
        // A notebook's own canvas: its ticked sources not placed, then its
        // open Ideas not placed (product owner, 2026-10-09).
        var notebookTitle: String?
        var notebookRefs: [String] = []
        if let notebookID = vm.canvas(of: map)?.notebookID, let notebook = vm.notebook(id: notebookID) {
            notebookTitle = NotebookTitle(notebook.title).text
            let unticked = vm.notebookChatExclusions[notebookID] ?? []
            notebookRefs = notebook.approvedSourceIDs
                .filter { !unticked.contains($0) }
                .map { KnowledgeMap.ItemRef(kind: .source, id: $0).description }
                .filter { map.nodesByRef[$0] != nil && !placed.contains($0) && !listed.contains($0) }
            let linkedIdeas = Set(vm.ideas
                .filter { idea in
                    idea.status == .open && idea.links.contains { $0.kind == .notebook && $0.targetID == notebookID }
                }
                .map { KnowledgeMap.ItemRef(kind: .idea, id: $0.id).description })
            notebookRefs += map.unplacedIdeaRefs.filter { linkedIdeas.contains($0) && !listed.contains($0) }
            listed.formUnion(notebookRefs)
        }
        // Newest first: the cards list clips oldest first and Ideas newest first.
        let clips = map.content.nodes.reversed()
            .filter { $0.kind == "clip" && !placed.contains($0.ref) && !listed.contains($0.ref) }
            .map(\.ref)
        listed.formUnion(clips)
        let ideas = map.unplacedIdeaRefs.filter { !listed.contains($0) }
        return Contents(
            relatedTitle: map.selection.isEmpty ? "Related to this canvas" : "Related to the selection",
            related: related,
            notebookTitle: notebookTitle,
            notebookRefs: notebookRefs,
            clips: clips,
            ideas: ideas,
            notebooks: map.content.notebooks.filter { !$0.refs.isEmpty }
        )
    }

    @ViewBuilder
    private var sections: some View {
        let held = contents
        if !held.related.isEmpty {
            header("related", held.relatedTitle, placeAll: held.related.count > 1 ? held.related : nil)
            if !folded.contains("related") {
                ForEach(held.related, id: \.self) { ref in
                    row(ref)
                }
            }
        }
        if let title = held.notebookTitle, !held.notebookRefs.isEmpty {
            header("notebook", title, placeAll: held.notebookRefs.count > 1 ? held.notebookRefs : nil)
            if !folded.contains("notebook") {
                ForEach(held.notebookRefs, id: \.self) { ref in
                    row(ref)
                }
            }
        }
        if !held.clips.isEmpty {
            header("clips", "Clips", placeAll: nil)
            if !folded.contains("clips") {
                ForEach(held.clips, id: \.self) { ref in
                    row(ref)
                }
            }
        }
        if !held.ideas.isEmpty {
            header("ideas", "Ideas", placeAll: nil)
            if !folded.contains("ideas") {
                let shown = showsAllIdeas ? held.ideas : Array(held.ideas.prefix(Self.ideasShown))
                ForEach(shown, id: \.self) { ref in
                    row(ref)
                }
                if shown.count < held.ideas.count {
                    Button {
                        showsAllIdeas = true
                    } label: {
                        Text("Show All \(held.ideas.count)")
                            .zoomedSystemFont(size: 11.5)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.08))
                    .accessibilityIdentifier("knowledgeMap.library.ideas.showAll")
                }
            }
        }
        if !held.notebooks.isEmpty {
            header("notebooks", "Notebooks", placeAll: nil)
            if !folded.contains("notebooks") {
                ForEach(held.notebooks, id: \.id) { notebook in
                    KnowledgeMapLibraryNotebookRow(notebook: notebook, popoverRef: $popoverRef)
                }
            }
        }
        if held.related.isEmpty, held.notebookRefs.isEmpty, held.clips.isEmpty, held.ideas.isEmpty, held.notebooks.isEmpty {
            Text("Nothing to place yet.")
                .zoomedSystemFont(size: 11.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .textSelection(.disabled)
        }
    }

    /// A card's row. The row is given the card itself, so it is drawn again when
    /// the card changes (the model's index of cards is not observed).
    @ViewBuilder
    private func row(_ ref: String) -> some View {
        if let node = map.nodesByRef[ref] {
            KnowledgeMapLibraryRow(node: node, popoverRef: $popoverRef)
        }
    }

    /// A section's heading: its name and a chevron, one button that folds it,
    /// and, where the section can be set down whole, Place All.
    private func header(_ id: String, _ title: String, placeAll: [String]?) -> some View {
        let isFolded = folded.contains(id)
        return HStack(spacing: 4) {
            Button {
                if isFolded { folded.remove(id) } else { folded.insert(id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .zoomedSystemFont(size: 8, weight: .bold)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                        .frame(width: 10)
                    Text(title)
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.disabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.08))
            .accessibilityLabel(isFolded ? "Show \(title)" : "Fold \(title)")
            .accessibilityIdentifier("knowledgeMap.library.section.\(id)")
            if let refs = placeAll {
                Button("Place All") {
                    map.send(.dropAtCenter(refs: refs, regionName: nil))
                }
                .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3, opacity: 0.10))
                .zoomedSystemFont(size: 11)
                .help("Set these down beside the selection, or in the middle of the view")
                .accessibilityIdentifier("knowledgeMap.library.section.\(id).placeAll")
            }
        }
        .padding(.top, 6)
    }
}

// MARK: Rows

/// A card of the Library: drawn as what it is, dragged whole, a click shows it
/// in a popover beside it, a right-click offers its other ways.
struct KnowledgeMapLibraryRow: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let node: KnowledgeMapNode
    @Binding var popoverRef: String?

    private var ref: String { node.ref }

    var body: some View {
        let map = vm.knowledgeMap(in: windowState)
        KnowledgeMapCardRowLabel(node: node, map: map)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .hoverHighlight(cornerRadius: 8, inset: 0, opacity: 0.08)
            .textSelection(.disabled)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(node.title)
            .accessibilityIdentifier("knowledgeMap.library.row.\(ref)")
            .openHandCursor()
            .onTapGesture { popoverRef = ref }
            .onDrag { knowledgeMapCardDragProvider(ref: ref, vm: vm, map: map) }
            .popover(
                isPresented: Binding(
                    get: { popoverRef == ref },
                    set: { if !$0, popoverRef == ref { popoverRef = nil } }
                ),
                arrowEdge: .leading
            ) {
                KnowledgeMapPopupCard(ref: ref, drawsChrome: false, onClose: { popoverRef = nil })
                    .frame(width: KnowledgeMapPopupMetrics.width)
                    .environment(vm)
                    .environment(windowState)
            }
            .contextMenu {
                Button("Place on the Canvas") { map.send(.dropAtCenter(refs: [ref], regionName: nil)) }
                Button("Open Beside") { vm.task(in: windowState) { await vm.openKnowledgeMapItemBeside(ref, in: windowState) } }
                Button("Open") { vm.task(in: windowState) { await vm.openKnowledgeMapItem(ref, in: windowState) } }
            }
    }
}

/// A notebook of the Library: dragged as the notebook is, to be set down as its
/// frame; a click offers that, and opening the notebook, in a popover.
struct KnowledgeMapLibraryNotebookRow: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let notebook: KnowledgeMapNotebook
    @Binding var popoverRef: String?

    private var popoverKey: String { "notebook:" + notebook.id }

    var body: some View {
        KnowledgeMapNotebookRowLabel(notebook: notebook)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .hoverHighlight(cornerRadius: 8, inset: 0, opacity: 0.08)
            .textSelection(.disabled)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(notebook.title)
            .accessibilityIdentifier("knowledgeMap.library.row.\(popoverKey)")
            .openHandCursor()
            .onTapGesture { popoverRef = popoverKey }
            .onDrag {
                notebookDragProvider(for: StudioNotebookTransfer(notebookID: notebook.id), title: notebook.title)
            }
            .popover(
                isPresented: Binding(
                    get: { popoverRef == popoverKey },
                    set: { if !$0, popoverRef == popoverKey { popoverRef = nil } }
                ),
                arrowEdge: .leading
            ) {
                notebookCard
            }
            .contextMenu {
                Button("Place as a Frame") { vm.setDownKnowledgeMapNotebook(notebook.id, at: nil) }
                Button("Open Notebook") { vm.openNotebook(notebook.id, in: windowState) }
            }
    }

    private var notebookCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(notebook.title)
                .zoomedSystemFont(size: 14, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
            if !notebook.summary.isEmpty {
                Text(notebook.summary)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Button("Place as a Frame") {
                    vm.setDownKnowledgeMapNotebook(notebook.id, at: nil)
                    popoverRef = nil
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                .help("Set its cards down in a region of their own, beside the selection or in the middle of the view")
                .accessibilityIdentifier("knowledgeMap.library.notebook.place")
                Button("Open Notebook") {
                    popoverRef = nil
                    vm.openNotebook(notebook.id, in: windowState)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                .accessibilityIdentifier("knowledgeMap.library.notebook.open")
                Spacer(minLength: 0)
            }
            .zoomedSystemFont(size: 12)
        }
        .padding(14)
        .frame(width: KnowledgeMapPopupMetrics.width, alignment: .leading)
        .textSelection(.disabled)
    }
}

// MARK: What a row looks like

/// A card drawn as what it is (the Library's rows, and the add box's and the
/// find field's results): an Idea a small yellow note, a clip its picture, a
/// source its kind's glyph in its type's tint with its byline, any other card
/// its glyph and title.
struct KnowledgeMapCardRowLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    let node: KnowledgeMapNode
    let map: KnowledgeMapModel

    private static let stickyFill = (light: "#fff3b0", dark: "#5c4f1c")
    private static let stickyInk = (light: "#3d3200", dark: "#fff6d6")

    var body: some View {
        switch node.kind {
        case "idea": note
        case "clip": clip
        case "source": titled(subtitle: node.sub)
        default: titled(subtitle: nil)
        }
    }

    /// An Idea: its title and two lines of its note, on the plane's yellow.
    private var note: some View {
        let dark = colorScheme == .dark
        return VStack(alignment: .leading, spacing: 3) {
            Text(node.title)
                .zoomedSystemFont(size: 12, weight: .medium)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if node.sub != KnowledgeMapAddSearch.noteLessIdeaLine, !node.sub.isEmpty {
                Text(node.sub)
                    .zoomedSystemFont(size: 11)
                    .opacity(0.75)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Color(mapHex: dark ? Self.stickyInk.dark : Self.stickyInk.light))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(mapHex: dark ? Self.stickyFill.dark : Self.stickyFill.light),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    /// A clip: its picture 64 points tall (a passage its words), then its
    /// title and the paper it came from.
    private var clip: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let words = node.quote, !words.isEmpty {
                Text("“\(words)”")
                    .zoomedSystemFont(size: 11.5)
                    .italic()
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(KnowledgeMapCardGlyph.tint(for: node)).frame(width: 2)
                    }
            } else {
                KnowledgeMapClipPicture(node: node, map: map)
            }
            Text(node.title)
                .zoomedSystemFont(size: 12, weight: .medium)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !node.sub.isEmpty {
                Text(node.sub)
                    .zoomedSystemFont(size: 10.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A source, Page, site, chat, canvas or picture: its glyph in its tint.
    private func titled(subtitle: String?) -> some View {
        HStack(alignment: .center, spacing: 9) {
            KnowledgeMapGlyphTile(symbol: KnowledgeMapCardGlyph.symbol(for: node), tint: KnowledgeMapCardGlyph.tint(for: node))
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .zoomedSystemFont(size: 12)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .zoomedSystemFont(size: 10.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A notebook as a row: its book glyph, its name and how many cards it holds.
struct KnowledgeMapNotebookRowLabel: View {
    let notebook: KnowledgeMapNotebook

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            KnowledgeMapGlyphTile(symbol: "book.closed", tint: .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(notebook.title)
                    .zoomedSystemFont(size: 12)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(notebook.refs.count == 1 ? "1 card" : "\(notebook.refs.count) cards")
                    .zoomedSystemFont(size: 10.5)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A glyph on a soft square of its tint.
struct KnowledgeMapGlyphTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .zoomedSystemFont(size: 12, weight: .medium)
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// A figure clip's picture, 64 points tall, drawn from its page region by
/// `KnowledgeMapModel.clipPicture`; a photo glyph stands in until it comes.
private struct KnowledgeMapClipPicture: View {
    let node: KnowledgeMapNode
    let map: KnowledgeMapModel

    @State private var picture: NSImage?

    var body: some View {
        Group {
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            } else {
                Image(systemName: "photo")
                    .zoomedSystemFont(size: 16)
                    .foregroundStyle(.tertiary)
                    .frame(width: 100, height: 64)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: node.ref) {
            guard picture == nil, let clipID = KnowledgeMap.ItemRef(node.ref)?.id, let clip = map.clips[clipID],
                  let draw = map.clipPicture else { return }
            picture = await KnowledgeMapRowPictures.shared.picture(for: node.ref, clip: clip, draw: draw)
        }
    }
}

/// The clips' pictures the rows have drawn, kept by ref so a row that scrolls
/// back into view, or the same clip in the add box, does not draw it again.
@MainActor
final class KnowledgeMapRowPictures {
    static let shared = KnowledgeMapRowPictures()

    private var images: [String: NSImage] = [:]
    /// Rows are small, so a few dozen are enough; past this the cache starts over.
    private static let capacity = 120

    func picture(
        for ref: String,
        clip: SourceHighlight,
        draw: @MainActor (SourceHighlight) async -> String?
    ) async -> NSImage? {
        if let cached = images[ref] { return cached }
        guard let dataURL = await draw(clip) else { return nil }
        // The bytes are decoded to row size off the main actor.
        let thumbnail = await Task.detached(priority: .utility) { Self.thumbnail(fromDataURL: dataURL) }.value
        guard let thumbnail else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        if images.count >= Self.capacity { images.removeAll() }
        images[ref] = image
        return image
    }

    /// A data URL's picture, at most 256 pixels along its long side: twice a
    /// row's height, for a sharp picture on a Retina display.
    nonisolated private static func thumbnail(fromDataURL url: String) -> CGImage? {
        guard let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A card's glyph and tint: the type's own, as the renderer draws its dot
/// (`TYPE_TINTS`).
enum KnowledgeMapCardGlyph {
    static func symbol(for node: KnowledgeMapNode) -> String {
        switch node.kind {
        case "source":
            return StudioSourceType(rawValue: node.type)?.symbolName ?? "doc.richtext"
        case "doc":
            switch node.type {
            case "site": return "globe"
            case "animation": return ArtifactKind.animation.symbolName
            case "audio": return ArtifactKind.audioOverview.symbolName
            case "reading": return ArtifactKind.mnemonicReading.symbolName
            default: return "doc.text"
            }
        case "chat": return "bubble.left.and.bubble.right"
        case "canvas": return KnowledgeMap.symbolName
        case "picture", "clip": return "photo"
        case "page": return "doc.plaintext"
        default: return "doc"
        }
    }

    /// The renderer's tints by type; the kind's, then the neutral grey, when a
    /// type has none.
    private static let tints: [String: String] = [
        "paper": "#378ADD", "article": "#1D9E75", "podcast": "#7F77DD", "video": "#D85A30",
        "book": "#BA7517", "meeting": "#888780", "course": "#639922", "xPost": "#5F5E5A",
        "idea": "#EF9F27", "clip": "#D4537E", "page": "#5B6B7F",
        "doc": "#5F5E5A", "site": "#0F6E56", "animation": "#7F77DD", "audio": "#993556", "reading": "#BA7517",
        "picture": "#8E6BBF", "chat": "#5AC8FA", "canvas": "#7F77DD",
    ]
    private static let neutral = "#888780"

    static func tint(for node: KnowledgeMapNode) -> Color {
        Color(mapHex: tints[node.type] ?? tints[node.kind] ?? neutral)
    }
}

// MARK: Dragging a row

extension View {
    /// The open hand a row shows under the pointer: it can be picked up. Where
    /// the system has pointer styles (macOS 15) it owns the cursor's life, so
    /// a row that leaves while the pointer is over it (a card set down is no
    /// longer in the Library) never leaves a hand behind; before that, the
    /// app's own hover helper.
    @ViewBuilder
    func openHandCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.grabIdle)
        } else {
            cursor(.openHand)
        }
    }
}

/// What a Library or result row puts on the drag: the card itself
/// (`KnowledgeMapCardTransfer`, which the plane reads first and takes for all
/// the drag carries), and the kind's own drag besides, so an Idea, a chat or a
/// Page takes the card as it takes it from the Sources list or Pages: a
/// source's article, a Doc's artifact, a clip's clip.
@MainActor
func knowledgeMapCardDragProvider(ref: String, vm: StudioViewModel, map: KnowledgeMapModel) -> NSItemProvider {
    let provider: NSItemProvider
    switch KnowledgeMap.ItemRef(ref) {
    case .some(let item) where item.kind == .source:
        provider = vm.articles.first(where: { $0.id == item.id }).map { articleDragProvider(for: $0) } ?? NSItemProvider()
    case .some(let item) where item.kind == .doc:
        provider = vm.artifacts.first(where: { $0.id == item.id }).map { studioArtifactDragProvider(for: $0) } ?? NSItemProvider()
    case .some(let item) where item.kind == .clip:
        provider = knowledgeMapClipDragProvider(clipID: item.id, map: map) ?? NSItemProvider()
    default:
        provider = NSItemProvider()
    }
    provider.registerKnowledgeMapCards([ref])
    return provider
}

extension NSItemProvider {
    /// Puts cards on the drag by their refs (`KnowledgeMapCardTransfer`, own
    /// process only): the Canvas's plane sets down exactly these.
    func registerKnowledgeMapCards(_ refs: [String]) {
        guard let data = try? JSONEncoder().encode(KnowledgeMapCardTransfer(refs: refs)) else { return }
        registerDataRepresentation(forTypeIdentifier: UTType.knowledgeMapCard.identifier, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
    }
}

/// A saved clip or passage as the Reader's notes and the Canvas drag it.
@MainActor
private func knowledgeMapClipDragProvider(clipID: String, map: KnowledgeMapModel) -> NSItemProvider? {
    guard let clip = map.clips[clipID],
          let transfer = StudioClipTransfer(clip: clip) ?? StudioClipTransfer(passage: clip),
          let data = try? JSONEncoder().encode(transfer) else { return nil }
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.studioClip.identifier, visibility: .ownProcess) { done in
        done(data, nil)
        return nil
    }
    return provider
}
