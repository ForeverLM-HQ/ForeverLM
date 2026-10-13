import SwiftUI

#if os(macOS)
import AppKit
import CoreGraphics
import OSLog
#endif

// MARK: - UI Zoom

/// Maps an integer step to a DynamicTypeSize for Cmd+/Cmd- zooming.
enum UIZoom {
    static let defaultStep = 4 // .xxLarge - a more readable app default
    static let minStep = 0
    static let maxStep = 8

    static func size(for step: Int) -> DynamicTypeSize {
        switch min(max(step, minStep), maxStep) {
        case 0: return .small
        case 1: return .medium
        case 2: return .large
        case 3: return .xLarge
        case 4: return .xxLarge
        case 5: return .xxxLarge
        case 6: return .accessibility1
        case 7: return .accessibility2
        case 8: return .accessibility3
        default: return .xxLarge
        }
    }

    static func scale(for step: Int) -> CGFloat {
        switch min(max(step, minStep), maxStep) {
        case 0: return 0.96
        case 1: return 1.00
        case 2: return 1.08
        case 3: return 1.18
        case 4: return 1.30
        case 5: return 1.44
        case 6: return 1.60
        case 7: return 1.78
        case 8: return 1.96
        default: return 1.30
        }
    }

}

/// Chat's own zoom, held as an offset from the app-wide step.
///
/// A trackpad pinch over the transcript is about the conversation, not the whole
/// interface: it moves this offset only, so the Sources column beside chat keeps
/// the size it was given. Storing an offset rather than an absolute step means
/// app zoom (⌘=/⌘-) still carries chat along with everything else, and ⌘0
/// returns both to the default.
///
/// The offset is one per chat panel, kept on the panel's
/// `StudioAssistantSessionStore` rather than in a preference: a pinch over the
/// chat window on one display leaves the chat window on the other alone. It
/// is not persisted — every chat opens at the app-wide size.
enum ChatZoom {

    /// Trackpad magnification is continuous while zoom is stepped. A pinch has
    /// to travel this far before it crosses a step, so small two-finger
    /// movements do not make the transcript flicker between sizes.
    static let magnificationPerStep: CGFloat = 0.08

    static func step(appStep: Int, offset: Int) -> Int {
        min(max(appStep + offset, UIZoom.minStep), UIZoom.maxStep)
    }

    static func size(appStep: Int, offset: Int) -> DynamicTypeSize {
        UIZoom.size(for: step(appStep: appStep, offset: offset))
    }

    static func scale(appStep: Int, offset: Int) -> CGFloat {
        UIZoom.scale(for: step(appStep: appStep, offset: offset))
    }

    /// The offset after moving chat one step, or nil at the end of the range.
    ///
    /// The offset is rewritten from the resolved step rather than incremented,
    /// so it can never drift past the clamped range and leave a pinch back the
    /// other way doing nothing for several steps.
    static func offset(stepping delta: Int, appStep: Int, offset: Int) -> Int? {
        let current = step(appStep: appStep, offset: offset)
        let next = min(max(current + delta, UIZoom.minStep), UIZoom.maxStep)
        guard next != current else { return nil }
        return next - appStep
    }
}

#if os(macOS)
private enum UIZoomKeyboardAction {
    case zoomIn
    case zoomOut
    case reset
}

private extension NSEvent {
    var uiZoomKeyboardAction: UIZoomKeyboardAction? {
        let activeModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard activeModifiers.contains(.command),
              !activeModifiers.contains(.control),
              !activeModifiers.contains(.option) else {
            return nil
        }

        switch charactersIgnoringModifiers {
        case "=", "+":
            return .zoomIn
        case "-":
            return activeModifiers.contains(.shift) ? nil : .zoomOut
        case "0":
            return activeModifiers.contains(.shift) ? nil : .reset
        default:
            return nil
        }
    }
}

private struct UIZoomShortcutMonitor: NSViewRepresentable {
    @Binding var uiZoomStep: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(uiZoomStep: $uiZoomStep)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.uiZoomStep = $uiZoomStep
        context.coordinator.installMonitor()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.uiZoomStep = $uiZoomStep
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var uiZoomStep: Binding<Int>
        private var monitor: Any?
        private var accumulatedChatMagnification: CGFloat = 0
        private weak var chatMagnificationWindow: NSWindow?

        init(uiZoomStep: Binding<Int>) {
            self.uiZoomStep = uiZoomStep
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .magnify, .leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self else { return event }

                // Where the last click landed decides who owns Cmd+F when
                // keyboard focus did not follow it. Observed, never consumed.
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    MainActor.assumeIsolated {
                        ReaderShortcutRouter.shared.noteMouseDown(at: event.locationInWindow, in: event.window)
                        SourceSearchShortcutRouter.shared.noteMouseDown(at: event.locationInWindow, in: event.window)
                    }
                    return event
                }

                if event.type == .magnify {
                    let handled = MainActor.assumeIsolated {
                        self.handleChatMagnification(event)
                    }
                    return handled ? nil : event
                }

                // Cmd+F goes to the focused reader or doc, else to the window's
                // primary reader. Cmd+=/-/0 is routed by focus so neighboring
                // panels retain app UI zoom.
                // nil = not consumed here, true = consumed.
                let readerRouting = MainActor.assumeIsolated { () -> Bool? in
                    let window = event.window ?? NSApp.keyWindow
                    // The sources column claims Cmd+F while keyboard focus sits
                    // inside it; Shift+Cmd+F reaches it from anywhere.
                    if event.isSourcesFindShortcut,
                       let revealSourcesSearch = SourceSearchShortcutRouter.shared.handler(for: window) {
                        revealSourcesSearch()
                        return true
                    }
                    // A click on a reader outranks focus left in the sources
                    // column: Cmd+F (and Ctrl+F) then finds in that reader.
                    if event.isCommandFindShortcut,
                       let find = ReaderShortcutRouter.shared.clickedHandlers(for: window)?.find {
                        find()
                        return true
                    }
                    if event.isReaderFindShortcut, !event.isCommandFindShortcut,
                       let find = ReaderShortcutRouter.shared.clickedControlFindHandler(for: window) {
                        find()
                        return true
                    }
                    if event.isCommandFindShortcut,
                       let revealSourcesSearch = SourceSearchShortcutRouter.shared.focusedHandler(for: window) {
                        revealSourcesSearch()
                        return true
                    }
                    if event.isCommandFindShortcut,
                       let find = ReaderShortcutRouter.shared.findHandler(for: window) {
                        find()
                        return true
                    }
                    if let action = event.uiZoomKeyboardAction {
                        if SourceSearchShortcutRouter.shared.focusedHandler(for: window) != nil {
                            return nil
                        }
                        // A reader owns document zoom only while focus is inside
                        // it. Sidebars and neighboring panels keep app UI zoom
                        // even when a reader happens to be visible in the window,
                        // and so does a focused surface that has no zoom of its
                        // own (a Doc scales with the app).
                        guard let handlers = ReaderShortcutRouter.shared.focusedHandlers(for: window) else {
                            return nil
                        }
                        switch action {
                        case .zoomIn:
                            guard let zoomIn = handlers.zoomIn else { return nil }
                            zoomIn()
                        case .zoomOut:
                            guard let zoomOut = handlers.zoomOut else { return nil }
                            zoomOut()
                        case .reset:
                            guard let resetZoom = handlers.resetZoom else { return nil }
                            resetZoom()
                        }
                        return true
                    }
                    return nil
                }
                if readerRouting == true {
                    return nil
                }

                guard let action = event.uiZoomKeyboardAction else {
                    return event
                }

                switch action {
                case .zoomIn:
                    uiZoomStep.wrappedValue = min(uiZoomStep.wrappedValue + 1, UIZoom.maxStep)
                case .zoomOut:
                    uiZoomStep.wrappedValue = max(uiZoomStep.wrappedValue - 1, UIZoom.minStep)
                case .reset:
                    uiZoomStep.wrappedValue = UIZoom.defaultStep
                    // Reset is the way back from a chat pinched far off the app's
                    // size, so it drops the offsets of this window's chats as
                    // well — this window's, so a chat pinched larger on the
                    // other display keeps its size.
                    MainActor.assumeIsolated {
                        ChatZoomShortcutRouter.shared.resetAll(in: event.window ?? NSApp.keyWindow)
                    }
                }

                return nil
            }
        }

        /// A trackpad pinch over a chat panel moves that panel's own zoom, and
        /// no other chat's. A pinch over a reader is that document's continuous
        /// zoom and its view already handles the event; a pinch anywhere else
        /// is nobody's and passes through untouched, so the interface beside
        /// chat never scales.
        @MainActor
        private func handleChatMagnification(_ event: NSEvent) -> Bool {
            guard let window = event.window ?? NSApp.keyWindow else {
                resetChatMagnificationTracking()
                return false
            }
            // `locationInWindow` is undefined for gesture events. Use the live
            // pointer, which is what the readers route by too.
            let windowPoint = window.gesturePointerLocation

            guard ReaderShortcutRouter.shared.handlers(at: windowPoint, in: window) == nil,
                  let chat = ChatZoomShortcutRouter.shared.handlers(at: windowPoint, in: window) else {
                resetChatMagnificationTracking()
                return false
            }

            if event.phase.contains(.began) || chatMagnificationWindow !== window {
                resetChatMagnificationTracking()
            }
            chatMagnificationWindow = window
            accumulatedChatMagnification += event.magnification

            while accumulatedChatMagnification >= ChatZoom.magnificationPerStep {
                guard chat.step(1) else {
                    accumulatedChatMagnification = 0
                    break
                }
                accumulatedChatMagnification -= ChatZoom.magnificationPerStep
            }

            while accumulatedChatMagnification <= -ChatZoom.magnificationPerStep {
                guard chat.step(-1) else {
                    accumulatedChatMagnification = 0
                    break
                }
                accumulatedChatMagnification += ChatZoom.magnificationPerStep
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                resetChatMagnificationTracking()
            }
            return true
        }

        private func resetChatMagnificationTracking() {
            accumulatedChatMagnification = 0
            chatMagnificationWindow = nil
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
#endif

private struct UIZoomScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = UIZoom.scale(for: UIZoom.defaultStep)
}

extension EnvironmentValues {
    var uiZoomScale: CGFloat {
        get { self[UIZoomScaleKey.self] }
        set { self[UIZoomScaleKey.self] = newValue }
    }
}

private extension View {
    func appUIZoom(step: Binding<Int>) -> some View {
        modifier(AppUIZoomModifier(step: step))
    }
}

extension View {
    func zoomedSystemFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(UIZoomedSystemFontModifier(size: size, weight: weight, design: design))
    }
}

private struct UIZoomedSystemFontModifier: ViewModifier {
    @Environment(\.uiZoomScale) private var uiZoomScale

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * uiZoomScale, weight: weight, design: design))
    }
}

private struct AppUIZoomModifier: ViewModifier {
    @Binding var step: Int

    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(UIZoom.size(for: step))
            .environment(\.uiZoomScale, UIZoom.scale(for: step))
            #if os(macOS)
            .background {
                UIZoomShortcutMonitor(uiZoomStep: $step)
                    .frame(width: 0, height: 0)
            }
            #endif
    }
}

#if os(macOS)
/// The app icon for in-app use (Settings header, sign-in wall).
///
/// Resolved and decoded once at launch, while the bundle on disk is guaranteed intact.
/// `NSApp.applicationIconImage` re-reads the bundle lazily, so a Clean Build Folder while
/// the app stays open deletes the icon files out from under the running process and every
/// later lookup degrades to the generic blank-document icon.
@MainActor
enum AppIconImage {
    static let shared: NSImage = {
        // The annotation is load-bearing: `applicationIconImage` is null_resettable, so it
        // imports as `NSImage!` and `??` infers an optional result without it.
        let icon: NSImage = NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage
        // Snapshot into an independent bitmap; NSImage keeps file-backed reps lazy,
        // so without this the pixels are still read from disk at first draw.
        var rect = NSRect(x: 0, y: 0, width: 256, height: 256)
        guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return icon
        }
        let snapshot = NSImage(cgImage: cgImage, size: NSSize(width: 256, height: 256))
        guard ForeverLMRuntimeIdentity.isDevelopment else { return snapshot }

        let badged = NSImage(size: snapshot.size)
        badged.lockFocus()
        snapshot.draw(in: NSRect(origin: .zero, size: snapshot.size))
        let badgeRect = NSRect(x: 132, y: 12, width: 112, height: 54)
        // Green "NEW" for the First Run app, so the Dock never leaves you
        // guessing which of the two Dev apps is the stranger's first launch.
        let isFirstRun = ForeverLMRuntimeIdentity.isFirstRun
        (isFirstRun ? NSColor.systemGreen : NSColor.systemOrange).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 14, yRadius: 14).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 29, weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        let label = NSString(string: isFirstRun ? "NEW" : "DEV")
        let labelSize = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: badgeRect.midX - labelSize.width / 2, y: 22),
            withAttributes: attributes
        )
        badged.unlockFocus()
        NSApplication.shared.applicationIconImage = badged
        return badged
    }()
}
#endif

@main
struct ForeverLMApp: App {
    #if os(macOS) && FOREVERLM_FIRST_RUN
    // First on purpose: stored properties initialize in declaration order, and
    // the ones below open the library and read the keychain it may clear.
    private let firstRunFreshStart: Void = FirstRunFreshStart.prepareIfRequested()
    #endif
    #if os(macOS)
    @NSApplicationDelegateAdaptor(ForeverLMApplicationDelegate.self) private var applicationDelegate
    #endif
    @State private var studioViewModel = StudioViewModel(
        storageService: StorageService(),
        usesStudioWindowRegistry: true,
        // The notebook last worked in on this Mac, which a new window opens
        // in: this app's own defaults, never synced. A UI test run starts
        // from none, on the Space.
        notebookRecencyDefaults: UITestConfiguration.isUITesting ? nil : .standard
    )
    /// One account model for the whole app: the launch gate, the Settings card, and any
    /// future surface all read the same sign-in state, so signing out in Settings re-walls
    /// the app immediately instead of leaving a stale unlocked window behind.
    @State private var managedAIAccount = ManagedAIAccountModel()
    @SyncedStorage("uiZoomStep") private var uiZoomStep = UIZoom.defaultStep
    @SyncedStorage("studio.assistantIntegrationsEnabled") private var assistantIntegrationsEnabled = true
    /// Observed so the Canvas and Atlas menu items come and go with the beta
    /// sign-up (`BetaFeatures`).
    @SyncedStorage(wrappedValue: false, BetaReleases.preferenceKey) private var signedUpForBetas: Bool
    private var showsCanvas: Bool { BetaFeatures.showsCanvas(signedUpForBetas: signedUpForBetas) }
    @Environment(\.scenePhase) private var scenePhase
    private let appUpdateController = AppUpdateController()

    private var activeWindowState: StudioWindowState? {
        StudioWindowRegistry.shared.activeState
    }

    /// The notebook the key Studio window holds, for the Notebook menu.
    private var activeWindowNotebook: NotebookWorkspace? {
        activeWindowState?.notebook
    }


    /// Whether the key Studio window shows a canvas, whose menu then owns
    /// ⌥⌘S as Save Version (docs/knowledge-map-design.md, "Versions, export
    /// and publishing"): the Sources toggles give it up while it shows.
    private var activeWindowShowsCanvas: Bool {
        guard showsCanvas, let state = activeWindowState else { return false }
        return studioViewModel.visibleCenterTabs(in: state).contains(.knowledgeMap)
    }

    /// Extend Map to Other Display needs a second display and the Map
    /// showing in the key Studio window.
    private var canExtendMapToOtherDisplay: Bool {
        guard KnowledgeMapDisplayExtension.shared.displayCount > 1, let state = activeWindowState else { return false }
        return studioViewModel.visibleCenterTabs(in: state).contains(.knowledgeMap)
    }

    private func postToActiveStudioWindow(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: activeWindowState?.id)
    }

    /// The Today menu reads the day for its titles and enabled states.
    private var day: DayModel { DayModel.shared }

    init() {
        #if os(macOS)
        StudioViewModel.exitIfBrowserReadingListWorkerRequested()
        UIResponsivenessMonitor.shared.start()
        // Before any scene body runs, so the first window to register can adopt
        // the arrangement the last session left behind.
        StudioWorkspaceWindowCoordinator.shared.armLastSessionRestore()
        _ = AppIconImage.shared
        // Under generation 2 a narration lives in a working folder of its own and the replica, not in iCloud
        // Drive; set before anything reads or writes narration. Generation 1 keeps iCloud Drive.
        MacNarrationLibrary.install()
        #endif
        #if DEBUG
        // Warns when a synced preference is written straight to UserDefaults,
        // bypassing PreferenceStore — such a write never reaches the sync rail.
        PreferenceStore.startBypassAudit()
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "studio") {
            StudioWindowRoot()
                .environment(studioViewModel)
                .environment(studioViewModel.articlesStore)
                .environment(studioViewModel.readingProgressStore)
                .environment(managedAIAccount)
                .environmentObject(appUpdateController)
                .environmentObject(CloudKitSyncStatusCenter.shared)
                .appUIZoom(step: $uiZoomStep)
                .preferredColorScheme(UITestConfiguration.isUITesting ? .dark : nil)
                .textSelection(.enabled)
                .foreverlmWritingToolsDisabled()
                .task {
                    // Under generation 2 a store's one-time activation runs first, before the MCP server,
                    // the relay and the background writers (docs/cloudkit-schema-design.md §13.3 step 3).
                    // Once per process; nothing under generation 1.
                    await GenerationActivationLauncher.runAtLaunch(storage: studioViewModel.storage)
                }
                .task {
                    #if os(macOS)
                    // The Settings-parity MCP tools reach the few pane actions
                    // that are view-model methods through this.
                    AppModelBridge.studio = studioViewModel
                    AppModelBridge.account = managedAIAccount
                    #endif
                    StorageService.scheduleLegacyContentConsolidationAfterLaunch()
                    // Same shape, one level down: book folders that still carry a
                    // download site's tag in their name are renamed, and the rows
                    // that name them rewritten, once. Files, so not a migration.
                    StorageService.scheduleBookFolderAdoptionAfterLaunch(storage: studioViewModel.storage)
                    // Preferences synced from another Mac land in knowledge.db, not
                    // UserDefaults, so they have to be pushed across once per launch.
                    // Not a migration — a read of a handful of short rows, done after
                    // first render and off the main actor (StorageService is an actor),
                    // then applied to the view model on main.
                    await PreferenceStore.hydrateFromStore()
                    // The retired question calibration's last rule, cleared
                    // once so older clients stop appending it to their prompts.
                    await RetiredQuestionCalibration.clearOnce(storage: studioViewModel.storage)
                    #if os(macOS)
                    MacAccountUser.seedSyncedDisplayNameIfNeeded()
                    #endif
                    studioViewModel.reloadSyncedPreferences()
                    // Only now: the one-time integration-tab unpin reads and
                    // writes the same preferences hydration just restored, and
                    // running it first wrote a fresh container's default over
                    // the learner's stored pin choices.
                    studioViewModel.applyIntegrationTabUnpinDefaults()
                    // Warm the second preference domain before anything reads a
                    // defaults-write hatch. Small local file, but several of those
                    // keys are read from main-actor derived state.
                    await Task.detached(priority: .utility) {
                        DefaultsEscapeHatch.prime()
                    }.value
                }
                .task {
                    // Remote list prices (OpenRouter's directory) so cost
                    // estimates and price labels are current from first use.
                    // The cached table is a tiny UserDefaults decode; the
                    // refresher keeps it off the main actor and
                    // fetches at most one snapshot per five minutes.
                    //
                    // This has to happen at launch rather than when a picker
                    // opens: background work records most of the ledger, and
                    // an unloaded table stamps those rows with no cost at all.
                    AIModelPriceRefresher.refreshIfStale()
                }
                .task {
                    // A model is put to work only once it passed a test run of
                    // that work (AIModelQualification). Ask again about the
                    // few models the settings use when their verdict is due,
                    // after launch has settled; nothing when this Mac cannot
                    // spend.
                    guard !UITestConfiguration.isUITesting else { return }
                    try? await Task.sleep(for: .seconds(30))
                    await Task.detached(priority: .utility) {
                        await AIModelQualification.sweepInUse()
                    }.value
                }
                .task {
                    // Remove credentials from retired client-side AI routes,
                    // former direct-Meta trial flags and the retired Ramp
                    // Router key. Keychain I/O stays off-main.
                    await Task.detached(priority: .utility) {
                        KeychainService.purgeRetiredProviderData()
                        // And the models background tasks had of their own.
                        KeychainService.purgeRetiredTaskModels()
                        // And the retired Google Calendar plugin's grants.
                        KeychainService.purgeRetiredGoogleCalendarGrants()
                        // And the Planner's choice of Mac calendars, made
                        // beside that plugin, which hid the day without it.
                        AppleCalendarService.retirePlannerCalendarChoice()
                        // And the preference keys nothing reads, the stale
                        // type-named window frames most of all: every defaults
                        // write made the next read diff them again.
                        RetiredDefaultsCleanup.runAtLaunch()
                    }.value
                }
                .task {
                    // One-time retirement cleanup for reminders registered by
                    // older builds. The helper no-ops after its first run.
                    NotificationRetirement.cancelAll()
                    // Strictly after the sweep, which clears every pending
                    // request: the bout's alarms are the one scheduled channel
                    // that survived the retirement, and a sweep running after
                    // them would silently cancel a running bout's timer.
                    LearningBoutAlarms.shared.start()
                }
                .task {
                    // Donate sources to Spotlight's semantic index so the new Siri
                    // can resolve them by meaning. Runs off-main after launch.
                    if #available(macOS 15.0, *) {
                        SiriSpotlightDonationCoordinator.shared.start()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Resume the verified one-time drain of historical iCloud
                    // content whenever the app comes forward. A completed install
                    // does only a root-level presence check; CloudDocs resurrecting
                    // an old fork re-arms the same idempotent worker.
                    if phase == .active {
                        StorageService.scheduleLegacyContentConsolidation()
                        // App activation is the primary recovery event for an MCP
                        // launch that previously reached a terminal auth or
                        // configuration error. The launcher no-ops while connected
                        // or already reconnecting.
                        if !UITestConfiguration.isUITesting,
                           AssistantIntegrationSettings.isEnabled,
                           managedAIAccount.hasAccountAccess {
                            Task {
                                await MCPRuntimeCoordinator.startPreferredRuntime()
                            }
                        }
                        // The free days' notices, two days before the end and on
                        // the last day, each once.
                        FreeDaysNotices.showIfDue(account: managedAIAccount, vm: studioViewModel)
                        // App activation is the review's event: it reads
                        // today's cards again and re-asserts the one daily
                        // notification, which the one-time retirement sweep would
                        // otherwise remove if the two ever ran in the wrong order.
                        // Two reads of every kept card and its answers, for a
                        // count in the Memory row's help: at .utility, so no
                        // click waits behind them on the storage actor.
                        Task(priority: .utility) {
                            await studioViewModel.refreshMemoryCardState()
                        }
                        Task(priority: .utility) {
                            await studioViewModel.runDeferredSourceSyncRepair()
                            await studioViewModel.runDeferredSourceTextReferenceRepair()
                            await studioViewModel.runDeferredStoredSoftHyphenRepair()
                            await studioViewModel.runDeferredPaperFigureMarkdownRepair()
                            await studioViewModel.runDeferredSourceWordCountRepair()
                            await studioViewModel.runDeferredPaperFigureImageSweep()
                            await studioViewModel.runCanonicalContentCleanup()
                            studioViewModel.kickSourceEmbeddingIndexing()
                        }
                    }
                }
                .task {
                    // MCP follows its own enable toggle, and stops while the app is
                    // locked (the free days over, nothing paid): the gate is in
                    // `MCPServerLauncher.startHostedTunnel`, and the lock's change
                    // below stops or restarts the connection. Tool calls that reach
                    // this Mac directly are refused while locked by
                    // `MCPProtocolHandler.appLockRefusal`; the hosted gateway refuses
                    // its own. Non-blocking: errors are shown in Settings -> MCP,
                    // not here.
                    //
                    // The tunnel is provisioned under the Apple user id, which only
                    // sign-in writes. On a first launch the window is up before the
                    // account wall clears, so starting here would fail with "your
                    // Apple account isn't linked" and stay failed while the app
                    // remained active. Signed out, the start waits for the
                    // hasAccountAccess change below instead.
                    if !UITestConfiguration.isUITesting,
                       AssistantIntegrationSettings.isEnabled,
                       managedAIAccount.hasAccountAccess {
                        await MCPRuntimeCoordinator.startPreferredRuntime()
                    }
                }
                .onChange(of: assistantIntegrationsEnabled) { _, enabled in
                    Task {
                        if enabled {
                            guard managedAIAccount.hasAccountAccess else { return }
                            await MCPRuntimeCoordinator.startPreferredRuntime()
                        } else {
                            await MCPRuntimeCoordinator.stopAll()
                        }
                    }
                }
                .onChange(of: managedAIAccount.isAppLocked) { _, locked in
                    // The pay screen is up: background AI, sync and the MCP
                    // connection stop (docs/pricing-pro-design.md → Day 8). Paying
                    // brings them back exactly as they were.
                    guard !UITestConfiguration.isUITesting else { return }
                    Task {
                        if locked {
                            await MCPRuntimeCoordinator.stopAll()
                        } else {
                            if AssistantIntegrationSettings.isEnabled, managedAIAccount.hasAccountAccess {
                                await MCPRuntimeCoordinator.startPreferredRuntime()
                            }
                            await MacSyncSession.current?.syncNow()
                        }
                    }
                }
                .onChange(of: managedAIAccount.freeDaysLeft) { _, _ in
                    FreeDaysNotices.showIfDue(account: managedAIAccount, vm: studioViewModel)
                }
                .onChange(of: managedAIAccount.hasAccountAccess) { _, hasAccess in
                    guard !UITestConfiguration.isUITesting,
                          AssistantIntegrationSettings.isEnabled else { return }
                    Task {
                        if hasAccess {
                            // Sign-in (or the stored session loading) just stored the
                            // Apple user id, so the tunnel can be provisioned now.
                            await MCPRuntimeCoordinator.startPreferredRuntime()
                        } else if KeychainService.appleUserID == nil {
                            // Signed out: the tunnel bills whoever provisioned it, so
                            // it does not stay up for the person who just left. A
                            // lapsed session keeps its Apple user id and its tunnel.
                            await MCPRuntimeCoordinator.stopAll()
                        }
                    }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(
                        name: .requestOpenStudioSettings,
                        object: nil
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // AppKit's About window, which says Beta while this build is one
            // (`RunningBuildChannel`).
            CommandGroup(replacing: .appInfo) {
                Button("About \(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ForeverLM")") {
                    AboutPanel.show()
                }
            }

            CommandGroup(after: .appInfo) {
                #if DIRECT_DOWNLOAD
                CheckForUpdatesView(updateController: appUpdateController)
                #endif
                Button("What's New in ForeverLM…") {
                    postToActiveStudioWindow(.showWhatsNew)
                }
                Button("Set Up ForeverLM…") {
                    postToActiveStudioWindow(.showGettingStarted)
                }
                ThirdPartyLicensesMenuItem()
                ScreenRecordModeMenuItem()
            }

            CommandGroup(after: .toolbar) {
                Button(activeWindowState?.drawsNavigationRail == false ? "Show Navigation Sidebar" : "Hide Navigation Sidebar") {
                    guard let state = activeWindowState else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        // As the sidebar toggle does: Home's sidebar and the
                        // Space's fold together, never the icon strip, and a
                        // sidebar stepping aside for a memory review comes
                        // back on asking.
                        let shown = !state.drawsNavigationRail
                        state.setNavigationRailShown(shown)
                        UserDefaults.standard.set(!shown, forKey: "space.sidebarHidden")
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])

                Button("Open Chat") {
                    postToActiveStudioWindow(.toggleStudioAssistant)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Open Reader") {
                    postToActiveStudioWindow(.openStudioReader)
                }
                .keyboardShortcut("r", modifiers: .command)

                // The Space and the full-window Library, by shortcut as well
                // as from the rail. Nothing in the app saves or prints, so ⌘P
                // is free for the Space (where every notebook is listed); ⇧⌘L
                // is the Library's.
                ForEach(StudioShellCommand.allCases, id: \.self) { command in
                    Button(command.title) {
                        switch command {
                        case .space: postToActiveStudioWindow(.openStudioSpace)
                        case .library: postToActiveStudioWindow(.openStudioLibrary)
                        }
                    }
                    .keyboardShortcut(command.key, modifiers: command.modifiers)
                }

                // Plugins, the strip's row under the Library, in the key
                // window (docs/codex-shell-plan.md, Track 2).
                Button("Plugins") {
                    guard let state = activeWindowState else { return }
                    studioViewModel.openPluginsPlace(nil, in: state)
                }

                // The Atlas (docs/atlas-design.md): a topic laid out as
                // concepts at levels of abstraction, in the key window. A beta
                // feature with the Canvas (`BetaFeatures`).
                if showsCanvas {
                    Button("Atlas") {
                        guard let state = activeWindowState else { return }
                        studioViewModel.inWindow(state) { studioViewModel.openAtlasPane(in: state) }
                    }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                }

                // Today's page in Docs, in the key window, as the rail's
                // Daily Notes row opens it (docs/notes-graph-design.md). ⌘D
                // plans the day in a chat; ⇧⌘D writes in it.
                Button("Daily Notes") {
                    guard let state = activeWindowState else { return }
                    Task { await studioViewModel.openDailyNote(in: state) }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                // While the key window shows a canvas, ⌥⌘S saves a version of
                // it (Heptabase's shortcut), here and nowhere else; the
                // Notebook menu's Sources item takes ⌥⌘S in a notebook.
                if activeWindowShowsCanvas {
                    Button("Save Canvas Version…") {
                        studioViewModel.promptSaveCanvasVersion(canvasID: studioViewModel.knowledgeMap.mapID)
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                }

                Divider()

                // The Map going on across a second display
                // (docs/knowledge-map-design.md, "Extending to another display").
                // Kept while an extension is running, so it can always be stopped.
                if showsCanvas || KnowledgeMapDisplayExtension.shared.isActive {
                    Button(KnowledgeMapDisplayExtension.shared.isActive ? "Stop Extending Canvas" : "Extend Canvas to Other Display") {
                        if KnowledgeMapDisplayExtension.shared.isActive {
                            KnowledgeMapDisplayExtension.shared.stop()
                        } else {
                            postToActiveStudioWindow(.extendKnowledgeMapToOtherDisplay)
                        }
                    }
                    .disabled(!KnowledgeMapDisplayExtension.shared.isActive && !canExtendMapToOtherDisplay)

                    Divider()
                }

                // Saved window arrangements. The product owner asked on 2026-09-25 for
                // them here rather than behind a dedicated titlebar button.
                Menu("Workspaces") {
                    Button("Save Current Workspace…") {
                        postToActiveStudioWindow(.saveStudioWorkspace)
                    }

                    let savedWorkspaces = StudioWorkspaceViewStore.shared.views
                    if !savedWorkspaces.isEmpty {
                        Divider()
                        ForEach(savedWorkspaces) { savedView in
                            Button(savedView.name) {
                                NotificationCenter.default.post(
                                    name: .applyStudioWorkspace,
                                    object: activeWindowState?.id,
                                    userInfo: [StudioWorkspaceMenuCommand.workspaceIDKey: savedView.id]
                                )
                            }
                        }
                        Divider()
                        Button("Manage Workspaces…") {
                            postToActiveStudioWindow(.manageStudioWorkspaces)
                        }
                    }
                }

                Divider()

                Button("Zoom In") {
                    uiZoomStep = min(uiZoomStep + 1, UIZoom.maxStep)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    uiZoomStep = max(uiZoomStep - 1, UIZoom.minStep)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Zoom") {
                    uiZoomStep = UIZoom.defaultStep
                    // The chats of the front window come back with it; a chat
                    // pinched larger in a window on the other display stays.
                    ChatZoomShortcutRouter.shared.resetAll(in: NSApp.keyWindow)
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            // The notebook the key window holds (docs/notebooks-design.md, "The
            // notebook workspace"). Every column toggle has a menu item, as
            // ui-design principle 5 asks, and every Studio tile has one under
            // Make; with no notebook open only Add Sources… shows, disabled,
            // and ⌥⌘S stays the View menu's.
            CommandMenu("Notebook") {
                Button("Add Sources…") {
                    postToActiveStudioWindow(.showNotebookAddSources)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(activeWindowNotebook == nil)

                // ⌥⌘S belongs to whichever Sources the key window shows: the
                // View menu's library list, or this column — never both — and
                // to Save Version while a canvas shows.
                if let notebook = activeWindowNotebook, let state = activeWindowState {
                    Button(notebook.sourcesCollapsed ? "Show Sources" : "Hide Sources") {
                        guard state.notebook != nil else { return }
                        withAnimation(.easeInOut(duration: 0.22)) {
                            state.notebook?.sourcesCollapsed.toggle()
                        }
                    }
                    // A canvas on show takes ⌥⌘S for Save Version (the View menu's).
                    .keyboardShortcut(activeWindowShowsCanvas ? nil : KeyboardShortcut("s", modifiers: [.command, .option]))

                    Divider()

                    Button(notebook.studioCollapsed ? "Show Studio" : "Hide Studio") {
                        guard state.notebook != nil else { return }
                        withAnimation(.easeInOut(duration: 0.22)) {
                            state.notebook?.studioCollapsed.toggle()
                        }
                    }

                    Divider()

                    Menu("Make") {
                        NotebookMakeMenuItems(vm: studioViewModel, windowState: state, notebookID: notebook.notebookID)
                    }

                    Button("New Note") {
                        let notebookID = notebook.notebookID
                        Task { await studioViewModel.makeNotebookNote(notebookID: notebookID, in: state) }
                    }
                    .disabled(!studioViewModel.notebookTakesMadeThings(notebook.notebookID))

                    // The notebook's sources laid out as concepts at levels
                    // (docs/atlas-design.md); the Atlas leaves the notebook
                    // as the Canvas does. A beta feature (`BetaFeatures`).
                    if showsCanvas {
                        Button("Atlas of This Notebook") {
                            let notebookID = notebook.notebookID
                            studioViewModel.inWindow(state) {
                                studioViewModel.openAtlas(topic: nil, itemRefs: [], notebookID: notebookID)
                            }
                        }
                    }

                    Divider()

                    Button("Rename Notebook…") {
                        postToActiveStudioWindow(.renameNotebook)
                    }
                    .disabled(studioViewModel.notebook(id: notebook.notebookID).map(studioViewModel.isNotebookReadOnly) ?? true)

                    Button("Close Notebook") {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            studioViewModel.showSpaceAll(in: state)
                        }
                    }
                }
            }

            // The day's own menu, beside View (product owner, 2026-09-09). Since the
            // Planner went on 2026-09-30 the day is the Mac's Calendar: the
            // menu plans it in a chat that writes events there, opens the
            // Calendar app, runs the bout timer, opens Activity and starts
            // the review. Since 2026-10-06 the rail's Now chip shows only
            // while something is happening, so this menu is where the day's
            // ways on always are.
            CommandMenu("Today") {
                Button("Plan the Day in Chat") {
                    postToActiveStudioWindow(.requestPlanTheDayChat)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Open Calendar") {
                    AppleCalendarService.openCalendarApp()
                }

                // What the chip's popover offered while the calendar was off
                // or refused by macOS: the Calendar pane, which says which.
                if !day.isCalendarOn {
                    Button("Turn On Calendar…") {
                        PluginsPlace.requestOpen(.appleCalendar)
                    }
                }

                // The day's record, in the key window, as the Now chip's
                // popover opens it.
                Button("Day") {
                    guard let state = activeWindowState else { return }
                    studioViewModel.inWindow(state) { studioViewModel.openActivityInReader() }
                }

                Divider()

                // The timer, from the menu bar so a bout can be started and
                // written up from wherever the learner is reading.
                if day.liveBout == nil {
                    Button("Start Pomodoro Timer…") {
                        DayModel.shared.requestStart()
                    }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                } else {
                    Button("Write Up the Bout…") {
                        DayModel.shared.requestWriteUp()
                    }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(day.liveBout?.writtenAt != nil)
                    Button("Stop the Clock") {
                        guard let bout = DayModel.shared.liveBout else { return }
                        Task { _ = try? await DayModel.shared.endBout(bout.id) }
                    }
                    .disabled(!day.isBoutRunning)
                }

                Divider()

                // The Memory pane, whose Start Review is the way into the
                // review: a menu item is one click, like the rail's row.
                Button("Today's Review…") {
                    postToActiveStudioWindow(.requestMemoryReview)
                }
            }
        }

        #if os(macOS)
        WindowGroup("Source Reader", id: "source-reader", for: String.self) { $articleId in
            if let articleId, let article = studioViewModel.articles.first(where: { $0.id == articleId }) {
                // Reader components share the same environment contract as
                // docked readers. The pop-out never mutates side panels, but
                // receives the active workspace for read-only layout policy,
                // and that workspace's Sources panel state with it.
                let workspace = StudioWindowRegistry.shared.activeState ?? StudioWindowState()
                SourceReaderWindow(article: article)
                    // No Studio window: a chat request made here lands in the
                    // Studio window used last, and the router says so.
                    .background(StudioWindowKeyAttachment.detachedWindow)
                    .environment(studioViewModel)
                    .environment(workspace)
                    .environment(managedAIAccount)
                    .environment(studioViewModel.articlesStore)
                    .environment(workspace.sidebarStore)
                    .environment(studioViewModel.readingProgressStore)
                    .appUIZoom(step: $uiZoomStep)
                    .textSelection(.enabled)
                    .foreverlmWritingToolsDisabled()
            } else {
                ContentUnavailableView("Source Not Found", systemImage: "doc.questionmark")
                    .appUIZoom(step: $uiZoomStep)
                    .foreverlmWritingToolsDisabled()
            }
        }
        .defaultSize(width: 800, height: 600)
        // This scene is opened only from a concrete source/Reader action. It is
        // presentation, not a creatable document, so it must not contribute a
        // "New Source Reader Window" item to File > New.
        .commandsRemoved()

        Window("Third-Party Licenses", id: "third-party-licenses") {
            ThirdPartyLicensesWindowView()
                .foreverlmWritingToolsDisabled()
        }
        .defaultSize(width: 640, height: 720)

        #endif
    }
}

#if os(macOS)
/// One instance is created for every member of the main `WindowGroup`. The
/// shared environment is supplied by `ForeverLMApp`; only workspace presentation
/// — including the window's own Sources panel state — is scene-local and
/// restored independently by SwiftUI.
private struct StudioWindowRoot: View {
    @State private var windowState = StudioWindowState()
    @SceneStorage("studio.window.workspace.v1") private var encodedSnapshot = ""
    @State private var hasRestoredSnapshot = false
    /// The beta sign-up (`BetaFeatures`): when it turns off, here, from MCP or
    /// on another Mac, a Canvas or Atlas pane on screen leaves the window.
    @SyncedStorage(wrappedValue: false, BetaReleases.preferenceKey) private var signedUpForBetas: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(StudioViewModel.self) private var vm

    /// A scene with no snapshot of its own is a brand-new window: it opens in
    /// the notebook last worked in, or on the Space (decisions v5, 1). A
    /// restored scene comes back as it was, its notebook included.
    private var opensNewWindow: (@MainActor (StudioWindowState) -> Void)? {
        guard encodedSnapshot.isEmpty else { return nil }
        let vm = vm
        return { state in vm.openNotebookOrSpaceInNewWindow(state) }
    }

    var body: some View {
        let persistenceRevision = windowState.persistenceRevision
        ContentView()
            .environment(windowState)
            .environment(windowState.sidebarStore)
            .background(StudioWindowRegistryAttachment(state: windowState, opensNewWindow: opensNewWindow))
            .task {
                guard !hasRestoredSnapshot else { return }
                if !windowState.workspaceRestoreOverridesSceneSnapshot {
                    windowState.restore(from: encodedSnapshot)
                }
                hasRestoredSnapshot = true
                // Put back the rest of the windows the last session had. The
                // coordinator does this once per launch, on a task of its own,
                // so every window reaching here does not repeat it and closing
                // this window while it waits for restoration does not lose it.
                StudioWorkspaceWindowCoordinator.shared.reopenLastSessionWindowsIfNeeded {
                    openWindow(id: "studio")
                }
            }
            .onChange(of: persistenceRevision) { _, _ in
                guard hasRestoredSnapshot else { return }
                encodedSnapshot = windowState.encodedSnapshot()
            }
            .onChange(of: signedUpForBetas) { _, _ in
                windowState.closeUnofferedPanes()
            }
    }
}

/// Owns only AppKit presentation handles. Durable workspace data stays in the
/// shared plist-backed model; this adapter captures and reapplies real window
/// frames without putting `NSWindow` into synced or observable state.
struct StudioDisplayDescriptor: Equatable {
    var uuid: String?
    var id: String?
    var name: String
    var index: Int
}

/// Resolves a saved display against the screens connected now. A persistent
/// CoreGraphics UUID is authoritative. Legacy records fall back to the current
/// display number, then their spatial index before a product name: two matching
/// monitors commonly publish the same name, so "first screen with this name"
/// is not identity and can put both saved windows on one display.
enum StudioWorkspaceDisplayResolver {
    static func index(
        for placement: StudioWindowPlacement,
        among displays: [StudioDisplayDescriptor]
    ) -> Int? {
        guard !displays.isEmpty else { return nil }
        if let uuid = placement.displayUUID,
           let match = displays.firstIndex(where: { $0.uuid == uuid }) {
            return match
        }
        if let id = placement.displayID,
           let match = displays.firstIndex(where: { $0.id == id }) {
            return match
        }

        if displays.indices.contains(placement.displayIndex) {
            let indexed = displays[placement.displayIndex]
            if placement.displayName == nil || indexed.name == placement.displayName {
                return placement.displayIndex
            }
        }

        if let name = placement.displayName {
            let nameMatches = displays.indices.filter { displays[$0].name == name }
            if nameMatches.count == 1 { return nameMatches[0] }
            if let nearest = nameMatches.min(by: {
                abs(displays[$0].index - placement.displayIndex)
                    < abs(displays[$1].index - placement.displayIndex)
            }) {
                return nearest
            }
        }

        return min(max(placement.displayIndex, 0), displays.count - 1)
    }
}

/// Pairs live windows with saved windows before applying either state or frame.
/// Reusing a window already on the target display avoids an unnecessary
/// cross-display swap, which AppKit cannot reliably perform for zoomed or
/// transitioning windows. The menu-invoking window is only a final fallback
/// when no saved display identity matches.
enum StudioWorkspaceWindowMatcher {
    static func assignments(
        saved: [StudioWindowPlacement?],
        existing: [StudioWindowPlacement?],
        preferredExistingIndex: Int?
    ) -> [Int?] {
        var result = Array<Int?>(repeating: nil, count: saved.count)
        var unmatchedExisting = Set(existing.indices)

        func distance(_ lhs: StudioWindowPlacement, _ rhs: StudioWindowPlacement) -> Double {
            abs(lhs.normalizedX - rhs.normalizedX)
                + abs(lhs.normalizedY - rhs.normalizedY)
                + abs(lhs.normalizedWidth - rhs.normalizedWidth)
                + abs(lhs.normalizedHeight - rhs.normalizedHeight)
        }

        func assignMatches(
            _ matches: (StudioWindowPlacement, StudioWindowPlacement) -> Bool
        ) {
            for savedIndex in saved.indices where result[savedIndex] == nil {
                guard let target = saved[savedIndex] else { continue }
                let candidates = unmatchedExisting.filter { existingIndex in
                    guard let current = existing[existingIndex] else { return false }
                    return matches(target, current)
                }
                guard let chosen = candidates.min(by: { lhs, rhs in
                    guard let left = existing[lhs], let right = existing[rhs] else {
                        return lhs < rhs
                    }
                    let leftDistance = distance(target, left)
                    let rightDistance = distance(target, right)
                    if leftDistance == rightDistance {
                        if lhs == preferredExistingIndex { return true }
                        if rhs == preferredExistingIndex { return false }
                        return lhs < rhs
                    }
                    return leftDistance < rightDistance
                }) else { continue }
                result[savedIndex] = chosen
                unmatchedExisting.remove(chosen)
            }
        }

        assignMatches { target, current in
            target.displayUUID != nil && target.displayUUID == current.displayUUID
        }
        assignMatches { target, current in
            target.displayID != nil && target.displayID == current.displayID
        }
        assignMatches { target, current in
            target.displayName != nil
                && target.displayName == current.displayName
                && target.displayIndex == current.displayIndex
        }
        assignMatches { target, current in
            target.displayIndex == current.displayIndex
        }

        // A product name is safe only when exactly one unmatched live window
        // carries it. Identical monitors must fall through to spatial order.
        for savedIndex in saved.indices where result[savedIndex] == nil {
            guard let name = saved[savedIndex]?.displayName else { continue }
            let candidates = unmatchedExisting.filter { existing[$0]?.displayName == name }
            guard candidates.count == 1, let chosen = candidates.first else { continue }
            result[savedIndex] = chosen
            unmatchedExisting.remove(chosen)
        }

        if let preferredExistingIndex,
           unmatchedExisting.contains(preferredExistingIndex),
           let savedIndex = result.firstIndex(where: { $0 == nil }) {
            result[savedIndex] = preferredExistingIndex
            unmatchedExisting.remove(preferredExistingIndex)
        }

        let remainingSaved = result.indices.filter { result[$0] == nil }
        let remainingExisting = unmatchedExisting.sorted { lhs, rhs in
            let left = existing[lhs]?.displayIndex ?? .max
            let right = existing[rhs]?.displayIndex ?? .max
            return left == right ? lhs < rhs : left < right
        }
        for (savedIndex, existingIndex) in zip(remainingSaved, remainingExisting) {
            result[savedIndex] = existingIndex
        }
        return result
    }
}

/// The arithmetic behind putting a last session back, kept free of AppKit so
/// it can be checked with plain counts.
///
/// `saved` is how many windows the last session recorded; `live` is how many
/// Studio windows exist once the launch has settled — the one SwiftUI always
/// opens plus every window macOS restored on its own. Only the shortfall is
/// opened. A live count past `StudioLastSessionStore.maximumWindows` is an
/// inflated session being restored, and the surplus is closed rather than
/// carried into the next quit's save.
enum StudioLastSessionReconciliation {
    struct Plan: Equatable {
        var windowsToOpen: Int
        var windowsToClose: Int
    }

    static func plan(
        saved: Int,
        live: Int,
        maximum: Int = StudioLastSessionStore.maximumWindows
    ) -> Plan {
        Plan(
            windowsToOpen: max(0, min(saved, maximum) - live),
            windowsToClose: max(0, live - maximum)
        )
    }
}

@MainActor
final class StudioWorkspaceWindowCoordinator {
    static let shared = StudioWorkspaceWindowCoordinator()

    private final class Entry {
        let state: StudioWindowState
        weak var window: NSWindow?
        /// Registration order, so closing surplus windows takes the latest.
        let order: Int

        init(state: StudioWindowState, window: NSWindow, order: Int) {
            self.state = state
            self.window = window
            self.order = order
        }
    }

    private let logger = Logger(subsystem: "com.foreverlm", category: "StudioLastSession")
    private var entries: [UUID: Entry] = [:]
    private var registrations = 0
    private var pendingWindows: [StudioSavedWorkspaceWindow] = []
    private var lastSessionArmed = false
    private var didConsiderLastSession = false
    private var lastSessionWindowCount = 0
    private var didFinishRestoringWindows = false
    private var restorationObserver: NSObjectProtocol?
    private var reopenTask: Task<Void, Never>?
    private var pendingRegistrationAction: PendingRegistrationAction?

    /// Work waiting for a window that does not exist yet: a Studio window has
    /// been asked for through `openWindow`, and something should happen in it
    /// as soon as SwiftUI has made it. There is no handle to that window before
    /// it registers, so this is how "open a window, then open the source in it"
    /// is expressed. Timed, because a window that never arrives must not let
    /// the action fire in whatever window the learner opens next.
    private struct PendingRegistrationAction {
        let deadline: ContinuousClock.Instant
        let action: @MainActor (StudioWindowState) -> Void
    }

    static let pendingRegistrationTimeout: Duration = .seconds(5)

    init() {}

    /// `opensNewWindow` is what a brand-new window — a scene with no snapshot
    /// of its own — opens in: run here, unless the window is taking a saved
    /// one from the last session or a named workspace, and before anything
    /// asked of the window (`performInNextRegisteredWindow`) runs, so a
    /// source sent to a new window opens in the notebook it opens in.
    func register(
        state: StudioWindowState,
        window: NSWindow,
        opensNewWindow: (@MainActor (StudioWindowState) -> Void)? = nil
    ) {
        seedLastSessionIfNeeded()
        registrations += 1
        entries[state.id] = Entry(state: state, window: window, order: registrations)
        updatePlacement(for: state, window: window)
        if !pendingWindows.isEmpty {
            let saved = pendingWindows.removeFirst()
            state.workspaceRestoreOverridesSceneSnapshot = true
            state.applyWorkspaceSnapshot(saved.snapshot)
            apply(saved.placement, to: window)
            // Only a relaunch the app asked for queues windows with content
            // (see `seedLastSessionIfNeeded`); a named workspace never has any.
            if let content = saved.content, !content.isEmpty {
                state.pendingResumeContent = content
            }
        } else if let opensNewWindow, !state.workspaceRestoreOverridesSceneSnapshot {
            opensNewWindow(state)
        }
        if let pending = pendingRegistrationAction {
            pendingRegistrationAction = nil
            if ContinuousClock().now <= pending.deadline {
                pending.action(state)
            }
        }
    }

    /// Runs `action` in the next Studio window to register, provided one does
    /// within `pendingRegistrationTimeout`. The caller opens the window itself,
    /// right after this — the coordinator cannot, since only a scene's
    /// environment can reach `openWindow`. A second request before the window
    /// arrives replaces the first: the learner asked for the later thing.
    func performInNextRegisteredWindow(
        _ action: @escaping @MainActor (StudioWindowState) -> Void
    ) {
        pendingRegistrationAction = PendingRegistrationAction(
            deadline: ContinuousClock().now + Self.pendingRegistrationTimeout,
            action: action
        )
    }

    func unregister(state: StudioWindowState) {
        entries.removeValue(forKey: state.id)
    }

    func window(for state: StudioWindowState) -> NSWindow? {
        entries[state.id]?.window
    }

    /// Brings a Studio window forward after a command has sent something to it.
    /// Placing a source in a window the learner cannot see is indistinguishable
    /// from doing nothing, so the destination becomes key — which is also what
    /// re-points the key-window registry that legacy navigation reads.
    ///
    /// Deliberately not `ignoringOtherApps`: this only ever runs from a menu
    /// inside ForeverLM, so the app is already frontmost, and forcing
    /// activation would steal focus back from anything the learner switched to
    /// in between.
    func bringToFront(_ state: StudioWindowState) {
        guard let window = window(for: state) else { return }
        NSApp.activate(ignoringOtherApps: false)
        window.makeKeyAndOrderFront(nil)
    }

    func updatePlacement(for state: StudioWindowState, window: NSWindow) {
        state.workspacePlacement = placement(for: window)
    }

    /// Opt in to putting the last session back. Called once, at launch, by the
    /// app itself — before `NSApplication` launches, so AppKit's restoration
    /// pass cannot finish before anyone is listening for it.
    ///
    /// Registering a window deliberately does not imply this. Restoring is a
    /// launch decision, and making it a side effect of registration meant every
    /// caller that builds windows — a second Studio window opened by hand, a
    /// test constructing two states — could pull a stored arrangement in
    /// underneath itself.
    func armLastSessionRestore() {
        guard !StudioLastSessionStore.isDisabled() else {
            logger.notice("Last session: off for this process (\(StudioLastSessionStore.environmentKey, privacy: .public)); nothing restored, nothing saved")
            return
        }
        lastSessionArmed = true
        guard restorationObserver == nil else { return }
        restorationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishRestoringWindowsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didFinishRestoringWindows = true
            }
        }
    }

    /// Puts back the windows the last session left behind.
    ///
    /// Reuses `pendingWindows`, the same queue a named workspace restore uses:
    /// windows consume it in saved order as they register, so the arrangement is
    /// rebuilt without this having to know when SwiftUI gets around to making
    /// them. Seeding is driven from `register`, `reopenLastSessionWindowsIfNeeded`
    /// and `reconcileLastSessionWindows`, because a window's registration and
    /// its `task` are not ordered against each other and either may come first.
    ///
    /// A single saved window queues nothing: SwiftUI already restores one
    /// window's frame and its panes come from `SceneStorage`, so the only thing
    /// worth adding is the windows beyond the first. The count is kept either
    /// way, because the reconciliation also closes an inflated set of restored
    /// windows, and that does not depend on what was saved.
    ///
    /// After a relaunch the app started itself — an update's Restart, the Full
    /// Disk Access relaunch — every saved window is queued, the single one
    /// included, and each keeps its content: the learner pressed a button that
    /// promised the same app back, so the same source, chat and doc come back
    /// with it. The layout has to come from the store then too, because a
    /// graceful quit leaves no `SceneStorage` for the first window to restore.
    private func seedLastSessionIfNeeded() {
        guard lastSessionArmed, !didConsiderLastSession else { return }
        didConsiderLastSession = true
        let resumesContent = StudioLastSessionStore.consumeContentResumeRequest()
        guard entries.isEmpty, pendingWindows.isEmpty else { return }

        let saved = StudioLastSessionStore.load()
        lastSessionWindowCount = saved.count
        if resumesContent {
            logger.notice("Last session: relaunch requested by the app; restoring content in \(saved.count, privacy: .public) window(s)")
            pendingWindows = saved
            return
        }
        guard saved.count > 1 else { return }
        pendingWindows = saved.map(\.withoutContent)
    }

    /// Records the open windows for the next launch. Called at quit, and again
    /// just before a relaunch the app starts itself, so the record is of the
    /// moment the learner pressed Restart even if termination is cut short.
    ///
    /// Only windows that are on screen are recorded. A Studio window that was
    /// ordered out but never closed — a pop-out's host, a window a driver left
    /// behind — is not part of the arrangement the learner sees, and putting
    /// it back opens a window that was not there. A process launched with the
    /// record turned off (`StudioLastSessionStore.isDisabled`) saves nothing,
    /// so its windows never become the next launch's arrangement.
    func saveLastSession() {
        guard !StudioLastSessionStore.isDisabled() else { return }
        StudioLastSessionStore.save(captureWorkspace(includingContent: true, onScreenOnly: true))
    }

    /// Whether a window counts toward the last session: ordered in, or sitting
    /// in the Dock as a miniaturized window the learner can bring back.
    static func isOnScreen(_ window: NSWindow) -> Bool {
        window.isVisible || window.isMiniaturized
    }

    /// The app is about to quit and come straight back: save what every window
    /// shows and ask the next launch to put it back.
    func prepareForRelaunch() {
        saveLastSession()
        StudioLastSessionStore.requestContentResume()
    }

    /// Puts the rest of the last session back, once per launch, after macOS has
    /// finished restoring windows of its own.
    ///
    /// The count cannot be settled when the first window asks. SwiftUI restores
    /// the previous launch's windows itself, and those scenes register after
    /// the first window's task has run, so a count taken then saw one window,
    /// opened the whole saved session on top of the restored one, and the next
    /// quit saved the sum: measured on 2026-09-03, a 35-window store came back
    /// as 269 windows and was saved as 269. So the decision waits for AppKit's
    /// restoration pass, then for registrations to stop arriving, and is taken
    /// against the windows that actually exist.
    func reopenLastSessionWindowsIfNeeded(openWindow: @escaping @MainActor () -> Void) {
        seedLastSessionIfNeeded()
        guard lastSessionArmed, reopenTask == nil else { return }
        reopenTask = Task { @MainActor [weak self] in
            await self?.waitForWindowRestorationToSettle()
            guard let self else { return }
            let plan = self.reconcileLastSessionWindows()
            for _ in 0..<plan.windowsToOpen {
                openWindow()
            }
        }
    }

    /// Closes the Studio windows past the cap and says how many the last
    /// session is still short, answered once. Kept apart from the wait so the
    /// counting can be exercised against registered windows without a launch.
    func reconcileLastSessionWindows() -> StudioLastSessionReconciliation.Plan {
        seedLastSessionIfNeeded()
        let live = liveEntries.sorted { $0.order < $1.order }
        let plan = StudioLastSessionReconciliation.plan(
            saved: lastSessionWindowCount,
            live: live.count
        )
        logger.notice(
            "Last session: saved \(self.lastSessionWindowCount, privacy: .public) window(s), \(live.count, privacy: .public) live after restoration; opening \(plan.windowsToOpen, privacy: .public), closing \(plan.windowsToClose, privacy: .public)"
        )
        lastSessionWindowCount = 0
        for entry in live.suffix(plan.windowsToClose) {
            entries.removeValue(forKey: entry.state.id)
            entry.window?.performClose(nil)
        }
        return plan
    }

    /// Waits for AppKit's restoration pass, then for the registrations it
    /// produces to stop. Both waits are bounded: the first for a launch path
    /// that never posts the notification, the second so a session being
    /// restored one window at a time cannot hold the reopen forever.
    private func waitForWindowRestorationToSettle() async {
        let clock = ContinuousClock()
        let restorationDeadline = clock.now + .seconds(3)
        while !didFinishRestoringWindows, clock.now < restorationDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !didFinishRestoringWindows {
            logger.info("Last session: no window-restoration notice within 3 s; counting what exists")
        }

        var settledCount = liveEntries.count
        var quietTicks = 0
        let settleDeadline = clock.now + .seconds(15)
        while quietTicks < 2, clock.now < settleDeadline {
            try? await Task.sleep(for: .milliseconds(100))
            let count = liveEntries.count
            if count == settledCount {
                quietTicks += 1
            } else {
                settledCount = count
                quietTicks = 0
            }
        }
    }

    /// Every live window's arrangement, and with `includingContent` what each
    /// one is showing. Named workspaces take the arrangement alone; the
    /// last-session record takes both, and only from windows on screen.
    func captureWorkspace(
        includingContent: Bool = false,
        onScreenOnly: Bool = false
    ) -> [StudioSavedWorkspaceWindow] {
        liveEntries
            .filter { entry in
                guard onScreenOnly, let window = entry.window else { return true }
                return Self.isOnScreen(window)
            }
            .sorted { lhs, rhs in
                placementSortKey(lhs.state.workspacePlacement)
                    < placementSortKey(rhs.state.workspacePlacement)
            }
            .map { entry in
                if let window = entry.window {
                    updatePlacement(for: entry.state, window: window)
                }
                return StudioSavedWorkspaceWindow(
                    snapshot: entry.state.snapshot,
                    placement: entry.state.workspacePlacement,
                    content: includingContent ? Self.content(of: entry.state) : nil
                )
            }
    }

    /// What a window is showing right now. The Reader's source is the one the
    /// window chose for itself, or failing that the one its mounted reader is
    /// displaying from the app-wide selection.
    static func content(of state: StudioWindowState) -> StudioWindowContent {
        StudioWindowContent(
            readerSourceID: state.ownsReaderSelection
                ? state.readerArticleID
                : state.readerSourceIDsOnScreen.first,
            chatSessionID: state.chatSessionID,
            artifactID: state.openArtifactID,
            sidebarTab: state.sidebarStore.sidebarTab.rawValue
        )
    }

    /// Applies as many saved windows as already exist, closes surplus Studio
    /// windows, and returns how many new `WindowGroup` members the caller must
    /// open. Newly registered windows consume `pendingWindows` in saved order.
    func restore(
        _ savedView: StudioSavedWorkspaceView,
        invokedBy invokingState: StudioWindowState
    ) -> Int {
        pendingWindows.removeAll()
        let savedWindows = savedView.windows.sorted {
            placementSortKey($0.placement) < placementSortKey($1.placement)
        }
        let existing = liveEntries.sorted {
            placementSortKey($0.state.workspacePlacement)
                < placementSortKey($1.state.workspacePlacement)
        }
        // Re-read real frames at the moment of restore. A display reconnect or
        // an AppKit move notification still in flight must not make matching
        // decisions from stale presentation state.
        for entry in existing {
            if let window = entry.window {
                updatePlacement(for: entry.state, window: window)
            }
        }

        let invokingIndex = existing.firstIndex(where: { $0.state === invokingState })
        let assignments = StudioWorkspaceWindowMatcher.assignments(
            saved: savedWindows.map(\.placement),
            existing: existing.map(\.state.workspacePlacement),
            preferredExistingIndex: invokingIndex
        )
        var reusedExistingIndices: Set<Int> = []
        var unmatchedSaved: [StudioSavedWorkspaceWindow] = []
        for (savedIndex, saved) in savedWindows.enumerated() {
            guard let existingIndex = assignments[savedIndex] else {
                unmatchedSaved.append(saved)
                continue
            }
            reusedExistingIndices.insert(existingIndex)
            let entry = existing[existingIndex]
            // A reused scene can still be waiting for its SceneStorage task.
            // Mark it exactly like a newly opened pending scene so that late
            // hydration cannot overwrite the named workspace we just applied.
            entry.state.workspaceRestoreOverridesSceneSnapshot = true
            entry.state.applyWorkspaceSnapshot(saved.snapshot)
            if let window = entry.window {
                apply(saved.placement, to: window)
            }
        }

        for (index, entry) in existing.enumerated() where !reusedExistingIndices.contains(index) {
            entry.window?.performClose(nil)
        }
        pendingWindows = unmatchedSaved
        return pendingWindows.count
    }

    private var liveEntries: [Entry] {
        entries = entries.filter { $0.value.window != nil }
        return Array(entries.values)
    }

    private func placementSortKey(_ placement: StudioWindowPlacement?) -> String {
        StudioWindowPlacement.onScreenSortKey(placement)
    }

    private func placement(for window: NSWindow) -> StudioWindowPlacement? {
        guard let screen = window.screen ?? NSScreen.main else { return nil }
        let screens = orderedScreens
        let displayIndex = screens.firstIndex(of: screen) ?? 0
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return nil }
        let frame = window.frame
        return StudioWindowPlacement(
            displayUUID: displayUUID(for: screen),
            displayID: displayID(for: screen),
            displayName: screen.localizedName,
            displayIndex: displayIndex,
            normalizedX: Double((frame.minX - visible.minX) / visible.width),
            normalizedY: Double((frame.minY - visible.minY) / visible.height),
            normalizedWidth: Double(frame.width / visible.width),
            normalizedHeight: Double(frame.height / visible.height)
        )
    }

    private func apply(_ placement: StudioWindowPlacement?, to window: NSWindow) {
        guard let placement else { return }
        let screens = orderedScreens
        guard !screens.isEmpty else { return }
        let descriptors = screens.enumerated().map { index, screen in
            StudioDisplayDescriptor(
                uuid: displayUUID(for: screen),
                id: displayID(for: screen),
                name: screen.localizedName,
                index: index
            )
        }
        guard let screenIndex = StudioWorkspaceDisplayResolver.index(
            for: placement,
            among: descriptors
        ) else { return }
        let screen = screens[screenIndex]
        let visible = screen.visibleFrame
        let width = min(
            visible.width,
            max(window.minSize.width, visible.width * placement.normalizedWidth)
        )
        let height = min(
            visible.height,
            max(window.minSize.height, visible.height * placement.normalizedHeight)
        )
        let requestedX = visible.minX + visible.width * placement.normalizedX
        let requestedY = visible.minY + visible.height * placement.normalizedY
        let frame = NSRect(
            x: min(max(requestedX, visible.minX), visible.maxX - width),
            y: min(max(requestedY, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
        window.setFrame(frame, display: true, animate: false)
    }

    private var orderedScreens: [NSScreen] {
        NSScreen.screens.sorted {
            if $0.frame.minX == $1.frame.minX { return $0.frame.minY < $1.frame.minY }
            return $0.frame.minX < $1.frame.minX
        }
    }

    private func displayID(for screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .stringValue
    }

    private func displayUUID(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value) else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}

/// Associates a SwiftUI scene with its real AppKit window. Key-window changes
/// drive imperative menu/navigation routing without polling or global broadcasts.
private struct StudioWindowRegistryAttachment: NSViewRepresentable {
    let state: StudioWindowState
    /// For a brand-new window: what it opens in, run as it registers
    /// (`StudioWorkspaceWindowCoordinator.register`). Nil for a scene that
    /// restores a snapshot of its own.
    var opensNewWindow: (@MainActor (StudioWindowState) -> Void)?

    func makeNSView(context: Context) -> StudioWindowRegistryView {
        StudioWindowRegistryView(state: state, opensNewWindow: opensNewWindow)
    }

    func updateNSView(_ nsView: StudioWindowRegistryView, context: Context) {
        nsView.state = state
        nsView.attachToCurrentWindowIfNeeded()
    }
}

/// Tells the window registry when the window hosting this view becomes or
/// resigns key. `StudioWindowRegistryAttachment` does that for Studio windows;
/// this is for the app's other windows, whose focus the chat router has to
/// know about: a popped-out Reader is no Studio window, so a request made in
/// it goes to the Studio window used last and is announced, while a popped-out
/// Chat stands for the window it came from, so acting in it is acting there.
struct StudioWindowKeyAttachment: NSViewRepresentable {
    let onBecomeKey: @MainActor () -> Void
    let onResignKey: @MainActor () -> Void

    static var detachedWindow: StudioWindowKeyAttachment {
        StudioWindowKeyAttachment(
            onBecomeKey: { StudioWindowRegistry.shared.noteDetachedWindowIsKey(true) },
            onResignKey: { StudioWindowRegistry.shared.noteDetachedWindowIsKey(false) }
        )
    }

    static func standing(for state: StudioWindowState) -> StudioWindowKeyAttachment {
        StudioWindowKeyAttachment(
            onBecomeKey: { StudioWindowRegistry.shared.activateIfRegistered(state) },
            onResignKey: {}
        )
    }

    func makeNSView(context: Context) -> StudioWindowKeyObserverView {
        StudioWindowKeyObserverView(onBecomeKey: onBecomeKey, onResignKey: onResignKey)
    }

    func updateNSView(_ nsView: StudioWindowKeyObserverView, context: Context) {
        nsView.attachToCurrentWindowIfNeeded()
    }
}

@MainActor
final class StudioWindowKeyObserverView: NSView {
    private let onBecomeKey: @MainActor () -> Void
    private let onResignKey: @MainActor () -> Void
    private weak var observedWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []

    init(onBecomeKey: @escaping @MainActor () -> Void, onResignKey: @escaping @MainActor () -> Void) {
        self.onBecomeKey = onBecomeKey
        self.onResignKey = onResignKey
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Torn down while its window is still key — SwiftUI swapping the
            // scene's content — must not leave "a detached window is key"
            // standing: every later request would then look detached.
            if observedWindow?.isKeyWindow == true { onResignKey() }
            detachFromObservedWindow()
        } else {
            attachToCurrentWindowIfNeeded()
        }
    }

    func attachToCurrentWindowIfNeeded() {
        guard let window, observedWindow !== window else { return }
        detachFromObservedWindow()
        observedWindow = window
        // The window may already be key by the time SwiftUI hosts this view.
        if window.isKeyWindow { onBecomeKey() }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { self.onBecomeKey() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { self.onResignKey() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    if self.observedWindow?.isKeyWindow == true { self.onResignKey() }
                    self.detachFromObservedWindow()
                }
            },
        ]
    }

    private func detachFromObservedWindow() {
        let center = NotificationCenter.default
        windowObservers.forEach { center.removeObserver($0) }
        windowObservers = []
        observedWindow = nil
    }
}

@MainActor
private final class StudioWindowRegistryView: NSView {
    var state: StudioWindowState
    /// Run once, as the window first registers; then let go, so a later
    /// registration (the view moving to another window) is not a new window.
    private var opensNewWindow: (@MainActor (StudioWindowState) -> Void)?
    private weak var observedWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []

    init(state: StudioWindowState, opensNewWindow: (@MainActor (StudioWindowState) -> Void)?) {
        self.state = state
        self.opensNewWindow = opensNewWindow
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachToCurrentWindowIfNeeded()
    }

    func attachToCurrentWindowIfNeeded() {
        guard let window, observedWindow !== window else { return }
        detachFromObservedWindow()
        observedWindow = window
        StudioWindowRegistry.shared.register(state, makeActive: window.isKeyWindow)
        let opensNewWindow = self.opensNewWindow
        self.opensNewWindow = nil
        StudioWorkspaceWindowCoordinator.shared.register(state: state, window: window, opensNewWindow: opensNewWindow)

        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    StudioWindowRegistry.shared.activate(self.state)
                }
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    StudioWindowRegistry.shared.unregister(self.state)
                    StudioWorkspaceWindowCoordinator.shared.unregister(state: self.state)
                    self.detachFromObservedWindow()
                }
            },
            center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                MainActor.assumeIsolated {
                    StudioWorkspaceWindowCoordinator.shared.updatePlacement(
                        for: self.state,
                        window: window
                    )
                }
            },
            center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                MainActor.assumeIsolated {
                    StudioWorkspaceWindowCoordinator.shared.updatePlacement(
                        for: self.state,
                        window: window
                    )
                }
            },
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                MainActor.assumeIsolated {
                    StudioWorkspaceWindowCoordinator.shared.updatePlacement(
                        for: self.state,
                        window: window
                    )
                }
            },
        ]
    }

    private func detachFromObservedWindow() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        observedWindow = nil
    }
}
#endif

private extension View {
    /// ForeverLM owns its AI workflows, so system Writing Tools should not offer a
    /// second, overlapping editing surface inside the app.
    @ViewBuilder
    func foreverlmWritingToolsDisabled() -> some View {
        if #available(macOS 15.0, *) {
            writingToolsBehavior(.disabled)
        } else {
            self
        }
    }
}

/// App-menu entry (next to About) for the standalone licenses window.
private struct ThirdPartyLicensesMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Third-Party Licenses…") {
            openWindow(id: "third-party-licenses")
        }
    }
}
