#if os(macOS)
import SwiftUI

/// A picture's actions: every picture made from a prompt — drawn by a chat
/// here, or made in ChatGPT or Claude and saved through MCP — is kept to use
/// again (product owner, 2026-09-22: "whenever we generate an image, that should
/// also show up under artifacts, so we can always reuse those"). A picture
/// iterated on is one image in versions, one row at its latest ("you
/// shouldn't show like 10 versions of the same image"); the sheet holds the
/// versions. A picture is listed in its notebook's Studio alone, whose row opens
/// it with its title, model and prompt, and renames, refiles, copies, drags
/// out or trashes it. The store (`GeneratedImageStore`) is the whole state —
/// a file per version, its title, prompt, image id and notebook in the
/// file's own metadata — so nothing here is a record.
@MainActor
enum GeneratedImageActions {
    /// The images this Mac holds, most recently changed first; browser
    /// screenshots share the store and are left out.
    ///
    /// Screen record mode keeps only pictures made during the take, or kept on
    /// its list (`ScreenRecordMode.imageIDs`): an image carries no Notebook or
    /// source link to earn a pass by.
    static func loadDrawn() async -> [GeneratedImageStore.ImageGroup] {
        let scope = ScreenRecordScope.resolve { _ in [] }
        let groups = await Task.detached(priority: .userInitiated) {
            GeneratedImageStore.imageGroups()
        }.value
        guard let scope else { return groups }
        return groups.filter { scope.allowsImage(id: $0.imageID, createdAt: $0.updatedAt) }
    }

    /// The card's title: the image's own, never its prompt (product owner,
    /// 2026-09-24: "they should just have a title, not the entire prompt as
    /// the title").
    static func title(for group: GeneratedImageStore.ImageGroup) -> String {
        group.title ?? untitled
    }

    static let untitled = "Untitled image"

    /// What made the picture, for the card's caption and the sheet.
    static func madeBy(_ listing: GeneratedImageStore.Listing) -> String {
        listing.details?.model ?? (listing.details?.origin == .saved ? "Saved from elsewhere" : "Generated image")
    }

    /// Renames every version; true when the title is written.
    static func rename(_ group: GeneratedImageStore.ImageGroup, to title: String) async -> Bool {
        await run { try GeneratedImageStore.rename(group: group, to: title) }
    }

    /// Puts the image in a notebook, or with nil in none; true when written.
    static func setNotebook(_ group: GeneratedImageStore.ImageGroup, to notebookID: String?) async -> Bool {
        await run { try GeneratedImageStore.setNotebook(group: group, to: notebookID) }
    }

    static func copyImage(_ listing: GeneratedImageStore.Listing) {
        guard let image = NSImage(contentsOfFile: listing.path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    static func copyPrompt(_ listing: GeneratedImageStore.Listing) {
        guard let prompt = listing.details?.text, !prompt.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    static func showInFinder(_ listing: GeneratedImageStore.Listing) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: listing.path)])
    }

    /// Moves every version of the image to the Trash; true when it is gone.
    /// A chat that showed one then says in place that this Mac does not hold it.
    static func trash(_ group: GeneratedImageStore.ImageGroup) async -> Bool {
        await run { try GeneratedImageStore.trash(group: group) }
    }

    /// Moves one version to the Trash; the image keeps its others.
    static func trash(version listing: GeneratedImageStore.Listing) async -> Bool {
        await run { try GeneratedImageStore.trash(id: listing.id) }
    }

    private static func run(_ work: @escaping @Sendable () throws -> Void) async -> Bool {
        do {
            try await Task.detached(priority: .userInitiated) { try work() }.value
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    static func dragProvider(_ listing: GeneratedImageStore.Listing) -> NSItemProvider {
        NSItemProvider(contentsOf: URL(fileURLWithPath: listing.path)) ?? NSItemProvider()
    }

    @ViewBuilder
    static func menuItems(
        for group: GeneratedImageStore.ImageGroup,
        onRename: @escaping (GeneratedImageStore.ImageGroup) -> Void,
        onTrash: @escaping (GeneratedImageStore.ImageGroup) -> Void,
        notebook: GeneratedImageNotebookFiling? = nil
    ) -> some View {
        let latest = group.latest
        Button("Rename…") { onRename(group) }
        if let notebook {
            // A picture lives in one notebook: adding it to another moves it.
            // There is no Remove: a picture is listed only in its notebook's
            // Studio, so one taken out of every notebook would be listed
            // nowhere. Move to Trash is how one goes.
            NotebookFilingMenuItems(
                sourceIDs: [],
                livesIn: notebook.livesIn,
                add: { notebook.set($0) }
            )
        }
        Divider()
        Button("Copy Image") { copyImage(latest) }
        if latest.details?.text.isEmpty == false {
            Button("Copy Prompt") { copyPrompt(latest) }
        }
        Button("Show in Finder") { showInFinder(latest) }
        Divider()
        Button(group.versions.count > 1 ? "Move All \(group.versions.count) Versions to Trash" : "Move to Trash", role: .destructive) {
            onTrash(group)
        }
    }
}

/// Where a picture lives, for its row's Add to Notebook ▸
/// (`GeneratedImageStore.setNotebook`): the notebook it is in, and the write
/// that moves it to another.
struct GeneratedImageNotebookFiling {
    let livesIn: () -> Set<String>
    let set: (String) -> Void
}

/// An image at the size of the sheet under its title, which is edited in
/// place, with the model that made it, the prompt it was made from and,
/// when it has several, a strip of its versions to step between.
struct GeneratedImageSheet: View {
    let group: GeneratedImageStore.ImageGroup
    let onTrash: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// The versions still in the store; one trashed here leaves the strip.
    @State private var versions: [GeneratedImageStore.Listing]
    @State private var selectedID: String
    @State private var image: NSImage?
    /// The title as written to the files, and the field's text.
    @State private var savedTitle: String?
    @State private var titleDraft: String
    @FocusState private var titleFocused: Bool
    @State private var didCopyImage = false
    @State private var didCopyPrompt = false

    init(group: GeneratedImageStore.ImageGroup, onTrash: @escaping () -> Void) {
        self.group = group
        self.onTrash = onTrash
        _versions = State(initialValue: group.versions)
        _selectedID = State(initialValue: group.latest.id)
        _savedTitle = State(initialValue: group.title)
        _titleDraft = State(initialValue: group.title ?? "")
    }

    private var selected: GeneratedImageStore.Listing {
        versions.first { $0.id == selectedID } ?? versions[0]
    }

    var body: some View {
        let listing = selected
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    TextField(GeneratedImageActions.untitled, text: $titleDraft)
                        .textFieldStyle(.plain)
                        .zoomedSystemFont(size: 17, weight: .semibold)
                        .focused($titleFocused)
                        .onSubmit { commitTitle() }
                        .onChange(of: titleFocused) { _, focused in
                            if !focused { commitTitle() }
                        }
                        .help("Rename the image")
                        .accessibilityLabel("Title")
                        .accessibilityIdentifier("studio.artifacts.image.title")
                    Text(caption(for: listing))
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                headerActions(for: listing)
            }

            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onDrag { GeneratedImageActions.dragProvider(listing) }
                        .accessibilityLabel(savedTitle ?? GeneratedImageActions.untitled)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 520)

            if versions.count > 1 {
                versionStrip
            }

            if let prompt = listing.details?.text, !prompt.isEmpty {
                promptCard(prompt, for: listing)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 740)
        .task(id: listing.id) {
            let path = listing.path
            image = await Task.detached(priority: .userInitiated) { NSImage(contentsOfFile: path) }.value
        }
        // A group of its own: on a plain container the identifier replaced the
        // title field's and landed on every button of the sheet.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.artifacts.image.\(group.imageID)")
    }

    /// Copy Image is the one action that stays in view; the rest wait in the
    /// ⋯ menu and the × leaves (quiet chrome: a head holds its primary action,
    /// a ⋯ and the close).
    private func headerActions(for listing: GeneratedImageStore.Listing) -> some View {
        HStack(spacing: 6) {
            SpaceDarkPillButton(
                title: didCopyImage ? "Copied" : "Copy Image",
                systemImage: didCopyImage ? "checkmark" : "doc.on.doc",
                image: nil
            ) {
                GeneratedImageActions.copyImage(listing)
                flash($didCopyImage)
            }
            .accessibilityIdentifier("studio.artifacts.image.copy")
            Menu {
                Button("Show in Finder") { GeneratedImageActions.showInFinder(listing) }
                Divider()
                if versions.count > 1 {
                    Menu("Move to Trash") {
                        Button("This Version (v\(listing.version))", role: .destructive) { trashSelectedVersion() }
                        Button("All \(versions.count) Versions", role: .destructive, action: onTrash)
                    }
                } else {
                    Button("Move to Trash", role: .destructive, action: onTrash)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .hoverHighlight(cornerRadius: 8, inset: 0)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show in Finder or move to Trash")
            .accessibilityLabel("More")
            .accessibilityIdentifier("studio.artifacts.image.more")
            Button {
                commitTitle()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("studio.artifacts.image.close")
        }
    }

    /// The prompt, on a quiet card with its own copy glyph: the action sits on
    /// the thing it copies.
    private func promptCard(_ prompt: String, for listing: GeneratedImageStore.Listing) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView {
                Text(prompt)
                    .zoomedSystemFont(size: 12)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            Button {
                GeneratedImageActions.copyPrompt(listing)
                flash($didCopyPrompt)
            } label: {
                Image(systemName: didCopyPrompt ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help("Copy the prompt")
            .accessibilityLabel("Copy Prompt")
            .accessibilityIdentifier("studio.artifacts.image.copyPrompt")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Shows a copy's check for a moment.
    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            flag.wrappedValue = false
        }
    }

    /// The versions oldest to newest, as small pictures; the selected one is
    /// ringed.
    private var versionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(versions.reversed()) { version in
                    Button {
                        selectedID = version.id
                    } label: {
                        VStack(spacing: 3) {
                            VersionThumbnail(path: version.path)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(
                                            version.id == selectedID ? Color.accentColor : Color.primary.opacity(0.12),
                                            lineWidth: version.id == selectedID ? 2 : 1
                                        )
                                }
                            Text("v\(version.version)")
                                .zoomedSystemFont(size: 10, weight: .medium)
                                .foregroundStyle(version.id == selectedID ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(GeneratedImageStore.altText(version.details?.text ?? ""))
                    .accessibilityLabel("Version \(version.version)")
                    .accessibilityAddTraits(version.id == selectedID ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Versions")
    }

    /// The model that made the shown version first (product owner, 2026-09-24:
    /// "images should definitely have the model there that generated it"),
    /// then when, then which version.
    private func caption(for listing: GeneratedImageStore.Listing) -> String {
        var parts: [String] = []
        if let model = listing.details?.model {
            parts.append(listing.details?.origin == .saved ? "\(model) · saved from elsewhere" : model)
        } else {
            parts.append(listing.details?.origin == .saved ? "Saved from elsewhere" : "Model not recorded")
        }
        parts.append(listing.createdAt.formatted(date: .abbreviated, time: .shortened))
        if versions.count > 1 { parts.append("Version \(listing.version) of \(versions.count)") }
        // A redraw from a quiz, a walkthrough card or a chat's right-click
        // menu (`GeneratedImageRedraw`) names the version it was drawn over.
        if let replaced = listing.details?.replaces,
           let old = versions.first(where: { $0.id == replaced }) {
            parts.append("Redraw of v\(old.version)")
        }
        return parts.joined(separator: " · ")
    }

    /// Writes the field's title to every version; an emptied field puts the
    /// saved title back rather than leaving the image nameless.
    private func commitTitle() {
        guard let title = GeneratedImageStore.cleanTitle(titleDraft) else {
            titleDraft = savedTitle ?? ""
            return
        }
        guard title != savedTitle else { return }
        savedTitle = title
        titleDraft = title
        let current = GeneratedImageStore.ImageGroup(imageID: group.imageID, versions: versions)
        Task {
            if !(await GeneratedImageActions.rename(current, to: title)) {
                savedTitle = group.title
                titleDraft = group.title ?? ""
            }
        }
    }

    private func trashSelectedVersion() {
        let listing = selected
        Task {
            guard await GeneratedImageActions.trash(version: listing) else { return }
            versions.removeAll { $0.id == listing.id }
            if let latest = versions.first { selectedID = latest.id } else { dismiss() }
        }
    }
}

/// One version's picture in the strip, read off the main actor.
private struct VersionThumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .task(id: path) {
            let path = path
            image = await Task.detached(priority: .utility) { NSImage(contentsOfFile: path) }.value
        }
    }
}
#endif
