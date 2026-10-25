import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MobileSourceActionDestination: String, Identifiable {
    case notebook
    case schedule

    var id: String { rawValue }
}

/// A notebook's editor. There is none for a new notebook: New notebook makes
/// it at once, and ForeverLM names it (`NotebookNaming`).
enum MobileNotebookEditorDestination: Identifiable {
    case edit(MobileCloudNotebook)

    var id: String {
        switch self {
        case .edit(let notebook): return notebook.id
        }
    }

    var mode: MobileNotebookEditorSheet.Mode {
        switch self {
        case .edit(let notebook): return .edit(notebook)
        }
    }
}

extension View {
    func mobileSourceActionSheets(
        destination: Binding<MobileSourceActionDestination?>,
        source: MobileCloudSource,
        suggestedNotebook: MobileCloudNotebook? = nil
    ) -> some View {
        sheet(item: destination) { value in
            switch value {
            case .notebook:
                MobileSourceNotebookPickerSheet(source: source, suggestedNotebook: suggestedNotebook)
            case .schedule:
                MobileScheduleSourceSheet(source: source, suggestedNotebook: suggestedNotebook)
            }
        }
    }
}

struct MobileSourceManagementMenu: View {
    let source: MobileCloudSource
    var suggestedNotebook: MobileCloudNotebook?

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @State private var destination: MobileSourceActionDestination?
    @State private var confirmsDelete = false

    var body: some View {
        Menu {
            MobileSourceShareButtons(source: source)
            MobileOfflineSaveButton(source: source)
            Divider()
            Button("Add to Notebook", systemImage: "folder.badge.plus") {
                destination = .notebook
            }
            Button("Schedule", systemImage: "calendar.badge.plus") {
                destination = .schedule
            }
            Divider()
            Button("Archive Source", systemImage: "archivebox") {
                Task { _ = await vm.archiveSource(source) }
            }
            Button("Delete Source", systemImage: "trash", role: .destructive) {
                confirmsDelete = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Source actions")
        .mobileSourceActionSheets(
            destination: $destination,
            source: source,
            suggestedNotebook: suggestedNotebook
        )
        .confirmationDialog(
            "Delete this source everywhere?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Source", role: .destructive) {
                Task { _ = await vm.deleteSource(source) }
            }
        } message: {
            Text("The source will be removed from the library, Notebooks, and Schedule on every device.")
        }
    }
}

/// Share… for every source, and Show in Files for one that reads as a PDF, in the reader's ⋯ menu and a
/// source row's long-press menu.
struct MobileSourceShareButtons: View {
    let source: MobileCloudSource

    @ObservedObject private var share = MobileSourceShare.shared
    @ObservedObject private var export = MobileSourcePDFExport.shared

    var body: some View {
        Button("Share…", systemImage: "square.and.arrow.up") {
            Task { await share.share(source) }
        }
        .disabled(isPreparing)
        .accessibilityIdentifier("source.share")

        if MobileSourcePDFExport.canExport(source) {
            Button("Show in Files", systemImage: "folder") {
                Task { await export.showInFiles(source) }
            }
            .disabled(isPreparing)
            .accessibilityIdentifier("source.showPDFInFiles")
        }
    }

    private var isPreparing: Bool {
        share.preparingSourceIDs.contains(source.id) || export.preparingSourceIDs.contains(source.id)
    }
}

/// A source out of ForeverLM to the system share sheet, which lists ChatGPT (and Files, AirDrop, Mail) as
/// targets: the learner picks ChatGPT there and the source opens in its app as an attachment, to chat
/// about. iOS gives an app no way to open ChatGPT with a file itself, so the pick is theirs. A source
/// that reads as a PDF goes as its document (`MobileSourcePDFExport`); any other goes as its text in a
/// Markdown file named after its title, with the source's address under the title.
@MainActor
final class MobileSourceShare: ObservableObject {
    static let shared = MobileSourceShare()

    /// Sources whose text is being read for a share, so a row shows a spinner and cannot ask twice.
    @Published private(set) var preparingSourceIDs: Set<String> = []

    func share(_ source: MobileCloudSource) async {
        // A PDF source goes as its PDF; when it has none to be had it goes as its text, like any other.
        if MobileSourcePDFExport.canExport(source), await MobileSourcePDFExport.shared.share(source) { return }
        guard !preparingSourceIDs.contains(source.id) else { return }
        preparingSourceIDs.insert(source.id)
        defer { preparingSourceIDs.remove(source.id) }
        do {
            let raw = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: source.id)
            let file = try await Self.write(
                body: MobileReaderText.reflowed(raw, sourceType: source.sourceType),
                title: source.title,
                address: source.url
            )
            MobileSourcePDFExport.presentShareSheet(for: file)
        } catch {
            MobileSourcePDFExport.presentFailure(title: "Can't Share Source", error: error)
        }
    }

    /// The Markdown file, in a scratch folder emptied first so only the latest share is kept.
    private static func write(body: String, title: String, address: String?) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MobileSourceShareError.noText }
            let fileManager = FileManager.default
            let folder = fileManager.temporaryDirectory.appendingPathComponent("SharedSources", isDirectory: true)
            try? fileManager.removeItem(at: folder)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(MobileSourceFilePath.sharedFileName(title: title, extension: "md"), isDirectory: false)
            let link = address.flatMap { $0.isEmpty ? nil : "\n\($0)\n" } ?? ""
            try Data("# \(title)\n\(link)\n\(body)\n".utf8).write(to: file, options: .atomic)
            return file
        }.value
    }
}

enum MobileSourceShareError: LocalizedError {
    case noText

    var errorDescription: String? {
        switch self {
        case .noText: return "This source has no text to share yet."
        }
    }
}

/// A source's original PDF, out of ForeverLM: to the system share sheet, so a
/// paper can go to ChatGPT or another app, into Files, or over AirDrop; or
/// into On My iPhone › ForeverLM, with the Files app opened on it.
@MainActor
final class MobileSourcePDFExport: ObservableObject {
    static let shared = MobileSourcePDFExport()

    /// Sources whose PDF is being fetched for one of the two. The reader has
    /// already downloaded the document it shows, so from there the sheet opens
    /// at once; a long press on a paper never opened may have to download it
    /// first, and its row shows a spinner meanwhile.
    @Published private(set) var preparingSourceIDs: Set<String> = []

    /// A paywalled paper has no document to hand over, so it offers neither.
    static func canExport(_ source: MobileCloudSource) -> Bool {
        (source.sourceType == "paper" || source.isPDFBackedBookChapter) && !source.isPaywalled
    }

    /// Shares the PDF. False when the source has no PDF to be had (none, kept on the Mac, not uploaded
    /// yet), with nothing presented, so the caller can send its text instead.
    func share(_ source: MobileCloudSource) async -> Bool {
        let original: URL
        switch await fetch(source, failureTitle: "Can't Share PDF", quietWhenNoDocument: true) {
        case .file(let url): original = url
        case .noDocument: return false
        case .handled: return true
        }
        do {
            let fileManager = FileManager.default
            let folder = fileManager.temporaryDirectory.appendingPathComponent("SharedPDFs", isDirectory: true)
            let named = try await Self.place(original, into: folder, title: source.title, asHardLink: true)
            Self.presentShareSheet(for: named)
        } catch {
            Self.presentFailure(title: "Can't Share PDF", error: error)
        }
        return true
    }


    /// The app's Documents folder is what Files lists as On My iPhone ›
    /// ForeverLM (`UIFileSharingEnabled`), and nothing else is kept in it. A
    /// paper placed there stays until the learner deletes it in Files; showing
    /// it again replaces it. The iCloud container is not public, so this is
    /// the one place the Files app can be opened on a paper.
    func showInFiles(_ source: MobileCloudSource) async {
        guard case .file(let original) = await fetch(source, failureTitle: "Can't Show in Files", quietWhenNoDocument: false) else { return }
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let placed = try await Self.place(original, into: documents, title: source.title, asHardLink: false)
            // Files opens a `shareddocuments:` link on the file itself. Should
            // it refuse, the share sheet's Save to Files reaches Files too.
            if let filesURL = MobileSourceFilePath.filesAppURL(for: placed),
               await UIApplication.shared.open(filesURL) {
                return
            }
            Self.presentShareSheet(for: placed)
        } catch {
            Self.presentFailure(title: "Can't Show in Files", error: error)
        }
    }

    private enum Fetched {
        case file(URL)
        /// No document to be had, and nothing presented, so the caller can do without one.
        case noDocument
        /// Already preparing, or the learner has been shown why not.
        case handled
    }

    private func fetch(_ source: MobileCloudSource, failureTitle: String, quietWhenNoDocument: Bool) async -> Fetched {
        guard !preparingSourceIDs.contains(source.id) else { return .handled }
        preparingSourceIDs.insert(source.id)
        defer { preparingSourceIDs.remove(source.id) }
        do {
            let pdf = try await MobileSourceFileStore.shared.fetchPDF(
                sourceID: source.id,
                relativePath: MobileSourceFilePath.relativePDFPath(
                    localFilePath: source.localFilePath,
                    url: source.url
                )
            )
            guard pdf.pages != nil else { return .file(pdf.url) }
            return .file(try await Self.chapterFile(pdf))
        } catch {
            if quietWhenNoDocument, let fileError = error as? MobileSourceFileError, fileError.leavesOnlyText {
                return .noDocument
            }
            Self.presentFailure(title: failureTitle, error: error)
            return .handled
        }
    }

    /// A chapter kept as a run of its book's pages leaves as the chapter, not
    /// the whole book: its pages written to a file of their own, in a scratch
    /// folder that keeps only the latest.
    private static func chapterFile(_ pdf: MobileSourcePDF) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let document = try pdf.document()
            let fileManager = FileManager.default
            let folder = fileManager.temporaryDirectory.appendingPathComponent("ChapterPDFs", isDirectory: true)
            try? fileManager.removeItem(at: folder)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Chapter.pdf", isDirectory: false)
            guard document.write(to: file) else { throw MobileSourceFileError.noPDFAvailable }
            return file
        }.value
    }

    /// The document under the source's title, since the phone's copy is named
    /// by a hash of the source id. A file already there by that name is
    /// replaced.
    ///
    /// A share is a hard link, which costs no space, in a folder emptied first
    /// so only the latest share is kept; a copy stands in when the link cannot
    /// be made. Files gets a copy of its own: Markup there can write to the
    /// file it opened, and a hard link would carry that into the reader's copy.
    private static func place(
        _ original: URL,
        into folder: URL,
        title: String,
        asHardLink: Bool
    ) async throws -> URL {
        let fileName = MobileSourceFilePath.sharedPDFFileName(title: title)
        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            if asHardLink { try? fileManager.removeItem(at: folder) }
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(fileName, isDirectory: false)
            try? fileManager.removeItem(at: destination)
            if asHardLink, (try? fileManager.linkItem(at: original, to: destination)) != nil {
                return destination
            }
            try fileManager.copyItem(at: original, to: destination)
            return destination
        }.value
    }

    static func presentShareSheet(for file: URL) {
        present(UIActivityViewController(activityItems: [file], applicationActivities: nil))
    }

    static func presentFailure(title: String, error: Error) {
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert)
    }

    /// Over whatever is on screen: both start from a menu, which leaves no
    /// SwiftUI presentation to hang a sheet on.
    private static func present(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        // iPad shows the share sheet as a popover. The menu that asked for it
        // is gone by now, from a toolbar or from a row, so it stands centred.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}

struct MobileSourceNotebookPickerSheet: View {
    let source: MobileCloudSource
    let suggestedNotebook: MobileCloudNotebook?

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let suggestedNotebook {
                    notebookButton(suggestedNotebook)
                }

                Section("Notebooks") {
                    ForEach(otherNotebooks) { notebook in
                        notebookButton(notebook)
                    }
                }

                Section {
                    // Made at once with the source in it; ForeverLM names it.
                    Button("New Notebook", systemImage: "plus") {
                        Task { await createAndAdd() }
                    }
                    .disabled(vm.isMutatingLibrary)
                }
            }
            .navigationTitle("Add to Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var otherNotebooks: [MobileCloudNotebook] {
        vm.notebooks.filter { $0.id != suggestedNotebook?.id }
    }

    private func notebookButton(_ notebook: MobileCloudNotebook) -> some View {
        Button {
            Task {
                if await vm.addSources([source], toNotebookID: notebook.id) { dismiss() }
            }
        } label: {
            HStack {
                let title = NotebookTitle(notebook.title)
                Label {
                    Text(title.text)
                } icon: {
                    MobileNotebookIconView(notebookID: notebook.id, size: 22, cornerRadius: 5) {
                        Text(title.displayIcon)
                    }
                }
                Spacer()
                if notebook.sourceIDs.contains(source.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(notebook.sourceIDs.contains(source.id) || vm.isMutatingLibrary)
    }

    private func createAndAdd() async {
        guard let notebookID = await vm.createUnnamedNotebook() else { return }
        if await vm.addSources([source], toNotebookID: notebookID) { dismiss() }
    }
}

struct MobileScheduleSourceSheet: View {
    let source: MobileCloudSource
    let suggestedNotebook: MobileCloudNotebook?

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var notebookID: String?
    @State private var addToNotebook = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        quickDateButton("Today", offset: 0)
                        quickDateButton("Tomorrow", offset: 1)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                if !vm.notebooks.isEmpty {
                    Section("Notebook") {
                        Picker("Notebook", selection: $notebookID) {
                            Text("None").tag(String?.none)
                            ForEach(vm.notebooks) { notebook in
                                Text(notebook.title).tag(Optional(notebook.id))
                            }
                        }
                        if let selectedNotebook, !selectedNotebook.sourceIDs.contains(source.id) {
                            Toggle("Add source to Notebook", isOn: $addToNotebook)
                        }
                    }
                }
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            if await vm.scheduleSource(
                                source,
                                on: date,
                                notebookID: notebookID,
                                addToNotebook: addToNotebook
                            ) { dismiss() }
                        }
                    }
                    .disabled(vm.isMutatingLibrary)
                }
            }
            .onAppear {
                notebookID = suggestedNotebook?.id
                addToNotebook = suggestedNotebook.map { !$0.sourceIDs.contains(source.id) } ?? false
                if let placement = vm.scheduledPlacement(for: source.id) {
                    date = placement.plannedAt
                }
            }
            .onChange(of: notebookID) { _, _ in
                addToNotebook = selectedNotebook.map { !$0.sourceIDs.contains(source.id) } ?? false
            }
        }
    }

    private var selectedNotebook: MobileCloudNotebook? {
        vm.notebooks.first { $0.id == notebookID }
    }

    private func quickDateButton(_ label: String, offset: Int) -> some View {
        Button(label) {
            date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }
}

struct MobileNotebookEditorSheet: View {
    enum Mode {
        case edit(MobileCloudNotebook)
    }

    let mode: Mode

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var summary = ""
    @State private var instructions = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Notebook name", text: $title)
                }
                Section("Description") {
                    TextField("A short line shown on the notebook card", text: $summary)
                }
                Section("Instructions") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 140)
                }
            }
            .navigationTitle("Edit Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isMutatingLibrary)
                }
            }
            .onAppear {
                guard case .edit(let notebook) = mode else { return }
                title = notebook.title
                summary = notebook.summary ?? ""
                instructions = notebook.instructions ?? ""
            }
        }
    }

    private func save() async {
        switch mode {
        case .edit(let notebook):
            if await vm.updateNotebook(id: notebook.id, title: title, instructions: instructions, summary: summary) {
                dismiss()
            }
        }
    }
}

struct MobileCaptureSourceSheet: View {
    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var title = ""
    @State private var sourceType = "article"
    @State private var notebookID: String?
    @State private var schedulesSource = false
    @State private var scheduleDate = Date()
    @State private var showsFileImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Title (optional)", text: $title)
                    Picker("Type", selection: $sourceType) {
                        Text("Article").tag("article")
                        Text("Paper").tag("paper")
                        Text("Podcast").tag("podcast")
                        Text("Video").tag("video")
                        Text("X Post").tag("xpost")
                    }
                    Button("Choose File", systemImage: "doc.badge.plus") {
                        showsFileImporter = true
                    }
                }

                if !vm.notebooks.isEmpty {
                    Section("Notebook") {
                        Picker("Add to", selection: $notebookID) {
                            Text("None").tag(String?.none)
                            ForEach(vm.notebooks) { notebook in
                                Text(notebook.title).tag(Optional(notebook.id))
                            }
                        }
                    }
                }

                Section("Schedule") {
                    Toggle("Schedule source", isOn: $schedulesSource)
                    if schedulesSource {
                        DatePicker("Date", selection: $scheduleDate, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await capture() } }
                        .disabled(parsedURL == nil || vm.isMutatingLibrary)
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await captureFile(url) }
            }
        }
    }

    private var parsedURL: URL? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private func capture() async {
        guard let url = parsedURL,
              let id = await vm.captureSource(
                url: url,
                title: title.isEmpty ? nil : title,
                sourceType: sourceType
              ),
              let source = vm.allSources.first(where: { $0.id == id }) else { return }

        guard await applyRelationships(to: source) else { return }
        dismiss()
    }

    private func captureFile(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let id = await vm.captureFile(url: url, title: title.isEmpty ? nil : title),
              let source = vm.allSources.first(where: { $0.id == id }) else { return }
        guard await applyRelationships(to: source) else { return }
        dismiss()
    }

    private func applyRelationships(to source: MobileCloudSource) async -> Bool {
        if let notebookID, !schedulesSource {
            return await vm.addSources([source], toNotebookID: notebookID)
        }
        if schedulesSource {
            return await vm.scheduleSource(
                source,
                on: scheduleDate,
                notebookID: notebookID,
                addToNotebook: notebookID != nil
            )
        }
        return true
    }
}

struct MobileManagementSourceRow: View {
    let source: MobileCloudSource

    var body: some View {
        HStack(spacing: 12) {
            MobileSourceIconTile(sourceType: source.sourceType, size: CGSize(width: 36, height: 36))
            VStack(alignment: .leading, spacing: 3) {
                Text(source.title).lineLimit(2)
                if let subtitle = source.citationSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
