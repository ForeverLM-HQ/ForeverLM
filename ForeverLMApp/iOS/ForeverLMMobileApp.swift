import SwiftUI

@main
struct ForeverLMMobileApp: App {
    // Shared with the CarPlay scene (see MobileAudioReviewViewModel.shared).
    @StateObject private var viewModel = MobileAudioReviewViewModel.shared
    // CloudKit pushes for the library's sync (MobileAppDelegate).
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @State private var account = MobileAccountGateModel()
    @Environment(\.scenePhase) private var scenePhase
    // Scene activation and the root task race on cold launch. Foreground refresh
    // stays disabled until the root task finishes so they cannot start two loads.
    @State private var hasCompletedInitialLoad = false
    @State private var showsCreditsRequired = false
    @State private var handledCreditsEmptyEpisode = false

    init() {
        // Background task handlers must be registered before launch finishes.
        MobileMemoryReviewScheduler.shared.register()
        // Under generation 2 narration is the replica's, kept in a working folder instead of iCloud Drive.
        MobileNarrationLibrary.install()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showsVoiceSurfacePreview {
                    voiceSurfacePreview
                } else if showsPageEditorPreview {
                    pageEditorPreview
                } else if showsSpacePreview {
                    spacePreview
                } else if showsHomePreview {
                    homePreview
                } else if showsAppPreview {
                    appPreview
                } else if account.showsWall {
                    // Sign in with Apple comes before everything else, same as the
                    // Mac: it is the identity managed AI meters against, and the
                    // wall is the one place the app ever asks.
                    MobileAccountWall(
                        isResolving: account.isResolving,
                        isCheckingSession: account.isValidatingLapsedSession
                    ) {
                        account.didSignIn()
                        Task {
                            // The walled load() published signedIn=false into the
                            // view model; reload so the session is visible, then
                            // run anything Siri queued while the wall was up.
                            await viewModel.load(forceRefresh: false)
                            await viewModel.handlePendingSiriCommandIfNeeded()
                        }
                    }
                } else {
                    // Notebooks are the phone's front door: Home lists them,
                    // and a launch reopens the notebook last worked in. Voice
                    // is CarPlay and Review by Voice; typed chat lives in a notebook's Chat tab and the
                    // Reader's Ask. Everything records back to the Mac.
                    MobileAudioReviewView()
                        .environmentObject(viewModel)
                        .environment(account)
                }
            }
            #if DEBUG
            // XCUITest-only self-check line (launch-argument gated); see
            // MobileUITestProbe. Mounted outside the wall so the probe's
            // CloudKit checks stay readable on a runner that has no Apple ID
            // to sign in with. Bottom-leading keeps it clear of the hero and
            // the session banner.
            .overlay(alignment: .bottomLeading) {
                if MobileUITestProbe.isEnabled {
                    MobileUITestProbeView()
                        .padding(.leading, 4)
                }
            }
            #endif
            .foreverlmWritingToolsDisabled()
            .task {
                await account.validateStoredSession()
            }
            .task {
                await Task.detached(priority: .utility) {
                    KeychainService.purgeRetiredProviderData()
                    // And the preference keys nothing reads: the paid app's
                    // cached plan and clock (2026-11-24, ForeverLM is free).
                    RetiredDefaultsCleanup.runAtLaunch()
                }.value
            }
            .task {
                // One-time cleanup of reminders registered under the retired
                // notification scheme. The helper no-ops after its first run, and it
                // owes nothing to iCloud, so it stays outside the gate below.
                NotificationRetirement.cancelAll()
            }
            .task(id: account.hasAccountAccess) {
                // The bout's clock, behind the same gate as the catalog and for
                // the same reason: it reads the private database, and building
                // a CKContainer before there is an account to resolve it
                // against traps the process rather than throwing.
                guard account.hasAccountAccess == true, !showsPreview else { return }
                MobileLearningBoutTimer.shared.start()
            }
            .task(id: account.hasAccountAccess) {
                // The catalog reads through the sync session, which builds its
                // CKContainer, and CloudKit answers a container it will not
                // serve by trapping the process rather than by throwing, so
                // nothing may load before the gate has answered. A device that
                // never signed in has no account persona to resolve the
                // container against, and nothing here belongs to it anyway: the
                // catalog is the user's own private database. The wall's
                // `didSignIn` handler loads the list on sign-in. A DEBUG
                // preview draws a sample library and never syncs.
                guard account.hasAccountAccess == true, !showsPreview else { return }
                // The sync (docs/cloudkit-schema-design.md §2.3), beside the catalog below.
                if MobileSyncSession.isEnabled {
                    Task { await MobileSyncSession.startIfEnabled() }
                }
                await viewModel.load(forceRefresh: false)
                // The daily quiz reminder, on for every signed-in phone.
                await MobileMemoryReviewScheduler.ensureDailyReminder(hour: MobileMemoryReviewScheduler.shared.hour)
                await viewModel.importPendingSharedSources()
                await viewModel.handlePendingSiriCommandIfNeeded()
                hasCompletedInitialLoad = true
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else {
                    viewModel.flushPlaybackProgress()
                    if MobileSyncSession.isEnabled {
                        // iOS suspends the app within seconds of this; the assertion keeps it running until the
                        // sitting and the day's activity have been sent (D44).
                        let assertion = MobileBackgroundSaveAssertion(name: "ForeverLM sync flush")
                        Task {
                            await MobileSyncSession.current?.background()
                            await MainActor.run { assertion.end() }
                        }
                    }
                    return
                }
                // Event-driven recheck, like the Mac: a revocation that lands
                // while backgrounded takes effect on next use. The interval
                // makes the cold-launch flip a no-op after the launch check.
                Task { await account.validateStoredSession(minimumInterval: 15 * 60) }
                Task { await resetCreditsEmptyEpisodeIfResolved() }
                // Everything below reaches iCloud, so it waits for the same
                // gate the launch preload waits for. A foreground on a
                // signed-out device must not be the thing that builds the
                // CloudKit container.
                guard account.hasAccountAccess == true else { return }
                if MobileSyncSession.isEnabled {
                    Task { await MobileSyncSession.current?.foreground() }
                }
                // A text-to-speech generation the phone suspended part-way finishes
                // from its journaled chunks rather than starting over: coming
                // back to the app is enough to pick it up where it stopped.
                Task { await viewModel.resumeInterruptedTextToSpeechGeneration() }
                // The first foreground after the hour is the path that always
                // works for preparing today's review; the background refresh
                // is a courtesy iOS may or may not extend.
                Task {
                    await MobileMemoryReviewScheduler.shared.prepareIfDue()
                    MobileMemoryReviewScheduler.shared.scheduleNextRefresh()
                }
                guard hasCompletedInitialLoad else { return }
                // Cheap: the catalog load is a coalesced zone-delta behind a
                // snapshot.
                Task {
                    await viewModel.load()
                    // Quietly fetch the narrations likely to be played next, on Wi-Fi only.
                    viewModel.startNarrationPrefetch()
                }
                Task { await viewModel.importPendingSharedSources() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mobileSiriCommandQueued)) { _ in
                guard !account.showsWall else { return }
                Task { await viewModel.handlePendingSiriCommandIfNeeded() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .managedAICreditsEmpty)) { _ in
                // Several requests can fail together when nothing can pay.
                // Present once for that episode, just like the Mac shell,
                // while each feature keeps its local error.
                guard !account.showsWall, !handledCreditsEmptyEpisode else { return }
                handledCreditsEmptyEpisode = true
                showsCreditsRequired = true
            }
            .sheet(isPresented: $showsCreditsRequired) {
                MobileCreditsRequiredSheet()
            }
            .onOpenURL { url in
                // The widget's Today and review taps, a notebook named in a
                // calendar note or a Doc (Back is Home), a source. The shell
                // follows it, also when the link is what launched the app.
                guard let link = MobileDeepLink.parse(url) else { return }
                viewModel.pendingDeepLink = link
            }
        }
    }

    private var showsVoiceSurfacePreview: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foreverlm-uitest-voice-surface")
#else
        false
#endif
    }

    /// The XCUITest-only voice-surface preview, kept behind a property so the
    /// reference itself disappears in Release. `showsVoiceSurfacePreview` is
    /// already false there, but Swift type-checks the branch either way, and
    /// `MobileVoiceSurfaceDebugPreview` lives in this file's own `#if DEBUG`
    /// section — so naming it straight from `body` broke the Release build.
    @ViewBuilder
    private var voiceSurfacePreview: some View {
#if DEBUG
        MobileVoiceSurfaceDebugPreview()
#else
        EmptyView()
#endif
    }

    /// The page editor over a fixed page, for a Simulator screenshot without
    /// signing in (`MobilePageEditorHarness`, DEBUG only).
    private var showsPageEditorPreview: Bool {
#if DEBUG
        MobilePageEditorHarness.isEnabled
#else
        false
#endif
    }

    /// Kept behind a property, as `voiceSurfacePreview` is, so Release never
    /// names the DEBUG-only harness.
    @ViewBuilder
    private var pageEditorPreview: some View {
#if DEBUG
        MobilePageEditorHarnessView()
#else
        EmptyView()
#endif
    }

    /// The Space's screens over a sample library made in memory, for a
    /// Simulator screenshot without signing in (`MobileSpaceHarness`, DEBUG
    /// only).
    private var showsSpacePreview: Bool {
#if DEBUG
        MobileSpaceHarness.isEnabled
#else
        false
#endif
    }

    /// Whether a DEBUG preview stands in for the app (`-foreverlm-uitest-*`).
    private var showsPreview: Bool {
        showsVoiceSurfacePreview || showsPageEditorPreview || showsSpacePreview || showsHomePreview || showsAppPreview
    }

    /// The whole app over a sample library, for a Simulator check of every
    /// screen without signing in (`MobileAppHarness`, DEBUG only).
    private var showsAppPreview: Bool {
#if DEBUG
        MobileAppHarness.isEnabled
#else
        false
#endif
    }

    @ViewBuilder
    private var appPreview: some View {
#if DEBUG
        MobileAppHarnessView()
            .environmentObject(viewModel)
            .environment(account)
#else
        EmptyView()
#endif
    }

    /// Home over a sample library, for a Simulator screenshot without signing
    /// in (`MobileHomeHarness`, DEBUG only).
    private var showsHomePreview: Bool {
#if DEBUG
        MobileHomeHarness.isEnabled
#else
        false
#endif
    }

    @ViewBuilder
    private var homePreview: some View {
#if DEBUG
        MobileHomeHarnessView()
            .environmentObject(viewModel)
#else
        EmptyView()
#endif
    }

    @ViewBuilder
    private var spacePreview: some View {
#if DEBUG
        MobileSpaceHarnessView()
            .environmentObject(viewModel)
#else
        EmptyView()
#endif
    }

    /// A dismissed prompt stays suppressed while the account is still empty,
    /// but a key added in Settings (or synced from the Mac) starts a fresh
    /// episode. App activation is the natural event-driven reconciliation
    /// point; no balance polling is needed.
    @MainActor
    private func resetCreditsEmptyEpisodeIfResolved() async {
        guard handledCreditsEmptyEpisode,
              !showsCreditsRequired,
              ManagedAI.hasOwnKey else { return }
        handledCreditsEmptyEpisode = false
        showsCreditsRequired = false
    }
}

private extension View {
    /// Keep system Writing Tools from presenting a second AI editing surface in
    /// ForeverLM while retaining compatibility with the iOS 17 deployment target.
    @ViewBuilder
    func foreverlmWritingToolsDisabled() -> some View {
        if #available(iOS 18.0, *) {
            writingToolsBehavior(.disabled)
        } else {
            self
        }
    }
}

#if DEBUG
/// Visual regression state for the voice conversation's surface. It never
/// starts audio or bypasses identity in Release builds.
private struct MobileVoiceSurfaceDebugPreview: View {
    @State private var isMicrophoneMuted = false
    @State private var isDismissed = false

    var body: some View {
        if showsOrbOnly {
            orbOnly
        } else if isDismissed {
            MobileVoiceTranscriptView(
                transcript: MobileVoiceChatTranscript(
                    messages: [
                        MobileChatMessage(
                            id: UUID(),
                            role: .assistant,
                            content: "What would you like to understand?",
                            isStreaming: false
                        ),
                        MobileChatMessage(
                            id: UUID(),
                            role: .user,
                            content: "Explain attention in transformers.",
                            isStreaming: false
                        ),
                    ]
                )
            )
            .accessibilityElement(children: .contain)
                .accessibilityIdentifier("voice.previewDismissed")
        } else {
            VoiceSessionSurface(
                state: VoiceSessionPresentationState(
                    phase: previewPhase,
                    statusText: previewPhase == .ending ? "Ending…" : "Listening",
                    headerTitle: "Transformers",
                    headerSystemImage: MobileNotebookGlyph.symbolName,
                    contextItems: [
                        VoiceContextItem(
                            id: "paper",
                            title: "Attention Is All You Need",
                            sourceType: "paper"
                        ),
                        VoiceContextItem(
                            id: "podcast",
                            title: "The Gradient Podcast",
                            sourceType: "podcast"
                        ),
                    ],
                    isMicrophoneMuted: isMicrophoneMuted,
                    microphoneLevel: VoiceMicrophoneLevel(initial: isMicrophoneMuted ? 0 : 0.18),
                    terminalErrorMessage: nil,
                    inlineErrorMessage: previewInlineError
                ),
                identifierPrefix: "voice",
                onToggleMute: { isMicrophoneMuted.toggle() },
                onEnd: { isDismissed = true }
            )
        }
    }

    private var previewPhase: VoiceSessionPhase {
        ProcessInfo.processInfo.arguments.contains("-foreverlm-uitest-voice-surface-ending")
            ? .ending
            : .live
    }

    /// The orb, alone, on the surface's own background.
    ///
    /// The palette test measures pixels, and every other thing on the voice
    /// screen is a source of colour it must not count: the source cards carry
    /// per-type tint glyphs at full saturation, and the End button is pure red.
    /// Cropping to the orb's accessibility frame would quietly capture the card
    /// below it and fail the test on a purple thumbnail while the mark was
    /// fine. Giving it a screen with nothing else on it needs no crop and no
    /// coordinate maths.
    private var orbOnly: some View {
        GeometryReader { proxy in
            // As large as the screen allows. The measurement counts stained
            // pixels, so a bigger orb is a stronger signal for the same defect
            // — at the surface's own size the stains are only a few hundred
            // pixels and sit too close to the compositor's own edge noise.
            let width = min(proxy.size.width, proxy.size.height * VoiceOrb.aspectRatio)
            ZStack {
                Color(uiColor: .systemBackground)
                VoiceOrb(activity: .listening, inputLevel: 0.18)
                    .frame(width: width, height: width / VoiceOrb.aspectRatio)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Voice status")
                    .accessibilityIdentifier("voice.status")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    private var showsOrbOnly: Bool {
        ProcessInfo.processInfo.arguments.contains("-foreverlm-uitest-voice-surface-orb-only")
    }

    /// Renders the inline error banner on demand.
    ///
    /// This exists for the test that asserts the banner is *absent* during a
    /// healthy session. That assertion is only worth anything if the same
    /// query can be shown to find the banner when it really is on screen —
    /// otherwise a renamed identifier would make the absence check pass
    /// forever, which is precisely the failure it is meant to catch.
    private var previewInlineError: String? {
        ProcessInfo.processInfo.arguments.contains("-foreverlm-uitest-voice-surface-error")
            ? "The voice connection dropped."
            : nil
    }
}
#endif
