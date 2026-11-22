import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Real-data setup shown inside the normal Studio. Every step performs the same
/// action the learner will use later; there is no sample library or sandbox.
struct GettingStartedGuide: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(ManagedAIAccountModel.self) private var account
    @Binding var isPresented: Bool

    @PreferenceStorage(Prefs.Rail.gettingStartedCompleted) private var isCompleted
    @PreferenceStorage(Prefs.Rail.gettingStartedCompletedSteps) private var completedSteps
    /// Set by the welcome's Get Started. The first step's Relaunch comes back
    /// with no step done yet, and must land on that step, not replay the
    /// story. Kept on this Mac: the relaunch it bridges is this Mac's.
    @PreferenceStorage(Prefs.Rail.welcomeSeen) private var welcomeSeen
    @PreferenceStorage(Prefs.Rail.suggestionsArmed) private var arrivalSuggestionsArmed
    @PreferenceStorage(Prefs.Models.backgroundUsageConsented) private var hasConsentedToBackgroundAIUsage
    /// The AI step's two pages: the key, then the credits.
    @State private var aiPage: AIStepPage = .key
    /// The credits page's one question; nil until Yes opens the steps.
    @State private var hasPaidPlan: Bool?
    @PreferenceStorage(Prefs.Rail.aiSubscriptions) private var aiSubscriptionAnswer
    @PreferenceStorage(Prefs.Discovery.youtubeLikedTranscriptFormattingEnabled, default: false)
    private var automaticallyFormatLikedVideoTranscripts

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
    @State private var copiedConnectorURL = false
    /// The AI apps this account has connected, from the gateway; nil until read.
    @State private var connectedAssistants: Set<AISubscription>?
    @State private var zoomFolder = StudioViewModel.zoomLocalTranscriptCustomFolder
    /// Read at launch and whenever ForeverLM becomes active again, as it does
    /// on the way back from System Settings.
    @State private var hasFullDiskAccess = false
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
            hasFullDiskAccess = await FullDiskAccess.check()
            step = firstIncompleteStep
            startSourceAutoSync(for: step)
            await prepare(step)
        }
        .onChange(of: account.ownKey != nil) { wasConnected, isConnected in
            // The key arriving is the answer: show it a moment, then the next page.
            // Only from the key page itself: a learner reading the credits
            // page is left there, and its Continue goes on.
            guard isConnected, !wasConnected, step == .enhancements, aiPage == .key, page == nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                guard step == .enhancements, aiPage == .key, page == nil, canContinue else { return }
                withAnimation(.easeInOut(duration: 0.2)) { aiPage = .credits }
            }
        }
        .onChange(of: step) { _, newStep in
            if newStep == .enhancements {
                aiPage = .key
                hasPaidPlan = nil
            }
            startSourceAutoSync(for: newStep)
            Task { await prepare(newStep) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { hasFullDiskAccess = await FullDiskAccess.check() }
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
            WelcomeStory(startsAtEnd: welcomeOverride == true) {
                welcomeSeen = true
                withAnimation(.easeInOut(duration: 0.25)) { welcomeOverride = false }
            }
        }
    }

    /// The bar, and the × only on a guide reopened after setup was finished.
    /// The bar alone tells the progress — no section name in capitals, no
    /// "3 of 7" (product owner, 2026-10-06: "fewer buttons and bells and
    /// whistles"). First setup cannot be closed (product owner, 2026-11-21:
    /// "it shouldn't let you click away the onboarding; it's important to
    /// complete").
    private var header: some View {
        HStack(spacing: 12) {
            progressBar
            if isCompleted { closeButton }
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
            isPresented = false
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.hoverWash(in: Circle()))
        .help("Close")
        .accessibilityLabel("Close")
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
            // Pages of More sources.
            case .books: booksStep
            case .meetings: meetingsStep
            case .youtube: youtubeStep
            case .xPosts: xPostsStep
            // No longer in `onboardingOrder`; kept for their synced bits.
            case .storage, .planner, .memory, .ideas, .artifacts, .assistants, .courses: EmptyView()
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
                title: "Which podcasts should come in?",
                detail: "Tick the shows to bring in."
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
                title: "Which browsers do you use?",
                detail: ""
            )
            ReadingListBrowserChoices(isEnabled: readingListBrowserBinding)
            if vm.needsBrowserAccess {
                needsFullDiskAccess("ForeverLM can read your Reading Lists once it has Full Disk Access.")
            } else if let readingListCaption {
                pageNote(readingListCaption)
            }
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
                detail: "Choose your export. Your app is never changed."
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
                detail: ""
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
                    detail: "Copied once. Zotero is never changed."
                )
                ZoteroImportCard()
            case .referenceManager:
                stepHeading(
                    icon: "books.vertical",
                    title: "Bring over your reference manager",
                    detail: "Export as BibTeX or RIS, then choose the file."
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
                    detail: "Drop them below, or choose them."
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
                    detail: "Sign in, then choose what comes in."
                )
                primaryAction("Connect YouTube", inFlight: workingAction == "youtube-connect") {
                    run("youtube-connect") { await connectYouTube() }
                }
                .disabled(!YouTubeService.shared.canConnect)
            } else if showYouTubeSourceChoice || (youtubeAccount?.choices.source == nil && !isChoosingLikedVideos) {
                stepHeading(
                    icon: "play.rectangle.fill",
                    title: "Which videos should come in?",
                    detail: "Only what you pick comes in."
                )
                VStack(spacing: 10) {
                    choiceRow(
                        icon: "list.bullet.rectangle",
                        title: "A playlist named ForeverLM",
                        detail: "Add a video to it and it comes in.",
                        recommended: true
                    ) {
                        showYouTubeSourceChoice = false
                        isChoosingLikedVideos = false
                        configureForeverLMPlaylist()
                    }
                    choiceRow(
                        icon: "hand.thumbsup",
                        title: "Videos I like",
                        detail: "Like a video and it comes in."
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
                        detail: "Starts from now on.",
                        recommended: true
                    ) {
                        configureYouTube(.futureOnly)
                    }
                    choiceRow(
                        icon: "tray.full",
                        title: "Yes, bring in my liked videos",
                        detail: "A long history can cost a lot in AI."
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
                        ? "Like a video and it comes in."
                        : "Add a video to your playlist and it comes in."
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
                detail: "Drop EPUBs or PDFs below."
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
            Link("How about Kindle?", destination: URL(string: "https://docs.foreverlm.com/kindle")!)
                .font(.subheadline)
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

    /// Books, meetings, YouTube and X (product owner, 2026-09-24: fewer
    /// screens). The question asks which the learner uses, and only those get
    /// a page, one after another; the rest can be set up later from their
    /// place in the sidebar.
    private var moreSourcesStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: GettingStartedStep.moreSources.icon,
                title: "What else do you learn from?",
                detail: "Tick any you use."
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
        case .meetings: meetingsStep
        case .youtube: youtubeStep
        case .xPosts: xPostsStep
        default: EmptyView()
        }
    }

    private func moreSourceHint(_ source: GettingStartedStep) -> String {
        switch source {
        case .books: return "EPUBs, PDFs and your Apple Books library"
        case .meetings: return "Zoom meeting transcripts"
        case .youtube: return "The videos you like, or a playlist named ForeverLM"
        case .xPosts: return "Posts you bookmark on X"
        default: return ""
        }
    }

    /// Sign in with X; the posts the learner bookmarks come in, and the page
    /// can be left unconnected and done later from the X tab.
    private var xPostsStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: "text.bubble",
                title: vm.isXOAuthSignedIn ? "X is connected" : "Connect X",
                detail: vm.isXOAuthSignedIn
                    ? "Bookmarked posts come in."
                    : "Sign in, and bookmarked posts come in."
            )
            if !vm.isXOAuthSignedIn {
                primaryAction(
                    vm.isConnectingX ? "Connecting to X…" : "Connect X",
                    inFlight: vm.isConnectingX
                ) {
                    Task { await vm.signInWithX() }
                }
            }
            if let error = vm.xConnectError, !vm.isXOAuthSignedIn {
                errorNote(error)
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
                detail: "Each meeting's transcript comes in on its own."
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
            // Google Meet's notes and transcripts reach ForeverLM through the
            // Google Drive plugin; Slack and Notion bring no meetings, so they
            // are not named here. This is a docs link, not a jump to Plugins:
            // the jump closed the whole guide and dropped the learner in the
            // app mid-setup (reported 2026-11-20).
            Link(
                "Using Google Meet? Connect Google Drive",
                destination: URL(string: "https://docs.foreverlm.com/external-plugins#google-drive")!
            )
            .font(.subheadline)
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
    /// app. Each app ticked then gets a page that adds ForeverLM to it,
    /// which is why this closes Setup: by then the library holds
    /// what the connector reaches. Any number may be ticked; "No" clears them.
    private var subscriptionsStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: GettingStartedStep.subscriptions.icon,
                title: "Do you already pay for an AI app?",
                detail: "Tick every one you pay for."
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
                    // 320 wide keeps the clip and its caption above the
                    // footer in the 640-point sheet; at 440 the clip ran
                    // under the footer and the caption was out of sight.
                    WelcomeClipPlayer(url: url)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .frame(maxWidth: 320)
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
    /// the relaunch. It cannot be skipped (product owner, 2026-11-20).
    private var fullDiskAccessStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: GettingStartedStep.fullDiskAccess.icon,
                title: "Allow Full Disk Access",
                // No explanation (product owner, 2026-11-20: "maybe no need
                // for the explanation here either"); the next page walks
                // through adding the app in System Settings.
                detail: ""
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
                    ? "Click \"+\", choose this exact app, and turn it on."
                    : "Click \"+\", choose ForeverLM in Applications, and turn it on."
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
    /// 2026-10-11: "more like a Typeform"): connect OpenRouter, then how
    /// OpenAI and Anthropic credits can pay. AI features run on the learner's
    /// own OpenRouter key, billed by OpenRouter at cost. Models are chosen in
    /// Settings, not here (product owner, 2026-11-20: "this can just be done
    /// in the settings later"). Continuing past the last page is the consent
    /// to background work.
    private var enhancementsStep: some View {
        Group {
            switch aiPage {
            case .key: openRouterKeyPage
            case .credits: providerCreditsPage
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
                assetIcon: "OpenRouterIcon",
                title: "Connect OpenRouter",
                detail: "Your AI runs on your own account."
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
                    .disabled(account.openRouterConnectInFlight)
                    .accessibilityIdentifier("gettingStarted.connectOpenRouter")

                    if account.openRouterConnectInFlight {
                        Text("Finish in your browser, then come back.")
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

    // MARK: OpenAI and Anthropic credits

    /// The product owner, 2026-11-11: onboarding should make it "super clear
    /// that someone can use their OpenAI and Anthropic API credits as well,
    /// and tell them how to set that in OpenRouter and how to put BYOK".
    /// OpenRouter runs those labs' models on the learner's own provider key,
    /// and ForeverLM sends them to the lab's own endpoint
    /// (`AIService.pinLabModelToItsOwnEndpoint`), where that key applies.
    ///
    /// The page is one question (product owner, 2026-11-21: "do you already
    /// have a paid Claude or ChatGPT subscription? If so, you might have API
    /// credits as part of your subscription"). No moves on; Yes opens the three
    /// steps. Some paid plans now include monthly API credits, claimed in the
    /// lab's own billing settings (docs-site/ai-providers.md has the same list).
    private var providerCreditsPage: some View {
        VStack(spacing: 24) {
            if hasPaidPlan == true {
                stepHeading(
                    icon: "creditcard",
                    assetIcon: "OpenRouterIcon",
                    title: "Use your plan's API credits",
                    detail: "Some Claude and ChatGPT plans include monthly API credits. Check yours."
                )
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(Self.providerCreditSteps.enumerated()), id: \.offset) { index, text in
                        instruction("\(index + 1)", text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .setupCard()
                VStack(spacing: 10) {
                    primaryAction("Add my key on OpenRouter") { open(Self.openRouterIntegrationsURL) }
                    HStack(spacing: 16) {
                        Button("Claim Claude credits") { open(Self.claudeCreditsURL) }
                        Button("Claim ChatGPT credits") { open(Self.openAICreditsURL) }
                    }
                    .buttonStyle(.link)
                    .font(.subheadline)
                }
            } else {
                stepHeading(
                    icon: "creditcard",
                    assetIcon: "OpenRouterIcon",
                    title: "Do you have a paid Claude or ChatGPT plan?",
                    detail: "Some plans include API credits."
                )
                VStack(spacing: 10) {
                    choiceRow(title: "Yes") {
                        withAnimation(.easeInOut(duration: 0.2)) { hasPaidPlan = true }
                    }
                    choiceRow(title: "No") { goForward() }
                }
            }
        }
    }

    /// OpenRouter's own-key (BYOK) setup, in its own words
    /// (openrouter.ai/docs/guides/overview/auth/byok).
    static let providerCreditSteps = [
        "Claim your monthly credits, then copy an API key from that OpenAI or Anthropic account",
        "On OpenRouter, open Settings › Integrations and paste the key under OpenAI or Anthropic",
        "Turn on Always use this key and Never use shared capacity, so your credits pay and your OpenRouter balance is never charged",
    ]

    static let claudeCreditsURL = URL(string: "https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers")!
    static let openAICreditsURL = URL(string: "https://platform.openai.com/settings/organization/billing/overview")!

    static let openRouterIntegrationsURL = URL(string: "https://openrouter.ai/settings/integrations")!

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
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var forward: GettingStartedFlow.Forward {
        GettingStartedFlow.forward(canContinue: canContinue, canSkip: canSkip, isLast: isLastPage)
    }

    /// Whether the page may be left unanswered. The AI step and Full Disk
    /// Access may not (product owner, 2026-11-20: "the step shouldn't be
    /// allowed to be skipped"); the Papers, More sources and Your AI
    /// questions carry their own "none" answer, so they need no Skip beside it.
    private var canSkip: Bool {
        switch step {
        case .enhancements, .fullDiskAccess: return false
        case .paper, .moreSources, .subscriptions: return page != nil
        default: return true
        }
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
        // The key page leads to the credits page, which ends the step. The
        // models are chosen later, in Settings (product owner, 2026-11-20: "this
        // can just be done in the settings later").
        if step == .enhancements, aiPage == .key {
            withAnimation(.easeInOut(duration: 0.2)) {
                pages = []
                aiPage = .credits
            }
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
        } else if step == .enhancements, aiPage == .credits {
            withAnimation(.easeInOut(duration: 0.2)) {
                if hasPaidPlan == nil { aiPage = .key } else { hasPaidPlan = nil }
            }
        } else if let previous = previousStep {
            go(to: previous)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { welcomeOverride = true }
        }
    }

    private func readingListBrowserBinding(_ browser: ReadingListBrowser) -> Binding<Bool> {
        browser.binding(in: $enabledReadingListBrowsers) { vm.readingListBrowsersDidChange() }
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
        case .xPosts: return vm.isXOAuthSignedIn
        case .meetings: return newestSource(of: .meeting) != nil || zoomFolder != nil
        case .youtube:
            return (youtubeAccount?.choices.source != nil && newestYouTubeVideo != nil)
                || newestSource(of: .video) != nil
        // The question waits for a pick or "None of these"; the pages after
        // it can each be left as they are.
        case .moreSources:
            return page != nil || !moreSourcePicks.isEmpty || noMoreSources
        case .planner, .memory, .ideas, .artifacts, .assistants, .courses:
            return true
        case .enhancements:
            switch aiPage {
            case .key:
                return GettingStartedAIPayment.isReady(
                    hasOwnKey: account.ownKey != nil,
                    ownKeyAllowed: account.ownKeyAllowed
                )
            // The question moves on at "No"; "Yes" opens the steps, and
            // Continue waits for that.
            case .credits:
                return hasPaidPlan == true
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
            let isFirstFinish = !isCompleted
            isCompleted = true
            arrivalSuggestionsArmed = true
            // The Studio appears with suggestions for what to do first
            // (product owner, 2026-09-22), and they live on the Reader's idle
            // page. A first window opens on the Space, with the Reader behind
            // it, so the first finish brings the Reader forward; a guide
            // reopened later leaves the window as the learner had it.
            if isFirstFinish {
                vm.revealCenterTab(.reader, beside: .reader)
            }
            isPresented = false
            return
        }
        go(to: next)
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
        case .meetings:
            target = newestSource(of: .meeting).map { ($0, .meetings) }
        case .youtube:
            target = (newestYouTubeVideo ?? newestSource(of: .video)).map { ($0, .videos) }
        case .enhancements, .storage, .subscriptions, .fullDiskAccess, .planner, .memory, .ideas, .artifacts, .assistants,
             .moreSources, .courses, .xPosts:
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

    private func stepHeading(icon: String, assetIcon: String? = nil, title: String, detail: String) -> some View {
        SetupStepHeading(icon: icon, title: title, detail: detail, assetIcon: assetIcon)
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
            Preferences.set(url.path, for: Prefs.Meetings.zoomLocalTranscriptFolder)
            zoomFolder = StudioViewModel.zoomLocalTranscriptCustomFolder
            vm.zoomLocalTranscriptFolderDidChange()
        }
    }

}

/// A page's icon, its question and one line on what to do.
struct SetupStepHeading: View {
    let icon: String
    let title: String
    let detail: String
    /// An image from the asset catalog drawn in place of the SF Symbol, for a
    /// page about one company (OpenRouter's mark).
    var assetIcon: String? = nil

    var body: some View {
        VStack(spacing: 10) {
                Group {
                    if let assetIcon {
                        Image(assetIcon)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 26))
                    }
                }
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)
                // A page that needs no explanation passes an empty detail.
                if !detail.isEmpty {
                    Text(detail)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

