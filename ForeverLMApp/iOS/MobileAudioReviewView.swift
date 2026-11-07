import SwiftUI

// The phone's shell (docs/notebooks-design.md, "iPhone"). Home is the
// Notebooks list (`MobileNotebookHomeView`) at the root of one navigation
// stack; a notebook, the Reader, Memory, the Space and its pages, the Library
// and Settings are pushed on it as typed routes, so a link
// (`foreverlm://notebook/…`, `…/source/…`, `…/doc/…`) and the cold launch's
// return to the last notebook can push them too. On a screen with the room,
// the Space is a split view over the stack instead (`MobileSpaceSplitView`). Voice
// (CarPlay, Review by Voice) is a full-screen cover over whatever is on screen,
// so it comes back to what was open. Playback rides outside the stack.
struct MobileAudioReviewView: View {
    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @ObservedObject private var live = MobileVoiceConversationController.shared
    @State private var path: [MobileShellRoute] = []
    /// The voice conversation that just ended, shown in the cover until Done.
    @State private var completedVoiceChat: MobileVoiceChatTranscript?
    @State private var isEndingVoiceSession = false
    /// What the cover's presentation is set to; it follows
    /// `isVoiceCoverPresented`, and is asked again when UIKit refused it.
    @State private var showsVoiceCover = false
    /// Whether the cover's content is on screen, so a refused presentation
    /// can be told from one that happened.
    @State private var voiceCoverIsOnScreen = false
    /// The Space as a split view over Home, on a screen with the room for one.
    @State private var spaceCover: MobileSpaceCoverRequest?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// True on iPad, where the first-sync welcome gets the large-title treatment.
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack(path: $path) {
            homeRoot
                .navigationDestination(for: MobileShellRoute.self) { route in
                    destination(route)
                }
        }
        // The Space's screens push on this stack, and read the notebooks for a row's notebook and a
        // page's `[[` and `@`.
        .environment(MobileSpaceStore.shared)
        .environment(MobileSpaceRecents.shared)
        .environment(\.spaceNavigation, .stack($path))
        .environment(\.spaceNotebookTitles, Dictionary(vm.notebooks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }))
        .fullScreenCover(item: $spaceCover) { request in
            MobileSpaceSplitView(
                request: request,
                onClose: { spaceCover = nil },
                onFollow: { link in
                    // A source or a notebook opens where the Space was opened from, under it.
                    spaceCover = nil
                    follow(link, fromInsideApp: true)
                }
            )
            .environment(MobileSpaceStore.shared)
            .environment(MobileSpaceRecents.shared)
            .environment(\.spaceNotebookTitles, Dictionary(vm.notebooks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }))
            .environmentObject(vm)
        }
        // A link tapped in a chat or a Doc (a citation, a notebook's address)
        // is followed here, in this stack, rather than handed to the system.
        .environment(\.openURL, OpenURLAction { url in
            guard let link = MobileDeepLink.parse(url) else { return .systemAction }
            follow(link, fromInsideApp: true)
            return .handled
        })
        // Playback belongs to the app shell, not to any one destination. Keeping
        // the bar outside the NavigationStack's presented content makes it stay
        // in place while the learner moves between Home, a notebook, the
        // reader, the library, Settings, and the rest of the stack.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // A hands-free review or source chat (Siri, a notebook's
                // Quiz) speaks wherever it was started; this says what it is
                // doing on every screen. Playback has the bar below.
                if vm.isReviewActive || vm.isSourceChatActive {
                    MobileSessionBanner()
                        .environmentObject(vm)
                }
                MobileCompactPlaybackBar()
            }
        }
        .fullScreenCover(isPresented: voiceCoverBinding) {
            MobileVoiceSessionCover(
                completedTranscript: $completedVoiceChat,
                isEnding: $isEndingVoiceSession,
                onFollowLink: { link in follow(link, fromInsideApp: true) }
            )
            .environmentObject(vm)
            .onAppear { voiceCoverIsOnScreen = true }
            .onDisappear { voiceCoverIsOnScreen = false }
        }
        .onChange(of: isVoiceCoverPresented, initial: true) { _, wanted in
            showsVoiceCover = wanted
        }
        .task(id: isVoiceCoverPresented) {
            await presentVoiceCoverWhenRefused()
        }
        .alert(item: $vm.textToSpeechCostConfirmation) { confirmation in
            Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .default(Text("Generate")) {
                    vm.resolveTextToSpeechCostConfirmation(approved: true)
                },
                secondaryButton: .cancel {
                    vm.resolveTextToSpeechCostConfirmation(approved: false)
                }
            )
        }
        // Where the system asked to go: the widget's Today (Home, where the
        // plan is a card) and review taps, Siri, the reminder, a notebook or
        // a source named by a link.
        .onChange(of: vm.pendingDeepLink) { _, link in
            guard let link else { return }
            vm.pendingDeepLink = nil
            follow(link)
        }
        .task {
            // A request that launched the app arrives before this view does.
            if let link = vm.pendingDeepLink {
                vm.pendingDeepLink = nil
                follow(link)
            }
        }
    }

    // MARK: - Home

    @ViewBuilder
    private var homeRoot: some View {
        Group {
            if vm.isLoading && vm.allSources.isEmpty && !vm.hasDismissedInitialSyncScreen {
                loadingState
            } else {
                MobileNotebookHomeView { route in open(route) }
            }
        }
        // No title: the brand is the app's icon, and a large "ForeverLM" over the list only moved
        // the notebooks down (the product owner, 2026-10-11: it "looks ugly"). The bar holds Settings
        // and, in Home's own toolbar, +; voice sits beside Search at the bottom.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: MobileShellRoute.settings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("home.settings")
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: MobileShellRoute) -> some View {
        switch route {
        case .notebook(let notebookID):
            MobileNotebookScreen(notebookID: notebookID)
        case .source(let sourceID, let notebookID):
            MobileShellSourceDestination(sourceID: sourceID, notebookID: notebookID)
        case .doc(let artifactID, let notebookID):
            MobileShellPageDestination(pageID: artifactID, notebookID: notebookID)
        case .space(let place):
            MobileSpaceScreen(place: place)
        case .page(let pageID):
            MobileShellPageDestination(pageID: pageID, notebookID: nil)
        case .savedChat(let sessionID, let title):
            MobileNotebookSavedChatScreen(sessionID: sessionID, title: title)
        case .memory:
            MobileMemoryScreen { route in path.append(route) }
        case .cardReview(let scope):
            MobileCardReviewScreen(mode: .today(scope))
        case .cardPractice(let scope):
            MobileCardReviewScreen(mode: .today(scope), opensAsPractice: true)
        case .notebookPractice(let notebookID):
            MobileCardReviewScreen(mode: .notebookPractice(notebookID: notebookID))
        case .cardsToCheck(let notebookID):
            MobileCardsToCheckScreen(notebookID: notebookID) { sourceID in
                path.append(.source(sourceID, notebookID: notebookID))
            }
        case .course(let courseID):
            MobileCoursePageScreen(courseID: courseID)
        case .notebooks(let filter):
            MobileNotebooksScreen(filter: filter) { route in path.append(route) }
        case .library:
            MobileSourceBrowserView()
        case .toRead:
            MobileToReadScreen()
        case .followUp:
            MobileFollowUpScreen()
        case .settings:
            MobileSettingsView()
        }
    }

    // MARK: - Routes

    /// Opens a route Home asked for. On a screen with the room for it the Space is the split view
    /// over Home (a page in it, for today's note); everything else, and the Space on a phone, is
    /// pushed.
    private func open(_ route: MobileShellRoute) {
        let roomy = MobileSpaceLayout.usesSplitView(isRegularWidth: horizontalSizeClass == .regular,
                                                    isRegularHeight: verticalSizeClass == .regular)
        switch route {
        case .space(let place) where roomy:
            spaceCover = MobileSpaceCoverRequest(place: place ?? .all)
        case .page(let pageID) where roomy:
            spaceCover = MobileSpaceCoverRequest(pageID: pageID)
        default:
            path.append(route)
        }
    }

    /// Follows a link or a system request in this stack. A source is pushed
    /// where the learner is, in the notebook they are in, so a citation's
    /// Reader returns to its chat. A notebook named by a link from outside
    /// (a calendar note, another app) replaces the stack, so Back is Home;
    /// one linked from inside the app (a Doc, a chat) is pushed, so Back
    /// returns to where it was linked from.
    private func follow(_ link: MobileDeepLink, fromInsideApp: Bool = false) {
        path = MobileShellRoute.following(link, from: path, fromInsideApp: fromInsideApp)
    }

    // MARK: - Voice

    private var isVoiceCoverPresented: Bool {
        live.isActive || isEndingVoiceSession || completedVoiceChat != nil || live.needsSignIn
    }

    private var voiceCoverBinding: Binding<Bool> {
        Binding(
            get: { showsVoiceCover },
            set: { presented in
                showsVoiceCover = presented
                guard !presented else { return }
                completedVoiceChat = nil
                if live.needsSignIn { live.cancelSignIn() }
            }
        )
    }

    /// Voice can start while a sheet or cover is still leaving (CarPlay starts
    /// it from the car at any moment), so the cover is asked for while that
    /// sheet or cover is still leaving — and UIKit
    /// refuses a presentation while another is under way, which would leave a
    /// session running with nothing on screen. So while the cover is wanted
    /// and its content has not appeared, it is asked for again; one that
    /// presented the first time is never touched.
    private func presentVoiceCoverWhenRefused() async {
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, isVoiceCoverPresented else { return }
            if voiceCoverIsOnScreen { return }
            showsVoiceCover = false
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, isVoiceCoverPresented else { return }
            showsVoiceCover = true
        }
    }

    // MARK: - First sync

    private var loadingState: some View {
        // The first sync is a background pass, not a doorway. On a first launch
        // this used to be a wait screen — a spinner, a record count, and the
        // whole iPad canvas black around it — that read as "the app is stuck".
        // It is now an invitation: start using ForeverLM, and the library fills
        // in behind you. The sync readout stays, demoted to a small card, and the
        // shell's sync row carries the same numbers once the learner leaves.
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Gated on the pass itself, not on progress numbers: the walk's
            // first stretches can page through thousands of records this
            // catalog doesn't collect before the first checkpoint lands.
            if vm.isInitialCatalogSync {
                // Sized to the canvas: on a phone this fills the screen at the
                // ordinary type sizes, but on an iPad the same cluster sat as a
                // small island in a field of black. Regular width gets the
                // large-title treatment — bigger glyph, bigger type, a wider
                // measure — so the welcome reads as the page, not a dialog on it.
                VStack(spacing: isRegularWidth ? MobileDesign.Spacing.xLarge : MobileDesign.Spacing.large) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: isRegularWidth ? 72 : 44, weight: .light))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    VStack(spacing: isRegularWidth ? MobileDesign.Spacing.medium : MobileDesign.Spacing.small) {
                        Text("Get started while iCloud syncs")
                            .font(isRegularWidth ? .largeTitle.weight(.bold) : .title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text("Your library fills in from iCloud while you work.")
                            .font(isRegularWidth ? .title3 : .body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: initialSyncMeasure)

                    Button {
                        vm.dismissInitialSyncScreen()
                    } label: {
                        Text("Get Started")
                            .font(isRegularWidth ? .title3.weight(.semibold) : .headline)
                            .frame(minWidth: isRegularWidth ? 260 : 200)
                            .padding(.vertical, isRegularWidth ? MobileDesign.Spacing.small : 0)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("voice.dismissSyncScreen")
                }
                .padding(.horizontal, MobileDesign.Spacing.xLarge)

                Spacer().frame(height: isRegularWidth ? 48 : MobileDesign.Spacing.xxLarge)

                initialSyncCard
                    .padding(.horizontal, MobileDesign.Spacing.xLarge)
            } else if let status = vm.syncStatus {
                syncStatusView(status)
            } else {
                ProgressView()
                Text("Syncing your sources…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, MobileDesign.Spacing.medium)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// How wide the welcome and its card may run. A phone gets a paragraph
    /// measure; an iPad gets the readable-content width so the type above can
    /// grow without wrapping into a tall column.
    private var initialSyncMeasure: CGFloat {
        isRegularWidth ? 600 : 440
    }

    /// The sync readout as a quiet card under the welcome: the step, the live
    /// count, a real bar when there is one, and the one caveat that matters
    /// (a lock mid-pass stops it) — never the headline.
    private var initialSyncCard: some View {
        HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
            if let status = vm.syncStatus, status.fractionComplete == nil {
                ProgressView()
                    .controlSize(isRegularWidth ? .regular : .small)
                    .padding(.top, 2)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(isRegularWidth ? .body : .subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: isRegularWidth ? MobileDesign.Spacing.small : MobileDesign.Spacing.xSmall) {
                Text(vm.syncStatus?.stepText ?? "Syncing your library")
                    .font(isRegularWidth ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                    .contentTransition(.identity)
                Text(vm.syncStatus?.detailText ?? "Connecting to iCloud…")
                    .font(isRegularWidth ? .subheadline : .footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("voice.syncProgress")
                if let fraction = vm.syncStatus?.fractionComplete {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .accessibilityIdentifier("voice.syncProgressBar")
                }
                Text("Keep ForeverLM open until it finishes. If it is interrupted, it picks up where it left off.")
                    .font(isRegularWidth ? .footnote : .caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(isRegularWidth ? MobileDesign.Spacing.xLarge : MobileDesign.Spacing.large)
        .mobileFloatingSurface(cornerRadius: MobileDesign.Radius.card)
        .frame(maxWidth: initialSyncMeasure)
        .accessibilityElement(children: .combine)
    }

    /// A determinate bar once the current phase can honestly estimate a
    /// fraction (a prior full walk's total, or a known download count);
    /// an indeterminate spinner otherwise — never a bar that fills on guesswork.
    private func syncStatusView(_ status: MobileCatalogSyncStatus) -> some View {
        VStack(spacing: 10) {
            if let fraction = status.fractionComplete {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                    .accessibilityIdentifier("voice.syncProgressBar")
            } else {
                ProgressView()
            }
            Text(status.stepText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.identity)
            Text(status.detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityIdentifier("voice.syncProgress")
        }
        .animation(.default, value: status.phase)
    }
}

/// The Reader for a source a link named. A source that has not reached this
/// phone says so rather than showing an empty reader.
struct MobileShellSourceDestination: View {
    let sourceID: String
    let notebookID: String?

    @EnvironmentObject private var vm: MobileAudioReviewViewModel

    var body: some View {
        if let source = vm.sourcesByID[sourceID] {
            MobileSourceReaderView(
                source: source,
                notebook: notebookID.flatMap { id in vm.notebooks.first { $0.id == id } }
            )
        } else {
            ContentUnavailableView(
                "Not on This iPhone Yet",
                systemImage: "icloud.and.arrow.down",
                description: Text("This source has not synced from your Mac yet.")
            )
            .navigationTitle("Source")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// A page a route named, looked up when it is drawn. The learner's own Markdown page the Space holds is
/// written in place (`MobilePageScreen`), opened from the Space, a link or a notebook's Studio alike, so
/// a page edits the same everywhere on the phone. What the Space does not write here — a reading, a
/// linked Google Doc, a team's page — is read in the notebook that opened it, as before, and so is
/// every page under generation 1.
private struct MobileShellPageDestination: View {
    let pageID: String
    /// The notebook whose Studio opened it; nil from the Space or a link.
    let notebookID: String?

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(MobileSpaceStore.self) private var spaceStore

    var body: some View {
        Group {
            if let read = readInNotebook {
                if read.artifact.isMnemonicReading {
                    MobileMnemonicReadingView(artifact: read.artifact, notebook: read.notebook, vm: vm)
                } else {
                    MobileNotebookDocView(artifact: read.artifact, notebook: read.notebook)
                }
            } else {
                MobilePageScreen(pageID: pageID)
            }
        }
        .task {
            // A Studio's page opened before the Space was read: read it, so an own page is written.
            if notebookID != nil, !spaceStore.isAvailable { await spaceStore.refresh() }
        }
    }

    /// The page and notebook it is read in, when the Space does not write it here.
    private var readInNotebook: (artifact: MobileCloudArtifact, notebook: MobileCloudNotebook)? {
        if spaceStore.isAvailable, let page = spaceStore.pages.first(where: { $0.id == pageID }),
           notebookID == nil || page.isEditableMarkdown {
            return nil
        }
        guard let artifact = vm.notebookArtifacts.first(where: { $0.id == pageID }),
              let notebookID = notebookID ?? artifact.homeNotebookID,
              let notebook = vm.notebooks.first(where: { $0.id == notebookID }) else { return nil }
        return (artifact, notebook)
    }
}

/// Today's review chat from before cards, continued: the card review's
/// menu offers it only while that chat holds an answer of the learner's
/// (`MobileCardReviewSession.dayChatIsUnderway`), and it never prepares one —
/// a chat gone meanwhile says so. Every entry that opened this chat opens
/// the card review since the phone's card review (docs/memory-design.md,
/// "The card review on the iPhone"); voice still speaks the chat, preparing
/// it when none exists. This screen owns the conversation while it is on the
/// stack.
struct MobileMemoryReviewChatScreen: View {
    @StateObject private var review = MobileMemoryReviewViewModel(preparesIfMissing: false)

    var body: some View {
        MobileMemoryReviewView(viewModel: review) {
            // The same review, spoken turn by turn: voice drives this very
            // review, so its cards follow the conversation.
            Task { await MobileVoiceConversationController.shared.startMemoryReview(review) }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The voice session as a full-screen cover over wherever it was started —
/// Home, a notebook, the Reader — so ending it returns there. It shows the
/// live session, then the conversation that just ended until Done; a start
/// that needs Sign in with Apple asks here, inside the same cover, so no sheet
/// races the cover's own dismissal.
struct MobileVoiceSessionCover: View {
    @Binding var completedTranscript: MobileVoiceChatTranscript?
    @Binding var isEnding: Bool
    /// Follows a foreverlm:// link in the shell's stack, under the cover.
    let onFollowLink: (MobileDeepLink) -> Void

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @ObservedObject private var live = MobileVoiceConversationController.shared

    var body: some View {
        Group {
            if live.isActive || isEnding {
                session
            } else if live.needsSignIn {
                signIn
            } else if let completedTranscript {
                NavigationStack {
                    MobileVoiceTranscriptView(transcript: completedTranscript)
                        .navigationTitle(transcriptTitle)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { self.completedTranscript = nil }
                                    .accessibilityIdentifier("voice.transcript.done")
                            }
                        }
                }
                // A source the conversation cited opens where it was started:
                // the transcript closes, and the Reader is pushed in the
                // notebook (or on Home) under it.
                .environment(\.openURL, OpenURLAction { url in
                    guard let link = MobileDeepLink.parse(url) else { return .systemAction }
                    self.completedTranscript = nil
                    onFollowLink(link)
                    return .handled
                })
            } else {
                Color(uiColor: .systemBackground).ignoresSafeArea()
            }
        }
    }

    private var transcriptTitle: String {
        live.activeNotebook?.title ?? live.activeSourceTitle ?? "Voice Chat"
    }

    private var session: some View {
        VStack(spacing: MobileDesign.Spacing.medium) {
            VoiceSessionSurface(
                state: presentationState,
                identifierPrefix: "voice",
                recoveryActionTitle: "Resume",
                onRecovery: { Task { await live.resume() } },
                onToggleMute: live.toggleMicrophoneMuted,
                onEnd: end,
                onDismissError: { live.errorMessage = nil }
            )
            if let figure = live.presentedFigure {
                MobilePaperFigureCard(
                    figure: figure,
                    panel: nil,
                    relativePDFPath: vm.allSources
                        .first(where: { $0.id == figure.sourceID })
                        .flatMap {
                            MobileSourceFilePath.relativePDFPath(
                                localFilePath: $0.localFilePath,
                                url: $0.url
                            )
                        }
                )
                    .padding(.horizontal, MobileDesign.Spacing.large)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: live.presentedFigure?.id)
    }

    /// Signed out is the one voice-start failure the learner can act on, so it
    /// gets the real Sign in with Apple button.
    private var signIn: some View {
        NavigationStack {
            MobileSignInPrompt {
                Task { await live.resumeAfterSignIn() }
            }
            .navigationTitle("Voice Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { live.cancelSignIn() }
                }
            }
        }
    }

    private func end() {
        guard !isEnding else { return }
        isEnding = true
        Task {
            await live.end()
            let transcript = MobileVoiceChatTranscript(turns: live.transcript)
            // A session ended before anyone spoke has nothing to show; the
            // cover closes on what was under it.
            completedTranscript = transcript.messages.isEmpty ? nil : transcript
            isEnding = false
        }
    }

    private var presentationState: VoiceSessionPresentationState {
        let header: (title: String, image: String)
        if let target = live.activeMemoryTarget {
            header = (target, "brain.head.profile")
        } else if let notebook = live.activeNotebook {
            header = (notebook.title, MobileNotebookGlyph.symbolName)
        } else if let title = live.activeSourceTitle {
            header = (title, "doc.text")
        } else {
            header = ("Voice", "waveform")
        }

        return VoiceSessionPresentationState(
            phase: live.phase.presentationPhase,
            statusText: live.statusText,
            headerTitle: header.title,
            headerSystemImage: header.image,
            contextItems: live.loadedSources.map {
                VoiceContextItem(
                    id: $0.id,
                    title: $0.title,
                    subtitle: $0.citationSubtitle,
                    sourceType: $0.sourceType,
                    thumbnailURL: $0.thumbnailURL
                )
            },
            isMicrophoneMuted: live.isMicrophoneMuted,
            microphoneLevel: live.microphoneLevel,
            terminalErrorMessage: live.phase == .failed ? live.errorMessage : nil,
            inlineErrorMessage: live.phase == .failed ? nil : live.errorMessage,
            isTutorWorking: live.isTutorWorking,
            caption: live.caption
        )
    }
}

private extension MobileVoiceConversationController.Phase {
    var presentationPhase: VoiceSessionPhase {
        switch self {
        case .idle: return .idle
        case .connecting: return .connecting
        case .live: return .live
        case .ending: return .ending
        case .failed: return .failed
        }
    }
}

private struct MobileSessionBanner: View {
    @EnvironmentObject private var vm: MobileAudioReviewViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: bannerIcon)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(bannerTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(bannerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.medium)
        .background(.ultraThinMaterial)
    }

    private var bannerIcon: String {
        if vm.isReviewActive { return "brain.head.profile" }
        if vm.isSourceChatActive { return "text.bubble" }
        if vm.currentItem == nil, vm.textToSpeechPreparingTitle != nil { return "waveform" }
        if vm.currentItem == nil, vm.narrationDownloadSourceID != nil { return "icloud.and.arrow.down" }
        return vm.isPlaying ? "speaker.wave.2.fill" : "speaker.slash"
    }

    private var bannerTitle: String {
        if vm.isReviewActive {
            return vm.reviewTitle ?? "review"
        }
        if vm.isSourceChatActive {
            return vm.activeChatTitle ?? "Source chat"
        }
        if vm.currentItem == nil, let preparing = vm.textToSpeechPreparingTitle {
            return preparing
        }
        if vm.currentItem == nil, let downloading = vm.narrationDownloadTitle {
            return downloading
        }
        return vm.currentItem?.title ?? "Playback"
    }

    private var bannerSubtitle: String {
        if vm.isReviewActive {
            return vm.voice.isListening ? "Listening for your answer" : (vm.reviewStatus ?? "In progress")
        }
        if vm.isSourceChatActive {
            return vm.voice.isListening ? "Listening" : "Ask Siri to stop the chat"
        }
        if vm.currentItem == nil, vm.textToSpeechPreparingTitle != nil {
            if let progress = vm.textToSpeechGenerationProgress {
                return "Generating audio · \(progress.percentCompleted)%"
            }
            return vm.textToSpeechPreparationDetail ?? "Preparing audio…"
        }
        if vm.currentItem == nil, let download = vm.narrationDownloadProgress {
            return download.statusLabel(at: Date())
        }
        return vm.playerDetailText
    }
}

/// Today's plan on the home screen. This is the only place the phone displays a
/// plan: there is no Schedule pane, and planning itself happens in the
/// conversation through the Schedule voice tools, exactly as on the Mac.
///
/// Each row opens its source. The leading circle is the only hand-driven
/// completion in the UI — opening a source records activity, never completion —
/// and the row's long-press menu quizzes that one source. Since 2026-10-06
/// the calendar glyph is grey and no row carries an accent quiz button
/// (the product owner: "cleaner and fewer buttons and bells and whistles").
struct MobileTodayPlanCard: View {
    let items: [MobileScheduledCatalogItem]
    let maxRows: Int
    let onMarkDone: (MobileScheduledCatalogItem) -> Void
    let onQuiz: (MobileScheduledCatalogItem) -> Void

    private var visibleItems: [MobileScheduledCatalogItem] {
        Array(items.prefix(maxRows))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            HStack(spacing: MobileDesign.Spacing.small) {
                Image(systemName: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Today")
                    .font(.headline)
                Spacer(minLength: 0)
                Text(items.count == 1 ? "1 source" : "\(items.count) sources")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(visibleItems) { item in
                    if item.id != visibleItems.first?.id {
                        Divider()
                    }
                    MobileTodayPlanRow(
                        item: item,
                        onMarkDone: { onMarkDone(item) },
                        onQuiz: { onQuiz(item) }
                    )
                }
            }

            if items.count > maxRows {
                Text("+\(items.count - maxRows) more")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(MobileDesign.Spacing.medium)
        .mobileFloatingSurface()
        .accessibilityIdentifier("home.todayPlan")
    }
}

/// One pending item on today's plan. The circle is a sibling of the source
/// link rather than nested inside it, so each gets its own tap; Quiz Me is
/// the row's long-press menu and a VoiceOver action.
private struct MobileTodayPlanRow: View {
    let item: MobileScheduledCatalogItem
    let onMarkDone: () -> Void
    let onQuiz: () -> Void

    @EnvironmentObject private var vm: MobileAudioReviewViewModel

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Button(action: onMarkDone) {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: MobileDesign.Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.isMutatingLibrary)
            .accessibilityLabel("Mark \(item.source.title) done")
            .accessibilityIdentifier("today.markDone")

            NavigationLink(value: MobileShellRoute.source(item.source.id, notebookID: nil)) {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.xSmall) {
                    Text(item.source.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let detailText {
                        Text(detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today.item")
            .accessibilityAction(named: "Quiz Me") { onQuiz() }
        }
        .padding(.vertical, MobileDesign.Spacing.xSmall)
        .contextMenu {
            Button("Quiz Me", systemImage: "brain.head.profile", action: onQuiz)
                .accessibilityIdentifier("today.quiz")
        }
    }

    /// What the app has actually seen happen with this source today. It is a
    /// hint, never a completion claim — that is what the circle is for.
    private var activityHint: String? {
        let today = Calendar.current.startOfDay(for: Date())
        let kinds = Set(
            item.activityDays
                .filter { Calendar.current.startOfDay(for: $0.dayStart) == today }
                .flatMap(\.kinds)
        )
        if kinds.contains(.review) { return "reviewed" }
        if kinds.contains(.chat) { return "discussed" }
        if kinds.contains(.listening) { return "played" }
        if kinds.contains(.watching) { return "played" }
        if kinds.contains(.reading) { return "opened" }
        return nil
    }

    private var detailText: String? {
        var parts: [String] = []
        if let groupTitle = item.groupTitle, !groupTitle.isEmpty {
            parts.append(groupTitle)
        } else if let subtitle = item.source.citationSubtitle, !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if let activityHint {
            parts.append(activityHint)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
