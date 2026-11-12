// The source sidebar's list content and the meetings empty state.
import SwiftUI
import AppKit

extension StudioSidebar {
    @ViewBuilder
    var sidebarListContent: some View {
            if sidebar.sidebarTab == .xPosts, !vm.isXOAuthSignedIn {
                Section {
                    Button {
                        Task { await vm.signInWithX() }
                    } label: {
                        HStack(spacing: 6) {
                            if vm.isConnectingX {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 12, height: 12)
                            } else {
                                XLogoShape()
                                    .fill(.foreground, style: FillStyle(eoFill: true))
                                    .frame(width: 12, height: 12)
                            }
                            Text(vm.isConnectingX ? "Connecting to X…" : "Connect to X")
                        }
                    }
                    // The sign-in window is hosted by a system agent that can be
                    // slow to launch; the row says so instead of looking dead.
                    .disabled(vm.isConnectingX)
                }
            } else if sidebar.sidebarTab == .xPosts, let attention = vm.xPluginAttention {
                // The red dot on the tab says something went wrong; this row is
                // where it says what. A failed sync does not announce itself with
                // a toast that vanishes before it is read; it waits here,
                // with the fix beside it, until a sync goes through.
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(attention)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        // A failure a new sign-in might clear offers one beside
                        // the retry; "try again later" alone left the learner
                        // no way out of a token X had stopped honouring.
                        if !vm.xPluginNeedsReauth, vm.xPluginOffersReconnect {
                            Button("Reconnect") {
                                Task { await vm.signInWithX() }
                            }
                            .controlSize(.small)
                            .disabled(vm.isSyncingXBookmarks || vm.isConnectingX)
                        }
                        Button(vm.xPluginNeedsReauth ? "Reconnect" : "Try Again") {
                            Task {
                                if vm.xPluginNeedsReauth {
                                    await vm.signInWithX()
                                } else {
                                    await vm.syncXBookmarks()
                                }
                            }
                        }
                        .controlSize(.small)
                        // A retry inside X's rate-limit window is another
                        // refused request; the message names when the
                        // window reopens and the sync runs itself then.
                        .disabled(vm.isSyncingXBookmarks || vm.isConnectingX || (!vm.xPluginNeedsReauth && vm.isXSyncPaused))
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("X bookmarks need attention")
                }
            }
            if sidebar.sidebarTab == .books {
                Section {
                    // The button stays while a book imports: another book
                    // picked or dropped now waits its turn behind it.
                    Button {
                        Task {
                            let urls = await FilePanel.open { panel in
                                panel.allowedContentTypes = supportedBookImportContentTypes
                                panel.allowsMultipleSelection = true
                                panel.message = "Select books (PDF, EPUB, or DRM-free Kindle) to import"
                            }
                            await importBooks(urls)
                        }
                    } label: {
                        Label("Add Book…", systemImage: "book.closed.fill")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green.opacity(0.8))
                    .controlSize(.small)
                    .overlay {
                        StudioDropZoneOverlay(
                            isActive: isAddBookButtonDropTargeted,
                            title: "Import book",
                            systemImage: "book.closed.fill",
                            cornerRadius: 6,
                            inset: 0
                        )
                    }
                    .onDrop(of: supportedBookImportDropTypes, isTargeted: $isAddBookButtonDropTargeted) { providers in
                        handleBookFileDrop(providers)
                    }
                    if !vm.bookImportStatus.isEmpty || vm.bookImportsPending > 0 {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(bookImportProgressLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
            }

            if sidebar.sidebarTab == .papers {
                Section {
                    Button {
                        Task {
                            let urls = await FilePanel.open { panel in
                                panel.allowedContentTypes = [.pdf]
                                panel.allowsMultipleSelection = true
                                panel.message = "Select one or more paper PDFs to import"
                            }
                            guard !urls.isEmpty else { return }
                            var failures: [String] = []
                            for url in urls {
                                do {
                                    try await vm.importPDF(
                                        from: url.path,
                                        selectInReader: false
                                    )
                                } catch {
                                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                                }
                            }
                            if !failures.isEmpty {
                                vm.errorMessage = failures.joined(separator: "\n")
                            }
                        }
                    } label: {
                        Label("Upload PDFs…", systemImage: "doc.fill")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple.opacity(0.8))
                    .controlSize(.small)
                    .overlay {
                        StudioDropZoneOverlay(
                            isActive: isUploadPapersButtonDropTargeted,
                            title: "Import as new paper",
                            systemImage: "doc.badge.plus",
                            cornerRadius: 6,
                            inset: 0
                        )
                    }
                    .onDrop(of: [.fileURL, .pdf], isTargeted: $isUploadPapersButtonDropTargeted) { providers in
                        handlePaperFileDrop(providers)
                    }
                }
            }

            // A linked Drive folder is what makes a broken connection matter
            // here; a learner who only imports local recordings is never nagged.
            if sidebar.sidebarTab == .meetings,
               vm.meetingMetadata.values.contains(where: { $0.driveFolderURL?.isEmpty == false }) {
                Section {
                    GoogleDriveHealthBanner(
                        accountID: nil,
                        isWorking: isGoogleDriveWorking,
                        reconnect: startGoogleDriveMeetingImport
                    )
                }
            }

            if sidebar.sidebarTab == .meetings, !showsMeetingsEmptyHelp {
                Section {
                    // Side by side where the column has room, stacked where it
                    // does not: two labels that cannot shrink ran past a narrow
                    // Library column and were cut at both its edges.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            addMeetingFolderButton
                            addRecordingButton
                            liveMeetingButton
                        }
                        VStack(spacing: 8) {
                            addMeetingFolderButton
                            addRecordingButton
                            liveMeetingButton
                        }
                    }
                }
            }

            if sidebar.sidebarTab == .videos {
                Section {
                    Button {
                        alertText = ""
                        activeAlert = .addYouTubeVideo
                    } label: {
                        Label("Add Video…", systemImage: "play.rectangle.fill")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red.opacity(0.8))
                    .controlSize(.small)
                }
            }

            if !vm.paperVersionConflicts.isEmpty && sidebar.sidebarTab == .papers {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .font(.caption)
                            let count = vm.paperVersionConflicts.count
                            Text("\(count) paper\(count == 1 ? "" : "s") have multiple versions saved.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Fix Sources") {
                            Task { await vm.fixPaperVersionConflicts() }
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }

            let tabDiscoveryWarnings = vm.discoveryWarnings(for: sidebar.sidebarTab)
            if !tabDiscoveryWarnings.isEmpty {
                let accessWarnings = tabDiscoveryWarnings.filter { isFullDiskAccessWarning($0) }
                let otherWarnings = tabDiscoveryWarnings.filter { !isFullDiskAccessWarning($0) }

                if !accessWarnings.isEmpty {
                    Section {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Full Disk Access needed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button("Open Settings") {
                                openFullDiskAccessSettings()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(vm.isLoadingQueue)
                        }
                    }
                }

                let showOtherWarnings = (isBrowserReadingListTab || sidebar.sidebarTab == .podcasts) && !otherWarnings.isEmpty

                if showOtherWarnings {
                Section {
                    if showOtherWarnings {
                    ForEach(otherWarnings, id: \.self) { warning in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Button("Refresh") {
                                    Task { await vm.loadQueue() }
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    }
                }
                }
            }

            if showsMeetingsEmptyHelp {
                meetingsEmptyHelp
            }

            sidebarArticlesSections
    }

    /// A genuinely empty Meetings tab needs a way forward. Search and filter
    /// misses keep their ordinary empty-list behavior: sending someone into
    /// plugin setup when their meetings are merely hidden would be wrong —
    /// and a provider filter that matches nothing is a filter miss, not an
    /// empty library, so it is checked here alongside search.
    private var showsMeetingsEmptyHelp: Bool {
        sidebar.sidebarTab == .meetings
            && sidebar.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !windowVM.hasActiveSourceListFilters
            && windowVM.tabTotalCount == 0
            && windowVM.filteredMeetingGroupNames.isEmpty
            && !vm.isLoadingQueue
    }

    /// The empty Meetings tab names every provider that can fill it, not just
    /// the one with a button. Google Drive is the only provider ForeverLM can
    /// connect from here — Read AI and other plugins push meetings in over
    /// MCP — but an empty state that mentioned Drive alone would read as "this
    /// tab is Google Drive", which is exactly the impression the split tabs
    /// left and this tab exists to correct.
    ///
    /// It wears the Space's empty state (`SpaceEmptyLine`'s sizes, the dark
    /// pill under the line), not `ContentUnavailableView`, whose large grey
    /// description and blue button read as a different app in this pane.
    private var meetingsEmptyHelp: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image("MeetingsIcon")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text("No meetings yet")
                        .zoomedSystemFont(size: 13, weight: .semibold)
                        .foregroundStyle(.primary)
                    Text(
                        isGoogleDriveSignedIn && !hasGoogleDriveFolderReadAccess
                            ? "Reconnect to read the files inside this meeting folder."
                            : isGoogleDriveSignedIn
                            ? "Choose the folder that holds your meeting recordings and transcripts."
                            : "Connect Google Drive, or import a folder of recordings from this Mac."
                    )
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            }

            HStack(spacing: 8) {
                SpaceDarkPillButton(
                    title: isGoogleDriveWorking
                        ? "Waiting for Google… Cancel"
                        : (isGoogleDriveSignedIn && !hasGoogleDriveFolderReadAccess
                            ? "Reconnect Google Drive"
                            : (isGoogleDriveSignedIn ? "Choose Meeting Folder" : "Connect Google Drive")),
                    systemImage: nil,
                    image: nil,
                    action: startGoogleDriveMeetingImport
                )
                if isGoogleDriveWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            // Every provider that fills this tab, quiet under the one action.
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    ForEach(MeetingProvider.allCases) { provider in
                        MeetingProviderMark(provider: provider, size: 14)
                    }
                }
                Text("Google Drive, Read AI, Zoom and local folders all land here.")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    /// The Meetings tab's primary action, filling its row where it has room.
    private var addMeetingFolderButton: some View {
        Button(action: startGoogleDriveMeetingImport) {
            Label(
                isGoogleDriveWorking
                    ? "Waiting for Google… Cancel"
                    : (isGoogleDriveSignedIn && !hasGoogleDriveFolderReadAccess
                        ? "Reconnect Google Drive…"
                        : "Add Meeting Folder…"),
                systemImage: isGoogleDriveWorking ? "xmark.circle" : "folder.badge.plus"
            )
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue.opacity(0.8))
        .controlSize(.small)
    }

    /// Followed the Zoom tab down here when the tabs merged: pasting a
    /// recording link is how one provider's sessions arrive, not a place of its
    /// own.
    private var addRecordingButton: some View {
        Button {
            alertText = ""
            zoomPasscodeText = ""
            activeAlert = .addZoomRecording
        } label: {
            Label("Add Recording…", systemImage: "video.badge.plus")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// A meeting happening now, transcribed on this Mac as it is said
    /// (`LiveMeetingPane`); Chat › Live Meeting opens the same pane.
    private var liveMeetingButton: some View {
        Button {
            vm.openLiveMeeting()
        } label: {
            Label("Live Meeting", systemImage: "waveform")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
