import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct ArtifactSourceCitation: Codable, Equatable {
    let sourceID: String
    let title: String
    let bookID: String?

    init(sourceID: String, title: String, bookID: String? = nil) {
        self.sourceID = sourceID
        self.title = title
        self.bookID = bookID
    }
}

struct ArtifactSourceInsertion: Identifiable, Equatable {
    let id = UUID()
    let citations: [ArtifactSourceCitation]
    /// View-local coordinates for a drop on the page, whose passage is the one
    /// under the pointer. A drop that landed on the pane but not on the page —
    /// the title, or the source shelf — leaves this nil, and attaches to the
    /// highlighted passage instead.
    let editorLocation: CGPoint?

    init(citations: [ArtifactSourceCitation], editorLocation: CGPoint? = nil) {
        self.citations = citations
        self.editorLocation = editorLocation
    }
}

/// One doc or Notebook dragged onto the page, to be written into the prose as a
/// titled link.
struct ArtifactPageLinkTransfer: Equatable {
    let link: StudioEntityLink
    /// The title the drag carried, when it carried one — a Docs row does, a
    /// Notebook row does not. The host resolves the name either way.
    let title: String?
}

/// The two things the page takes from an in-app drag, which it treats
/// differently: a source attaches invisibly to the passage under the pointer,
/// a doc or Notebook is written where the pointer is.
enum ArtifactPageDragKind: Equatable {
    case sources
    case links
}

enum ArtifactPageDrop {
    case sources([StudioArticleTransfer])
    case links([ArtifactPageLinkTransfer])
}

/// What the editor does with a source, doc or Notebook dragged over the page.
///
/// The drag lands on the web view itself, never on a SwiftUI target above it
/// (see `ArtifactEditorWebView`), and the web view answers through these. The
/// pointer's position goes straight to the editor's coordinator: routing a
/// mouse move through SwiftUI state would rebuild the pane on every frame of
/// the drag. Every call is on the main thread, where AppKit delivers the drag.
struct ArtifactPageDragHandling {
    /// The drag entered or left the page.
    var targeted: (Bool) -> Void
    /// Where the pointer is over the page, in the web view's own top-left
    /// coordinate space — or nil once the drag has left it or landed.
    var moved: (ArtifactPageDragKind, CGPoint?) -> Void
    /// The drag ended on the page: what was dragged, and where it landed.
    var dropped: (ArtifactPageDrop, CGPoint) -> Void
}

/// A link the host has resolved to its title, on its way into the prose.
struct ArtifactPageLink: Equatable, Encodable {
    let title: String
    /// The stored `foreverlm://doc/…` or `foreverlm://notebook/…` address.
    let href: String

    init(title: String, link: StudioEntityLink) {
        self.title = title
        href = link.markdownDestination
    }
}

/// One thing a typed link can point at — a doc of the same library or a
/// Notebook — as the editor's `setLinkTargets` takes it: the editor lists these
/// under a `[[` in the prose and under the Link field, filtered by what the
/// writer types, and writes the chosen one as `[Title](foreverlm://doc/<id>)`.
/// `detail` is the quieter second column: where a doc is filed, or Draft.
struct ArtifactPageLinkTarget: Equatable, Encodable, Sendable {
    let kind: String
    let id: String
    let title: String
    let detail: String

    init(link: StudioEntityLink, title: String, detail: String = "") {
        kind = link.kind
        id = link.id
        self.title = title
        self.detail = detail
    }
}

struct ArtifactLinkInsertion: Identifiable, Equatable {
    let id = UUID()
    let links: [ArtifactPageLink]
    /// Where on the page the links are written, in the web view's top-left
    /// coordinates; nil writes them at the caret.
    let editorLocation: CGPoint?

    init(links: [ArtifactPageLink], editorLocation: CGPoint? = nil) {
        self.links = links
        self.editorLocation = editorLocation
    }
}

struct ArtifactAttachmentInsertion: Identifiable, Equatable {
    let id = UUID()
    let token: String
    let altText: String
    let dataURL: String
}

/// One formatting action of the page menu's Format items. The editor runs the
/// same Milkdown command its selection bar runs (the bar has carried
/// formatting since 2026-10-06, docs/ui-design.md "Quiet chrome"), so the
/// menu, the bar and the ⌘B / ⌘I / ⌥⌘X / ⌘E keymaps remain one behaviour.
enum ArtifactFormatCommand: String, Hashable, Identifiable, Sendable {
    case bold
    case italic
    case strikethrough
    case code
    case math
    case link

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .math: return "sum"
        case .link: return "link"
        }
    }

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .code: return "Inline code"
        case .math: return "Inline math"
        case .link: return "Link"
        }
    }

    /// Appended to the hover title. These are the keymaps Milkdown binds inside
    /// the editor; inline math and link have no bound shortcut to advertise.
    var shortcutHint: String? {
        switch self {
        case .bold: return "⌘B"
        case .italic: return "⌘I"
        case .strikethrough: return "⌥⌘X"
        case .code: return "⌘E"
        case .math, .link: return nil
        }
    }

    /// What the header menu's item says: the action, then the keystroke that
    /// does the same thing without leaving the page.
    var helpText: String {
        guard let shortcutHint else { return title }
        return "\(title) (\(shortcutHint))"
    }

    /// The two sections the header menu draws a separator between, keeping the
    /// grouping the editor's own toolbar used: marks that restyle the words
    /// under the caret, then actions that put something new in the document.
    static let markGroup: [ArtifactFormatCommand] = [.bold, .italic, .strikethrough]
    static let insertGroup: [ArtifactFormatCommand] = [.code, .math, .link]
}

/// What the page's top line pill asks the editor for besides Edit with AI
/// (docs/docs-design.md, "The page's top line"): each is a row of the editor's
/// `/` list, run at the caret by the editor itself, so a press does exactly
/// what the row does.
enum ArtifactEditorTool: String, Hashable, Sendable {
    /// The `/` list's Image row: the host's picture picker.
    case image
    /// The Visualize row: the Edit with AI panel in visualize mode.
    case visualize
    /// Insert +: the `/` list itself, opened at the caret.
    case insert
    /// Return in the title: the caret goes into the page.
    case focus

    /// The call into the editor (`runSlashRow`, `openInsertMenu`).
    var script: String {
        switch self {
        case .image: return "window.foreverLMArtifactEditor.runSlashRow(\"image\");"
        case .visualize: return "window.foreverLMArtifactEditor.runSlashRow(\"visualize\");"
        case .insert: return "window.foreverLMArtifactEditor.openInsertMenu();"
        case .focus: return "window.foreverLMArtifactEditor.focus();"
        }
    }
}

/// One header button press, matched to the press that raised it so tapping the
/// same button twice is delivered twice.
struct ArtifactFormatRequest: Identifiable, Equatable {
    enum Action: Equatable {
        case format(ArtifactFormatCommand)
        case tool(ArtifactEditorTool)
    }

    let id = UUID()
    let action: Action

    init(command: ArtifactFormatCommand) { action = .format(command) }
    init(tool: ArtifactEditorTool) { action = .tool(tool) }
}

struct ArtifactEditorSelection: Equatable {
    let text: String
    let from: Int
    let to: Int
    /// The heading the caret sits under, and that whole stretch of writing. Chat
    /// is handed this so a question arrives with the passage it is about.
    var sectionTitle: String = ""
    var sectionText: String = ""
    /// The sources cited inside the highlighted passage, in reading order —
    /// falling back to the surrounding section when the passage cites none.
    /// Empty means the passage stands on nothing of its own, and the note's own
    /// shelf is the grounding.
    var citedSourceIDs: [String] = []
    /// Only the sources attached to the passage — what the writer chose invisibly,
    /// without the ones its chips name. The attach control edits exactly this list.
    var groundedSourceIDs: [String] = []
    /// The formatting the caret or selection currently sits inside, so the pane
    /// header can light the matching buttons.
    var activeFormats: Set<ArtifactFormatCommand> = []

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The editor asking which sources a highlighted passage stands on. Carries what
/// is attached now, so the picker opens showing the current answer rather than an
/// empty list the writer has to rebuild.
struct ArtifactGroundingRequest: Identifiable, Equatable {
    let id = UUID()
    let selectedText: String
    let sourceIDs: [String]
}

/// The answer travelling back: the sources to attach to the selection the editor
/// still holds. An empty list detaches the passage.
struct ArtifactGroundingAttachment: Identifiable, Equatable {
    let id = UUID()
    let sourceIDs: [String]
}

/// The editor must take the width of its SwiftUI pane, including when Docs is
/// opened beside Chat or Reader. `WKWebView` otherwise contributes a large
/// AppKit fitting width to the representable; SwiftUI then centers that width
/// inside a narrower split and the page is clipped on both sides.
final class ArtifactEditorWebView: WKWebView {
    /// The doc's find bar. The app-wide key monitor normally claims Cmd+F
    /// before it reaches this view; this is the fallback for a press that
    /// arrives here anyway, so the shortcut never dies in the web process.
    weak var findState: ReaderFindState?

    /// No Apple Intelligence badge on a selection (`SharedWebKit.allowsWritingToolsAffordance(in:)`).
    @objc(allowsWritingToolsAffordance)
    var allowsWritingToolsAffordance: Bool { SharedWebKit.allowsWritingToolsAffordance(in: self) }

    /// The in-app drags — a source, a doc, a Notebook — which reach this view
    /// and nothing above it.
    ///
    /// WebKit registers the web view for file promises, PDF data, URLs and
    /// plain strings, and a source dragged from the sidebar advertises all of
    /// those so it can be dropped into a browser as a file. AppKit therefore
    /// chooses the web view as the drag's destination and never consults a
    /// SwiftUI drop target wrapped around it — which is why dropping a source
    /// on a doc did nothing in the Mac app until 2026-09-03 while working in
    /// the browser harness. In fact WebKit's drag hit test claims every drag
    /// over the view whatever it carries, so a doc or Notebook drag — which
    /// carries only its own type — meets the same fate. So the web view owns
    /// every in-app drag, registering for the doc and Notebook types itself,
    /// and hands every other drag to WebKit as before. Nil while no editor is
    /// attached, in which case an in-app drag is WebKit's too.
    var pageDrag: ArtifactPageDragHandling?
    /// Whether the drag session in progress is one this view claimed at
    /// `draggingEntered`, and what it carries. WebKit never saw that session
    /// begin, so it must not see it exit, end, or conclude either.
    private var currentDragKind: ArtifactPageDragKind?
    private var ownsCurrentDrag: Bool { currentDragKind != nil }

    static let sourceTransferType = NSPasteboard.PasteboardType(UTType.studioArticle.identifier)
    static let artifactTransferType = NSPasteboard.PasteboardType(UTType.studioArtifact.identifier)
    static let notebookTransferType = NSPasteboard.PasteboardType(UTType.studioNotebook.identifier)

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // WebKit's own registration covers the source drag's file and string
        // representations. A doc or Notebook drag advertises nothing but its
        // own type, and only a registered type makes this view a destination.
        registerForDraggedTypes(registeredDraggedTypes + [Self.artifactTransferType, Self.notebookTransferType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(registeredDraggedTypes + [Self.artifactTransferType, Self.notebookTransferType])
    }

    /// The sources a drag carries, one per pasteboard item. The sidebar puts
    /// a multi-selection in one item's `articleIds`, but nothing here relies on
    /// that.
    static func sourceTransfers(on pasteboard: NSPasteboard) -> [StudioArticleTransfer] {
        var payloads = (pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: sourceTransferType) }
        if payloads.isEmpty, let data = pasteboard.data(forType: sourceTransferType) {
            payloads = [data]
        }
        let decoder = JSONDecoder()
        return payloads.compactMap { try? decoder.decode(StudioArticleTransfer.self, from: $0) }
    }

    /// The docs and Notebooks a drag carries. A Docs row drags one doc with its
    /// title; a Notebook row drags one Notebook by id alone.
    static func linkTransfers(on pasteboard: NSPasteboard) -> [ArtifactPageLinkTransfer] {
        let decoder = JSONDecoder()
        var transfers: [ArtifactPageLinkTransfer] = []
        let items = pasteboard.pasteboardItems ?? []
        var artifactPayloads = items.compactMap { $0.data(forType: artifactTransferType) }
        if artifactPayloads.isEmpty, let data = pasteboard.data(forType: artifactTransferType) {
            artifactPayloads = [data]
        }
        for data in artifactPayloads {
            guard let transfer = try? decoder.decode(StudioArtifactTransfer.self, from: data) else { continue }
            transfers.append(ArtifactPageLinkTransfer(link: .doc(transfer.artifactID), title: transfer.title))
        }
        var notebookPayloads = items.compactMap { $0.data(forType: notebookTransferType) }
        if notebookPayloads.isEmpty, let data = pasteboard.data(forType: notebookTransferType) {
            notebookPayloads = [data]
        }
        for data in notebookPayloads {
            guard let transfer = try? decoder.decode(StudioNotebookTransfer.self, from: data) else { continue }
            transfers.append(ArtifactPageLinkTransfer(link: .notebook(transfer.notebookID), title: nil))
        }
        return transfers
    }

    /// What an in-app drag carries, or nil for a drag that is WebKit's.
    private func carriedKind(_ sender: NSDraggingInfo) -> ArtifactPageDragKind? {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.availableType(from: [Self.sourceTransferType]) != nil { return .sources }
        if pasteboard.availableType(from: [Self.artifactTransferType, Self.notebookTransferType]) != nil { return .links }
        return nil
    }

    /// The pointer in this view's coordinates. The view is flipped, so this is
    /// the top-left space ProseMirror's `posAtCoords` expects.
    private func pagePoint(_ sender: NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let pageDrag, let kind = carriedKind(sender) else {
            currentDragKind = nil
            return super.draggingEntered(sender)
        }
        currentDragKind = kind
        pageDrag.targeted(true)
        pageDrag.moved(kind, pagePoint(sender))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let currentDragKind, let pageDrag else { return super.draggingUpdated(sender) }
        pageDrag.moved(currentDragKind, pagePoint(sender))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let currentDragKind else { return super.draggingExited(sender) }
        pageDrag?.moved(currentDragKind, nil)
        pageDrag?.targeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard ownsCurrentDrag else { return super.prepareForDragOperation(sender) }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let currentDragKind else { return super.performDragOperation(sender) }
        let point = pagePoint(sender)
        pageDrag?.moved(currentDragKind, nil)
        pageDrag?.targeted(false)
        guard let pageDrag else { return false }
        switch currentDragKind {
        case .sources:
            let transfers = Self.sourceTransfers(on: sender.draggingPasteboard)
            guard !transfers.isEmpty else { return false }
            pageDrag.dropped(.sources(transfers), point)
        case .links:
            let transfers = Self.linkTransfers(on: sender.draggingPasteboard)
            guard !transfers.isEmpty else { return false }
            pageDrag.dropped(.links(transfers), point)
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        guard ownsCurrentDrag else { return super.concludeDragOperation(sender) }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard let kind = currentDragKind else { return super.draggingEnded(sender) }
        currentDragKind = nil
        pageDrag?.moved(kind, nil)
        pageDrag?.targeted(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.isCommandFindShortcut, let findState {
            findState.show()
            return
        }
        super.keyDown(with: event)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

/// What the reader folded in each doc — a section under an `## ` heading, a
/// bullet with bullets under it — kept on this Mac by the doc's id. The editor
/// hands it over as JSON it alone reads (`foldsChanged`) and gets it back when
/// the doc opens (`setMarkdown`'s second argument); the Markdown never carries
/// it. Device-local (`SyncedPreferenceKeys.excluded`): how one reader left a
/// doc on one screen, not a fact about the doc.
enum ArtifactOutlineFolds {
    static let key = "docs.outlineFolds"

    /// The doc's folds as the editor last reported them; empty when nothing in
    /// it is folded.
    static func folds(for docID: String, defaults: UserDefaults = .standard) -> String {
        (defaults.dictionary(forKey: key)?[docID] as? String) ?? ""
    }

    /// An empty value unfolds the doc and drops its entry.
    static func set(_ folds: String, for docID: String, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        if folds.isEmpty {
            guard all.removeValue(forKey: docID) != nil else { return }
        } else {
            guard all[docID] as? String != folds else { return }
            all[docID] = folds
        }
        if all.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(all, forKey: key)
        }
    }
}

/// One editable, rendered Markdown surface for Notebook artifacts. The editor is
/// bundled with the app and keeps Markdown — not HTML — as its value, so existing
/// revision-safe artifact persistence remains the source of truth.
/// How wide the page is drawn in the Docs pane. The prose column is capped at
/// a readable line by default and centred, which on a wide pane leaves most of
/// the width blank; a reader who wants the doc broader picks a wider cap, or
/// lets the page fill the pane. One setting for every doc — it is a fact about
/// the reader and the pane, not about a document — and it follows the account
/// like the other display preferences (`SyncedPreferenceKeys`).
enum ArtifactPageWidth: String, CaseIterable, Identifiable {
    case standard
    case wide
    case full

    static let key = "notepad.pageWidth"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .wide: "Wide"
        case .full: "Full Width"
        }
    }

    /// The prose column's cap in points, or `nil` when the page fills the pane.
    /// The editor's stylesheet defaults to the standard cap, and the host mirrors
    /// the same number when it lays the title on the page's left edge.
    var maxWidth: CGFloat? {
        switch self {
        case .standard: 760
        case .wide: 1040
        case .full: nil
        }
    }
}

/// Whether the Docs pane draws margin cards: the sources a paragraph cites in
/// its sentences, stacked beside it (or below it in a narrow pane). Off, the
/// page reads as prose alone and takes back the column; the links stay in the
/// prose, and a reference line keeps its card, since that line is the doc's
/// own paragraph. A reading preference like the page width, so one setting for
/// every doc that follows the account.
enum ArtifactMarginCards {
    static let key = "notepad.showsMarginCards"
}

/// The page's place in the pane, as `artifact-editor.css` and `artifact-editor.js`
/// lay it out, so the native title above the page can share the prose's left edge.
enum ArtifactPageGeometry {
    /// The margin column: 240pt of card and a 20pt gutter.
    static let marginColumnWidth: CGFloat = 260
    /// The pane width below which no margin column is drawn and the cards flow
    /// below their paragraphs instead.
    static let marginColumnBreakpoint: CGFloat = 790

    /// The left edge of the prose in a pane `paneWidth` wide, for a page capped
    /// at `pageMaxWidth` (`nil`: the page fills the pane): the centring margin
    /// plus the page's own side padding, which yields as the pane narrows. With
    /// a margin column the page keeps its full width beside the column only when
    /// the pane holds both — the same threshold `marginTier` uses in the editor —
    /// and otherwise sits at the left, yielding the column's width.
    static func inset(paneWidth: CGFloat, pageMaxWidth: CGFloat?, hasMarginColumn: Bool) -> CGFloat {
        guard paneWidth > 0 else { return 28 }
        let padding = min(48, max(20, paneWidth * 0.06))
        let cap = pageMaxWidth ?? .infinity
        if hasMarginColumn, paneWidth >= marginColumnBreakpoint {
            if paneWidth >= cap + marginColumnWidth {
                return (paneWidth - cap - marginColumnWidth) / 2 + padding
            }
            return padding
        }
        let column = min(paneWidth, cap)
        return (paneWidth - column) / 2 + padding
    }
}

/// A native row's side inset onto the prose's left edge
/// (`ArtifactPageGeometry.inset`), animating the pane's width rather than the
/// inset. While the pane's width animates — Sources sliding in beside the page —
/// SwiftUI draws the editor's web view at each frame's width and the prose
/// follows it there, so a padding worked out once from the width the animation
/// ends at put the title at the end of the move before the text had begun it
/// (product owner, 2026-10-10: "the title of the doc first shifts to the left, and
/// then the text"). Interpolating the width and placing the row from it on every
/// frame keeps the title on the prose's edge the whole way, the page geometry's
/// kinks included. The width has to reach this modifier in the same transaction
/// as the pane's resize — from a `GeometryReader`, not `onGeometryChange`, whose
/// update lands after the animation has been decided and so jumps.
struct ArtifactPageInset: ViewModifier, Animatable {
    var paneWidth: CGFloat
    var pageMaxWidth: CGFloat?
    var hasMarginColumn: Bool

    var animatableData: CGFloat {
        get { paneWidth }
        set { paneWidth = newValue }
    }

    func body(content: Content) -> some View {
        content.padding(
            .horizontal,
            ArtifactPageGeometry.inset(
                paneWidth: paneWidth,
                pageMaxWidth: pageMaxWidth,
                hasMarginColumn: hasMarginColumn
            )
        )
    }
}

/// The editor's **Edit with AI** panel asking for a revised passage. The editor
/// keeps the passage's place and shows the answer; the host only runs the model.
struct ArtifactAIEditRequest: Equatable, Sendable {
    let requestID: String
    let edit: DocPassageEditRequest

    /// The editor's `aiEditRequested` payload, or nil when it carries no
    /// request id or instruction — nothing could be answered to.
    static func parse(_ payload: [String: Any], docTitle: String) -> ArtifactAIEditRequest? {
        guard let requestID = payload["requestID"] as? String, !requestID.isEmpty,
              let instruction = payload["instruction"] as? String,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ArtifactAIEditRequest(
            requestID: requestID,
            edit: DocPassageEditRequest(
                instruction: instruction,
                passage: payload["passage"] as? String ?? "",
                before: payload["before"] as? String ?? "",
                after: payload["after"] as? String ?? "",
                inline: payload["inline"] as? Bool ?? false,
                sectionTitle: payload["sectionTitle"] as? String ?? "",
                docTitle: docTitle,
                // The editor sends at most this much; a payload that sends more
                // is not allowed to crowd the passage out of the turn.
                instructions: String((payload["instructions"] as? String ?? "").prefix(instructionsLimit)),
                writesVisualization: payload["scope"] as? String == "visualize"
            )
        )
    }

    /// The most characters of a page's Assistant instructions a request carries.
    static let instructionsLimit = 2_000
}

/// Pictures pasted or dropped onto a page (`imagesPasted`): each one's data
/// URL, written to a file in a folder of its own under `directory` for the
/// host to keep in the page's attachments the way it keeps a file picked for
/// the Image row. The file is named for the picture, because that name is
/// the picture's alt text; WebKit names every pasted picture "image", which
/// says nothing, so it reads "Pasted image". A data URL that is not a base64
/// picture of a type the system knows is skipped; so is anything past the
/// first `limit`.
enum ArtifactPastedImages {
    static let limit = 20

    static func files(from payload: [String: Any], in directory: URL = FileManager.default.temporaryDirectory) -> [URL] {
        guard let images = payload["images"] as? [[String: Any]] else { return [] }
        var files: [URL] = []
        for image in images.prefix(limit) {
            guard let dataURL = image["dataURL"] as? String, let picture = decode(dataURL) else { continue }
            let named = ((image["name"] as? String) ?? "") as NSString
            let stem = String(named.deletingPathExtension.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == " "
            }).trimmingCharacters(in: .whitespaces)
            let name = stem.isEmpty || stem.lowercased() == "image" ? "Pasted image" : String(stem.prefix(60))
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let url = folder.appendingPathComponent("\(name).\(picture.fileExtension)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try picture.data.write(to: url, options: .atomic)
                files.append(url)
            } catch {
                continue
            }
        }
        return files
    }

    /// `data:image/<type>;base64,<data>`, read as the bytes and the file
    /// ending of that type; nil for anything else.
    static func decode(_ dataURL: String) -> (data: Data, fileExtension: String)? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mimeType = String(header.dropLast(";base64".count))
        guard let type = UTType(mimeType: mimeType), type.conforms(to: .image),
              let fileExtension = type.preferredFilenameExtension,
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              !data.isEmpty else { return nil }
        return (data, fileExtension)
    }
}

/// The editor's `openAttachmentRequested` payload: the writer chose Save file…
/// on a link to a file attached to the page. The token is the link's own and is
/// checked by whoever resolves it (`ArtifactFileAttachment.isStoredToken`); the
/// name is the text of the link, which is what the save panel offers.
struct ArtifactAttachmentOpenRequest: Equatable, Sendable {
    let token: String
    let name: String

    /// Nil when the payload names no token: there is no file to save.
    static func parse(_ payload: [String: Any]) -> ArtifactAttachmentOpenRequest? {
        guard let token = (payload["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return ArtifactAttachmentOpenRequest(token: token, name: payload["name"] as? String ?? "")
    }
}

/// The editor's `imageGenerationRequested` payload: the writer chose Generate
/// image and described the picture. The host draws it and answers with
/// `completeImageGeneration`, or with `failAIEdit` when it cannot.
struct ArtifactImageGenerationRequest: Equatable, Sendable {
    let requestID: String
    let prompt: String

    /// Nil when the payload carries no request id or no description: nothing
    /// could be drawn, or answered to.
    static func parse(_ payload: [String: Any]) -> ArtifactImageGenerationRequest? {
        guard let requestID = payload["requestID"] as? String, !requestID.isEmpty,
              let prompt = (payload["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return nil }
        return ArtifactImageGenerationRequest(requestID: requestID, prompt: prompt)
    }
}

/// A picture the model drew for a doc, already kept in the doc's Attachments:
/// what `insertAttachment` and `completeImageGeneration` take.
struct ArtifactGeneratedImage: Equatable, Sendable {
    let token: String
    let dataURL: String
    let altText: String

    /// The picture's alt text is the opening of the description it was drawn
    /// from, on one line, at most this many characters.
    static let altTextLimit = 120

    static func altText(forPrompt prompt: String) -> String {
        let flattened = prompt
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > altTextLimit else { return flattened }
        let head = String(flattened.prefix(altTextLimit))
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head[...]
        return String(cut).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

struct ArtifactMarkdownEditorView: NSViewRepresentable {
    @Binding var markdown: String
    let saveRequestID: Int
    let publicationRequestID: Int
    /// The page menu's **Edit with AI**: each bump opens the editor's Edit
    /// with AI panel on the selection, or on the section at the caret.
    let aiEditOpenRequestID: Int
    /// The doc's title, for the model's framing of a passage edit.
    let docTitle: String
    @Binding var sourceInsertion: ArtifactSourceInsertion?
    /// A source drag from the sidebar entered or left the page.
    let onSourceDragTargeted: (Bool) -> Void
    /// A source landed on the page, at a point in the page's own coordinates.
    /// The host turns it into an `ArtifactSourceInsertion`, so the drop then
    /// reaches the editor the way every other insertion does.
    let onSourceDrop: ([StudioArticleTransfer], CGPoint) -> Void
    /// A doc or Notebook landed on the page. The host names it and answers with
    /// an `ArtifactLinkInsertion`, which writes the link where it landed.
    let onLinkDrop: ([ArtifactPageLinkTransfer], CGPoint) -> Void
    @Binding var linkInsertion: ArtifactLinkInsertion?
    /// A link to another doc or a Notebook was followed — from its hover
    /// tooltip, or a shift-click on the link itself.
    let onOpenLink: (StudioEntityLink) -> Void
    /// What a typed link can point at: the library's other docs and the
    /// Notebooks, offered under `[[` and in the Link field. The whole list goes
    /// to the editor whenever it changes; the editor filters as the writer types.
    var linkTargets: [ArtifactPageLinkTarget] = []
    /// What the library says about each web reference the doc holds, keyed by
    /// the address exactly as the editor reported it in `onReferencesChange`.
    let referenceStatuses: [String: ArtifactReferenceStatus]
    /// The doc's set of web references changed — a reference line appeared, or
    /// its address was edited. The host answers through `referenceStatuses`.
    let onReferencesChange: ([String]) -> Void
    /// Whether the doc has a margin column — a paragraph citing the web in its
    /// sentences carries its cards beside it, and the page moves over to make
    /// room. The host lays the title on the same column as the prose.
    let onMarginColumnChange: (Bool) -> Void
    /// Add to Sources was pressed on a reference card.
    let onAddReference: (String) -> Void
    /// Request from team was pressed on a team Doc's card: ask the team for
    /// the source the import could not add.
    var onRequestReference: (String) -> Void = { _ in }
    /// Share was pressed on a card whose request this Mac can answer; the
    /// second argument is the request id.
    var onFulfilReference: (String, String) -> Void = { _, _ in }
    /// The check on a reference card was pressed: open that source.
    let onOpenSource: (String) -> Void
    let attachmentDataURLs: [String: String]
    @Binding var attachmentInsertion: ArtifactAttachmentInsertion?
    @Binding var groundingAttachment: ArtifactGroundingAttachment?
    @Binding var formatRequest: ArtifactFormatRequest?
    /// The prose column's cap in points; `nil` lets the page fill the pane.
    let pageMaxWidth: CGFloat?
    /// Off, no margin cards are drawn and the page takes back their column
    /// (`ArtifactMarginCards`).
    var showsMarginCards = true
    /// Off, the page reads without a caret: a team Doc, whose changes go
    /// through a member's private draft rather than the shared copy.
    var isEditable = true
    /// The doc's id, under which its folds are kept (`ArtifactOutlineFolds`);
    /// `nil` keeps none, and every doc opens unfolded.
    var foldDocumentID: String? = nil
    /// The notes graph's way between the pane and the editor: what the pane
    /// knows of the doc's graph goes in through it, and the editor's requests
    /// — block search, a block given an id, a page made, a reference followed
    /// — come out (docs/notes-graph-design.md, "Editor and host"). Nil: the
    /// editor hears nothing of the graph, as from a host that knows none.
    var notesGraph: ArtifactNotesGraphBridge? = nil
    /// Find-in-doc, driven the way every reader drives it: the bar bumps
    /// `searchRevision`, and the next update pass runs one search.
    let findState: ReaderFindState
    let findRevision: Int
    let onSave: (String) -> Void
    let onPublication: (String) -> Void
    let onRequestChat: (ArtifactEditorSelection) -> Void
    let onRequestComment: (ArtifactEditorSelection) -> Void
    let onRequestGrounding: (ArtifactGroundingRequest) -> Void
    /// The editor asked the AI for a revised passage; the answer is the
    /// replacement Markdown, and a thrown error is shown in the panel.
    let onRequestAIEdit: (ArtifactAIEditRequest) async throws -> String
    /// Image was chosen in the slash menu: the host asks the writer for a
    /// picture file, and the pick comes back as an `attachmentInsertion`.
    let onRequestImage: () -> Void
    /// Pictures were pasted or dropped onto the page, written to temporary
    /// files, each in a folder of its own (`ArtifactPastedImages`): the host
    /// keeps them in the doc's Attachments and writes each where the caret
    /// is, as for the Image row, then removes the folders.
    var onImageFiles: ([URL]) -> Void = { _ in }
    /// The page's comment threads, each marked on its passage
    /// (`setCommentAnchors`); the editor finds the words again and keeps the
    /// mark on them as the page changes.
    var commentAnchors: [ArtifactCommentAnchor] = []
    /// The thread open in the Comments panel: its passage is marked more
    /// strongly, and shown when the choice was made in the panel.
    var activeCommentID: String? = nil
    /// Marked words were clicked: the host opens that thread.
    var onCommentAnchorClicked: (String) -> Void = { _ in }
    /// The threads whose words are no longer in the page.
    var onCommentAnchorsDetached: (Set<String>) -> Void = { _ in }
    /// Generate image was chosen and described: the answer is the picture,
    /// kept in the doc's Attachments, for the editor to write where the caret
    /// was. A thrown error is shown in the panel.
    let onRequestImageGeneration: (ArtifactImageGenerationRequest) async throws -> ArtifactGeneratedImage
    /// The editor wrote a drawn picture into the page; the host keeps its data
    /// URL with the doc's other attachments.
    let onGeneratedImageInserted: (ArtifactGeneratedImage) -> Void
    /// A Prompt block's **Chat about this** was pressed; the argument is the
    /// prompt's words. The host opens Chat with them waiting under the composer.
    let onRequestPrompt: (String) -> Void
    /// File was chosen in the slash menu: the host asks the writer for a file,
    /// keeps it in the page's Attachments and answers with it — nil when the
    /// writer cancelled or the file could not be kept (the host says why).
    let onRequestFile: () async -> ArtifactFileAttachment?
    /// Save file… was chosen on a link to an attached file: the host asks where
    /// to put a copy.
    let onOpenAttachment: (ArtifactAttachmentOpenRequest) -> Void
    let onSelectionChange: (ArtifactEditorSelection) -> Void
    let onError: (String) -> Void
    @Environment(\.uiZoomScale) private var uiZoomScale

    private static let messageHandlerName = "artifactEditor"
    @MainActor private static var reusableWebViews: [ArtifactEditorWebView] = []
    private static let reusePoolCapacity = 1

    private var fontSize: CGFloat { (15 * uiZoomScale).rounded() }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            markdown: $markdown,
            saveRequestID: saveRequestID,
            publicationRequestID: publicationRequestID,
            sourceInsertion: $sourceInsertion,
            onSourceDragTargeted: onSourceDragTargeted,
            onSourceDrop: onSourceDrop,
            onLinkDrop: onLinkDrop,
            linkInsertion: $linkInsertion,
            onOpenLink: onOpenLink,
            linkTargets: linkTargets,
            referenceStatuses: referenceStatuses,
            onReferencesChange: onReferencesChange,
            onMarginColumnChange: onMarginColumnChange,
            onAddReference: onAddReference,
            onRequestReference: onRequestReference,
            onFulfilReference: onFulfilReference,
            onOpenSource: onOpenSource,
            attachmentDataURLs: attachmentDataURLs,
            attachmentInsertion: $attachmentInsertion,
            groundingAttachment: $groundingAttachment,
            formatRequest: $formatRequest,
            fontSize: fontSize,
            pageMaxWidth: pageMaxWidth,
            showsMarginCards: showsMarginCards,
            isEditable: isEditable,
            onSave: onSave,
            onPublication: onPublication,
            onRequestChat: onRequestChat,
            onRequestComment: onRequestComment,
            onRequestGrounding: onRequestGrounding,
            onRequestAIEdit: onRequestAIEdit,
            onRequestImage: onRequestImage,
            onRequestImageGeneration: onRequestImageGeneration,
            onGeneratedImageInserted: onGeneratedImageInserted,
            onRequestPrompt: onRequestPrompt,
            onRequestFile: onRequestFile,
            onOpenAttachment: onOpenAttachment,
            aiEditOpenRequestID: aiEditOpenRequestID,
            docTitle: docTitle,
            onSelectionChange: onSelectionChange,
            onError: onError
        )
        coordinator.foldDocumentID = foldDocumentID
        coordinator.notesGraph = notesGraph
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView: ArtifactEditorWebView
        if let reused = Self.reusableWebViews.popLast() {
            webView = reused
        } else {
            let contentController = WKUserContentController()
            let configuration = WKWebViewConfiguration()
            configuration.userContentController = contentController
            configuration.websiteDataStore = .nonPersistent()
            SharedWebKit.applySharedProcessPool(to: configuration)
            SharedWebKit.disableSystemWritingTools(on: configuration)
            if configuration.preferences.responds(to: Selector(("_setShouldAllowUserInstalledFonts:"))) {
                configuration.preferences.setValue(false, forKey: "shouldAllowUserInstalledFonts")
            }
            webView = ArtifactEditorWebView(frame: .zero, configuration: configuration)
            webView.setValue(false, forKey: "drawsBackground")
            webView.allowsMagnification = false
        }

        // The document page is intentionally responsive. Do not let AppKit's
        // fitting priorities turn the web view's previous/wide size into a
        // minimum when this instance is reused in a split pane.
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        webView.configuration.userContentController.add(
            context.coordinator,
            name: Self.messageHandlerName
        )
        webView.navigationDelegate = context.coordinator
        webView.findState = findState
        context.coordinator.attach(to: webView)

        if webView.url == nil {
            loadEditor(into: webView, coordinator: context.coordinator)
        } else {
            context.coordinator.probeReadiness(in: webView)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onImageFiles = onImageFiles
        context.coordinator.onCommentAnchorClicked = onCommentAnchorClicked
        context.coordinator.onCommentAnchorsDetached = onCommentAnchorsDetached
        context.coordinator.openFoldDocument(foldDocumentID)
        context.coordinator.useNotesGraph(notesGraph)
        context.coordinator.update(
            markdown: $markdown,
            saveRequestID: saveRequestID,
            publicationRequestID: publicationRequestID,
            sourceInsertion: $sourceInsertion,
            onSourceDragTargeted: onSourceDragTargeted,
            onSourceDrop: onSourceDrop,
            onLinkDrop: onLinkDrop,
            linkInsertion: $linkInsertion,
            onOpenLink: onOpenLink,
            linkTargets: linkTargets,
            referenceStatuses: referenceStatuses,
            onReferencesChange: onReferencesChange,
            onMarginColumnChange: onMarginColumnChange,
            onAddReference: onAddReference,
            onRequestReference: onRequestReference,
            onFulfilReference: onFulfilReference,
            onOpenSource: onOpenSource,
            attachmentDataURLs: attachmentDataURLs,
            attachmentInsertion: $attachmentInsertion,
            groundingAttachment: $groundingAttachment,
            formatRequest: $formatRequest,
            fontSize: fontSize,
            pageMaxWidth: pageMaxWidth,
            showsMarginCards: showsMarginCards,
            isEditable: isEditable,
            onSave: onSave,
            onPublication: onPublication,
            onRequestChat: onRequestChat,
            onRequestComment: onRequestComment,
            onRequestGrounding: onRequestGrounding,
            onRequestAIEdit: onRequestAIEdit,
            onRequestImage: onRequestImage,
            onRequestImageGeneration: onRequestImageGeneration,
            onGeneratedImageInserted: onGeneratedImageInserted,
            onRequestPrompt: onRequestPrompt,
            onRequestFile: onRequestFile,
            onOpenAttachment: onOpenAttachment,
            aiEditOpenRequestID: aiEditOpenRequestID,
            docTitle: docTitle,
            onSelectionChange: onSelectionChange,
            onError: onError,
            in: webView
        )
        context.coordinator.useComments(commentAnchors, activeID: activeCommentID, in: webView)
        context.coordinator.performFindIfNeeded(in: webView, revision: findRevision, state: findState)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let canReuse = coordinator.canReuse
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: messageHandlerName
        )
        webView.navigationDelegate = nil
        (webView as? ArtifactEditorWebView)?.findState = nil
        coordinator.detach()

        if canReuse,
           let reusable = webView as? ArtifactEditorWebView,
           reusableWebViews.count < reusePoolCapacity {
            reusable.removeFromSuperview()
            reusableWebViews.append(reusable)
        } else {
            webView.loadHTMLString("", baseURL: nil)
        }
    }

    private func loadEditor(into webView: WKWebView, coordinator: Coordinator) {
        let bundledURL = Bundle.main.url(
            forResource: "artifact-editor",
            withExtension: "html",
            subdirectory: "ArtifactEditorResources"
        ) ?? Bundle.main.url(forResource: "artifact-editor", withExtension: "html")

        guard let bundledURL else {
            coordinator.reportError("The artifact editor resources are missing from this build.")
            return
        }
        webView.loadFileURL(
            bundledURL,
            allowingReadAccessTo: bundledURL.deletingLastPathComponent()
        )
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, ArtifactNotesGraphPage {
        /// The notes graph's bridge to the pane; see `notesGraph` on the view.
        fileprivate(set) var notesGraph: ArtifactNotesGraphBridge?
        private var markdown: Binding<String>
        private var latestSwiftMarkdown: String
        private var lastEditorMarkdown: String
        private var saveRequestID: Int
        private var publicationRequestID: Int
        private var pendingSaveRequest = false
        private var pendingPublicationRequest = false
        private var sourceInsertion: Binding<ArtifactSourceInsertion?>
        private var onSourceDragTargeted: (Bool) -> Void
        private var onSourceDrop: ([StudioArticleTransfer], CGPoint) -> Void
        private var sourceInsertionID: UUID?
        private var pendingSourceInsertion: ArtifactSourceInsertion?
        private var onLinkDrop: ([ArtifactPageLinkTransfer], CGPoint) -> Void
        private var linkInsertion: Binding<ArtifactLinkInsertion?>
        private var linkInsertionID: UUID?
        private var pendingLinkInsertion: ArtifactLinkInsertion?
        private var onOpenLink: (StudioEntityLink) -> Void
        private var linkTargets: [ArtifactPageLinkTarget]
        private var referenceStatuses: [String: ArtifactReferenceStatus]
        private var onReferencesChange: ([String]) -> Void
        private var onMarginColumnChange: (Bool) -> Void
        private var onAddReference: (String) -> Void
        private var onRequestReference: (String) -> Void
        private var onFulfilReference: (String, String) -> Void
        private var onOpenSource: (String) -> Void
        private var attachmentDataURLs: [String: String]
        /// The attachments the page can already draw: the tokens last sent
        /// with `setAttachmentURLs`, and those it registered itself when a
        /// picture was inserted into it.
        private var pageAttachmentTokens: Set<String> = []
        private var attachmentInsertion: Binding<ArtifactAttachmentInsertion?>
        private var attachmentInsertionID: UUID?
        private var groundingAttachment: Binding<ArtifactGroundingAttachment?>
        private var groundingAttachmentID: UUID?
        private var pendingGroundingAttachment: ArtifactGroundingAttachment?
        private var pendingAttachmentInsertion: ArtifactAttachmentInsertion?
        private var formatRequest: Binding<ArtifactFormatRequest?>
        private var formatRequestID: UUID?
        private var pendingFormatRequest: ArtifactFormatRequest?
        private var fontSize: CGFloat
        private var pageMaxWidth: CGFloat?
        private var showsMarginCards: Bool
        private var lastFindRevision = 0
        private var isReady = false
        private var initializationStarted = false
        private var didFail = false
        private weak var webView: WKWebView?
        private var onSave: (String) -> Void
        private var onPublication: (String) -> Void
        private var onRequestChat: (ArtifactEditorSelection) -> Void
        private var onRequestComment: (ArtifactEditorSelection) -> Void
        private var onRequestGrounding: (ArtifactGroundingRequest) -> Void
        private var onRequestAIEdit: (ArtifactAIEditRequest) async throws -> String
        private var onRequestImage: () -> Void
        var onImageFiles: ([URL]) -> Void = { _ in }
        var onCommentAnchorClicked: (String) -> Void = { _ in }
        var onCommentAnchorsDetached: (Set<String>) -> Void = { _ in }
        private var commentAnchors: [ArtifactCommentAnchor] = []
        private var activeCommentID: String?
        private var onRequestImageGeneration: (ArtifactImageGenerationRequest) async throws -> ArtifactGeneratedImage
        private var onGeneratedImageInserted: (ArtifactGeneratedImage) -> Void
        private var onRequestPrompt: (String) -> Void
        private var onRequestFile: () async -> ArtifactFileAttachment?
        private var onOpenAttachment: (ArtifactAttachmentOpenRequest) -> Void
        private var aiEditOpenRequestID: Int
        private var docTitle: String
        /// Whose folds the editor holds; see `foldDocumentID` on the view.
        fileprivate(set) var foldDocumentID: String?
        /// Another doc came into this editor since the body was last sent.
        private var foldDocumentChanged = false
        private var onSelectionChange: (ArtifactEditorSelection) -> Void
        private var onError: (String) -> Void
        private var isEditable: Bool
        /// Hears a model change anywhere — the mark's own menu, Settings, a
        /// synced pick, an assistant over MCP — so the mark names the model
        /// the next edit runs on.
        private var modelChangeObserver: NSObjectProtocol?

        var canReuse: Bool { isReady && !didFail }

        init(
            markdown: Binding<String>,
            saveRequestID: Int,
            publicationRequestID: Int,
            sourceInsertion: Binding<ArtifactSourceInsertion?>,
            onSourceDragTargeted: @escaping (Bool) -> Void,
            onSourceDrop: @escaping ([StudioArticleTransfer], CGPoint) -> Void,
            onLinkDrop: @escaping ([ArtifactPageLinkTransfer], CGPoint) -> Void,
            linkInsertion: Binding<ArtifactLinkInsertion?>,
            onOpenLink: @escaping (StudioEntityLink) -> Void,
            linkTargets: [ArtifactPageLinkTarget] = [],
            referenceStatuses: [String: ArtifactReferenceStatus],
            onReferencesChange: @escaping ([String]) -> Void,
            onMarginColumnChange: @escaping (Bool) -> Void,
            onAddReference: @escaping (String) -> Void,
            onRequestReference: @escaping (String) -> Void,
            onFulfilReference: @escaping (String, String) -> Void,
            onOpenSource: @escaping (String) -> Void,
            attachmentDataURLs: [String: String],
            attachmentInsertion: Binding<ArtifactAttachmentInsertion?>,
            groundingAttachment: Binding<ArtifactGroundingAttachment?>,
            formatRequest: Binding<ArtifactFormatRequest?>,
            fontSize: CGFloat,
            pageMaxWidth: CGFloat?,
            showsMarginCards: Bool,
            isEditable: Bool,
            onSave: @escaping (String) -> Void,
            onPublication: @escaping (String) -> Void,
            onRequestChat: @escaping (ArtifactEditorSelection) -> Void,
            onRequestComment: @escaping (ArtifactEditorSelection) -> Void,
            onRequestGrounding: @escaping (ArtifactGroundingRequest) -> Void,
            onRequestAIEdit: @escaping (ArtifactAIEditRequest) async throws -> String,
            onRequestImage: @escaping () -> Void,
            onRequestImageGeneration: @escaping (ArtifactImageGenerationRequest) async throws -> ArtifactGeneratedImage,
            onGeneratedImageInserted: @escaping (ArtifactGeneratedImage) -> Void,
            onRequestPrompt: @escaping (String) -> Void,
            onRequestFile: @escaping () async -> ArtifactFileAttachment?,
            onOpenAttachment: @escaping (ArtifactAttachmentOpenRequest) -> Void,
            aiEditOpenRequestID: Int,
            docTitle: String,
            onSelectionChange: @escaping (ArtifactEditorSelection) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.markdown = markdown
            latestSwiftMarkdown = markdown.wrappedValue
            lastEditorMarkdown = markdown.wrappedValue
            self.saveRequestID = saveRequestID
            self.publicationRequestID = publicationRequestID
            self.sourceInsertion = sourceInsertion
            self.onSourceDragTargeted = onSourceDragTargeted
            self.onSourceDrop = onSourceDrop
            sourceInsertionID = sourceInsertion.wrappedValue?.id
            pendingSourceInsertion = sourceInsertion.wrappedValue
            self.onLinkDrop = onLinkDrop
            self.linkInsertion = linkInsertion
            linkInsertionID = linkInsertion.wrappedValue?.id
            pendingLinkInsertion = linkInsertion.wrappedValue
            self.onOpenLink = onOpenLink
            self.linkTargets = linkTargets
            self.referenceStatuses = referenceStatuses
            self.onReferencesChange = onReferencesChange
            self.onMarginColumnChange = onMarginColumnChange
            self.onAddReference = onAddReference
            self.onRequestReference = onRequestReference
            self.onFulfilReference = onFulfilReference
            self.onOpenSource = onOpenSource
            self.attachmentDataURLs = attachmentDataURLs
            self.attachmentInsertion = attachmentInsertion
            attachmentInsertionID = attachmentInsertion.wrappedValue?.id
            pendingAttachmentInsertion = attachmentInsertion.wrappedValue
            self.groundingAttachment = groundingAttachment
            groundingAttachmentID = groundingAttachment.wrappedValue?.id
            pendingGroundingAttachment = groundingAttachment.wrappedValue
            self.formatRequest = formatRequest
            formatRequestID = formatRequest.wrappedValue?.id
            pendingFormatRequest = formatRequest.wrappedValue
            self.fontSize = fontSize
            self.pageMaxWidth = pageMaxWidth
            self.showsMarginCards = showsMarginCards
            self.onSave = onSave
            self.onPublication = onPublication
            self.onRequestChat = onRequestChat
            self.onRequestComment = onRequestComment
            self.onRequestGrounding = onRequestGrounding
            self.onRequestAIEdit = onRequestAIEdit
            self.onRequestImage = onRequestImage
            self.onRequestImageGeneration = onRequestImageGeneration
            self.onGeneratedImageInserted = onGeneratedImageInserted
            self.onRequestPrompt = onRequestPrompt
            self.onRequestFile = onRequestFile
            self.onOpenAttachment = onOpenAttachment
            self.docTitle = docTitle
            self.onSelectionChange = onSelectionChange
            self.onError = onError
            self.isEditable = isEditable
            self.aiEditOpenRequestID = aiEditOpenRequestID
            super.init()
            modelChangeObserver = NotificationCenter.default.addObserver(
                forName: .aiProviderDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isReady, let webView = self.webView else { return }
                self.deliverAIEditModel(in: webView)
            }
        }

        deinit {
            if let modelChangeObserver {
                NotificationCenter.default.removeObserver(modelChangeObserver)
            }
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            notesGraph?.attach(self)
            (webView as? ArtifactEditorWebView)?.pageDrag = ArtifactPageDragHandling(
                targeted: { [weak self] targeted in self?.onSourceDragTargeted(targeted) },
                moved: { [weak self] kind, point in self?.previewDrop(kind, at: point) },
                dropped: { [weak self] drop, point in
                    switch drop {
                    case .sources(let transfers): self?.onSourceDrop(transfers, point)
                    case .links(let transfers): self?.onLinkDrop(transfers, point)
                    }
                }
            )
        }

        func detach() {
            (webView as? ArtifactEditorWebView)?.pageDrag = nil
            notesGraph?.detach(self)
            webView = nil
            isReady = false
            initializationStarted = false
        }

        /// The pane handed over another bridge — it never does for one doc,
        /// but a stale one must not keep hearing this page.
        func useNotesGraph(_ bridge: ArtifactNotesGraphBridge?) {
            guard notesGraph !== bridge else { return }
            notesGraph?.detach(self)
            notesGraph = bridge
            guard let bridge, webView != nil else { return }
            bridge.attach(self)
            if isReady { bridge.pageBecameReady(self) }
        }

        /// One notes-graph call into the page, made only while the page is
        /// ready and holds the doc the call is about.
        @discardableResult
        func runNotesGraphScript(_ script: String, forDoc docID: String) -> Bool {
            guard isReady, let webView else { return false }
            if let foldDocumentID, foldDocumentID != docID { return false }
            webView.evaluateJavaScript(script) { _, _ in }
            return true
        }

        /// A report the editor names another doc in was sent from the doc
        /// before this one: a report sent on leaving can arrive after the next
        /// doc is up. A report naming no doc is this one's.
        private func isAboutOpenDoc(_ payload: [String: Any]) -> Bool {
            guard let key = payload["key"] as? String, let foldDocumentID else { return true }
            return key == foldDocumentID
        }

        /// What the writer typed that the pane has not heard yet, taken as the
        /// draft the pane saves. `markdownChanged` trails an edit by the
        /// editor's debounce, so a pane about to save right after the writer
        /// did something — a page made and linked, then opened — asks for it.
        /// A page the writer has not changed answers nothing: Milkdown's own
        /// spelling of an untouched page is not an edit to save.
        func syncMarkdown(forDoc docID: String) async throws {
            guard isReady, let webView else { return }
            if let foldDocumentID, foldDocumentID != docID { return }
            let held: String? = try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript("window.foreverLMArtifactEditor.unsentMarkdown();") { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result as? String)
                    }
                }
            }
            guard let value = held else { return }
            lastEditorMarkdown = value
            latestSwiftMarkdown = value
            if markdown.wrappedValue != value {
                markdown.wrappedValue = value
            }
        }

        /// Show or clear the hint of what a drag will do where the pointer is:
        /// the passage a source will attach to, or the caret a doc or Notebook
        /// link will be written at. Only the editor knows where its passages
        /// are on screen, so the point travels to it and the answer is drawn there.
        private func previewDrop(_ kind: ArtifactPageDragKind, at point: CGPoint?) {
            guard isReady, let webView else { return }
            guard let point else {
                webView.evaluateJavaScript("window.foreverLMArtifactEditor.endDropPreview();")
                return
            }
            let function = kind == .sources ? "previewSourceDrop" : "previewLinkDrop"
            webView.evaluateJavaScript(
                "window.foreverLMArtifactEditor.\(function)(\(Double(point.x)), \(Double(point.y)));"
            )
        }

        func update(
            markdown: Binding<String>,
            saveRequestID: Int,
            publicationRequestID: Int,
            sourceInsertion: Binding<ArtifactSourceInsertion?>,
            onSourceDragTargeted: @escaping (Bool) -> Void,
            onSourceDrop: @escaping ([StudioArticleTransfer], CGPoint) -> Void,
            onLinkDrop: @escaping ([ArtifactPageLinkTransfer], CGPoint) -> Void,
            linkInsertion: Binding<ArtifactLinkInsertion?>,
            onOpenLink: @escaping (StudioEntityLink) -> Void,
            linkTargets: [ArtifactPageLinkTarget] = [],
            referenceStatuses: [String: ArtifactReferenceStatus],
            onReferencesChange: @escaping ([String]) -> Void,
            onMarginColumnChange: @escaping (Bool) -> Void,
            onAddReference: @escaping (String) -> Void,
            onRequestReference: @escaping (String) -> Void,
            onFulfilReference: @escaping (String, String) -> Void,
            onOpenSource: @escaping (String) -> Void,
            attachmentDataURLs: [String: String],
            attachmentInsertion: Binding<ArtifactAttachmentInsertion?>,
            groundingAttachment: Binding<ArtifactGroundingAttachment?>,
            formatRequest: Binding<ArtifactFormatRequest?>,
            fontSize: CGFloat,
            pageMaxWidth: CGFloat?,
            showsMarginCards: Bool,
            isEditable: Bool,
            onSave: @escaping (String) -> Void,
            onPublication: @escaping (String) -> Void,
            onRequestChat: @escaping (ArtifactEditorSelection) -> Void,
            onRequestComment: @escaping (ArtifactEditorSelection) -> Void,
            onRequestGrounding: @escaping (ArtifactGroundingRequest) -> Void,
            onRequestAIEdit: @escaping (ArtifactAIEditRequest) async throws -> String,
            onRequestImage: @escaping () -> Void,
            onRequestImageGeneration: @escaping (ArtifactImageGenerationRequest) async throws -> ArtifactGeneratedImage,
            onGeneratedImageInserted: @escaping (ArtifactGeneratedImage) -> Void,
            onRequestPrompt: @escaping (String) -> Void,
            onRequestFile: @escaping () async -> ArtifactFileAttachment?,
            onOpenAttachment: @escaping (ArtifactAttachmentOpenRequest) -> Void,
            aiEditOpenRequestID: Int,
            docTitle: String,
            onSelectionChange: @escaping (ArtifactEditorSelection) -> Void,
            onError: @escaping (String) -> Void,
            in webView: WKWebView
        ) {
            self.markdown = markdown
            self.sourceInsertion = sourceInsertion
            self.onSourceDragTargeted = onSourceDragTargeted
            self.onSourceDrop = onSourceDrop
            self.onLinkDrop = onLinkDrop
            self.linkInsertion = linkInsertion
            self.onOpenLink = onOpenLink
            self.onReferencesChange = onReferencesChange
            self.onMarginColumnChange = onMarginColumnChange
            self.onAddReference = onAddReference
            self.onRequestReference = onRequestReference
            self.onFulfilReference = onFulfilReference
            self.onOpenSource = onOpenSource
            latestSwiftMarkdown = markdown.wrappedValue
            // A picture goes into the page before the attachment map is
            // compared: the page registers it as it inserts it, so the map the
            // host then holds adds nothing the page lacks and the document is
            // not drawn again around the caret the picture is going in at.
            self.attachmentInsertion = attachmentInsertion
            if attachmentInsertionID != attachmentInsertion.wrappedValue?.id {
                attachmentInsertionID = attachmentInsertion.wrappedValue?.id
                pendingAttachmentInsertion = attachmentInsertion.wrappedValue
                if isReady { insertPendingAttachment(in: webView) }
            }
            if self.attachmentDataURLs != attachmentDataURLs {
                self.attachmentDataURLs = attachmentDataURLs
                if isReady, Self.pageNeedsAttachments(host: attachmentDataURLs, pageTokens: pageAttachmentTokens) {
                    deliverAttachmentURLs(in: webView)
                }
            }
            if self.referenceStatuses != referenceStatuses {
                self.referenceStatuses = referenceStatuses
                if isReady { deliverReferenceStatuses(in: webView) }
            }
            if self.linkTargets != linkTargets {
                self.linkTargets = linkTargets
                if isReady { deliverLinkTargets(in: webView) }
            }
            self.groundingAttachment = groundingAttachment
            self.formatRequest = formatRequest
            self.onSave = onSave
            self.onPublication = onPublication
            self.onRequestChat = onRequestChat
            self.onRequestComment = onRequestComment
            self.onRequestGrounding = onRequestGrounding
            self.onRequestAIEdit = onRequestAIEdit
            self.onRequestImage = onRequestImage
            self.onRequestImageGeneration = onRequestImageGeneration
            self.onGeneratedImageInserted = onGeneratedImageInserted
            self.onRequestPrompt = onRequestPrompt
            self.onRequestFile = onRequestFile
            self.onOpenAttachment = onOpenAttachment
            self.docTitle = docTitle
            self.onSelectionChange = onSelectionChange
            self.onError = onError

            if self.fontSize != fontSize {
                self.fontSize = fontSize
                if isReady {
                    webView.evaluateJavaScript(
                        "window.foreverLMArtifactEditor.setFontSize(\(Double(fontSize)));")
                }
            }

            if self.pageMaxWidth != pageMaxWidth {
                self.pageMaxWidth = pageMaxWidth
                if isReady {
                    webView.evaluateJavaScript(Self.pageWidthScript(pageMaxWidth))
                }
            }

            if self.showsMarginCards != showsMarginCards {
                self.showsMarginCards = showsMarginCards
                if isReady {
                    webView.evaluateJavaScript(Self.marginCardsScript(showsMarginCards))
                }
            }

            if self.isEditable != isEditable {
                self.isEditable = isEditable
                if isReady {
                    webView.evaluateJavaScript("window.foreverLMArtifactEditor.setEditable(\(isEditable));")
                }
            }

            if isReady, lastEditorMarkdown != latestSwiftMarkdown || foldDocumentChanged {
                let opensAnotherDoc = foldDocumentChanged
                lastEditorMarkdown = latestSwiftMarkdown
                foldDocumentChanged = false
                webView.evaluateJavaScript(setMarkdownScript())
                if opensAnotherDoc {
                    // The editor forgets the last page's threads when another
                    // opens; this page's go in after its body.
                    deliverCommentAnchors(in: webView)
                    focusIfEmpty(in: webView)
                }
            }

            if self.aiEditOpenRequestID != aiEditOpenRequestID {
                self.aiEditOpenRequestID = aiEditOpenRequestID
                if isReady {
                    webView.evaluateJavaScript("window.foreverLMArtifactEditor.openAIEdit();")
                }
            }

            if self.saveRequestID != saveRequestID {
                self.saveRequestID = saveRequestID
                if isReady {
                    webView.evaluateJavaScript("window.foreverLMArtifactEditor.requestSave();")
                } else {
                    pendingSaveRequest = true
                }
            }

            if self.publicationRequestID != publicationRequestID {
                self.publicationRequestID = publicationRequestID
                if isReady { deliverPublication(in: webView) }
                else { pendingPublicationRequest = true }
            }

            if sourceInsertionID != sourceInsertion.wrappedValue?.id {
                sourceInsertionID = sourceInsertion.wrappedValue?.id
                pendingSourceInsertion = sourceInsertion.wrappedValue
                if isReady { attachPendingSources(in: webView) }
            }

            if linkInsertionID != linkInsertion.wrappedValue?.id {
                linkInsertionID = linkInsertion.wrappedValue?.id
                pendingLinkInsertion = linkInsertion.wrappedValue
                if isReady { insertPendingLinks(in: webView) }
            }

            if groundingAttachmentID != groundingAttachment.wrappedValue?.id {
                groundingAttachmentID = groundingAttachment.wrappedValue?.id
                pendingGroundingAttachment = groundingAttachment.wrappedValue
                if isReady { deliverPendingGrounding(in: webView) }
            }

            if formatRequestID != formatRequest.wrappedValue?.id {
                formatRequestID = formatRequest.wrappedValue?.id
                pendingFormatRequest = formatRequest.wrappedValue
                if isReady { runPendingFormatCommand(in: webView) }
            }

        }

        func probeReadiness(in webView: WKWebView) {
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                let result = try? await webView.evaluateJavaScript(
                    "document.body.classList.contains('ready')"
                )
                if result as? Bool == true {
                    markReady(in: webView)
                } else {
                    didFail = true
                    reportError("The artifact editor could not be restored.")
                }
            }
        }

        func reportError(_ message: String) {
            didFail = true
            onError(message)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == ArtifactMarkdownEditorView.messageHandlerName,
                  let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else { return }

            // The notes graph's requests go to the pane through the bridge
            // (PROTOCOL.md, "Editor → host"); one the editor sends malformed
            // is not a request.
            if ArtifactNotesGraphMessage.messageTypes.contains(type) {
                guard let request = ArtifactNotesGraphMessage.parse(type: type, payload: payload) else { return }
                notesGraph?.receive(request)
                return
            }

            switch type {
            case "ready":
                if let webView = message.webView {
                    markReady(in: webView)
                }
            case "foldsChanged":
                // Keyed by the doc the editor names, not the one now open: a
                // report from the doc just closed still belongs to that doc.
                guard let docID = payload["key"] as? String,
                      let folds = payload["folds"] as? String else { return }
                ArtifactOutlineFolds.set(folds, for: docID)
            case "markdownChanged":
                guard let value = payload["markdown"] as? String, isAboutOpenDoc(payload) else { return }
                lastEditorMarkdown = value
                latestSwiftMarkdown = value
                if markdown.wrappedValue != value {
                    markdown.wrappedValue = value
                }
            case "saveRequested":
                guard let value = payload["markdown"] as? String, isAboutOpenDoc(payload) else { return }
                lastEditorMarkdown = value
                latestSwiftMarkdown = value
                if markdown.wrappedValue != value {
                    markdown.wrappedValue = value
                }
                onSave(value)
            case "chatRequested":
                // Hand the fresh selection straight to the chat callback: a
                // SwiftUI state write from `onSelectionChange` would not be
                // visible to a caller reading it in the same update pass.
                let selection = Self.selection(from: payload)
                onSelectionChange(selection)
                onRequestChat(selection)
            case "commentRequested":
                let selection = Self.selection(from: payload)
                onSelectionChange(selection)
                onRequestComment(selection)
            case "groundingRequested":
                onRequestGrounding(ArtifactGroundingRequest(
                    selectedText: payload["selected"] as? String ?? "",
                    sourceIDs: payload["sourceIDs"] as? [String] ?? []
                ))
            case "aiEditRequested":
                guard let request = ArtifactAIEditRequest.parse(payload, docTitle: docTitle) else { return }
                answerAIEdit(request, in: message.webView)
            case "pastedLinesNeedJoining":
                guard let request = PastedLineJoining.Request.parse(payload) else {
                    // Not a paste this host asks about: the editor stops waiting.
                    if let requestID = payload["requestID"] as? String, !requestID.isEmpty {
                        message.webView?.evaluateJavaScript(Self.forgetPastedLineJoiningScript(requestID: requestID)) { _, _ in }
                    }
                    return
                }
                answerPastedLineJoining(request, in: message.webView)
            case "imageRequested":
                // The writer chose Image in the slash menu: the host asks for a
                // picture file, and the pick comes back as an insertion.
                onRequestImage()
            case "imagesPasted":
                let files = ArtifactPastedImages.files(from: payload)
                if !files.isEmpty { onImageFiles(files) }
            case "promptRequested":
                // A Prompt block's Chat about this: its words wait under the
                // composer of a chat opened beside the page; nothing is sent.
                onRequestPrompt((payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            case "fileRequested":
                answerFileRequest(in: message.webView)
            case "openAttachmentRequested":
                guard let request = ArtifactAttachmentOpenRequest.parse(payload) else { return }
                onOpenAttachment(request)
            case "imageGenerationRequested":
                if let request = ArtifactImageGenerationRequest.parse(payload) {
                    answerImageGeneration(request, in: message.webView)
                } else if let requestID = payload["requestID"] as? String, !requestID.isEmpty {
                    // The panel is waiting on this request: it is told, not left drawing.
                    message.webView?.evaluateJavaScript(Self.aiEditFailureScript(
                        requestID: requestID,
                        message: "Describe the picture you want drawn."
                    )) { _, _ in }
                }
            case "aiEditModelMenuRequested":
                guard let webView = message.webView,
                      let x = (payload["x"] as? NSNumber)?.doubleValue,
                      let y = (payload["y"] as? NSNumber)?.doubleValue,
                      let width = (payload["width"] as? NSNumber)?.doubleValue,
                      let height = (payload["height"] as? NSNumber)?.doubleValue else { return }
                showAIEditModelMenu(below: CGRect(x: x, y: y, width: width, height: height), in: webView)
            case "commentAnchorClicked":
                guard let id = payload["id"] as? String, !id.isEmpty else { return }
                editorChosenCommentID = id
                onCommentAnchorClicked(id)
            case "commentAnchorsResolved":
                onCommentAnchorsDetached(Set((payload["detached"] as? [String]) ?? []))
            case "selectionChanged":
                onSelectionChange(Self.selection(from: payload))
            case "openLinkRequested":
                guard let href = payload["href"] as? String else { return }
                if let link = StudioEntityLink.parse(destination: href) {
                    openEntityLink(link, address: URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else if let source = NotesGraphSourceLink.parse(href) {
                    // A source the page foot names — something read that day,
                    // or a passage highlighted — opens beside the doc; a
                    // highlight at its passage, when the pane knows the graph.
                    if let notesGraph {
                        notesGraph.receive(.openSourceRequested(source))
                    } else {
                        onOpenSource(source.sourceID)
                    }
                }
            case "referencesChanged":
                onReferencesChange((payload["hrefs"] as? [String]) ?? [])
                onMarginColumnChange((payload["marginColumn"] as? Bool) ?? false)
            case "addReferenceRequested":
                guard let href = payload["href"] as? String, !href.isEmpty else { return }
                onAddReference(href)
            case "requestReferenceRequested":
                guard let href = payload["href"] as? String, !href.isEmpty else { return }
                onRequestReference(href)
            case "fulfilReferenceRequested":
                guard let href = payload["href"] as? String, !href.isEmpty else { return }
                onFulfilReference(href, (payload["requestID"] as? String) ?? "")
            case "openSourceRequested":
                // The page foot names its sources with this message too, a
                // highlight's address carrying the mark (`?highlight=`): that
                // one opens at its passage when the pane knows the graph.
                if let href = payload["href"] as? String,
                   let source = NotesGraphSourceLink.parse(href), source.highlightID != nil,
                   let notesGraph {
                    notesGraph.receive(.openSourceRequested(source))
                    return
                }
                guard let sourceID = payload["sourceID"] as? String, !sourceID.isEmpty else { return }
                onOpenSource(sourceID)
            case "sourcesDropped":
                // A source drag the web view did not claim at the AppKit level
                // — one carrying only a `foreverlm://source/<id>` address —
                // reaches the page as a browser drop, and the page reports the
                // ids and the point. Named from the library the way a claimed
                // drop is; an id the library does not hold writes nothing.
                let sourceIDs = ((payload["sourceIDs"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard !sourceIDs.isEmpty,
                      let x = (payload["x"] as? NSNumber)?.doubleValue,
                      let y = (payload["y"] as? NSNumber)?.doubleValue else { return }
                let transfers = sourceIDs.map { StudioArticleTransfer(articleId: $0, articleIds: [$0], title: "", sourceType: "") }
                onSourceDrop(transfers, CGPoint(x: x, y: y))
            case "error":
                reportError(payload["message"] as? String ?? "The artifact editor failed to load.")
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !initializationStarted else { return }
            initializationStarted = true
            // `create` is async and returns a Promise. WKWebView cannot bridge that
            // object through `evaluateJavaScript`, even though editor startup itself
            // continues successfully, so make the evaluated expression return a
            // property-list-compatible value.
            let script = Self.startupScript(
                markdown: latestSwiftMarkdown,
                fontSize: fontSize,
                pageMaxWidth: pageMaxWidth,
                showsMarginCards: showsMarginCards
            )
            webView.evaluateJavaScript(script) { [weak self] _, error in
                if let error {
                    self?.reportError("Could not start the artifact editor: \(error.localizedDescription)")
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            reportError("Could not load the artifact editor: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            reportError("Could not load the artifact editor: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // One of the editor's own addresses is an identity, not a
            // destination: `foreverlm.invalid` resolves nowhere, and handing it
            // to the browser opens a failed page. Grounded prose is the case
            // that reaches here — it carries a link mark so that a passage can
            // say what it stands on, and clicking it belongs to the caret. A
            // link to another doc or a Notebook is the one private address
            // that goes somewhere, and the host takes it there.
            if let link = StudioEntityLink.parse(url) {
                openEntityLink(link, address: url)
            } else if !Self.isPrivateSourceAddress(url) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        /// A page link whose anchor names a block (`foreverlm://doc/<id>#<block
        /// id>`, what a block's Copy link writes) opens the page with that block
        /// shown and flashed, the way a block reference opens one
        /// (`openReferenceRequested`). Any other link, or a pane without the
        /// notes graph, opens the thing itself.
        private func openEntityLink(_ link: StudioEntityLink, address: URL?) {
            if case .doc(let id) = link, let notesGraph, let blockID = Self.blockAnchor(of: address) {
                notesGraph.receive(.openReferenceRequested(kind: "doc", id: id, blockID: blockID, plainText: nil))
            } else {
                onOpenLink(link)
            }
        }

        /// The block id a page link's anchor names, or nil.
        static func blockAnchor(of address: URL?) -> String? {
            guard let fragment = address?.fragment, DocGraphSyntax.isBlockID(fragment) else { return nil }
            return fragment
        }

        /// An empty page has nothing to read, only to write: the caret goes into
        /// it, so what is typed after New Page (or opening an empty daily note)
        /// lands on the page rather than nowhere until the page is clicked.
        private func focusIfEmpty(in webView: WKWebView) {
            guard isEditable,
                  latestSwiftMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Never from a field being typed in (the title, a search), nor from
            // a list being arrowed through, which would lose its place at the
            // first empty page or daily note it passed.
            let responder = webView.window?.firstResponder
            if let field = responder as? NSTextView, field.isFieldEditor { return }
            if responder is NSTableView || responder is NSCollectionView { return }
            webView.window?.makeFirstResponder(webView)
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.focus();")
        }

        private func markReady(in webView: WKWebView) {
            isReady = true
            didFail = false
            webView.evaluateJavaScript(
                "window.foreverLMArtifactEditor.setFontSize(\(Double(fontSize)));")
            webView.evaluateJavaScript(Self.pageWidthScript(pageMaxWidth))
            webView.evaluateJavaScript(Self.marginCardsScript(showsMarginCards))
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.setEditable(\(isEditable));")
            webView.evaluateJavaScript(Self.slashFeaturesScript)
            webView.evaluateJavaScript(Self.joinsPastedLinesScript)
            // A pooled web view may still contain the previously opened artifact.
            // `setMarkdown` is a no-op when this is already the current value.
            lastEditorMarkdown = latestSwiftMarkdown
            foldDocumentChanged = false
            webView.evaluateJavaScript(setMarkdownScript())
            deliverCommentAnchors(in: webView)
            deliverActiveComment(in: webView, reveal: false)
            deliverAttachmentURLs(in: webView)
            deliverReferenceStatuses(in: webView)
            deliverLinkTargets(in: webView)
            deliverAIEditModel(in: webView)
            // After the body: a block to reveal is looked for in this doc, and
            // a pooled page's page-foot sections are the last doc's until now.
            notesGraph?.pageBecameReady(self)
            if pendingSaveRequest {
                pendingSaveRequest = false
                webView.evaluateJavaScript("window.foreverLMArtifactEditor.requestSave();")
            }
            if pendingPublicationRequest {
                pendingPublicationRequest = false
                deliverPublication(in: webView)
            }
            attachPendingSources(in: webView)
            insertPendingLinks(in: webView)
            focusIfEmpty(in: webView)
            insertPendingAttachment(in: webView)
            deliverPendingGrounding(in: webView)
            runPendingFormatCommand(in: webView)
        }

        /// Attach a dropped source to the passage the drop chose: the paragraph
        /// under the pointer, or the highlighted one when the drop landed on the
        /// pane rather than on the page.
        private func attachPendingSources(in webView: WKWebView) {
            guard let insertion = pendingSourceInsertion else { return }
            pendingSourceInsertion = nil
            if sourceInsertion.wrappedValue?.id == insertion.id {
                let insertionID = insertion.id
                DispatchQueue.main.async { [weak self] in
                    guard self?.sourceInsertion.wrappedValue?.id == insertionID else { return }
                    self?.sourceInsertion.wrappedValue = nil
                }
            }
            let data = (try? JSONEncoder().encode(insertion.citations)) ?? Data("[]".utf8)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            let script: String
            if let location = insertion.editorLocation {
                script = "window.foreverLMArtifactEditor.dropSourcesAt(\(json), \(Double(location.x)), \(Double(location.y)));"
            } else {
                script = "window.foreverLMArtifactEditor.attachSourcesToSelection(\(json));"
            }
            webView.evaluateJavaScript(script) { [weak self] _, error in
                if let error {
                    self?.reportError("Could not attach the source: \(error.localizedDescription)")
                }
            }
        }

        /// Write dropped doc and Notebook links where they landed, or at the
        /// caret when the drop carried no point.
        private func insertPendingLinks(in webView: WKWebView) {
            guard let insertion = pendingLinkInsertion else { return }
            pendingLinkInsertion = nil
            if linkInsertion.wrappedValue?.id == insertion.id {
                let insertionID = insertion.id
                DispatchQueue.main.async { [weak self] in
                    guard self?.linkInsertion.wrappedValue?.id == insertionID else { return }
                    self?.linkInsertion.wrappedValue = nil
                }
            }
            let data = (try? JSONEncoder().encode(insertion.links)) ?? Data("[]".utf8)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            let x = insertion.editorLocation.map { "\(Double($0.x))" } ?? "null"
            let y = insertion.editorLocation.map { "\(Double($0.y))" } ?? "null"
            webView.evaluateJavaScript(
                "window.foreverLMArtifactEditor.insertLinksAt(\(json), \(x), \(y));"
            ) { [weak self] _, error in
                if let error {
                    self?.reportError("Could not insert the link: \(error.localizedDescription)")
                }
            }
        }

        /// WebKit's own find selects the match and scrolls it into view, in the
        /// editable page exactly as in a read-only one. Run outside the update
        /// pass: the result lands in `statusText`, which is view state.
        func performFindIfNeeded(in webView: WKWebView, revision: Int, state: ReaderFindState) {
            guard revision > 0, revision != lastFindRevision else { return }
            lastFindRevision = revision
            Task { @MainActor [weak webView] in
                guard let webView else { return }
                ReaderFindPerformer.performWebFind(
                    in: webView,
                    state: state,
                    query: state.query,
                    backwards: state.searchesBackward
                )
            }
        }

        private func runPendingFormatCommand(in webView: WKWebView) {
            guard let request = pendingFormatRequest else { return }
            pendingFormatRequest = nil
            if formatRequest.wrappedValue?.id == request.id {
                let requestID = request.id
                DispatchQueue.main.async { [weak self] in
                    guard self?.formatRequest.wrappedValue?.id == requestID else { return }
                    self?.formatRequest.wrappedValue = nil
                }
            }
            switch request.action {
            case .format(let command):
                webView.evaluateJavaScript(
                    "window.foreverLMArtifactEditor.runFormatCommand(\(Self.jsonString(command.rawValue)));"
                ) { [weak self] _, error in
                    if let error {
                        self?.reportError("Could not apply the formatting: \(error.localizedDescription)")
                    }
                }
            case .tool(let tool):
                // The press was on the pane's top line, so the page may not be
                // the window's first responder: the picker the tool opens, and
                // what is typed into it, need the page to be.
                webView.window?.makeFirstResponder(webView)
                webView.evaluateJavaScript(tool.script) { [weak self] _, error in
                    if let error {
                        self?.reportError("Could not run that tool: \(error.localizedDescription)")
                    }
                }
            }
        }

        private func deliverAttachmentURLs(in webView: WKWebView) {
            pageAttachmentTokens = Set(attachmentDataURLs.keys)
            let data = (try? JSONEncoder().encode(attachmentDataURLs)) ?? Data("{}".utf8)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.setAttachmentURLs(\(json));")
        }

        /// The library's answer for the doc's reference cards. The whole map goes
        /// each time, so a card the host stops mentioning returns to its quiet form.
        private func deliverReferenceStatuses(in webView: WKWebView) {
            let data = (try? JSONEncoder().encode(referenceStatuses)) ?? Data("{}".utf8)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.setReferenceStatuses(\(json));")
        }

        /// What a typed link can point at. The whole list goes each time, so a
        /// doc renamed, filed elsewhere or deleted reads that way in the picker.
        private func deliverLinkTargets(in webView: WKWebView) {
            let data = (try? JSONEncoder().encode(linkTargets)) ?? Data("[]".utf8)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.setLinkTargets(\(json));")
        }

        private func deliverPublication(in webView: WKWebView) {
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.publicationHTML();") {
                [weak self] result, error in
                if let error {
                    self?.reportError("Could not prepare the publication: \(error.localizedDescription)")
                } else if let html = result as? String, !html.isEmpty {
                    self?.onPublication(html)
                }
            }
        }

        /// Hand the chosen sources to the passage the editor still has selected.
        ///
        /// The selection lives in the editor, not here — the picker was opened from
        /// it and does not move it — so the attachment travels as a list of ids and
        /// the editor applies it to whatever the writer highlighted.
        private func deliverPendingGrounding(in webView: WKWebView) {
            guard let attachment = pendingGroundingAttachment else { return }
            pendingGroundingAttachment = nil
            if groundingAttachment.wrappedValue?.id == attachment.id {
                let attachmentID = attachment.id
                DispatchQueue.main.async { [weak self] in
                    guard self?.groundingAttachment.wrappedValue?.id == attachmentID else { return }
                    self?.groundingAttachment.wrappedValue = nil
                }
            }
            let data = (try? JSONEncoder().encode(attachment.sourceIDs)) ?? Data("[]".utf8)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.attachSources(\(json));") {
                [weak self] _, error in
                if let error {
                    self?.reportError("Could not attach the sources: \(error.localizedDescription)")
                }
            }
        }

        private func insertPendingAttachment(in webView: WKWebView) {
            guard let insertion = pendingAttachmentInsertion else { return }
            pendingAttachmentInsertion = nil
            if attachmentInsertion.wrappedValue?.id == insertion.id {
                let insertionID = insertion.id
                DispatchQueue.main.async { [weak self] in
                    guard self?.attachmentInsertion.wrappedValue?.id == insertionID else { return }
                    self?.attachmentInsertion.wrappedValue = nil
                }
            }
            let payload: [String: String] = [
                "token": insertion.token,
                "altText": insertion.altText,
                "dataURL": insertion.dataURL,
            ]
            let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            // The page registers the picture as it inserts it.
            pageAttachmentTokens.insert(insertion.token)
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.insertAttachment(\(json));") {
                [weak self] _, error in
                if let error {
                    self?.reportError("Could not insert the image: \(error.localizedDescription)")
                }
            }
        }

        /// Run the model for the panel's request and hand the answer back to the
        /// editor, which shows it against the passage. The web view is the one
        /// the request came from; a doc closed meanwhile has nothing to hear it.
        private func answerAIEdit(_ request: ArtifactAIEditRequest, in webView: WKWebView?) {
            let respond = onRequestAIEdit
            Task { @MainActor [weak self, weak webView] in
                let script: String
                do {
                    let markdown = try await respond(request)
                    script = "window.foreverLMArtifactEditor.completeAIEdit(\(Self.jsonString(request.requestID)), { markdown: \(Self.jsonString(markdown)) });"
                } catch {
                    script = "window.foreverLMArtifactEditor.failAIEdit(\(Self.jsonString(request.requestID)), \(Self.jsonString(error.localizedDescription)));"
                }
                guard let webView, self != nil else { return }
                webView.evaluateJavaScript(script) { _, _ in }
            }
        }

        /// Ask the Pasted Line Joining model what each break of a paste was and
        /// hand the answer to the editor, which joins the lines only while the
        /// paste is still as it came. A failed or unconfigured call leaves the
        /// paste as pasted; the ledger keeps the failure.
        private func answerPastedLineJoining(_ request: PastedLineJoining.Request, in webView: WKWebView?) {
            let pageTitle = docTitle
            Task { @MainActor [weak webView] in
                let script: String
                do {
                    let breaks = try await PastedLineJoining.liveBreaks(for: request, pageTitle: pageTitle)
                    script = Self.pastedLineJoiningScript(requestID: request.requestID, breaks: breaks)
                } catch {
                    script = Self.forgetPastedLineJoiningScript(requestID: request.requestID)
                }
                guard let webView else { return }
                webView.evaluateJavaScript(script) { _, _ in }
            }
        }

        /// Ask the writer for a file and hand it to the editor, which writes it
        /// where the caret was as a link to the page's copy
        /// (`insertFileAttachment`). The host says why when it cannot be kept.
        private func answerFileRequest(in webView: WKWebView?) {
            let pick = onRequestFile
            Task { @MainActor [weak webView] in
                guard let file = await pick(), let webView else { return }
                webView.evaluateJavaScript(Self.fileInsertionScript(file)) { _, _ in }
            }
        }

        /// `insertFileAttachment`'s call: the file as the editor links it.
        static func fileInsertionScript(_ file: ArtifactFileAttachment) -> String {
            "window.foreverLMArtifactEditor.insertFileAttachment({ token: \(jsonString(file.token)), name: \(jsonString(file.name)), size: \(file.size) });"
        }

        /// Draw the picture the writer described and hand it to the editor,
        /// which writes it where the caret was and closes its panel
        /// (`completeImageGeneration`). The host draws it on the account's
        /// image model and keeps it in the doc's Attachments; a failure goes
        /// to the panel the writer is looking at, in a sentence.
        private func answerImageGeneration(_ request: ArtifactImageGenerationRequest, in webView: WKWebView?) {
            let respond = onRequestImageGeneration
            Task { @MainActor [weak self, weak webView] in
                let script: String
                var drawn: ArtifactGeneratedImage?
                do {
                    let image = try await respond(request)
                    drawn = image
                    script = Self.imageGenerationScript(requestID: request.requestID, image: image)
                } catch {
                    script = Self.aiEditFailureScript(requestID: request.requestID, message: error.localizedDescription)
                }
                guard let webView, let self else { return }
                webView.evaluateJavaScript(script) { _, _ in }
                // The page registers the picture itself when it inserts it, so
                // the host's copy of the attachments gains it only after that
                // call: the update it causes then finds nothing new to send,
                // and the page is not drawn again around the caret.
                if let drawn {
                    pageAttachmentTokens.insert(drawn.token)
                    onGeneratedImageInserted(drawn)
                }
            }
        }

        /// `completeImageGeneration`'s call: the picture as `insertAttachment`
        /// takes it.
        static func imageGenerationScript(requestID: String, image: ArtifactGeneratedImage) -> String {
            let payload: [String: String] = [
                "token": image.token,
                "altText": image.altText,
                "dataURL": image.dataURL,
            ]
            let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return "window.foreverLMArtifactEditor.completeImageGeneration(\(jsonString(requestID)), \(json));"
        }

        /// `failAIEdit`'s call: the panel the request came from says why.
        static func aiEditFailureScript(requestID: String, message: String) -> String {
            "window.foreverLMArtifactEditor.failAIEdit(\(jsonString(requestID)), \(jsonString(message)));"
        }

        /// What the host can do for the slash menu's rows that are not the
        /// editor's own. Every row the host answers is offered; the editor
        /// shows none of them on a page that is not editable.
        static let slashFeaturesScript =
            "window.foreverLMArtifactEditor.setSlashFeatures({ pages: true, images: true, imageGeneration: true, visualize: true, files: true });"

        /// This host answers `pastedLinesNeedJoining`, so the editor asks it
        /// about a paste of printed lines; a host that never says so is never
        /// asked, and its pastes stay as they came.
        static let joinsPastedLinesScript =
            "window.foreverLMArtifactEditor.setJoinsPastedLines(true);"

        /// `completePastedLineJoining`'s call: what each break was, in order.
        static func pastedLineJoiningScript(requestID: String, breaks: [PastedLineJoining.Break]) -> String {
            let list = breaks.map { jsonString($0.rawValue) }.joined(separator: ", ")
            return "window.foreverLMArtifactEditor.completePastedLineJoining(\(jsonString(requestID)), [\(list)]);"
        }

        /// `forgetPastedLineJoining`'s call: no answer is coming for this paste.
        static func forgetPastedLineJoiningScript(requestID: String) -> String {
            "window.foreverLMArtifactEditor.forgetPastedLineJoining(\(jsonString(requestID)));"
        }

        /// Name the Docs model to the panel's ForeverLM mark, which shows once
        /// it has a name. The name is read off the main actor: the stored
        /// routes can reach `KeychainService.load`.
        private func deliverAIEditModel(in webView: WKWebView) {
            Task { @MainActor [weak self, weak webView] in
                let name = await Task.detached(priority: .userInitiated) {
                    DocsModelMenu.currentModelName()
                }.value
                guard let self, self.isReady, let webView else { return }
                webView.evaluateJavaScript(
                    "window.foreverLMArtifactEditor.setAIEditModel({ name: \(Self.jsonString(name)) });"
                ) { _, _ in }
            }
        }

        /// The mark was pressed: the model menu opens under it, at the rect
        /// the page measured. The editor never scales its page, so the page's
        /// CSS pixels are the web view's points.
        private func showAIEditModelMenu(below rect: CGRect, in webView: WKWebView) {
            Task { @MainActor [weak webView] in
                guard let webView else { return }
                await DocsModelMenu.present(in: webView, below: rect) { [weak webView] message in
                    webView?.evaluateJavaScript(
                        "window.foreverLMArtifactEditor.refuseAIEditModel(\(Self.jsonString(message)));"
                    ) { _, _ in }
                }
            }
        }

        private static func selection(from payload: [String: Any]) -> ArtifactEditorSelection {
            ArtifactEditorSelection(
                text: payload["selected"] as? String ?? "",
                from: payload["from"] as? Int ?? 0,
                to: payload["to"] as? Int ?? 0,
                sectionTitle: payload["sectionTitle"] as? String ?? "",
                sectionText: payload["sectionText"] as? String ?? "",
                citedSourceIDs: payload["sourceIDs"] as? [String] ?? [],
                groundedSourceIDs: payload["grounded"] as? [String] ?? [],
                activeFormats: Set(
                    (payload["formats"] as? [String] ?? []).compactMap(ArtifactFormatCommand.init(rawValue:))
                )
            )
        }

        /// The page's threads and the open one, sent when they change. A
        /// choice of thread made here (from the panel) shows its passage; one
        /// the editor reported (a click on the words) is already in view.
        func useComments(_ anchors: [ArtifactCommentAnchor], activeID: String?, in webView: WKWebView) {
            if commentAnchors != anchors {
                commentAnchors = anchors
                if isReady { deliverCommentAnchors(in: webView) }
            }
            if activeCommentID != activeID {
                activeCommentID = activeID
                if isReady { deliverActiveComment(in: webView, reveal: activeID != editorChosenCommentID) }
                editorChosenCommentID = nil
            }
        }

        /// The thread whose words were clicked in the page, until the host's
        /// next pass hands it back as the open thread.
        private var editorChosenCommentID: String?

        private func deliverCommentAnchors(in webView: WKWebView) {
            webView.evaluateJavaScript(ArtifactCommentAnchor.script(for: commentAnchors))
        }

        private func deliverActiveComment(in webView: WKWebView, reveal: Bool) {
            let id = activeCommentID.map(Self.jsonString) ?? "null"
            webView.evaluateJavaScript("window.foreverLMArtifactEditor.setActiveComment(\(id), { reveal: \(reveal) });")
        }

        func openFoldDocument(_ docID: String?) {
            guard foldDocumentID != docID else { return }
            foldDocumentID = docID
            foldDocumentChanged = true
        }

        /// The body, and with it the doc's id and kept folds, which the editor
        /// takes only when the doc is not the one it already holds.
        private func setMarkdownScript() -> String {
            let foldState = foldDocumentID.map { docID in
                "{ key: \(Self.jsonString(docID)), folds: \(Self.jsonString(ArtifactOutlineFolds.folds(for: docID))) }"
            } ?? "null"
            return "window.foreverLMArtifactEditor.setMarkdown(\(Self.jsonString(latestSwiftMarkdown)), \(foldState));"
        }

        private static func jsonString(_ value: String) -> String {
            let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
            return String(data: data, encoding: .utf8) ?? "\"\""
        }

        /// The page width and the margin cards go in before `create`, so the
        /// first paint is already at the reader's width, with or without the
        /// cards, rather than the stylesheet's default.
        static func startupScript(
            markdown: String,
            fontSize: CGFloat,
            pageMaxWidth: CGFloat?,
            showsMarginCards: Bool = true
        ) -> String {
            pageWidthScript(pageMaxWidth)
                + " " + marginCardsScript(showsMarginCards)
                + " window.foreverLMArtifactEditor.create(\(jsonString(markdown)), \(Double(fontSize))); true;"
        }

        static func marginCardsScript(_ shown: Bool) -> String {
            "window.foreverLMArtifactEditor.setMarginCardsShown(\(shown));"
        }

        /// Whether the host holds a picture the page cannot draw yet. Only
        /// then is the whole map sent, which draws the document again: a page
        /// that registered a picture itself when it inserted it (an upload, a
        /// drawing) has it already, and a map that only lost pictures changes
        /// nothing the page shows.
        static func pageNeedsAttachments(host: [String: String], pageTokens: Set<String>) -> Bool {
            !Set(host.keys).isSubset(of: pageTokens)
        }

        /// `setPageWidth` takes the cap in CSS pixels; anything that is not a
        /// finite positive number means the page fills the pane.
        static func pageWidthScript(_ pageMaxWidth: CGFloat?) -> String {
            let argument = pageMaxWidth.map { "\(Double($0))" } ?? "null"
            return "window.foreverLMArtifactEditor.setPageWidth(\(argument));"
        }

        /// Whether a URL is one of the editor's own source addresses — a
        /// grounded passage, or a citation chip in a doc old enough to still
        /// carry one — rather than a link to somewhere on the web.
        private static func isPrivateSourceAddress(_ url: URL) -> Bool {
            let host = url.host?.lowercased()
            if url.scheme?.lowercased() == "foreverlm", host == "source" || host == "grounding" {
                return true
            }
            guard url.scheme?.lowercased() == "https", host == "foreverlm.invalid" else { return false }
            return url.pathComponents.filter { $0 != "/" }.first.map {
                $0 == "source" || $0 == "grounding"
            } ?? false
        }
    }
}
