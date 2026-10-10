import SwiftUI

struct MobileSourceHighlightEditorRequest: Identifiable {
    let id = UUID()
    let existing: SourceHighlight?
    let selection: MobileReaderHighlightSelection?
}

struct MobileSourceHighlightEditor: View {
    let request: MobileSourceHighlightEditorRequest
    let sourceID: String
    let onSave: (SourceHighlight) async -> Bool
    let onDelete: ((String) async -> Bool)?

    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var color: SourceHighlightColor
    @State private var isSaving = false

    init(
        request: MobileSourceHighlightEditorRequest,
        sourceID: String,
        onSave: @escaping (SourceHighlight) async -> Bool,
        onDelete: ((String) async -> Bool)?
    ) {
        self.request = request
        self.sourceID = sourceID
        self.onSave = onSave
        self.onDelete = onDelete
        _note = State(initialValue: request.existing?.note ?? "")
        _color = State(initialValue: request.existing?.color ?? .default)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(quote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }

                // Research's words, shown as what they are and not editable
                // here: the phone edits the learner's own note.
                if let existing = request.existing, existing.hasPublicationUpdate {
                    Section {
                        Text(existing.publicationUpdate)
                            .font(.callout)
                    } header: {
                        Label("Since publication", systemImage: "sparkles")
                    }
                }

                Section("Color") {
                    HStack(spacing: 18) {
                        ForEach(SourceHighlightColor.allCases, id: \.rawValue) { choice in
                            Button {
                                color = choice
                            } label: {
                                Circle()
                                    .fill(swiftUIColor(choice))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if color == choice {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.black.opacity(0.65))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.displayName)
                        }
                    }
                }

                Section("Note") {
                    TextEditor(text: $note)
                        .frame(minHeight: 110)
                }

                if let existing = request.existing, let onDelete {
                    Section {
                        Button("Delete Highlight", role: .destructive) {
                            isSaving = true
                            Task {
                                if await onDelete(existing.id) { dismiss() }
                                isSaving = false
                            }
                        }
                    }
                }
            }
            .navigationTitle(request.existing == nil ? "Highlight" : "Edit Highlight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            if await onSave(highlight) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private var quote: String {
        request.existing?.quote ?? request.selection?.quote ?? ""
    }

    private var highlight: SourceHighlight {
        let now = Date()
        if let existing = request.existing {
            return SourceHighlight(
                id: existing.id,
                sourceID: existing.sourceID,
                quote: existing.quote,
                note: note,
                color: color,
                anchor: existing.anchor,
                pdfAnchor: existing.pdfAnchor,
                imageAnchors: existing.imageAnchors,
                // A note edited on the phone keeps the chat it came from, the
                // papers it cites and its since-publication update.
                chatSessionID: existing.chatSessionID,
                references: existing.references,
                publicationUpdate: existing.publicationUpdate,
                publicationUpdateAt: existing.publicationUpdateAt,
                createdAt: existing.createdAt,
                updatedAt: now
            )
        }
        let selection = request.selection!
        return SourceHighlight(
            id: SourceHighlight.newID(),
            sourceID: sourceID,
            quote: selection.quote,
            note: note,
            color: color,
            anchor: selection.anchor,
            pdfAnchor: selection.pdfAnchor,
            createdAt: now,
            updatedAt: now
        )
    }

    private func swiftUIColor(_ color: SourceHighlightColor) -> Color {
        let rgb = color.components
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
