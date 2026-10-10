import SwiftUI

/// The share sheet (docs/notebooks-design.md, "iPhone"): Cancel and Add, what
/// is being shared, and the notebook it goes into — the one last shared into,
/// or "Not in a notebook", the Mac's words for the library alone. The
/// Notebook row is left out while the app has listed no notebook.
struct MobileShareSheetView: View {
    @ObservedObject var model: MobileShareSheetModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.isReading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else if model.items.isEmpty {
                        Text(MobileShareExtensionError.unsupportedAttachment.localizedDescription)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.items) { item in
                            itemRow(item)
                        }
                    }
                }

                if !model.notebooks.isEmpty {
                    Section {
                        Picker("Notebook", selection: $model.notebookID) {
                            Text("Not in a notebook").tag(String?.none)
                            ForEach(model.notebooks) { notebook in
                                Text(MobileShareNotebookList.displayTitle(of: notebook))
                                    .tag(Optional(notebook.id))
                            }
                        }
                        .disabled(model.isAdding)
                        .accessibilityIdentifier("share.notebook")
                    }
                }
            }
            .navigationTitle("ForeverLM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                        .accessibilityIdentifier("share.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isAdding {
                        ProgressView()
                    } else {
                        Button("Add") { model.add() }
                            .disabled(!model.canAdd)
                            .accessibilityIdentifier("share.add")
                    }
                }
            }
            .alert(
                model.errorMessage ?? "",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            }
        }
        .task { await model.read() }
    }

    private func itemRow(_ item: MobileShareSheetModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.headline)
                .font(.body)
                .lineLimit(2)
            if let subheadline = item.subheadline {
                Text(subheadline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share.item")
    }
}
