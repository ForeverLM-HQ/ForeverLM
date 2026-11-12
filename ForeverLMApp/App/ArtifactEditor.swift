// The Doc editor and the chips it draws above the shelf.

import AppKit
import SwiftUI

struct ArtifactEditor: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let artifact: ArtifactRecord
    @Binding var publishedStatus: PublishedDocStatus?
    let formatting: ArtifactFormattingBridge
    /// The pane header's controls for this doc; what they open is presented here.
    @Bindable var chrome: ArtifactDocChromeBridge
    let onOpenSource: (String) -> Void
    /// A block of this doc to show and flash once the editor holds it.
    var blockReveal: ArtifactBlockRevealRequest? = nil

    /// The notes graph for this doc: what the editor is told about it, and
    /// the answers to what it asks (`ArtifactNotesGraphHost`).
    @State private var notesGraph = ArtifactNotesGraphHost()
    @State private var snapshot: ArtifactMarkdownSnapshot?
    /// The page's text as the editor last reported it, read where it is
    /// needed and never to decide what the body draws (`ArtifactEditorDraft`).
    @State private var editorDraft = ArtifactEditorDraft()
    /// Bumped when the host, not the editor, changes the text — a load, a
    /// merge, a restore, Keep on a proposal — so the editor is handed the new
    /// text and the rendered page draws it. The editor's reports leave it be.
    @State private var draftRevision = 0
    /// How long the text stands still before it is saved.
    private static let autosavePause: Duration = .milliseconds(800)
    @State private var isLoading = true
    @State private var isDownloadingFromICloud = false
    @State private var isSaving = false
    /// A save was asked for while one was in flight. Only that it was: when
    /// the first one lands, what goes out is the draft as it is then.
    @State private var saveQueued = false
    /// Another writer's version of the body that could not be merged into this
    /// draft — the same passage changed on both sides. Held until the writer
    /// picks one; autosave waits with it.
    @State private var heldRemoteMarkdown: String?
    @State private var isUpdatingTitle = false
    @State private var pageHTML: String?
    @State private var pageError: String?
    /// The page's Edit mode: the change asked for on a hovered block, through
    /// to Keep or Discard (docs/docs-design.md → Edit with AI → On the page).
    @State private var pageEdit: DocPageEditSession?
    @State private var sourceInsertion: ArtifactSourceInsertion?
    /// A doc or Notebook dropped on the page, named and on its way into the prose.
    @State private var linkInsertion: ArtifactLinkInsertion?
    /// The editor asking what the highlighted passage stands on.
    @State private var groundingRequest: ArtifactGroundingRequest?
    @State private var groundingAttachment: ArtifactGroundingAttachment?
    @State private var mutedShelfSourceIDs: Set<String> = []
    @State private var isSourceDropTargeted = false
    @State private var titleDraft = ""
    /// Whether the header shows the title as a field. At rest the title is a
    /// label the writer can drag — into a chat to add the doc to its context,
    /// to the center edge to open Docs beside — and a click on it opens the
    /// field. An editable field cannot be that drag source: its field editor
    /// takes the press for text selection before SwiftUI's drag can start.
    @State private var isEditingTitle = false
    /// Whether the doc is named by its first heading: the stored title is the
    /// `# ` heading the body opens with, so the header would only say the
    /// name a second time, and is not drawn. The heading is the title then —
    /// editing it renames the doc, deleting it brings the header back.
    @State private var titleFollowsHeading = false
    /// The page opened with its title row, so the row keeps its place until the
    /// page is opened again. When the first heading names the page mid-visit,
    /// the row goes blank rather than away: taking it away moved the whole
    /// page up under the caret as the writer went on from the heading.
    @State private var titleRowHeld = false
    /// The selection as the view draws it (the shelf, the passage's chats):
    /// current whenever it holds words. A bare caret moving as the writer
    /// types is not taken: nothing here reads where a caret is, and taking it
    /// ran this body again at every pause in typing. A request that needs the
    /// caret (Chat, Comment) arrives with the selection in hand.
    @State private var editorSelection = ArtifactEditorSelection(text: "", from: 0, to: 0)
    @State private var attachmentDataURLs: [String: String] = [:]
    /// The web references the editor draws as cards, and the library's answer
    /// for each. The editor reports the addresses; the host looks them up and
    /// hands the answers back, and re-asks whenever the library changes.
    @State private var referenceHrefs: [String] = []
    @State private var referenceStatuses: [String: ArtifactReferenceStatus] = [:]
    /// Resolves the cards' pictures after the answers, a few at a time; a new
    /// answer or a closed doc cancels the one in flight.
    @State private var referenceArtworkTask: Task<Void, Never>?
    /// How wide the page is drawn; the title's inset follows it.
    @WindowStorage(Prefs.Readers.pageColumnWidth, default: ArtifactPageWidth.standard) private var pageWidthPreference
    /// The width the page's edges are being dragged to, stored the same way;
    /// nil when no drag is under way. The title follows it frame by frame, and
    /// only the drag's last width is kept, so a drag syncs once.
    @State private var draggedPageWidth: Double?
    @State private var attachmentInsertion: ArtifactAttachmentInsertion?
    @State private var isImportingImage = false
    @State private var publicationRequestID = 0
    /// The Export ▸ format waiting for the editor's publication HTML: the
    /// HTML file, or the PDF printed from it.
    @State private var pendingPublicationExport: PageExportFormat?
    /// What the next save is, for the page's version history: Keep on a
    /// change the page's Edit proposed is an assistant's edit; everything
    /// else the editor writes is the writer's typing.
    @State private var nextSaveVersionReason: PageVersionReason?
    @State private var comments: [ArtifactCommentRecord] = []
    @State private var chatLinks: [ArtifactChatLink] = []
    @State private var pendingCommentSelection: ArtifactEditorSelection?
    /// The comment thread open in the Comments panel, whose passage the page
    /// marks and shows; set from the panel or by clicking marked words.
    @State private var selectedCommentThreadID: String?
    /// Threads whose words the editor no longer finds in the page.
    @State private var detachedCommentThreadIDs: Set<String> = []
    /// The version chosen in Page activity, read over the page; nil shows the
    /// page as it is.
    @State private var previewedPageVersion: PageVersion?
    @State private var paneWidth: CGFloat = 0
    @State private var findState = ReaderFindState()
    @FocusState private var titleFocused: Bool
    /// False while Pages is kept mounted behind another tab of its pane
    /// (`StudioKeptPaneTabs`): the page stays loaded, unseen.
    @Environment(\.studioPaneTabIsShown) private var paneTabIsShown

    /// Mirrors the page geometry in `artifact-editor.css` so the title starts on
    /// the same left edge as the prose beneath it: a column capped at the page
    /// width the reader chose (760pt by default, or the whole pane), centred in
    /// the pane, with side padding that yields as the pane narrows.
    /// The title is the first field in the page, not a band above one, so it
    /// has to move with the page instead of keeping an inset of its own.
    ///
    /// `width` is the document column's own — the pane's, less the comments
    /// drawer — read by the column's `GeometryReader`, so that while it animates
    /// the rows move with the prose rather than ahead of it (`ArtifactPageInset`).
    private func pageInset(for width: CGFloat) -> ArtifactPageInset {
        ArtifactPageInset(
            paneWidth: width,
            pageMaxWidth: pageMaxWidth
        )
    }

    /// The prose column's cap: the width being dragged to, else the kept one.
    private var pageMaxWidth: CGFloat? {
        ArtifactPageWidth.maxWidth(draggedPageWidth ?? pageWidthPreference)
    }

    /// Whether the pane can hold the page and the side panel at once.
    private var sidePanelFitsBesidePage: Bool { paneWidth <= 0 || paneWidth >= 620 }

    private var sidePanelWidth: CGFloat { min(300, max(240, paneWidth * 0.4)) }

    @ViewBuilder
    private func sidePanelView(_ panel: PageSidePanel) -> some View {
        switch panel {
        case .comments:
            commentsSidebar
        case .activity:
            PageActivityPanel(
                loadVersions: { await vm.pageVersions(artifact.id) },
                reloadToken: snapshot?.revision ?? "",
                previewedVersion: $previewedPageVersion,
                onClose: { chrome.isActivityVisible = false }
            )
        }
    }

    /// The page's text as it stands (`ArtifactEditorDraft`).
    private var draft: String { editorDraft.text }

    private var hasUnsavedChanges: Bool {
        guard let snapshot else { return false }
        return draft != snapshot.markdown
    }

    /// The host's own change to the text. The editor takes it on the pass the
    /// revision brings, and the autosave hears it as it hears typing.
    private func setDraft(_ text: String) {
        guard editorDraft.replaceText(with: text, autosaveAfter: Self.autosavePause, save: autosaveIfDue) else { return }
        draftRevision &+= 1
    }

    /// The editor's report of what the writer typed: held, and nothing drawn.
    /// While the rendered page shows there is no typing to report; a report
    /// then is the editor's last word as it left, and the page draws it.
    private func editorReported(_ text: String) {
        guard editorDraft.replaceText(with: text, autosaveAfter: Self.autosavePause, save: autosaveIfDue) else { return }
        if chrome.showsPage { draftRevision &+= 1 }
    }

    /// The text stood still: write it, unless there is nothing new or another
    /// writer's version waits for the writer's choice.
    private func autosaveIfDue() {
        guard snapshot != nil, hasUnsavedChanges, heldRemoteMarkdown == nil else { return }
        save(draft)
    }

    /// A team Doc reads as a page here; a member edits a private draft of it
    /// (docs/teams-design.md, decision 11).
    /// So does a Doc someone shared with this account to read only (`SharedDocState`).
    private var isReadOnly: Bool { artifact.teamID != nil || vm.sharedDocs[artifact.id]?.canEdit == false }

    /// The day this doc is the daily note for; nil for any other doc.
    private var dailyNoteDayKey: String? { DailyNote.dayKey(ofID: artifact.id) }

    /// The library this doc's graph is: its team's — a member's draft of a
    /// team Doc too — or My Library (nil).
    private var graphTeamID: String? { vm.referenceLibraryTeamID(for: artifact) }

    /// The library's docs and Ideas as the graph last read them.
    private var notesGraphLibrarySignature: Int {
        ArtifactNotesGraphHost.librarySignature(
            artifacts: vm.artifacts,
            ideas: vm.ideas,
            openDocID: artifact.id,
            teamID: graphTeamID
        )
    }

    // Put behind another tab of its pane, the page stays mounted, so the
    // leaving that `onDisappear` answers happens here: the draft and title are
    // saved now, the title gives up the keyboard, and the body is published as
    // a closed Doc's is. Outside `editorBody`, whose chain is already as long
    // as the type checker takes in reasonable time.
    var body: some View {
        editorBody.onChange(of: paneTabIsShown) { _, shown in
            guard !shown else { return }
            titleFocused = false
            editorDraft.cancelAutosave()
            save(draft)
            saveTitle()
            DocBodySync.requestPublish(artifact.id)
        }
    }

    private var editorBody: some View {
        HStack(spacing: 0) {
            if chrome.sidePanel == nil || sidePanelFitsBesidePage {
                // The column's width is read in layout, so it reaches the rows
                // in the resize's own transaction: when the pane's width
                // animates, the title moves with the prose instead of jumping
                // to where the prose will end up (`ArtifactPageInset`).
                GeometryReader { column in
                    let inset = pageInset(for: column.size.width)
                    VStack(spacing: 0) {
                        if chrome.showsPage {
                            // The HTML owns its title and report header, and the
                            // doc's controls are in the pane header: nothing of
                            // ours stands between the chrome line and the page
                            // until Cmd+F opens the find bar.
                            ReaderFindBar(state: findState, prompt: "Find in page")
                            pageSurface
                        } else {
                            // A doc named by its first heading has its title on
                            // the page already; the header would say it twice.
                            // A daily note's header steps between days, so it
                            // always stands. A subpage names the pages above it
                            // first, quietly (docs/docs-design.md, "Subpages").
                            PageParentTrail(pageID: artifact.id, inset: inset)
                            if let dayKey = dailyNoteDayKey {
                                dailyNoteHeader(dayKey: dayKey, inset: inset)
                            } else if !titleFollowsHeading || isEditingTitle {
                                header(inset: inset)
                            } else if titleRowHeld {
                                header(inset: inset).hidden()
                            }
                            ReaderFindBar(state: findState, prompt: "Find in page")
                            heldVersionBanner(inset: inset)
                            documentSurface
                            referencesShelf
                        }
                    }
                }
                // A version chosen in Page activity is read over the page; the
                // editor stays alive beneath it, caret and undo kept.
                .overlay {
                    if let version = previewedPageVersion, chrome.isActivityVisible {
                        PageVersionOverlay(
                            version: version,
                            loadMarkdown: { try await vm.pageVersionMarkdown(artifact.id, version: $0) },
                            restore: isReadOnly ? nil : { try await restoreVersion($0) },
                            onDone: { previewedPageVersion = nil }
                        )
                    }
                }
                // Cmd+F reaches the doc while focus is anywhere in its column —
                // the page, its title, or the find bar itself — and from the
                // rest of the window when no reader holds focus: the same claim
                // every reader makes. No zoom handlers, because the page scales
                // with the app's UI zoom rather than a zoom of its own.
                .background {
                    ReaderShortcutTarget(find: { findState.show() })
                }
            }
            if let panel = chrome.sidePanel {
                if sidePanelFitsBesidePage {
                    Divider()
                    sidePanelView(panel)
                        .frame(width: sidePanelWidth)
                } else {
                    // Too narrow to stand beside the page: the panel takes the
                    // pane rather than pushing the document off it.
                    sidePanelView(panel)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: chrome.sidePanel) { _, panel in
            if panel != .activity { previewedPageVersion = nil }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            paneWidth = width
        }
        // Skipped while the doc is still loading: `load()` fetches the links
        // itself, and running both would query twice for the same answer.
        .task(id: vm.artifactChatLinksRevision) {
            guard !isLoading else { return }
            chatLinks = await vm.artifactChatLinks(artifact.id)
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Keep the complete note as a fallback target for drops that land on
        // its title or source shelf. Drops over the document use the narrower
        // target below, whose passage is the paragraph under the pointer.
        //
        // Off the page there is no paragraph, so the highlighted passage is the
        // only thing such a drop can mean — and with nothing highlighted there
        // is nothing to attach to, which the drag springing back says better
        // than a source silently landing somewhere the writer cannot see.
        .dropDestination(for: StudioArticleTransfer.self) { transfers, _ in
            guard !isReadOnly, editorSelection.hasText else { return false }
            let citations = transfers.flatMap(citations(from:))
            guard !citations.isEmpty else { return false }
            sourceInsertion = ArtifactSourceInsertion(citations: citations)
            return true
        }
        .task(id: "\(artifact.id)-\(chrome.reloadGeneration)") { await load() }
        // Unpublished while its page showed: back to the editor.
        .onChange(of: publishedStatus) { oldStatus, newStatus in
            guard oldStatus != nil, newStatus == nil else { return }
            chrome.showsPage = false
            pageHTML = nil
        }
        // The page follows the text: toggling it on renders the current draft,
        // and a change to the text while it shows re-renders (the revision
        // says when, without hashing the page). Off, nothing is fetched. Nor
        // is it before the text has loaded: rendering then would post an
        // empty doc that the loaded text cancels a moment later.
        .task(id: chrome.showsPage && snapshot != nil ? "page:\(titleDraft):\(draftRevision):\(pageEdit?.renderKey ?? "")" : "editor") {
            guard chrome.showsPage, snapshot != nil else { return }
            await renderPage()
        }
        // Leaving the page drops a proposal that was never kept: the editor
        // shows the draft, and the draft is what the page comes back to.
        .onChange(of: chrome.showsPage) { _, showsPage in
            if !showsPage, let pageEdit, pageEdit.status != .kept { self.pageEdit = nil }
            // The match belongs to the surface that is leaving; the bar
            // reopens over the other one with Cmd+F.
            findState.close()
        }
        // The autosave runs from `editorDraft`, 800 ms after the text last
        // changed (`setDraft`, `editorReported`), not from a task keyed on
        // the text, which re-ran this body at every report.
        // The notes graph follows the library — another doc saved, a page
        // made, an Idea linked — and the doc's own saves, half a second after
        // each settles (docs/notes-graph-design.md).
        .task(id: notesGraphLibrarySignature) {
            guard snapshot != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            notesGraph.libraryChanged(signature: notesGraphLibrarySignature)
        }
        .task(id: snapshot?.revision) {
            guard let revision = snapshot?.revision else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            notesGraph.bodySaved(revision: revision)
        }
        // A daily note's page foot lists what its day held, which grows as
        // the day is read and written in: heard two seconds after the log
        // last changed.
        .task(id: artifact.id) {
            guard dailyNoteDayKey != nil else { return }
            var pending: Task<Void, Never>?
            for await _ in NotificationCenter.default.notifications(named: .dayPlansDidChange) {
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    notesGraph.dayActivityChanged()
                }
            }
            pending?.cancel()
        }
        .onChange(of: blockReveal) { _, _ in applyBlockReveal() }
        // The header's comments control shows while comments are open.
        .onChange(of: comments, initial: true) { _, comments in
            chrome.openCommentCount = comments.filter { !$0.isResolved }.count
        }
        .onAppear {
            titleDraft = artifact.title
            // This editor takes the pane header over: every page opens here,
            // ready to type in, and nothing of the previous doc's carries across.
            chrome.reset()
            chrome.flushDraft = { try await flushDraft() }
            applyBlockReveal()
        }
        .onDisappear {
            vm.notePageSelection("", artifactID: artifact.id)
            editorDraft.cancelAutosave()
            save(draft)
            saveTitle()
            referenceArtworkTask?.cancel()
            notesGraph.close()
            chrome.flushDraft = nil
            // Closing a Doc publishes its body now rather than on idle (generation 2, D44).
            DocBodySync.requestPublish(artifact.id)
        }
        .onChange(of: artifact.title) { _, title in
            if !titleFocused { titleDraft = title }
            // Judged against the saved body, not the draft: a rename the
            // heading made is measured by the text it was made from, so
            // typing on in the heading does not bring the header back
            // between one save and the next.
            titleFollowsHeading = ArtifactMarkdownTitle.names(title, in: snapshot?.markdown ?? draft)
        }
        .onChange(of: titleFocused) { _, focused in
            guard !focused else { return }
            saveTitle()
            isEditingTitle = false
        }
        .onChange(of: artifact.updatedAt) { _, _ in
            Task { await refreshBodyAfterArtifactUpdate() }
        }
        // Another writer's body landed on disk — a teammate's edit through the
        // team's zone. Re-read at once rather than after the list reloads.
        .task(id: artifact.id) {
            for await notification in NotificationCenter.default.notifications(named: .cloudKitSyncRemoteStoreDidChange) {
                let changed = notification.userInfo?[CloudKitSyncNotificationInfo.changedArtifactIDsKey] as? [String] ?? []
                guard changed.contains(artifact.id) else { continue }
                await refreshBodyAfterArtifactUpdate()
            }
        }
        .onChange(of: chrome.publishDraftRequest) { _, request in
            guard let request else { return }
            chrome.publishDraftRequest = nil
            Task { await publishDraft(overwrite: request.overwrite) }
        }
        .confirmationDialog(
            "Someone else changed this page since your draft began",
            isPresented: $chrome.showDraftPublishConflict,
            titleVisibility: .visible
        ) {
            Button("Replace with My Draft", role: .destructive) {
                chrome.publishDraftRequest = ArtifactDraftPublishRequest(overwrite: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their changes and yours touch the same passage, so they cannot be combined.")
        }
        .confirmationDialog(
            "Discard this draft?",
            isPresented: $chrome.showDiscardDraftConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive) {
                Task { await vm.discardTeamDocDraft(artifact.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The team's page stays as it is.")
        }
        // The page menu's Export ▸ and Rename…, answered here, where the
        // text is (docs/docs-design.md).
        .onChange(of: chrome.exportRequest) { _, request in
            guard let request else { return }
            chrome.exportRequest = nil
            if request.delivery == .copy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft, forType: .string)
                vm.showToast("Copied as Markdown")
            } else {
                export(request.format)
            }
        }
        .onChange(of: chrome.titleEditRequestID) { _, _ in
            guard !isReadOnly, !chrome.showsPage else { return }
            isEditingTitle = true
            // After the menu has closed and handed focus back to the page.
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                titleFocused = true
            }
        }
        // Add to Chat and the card's New Chat: a chat about the page as a whole.
        .onChange(of: chrome.wholePageChatRequest) { _, request in
            guard let request else { return }
            chrome.wholePageChatRequest = nil
            Task { await openWholePageSideChat(request) }
        }
        // The picker's one job: what the highlighted passage stands on. It opens
        // showing the current answer and sends the whole edited set back at once.
        .sheet(item: $groundingRequest) { request in
            ArtifactSourcePicker(
                initial: request.sourceIDs,
                seed: request.selectedText,
                purpose: request.insertsCards ? .insert : .grounding
            ) { sourceIDs in
                // Nothing chosen writes nothing; for a passage it detaches.
                guard !(request.insertsCards && sourceIDs.isEmpty) else { return }
                groundingAttachment = ArtifactGroundingAttachment(
                    sourceIDs: sourceIDs,
                    citations: groundingCitations(for: sourceIDs),
                    insertsCards: request.insertsCards
                )
            }
        }
        // The draft is flushed first, so what Google receives is what the page
        // shows, and the autosave has nothing left to write once the doc is
        // read-only.
        .sheet(isPresented: $chrome.isConvertingToGoogleDoc) {
            ConvertToGoogleDocSheet(artifact: artifact) {
                try await flushDraft()
                _ = try await vm.convertDocToGoogleDoc(artifact.id)
            }
        }
        // The draft is flushed first so the page carries what the pane shows.
        .sheet(isPresented: $chrome.isPublishSheetPresented) {
            PublishDocSheet(artifact: artifact, existing: publishedStatus) { access, slug in
                try await flushDraft()
                return try await vm.publishDoc(artifact.id, access: access, slug: slug)
            } published: { status in
                // Publishing leaves the page where it is, as a Codex page's
                // Share does; View as Page shows it as foreverlm.com draws it.
                publishedStatus = status
            }
        }
        .confirmationDialog(
            "Unpublish ‘\(artifact.title)’?",
            isPresented: $chrome.showUnpublishConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unpublish", role: .destructive) {
                Task {
                    do {
                        try await vm.unpublishDoc(artifact.id)
                        publishedStatus = nil
                    } catch {
                        chrome.errorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("The published page on foreverlm.com is taken down and its link stops working. This Page stays in your library.")
        }
        // Image in the slash menu: the picture goes in at the caret, which is
        // still where the writer left it (`insertImage`).
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.png, .jpeg, .heic, .gif, .webP],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { chrome.errorMessage = error.localizedDescription }
                return
            }
            Task { await insertImage(from: url) }
        }
    }

    /// The stored title identifies the Doc; Markdown headings own the page
    /// hierarchy and are where the writer chooses scale.
    private static let titleFont = Font.system(size: 18, weight: .semibold)

    /// The title: the first field in the page, and the header's only content.
    /// Not drawn while the doc's first heading is its title
    /// (`titleFollowsHeading`): the page says the name already.
    /// The doc's controls — Page/Edit, its address, its overflow — are the
    /// pane header's (`ArtifactCanvas.docControls`), so this row is never drawn
    /// over the rendered page.
    private func header(inset: ArtifactPageInset) -> some View {
        HStack(spacing: 8) {
            if isEditingTitle {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(Self.titleFont)
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .focused($titleFocused)
                    .onAppear { titleFocused = true }
                    .onSubmit {
                        saveTitle()
                        titleFocused = false
                        // Return goes on into the page, as it does from a title
                        // in Notion and ChatGPT's Pages.
                        formatting.run(.focus)
                    }
                    .task(id: titleDraft) {
                        guard titleFocused else { return }
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        saveTitle()
                    }
            } else {
                // The same shape as the Docs-list row: a button that a click
                // activates and a press-and-move drags, carrying the doc and
                // the Docs pane on one provider, so the title drags wherever
                // the row does.
                Button {
                    if !isReadOnly { isEditingTitle = true }
                } label: {
                    Text(titleDraft.isEmpty ? "Title" : titleDraft)
                        .font(Self.titleFont)
                        .lineLimit(1)
                        .foregroundStyle(titleDraft.isEmpty ? .tertiary : .primary)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Title")
                .accessibilityValue(titleDraft)
                .accessibilityHint("Click to rename. Drag into a chat to add this page to it.")
                .onDrag {
                    StudioDragVisibility.shared.begin(centerTab: .notepad, artifactID: artifact.id)
                    return studioArtifactDragProvider(for: artifact)
                }
            }
        }
        .modifier(inset)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    /// A daily note's title row: its day, which is its name until it is
    /// clicked and renamed (emptying the name gives the day back),
    /// then ‹ and › to step a day back or forward — opening that
    /// day's note, made if it does not exist yet — and Today while the note
    /// is another day's (docs/notes-graph-design.md, "Daily Notes"). Today,
    /// ‹ and › show while the pointer is over the row, in
    /// slots that keep their size (the product owner: "cleaner and fewer buttons");
    /// ⇧⌘D still opens today. The day drags as a doc's title does, into a
    /// chat or to the center edge.
    private func dailyNoteHeader(dayKey: String, inset: ArtifactPageInset) -> some View {
        // The hover lives in its own view, so pointing at the row never
        // re-runs the editor's body.
        NotebookHoverRow(isActive: true) { isHovered in
            dailyNoteHeaderRow(dayKey: dayKey, revealsControls: isHovered, inset: inset)
        }
    }

    private func dailyNoteHeaderRow(dayKey: String, revealsControls: Bool, inset: ArtifactPageInset) -> some View {
        let previous = DailyNoteDays.dayKey(dayKey, offsetBy: -1)
        let next = DailyNoteDays.dayKey(dayKey, offsetBy: 1)
        return HStack(spacing: 2) {
            if isEditingTitle {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(Self.titleFont)
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .focused($titleFocused)
                    .onAppear { titleFocused = true }
                    .onSubmit {
                        saveTitle()
                        titleFocused = false
                    }
                    .task(id: titleDraft) {
                        guard titleFocused else { return }
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        saveTitle()
                    }
            } else {
                // Clicking the day renames the note, as a doc's title does;
                // a press-and-move drags it.
                Button {
                    if !isReadOnly { isEditingTitle = true }
                } label: {
                    Text(titleDraft.isEmpty ? (DailyNote.title(forDayKey: dayKey) ?? artifact.title) : titleDraft)
                        .font(Self.titleFont)
                        .lineLimit(1)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint("Click to rename. Drag into a chat to add this page to it.")
                .onDrag {
                    StudioDragVisibility.shared.begin(centerTab: .notepad, artifactID: artifact.id)
                    return studioArtifactDragProvider(for: artifact)
                }
            }
            if !DailyNoteDays.isToday(dayKey) {
                Button {
                    openDailyNote(DailyNoteDays.today())
                } label: {
                    Text("Today")
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .help("Today's daily note")
                .accessibilityLabel("Today")
                .opacity(revealsControls ? 1 : 0)
            }
            Group {
                dayStepButton(systemImage: "chevron.left", label: "Previous day", target: previous)
                dayStepButton(systemImage: "chevron.right", label: "Next day", target: next)
            }
            .opacity(revealsControls ? 1 : 0)
        }
        .modifier(inset)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private func dayStepButton(systemImage: String, label: String, target: String?) -> some View {
        Button {
            if let target { openDailyNote(target) }
        } label: {
            Image(systemName: systemImage)
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash)
        .disabled(target == nil)
        .help(target.flatMap { DailyNote.title(forDayKey: $0) }.map { "\(label): \($0)" } ?? label)
        .accessibilityLabel(label)
    }

    /// Another day's note, in this window's Docs.
    private func openDailyNote(_ dayKey: String) {
        Task { await vm.openDailyNote(dayKey: dayKey, in: windowState) }
    }

    /// What the highlighted passage stands on.
    ///
    /// This is the shelf's only job: listing everything the doc stands on —
    /// every chip anywhere in it, plus every source its Notebooks lend it —
    /// would be a pile that answers a question nobody is asking, and a permanent
    /// band under the page. Sources attached to a passage are invisible in the
    /// prose, so the moment they are worth showing is the moment a writer selects
    /// the passage, and this is where they appear.
    ///
    /// The doc-wide list is `documentContextSourceIDs`: a question about a
    /// passage that stands on nothing falls back to it. It is not drawn.
    /// The doc as a page, or why it cannot be shown yet.
    @ViewBuilder
    private var pageSurface: some View {
        if let pageHTML {
            ArtifactPageWebView(
                html: pageHTML,
                // A team Doc reads without a caret and without Edit; the
                // member's draft has both.
                editing: isReadOnly || snapshot == nil ? nil : DocPageEditing(review: pageEdit?.review),
                onAddToLibrary: { href in
                    Task {
                        let status = await vm.addReferenceToLibrary(href, teamID: vm.referenceLibraryTeamID(for: artifact))
                        switch status.state {
                        case .inLibrary: vm.showToast(artifact.teamID == nil ? "Added to your library" : "Added to the team library")
                        case .failed, .requestable: vm.showToast(status.message ?? "The source could not be added.")
                        // A standing request, or one this Mac can fulfil, is the
                        // card's business; the page surface has nothing to add.
                        case .absent, .adding, .requested, .fulfillable: break
                        }
                    }
                },
                onEditMessage: handlePageEditMessage,
                sourceForLines: { start, end in
                    isReadOnly ? nil : DocPagePassage.passage(markdown: draft, start: start, end: end)
                },
                findState: findState,
                findRevision: findState.searchRevision
            )
        } else if let pageError {
            VStack(spacing: 10) {
                Text(pageError)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button("Try Again") { Task { await renderPage() } }
                    .buttonStyle(.hoverWash)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Rendering the page…")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What the page draws: the proposal under review while there is one, else
    /// the draft.
    private var pageMarkdown: String { pageEdit?.candidate ?? draft }

    /// The page reads block references, title links and tags as their words,
    /// as the published page does — but line for line
    /// (`docGraphResolvedMarkdownKeepingLines`: an embed reads as its block's
    /// own words on its own line), because the page's Edit mode maps each
    /// block it draws back to the draft's lines. A resolution that would
    /// still move a line leaves the page on the draft as written.
    private func pageMarkdownForReaders(_ markdown: String) async -> String {
        guard NotesGraphHostText.mayHoldGraphMarkup(markdown) else { return markdown }
        let resolved = await vm.loggedRead("the page's embedded blocks") {
            try await vm.storage.docGraphResolvedMarkdownKeepingLines(markdown, teamID: graphTeamID)
        }
        guard let resolved else { return markdown }
        return NotesGraphHostText.lineKeepingResolution(original: markdown, resolved: resolved)
    }

    private func renderPage() async {
        pageError = nil
        do {
            let markdown = await pageMarkdownForReaders(pageMarkdown)
            // A link to another doc that has a page of its own becomes a link
            // to that page, as it does on foreverlm.com; the statuses the Docs
            // list already holds say which docs those are.
            let html = try await DocPublishing.page(
                title: titleDraft.isEmpty ? artifact.title : titleDraft,
                markdown: markdown,
                pageURL: publishedStatus?.url,
                publishedAt: publishedStatus?.publishedAt,
                docLinks: vm.publishedDocStatuses.mapValues { $0.url.absoluteString }
            )
            guard chrome.showsPage else { return }
            pageHTML = html
        } catch {
            // A render superseded by a newer draft is cancelled, not failed: the
            // replacement is already on its way, and "cancelled" is not a page
            // error the writer can act on.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            guard chrome.showsPage else { return }
            pageHTML = nil
            pageError = error.localizedDescription
        }
    }

    /// The page's Edit mode asking. The block's lines name a passage of the
    /// draft; the model answers on the Edit-with-AI route; the page is drawn
    /// again with the proposal in place; and only Keep writes.
    private func handlePageEditMessage(_ message: DocPageEditMessage) {
        guard !isReadOnly, snapshot != nil else { return }
        switch message {
        case .editRequested(let start, let end, let instruction, let selection):
            if let pageEdit, pageEdit.status == .working { return }
            let session = DocPageEditSession(start: start, end: end, instruction: instruction, selection: selection, original: draft)
            pageEdit = session
            performPageEdit(session)
        case .retry(let instruction):
            guard var session = pageEdit, session.status != .working else { return }
            session.instruction = instruction
            session.status = .working
            pageEdit = session
            performPageEdit(session)
        case .keep:
            guard var session = pageEdit, session.status == .proposed, let candidate = session.candidate else { return }
            setDraft(candidate)
            nextSaveVersionReason = .assistantEdit
            session.status = .kept
            pageEdit = session
        case .discard:
            pageEdit = nil
        case .undo:
            guard let session = pageEdit, session.status == .kept, let candidate = session.candidate, draft == candidate else {
                pageEdit = nil
                return
            }
            setDraft(session.original)
            if draft == snapshot?.markdown { nextSaveVersionReason = nil }
            pageEdit = nil
        case .sourceRequested:
            // Answered by the web view itself, from `sourceForLines`.
            break
        case .textEdited(let start, let end, let markdown):
            // The writer's own words, written as typing would be: no proposal
            // to review, only Undo for a moment.
            guard DocPagePassage.passage(markdown: draft, start: start, end: end) != nil else { return }
            let session = DocPageEditSession.kept(start: start, end: end, original: draft, markdown: markdown)
            guard let candidate = session.candidate else { return }
            setDraft(candidate)
            pageEdit = session
        }
    }

    private func performPageEdit(_ session: DocPageEditSession) {
        Task {
            var updated = session
            guard let request = DocPagePassage.request(
                markdown: session.original,
                start: session.start,
                end: session.end,
                instruction: session.instruction,
                selection: session.selection,
                docTitle: titleDraft.isEmpty ? artifact.title : titleDraft
            ) else {
                updated.status = .failed("The page no longer matches this Page's text. Try again from the redrawn page.")
                if pageEdit?.id == session.id { pageEdit = updated }
                return
            }
            do {
                let proposal = try await vm.editDocPassageWithAI(request)
                updated.propose(proposal)
            } catch {
                updated.status = .failed(error.localizedDescription)
            }
            // A decision taken meanwhile (Discard, a new request) wins.
            guard pageEdit?.id == session.id, pageEdit?.status == .working else { return }
            pageEdit = updated
        }
    }

    @ViewBuilder
    private var referencesShelf: some View {
        if editorSelection.hasText {
            Divider()
            selectionChatsRow
            shelfRow
        }
    }

    /// The conversations that started on the selected passage.
    ///
    /// Same rule as the shelf: a chat anchored to a paragraph is invisible in
    /// the prose, so it appears the moment the writer selects that paragraph and
    /// nowhere else on the page. The doc-wide list stays in the Comments panel. Offsets
    /// are trusted only for the saved revision the page is showing; a draft
    /// with unsaved edits has moved its positions, so the quote decides instead.
    private var selectionChatLinks: [ArtifactChatLink] {
        guard editorSelection.hasText, !chatLinks.isEmpty else { return [] }
        let revision = hasUnsavedChanges ? "" : (snapshot?.revision ?? "")
        let range = min(editorSelection.from, editorSelection.to)..<max(editorSelection.from, editorSelection.to)
        return chatLinks.filter {
            $0.link.anchors(selection: range, selectedText: editorSelection.text, inRevision: revision)
        }
    }

    @ViewBuilder
    private var selectionChatsRow: some View {
        let links = selectionChatLinks
        if !links.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .zoomedSystemFont(size: 10, weight: .medium)
                    .foregroundStyle(.tertiary)
                    .help("Chats that started on the selected passage")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(links) { entry in
                            ArtifactSelectionChatChip(
                                entry: entry,
                                open: { vm.requestResumeReviewSession(entry.session.id) },
                                forget: {
                                    Task {
                                        await vm.forgetArtifactChatLink(entry.link.id)
                                        chatLinks = await vm.artifactChatLinks(artifact.id)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 14)
            .padding(.top, 5)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chats about the selected passage")
        }
    }

    private var shelfRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "books.vertical")
                .zoomedSystemFont(size: 10, weight: .medium)
                .foregroundStyle(.tertiary)
                .help("What the selected passage stands on")

            if shelfSources.isEmpty {
                // A selected claim standing on nothing is worth saying plainly —
                // it is the one thing this row can tell a writer that the prose
                // cannot.
                Text("No sources linked to this passage yet")
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shelfSources) { entry in
                            ArtifactShelfChip(
                                article: entry.article,
                                bookCoverPath: entry.bookCoverPath,
                                title: entry.title,
                                isMuted: mutedShelfSourceIDs.contains(entry.id),
                                toggle: {
                                    if mutedShelfSourceIDs.remove(entry.id) == nil {
                                        mutedShelfSourceIDs.insert(entry.id)
                                    }
                                },
                                open: { onOpenSource(entry.article.id) }
                            )
                        }
                    }
                }
            }

            // The verb on a row that is about one passage can only mean one
            // thing: attach a source to that passage.
            Button {
                groundingRequest = ArtifactGroundingRequest(
                    selectedText: editorSelection.text,
                    sourceIDs: editorSelection.groundedSourceIDs
                )
            } label: {
                Image(systemName: "plus.circle")
                    .zoomedSystemFont(size: 11, weight: .medium)
            }
            .buttonStyle(.hoverWash(inset: -3))
            .foregroundStyle(.secondary)
            .help("Attach a source to this passage")
        }
        .frame(height: 30)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var documentSurface: some View {
        @Bindable var formatting = formatting
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isDownloadingFromICloud {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading from iCloud…")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot != nil {
            // Read so that a change the host made to the text brings this
            // pass back, and the pass hands the editor the text. The editor's
            // own reports go to `editorDraft` alone and bring nothing back.
            let _ = draftRevision
            ArtifactMarkdownEditorView(
                markdown: Binding(get: { editorDraft.text }, set: { editorReported($0) }),
                saveRequestID: 0,
                publicationRequestID: publicationRequestID,
                aiEditOpenRequestID: chrome.aiEditOpenRequestID,
                docTitle: titleDraft,
                sourceInsertion: $sourceInsertion,
                onSourceDragTargeted: { isSourceDropTargeted = $0 },
                // A drop on the page attaches to the passage under the pointer.
                // The editor's web view receives the drag itself, because
                // WebKit would otherwise claim it — see `ArtifactEditorWebView`.
                onSourceDrop: { transfers, location in
                    guard !isReadOnly else { return }
                    let citations = transfers.flatMap(citations(from:))
                    guard !citations.isEmpty else { return }
                    sourceInsertion = ArtifactSourceInsertion(
                        citations: citations,
                        editorLocation: location
                    )
                },
                // A doc or Notebook dropped on the page is written where it
                // landed as a titled link. The library's current name wins
                // over the one the drag carried, and a doc dropped on itself
                // writes nothing — a page pointing at itself is not a link.
                onLinkDrop: { transfers, location in
                    guard !isReadOnly else { return }
                    let links = transfers.compactMap(pageLink(for:))
                    guard !links.isEmpty else { return }
                    linkInsertion = ArtifactLinkInsertion(links: links, editorLocation: location)
                },
                linkInsertion: $linkInsertion,
                // A doc opens in this window's Docs. A day's link opens its
                // daily note, made when the day has none yet — the one write
                // opening a link does (docs/notes-graph-design.md).
                onOpenLink: { link in
                    Task {
                        if case .doc(let id) = link {
                            if let day = DailyNote.dayKey(ofID: id), !vm.artifacts.contains(where: { $0.id == id }) {
                                await vm.openDailyNote(dayKey: day, in: windowState)
                            } else {
                                await vm.openDoc(id, revealing: nil, in: windowState)
                            }
                        } else {
                            await vm.open(link)
                        }
                    }
                },
                linkTargets: linkTargets,
                referenceStatuses: referenceStatuses,
                onReferencesChange: { hrefs in
                    referenceHrefs = hrefs
                    Task { await refreshReferenceStatuses() }
                },
                // Add to Sources on a card. The card waits while the import
                // runs; only a card still waiting hears the answer, so a doc
                // that moved on in the meantime is not written over.
                onAddReference: { href in
                    referenceStatuses[href] = .adding
                    Task {
                        let teamID = vm.referenceLibraryTeamID(for: artifact)
                        var status = await vm.addReferenceToLibrary(href, teamID: teamID)
                        // On a team Doc an import that did not land is not the
                        // end: a teammate may hold the source. The card offers
                        // to ask them (docs/teams-design.md, decision 14).
                        if status.state == .failed, teamID != nil {
                            status = .requestable(status.message ?? "The source could not be added.")
                        }
                        if referenceStatuses[href] == .adding { referenceStatuses[href] = status }
                    }
                },
                onRequestReference: { href in
                    guard let teamID = vm.referenceLibraryTeamID(for: artifact) else { return }
                    referenceStatuses[href] = .adding
                    Task {
                        let status = await vm.requestShare(href, teamID: teamID, artifactID: artifact.id, title: referenceStatuses[href]?.title)
                        if referenceStatuses[href] == .adding { referenceStatuses[href] = status }
                    }
                },
                onFulfilReference: { href, requestID in
                    // Answering copies the source into the team: the first
                    // time, the learner affirms they may share it.
                    SharingRightsPrompt.shared.askIfNeeded {
                        referenceStatuses[href] = .adding
                        Task {
                            var status: ArtifactReferenceStatus = .failed("The request could not be answered.")
                            if let request = await vm.fulfilShareRequest(requestID), let copy = request.fulfilledSourceID {
                                status = .inLibrary(sourceID: copy)
                            }
                            if referenceStatuses[href] == .adding { referenceStatuses[href] = status }
                        }
                    }
                },
                // The check on a card opens the source beside the doc, the way
                // the References shelf does.
                onOpenSource: { sourceID in
                    Task { await vm.openLinkedSourceInReader(sourceID, beside: .notepad) }
                },
                attachmentDataURLs: attachmentDataURLs,
                attachmentInsertion: $attachmentInsertion,
                groundingAttachment: $groundingAttachment,
                formatRequest: $formatting.request,
                pageMaxWidth: pageMaxWidth,
                onPageWidthChange: { width, done in
                    let stored = ArtifactPageWidth.stored(width)
                    if done {
                        pageWidthPreference = stored
                        draggedPageWidth = nil
                    } else {
                        draggedPageWidth = stored
                    }
                },
                isEditable: !isReadOnly,
                foldDocumentID: artifact.id,
                notesGraph: notesGraph.bridge,
                findState: findState,
                findRevision: findState.searchRevision,
                onSave: save,
                onPublication: receivePublication,
                onRequestChat: { openChat(about: $0) },
                onRequestComment: { selection in
                    editorSelection = selection
                    pendingCommentSelection = selection
                    selectedCommentThreadID = nil
                    chrome.isCommentsVisible = true
                },
                onRequestGrounding: { request in groundingRequest = request },
                onRequestAIEdit: { request in try await vm.editDocPassageWithAI(request.edit) },
                // Image in the slash menu: the file picker for a picture.
                onRequestImage: { isImportingImage = true },
                // A screenshot pasted, a picture dropped: kept like a picked file,
                // one after another, and the temporary copies removed.
                onImageFiles: { files in
                    guard !isReadOnly else { return }
                    Task {
                        for file in files {
                            await insertImage(from: file)
                            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                        }
                    }
                },
                // Comments sit on their passages in the page, and a click on
                // the words opens the thread in the Comments panel.
                commentAnchors: ArtifactCommentThread.threads(from: comments).map(ArtifactCommentAnchor.init(thread:)),
                activeCommentID: chrome.isCommentsVisible ? selectedCommentThreadID : nil,
                onCommentAnchorClicked: { id in
                    selectedCommentThreadID = id
                    chrome.isCommentsVisible = true
                },
                onCommentAnchorsDetached: { detachedCommentThreadIDs = $0 },
                // An AI edit written into the page: the body before it is kept
                // in Page activity as "Before an AI edit".
                onAIEditWritten: { nextSaveVersionReason = .assistantEdit },
                // Generate image: drawn on the account's image model and kept in
                // this doc's Attachments; the editor writes it at the caret.
                onRequestImageGeneration: { [artifactID = artifact.id] request in
                    try await vm.generateDocImage(prompt: request.prompt, artifactID: artifactID)
                },
                onGeneratedImageInserted: { image in
                    attachmentDataURLs[image.token] = image.dataURL
                },
                // A Prompt block's Chat about this: Chat opens beside the page
                // with the prompt's words waiting, unsent, in the composer.
                onRequestPrompt: { text in openChat(withPrompt: text) },
                // File in the slash menu: any file, kept in this page's
                // Attachments and linked at the caret.
                onRequestFile: { await attachFile() },
                // Save file… on a link to an attached file.
                onOpenAttachment: { request in
                    Task { await saveAttachment(request) }
                },
                onSelectionChange: { selection in
                    if selection.hasText || editorSelection.hasText { editorSelection = selection }
                    formatting.activeFormats = selection.activeFormats
                    // A chat beside this Page shows the highlight as its quote.
                    vm.notePageSelection(selection.hasText ? selection.text : "", artifactID: artifact.id)
                },
                onError: { chrome.errorMessage = $0 }
            )
            .id(chrome.reloadGeneration)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // A source added or removed anywhere — the sidebar, an assistant,
            // another Mac through sync — changes what the cards should say.
            .onChange(of: vm.articles.count) { _, _ in
                Task { await refreshReferenceStatuses() }
            }
            // A request made, answered or declined anywhere in the team changes
            // what a team Doc's cards offer.
            .onChange(of: vm.openShareRequestsByTeamID) { _, _ in
                Task { await refreshReferenceStatuses() }
            }
            .overlay {
                if isSourceDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        } else {
            ContentUnavailableView(
                "Could not open page",
                systemImage: "exclamationmark.triangle",
                description: Text(chrome.errorMessage ?? "The page is unavailable.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Ask the library about the doc's reference cards. A card whose import is
    /// still running keeps its wait — that import answers for it — unless the
    /// library already reports the source, which is the answer either way.
    private func refreshReferenceStatuses() async {
        let hrefs = referenceHrefs
        guard !hrefs.isEmpty else {
            referenceArtworkTask?.cancel()
            referenceStatuses = [:]
            return
        }
        let teamID = vm.referenceLibraryTeamID(for: artifact)
        var fresh = await vm.referenceLibraryStatuses(for: hrefs, teamID: teamID)
        // On a team Doc a source the team lacks may already be asked for: the
        // card shows the standing request, and Share when this Mac holds it.
        if let teamID {
            for href in hrefs where fresh[href]?.state == .absent {
                guard let request = vm.openShareRequest(teamID: teamID, url: href) else { continue }
                fresh[href] = vm.canFulfil(request) ? .fulfillable(request) : .requested(request)
            }
        }
        for (href, status) in referenceStatuses {
            if status.state == .adding, fresh[href]?.state != .inLibrary {
                fresh[href] = .adding
            } else if status.state == .requestable, fresh[href]?.state == .absent {
                // The offer to ask stands until the library or a request answers.
                fresh[href] = status
            } else if let answer = fresh[href], answer.state == status.state, answer.sourceID == status.sourceID {
                // The same answer as before keeps the picture already resolved
                // for it, so a library change elsewhere does not blank every tile.
                fresh[href] = status
            }
        }
        referenceStatuses = fresh
        referenceArtworkTask?.cancel()
        referenceArtworkTask = Task { await resolveReferenceArtwork(order: hrefs) }
    }

    /// The cards' pictures, after the answers: the library's own artwork for a
    /// saved source, a link preview for one the library does not hold. Resolved
    /// in the doc's order, a few at a time, and handed over a batch at a time —
    /// every batch re-sends the whole map to the editor, so one message per
    /// card would be the wrong shape for a report with a hundred and fifty. The
    /// library's pictures come first: they are on disk and quick, and the
    /// previews wait on the network.
    private func resolveReferenceArtwork(order hrefs: [String]) async {
        let pending = hrefs.compactMap { href -> (String, ArtifactReferenceStatus)? in
            guard let status = referenceStatuses[href], status.kind == nil, status.state != .adding else { return nil }
            return (href, status)
        }
        guard !pending.isEmpty else { return }
        let saved = pending.filter { $0.1.state == .inLibrary }
        let unsaved = pending.filter { $0.1.state != .inLibrary }

        // A source card may name a source of another library than the one
        // open (a team's paper in a page of My Library); the open library's
        // list does not hold it, so storage is asked for it by id.
        var known = Dictionary(vm.articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (_, status) in saved {
            guard let id = status.sourceID, known[id] == nil,
                  let article = await vm.persistedArticle(forLinkToken: id) else { continue }
            known[id] = article
        }
        guard !Task.isCancelled else { return }
        let articlesByID = known
        for batch in Self.batches(of: saved, size: 8) {
            let resolved = await withTaskGroup(of: (String, ArtifactReferenceStatus).self) { group in
                for (href, status) in batch {
                    group.addTask {
                        var decorated = status
                        if let id = status.sourceID, let article = articlesByID[id] {
                            decorated.kind = article.sourceType.rawValue
                            decorated.title = article.title
                            decorated.detail = ReferenceCardArtwork.libraryDetail(for: article)
                            decorated.thumbnailURL = await ReferenceCardArtwork.libraryThumbnailURL(for: article)
                        } else {
                            decorated.kind = "page"
                        }
                        return (href, decorated)
                    }
                }
                var collected: [String: ArtifactReferenceStatus] = [:]
                for await (href, decorated) in group { collected[href] = decorated }
                return collected
            }
            guard !Task.isCancelled else { return }
            applyReferenceArtwork(resolved)
        }

        for batch in Self.batches(of: unsaved, size: 6) {
            let resolved = await withTaskGroup(of: (String, ArtifactReferenceStatus).self) { group in
                for (href, status) in batch {
                    group.addTask {
                        let preview = await ReferenceLinkPreviews.shared.preview(for: href)
                        var decorated = status
                        decorated.kind = preview.kind
                        decorated.thumbnailURL = preview.imageURL
                        decorated.iconURL = preview.iconURL
                        decorated.title = preview.title
                        decorated.detail = preview.detail
                        return (href, decorated)
                    }
                }
                var collected: [String: ArtifactReferenceStatus] = [:]
                for await (href, decorated) in group { collected[href] = decorated }
                return collected
            }
            guard !Task.isCancelled else { return }
            applyReferenceArtwork(resolved)
        }
    }

    /// A picture lands only on a card whose answer is still the one it was
    /// resolved for; a card that was added or removed in the meantime keeps the
    /// answer that arrived since.
    private func applyReferenceArtwork(_ resolved: [String: ArtifactReferenceStatus]) {
        for (href, decorated) in resolved {
            guard let current = referenceStatuses[href],
                  current.state == decorated.state,
                  current.sourceID == decorated.sourceID else { continue }
            referenceStatuses[href] = decorated
        }
    }

    private static func batches<Element>(of elements: [Element], size: Int) -> [[Element]] {
        stride(from: 0, to: elements.count, by: size).map { Array(elements[$0..<min($0 + size, elements.count)]) }
    }

    /// The editor's publication HTML, asked for by Export ▸ HTML… or PDF…:
    /// the page's title goes in as its title, and as its heading unless the
    /// body opens with it, then the file is written where the writer says.
    private func receivePublication(_ editorHTML: String) {
        guard let format = pendingPublicationExport else { return }
        pendingPublicationExport = nil
        let title = titleDraft.isEmpty ? artifact.title : titleDraft
        let html = PageExport.titledHTML(editorHTML, title: title, bodyOpensWithTitle: titleFollowsHeading)
        Task {
            guard let url = await PageExport.chooseDestination(title: title, format: format) else { return }
            do {
                let data = format == .pdf ? try await PageExport.pdf(fromHTML: html) : Data(html.utf8)
                try await PageExport.write(data, to: url)
                vm.showToast("Exported \(url.lastPathComponent)")
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }

    /// The page as its side chat is told about it: the stored revision, not the
    /// unsaved draft, which is the text `read_doc` returns and what
    /// `attachDocToChat` keeps to.
    private func sideChatPage(_ snapshot: ArtifactMarkdownSnapshot?) -> PageSideChatPage {
        PageSideChatPage(
            artifactID: artifact.id,
            title: artifact.title,
            revision: snapshot?.revision ?? "",
            notebookID: artifact.homeNotebookID,
            attachment: snapshot.map { ChatDocAttachment(snapshot: $0) }
        )
    }

    /// A chat about the page as a whole, for the side chat: the page rides
    /// along by identity, on the sources it stands on. The page is read from
    /// storage when the editor has not loaded it, so the chat is never opened
    /// without the page in its context.
    @MainActor
    private func openWholePageSideChat(_ request: PageSideChatWholePageRequest) async {
        let stored: ArtifactMarkdownSnapshot?
        if let snapshot {
            stored = snapshot
        } else {
            stored = await vm.loggedRead("the page") { try await vm.artifactMarkdown(artifact.id) }
        }
        chrome.sideChatRequest = PageSideChatOpening(
            page: sideChatPage(stored),
            sourceIDs: documentContextSourceIDs,
            passage: nil,
            draft: nil,
            joinsOpenChat: request.intent == .addToChat
        )
    }

    private func openChat(about selection: ArtifactEditorSelection) {
        // A highlighted passage is the sharpest question; without one, the
        // section the caret sits in is what the writer means by "here".
        let framing = selection.hasText ? selection.text : selection.sectionText
        // A window with a side chat over its pages opens the card instead of
        // docking the Chat pane, with the same passage, sources, page and
        // Notebook (docs/pages-side-chat-design.md).
        if chrome.hostsSideChat {
            let sourceIDs = chatSourceIDs(for: selection)
            chrome.sideChatRequest = PageSideChatOpening(
                page: sideChatPage(snapshot),
                sourceIDs: sourceIDs,
                passage: StudioViewModel.notepadSelectionRequest(
                    noteTitle: artifact.title,
                    sectionTitle: selection.sectionTitle,
                    selectedText: framing,
                    sourceIDs: sourceIDs,
                    artifactID: artifact.id,
                    artifactRevision: snapshot?.revision ?? "",
                    artifactNotebookID: artifact.homeNotebookID,
                    selectionRange: selection.hasText ? selection.from..<selection.to : nil,
                    contextExcerpt: selection.hasText ? selection.sectionText : nil,
                    artifactAttachment: snapshot.map { ChatDocAttachment(snapshot: $0) }
                ),
                draft: nil
            )
            return
        }
        vm.requestNotepadChat(
            noteTitle: artifact.title,
            sectionTitle: selection.sectionTitle,
            selectedText: framing,
            sourceIDs: chatSourceIDs(for: selection),
            artifactID: artifact.id,
            artifactRevision: snapshot?.revision ?? "",
            artifactNotebookID: artifact.homeNotebookID,
            selectionRange: selection.hasText ? selection.from..<selection.to : nil,
            contextExcerpt: selection.hasText ? selection.sectionText : nil,
            // The stored revision, not the unsaved draft: that is the text
            // `read_doc` returns, the same contract `attachDocToChat` keeps.
            artifactAttachment: snapshot.map { ChatDocAttachment(snapshot: $0) }
        )
    }

    /// Chat about the page as a whole, opened from a Prompt block: no passage is
    /// quoted, the page rides along so Chat can read it, its Notebook frames
    /// the chat, and the prompt's words wait under the composer to be edited
    /// and sent by the writer.
    private func openChat(withPrompt text: String) {
        if chrome.hostsSideChat {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            chrome.sideChatRequest = PageSideChatOpening(
                page: sideChatPage(snapshot),
                sourceIDs: documentContextSourceIDs,
                passage: nil,
                draft: words.isEmpty ? nil : words
            )
            return
        }
        vm.requestNotepadChat(
            noteTitle: artifact.title,
            selectedText: "",
            sourceIDs: documentContextSourceIDs,
            artifactID: artifact.id,
            artifactRevision: snapshot?.revision ?? "",
            artifactNotebookID: artifact.homeNotebookID,
            selectionRange: nil,
            contextExcerpt: nil,
            // The stored revision, as `openChat(about:)` attaches it.
            artifactAttachment: snapshot.map { ChatDocAttachment(snapshot: $0) },
            draft: text
        )
    }

    private struct ShelfSource: Identifiable {
        /// The grounding reference this row stands for, and its identity: a source
        /// id, or `book:<book-id>`.
        let id: String
        /// The source whose reader this row opens. For a book that is its first
        /// chapter, which is neither what the row is called nor what it looks like.
        let article: StudioArticle
        /// The book's cover, for a `book:` row. A chapter's own art is a figure
        /// from inside it, so a whole-book row draws this instead.
        let bookCoverPath: String?
        let title: String
    }

    /// What the highlighted passage stands on, one row per thing the writer
    /// attached or named.
    ///
    /// One row per *reference*, not per resolved source: a book is one thing to
    /// stand on, so attaching "How Life Works" draws one chip called that. It
    /// expands into its chapters for the question Chat receives, which is why the
    /// count here and the ids sent there legitimately differ.
    private var shelfSources: [ShelfSource] {
        var seen = Set<String>()
        var entries: [ShelfSource] = []
        for reference in editorSelection.citedSourceIDs {
            guard seen.insert(reference).inserted else { continue }
            if reference.hasPrefix(StudioViewModel.notepadGroundingBookPrefix) {
                let bookID = String(reference.dropFirst(StudioViewModel.notepadGroundingBookPrefix.count))
                guard let representative = vm.bookChapterArticlesInOrder(for: bookID).first else { continue }
                entries.append(ShelfSource(
                    id: reference,
                    article: representative,
                    bookCoverPath: vm.bookCoverPaths[bookID],
                    title: vm.bookDisplayName(bookID)
                ))
            } else if let article = vm.articlesById[reference] {
                entries.append(ShelfSource(
                    id: reference,
                    article: article,
                    bookCoverPath: nil,
                    title: article.title
                ))
            }
        }
        return entries
    }

    /// The grounding a question inherits from where it was asked.
    ///
    /// Highlighting two passages and asking about them has to put those sources in
    /// the chat and nothing else — a doc's whole shelf standing behind every
    /// question is how a chat ends up answering from a source the writer never
    /// pointed at. The doc-wide list is the fallback for a passage that stands on
    /// nothing of its own, where the doc itself is the only grounding there is.
    private func chatSourceIDs(for selection: ArtifactEditorSelection) -> [String] {
        let cited = vm.expandedGroundingSourceIDs(
            selection.citedSourceIDs.filter { !mutedShelfSourceIDs.contains($0) }
        )
        return cited.isEmpty ? documentContextSourceIDs : cited
    }

    /// Everything the doc stands on: every source referenced anywhere in it, then
    /// every source its Notebooks lend it. No longer drawn anywhere — the shelf
    /// shows the selected passage — but still the fallback grounding.
    private var documentContextSourceIDs: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for sourceID in vm.sourceIDsReferencedByNotepadMarkdown(draft) {
            guard vm.articlesById[sourceID] != nil, seen.insert(sourceID).inserted else { continue }
            ordered.append(sourceID)
        }
        for notebookID in artifact.linkedNotebookIDs {
            for sourceID in vm.notebook(id: notebookID)?.approvedSourceIDs ?? [] {
                guard vm.articlesById[sourceID] != nil, seen.insert(sourceID).inserted else { continue }
                ordered.append(sourceID)
            }
        }
        return ordered.filter { !mutedShelfSourceIDs.contains($0) }
    }

    @MainActor
    private func load() async {
        isLoading = true
        isDownloadingFromICloud = false
        chrome.errorMessage = nil
        while !Task.isCancelled {
            do {
                let loaded = await vm.keepingDocPictures(of: try await vm.artifactMarkdown(artifact.id))
                snapshot = loaded
                setDraft(loaded.markdown)
                titleFollowsHeading = ArtifactMarkdownTitle.names(artifact.title, in: loaded.markdown)
                titleRowHeld = !titleFollowsHeading
                // A page stored with a title that differs from its opening
                // heading takes the heading's words, once, as it opens.
                // Off the load, so the page is not held while the title is saved.
                if titleDraft.isEmpty { titleDraft = artifact.title }
                Task { await saveInferredTitleIfNeeded(from: loaded.markdown) }
                // A page made a moment ago opens on its name, as ChatGPT's and
                // Notion's do: type it, press Return, and the caret is in the
                // page. Left empty, it keeps the placeholder and still takes its
                // first heading.
                if !isReadOnly, dailyNoteDayKey == nil,
                   loaded.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   ArtifactPlaceholderTitle.isPlaceholder(artifact.title) {
                    titleDraft = ""
                    isEditingTitle = true
                }
                attachmentDataURLs = try await vm.artifactAttachmentDataURLs(
                    artifact.id,
                    markdown: loaded.markdown
                )
                comments = try await vm.artifactComments(artifact.id)
                chatLinks = await vm.artifactChatLinks(artifact.id)
                heldRemoteMarkdown = await vm.artifactHeldRemoteMarkdown(artifact.id)
                isDownloadingFromICloud = false
                isLoading = false
                openNotesGraph(revision: loaded.revision)
                return
            } catch ArtifactError.downloading(_) {
                snapshot = nil
                isLoading = false
                isDownloadingFromICloud = true
                guard let documentURL = await vm.artifactFileURL(artifact.id) else { return }
                await ICloudFileChangeMonitor.waitForChangeOrBackstop(
                    at: documentURL.deletingLastPathComponent(),
                    timeout: .seconds(1)
                )
            } catch {
                snapshot = nil
                isDownloadingFromICloud = false
                chrome.errorMessage = error.localizedDescription
                isLoading = false
                return
            }
        }
    }

    /// The doc's graph, read once its body is here: the editor learns the
    /// block texts it references, which titles name pages, how often its own
    /// blocks are referenced and what points at it, and its requests are
    /// answered (docs/notes-graph-design.md).
    private func openNotesGraph(revision: String) {
        if !vm.hasLoadedIdeasOnce {
            // `[[` offers the Ideas, and a doc's Linked References list the
            // Ideas linked to it; the library heard about them changes the
            // signature, and the graph is read again.
            Task { await vm.loadIdeas() }
        }
        notesGraph.open(
            docID: artifact.id,
            pageID: vm.teamArtifactID(forDraft: artifact.id) ?? artifact.id,
            teamID: graphTeamID,
            vm: vm,
            window: windowState,
            librarySignature: notesGraphLibrarySignature,
            revision: revision,
            draft: { draft },
            replaceInDraft: { old, new in
                let replaced = draft.replacingOccurrences(of: old, with: new)
                if replaced != draft { setDraft(replaced) }
            },
            // A page made from the editor opens in this pane: the draft is
            // written first, so the link to it is kept.
            flushDraft: { try await flushDraft() }
        )
    }

    /// A block asked to be shown in this doc: the editor shows it once it
    /// holds the doc. The rendered page has no blocks to flash, so a doc
    /// showing it comes back to the editor for it.
    private func applyBlockReveal() {
        guard let blockReveal, blockReveal.artifactID == artifact.id else { return }
        if chrome.showsPage { chrome.showsPage = false }
        notesGraph.bridge.reveal(blockReveal)
    }

    /// The body on disk moved on — another writer's edit arrived through
    /// CloudKit, or this Mac's own save landed — and the editor follows it.
    ///
    /// `updatedAt` also advances for this editor's own body saves and for
    /// metadata-only changes such as a title edit, and rebuilding the WebView
    /// for either one would destroy its caret-anchored Source menu, so the
    /// revision is compared first. A clean draft simply takes the new body. A
    /// draft with unsaved typing is merged with it line by line, against the
    /// body this editor opened, so a teammate's paragraph and this writer's
    /// both stand; when both changed the same passage the writer's draft stays
    /// on screen and the other version is held for them to choose.
    @MainActor
    private func refreshBodyAfterArtifactUpdate() async {
        guard let openedSnapshot = snapshot,
              !isSaving,
              !isUpdatingTitle else { return }

        do {
            let latest = try await vm.artifactMarkdown(artifact.id)
            let held = await vm.artifactHeldRemoteMarkdown(artifact.id)
            if latest.revision != openedSnapshot.revision {
                let latestAttachmentURLs = try await vm.artifactAttachmentDataURLs(
                    artifact.id,
                    markdown: latest.markdown
                )
                // A save may have started while storage was being read; it
                // owns the revision then, and its completion comes back here.
                guard snapshot?.revision == openedSnapshot.revision,
                      !isSaving,
                      !isUpdatingTitle else { return }
                if !hasUnsavedChanges {
                    setDraft(latest.markdown)
                } else {
                    switch ArtifactThreeWayMerge.merge(
                        base: openedSnapshot.markdown,
                        mine: draft,
                        theirs: latest.markdown
                    ) {
                    case .merged(let merged):
                        // Autosave carries the combined text back out.
                        setDraft(merged)
                    case .conflict:
                        heldRemoteMarkdown = latest.markdown
                    }
                }
                snapshot = latest
                titleFollowsHeading = ArtifactMarkdownTitle.names(artifact.title, in: draft)
                attachmentDataURLs = latestAttachmentURLs
            }
            if let held, heldRemoteMarkdown == nil { heldRemoteMarkdown = held }
        } catch ArtifactError.downloading(_) {
            // Keep the intact local draft visible while iCloud materializes the
            // newer package. A later file-change event will advance updatedAt.
        } catch {
            chrome.errorMessage = error.localizedDescription
        }
    }

    /// Two versions of one passage, and only the writer can say which stands.
    /// Theirs is held off screen; Keep mine saves this draft over it, Use
    /// theirs takes it in place of the draft.
    @ViewBuilder
    private func heldVersionBanner(inset: ArtifactPageInset) -> some View {
        if heldRemoteMarkdown != nil {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text("Changed elsewhere while you were editing")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Use theirs") { resolveHeldRemoteVersion(keepMine: false) }
                    .buttonStyle(.hoverWash)
                Button("Keep mine") { resolveHeldRemoteVersion(keepMine: true) }
                    .buttonStyle(.hoverWash)
            }
            .modifier(inset)
            .padding(.vertical, 6)
        }
    }

    private func resolveHeldRemoteVersion(keepMine: Bool) {
        guard let held = heldRemoteMarkdown else { return }
        heldRemoteMarkdown = nil
        if !keepMine { setDraft(held) }
        Task { await vm.discardArtifactHeldRemoteMarkdown(artifact.id) }
        save(draft)
    }

    /// Publish this draft to its team: the text goes through first, so the
    /// stored body is what publishes.
    @MainActor
    private func publishDraft(overwrite: Bool) async {
        do {
            try await flushDraft()
            try await vm.publishTeamDocDraft(artifact.id, overwrite: overwrite)
        } catch ArtifactError.conflict {
            chrome.showDraftPublishConflict = true
        } catch {
            chrome.errorMessage = error.localizedDescription
        }
    }

    private func save(_ markdown: String) {
        guard let snapshot, markdown != snapshot.markdown else { return }
        if isSaving {
            saveQueued = true
            return
        }
        isSaving = true
        chrome.errorMessage = nil
        let versionReason = nextSaveVersionReason ?? .learnerEdit
        nextSaveVersionReason = nil
        Task {
            do {
                let saved = try await vm.saveArtifactMarkdown(
                    artifactID: artifact.id,
                    markdown: markdown,
                    expectedRevision: snapshot.revision,
                    versionReason: versionReason
                )
                self.snapshot = saved
                if draft == markdown { setDraft(saved.markdown) }
                await saveInferredTitleIfNeeded(from: saved.markdown)
            } catch ArtifactError.conflict {
                // Another writer's body landed between this draft's snapshot
                // and its save. Merge against what was opened, then save the
                // result; `draft` already holds the newest typing, so a save
                // queued behind this one has nothing more to add.
                isSaving = false
                saveQueued = false
                await refreshBodyAfterArtifactUpdate()
                if hasUnsavedChanges, heldRemoteMarkdown == nil { save(draft) }
                return
            } catch {
                chrome.errorMessage = error.localizedDescription
            }
            isSaving = false
            if saveQueued {
                saveQueued = false
                // The draft as it is now. Replaying the text the queued request
                // carried set the draft back to it, and the editor with it
                // (`setMarkdown`): words typed while the first save was out
                // vanished and the caret jumped.
                save(draft)
            }
        }
    }

    /// Write the draft through now and wait for it, where `save(_:)` schedules
    /// and returns. Used before the doc changes kind: a conversion sends the
    /// stored body, so the stored body has to be the page.
    private func flushDraft() async throws {
        // The page's text as it stands, not the draft, which trails typing by
        // the editor's pause: the buttons that call this (Share, Duplicate,
        // Restore, Convert) never take focus from the page, so nothing has
        // told the pane about the last words yet.
        try await notesGraph.bridge.syncMarkdownFromPage()
        // A save already in flight owns the revision; let it land first.
        while isSaving {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let snapshot, draft != snapshot.markdown else { return }
        isSaving = true
        defer { isSaving = false }
        let versionReason = nextSaveVersionReason ?? .learnerEdit
        nextSaveVersionReason = nil
        let saved = try await vm.saveArtifactMarkdown(
            artifactID: artifact.id,
            markdown: draft,
            expectedRevision: snapshot.revision,
            versionReason: versionReason
        )
        self.snapshot = saved
    }

    /// **Restore This Version**: the typing on screen is written first, so the
    /// version list keeps it; then the version is written over it, keeping
    /// what it replaces as a version, and the editor takes the restored text
    /// the way it takes a body another writer saved.
    @MainActor
    private func restoreVersion(_ version: PageVersion) async throws {
        try await flushDraft()
        guard let opened = snapshot else { throw ArtifactError.unavailable(artifact.title) }
        isSaving = true
        defer { isSaving = false }
        let restored = try await vm.restorePageVersion(
            artifact.id,
            version: version,
            expectedRevision: opened.revision
        )
        snapshot = restored
        setDraft(restored.markdown)
        titleFollowsHeading = ArtifactMarkdownTitle.names(artifact.title, in: restored.markdown)
        let restoredURLs = await vm.loggedRead("the restored page's pictures") {
            try await vm.artifactAttachmentDataURLs(artifact.id, markdown: restored.markdown)
        }
        if let urls = restoredURLs {
            attachmentDataURLs = urls
        }
    }

    /// **Export ▸**. Markdown is the text on screen. HTML and PDF are the
    /// page as the editor draws it — its publication HTML, pictures inside —
    /// so the rendered page, which has no editor beneath it, hands the pane
    /// to the editor first.
    private func export(_ format: PageExportFormat) {
        let title = titleDraft.isEmpty ? artifact.title : titleDraft
        switch format {
        case .markdown:
            let markdown = draft
            Task {
                guard let url = await PageExport.chooseDestination(title: title, format: .markdown) else { return }
                do {
                    try await PageExport.write(Data(markdown.utf8), to: url)
                    vm.showToast("Exported \(url.lastPathComponent)")
                } catch {
                    vm.errorMessage = error.localizedDescription
                }
            }
        case .html, .pdf:
            guard snapshot != nil else { return }
            pendingPublicationExport = format
            if chrome.showsPage {
                chrome.showsPage = false
                // The editor is made on this pass with the current request
                // id; a later bump is what it answers.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    publicationRequestID += 1
                }
            } else {
                publicationRequestID += 1
            }
        }
    }

    private func saveTitle() {
        let typed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Emptying a daily note's title gives it its day back.
        let title = typed.isEmpty ? (dailyNoteDayKey.flatMap { DailyNote.title(forDayKey: $0) } ?? "") : typed
        guard !title.isEmpty else {
            titleDraft = artifact.title
            return
        }
        guard title != artifact.title else {
            titleDraft = title
            return
        }
        titleDraft = title
        // A page named by its heading is renamed in the heading too (storage
        // writes it with the title, `StorageService.updateArtifact`), so the
        // title and the heading stay one string and the header stays folded
        // into the heading. A name typed to match the heading folds it too.
        let heading = ArtifactMarkdownTitle.first(in: draft) != nil
        titleFollowsHeading = ArtifactMarkdownTitle.names(title, in: draft)
            || (heading && ArtifactMarkdownTitle.canBeNamedByBody(artifact))
        isUpdatingTitle = true
        Task {
            await vm.updateArtifact(artifactID: artifact.id, title: title)
            isUpdatingTitle = false
            // The heading was rewritten with the title: the editor takes it.
            await refreshBodyAfterArtifactUpdate()
        }
    }

    /// The page's Comments panel (`PageCommentsSidebar`): its threads, and
    /// the chats its passages started.
    private var commentsSidebar: some View {
        PageCommentsSidebar(
            artifactID: artifact.id,
            comments: $comments,
            chatLinks: $chatLinks,
            pendingSelection: $pendingCommentSelection,
            selectedThreadID: $selectedCommentThreadID,
            detachedThreadIDs: detachedCommentThreadIDs,
            prepareToComment: { try await saveDraftBeforeComment() },
            onClose: { chrome.isCommentsVisible = false },
            onError: { chrome.errorMessage = $0 }
        )
    }

    /// A comment is anchored on the saved text: the draft is written first
    /// when it holds words the store has not seen.
    private func saveDraftBeforeComment() async throws {
        guard let openedSnapshot = snapshot, draft != openedSnapshot.markdown else { return }
        snapshot = try await vm.saveArtifactMarkdown(
            artifactID: artifact.id,
            markdown: draft,
            expectedRevision: openedSnapshot.revision
        )
    }

    /// File in the slash menu: the writer picks any file, and the page keeps a
    /// copy of it in its Attachments. Nil when they cancel or the file cannot
    /// be kept (over 25 MB, empty, a folder, a linked page); the reason is
    /// shown, and nothing is cut to fit.
    @MainActor
    private func attachFile() async -> ArtifactFileAttachment? {
        guard let url = await FilePanel.open({ panel in
            panel.message = "Choose a file to attach to this page"
            panel.prompt = "Attach"
        }).first else { return nil }
        do {
            return try await vm.importArtifactFile(url, artifactID: artifact.id)
        } catch {
            chrome.errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Save file… on a link to an attached file: a copy goes where the writer
    /// chooses, under the name the link shows. A token that is not one this app
    /// wrote is refused before anything is read.
    @MainActor
    private func saveAttachment(_ request: ArtifactAttachmentOpenRequest) async {
        do {
            let source = try await vm.artifactAttachmentFileURL(artifact.id, token: request.token)
            let suggested = ArtifactFileAttachment.suggestedFileName(
                linkName: request.name,
                token: request.token,
                pageTitle: artifact.title
            )
            guard let destination = await FilePanel.save({ panel in
                panel.nameFieldStringValue = suggested
                panel.message = "Save a copy of this file"
            }) else { return }
            try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: source, options: [.mappedIfSafe])
                try data.write(to: destination, options: .atomic)
            }.value
            vm.showToast("Saved \(destination.lastPathComponent)")
        } catch {
            vm.showToast("Could not save the file: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func insertImage(from url: URL) async {
        do {
            let attachment = try await vm.importArtifactImage(url, artifactID: artifact.id)
            let urls = try await vm.artifactAttachmentDataURLs(
                artifact.id,
                markdown: draft + "\n\n![](" + "foreverlm://attachment/" + attachment.token + ")"
            )
            attachmentDataURLs.merge(urls) { _, new in new }
            guard let dataURL = attachmentDataURLs[attachment.token] else {
                throw ArtifactBodyPackageError.missingAttachment(attachment.token)
            }
            attachmentInsertion = ArtifactAttachmentInsertion(
                token: attachment.token,
                altText: attachment.altText,
                dataURL: dataURL
            )
        } catch {
            chrome.errorMessage = error.localizedDescription
        }
    }

    /// A page whose body opens with a `# ` heading is named by it
    /// (`ArtifactMarkdownTitle`): the stored title takes the heading's words
    /// whenever they differ, so a body an assistant wrote under another
    /// wording, a heading typed over, and a title that drifted all end as one
    /// string and the header never says the name twice. A heading deleted
    /// outright leaves the title standing and brings the header back. Run
    /// after a save and when the page opens, which repairs a page stored
    /// with two names.
    private func saveInferredTitleIfNeeded(from markdown: String) async {
        guard titleDraft == artifact.title, !titleFocused else { return }
        guard let heading = ArtifactMarkdownTitle.first(in: markdown) else {
            titleFollowsHeading = false
            return
        }
        titleFollowsHeading = ArtifactMarkdownTitle.names(artifact.title, in: markdown)
        guard ArtifactMarkdownTitle.canBeNamedByBody(artifact),
              let adopted = ArtifactMarkdownTitle.adoptedTitle(replacing: artifact.title, in: markdown) else { return }
        titleFollowsHeading = true
        titleDraft = adopted
        isUpdatingTitle = true
        await vm.updateArtifact(artifactID: artifact.id, title: heading)
        isUpdatingTitle = false
    }

}

private extension ArtifactEditor {

    /// What a link typed into this doc can point at: the other docs of the
    /// same library — a team Doc offers the team's docs, a doc in My Library
    /// offers My Library's, because a teammate cannot follow a link into a
    /// library they do not have — newest edit first, then the open Ideas (My
    /// Library's own, so not in a team's Doc), then the Notebooks, then the
    /// learner's recent chats (also My Library's own, for `@`). Archived
    /// and hidden docs stay out, and so does the doc itself; so do the daily
    /// notes, which the editor offers as days. The detail column says where
    /// a doc is filed, or that it is a draft.
    var linkTargets: [ArtifactPageLinkTarget] {
        let docs = ArtifactPageLinkTargets.docs(
            vm.artifacts,
            openDocID: artifact.id,
            teamID: artifact.teamID,
            isAudioOverview: { vm.isAudioOverview($0) },
            filedUnder: { $0.homeNotebookID.flatMap { vm.notebook(id: $0)?.title } ?? "" }
        )
        let ideas = graphTeamID == nil ? ArtifactPageLinkTargets.ideas(vm.ideas) : []
        let notebooks = vm.notebooks.map {
            ArtifactPageLinkTarget(link: .notebook($0.id), title: $0.title, detail: "Notebook")
        }
        // A teammate cannot open the learner's chats, so a team page offers none.
        let chats = graphTeamID == nil ? ArtifactPageLinkTargets.chats(vm.reviewSessionLinks) : []
        return docs + ideas + notebooks + chats
    }

    /// The link a dropped doc or Notebook becomes, named from the library.
    private func pageLink(for transfer: ArtifactPageLinkTransfer) -> ArtifactPageLink? {
        switch transfer.link {
        case .doc(let id):
            guard id != artifact.id else { return nil }
            let title = vm.artifacts.first { $0.id == id }?.title ?? transfer.title
            guard let title, !title.isEmpty else { return nil }
            return ArtifactPageLink(title: title, link: transfer.link)
        case .notebook(let id):
            guard let notebook = vm.notebook(id: id) else { return nil }
            return ArtifactPageLink(title: notebook.title, link: transfer.link)
        case .chat(let id):
            let title = vm.reviewSessionLinks.first { $0.id == id }?.title ?? transfer.title
            guard let title, !title.isEmpty else { return nil }
            return ArtifactPageLink(title: title, link: transfer.link)
        case .quiz(let id):
            let title = vm.courseQuiz(id)?.title ?? transfer.title
            guard let title, !title.isEmpty else { return nil }
            return ArtifactPageLink(title: title, link: transfer.link)
        case .idea(let id):
            let title = vm.ideas.first { $0.id == id }?.title ?? transfer.title
            guard let title, !title.isEmpty else { return nil }
            return ArtifactPageLink(title: title, link: transfer.link)
        }
    }

    /// The picker's answer as citations, for the footnotes the newly attached
    /// sources leave. An id is a source, or `book:<id>` for a whole book, which
    /// stands as its first chapter under the book's name, as a book row dropped
    /// on the page does. An id the library does not hold has no citation, and
    /// is attached without a note.
    func groundingCitations(for tokens: [String]) -> [ArtifactSourceCitation] {
        tokens.compactMap { token in
            if token.hasPrefix("book:") {
                let bookID = String(token.dropFirst("book:".count))
                guard let representative = vm.bookChapterArticlesInOrder(for: bookID).first else { return nil }
                return ArtifactSourceCitation(
                    sourceID: representative.id,
                    title: vm.bookDisplayName(bookID),
                    bookID: bookID
                )
            }
            guard let source = vm.articlesById[token] else { return nil }
            return ArtifactSourceCitation(sourceID: token, title: source.title)
        }
    }

    private func citations(from transfer: StudioArticleTransfer) -> [ArtifactSourceCitation] {
        let sourceIDs = transfer.draggedSourceIDs
        let sources = sourceIDs.compactMap { vm.articlesById[$0] }
        let bookIDs = Set(sources.compactMap { source -> String? in
            guard source.sourceType == .book else { return nil }
            return source.parentGroup
        })
        if bookIDs.count == 1, let bookID = bookIDs.first,
           sources.count == sourceIDs.count,
           sources.allSatisfy({ $0.sourceType == .book && $0.parentGroup == bookID }),
           let representative = vm.bookChapterArticlesInOrder(for: bookID).first {
            return [ArtifactSourceCitation(
                sourceID: representative.id,
                title: vm.bookDisplayName(bookID),
                bookID: bookID
            )]
        }
        return sourceIDs.compactMap { sourceID in
            if let source = vm.articlesById[sourceID] {
                return ArtifactSourceCitation(sourceID: source.id, title: source.title)
            }
            // A source the library does not hold is named only by the drag
            // that carried its title; a drag that carried none writes nothing.
            guard sourceID == transfer.articleId, !transfer.title.isEmpty else { return nil }
            return ArtifactSourceCitation(sourceID: sourceID, title: transfer.title)
        }
    }
}

/// One source on the note's shelf. The title opens the source; the trailing
/// check controls whether the next Chat question receives it as grounding.
/// One conversation that started on the selected passage, as a chip in the
/// row above the shelf. Named for the chat; the words it was asked about live in
/// the tooltip, since the writer is looking at them.
private struct ArtifactSelectionChatChip: View {
    let entry: ArtifactChatLink
    let open: () -> Void
    let forget: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .zoomedSystemFont(size: 9)
                    .foregroundStyle(Color.accentColor)
                Text(entry.displayTitle)
                    .zoomedSystemFont(size: 10)
                    .lineLimit(1)
                Text(entry.link.createdAt, style: .relative)
                    .zoomedSystemFont(size: 9)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 220, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .background(
            Color.primary.opacity(0.07),
            in: Capsule()
        )
        .help("Open this chat — about: \(entry.link.anchorQuote)")
        .accessibilityLabel("Open chat \(entry.displayTitle), about: \(entry.link.anchorQuote)")
        .contextMenu {
            Button("Open Chat", systemImage: "bubble.left.and.text.bubble.right") { open() }
            OtherWindowMenuItem(.chat(entry.session.id))
            Button("Forget This Link", systemImage: "link.badge.minus", role: .destructive) { forget() }
        }
    }
}

private struct ArtifactShelfChip: View {
    let article: StudioArticle
    /// A whole book's cover. Its `article` is one chapter, whose own art is a
    /// picture from inside the book rather than its front.
    let bookCoverPath: String?
    /// What the row is called. A book's row is named for the book, not for the
    /// chapter that happens to stand for it.
    let title: String
    let isMuted: Bool
    let toggle: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Button(action: open) {
                HStack(spacing: 5) {
                    SourceThumbnail(source: article, size: 20, bookCoverPath: bookCoverPath)

                    Text(title)
                        .zoomedSystemFont(size: 10)
                        .lineLimit(1)
                }
                .padding(.leading, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: 176, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help("Open \(title)")
            .accessibilityLabel("Open \(title)")

            Button(action: toggle) {
                Image(systemName: isMuted ? "circle" : "checkmark.circle.fill")
                    .zoomedSystemFont(size: 9, weight: .medium)
                    .foregroundStyle(isMuted ? Color.secondary.opacity(0.6) : Color.accentColor)
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help(isMuted ? "Add when opening Chat" : "Don't add when opening Chat")
            .accessibilityLabel(isMuted ? "Add \(title) when opening Chat" : "Don't add \(title) when opening Chat")
        }
        .background(
            Color.primary.opacity(0.07),
            in: Capsule()
        )
        .opacity(isMuted ? 0.45 : 1)
        .contextMenu {
            Button("Open in Reader", systemImage: "book") { open() }
            OtherWindowSourceMenuItem(article)
            Button(
                isMuted ? "Add When Opening Chat" : "Don't Add When Opening Chat",
                systemImage: isMuted ? "plus.circle" : "minus.circle"
            ) { toggle() }
        }
    }
}
