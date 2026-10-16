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

/// The pages of Setup's AI step: the key, then the models.
private enum AIStepPage {
    case key
    case models
}

/// A page a Setup step opens after its question. Setup reads like a Typeform
/// (product owner, 2026-10-11: "it really focuses on one thing at a time" and
/// "should be crystal clear for the user what to do at each point"): each page
/// asks one thing and has one button that does it, and a choice that needs
/// more leads to a page of its own rather than opening in place.
enum GettingStartedPage: Hashable {
    /// Full Disk Access, once System Settings is open: add the app, relaunch.
    case addToFullDiskAccess
    /// Articles: a read-later app's export, brought over once.
    case readLaterImport
    /// Papers: the place the learner said their papers live.
    case papers(GettingStartedPaperRoute)
    /// More sources: one page for each source picked, in `moreSourceRows` order.
    case moreSource(GettingStartedStep)
    /// Your AI: one page for each app picked, to add ForeverLM to it.
    case connect(AISubscription)
}

/// The answers to "Where do your papers live?", each with its own page.
enum GettingStartedPaperRoute: Hashable {
    case zotero
    case referenceManager
    case pdfs
}

/// How Setup moves forward, kept apart from the view so it can be tested.
enum GettingStartedFlow {
    /// The pick after `current`, or the first pick when there is no current one.
    static func next<T: Equatable>(after current: T?, in picks: [T]) -> T? {
        guard let current else { return picks.first }
        guard let index = picks.firstIndex(of: current) else { return nil }
        let after = picks.index(after: index)
        return after < picks.endIndex ? picks[after] : nil
    }

    /// The footer's one forward button.
    enum Forward: Equatable {
        /// Continue, to the next page or step.
        case next
        /// Finish, on Setup's last page.
        case finish
        /// Skip, on a page that can be left unanswered.
        case skip
        /// A disabled Continue: the page waits for its answer.
        case waiting
    }

    /// One way forward at a time: Continue once the page is answered, Skip
    /// while it is not but may be left, and otherwise a Continue that waits.
    static func forward(canContinue: Bool, canSkip: Bool, isLast: Bool) -> Forward {
        if canContinue { return isLast ? .finish : .next }
        return canSkip ? .skip : .waiting
    }
}

/// Setup's AI step (product owner, 2026-09-25): ForeverLM's AI features run on the
/// learner's own OpenRouter key, billed by OpenRouter at cost, so the step
/// asks for the key, and the key has to be one the account may run
/// (`ownKeyAllowed`): any unlocked account, so a new learner in the free
/// days needs only the key. An account that can already pay another way (a
/// comp, or balance left from before top-ups were retired) goes on without
/// one.
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
    /// The AI step's two pages. `modelsReady` is the models page's word that
    /// the set is taken and OpenRouter will run it, which Continue waits for.
    @State private var aiPage: AIStepPage = .key
    @State private var modelsReady = false
    @State private var showsKeyField = false
    @SyncedStorage(AISubscription.storageKey) private var aiSubscriptionAnswer = ""
    @SyncedStorage(StudioViewModel.youtubeLikedTranscriptFormattingKey)
    private var automaticallyFormatLikedVideoTranscripts = false

    @State private var step: GettingStartedStep = .enhancements
    /// The pages opened past the step's question, newest last; empty on the
    /// question itself. Back closes the newest.
    @State private var pages: [GettingStartedPage] = []
    /// Nil until the learner moves off or back to the welcome; until then a
    /// fresh guide shows it and a reopened one does not.
    @State private var welcomeOverride: Bool?
    @State private var workingAction: String?
    @State private var youtubeError: String?
    @State private var isYouTubeSignedIn = YouTubeService.shared.isSignedIn
    /// The account this step sets up: the one just connected, else the first.
    @State private var youtubeAccountID: String?
    @State private var showYouTubeSourceChoice = false
    @State private var isChoosingLikedVideos = false
    @State private var enabledReadingListBrowsers = ReadingListBrowser.enabled
    @State private var isFileDropTargeted = false
    @State private var fileImportError: String?
    @State private var oneTimeImportResults: [String: String] = [:]
    @State private var oneTimeImportErrors: [String: String] = [:]
    @State private var appleBooks: AppleBooksLibrary.Scan?
    @State private var selectedAppleBooks: Set<String> = []
    @State private var playlistLink = ""
    @State private var linkError: String?
    @State private var linkErrorAction: String?
    @State private var copiedConnectorURL = false
    /// The AI apps this account has connected, from the gateway; nil until read.
    @State private var connectedAssistants: Set<AISubscription>?
    @State private var zoomFolder = StudioViewModel.zoomLocalTranscriptCustomFolder
    @State private var ownKeyDraft = ""
    @State private var ownKeySaving = false
    /// Read at launch and whenever ForeverLM becomes active again, as it does
    /// on the way back from System Settings.
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted
    /// The sources ticked on the More sources question; each gets a page.
    @State private var moreSourcePicks: Set<GettingStartedStep> = []
    /// "None of these" on the More sources question.
    @State private var noMoreSources = false
    /// Whether Zotero keeps a library on this Mac; nil until looked for.
    @State private var hasZoteroLibrary: Bool?
    /// Shows found in Apple Podcasts by the Podcasts step, nil until read.
    @State private var podcastInventoryCount: Int?

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
            step = firstIncompleteStep
            startSourceAutoSync(for: step)
            await prepare(step)
        }
        .onChange(of: account.ownKey != nil) { wasConnected, isConnected in
            // The key arriving is the answer: show it a moment, then the next page.
            guard isConnected, !wasConnected, step == .enhancements, aiPage == .key else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                guard step == .enhancements, aiPage == .key, canContinue else { return }
                withAnimation(.easeInOut(duration: 0.2)) { aiPage = .models }
            }
        }
        .onChange(of: step) { _, newStep in
            if newStep == .enhancements { aiPage = .key }
            startSourceAutoSync(for: newStep)
            Task { await prepare(newStep) }
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

    /// One page at a time, centred in the sheet like the welcome, and
    /// scrolling only when a page runs long (a long list of shows).
    private var stepContent: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    pageContent
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .id("\(step.rawValue)|\(String(describing: page))")
                .transition(.opacity)
            }
        }
    }

    /// The page on screen: a follow-up, or else the step's question.
    private var page: GettingStartedPage? { pages.last }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case nil:
            switch step {
            case .podcasts: podcastStep
            case .article: articleStep
            case .paper: paperStep
            case .enhancements: enhancementsStep
            case .subscriptions: subscriptionsStep
            case .fullDiskAccess: fullDiskAccessStep
            case .moreSources: moreSourcesStep
            // Pages of More sources since 2026-09-24.
            case .books: booksStep
            case .courses: coursesStep
            case .meetings: meetingsStep
            case .youtube: youtubeStep
            // No longer in `onboardingOrder`; kept for their synced bits.
            case .storage, .planner, .memory, .ideas, .artifacts, .assistants: EmptyView()
            }
        case .addToFullDiskAccess: addToFullDiskAccessPage
        case .readLaterImport: readLaterPage
        case .papers(let route): paperRoutePage(route)
        case .moreSource(let source): moreSourcePage(source)
        case .connect(let assistant): connectPage(assistant)
        }
    }

    /// Opens a follow-up page over the current one.
    private func show(_ next: GettingStartedPage) {
        withAnimation(.easeInOut(duration: 0.2)) { pages.append(next) }
        if case .moreSource(let source) = next {
            startSourceAutoSync(for: source)
        }
    }

    /// Leaves for another step's question, as "Allow Full Disk Access" does
    /// from a step that cannot read without it.
    private func go(to destination: GettingStartedStep) {
        withAnimation(.easeInOut(duration: 0.2)) {
            pages = []
            step = destination
        }
    }

    // MARK: Page parts

    /// The one thing to do on a page.
    private func primaryAction(
        _ title: String,
        inFlight: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if inFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Text(title)
                }
            }
            .frame(minWidth: 170)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(inFlight)
    }

    /// The quiet way round, under the one thing to do.
    private func secondaryAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func doneLabel(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(.green)
            .multilineTextAlignment(.center)
    }

    private func pageNote(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorNote(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One answer to a question: a full-width row the learner clicks. A
    /// single-answer question moves on at the click; one taking several
    /// answers ticks the row (`isSelected` non-nil) and waits for Continue.
    private func choiceRow(
        icon: String? = nil,
        logo: AISubscription? = nil,
        title: String,
        detail: String? = nil,
        recommended: Bool = false,
        isSelected: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let selected = isSelected == true
        return Button(action: action) {
            HStack(spacing: 14) {
                if let logo {
                    subscriptionMark(logo)
                        .frame(width: 24, height: 24)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        if recommended { RecommendedBadge() }
                    }
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let isSelected {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Where a step's export lives in each app, under its Choose button.
    private func exportHints(_ hints: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where to find the export")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(hints.indices, id: \.self) { index in
                Text("**\(hints[index].0)**: \(hints[index].1)")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .setupCard()
    }

    /// What a one-time import is doing or did.
    @ViewBuilder
    private func importOutcome(_ action: String, isImporting: Bool, status: String?) -> some View {
        if isImporting, let status {
            Label(status, systemImage: "hourglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        if let summary = oneTimeImportResults[action] {
            doneLabel(summary)
        }
        if let error = oneTimeImportErrors[action] {
            errorNote(error)
        }
    }

    /// A step that reads something macOS guards, asked before access is on:
    /// one sentence, and the way to the step that turns it on.
    private func needsFullDiskAccess(_ text: String) -> some View {
        VStack(spacing: 14) {
            pageNote(text)
            primaryAction("Allow Full Disk Access") { go(to: .fullDiskAccess) }
        }
    }

    // MARK: Podcasts

    /// The product owner, 2026-09-24: the learner chooses which shows to bring
    /// in before anything is imported. The import itself starts when they move
    /// on (`completeAndAdvance`), so a show turned away is never fetched or
    /// cleaned up.
    private var podcastStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: GettingStartedStep.podcasts.icon,
                title: "Which podcasts do you learn from?",
                detail: "Tick the shows to bring in from Apple Podcasts. The episodes you play come in on their own."
            )
            if vm.needsPodcastAccess || !hasFullDiskAccess {
                needsFullDiskAccess("ForeverLM can read Apple Podcasts once it has Full Disk Access.")
            } else {
                PodcastShowChooser(showCount: $podcastInventoryCount)
            }
        }
    }

    // MARK: Articles

    /// The product owner, 2026-09-24: setting up the Reading List is the step,
    /// not waiting for a first save. A read-later app's library can come over
    /// instead, on a page of its own.
    private var articleStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: "globe",
                title: "Which browsers do you save pages in?",
                detail: "Pages you add to a browser's Reading List come into ForeverLM. Tick every browser you use."
            )
            ReadingListBrowserChoices(isEnabled: readingListBrowserBinding)
            if vm.needsBrowserAccess {
                needsFullDiskAccess("ForeverLM can read your Reading Lists once it has Full Disk Access.")
            } else if let readingListCaption {
                pageNote(readingListCaption)
            }
            secondaryAction("Coming from Readwise, Instapaper or Pocket?") { show(.readLaterImport) }
        }
    }

    /// How to save a page, in the learner's browser's own words, once one is
    /// ticked. Only the last 30 days come in at first, which Settings ›
    /// Sources changes.
    private var readingListCaption: String? {
        let browsers = ReadingListBrowser.allCases.filter(enabledReadingListBrowsers.contains)
        guard let first = browsers.first else { return nil }
        let how = browsers.count == 1 ? first.saveInstruction : "Save a page to its Reading List"
        return "\(how), and it comes in here. Pages from the last 30 days come in now."
    }

    /// A read-later app's export, read once. Nothing keeps syncing with the
    /// app afterwards.
    private var readLaterPage: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: "tray.and.arrow.down",
                title: "Bring over your read-later app",
                detail: "Export your saved articles from the app, then choose the export here. ForeverLM copies them once and never changes the app."
            )
            primaryAction(
                "Choose Export…",
                inFlight: workingAction == "read-later" || vm.isImportingReadLaterExport
            ) {
                importOnce("read-later", types: Self.readLaterContentTypes,
                           message: "Choose the CSV, HTML or JSON export, or its unzipped folder") { urls in
                    let report = try await vm.importReadLaterExport(from: urls)
                    return (report.summary, report.warnings)
                }
            }
            importOutcome("read-later", isImporting: vm.isImportingReadLaterExport, status: vm.readLaterImportStatus)
            exportHints([
                ("Readwise Reader", "Settings › Export, then choose the CSV."),
                ("Instapaper", "Settings › Export, then choose the CSV or HTML file."),
                ("Raindrop", "Settings › Backups, then choose the CSV or HTML file."),
                ("Pocket, Omnivore, others", "choose the export file, or the unzipped export folder.")
            ])
        }
    }

    // MARK: Papers

    /// The product owner, 2026-09-24: papers come over from where they live.
    /// The question names the places, and each answer has a page with its one
    /// way in: Zotero, found on this Mac, in one click; another manager's
    /// export; or PDFs dropped in.
    private var paperStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: "doc.text.magnifyingglass",
                title: "Where do your papers live?",
                detail: "Pick one. You can add papers from anywhere later."
            )
            VStack(spacing: 10) {
                if hasZoteroLibrary == true {
                    choiceRow(icon: "books.vertical", title: "Zotero", detail: "Found on this Mac") {
                        show(.papers(.zotero))
                    }
                }
                choiceRow(
                    icon: "books.vertical",
                    title: hasZoteroLibrary == true ? "Another reference manager" : "A reference manager",
                    detail: "Paperpile, Mendeley, EndNote and others"
                ) {
                    show(.papers(.referenceManager))
                }
                choiceRow(icon: "doc", title: "PDFs on this Mac") {
                    show(.papers(.pdfs))
                }
                choiceRow(icon: "xmark.circle", title: "I don't have any yet") {
                    completeAndAdvance()
                }
            }
            .frame(maxWidth: 440)
        }
    }

    /// The page for the place picked. Papers are fetched and tidied up in
    /// the background, so the page shows them coming in and Continue does not
    /// wait for the end.
    @ViewBuilder
    private func paperRoutePage(_ route: GettingStartedPaperRoute) -> some View {
        VStack(spacing: 24) {
            switch route {
            case .zotero:
                stepHeading(
                    icon: "books.vertical",
                    title: "Bring over your Zotero library",
                    detail: "ForeverLM copies your papers once. Zotero itself is never changed."
                )
                ZoteroImportCard()
            case .referenceManager:
                stepHeading(
                    icon: "books.vertical",
                    title: "Bring over your reference manager",
                    detail: "Export your library as BibTeX or RIS, then choose the export here. Papers without a PDF are fetched by their DOI."
                )
                primaryAction(
                    "Choose Export…",
                    inFlight: workingAction == "reference-library" || vm.isImportingReferenceLibrary
                ) {
                    importOnce("reference-library", types: Self.referenceLibraryContentTypes,
                               message: "Choose a Zotero folder, a BibTeX or RIS export, or a folder of PDFs") { urls in
                        try await vm.importReferenceLibrary(from: urls).summaryAndWarnings
                    }
                }
                importOutcome(
                    "reference-library",
                    isImporting: vm.isImportingReferenceLibrary,
                    status: vm.referenceLibraryImportStatus
                )
                // A one-time move, not a connector: nothing keeps watching the
                // manager afterwards (docs-site/papers.md says why).
                exportHints([
                    ("Paperpile", "export BibTeX into the Paperpile folder Google Drive syncs, then choose that folder."),
                    ("Mendeley", "export your library as BibTeX and choose the file."),
                    ("Zotero", "choose the Zotero folder in your home folder, the one holding zotero.sqlite."),
                    ("EndNote, JabRef, ReadCube", "export BibTeX or RIS, or choose a folder of PDFs.")
                ])
            case .pdfs:
                stepHeading(
                    icon: "doc",
                    title: "Add your PDFs",
                    detail: "Drop them below, or choose them. You can carry on while they come in."
                )
                fileDropZone(
                    "Drop PDFs here",
                    icon: "arrow.down.doc",
                    types: [.pdf],
                    chooseTitle: "Choose PDFs…"
                ) { url in
                    _ = try await vm.importPDF(from: url.path, selectInReader: false)
                }
            }
            SourceCleanupProgress(types: [.paper], task: .paperNarrationPreparation)
        }
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

    // MARK: YouTube

    /// One question at a time: connect the account, then which videos come
    /// in, then (for likes) whether the old ones do too.
    private var youtubeStep: some View {
        VStack(spacing: 24) {
            if !isYouTubeSignedIn {
                stepHeading(
                    icon: "play.rectangle.fill",
                    title: "Connect YouTube",
                    detail: "Sign in to YouTube, then choose which of your videos come into ForeverLM."
                )
                primaryAction("Connect YouTube", inFlight: workingAction == "youtube-connect") {
                    run("youtube-connect") { await connectYouTube() }
                }
                .disabled(!YouTubeService.shared.canConnect)
            } else if showYouTubeSourceChoice || (youtubeAccount?.choices.source == nil && !isChoosingLikedVideos) {
                stepHeading(
                    icon: "play.rectangle.fill",
                    title: "Which videos should come in?",
                    detail: "Only the videos you pick come in, never your whole history."
                )
                VStack(spacing: 10) {
                    choiceRow(
                        icon: "list.bullet.rectangle",
                        title: "A playlist named ForeverLM",
                        detail: "Add a video to it on YouTube and it comes in.",
                        recommended: true
                    ) {
                        showYouTubeSourceChoice = false
                        isChoosingLikedVideos = false
                        configureForeverLMPlaylist()
                    }
                    choiceRow(
                        icon: "hand.thumbsup",
                        title: "Videos I like",
                        detail: "Like a video on YouTube and it comes in."
                    ) {
                        showYouTubeSourceChoice = false
                        isChoosingLikedVideos = true
                    }
                }
                .frame(maxWidth: 440)
                .disabled(workingAction != nil)
                actionProgress("youtube-source")
            } else if isChoosingLikedVideos
                || (youtubeAccount?.choices.source == .likedVideos && youtubeAccount?.choices.likedPolicy == .undecided) {
                stepHeading(
                    icon: "hand.thumbsup",
                    title: "Bring in the videos you've already liked?",
                    detail: "Nothing comes in until you choose."
                )
                VStack(spacing: 10) {
                    choiceRow(
                        icon: "clock.arrow.circlepath",
                        title: "No, only new likes",
                        detail: "Your library starts with what you like from now on.",
                        recommended: true
                    ) {
                        configureYouTube(.futureOnly)
                    }
                    choiceRow(
                        icon: "tray.full",
                        title: "Yes, bring in my liked videos",
                        detail: "This can spend a lot on AI for a long history."
                    ) {
                        configureYouTube(.importExisting)
                    }
                }
                .frame(maxWidth: 440)
                .disabled(workingAction != nil)
                Toggle("Format transcripts with AI", isOn: $automaticallyFormatLikedVideoTranscripts)
                actionProgress("youtube-policy")
            } else if let source = youtubeAccount?.choices.source {
                stepHeading(
                    icon: "play.rectangle.fill",
                    title: "YouTube is connected",
                    detail: source == .likedVideos
                        ? "Like a video on YouTube and it comes in here."
                        : "Add a video to your ForeverLM playlist on YouTube and it comes in here."
                )
                if let video = newestYouTubeVideo {
                    detectedSourceCard(video, label: "Last video in")
                }
                secondaryAction("Change which videos come in") {
                    showYouTubeSourceChoice = true
                    isChoosingLikedVideos = false
                }
            }
            if let youtubeError {
                errorNote(youtubeError)
            }
        }
    }

    // MARK: Books

    private var booksStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: "book.closed",
                title: "Add your books",
                detail: "Drop EPUBs or PDFs below. ForeverLM splits each one into chapters."
            )
            fileDropZone(
                "Drop EPUBs or PDFs here",
                icon: "arrow.down.doc",
                types: supportedBookImportContentTypes,
                chooseTitle: "Choose Books…"
            ) { url in
                try await vm.importBook(from: url.path)
            }
            if !vm.bookImportStatus.isEmpty {
                Label(vm.bookImportStatus, systemImage: "hourglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let book = newestSource(of: .book) {
                detectedSourceCard(book, label: "Last book added")
            }
            appleBooksImport
        }
    }

    /// The books already in Apple Books, behind one quiet button until asked
    /// for, then a list to tick.
    @ViewBuilder
    private var appleBooksImport: some View {
        if let appleBooks {
            VStack(alignment: .leading, spacing: 10) {
                if appleBooks.books.isEmpty {
                    Text(appleBooks.cloudOnlyCount > 0
                        ? "Your Apple Books are still in iCloud. Open one in Apple Books to download it, then look again."
                        : "No EPUB or PDF books found in Apple Books. Books bought in the Book Store are protected and cannot be imported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Look Again") { scanAppleBooks() }
                } else {
                    Text("Your Apple Books")
                        .font(.headline)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .setupCard()
        } else {
            HStack(spacing: 8) {
                secondaryAction("Import from Apple Books instead") { scanAppleBooks() }
                actionProgress("apple-books-scan")
            }
        }
    }

    private func scanAppleBooks() {
        run("apple-books-scan") {
            let scan = await Task.detached(priority: .userInitiated) {
                AppleBooksLibrary.scan()
            }.value
            appleBooks = scan
            selectedAppleBooks = Set(scan.books.map(\.path))
        }
    }

    // MARK: More sources

    /// Books, courses, meetings and YouTube (product owner, 2026-09-24: fewer
    /// screens). The question asks which the learner uses, and only those get
    /// a page, one after another; the rest can be set up later from their
    /// place in the sidebar.
    private var moreSourcesStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: GettingStartedStep.moreSources.icon,
                title: "What else do you learn from?",
                detail: "Tick any you use. Each one gets set up next."
            )
            VStack(spacing: 10) {
                ForEach(GettingStartedStep.moreSourceRows) { source in
                    choiceRow(
                        icon: source.icon,
                        title: source.title,
                        detail: moreSourceHint(source),
                        isSelected: moreSourcePicks.contains(source)
                    ) {
                        noMoreSources = false
                        if moreSourcePicks.contains(source) {
                            moreSourcePicks.remove(source)
                        } else {
                            moreSourcePicks.insert(source)
                        }
                    }
                }
                choiceRow(icon: "xmark.circle", title: "None of these", isSelected: noMoreSources) {
                    noMoreSources.toggle()
                    if noMoreSources { moreSourcePicks = [] }
                }
            }
            .frame(maxWidth: 440)
        }
    }

    /// The picks in the question's order, which is the order their pages come in.
    private var orderedMoreSourcePicks: [GettingStartedStep] {
        GettingStartedStep.moreSourceRows.filter(moreSourcePicks.contains)
    }

    @ViewBuilder
    private func moreSourcePage(_ source: GettingStartedStep) -> some View {
        switch source {
        case .books: booksStep
        case .courses: coursesStep
        case .meetings: meetingsStep
        case .youtube: youtubeStep
        default: EmptyView()
        }
    }

    private func moreSourceHint(_ source: GettingStartedStep) -> String {
        switch source {
        case .books: return "EPUBs, PDFs and your Apple Books library"
        case .courses: return "A YouTube lecture series, one lecture per video"
        case .meetings: return "Zoom meeting transcripts"
        case .youtube: return "The videos you like, or a playlist named ForeverLM"
        default: return ""
        }
    }

    private var coursesStep: some View {
        VStack(spacing: 24) {
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let course = newestCourseLecture {
                detectedSourceCard(course, label: "Course added")
            }
        }
    }

    /// Zoom saves its recordings to a folder on this Mac; ForeverLM watches it.
    /// Other meeting tools are plugins, one quiet link away.
    private var meetingsStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: "person.2.wave.2",
                title: "Bring in your Zoom meetings",
                detail: "ForeverLM watches the folder Zoom saves recordings to, and adds each meeting's transcript on its own."
            )
            VStack(spacing: 10) {
                Text(zoomFolderDisplayPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose a Different Folder…") { chooseZoomFolder() }
            }
            .frame(maxWidth: .infinity)
            .setupCard()
            if let meeting = newestSource(of: .meeting) {
                detectedSourceCard(meeting, label: "Last meeting in")
            }
            secondaryAction("Using Google Meet, Slack or Notion? Connect them in Plugins") {
                // Plugins is a place in the window, under the guide, so the
                // guide steps aside for it; setup picks up here next time.
                isPresented = false
                PluginsPlace.requestOpen()
            }
        }
    }

    // MARK: Your AI

    /// What the learner said they pay for; nil until the question is answered,
    /// empty for "no".
    private var aiSubscriptions: Set<AISubscription>? {
        AISubscription.decode(aiSubscriptionAnswer)
    }

    private var paysForAISubscription: Bool {
        aiSubscriptions.map { !$0.isEmpty } ?? false
    }

    /// The picks in the question's order, which is the order their pages come in.
    private var orderedAISubscriptions: [AISubscription] {
        AISubscription.allCases.filter { aiSubscriptions?.contains($0) == true }
    }

    /// The product owner, 2026-09-23: ask whether the learner already pays for an AI
    /// app. Each app ticked then gets a page that adds ForeverLM to it
    /// (2026-09-24), which is why this closes Setup: by then the library holds
    /// what the connector reaches. Any number may be ticked; "No" clears them.
    private var subscriptionsStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: GettingStartedStep.subscriptions.icon,
                title: "Do you already pay for an AI app?",
                detail: "Tick every one you pay for. Next, you add ForeverLM to each, so it can reach your library."
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
            // The product owner, 2026-09-24: show the connector at work in an AI app,
            // so "works inside the AI app you already use" is seen, not read.
            if !paysForAISubscription, let url = WelcomeClipPlayer.url(named: Self.connectorClip) {
                VStack(spacing: 8) {
                    WelcomeClipPlayer(url: url)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .frame(maxWidth: 440)
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
    }

    // MARK: Connecting an AI app

    /// The product owner, 2026-09-24: saying which AI apps you pay for leads
    /// straight to connecting them, one page per app: its steps, the address
    /// to paste, the page to do it on and, when WelcomeClipsResources has one,
    /// a clip of the steps being done. The page turns green on its own once
    /// the gateway sees the app sign in.
    private func connectPage(_ assistant: AISubscription) -> some View {
        let isConnected = connectedAssistants?.contains(assistant) == true
        return VStack(spacing: 24) {
            VStack(spacing: 10) {
                subscriptionMark(assistant)
                    .frame(width: 40, height: 40)
                Text(assistant == .other ? "Add ForeverLM to your AI app" : "Add ForeverLM to \(assistant.title)")
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)
                if isConnected {
                    doneLabel("Connected")
                } else {
                    Text("Follow these steps, then come back here.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(assistant.connectorSteps.enumerated()), id: \.offset) { index, text in
                    instruction("\(index + 1)", text)
                }
                HStack {
                    Text(Self.connectorURL)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button(copiedConnectorURL ? "Copied" : "Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.connectorURL, forType: .string)
                        copiedConnectorURL = true
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if let note = assistant.connectorNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .setupCard()

            if !isConnected {
                if let page = assistant.connectorPage {
                    primaryAction(page.title) { open(page.url) }
                }
                if connectedAssistants != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(assistant == .other ? "Waiting for your AI app" : "Waiting for \(assistant.title)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
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
        }
        .task { await watchConnectedAssistants() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Connecting happens in the browser; see it on the way back.
            Task { if let latest = await ConnectedAssistants.fetch() { connectedAssistants = latest } }
        }
    }

    /// Re-read while a connect page is on screen: the learner connects in
    /// another app, and the page should turn green without anyone pressing
    /// anything.
    private func watchConnectedAssistants() async {
        while !Task.isCancelled {
            if let latest = await ConnectedAssistants.fetch() { connectedAssistants = latest }
            try? await Task.sleep(for: .seconds(8))
        }
    }

    // MARK: Full Disk Access

    /// The product owner, 2026-09-24: ask for Full Disk Access during setup rather than
    /// only when a Podcasts or Reading List scan is found blocked. macOS never
    /// lists ForeverLM there on its own, and applies the grant only at launch,
    /// so the step is two pages with one thing to do on each: open System
    /// Settings, then add the app and relaunch. Setup comes back to it after
    /// the relaunch. It can be skipped: only Apple Podcasts and the Reading
    /// Lists need it.
    private var fullDiskAccessStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: GettingStartedStep.fullDiskAccess.icon,
                title: "Allow Full Disk Access",
                detail: "So ForeverLM can read Apple Podcasts and your browsers' Reading Lists. macOS asks you to allow it once."
            )
            if hasFullDiskAccess {
                doneLabel("Full Disk Access is on")
            } else {
                primaryAction("Open System Settings") {
                    FullDiskAccess.openSettings()
                    show(.addToFullDiskAccess)
                }
            }
        }
    }

    private var addToFullDiskAccessPage: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: "plus.circle",
                title: "Add \(ForeverLMRuntimeIdentity.displayName) to the list",
                detail: isDevelopmentBuild
                    ? "In System Settings, click \"+\" under the list, choose this exact \(ForeverLMRuntimeIdentity.displayName) app, and turn it on."
                    : "In System Settings, click \"+\" under the list, choose ForeverLM in Applications, and turn it on."
            )
            if hasFullDiskAccess {
                doneLabel("Full Disk Access is on")
            } else {
                if isDevelopmentBuild {
                    VStack(spacing: 8) {
                        Text(Bundle.main.bundleURL.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Reveal App") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                    }
                }
                VStack(spacing: 10) {
                    primaryAction("Relaunch \(ForeverLMRuntimeIdentity.displayName)") { FullDiskAccess.relaunch() }
                    pageNote("Once it is turned on, relaunch. macOS applies the access only when the app starts, and Setup comes back here.")
                }
                secondaryAction("Open System Settings again") { FullDiskAccess.openSettings() }
            }
        }
    }

    /// The First Run app reads the production steps: it stands in for a new
    /// learner, who has no Dev copy to tell apart from the installed one.
    private var isDevelopmentBuild: Bool {
        ForeverLMRuntimeIdentity.isDevelopment && !ForeverLMRuntimeIdentity.isFirstRun
    }

    // MARK: AI

    /// Setup's AI step is two pages, one question each (product owner,
    /// 2026-10-11: "more like a Typeform"): connect OpenRouter, then pick the
    /// models. AI features run on the learner's own OpenRouter key, billed by
    /// OpenRouter at cost; the free days run the key, so there is no plan row
    /// (the paid app, 2026-10-10). The data policy and the single Chat model
    /// left setup for Settings. Pressing Continue on the models page
    /// is also the consent to background work, which that page says.
    private var enhancementsStep: some View {
        Group {
            switch aiPage {
            case .key: openRouterKeyPage
            case .models: GettingStartedModelsPage(isReady: $modelsReady)
            }
        }
        .frame(maxWidth: .infinity)
        .id(aiPage)
        .transition(.opacity)
    }

    private var openRouterKeyPage: some View {
        VStack(spacing: 28) {
            stepHeading(
                icon: "key.fill",
                title: "Connect OpenRouter",
                detail: "ForeverLM's AI runs on your own OpenRouter account."
            )
            if let own = account.ownKey {
                Label("Connected · key ending in \(own.suffix)", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 14) {
                    // Signing in at OpenRouter hands the app a key; pasting one
                    // stays for anyone who already has a key to hand.
                    Button {
                        Task { await account.connectOpenRouter() }
                    } label: {
                        Group {
                            if account.openRouterConnectInFlight {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Connect OpenRouter")
                            }
                        }
                        .frame(minWidth: 170)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(account.openRouterConnectInFlight || ownKeySaving)
                    .accessibilityIdentifier("gettingStarted.connectOpenRouter")

                    if account.openRouterConnectInFlight {
                        Text("Finish in your browser, then come back.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if showsKeyField {
                        HStack(spacing: 8) {
                            SecureField("OpenRouter key", text: $ownKeyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
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
                    } else {
                        Button("Paste a key instead") { showsKeyField = true }
                            .buttonStyle(.plain)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let message = account.errorMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
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

    /// Back on the left, and on the right one way forward: Continue once the
    /// page is answered (Return presses it), Skip while it may be left
    /// unanswered, never both.
    private var footer: some View {
        HStack {
            Button("Back") { goBack() }
                .buttonStyle(.hoverWash)
                .foregroundStyle(.secondary)
            Spacer()
            switch forward {
            case .skip:
                Button("Skip this step") { completeAndAdvance() }
            case .next, .finish, .waiting:
                Button(forward == .finish ? "Finish" : "Continue") { goForward() }
                    .buttonStyle(.borderedProminent)
                    .disabled(forward == .waiting)
                    .keyboardShortcut(returnContinues ? .defaultAction : nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var forward: GettingStartedFlow.Forward {
        GettingStartedFlow.forward(canContinue: canContinue, canSkip: canSkip, isLast: isLastPage)
    }

    /// Whether the page may be left unanswered. The AI step may not; the
    /// Papers, More sources and Your AI questions carry their own "none"
    /// answer, so they need no Skip beside it.
    private var canSkip: Bool {
        switch step {
        case .enhancements: return false
        case .paper, .moreSources, .subscriptions: return page != nil
        default: return true
        }
    }

    /// A page with a text field keeps Return for the field.
    private var returnContinues: Bool {
        if step == .enhancements, aiPage == .key, showsKeyField { return false }
        return page != .moreSource(.courses)
    }

    private var isLastPage: Bool {
        nextIncompleteStep == nil && nextPage == nil && !(step == .enhancements && aiPage == .key)
    }

    /// The page Continue opens before the step is done: the next source or
    /// AI app picked on the question.
    private var nextPage: GettingStartedPage? {
        switch (step, page) {
        case (.moreSources, nil):
            return GettingStartedFlow.next(after: nil, in: orderedMoreSourcePicks).map { .moreSource($0) }
        case (.moreSources, .some(.moreSource(let current))):
            return GettingStartedFlow.next(after: current, in: orderedMoreSourcePicks).map { .moreSource($0) }
        case (.subscriptions, nil):
            return GettingStartedFlow.next(after: nil, in: orderedAISubscriptions).map { .connect($0) }
        case (.subscriptions, .some(.connect(let current))):
            return GettingStartedFlow.next(after: current, in: orderedAISubscriptions).map { .connect($0) }
        default:
            return nil
        }
    }

    private func goForward() {
        // The key page leads to the models page; the models page says
        // background work draws on what they chose.
        if step == .enhancements, aiPage == .key {
            withAnimation(.easeInOut(duration: 0.2)) { aiPage = .models }
            return
        }
        if let nextPage {
            show(nextPage)
            return
        }
        if step == .enhancements { hasConsentedToBackgroundAIUsage = true }
        openDetectedSourceForCurrentStep()
        completeAndAdvance()
    }

    /// Closes the newest page, else goes to the step before, else to the welcome.
    private func goBack() {
        if !pages.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) { _ = pages.removeLast() }
        } else if step == .enhancements, aiPage == .models {
            withAnimation(.easeInOut(duration: 0.2)) { aiPage = .key }
        } else if let previous = previousStep {
            go(to: previous)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { welcomeOverride = true }
        }
    }

    private func readingListBrowserBinding(_ browser: ReadingListBrowser) -> Binding<Bool> {
        Binding(
            get: { enabledReadingListBrowsers.contains(browser) },
            set: { isOn in
                browser.setEnabled(isOn)
                if isOn {
                    enabledReadingListBrowsers.insert(browser)
                } else {
                    enabledReadingListBrowsers.remove(browser)
                }
                vm.readingListBrowsersDidChange()
            }
        )
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

    private var youtubeAccount: YouTubeAccount? {
        vm.youtubeAccount(id: youtubeAccountID ?? "") ?? vm.youtubeAccounts.first
    }

    private var newestYouTubeVideo: StudioArticle? {
        vm.activeArticles
            .filter { $0.discoveryOrigin == .youtubePlaylist && $0.sourceType == .video }
            .max(by: { $0.dateAdded < $1.dateAdded })
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
            return (youtubeAccount?.choices.source != nil && newestYouTubeVideo != nil)
                || newestSource(of: .video) != nil
        // The question waits for a pick or "None of these"; the pages after
        // it can each be left as they are.
        case .moreSources:
            return page != nil || !moreSourcePicks.isEmpty || noMoreSources
        case .planner, .memory, .ideas, .artifacts, .assistants:
            return true
        case .enhancements:
            switch aiPage {
            case .key:
                return GettingStartedAIPayment.isReady(
                    hasOwnKey: account.ownKey != nil,
                    ownKeyAllowed: account.ownKeyAllowed,
                    canPayWithoutKey: hasUsableForeverLMCredits
                )
            case .models:
                return modelsReady
            }
        case .storage:
            return true
        // Connecting an app can wait, so its page never holds Setup up.
        case .subscriptions:
            return page != nil || aiSubscriptions != nil
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
        go(to: next)
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

    /// What a step reads before its question can be asked.
    private func prepare(_ step: GettingStartedStep) async {
        switch step {
        case .enhancements:
            await account.reloadOwnKey()
            await account.refresh(silently: true)
        case .paper where hasZoteroLibrary == nil:
            // Zotero gets its own answer only when it keeps a library here.
            let homeDir = BookmarkAccessManager.realHomeDirectory
            hasZoteroLibrary = await Task.detached(priority: .userInitiated) {
                ReferenceLibraryImportService.zoteroDataDirectory(homeDir: homeDir) != nil
            }.value
        default:
            break
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
            let account = try await YouTubeService.shared.authenticate()
            await vm.reloadYouTubeAccounts()
            youtubeAccountID = account.id
            isYouTubeSignedIn = YouTubeService.shared.isSignedIn
            youtubeError = nil
        } catch {
            youtubeError = error.localizedDescription
        }
    }

    private func configureYouTube(_ policy: YouTubeLikedImportPolicy) {
        guard let accountID = youtubeAccount?.id else { return }
        run("youtube-policy") {
            _ = await vm.configureYouTubeLikedVideos(
                policy,
                accountID: accountID,
                automaticallyFormatTranscripts: automaticallyFormatLikedVideoTranscripts
            )
            isChoosingLikedVideos = false
        }
    }

    private func configureForeverLMPlaylist() {
        guard let accountID = youtubeAccount?.id else { return }
        run("youtube-source") {
            let groupID = await vm.followYouTubeForeverLMPlaylist(accountID: accountID)
            guard groupID != nil else {
                youtubeError = vm.errorMessage ?? "Could not find your ForeverLM playlist."
                return
            }
        }
    }

    private func stepHeading(icon: String, title: String, detail: String) -> some View {
        SetupStepHeading(icon: icon, title: title, detail: detail)
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number)
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    @ViewBuilder
    private func actionProgress(_ action: String) -> some View {
        if workingAction == action {
            ProgressView().controlSize(.small)
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
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

}

/// A page's icon, its question and one line on what to do.
private struct SetupStepHeading: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
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
                text: "ForeverLM keeps track of what you read and writes quizzes on what you want to stick."
            )
            promise(
                icon: Self.yourAIIcon,
                title: "You’re in charge of your AI.",
                text: "Pick the models on your own OpenRouter key, at cost, or free ones. It works with the AI app you already pay for, too."
            )
            VStack(alignment: .leading, spacing: 12) {
                promise(
                    icon: Self.yourDataIcon,
                    title: "You’re in charge of your data.",
                    text: "Your library lives on this Mac and syncs through your own iCloud. ForeverLM keeps no copy of your chats."
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
            // What ForeverLM costs, said once at the start (product owner,
            // 2026-10-10): the count and the price are the account server's.
            Text(EarlyUserDealOffer.headline(
                onceCents: ManagedAI.appAccess?.prices.onceCents,
                freeDays: ManagedAI.appAccess?.freeDaysTotal
            ))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("welcome.price")
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

/// Setup's models page (product owner, 2026-09-28, then 2026-10-11): the whole
/// set in one step (`RecommendedModels`) on one card, with the rest behind
/// "Choose my own". What it would take is read when the page appears and said
/// before it is taken. Free models run only once OpenRouter's privacy settings
/// allow them, so a refusal is the one thing the page raises, and Continue
/// waits for it.
private struct GettingStartedModelsPage: View {
    @Binding var isReady: Bool

    @State private var choice: RecommendedModels.Choice?
    @State private var loadError: String?
    @State private var isApplied = false
    @State private var working = false
    @State private var applyError: String?
    /// Nil until checked, or while a check runs.
    @State private var access: FreeModelAccess.Verdict?
    @State private var isChecking = false
    @State private var choosingMyself = false
    /// The Background rows' word, for the learner who chooses their own.
    @State private var ownChoiceReady = true

    var body: some View {
        VStack(spacing: 24) {
            SetupStepHeading(
                icon: "sparkles",
                title: "Pick your models",
                detail: "We chose these for you. Change them any time in Settings."
            )

            if choosingMyself {
                ownChoice
            } else {
                recommended
            }

            VStack(spacing: 6) {
                if !choosingMyself {
                    Text("ForeverLM also runs AI on its own, on transcripts, read-aloud and titles.")
                }
                Link(ManagedAI.OwnKeyRouter.openRouter.creditsLinkTitle, destination: ManagedAI.OwnKeyRouter.openRouter.creditsURL)
                    .accessibilityIdentifier("gettingStarted.openRouterCredits")
                    .help("Free models answer 50 requests a day until you have bought $10 of credits in total, then 1,000.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .task {
            await load()
            updateReadiness()
        }
        .onChange(of: isApplied) { _, _ in
            access = nil
            updateReadiness()
            Task { await checkAccess() }
        }
        .onChange(of: choosingMyself) { _, _ in updateReadiness() }
        .onChange(of: ownChoiceReady) { _, _ in updateReadiness() }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderDidChange).receive(on: RunLoop.main)) { _ in
            Task { await readApplied() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange).receive(on: RunLoop.main)) { _ in
            // The key decides whether background work can start free.
            Task { await load() }
        }
        // Back from OpenRouter's privacy page in the browser.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard isApplied, access != .allowed else { return }
            Task { await checkAccess() }
        }
    }

    // MARK: The recommended set

    @ViewBuilder
    private var recommended: some View {
        if let choice {
            VStack(spacing: 18) {
                VStack(spacing: 0) {
                    row("Chat", choice.chat.model.name)
                    Divider()
                    row("Background", backgroundName(choice))
                }
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 400)

                if isApplied {
                    appliedStatus
                } else {
                    Button {
                        apply(choice)
                    } label: {
                        Group {
                            if working {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Use these models")
                            }
                        }
                        .frame(minWidth: 170)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(working)
                    .accessibilityIdentifier("gettingStarted.recommendedModels")
                }

                if let applyError {
                    Label(applyError, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Choose my own") { choosingMyself = true }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let loadError {
            VStack(spacing: 10) {
                Label(loadError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Try Again") { Task { await load() } }
                    Button("Choose my own") { choosingMyself = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func row(_ role: String, _ name: String) -> some View {
        HStack {
            Text(role)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(name)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func backgroundName(_ choice: RecommendedModels.Choice) -> String {
        choice.freeText == nil ? choice.backup.model.name : "Free, then \(choice.backup.model.name)"
    }

    @ViewBuilder
    private var appliedStatus: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if isChecking {
                    ProgressView().controlSize(.small)
                }
            }
            if access == .refused {
                Text(FreeModelAccess.refusedExplanation)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                HStack(spacing: 14) {
                    Link("Open OpenRouter privacy settings", destination: FreeModelsSetup.openRouterPrivacyURL)
                    Button("Check Again") { Task { await checkAccess() } }
                        .disabled(isChecking)
                }
                .font(.caption)
            } else if case .unknown(let message)? = access {
                Text("Could not check whether OpenRouter allows free models: \(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }
        }
    }

    // MARK: Choosing their own

    private var ownChoice: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chat").font(.headline)
                GettingStartedChatModelChoice()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Background work").font(.headline)
                GettingStartedBackgroundModelChoice(isReady: $ownChoiceReady)
            }
            Button("Use the recommended models") { choosingMyself = false }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    // MARK: Readiness

    /// Continue waits for the set to be taken, and, while background work is
    /// free, for OpenRouter to allow free models. A check that failed for
    /// another reason says so and lets the learner go on.
    private func updateReadiness() {
        if choosingMyself { isReady = ownChoiceReady; return }
        guard isApplied, let choice else { isReady = false; return }
        guard choice.freeText != nil else { isReady = true; return }
        switch access {
        case nil, .refused?: isReady = false
        default: isReady = true
        }
    }

    private func checkAccess() async {
        guard isApplied, !isChecking, let free = choice?.freeText else { return }
        isChecking = true
        access = nil
        updateReadiness()
        let verdict = await Task.detached(priority: .userInitiated) {
            await FreeModelAccess.check(model: free.id)
        }.value
        isChecking = false
        guard isApplied else { return }
        access = verdict
        updateReadiness()
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
        updateReadiness()
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
/// paid model below.
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

    private let paid = KeychainService.defaultBackgroundTaskRoute

    private var choice: Choice {
        if AIFreeModels.isFreeSelection(provider: route.provider, model: route.model) { return .free }
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
                detail: AIModelListPrice.label(provider: paid.provider, modelID: paid.model)
                    .map { "Faster and more dependable. Paid through your OpenRouter key, \($0)" }
                    ?? "Faster and more dependable. Paid through your OpenRouter key",
                isEnabled: true
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
                meetingsChoice
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
