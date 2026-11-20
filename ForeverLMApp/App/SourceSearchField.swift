// The source sidebar's search field.
import SwiftUI
import AppKit

/// The Sources search field.
///
/// It takes every keystroke into `searchFieldText`; the lists filter on
/// `searchText`, which follows once typing pauses. Filtering the whole library,
/// and redrawing a list of hundreds of papers, on each keystroke made typing lag
/// behind the fingers (product owner, 2026-10-10). It is its own view for the
/// same reason: the sidebar around it reads only the committed query, so a
/// keystroke redraws this field and nothing else.
struct SourceSearchField: View {
    @Environment(StudioSidebarStore.self) private var sidebar
    var isFocused: FocusState<Bool>.Binding
    let help: String
    /// Return, after the query is committed.
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        @Bindable var sidebar = sidebar
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .zoomedSystemFont(size: 11.5, weight: .medium)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search \(sidebar.searchNoun)", text: $sidebar.searchFieldText)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 12.5)
                // AppKit's text field reports an intrinsic minimum width from the
                // placeholder, so let long source-count placeholders compress in
                // narrow source columns.
                .frame(minWidth: 0)
                .focused(isFocused)
                .onSubmit {
                    // Return applies the query without waiting out the pause.
                    commit()
                    onSubmit()
                }
                .onKeyPress(.escape) {
                    onClear()
                    return .handled
                }
                .accessibilityLabel("Search \(sidebar.searchNoun)")
                .help(help)
            // The scope the query is confined to, so "title:" is visibly doing
            // something before the list changes.
            if let field = StudioViewModel.SidebarSearchQuery(parsing: sidebar.searchFieldText).field {
                Text(field.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    // Selectable text cannot carry its own AX label on macOS;
                    // see AGENTS.md, "Text that speaks for itself".
                    .textSelection(.disabled)
                    .accessibilityLabel("Searching \(field.label.lowercased()) only")
            }
            if !sidebar.searchFieldText.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .zoomedSystemFont(size: 11.5)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.hoverWash(in: Circle(), inset: -3))
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        // Grows with the app's text size rather than clipping it.
        .padding(.vertical, 6)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(isFocused.wrappedValue ? 0.22 : 0.12), lineWidth: 1)
        }
        // Clearing applies at once; anything else waits for a pause.
        .task(id: sidebar.searchFieldText) {
            if !sidebar.searchFieldText.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            commit()
        }
    }

    /// Hands the field's text to the lists. It copies the field as it is now,
    /// not as it was when the pause began, so a keystroke landing just as the
    /// pause ends is never written back over (`searchText` puts the field in
    /// step with whatever it is given).
    private func commit() {
        guard sidebar.searchText != sidebar.searchFieldText else { return }
        sidebar.searchText = sidebar.searchFieldText
    }
}

// MARK: - Pull-to-refresh
