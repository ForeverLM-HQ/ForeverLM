import Foundation
import Testing
@testable import ForeverLM

@Suite("Release notes")
struct ReleaseNotesTests {
    private static let fixture = """
    # Changelog

    All notable changes to ForeverLM are documented here.

    ## 0.8.0 (build 48) — 2026-09-04

    **Highlights:**
    - Deep Research works like a research agent, with a "Research: …" Doc
    - A Google Doc can live in the Docs pane
      and this wrapped line is not a bullet
    - The chat's doc tools are named `list_docs` and `read_doc`

    **Version:** the minor version moves to 0.8.0.

    ## 0.7.0 (build 47) — 2026-09-04

    **Highlights:**
    - Today's memory review is one review on every device

    ## 0.6.1 (build 46) — 2026-09-03

    - No highlights heading here, so nothing to show

    ## 0.5.0 (build 33, withdrawn) — 2026-08-31

    **Highlights:**
    - A withdrawn build's notes never show

    ## 0.5.0 — 2026-08-29

    **Highlights:**
    - The product is now ForeverLM
    """

    private var entries: [ReleaseNotesEntry] { ReleaseNotesChangelog.parse(Self.fixture) }

    @Test("Section headers yield version, build, date and the withdrawn flag")
    func parsesHeaders() {
        let parsed = entries
        #expect(parsed.map(\.version) == ["0.8.0", "0.7.0", "0.6.1", "0.5.0", "0.5.0"])
        #expect(parsed.map(\.build) == [48, 47, 46, 33, nil])
        #expect(parsed[0].date == "2026-09-04")
        #expect(parsed[4].date == "2026-08-29")
        #expect(parsed.map(\.isWithdrawn) == [false, false, false, true, false])
        #expect(ReleaseNotesChangelog.parseHeader("Unreleased") == nil)
        #expect(ReleaseNotesChangelog.parseHeader("0.9.0 (build 49) - 2026-09-10")?.date == "2026-09-10")
    }

    @Test("Highlights are the bullets under the heading, markdown intact, continuation lines ignored")
    func parsesHighlights() {
        let parsed = entries
        #expect(parsed[0].highlights == [
            "Deep Research works like a research agent, with a \"Research: …\" Doc",
            "A Google Doc can live in the Docs pane",
            "The chat's doc tools are named `list_docs` and `read_doc`",
        ])
        #expect(parsed[1].highlights == ["Today's memory review is one review on every device"])
        #expect(parsed[2].highlights.isEmpty)
    }

    @Test("The running build's section leads; a version-only header stands in for an old section")
    func findsCurrentEntry() {
        let parsed = entries
        #expect(ReleaseNotesChangelog.entry(forVersion: "0.8.0", build: 48, in: parsed)?.build == 48)
        #expect(ReleaseNotesChangelog.entry(forVersion: "0.5.0", build: 30, in: parsed)?.build == nil)
        #expect(ReleaseNotesChangelog.entry(forVersion: "0.9.0", build: 49, in: parsed) == nil)
    }

    @Test("An update from several builds back also shows the skipped releases, capped and without withdrawn or empty ones")
    func entriesToPresentAcrossSkippedReleases() {
        let parsed = entries
        let fromBuild45 = ReleaseNotesChangelog.entriesToPresent(version: "0.8.0", build: 48, lastSeenBuild: 45, in: parsed)
        #expect(fromBuild45.map(\.build) == [48, 47])

        let fromBuild30 = ReleaseNotesChangelog.entriesToPresent(version: "0.8.0", build: 48, lastSeenBuild: 30, in: parsed)
        #expect(fromBuild30.map(\.build) == [48, 47], "46 has no highlights, 33 is withdrawn, the buildless 0.5.0 cannot be placed")

        let capped = ReleaseNotesChangelog.entriesToPresent(version: "0.8.0", build: 48, lastSeenBuild: 30, in: parsed, limit: 1)
        #expect(capped.map(\.build) == [48])

        let neverSeen = ReleaseNotesChangelog.entriesToPresent(version: "0.8.0", build: 48, lastSeenBuild: nil, in: parsed)
        #expect(neverSeen.map(\.build) == [48], "a first recording shows only the running build")

        let direct = ReleaseNotesChangelog.entriesToPresent(version: "0.8.0", build: 48, lastSeenBuild: 47, in: parsed)
        #expect(direct.map(\.build) == [48])
    }

    @Test("A build without its own highlights presents nothing")
    func nothingWithoutCurrentSection() {
        let parsed = entries
        #expect(ReleaseNotesChangelog.entriesToPresent(version: "0.6.1", build: 46, lastSeenBuild: 45, in: parsed).isEmpty)
        #expect(ReleaseNotesChangelog.entriesToPresent(version: "0.5.0", build: 33, lastSeenBuild: 30, in: parsed).isEmpty)
        #expect(ReleaseNotesChangelog.entriesToPresent(version: "0.9.0", build: 49, lastSeenBuild: 48, in: parsed).isEmpty)
    }

    @Test("The sheet shows after an update, not on a fresh install or a downgrade")
    func presentationDecision() {
        #expect(ReleaseNotesPresentation.shouldPresent(currentBuild: 48, lastSeenBuild: 47, isExistingInstall: true))
        #expect(ReleaseNotesPresentation.shouldPresent(currentBuild: 48, lastSeenBuild: 47, isExistingInstall: false))
        #expect(!ReleaseNotesPresentation.shouldPresent(currentBuild: 48, lastSeenBuild: 48, isExistingInstall: true))
        #expect(!ReleaseNotesPresentation.shouldPresent(currentBuild: 48, lastSeenBuild: 49, isExistingInstall: true))
        #expect(ReleaseNotesPresentation.shouldPresent(currentBuild: 48, lastSeenBuild: nil, isExistingInstall: true),
                "an install from before the feature has never recorded a build, and is still an update")
        #expect(!ReleaseNotesPresentation.shouldPresent(currentBuild: 48, lastSeenBuild: nil, isExistingInstall: false),
                "a first launch belongs to the Getting Started guide")
    }

    @Test("A bold lead becomes the card title, the rest its detail")
    func highlightWithBoldLead() {
        let highlight = ReleaseNotesHighlight(bullet: "**Deep Research works like a research agent.** A visible plan, web search on every step")
        #expect(highlight.title == "Deep Research works like a research agent")
        #expect(highlight.detail == "A visible plan, web search on every step")
        #expect(highlight.symbolName == "text.magnifyingglass")
    }

    @Test("A bold lead that carries on past a comma leaves no comma or 'and' at the head of the detail")
    func highlightWithBoldLeadInsideSentence() {
        let comma = ReleaseNotesHighlight(bullet: "**AI runs on your own OpenRouter key with a Monthly, Yearly or Lifetime plan**, billed by OpenRouter at cost.")
        #expect(comma.title == "AI runs on your own OpenRouter key with a Monthly, Yearly or Lifetime plan")
        #expect(comma.detail == "Billed by OpenRouter at cost.")

        let conjunction = ReleaseNotesHighlight(bullet: "**A parent's plan covers the family**, and parents can assign sources for their children to learn.")
        #expect(conjunction.title == "A parent's plan covers the family")
        #expect(conjunction.detail == "Parents can assign sources for their children to learn.")

        let instead = ReleaseNotesHighlight(bullet: "**The model picker opens above the composer** instead of running off the bottom of the window.")
        #expect(instead.detail == "Instead of running off the bottom of the window.")

        let colon = ReleaseNotesHighlight(bullet: "**Billing is four cards**: plan, your own key, balance and limits.")
        #expect(colon.title == "Billing is four cards")
        #expect(colon.detail == "Plan, your own key, balance and limits.")

        let allBold = ReleaseNotesHighlight(bullet: "**Clicking a citation in a PDF shows its reference card in place.**")
        #expect(allBold.title == nil)
        #expect(allBold.detail == "Clicking a citation in a PDF shows its reference card in place.")
    }

    @Test("A bullet splits on a short first colon, and keeps a long or quoted one whole")
    func highlightFromColonBullet() {
        let split = ReleaseNotesHighlight(bullet: "A Memory row in the rail: one review per day over what you took in")
        #expect(split.title == "A Memory row in the rail")
        #expect(split.detail == "One review per day over what you took in")
        #expect(split.symbolName == "brain.head.profile")

        let quoted = ReleaseNotesHighlight(bullet: "\"Have today's review ready\" in Settings: prepares the chat")
        #expect(quoted.title == nil, "a quoted label before the colon is not a title")
        #expect(quoted.detail == "\"Have today's review ready\" in Settings: prepares the chat")

        let long = ReleaseNotesHighlight(bullet: String(repeating: "word ", count: 20) + "and more: detail")
        #expect(long.title == nil)

        let plain = ReleaseNotesHighlight(bullet: "Cmd+F finds text in a doc")
        #expect(plain.title == nil)
        #expect(plain.detail == "Cmd+F finds text in a doc")
        #expect(plain.symbolName == "doc.text")

        let page = ReleaseNotesHighlight(bullet: "Cmd+F finds text in a page")
        #expect(page.symbolName == "doc.text", "Pages is the Docs pane's new name; old entries still say docs")

        let googleDoc = ReleaseNotesHighlight(bullet: "**A Google Doc can live in the Docs pane.** A read-only text copy for chat and review")
        #expect(googleDoc.symbolName == "doc.text", "'review' in the detail must not outrank the doc")

        let unmatched = ReleaseNotesHighlight(bullet: "Something entirely different happened")
        #expect(unmatched.symbolName == "sparkles")
    }

    @Test("The sheet's subtitle names the version alone, without the build or the date")
    func subtitle() {
        let entry = ReleaseNotesEntry(version: "0.8.0", build: 48, date: "2026-09-04", isWithdrawn: false, highlights: [])
        #expect(WhatsNewSheet.subtitle(for: entry) == "Version 0.8.0")
        let bare = ReleaseNotesEntry(version: "0.5.0", build: nil, date: nil, isWithdrawn: false, highlights: [])
        #expect(WhatsNewSheet.subtitle(for: bare) == "Version 0.5.0")
    }

    @Test("The center holds the notes pending, gives them to one window, survives a teardown, and records the build only on Continue")
    @MainActor
    func centerLifecycle() {
        let defaults = UserDefaults(suiteName: "ReleaseNotesTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        guard let build = WhatsNewCenter.currentBuild else {
            Issue.record("the test host carries no CFBundleVersion")
            return
        }
        // Notes for the running build, whatever version the host reports.
        let markdown = """
        ## \(WhatsNewCenter.currentVersion) (build \(build)) — 2026-09-04

        **Highlights:**
        - **Something new.** With a detail
        """
        let first = StudioWindowState()
        let second = StudioWindowState()
        let center = WhatsNewCenter(defaults: defaults, changelogLoader: { ReleaseNotesChangelog.parse(markdown) }, activeWindow: { nil })

        // A recorded build older than this one is an update: the notes go pending.
        defaults.set(build - 1, forKey: WhatsNewCenter.lastSeenBuildKey)
        center.presentAfterLaunchIfNeeded(in: first, isExistingInstall: true)
        #expect(center.pendingEntries.count == 1)
        #expect(!center.isPresented, "the launch presentation waits for windows to settle")

        #expect(center.presentPending(in: first))
        #expect(center.isPresenting(in: first))
        #expect(!center.presentPending(in: second), "the second window must not steal the sheet")
        #expect(center.isPresenting(in: first))

        // The window closes under the sheet: nothing is recorded, the notes stay pending.
        center.sheetWasTornDown(in: second)
        #expect(center.isPresenting(in: first), "a window that is not presenting cannot tear the sheet down")
        center.sheetWasTornDown(in: first)
        #expect(!center.isPresented)
        #expect(defaults.integer(forKey: WhatsNewCenter.lastSeenBuildKey) == build - 1)
        #expect(center.presentPending(in: second))
        #expect(center.isPresenting(in: second))

        // Continue records the build and clears the pending notes.
        center.confirm()
        #expect(!center.isPresented)
        #expect(center.pendingEntries.isEmpty)
        #expect(defaults.integer(forKey: WhatsNewCenter.lastSeenBuildKey) == build)
        #expect(!center.presentPending(in: first), "nothing is pending after Continue")
    }

    @Test("The center records a fresh install or a current build without presenting")
    @MainActor
    func centerSkipsWithoutAnUpdate() {
        let defaults = UserDefaults(suiteName: "ReleaseNotesTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        guard let build = WhatsNewCenter.currentBuild else {
            Issue.record("the test host carries no CFBundleVersion")
            return
        }
        let window = StudioWindowState()

        let fresh = WhatsNewCenter(defaults: defaults, changelogLoader: { [] }, activeWindow: { nil })
        fresh.presentAfterLaunchIfNeeded(in: window, isExistingInstall: false)
        #expect(fresh.pendingEntries.isEmpty)
        #expect(defaults.integer(forKey: WhatsNewCenter.lastSeenBuildKey) == build, "a fresh install records the build so the next update is recognised")

        let current = WhatsNewCenter(defaults: defaults, changelogLoader: { [] }, activeWindow: { nil })
        current.presentAfterLaunchIfNeeded(in: window, isExistingInstall: true)
        #expect(current.pendingEntries.isEmpty)
        #expect(!current.isPresented)
    }

    @Test("A launch the Getting Started guide owns records a fresh install's build, shows nothing, and leaves an older recorded build for the next launch")
    @MainActor
    func centerDefersToGettingStarted() {
        let defaults = UserDefaults(suiteName: "ReleaseNotesTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        guard let build = WhatsNewCenter.currentBuild else {
            Issue.record("the test host carries no CFBundleVersion")
            return
        }
        let markdown = """
        ## \(WhatsNewCenter.currentVersion) (build \(build)) — 2026-09-04

        **Highlights:**
        - **Something new.** With a detail
        """
        let notes = { ReleaseNotesChangelog.parse(markdown) }
        let window = StudioWindowState()

        // A fresh install: the guide takes the first launch and the build is
        // recorded, so the second launch is not read as an update.
        let firstLaunch = WhatsNewCenter(defaults: defaults, changelogLoader: notes, activeWindow: { nil })
        firstLaunch.deferToGettingStarted()
        #expect(firstLaunch.pendingEntries.isEmpty)
        #expect(!firstLaunch.isPresented)
        #expect(defaults.integer(forKey: WhatsNewCenter.lastSeenBuildKey) == build)
        let secondLaunch = WhatsNewCenter(defaults: defaults, changelogLoader: notes, activeWindow: { nil })
        secondLaunch.presentAfterLaunchIfNeeded(in: window, isExistingInstall: true)
        #expect(secondLaunch.pendingEntries.isEmpty, "the guide's launch was this build, not an update")

        // An existing install whose guide reopened after an update: the older
        // build stays recorded, so the notes show once the guide stands down.
        defaults.set(build - 1, forKey: WhatsNewCenter.lastSeenBuildKey)
        let guided = WhatsNewCenter(defaults: defaults, changelogLoader: notes, activeWindow: { nil })
        guided.deferToGettingStarted()
        #expect(guided.pendingEntries.isEmpty)
        #expect(defaults.integer(forKey: WhatsNewCenter.lastSeenBuildKey) == build - 1)
        let afterGuide = WhatsNewCenter(defaults: defaults, changelogLoader: notes, activeWindow: { nil })
        afterGuide.presentAfterLaunchIfNeeded(in: window, isExistingInstall: true)
        #expect(afterGuide.pendingEntries.count == 1)
    }

    /// The release workflow's contract: the section for the version and build
    /// in project.yml exists in the public changelog with highlights to show.
    /// `release_macos.sh` makes the same check before it builds; this fails
    /// earlier, in the test run before the push.
    @Test("docs-site/changelog.md has What's New highlights for the build project.yml ships")
    func bundledChangelogCoversNotebookVersion() throws {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
        let projectYAML = try String(contentsOf: appDir.appendingPathComponent("project.yml"), encoding: .utf8)
        let changelog = try String(
            contentsOf: appDir.deletingLastPathComponent().appendingPathComponent("docs-site/changelog.md"),
            encoding: .utf8
        )

        func setting(_ name: String) -> String? {
            projectYAML
                .components(separatedBy: .newlines)
                .first { $0.contains("\(name): \"") }?
                .components(separatedBy: "\"")
                .dropFirst().first
        }
        let version = try #require(setting("MARKETING_VERSION"))
        let build = try #require(setting("CURRENT_PROJECT_VERSION").flatMap(Int.init))

        let parsed = ReleaseNotesChangelog.parse(changelog)
        let current = try #require(
            ReleaseNotesChangelog.entry(forVersion: version, build: build, in: parsed),
            "docs-site/changelog.md needs a '## \(version) (build \(build)) — <date>' section; the app shows its Highlights after the update"
        )
        #expect(current.build == build, "the section must name the build, not only the version")
        #expect(!current.highlights.isEmpty, "the section needs a **Highlights:** list")
        #expect(!current.isWithdrawn)
        #expect(current.date != nil)
    }

    @Test("The Mac app bundles the public changelog")
    func changelogIsBundled() throws {
        let url = try #require(Bundle.main.url(forResource: WhatsNewCenter.changelogResourceName, withExtension: "md"))
        let markdown = try String(contentsOf: url, encoding: .utf8)
        #expect(!ReleaseNotesChangelog.parse(markdown).isEmpty)
    }
}
