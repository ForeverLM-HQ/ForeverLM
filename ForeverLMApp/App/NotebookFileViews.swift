import AppKit
import PDFKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct NotebookFilesCanvas: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let onBack: () -> Void

    @State private var selectedFileID: String?
    @State private var isDropTargeted = false
    @State private var editors: [NotebookEditorApplication] = []
    @State private var showNewMarkdownFile = false
    @State private var newMarkdownFileName = "Untitled.md"
    @State private var paneWidth: CGFloat = 0

    /// Whether the pane can hold the file list and a preview side by side. A
    /// center pane is allowed to be as narrow as
    /// `StudioCenterTabGroupSizing.minimumContentWidth`; two columns that
    /// declare more than that between them do not shrink, they overflow the
    /// pane and are drawn centred and clipped on both edges.
    private var listFitsBesidePreview: Bool {
        paneWidth <= 0 || paneWidth >= 560
    }

    private var files: [NotebookFileRecord] {
        vm.notebookFiles(notebookID: goal.id).sorted {
            $0.notebookRelativePath.localizedStandardCompare($1.notebookRelativePath) == .orderedAscending
        }
    }

    private var selectedFile: NotebookFileRecord? {
        guard let selectedFileID else { return nil }
        return files.first { $0.id == selectedFileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar

            if files.isEmpty {
                emptyWorkspace
            } else if !listFitsBesidePreview {
                // One column's worth of pane holds one column: the list, until a
                // file is chosen, and then the preview with a way back.
                if let selectedFile {
                    VStack(spacing: 0) {
                        HStack {
                            Button {
                                selectedFileID = nil
                            } label: {
                                Label("Files", systemImage: "chevron.left")
                                    .zoomedSystemFont(size: 11, weight: .medium)
                            }
                            .buttonStyle(.hoverWash(tint: Color.accentColor))
                            Spacer()
                        }
                        NotebookFilePreviewPane(
                            record: selectedFile,
                            editors: editors,
                            isReadOnly: goal.isArchived
                        )
                        .id(selectedFile.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    fileList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HSplitView {
                    fileList
                        .frame(minWidth: 200, idealWidth: 280, maxWidth: 340)

                    if let selectedFile {
                        NotebookFilePreviewPane(
                            record: selectedFile,
                            editors: editors,
                            isReadOnly: goal.isArchived
                        )
                        .id(selectedFile.id)
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            "Select a file",
                            systemImage: "doc",
                            description: Text("")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            paneWidth = width
        }
        .padding(.horizontal, StudioDesign.Metrics.pageMargin)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: goal.id) {
            await vm.refreshNotebookFiles(notebookID: goal.id, force: true)
            editors = await NotebookEditorDiscovery.installedEditors()
            chooseInitialFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await vm.refreshNotebookFiles(notebookID: goal.id)
                reconcileSelection()
            }
        }
        .onChange(of: files.map(\.id)) { _, _ in
            reconcileSelection()
        }
        .alert("New Markdown File", isPresented: $showNewMarkdownFile) {
            TextField("Filename.md", text: $newMarkdownFileName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                createMarkdownFile()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .zoomedSystemFont(size: 11, weight: .semibold)
            }
            .buttonStyle(.hoverWash)
            .help("Back to About")

            Text("Other files")
                .zoomedSystemFont(size: 17, weight: .semibold)

            Spacer(minLength: 8)

            Menu {
                Button("Open in Finder", systemImage: "folder") {
                    openWorkspace()
                }
                ForEach(editors) { editor in
                    Button("Open in \(editor.name)", systemImage: "chevronleft.forwardslash.chevronright") {
                        openWorkspace(in: editor)
                    }
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Open the notebook's folder")

            Menu {
                Button("New Markdown File…", systemImage: "doc.badge.plus") {
                    newMarkdownFileName = "Untitled.md"
                    showNewMarkdownFile = true
                }
                Button("Add Files…", systemImage: "plus") {
                    chooseFiles()
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Create or add files")
            .disabled(goal.isArchived)
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .zoomedSystemFont(size: 28, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 68, height: 68)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 17))

            VStack(spacing: 6) {
                Text(goal.isArchived ? "No files" : "No files yet")
                    .zoomedSystemFont(size: 16, weight: .semibold)
                Text(
                    goal.isArchived
                        ? "This notebook's folder is empty."
                        : "Drag files here, or add them from your Mac.\nThey're stored in the notebook's folder."
                )
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            if !goal.isArchived {
                HStack(spacing: 8) {
                    Button("New Markdown File") {
                        newMarkdownFileName = "Untitled.md"
                        showNewMarkdownFile = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Add Files…", action: chooseFiles)
                        .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.primary.opacity(isDropTargeted ? 0.04 : 0.015),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12),
                    style: goal.isArchived
                        ? StrokeStyle(lineWidth: 1)
                        : StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [5, 4])
                )
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !goal.isArchived else { return false }
            return importDroppedFiles(providers)
        }
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(files) { record in
                    NotebookFileRow(
                        record: record,
                        isSelected: selectedFileID == record.id,
                        isReadOnly: goal.isArchived,
                        editors: editors,
                        onSelect: { selectedFileID = record.id }
                    )
                }
            }
            .padding(8)
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                    lineWidth: isDropTargeted ? 2 : 1
                )
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !goal.isArchived else { return false }
            return importDroppedFiles(providers)
        }
    }

    private func chooseFiles() {
        Task {
            let urls = await FilePanel.open { panel in
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = true
                panel.message = "Add files to the notebook"
                panel.prompt = "Add"
            }
            await vm.importNotebookFiles(notebookID: goal.id, urls: urls)
        }
    }

    private func createMarkdownFile() {
        let trimmedName = newMarkdownFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = URL(fileURLWithPath: trimmedName).pathExtension.isEmpty
            ? trimmedName + ".md"
            : trimmedName
        Task {
            do {
                let snapshot = try await vm.createNotebookMarkdownFile(
                    notebookID: goal.id,
                    preferredRelativePath: requestedName
                )
                selectedFileID = snapshot.record.id
            } catch {
                vm.errorMessage = error.localizedDescription
                vm.showToast("Could not create Markdown file")
            }
        }
    }

    private func importDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        let group = DispatchGroup()
        let collector = NotebookDroppedFileCollector()
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            handled = true
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else {
                    url = item as? URL
                }
                if let url {
                    collector.append(url)
                }
            }
        }
        if handled {
            group.notify(queue: .main) {
                let urls = collector.snapshot()
                Task { @MainActor in
                    await vm.importNotebookFiles(notebookID: goal.id, urls: urls)
                }
            }
        }
        return handled
    }

    private func openWorkspace(in editor: NotebookEditorApplication? = nil) {
        Task {
            guard let url = await vm.notebookWorkspaceURL(notebookID: goal.id) else { return }
            if let editor {
                let configuration = NSWorkspace.OpenConfiguration()
                do {
                    try await NSWorkspace.shared.open(
                        [url],
                        withApplicationAt: editor.url,
                        configuration: configuration
                    )
                } catch {
                    vm.showToast("Could not open workspace in \(editor.name): \(error.localizedDescription)")
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func chooseInitialFile() {
        if selectedFileID == nil {
            selectedFileID = files.first?.id
        }
    }

    private func reconcileSelection() {
        guard let selectedFileID, files.contains(where: { $0.id == selectedFileID }) else {
            self.selectedFileID = files.first?.id
            return
        }
    }
}

struct NotebookFilesInspectorSection: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let action: () -> Void

    private var files: [NotebookFileRecord] {
        vm.notebookFiles(notebookID: goal.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Other files")
                    .zoomedSystemFont(size: 13, weight: .semibold)
                if !files.isEmpty {
                    Text("\(files.count)")
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .zoomedSystemFont(size: 20, weight: .medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, height: 46)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                            .zoomedSystemFont(size: 12, weight: .semibold)
                            .foregroundStyle(.primary)
                        Text("Open folder")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
            .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0))
        }
        .padding(18)
        .task(id: goal.id) {
            await vm.refreshNotebookFiles(notebookID: goal.id)
        }
    }
}

private struct NotebookFileRow: View {
    @Environment(StudioViewModel.self) private var vm
    let record: NotebookFileRecord
    let isSelected: Bool
    let isReadOnly: Bool
    let editors: [NotebookEditorApplication]
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Image(systemName: fileSystemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.notebookRelativePath)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(record.sizeDescription)
                        .zoomedSystemFont(size: 9)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 2)
            }
            .zoomedSystemFont(size: 11)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.app") {
                open()
            }
            ForEach(editors) { editor in
                Button("Open in \(editor.name)") {
                    open(in: editor)
                }
            }
            Button("Reveal in Finder", systemImage: "folder") {
                reveal()
            }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                Task { await vm.removeNotebookFile(record) }
            }
            .disabled(isReadOnly)
        }
    }

    private var fileSystemImage: String {
        switch record.pathExtension {
        case "ipynb": return "rectangle.and.pencil.and.ellipsis"
        case "csv", "tsv": return "tablecells"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        default: return "doc"
        }
    }

    private func open(in editor: NotebookEditorApplication? = nil) {
        Task {
            let url = await vm.notebookFileURL(record)
            if let editor {
                let configuration = NSWorkspace.OpenConfiguration()
                do {
                    try await NSWorkspace.shared.open(
                        [url],
                        withApplicationAt: editor.url,
                        configuration: configuration
                    )
                } catch {
                    vm.showToast("Could not open file in \(editor.name): \(error.localizedDescription)")
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func reveal() {
        Task {
            let url = await vm.notebookFileURL(record)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private struct NotebookFilePreviewPane: View {
    @Environment(StudioViewModel.self) private var vm
    let record: NotebookFileRecord
    let editors: [NotebookEditorApplication]
    let isReadOnly: Bool

    @State private var preview: NotebookFilePreview?
    @State private var reloadID = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name)
                        .zoomedSystemFont(size: 13, weight: .semibold)
                        .lineLimit(1)
                    if let directoryPath = record.notebookDirectoryPath {
                        Text(directoryPath)
                            .zoomedSystemFont(size: 10)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Menu {
                    Button("Open", systemImage: "arrow.up.forward.app") {
                        open()
                    }
                    ForEach(editors) { editor in
                        Button("Open in \(editor.name)") {
                            open(in: editor)
                        }
                    }
                    Button("Reveal in Finder", systemImage: "folder") {
                        reveal()
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Open externally")
            }
            .padding(12)

            Divider()

            Group {
                if record.isMarkdownDocument {
                    NotebookMarkdownEditor(record: record, isReadOnly: isReadOnly)
                } else if let preview {
                    previewBody(preview)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        // PDFKit and Quick Look paint their own opaque backgrounds, so the card
        // has to clip them back to its corners.
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .task(id: "\(record.id)-\(record.modifiedAt.timeIntervalSinceReferenceDate)-\(reloadID)") {
            guard !record.isMarkdownDocument else { return }
            preview = nil
            preview = await vm.notebookFilePreview(record)
        }
    }

    @ViewBuilder
    private func previewBody(_ preview: NotebookFilePreview) -> some View {
        switch preview {
        case .notebook(let notebook):
            JupyterNotebookPreviewView(notebook: notebook)
        case .table(let table):
            NotebookTablePreviewView(table: table)
        case .text(let content, let isTruncated):
            ScrollView([.horizontal, .vertical]) {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
            .overlay(alignment: .bottomTrailing) {
                if isTruncated {
                    Text("Preview truncated")
                        .zoomedSystemFont(size: 9, weight: .medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
        case .pdf(let url):
            NotebookPDFPreviewView(url: url)
        case .quickLook(let url):
            NotebookQuickLookPreviewView(url: url)
        case .unavailable(let message):
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "icloud.and.arrow.down",
                    description: Text(message)
                )
                Button("Try Again") { reloadID += 1 }
                    .controlSize(.small)
            }
        }
    }

    private func open(in editor: NotebookEditorApplication? = nil) {
        Task {
            let url = await vm.notebookFileURL(record)
            if let editor {
                let configuration = NSWorkspace.OpenConfiguration()
                do {
                    try await NSWorkspace.shared.open(
                        [url],
                        withApplicationAt: editor.url,
                        configuration: configuration
                    )
                } catch {
                    vm.showToast("Could not open file in \(editor.name): \(error.localizedDescription)")
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func reveal() {
        Task {
            let url = await vm.notebookFileURL(record)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// A complete-file editor rather than an editable preview. Loading and saving
/// stay on `StorageService`; SwiftUI owns only the in-memory draft. Saves carry
/// the revision that was loaded so an external or iCloud edit fails loudly
/// instead of being overwritten.
private struct NotebookMarkdownEditor: View {
    @Environment(StudioViewModel.self) private var vm
    let record: NotebookFileRecord
    let isReadOnly: Bool

    @State private var snapshot: NotebookMarkdownFileSnapshot?
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var reloadGeneration = 0

    private var hasUnsavedChanges: Bool {
        guard let snapshot else { return false }
        return draft != snapshot.markdown
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if isReadOnly {
                    Text("Read only")
                        .foregroundStyle(.secondary)
                } else if hasUnsavedChanges {
                    Text("Edited")
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(errorMessage)
                    Button("Reload") {
                        reloadGeneration += 1
                    }
                    .buttonStyle(.hoverWash(tint: Color.accentColor))
                }

                Button("Save") {
                    save()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(isReadOnly || !hasUnsavedChanges || isSaving)
            }
            .zoomedSystemFont(size: 10, weight: .medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot != nil {
                TextEditor(text: $draft)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .disabled(isReadOnly)
            } else {
                ContentUnavailableView(
                    "Could not open file",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage ?? "The Markdown file is unavailable.")
                )
            }
        }
        .task(id: "\(record.id)-\(reloadGeneration)") {
            await load()
        }
        .onChange(of: record.modifiedAt) { _, modifiedAt in
            guard !hasUnsavedChanges,
                  snapshot?.record.modifiedAt != modifiedAt else { return }
            reloadGeneration += 1
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await vm.notebookMarkdownFile(
                notebookID: record.notebookID,
                relativePath: record.notebookRelativePath
            )
            snapshot = loaded
            draft = loaded.markdown
        } catch {
            snapshot = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() {
        guard let snapshot, hasUnsavedChanges else { return }
        let markdownToSave = draft
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let saved = try await vm.saveNotebookMarkdownFile(
                    notebookID: record.notebookID,
                    relativePath: snapshot.record.notebookRelativePath,
                    markdown: markdownToSave,
                    expectedRevision: snapshot.revision
                )
                // The learner may keep typing while the actor writes. Advance
                // the saved revision but preserve any newer in-memory draft.
                self.snapshot = saved
                if draft == markdownToSave {
                    draft = saved.markdown
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

/// PDFKit renders the pages. A file named `.pdf` that isn't one — a saved web
/// page, say — falls through to Quick Look rather than an empty pane.
private struct NotebookPDFPreviewView: View {
    let url: URL

    @State private var document: PDFDocument?
    @State private var didAttemptLoad = false

    var body: some View {
        Group {
            if let document {
                NotebookPDFDocumentView(document: document)
            } else if didAttemptLoad {
                NotebookQuickLookPreviewView(url: url)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            document = nil
            didAttemptLoad = false
            document = await AsyncPDFDocumentLoader.load(url: url)
            didAttemptLoad = true
        }
    }
}

private struct NotebookPDFDocumentView: NSViewRepresentable {
    let document: PDFDocument
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.colorScheme) private var colorScheme
    @SyncedStorage(ReaderDarkMode.originalPageColorsKey) private var originalPageColors = false

    private var darkensPage: Bool {
        ReaderDarkMode.darkensPage(in: colorScheme, originalPageColors: originalPageColors)
    }

    /// A paper in a Notebook's folder is a local PDF like any in the library,
    /// so its citations show the same reference card (product owner, 2026-09-25:
    /// "it also has to be applied to local pdfs").
    final class Coordinator {
        let referencePreview = ReaderPDFReferencePreview()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = FindablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        ReaderDarkMode.apply(darkensPage, to: view)
        context.coordinator.referencePreview.attach(to: view)
        configureReferencePreview(context.coordinator.referencePreview)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        configureReferencePreview(context.coordinator.referencePreview)
        if nsView.document !== document {
            nsView.document = document
            context.coordinator.referencePreview.documentChanged()
        }
        ReaderDarkMode.apply(darkensPage, to: nsView)
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.referencePreview.detach()
    }

    private func configureReferencePreview(_ preview: ReaderPDFReferencePreview) {
        preview.library = vm
        preview.openSource = { [weak vm] sourceID in
            Task { await vm?.revealSourceInReader(sourceID) }
        }
    }
}

/// Quick Look renders whatever the system can render — Office and iWork
/// documents, images, media, archives — and falls back to the icon-and-metadata
/// card Finder shows for formats no generator handles.
private struct NotebookQuickLookPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        // The pane outlives any one file, so the preview has to be closed when
        // SwiftUI tears it down rather than when the window closes.
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        guard (nsView.previewItem as? NSURL) as URL? != url else { return }
        nsView.previewItem = url as NSURL
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}

private struct JupyterNotebookPreviewView: View {
    let notebook: JupyterNotebookPreview

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let kernelName = notebook.kernelName {
                    Text(kernelName)
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
                ForEach(notebook.cells) { cell in
                    notebookCell(cell)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func notebookCell(_ cell: JupyterNotebookCell) -> some View {
        switch cell.kind {
        case .markdown:
            Text(markdown(cell.source))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        case .code, .raw:
            VStack(alignment: .leading, spacing: 8) {
                if cell.kind == .code {
                    Text(cell.executionCount.map { "In [\($0)]" } ?? "In [ ]")
                        .zoomedSystemFont(size: 9, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
                ScrollView(.horizontal) {
                    Text(cell.source)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(cell.outputs) { output in
                    notebookOutput(output)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func notebookOutput(_ output: JupyterNotebookOutput) -> some View {
        switch output {
        case .text(_, let content):
            ScrollView(.horizontal) {
                Text(content)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(.top, 4)
        case .image(_, let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 760)
                    .accessibilityLabel("Notebook output")
            }
        case .notice(_, let message):
            Text(message)
                .zoomedSystemFont(size: 10)
                .foregroundStyle(.secondary)
        }
    }

    private func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(source)
    }
}

private struct NotebookTablePreviewView: View {
    let table: NotebookTabularPreview

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                        tableCell(column, isHeader: true)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(table.columns.indices), id: \.self) { index in
                            tableCell(index < row.count ? row[index] : "", isHeader: false)
                        }
                    }
                }
            }
            .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            if table.isTruncated {
                Text("Sample: \(table.sampledRowCount) rows")
                    .zoomedSystemFont(size: 9, weight: .medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
            }
        }
    }

    private func tableCell(_ value: String, isHeader: Bool) -> some View {
        Text(value)
            .zoomedSystemFont(size: 10, weight: isHeader ? .semibold : .regular)
            .lineLimit(3)
            .frame(minWidth: 90, maxWidth: 240, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHeader ? Color.primary.opacity(0.07) : Color.clear)
            .overlay {
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

struct NotebookEditorApplication: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
}

private enum NotebookEditorDiscovery {
    static func installedEditors() async -> [NotebookEditorApplication] {
        await Task.detached(priority: .utility) {
            let candidates: [(name: String, bundleIDs: [String])] = [
                ("VS Code", ["com.microsoft.VSCodeInsiders", "com.microsoft.VSCode"]),
                ("Cursor", ["com.todesktop.230313mzl4w4u92"]),
            ]
            return candidates.compactMap { candidate in
                for bundleID in candidate.bundleIDs {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        return NotebookEditorApplication(id: bundleID, name: candidate.name, url: url)
                    }
                }
                return nil
            }
        }.value
    }
}

private final class NotebookDroppedFileCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}
