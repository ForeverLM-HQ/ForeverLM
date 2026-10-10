import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The browser Reading Lists used by the first-source workflow. Onboarding and
/// the persistent empty-library guide share this copy so they teach the same
/// import path.
enum ReadingListBrowser: String, CaseIterable, Identifiable, Hashable {
    case safari
    case chrome
    case brave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        }
    }

    /// The browser's logo in the asset catalog.
    var logoAssetName: String {
        switch self {
        case .safari: return "SafariIcon"
        case .chrome: return "ChromeIcon"
        case .brave: return "BraveIcon"
        }
    }

    var preference: BrowserPreference {
        switch self {
        case .safari: return .safari
        case .chrome: return .chrome
        case .brave: return .brave
        }
    }

    var saveInstruction: String {
        switch self {
        case .safari: return "Choose Share, then Add to Reading List"
        case .chrome: return "Open Reading List, then choose Add current tab"
        case .brave: return "Open Reading List in the sidebar, then choose Add current tab"
        }
    }

    var shortcut: String? {
        switch self {
        case .safari: return "Shortcut: ⇧⌘D"
        case .chrome, .brave: return nil
        }
    }

    /// The per-Mac switch the Reading List scan reads. Unset means on, which
    /// keeps every install from before setup asked; a fresh setup writes all
    /// three off (`holdUntilChosen`) so nothing is imported until the learner
    /// picks a browser in the Articles or Papers step, or in Settings → Sources.
    var enabledKey: String {
        switch self {
        case .safari: return "readingListSafari"
        case .chrome: return "readingListChrome"
        case .brave: return "readingListBrave"
        }
    }

    var isEnabled: Bool {
        DefaultsEscapeHatch.bool(forKey: enabledKey, default: true)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    static var enabled: Set<ReadingListBrowser> {
        Set(allCases.filter(\.isEnabled))
    }

    init?(bundleIdentifier: String?) {
        guard let match = Self.allCases.first(where: {
            $0.preference.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier ?? "") == .orderedSame
        }) else { return nil }
        self = match
    }

    /// The Mac's default browser, when it is one whose Reading List ForeverLM
    /// reads. Setup recommends it: it is where the learner already saves pages.
    static var systemDefault: ReadingListBrowser? {
        guard let web = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: web) else { return nil }
        return ReadingListBrowser(bundleIdentifier: Bundle(url: app)?.bundleIdentifier)
    }

    /// First launch: turn off every browser this Mac has no answer for, so the
    /// setup guide's choice is the only thing that starts an import.
    static func holdUntilChosen(defaults: UserDefaults = .standard) {
        for browser in allCases where defaults.object(forKey: browser.enabledKey) == nil {
            defaults.set(false, forKey: browser.enabledKey)
        }
    }
}

/// A Reading List browser's logo and name, as setup and Settings → Sources
/// label their browser switches.
struct ReadingListBrowserLabel: View {
    let browser: ReadingListBrowser

    var body: some View {
        HStack(spacing: 8) {
            Image(browser.logoAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(browser.title)
        }
    }
}

/// An AI app the learner may already pay for. Setup asks (product owner, 2026-09-23)
/// instead of telling everyone about Claude and ChatGPT, so the AI step can say
/// what that subscription covers and the last step shows the one connector
/// setup that fits. The steps follow docs-site/setup-mcp.md and Settings ›
/// External AI Assistants.
enum AISubscription: String, CaseIterable, Identifiable, Hashable {
    case claude
    case chatGPT = "chatgpt"
    case grok
    case gemini
    case other

    /// Synced: what someone pays for follows the account, not the Mac.
    static let storageKey = "gettingStarted.aiSubscriptions"
    private static let noneAnswer = "none"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .grok: return "Grok"
        case .gemini: return "Gemini"
        case .other: return "Another one"
        }
    }

    var logoAssetName: String? {
        switch self {
        case .claude: return "ClaudeIcon"
        case .chatGPT: return "OpenAIIcon"
        case .grok: return "GrokIcon"
        case .gemini: return "GeminiIcon"
        case .other: return nil
        }
    }

    var usesTemplateLogo: Bool { self == .chatGPT || self == .grok }

    /// Where the connector goes in that app; the card adds the address.
    var connectorSteps: [String] {
        switch self {
        case .claude:
            return [
                "In Claude, open Customize › Connectors",
                "Choose Add custom connector, name it ForeverLM, and paste the address below",
                "Choose Connect and sign in with the same Apple Account as here",
            ]
        case .chatGPT:
            return [
                "In ChatGPT, open Settings › Apps › Advanced Settings and turn on developer mode",
                "Back in Settings › Apps, choose Create, name it ForeverLM, and paste the address below",
                "Choose OAuth and sign in with the same Apple Account as here",
            ]
        case .grok:
            return [
                "On grok.com, open Connectors and choose New Connector, then Custom",
                "Name it ForeverLM and paste the address below",
                "Sign in with the same Apple Account as here",
            ]
        case .gemini:
            return [
                "In Gemini, open Settings & help › Connected Apps",
                "Add a custom app named ForeverLM with the address below",
                "Sign in with the same Apple Account as here",
            ]
        case .other:
            return [
                "Add ForeverLM to it as an MCP connector with the address below",
                "Sign in with the same Apple Account as here",
            ]
        }
    }

    var connectorNote: String? {
        self == .gemini ? "Gemini uses ForeverLM in Spark tasks only." : nil
    }

    var connectorPage: (title: String, url: URL)? {
        switch self {
        case .claude: return ("Open Claude Connectors", URL(string: "https://claude.ai/settings/connectors")!)
        case .chatGPT: return ("Open ChatGPT", URL(string: "https://chatgpt.com")!)
        case .grok: return ("Open Grok Connectors", URL(string: "https://grok.com/connectors")!)
        case .gemini: return ("Open Gemini", URL(string: "https://gemini.google.com")!)
        case .other: return nil
        }
    }

    /// The stored answer: nil until asked, empty for "no", else the picks. A
    /// value from a newer build this one does not know is still something the
    /// learner pays for, so it reads as `.other` rather than as unanswered.
    static func decode(_ stored: String) -> Set<AISubscription>? {
        let stored = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.isEmpty { return nil }
        if stored == noneAnswer { return [] }
        return Set(stored.split(separator: ",").map { AISubscription(rawValue: String($0)) ?? .other })
    }

    static func encode(_ answer: Set<AISubscription>?) -> String {
        guard let answer else { return "" }
        if answer.isEmpty { return noneAnswer }
        return allCases.filter(answer.contains).map(\.rawValue).joined(separator: ",")
    }

    /// Which of these an AI app is, from the name it registered with the
    /// hosted connector ("Claude", "ChatGPT", "Grok", "Claude Code (foreverlm)").
    /// Claude Code runs on a Claude plan and Codex on a ChatGPT one, so they
    /// count for those. ForeverLM's own clients are nobody's AI app.
    static func matching(clientName: String) -> AISubscription? {
        let name = clientName.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("foreverlm") { return nil }
        if name.hasPrefix("claude") { return .claude }
        if name.hasPrefix("chatgpt") || name.hasPrefix("codex") || name.hasPrefix("openai") { return .chatGPT }
        if name.hasPrefix("grok") || name.hasPrefix("xai") { return .grok }
        if name.hasPrefix("gemini") || name.hasPrefix("google") { return .gemini }
        return .other
    }

    /// The walkthrough clip of these steps in WelcomeClipsResources; the row
    /// plays it when the folder carries it.
    var walkthroughClip: String { "connector-\(rawValue)" }
}

/// The AI apps connected to this account's hosted connector, as the gateway's
/// `/assistants` lists them, so the setup plan can tick each app off once the
/// learner has added ForeverLM to it. Nil when that cannot be read (signed
/// out, offline), which the plan shows as unknown rather than "not connected".
enum ConnectedAssistants {
    static func fetch() async -> Set<AISubscription>? {
        guard let token = ManagedAI.requestSessionToken,
              let url = URL(string: "https://plugin.\(MCPBrandDomains.current)/assistants") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let reply = try? await URLSession.shared.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: reply.0)) as? [String: Any],
              let rows = object["assistants"] as? [[String: Any]] else { return nil }
        return Set(rows.compactMap { ($0["name"] as? String).flatMap(AISubscription.matching(clientName:)) })
    }
}

/// Full Disk Access, which Apple Podcasts and the browsers' Reading Lists
/// need. Setup asks for it once; the sidebar's access card asks again when a
/// scan is blocked.
enum FullDiskAccess {
    /// Whether this process can read files only Full Disk Access opens. The
    /// TCC databases are protected by nothing else and never raise a prompt,
    /// unlike the Podcasts group container, whose "access data from other
    /// apps" dialog discovery must never provoke.
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for path in probes {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
        }
        return false
    }

    /// System Settings on the Full Disk Access list: the Ventura+ anchor
    /// first, then the older ones.
    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// macOS evaluates Full Disk Access per process at launch, so a grant made
    /// while the app is running takes effect only after a relaunch — no rescan
    /// from the still-running process can pick it up.
    @MainActor
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "for _ in $(seq 1 150); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done; "
                + "kill -0 \(pid) 2>/dev/null || exec /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path
        ]
        try? relauncher.run()
        // The same app comes straight back, so it comes back to the same view.
        StudioWorkspaceWindowCoordinator.shared.prepareForRelaunch()
        NSApp.terminate(nil)
    }
}

/// The rail's three groups. Setup comes first because its storage and AI
/// steps gate what the source steps may do; the workspace steps only show
/// where things are.
enum GettingStartedSection: String, CaseIterable, Identifiable {
    case setup = "Setup"
    case sources = "Sources"
    case assistant = "Your AI"
    case workspace = "Workspace"

    var id: String { rawValue }

    var steps: [GettingStartedStep] {
        GettingStartedStep.onboardingOrder.filter { $0.section == self }
    }
}

/// Setup's AI step (product owner, 2026-09-25): ForeverLM's AI features run on the
/// learner's own OpenRouter key, billed by OpenRouter at cost, and a plan is
/// what lets the key run them, so the step asks for both, key first. An
/// account that can already pay another way — a comp, or balance left from
/// before top-ups were retired — goes on without them.
///
/// Free mode does not stand in for the plan (2026-09-27; it did for a day):
/// it is offered once the plan is active, for a learner who wants nothing
/// charged to the key.
enum GettingStartedAIPayment {
    static func isReady(hasOwnKey: Bool, ownKeyAllowed: Bool, canPayWithoutKey: Bool) -> Bool {
        (hasOwnKey && ownKeyAllowed) || canPayWithoutKey
    }
}

enum GettingStartedStep: Int, CaseIterable, Identifiable {
    case podcasts
    case article
    case paper
    case youtube
    case enhancements
    case storage
    case books
    case courses
    case meetings
    /// Retired with the rest of the tour on 2026-09-24, and with the Planner
    /// itself on 2026-09-30; kept for its bit, like the cases after it.
    case planner
    case memory
    case ideas
    case artifacts
    case assistants
    case subscriptions
    case fullDiskAccess
    /// Books, courses, meetings and YouTube on one screen.
    case moreSources

    var id: Int { rawValue }
    var bit: Int { 1 << rawValue }

    /// Ask for AI-balance consent before importing anything that may enqueue
    /// an LLM task. Keep the raw values stable because `bit` is synced already.
    /// Full Disk Access opens Setup, straight after the welcome
    /// (product owner, 2026-09-24): its relaunch is least in the way before
    /// anything else has been answered, and the Podcasts and Reading List
    /// steps later on find something to read.
    ///
    /// The product owner, 2026-09-24: as few screens as possible. Storage says nothing
    /// the welcome's data page cannot, so it moved there; books, courses,
    /// meetings and YouTube share `moreSources`; and the workspace tour is
    /// gone, since the arrival suggestions and each area's own empty state
    /// show where things are. Those cases stay only for their synced bits.
    ///
    /// The product owner, 2026-09-25: the subscription question comes last. Its real
    /// job is connecting ForeverLM to the AI app the learner pays for, and
    /// that connector has something to reach only once podcasts, the Reading
    /// List and papers are in.
    static let onboardingOrder: [GettingStartedStep] = [
        .fullDiskAccess, .enhancements,
        .podcasts, .article, .paper, .moreSources,
        .subscriptions,
    ]

    /// The rows `moreSources` opens, in the order it lists them.
    static let moreSourceRows: [GettingStartedStep] = [.books, .courses, .meetings, .youtube]

    var section: GettingStartedSection {
        switch self {
        case .fullDiskAccess, .storage, .enhancements: return .setup
        case .subscriptions: return .assistant
        case .podcasts, .books, .article, .paper, .courses, .meetings, .youtube, .moreSources: return .sources
        case .planner, .memory, .ideas, .artifacts, .assistants: return .workspace
        }
    }

    /// Workspace steps explain where something lives; nothing has to happen
    /// before Continue.
    var isTour: Bool { section == .workspace }

    var title: String {
        switch self {
        case .podcasts: return "Podcasts"
        case .books: return "Books"
        case .article: return "Articles"
        case .paper: return "Papers"
        case .courses: return "Courses"
        case .meetings: return "Meetings"
        case .youtube: return "YouTube"
        case .enhancements: return "AI"
        case .storage: return "Storage"
        case .planner: return "Planner"
        case .memory: return "Memory"
        case .ideas: return "Ideas"
        case .artifacts: return "Artifacts"
        case .assistants: return "Claude & ChatGPT"
        case .subscriptions: return "Subscriptions"
        case .fullDiskAccess: return "Full Disk Access"
        case .moreSources: return "More sources"
        }
    }

    var icon: String {
        switch self {
        // Every name here must be a real SF Symbol: an unknown one draws
        // nothing, which is how Podcasts once had no icon ("podcasts").
        case .podcasts: return StudioSidebarTab.podcasts.icon
        case .books: return "book.closed"
        case .article: return "globe"
        case .paper: return "doc.text.magnifyingglass"
        case .courses: return "graduationcap"
        case .meetings: return "person.2.wave.2"
        case .youtube: return "play.rectangle.fill"
        case .enhancements: return "sparkles"
        case .storage: return "icloud"
        case .planner: return "calendar.day.timeline.left"
        case .memory: return StudioRailItem.memory.systemImage
        case .ideas: return "lightbulb"
        case .artifacts: return "square.grid.2x2"
        case .assistants: return "point.3.connected.trianglepath.dotted"
        case .subscriptions: return "bubble.left.and.bubble.right"
        case .fullDiskAccess: return "lock.shield"
        case .moreSources: return "square.stack.3d.up"
        }
    }
}

extension Notification.Name {
    /// Posted by the app menu's "Set Up ForeverLM…" item; the active Studio
    /// window reopens the Getting Started guide. Closing the guide with
    /// "Continue later" used to be final, with no way back to it.
    static let showGettingStarted = Notification.Name("showGettingStarted")
}

/// Real-data setup shown inside the normal Studio. Every step performs the same
/// action the learner will use later; there is no sample library or sandbox.
struct GettingStartedGuide: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(ManagedAIAccountModel.self) private var account
    @Binding var isPresented: Bool

    @SyncedStorage("gettingStarted.completed") private var isCompleted = false
    @SyncedStorage("gettingStarted.dismissed") private var isDismissed = false
    @SyncedStorage("gettingStarted.completedSteps") private var completedSteps = 0
    /// Set by the welcome's Get Started. The first step's Relaunch comes back
    /// with no step done yet, and must land on that step, not replay the
    /// story. Kept on this Mac: the relaunch it bridges is this Mac's.
    @SyncedStorage("gettingStarted.welcomeSeen") private var welcomeSeen = false
    @SyncedStorage(GetStartedSuggestions.armedKey) private var arrivalSuggestionsArmed = false
    @SyncedStorage("aiBackground.usageConsented") private var hasConsentedToBackgroundAIUsage = false
    /// False while background work is on a free model OpenRouter has not been
    /// seen to allow: the AI step waits for the learner to allow free models,
    /// or to pick the paid one.
    @State private var backgroundModelReady = true
    @SyncedStorage(AIFreeMode.enabledKey) private var freeModeOn = false
    @State private var confirmingFreeMode = false
    @State private var freeModeWorking = false
    @State private var freeModeError: String?
    @SyncedStorage(AISubscription.storageKey) private var aiSubscriptionAnswer = ""
    @SyncedStorage(StudioViewModel.youtubeLikedTranscriptFormattingKey)
    private var automaticallyFormatLikedVideoTranscripts = false

    @State private var step: GettingStartedStep = .enhancements
    /// Nil until the learner moves off or back to the welcome; until then a
    /// fresh guide shows it and a reopened one does not.
    @State private var welcomeOverride: Bool?
    @State private var workingAction: String?
    @State private var youtubeItems: [YouTubePlaylistItem] = []
    @State private var youtubeError: String?
    @State private var isYouTubeSignedIn = YouTubeService.shared.isSignedIn
    @State private var isLoadingYouTubePreview = false
    @State private var hasLoadedYouTubePreview = false
    @State private var showYouTubeSourceChoice = false
    @State private var isChoosingLikedVideos = false
    @State private var readingListBrowser: ReadingListBrowser = .safari
    @State private var enabledReadingListBrowsers = ReadingListBrowser.enabled
    @State private var isFileDropTargeted = false
    @State private var fileImportError: String?
    @State private var oneTimeImportResults: [String: String] = [:]
    @State private var oneTimeImportErrors: [String: String] = [:]
    @State private var appleBooks: AppleBooksLibrary.Scan?
    @State private var selectedAppleBooks: Set<String> = []
    @State private var playlistLink = ""
    @State private var meetingLink = ""
    @State private var videoLink = ""
    @State private var linkError: String?
    @State private var linkErrorAction: String?
    @State private var copiedConnectorURL = false
    /// The connector plan's open row, once the learner picks one; until then
    /// the first app not yet connected is open.
    @State private var connectorAssistant: AISubscription?
    /// The AI apps this account has connected, from the gateway; nil until read.
    @State private var connectedAssistants: Set<AISubscription>?
    @State private var zoomFolder = StudioViewModel.zoomLocalTranscriptCustomFolder
    @State private var ownKeyDraft = ""
    @State private var ownKeySaving = false
    /// Read at launch and whenever ForeverLM becomes active again, as it does
    /// on the way back from System Settings.
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted
    /// The row open on the More sources step, if any.
    @State private var openMoreSource: GettingStartedStep?
    /// Shows found in Apple Podcasts by the Podcasts step, nil until read.
    @State private var podcastInventoryCount: Int?

    private let exampleArticleURL = URL(string: "https://en.wikipedia.org/wiki/Feynman_Technique")!
    private let examplePaperURL = URL(string: "https://arxiv.org/abs/1706.03762")!
    private let exampleVideoURL = URL(string: "https://www.youtube.com/watch?v=5MgBikgcWnY")!

    var body: some View {
        ZStack {
            // Setup stands in for the app rather than floating over it: the
            // Studio appears only once the learner is through (product owner,
            // 2026-09-22), and then with suggestions for what to do first.
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
                .onTapGesture { }

            Group {
                if isShowingWelcome {
                    welcome
                        .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        header
                        stepContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        Divider()
                        footer
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: 760, height: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.25), radius: 28, y: 12)
        }
        .transition(.opacity)
        .task {
            if !enabledReadingListBrowsers.contains(readingListBrowser),
               let chosen = ReadingListBrowser.allCases.first(where: enabledReadingListBrowsers.contains) {
                readingListBrowser = chosen
            }
            step = firstIncompleteStep
            await prepareCurrentStep()
        }
        .onChange(of: step) { _, newStep in
            startSourceAutoSync(for: newStep)
            Task {
                if newStep == .youtube {
                    await loadYouTubePreview()
                } else if newStep == .enhancements {
                    await account.reloadOwnKey()
                    await account.refresh(silently: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
            guard step == .enhancements else { return }
            Task { await account.refresh(minimumInterval: 2, silently: true) }
        }
    }

    /// The first thing a new learner sees: a day's worth of reading, listening
    /// and watching, the question of how much of it stays, and the mark as the
    /// answer, then what ForeverLM does about it. The steps follow in order
    /// with no rail to jump around, so the guide reads as one walk-through
    /// rather than a settings list (product owner, 2026-09-22). Coming Back from the
    /// first step lands on the last page rather than replaying the story.
    private var welcome: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                closeButton
            }
            .padding(20)

            WelcomeStory(startsAtEnd: welcomeOverride == true) {
                welcomeSeen = true
                withAnimation(.easeInOut(duration: 0.25)) { welcomeOverride = false }
            }
        }
    }

    /// The bar and the ×. Progress was told three ways until 2026-10-06 — the
    /// section's name in capitals, "3 of 7" and the bar — and the bar alone
    /// says it (product owner, 2026-10-06: "fewer buttons and bells and whistles").
    private var header: some View {
        HStack(spacing: 12) {
            progressBar
            closeButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// One segment per step, so the learner sees how far there is to go and
    /// which steps they have already done.
    private var progressBar: some View {
        HStack(spacing: 4) {
            ForEach(GettingStartedStep.onboardingOrder) { candidate in
                Capsule()
                    .fill(
                        candidate == step || isComplete(candidate)
                            ? Color.accentColor
                            : Color.primary.opacity(0.12)
                    )
                    .opacity(candidate == step || !isComplete(candidate) ? 1 : 0.45)
                    .frame(height: 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(stepPosition ?? 1) of \(GettingStartedStep.onboardingOrder.count)")
    }

    private var closeButton: some View {
        Button {
            isDismissed = true
            isPresented = false
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.hoverWash(in: Circle()))
        .help("Continue later")
        .accessibilityLabel("Continue later")
    }

    private var stepPosition: Int? {
        GettingStartedStep.onboardingOrder.firstIndex(of: step).map { $0 + 1 }
    }

    /// A fresh guide opens on the welcome; one reopened after the welcome or
    /// some steps goes straight back to where the learner left off.
    private var isShowingWelcome: Bool {
        welcomeOverride ?? (completedSteps == 0 && !welcomeSeen)
    }

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch step {
                case .podcasts: podcastStep
                case .books: booksStep
                case .article: articleStep
                case .paper: paperStep
                case .courses: coursesStep
                case .meetings: meetingsStep
                case .youtube: youtubeStep
                case .enhancements: enhancementsStep
                case .subscriptions: subscriptionsStep
                case .fullDiskAccess: fullDiskAccessStep
                case .moreSources: moreSourcesStep
                // No longer in `onboardingOrder`; kept for their synced bits.
                case .storage, .planner, .memory, .ideas, .artifacts, .assistants: EmptyView()
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    /// The product owner, 2026-09-24: the learner chooses which shows to keep, hide or
    /// leave out before anything is imported. The import itself starts when
    /// they move on (`completeAndAdvance`), so a show turned away is never
    /// fetched or cleaned up.
    private var podcastStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: GettingStartedStep.podcasts.icon,
                title: "Choose your podcasts",
                detail: "Episodes you play in Apple Podcasts arrive here with their transcripts. Choose which shows to keep before anything comes in."
            )

            if vm.needsPodcastAccess || !hasFullDiskAccess {
                accessNotice("Full Disk Access is needed to read Apple Podcasts. macOS does not list ForeverLM until you add it with the \"+\" button — add it, turn it on, then relaunch ForeverLM.")
                Button("Enable Access") { openFullDiskAccessSettings() }
            }

            PodcastShowChooser(showCount: $podcastInventoryCount)

            Button("Open Apple Podcasts") { open(URL(string: "podcasts://")!) }
        }
    }

    /// The product owner, 2026-09-24: setting up the Reading List is the step, not
    /// waiting for a first save. How much of the backlog to bring comes
    /// first, then the browsers; a read-later app's library can come over too.
    private var articleStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: "globe",
                title: "Set up your Reading List",
                detail: "ForeverLM reads the Reading List in Safari, Chrome and Brave, so a page you save there arrives here. It is free and already in your browser."
            )
            ReadingListSetupCard(isEnabled: readingListBrowserBinding)
            if vm.needsBrowserAccess {
                accessNotice("Add ForeverLM to Full Disk Access with the \"+\" button — macOS does not list it until you do — turn it on, then relaunch the app.")
            }
            if !enabledReadingListBrowsers.isEmpty {
                readingListBrowserPicker
                readingListInstructions
                HStack {
                    Button("Open Example in \(readingListBrowser.title)") {
                        openInReadingListBrowser(exampleArticleURL)
                    }
                    Button("Check Reading Lists") {
                        run("article") { await vm.refreshTab(.articles) }
                    }
                    actionProgress("article")
                }
            }
            SourceCleanupProgress(types: [.article], task: .paperNarrationPreparation)
            readLaterImport
        }
    }

    /// The product owner, 2026-09-24: papers come over from the reference manager they
    /// live in. Zotero is found on this Mac and imported in one click; any
    /// other manager's export, dropped PDFs and Reading List saves work too.
    private var paperStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: "doc.text.magnifyingglass",
                title: "Bring your papers",
                detail: "Bring your library over from your reference manager, or drop PDFs. ForeverLM finds each PDF and its metadata, then cleans up the text so it reads well and quotes correctly."
            )
            ZoteroImportCard()
            referenceManagerImport
            fileDropZone(
                "Drop PDFs here",
                icon: "arrow.down.doc",
                types: [.pdf],
                chooseTitle: "Choose PDFs…"
            ) { url in
                _ = try await vm.importPDF(from: url.path, selectInReader: false)
            }
            readingListPapersNote
            SourceCleanupProgress(types: [.paper], task: .paperNarrationPreparation)
            if let paper = newestPaper {
                VStack(alignment: .leading, spacing: 10) {
                    detectedSourceCard(paper, label: "Latest paper")
                    ingestionStage("PDF located", done: paper.localFilePath != nil)
                    ingestionStage("Metadata extracted", done: paper.author?.isEmpty == false || paper.journal?.isEmpty == false)
                    ingestionStage("Full text ready", done: paper.state == .ready)
                    if paper.state == .error, let error = paper.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .setupCard()
            }
        }
    }

    /// The Reading List was set up in the Articles step; a paper saved there
    /// arrives the same way, so this step only says so.
    @ViewBuilder
    private var readingListPapersNote: some View {
        let browsers = ReadingListBrowser.allCases.filter(enabledReadingListBrowsers.contains)
        if browsers.isEmpty {
            Label("Turn on a Reading List in the Articles step to save papers from your browser too.", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Label("Papers you save to your Reading List in \(browsers.map(\.title).joined(separator: " or ")) arrive here too.", systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Example") { openInReadingListBrowser(examplePaperURL) }
                    .controlSize(.small)
            }
        }
    }

    /// A one-time move out of a reference manager, not a connector: the papers
    /// are copied into the library once and nothing keeps watching Zotero,
    /// Paperpile or Mendeley afterwards (docs-site/papers.md says why).
    private var referenceManagerImport: some View {
        oneTimeImportCard(
            title: "Coming from a reference manager?",
            icon: "books.vertical",
            detail: "Bring your papers over once. ForeverLM copies them into your library and never changes the original.",
            hints: [
                ("Zotero", "choose the Zotero folder in your home folder, the one holding zotero.sqlite."),
                ("Paperpile", "export BibTeX into the Paperpile folder Google Drive syncs, then choose that folder."),
                ("Mendeley", "export your library as BibTeX and choose the file. Papers without a PDF are fetched by DOI."),
                ("EndNote, JabRef, ReadCube", "export BibTeX or RIS, or choose a folder of PDFs.")
            ],
            action: "reference-library",
            isImporting: vm.isImportingReferenceLibrary,
            status: vm.referenceLibraryImportStatus
        ) {
            importOnce("reference-library", types: Self.referenceLibraryContentTypes,
                       message: "Choose a Zotero folder, a BibTeX or RIS export, or a folder of PDFs") { urls in
                try await vm.importReferenceLibrary(from: urls).summaryAndWarnings
            }
        }
    }

    /// The same one-time move for articles: a read-later app's export, read
    /// once. Nothing keeps syncing with the app afterwards.
    private var readLaterImport: some View {
        oneTimeImportCard(
            title: "Coming from a read-later app?",
            icon: "tray.and.arrow.down",
            detail: "Bring your saved articles over once from the app's export. The app itself is never changed.",
            hints: [
                ("Readwise Reader", "Settings › Export, then choose the CSV."),
                ("Instapaper", "Settings › Export, then choose the CSV or HTML file."),
                ("Raindrop", "Settings › Backups, then choose the CSV or HTML file."),
                ("Pocket, Omnivore, others", "choose the export file, or the unzipped export folder.")
            ],
            action: "read-later",
            isImporting: vm.isImportingReadLaterExport,
            status: vm.readLaterImportStatus
        ) {
            importOnce("read-later", types: Self.readLaterContentTypes,
                       message: "Choose the CSV, HTML or JSON export, or its unzipped folder") { urls in
                let report = try await vm.importReadLaterExport(from: urls)
                return (report.summary, report.warnings)
            }
        }
    }

    private func oneTimeImportCard(
        title: String,
        icon: String,
        detail: String,
        hints: [(String, String)],
        action: String,
        isImporting: Bool,
        status: String?,
        choose: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                Button("Choose Export…", action: choose)
                    .disabled(workingAction != nil || isImporting)
                actionProgress(action)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hints.indices, id: \.self) { index in
                    Text("**\(hints[index].0)**: \(hints[index].1)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isImporting, let status {
                Label(status, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let summary = oneTimeImportResults[action] {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let error = oneTimeImportErrors[action] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .setupCard()
    }

    private func importOnce(
        _ action: String,
        types: [UTType],
        message: String,
        importing: @escaping @MainActor ([URL]) async throws -> (summary: String, warnings: [String])
    ) {
        Task { @MainActor in
            let urls = await FilePanel.open { panel in
                panel.allowedContentTypes = types
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.message = message
            }
            guard !urls.isEmpty else { return }
            run(action) {
                oneTimeImportResults[action] = nil
                oneTimeImportErrors[action] = nil
                do {
                    let report = try await importing(urls)
                    oneTimeImportResults[action] = report.summary
                    if !report.warnings.isEmpty {
                        let shown = report.warnings.prefix(3).joined(separator: "\n")
                        let more = report.warnings.count > 3 ? "\n…and \(report.warnings.count - 3) more" : ""
                        oneTimeImportErrors[action] = shown + more
                    }
                } catch is CancellationError {
                } catch {
                    oneTimeImportErrors[action] = error.localizedDescription
                }
            }
        }
    }

    private static let readLaterContentTypes: [UTType] = [
        .folder, .commaSeparatedText, .html, .json, .plainText
    ]

    private static let referenceLibraryContentTypes: [UTType] = [
        .folder, .pdf,
        UTType(filenameExtension: "bib"),
        UTType(filenameExtension: "bibtex"),
        UTType(filenameExtension: "ris"),
        UTType(filenameExtension: "sqlite")
    ].compactMap { $0 }

    private var youtubeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: "play.rectangle.fill",
                title: "Import from YouTube",
                detail: "Connect YouTube to bring in the videos you like, or a playlist named ForeverLM. Any single video can be added by its link."
            )

            if !isYouTubeSignedIn {
                Button {
                    run("youtube-connect") { await connectYouTube() }
                } label: {
                    Label("Connect YouTube", systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!YouTubeService.shared.canConnect || workingAction != nil)
                actionProgress("youtube-connect")
            } else {
                Label("YouTube connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                if (vm.youtubeImportSource == nil && !isChoosingLikedVideos)
                    || showYouTubeSourceChoice {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Import from")
                            .font(.headline)
                        HStack {
                            Button("Liked Videos") {
                                showYouTubeSourceChoice = false
                                isChoosingLikedVideos = true
                            }
                            Button("ForeverLM Playlist") {
                                showYouTubeSourceChoice = false
                                isChoosingLikedVideos = false
                                configureForeverLMPlaylist()
                            }
                            .buttonStyle(.borderedProminent)
                            RecommendedBadge()
                            actionProgress("youtube-source")
                        }
                        .disabled(workingAction != nil)
                        Text("Only the videos you save to learn from come in, not everything you have ever liked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .setupCard()
                } else if let source = vm.youtubeImportSource {
                    HStack {
                        Label(source.displayName, systemImage: source.iconName)
                        Spacer()
                        Button("Change") {
                            showYouTubeSourceChoice = true
                            isChoosingLikedVideos = false
                        }
                        .controlSize(.small)
                    }
                    .setupCard()
                }

                if isChoosingLikedVideos
                    || (vm.youtubeImportSource == .likedVideos && vm.youtubeLikedImportPolicy == .undecided) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Import your existing liked videos?")
                            .font(.headline)
                        Text("Nothing is imported until you choose.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Toggle(
                            "Format transcripts with AI",
                            isOn: $automaticallyFormatLikedVideoTranscripts
                        )
                        Text("This can spend a lot on AI for a large history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Import Existing Likes") { configureYouTube(.importExisting) }
                            Button("Only Future Likes") { configureYouTube(.futureOnly) }
                                .buttonStyle(.borderedProminent)
                            RecommendedBadge()
                            actionProgress("youtube-policy")
                        }
                        .disabled(workingAction != nil)
                        Text("Your library starts with what you like from now on, not years of old likes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .setupCard()
                }

                if !youtubeChannels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose channels to show")
                            .font(.headline)
                        ForEach(youtubeChannels, id: \.self) { channel in
                            Toggle(isOn: youtubeChannelVisibilityBinding(channel)) {
                                Text(channel).lineLimit(1)
                            }
                            .toggleStyle(.switch)
                        }
                    }
                    .setupCard()
                }

                if vm.youtubeImportSource != nil {
                    HStack {
                        Button("Open Example Video") { open(exampleVideoURL) }
                        Button("Check YouTube") {
                            run("youtube-refresh") { await vm.refreshYouTubeVideosOnSidebarRefresh() }
                        }
                        .buttonStyle(.borderedProminent)
                        actionProgress("youtube-refresh")
                    }
                }

                if let video = newestYouTubeVideo {
                    detectedSourceCard(video, label: "YouTube video found")
                } else if let source = vm.youtubeImportSource {
                    waitingCard(
                        source == .likedVideos
                            ? "Like a video on YouTube, then check again"
                            : "Add a video to ForeverLM, then check again",
                        icon: source.iconName
                    )
                }
            }

            linkField(
                "Or paste any YouTube link",
                text: $videoLink,
                buttonTitle: "Add Video",
                action: "video-link"
            ) { link in
                try await vm.addArticle(url: link, revealInReader: false)
            }

            if let youtubeError {
                Label(youtubeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var booksStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: "book.closed",
                title: "Add your books",
                detail: "Drop any EPUB or PDF here, or bring in the books you already keep in Apple Books. ForeverLM splits each one into chapters."
            )
            fileDropZone(
                "Drop EPUBs or PDFs here",
                icon: "arrow.down.doc",
                types: supportedBookImportContentTypes,
                chooseTitle: "Choose Books…"
            ) { url in
                try await vm.importBook(from: url.path)
            }
            appleBooksImport
            if !vm.bookImportStatus.isEmpty {
                Label(vm.bookImportStatus, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let book = newestSource(of: .book) {
                detectedSourceCard(book, label: "Book added")
            }
        }
    }

    @ViewBuilder
    private var appleBooksImport: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Apple Books", systemImage: "books.vertical")
                    .font(.headline)
                Spacer()
                Button("Open Apple Books") { openAppleBooks() }
                Button(appleBooks == nil ? "Find My Books" : "Look Again") {
                    run("apple-books-scan") {
                        let scan = await Task.detached(priority: .userInitiated) {
                            AppleBooksLibrary.scan()
                        }.value
                        appleBooks = scan
                        selectedAppleBooks = Set(scan.books.map(\.path))
                    }
                }
                actionProgress("apple-books-scan")
            }
            if let appleBooks {
                if appleBooks.books.isEmpty {
                    Text(appleBooks.cloudOnlyCount > 0
                        ? "Your Apple Books are still in iCloud. Open one in Apple Books to download it, then look again."
                        : "No EPUB or PDF books found in Apple Books. Books bought in the Book Store are protected and cannot be imported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(appleBooks.books) { book in
                        Toggle(isOn: appleBookSelectionBinding(book.path)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(book.title).lineLimit(1)
                                if let author = book.author {
                                    Text(author)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    if appleBooks.cloudOnlyCount > 0 {
                        Text("\(appleBooks.cloudOnlyCount) more are still in iCloud. Open them in Apple Books to download them first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Import \(selectedAppleBooks.count == 1 ? "1 Book" : "\(selectedAppleBooks.count) Books")") {
                            importSelectedAppleBooks()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedAppleBooks.isEmpty || workingAction != nil)
                        actionProgress("apple-books-import")
                    }
                }
            }
        }
        .setupCard()
    }

    // MARK: More sources

    /// Books, courses, meetings and YouTube on one screen (product owner,
    /// 2026-09-24: fewer screens). Each is a row that opens its own setup in
    /// place, without its heading; nothing has to be opened, and each one can
    /// be set up later from its place in the sidebar.
    private var moreSourcesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: GettingStartedStep.moreSources.icon,
                title: "Anything else you learn from?",
                detail: "Open any you use to set it up now, and leave the rest. Each one can also be set up later from its place in the sidebar."
            )
            VStack(spacing: 10) {
                ForEach(GettingStartedStep.moreSourceRows) { source in
                    moreSourceRow(source)
                }
            }
        }
    }

    private func moreSourceRow(_ source: GettingStartedStep) -> some View {
        let isOpen = openMoreSource == source
        return VStack(alignment: .leading, spacing: 16) {
            Button {
                toggleMoreSource(source)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: source.icon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.title)
                            .font(.headline)
                        Text(moreSourceHint(source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hasAddedMoreSource(source) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Set up")
                    }
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                moreSourceContent(source)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .setupCard()
    }

    @ViewBuilder
    private func moreSourceContent(_ source: GettingStartedStep) -> some View {
        Group {
            switch source {
            case .books: booksStep
            case .courses: coursesStep
            case .meetings: meetingsStep
            case .youtube: youtubeStep
            default: EmptyView()
            }
        }
        // The row already says what it is.
        .environment(\.setupStepHeadingHidden, true)
    }

    private func moreSourceHint(_ source: GettingStartedStep) -> String {
        switch source {
        case .books: return "EPUBs, PDFs and your Apple Books library"
        case .courses: return "A YouTube lecture series, one lecture per video"
        case .meetings: return "Zoom and other meeting transcripts"
        case .youtube: return "The videos you like, or a playlist named ForeverLM"
        default: return ""
        }
    }

    /// What the four steps used to wait for before Continue.
    private func hasAddedMoreSource(_ source: GettingStartedStep) -> Bool {
        switch source {
        case .books: return newestSource(of: .book) != nil
        case .courses: return newestCourseLecture != nil
        case .meetings: return newestSource(of: .meeting) != nil || zoomFolder != nil
        case .youtube:
            return (vm.youtubeImportSource != nil && newestYouTubeVideo != nil)
                || newestSource(of: .video) != nil
        default: return false
        }
    }

    /// Opening a row does what arriving on its old step did: start the Zoom
    /// watcher, or load the YouTube preview.
    private func toggleMoreSource(_ source: GettingStartedStep) {
        let opening = openMoreSource != source
        withAnimation(.easeInOut(duration: 0.2)) { openMoreSource = opening ? source : nil }
        guard opening else { return }
        startSourceAutoSync(for: source)
        if source == .youtube {
            Task { await loadYouTubePreview() }
        }
    }

    private var coursesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: "graduationcap",
                title: "Turn a YouTube playlist into a course",
                detail: "Paste the link of a lecture series on YouTube. Each video becomes a lecture, with its transcript, in order."
            )
            linkField(
                "YouTube playlist link",
                text: $playlistLink,
                buttonTitle: "Add Course",
                action: "course"
            ) { link in
                await vm.importYouTubePlaylist(url: link)
            }
            if let status = vm.playlistImportStatus {
                Label(status, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let course = newestCourseLecture {
                detectedSourceCard(course, label: "Course added")
            } else {
                waitingCard("Waiting for a course", icon: "graduationcap")
            }
        }
    }

    private var meetingsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: "person.2.wave.2",
                title: "Bring in your meetings",
                detail: "Connect your meeting tools once, and every transcript arrives on its own."
            )
            VStack(alignment: .leading, spacing: 8) {
                Label("Zoom", systemImage: "video")
                    .font(.headline)
                Text("Zoom saves its recordings to a folder on this Mac. ForeverLM watches that folder and adds each meeting's transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(zoomFolderDisplayPath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose Folder…") { chooseZoomFolder() }
                }
            }
            .setupCard()
            VStack(alignment: .leading, spacing: 8) {
                Label("More connectors", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Text("Google Drive, Google Calendar, Slack, Notion and others live in Settings › Plugins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Plugins") { openSettings(.plugins) }
            }
            .setupCard()
            linkField(
                "Or paste a Zoom recording link",
                text: $meetingLink,
                buttonTitle: "Add Meeting",
                action: "meeting-link"
            ) { link in
                try await vm.addArticle(url: link, revealInReader: false)
            }
            if let meeting = newestSource(of: .meeting) {
                detectedSourceCard(meeting, label: "Meeting added")
            }
        }
    }

    /// What the learner said they pay for; nil until the question is answered,
    /// empty for "no".
    private var aiSubscriptions: Set<AISubscription>? {
        AISubscription.decode(aiSubscriptionAnswer)
    }

    private var paysForAISubscription: Bool {
        aiSubscriptions.map { !$0.isEmpty } ?? false
    }

    /// The product owner, 2026-09-23: ask whether the learner already pays for an AI
    /// app. The answer leads straight into connecting each app ticked
    /// (2026-09-24), which is why it closes Setup: by then the library holds
    /// what the connector reaches. Any number may be ticked; "No" clears them.
    private var subscriptionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: GettingStartedStep.subscriptions.icon,
                title: "Do you already pay for an AI subscription?",
                detail: "Reach everything you just brought in from the AI app you already use, on the subscription you already have."
            )
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ForEach(AISubscription.allCases) { subscription in
                    subscriptionChoice(subscription)
                }
                subscriptionChoice(nil)
            }
            if let picks = aiSubscriptions, !picks.isEmpty {
                connectorPlan(AISubscription.allCases.filter(picks.contains))
                    .padding(.top, 8)
            }
            // The product owner, 2026-09-24: show the connector at work in an AI app,
            // so "works inside the AI app you already use" is seen, not read.
            // Once an app is ticked, its connect plan takes this space.
            if !paysForAISubscription, let url = WelcomeClipPlayer.url(named: Self.connectorClip) {
                VStack(spacing: 8) {
                    WelcomeClipPlayer(url: url)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .frame(maxWidth: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.primary.opacity(0.1))
                        }
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        .accessibilityHidden(true)
                    Text("Codex reaching your papers and podcasts, on a ChatGPT subscription")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
    }

    /// Codex asking the ForeverLM connector what papers and podcasts the
    /// library holds; the step shows it when WelcomeClipsResources carries it.
    private static let connectorClip = "setup-codex-library"

    /// One tile of the question; nil is "No".
    private func subscriptionChoice(_ subscription: AISubscription?) -> some View {
        let isSelected = subscription.map { aiSubscriptions?.contains($0) == true }
            ?? (aiSubscriptions?.isEmpty == true)
        return Button {
            toggleSubscription(subscription)
        } label: {
            HStack(spacing: 10) {
                subscriptionMark(subscription)
                    .frame(width: 22, height: 22)
                Text(subscription?.title ?? "No")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 10, inset: 0))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func subscriptionMark(_ subscription: AISubscription?) -> some View {
        if let subscription, let logo = subscription.logoAssetName {
            Image(logo)
                .resizable()
                .renderingMode(subscription.usesTemplateLogo ? .template : .original)
                .scaledToFit()
                .foregroundStyle(.primary)
        } else {
            Image(systemName: subscription == nil ? "xmark.circle" : "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func toggleSubscription(_ subscription: AISubscription?) {
        let current = aiSubscriptions
        let next: Set<AISubscription>?
        if let subscription {
            var picks = current ?? []
            if picks.contains(subscription) { picks.remove(subscription) } else { picks.insert(subscription) }
            // Unticking the last one leaves the question unanswered, not "no".
            next = picks.isEmpty ? nil : picks
        } else {
            next = current?.isEmpty == true ? nil : []
        }
        aiSubscriptionAnswer = AISubscription.encode(next)
        connectorAssistant = nil
    }

    // MARK: Connector plan

    /// The product owner, 2026-09-24: saying which AI apps you pay for leads straight
    /// to connecting them. One row per app says whether it is connected yet
    /// (the gateway knows once the app has signed in), and the open row
    /// carries that app's steps, the address, the page to do it on and, when
    /// WelcomeClipsResources has one, a clip of the steps being done.
    private func connectorPlan(_ choices: [AISubscription]) -> some View {
        let open = openConnectorRow(in: choices)
        let connectedCount = choices.filter { connectedAssistants?.contains($0) == true }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connect ForeverLM")
                    .font(.headline)
                Spacer()
                if connectedAssistants != nil {
                    Text("\(connectedCount) of \(choices.count) connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ForEach(choices) { assistant in
                connectorPlanRow(assistant, isOpen: assistant == open)
            }
        }
        .task { await watchConnectedAssistants() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Connecting happens in the browser; see it on the way back.
            Task { if let latest = await ConnectedAssistants.fetch() { connectedAssistants = latest } }
        }
    }

    /// The row the learner opened, else the first app not yet connected; with
    /// every app connected, none.
    private func openConnectorRow(in choices: [AISubscription]) -> AISubscription? {
        if let connectorAssistant, choices.contains(connectorAssistant) { return connectorAssistant }
        return choices.first { connectedAssistants?.contains($0) != true }
    }

    private func connectorPlanRow(_ assistant: AISubscription, isOpen: Bool) -> some View {
        let isConnected = connectedAssistants?.contains(assistant) == true
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                connectorAssistant = assistant
            } label: {
                HStack(spacing: 10) {
                    subscriptionMark(assistant)
                        .frame(width: 20, height: 20)
                    Text(assistant == .other ? "Add ForeverLM to your AI app" : "Add ForeverLM to \(assistant.title)")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    } else if connectedAssistants != nil {
                        Text("Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: -6))
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(assistant.connectorSteps.enumerated()), id: \.offset) { index, text in
                        instruction("\(index + 1)", text)
                    }
                    HStack {
                        Text(Self.connectorURL)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button(copiedConnectorURL ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.connectorURL, forType: .string)
                            copiedConnectorURL = true
                        }
                    }
                    .padding(.top, 4)
                    if let note = assistant.connectorNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let url = WelcomeClipPlayer.url(named: assistant.walkthroughClip) {
                        WelcomeClipPlayer(url: url)
                            .aspectRatio(16.0 / 10.0, contentMode: .fit)
                            .frame(maxWidth: 440)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.1))
                            }
                            .accessibilityHidden(true)
                            // A new clip per app, not the last one's player.
                            .id(assistant)
                    }
                    HStack(spacing: 12) {
                        if let page = assistant.connectorPage {
                            Button(page.title) { open(page.url) }
                                .buttonStyle(.borderedProminent)
                        }
                        if !isConnected, connectedAssistants != nil {
                            ProgressView().controlSize(.small)
                            Text(assistant == .other ? "Waiting for your AI app" : "Waiting for \(assistant.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .setupCard()
    }

    /// Re-read while the plan is on screen: the learner connects in another
    /// app, and the row should turn green without anyone pressing anything.
    private func watchConnectedAssistants() async {
        while !Task.isCancelled {
            if let latest = await ConnectedAssistants.fetch() { connectedAssistants = latest }
            try? await Task.sleep(for: .seconds(8))
        }
    }

    /// The product owner, 2026-09-24: ask for Full Disk Access during setup rather than
    /// only when a Podcasts or Reading List scan is found blocked. macOS never
    /// lists ForeverLM there on its own, and applies the grant only at launch,
    /// so the step walks through the "+" button and the relaunch, and setup
    /// comes back to it afterwards. It can be skipped: only Apple Podcasts and
    /// the Reading Lists need it.
    private var fullDiskAccessStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: GettingStartedStep.fullDiskAccess.icon,
                title: "Let ForeverLM read Apple Podcasts and your Reading Lists",
                detail: "The episodes you play in Apple Podcasts and the pages you save in Safari, Chrome or Brave are kept in files macOS guards with Full Disk Access. ForeverLM only reads them."
            )

            if hasFullDiskAccess {
                Label("Full Disk Access is on. Podcasts and Reading Lists arrive on their own from here.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .setupCard()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    instruction("1", "Click Open Settings. It opens Privacy & Security › Full Disk Access.")
                    instruction("2", isDevelopmentBuild
                        ? "Click \"+\" under the list, choose this exact \(ForeverLMRuntimeIdentity.displayName) app (Reveal App shows it) and turn it on."
                        : "Click \"+\" under the list, choose ForeverLM in Applications and turn it on. macOS does not list it until you add it.")
                    instruction("3", "Click Relaunch \(ForeverLMRuntimeIdentity.displayName). macOS applies the access only when the app starts, and setup comes back to this step.")
                    if isDevelopmentBuild {
                        Text(Bundle.main.bundleURL.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 27)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .setupCard()

                HStack {
                    Button {
                        FullDiskAccess.openSettings()
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        FullDiskAccess.relaunch()
                    } label: {
                        Label("Relaunch \(ForeverLMRuntimeIdentity.displayName)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if isDevelopmentBuild {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        } label: {
                            Label("Reveal App", systemImage: "folder")
                        }
                    }
                }
            }
        }
    }

    /// The First Run app reads the production steps: it stands in for a new
    /// learner, who has no Dev copy to tell apart from the installed one.
    private var isDevelopmentBuild: Bool {
        ForeverLMRuntimeIdentity.isDevelopment && !ForeverLMRuntimeIdentity.isFirstRun
    }

    /// The product owner, 2026-09-25: AI features run on the learner's own OpenRouter
    /// key, billed by OpenRouter at cost, and a ForeverLM plan is what lets the
    /// key run them. The step asks for the key, then the plan (with Free mode
    /// offered once it is active), then the models: the one new chats start
    /// on, and the one background work runs on, since that is most of what
    /// the key pays for. Background work defaults to a free model (product owner,
    /// 2026-09-26): it waits for nobody, so a busy or slower model costs it
    /// little. Pressing Continue is also the consent to background work,
    /// which that row says.
    private var enhancementsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                icon: "sparkles",
                title: "Add your OpenRouter key, choose a plan and your models",
                detail: "AI features run on your own OpenRouter API key, and OpenRouter bills you for them at cost. Right now ForeverLM supports OpenRouter. A ForeverLM plan lets your key run them. You only do this once."
            )

            aiSetupRow(title: "Your OpenRouter key", icon: "key", isDone: account.ownKey != nil) {
                ownKeySetup
            }

            aiSetupRow(title: "Your data", icon: "hand.raised", isDone: nil) {
                dataPolicySetup
            }

            aiSetupRow(title: "Your ForeverLM plan", icon: "star", isDone: account.ownKeyAllowed) {
                planAndFreeMode
            }

            aiSetupRow(title: "Recommended models", icon: "checkmark.seal", isDone: nil) {
                GettingStartedRecommendedModels()
            }

            aiSetupRow(title: "Chat", icon: "bubble.left.and.text.bubble.right", isDone: nil) {
                GettingStartedChatModelChoice()
            }

            aiSetupRow(title: "Background work", icon: "gearshape.2", isDone: backgroundModelReady) {
                GettingStartedBackgroundModelChoice(isReady: $backgroundModelReady)
            }

            if let message = account.errorMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Turn on Free mode?", isPresented: $confirmingFreeMode, titleVisibility: .visible) {
            Button("Turn On Free Mode") { turnOnFreeMode() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AIFreeMode.confirmationMessage(turnsOffDataPolicySwitch: AIDataPolicy.deniesDataCollection))
        }
    }

    /// The product owner (2026-09-27): during setup, say that the models' terms are the
    /// learner's to understand, and link OpenRouter's own setting for leaving
    /// out models that train on what is sent, then show it being changed.
    private var dataPolicySetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                Text(ManagedAI.OwnKeyRouter.openRouter.trainingNote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("gettingStarted.openRouterTraining")
                Text(AIDataPolicy.openRouterAccountNote)
                    .foregroundStyle(.secondary)
                Link("Open OpenRouter privacy settings", destination: FreeModelsSetup.openRouterPrivacyURL)
                    .accessibilityIdentifier("gettingStarted.openRouterPrivacy")
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            openRouterClip(Self.openRouterPrivacyClip)
        }
    }

    /// The plan row: the plan, then Free mode once it is active. Free mode is
    /// offered with what it leaves out said before it goes on, and again
    /// while it is on, so no one finds out when an image fails to draw.
    @ViewBuilder
    private var planAndFreeMode: some View {
        if !account.ownKeyAllowed {
            VStack(alignment: .leading, spacing: 8) {
                AppPlanPicker()
                Text("Checkout opens in your browser. Come back here once it is done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if freeModeOn {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your plan is active, and Free mode is on. ForeverLM uses only OpenRouter's free models, and nothing is charged to your OpenRouter account.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                freeModeLimits
                Button("Turn Off Free Mode") {
                    FreeModelsSetup.disableFreeMode()
                    freeModeError = nil
                }
                .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your plan is active.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)

                Divider()
                    .padding(.vertical, 4)

                Text(AIFreeMode.switchTitle)
                    .font(.subheadline.weight(.semibold))
                Text(AIFreeMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                freeModeLimits
                HStack(spacing: 8) {
                    Button("Use Free Mode…") { confirmingFreeMode = true }
                        .disabled(account.ownKey == nil || freeModeWorking)
                        .accessibilityIdentifier("gettingStarted.freeMode")
                    if freeModeWorking {
                        ProgressView().controlSize(.small)
                        Text("Choosing free models…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if account.ownKey == nil {
                        Text("Add your OpenRouter key first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let freeModeError {
                    Label(freeModeError, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What Free mode leaves out, and what its models give up.
    private var freeModeLimits: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(AIFreeMode.unavailableNote, systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
            Label("Free models' providers may keep and train on what you send, and they are often busy or rate-limited.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func turnOnFreeMode() {
        guard !freeModeWorking else { return }
        freeModeWorking = true
        freeModeError = nil
        Task { @MainActor in
            defer { freeModeWorking = false }
            do {
                try await FreeModelsSetup.enableFreeMode()
            } catch {
                freeModeError = error.localizedDescription
            }
        }
    }

    /// One of the AI step's parts, with a check once it is done. `isDone`
    /// nil is a part with nothing to finish, such as a choice that already
    /// has a default.
    private func aiSetupRow<Content: View>(
        title: String,
        icon: String,
        isDone: Bool?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: isDone == true ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isDone == true ? Color.accentColor : .secondary)
                    .opacity(isDone == nil ? 0 : 1)
                    .accessibilityHidden(isDone == nil)
                    .accessibilityLabel(isDone == true ? "Done" : "Not done")
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            content()
                .padding(.leading, 34)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    /// What OpenRouter is (the models' terms follow in "Your data"), then
    /// the key, then the credits: the credits are shown whether or not the key is in yet, since
    /// buying them is the step after it and a learner in Free mode still
    /// needs them to get past 50 free requests a day.
    private var ownKeySetup: some View {
        let router = ManagedAI.OwnKeyRouter.openRouter
        return VStack(alignment: .leading, spacing: 10) {
            Text(router.aboutNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ownKeyStatus
            Divider()
            Label(router.creditsNote, systemImage: "creditcard")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(router.creditsLinkTitle, destination: router.creditsURL)
                .font(.caption)
                .accessibilityIdentifier("gettingStarted.openRouterCredits")
            openRouterClip(Self.openRouterCreditsClip)
        }
    }

    /// The product owner (2026-09-27): the two things done on OpenRouter's own site,
    /// adding the credits and changing its privacy settings, are each shown
    /// being done in a browser, under the link that goes there. A row plays
    /// its clip when WelcomeClipsResources carries it.
    private static let openRouterCreditsClip = "setup-openrouter-credits"
    private static let openRouterPrivacyClip = "setup-openrouter-privacy"

    @ViewBuilder
    private func openRouterClip(_ name: String) -> some View {
        if let url = WelcomeClipPlayer.url(named: name) {
            WelcomeClipPlayer(url: url)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .frame(maxWidth: 440)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1))
                }
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var ownKeyStatus: some View {
        if let own = account.ownKey {
            Label("\(own.router.label) key ending in \(own.suffix)", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Signing in at OpenRouter hands the app a key; pasting one
                // stays for anyone who already has a key to hand.
                HStack(spacing: 8) {
                    Button {
                        Task { await account.connectOpenRouter() }
                    } label: {
                        if account.openRouterConnectInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Connect OpenRouter")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.openRouterConnectInFlight || ownKeySaving)
                    if account.openRouterConnectInFlight {
                        Text("Finish in your browser, then come back.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(ManagedAI.OwnKeyRouter.openRouter.accountNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    SecureField("Or paste a key", text: $ownKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveOwnKey() }
                    Button {
                        saveOwnKey()
                    } label: {
                        if ownKeySaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(ownKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownKeySaving)
                }
                Link(ManagedAI.OwnKeyRouter.openRouter.keysLinkTitle, destination: ManagedAI.OwnKeyRouter.openRouter.keysURL)
                    .font(.caption)
                Label(ManagedAI.OwnKeyRouter.openRouter.keyPrivacyNote, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveOwnKey() {
        let key = ownKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !ownKeySaving else { return }
        ownKeySaving = true
        Task { @MainActor in
            // A key OpenRouter refuses stays in the field, with the reason below.
            if await account.setOwnKey(key, router: .openRouter) { ownKeyDraft = "" }
            ownKeySaving = false
        }
    }

    private var footer: some View {
        HStack {
            if step != .enhancements, step != .storage, step != .subscriptions, step != .moreSources, !step.isTour {
                Button("Skip this step") { completeAndAdvance() }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let previous = previousStep {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) { step = previous }
                }
            } else {
                // The first step goes back to the welcome.
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.25)) { welcomeOverride = true }
                }
            }
            Button(nextIncompleteStep == nil ? "Finish" : "Continue") {
                // The AI step says background work draws on what they chose.
                if step == .enhancements { hasConsentedToBackgroundAIUsage = true }
                openDetectedSourceForCurrentStep()
                completeAndAdvance()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func readingListBrowserBinding(_ browser: ReadingListBrowser) -> Binding<Bool> {
        Binding(
            get: { enabledReadingListBrowsers.contains(browser) },
            set: { isOn in
                browser.setEnabled(isOn)
                if isOn {
                    enabledReadingListBrowsers.insert(browser)
                    readingListBrowser = browser
                } else {
                    enabledReadingListBrowsers.remove(browser)
                    if readingListBrowser == browser,
                       let other = ReadingListBrowser.allCases.first(where: enabledReadingListBrowsers.contains) {
                        readingListBrowser = other
                    }
                }
                vm.readingListBrowsersDidChange()
            }
        )
    }

    /// The instructions follow one browser; the picker appears only when more
    /// than one is chosen, since a single choice leaves nothing to pick.
    @ViewBuilder
    private var readingListBrowserPicker: some View {
        let choices = ReadingListBrowser.allCases.filter(enabledReadingListBrowsers.contains)
        if choices.count > 1 {
            Picker("Show steps for", selection: $readingListBrowser) {
                ForEach(choices) { browser in
                    Text(browser.title).tag(browser)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
        }
    }

    private var readingListInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            instruction("1", "Open the example or any article you want to learn")
            instruction("2", readingListBrowser.saveInstruction)
            instruction("3", "Return to ForeverLM and check Reading Lists")
            if let shortcut = readingListBrowser.shortcut {
                Text(shortcut)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 27)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .setupCard()
    }

    private var podcastShowNames: [String] {
        Set(vm.activeArticles.filter { $0.sourceType == .podcast }.map(\.domain))
            .union(vm.hiddenPodcastShowNames)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var newestReadingListArticle: StudioArticle? {
        vm.activeArticles
            .filter { StudioViewModel.isBrowserReadingListSource($0) && $0.sourceType == .article }
            .max(by: { $0.dateAdded < $1.dateAdded })
    }

    /// Any paper, however it arrived: a dropped PDF counts as much as a
    /// Reading List save.
    private var newestPaper: StudioArticle? {
        newestSource(of: .paper)
    }

    private func newestSource(of type: StudioSourceType) -> StudioArticle? {
        vm.activeArticles
            .filter { $0.sourceType == type }
            .max(by: { $0.dateAdded < $1.dateAdded })
    }

    /// The first lecture of the course added last, for the Courses step. A
    /// playlist course's lectures are videos, not course-typed sources, so the
    /// step asks the courses themselves: waiting for a `course` source never
    /// saw a playlist arrive.
    private var newestCourseLecture: StudioArticle? {
        let lectures = vm.allCourseGroupNames.flatMap { vm.courseLectures(for: $0) }
        guard let courseID = lectures.max(by: { $0.createdAt < $1.createdAt })?.courseName else { return nil }
        for lecture in vm.courseLectures(for: courseID) {
            if let first = vm.courseLectureItems(for: lecture.id).lazy.compactMap(vm.article(for:)).first {
                return first
            }
        }
        return nil
    }

    private var newestYouTubeVideo: StudioArticle? {
        vm.activeArticles
            .filter { $0.discoveryOrigin == .youtubePlaylist && $0.sourceType == .video }
            .max(by: { $0.dateAdded < $1.dateAdded })
    }

    private var youtubeChannels: [String] {
        Set(youtubeItems.compactMap(\.channelTitle))
            .union(vm.hiddenYouTubeChannelNames)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var canContinue: Bool {
        switch step {
        // The step is done once the shows can be chosen: their defaults are
        // an answer, and the import follows on Continue.
        case .podcasts: return (podcastInventoryCount ?? 0) > 0 || !podcastShowNames.isEmpty
        // A chosen Reading List is set up even before anything is saved to
        // it ("Only new saves"), and a read-later library brought over once
        // is as good an answer.
        case .article:
            return !enabledReadingListBrowsers.isEmpty
                || newestReadingListArticle != nil
                || oneTimeImportResults["read-later"] != nil
        case .paper: return newestPaper != nil || oneTimeImportResults["reference-library"] != nil
        case .books: return newestSource(of: .book) != nil
        case .courses: return newestCourseLecture != nil
        case .meetings: return newestSource(of: .meeting) != nil || zoomFolder != nil
        case .youtube:
            return (vm.youtubeImportSource != nil && newestYouTubeVideo != nil)
                || newestSource(of: .video) != nil
        case .planner, .memory, .ideas, .artifacts, .assistants, .moreSources:
            return true
        case .enhancements:
            return GettingStartedAIPayment.isReady(
                hasOwnKey: account.ownKey != nil,
                ownKeyAllowed: account.ownKeyAllowed,
                canPayWithoutKey: hasUsableForeverLMCredits
            ) && backgroundModelReady
        case .storage:
            return true
        case .subscriptions:
            return aiSubscriptions != nil
        case .fullDiskAccess:
            return hasFullDiskAccess
        }
    }

    private var firstIncompleteStep: GettingStartedStep {
        GettingStartedStep.onboardingOrder.first(where: { !isComplete($0) }) ?? .enhancements
    }

    private func isComplete(_ candidate: GettingStartedStep) -> Bool {
        if candidate == .enhancements, !hasConsentedToBackgroundAIUsage { return false }
        return (completedSteps & candidate.bit) != 0
    }

    private var previousStep: GettingStartedStep? {
        guard let index = GettingStartedStep.onboardingOrder.firstIndex(of: step), index > 0 else {
            return nil
        }
        return GettingStartedStep.onboardingOrder[index - 1]
    }

    /// Prefer the next unfinished step, then wrap to an earlier one if the
    /// learner used the rail to jump ahead.
    private var nextIncompleteStep: GettingStartedStep? {
        guard let index = GettingStartedStep.onboardingOrder.firstIndex(of: step) else { return nil }
        let after = GettingStartedStep.onboardingOrder.dropFirst(index + 1)
        if let next = after.first(where: { !isComplete($0) }) { return next }
        return GettingStartedStep.onboardingOrder[..<index].first(where: { !isComplete($0) })
    }

    private func completeAndAdvance() {
        completedSteps |= step.bit
        // The shows have been chosen (or the step skipped): only now does
        // Apple Podcasts import, so nothing arrives for a show turned away.
        if step == .podcasts, vm.hasCompletedInitialQueueLoad {
            vm.startPodcastAutoSync()
        }
        guard let next = nextIncompleteStep else {
            isCompleted = true
            isDismissed = false
            arrivalSuggestionsArmed = true
            isPresented = false
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }

    /// A comp, or balance left from before top-ups were retired. Asked
    /// without the key, which `Balance.isEmpty` would otherwise count.
    private var hasUsableForeverLMCredits: Bool {
        guard let balance = account.balance, !balance.disabled else { return false }
        return balance.billingExempt || balance.microUSD > 0
    }

    /// A first launch holds the local source watchers until setup reaches the
    /// step that introduces them; from there on, a save in the browser or an
    /// episode played in Apple Podcasts arrives on its own, as the step says.
    private func startSourceAutoSync(for step: GettingStartedStep) {
        guard vm.hasCompletedInitialQueueLoad else { return }
        switch step {
        case .article, .paper:
            vm.startReadingListAutoSync()
        // Podcasts import once the shows are chosen, in completeAndAdvance.
        case .meetings:
            vm.startZoomLocalTranscriptAutoSync()
        default:
            break
        }
    }

    private func prepareCurrentStep() async {
        startSourceAutoSync(for: step)
        if step == .youtube {
            await loadYouTubePreview()
        } else if step == .enhancements {
            await account.reloadOwnKey()
            await account.refresh(silently: true)
        }
    }

    private func openDetectedSourceForCurrentStep() {
        let target: (StudioArticle, StudioSidebarTab)?
        switch step {
        case .podcasts:
            target = vm.activeArticles.first(where: { $0.sourceType == .podcast }).map { ($0, .podcasts) }
        case .article:
            target = newestReadingListArticle.map { ($0, .articles) }
        case .paper:
            target = newestPaper.map { ($0, .papers) }
        case .books:
            target = newestSource(of: .book).map { ($0, .books) }
        case .courses:
            // A course opens on its own page, in the rail's Courses tab.
            if let courseID = newestCourseLecture.flatMap({ vm.courseIDs(containing: $0).first }) {
                vm.openCourse(courseID)
            }
            target = nil
        case .meetings:
            target = newestSource(of: .meeting).map { ($0, .meetings) }
        case .youtube:
            target = (newestYouTubeVideo ?? newestSource(of: .video)).map { ($0, .videos) }
        case .enhancements, .storage, .subscriptions, .fullDiskAccess, .planner, .memory, .ideas, .artifacts, .assistants,
             .moreSources:
            target = nil
        }
        guard let (article, tab) = target else { return }
        vm.sidebarTab = tab
        vm.selectedArticleId = article.id
        vm.selectedArticleIds = [article.id]
    }

    private func run(_ action: String, operation: @escaping @MainActor () async -> Void) {
        guard workingAction == nil else { return }
        workingAction = action
        Task { @MainActor in
            await operation()
            workingAction = nil
        }
    }

    private func connectYouTube() async {
        do {
            try await YouTubeService.shared.authenticate()
            isYouTubeSignedIn = YouTubeService.shared.isSignedIn
            youtubeError = nil
            await loadYouTubePreview()
        } catch {
            youtubeError = error.localizedDescription
        }
    }

    private func loadYouTubePreview() async {
        isYouTubeSignedIn = YouTubeService.shared.isSignedIn
        guard isYouTubeSignedIn, !hasLoadedYouTubePreview, !isLoadingYouTubePreview else { return }
        isLoadingYouTubePreview = true
        defer { isLoadingYouTubePreview = false }
        do {
            switch vm.youtubeImportSource {
            case .likedVideos:
                youtubeItems = try await YouTubeService.shared.listLikedVideos(maxCount: 500)
            case .foreverLMPlaylist:
                let feed = try await YouTubeService.shared.listForeverLMPlaylistFeed(maxCount: 500)
                youtubeItems = feed.items
            case nil:
                youtubeItems = []
                return
            }
            hasLoadedYouTubePreview = true
            youtubeError = nil
        } catch {
            youtubeError = error.localizedDescription
        }
    }

    private func configureYouTube(_ policy: YouTubeLikedImportPolicy) {
        run("youtube-policy") {
            _ = await vm.configureYouTubeLikedVideos(
                policy,
                automaticallyFormatTranscripts: automaticallyFormatLikedVideoTranscripts
            )
            isChoosingLikedVideos = false
            hasLoadedYouTubePreview = false
            await loadYouTubePreview()
        }
    }

    private func configureForeverLMPlaylist() {
        run("youtube-source") {
            let groupID = await vm.followYouTubeForeverLMPlaylist()
            guard groupID != nil else {
                youtubeError = vm.errorMessage ?? "Could not find your ForeverLM playlist."
                return
            }
            hasLoadedYouTubePreview = false
            await loadYouTubePreview()
        }
    }

    private func youtubeChannelVisibilityBinding(_ channel: String) -> Binding<Bool> {
        Binding(
            get: { !vm.isYouTubeChannelHidden(channel) },
            set: { visible in Task { await vm.setYouTubeChannelHidden(channel, hidden: !visible) } }
        )
    }

    private func stepHeading(icon: String, title: String, detail: String) -> some View {
        SetupStepHeading(icon: icon, title: title, detail: detail)
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Text(number)
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text).font(.caption)
        }
    }

    private func waitingCard(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .setupCard()
    }

    private func accessNotice(_ text: String) -> some View {
        Label(text, systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .setupCard()
    }

    private func detectedSourceCard(_ article: StudioArticle, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(article.title).font(.subheadline.weight(.medium)).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .setupCard()
    }

    private func ingestionStage(_ label: String, done: Bool) -> some View {
        Label(label, systemImage: done ? "checkmark.circle.fill" : "circle.dotted")
            .font(.caption)
            .foregroundStyle(done ? Color.green : Color.secondary)
    }

    @ViewBuilder
    private func actionProgress(_ action: String) -> some View {
        if workingAction == action {
            ProgressView().controlSize(.small)
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func openInReadingListBrowser(_ url: URL) {
        BrowserService.open(url, preference: readingListBrowser.preference)
    }

    // MARK: Adding sources from the guide

    /// The hosted connector address, the same one Settings › MCP hands out.
    static let connectorURL = "https://plugin.foreverlm.com/mcp"

    /// A drop target that also offers a file picker. The drop goes through an
    /// AppKit catcher because the Studio under the guide can hold web views,
    /// and AppKit hands a drag to those before any SwiftUI `.onDrop`.
    private func fileDropZone(
        _ title: String,
        icon: String,
        types: [UTType],
        chooseTitle: String,
        importFile: @escaping @MainActor (URL) async throws -> Void
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(isFileDropTargeted ? Color.accentColor : .secondary)
            Text(title)
                .font(.subheadline.weight(.medium))
            HStack {
                Button(chooseTitle) {
                    Task { @MainActor in
                        let urls = await FilePanel.open { panel in
                            panel.allowedContentTypes = types
                            panel.allowsMultipleSelection = true
                        }
                        importFiles(urls, importFile: importFile)
                    }
                }
                actionProgress("file-import")
            }
            if let fileImportError {
                Label(fileImportError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            isFileDropTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFileDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        }
        .overlay {
            StudioDropCatcher(
                types: [.fileURL],
                onTargeted: { isFileDropTargeted = $0 },
                onDrop: { providers in
                    Task { @MainActor in
                        var urls: [URL] = []
                        for provider in providers {
                            if let url = await Self.fileURL(from: provider) { urls.append(url) }
                        }
                        let accepted = urls.filter { Self.url($0, conformsToAnyOf: types) }
                        if accepted.count < urls.count {
                            fileImportError = "Only \(types.compactMap(\.preferredFilenameExtension).map { $0.uppercased() }.joined(separator: ", ")) files can be added here."
                        }
                        importFiles(accepted, importFile: importFile)
                    }
                    return true
                }
            )
        }
    }

    private func importFiles(
        _ urls: [URL],
        importFile: @escaping @MainActor (URL) async throws -> Void
    ) {
        guard !urls.isEmpty else { return }
        run("file-import") {
            fileImportError = nil
            for url in urls {
                do {
                    try await importFile(url)
                } catch {
                    fileImportError = "Couldn’t add \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let url: URL?
                if let data = data as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = data as? String {
                    url = URL(string: value)
                } else {
                    url = data as? URL
                }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private static func url(_ url: URL, conformsToAnyOf types: [UTType]) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    /// A one-line link box with its button; the link clears once it is added.
    private func linkField(
        _ prompt: String,
        text: Binding<String>,
        buttonTitle: String,
        action: String,
        add: @escaping @MainActor (String) async throws -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(prompt, text: text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitLink(text, action: action, add: add) }
                Button(buttonTitle) { submitLink(text, action: action, add: add) }
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || workingAction != nil)
                actionProgress(action)
            }
            if let linkError, workingAction == nil, linkErrorAction == action {
                Label(linkError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submitLink(
        _ text: Binding<String>,
        action: String,
        add: @escaping @MainActor (String) async throws -> Void
    ) {
        let link = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        run(action) {
            linkError = nil
            linkErrorAction = action
            do {
                try await add(link)
                text.wrappedValue = ""
            } catch {
                linkError = error.localizedDescription
            }
        }
    }

    private func appleBookSelectionBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { selectedAppleBooks.contains(path) },
            set: { isOn in
                if isOn { selectedAppleBooks.insert(path) } else { selectedAppleBooks.remove(path) }
            }
        )
    }

    private func importSelectedAppleBooks() {
        let books = (appleBooks?.books ?? []).filter { selectedAppleBooks.contains($0.path) }
        run("apple-books-import") {
            fileImportError = nil
            for book in books {
                do {
                    try await vm.importBook(from: book.path)
                    selectedAppleBooks.remove(book.path)
                } catch {
                    fileImportError = "Couldn’t add \(book.title): \(error.localizedDescription)"
                }
            }
        }
    }

    private func openAppleBooks() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private var zoomFolderDisplayPath: String {
        let path = zoomFolder
            ?? StudioViewModel.zoomLocalTranscriptDefaultFolder(homeDir: BookmarkAccessManager.realHomeDirectory)
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseZoomFolder() {
        Task { @MainActor in
            let urls = await FilePanel.open { panel in
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.message = "Choose the folder Zoom saves its recordings to"
            }
            guard let url = urls.first else { return }
            UserDefaults.standard.set(url.path, forKey: StudioViewModel.zoomLocalTranscriptFolderKey)
            zoomFolder = StudioViewModel.zoomLocalTranscriptCustomFolder
            vm.zoomLocalTranscriptFolderDidChange()
        }
    }

    /// Settings draws over the guide, so closing it comes back to this step.
    private func openSettings(_ pane: SettingsPane) {
        NotificationCenter.default.post(name: .requestOpenStudioSettings, object: pane)
    }

    private func openFullDiskAccessSettings() {
        FullDiskAccess.openSettings()
    }
}

/// A step's icon, title and detail. A step opened inside a More sources row
/// leaves it out, since the row already names it.
private struct SetupStepHeading: View {
    let icon: String
    let title: String
    let detail: String
    @Environment(\.setupStepHeadingHidden) private var isHidden

    var body: some View {
        if !isHidden {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SetupStepHeadingHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var setupStepHeadingHidden: Bool {
        get { self[SetupStepHeadingHiddenKey.self] }
        set { self[SetupStepHeadingHiddenKey.self] = newValue }
    }
}

private extension View {
    func setupCard() -> some View {
        padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Welcome story

/// The welcome's opening, drawn to one sentence the learner should be able to
/// say afterwards: "I take in a lot every day, most of it is gone within a
/// week, and ForeverLM keeps all of it within reach."
///
/// What makes that hard to see is that forgetting is invisible: you remember
/// that you read a paper, not what it said. So the stage is one day's
/// timeline, and each thing taken in lands on it as a card. "A week later",
/// every card keeps its kind but its title greys into placeholder bars,
/// oldest first; the book stays a little clearer while "I've seen this idea
/// before, in that book…" is said. The mark then answers it: the same cards
/// come back whole and gather into one stack under it. One page then says
/// how, in three rows: what they read comes back as quizzes, the AI is
/// theirs to choose, and the data is theirs to keep, in their own iCloud
/// (the old Storage step). Data comes last because the first step, Full
/// Disk Access, asks to read some of it. The product owner, 2026-09-24: fewer
/// screens, so the three used to be pages of their own.
/// The product owner, 2026-09-22: the onboarding starts with the story, not with a
/// settings question; 2026-09-24: the day has to look far better than a grid
/// of icons.
struct WelcomeStory: View {
    /// One thing taken in during the day. The titles are invented: the story
    /// never shows anyone's own library.
    struct Moment: Identifiable {
        let icon: String
        let kind: String
        let title: String
        /// When it happened, in hours from midnight.
        let hours: Double
        let tint: Color
        var id: String { icon }
    }

    static let day: [Moment] = [
        Moment(icon: "headphones", kind: "Podcast", title: "Why sleep clears the brain", hours: 7.25, tint: .purple),
        Moment(icon: "envelope.open", kind: "Newsletter", title: "This week in longevity", hours: 8.75, tint: .orange),
        Moment(icon: "doc.text.magnifyingglass", kind: "Paper", title: "Mitochondria move between cells", hours: 10.25, tint: .blue),
        Moment(icon: "person.3", kind: "Meeting", title: "Lab meeting: next experiments", hours: 12, tint: .green),
        Moment(icon: "newspaper", kind: "Article", title: "The race for solid-state batteries", hours: 14, tint: .teal),
        Moment(icon: "play.rectangle.fill", kind: "Lecture", title: "How memory consolidates", hours: 16.5, tint: .red),
        Moment(icon: "book", kind: "Book", title: "Chapter 7: The forgetting curve", hours: 19.5, tint: .brown),
        Moment(icon: "text.bubble", kind: "Posts on X", title: "43 posts in your feed", hours: 22.5, tint: .indigo),
    ]

    /// The card the quote is about, kept a little clearer than the rest.
    static let halfRememberedIcon = "book"

    enum Beat: Int, Comparable {
        /// Played on a clock.
        case day, question
        /// Turned by the learner.
        case answer, howItWorks
        static func < (lhs: Beat, rhs: Beat) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let yourAIIcon = "slider.horizontal.3"
    static let rememberIcon = "rectangle.stack"
    static let yourDataIcon = "lock.shield"

    var startsAtEnd = false
    var onStart: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat: Beat = .day
    @State private var shownMoments = 0
    /// The day's clock, in hours; the playhead on the timeline follows it.
    @State private var clock: Double = 7
    /// How many cards, oldest first, have lost their titles.
    @State private var forgottenMoments = 0
    @State private var showsFingertips = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch beat {
                case .day, .question, .answer:
                    // One stage for all three, so the cards the day laid down
                    // are the ones that fade and the ones that come back.
                    dayStage
                        .transition(.opacity)
                case .howItWorks:
                    howItWorks
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // One slot at the bottom, so nothing shifts when the button
            // changes from page to page.
            Group {
                switch beat {
                case .day, .question:
                    Button("Skip") { advance(to: .answer) }
                        .buttonStyle(.hoverWash)
                        .foregroundStyle(.secondary)
                case .answer:
                    primaryButton("Continue") { advance(to: .howItWorks) }
                case .howItWorks:
                    primaryButton("Get Started", action: onStart)
                }
            }
            .keyboardShortcut(.defaultAction)
            .frame(height: 44)
            .padding(.bottom, 36)
        }
        .task { await play() }
    }

    // MARK: Day stage

    private static let stageSize = CGSize(width: 700, height: 470)
    private static let cardSize = CGSize(width: 96, height: 118)
    private static let timelineY: CGFloat = 258
    private static let timelineSpan: ClosedRange<CGFloat> = 20...680
    private static let hoursSpan: ClosedRange<Double> = 7...23

    private var dayStage: some View {
        ZStack(alignment: .topLeading) {
            headline
            timeline
            cards
            answerHeadline
            fingertips
        }
        .frame(width: Self.stageSize.width, height: Self.stageSize.height)
    }

    /// The day's line and its readout, then the question in the same place.
    private var headline: some View {
        ZStack {
            Text("Every day, you take in so much.")
                .opacity(beat == .day && shownMoments > 0 ? 1 : 0)
            Text("How much of it do you actually remember?")
                .opacity(beat == .question ? 1 : 0)
        }
        .font(.system(size: 26, weight: .semibold, design: .rounded))
        .multilineTextAlignment(.center)
        .position(x: Self.stageSize.width / 2, y: 22)
    }

    private var timeline: some View {
        let start = Self.timelineSpan.lowerBound
        let playhead = x(forHours: clock)
        let isDay = beat == .day
        return ZStack(alignment: .topLeading) {
            Text(isDay ? Self.clockText(clock) : "A week later")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .position(x: Self.stageSize.width / 2, y: 60)

            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(width: Self.timelineSpan.upperBound - start, height: 3)
                .position(x: (start + Self.timelineSpan.upperBound) / 2, y: Self.timelineY)
            Capsule()
                .fill(Color.accentColor.opacity(isDay ? 1 : 0.25))
                .frame(width: max(playhead - start, 0), height: 3)
                .position(x: (start + playhead) / 2, y: Self.timelineY)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 11, height: 11)
                .shadow(color: .accentColor.opacity(0.6), radius: 6)
                .opacity(isDay && shownMoments > 0 ? 1 : 0)
                .position(x: playhead, y: Self.timelineY)

            ForEach(Array(Self.day.enumerated()), id: \.element.id) { index, moment in
                let above = index.isMultiple(of: 2)
                let stemLength: CGFloat = 22
                let pointX = x(forHours: moment.hours)
                Circle()
                    .fill(moment.tint)
                    .frame(width: 7, height: 7)
                    .position(x: pointX, y: Self.timelineY)
                    .opacity(index < shownMoments ? 1 : 0)
                Rectangle()
                    .fill(moment.tint.opacity(0.5))
                    .frame(width: 1.5, height: stemLength)
                    .position(x: pointX, y: Self.timelineY + (above ? -stemLength / 2 : stemLength / 2))
                    .opacity(index < shownMoments ? 1 : 0)
            }
        }
        .opacity(beat == .answer ? 0 : (isDay ? 1 : 0.55))
        .accessibilityHidden(true)
    }

    private var cards: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.day.enumerated()), id: \.element.id) { index, moment in
                let shown = index < shownMoments || beat >= .answer
                let above = index.isMultiple(of: 2)
                let forgotten = beat == .question && index < forgottenMoments
                let halfRemembered = forgotten && showsFingertips && moment.icon == Self.halfRememberedIcon
                card(moment, forgotten: forgotten)
                    .opacity(shown ? (forgotten ? (halfRemembered ? 0.85 : 0.4) : 1) : 0)
                    .scaleEffect(
                        shown || reduceMotion ? (halfRemembered ? 1.06 : 1) : 0.82,
                        anchor: above ? .bottom : .top
                    )
                    .rotationEffect(.degrees(beat >= .answer ? fanOffset(index) * 4 : 0))
                    .position(cardCenter(index))
                    .zIndex(Double(index))
            }
        }
        // Reduce Motion: the cards fade into the stack rather than fly to it.
        .id(reduceMotion && beat >= .answer ? 1 : 0)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    /// A card on the timeline. Forgotten, it keeps its kind and colour's ghost
    /// but its title turns into bars: you know it was a paper, not what it said.
    private func card(_ moment: Moment, forgotten: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [moment.tint.opacity(0.9), moment.tint.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: moment.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(height: 48)
            .saturation(forgotten ? 0 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(moment.kind.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    Text(moment.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(forgotten ? 0 : 1)
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().frame(width: 72, height: 7)
                        Capsule().frame(width: 54, height: 7)
                    }
                    .foregroundStyle(Color.primary.opacity(0.12))
                    .padding(.top, 3)
                    .opacity(forgotten ? 1 : 0)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(forgotten ? 0.04 : 0.16), radius: 8, y: 4)
    }

    private var answerHeadline: some View {
        VStack(spacing: 14) {
            ForeverLMMark(width: 150, motion: .drifting)
            Text("ForeverLM makes it all seamless.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Everything you read, hear and watch, right at your fingertips.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .opacity(beat == .answer ? 1 : 0)
        .offset(y: beat == .answer || reduceMotion ? 0 : 10)
        .position(x: Self.stageSize.width / 2, y: 128)
    }

    private var fingertips: some View {
        VStack(spacing: 6) {
            Text("“I’ve seen this idea before, in that book…”")
                .italic()
            Text("If only it were right there at your fingertips.")
        }
        .font(.title3)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .opacity(beat == .question && showsFingertips ? 1 : 0)
        .position(x: Self.stageSize.width / 2, y: 438)
    }

    private func x(forHours hours: Double) -> CGFloat {
        let clamped = min(max(hours, Self.hoursSpan.lowerBound), Self.hoursSpan.upperBound)
        let fraction = (clamped - Self.hoursSpan.lowerBound)
            / (Self.hoursSpan.upperBound - Self.hoursSpan.lowerBound)
        let span = Self.timelineSpan
        return span.lowerBound + CGFloat(fraction) * (span.upperBound - span.lowerBound)
    }

    /// Where a card sits: on its time along the day, alternately above and
    /// below the line, then fanned into one stack under the mark.
    private func cardCenter(_ index: Int) -> CGPoint {
        if beat >= .answer {
            let offset = fanOffset(index)
            return CGPoint(x: Self.stageSize.width / 2 + offset * 50, y: 352 + abs(offset) * 5)
        }
        let gap = 22 + Self.cardSize.height / 2
        let above = index.isMultiple(of: 2)
        return CGPoint(
            x: x(forHours: Self.day[index].hours),
            y: Self.timelineY + (above ? -gap : gap)
        )
    }

    private func fanOffset(_ index: Int) -> CGFloat {
        CGFloat(index) - CGFloat(Self.day.count - 1) / 2
    }

    static func clockText(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        var components = DateComponents()
        components.hour = (minutes / 60) % 24
        components.minute = minutes % 60
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Here’s how it works.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
            promise(
                icon: Self.rememberIcon,
                title: "Remember what you read.",
                text: "ForeverLM keeps track of what you read and, when you want it to stick, writes quizzes on it for you. Like Anki flashcards, updated for a new era."
            )
            promise(
                icon: Self.yourAIIcon,
                title: "You’re in charge of your AI.",
                text: "Choose the models you want, at a price you’re comfortable with. Already pay for an AI subscription? ForeverLM works with it too, without locking you in."
            )
            VStack(alignment: .leading, spacing: 12) {
                promise(
                    icon: Self.yourDataIcon,
                    title: "You’re in charge of your data.",
                    text: "Your library lives on this Mac and syncs through your own iCloud, to your iPhone, iPad and the web. ForeverLM keeps no copy of your chats."
                )
                VStack(alignment: .leading, spacing: 10) {
                    Text("The free 5 GB of iCloud fills fast once papers and audio sync, so iCloud+ \(ICloudStorage.recommendedPlan) works best.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ICloudStorageNotices()
                }
                .padding(.leading, 50)
            }
        }
        .frame(maxWidth: 540)
        .padding(.horizontal, 40)
    }

    private func promise(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(minWidth: 180)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
    }

    /// Plays the story forward on a clock. Skip can jump ahead at any point,
    /// so every beat only ever moves forward.
    private func play() async {
        if startsAtEnd {
            beat = .howItWorks
            return
        }
        guard beat == .day else { return }
        if reduceMotion {
            shownMoments = Self.day.count
            clock = Self.hoursSpan.upperBound
            guard await pause(3) else { return }
            advance(to: .question)
            forgottenMoments = Self.day.count
            showsFingertips = true
            guard await pause(4) else { return }
            advance(to: .answer)
            return
        }
        guard await pause(0.5) else { return }
        for (index, moment) in Self.day.enumerated() {
            guard beat == .day else { return }
            withAnimation(.easeInOut(duration: 0.45)) { clock = moment.hours }
            guard await pause(0.2) else { return }
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) { shownMoments = index + 1 }
            guard await pause(0.42) else { return }
        }
        withAnimation(.easeInOut(duration: 0.6)) { clock = Self.hoursSpan.upperBound }
        guard await pause(1.1) else { return }
        advance(to: .question)
        guard await pause(0.5) else { return }
        // A week goes by: the titles go, oldest first.
        for index in Self.day.indices {
            withAnimation(.easeInOut(duration: 0.8)) { forgottenMoments = index + 1 }
            guard await pause(0.14) else { return }
        }
        guard await pause(0.9) else { return }
        withAnimation(.easeInOut(duration: 0.6)) { showsFingertips = true }
        guard await pause(3.4) else { return }
        advance(to: .answer)
    }

    private func advance(to next: Beat) {
        guard next > beat else { return }
        let duration = reduceMotion ? 0.2 : (next > .answer ? 0.35 : 0.7)
        withAnimation(.easeInOut(duration: duration)) { beat = next }
    }

    /// False once the story is skipped to the end or the view goes away.
    private func pause(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            return false
        }
        return beat < .answer
    }
}

/// A silent screen recording that loops beside a welcome page. The clips are
/// recorded from a demo library, never a learner's own, and ship in
/// WelcomeClipsResources, whose README is the shot list.
struct WelcomeClipPlayer: NSViewRepresentable {
    let url: URL

    static func url(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "WelcomeClipsResources")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        context.coordinator.player = player
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {}

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.looper?.disableLooping()
        coordinator.player?.pause()
        view.playerLayer.player = nil
    }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }

    final class PlayerLayerView: NSView {
        let playerLayer: AVPlayerLayer = {
            let layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspect
            return layer
        }()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        override func makeBackingLayer() -> CALayer { playerLayer }
    }
}

/// The mark setup puts on the option it suggests. Every choice in setup has
/// one, with a line beside it saying why (product owner, 2026-09-22).
struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }
}

// MARK: - After setup

/// What to do first, once setup hands over to the app: read something that
/// came in, quiz yourself on it, ask about the library, plan the day. Shown on
/// the Reader's idle page only after the guide is finished (an install that
/// finished setup before this existed never sees it), and each suggestion
/// ticks off once used. It goes away when all four are done or it is closed.
struct GetStartedSuggestions: View {
    enum Suggestion: Int, CaseIterable, Identifiable {
        case read, quiz, ask, plan

        var id: Int { rawValue }
        var bit: Int { 1 << rawValue }

        var icon: String {
            switch self {
            case .read: return "book"
            case .quiz: return "rectangle.stack"
            case .ask: return "bubble.left.and.text.bubble.right"
            case .plan: return "calendar"
            }
        }

        var title: String {
            switch self {
            case .read: return "Read something you saved"
            case .quiz: return "Quiz yourself on it"
            case .ask: return "Ask about your library"
            case .plan: return "Plan your day"
            }
        }
    }

    static let armedKey = "gettingStarted.suggestionsArmed"
    static let allDone = Suggestion.allCases.reduce(0) { $0 | $1.bit }

    static func isShowing(armed: Bool, doneBits: Int) -> Bool {
        armed && doneBits & allDone != allDone
    }

    @Environment(StudioViewModel.self) private var vm
    @SyncedStorage(Self.armedKey) private var isArmed = false
    @SyncedStorage("gettingStarted.suggestionsDone") private var doneBits = 0

    /// The source the first two suggestions are about, newest first.
    var source: StudioArticle?
    var onOpenSource: (String) -> Void

    var body: some View {
        if Self.isShowing(armed: isArmed, doneBits: doneBits) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Get started")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { doneBits = Self.allDone }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                    .help("Hide suggestions")
                    .accessibilityLabel("Hide suggestions")
                }
                ForEach(Suggestion.allCases) { suggestion in
                    row(suggestion)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .transition(.opacity)
        }
    }

    /// A grey glyph and the suggestion's title, one line each (2026-10-06:
    /// the accent glyphs, a green check and a subline under every row went;
    /// the source the first two are about is the row's tooltip).
    private func row(_ suggestion: Suggestion) -> some View {
        let isDone = doneBits & suggestion.bit != 0
        let needsSource = suggestion == .read || suggestion == .quiz
        return Button {
            perform(suggestion)
            withAnimation(.easeInOut(duration: 0.2)) { doneBits |= suggestion.bit }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isDone ? "checkmark.circle" : suggestion.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(suggestion.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .strikethrough(isDone, color: .secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .disabled(needsSource && source == nil)
        .help(help(for: suggestion))
    }

    private func help(for suggestion: Suggestion) -> String {
        switch suggestion {
        case .read, .quiz: return source?.title ?? "Nothing has come in yet"
        case .ask, .plan: return suggestion.title
        }
    }

    private func perform(_ suggestion: Suggestion) {
        switch suggestion {
        case .read:
            if let source { onOpenSource(source.id) }
        case .quiz:
            if let source {
                vm.startCompanionReview(goalID: nil, sourceIDs: [source.id], topic: source.title)
            }
        case .ask:
            vm.requestBlankReviewChat()
        case .plan:
            vm.requestPlanDayChat(request: ReviewSlashCommandParser.planDayRequest(nil))
        }
    }
}

// MARK: - iCloud storage

/// What can stop a library syncing, as the setup guide and Settings › iCloud
/// both show it: a Mac not signed in to iCloud, or an iCloud that is full.
/// Every library syncs (`ICloudStorage`), so there is nothing to choose; when
/// sync is fine this shows nothing.
struct ICloudStorageNotices: View {
    @ObservedObject private var status = CloudKitSyncStatusCenter.shared
    @State private var isSignedIn = CloudRuntimeAvailability.isSignedIn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isSignedIn {
                notice(
                    "This Mac is not signed in to iCloud, so your library stays on this Mac for now. Sign in under System Settings › Apple Account and it starts syncing.",
                    icon: "person.crop.circle.badge.exclamationmark",
                    tint: .orange,
                    action: ("Open iCloud Settings", ICloudStorageNotices.openICloudSettings)
                )
            }
            if status.isICloudFull {
                notice(
                    "Your iCloud storage is full, so sync has paused. \(ICloudStorage.fullConsequence) Free up space or upgrade to the \(ICloudStorage.recommendedPlan) plan.",
                    icon: "externaldrive.badge.exclamationmark",
                    tint: .red,
                    action: ("Manage iCloud Storage", ICloudStorageNotices.openICloudSettings)
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Signing in happens in System Settings; see it on the way back.
            isSignedIn = CloudRuntimeAvailability.isSignedIn
        }
    }

    private func notice(
        _ text: String,
        icon: String,
        tint: Color,
        action: (title: String, run: @MainActor () -> Void)
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Button(action.title, action: action.run)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func openICloudSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud",
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings",
            "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}

// MARK: - Apple Books

/// The books a learner already keeps in Apple Books, read from Apple Books'
/// own index so the guide can offer them by title. Books synced through
/// iCloud live in the iBooks ubiquity container as unpacked `.epub` folders,
/// which `importBook` reads directly; a book iCloud has not downloaded is
/// counted rather than offered, because reading it would stall on the fetch.
enum AppleBooksLibrary {
    struct Book: Identifiable, Hashable, Sendable {
        let path: String
        let title: String
        let author: String?
        var id: String { path }
    }

    struct Scan: Sendable {
        var books: [Book]
        var cloudOnlyCount: Int
    }

    static let supportedExtensions: Set<String> = ["epub", "pdf"]

    static func scan(homeDir: String = BookmarkAccessManager.realHomeDirectory) -> Scan {
        let indexPath = (homeDir as NSString).appendingPathComponent(
            "Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books/Books.plist"
        )
        let entries: [Book]
        if let data = FileManager.default.contents(atPath: indexPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let rows = plist["Books"] as? [[String: Any]] {
            entries = books(fromIndex: rows)
        } else {
            let folder = (homeDir as NSString).appendingPathComponent(
                "Library/Mobile Documents/iCloud~com~apple~iBooks/Documents"
            )
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            entries = names
                .filter { supportedExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .map { name in
                    Book(
                        path: (folder as NSString).appendingPathComponent(name),
                        title: (name as NSString).deletingPathExtension,
                        author: nil
                    )
                }
        }

        var seen: Set<String> = []
        var available: [Book] = []
        var cloudOnly: Set<String> = []
        for book in entries {
            let key = "\(book.title.lowercased())\u{1F}\(book.author?.lowercased() ?? "")"
            guard !seen.contains(key) else { continue }
            if isDownloaded(book.path) {
                seen.insert(key)
                cloudOnly.remove(key)
                available.append(book)
            } else if FileManager.default.fileExists(atPath: book.path) {
                cloudOnly.insert(key)
            }
        }
        available.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Scan(books: available, cloudOnlyCount: cloudOnly.count)
    }

    /// Apple Books keeps one row per copy, so a book imported twice appears
    /// twice; previews are samples, not the book.
    static func books(fromIndex rows: [[String: Any]]) -> [Book] {
        rows.compactMap { row in
            guard (row["isPreview"] as? Bool) != true,
                  let path = row["path"] as? String,
                  supportedExtensions.contains((path as NSString).pathExtension.lowercased())
            else { return nil }
            let title = (row["itemName"] as? String)
                ?? (row["BKDisplayName"] as? String)
                ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let author = (row["artistName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Book(path: path, title: title, author: author)
        }
    }

    private static func isDownloaded(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]) else { return false }
        guard values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }
}

/// Setup's Recommended models row (product owner, 2026-09-28): the whole set in one
/// step (`RecommendedModels`). What it would take is read when the row
/// appears and said before it is taken. The Chat and Background work rows
/// below then show what it chose, and change one model at a time.
private struct GettingStartedRecommendedModels: View {
    @State private var choice: RecommendedModels.Choice?
    @State private var loadError: String?
    @State private var isApplied = false
    @State private var working = false
    @State private var applyError: String?
    @SyncedStorage(AIFreeMode.enabledKey) private var freeModeOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let choice {
                Group {
                    roleLine("Chat", chatLine(choice))
                    roleLine("Background work", backgroundLine(choice))
                    if choice.freeText != nil {
                        Text("Free models are not limited to US hosts. Meetings stay on \(choice.backup.model.name).")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if isApplied {
                        Label("Using the recommended models", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Button("Use Recommended Models") { apply(choice) }
                            .disabled(working || freeModeOn)
                            .accessibilityIdentifier("gettingStarted.recommendedModels")
                        if working {
                            ProgressView().controlSize(.small)
                        } else if freeModeOn {
                            Text("Not in Free mode, which uses only free models.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            RecommendedBadge()
                        }
                    }
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await load() } }
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking which models run on hosts in the US…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let applyError {
                Label(applyError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderDidChange).receive(on: RunLoop.main)) { _ in
            Task { await readApplied() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange).receive(on: RunLoop.main)) { _ in
            // The key decides whether background work can start free.
            Task { await load() }
        }
    }

    private func roleLine(_ role: String, _ text: String) -> some View {
        (Text(role).fontWeight(.semibold) + Text("  ") + Text(text))
            .foregroundStyle(.primary)
    }

    private func chatLine(_ choice: RecommendedModels.Choice) -> String {
        "\(choice.chat.model.name), with open weights, run only by its \(choice.chat.hosts.count) hosts in \(RecommendedModels.region.name)."
    }

    private func backgroundLine(_ choice: RecommendedModels.Choice) -> String {
        let backup = "\(choice.backup.model.name) on its cheapest host in \(RecommendedModels.region.name)"
        let price = choice.backup.cheapestPrice.map {
            " (\(AIModelListPrice.pairLabel(input: $0.input, output: $0.output)) per 1M tokens in / out)"
        } ?? ""
        return choice.freeText == nil
            ? "\(backup)\(price)."
            : "OpenRouter's free models, then \(backup)\(price) when they fail."
    }

    /// Off the main actor: the directory, the US lists and the free models'
    /// test runs are all network reads.
    private func load() async {
        loadError = nil
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try await RecommendedModels.load()
            }.value
            choice = loaded
            await readApplied()
        } catch {
            choice = nil
            loadError = error.localizedDescription
        }
    }

    /// Keychain reads, so off the main actor.
    private func readApplied() async {
        guard let choice else { return }
        isApplied = await Task.detached(priority: .userInitiated) {
            RecommendedModels.isApplied(choice)
        }.value
    }

    /// The chat model is tested first, as the Chat row tests a pick
    /// (`AIModelQualification`); the set is taken only if it passes.
    private func apply(_ choice: RecommendedModels.Choice) {
        guard !working else { return }
        working = true
        applyError = nil
        Task { @MainActor in
            defer { working = false }
            let chatID = choice.chat.model.id
            let verdict = await Task.detached(priority: .userInitiated) {
                await AIModelQualification.testBeforeSelecting(provider: .openRouter, model: chatID, role: .chat)
            }.value
            guard verdict == .go else {
                applyError = AIModelQualification.refusalText(name: choice.chat.model.name, role: .chat, verdict: verdict)
                return
            }
            do {
                try await RecommendedModels.apply(choice)
                await readApplied()
            } catch {
                applyError = error.localizedDescription
            }
        }
    }
}

/// Setup's Chat row (product owner, 2026-09-26): the model new chats start on,
/// from the same catalog as Settings › Chat › Models. Choosing one also
/// offers it in the chat's model picker, as starring a card there does.
private struct GettingStartedChatModelChoice: View {
    @State private var groups: [AIModelCatalog.MakerGroup] = []
    @State private var defaultEntry: AIModelCatalogEntry?
    @State private var testingModelName: String?
    @State private var pickRefusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The model new chats start with.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Menu {
                    ForEach(groups, id: \.maker) { group in
                        Menu(group.maker.displayName) {
                            ForEach(group.entries) { entry in
                                Button {
                                    choose(entry)
                                } label: {
                                    HStack {
                                        Text(entry.displayName)
                                        if entry.id == defaultEntry?.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    // The pick shows at once while it is tested; no word
                    // about the test (product owner, 2026-09-27).
                    Text(testingModelName ?? defaultEntry?.displayName ?? "Choose a model")
                        .lineLimit(1)
                }
                .fixedSize()
                .disabled(testingModelName != nil)
                .accessibilityIdentifier("gettingStarted.chatModel")

                if let defaultEntry, let price = AIModelListPrice.label(for: defaultEntry) {
                    Text("\(price) per 1M tokens in / out")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let pickRefusal {
                Label(pickRefusal, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderDidChange).receive(on: RunLoop.main)) { _ in
            Task { await load() }
        }
    }

    /// Off the main actor: the stored chat route can reach `KeychainService.load`.
    private func load() async {
        let snapshot = await Task.detached(priority: .userInitiated) {
            let defaultEntry = AIModelCatalog.defaultEntry
            let groups = AIModelCatalog.makerGroups
            return (groups, defaultEntry)
        }.value
        groups = snapshot.0
        defaultEntry = snapshot.1
    }

    /// A model not yet tried for chat is tested first and chosen only if it
    /// passes (`AIModelQualification`).
    private func choose(_ entry: AIModelCatalogEntry) {
        pickRefusal = nil
        guard !AIModelQualification.isPassed(provider: entry.provider, model: entry.modelID, role: .chat) else {
            AIModelCatalog.setDefault(entry)
            defaultEntry = AIModelCatalog.defaultEntry
            return
        }
        testingModelName = entry.displayName
        Task {
            let verdict = await Task.detached(priority: .userInitiated) {
                await AIModelQualification.testBeforeSelecting(provider: entry.provider, model: entry.modelID, role: .chat)
            }.value
            testingModelName = nil
            if verdict == .go {
                AIModelCatalog.setDefault(entry)
                defaultEntry = AIModelCatalog.defaultEntry
            } else {
                pickRefusal = AIModelQualification.refusalText(name: entry.displayName, role: .chat, verdict: verdict)
            }
        }
    }
}

/// Setup's Background work row (product owner, 2026-09-25): what the work ForeverLM
/// does on its own runs on, which is most of what the learner's OpenRouter key
/// pays for. OpenRouter's best free model that can do the work, or the paid
/// one ForeverLM ships with; the same choice sits under Settings › Background.
///
/// Free is the default (product owner, 2026-09-26): background work waits for no
/// one, so a free model's queues and rate limits cost it little. Until the
/// learner picks, the free model is chosen as soon as one can run, which is
/// once the key above is in; a pick made before, here or in Settings, stands.
///
/// A free model runs only once the learner allows free endpoints in their
/// OpenRouter privacy settings, so choosing it is choosing that too: the row
/// checks with one free request (`FreeModelAccess`), says what to turn on when
/// OpenRouter refuses, checks again when the learner comes back to the app,
/// and holds the step until it passes or the paid model is picked.
///
/// With the free model, the row asks about meetings too (product owner,
/// 2026-09-27: "maybe during onboarding when the user sets all the settings;
/// they can choose"). A meeting's transcript holds private conversations, so
/// meetings keep a paid model unless the learner lets them use the free one
/// (`MeetingModels`): the answer is stored, and a meeting task whose
/// Background model is free runs on that model's first paid backup, or the
/// paid model below. Free mode is asked nothing about meetings, since nothing
/// paid runs in it.
private struct GettingStartedBackgroundModelChoice: View {
    @Binding var isReady: Bool

    private enum Choice: Hashable {
        case free
        case paid
        case other
    }

    /// Seeded from the shipped route; the stored one is read off the main
    /// actor, since it can reach `KeychainService.load`.
    @State private var route = KeychainService.defaultBackgroundTaskRoute
    @State private var freeText: OpenRouterDirectoryModel?
    @State private var freeVision: OpenRouterDirectoryModel?
    /// The next free models for the same work, which become the free
    /// pick's backup models.
    @State private var freeTextBackups: [OpenRouterDirectoryModel] = []
    @State private var freeVisionBackups: [OpenRouterDirectoryModel] = []
    @State private var directoryLoaded = false
    @State private var blocker = FreeModelsSetup.pickBlocker()
    /// Nil until checked, or while a check runs.
    @State private var access: FreeModelAccess.Verdict?
    @State private var isChecking = false
    /// The Meetings answer (`MeetingModels.mayUseFree`, read back): true
    /// keeps the meeting tasks on a paid model while background work is
    /// free, as recommended.
    @State private var meetingsStayPaid = !MeetingModels.mayUseFree
    /// Counts the reads of the settings, so only the newest one is shown.
    @State private var readCount = 0
    /// Free mode offers only free models, so the paid one is shown but not
    /// taken while it is on.
    @SyncedStorage(AIFreeMode.enabledKey) private var freeModeOn = false

    private let paid = KeychainService.defaultBackgroundTaskRoute

    private var choice: Choice {
        if AIFreeMode.isFreeSelection(provider: route.provider, model: route.model) { return .free }
        if route.provider == paid.provider, route.model == paid.model { return .paid }
        return .other
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Kept, in one sentence: Continue on this step is the consent to
            // background work (`aiBackground.usageConsented`), and this is
            // the line that says what is being agreed to.
            Text("ForeverLM also runs AI on its own, on transcripts, read-aloud and titles; a free model is the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            option(
                .free,
                title: freeText.map { "Free: \($0.name)" } ?? "Free model",
                detail: freeDetail,
                isEnabled: freeText != nil && blocker == nil
            )

            option(
                .paid,
                title: AIModelCatalog.displayName(provider: paid.provider, modelID: paid.model),
                detail: freeModeOn
                    ? "Not in Free mode, which uses only free models."
                    : AIModelListPrice.label(provider: paid.provider, modelID: paid.model)
                        .map { "Faster and more dependable. Paid through your OpenRouter key, \($0)" }
                        ?? "Faster and more dependable. Paid through your OpenRouter key",
                isEnabled: !freeModeOn
            )

            if choice == .other {
                option(
                    .other,
                    title: "Keep \(AIModelCatalog.displayName(provider: route.provider, modelID: route.model))",
                    detail: "Chosen earlier",
                    isEnabled: true
                )
            }

            if choice == .free {
                freeAccessStatus
                if !freeModeOn {
                    meetingsChoice
                }
            }
        }
        .task {
            await readSettings()
            if let directory = try? await OpenRouterCatalogAvailability.shared.models() {
                await AIModelQualification.qualifyFreeCandidates(from: directory, wanted: 1)
                let text = FreeModelsSetup.candidates(needsVision: false, from: directory)
                let vision = FreeModelsSetup.candidates(needsVision: true, from: directory)
                freeText = text.first
                freeVision = vision.first
                freeTextBackups = Array(text.dropFirst())
                freeVisionBackups = Array(vision.dropFirst())
            }
            directoryLoaded = true
            await chooseFreeUnlessPicked()
            await checkAccessIfFree()
        }
        .onChange(of: choice) { _, _ in
            access = nil
            updateReadiness()
            Task { await checkAccessIfFree() }
        }
        // Back from OpenRouter's privacy page in the browser.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard choice == .free, access != .allowed else { return }
            Task { await checkAccessIfFree() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange).receive(on: RunLoop.main)) { _ in
            blocker = FreeModelsSetup.pickBlocker()
            Task { await chooseFreeUnlessPicked() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderDidChange).receive(on: RunLoop.main)) { _ in
            blocker = FreeModelsSetup.pickBlocker()
            // Free mode going on or off moves the Background model itself.
            Task {
                await readSettings()
                // "Your data" above turned on the switch that leaves a free
                // model no host: the free pick would only be refused.
                if AIDataPolicy.deniesDataCollection, choice == .free { choose(.paid) }
            }
        }
    }

    /// Reads the Background model off the main actor, since it can reach
    /// `KeychainService.load`, and the Meetings answer. Every settings change
    /// reads again, so only the newest read is shown.
    private func readSettings() async {
        readCount += 1
        let read = readCount
        let stored = await Task.detached(priority: .userInitiated) {
            KeychainService.displayedBackgroundTaskRoute
        }.value
        guard read == readCount else { return }
        route = stored
        meetingsStayPaid = !MeetingModels.mayUseFree
    }

    /// Whether meetings go free with the rest of background work.
    private var meetingsChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 2)
            Text("Meetings")
                .font(.subheadline.weight(.semibold))
            meetingsOption(
                stayPaid: true,
                title: "Keep meetings on a paid model",
                detail: MeetingModels.privacyReason
            )
            meetingsOption(
                stayPaid: false,
                title: "Let meetings use the free model too",
                detail: nil
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gettingStarted.background.meetings")
    }

    private func meetingsOption(stayPaid: Bool, title: String, detail: String?) -> some View {
        let isSelected = meetingsStayPaid == stayPaid
        return Button {
            chooseMeetings(stayPaid: stayPaid)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline)
                        if stayPaid {
                            RecommendedBadge()
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: -6))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The Meetings answer, stored at once. It changes no model: a meeting
    /// task reads it each time it runs (`MeetingModels.staysOffFree`).
    private func chooseMeetings(stayPaid: Bool) {
        meetingsStayPaid = stayPaid
        MeetingModels.setMayUseFree(!stayPaid)
    }

    @ViewBuilder
    private var freeAccessStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch access {
            case .allowed?:
                Label("Your OpenRouter account allows free models.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .refused?:
                Label(FreeModelAccess.refusedExplanation, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .unknown(let message)?:
                Label("Could not check whether OpenRouter allows free models: \(message)", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            case nil:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking that your OpenRouter account allows free models…")
                }
                .foregroundStyle(.secondary)
            }
            if access != .allowed {
                HStack(spacing: 12) {
                    Link("Open OpenRouter privacy settings", destination: FreeModelsSetup.openRouterPrivacyURL)
                    Button("Check Again") {
                        Task { await checkAccessIfFree() }
                    }
                    .disabled(isChecking)
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func checkAccessIfFree() async {
        guard choice == .free, !isChecking else { return }
        isChecking = true
        access = nil
        updateReadiness()
        let model = route.model
        let verdict = await Task.detached(priority: .userInitiated) {
            await FreeModelAccess.check(model: model)
        }.value
        isChecking = false
        // The learner may have picked the paid model while it ran.
        guard choice == .free, route.model == model else { return }
        access = verdict
        updateReadiness()
    }

    /// Only a refusal, or a check still running, holds the step: a check
    /// that failed for another reason says so and lets the learner go on.
    private func updateReadiness() {
        switch (choice, access) {
        case (.free, nil), (.free, .refused?): isReady = false
        default: isReady = true
        }
    }

    private var freeDetail: String {
        if let blocker { return blocker }
        if !directoryLoaded { return "Looking for OpenRouter's free models…" }
        if freeText == nil { return "OpenRouter lists no free model that can do this today." }
        return FreeModelsSetup.pickTradeoffs
    }

    /// The free default, applied only while no Background model has ever
    /// been stored: a learner who picked one keeps it.
    private func chooseFreeUnlessPicked() async {
        guard freeText != nil, blocker == nil else { return }
        let unpicked = await Task.detached(priority: .userInitiated) {
            KeychainService.backgroundTaskProvider == nil
        }.value
        if unpicked { choose(.free) }
    }

    private func option(_ value: Choice, title: String, detail: String, isEnabled: Bool) -> some View {
        Button {
            choose(value)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == value ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // The wash below dims nothing on its own.
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: -6))
        .disabled(!isEnabled)
        .accessibilityAddTraits(choice == value ? .isSelected : [])
    }

    private func choose(_ value: Choice) {
        switch value {
        case .paid:
            let multimodal = KeychainService.defaultBackgroundMultimodalTaskRoute
            KeychainService.setBackgroundTaskRoute(provider: paid.provider, model: paid.model)
            KeychainService.setBackgroundMultimodalTaskRoute(provider: multimodal.provider, model: multimodal.model)
            // The free backups the free choice brought go with it; their
            // providers may keep what is sent, which the paid pick declined.
            for (slot, given) in [("background.text", freeTextBackups), ("background.images", freeVisionBackups)] {
                let stored = AIBackupModels.stored(slot: slot).map { $0.model.lowercased() }
                let brought = given.prefix(FreeModelsSetup.freeBackupCount).map { $0.id.lowercased() }
                if !stored.isEmpty, stored == Array(brought) { AIBackupModels.set([], slot: slot) }
            }
            route = paid
        case .free:
            guard let freeText, blocker == nil else { return }
            FreeModelsSetup.setFreeBackground(freeText, multimodal: false, backups: freeTextBackups)
            // With no free model that reads images, those tasks keep theirs.
            if let freeVision {
                FreeModelsSetup.setFreeBackground(freeVision, multimodal: true, backups: freeVisionBackups)
            }
            route = AITaskModelRoute(provider: .openRouter, model: freeText.id)
        case .other:
            break
        }
    }
}
