import SwiftUI

// MARK: - Collections of notebooks in the Space
//
// docs/notebooks-design.md, "Collections": Add to Collection ▸ on a
// notebook's row in the Space, the headings of All's Group by Collection, and
// the questions both ask (a name, whether to delete). The rows and their rules
// are `NotebookCollections`; the writes are `StudioViewModel+NotebookCollections`.

/// Add to Collection ▸ on a notebook's row or card in the Space: each collection, ticked when
/// the notebook is in it (a click puts it in or takes it out), then New
/// Collection…, which makes one with this notebook in it.
struct NotebookCollectionMenu: View {
    @Environment(StudioViewModel.self) private var vm
    let notebookID: String
    let onNewCollection: () -> Void

    var body: some View {
        let collections = vm.orderedNotebookCollections
        Menu("Add to Collection", systemImage: "rectangle.stack") {
            ForEach(collections) { collection in
                Toggle(collection.name, isOn: Binding(
                    get: { vm.notebookCollections.contains(notebookID, in: collection.id) },
                    set: { vm.setNotebook(notebookID, inCollection: collection.id, isMember: $0) }
                ))
            }
            if !collections.isEmpty {
                Divider()
            }
            Button("New Collection…", action: onNewCollection)
        }
    }
}

/// A question about a collection's name: New Collection (Create), optionally
/// with notebooks to put in it, or Rename Collection (Rename).
struct NotebookCollectionNameRequest: Identifiable {
    enum Purpose {
        case create(adding: [String])
        case rename(NotebookCollection)
    }

    let id = UUID()
    let purpose: Purpose

    static func create(adding notebookIDs: [String] = []) -> NotebookCollectionNameRequest {
        NotebookCollectionNameRequest(purpose: .create(adding: notebookIDs))
    }

    static func rename(_ collection: NotebookCollection) -> NotebookCollectionNameRequest {
        NotebookCollectionNameRequest(purpose: .rename(collection))
    }

    var title: String {
        switch purpose {
        case .create: return "New Collection"
        case .rename: return "Rename Collection"
        }
    }

    var confirmTitle: String {
        switch purpose {
        case .create: return "Create"
        case .rename: return "Rename"
        }
    }

    var initialName: String {
        switch purpose {
        case .create: return ""
        case .rename(let collection): return collection.name
        }
    }
}

private struct NotebookCollectionNamePrompt: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    @Binding var request: NotebookCollectionNameRequest?
    let onCreated: (NotebookCollection) -> Void
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert(
                request?.title ?? "",
                isPresented: Binding(
                    get: { request != nil },
                    set: { if !$0 { request = nil } }
                ),
                presenting: request
            ) { request in
                TextField("Name", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button(request.confirmTitle) { commit(request) }
                    .disabled(NotebookCollections.cleanedName(draft) == nil)
            }
            .onChange(of: request?.id) { _, _ in
                draft = request?.initialName ?? ""
            }
    }

    private func commit(_ request: NotebookCollectionNameRequest) {
        defer { draft = "" }
        switch request.purpose {
        case .create(let notebookIDs):
            if let created = vm.createNotebookCollection(named: draft, adding: notebookIDs) {
                onCreated(created)
            }
        case .rename(let collection):
            vm.renameNotebookCollection(collection.id, to: draft)
        }
    }
}

/// Asks before a collection is deleted; its notebooks stay where they are.
private struct NotebookCollectionDeleteConfirmation: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    @Binding var collection: NotebookCollection?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete “\(collection?.name ?? "")”?",
                isPresented: Binding(
                    get: { collection != nil },
                    set: { if !$0 { collection = nil } }
                ),
                titleVisibility: .visible,
                presenting: collection
            ) { collection in
                Button("Delete Collection", role: .destructive) {
                    vm.deleteNotebookCollection(collection.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its notebooks stay where they are.")
            }
    }
}

extension View {
    /// Asks for a collection's name while `request` is set; `onCreated`
    /// hears of a collection New Collection made.
    func notebookCollectionNamePrompt(
        _ request: Binding<NotebookCollectionNameRequest?>,
        onCreated: @escaping (NotebookCollection) -> Void = { _ in }
    ) -> some View {
        modifier(NotebookCollectionNamePrompt(request: request, onCreated: onCreated))
    }

    /// Asks whether to delete `collection` while it is set.
    func notebookCollectionDeleteConfirmation(_ collection: Binding<NotebookCollection?>) -> some View {
        modifier(NotebookCollectionDeleteConfirmation(collection: collection))
    }
}
