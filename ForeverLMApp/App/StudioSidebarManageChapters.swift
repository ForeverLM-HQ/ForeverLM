import SwiftUI

// MARK: - Manage Book Chapters

struct ManageChaptersTarget: Identifiable {
    let groupName: String
    var id: String { groupName }
}

/// Sheet that lists every chapter source in a book and lets the user remove
/// selected chapters. `removeSelected` defers destructive cleanup briefly so
/// an accidental removal can be undone without losing the original state.
struct ManageBookChaptersSheet: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    let groupName: String
    @State private var selected: Set<String> = []
    @State private var isDeleting = false

    private var chapters: [StudioArticle] {
        vm.bookChapterArticlesInOrder(for: groupName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.bookDisplayName(groupName))
                    .font(.headline)
                    .lineLimit(1)
                Text("Select chapters to remove from this book.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !chapters.isEmpty {
                Button(selected.count == chapters.count ? "Clear" : "Select all") {
                    if selected.count == chapters.count { selected.removeAll() }
                    else { selected = Set(chapters.map(\.id)) }
                }
                .font(.callout)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if chapters.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("This book has no chapters.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(chapters) { chapter in
                    Button {
                        toggle(chapter.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected.contains(chapter.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(chapter.id) ? Color.accentColor : Color.secondary)
                            Text(chapter.title)
                                .lineLimit(1)
                            Spacer()
                            if let wc = chapter.wordCount, wc > 0 {
                                Text("\(wc) words")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(selected.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
            Button(role: .destructive) {
                deleteSelected()
            } label: {
                if isDeleting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Remove \(selected.count) Chapter\(selected.count == 1 ? "" : "s")")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty || isDeleting)
        }
        .padding(16)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func deleteSelected() {
        let ids = selected
        guard !ids.isEmpty else { return }
        isDeleting = true
        Task {
            await vm.removeSelected(ids)
            selected.removeAll()
            isDeleting = false
            if vm.bookChapterArticlesInOrder(for: groupName).isEmpty {
                dismiss()
            }
        }
    }
}
