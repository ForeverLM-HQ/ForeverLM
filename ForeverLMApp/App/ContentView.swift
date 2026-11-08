import SwiftUI
#if os(macOS)
import AppKit
import notify
#endif

/// Root view router — requires an Apple account, then opens Studio.
struct ContentView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(ManagedAIAccountModel.self) private var account
    @State private var mcpAuthorization = MCPAuthorizationPromptModel()

    private var presentsAccountWall: Bool {
        (!account.hasAccountAccess
            || account.isLoadingStoredSession
            || account.isValidatingLapsedSession)
            && !UITestConfiguration.isUITesting
    }

    private var hidesStudio: Bool { presentsAccountWall }

    var body: some View {
        ZStack {
            // Keep Studio's root identity stable while a stored Apple session is
            // validated. Replacing this entire, very large graph with the wall
            // made SwiftUI tear it down during an active update transaction; the
            // resulting release race repeatedly crashed in `destroy of StudioView`.
            StudioView()
                .opacity(hidesStudio ? 0 : 1)
                .allowsHitTesting(!hidesStudio)
                .accessibilityHidden(hidesStudio)
                .onAppear {
                    if UITestConfiguration.isUITesting {
                        // Force a deterministic Retina-sized window for release screenshots.
                        // A developer may have a non-Retina external display active; centering on
                        // whichever display owns the restored window made captures switch between
                        // 1x and 2x from run to run.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow || $0.isMainWindow }) {
                                let size = NSSize(width: 1440, height: 900)
                                window.setContentSize(size)
                                let targetScreen = NSScreen.screens.max {
                                    $0.backingScaleFactor < $1.backingScaleFactor
                                } ?? NSScreen.main
                                if let targetScreen {
                                    let visibleFrame = targetScreen.visibleFrame
                                    let windowFrame = window.frame
                                    let origin = NSPoint(
                                        x: visibleFrame.midX - windowFrame.width / 2,
                                        y: visibleFrame.midY - windowFrame.height / 2
                                    )
                                    window.setFrameOrigin(origin)
                                } else {
                                    window.center()
                                }
                                window.makeKeyAndOrderFront(nil)
                            }
                        }
                        registerWindowCaptureHookIfRequested()
                    }
                }
                .onOpenURL(perform: handleOpenURL)
                // A link from outside — a doc's address from Codex, a chat or
                // the Terminal — lands in a window that is already open. Left
                // to itself, SwiftUI answers a URL with a new window whenever
                // none of the open ones is key, and a window that has never
                // been key cannot present a sheet: in build 85 three docs
                // opened that way could not be published or trashed from
                // their ⋯ menu (2026-09-08). The reveal itself goes to the
                // active window (`bringStudioForward`).
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onReceive(NotificationCenter.default.publisher(for: .requestOpenStudioEntityLink)) { note in
                    guard let link = note.object as? StudioEntityLink else { return }
                    Task { await vm.open(link) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .requestOpenChatSavedCards)) { note in
                    guard let cards = note.object as? ChatSavedCards else { return }
                    Task { await vm.openChatSavedCards(cards) }
                }

            if presentsAccountWall {
                // Sign in with Apple is required to use ForeverLM. It also supplies the
                // durable identity used for managed AI credits and the optional MCP unlock.
                //
                // A lapsed session keeps the wall up until the proxy answers, rather than
                // opening the app on a grace window that may be covering a revoked token.
                // If the proxy confirms it, this flips to Studio; if the network is down,
                // grace applies and it opens anyway.
                //
                // UI tests and App Store screenshot runs skip it — there is no Apple ID to
                // sign into on a test runner, and the wall would be the only screen captured.
                AppleAccountWall(
                    isCheckingSession: account.isLoadingStoredSession || account.isValidatingLapsedSession
                )
            }
        }
        .task {
            guard !UITestConfiguration.isUITesting else { return }
            mcpAuthorization.refresh()
        }
        .task {
            // The gate above reads the Keychain and nothing else, so a token the proxy has
            // already revoked would open the app forever. Ask once per launch — silently,
            // and only a real rejection re-walls, so an offline Mac is unaffected.
            guard !UITestConfiguration.isUITesting else { return }
            await account.loadStoredSession()
            await account.validateStoredSession()
            // Keep a root-level owner for the bootstrap as well as StudioView's
            // account-keyed task. The view model makes both paths idempotent, and
            // this path completes even if a scene closes during validation.
            if account.hasAccountAccess {
                await vm.ensureInitialQueueLoaded()
            }
            if account.isSignedIn {
                await ArticleSpeechVoicePreviewRepository.shared.startPrewarming(
                    prioritizedModelID: MacArticleSpeechSettings.openRouterModel
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Event-driven recheck rather than a poll timer: a revocation that lands while
            // the app sits in the background takes effect the next time it is used.
            guard !UITestConfiguration.isUITesting else { return }
            Task { await account.validateStoredSession(minimumInterval: 15 * 60) }
            // The directory read behind the price watch: a model the learner
            // uses may have stopped being free while the app sat unused. The
            // refresher's five-minute cooldown keeps this cheap.
            AIModelPriceRefresher.refreshIfStale()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mcpPendingAuthorizationsChanged)) { _ in
            mcpAuthorization.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .legacyContentDidMigrate)) { _ in
            // The migrator cleared absolute-path cache entries that pointed at
            // removed legacy roots. Republish once so the existing debounced,
            // off-main path warmer resolves every row under the canonical root.
            vm.articles = vm.articles
        }
        .onReceive(NotificationCenter.default.publisher(for: .sourceDocumentsDidInstall)) { _ in
            // Same shape as a migration: files appeared at paths the rows
            // already hold, and only the cleared path cache makes them visible.
            vm.articles = vm.articles
        }
        .sheet(item: $mcpAuthorization.current) { request in
            MCPAuthorizationApprovalSheet(request: request) { approved in
                mcpAuthorization.resolve(request, approved: approved)
            }
        }
    }

    /// UI-testing only: when launched with `--capture-window-png <path>`, listen for the
    /// Darwin notification `com.foreverlm.capture-window` (post with
    /// `notifyutil -p com.foreverlm.capture-window`) and render the main window to a PNG
    /// at that path. Uses `cacheDisplay`, so it needs no screen-recording permission and
    /// captures at native Retina scale. Used by the marketing/App Store screenshot pipeline.
    private func registerWindowCaptureHookIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "--capture-window-png"),
              args.indices.contains(flagIndex + 1) else {
            return
        }
        let outputPath = args[flagIndex + 1]
        var token: Int32 = 0
        notify_register_dispatch("com.foreverlm.capture-window", &token, DispatchQueue.main) { _ in
            captureMainWindowPNG(to: outputPath)
        }
    }

    /// A link from outside the app should show its target where the reader is
    /// looking: the app comes forward and the active Studio window becomes key,
    /// so the reveal lands there and the window can present the sheets that
    /// follow (Publish, Update Page, Move to Trash). A window that is main but
    /// never key — what SwiftUI made for an external URL in build 85 — cannot.
    private func bringStudioForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let state = StudioWindowRegistry.shared.activeState,
           let window = StudioWorkspaceWindowCoordinator.shared.window(for: state) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func handleOpenURL(_ url: URL) {
        // A web address handed to the app — ForeverLM chosen as the browser
        // for a link, or `open -a ForeverLM https://…` — opens in the Browser
        // pane, straight at the destination.
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            vm.openInBrowser(url)
            return
        }
        guard url.scheme?.lowercased() == ForeverLMRuntimeIdentity.urlScheme else { return }

        // A web sign-in that continued in a browser tab ends here.
        if AppleIdentityToken.handleWebCallback(url) { return }

        if url.host?.lowercased() == "settings",
           let destination = url.pathComponents.dropFirst().first?.lowercased() {
            // The web library's links into the Mac still say settings/ for
            // the plugins, which are a place of their own since 2026-10-13.
            switch destination {
            case "plugins":
                PluginsPlace.requestOpen()
                return
            case "google-drive":
                PluginsPlace.requestOpen(.googleDrive)
                return
            case "calendar":
                PluginsPlace.requestOpen(.appleCalendar)
                return
            default:
                break
            }
            let pane: SettingsPane?
            switch destination {
            case "mcp":
                let showsPairingCode =
                    url.pathComponents.dropFirst(2).first?.lowercased() == "pairing"
                pane = showsPairingCode ? .mcpPairing : .mcp
            case "general", "appearance", "memory":
                pane = .general
            default:
                pane = nil
            }
            if let pane {
                NotificationCenter.default.post(name: .requestOpenStudioSettings, object: pane)
                return
            }
        }

        // A plugin's or a skill's Copy Link (`PluginsPlaceLink`).
        if let link = PluginsPlaceLink.parse(url) {
            bringStudioForward()
            Task { await PluginsPlace.open(link, vm: vm) }
            return
        }

        if url.host?.lowercased() == "mcp" {
            // The OAuth waiting page deep-links here to bring the app forward;
            // re-surface the approval prompt in case it was dismissed.
            mcpAuthorization.refresh()
            return
        }

        // The cards a chat saved (`foreverlm://cards?…`), clicked anywhere but
        // the chat that draws them: To Check at the first still to check.
        if let cards = ChatSavedCards.parse(url) {
            bringStudioForward()
            Task { await vm.openChatSavedCards(cards) }
            return
        }

        // A doc or a Notebook, addressed the way a doc's own links address them.
        if let entity = StudioEntityLink.parse(url) {
            bringStudioForward()
            Task { await vm.open(entity) }
            return
        }

        guard let link = ChatMarkdownView.sourceLink(from: url) else { return }
        let sourceID = link.sourceID

        // Show the source in the main window's reader panel, like a Library
        // click. Deliberately leaves chat context and the Chat panel
        // alone: these links are mostly clicked from inside the assistant
        // chat, and the conversation must survive the navigation.
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "action" })?
            .value
        bringStudioForward()
        Task {
            await vm.openLinkedSourceInReader(sourceID, at: link.seconds, passage: link.passage, page: link.page)
            if action == "find-mentioned-papers",
               let resolvedSourceID = vm.selectedArticleId {
                await vm.extractMentionedPapersFromMeeting(for: resolvedSourceID)
            } else if action == "get-transcript",
                      let resolvedSourceID = vm.selectedArticleId {
                do {
                    _ = try await vm.ensureMeetingTranscript(for: resolvedSourceID)
                    vm.showToast("Meeting transcript is ready.")
                } catch {
                    vm.showToast("Couldn't get transcript: \(error.localizedDescription)")
                }
            } else if action == "transcribe-podcast-audio",
                      let resolvedSourceID = vm.selectedArticleId {
                await vm.transcribePodcastEpisodeAudio(for: resolvedSourceID)
            } else if action == "refresh-from-website",
                      let resolvedSourceID = vm.selectedArticleId {
                await vm.refreshArticleFromWebsite(resolvedSourceID)
            }
        }
    }
}

/// Drives the native approval prompt for MCP OAuth authorizations initiated in a
/// browser (see the owner-consent gate in MCPOAuth.swift). The OAuth provider
/// posts `.mcpPendingAuthorizationsChanged`; this model pulls the pending queue
/// and the sheet resolves one request at a time.
@MainActor
@Observable
final class MCPAuthorizationPromptModel {
    var current: MCPPendingAuthorizationSummary?

    func refresh() {
        Task {
            let oauthProvider = await MCPOAuthProvider.sharedProvider()
            let pending = await oauthProvider.pendingAuthorizationSummaries()
            // Keep the sheet stable while its request is still waiting.
            if let current, pending.contains(current) { return }
            current = pending.first
            if current != nil {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func resolve(_ request: MCPPendingAuthorizationSummary, approved: Bool) {
        current = nil
        Task {
            let oauthProvider = await MCPOAuthProvider.sharedProvider()
            await oauthProvider.resolveAuthorization(id: request.id, approved: approved)
        }
    }
}

private struct MCPAuthorizationApprovalSheet: View {
    let request: MCPPendingAuthorizationSummary
    let onResolve: (Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "personalhotspot")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            Text("Allow \(request.clientName) to connect?")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            // The scope line must match what approval actually grants: an
            // ingest-only plugin must not be described as able to read the
            // knowledge base, and a full client must not sound like one.
            Text(request.ingestOnly
                ? "\(request.clientName) is asking for ingest-only access: it can add sources to your library, but cannot read your knowledge base, modify or delete other sources, or use any other tools. Approve only if you just started this connection yourself."
                : "\(request.clientName) is asking to read and manage your ForeverLM knowledge base. Approve only if you just started this connection yourself.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if request.ingestOnly {
                Label("Add-only access", systemImage: "tray.and.arrow.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            VStack(spacing: 2) {
                Text(request.matchCode)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text("Your browser shows this same code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)

            HStack(spacing: 10) {
                Button("Deny") {
                    onResolve(false)
                }
                .keyboardShortcut(.cancelAction)

                Button("Approve") {
                    onResolve(true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 360)
    }
}

#if os(macOS)
/// Render the app's main window (including title bar) to a PNG at native Retina scale.
/// `cacheDisplay` draws the view hierarchy directly, so this works without the
/// Screen Recording permission that `screencapture`/CGWindowList capture require.
@MainActor
private func captureMainWindowPNG(to path: String) {
    guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && !$0.isMiniaturized })
            ?? NSApplication.shared.windows.first,
          let contentView = window.contentView else {
        return
    }
    let frameView = contentView.superview ?? contentView
    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
        return
    }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
}
#endif
