import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The three tabs at the foot of a notebook, Gemini Notebook's words.
enum MobileNotebookTab: String, CaseIterable, Hashable {
    case sources
    case chat
    case studio

    var title: String {
        switch self {
        case .sources: return "Sources"
        case .chat: return "Chat"
        case .studio: return "Studio"
        }
    }

    var symbolName: String {
        switch self {
        case .sources: return "books.vertical"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .studio: return "sparkles"
        }
    }
}

/// One notebook on the phone (docs/notebooks-design.md, "iPhone"): its
/// sources with the boxes that pick what its chat reads, its chats, and what
/// was made from it, behind a bottom bar of Sources · Chat · Studio — on a
/// wide screen (an iPad, an iPhone Duo opened), the three side by side
/// (`MobileNotebookColumns`). Pushed
/// over Home — from a card, a link, or the cold launch's return to the
/// notebook last worked in — and the Reader is pushed inside it, so Back
/// always comes back here.
struct MobileNotebookScreen: View {
    let notebookID: String

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var selection = MobileNotebookChatSelectionStore()
    /// The notebook's open chat and its composer state; kept here so switching
    /// tabs never loses a conversation under way.
    @StateObject private var chatSession = MobileNotebookChatSession()
    @State private var tab: MobileNotebookTab?
    @State private var hidesTabBar = false
    @State private var showsAddSources = false
    @State private var showsContextPicker = false
    @State private var showsShare = false
    @State private var editor: MobileNotebookEditorDestination?
    @State private var confirmsArchive = false
    @State private var confirmsDelete = false

    private var notebook: MobileCloudNotebook? {
        vm.notebooks.first { $0.id == notebookID }
    }

    /// Chat when the notebook has sources to ask about, else Sources (Gemini
    /// also opens on Chat).
    private func openingTab(for notebook: MobileCloudNotebook) -> MobileNotebookTab {
        vm.notebookSources(in: notebook).isEmpty ? .sources : .chat
    }

    var body: some View {
        Group {
            if let notebook {
                content(notebook)
            } else {
                missing
            }
        }
        .navigationTitle(notebook?.title ?? "Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Remembered on this phone, so the next cold launch reopens here.
            // A local note, not a write to the notebook (opening is a read).
            MobileLastNotebookStore.standard.remember(notebookID)
            // Home's Recent counts the notebooks opened here, as the Mac's
            // rail counts those opened in a window.
            MobileNotebookRailStore.shared.noteOpened(notebookID)
        }
        .task(id: notebookID) {
            await selection.load(notebookID: notebookID)
        }
    }

    @ViewBuilder
    private func content(_ notebook: MobileCloudNotebook) -> some View {
        let current = tab ?? openingTab(for: notebook)
        Group {
            switch current {
            case .sources:
                MobileNotebookSourcesTab(
                    notebook: notebook,
                    selection: selection,
                    onAddSources: { showsAddSources = true }
                )
            case .chat:
                MobileNotebookChatTab(
                    notebook: notebook,
                    selection: selection,
                    session: chatSession,
                    hidesTabBar: $hidesTabBar,
                    onAddSources: { showsAddSources = true }
                )
            case .studio:
                MobileNotebookStudioTab(notebook: notebook, selection: selection)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !hidesTabBar {
                MobileNotebookTabBar(selection: Binding(
                    get: { current },
                    set: { tab = $0 }
                ))
            }
        }
        // A wide screen (an iPad, an iPhone Duo opened) draws the three side
        // by side instead, as the Mac does (`MobileNotebookColumns`); a bar
        // hidden for the keyboard comes back when the tabs do.
        .mobileNotebookColumns(
            notebook: notebook,
            selection: selection,
            session: chatSession,
            onAddSources: { showsAddSources = true },
            onLayoutChange: { hidesTabBar = false }
        )
        .toolbar {
            // Share at the top right, the NotebookLM place for it, beside ⋯.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showsShare = true
                } label: {
                    Label("Share", systemImage: "person.badge.plus")
                }
                .accessibilityIdentifier("notebook.share")
                notebookMenu(notebook)
            }
        }
        .sheet(isPresented: $showsAddSources) {
            MobileNotebookAddSourcesSheet(notebook: notebook, selection: selection)
        }
        .sheet(isPresented: $showsShare) {
            // A notebook is shared by moving it into a space (D21, §5.3).
            MobileSpaceShareSheet(notebook: notebook, sourceCount: notebook.approvedSourceCount)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsContextPicker) {
            MobileRelatedNotebooksPickerSheet(notebook: notebook, selection: selection)
        }
        .sheet(item: $editor) { destination in
            MobileNotebookEditorSheet(mode: destination.mode)
        }
        .confirmationDialog("Archive this Notebook?", isPresented: $confirmsArchive) {
            Button("Archive Notebook", role: .destructive) {
                Task {
                    if await vm.archiveNotebook(id: notebook.id) { dismiss() }
                }
            }
        }
        .confirmationDialog("Delete its chats too?", isPresented: $confirmsDelete) {
            Button("Delete Notebook, Keep Chats", role: .destructive) {
                Task {
                    if await vm.deleteNotebook(id: notebook.id, deleteLinkedChats: false) { dismiss() }
                }
            }
            Button("Delete Notebook and Chats", role: .destructive) {
                Task {
                    if await vm.deleteNotebook(id: notebook.id, deleteLinkedChats: true) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(notebook.title) will be deleted. Keep its chats ungrouped in Chats, or delete them too. Its sources will remain available.")
        }
    }

    private func notebookMenu(_ notebook: MobileCloudNotebook) -> some View {
        Menu {
            Button("Add Sources", systemImage: "plus") {
                showsAddSources = true
            }
            // The name, the card line and the instructions chats follow.
            Button("Edit Notebook", systemImage: "pencil") {
                editor = .edit(notebook)
            }
            // Another notebook's sources for this one's chats, linked and
            // put in at once; its group's × takes it out again.
            Button("Add a Notebook to Context", systemImage: "folder.badge.plus") {
                showsContextPicker = true
            }
            .disabled(!MobileNotebookContextPicker.hasCandidates(for: notebook, in: vm.notebooks))
            Divider()
            Button("Archive Notebook", systemImage: "archivebox") {
                confirmsArchive = true
            }
            Button("Delete Notebook", systemImage: "trash", role: .destructive) {
                confirmsDelete = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Notebook actions")
        .accessibilityIdentifier("notebook.menu")
    }

    /// A link to a notebook this phone does not have (not synced yet, or
    /// archived or deleted on another device).
    private var missing: some View {
        ContentUnavailableView {
            Label("Notebook Not Here", systemImage: MobileNotebookGlyph.symbolName)
        } description: {
            Text(vm.syncStatus == nil
                ? "This notebook is not on this iPhone. It may have been archived or deleted on another device."
                : "This notebook has not synced to this iPhone yet.")
        }
    }
}

/// The notebook's bottom bar: Sources · Chat · Studio. Drawn by the notebook
/// itself, so a Reader pushed over it keeps its own bottom toolbar.
struct MobileNotebookTabBar: View {
    @Binding var selection: MobileNotebookTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MobileNotebookTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbolName)
                            .font(.body.weight(selection == tab ? .semibold : .regular))
                        Text(tab.title)
                            .font(.caption2.weight(selection == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("notebook.tab.\(tab.rawValue)")
            }
        }
        .padding(.top, MobileDesign.Spacing.xSmall)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notebook.tabBar")
    }
}

// MARK: - Chat checkboxes

/// One row's box for the notebook's chat.
struct MobileSourceChatTick {
    let isOn: Bool
    let isEnabled: Bool
    let toggle: () -> Void
}

/// A box that ticks, clears, or — standing for several sources — shows some
/// ticked. A full 44-point target around a small mark.
struct MobileChatTickBox: View {
    let state: MobileNotebookTickState
    let label: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state == .unchecked ? Color.secondary : Color.accentColor)
                .frame(
                    width: MobileDesign.Metrics.minimumTouchTarget,
                    height: MobileDesign.Metrics.minimumTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private var symbolName: String {
        switch state {
        case .checked: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .unchecked: return "square"
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .checked: return "In chat"
        case .mixed: return "Some in chat"
        case .unchecked: return "Not in chat"
        }
    }
}

/// A library row's + in a notebook's Sources search.
struct MobileSourceNotebookAdd {
    let isAdding: Bool
    let isEnabled: Bool
    let add: () -> Void
}

/// The + that adds a library source to the notebook, in the box's place and
/// on the same 44-point target; a spinner while the add is saving.
struct MobileNotebookAddButton: View {
    let add: MobileSourceNotebookAdd
    let label: String

    var body: some View {
        Group {
            if add.isAdding {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(label)
            } else {
                Button(action: add.add) {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(add.isEnabled ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!add.isEnabled)
                .accessibilityLabel(label)
            }
        }
        .frame(
            width: MobileDesign.Metrics.minimumTouchTarget,
            height: MobileDesign.Metrics.minimumTouchTarget
        )
    }
}

/// The notebook's chat checkboxes on the phone: the member's two synced rows
/// the Mac keeps (`NotebookChatSelection`) — the unticked sources
/// (`notebook.chatExcluded.<notebookID>`) and the context notebooks put in
/// (`notebook.chatContextNotebooks.<notebookID>`) — read when the notebook
/// opens, and changed by reading both again, applying the Mac's rule
/// (`MobileNotebookChatSelection.applying`, `NotebookChatContext`) and
/// writing only a row that changed, the unticked one first — an empty row is
/// removed. Writes run one after another, in the order the boxes were
/// tapped. The phone keeps no copy of its own across launches: the rows are
/// the truth.
@MainActor
final class MobileNotebookChatSelectionStore: ObservableObject {
    /// Reads a row by key; nil when there is no row.
    typealias Read = @Sendable (String) async throws -> [String]?
    /// Writes a row by key; an empty value removes it.
    typealias Write = @Sendable (String, [String]) async throws -> Void
    typealias Selection = NotebookChatContext.Selection

    /// The unticked sources, nil until the rows have been read.
    @Published private(set) var excluded: Set<String>?
    /// The context notebooks put into the chats, nil until the rows have
    /// been read.
    @Published private(set) var contextNotebookIDs: Set<String>?
    @Published private(set) var readError: String?
    @Published private(set) var writeError: String?

    private let read: Read
    private let write: Write
    private var notebookID: String?
    private var writeChain: Task<Void, Never>?

    /// This member's NotebookState, as the replica holds it now with the phone's pending writes over it
    /// (§5.6, D52).
    nonisolated static let cloudRead: Read = { key in
        try await MobileNotebookRows.stringArrays([key], writer: MobileRecordWriter.required())[key]
    }

    /// NotebookState through the phone's writer: an untick names the Entry's stamps, a tick clears it.
    nonisolated static let cloudWrite: Write = { key, value in
        try await MobileNotebookRows.write(key, ids: value, writer: MobileRecordWriter.required())
    }

    init(read: @escaping Read = MobileNotebookChatSelectionStore.cloudRead,
         write: @escaping Write = MobileNotebookChatSelectionStore.cloudWrite) {
        self.read = read
        self.write = write
    }

    /// One notebook's two rows, read now, for a caller with no store of its
    /// own (Home's Talk).
    nonisolated static func readSelection(notebookID: String) async throws -> Selection {
        try await readRows(notebookID: notebookID, read: cloudRead)
    }

    /// Both rows at once; an absent row reads as empty.
    private nonisolated static func readRows(notebookID: String, read: Read) async throws -> Selection {
        async let excluded = read(MobileNotebookChatSelection.preferenceKey(notebookID: notebookID))
        async let context = read(MobileNotebookChatSelection.contextNotebooksKey(notebookID: notebookID))
        return Selection(excluded: Set(try await excluded ?? []), contextNotebookIDs: Set(try await context ?? []))
    }

    var isLoaded: Bool { current != nil }

    /// The two rows as last read or written; nil until both were read.
    var current: Selection? {
        guard let excluded, let contextNotebookIDs else { return nil }
        return Selection(excluded: excluded, contextNotebookIDs: contextNotebookIDs)
    }

    /// `notebook`'s boxes as the rows stand; nil until they were read.
    func board(for notebook: MobileCloudNotebook) -> MobileNotebookChatBoard? {
        current.map { MobileNotebookChatBoard(notebook: notebook, selection: $0) }
    }

    /// What a new chat in `notebook`, a voice conversation on it or Review me
    /// reads: its own sources and the context notebooks put in, minus the
    /// unticked; nothing until the rows were read.
    func chatSourceIDs(of notebook: MobileCloudNotebook) -> [String] {
        guard let current else { return [] }
        return MobileNotebookChatSelection.chatSourceIDs(of: notebook, selection: current)
    }

    func load(notebookID: String) async {
        if self.notebookID != notebookID {
            self.notebookID = notebookID
            excluded = nil
            contextNotebookIDs = nil
        }
        do {
            let rows = try await Self.readRows(notebookID: notebookID, read: read)
            guard self.notebookID == notebookID else { return }
            show(rows)
            readError = nil
        } catch {
            guard self.notebookID == notebookID else { return }
            readError = error.localizedDescription
        }
    }

    /// Ticks (`inChat`) or unticks `sourceIDs` in `notebook`'s chats; `through`
    /// names the context notebook whose group the row is in.
    func set(_ sourceIDs: [String], inChat: Bool, through contextNotebookID: String? = nil, in notebook: MobileCloudNotebook) async {
        guard !sourceIDs.isEmpty || inChat else { return }
        await apply(.sources(sourceIDs, inChat: inChat, through: contextNotebookID), to: notebook)
    }

    /// A context notebook's own box: puts one that is out into `notebook`'s
    /// chats as it was left, ticks every source of one already in, or takes
    /// it out (`NotebookChatContext.settingContextNotebooks`).
    func setContextNotebooks(_ notebookIDs: [String], inChat: Bool, in notebook: MobileCloudNotebook) async {
        await apply(.contextNotebooks(notebookIDs, inChat: inChat), to: notebook)
    }

    /// Select all: every source `notebook`'s chats draw on ticked, or unticked.
    func setAll(inChat: Bool, in notebook: MobileCloudNotebook) async {
        await apply(.all(inChat: inChat), to: notebook)
    }

    func apply(_ change: MobileNotebookChatSelection.Change, to notebook: MobileCloudNotebook) async {
        await apply(
            change,
            notebookID: notebook.id,
            own: MobileNotebookChatSelection.own(of: notebook),
            linked: MobileNotebookChatSelection.linked(of: notebook)
        )
    }

    /// One change to `notebookID`'s rows, against its own sources (`own`) and
    /// context notebooks (`linked`) as they stand. The boxes move at once;
    /// the rows are then read again, changed and written, and the boxes show
    /// what was written (or, when a write failed, the rows as they stand).
    func apply(
        _ change: MobileNotebookChatSelection.Change,
        notebookID: String,
        own: [String],
        linked: [NotebookChatContext.ContextNotebook]
    ) async {
        let before = self.notebookID == notebookID ? current : nil
        if let before {
            show(MobileNotebookChatSelection.stored(
                MobileNotebookChatSelection.applying(change, own: own, linked: linked, to: before),
                own: own,
                linked: linked
            ))
        }
        await enqueue { store in
            await store.commit(change, notebookID: notebookID, own: own, linked: linked, before: before)
        }
    }

    private func commit(
        _ change: MobileNotebookChatSelection.Change,
        notebookID: String,
        own: [String],
        linked: [NotebookChatContext.ContextNotebook],
        before: Selection?
    ) async {
        let excludedKey = MobileNotebookChatSelection.preferenceKey(notebookID: notebookID)
        let contextKey = MobileNotebookChatSelection.contextNotebooksKey(notebookID: notebookID)
        do {
            let rows = try await Self.readRows(notebookID: notebookID, read: read)
            let next = MobileNotebookChatSelection.stored(
                MobileNotebookChatSelection.applying(change, own: own, linked: linked, to: rows),
                own: own,
                linked: linked
            )
            // The unticked row first: a context notebook put in with one
            // source never reads all of them for want of the second write.
            if next.excluded != rows.excluded {
                try await write(excludedKey, next.excluded.sorted())
            }
            if next.contextNotebookIDs != rows.contextNotebookIDs {
                try await write(contextKey, next.contextNotebookIDs.sorted())
            }
            if self.notebookID == notebookID {
                show(next)
                writeError = nil
            }
        } catch {
            guard self.notebookID == notebookID else { return }
            writeError = "The change could not be saved: \(error.localizedDescription)"
            // The boxes show the rows as they stand, or as they were before
            // the tap when even those cannot be read.
            if let rows = try? await Self.readRows(notebookID: notebookID, read: read) {
                show(rows)
            } else if let before {
                show(before)
            }
        }
    }

    func clearWriteError() {
        writeError = nil
    }

    /// A source arrives ticked where it was added (the Mac's
    /// `NotebookChatSelection.arrivalsToTick`): an untick left in the row from
    /// when it last left the notebook does not outlive its return. The view
    /// model's add has already taken the arrivals out of the row
    /// (`MobileAudioReviewViewModel.addSources`, every route on the phone);
    /// this brings the boxes on screen along, reading the row again and
    /// writing it only if it still names them. Only the unticked row: a
    /// source the notebook gained puts no context notebook in.
    func tickArrivals(_ sourceIDs: [String], in grown: MobileCloudNotebook?) async {
        guard let grown, !sourceIDs.isEmpty else { return }
        let notebookID = grown.id
        await enqueue { store in
            await store.commitArrivals(sourceIDs, notebookID: notebookID)
        }
    }

    private func commitArrivals(_ sourceIDs: [String], notebookID: String) async {
        let key = MobileNotebookChatSelection.preferenceKey(notebookID: notebookID)
        do {
            let current = Set(try await read(key) ?? [])
            let next = MobileNotebookChatSelection.afterArrivals(current, arriving: sourceIDs)
            if Set(next) != current {
                try await write(key, next)
            }
            if self.notebookID == notebookID {
                excluded = Set(next)
                writeError = nil
            }
        } catch {
            guard self.notebookID == notebookID else { return }
            writeError = "The change could not be saved: \(error.localizedDescription)"
        }
    }

    /// Runs `work` after every change already queued, in tap order.
    private func enqueue(_ work: @escaping @MainActor (MobileNotebookChatSelectionStore) async -> Void) async {
        let previous = writeChain
        let next = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
        writeChain = next
        await next.value
    }

    private func show(_ rows: Selection) {
        if excluded != rows.excluded { excluded = rows.excluded }
        if contextNotebookIDs != rows.contextNotebookIDs { contextNotebookIDs = rows.contextNotebookIDs }
    }
}

// MARK: - Context notebooks

/// Putting another notebook into a notebook's context from the phone, and
/// taking one out (docs/notebooks-design.md, "iPhone"; the Mac's
/// `addContextNotebook` and `takeContextNotebookOut`). The link is the
/// notebook's own, on its record, written first; being in its chats is the
/// member's row, written once the link is saved.
@MainActor
enum MobileNotebookContextLinks {
    /// Add a Notebook to Context: links `candidate` after the notebooks this
    /// one links to and puts it into its chats in one step, its sources'
    /// boxes as they were (`NotebookChatContext.puttingIn`). One already
    /// linked is only put in. False when the link was not saved (the error
    /// bar says why).
    static func add(
        _ candidate: MobileCloudNotebook,
        to notebook: MobileCloudNotebook,
        vm: MobileAudioReviewViewModel,
        selection: MobileNotebookChatSelectionStore
    ) async -> Bool {
        guard candidate.id != notebook.id else { return false }
        let before = vm.notebooks.first { $0.id == notebook.id } ?? notebook
        if !before.relatedNotebookIDs.contains(candidate.id) {
            guard await vm.linkContextNotebook(candidate.id, toNotebookID: notebook.id) else { return false }
        }
        // The notebook as it stands now; the link just saved counts even
        // before the catalog's next pass has it.
        let after = vm.notebooks.first { $0.id == notebook.id } ?? before
        var linked = MobileNotebookChatSelection.linked(of: after)
        if !linked.contains(where: { $0.id == candidate.id }) {
            linked.append(NotebookChatContext.ContextNotebook(id: candidate.id, sourceIDs: candidate.poolSourceIDs))
        }
        await selection.apply(
            .putIn([candidate.id]),
            notebookID: notebook.id,
            own: MobileNotebookChatSelection.own(of: after),
            linked: linked
        )
        return true
    }

    /// Take Out of Context: unlinks `contextNotebookID` from the notebook and
    /// drops it from the chats' row, the one place this phone takes an id out
    /// of that row; the unticks of sources only it held go with it.
    static func takeOut(
        _ contextNotebookID: String,
        of notebook: MobileCloudNotebook,
        vm: MobileAudioReviewViewModel,
        selection: MobileNotebookChatSelectionStore
    ) async {
        guard await vm.unlinkContextNotebook(contextNotebookID, fromNotebookID: notebook.id) else { return }
        let after = vm.notebooks.first { $0.id == notebook.id } ?? notebook
        await selection.apply(
            .contextNotebooks([contextNotebookID], inChat: false),
            notebookID: notebook.id,
            own: MobileNotebookChatSelection.own(of: after),
            linked: MobileNotebookChatSelection.linked(of: after).filter { $0.id != contextNotebookID }
        )
    }
}

/// A context notebook's row at the head of its group, under the notebook's
/// own sources: the disclosure that shows its sources, "From Aging ·
/// 12 sources", its box — in the chats or out, mixed while some of its
/// sources are unticked — and, where the links can be changed, the × that
/// takes it out of context.
struct MobileContextNotebookHeader: View {
    let group: MobileNotebookContextGroup
    let state: MobileNotebookTickState
    let isEnabled: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onTick: () -> Void
    var onTakeOut: (() -> Void)? = nil

    private var countLabel: String {
        group.sources.count == 1 ? "1 source" : "\(group.sources.count) sources"
    }

    var body: some View {
        let title = NotebookTitle(group.notebook.title)
        let name = title.text.isEmpty ? "Untitled notebook" : title.text
        HStack(spacing: MobileDesign.Spacing.xSmall) {
            // Nothing to show while none of its sources is on this phone.
            Button {
                if !group.sources.isEmpty { onToggleExpanded() }
            } label: {
                HStack(spacing: MobileDesign.Spacing.small) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(group.sources.isEmpty ? 0 : 1)
                        .accessibilityHidden(true)
                    MobileNotebookIconView(notebookID: group.notebook.id, size: 22, cornerRadius: 5) {
                        Text(title.displayIcon)
                            .font(.body)
                    }
                    .accessibilityHidden(true)
                    (Text("From \(name)").fontWeight(.semibold)
                        + Text(" · \(countLabel)").foregroundStyle(.secondary))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, minHeight: MobileDesign.Metrics.minimumTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("From \(name), \(countLabel)")
            .accessibilityValue(group.sources.isEmpty ? "" : (isExpanded ? "Expanded" : "Collapsed"))
            .accessibilityIdentifier("notebook.context.group")

            MobileChatTickBox(
                state: state,
                label: "Include \(name) in chat",
                isEnabled: isEnabled,
                action: onTick
            )
            .accessibilityIdentifier("notebook.context.tick")

            if let onTakeOut {
                Button(action: onTakeOut) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: MobileDesign.Metrics.minimumTouchTarget,
                            height: MobileDesign.Metrics.minimumTouchTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Take \(name) out of context")
                .accessibilityIdentifier("notebook.context.takeOut")
            }
        }
    }
}

// MARK: - Library search

/// The library half of a notebook's searches — the Sources tab's "In your
/// library" and the Add sources sheet — after `MobileNotebookSourceSearch`:
/// the words' matches, then, when they find few, the library ranked by
/// meaning on the device, after a short pause in typing and off the main
/// actor (the first ranking embeds every title once).
@MainActor
final class MobileNotebookLibrarySearch: ObservableObject {
    @Published private(set) var meaning = MobileNotebookSourceSearch.Meaning()
    @Published private(set) var isRankingByMeaning = false

    func matches(
        in candidates: [MobileCloudSource],
        query: String,
        groupTitle: (MobileCloudSource) -> String?
    ) -> [MobileCloudSource] {
        MobileNotebookSourceSearch.libraryMatches(
            in: candidates,
            query: query,
            meaning: meaning,
            groupTitle: groupTitle
        )
    }

    /// Ranks `candidates` by meaning for a query the words found little for.
    /// Run from `.task(id: query)`, so a newer query cancels it.
    func rankByMeaningIfNeeded(
        query: String,
        in candidates: [MobileCloudSource],
        groupTitle: (MobileCloudSource) -> String?
    ) async {
        guard MobileNotebookSourceSearch.needsMeaning(in: candidates, query: query, groupTitle: groupTitle) else {
            isRankingByMeaning = false
            return
        }
        // Searching from the first moment, so the pause before the meaning
        // search never reads as "No Results".
        isRankingByMeaning = true
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let ranked = await MobileSemanticSourceSearch.search(for: query, in: candidates, limit: 20)
        guard !Task.isCancelled else { return }
        meaning = MobileNotebookSourceSearch.Meaning(query: query, sources: ranked)
        isRankingByMeaning = false
    }
}

// MARK: - Sources tab

/// The notebook's sources: "13 sources · 9 in chat", with Select all beside
/// it while some source is unticked, then the sources by type, each with its
/// box for the chat, then each notebook it links to as a group (its context
/// notebooks: "From Aging · 12 sources", the group's box, the × that takes it
/// out of context, and its sources with their boxes while open). Add sources
/// is the navigation bar's +; Scan Pages and Add a Notebook to Context are
/// in Add Sources and the notebook's ⋯ (2026-10-06, the product owner: "cleaner and
/// fewer buttons and bells and whistles"). A row opens the Reader inside the
/// notebook; its swipe listens, talks, or removes it from the notebook (a
/// group's rows are not the notebook's to remove). The search reaches past
/// the notebook into the whole library (`MobileNotebookSourceSearch`): the
/// notebook's matches, then the library's, each with a + that adds it to the
/// notebook. Opening a library row reads it in the notebook without adding it.
struct MobileNotebookSourcesTab: View {
    let notebook: MobileCloudNotebook
    @ObservedObject var selection: MobileNotebookChatSelectionStore
    let onAddSources: () -> Void

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @StateObject private var library = MobileNotebookLibrarySearch()
    @State private var query = ""
    /// Library sources whose + is saving.
    @State private var adding = Set<String>()
    /// The context notebooks whose sources are shown, on this screen only.
    @State private var openGroups = Set<String>()

    private var sources: [MobileCloudSource] {
        vm.notebookSources(in: notebook)
    }

    private var isSearching: Bool {
        !MobileSourceListSearch.terms(in: query).isEmpty
    }

    private var libraryCandidates: [MobileCloudSource] {
        MobileNotebookSourceSearch.libraryCandidates(vm.allSources, notListedIn: sources, held: notebook.sourceIDs)
    }

    var body: some View {
        let board = selection.board(for: notebook)
        let groups = vm.contextNotebookGroups(in: notebook)
        List {
            if isSearching {
                searchResults(board: board)
            } else {
                Section {
                    header(board: board, groups: groups)
                    if let message = selection.readError {
                        errorRow(message, retry: { Task { await selection.load(notebookID: notebook.id) } })
                    }
                    if let message = selection.writeError {
                        errorRow(message, retry: nil)
                    }
                }

                if sources.isEmpty {
                    Section {
                        Text(notebook.sourceIDs.isEmpty
                            ? "No sources yet"
                            : "Its sources haven't synced to this iPhone yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // A type's name alone over its rows, as the Mac's
                    // Library groups them; the count line above counts.
                    ForEach(MobileSourceTypeGrouping.groups(for: sources), id: \.label) { group in
                        Section {
                            ForEach(group.sources) { source in
                                row(source, board: board)
                            }
                        } header: {
                            sectionHeader(group.label)
                        }
                    }
                }

                ForEach(groups) { group in
                    contextSection(group, board: board)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search your library")
        .task(id: query) {
            await library.rankByMeaningIfNeeded(query: query, in: libraryCandidates, groupTitle: vm.collections.groupTitle(of:))
        }
        .refreshable {
            await vm.load()
            await selection.load(notebookID: notebook.id)
        }
        .toolbar {
            // Add sources, the tab's one action, on the bar beside Share and
            // the ⋯ (whose Add Sources it repeats); its sheet holds Scan
            // Pages, Photos, Upload PDF… and a pasted link.
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onAddSources) {
                    Label("Add sources", systemImage: "plus")
                }
                .accessibilityIdentifier("notebook.sources.add")
            }
        }
    }

    /// While there are words in the search: the notebook's matches, then the
    /// library's.
    @ViewBuilder
    private func searchResults(board: MobileNotebookChatBoard?) -> some View {
        let found = MobileNotebookSourceSearch.sections(
            notebook: sources,
            candidates: libraryCandidates,
            query: query,
            meaning: library.meaning,
            groupTitle: vm.collections.groupTitle(of:)
        )
        // A + ticks what it adds, so a failed write shows here too.
        if selection.writeError != nil || selection.readError != nil {
            Section {
                if let message = selection.readError {
                    errorRow(message, retry: { Task { await selection.load(notebookID: notebook.id) } })
                }
                if let message = selection.writeError {
                    errorRow(message, retry: nil)
                }
            }
        }
        if found.inNotebook.isEmpty, found.inLibrary.isEmpty, !library.isRankingByMeaning {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
        } else {
            if !found.inNotebook.isEmpty {
                Section {
                    ForEach(found.inNotebook) { source in
                        row(source, board: board)
                    }
                } header: {
                    sectionHeader("In this notebook")
                }
            }
            if !found.inLibrary.isEmpty || library.isRankingByMeaning {
                Section {
                    ForEach(found.inLibrary) { source in
                        libraryRow(source)
                    }
                    if library.isRankingByMeaning {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Searching your library")
                    }
                } header: {
                    sectionHeader("In your library")
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .textCase(nil)
    }

    /// "13 sources · 9 in chat", and Select all with its box while some
    /// source is unticked. While every source is ticked, which is how a
    /// notebook starts, the line stands alone (2026-10-06; the Mac draws it
    /// then only under the pointer); the chat's Sources sheet keeps Select
    /// all at all times, to clear every box.
    private func header(board: MobileNotebookChatBoard?, groups: [MobileNotebookContextGroup]) -> some View {
        let tally = MobileNotebookChatTally(board: board, own: sources, groups: groups)
        return HStack(spacing: MobileDesign.Spacing.small) {
            Text(tally.sourcesLine(own: sources.count))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("notebook.sources.count")
            Spacer(minLength: 0)
            if tally.isLoaded, tally.hasRows(own: sources.count), tally.state != .checked {
                Text("Select all")
                    .font(.subheadline)
                MobileChatTickBox(
                    state: tally.state,
                    label: "Select all for chat",
                    action: { toggleAll(tally) }
                )
                .accessibilityIdentifier("notebook.sources.selectAll")
            }
        }
        .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
    }

    /// Select all: every box ticked clears them all, anything else ticks all
    /// (the Mac's Select all), the context notebooks in the chats counted.
    private func toggleAll(_ tally: MobileNotebookChatTally) {
        guard tally.isLoaded else { return }
        let inChat = tally.state != .checked
        Task { await selection.setAll(inChat: inChat, in: notebook) }
    }

    private func row(_ source: MobileCloudSource, board: MobileNotebookChatBoard?) -> some View {
        let isInChat = board?.isInChat(source.id) ?? false
        return MobileBrowserSourceLink(
            source: source,
            notebook: notebook,
            chatTick: MobileSourceChatTick(
                isOn: isInChat,
                isEnabled: board != nil,
                toggle: {
                    Task { await selection.set([source.id], inChat: !isInChat, in: notebook) }
                }
            ),
            onRemoveFromNotebook: notebook.sourceIDs.contains(source.id)
                ? { Task { _ = await vm.removeSources([source.id], fromNotebookID: notebook.id) } }
                : nil
        )
    }

    /// A context notebook's group: its row, then its sources while open.
    @ViewBuilder
    private func contextSection(_ group: MobileNotebookContextGroup, board: MobileNotebookChatBoard?) -> some View {
        let isOpen = openGroups.contains(group.id)
        let state = board?.state(ofContextNotebook: group.id, shown: group.sources.map(\.id)) ?? .unchecked
        Section {
            MobileContextNotebookHeader(
                group: group,
                state: state,
                isEnabled: board != nil,
                isExpanded: isOpen,
                onToggleExpanded: {
                    if isOpen { openGroups.remove(group.id) } else { openGroups.insert(group.id) }
                },
                onTick: {
                    Task { await selection.setContextNotebooks([group.id], inChat: state != .checked, in: notebook) }
                },
                onTakeOut: {
                    Task { await MobileNotebookContextLinks.takeOut(group.id, of: notebook, vm: vm, selection: selection) }
                }
            )
            if isOpen {
                ForEach(group.sources) { source in
                    contextRow(source, in: group, board: board)
                }
            }
        }
    }

    /// A source of a context notebook: its box says whether a new chat reads
    /// it, and ticking it while the notebook is out puts the notebook in with
    /// that source alone. It opens the Reader as the notebook's own rows do.
    private func contextRow(
        _ source: MobileCloudSource,
        in group: MobileNotebookContextGroup,
        board: MobileNotebookChatBoard?
    ) -> some View {
        let isInChat = board?.isInChat(source.id) ?? false
        return MobileBrowserSourceLink(
            source: source,
            notebook: notebook,
            chatTick: MobileSourceChatTick(
                isOn: isInChat,
                isEnabled: board != nil,
                toggle: {
                    Task { await selection.set([source.id], inChat: !isInChat, through: group.id, in: notebook) }
                }
            )
        )
    }

    /// A library source the notebook does not list: the row opens the Reader
    /// in the notebook, as the notebook's own rows do, and only the + adds it.
    private func libraryRow(_ source: MobileCloudSource) -> some View {
        MobileBrowserSourceLink(
            source: source,
            notebook: notebook,
            notebookAdd: MobileSourceNotebookAdd(
                isAdding: adding.contains(source.id),
                isEnabled: !vm.isMutatingLibrary,
                add: { Task { await addToNotebook(source) } }
            )
        )
    }

    /// Adds one library source to the notebook, ticked for its chat as the
    /// Add sources sheet adds one; the reload that follows the add moves it to
    /// the notebook's section. A failure shows in the shell's error bar.
    private func addToNotebook(_ source: MobileCloudSource) async {
        guard adding.insert(source.id).inserted else { return }
        defer { adding.remove(source.id) }
        guard await vm.addSources([source], toNotebookID: notebook.id) else { return }
        await selection.tickArrivals([source.id], in: vm.notebooks.first { $0.id == notebook.id })
    }

    private func errorRow(_ message: String, retry: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: MobileDesign.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Retry", action: retry)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            } else {
                Button {
                    selection.clearWriteError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
        }
    }
}

// MARK: - Add sources

/// Adding to a notebook from the phone, the Mac's sheet on a phone: one field
/// that searches the whole library (its words, then by meaning) or takes up
/// to ten pasted links, then the ways in — Scan Pages, Photos, Upload PDF… —
/// then what the library suggests for the notebook, with Add all. A source
/// added joins the library once and the notebook by reference, and arrives
/// ticked for the notebook's chat. Scanned pages and photos are filed as one
/// PDF that carries the words read on them (`MobileScannedPagesPDF`).
struct MobileNotebookAddSourcesSheet: View {
    let notebook: MobileCloudNotebook
    @ObservedObject var selection: MobileNotebookChatSelectionStore

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked = Set<String>()
    @State private var suggestions: [MobileCloudSource] = []
    @StateObject private var library = MobileNotebookLibrarySearch()
    @State private var showsFileImporter = false
    @State private var showsScanner = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// Each pasted link's progress, by the link.
    @State private var linkProgress: [String: MobileNotebookLinkProgress] = [:]
    /// Scanned pages or photos being made into a PDF and filed.
    @State private var pagesBeingFiled: PagesBeingFiled?

    private struct PagesBeingFiled: Equatable {
        let kind: MobileCapturedPages.Kind
        let title: String
        let count: Int
    }

    /// Library sources the notebook does not hold itself yet.
    private var candidates: [MobileCloudSource] {
        MobileNotebookSourceSearch.libraryCandidates(vm.allSources, excluding: notebook.sourceIDs)
    }

    /// The links in the field; two spellings of one address are one link,
    /// by the normalizer the capture names its source with.
    private var pasted: MobileNotebookPastedLinks.Reading {
        MobileNotebookPastedLinks.read(query, sameSource: MobileURLNormalizer.normalize)
    }

    private var results: [MobileCloudSource] {
        library.matches(in: candidates, query: query, groupTitle: vm.collections.groupTitle(of:))
    }

    private var isSearching: Bool {
        pasted.links.isEmpty && !MobileSourceListSearch.terms(in: query).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if let pagesBeingFiled {
                    Section {
                        pagesRow(pagesBeingFiled)
                    }
                }

                let reading = pasted
                if !reading.links.isEmpty {
                    linksSection(reading)
                } else if isSearching {
                    Section("Your library") {
                        if results.isEmpty {
                            Text("Nothing in your library matches.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(results) { source in
                            pickRow(source)
                        }
                    }
                } else {
                    Section {
                        waysIn
                    }

                    if !suggestions.isEmpty || candidates.isEmpty {
                        Section {
                            if suggestions.isEmpty {
                                Text("Every library source is in this notebook.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(suggestions) { source in
                                pickRow(source)
                            }
                        } header: {
                            Text("Suggested from your library")
                        } footer: {
                            if suggestions.count > 1 {
                                Button("Add all \(suggestions.count)") {
                                    Task { await add(suggestions) }
                                }
                                .font(.footnote.weight(.semibold))
                                .disabled(isWorking)
                                .accessibilityIdentifier("notebook.addSources.addAll")
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search your library or paste a link"
            )
            .navigationTitle("Add Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                        // In the library's order, so the notebook's study
                        // order does not depend on the order of the taps.
                        let chosen = vm.allSources.filter { picked.contains($0.id) }
                        Task { await add(chosen) }
                    }
                    .disabled(picked.isEmpty || isWorking)
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await addFile(url) }
            }
            .fullScreenCover(isPresented: $showsScanner) {
                MobileDocumentScanner { result in
                    showsScanner = false
                    switch result {
                    case .success(let pictures):
                        guard !pictures.isEmpty else { return }
                        Task { await addPages(pictures, kind: .scan) }
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { await addPhotos(items) }
            }
            .task { await loadSuggestions() }
            .task(id: query) { await rankByMeaningIfNeeded() }
        }
    }

    // MARK: Ways in

    private enum WayIn: Hashable {
        case scan
        case photos
        case upload
    }

    /// Scan Pages and Photos side by side, Upload PDF… under them; with no
    /// camera to scan with, Photos and Upload PDF… side by side.
    private var waysIn: some View {
        let ways: [WayIn] = (MobileDocumentScanner.isSupported ? [.scan] : []) + [.photos, .upload]
        return VStack(spacing: MobileDesign.Spacing.small) {
            ForEach(Array(stride(from: 0, to: ways.count, by: 2)), id: \.self) { start in
                HStack(spacing: MobileDesign.Spacing.small) {
                    ForEach(ways[start..<min(start + 2, ways.count)], id: \.self) { way in
                        wayIn(way)
                    }
                }
            }
        }
        .padding(.vertical, MobileDesign.Spacing.xSmall)
    }

    @ViewBuilder
    private func wayIn(_ way: WayIn) -> some View {
        switch way {
        case .scan:
            Button {
                showsScanner = true
            } label: {
                MobileAddSourcesTile(title: "Scan Pages", systemImage: "doc.viewfinder")
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityIdentifier("notebook.addSources.scan")
        case .photos:
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: nil,
                selectionBehavior: .ordered,
                matching: .images
            ) {
                MobileAddSourcesTile(title: "Photos", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityIdentifier("notebook.addSources.photos")
        case .upload:
            Button {
                showsFileImporter = true
            } label: {
                MobileAddSourcesTile(title: "Upload PDF…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityIdentifier("notebook.addSources.uploadPDF")
        }
    }

    /// What is being made into a PDF: its name, its pages, a spinner.
    private func pagesRow(_ pages: PagesBeingFiled) -> some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(pages.title)
                    .lineLimit(2)
                Text(MobileCapturedPages.countLine(pages.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notebook.addSources.pages")
    }

    // MARK: Links

    @ViewBuilder
    private func linksSection(_ reading: MobileNotebookPastedLinks.Reading) -> some View {
        let waiting = reading.links.filter { linkProgress[$0] != .added }
        let isAdding = reading.links.contains { linkProgress[$0] == .adding }
        Section {
            ForEach(reading.links, id: \.self) { link in
                linkRow(link)
            }
            if !waiting.isEmpty {
                Button {
                    Task { await addLinks(waiting) }
                } label: {
                    HStack(spacing: MobileDesign.Spacing.small) {
                        Label(
                            isAdding ? "Adding…" : MobileNotebookPastedLinks.addTitle(count: waiting.count),
                            systemImage: "link.badge.plus"
                        )
                        Spacer(minLength: 0)
                        if isAdding {
                            ProgressView()
                        }
                    }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("notebook.addSources.link")
            }
        } header: {
            Text(reading.links.count == 1 ? "Link" : "Links")
        } footer: {
            if reading.leftOut > 0 {
                Text("Only the first \(MobileNotebookPastedLinks.limit) links are added.")
            }
        }
    }

    private func linkRow(_ link: String) -> some View {
        let progress = linkProgress[link]
        return HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(string: link)?.host ?? link)
                    .lineLimit(1)
                Text(link)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .failed(let reason) = progress {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            switch progress {
            case .adding:
                ProgressView()
            case .added:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Added")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Not added")
            case nil:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notebook.addSources.linkRow")
    }

    private func pickRow(_ source: MobileCloudSource) -> some View {
        Button {
            if picked.contains(source.id) {
                picked.remove(source.id)
            } else {
                picked.insert(source.id)
            }
        } label: {
            HStack(spacing: MobileDesign.Spacing.medium) {
                MobileManagementSourceRow(source: source)
                Spacer(minLength: 0)
                Image(systemName: picked.contains(source.id) ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(picked.contains(source.id) ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked.contains(source.id) ? .isSelected : [])
        .accessibilityIdentifier("notebook.addSources.row")
    }

    /// The library's nearest titles to the notebook's name, card line and
    /// instructions, by meaning, on the device. A placeholder title ("New
    /// notebook") seeds nothing, so a blank notebook suggests nothing.
    private func loadSuggestions() async {
        let title = NotebookNaming.isPlaceholder(notebook.title) ? nil : notebook.title
        let seed = [title, notebook.summary, notebook.instructions]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        let pool = candidates
        guard !seed.isEmpty, !pool.isEmpty else { return }
        let ranked = await Task.detached(priority: .userInitiated) {
            MobileSemanticSourceSearch.rank(for: seed, in: pool, limit: 12)
        }.value
        suggestions = ranked
    }

    /// Pasted links are added as they stand, never ranked as words.
    private func rankByMeaningIfNeeded() async {
        guard isSearching else { return }
        await library.rankByMeaningIfNeeded(query: query, in: candidates, groupTitle: vm.collections.groupTitle(of:))
    }

    private func add(_ sources: [MobileCloudSource]) async {
        guard !sources.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        guard await vm.addSources(sources, toNotebookID: notebook.id) else {
            errorMessage = vm.errorMessage ?? "The sources could not be added."
            return
        }
        await tickArrivals(sources.map(\.id))
        dismiss()
    }

    /// Each link into the library (the Mac fetches the page and reads what
    /// kind it is, as for a link shared to ForeverLM from another app), then
    /// the ones that landed into the notebook together, ticked. A link that
    /// fails says why on its row and the rest still land; once every link
    /// is in, the sheet closes.
    private func addLinks(_ links: [String]) async {
        let pending = links.compactMap { link in URL(string: link).map { (link: link, url: $0) } }
        guard !pending.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        for item in pending { linkProgress[item.link] = .adding }

        guard let outcomes = await vm.captureSources(
            urls: pending.map(\.url),
            sourceType: "unclassified",
            filingInto: notebook.id,
            onEach: { index, outcome in
                if case .failure(let error) = outcome {
                    linkProgress[pending[index].link] = .failed(error.localizedDescription)
                }
            }
        ) else {
            for item in pending { linkProgress[item.link] = nil }
            errorMessage = vm.errorMessage ?? "The links could not be added."
            return
        }

        // Each link was filed into the notebook by its own capture (D47).
        var filed: [String] = []
        for (item, outcome) in zip(pending, outcomes) {
            guard case .success(let id) = outcome else { continue }
            linkProgress[item.link] = .added
            if !filed.contains(id) { filed.append(id) }
        }
        guard !filed.isEmpty else { return }
        await tickArrivals(filed)
        if pasted.links.allSatisfy({ linkProgress[$0] == .added }) { dismiss() }
    }

    private func addFile(_ url: URL) async {
        isWorking = true
        defer { isWorking = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        switch await vm.fileIntoNotebook(pdfAt: url, title: nil, notebook: notebook) {
        case .success(let source):
            await tickArrivals([source.id])
            dismiss()
        case .failure(let failure):
            errorMessage = failure.message
        }
    }

    /// Photos picked, in the order picked, as one PDF.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let title = MobileCapturedPages.title(kind: .photos, madeAt: Date())
        pagesBeingFiled = PagesBeingFiled(kind: .photos, title: title, count: items.count)
        defer { pagesBeingFiled = nil }
        guard let pictures = await MobilePickedPhotos.pictures(items) else {
            errorMessage = "A photo could not be loaded, so nothing was added."
            return
        }
        await file(pictures, title: title, capture: "photos")
    }

    /// Scanned pages, in the order scanned, as one PDF.
    private func addPages(_ pictures: [MobileScannedPagesPDF.Picture], kind: MobileCapturedPages.Kind) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let title = MobileCapturedPages.title(kind: kind, madeAt: Date())
        pagesBeingFiled = PagesBeingFiled(kind: kind, title: title, count: pictures.count)
        defer { pagesBeingFiled = nil }
        await file(pictures, title: title, capture: kind == .photos ? "photos" : "scan")
    }

    private func file(_ pictures: [MobileScannedPagesPDF.Picture], title: String, capture: String = "scan") async {
        errorMessage = nil
        switch await vm.filePages(pictures, title: title, notebook: notebook, capture: capture) {
        case .success(let source):
            await tickArrivals([source.id])
            dismiss()
        case .failure(let failure):
            errorMessage = failure.message
        }
    }

    /// What was added arrives ticked, against the notebook's grown pool.
    private func tickArrivals(_ sourceIDs: [String]) async {
        await selection.tickArrivals(sourceIDs, in: vm.notebooks.first { $0.id == notebook.id })
    }
}
