import SwiftUI

extension Notification.Name {
    /// Posted by the app menu's "What's New in ForeverLM…" item; the active
    /// Studio window presents the sheet for the running build.
    static let showWhatsNew = Notification.Name("showWhatsNew")
}

/// Decides, once per launch and once per update, whether the What's New sheet
/// shows, and which Studio window shows it.
///
/// Every Studio window runs the same launch work, so the notes are computed
/// once and held as pending; the sheet then goes into the active window a
/// moment later, after window restoration has settled. Restoration can still
/// tear a window down under the sheet — SwiftUI reports that as a dismissal —
/// so a dismissal that was not the Continue button returns the notes to
/// pending and the next window to ask presents them again. Only Continue
/// records the build, and only then is the sheet finished with.
///
/// The build the learner has been shown is remembered per Mac in
/// UserDefaults — it is device state, not a preference, so it does not ride
/// the sync rail; a second Mac updating later should see the notes too.
@MainActor
@Observable
final class WhatsNewCenter {
    static let shared = WhatsNewCenter()

    /// The build whose notes were last presented (or deliberately skipped).
    static let lastSeenBuildKey = Prefs.Lifecycle.whatsNewLastSeenBuild.name
    /// The public changelog, bundled from `docs-site/changelog.md`.
    static let changelogResourceName = "changelog"
    static let fullChangelogURL = URL(string: "https://docs.foreverlm.com/changelog")!
    /// How long after the launch work the sheet waits for restored windows to
    /// settle before it picks the active one.
    static let launchPresentationDelay: Duration = .seconds(1.2)
    /// A sheet torn down by a closing window comes back this much later.
    static let representationDelay: Duration = .milliseconds(600)
    /// How many teardowns are retried before the notes are given up for this
    /// launch (they return on the next launch, since nothing was recorded).
    static let maximumRepresentations = 3

    /// What the sheet shows, newest release first.
    private(set) var entries: [ReleaseNotesEntry] = []
    /// Whether the sheet is up in `presentingWindow`.
    private(set) var isPresented = false
    /// Notes computed at launch and not yet confirmed with Continue.
    private(set) var pendingEntries: [ReleaseNotesEntry] = []
    /// The window that claimed the sheet. Weak so a closed window releases
    /// the claim without a bookkeeping step.
    private weak var presentingWindow: StudioWindowState?
    private var launchDecisionMade = false
    private var representations = 0

    private let defaults: UserDefaults
    private let changelogLoader: () -> [ReleaseNotesEntry]
    private let activeWindow: @MainActor () -> StudioWindowState?

    init(
        defaults: UserDefaults = .standard,
        changelogLoader: @escaping () -> [ReleaseNotesEntry] = WhatsNewCenter.loadBundledChangelog,
        activeWindow: @escaping @MainActor () -> StudioWindowState? = { StudioWindowRegistry.shared.activeState }
    ) {
        self.defaults = defaults
        self.changelogLoader = changelogLoader
        self.activeWindow = activeWindow
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var currentBuild: Int? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
    }

    static func loadBundledChangelog() -> [ReleaseNotesEntry] {
        guard let url = Bundle.main.url(forResource: changelogResourceName, withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return ReleaseNotesChangelog.parse(markdown)
    }

    /// Whether `window` is the one showing the sheet.
    func isPresenting(in window: StudioWindowState) -> Bool {
        isPresented && presentingWindow === window
    }

    /// The first launch after an update shows what the release added.
    ///
    /// Called from each Studio window's launch work once the library is loaded
    /// and the Getting Started guide has decided not to show — the guide owns a
    /// first launch, and two sheets at once would bury both. The decision is
    /// made once; later windows only offer themselves as a presenter.
    func presentAfterLaunchIfNeeded(in window: StudioWindowState, isExistingInstall: Bool) {
        guard !UITestConfiguration.isUITesting else { return }
        if launchDecisionMade {
            presentPending(in: window)
            return
        }
        launchDecisionMade = true
        guard let build = Self.currentBuild else { return }

        let lastSeenBuild = defaults.object(forKey: Self.lastSeenBuildKey) as? Int
        guard ReleaseNotesPresentation.shouldPresent(
            currentBuild: build,
            lastSeenBuild: lastSeenBuild,
            isExistingInstall: isExistingInstall
        ) else {
            markSeen(build: build)
            return
        }

        pendingEntries = ReleaseNotesChangelog.entriesToPresent(
            version: Self.currentVersion,
            build: build,
            lastSeenBuild: lastSeenBuild,
            in: changelogLoader()
        )
        guard !pendingEntries.isEmpty else {
            // Nothing bundled for this build: the release check should have
            // refused to ship it, but never re-ask on every launch.
            markSeen(build: build)
            return
        }

        schedulePresentation(after: Self.launchPresentationDelay, fallback: window)
    }

    /// The Getting Started guide is taking this launch, so nothing is presented.
    ///
    /// A Mac that has never recorded a build records this one: a fresh install
    /// shows the guide on its first launch, and without this the second launch
    /// found `lastSeenBuild == nil` on a library the guide had just marked as
    /// existing, and opened "What's New" for a version the learner never had.
    /// A recorded older build is left alone; those notes are an update and show
    /// on the first launch the guide does not take.
    func deferToGettingStarted() {
        guard !UITestConfiguration.isUITesting, !launchDecisionMade else { return }
        launchDecisionMade = true
        guard let build = Self.currentBuild,
              defaults.object(forKey: Self.lastSeenBuildKey) == nil else { return }
        markSeen(build: build)
    }

    /// Puts the pending notes into `window` unless a window already has them.
    /// Returns whether `window` now presents the sheet.
    @discardableResult
    func presentPending(in window: StudioWindowState) -> Bool {
        guard !pendingEntries.isEmpty, !isPresented, presentingWindow == nil else {
            return isPresenting(in: window)
        }
        present(pendingEntries, in: window)
        return true
    }

    /// The menu item: always shows something, so it reads as working even
    /// when the running build's own section is missing.
    func presentOnRequest(in window: StudioWindowState) {
        let all = changelogLoader()
        var toPresent: [ReleaseNotesEntry] = []
        if let build = Self.currentBuild {
            toPresent = ReleaseNotesChangelog.entriesToPresent(
                version: Self.currentVersion,
                build: build,
                lastSeenBuild: nil,
                in: all
            )
        }
        if toPresent.isEmpty, let newest = all.first(where: { !$0.isWithdrawn && !$0.highlights.isEmpty }) {
            toPresent = [newest]
        }
        guard !toPresent.isEmpty else { return }
        if isPresented {
            entries = toPresent
            return
        }
        present(toPresent, in: window)
    }

    /// The Continue button (or Escape): the notes are read.
    func confirm() {
        guard isPresented else { return }
        isPresented = false
        presentingWindow = nil
        pendingEntries = []
        if let build = Self.currentBuild { markSeen(build: build) }
    }

    /// SwiftUI dismissed the sheet without Continue — the window it was in is
    /// going away. The notes stay pending and come back in the active window.
    func sheetWasTornDown(in window: StudioWindowState) {
        guard isPresented, presentingWindow === window else { return }
        isPresented = false
        presentingWindow = nil
        guard !pendingEntries.isEmpty, representations < Self.maximumRepresentations else { return }
        representations += 1
        schedulePresentation(after: Self.representationDelay, fallback: nil)
    }

    private func schedulePresentation(after delay: Duration, fallback: StudioWindowState?) {
        Task { @MainActor [weak self, weak fallback] in
            try? await Task.sleep(for: delay)
            guard let self, !self.pendingEntries.isEmpty, !self.isPresented else { return }
            if let window = self.activeWindow() ?? fallback {
                self.presentPending(in: window)
            }
        }
    }

    private func present(_ entries: [ReleaseNotesEntry], in window: StudioWindowState) {
        self.entries = entries
        presentingWindow = window
        isPresented = true
    }

    /// Records the build as seen. Never moves the mark backwards: a downgrade
    /// that later re-updates should not present the notes it already showed.
    private func markSeen(build: Int) {
        let recorded = defaults.object(forKey: Self.lastSeenBuildKey) as? Int ?? 0
        guard build > recorded else { return }
        defaults.set(build, forKey: Self.lastSeenBuildKey)
    }
}

/// The What's New sheet: this release's highlights from the public changelog,
/// presented once after an update and on demand from the app menu.
///
/// A small flat header — the icon, "What's New" and "Version 0.8.0" — then
/// each highlight as a plain row: a grey symbol and its bold lead, the
/// detail shown when the row is clicked (product owner, 2026-09-20: "the user can
/// click on a high level title … and if they click they can see details").
/// Until 2026-10-06 the header was a 96pt icon over an iridescent wash with
/// the build in a pill, and each highlight a card with an accent tile and its
/// detail always beneath (product owner, 2026-10-06: "fewer buttons and bells and
/// whistles").
struct WhatsNewSheet: View {
    let entries: [ReleaseNotesEntry]
    let onContinue: () -> Void

    @Environment(\.openURL) private var openURL

    private var lead: ReleaseNotesEntry? { entries.first }

    var body: some View {
        VStack(spacing: 0) {
            hero

            ScrollView {
                VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        releaseSection(entry, isLead: index == 0)
                    }
                }
                .padding(.horizontal, StudioDesign.Spacing.xLarge - 6)
                .padding(.vertical, StudioDesign.Spacing.medium)
            }
            .frame(maxHeight: 440)

            Divider()

            footer
                .padding(.horizontal, StudioDesign.Spacing.xLarge)
                .padding(.vertical, StudioDesign.Spacing.medium + 2)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onContinue)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What's new in ForeverLM")
    }

    // MARK: Header

    private var hero: some View {
        HStack(spacing: StudioDesign.Spacing.medium) {
            Image(nsImage: AppIconImage.shared)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("What's New")
                    .font(.system(size: 17, weight: .semibold))
                if let lead {
                    Text(Self.subtitle(for: lead))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .textSelection(.disabled)
        .padding(.horizontal, StudioDesign.Spacing.xLarge)
        .padding(.top, StudioDesign.Spacing.xLarge)
        .padding(.bottom, StudioDesign.Spacing.medium)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Highlights

    private func releaseSection(_ entry: ReleaseNotesEntry, isLead: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Only an install that skipped releases sees more than one; each
            // is headed by its version alone.
            if entries.count > 1 {
                Text(entry.version)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.disabled)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                    .padding(.top, isLead ? 0 : StudioDesign.Spacing.small)
            }
            ForEach(Array(entry.highlights.enumerated()), id: \.offset) { _, bullet in
                WhatsNewHighlightRow(highlight: ReleaseNotesHighlight(bullet: bullet))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Full Changelog") {
                openURL(WhatsNewCenter.fullChangelogURL)
            }
            .buttonStyle(.link)
            .help("Open the complete changelog on the ForeverLM website")
            .accessibilityIdentifier("mac.whatsNew.fullChangelog")

            Spacer()

            Button {
                onContinue()
            } label: {
                Text("Continue")
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("mac.whatsNew.continue")
        }
    }

    /// "Version 0.8.0". The build number and the date went on 2026-10-06:
    /// About and the Full Changelog carry them.
    static func subtitle(for entry: ReleaseNotesEntry) -> String {
        "Version \(entry.version)"
    }

    /// Changelog bullets carry inline markdown — quoted labels, `code`,
    /// emphasis — which renders; anything malformed falls back to the raw text.
    static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

/// One highlight: a grey symbol and its bold lead; a click shows the detail
/// beneath and a second hides it. A bullet with no bold lead is its detail,
/// shown as it is.
private struct WhatsNewHighlightRow: View {
    let highlight: ReleaseNotesHighlight

    @State private var showsDetail = false

    var body: some View {
        if let title = highlight.title {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showsDetail.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        symbol
                        Text(WhatsNewSheet.attributed(title))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showsDetail ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
                .help(showsDetail ? "Hide the details" : "Show the details")
                .accessibilityValue(showsDetail ? "Expanded" : "Collapsed")

                if showsDetail {
                    detail
                        .padding(.leading, 36)
                        .padding(.trailing, 6)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                symbol
                detail
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
        }
    }

    private var symbol: some View {
        Image(systemName: highlight.symbolName)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 20)
            .accessibilityHidden(true)
    }

    private var detail: some View {
        Text(WhatsNewSheet.attributed(highlight.detail))
            .font(.system(size: 12.5))
            .foregroundStyle(highlight.title == nil ? .primary : .secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
