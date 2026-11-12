// The source sidebar's group labels, group menus and collection drops.
import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension StudioSidebar {
    /// A book file dropped on a Books-tab row imports it. Sources and groups
    /// dropped on a collection do not join it as a course; courses have their
    /// own pane (courses-design.md), where a drop does that.
    func handleGroupedCollectionDrop(_ providers: [NSItemProvider], groupName: String) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if sidebar.sidebarTab == .books {
                    handled = handleBookFileDrop([provider]) || handled
                }
                continue
            }
        }
        return handled
    }

    func sidebarGroupExpansionBinding(
        groupName: String,
        items: [StudioArticle]
    ) -> Binding<Bool> {
        Binding(
            get: { sidebar.expandedGroups.contains(groupName) },
            set: { isExpanded in
                if isExpanded {
                    sidebar.expandedGroups.insert(groupName)
                } else {
                    sidebar.expandedGroups.remove(groupName)
                    // Clear selection if the selected item is inside this collapsing group.
                    let itemIDs = Set(items.map(\.id))
                    if !windowState.sidebarSelectedSourceIDs.isDisjoint(with: itemIDs) {
                        windowState.sidebarSelectedSourceIDs.subtract(itemIDs)
                    }
                }
            }
        )
    }

    func expandableGroupLabel(groupName: String, itemCount: Int) -> some View {
        // The hover lives in its own view, so the count can show under the
        // pointer without re-running the list's body.
        SourceGroupRowHover { isHovered in
            courseOrBookGroupLabel(groupName: groupName, itemCount: itemCount, countRevealed: isHovered)
        }
            .onDrop(of: [.studioArticle, .studioGroup] + supportedBookImportDropTypes, isTargeted: nil) { providers in
                handleGroupedCollectionDrop(providers, groupName: groupName)
            }
            .onDrag {
                let sourceIDs = vm.sourceIDsForGroupInOrder(groupName)
                StudioDragVisibility.shared.begin(
                    articleIDs: sourceIDs,
                    groupName: groupName
                )
                return groupDragProvider(
                    for: StudioGroupTransfer(groupName: groupName, sourceIDs: sourceIDs)
                )
            }
    }

    /// A collection row's label. The count of
    /// a series or playlist shows only while `countRevealed` (the pointer is
    /// over the row): a column of numbers down the list was noise
    /// (product owner, 2026-10-06, "kind of like the chatgpt app"; ChatGPT's rows
    /// carry no counts).
    @ViewBuilder
    func courseOrBookGroupLabel(
        groupName: String,
        itemCount: Int,
        countRevealed: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            // A playlist or a book with no cover of its own draws its kind's
            // glyph in grey: colour is for covers and for state that needs
            // the learner (Lists are monochrome, docs/ui-design.md).
            if sidebar.sidebarTab == .videos {
                Image(systemName: "play.rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
            } else if sidebar.sidebarTab == .meetings {
                MeetingFolderIcon(imageURL: vm.meetingFolderImageURL(groupName))
            } else if let coverPath = vm.bookCoverPaths[groupName] {
                BookCoverThumbnail(pdfPath: coverPath)
            } else {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(groupDisplayName(groupName))
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .lineLimit(2)
                if sidebar.sidebarTab == .videos {
                    if let refreshedAt = vm.videoPlaylistMetadata[groupName]?.lastRefreshedAt {
                        Text("Refreshed \(refreshedAt.formatted(date: .abbreviated, time: .omitted))")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                } else if sidebar.sidebarTab == .meetings {
                    // How often the series recurs. The provider marks moved up
                    // beside the name, so this line exists only when there is
                    // recurrence to report.
                    if let subtitle = vm.meetingDisplaySubtitle(groupName) {
                        Text(subtitle)
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if metadataVisibility.isVisible(.subtitle, for: .book),
                       let subtitle = vm.bookDisplaySubtitle(groupName) {
                        Text(subtitle)
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    let bookParts: [String] = {
                        var p: [String] = []
                        if metadataVisibility.isVisible(.author, for: .book),
                           let a = vm.bookDisplayAuthor(groupName) { p.append(a) }
                        if metadataVisibility.isVisible(.edition, for: .book),
                           let e = vm.bookDisplayEdition(groupName) { p.append(e) }
                        if metadataVisibility.isVisible(.format, for: .book),
                           let f = vm.bookFormat(groupName) { p.append(f) }
                        if metadataVisibility.isVisible(.kind, for: .book),
                           let k = vm.bookDisplayKind(groupName) { p.append(k) }
                        return p
                    }()
                    if !bookParts.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(bookParts.enumerated()), id: \.offset) { index, part in
                                if index > 0 {
                                    Text("·").foregroundStyle(.tertiary)
                                }
                                Text(part)
                            }
                        }
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .id("\(String(describing: vm.videoPlaylistMetadata[groupName]))-\(String(describing: vm.meetingMetadata[groupName]))")
            Spacer()
            if vm.refreshingVideoPlaylistIDs.contains(groupName) {
                ProgressView()
                    .controlSize(.small)
            }
            if vm.transcribingMeetingGroupNames.contains(groupName) {
                ProgressView()
                    .controlSize(.small)
            }
            // A book added on this Mac reads while its details and chapters
            // are still being found.
            if sidebar.sidebarTab == .books, let status = vm.finishingBookStatus[groupName] {
                ProgressView()
                    .controlSize(.small)
                    .help(status)
            }
            if sidebar.sidebarTab == .meetings {
                let providers = MeetingProvider.marks(for: vm.meetingGroupProviders(groupName))
                HStack(spacing: 3) {
                    groupItemCount(itemCount, alignment: .trailing, isRevealed: countRevealed)
                    if !providers.isEmpty {
                        MeetingProviderBadges(providers: providers)
                    }
                }
            } else if sidebar.sidebarTab == .books {
                BookAudiobookBadge(
                    chapterIDs: vm.bookChapterArticlesInOrder(for: groupName)
                        .filter(ArticleSpeechContent.canAttemptRead)
                        .map(\.id)
                )
            } else {
                groupItemCount(itemCount, alignment: .trailing, isRevealed: countRevealed)
            }
        }
        .contextMenu {
            groupContextMenuItems(groupName: groupName, itemCount: itemCount)
        }
    }

    /// The whole-group actions of a playlist, meeting-group or book row.
    /// Shared by the row's own right-click menu and, on the Books tab, by the
    /// selection's menu: a book row selects its resume chapter, so without
    /// this a right-click on several covers could surface chapter actions
    /// instead of Hide Book and Remove Book.
    @ViewBuilder
    func groupContextMenuItems(groupName: String, itemCount: Int) -> some View {
        NotebookMenuSection(
            notebook: sidebarNotebook,
            target: sidebar.sidebarTab == .books ? .books([groupName]) : .collection(groupName)
        )
        // A book row opens the chapter it resumes at; this sends that chapter
        // to the other window instead.
        if sidebar.sidebarTab == .books,
           let chapter = vm.resumeBookChapter(for: groupName) ?? vm.bookSourceArticles(for: groupName).first {
            OtherWindowSourceMenuItem(chapter)
            Divider()
        }
        if assistantIntegrationsEnabled {
            // Add all items in this group to MCP context
            Button {
                vm.addSourcesToContext(vm.sourceIDsForGroupInOrder(groupName))
            } label: {
                Label("Add All to MCP Context", systemImage: "sparkles")
            }
        }

        // Show all review sessions linked to any item in this group
        let groupItemIds = vm.sourceIdsForGroup(groupName)
        let groupSessionCount = vm.reviewSessionLinks.filter { !Set($0.sourceIDs).isDisjoint(with: groupItemIds) }.count
        Button {
            vm.showReviewSessionsForGroup(groupName)
        } label: {
            Label(groupSessionCount > 0 ? "Show Review Sessions (\(groupSessionCount))" : "Show Review Sessions",
                  systemImage: "brain.head.profile")
        }
        Button {
            Task { await vm.scheduleGroup(groupName) }
        } label: {
            Label("Add Group to Schedule", systemImage: "calendar")
        }
        Divider()

        if sidebar.sidebarTab == .videos {
            Button {
                Task { await vm.refreshVideoPlaylist(groupName: groupName) }
            } label: {
                Label("Refresh Playlist", systemImage: "arrow.clockwise")
            }
            .disabled(vm.refreshingVideoPlaylistIDs.contains(groupName))
            Button {
                alertText = vm.videoPlaylistDisplayName(groupName)
                activeAlert = .renameVideoPlaylist(groupName)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                Task { await vm.setVideoPlaylistHidden(groupName, hidden: true) }
            } label: {
                Label("Hide Playlist", systemImage: "eye.slash")
            }
            Divider()
            Button(role: .destructive) {
                activeAlert = .removeVideoPlaylist(groupName)
            } label: {
                Label("Remove Playlist", systemImage: "trash")
            }
        } else if sidebar.sidebarTab == .meetings {
            // Recordings whose transcript has never been made. Opening
            // each recording in the reader and waiting there is a poor fit for
            // a folder of forty, so the group starts them all.
            let isTranscribingGroup = vm.transcribingMeetingGroupNames.contains(groupName)
            let untranscribed = vm.meetingSessionIDsNeedingTranscript(inGroup: groupName)
            if isTranscribingGroup || !untranscribed.isEmpty {
                Button {
                    Task { await vm.transcribeMeetingSessions(untranscribed, groupName: groupName) }
                } label: {
                    Label(
                        isTranscribingGroup
                            ? "Getting Transcripts…"
                            : "Get Transcripts (\(untranscribed.count))",
                        systemImage: "text.bubble"
                    )
                }
                .disabled(isTranscribingGroup)
                .help("Transcribe every recording in this folder that has no transcript yet")
                Divider()
            }
            Button {
                alertText = vm.meetingDisplayName(groupName)
                activeAlert = .renameMeeting(groupName)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            let mergeTargets = vm.visibleMeetingGroupNames.filter { $0 != groupName }
            if !mergeTargets.isEmpty {
                Menu {
                    ForEach(mergeTargets, id: \.self) { target in
                        Button(vm.meetingDisplayName(target)) {
                            activeAlert = .mergeMeeting(source: groupName, target: target)
                        }
                    }
                } label: {
                    Label("Merge Into", systemImage: "arrow.triangle.merge")
                }
            }
            // One sitting, one session: a standup a free Zoom account cut in
            // two arrives as two sessions of one day. New pairs fold as they
            // land; this folds the ones already there.
            let sameDaySurplus = vm.sameDayMeetingSessionSurplus(for: groupName)
            if sameDaySurplus > 0 {
                Button {
                    activeAlert = .mergeSameDayMeetingSessions(groupName)
                } label: {
                    Label("Merge Same-Day Sessions (\(sameDaySurplus))", systemImage: "arrow.triangle.merge")
                }
                .help("Fold the sessions that share a day into one session per day")
            }
            Button {
                meetingScheduleTarget = MeetingScheduleTarget(groupName: groupName)
            } label: {
                Label(vm.meetingMetadata[groupName]?.schedule == nil ? "Schedule…" : "Edit Schedule…", systemImage: "clock")
            }
            Button {
                alertText = vm.meetingFolderImageURL(groupName) ?? ""
                activeAlert = .editMeetingFolderImage(groupName)
            } label: {
                Label("Set Folder Image…", systemImage: "photo")
            }
            if vm.meetingFolderImageURL(groupName) != nil {
                Button {
                    vm.setMeetingFolderImageURL(nil, for: groupName)
                } label: {
                    Label("Use Default Image", systemImage: "arrow.uturn.backward")
                }
            }
            Button {
                Task { await vm.setMeetingHidden(groupName, hidden: true) }
            } label: {
                Label("Hide Meeting Group", systemImage: "eye.slash")
            }
            Divider()
            Button(role: .destructive) {
                activeAlert = .removeMeeting(groupName)
            } label: {
                Label("Delete Meeting Group", systemImage: "trash")
            }
        } else {
            // Cached-only: this menu is built with the group row, and the
            // uncached lookup enumerates an iCloud-backed book directory.
            if let epubURL = vm.cachedOriginalEPUBURL(forBookGroup: groupName) {
                Button {
                    if assistantIntegrationsEnabled {
                        vm.addSourcesToContext(vm.sourceIDsForGroupInOrder(groupName))
                    }
                    openEPUBInAppleBooks(epubURL)
                } label: {
                    Label("Open EPUB in Apple Books", systemImage: "book.pages")
                }
            }
            // One click narrates the whole book. Generating chapter by
            // chapter was the only route, and a forty-chapter book made
            // that forty clicks and forty price dialogs.
            let audiobookProgress = audioQueue.progress(forGroup: groupName)
            Button {
                Task { await startAudiobookGeneration(forBookGroup: groupName) }
            } label: {
                Label(
                    audiobookProgress.remaining > 0
                        ? "Generating Audiobook… (\(audiobookProgress.remaining) left)"
                        : "Generate Audiobook",
                    systemImage: "headphones"
                )
            }
            .disabled(audiobookProgress.remaining > 0)
            .help("Generate text-to-speech audio for every chapter that does not have it yet")
            // A book's walkthrough is one a chapter (product owner, 2026-09-19:
            // "books (or chapters thereof)"): this writes the chapters that
            // have none, one after another, steps only — one writing call a
            // chapter, no animations — so a forty-chapter book is one click
            // and a bounded bill. A chapter's own Write Walkthrough draws them.
            let walkthroughRemaining = walkthroughCoordinator.batchRemaining(forGroup: groupName)
            Button {
                let chapters = vm.bookChapterArticlesInOrder(for: groupName)
                Task { await walkthroughCoordinator.generateMissing(for: chapters, group: groupName, in: vm) }
            } label: {
                Label(
                    walkthroughRemaining > 0
                        ? "Writing Walkthroughs… (\(walkthroughRemaining) left)"
                        : "Write Walkthroughs for All Chapters",
                    systemImage: "figure.walk.motion"
                )
            }
            .disabled(walkthroughRemaining > 0)
            .help("Write a step-by-step walkthrough for every chapter that does not have one yet; steps only, no animations")
            Divider()
            Button {
                Task { await vm.setBookHidden(groupName, hidden: true) }
            } label: {
                Label("Hide Book", systemImage: "eye.slash")
            }
            Button {
                alertText = vm.bookDisplayName(groupName)
                activeAlert = .renameBook(groupName)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                alertText = vm.bookDisplayAuthor(groupName) ?? ""
                activeAlert = .editBookAuthor(groupName)
            } label: {
                Label(vm.bookDisplayAuthor(groupName) != nil ? "Edit Author" : "Add Author", systemImage: "person")
            }
            Button {
                alertText = vm.bookDisplaySubtitle(groupName) ?? ""
                activeAlert = .editBookSubtitle(groupName)
            } label: {
                Label(vm.bookDisplaySubtitle(groupName) != nil ? "Edit Subtitle" : "Add Subtitle", systemImage: "text.quote")
            }
            Button {
                alertText = vm.bookDisplayEdition(groupName) ?? ""
                activeAlert = .editBookEdition(groupName)
            } label: {
                Label(vm.bookDisplayEdition(groupName) != nil ? "Edit Edition" : "Add Edition", systemImage: "books.vertical")
            }
            Button {
                alertText = vm.bookDisplayKind(groupName) ?? ""
                activeAlert = .editBookKind(groupName)
            } label: {
                Label(vm.bookDisplayKind(groupName) != nil ? "Edit Category" : "Set Category", systemImage: "tag")
            }
            Divider()
            Button {
                chapterManagerTarget = ManageChaptersTarget(groupName: groupName)
            } label: {
                Label("Manage Chapters…", systemImage: "list.bullet.rectangle")
            }
            // A book is the same book only when it is the same file, so a
            // fresh copy of a damaged book, or the book on a Mac its file
            // never reached, becomes this book's file only when asked for here.
            Button {
                Task { await replaceBookFile(groupName) }
            } label: {
                Label("Replace Book File…", systemImage: "doc.badge.arrow.up")
            }
            .help("Use another copy of this book's file; its chapters are found again in it")
            Button(role: .destructive) {
                activeAlert = .deleteBook(groupName)
            } label: {
                Label("Remove Book", systemImage: "trash")
            }
        }
    }

    /// Asks for the file that is to be this book's, and imports it as the book.
    private func replaceBookFile(_ bookID: String) async {
        let urls = await FilePanel.open { panel in
            panel.allowedContentTypes = supportedBookImportContentTypes
            panel.allowsMultipleSelection = false
            panel.message = "Select the file for “\(vm.bookDisplayName(bookID))” (PDF, EPUB, or DRM-free Kindle)"
        }
        guard let url = urls.first else { return }
        do {
            try await vm.importBook(from: url.path, replacingBookID: bookID)
        } catch {
            vm.errorMessage = error.localizedDescription
            vm.showBookImportError = true
        }
    }

    private func groupItemCount(_ itemCount: Int, alignment: Alignment, isRevealed: Bool) -> some View {
        Text("\(itemCount)")
            .zoomedSystemFont(size: 11)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            // A fixed width keeps counts stable as their digit length changes.
            // Meeting provider marks follow this column, so their trailing edge
            // stays aligned at the right of every collection row. The column
            // keeps its width while the count is hidden, so neither the marks
            // nor a two-line title move when the pointer arrives.
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 22, alignment: alignment)
            .opacity(isRevealed ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isRevealed)
    }

    private func groupDisplayName(_ groupName: String) -> String {
        if sidebar.sidebarTab == .videos { return vm.videoPlaylistDisplayName(groupName) }
        if sidebar.sidebarTab == .meetings { return vm.meetingDisplayName(groupName) }
        return vm.bookDisplayName(groupName)
    }

    func openEPUBInAppleBooks(_ epubURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        if let booksURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") {
            NSWorkspace.shared.open([epubURL], withApplicationAt: booksURL, configuration: config)
        } else {
            NSWorkspace.shared.open(epubURL)
        }
    }
}
