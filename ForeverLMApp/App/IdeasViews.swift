import SwiftUI
import UniformTypeIdentifiers

// MARK: - The Ideas tab

/// The Ideas tab: what the learner jotted down, newest first, with the field
/// for the next thought at the top (product owner, 2026-09-20: "i can jot down my
/// ideas there and then link relevant research and explorations. i just need
/// a place to jot them down").
///
/// An Idea is a corollary to a Goal: the same kind of sentence, with no date
/// and no commitment yet. Each row carries the things the Idea is linked to
/// — the sources it came from, the chats and Docs that explored it, the Goal
/// it became — and opens them. See docs/ideas-design.md.
///
/// A link to one Idea (`foreverlm://idea/<id>`, in a Doc, a chat or the
/// Reader's Linked References) opens this pane with that Idea's editor up
/// (`StudioViewModel.openIdea`, `IdeaRevealRequest`).
struct IdeasPane: View {
    @Environment(StudioViewModel.self) private var vm
    /// The Studio window the pane is in: only its own requests are answered.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    /// The Idea a followed link asked for, open in its editor.
    @State private var revealedIdea: IdeaRecord?

    var body: some View {
        IdeasHomeView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .studioCenterTabCloseChrome(for: .ideas)
            // `initial`: the link that opened the pane asked before it existed.
            .onChange(of: vm.ideaRevealRequest, initial: true) { _, request in
                answer(request)
            }
            .sheet(item: $revealedIdea) { idea in
                IdeaEditorSheet(idea: idea) { title, notes in
                    Task { await vm.updateIdea(ideaID: idea.id, title: title, notes: notes) }
                }
            }
    }

    /// Opens the editor for a request made in this window, and consumes it,
    /// so the same Idea asked for again opens again; another window's pane
    /// leaves it for that window.
    private func answer(_ request: IdeaRevealRequest?) {
        guard let request, let windowState, request.windowID == windowState.id else { return }
        vm.ideaRevealRequest = nil
        guard let idea = vm.ideas.first(where: { $0.id == request.ideaID }) else { return }
        revealedIdea = idea
    }
}

/// An Idea the Ideas pane should open in its editor: a link to it followed
/// from a Doc, a chat or the Reader's Linked References. Stamped with the
/// window it was followed in, so no other window's pane answers, and with a
/// token, so asking twice for the same Idea is two requests.
struct IdeaRevealRequest: Equatable {
    let ideaID: String
    let windowID: UUID
    let token = UUID()
}

struct IdeasHomeView: View {
    @Environment(StudioViewModel.self) private var vm

    /// Under the Docs tab's Ideas chip (2026-09-29, when Ideas left the rail
    /// for the Artifacts home, which became the Docs tab on 2026-10-06): the
    /// home draws the title and the search, and scrolls, so
    /// the list comes with its jot field but without a header or a scroll
    /// view of its own.
    let isEmbedded: Bool
    /// The home's search: the Ideas whose words or note match.
    let query: String
    /// The home's notebook filter (shell stage 4): the Ideas it keeps; nil
    /// keeps every one.
    let admits: ((IdeaRecord) -> Bool)?
    /// Hears of an idea jotted here, so a list in the Space files it
    /// (`SpaceListPage`).
    let onJotted: ((IdeaRecord) -> Void)?

    /// The next thought, typed at the top of the list. Return saves it.
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    init(
        isEmbedded: Bool = false,
        query: String = "",
        admits: ((IdeaRecord) -> Bool)? = nil,
        onJotted: ((IdeaRecord) -> Void)? = nil
    ) {
        self.isEmbedded = isEmbedded
        self.query = query
        self.admits = admits
        self.onJotted = onJotted
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var bands: (open: [IdeaRecord], archived: [IdeaRecord]) {
        let bands = vm.ideaBands()
        let words = trimmedQuery
        guard !words.isEmpty || admits != nil else { return bands }
        let admits = admits
        let matches: (IdeaRecord) -> Bool = {
            (words.isEmpty
                || $0.title.localizedCaseInsensitiveContains(words)
                || ($0.notes?.localizedCaseInsensitiveContains(words) ?? false))
                && (admits?($0) ?? true)
        }
        return (open: bands.open.filter(matches), archived: bands.archived.filter(matches))
    }

    var body: some View {
        Group {
            if isEmbedded {
                list
            } else {
                ScrollView {
                    list
                        .padding(StudioDesign.Spacing.xLarge)
                        .frame(maxWidth: 940, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .task {
            await vm.loadIdeas()
            // The rows resolve their chips from the loaded library, which
            // the Docs home and the rail may not have asked for yet.
            if !vm.hasLoadedArtifactsOnce { await vm.loadArtifacts() }
            if vm.learningGoals.isEmpty { await vm.loadLearningGoals() }
            if vm.reviewSessionLinks.isEmpty { await vm.loadReviewSessionLinks() }
            await vm.loadResearchDirections()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ideasDidChange)) { _ in
            Task { await vm.loadIdeas() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .researchDirectionsDidChange)) { _ in
            Task { await vm.loadResearchDirections() }
        }
    }

    private var list: some View {
        let bands = bands

        return VStack(alignment: .leading, spacing: StudioDesign.Spacing.xLarge) {
            if !isEmbedded {
                header
            }
            jotField

            if bands.open.isEmpty && bands.archived.isEmpty {
                empty
            } else {
                if !bands.open.isEmpty {
                    VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                        ForEach(bands.open) { idea in
                            IdeaRow(idea: idea)
                        }
                    }
                    .animation(.easeInOut(duration: 0.16), value: bands.open.map(\.id))
                }
                archivedBand(bands.archived)
            }
        }
    }

    /// The title alone: its tagline, "Jotted down now, chased later.", went on
    /// 2026-10-06 (the product owner: "cleaner and fewer buttons and bells and
    /// whistles"); the jot field under it says what the pane is for.
    private var header: some View {
        Text("Ideas")
            .zoomedSystemFont(size: 23, weight: .bold)
    }

    /// The whole point of the tab: one field, always there, Return saves.
    /// No sheet and no button, so a thought is down before it is gone.
    private var jotField: some View {
        HStack(alignment: .top, spacing: StudioDesign.Spacing.small) {
            Image(systemName: "lightbulb")
                .zoomedSystemFont(size: 14)
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
            TextField("Jot an idea\u{2026}", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 15)
                .lineLimit(1...4)
                .focused($draftFocused)
                .onSubmit(jot)
                .accessibilityIdentifier("studio.ideas.jot")
        }
        .padding(StudioDesign.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(draftFocused ? 0.18 : 0.10), lineWidth: 1)
        )
    }

    private func jot() {
        let words = draft
        guard !IdeaRecord.normalizedTitle(words).isEmpty else { return }
        draft = ""
        let onJotted = onJotted
        Task {
            if let idea = await vm.createIdea(title: words) { onJotted?(idea) }
        }
    }

    private var empty: some View {
        Text(trimmedQuery.isEmpty ? "Nothing jotted down yet." : "No matching ideas")
            .zoomedSystemFont(size: 13)
            .foregroundStyle(.secondary)
            .padding(.vertical, StudioDesign.Spacing.small)
            .accessibilityIdentifier("studio.ideas.empty")
    }

    /// Put-away Ideas as one quiet line of titles: there to be found, not to
    /// be worked on. The way back is the row's menu.
    @ViewBuilder
    private func archivedBand(_ ideas: [IdeaRecord]) -> some View {
        if !ideas.isEmpty {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                Text("Archived")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                ForEach(ideas.prefix(8)) { idea in
                    HStack(spacing: StudioDesign.Spacing.small) {
                        Image(systemName: "archivebox")
                            .foregroundStyle(.tertiary)
                        Text(idea.title)
                            .zoomedSystemFont(size: 13)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(idea.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Unarchive") { Task { await vm.setIdeaStatus(ideaID: idea.id, status: .open) } }
                        Divider()
                        Button("Delete", role: .destructive) { Task { await vm.deleteIdea(ideaID: idea.id) } }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studio.ideas.archived")
        }
    }
}

// MARK: - One Idea

/// One Idea: the words, the note when there is one, and a chip for each
/// thing it is linked to. A chip opens what it names; the row itself opens
/// the editor, so the note is one click away. The row takes a source drop
/// the way a Goal's row does, and the drop links the sources to the Idea.
struct IdeaRow: View {
    @Environment(StudioViewModel.self) private var vm
    let idea: IdeaRecord

    @State private var isEditing = false
    @State private var isLinking = false
    @State private var isMakingGoal = false
    @State private var isConfirmingDelete = false
    @State private var isHovering = false
    @State private var isTargeted = false
    @State private var isShowingSources = false
    private let dragVisibility = StudioDragVisibility.shared

    /// The links the loaded library can name, in the kinds' display order;
    /// a link to a record that is gone or not loaded is drawn as nothing.
    private var chips: [(link: IdeaLink, title: String)] {
        IdeaLinkKind.displayOrder.flatMap { kind in
            idea.links
                .filter { $0.kind == kind }
                .compactMap { link in vm.ideaLinkTitle(link).map { (link, $0) } }
        }
    }

    private var canAcceptCurrentDrag: Bool {
        idea.isOpen && ideaCanAcceptCurrentDrag(idea: idea, dragVisibility: dragVisibility)
    }

    var body: some View {
        HStack(alignment: .top, spacing: StudioDesign.Spacing.large) {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                Text(idea.title)
                    .zoomedSystemFont(size: 15)
                    .fixedSize(horizontal: false, vertical: true)
                if let notes = idea.notes {
                    Text(notes)
                        .zoomedSystemFont(size: 13)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                chipRow
                // The canvases that hold it, each opening at its card.
                KnowledgeMapOnCanvasesLine(ref: "idea:\(idea.id)")
            }

            Spacer(minLength: 0)

            // The day it was jotted, under the pointer only (2026-10-06): a
            // date on every row was a column of decoration. Its slot keeps
            // its size, so the words never shift.
            Text(idea.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.tertiary)
                .opacity(isHovering ? 1 : 0)
        }
        .padding(StudioDesign.Spacing.large)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.18 : 0.08), lineWidth: 1)
        )
        .overlay {
            StudioDropZoneOverlay(
                isActive: isTargeted,
                isVisible: canAcceptCurrentDrag,
                title: "Link to \(idea.title)",
                systemImage: "lightbulb",
                cornerRadius: 12,
                inset: 0
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        // The chips inside are Buttons, which win over this gesture.
        .onTapGesture { isEditing = true }
        .onDrop(of: mcpSourceContextDropTypes, isTargeted: Binding(
            get: { isTargeted },
            set: { isTargeted = $0 && canAcceptCurrentDrag }
        )) { providers in
            StudioDragVisibility.shared.endSoon()
            guard idea.isOpen else { return false }
            return NotebookSourceDropHandler.handle(providers: providers, vm: vm, ideaID: idea.id)
        }
        .dropTargetWatchdog($isTargeted)
        .onHover { isHovering = $0 }
        .cursor(.pointingHand)
        .contextMenu {
            Button("Link\u{2026}") { isLinking = true }
            // Only an open Idea is a card on a canvas.
            if idea.isOpen { KnowledgeMapAddToCanvasMenu(refs: ["idea:\(idea.id)"]) }
            // Where it lives (shell stage 4): a link to a notebook, as Link…
            // makes, with the notebooks holding its sources first.
            NotebookFilingMenuItems(
                sourceIDs: idea.links.filter { $0.kind == .source }.map(\.targetID),
                livesIn: { Set(idea.links.filter { $0.kind == .notebook }.map(\.targetID)) },
                add: { notebookID in Task { await vm.addIdea(idea.id, toNotebook: notebookID) } },
                remove: { notebookID in Task { await vm.removeIdea(idea.id, fromNotebook: notebookID) } }
            )
            // A list of ideas in the Space holds it (`SpaceLists`).
            SpaceListMenu(recordID: idea.id, kind: .ideas)
            Button("Make it a goal\u{2026}") { isMakingGoal = true }
            if idea.isOpen {
                Button("Find Directions") { vm.requestDirectionSearch(forIdea: idea) }
            }
            Button("Edit\u{2026}") { isEditing = true }
            Divider()
            if idea.isArchived {
                Button("Unarchive") { Task { await vm.setIdeaStatus(ideaID: idea.id, status: .open) } }
            } else {
                Button("Archive") { Task { await vm.setIdeaStatus(ideaID: idea.id, status: .archived) } }
            }
            Divider()
            Button("Delete\u{2026}", role: .destructive) { isConfirmingDelete = true }
        }
        .sheet(isPresented: $isEditing) {
            IdeaEditorSheet(idea: idea) { title, notes in
                Task { await vm.updateIdea(ideaID: idea.id, title: title, notes: notes) }
            }
        }
        .sheet(isPresented: $isLinking) {
            IdeaLinkPickerSheet(idea: idea)
        }
        .sheet(isPresented: $isMakingGoal) {
            SetGoalSheet(presetTitle: idea.title) { title, deadline, notebookID, artifactID in
                var named = idea
                named.title = title
                Task { await vm.makeGoal(from: named, deadline: deadline, notebookID: notebookID, artifactID: artifactID) }
            }
        }
        .confirmationDialog(
            "Delete \u{201C}\(idea.title)\u{201D}?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await vm.deleteIdea(ideaID: idea.id) }
            }
        } message: {
            Text("What it is linked to stays in your library.")
        }
        // An element of its own that contains the chips. On a plain container
        // the label, identifier and help below were stamped on every element
        // inside, so each chip read as the Idea's title with the row's
        // identifier and hint (2026-09-28); the help is here, below the group,
        // for that reason. A group offers no press, so the row's click is
        // given to it as its action.
        .accessibilityElement(children: .contain)
        .help("Edit the idea")
        .accessibilityIdentifier("studio.ideas.row")
        .accessibilityLabel(idea.title)
        .accessibilityAction { isEditing = true }
    }

    /// The row's links, sources folded: an Idea gathers papers by the dozen,
    /// so its sources sit behind one "N sources" toggle and open beneath it,
    /// while the few chats, Docs, goals and notebooks stay named in the line.
    /// On an open Idea a quiet offer to link something closes the line while
    /// the pointer is over the row, in a slot that keeps its size; it was
    /// drawn on every open row until 2026-10-06. The row's menu has Link… at
    /// all times.
    @ViewBuilder
    private var chipRow: some View {
        let chips = chips
        let sources = chips.filter { $0.link.kind == .source }
        let others = chips.filter { $0.link.kind != .source }
        if !chips.isEmpty || idea.isOpen {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.xSmall) {
                FlowLayout(spacing: StudioDesign.Spacing.xSmall) {
                    if !sources.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { isShowingSources.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .zoomedSystemFont(size: 9, weight: .semibold)
                                    .rotationEffect(.degrees(isShowingSources ? 90 : 0))
                                Label(
                                    sources.count == 1 ? "1 source" : "\(sources.count) sources",
                                    systemImage: IdeaLinkKind.source.symbolName
                                )
                                .zoomedSystemFont(size: 11)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.hoverWash)
                        .help(isShowingSources ? "Hide the linked sources" : "Show the linked sources")
                        .accessibilityIdentifier("studio.ideas.row.sourcesToggle")
                        .accessibilityValue(isShowingSources ? "Expanded" : "Collapsed")
                    }
                    ForEach(others, id: \.link) { chip in
                        linkChip(chip)
                    }
                    DirectionsChip(homeKind: .idea, homeID: idea.id, homeTitle: idea.title) {
                        vm.requestDirectionSearch(forIdea: idea)
                    }
                    if idea.isOpen {
                        Button {
                            isLinking = true
                        } label: {
                            Label(chips.isEmpty ? "Link research or a chat" : "Link", systemImage: "link")
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.hoverWash)
                        .opacity(isHovering ? 1 : 0)
                        .help("Link sources, chats, pages, a goal or a notebook to this idea")
                        .accessibilityIdentifier("studio.ideas.row.linkOffer")
                    }
                }
                if isShowingSources && !sources.isEmpty {
                    FlowLayout(spacing: StudioDesign.Spacing.xSmall) {
                        ForEach(sources, id: \.link) { chip in
                            linkChip(chip)
                        }
                    }
                    .padding(.leading, StudioDesign.Spacing.medium)
                }
            }
        }
    }

    /// A chip opens what it names; its menu opens it in another window or
    /// unlinks it.
    private func linkChip(_ chip: (link: IdeaLink, title: String)) -> some View {
        Button {
            Task { await vm.openIdeaLink(chip.link) }
        } label: {
            Label(chip.title, systemImage: vm.ideaLinkSymbolName(chip.link))
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 260, alignment: .leading)
        }
        .buttonStyle(.hoverWash)
        .help("Open \(chip.title)")
        .contextMenu {
            switch chip.link.kind {
            case .source: OtherWindowSourceMenuItem(sourceID: chip.link.targetID)
            case .artifact: OtherWindowMenuItem(.teamArtifact(chip.link.targetID))
            case .chat: OtherWindowMenuItem(.chat(chip.link.targetID))
            case .goal: OtherWindowMenuItem(.goals)
            case .notebook: OtherWindowMenuItem(.notebook(chip.link.targetID))
            }
            Divider()
            Button("Unlink") {
                Task { await vm.unlinkIdea(ideaID: idea.id, kind: chip.link.kind, targetIDs: [chip.link.targetID]) }
            }
        }
        .accessibilityIdentifier("studio.ideas.row.link")
    }
}

/// Whether the drag in flight is one the Idea's row can take: a source
/// payload the Idea does not already link. The same rule a Goal's row
/// applies (`notebookCanAcceptCurrentDrag`), read against the Idea's links.
func ideaCanAcceptCurrentDrag(idea: IdeaRecord, dragVisibility: StudioDragVisibility) -> Bool {
    if dragVisibility.draggedNotebookID != nil || dragVisibility.isPaneDrag {
        return false
    }
    if dragVisibility.draggedArtifactID != nil || dragVisibility.draggedGoalID != nil {
        return false
    }
    if dragVisibility.draggedGroupName != nil {
        return true
    }
    let draggedIDs = dragVisibility.draggedArticleIds
    guard !draggedIDs.isEmpty else { return dragVisibility.isDragging }
    let linked = Set(idea.linkedIDs(.source))
    return draggedIDs.contains { !linked.contains($0) }
}

// MARK: - Editing one

/// The words and the note. The title is one line; the note is where the
/// rest of the thought goes. Under them, the Idea's Linked References: the
/// Doc blocks that link it (`IdeaLinkedReferencesSection`).
struct IdeaEditorSheet: View {
    let idea: IdeaRecord
    /// The new title and note; the note blank when cleared.
    let save: (String, String) -> Void

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var notes: String
    /// The Doc blocks that link this Idea, read when the sheet opens.
    @State private var linkedReferences: [DocGraphReferenceGroup] = []
    @FocusState private var titleFocused: Bool

    init(idea: IdeaRecord, save: @escaping (String, String) -> Void) {
        self.idea = idea
        self.save = save
        _title = State(initialValue: idea.title)
        _notes = State(initialValue: idea.notes ?? "")
    }

    private var canSave: Bool {
        !IdeaRecord.normalizedTitle(title).isEmpty
    }

    private var hasChanges: Bool {
        title != idea.title || notes != (idea.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
            Text("Idea")
                .zoomedSystemFont(size: 21, weight: .bold)

            TextField("The idea, in a line", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 15)
                .lineLimit(1...3)
                .padding(StudioDesign.Spacing.medium)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .focused($titleFocused)
                .accessibilityIdentifier("studio.ideas.editor.title")

            TextEditor(text: $notes)
                .zoomedSystemFont(size: 13)
                .scrollContentBackground(.hidden)
                .padding(StudioDesign.Spacing.small)
                .frame(minHeight: 140, maxHeight: 280)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Notes")
                            .zoomedSystemFont(size: 13)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, StudioDesign.Spacing.small + 5)
                            .padding(.vertical, StudioDesign.Spacing.small + 8)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("studio.ideas.editor.notes")

            // Nothing at all while nothing links the Idea.
            if !linkedReferences.isEmpty {
                IdeaLinkedReferencesSection(groups: linkedReferences) {
                    // Following a reference is leaving the sheet, not
                    // Cancel: what was typed is kept.
                    if hasChanges, canSave { save(title, notes) }
                    dismiss()
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(title, notes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier("studio.ideas.editor.save")
            }
        }
        .padding(StudioDesign.Spacing.xLarge)
        .frame(width: 480)
        .onAppear { titleFocused = true }
        .task(id: idea.id) { await loadLinkedReferences() }
    }

    /// Reads the Idea's Linked References off the main actor; reading the
    /// graph writes nothing. A failure is said in a toast and draws nothing.
    private func loadLinkedReferences() async {
        do {
            let loaded = try await vm.storage.docGraphLinkedReferences(to: .idea(idea.id), teamID: nil)
            guard !Task.isCancelled else { return }
            // An Idea is linked from Docs' blocks; a group without blocks
            // would be a page that points at it as a whole, which no Doc is.
            linkedReferences = loaded.filter { $0.kind != .idea && !$0.blocks.isEmpty }
        } catch {
            guard !Task.isCancelled else { return }
            vm.showToast("Could not read what links this idea: \(error.localizedDescription)")
        }
    }
}

// MARK: - What links it

/// An Idea's Linked References (docs/notes-graph-design.md): the blocks of
/// the Docs that link this Idea (`foreverlm://idea/<id>`), grouped by Doc,
/// each under its breadcrumbs, the way Roam lists what points at a page. A
/// click opens that Doc at that block; the Doc's title opens it at the top.
/// The editor draws it only when something links the Idea.
struct IdeaLinkedReferencesSection: View {
    let groups: [DocGraphReferenceGroup]
    /// Called before a Doc opens: the sheet keeps what was typed and closes.
    let willOpen: () -> Void

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @State private var listHeight: CGFloat?

    /// The list scrolls past this height, so a much-linked Idea's sheet
    /// still fits the window.
    private static let maximumListHeight: CGFloat = 220
    /// How far a row's hover wash reaches past its text.
    private static let washInset: CGFloat = 3

    private var blockCount: Int {
        groups.reduce(0) { $0 + $1.blocks.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            HStack(spacing: StudioDesign.Spacing.xSmall) {
                Text("Linked References")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                Text("\(blockCount)")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
            }
            .padding(.leading, Self.washInset)
            ScrollView {
                VStack(alignment: .leading, spacing: StudioDesign.Spacing.medium) {
                    ForEach(groups, id: \.id) { group in
                        groupView(group)
                    }
                }
                // Room for the rows' wash, which the scroll view would clip.
                .padding(Self.washInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: listHeight.map { min($0, Self.maximumListHeight) })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.ideas.editor.linkedReferences")
    }

    private func groupView(_ group: DocGraphReferenceGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                open(group, at: nil)
            } label: {
                Label(group.title, systemImage: group.kind == .dailyNote ? "calendar" : "doc.text")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -Self.washInset))
            .help("Open \u{201C}\(group.title)\u{201D}")
            .contextMenu { OtherWindowMenuItem(.doc(group.id)) }

            ForEach(Array(group.blocks.enumerated()), id: \.offset) { _, block in
                Button {
                    open(group, at: block)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        if !block.breadcrumbs.isEmpty {
                            Text(block.breadcrumbs.joined(separator: " \u{203A} "))
                                .zoomedSystemFont(size: 10.5)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Text(block.plainText)
                            .zoomedSystemFont(size: 12)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, StudioDesign.Spacing.large)
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -Self.washInset))
                .help("Open \u{201C}\(group.title)\u{201D} at this block")
                .contextMenu { OtherWindowMenuItem(.doc(group.id)) }
                .accessibilityLabel(block.plainText)
            }
        }
    }

    /// The Doc at the block, in the window the sheet is in.
    private func open(_ group: DocGraphReferenceGroup, at block: DocGraphBlock?) {
        let window = windowState
        let reveal = block.map { DocBlockReveal(blockID: $0.blockID, key: $0.key, plainText: $0.plainText) }
        willOpen()
        Task { await vm.openDoc(group.id, revealing: reveal, in: window) }
    }
}

// MARK: - Linking

/// Everything an Idea can be linked to, by kind, behind one filter field:
/// the open Goals, the Notebooks, the library's sources, the recent chats,
/// and the Docs, Sites and animations. A row toggles its link; the sheet
/// stays open so several can be linked in one visit.
struct IdeaLinkPickerSheet: View {
    let idea: IdeaRecord

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var queryFocused: Bool

    /// The Idea as it reads now, so a toggle shows at once.
    private var current: IdeaRecord {
        vm.ideas.first(where: { $0.id == idea.id }) ?? idea
    }

    struct Choice: Identifiable, Equatable {
        let kind: IdeaLinkKind
        let id: String
        let title: String
        let symbolName: String
    }

    struct Group: Identifiable, Equatable {
        let kind: IdeaLinkKind
        let choices: [Choice]
        var id: IdeaLinkKind { kind }
        var title: String {
            switch kind {
            case .source: return "Sources"
            case .artifact: return "Pages, Sites and Animations"
            case .chat: return "Chats"
            case .goal: return "Goals"
            case .notebook: return "Notebooks"
            }
        }
    }

    /// Without a query: the open Goals, the Notebooks, and the newest twenty
    /// of each of the long lists, so the sheet opens to something. With one:
    /// every match across the library.
    private var groups: [Group] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !needle.isEmpty
        func matches(_ title: String) -> Bool {
            !searching || title.localizedCaseInsensitiveContains(needle)
        }
        func capped<T>(_ items: [T]) -> [T] {
            searching ? items : Array(items.prefix(20))
        }
        let goals = vm.allGoals
            .filter { !$0.isDone && !$0.isArchived && matches($0.title) }
            .map { Choice(kind: .goal, id: $0.id, title: $0.title, symbolName: IdeaLinkKind.goal.symbolName) }
        let notebooks = vm.notebooks
            .filter { matches($0.title) }
            .map { Choice(kind: .notebook, id: $0.id, title: $0.title, symbolName: IdeaLinkKind.notebook.symbolName) }
        let sources = capped(
            vm.activeArticles
                .filter { vm.isVisibleInRecordingMode($0) && matches(vm.displayTitle(for: $0)) }
                .sorted { $0.dateAdded > $1.dateAdded }
        ).map { Choice(kind: .source, id: $0.id, title: vm.displayTitle(for: $0), symbolName: $0.sourceType.symbolName) }
        let chats = capped(
            vm.reviewSessionLinks
                .filter { $0.hiddenAt == nil && $0.teamID == nil && vm.isVisibleInRecordingMode($0) && matches($0.title) }
                .sorted { $0.createdAt > $1.createdAt }
        ).map { Choice(kind: .chat, id: $0.id, title: $0.title, symbolName: IdeaLinkKind.chat.symbolName) }
        let artifacts = capped(
            vm.artifacts
                .filter { !$0.isHidden && !$0.isArchived && !vm.isAudioOverview($0) && matches($0.title) }
                .sorted { $0.updatedAt > $1.updatedAt }
        ).map { Choice(kind: .artifact, id: $0.id, title: $0.title, symbolName: $0.goalRowSymbolName) }
        return [
            Group(kind: .goal, choices: goals),
            Group(kind: .notebook, choices: notebooks),
            Group(kind: .source, choices: sources),
            Group(kind: .chat, choices: chats),
            Group(kind: .artifact, choices: artifacts),
        ].filter { !$0.choices.isEmpty }
    }

    var body: some View {
        let current = current
        let groups = groups
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.xSmall) {
                Text("Link to this idea")
                    .zoomedSystemFont(size: 21, weight: .bold)
                Text(current.title)
                    .zoomedSystemFont(size: 13)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            TextField("Filter goals, notebooks, sources, chats and pages", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .accessibilityIdentifier("studio.ideas.picker.filter")

            if groups.isEmpty {
                Text("Nothing matches.")
                    .zoomedSystemFont(size: 13)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .accessibilityIdentifier("studio.ideas.picker.empty")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: StudioDesign.Spacing.medium) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .zoomedSystemFont(size: 11, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, StudioDesign.Spacing.small)
                                ForEach(group.choices) { choice in
                                    row(choice, linked: current.links.contains { $0.kind == choice.kind && $0.targetID == choice.id })
                                }
                            }
                        }
                    }
                    .padding(.vertical, StudioDesign.Spacing.xSmall)
                }
                .frame(minHeight: 200, maxHeight: 380)
            }

            HStack {
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("studio.ideas.picker.done")
            }
        }
        .padding(StudioDesign.Spacing.xLarge)
        .frame(width: 480)
        .onAppear { queryFocused = true }
        .task {
            if !vm.hasLoadedArtifactsOnce { await vm.loadArtifacts() }
            if vm.reviewSessionLinks.isEmpty { await vm.loadReviewSessionLinks() }
        }
    }

    private func row(_ choice: Choice, linked: Bool) -> some View {
        Button {
            Task {
                if linked {
                    await vm.unlinkIdea(ideaID: idea.id, kind: choice.kind, targetIDs: [choice.id])
                } else {
                    await vm.linkIdea(ideaID: idea.id, kind: choice.kind, targetIDs: [choice.id])
                }
            }
        } label: {
            HStack(spacing: StudioDesign.Spacing.small) {
                Image(systemName: choice.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(choice.title)
                    .zoomedSystemFont(size: 13)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if linked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, StudioDesign.Spacing.small)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash)
        .accessibilityIdentifier("studio.ideas.picker.row")
        .accessibilityLabel(choice.title)
        .accessibilityValue(linked ? "Linked" : "")
    }
}
