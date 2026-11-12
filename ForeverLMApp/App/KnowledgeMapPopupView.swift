import SwiftUI

// MARK: - The ⌘-click popup (docs/knowledge-map-design.md, "Circling and the inspector")
//
// Heptabase's ⌘-click floats a card over the whiteboard without leaving it.
// Here it floats the card's faces beside the card the page drew, positioned as
// the review's question card is (`KnowledgeMapReviewPlacement`): to its right,
// to its left when the right has no room, clamped into the pane. An Idea's
// note is edited in place with `KnowledgeMapIdeaEditor`; every other card
// shows what the Canvas says of it, and Open Beside or Open takes it away
// to be read. One shows at a time. Esc, the ×, a click elsewhere on the plane
// (the selection moving off the card, the camera moving) and the pane closing
// all dismiss it.

/// The popup over the plane, in the window it was asked for.
struct KnowledgeMapPopupLayer: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    var body: some View {
        if let popup = vm.knowledgeMap(in: windowState).popup, popup.windowID == nil || popup.windowID == windowState.id {
            KnowledgeMapPopupHost(popup: popup)
                .id(popup.ref)
        }
    }
}

enum KnowledgeMapPopupMetrics {
    static let width: CGFloat = 330
    /// The card never grows taller than this; what is longer scrolls.
    static let maximumHeight: CGFloat = 460
    /// How long after it shows the popup ignores the plane's own reports
    /// (a late selection or view message from the press that opened it).
    static let armDelay: Duration = .milliseconds(450)
}

private struct KnowledgeMapPopupHost: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    let popup: KnowledgeMapPopup

    @State private var cardHeight: CGFloat = 200
    @State private var armed = false

    private var map: KnowledgeMapModel { vm.knowledgeMap(in: windowState) }

    /// Where the camera is, so a pan or a zoom (which moves the card from
    /// under the popup) takes it away.
    private var cameraKey: [Double] {
        let view = map.viewport
        return [view.center.x, view.center.y, view.span.w, view.span.h]
    }

    var body: some View {
        GeometryReader { geo in
            let card = CGSize(width: KnowledgeMapPopupMetrics.width, height: cardHeight)
            let origin = KnowledgeMapReviewPlacement.origin(beside: popup.rect, card: card, pane: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)
                KnowledgeMapPopupCard(ref: popup.ref, onClose: close)
                    .frame(width: KnowledgeMapPopupMetrics.width)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        if abs(height - cardHeight) > 0.5 { cardHeight = height }
                    }
                    .offset(x: origin.x, y: origin.y)
                    .animation(.easeOut(duration: 0.15), value: origin)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .task {
            try? await Task.sleep(for: KnowledgeMapPopupMetrics.armDelay)
            armed = true
        }
        // A click elsewhere on the plane: the selection leaves the card.
        .onChange(of: map.selection) { _, selection in
            if armed, !selection.contains(popup.ref) { close() }
        }
        .onChange(of: map.selectedRegionID) { _, id in
            if armed, id != nil { close() }
        }
        .onChange(of: map.selectedEdgeID) { _, id in
            if armed, id != nil { close() }
        }
        .onChange(of: cameraKey) {
            if armed { close() }
        }
        // The pane closing, or another card's popup replacing this one.
        .onDisappear {
            if map.popup?.ref == popup.ref { vm.dismissKnowledgeMapPopup() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("knowledgeMap.popup")
    }

    private func close() {
        vm.dismissKnowledgeMapPopup()
    }
}

/// The floating card: the faces the Canvas has of one card, and what to do
/// with it. The ⌘-click popup floats it over the plane; the Library sidebar
/// shows it in a popover beside a row, which draws its own material and
/// shadow (`drawsChrome: false`). A card not on the canvas offers **Place on
/// the Canvas**: beside the selection, else the middle of the view.
struct KnowledgeMapPopupCard: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let ref: String
    let drawsChrome: Bool
    let onClose: () -> Void

    /// How tall what the card says is, measured; the scroll view is that tall.
    @State private var faceHeight: CGFloat = 120

    init(ref: String, drawsChrome: Bool = true, onClose: @escaping () -> Void) {
        self.ref = ref
        self.drawsChrome = drawsChrome
        self.onClose = onClose
    }

    private var map: KnowledgeMapModel { vm.knowledgeMap(in: windowState) }
    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        if drawsChrome {
            card
                .background(.regularMaterial, in: Self.shape)
                .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        } else {
            card
        }
    }

    private var card: some View {
        let node = map.nodesByRef[ref]
        let placed = map.layout.placements[ref] != nil
        return VStack(alignment: .leading, spacing: 10) {
            header(node)
            // What the card says, as tall as it is; it scrolls only once it
            // would pass the most the popup is allowed. One scroll view
            // throughout, so an Idea's editor keeps what is typed in it.
            ScrollView {
                faceColumn(node)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        if abs(height - faceHeight) > 0.5 { faceHeight = height }
                    }
            }
            .frame(height: min(faceHeight, KnowledgeMapPopupMetrics.maximumHeight))
            // An Idea edits in place, so it has no Open; a card not on the canvas
            // can be set down from here.
            if let item = KnowledgeMap.ItemRef(ref), item.kind != .idea || !placed {
                HStack(spacing: 4) {
                    if !placed {
                        Button("Place on the Canvas") {
                            map.send(.dropAtCenter(refs: [ref], regionName: nil))
                            onClose()
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                        .help("Set it down beside the selection, or in the middle of the view")
                        .accessibilityIdentifier("knowledgeMap.popup.place")
                    }
                    if item.kind != .idea {
                        Button("Open Beside") {
                            vm.task(in: windowState) { await vm.openKnowledgeMapItemBeside(ref, in: windowState) }
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                        .help("Open it beside the Canvas")
                        .accessibilityIdentifier("knowledgeMap.popup.openBeside")
                        Button("Open") {
                            onClose()
                            vm.task(in: windowState) { await vm.openKnowledgeMapItem(ref, in: windowState) }
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                        .accessibilityIdentifier("knowledgeMap.popup.open")
                    }
                    Spacer(minLength: 0)
                }
                .zoomedSystemFont(size: 12)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func faceColumn(_ node: KnowledgeMapNode?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let node {
                faces(node)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ node: KnowledgeMapNode?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(node?.kind == "idea" ? Color.yellow.opacity(0.85) : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(Self.kindName(node))
                .zoomedSystemFont(size: 10.5, weight: .semibold)
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.disabled)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .accessibilityLabel("Close the popup")
            .accessibilityIdentifier("knowledgeMap.popup.close")
        }
    }

    /// "PAPER", "IDEA", "PAGE"…: what the card is, as the Canvas names its type.
    private static func kindName(_ node: KnowledgeMapNode?) -> String {
        guard let node else { return "CARD" }
        switch node.kind {
        case "idea": return "IDEA"
        case "clip": return node.quote == nil ? "CLIP" : "PASSAGE"
        case "doc": return node.type.uppercased()
        default: return node.type.isEmpty ? node.kind.uppercased() : node.type.uppercased()
        }
    }

    @ViewBuilder
    private func faces(_ node: KnowledgeMapNode) -> some View {
        if let item = KnowledgeMap.ItemRef(ref), item.kind == .idea, let idea = vm.ideas.first(where: { $0.id == item.id }) {
            KnowledgeMapIdeaEditor(idea: idea)
        } else {
            Text(node.title)
                .zoomedSystemFont(size: 14, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
            if !node.sub.isEmpty {
                Text(node.sub)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let quote = node.quote, !quote.isEmpty {
                Text("“\(quote)”")
                    .zoomedSystemFont(size: 12.5)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
            // What ForeverLM wrote about a source, from far to near.
            if let face = map.faces[ref] {
                writtenFaces(face)
            }
            ForEach(node.detail, id: \.self) { line in
                Text(line)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func writtenFaces(_ face: KnowledgeMapFaces.Face) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !face.mid.isEmpty {
                Text("✦ " + face.mid)
                    .zoomedSystemFont(size: 12.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(face.near, id: \.self) { line in
                Text(line)
                    .zoomedSystemFont(size: 11.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - The compact Idea editor

/// An Idea's title and note, edited where it is shown, with the evidence
/// linked to it and a way to Ideas (product owner, 2026-10-09: Heptabase edits a
/// note on the board). It writes through `StudioViewModel.updateIdea` when a
/// field loses focus and when it goes away, never on a keystroke, so the
/// card is rebuilt once per edit.
struct KnowledgeMapIdeaEditor: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let idea: IdeaRecord

    @State private var title: String
    @State private var notes: String
    @FocusState private var focus: Field?

    private enum Field { case title, notes }

    init(idea: IdeaRecord) {
        self.idea = idea
        _title = State(initialValue: idea.title)
        _notes = State(initialValue: idea.notes ?? "")
    }

    private var ref: String { KnowledgeMap.ItemRef(kind: .idea, id: idea.id).description }
    private var canSave: Bool { !IdeaRecord.normalizedTitle(title).isEmpty }
    private var hasChanges: Bool { title != idea.title || notes != (idea.notes ?? "") }
    private static let evidenceLimit = 6

    var body: some View {
        let evidence = vm.knowledgeMap(in: windowState).evidence(of: ref)
        VStack(alignment: .leading, spacing: 8) {
            TextField("The idea, in a line", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 14, weight: .semibold)
                .lineLimit(1...4)
                .focused($focus, equals: .title)
                .onSubmit { focus = .notes }
                .accessibilityIdentifier("knowledgeMap.popup.idea.title")
            TextEditor(text: $notes)
                .zoomedSystemFont(size: 12.5)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 84, maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                .focused($focus, equals: .notes)
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Notes")
                            .zoomedSystemFont(size: 12.5)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                            .textSelection(.disabled)
                    }
                }
                .accessibilityIdentifier("knowledgeMap.popup.idea.notes")
            if !evidence.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evidence · \(evidence.count)")
                        .zoomedSystemFont(size: 10.5, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                    ForEach(evidence.prefix(Self.evidenceLimit), id: \.self) { evidenceRef in
                        Button {
                            vm.task(in: windowState) { await vm.openKnowledgeMapItemBeside(evidenceRef, in: windowState) }
                        } label: {
                            Text(vm.knowledgeMap(in: windowState).title(of: evidenceRef))
                                .zoomedSystemFont(size: 12)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -3, opacity: 0.08))
                        .help("Open it beside the Canvas")
                    }
                    if evidence.count > Self.evidenceLimit {
                        Text("and \(evidence.count - Self.evidenceLimit) more")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                    }
                }
            }
            HStack {
                Button("Open in Ideas") {
                    commit()
                    vm.task(in: windowState) { await vm.openIdea(idea.id) }
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                .zoomedSystemFont(size: 12)
                .help("Open this idea in Ideas, beside the Canvas")
                .accessibilityIdentifier("knowledgeMap.popup.idea.open")
                Spacer(minLength: 0)
            }
        }
        .onChange(of: focus) { old, new in
            if old != nil, new != old { commit() }
        }
        .onDisappear { commit() }
    }

    /// Writes what was typed. An emptied title is not an Idea: it is put back
    /// as it was, never saved.
    private func commit() {
        guard hasChanges else { return }
        guard canSave else {
            title = idea.title
            return
        }
        let ideaID = idea.id, newTitle = title, newNotes = notes
        vm.task(in: windowState) { await vm.updateIdea(ideaID: ideaID, title: newTitle, notes: newNotes) }
    }
}
