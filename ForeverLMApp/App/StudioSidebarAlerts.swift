import SwiftUI
import Combine
import AppKit

struct MeetingMergeAlert: ViewModifier {
    let vm: StudioViewModel
    let isPresented: Binding<Bool>
    let groups: Binding<(source: String, target: String)?>

    func body(content: Content) -> some View {
        content.alert("Merge Meeting Groups", isPresented: isPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Merge") {
                guard let groups = groups.wrappedValue else { return }
                Task { await vm.mergeMeetingGroup(groups.source, into: groups.target) }
            }
        } message: {
            let source = groups.wrappedValue.map { vm.meetingDisplayName($0.source) } ?? "the first group"
            let target = groups.wrappedValue.map { vm.meetingDisplayName($0.target) } ?? "the destination"
            Text("Move every meeting from \(source) into \(target)? Future meetings sent to the first group, including Read AI imports, will also go to the second.")
        }
    }
}

struct SourceDetailsEditor: View {
    @Environment(\.dismiss) private var dismiss

    let vm: StudioViewModel
    let articleID: String
    let sourceType: StudioSourceType

    @State private var title: String
    @State private var author: String
    @State private var journal: String
    @State private var publishedYear: String
    @State private var isExtracting = false
    @State private var extractionFoundNothing = false
    @State private var isSaving = false

    init(vm: StudioViewModel, article: StudioArticle) {
        self.vm = vm
        articleID = article.id
        sourceType = article.sourceType
        _title = State(initialValue: article.title)
        // "Unknown authors"/"Unknown venue"/"Unknown year" are placeholders that
        // stand for a missing value. Pre-filling them looks like real content
        // and, saved back unchanged, leaves the field just as missing.
        _author = State(initialValue: Self.editableValue(article.author, placeholder: StudioArticle.unknownPaperAuthor))
        _journal = State(initialValue: Self.editableValue(article.journal, placeholder: StudioArticle.unknownPaperJournal))
        _publishedYear = State(
            initialValue: Self.editableValue(article.publishedYear, placeholder: StudioArticle.unknownPaperYear)
        )
    }

    private static func editableValue(_ value: String?, placeholder: String) -> String {
        guard let value, value != placeholder else { return "" }
        return value
    }

    private var showsAuthor: Bool {
        sourceType == .book
            || sourceType == .paper
            || sourceType == .article
            || sourceType == .unclassified
    }

    private var supportsAIExtraction: Bool {
        sourceType == .paper
            || sourceType == .article
            || sourceType == .unclassified
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Details")
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Title")
                    TextField("Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .sourceDetailsPasteEnabled()
                }

                if showsAuthor {
                    GridRow {
                        Text("Author")
                        TextField("Author", text: $author)
                            .textFieldStyle(.roundedBorder)
                            .sourceDetailsPasteEnabled()
                    }
                }

                if sourceType == .paper {
                    GridRow {
                        Text("Venue")
                        TextField("Venue", text: $journal)
                            .textFieldStyle(.roundedBorder)
                            .sourceDetailsPasteEnabled()
                    }

                    GridRow {
                        Text("Year")
                        TextField("Year", text: $publishedYear)
                            .textFieldStyle(.roundedBorder)
                            .sourceDetailsPasteEnabled()
                    }
                }
            }

            if supportsAIExtraction {
                Button {
                    extractDetails()
                } label: {
                    if isExtracting {
                        Label("Extracting…", systemImage: "sparkles")
                    } else {
                        Label("Extract with AI", systemImage: "sparkles")
                    }
                }
                .disabled(isExtracting || isSaving)

                if extractionFoundNothing {
                    Text("The AI couldn't read a title or author from this document. Type them in, or try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || isExtracting || isSaving)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func extractDetails() {
        isExtracting = true
        extractionFoundNothing = false
        Task { @MainActor in
            if sourceType == .paper {
                _ = await vm.extractPaperMetadataWithAI(id: articleID, showToasts: false, metadataOnly: true)
            } else {
                extractionFoundNothing = !(await vm.fixTitle(for: articleID))
            }
            refreshFromModel()
            isExtracting = false
        }
    }

    private func save() {
        isSaving = true
        Task { @MainActor in
            let saved = await vm.updateSourceDetails(
                id: articleID,
                title: title,
                author: author,
                journal: journal,
                publishedYear: publishedYear
            )
            isSaving = false
            if saved {
                dismiss()
            }
        }
    }

    private func refreshFromModel() {
        guard let article = vm.articles.first(where: { $0.id == articleID }) else { return }
        title = article.title
        author = Self.editableValue(article.author, placeholder: StudioArticle.unknownPaperAuthor)
        journal = Self.editableValue(article.journal, placeholder: StudioArticle.unknownPaperJournal)
        publishedYear = Self.editableValue(
            article.publishedYear,
            placeholder: StudioArticle.unknownPaperYear
        )
    }
}

private extension View {
    /// SwiftUI's Paste command can lose the field editor while this view is in a
    /// sheet over a WebKit reader. Forward it to the focused AppKit field editor
    /// so Command-V retains the normal insertion/selection-replacement behavior.
    func sourceDetailsPasteEnabled() -> some View {
        onPasteCommand(of: [.text]) { _ in
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  editor.isEditable else { return }
            editor.paste(nil)
        }
    }
}

/// Extracted alerts (group 2).
struct SidebarAlertsGroup2: ViewModifier {
    /// The window these alerts are in. Absent outside a Studio window.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    var vm: StudioViewModel
    @Binding var showPDFURLAlert: Bool
    @Binding var pdfURLText: String
    @Binding var pdfURLArticleId: String?
    @Binding var showBookRenameAlert: Bool
    @Binding var bookRenameText: String
    @Binding var renamingBookGroup: String?
    @Binding var showBookAuthorAlert: Bool
    @Binding var bookAuthorText: String
    @Binding var editingAuthorBookGroup: String?
    @Binding var showBookSubtitleAlert: Bool
    @Binding var bookSubtitleText: String
    @Binding var editingBookSubtitleGroup: String?
    @Binding var showBookEditionAlert: Bool
    @Binding var bookEditionText: String
    @Binding var editingBookEditionGroup: String?
    @Binding var showBookKindAlert: Bool
    @Binding var bookKindText: String
    @Binding var editingBookKindGroup: String?
    @Binding var showDeleteBookAlert: Bool
    @Binding var deletingBookGroup: String?

    func body(content: Content) -> some View {
        @Bindable var bindableVM = vm
        content
            .alert("Attach PDF from URL", isPresented: $showPDFURLAlert) {
                TextField("PDF URL", text: $pdfURLText)
                Button("Cancel", role: .cancel) { }
                Button("Attach") {
                    if let id = pdfURLArticleId, !pdfURLText.isEmpty {
                        Task {
                            do {
                                try await vm.attachPDFFromURL(to: id, urlString: pdfURLText)
                            } catch {
                                // Fail loudly — surface the failure through the same alert
                                // the book-import path uses instead of silently dropping it.
                                vm.errorMessage = "Couldn't attach the PDF: \(error.localizedDescription)"
                                vm.showBookImportError = true
                            }
                        }
                    }
                }
            } message: {
                Text("Paste a direct link to the PDF file.")
            }
            .alert("Rename Book", isPresented: $showBookRenameAlert) {
                TextField("Title", text: $bookRenameText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let group = renamingBookGroup, !bookRenameText.isEmpty {
                        Task { await vm.renameBook(groupName: group, newTitle: bookRenameText) }
                    }
                }
            } message: {
                Text("Enter a new display name for this book.")
            }
            .alert(editingAuthorBookGroup.flatMap({ vm.bookDisplayAuthor($0) }) != nil ? "Edit Author" : "Add Author", isPresented: $showBookAuthorAlert) {
                TextField("Author", text: $bookAuthorText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let group = editingAuthorBookGroup {
                        Task { await vm.updateBookAuthor(groupName: group, author: bookAuthorText) }
                    }
                }
            } message: {
                Text("Enter the author name for this book.")
            }
            .alert(editingBookSubtitleGroup.flatMap({ vm.bookDisplaySubtitle($0) }) != nil ? "Edit Subtitle" : "Add Subtitle", isPresented: $showBookSubtitleAlert) {
                TextField("Subtitle", text: $bookSubtitleText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let group = editingBookSubtitleGroup {
                        Task { await vm.updateBookSubtitle(groupName: group, subtitle: bookSubtitleText) }
                    }
                }
            } message: {
                Text("Enter the subtitle for this book.")
            }
            .alert(editingBookEditionGroup.flatMap({ vm.bookDisplayEdition($0) }) != nil ? "Edit Edition" : "Add Edition", isPresented: $showBookEditionAlert) {
                TextField("Edition", text: $bookEditionText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let group = editingBookEditionGroup {
                        Task { await vm.updateBookEdition(groupName: group, edition: bookEditionText) }
                    }
                }
            } message: {
                Text("Enter the edition for this book.")
            }
            .alert(editingBookKindGroup.flatMap({ vm.bookDisplayKind($0) }) != nil ? "Edit Category" : "Set Category", isPresented: $showBookKindAlert) {
                TextField("Category", text: $bookKindText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let group = editingBookKindGroup {
                        Task { await vm.updateBookKind(groupName: group, kind: bookKindText) }
                    }
                }
            } message: {
                if vm.allBookKinds.isEmpty {
                    Text("Enter a category for this book (e.g. Textbook, Personal Development, Business).")
                } else {
                    Text("Existing categories: \(vm.allBookKinds.joined(separator: ", "))")
                }
            }
            .alert("Book Import Error", isPresented: Binding(
                get: { vm.showBookImportError && vm.isRequestTarget(vm.bookImportAlertWindowID, windowState) },
                set: { vm.showBookImportError = $0 }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(vm.errorMessage ?? "An unknown error occurred during book import.")
            }
            .alert(vm.bookImportNoticeTitle, isPresented: Binding(
                get: { vm.showBookImportNotice && vm.isRequestTarget(vm.bookImportAlertWindowID, windowState) },
                set: { vm.showBookImportNotice = $0 }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(vm.bookImportNotice ?? "")
            }
            .alert("Remove Book", isPresented: $showDeleteBookAlert) {
                Button("Remove from Library", role: .destructive) {
                    if let group = deletingBookGroup {
                        Task { await vm.removeBookGroup(group, deleteFiles: false) }
                    }
                }
                Button("Remove & Delete Files", role: .destructive) {
                    if let group = deletingBookGroup {
                        Task { await vm.removeBookGroup(group, deleteFiles: true) }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                let name = deletingBookGroup.flatMap { vm.bookDisplayName($0) } ?? "this book"
                Text("Remove \"\(name)\" from your library? You can undo before deletion finishes.\n\n\"Remove & Delete Files\" also deletes the book files from iCloud after the undo period.")
            }
    }
}

// MARK: - MCP Context Tray
