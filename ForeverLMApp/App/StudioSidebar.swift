import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

struct StudioSidebar: View, Equatable {
    /// Every input the sidebar draws from arrives through the environment,
    /// observation, or its own `@State`; nothing is passed in by the parent.
    /// SwiftUI still cannot tell two `StudioSidebar` values apart on its own
    /// and re-runs this body — and re-diffs the sources List, several thousand
    /// rows on a full library — every time `StudioView` re-evaluates, which it
    /// does for every center-pane layout change. Measured 2026-09-02 on a Dev
    /// build with the Podcasts tab (~1,000 rows): closing the Reader pane cost
    /// ~425 ms of main-thread work, most of it in `OutlineListCoordinator`
    /// re-diffing rows whose data had not changed. Declaring the values equal
    /// lets SwiftUI skip the body; dependency changes still re-run it.
    static func == (lhs: StudioSidebar, rhs: StudioSidebar) -> Bool { true }

    /// The app-wide view model: the library, imports, and actions. Its
    /// per-window accessors (`sidebarTab`, `selectedArticleIds`, the derived
    /// source lists) answer for the *key* window, which is not necessarily this
    /// one — so this sidebar renders from `sidebar` and `windowVM` below and
    /// keeps `vm` for actions and app-wide state.
    @Environment(StudioViewModel.self) var vm
    /// This window's Sources panel state: tab, search, filters, pagination,
    /// expanded groups. Injected per window by `StudioWindowRoot`.
    @Environment(StudioSidebarStore.self) var sidebar
    /// The window this sidebar belongs to, so a right-click can name the others.
    @Environment(StudioWindowState.self) var windowState
    /// `vm` answering for this window. Every derived list the sidebar draws —
    /// `activeTabArticles`, the papers partitions, "Show More" counts — reads
    /// through here, and every action that changes this panel's own state runs
    /// through `windowVM.inWindow { ... }`, so a window that is not key still
    /// shows and edits its own list rather than the key window's.
    var windowVM: StudioWindowScopedViewModel { vm.scoped(to: windowState) }
    let dragVisibility = StudioDragVisibility.shared
    /// Deliberately not `@ObservedObject`: the sidebar only reaches this
    /// service from context-menu content, which is built fresh when the menu
    /// opens. Observing it re-rendered the entire sidebar — and re-diffed the
    /// sources table — on every `playbackCurrentTime` tick during text-to-speech.
    let articleSpeech = ArticleSpeechService.shared
    /// The batch narration queue, observed so a book row can say how far its
    /// audiobook has to go. Its published state is a handful of small items,
    /// unlike the speech service's per-tick playback clock above.
    @ObservedObject var audioQueue = SourceAudioGenerationQueue.shared
    /// The book row's Write Walkthroughs for All Chapters reads its progress
    /// here, the way the audiobook item reads the audio queue's.
    @ObservedObject var walkthroughCoordinator = WalkthroughGenerationCoordinator.shared
    @Environment(\.openWindow) var openWindow
    @Environment(\.studioTitlebarBandHeight) var titlebarBandHeight
    /// The Library's layout (`LibraryPane`): a narrow pane draws the compact
    /// list, a wide one wider rows and a bar for a multi-selection.
    @Environment(\.sourcesListLayout) var sourcesListLayout
    /// Inside a notebook's Sources column the column's field searches, so
    /// the list's own row stays away while it is empty.
    @Environment(\.sourcesListHidesIdleSearch) var sourcesListHidesIdleSearch

    /// The source this window's Reader shows — the row a rebuilt list lands on
    /// when nothing else is selected, and the row a multi-selection keeps.
    var sidebarReaderSourceID: String? {
        windowState.readerSourceID(fallingBackTo: vm.selectedArticleId)
    }

    /// The notebook this window's rows are marked against, if it is working
    /// in one. Reads titles and ids only; the marks read the membership.
    var sidebarNotebook: SidebarNotebook? {
        vm.sidebarNotebook(in: windowState)
    }

    @State var isBooksDropTargeted = false
    @State var isAddBookButtonDropTargeted = false
    @State var isPapersDropTargeted = false
    @State var isUploadPapersButtonDropTargeted = false
    @State var isProcessingPapersExpanded = true
    @State var isPapersWithoutPDFExpanded = false
    @State var isPaywalledPapersExpanded = false
    @SyncedStorage("metadataVisibility") var metadataVisibility = MetadataVisibilitySettings()
    @SyncedStorage("studio.sourceTabBarLayout") var sourceTabBarLayout: SourceTabBarLayout = .compact
    @SyncedStorage("studio.showSourceTabLabels") var showSourceTabLabels = true
    @SyncedStorage("studio.sourceTabIconSize") var sourceTabIconSize: SourceTabIconSize = .medium
    @SyncedStorage("studio.assistantIntegrationsEnabled") var assistantIntegrationsEnabled = true
    /// The source type being dragged to a new position in the tab bar, and the
    /// tab whose slot it would take. Both paths that can start the drag — the
    /// in-band AppKit handle and the SwiftUI `.onDrag` used everywhere else —
    /// set the first, so the drop reorders off live state instead of waiting on
    /// the asynchronous pasteboard payload.
    @State var draggedSourceTab: StudioSidebarTab?
    @State var sourceTabDropTarget: StudioSidebarTab?
    /// The Customize popover: every source type with a pin checkmark, its icon
    /// and a reorder handle, opened from the tab bar's ⋯ menu.
    @State var isSourceTabCustomizePresented = false
    /// The source type whose hidden shows, groups and sources hang in a
    /// popover from its tab, opened by the tab's Show Hidden menu item.
    @State var hiddenItemsPopoverTab: StudioSidebarTab?
    /// Coalesces the native List selection callback and the row's explicit tap
    /// action. AppKit normally delivers both for one click, but controls, row
    /// whitespace, and newly inserted rows can occasionally deliver only the tap.
    @State var pendingSidebarOpenSourceID: String?
    /// The source whose row was just pressed. AppKit selects a List row on
    /// mouse-down, before it can know whether the press is a click or the start
    /// of a drag, so opening on the selection change opened every source that
    /// was merely dragged toward the chat. The open now waits for mouse-up; a
    /// drag beginning first cancels it. Keyboard selection still opens at once.
    @State var deferredSidebarOpenSourceID: String?
    /// The selection that press made, written with the open on mouse-up (or
    /// at once when the press becomes a drag), so a press that was a row
    /// control's selects nothing (`SidebarRowControlPress`).
    @State var deferredSidebarSelection: Set<String>?
    /// Focused by ⌘F while keyboard focus is in the sources column, or ⇧⌘F from
    /// anywhere (⌘F elsewhere belongs to Find in Reader); cleared and blurred by
    /// Escape or by the same shortcut again.
    @FocusState var isSourceSearchFocused: Bool
    /// The lazy list's (`usesLazySourceList`) keyboard focus, taken by a click
    /// on a row so ↑ ↓, Delete and Escape reach the list.
    @FocusState var isLazySourceListFocused: Bool
    /// Where the lazy list's ⇧-click and ⇧-arrow runs start: the row last
    /// clicked or arrowed to without ⇧.
    @State var lazyListAnchorSourceID: String?
    /// The row the lazy list's arrow keys move from.
    @State var lazyListCursorSourceID: String?

    /// Consolidated alert state — one active alert at a time.
    @State var activeAlert: SidebarAlertKind?
    @State var alertText = ""
    @State var zoomPasscodeText = ""
    @State var chapterManagerTarget: ManageChaptersTarget?
    @State var meetingScheduleTarget: MeetingScheduleTarget?
    @State var pendingRemoval = StudioViewModel.SidebarRemovalTargets()
    @State var isSourceRemovalDialogPresented = false
    @State var isGoogleDriveWorking = false
    /// Published connection state for view rendering. The service's raw
    /// properties consult Keychain; reading them from a view body blocked the
    /// main actor in the captured Meetings-tab stall.
    @State var isGoogleDriveSignedIn = false
    @State var hasGoogleDriveFolderReadAccess = false
    /// Cached plugin health for rendering the Meetings status row. OAuth and
    /// Keychain work stays outside the view body so opening Meetings cannot
    /// beachball while deciding whether to show a warning.
    @State var meetingPluginSummaries: [MCPOAuthProvider.UserPluginSummary] = []
    /// The user's MCP address when MCP is set up — what a setup prompt copied
    /// from the Meetings tab is filled in with. Read off-main together with the
    /// plugin list; the keychain is IPC and stays off the render path.
    @State var meetingPluginSetupAddress: String?
    @State var hasLoadedMeetingPluginHealth = false
    @State var didCopyMeetingPluginSetupPrompt = false

    enum SidebarAlertKind: Identifiable {
        case pdfURL(String)              // article ID
        case renameBook(String)          // book group name
        case editBookAuthor(String)      // book group name
        case editBookSubtitle(String)    // book group name
        case editBookEdition(String)     // book group name
        case editBookKind(String)        // book group name
        case deleteBook(String)          // book group name
        case addYouTubeVideo             // paste a single YouTube video URL
        case addZoomRecording            // paste a Zoom cloud-recording URL
        case renameVideoPlaylist(String)
        case removeVideoPlaylist(String)
        case renameMeeting(String)
        case mergeMeeting(source: String, target: String)
        case mergeSameDayMeetingSessions(String) // meeting group ID
        case editMeetingFolderImage(String) // meeting group ID
        case removeMeeting(String)
        case zoomPasscode(String)        // article ID of a Zoom recording video

        var id: String {
            switch self {
            case .pdfURL(let id):        return "pdf-\(id)"
            case .renameBook(let g):     return "bookRename-\(g)"
            case .editBookAuthor(let g): return "bookAuthor-\(g)"
            case .editBookSubtitle(let g): return "bookSubtitle-\(g)"
            case .editBookEdition(let g): return "bookEdition-\(g)"
            case .editBookKind(let g):   return "bookKind-\(g)"
            case .deleteBook(let g):     return "deleteBook-\(g)"
            case .renameVideoPlaylist(let g): return "videoPlaylistRename-\(g)"
            case .removeVideoPlaylist(let g): return "removeVideoPlaylist-\(g)"
            case .renameMeeting(let g): return "meetingRename-\(g)"
            case .mergeMeeting(let source, let target): return "meetingMerge-\(source)-\(target)"
            case .mergeSameDayMeetingSessions(let g): return "meetingMergeSameDay-\(g)"
            case .editMeetingFolderImage(let g): return "meetingImage-\(g)"
            case .removeMeeting(let g): return "removeMeeting-\(g)"
            case .addYouTubeVideo:       return "addYouTubeVideo"
            case .addZoomRecording:      return "addZoomRecording"
            case .zoomPasscode(let id):  return "zoomPasscode-\(id)"
            }
        }
    }

    private var showPDFURLAlert: Binding<Bool> { alertBinding(for: { if case .pdfURL = $0 { return true }; return false }) }
    private var showBookRenameAlert: Binding<Bool> { alertBinding(for: { if case .renameBook = $0 { return true }; return false }) }
    private var showBookAuthorAlert: Binding<Bool> { alertBinding(for: { if case .editBookAuthor = $0 { return true }; return false }) }
    private var showBookSubtitleAlert: Binding<Bool> { alertBinding(for: { if case .editBookSubtitle = $0 { return true }; return false }) }
    private var showBookEditionAlert: Binding<Bool> { alertBinding(for: { if case .editBookEdition = $0 { return true }; return false }) }
    private var showBookKindAlert: Binding<Bool> { alertBinding(for: { if case .editBookKind = $0 { return true }; return false }) }
    private var editingBookSubtitleGroup: Binding<String?> {
        Binding(get: { if case .editBookSubtitle(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var editingBookEditionGroup: Binding<String?> {
        Binding(get: { if case .editBookEdition(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var editingBookKindGroup: Binding<String?> {
        Binding(get: { if case .editBookKind(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var showDeleteBookAlert: Binding<Bool> { alertBinding(for: { if case .deleteBook = $0 { return true }; return false }) }
    private var showAddYouTubeVideoAlert: Binding<Bool> { alertBinding(for: { if case .addYouTubeVideo = $0 { return true }; return false }) }
    private var showAddZoomRecordingAlert: Binding<Bool> { alertBinding(for: { if case .addZoomRecording = $0 { return true }; return false }) }
    private var showRenameVideoPlaylistAlert: Binding<Bool> { alertBinding(for: { if case .renameVideoPlaylist = $0 { return true }; return false }) }
    private var showRemoveVideoPlaylistAlert: Binding<Bool> { alertBinding(for: { if case .removeVideoPlaylist = $0 { return true }; return false }) }
    private var renamingVideoPlaylistGroup: Binding<String?> {
        Binding(get: { if case .renameVideoPlaylist(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var removingVideoPlaylistGroup: Binding<String?> {
        Binding(get: { if case .removeVideoPlaylist(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var showRenameMeetingAlert: Binding<Bool> { alertBinding(for: { if case .renameMeeting = $0 { return true }; return false }) }
    private var renamingMeetingGroup: Binding<String?> {
        Binding(get: { if case .renameMeeting(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var showMergeMeetingAlert: Binding<Bool> { alertBinding(for: { if case .mergeMeeting = $0 { return true }; return false }) }
    private var mergingMeetingGroups: Binding<(source: String, target: String)?> {
        Binding(
            get: {
                if case .mergeMeeting(let source, let target) = activeAlert {
                    return (source, target)
                }
                return nil
            },
            set: { _ in }
        )
    }
    private var showMergeSameDayMeetingSessionsAlert: Binding<Bool> {
        alertBinding(for: { if case .mergeSameDayMeetingSessions = $0 { return true }; return false })
    }
    private var mergingSameDayMeetingGroup: Binding<String?> {
        Binding(get: { if case .mergeSameDayMeetingSessions(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var showMeetingFolderImageAlert: Binding<Bool> { alertBinding(for: { if case .editMeetingFolderImage = $0 { return true }; return false }) }
    private var editingMeetingFolderImageGroup: Binding<String?> {
        Binding(get: { if case .editMeetingFolderImage(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var showRemoveMeetingAlert: Binding<Bool> { alertBinding(for: { if case .removeMeeting = $0 { return true }; return false }) }
    private var removingMeetingGroup: Binding<String?> {
        Binding(get: { if case .removeMeeting(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var showZoomPasscodeAlert: Binding<Bool> { alertBinding(for: { if case .zoomPasscode = $0 { return true }; return false }) }
    private var zoomPasscodeArticleId: Binding<String?> {
        Binding(get: { if case .zoomPasscode(let id) = activeAlert { return id }; return nil }, set: { _ in })
    }

    private var refreshButtonHelp: String {
        let tabLabel = sidebar.sidebarTab.itemNoun
        if vm.isLoadingQueue {
            return vm.loadingStep ?? "Refreshing \(tabLabel)"
        }
        return "Refresh \(tabLabel)"
    }

    private func alertBinding(for matches: @escaping (SidebarAlertKind) -> Bool) -> Binding<Bool> {
        Binding(
            get: { if let a = activeAlert { return matches(a) }; return false },
            set: { if !$0 { activeAlert = nil } }
        )
    }

    private var sourceRemovalDialogTitle: String {
        if pendingRemoval.count > 1 {
            return "Remove \(pendingRemoval.count) \(sourceRemovalNoun)?"
        }
        if let group = pendingRemoval.bookGroups.first {
            return "Remove “\(vm.bookDisplayName(group))”?"
        }
        guard let id = pendingRemoval.sourceIDs.first,
              let article = vm.articles.first(where: { $0.id == id }) else {
            return "Remove Source?"
        }
        return "Remove “\(article.title)”?"
    }

    /// "Book", "Source", or "Item" for a mix — pluralised by the dialog.
    private var sourceRemovalNoun: String {
        let plural = pendingRemoval.count > 1
        if pendingRemoval.sourceIDs.isEmpty { return plural ? "Books" : "Book" }
        if pendingRemoval.bookGroups.isEmpty { return plural ? "Sources" : "Source" }
        return plural ? "Items" : "Item"
    }

    private var sourceRemovalHideLabel: String {
        pendingRemoval.count > 1 ? "Hide \(pendingRemoval.count) \(sourceRemovalNoun)" : "Hide \(sourceRemovalNoun)"
    }

    private var sourceRemovalRemoveLabel: String {
        pendingRemoval.count > 1
            ? "Remove \(pendingRemoval.count) \(sourceRemovalNoun) from Library"
            : "Remove \(sourceRemovalNoun) from Library"
    }

    /// Route every sidebar deletion gesture through the same confirmation. List
    /// rows move between dynamic sections while a paper is processing; a Delete
    /// command or full-swipe must never turn that presentation change into an
    /// immediate library mutation.
    ///
    /// On the Books tab a row is tagged with the chapter the book would resume,
    /// so the ids arriving here are chapter ids; the learner selected a book,
    /// and the confirmation names and acts on the book.
    func requestSourceRemoval(_ ids: Set<String>) {
        let existingIDs = Set(ids.filter { id in
            vm.articles.contains(where: { $0.id == id })
                && !vm.hasPendingDeletion(forSourceID: id)
        })
        let targets = vm.sidebarRemovalTargets(
            for: existingIDs,
            expandingBooks: sidebar.sidebarTab == .books
        )
        guard !targets.isEmpty else { return }
        pendingRemoval = targets
        isSourceRemovalDialogPresented = true
    }

    private var pdfURLArticleId: Binding<String?> {
        Binding(get: { if case .pdfURL(let id) = activeAlert { return id }; return nil }, set: { _ in })
    }
    private var renamingBookGroup: Binding<String?> {
        Binding(get: { if case .renameBook(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var editingAuthorBookGroup: Binding<String?> {
        Binding(get: { if case .editBookAuthor(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }
    private var deletingBookGroup: Binding<String?> {
        Binding(get: { if case .deleteBook(let g) = activeAlert { return g }; return nil }, set: { _ in })
    }

    // Text bindings (all share alertText)
    private var pdfURLText: Binding<String> { $alertText }
    private var bookRenameText: Binding<String> { $alertText }
    private var bookAuthorText: Binding<String> { $alertText }
    private var bookSubtitleText: Binding<String> { $alertText }
    private var bookEditionText: Binding<String> { $alertText }
    private var bookKindText: Binding<String> { $alertText }

    @MainActor
    private func refreshGoogleDriveConnectionState() async {
        let status = await Task.detached(priority: .utility) {
            (
                isSignedIn: GoogleDriveService.shared.isSignedIn,
                hasFolderReadAccess: GoogleDriveService.shared.hasFolderReadAccess
            )
        }.value
        guard !Task.isCancelled else { return }
        isGoogleDriveSignedIn = status.isSignedIn
        hasGoogleDriveFolderReadAccess = status.hasFolderReadAccess
    }

    @MainActor
    private func refreshMeetingPluginHealth() async {
        let oauthProvider = await MCPOAuthProvider.sharedProvider()
        let plugins = await oauthProvider.userPluginSummaries()
        let address = await Task.detached(priority: .utility) {
            KeychainService.load(.mcpTunnelURL)
        }.value
        guard !Task.isCancelled else { return }
        meetingPluginSummaries = plugins
        meetingPluginSetupAddress = (address?.isEmpty == false) ? address : nil
        hasLoadedMeetingPluginHealth = true
    }

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            if titlebarBandHeight == nil {
                sidebarTabBar
            } else if sidebarTabBarOverhang > 0 {
                // The bar mounts from the top overlay below; reserve only the
                // part of it that extends beneath the titlebar band (the roomy
                // grid is taller than the band).
                Color.clear.frame(height: sidebarTabBarOverhang)
            }

            sidebarSearchAndBanners

            // The full-window Library's bar for a multi-selection: the
            // row menu's actions on the whole selection, at hand.
            if sourcesListLayout == .wide {
                LibraryBulkBar(
                    onNewNotebook: { ids in createNotebook(with: ids) },
                    onRemove: { ids in requestSourceRemoval(ids) }
                )
            }

            if vm.libraryLoadErrorMessage != nil {
                libraryLoadFailureView
            } else if showFullAccessPrompt {
                fullAccessPrompt
            } else {
                sidebarList
            }
        }
        // The tab bar reaches the hidden-titlebar band as an overlay hung above
        // the panel's top edge — NOT via .ignoresSafeArea on this stack. On
        // macOS 26, a subtree that both ignores the top safe area and contains
        // a List stops painting its SwiftUI-drawn content entirely (the
        // NSTableView underneath still draws), which blanked the source-type
        // icons while the source rows kept rendering. Verified in isolation:
        // the overlay+offset composition paints, the ignoresSafeArea one does
        // not.
        // On the band's chrome (`studioBandOverlay`): when the search row is
        // hidden the List sits flush against the top safe area, so its rows
        // scroll up under the titlebar band and would otherwise bleed through
        // the source-type icons.
        .studioBandOverlay {
            sidebarTabBar
                // In the band, AppKit's titlebar drag would otherwise win over
                // the tabs' .onDrag reorder gesture and move the whole window.
                .background(WindowDragBlocker())
        }
        .background {
            SourceSearchShortcutTarget {
                if isSourceSearchFocused {
                    hideSourceSearch(clearingText: true)
                } else {
                    isSourceSearchFocused = true
                }
            }
        }
        .background(
            MouseUpObserver { completeDeferredSidebarOpenOnMouseUp() }
        )
        .onChange(of: dragVisibility.isDragging) { _, isDragging in
            // The press that became a drag is not a click: it must not open
            // the row on mouse-up. The selection it made stays, as it does in
            // every macOS list; a multi-selection it started from stays whole.
            if isDragging { keepDeferredSidebarSelectionForDrag() }
        }
        .task {
            async let drive: Void = refreshGoogleDriveConnectionState()
            async let meetings: Void = refreshMeetingPluginHealth()
            _ = await (drive, meetings)
        }
        // The rows' card counts, the No Cards pill's count and its list read
        // one coverage (`StudioViewModel.sourceCardCoverage`), read again
        // when the cards or the sources change; the same inputs in another
        // window read nothing twice. On the body, so a notebook's column
        // with its search row hidden reads it too.
        .task(id: "\(vm.memoryCardRevision)#\(vm.articles.count)#\(vm.activeTeamID ?? "")") {
            await vm.refreshSourceCardCoverage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in
            Task {
                async let drive: Void = refreshGoogleDriveConnectionState()
                async let meetings: Void = refreshMeetingPluginHealth()
                _ = await (drive, meetings)
            }
        }
        .onDeleteCommand {
            requestSourceRemoval(windowState.sidebarSelectedSourceIDs)
        }
        .confirmationDialog(
            sourceRemovalDialogTitle,
            isPresented: $isSourceRemovalDialogPresented,
            titleVisibility: .visible
        ) {
            Button(sourceRemovalHideLabel) {
                let targets = pendingRemoval
                pendingRemoval = StudioViewModel.SidebarRemovalTargets()
                isSourceRemovalDialogPresented = false
                Task { await vm.hideSidebarRemovalTargets(targets) }
            }
            Button(sourceRemovalRemoveLabel, role: .destructive) {
                let targets = pendingRemoval
                pendingRemoval = StudioViewModel.SidebarRemovalTargets()
                isSourceRemovalDialogPresented = false
                Task { await vm.removeSidebarRemovalTargets(targets) }
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = StudioViewModel.SidebarRemovalTargets()
            }
        } message: {
            if pendingRemoval.bookGroups.isEmpty {
                Text("Hidden sources leave the list only: chat, search and reviews still use them, and Hidden Items brings them back. You can undo immediately after removal.")
            } else {
                Text("Hidden books leave the list only: chat, search and reviews still use them, and Hidden Items brings them back. Removing a book keeps its files in iCloud; you can undo immediately after removal.")
            }
        }
        .modifier(SidebarAlertsGroup2(
            vm: vm,
            showPDFURLAlert: showPDFURLAlert, pdfURLText: pdfURLText, pdfURLArticleId: pdfURLArticleId,
            showBookRenameAlert: showBookRenameAlert, bookRenameText: bookRenameText, renamingBookGroup: renamingBookGroup,
            showBookAuthorAlert: showBookAuthorAlert, bookAuthorText: bookAuthorText, editingAuthorBookGroup: editingAuthorBookGroup,
            showBookSubtitleAlert: showBookSubtitleAlert, bookSubtitleText: bookSubtitleText, editingBookSubtitleGroup: editingBookSubtitleGroup,
            showBookEditionAlert: showBookEditionAlert, bookEditionText: bookEditionText, editingBookEditionGroup: editingBookEditionGroup,
            showBookKindAlert: showBookKindAlert, bookKindText: bookKindText, editingBookKindGroup: editingBookKindGroup,
            showDeleteBookAlert: showDeleteBookAlert, deletingBookGroup: deletingBookGroup
        ))
        .modifier(MeetingMergeAlert(
            vm: vm,
            isPresented: showMergeMeetingAlert,
            groups: mergingMeetingGroups
        ))
        .alert("Rename Meeting Group", isPresented: showRenameMeetingAlert) {
            TextField("Meeting group name", text: $alertText)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if let group = renamingMeetingGroup.wrappedValue {
                    let value = alertText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await vm.updateMeetingMetadata(groupName: group) { $0.title = value.isEmpty ? group : value } }
                }
            }
        }
        .alert("Merge Same-Day Sessions", isPresented: showMergeSameDayMeetingSessionsAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Merge") {
                if let group = mergingSameDayMeetingGroup.wrappedValue {
                    Task { await vm.mergeSameDayMeetingSessions(groupName: group) }
                }
            }
        } message: {
            let group = mergingSameDayMeetingGroup.wrappedValue
            let name = group.flatMap { vm.meetingDisplayName($0) } ?? "this meeting group"
            let surplus = group.map { vm.sameDayMeetingSessionSurplus(for: $0) } ?? 0
            Text(
                "Fold the \(surplus) session\(surplus == 1 ? "" : "s") of \(name) that share a day with an earlier one into that day's first session? "
                    + "The first session keeps its name; the others' transcripts follow it under a reconnection line, "
                    + "and their files and links move with them."
            )
        }
        .alert("Meeting Folder Image", isPresented: showMeetingFolderImageAlert) {
            TextField("Image address or file path", text: $alertText)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if let group = editingMeetingFolderImageGroup.wrappedValue {
                    vm.setMeetingFolderImageURL(alertText, for: group)
                }
            }
        } message: {
            Text("Paste the web address of an image, or the path to one on this Mac. A web address follows your account to your other devices; a file path only works here. Leave it empty to go back to the default icon.")
        }
        .alert("Delete Meeting Group", isPresented: showRemoveMeetingAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let group = removingMeetingGroup.wrappedValue {
                    Task { await vm.removeMeetingGroup(name: group) }
                }
            }
        } message: {
            let group = removingMeetingGroup.wrappedValue
            let name = group.flatMap { vm.meetingDisplayName($0) } ?? "this meeting group"
            let sessions = group.map { vm.meetingSessionCount(for: $0) } ?? 0
            let sessionText = sessions == 1 ? " and its 1 session" : " and its \(sessions) sessions"
            Text(
                "Delete \(name)\(sessions == 0 ? "" : sessionText) from ForeverLM? "
                    + "The folder and its files are left alone where they came from, "
                    + "so you can add it again later. "
                    + "You can undo for a few seconds; after that it is gone for good."
            )
        }
        .alert("Add YouTube Video", isPresented: showAddYouTubeVideoAlert) {
            TextField("YouTube URL", text: $alertText)
            Button("Cancel", role: .cancel) { }
            Button("Add") {
                let url = alertText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return }
                Task { try? await vm.addArticle(url: url) }
            }
        } message: {
            Text("Paste a YouTube video URL to add its transcript to your library.")
        }
        .alert("Add Zoom Recording", isPresented: showAddZoomRecordingAlert) {
            TextField("Zoom recording URL", text: $alertText)
            SecureField("Passcode (optional)", text: $zoomPasscodeText)
            Button("Cancel", role: .cancel) { }
            Button("Add") {
                let url = alertText.trimmingCharacters(in: .whitespacesAndNewlines)
                let passcode = zoomPasscodeText.trimmingCharacters(in: .whitespacesAndNewlines)
                zoomPasscodeText = ""
                guard !url.isEmpty else { return }
                guard ZoomRecordingService.isZoomRecordingURL(url) else {
                    vm.showToast("Paste a Zoom cloud-recording link.")
                    return
                }
                Task {
                    try? await vm.addArticle(
                        url: url,
                        zoomPasscode: passcode.isEmpty ? nil : passcode
                    )
                }
            }
        } message: {
            Text("The passcode is saved securely and entered automatically.")
        }
        .alert("Enter Zoom Passcode", isPresented: showZoomPasscodeAlert) {
            SecureField("Passcode", text: $alertText)
            Button("Cancel", role: .cancel) { }
            Button("Fetch Transcript") {
                if let id = zoomPasscodeArticleId.wrappedValue, !alertText.isEmpty {
                    let passcode = alertText
                    Task { await vm.fetchZoomTranscript(for: id, passcode: passcode) }
                }
            }
        } message: {
            Text("Saved securely in Keychain and reused for this recording.")
        }
        .alert("Rename Playlist", isPresented: showRenameVideoPlaylistAlert) {
            TextField("Playlist title", text: $alertText)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if let group = renamingVideoPlaylistGroup.wrappedValue {
                    Task { await vm.updateVideoPlaylistTitle(groupName: group, title: alertText) }
                }
            }
        } message: {
            Text("Enter a display title for this playlist.")
        }
        .alert("Remove Playlist", isPresented: showRemoveVideoPlaylistAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                if let group = removingVideoPlaylistGroup.wrappedValue {
                    Task { await vm.removeVideoPlaylistGroup(group) }
                }
            }
        } message: {
            let name = removingVideoPlaylistGroup.wrappedValue.flatMap { vm.videoPlaylistDisplayName($0) } ?? "this playlist"
            Text("Remove \"\(name)\"? You can undo immediately after removal.")
        }
        .sheet(item: $chapterManagerTarget) { target in
            ManageBookChaptersSheet(groupName: target.groupName)
        }
        .sheet(item: $meetingScheduleTarget) { target in
            MeetingScheduleSheet(groupName: target.groupName)
        }
    }

    /// New Notebook with the sources chosen: made at once, with no form
    /// (ForeverLM names it, `NotebookNaming`). The learner made a notebook to
    /// work in: it opens here, with the sources they chose.
    func createNotebook(with sourceIDs: [String]) {
        Task {
            guard let created = await vm.createNotebook(sourceIDs: sourceIDs) else { return }
            vm.openNotebook(created.id, in: windowState)
        }
    }

}
