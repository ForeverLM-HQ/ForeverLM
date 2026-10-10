#if os(macOS)
import SwiftUI

/// The canvas menu's **Versions…** (docs/knowledge-map-design.md, "Versions,
/// export and publishing"): the canvas's versions on this Mac, newest first,
/// each with how many cards, regions and arrows it holds. **Restore** writes
/// one back as a single edit (Undo takes it back, and what the canvas holds
/// now is kept in this list first); the trash button deletes one. Esc or ×
/// closes it.
struct CanvasVersionsSheet: View {
    @Environment(StudioViewModel.self) private var vm

    let canvasID: String
    let onClose: () -> Void

    @State private var versions: [KnowledgeMapVersion] = []
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var restoringID: String?
    @State private var actionError: String?
    @State private var deleting: KnowledgeMapVersion?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await load() }
        .confirmationDialog(
            "Delete this version?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { version in
            Button("Delete “\(version.name)”", role: .destructive) { delete(version) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is removed from this Mac's list. The canvas itself does not change.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Versions")
                .zoomedSystemFont(size: 14, weight: .semibold)
            Text(vm.canvasDisplayName(canvasID))
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button {
                vm.promptSaveCanvasVersion(canvasID: canvasID) {
                    Task { await load() }
                }
            } label: {
                Label("Save Version…", systemImage: "plus")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .help("Keep the canvas as it is now under a name")
            .accessibilityIdentifier("canvas.versions.save")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("canvas.versions.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            Text(loadError)
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if versions.isEmpty {
            VStack(spacing: 6) {
                Text("No versions yet")
                    .zoomedSystemFont(size: 13, weight: .medium)
                Text("ForeverLM keeps one on its own after a burst of edits, at most one every ten minutes; Save Version… keeps one now under a name. Versions stay on this Mac.")
                    .zoomedSystemFont(size: 11.5)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(versions) { version in
                            row(version)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                if let actionError {
                    Text(actionError)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func row(_ version: KnowledgeMapVersion) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(version.name)
                        .zoomedSystemFont(size: 12.5, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if version.kind == .auto {
                        Text("Automatic")
                            .zoomedSystemFont(size: 9, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                Text("\(PageVersionLabel.when(version.at)) · \(version.summary)")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                restore(version)
            } label: {
                HStack(spacing: 5) {
                    if restoringID == version.id {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Restore")
                }
                .zoomedSystemFont(size: 12, weight: .medium)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .disabled(restoringID != nil)
            .help("Put the canvas back as it was; Undo takes it back")
            .accessibilityIdentifier("canvas.versions.restore.\(version.id)")
            Button {
                deleting = version
            } label: {
                Image(systemName: "trash")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .disabled(restoringID != nil)
            .help("Delete this version")
            .accessibilityLabel("Delete this version")
            .accessibilityIdentifier("canvas.versions.delete.\(version.id)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func load() async {
        do {
            versions = try await vm.canvasVersions(of: canvasID)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    private func restore(_ version: KnowledgeMapVersion) {
        guard restoringID == nil else { return }
        restoringID = version.id
        actionError = nil
        Task {
            do {
                try await vm.restoreCanvasVersion(version, canvasID: canvasID)
                restoringID = nil
                onClose()
            } catch {
                restoringID = nil
                actionError = error.localizedDescription
            }
        }
    }

    private func delete(_ version: KnowledgeMapVersion) {
        actionError = nil
        Task {
            do {
                try await vm.deleteCanvasVersion(version, canvasID: canvasID)
                await load()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}
#endif
