import SwiftUI

// MARK: - A notebook's and a collection's menus

// One menu for a notebook wherever the phone draws it — Home's Pinned and
// Recent, the Notebooks screen's cards and rows — and one for a collection —
// Home's Collections, the Notebooks screen's chips — with the sheets and
// alerts they ask for (`notebookMenus(_:)`), so the two screens can never
// offer different things.

/// What a collection name prompt is asking for.
enum MobileCollectionNamePrompt {
    /// A new collection: with the notebook whose menu asked for it in it, or,
    /// asked for from the Notebooks screen's ⋯, none.
    case new(notebookID: String?)
    case rename(NotebookCollection)

    var title: String {
        switch self {
        case .new: return "New Collection"
        case .rename: return "Rename Collection"
        }
    }

    var actionTitle: String {
        switch self {
        case .new: return "Create"
        case .rename: return "Rename"
        }
    }
}

/// The sheets and alerts the menus ask for, held by the screen that draws
/// them.
@MainActor
final class MobileNotebookMenuState: ObservableObject {
    @Published var editor: MobileNotebookEditorDestination?
    @Published var notebookToDelete: MobileCloudNotebook?
    @Published var collectionNamePrompt: MobileCollectionNamePrompt = .new(notebookID: nil)
    @Published var isNamingCollection = false
    @Published var collectionName = ""
    @Published var collectionToDelete: NotebookCollection?
    @Published var isConfirmingCollectionDelete = false
    /// The collection last made from a prompt that named no notebook (the
    /// Notebooks screen's ⋯), which that screen shows at once.
    @Published var madeCollection: NotebookCollection?

    func promptForCollectionName(_ prompt: MobileCollectionNamePrompt) {
        collectionNamePrompt = prompt
        if case .rename(let collection) = prompt {
            collectionName = collection.name
        } else {
            collectionName = ""
        }
        isNamingCollection = true
    }

    func confirmDelete(_ collection: NotebookCollection) {
        collectionToDelete = collection
        isConfirmingCollectionDelete = true
    }
}

/// A notebook's menu: Play Audio Overview (while it has one), then
/// Edit, Add to Collection ▸, Pin or Unpin, Archive and Delete. Play is not
/// a round button on every row (the product owner: "cleaner and fewer buttons
/// and bells and whistles"); a gallery card keeps its ▶.
struct MobileNotebookMenuItems: View {
    let notebook: MobileCloudNotebook
    @ObservedObject var menus: MobileNotebookMenuState

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @ObservedObject private var collectionStore = MobileNotebookCollectionsStore.shared
    @ObservedObject private var railStore = MobileNotebookRailStore.shared

    var body: some View {
        if let overview = vm.audioOverviews(inNotebook: notebook.id).first {
            let isPlaying = vm.currentItem?.id == overview.carrier.id && vm.isPlaying
            Button(
                isPlaying ? "Pause Audio Overview" : "Play Audio Overview",
                systemImage: isPlaying ? "pause" : "play"
            ) {
                Task { await vm.toggleTextToSpeech(sourceID: overview.carrier.id) }
            }
            .accessibilityIdentifier("home.notebook.menuPlayOverview")
        }
        Divider()
        Button("Edit", systemImage: "pencil") {
            menus.editor = .edit(notebook)
        }
        collectionMenu
        if railStore.isPinned(notebook.id) {
            Button("Unpin", systemImage: "pin.slash") {
                Task { await vm.setNotebook(notebook.id, pinned: false) }
            }
        } else {
            Button("Pin", systemImage: "pin") {
                Task { await vm.setNotebook(notebook.id, pinned: true) }
            }
        }
        Button("Archive", systemImage: "archivebox") {
            Task { _ = await vm.archiveNotebook(id: notebook.id) }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            menus.notebookToDelete = notebook
        }
    }

    /// Add to Collection ▸: each collection, ticked while the notebook is in
    /// it (a tap puts it in or takes it out), then New Collection…, which
    /// makes one with this notebook in it.
    private var collectionMenu: some View {
        Menu("Add to Collection", systemImage: "rectangle.stack.badge.plus") {
            ForEach(collectionStore.state.ordered) { collection in
                Toggle(MobileNotebookCollectionLabel.text(collection), isOn: Binding(
                    get: { collectionStore.state.contains(notebook.id, in: collection.id) },
                    set: { isMember in
                        Task { await vm.setNotebook(notebook.id, inCollection: collection.id, isMember: isMember) }
                    }
                ))
            }
            if !collectionStore.state.isEmpty {
                Divider()
            }
            Button("New Collection…", systemImage: "plus") {
                menus.promptForCollectionName(.new(notebookID: notebook.id))
            }
        }
        .accessibilityIdentifier("home.notebook.addToCollection")
    }
}

/// A collection's menu: Rename… and Delete….
struct MobileCollectionMenuItems: View {
    let collection: NotebookCollection
    @ObservedObject var menus: MobileNotebookMenuState

    var body: some View {
        Button("Rename Collection…", systemImage: "pencil") {
            menus.promptForCollectionName(.rename(collection))
        }
        Button("Delete Collection…", systemImage: "trash", role: .destructive) {
            menus.confirmDelete(collection)
        }
    }
}

/// A collection's emoji and name, as a notebook's title splits them.
enum MobileNotebookCollectionLabel {
    static func text(_ collection: NotebookCollection) -> String {
        let title = NotebookTitle(collection.name)
        return [title.icon, title.text.isEmpty ? nil : title.text]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

extension View {
    /// The sheets and alerts `menus` asks for: the notebook editor, Delete's
    /// question, voice's failure, a collection's name and Delete's question.
    func notebookMenus(_ menus: MobileNotebookMenuState) -> some View {
        modifier(MobileNotebookMenuPresentations(menus: menus))
    }
}

private struct MobileNotebookMenuPresentations: ViewModifier {
    @ObservedObject var menus: MobileNotebookMenuState
    @EnvironmentObject private var vm: MobileAudioReviewViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $menus.editor) { destination in
                MobileNotebookEditorSheet(mode: destination.mode)
            }
            .confirmationDialog(
                "Delete its chats too?",
                isPresented: Binding(
                    get: { menus.notebookToDelete != nil },
                    set: { if !$0 { menus.notebookToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Notebook, Keep Chats", role: .destructive) {
                    deleteNotebook(deleteLinkedChats: false)
                }
                Button("Delete Notebook and Chats", role: .destructive) {
                    deleteNotebook(deleteLinkedChats: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(menus.notebookToDelete?.title ?? "The Notebook") will be deleted. Keep its chats ungrouped in Chats, or delete them too. Its sources will remain available.")
            }
            .alert(menus.collectionNamePrompt.title, isPresented: $menus.isNamingCollection) {
                TextField("Name", text: $menus.collectionName)
                    .accessibilityIdentifier("home.collections.name")
                Button(menus.collectionNamePrompt.actionTitle) { commitCollectionName() }
                    .disabled(NotebookCollections.cleanedName(menus.collectionName) == nil)
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Delete “\(menus.collectionToDelete?.name ?? "")”?",
                isPresented: $menus.isConfirmingCollectionDelete,
                presenting: menus.collectionToDelete
            ) { collection in
                Button("Delete Collection", role: .destructive) {
                    Task { await vm.deleteNotebookCollection(collection.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its notebooks stay where they are.")
            }
    }

    private func deleteNotebook(deleteLinkedChats: Bool) {
        guard let notebook = menus.notebookToDelete else { return }
        Task { _ = await vm.deleteNotebook(id: notebook.id, deleteLinkedChats: deleteLinkedChats) }
        menus.notebookToDelete = nil
    }

    private func commitCollectionName() {
        let name = menus.collectionName
        let prompt = menus.collectionNamePrompt
        Task {
            switch prompt {
            case .new(let notebookID):
                guard let made = await vm.createNotebookCollection(named: name, withNotebook: notebookID) else { return }
                if notebookID == nil { menus.madeCollection = made }
            case .rename(let collection):
                await vm.renameNotebookCollection(collection.id, to: name)
            }
        }
    }
}
