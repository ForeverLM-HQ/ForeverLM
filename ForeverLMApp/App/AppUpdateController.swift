import AppKit
import Combine
import Foundation
import os
import UserNotifications

#if DIRECT_DOWNLOAD
import Sparkle
#endif

/// User-visible stage of a Sparkle update cycle, published by AppUpdateController
/// and rendered by RailUpdateButton in the navigation rail's footer.
enum AppUpdatePhase: Equatable {
    case idle
    /// A new version exists; nothing has been downloaded yet.
    case available(version: String)
    /// Sparkle is downloading the update archive.
    case downloading(version: String)
    /// Downloaded; Sparkle is validating and extracting the archive.
    case preparing(version: String)
    /// Extracted and staged; Sparkle's install-and-relaunch prompt is up.
    case readyToInstall(version: String)
    /// The app on disk is already a newer build than this running copy,
    /// because another account on this Mac updated it. Only a relaunch is
    /// left; see `InstalledAppCopy`.
    case relaunchToFinish(version: String)

    var version: String? {
        switch self {
        case .idle:
            return nil
        case .available(let version), .downloading(let version),
             .preparing(let version), .readyToInstall(let version),
             .relaunchToFinish(let version):
            return version
        }
    }
}

/// Whether this account is signed up for beta releases.
///
/// A release goes to the appcast's `beta` channel first, and only reaches
/// everyone when it is promoted (`promote_release.sh`, docs/releasing.md
/// "Beta and production"). Sparkle offers a channel's items only to an updater
/// that names it in `allowedChannels(for:)`; the default channel, which
/// production builds are published to, is offered to every updater. So a Mac
/// signed up gets the newest of both, and every other Mac sees beta builds
/// not at all.
///
/// Synced, so signing up on one Mac signs up the account's other Macs too.
/// Off when never set: a beta is something the learner asked for. Signing
/// out again does not downgrade: Sparkle never installs an older build, so a
/// Mac on a beta stays on it until production passes it.
enum BetaReleases {
    static let preferenceKey = Prefs.Lifecycle.betaReleases.name
    /// The `<sparkle:channel>` value `release_macos.sh --beta` publishes under.
    static let channel = "beta"

    static var isSignedUp: Bool {
        Preferences.value(Prefs.Lifecycle.betaReleases)
    }

    static func setSignedUp(_ signedUp: Bool) {
        Preferences.set(signedUp, for: Prefs.Lifecycle.betaReleases)
    }

    /// What `SPUUpdaterDelegate.allowedChannels(for:)` answers. Empty means
    /// the default channel only.
    static func allowedChannels(signedUp: Bool) -> Set<String> {
        signedUp ? [channel] : []
    }
}

/// Whether the running build is a beta, so the About window and Settings can
/// say so (product owner, 2026-10-06, on 190's About window: "if we do [have the
/// latest beta] it must say it here").
///
/// A beta and its promoted production build are the same binary
/// (`promote_release.sh` only drops the appcast item's channel), so the build
/// cannot know this about itself: the feed says it. Read at launch and when
/// the About window opens, and kept on this Mac per build number, so an
/// update never shows the last build's answer and a promoted beta loses the
/// word at the next read. A build the feed does not list (a Dev build) is
/// none.
enum RunningBuildChannel {
    static let preferenceKey = Prefs.Lifecycle.runningBuildIsBeta.name

    static var runningBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    static var isBeta: Bool {
        // ForeverLM Dev carries the cut's build number but is not the binary
        // the feed published.
        guard !ForeverLMRuntimeIdentity.isDevelopment else { return false }
        return isBeta(stored: Preferences.value(Prefs.Lifecycle.runningBuildIsBeta) as? String, build: runningBuild)
    }

    /// The stored answer applies to `build` only.
    static func isBeta(stored: String?, build: String) -> Bool {
        !build.isEmpty && stored == "\(build):beta"
    }

    static func storedValue(isBeta: Bool, build: String) -> String {
        "\(build):\(isBeta ? "beta" : "release")"
    }

    /// Whether this Mac holds an answer for the running build yet.
    static var isKnown: Bool {
        (Preferences.value(Prefs.Lifecycle.runningBuildIsBeta) as? String)?.hasPrefix("\(runningBuild):") == true
    }

    /// Reads the feed the app updates from and keeps its answer for the
    /// running build, then calls `completion` on the main queue. A feed that
    /// cannot be read, or that does not list the build, leaves the stored
    /// answer as it was.
    static func refresh(timeout: TimeInterval = 8, completion: (() -> Void)? = nil) {
        let build = runningBuild
        guard !build.isEmpty,
              let string = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: string) else {
            completion.map { DispatchQueue.main.async(execute: $0) }
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, error == nil, (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true,
                  !AppcastFeed.items(in: data).isEmpty else {
                completion.map { DispatchQueue.main.async(execute: $0) }
                return
            }
            let answer = AppcastFeed.isBeta(build: build, in: data)
            DispatchQueue.main.async {
                if let answer {
                    Preferences.set(storedValue(isBeta: answer, build: build), for: Prefs.Lifecycle.runningBuildIsBeta)
                }
                completion?()
            }
        }.resume()
    }
}

/// The About window AppKit draws, with "Beta" after the version while the
/// running build is a beta (`RunningBuildChannel`): "Version 0.123.0 Beta
/// (192)". With no answer kept for this build yet, it waits a moment for the
/// feed; otherwise it opens at once and refreshes the answer for next time.
/// ForeverLM Dev is never a beta, so it never waits.
@MainActor
enum AboutPanel {
    static func show() {
        if ForeverLMRuntimeIdentity.isDevelopment {
            present()
        } else if RunningBuildChannel.isKnown {
            present()
            RunningBuildChannel.refresh()
        } else {
            RunningBuildChannel.refresh(timeout: 3) { present() }
        }
    }

    private static func present() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: RunningBuildChannel.isBeta ? "\(version) Beta" : version,
            .version: RunningBuildChannel.runningBuild,
        ])
        NSApp.activate()
    }
}

/// Features not ready for everyone: shown on Macs signed up for beta releases
/// (`BetaReleases`) and in ForeverLM Dev, where they are built, and nowhere
/// else. The product owner, 2026-10-06: the production release is to be the current one
/// "MINUS the canvas functionality; because i think that canvas stuff is not
/// yet ready". A beta build is promoted to production unchanged
/// (`promote_release.sh`), so this is read at run time, never compiled in.
///
/// A hidden feature keeps its code, its data and its sync. Only the ways in
/// close: the rail row, the menu items, Reader clips, its MCP tools, and a
/// window layout restored or synced onto one of its panes. Signing up brings
/// all of it back as it was.
enum BetaFeatures {
    /// The Canvas (the Map) and what lives on it — Ask the Canvas, Memory on
    /// the Canvas, written faces, Reader clips — and the Atlas, which shipped
    /// with it and lays itself out on it. Reader Levels does not depend on
    /// the Canvas and is not gated.
    static var showsCanvas: Bool {
        showsCanvas(signedUpForBetas: BetaReleases.isSignedUp)
    }

    /// For a view that observes the sign-up itself (`@PreferenceStorage` of
    /// `Prefs.Lifecycle.betaReleases`), so it redraws when the sign-up changes.
    static func showsCanvas(signedUpForBetas: Bool) -> Bool {
        showsCanvas(signedUpForBetas: signedUpForBetas, inDevBuild: isBuildingHere)
    }

    /// The rule itself: signed up, or the Dev build. Apart so tests, which
    /// run in a Dev build, can ask it about a production Mac.
    static func showsCanvas(signedUpForBetas: Bool, inDevBuild: Bool) -> Bool {
        signedUpForBetas || inDevBuild
    }

    /// ForeverLM Dev shows every beta feature. First Run does not: it stands
    /// in for a new learner's Mac, which production describes.
    private static var isBuildingHere: Bool {
        ForeverLMRuntimeIdentity.isDevelopment && !ForeverLMRuntimeIdentity.isFirstRun
    }

    /// The panes the Canvas gate closes: the Canvas module's places.
    static let canvasCenterTabs: Set<StudioCenterTab> = ShellPlaces.tabs(of: .canvas)

    /// The panes this Mac does not offer now: none when the Canvas shows.
    static var unofferedCenterTabs: Set<StudioCenterTab> {
        showsCanvas ? [] : canvasCenterTabs
    }
}

/// Whether the bundle this process was launched from has since been replaced
/// by a newer build.
///
/// Every account on a Mac runs the same /Applications/ForeverLM.app. When one
/// account updates it, a copy still running in another account keeps the old
/// build in memory, and Sparkle there compares the feed against that running
/// version: it offers the build already on disk, then fails to install it,
/// because the bundle belongs to the account that updated it and the
/// authorization prompt for replacing it does not come up ("Failed to gain
/// authorization required to update target", error -60008).
/// Nothing needs installing in that case, only a relaunch, so the app reads
/// the Info.plist on disk and says so instead of asking Sparkle.
enum InstalledAppCopy {
    struct Build: Equatable {
        /// CFBundleVersion, the build number Sparkle compares.
        let build: String
        /// CFBundleShortVersionString, what the pill shows.
        let displayVersion: String
    }

    /// The installed build when it is newer than `runningBuild`, else nil.
    static func newerBuild(installedInfo: [String: Any]?, runningBuild: String?) -> Build? {
        guard let runningBuild,
              let build = installedInfo?["CFBundleVersion"] as? String,
              AppcastFeed.isVersion(build, newerThan: runningBuild) else { return nil }
        let display = installedInfo?["CFBundleShortVersionString"] as? String ?? build
        return Build(build: build, displayVersion: display)
    }

    /// Read from disk on every call: `Bundle.main.infoDictionary` is cached
    /// from launch and so always describes the running build.
    static func newerBuildOnDisk(bundle: Bundle = .main) -> Build? {
        let plistURL = bundle.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return newerBuild(
            installedInfo: info,
            runningBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}

/// The disk image ForeverLM was installed from.
///
/// A learner downloads `ForeverLM.dmg`, drags the app into Applications and
/// opens it, and the image stays mounted with the `.dmg` file in Downloads.
/// Once the app runs from an Applications folder the installer is spent, so the
/// app offers to eject it and move the file to the Trash. The image is found
/// by what it carries (this app's bundle identifier), never by its volume name.
enum InstallerImage {
    struct Mounted: Equatable {
        /// The `.dmg` file, as `hdiutil info` reports it.
        let imagePath: String
        let mountPoint: String
    }

    /// Image paths the learner chose to keep, so a mounted installer is asked
    /// about once. Device-local: another Mac has its own installer.
    private static let logger = Logger(subsystem: "com.foreverlm", category: "InstallerImage")

    /// The mounted images in `hdiutil info -plist` output that carry a copy of
    /// this app. `bundleIdentifierAt` answers for the app at a path inside a mount.
    static func carryingThisApp(
        hdiutilInfo info: [String: Any]?,
        appFileName: String,
        bundleIdentifier: String,
        bundleIdentifierAt: (String) -> String?
    ) -> [Mounted] {
        guard let images = info?["images"] as? [[String: Any]] else { return [] }
        var found: [Mounted] = []
        for image in images {
            guard let imagePath = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for mountPoint in entities.compactMap({ $0["mount-point"] as? String }) {
                let appPath = (mountPoint as NSString).appendingPathComponent(appFileName)
                if bundleIdentifierAt(appPath) == bundleIdentifier {
                    found.append(Mounted(imagePath: imagePath, mountPoint: mountPoint))
                    break
                }
            }
        }
        return found
    }

    /// Whether `bundleURL` is an installed copy: inside one of the Applications
    /// folders, so not running off the image itself or from a translocated path.
    static func isInstalled(bundleURL: URL) -> Bool {
        let applicationFolders = FileManager.default.urls(for: .applicationDirectory, in: .allDomainsMask)
        let path = bundleURL.standardizedFileURL.path
        return applicationFolders.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Ask once, after launch, whether to throw the installer away. A no-op
    /// when the app is not installed yet, no installer is mounted, or the
    /// learner already kept it. Never blocks the main actor: `hdiutil` runs
    /// off-main and only the alert and its answer come back.
    @MainActor
    static func offerToTrashMountedInstaller(bundle: Bundle = .main) async {
        guard isInstalled(bundleURL: bundle.bundleURL),
              let bundleIdentifier = bundle.bundleIdentifier else { return }
        // Let the window come up first; the question is not what the launch is for.
        try? await Task.sleep(for: .seconds(3))
        let appFileName = bundle.bundleURL.lastPathComponent
        let kept = Set(Preferences.value(Prefs.Lifecycle.installerKeptImagePaths) ?? [])
        let mounted = await Task.detached(priority: .utility) { () -> [Mounted] in
            let info = (try? run(["info", "-plist"])).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
            }
            return carryingThisApp(
                hdiutilInfo: info,
                appFileName: appFileName,
                bundleIdentifier: bundleIdentifier,
                bundleIdentifierAt: Self.bundleIdentifier(ofAppAt:)
            )
        }.value
        guard let installer = mounted.first(where: { !kept.contains($0.imagePath) }) else { return }

        let alert = NSAlert()
        alert.messageText = "ForeverLM is installed. Move the installer to the Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep")
        guard alert.runModal() == .alertFirstButtonReturn else {
            Preferences.set(Array(kept.union([installer.imagePath])), for: Prefs.Lifecycle.installerKeptImagePaths)
            return
        }
        do {
            try await trash(installer)
        } catch {
            logger.error("Could not move the installer to the Trash: \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
        }
    }

    /// Eject the image, then move its `.dmg` to the Trash. The file is trashed
    /// only after the eject succeeds, so a busy image is left whole.
    private static func trash(_ installer: Mounted) async throws {
        try await Task.detached(priority: .utility) {
            _ = try run(["detach", installer.mountPoint])
        }.value
        let imageURL = URL(fileURLWithPath: installer.imagePath)
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([imageURL]) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func bundleIdentifier(ofAppAt path: String) -> String? {
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return info["CFBundleIdentifier"] as? String
    }

    private struct HdiutilFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs `hdiutil` and returns its standard output; a non-zero exit throws
    /// what it said on standard error.
    private static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Drain both pipes before waiting, or a full pipe stalls the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let said = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw HdiutilFailure(message: said.isEmpty ? "hdiutil exited with status \(process.terminationStatus)." : said)
        }
        return data
    }
}

/// Bridges Sparkle's update state into SwiftUI so the app can show a gentle in-app update affordance.
final class AppUpdateController: NSObject, ObservableObject {
    /// One reused identifier, so a second version supersedes the banner already
    /// sitting in Notification Center instead of stacking beneath it.
    private static let updateNotificationIdentifier = "com.foreverlm.update-available"
    /// The build the user has already been told about. Checks now run hourly and
    /// keep finding the same version until they act on it; without this they
    /// would be notified again every hour.

    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var canCheckForUpdates = false

    var isUpdateAvailable: Bool {
        phase != .idle
    }

    #if DIRECT_DOWNLOAD
    private var updater: SPUUpdater?
    private var userDriver: AppUpdateUserDriver?
    /// The build the pill took over from Sparkle and dismissed on the user's
    /// behalf, so that dismissal is not mistaken for a real "Remind Me Later".
    /// See `AppUpdateOfferPolicy` for why the pill releases the session.
    private var pillOwnedBuild: String?
    private var canCheckObservation: NSKeyValueObservation?
    private var didRequestLaunchBackgroundCheck = false
    private var activityObservers: [NSObjectProtocol] = []
    /// When the last silent check actually went out, so returning to the app
    /// repeatedly cannot turn activation into a request per click.
    private var lastEventDrivenCheck: Date?
    /// Long enough that ordinary app-switching costs nothing, short enough that
    /// coming back to the app after lunch finds a release published meanwhile.
    private static let eventDrivenCheckCooldown: TimeInterval = 15 * 60
    /// A check to start once the session that discarded a stale resumed build
    /// has ended. Sparkle refuses a new check while the old session is open, so
    /// the request waits for `didFinishUpdateCycle`.
    private var pendingRecheck: (userInitiated: Bool, delay: TimeInterval)?
    /// The feed is small and the answer must be current, so nothing is cached
    /// and nothing waits long: a feed that does not answer leaves the resumed
    /// build shown as before.
    private static let feedReadTimeout: TimeInterval = 8
    private static let logger = Logger(subsystem: "com.foreverlm", category: "AppUpdate")
    /// The sign-up as last read, read again only when a preference change
    /// names its key (`PreferenceKeyWatcher`).
    private var betaSignupWatcher: PreferenceKeyWatcher<Bool>?
    #endif

    override init() {
        super.init()

        #if DIRECT_DOWNLOAD
        guard !ForeverLMRuntimeIdentity.isDevelopment else { return }
        // Not SPUStandardUpdaterController: that always installs the standard
        // user driver, and the standard driver parks a scheduled update it is
        // told not to show, which is the stale-pill bug AppUpdateUserDriver
        // exists to prevent.
        let driver = MainActor.assumeIsolated {
            AppUpdateUserDriver(hostBundle: .main, delegate: self)
        }
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: self
        )
        do {
            try updater.start()
        } catch {
            Logger(subsystem: "com.foreverlm", category: "AppUpdate")
                .error("Sparkle updater failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        MainActor.assumeIsolated {
            driver.onPillOwnedUpdate = { [weak self] item, stage in
                self?.recordPillOwnedUpdate(item, stage: stage)
            }
            driver.onStaleResumedUpdate = { [weak self] item, newest, state in
                self?.recordStaleResumedUpdate(item, supersededBy: newest, state: state)
            }
            driver.newestPublishedVersion = { [weak self] completion in
                guard let self else {
                    completion(nil)
                    return
                }
                self.readNewestPublishedVersion(completion: completion)
            }
        }
        userDriver = driver
        self.updater = updater
        canCheckForUpdates = updater.canCheckForUpdates
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        // Claimed before the first check so a found update can present its
        // banner while the app is frontmost, and so clicking it lands here.
        UNUserNotificationCenter.current().delegate = self
        // Whether this build is a beta, for the About window and Settings.
        RunningBuildChannel.refresh()
        checkForUpdatesInBackgroundAfterLaunch()
        observeActivityEvents()
        #endif
    }

    deinit {
        #if DIRECT_DOWNLOAD
        for observer in activityObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        #endif
    }

    /// Starts a manual check, or brings Sparkle's existing progress window back
    /// into focus when a download or install is already under way.
    ///
    /// This is also what the rail pill does. The pill never holds a Sparkle
    /// session of its own (see `AppUpdateOfferPolicy`), so a click here runs a
    /// fresh check. When Sparkle has nothing to resume, that check reads the
    /// appcast and offers whatever is newest. When it holds a downloaded
    /// archive or a waiting installer, it resumes that build instead — and the
    /// user driver then reads the appcast itself and discards the resumed build
    /// if a newer one has shipped, so the check that follows offers the latest.
    /// Together that is the guarantee behind "update means update to the latest".
    func checkForUpdates() {
        #if DIRECT_DOWNLOAD
        // The pill and the menu item both land here. With a newer build
        // already on disk there is nothing to download: relaunch into it.
        if let installed = InstalledAppCopy.newerBuildOnDisk() {
            relaunchIntoInstalledBuild(installed)
            return
        }
        guard canCheckForUpdates else { return }
        updater?.checkForUpdates()
        #endif
    }

    private func setPhase(_ phase: AppUpdatePhase) {
        DispatchQueue.main.async {
            self.phase = phase
        }
    }

    /// Checks on every launch, with no interval floor.
    ///
    /// Sparkle's own schedule only fires in a running app, so a release published
    /// while this one was closed would otherwise wait out the full scheduled
    /// interval after the user came back. A launch is also the cheapest moment to
    /// find an update: nothing is in flight to interrupt. The check is silent
    /// unless it finds something.
    private func checkForUpdatesInBackgroundAfterLaunch() {
        #if DIRECT_DOWNLOAD
        guard !didRequestLaunchBackgroundCheck,
              let updater,
              updater.automaticallyChecksForUpdates else { return }

        didRequestLaunchBackgroundCheck = true
        DispatchQueue.main.async {
            updater.checkForUpdatesInBackground()
        }
        #endif
    }

    #if DIRECT_DOWNLOAD

    // MARK: - Updated from another account

    /// Shows Restart for a newer build already on disk, and reports whether
    /// there was one. Checked before every Sparkle check, because a check would
    /// offer that build and then fail to install it.
    @discardableResult
    private func showRelaunchIfInstalledCopyIsNewer() -> Bool {
        guard let installed = InstalledAppCopy.newerBuildOnDisk() else { return false }
        setPhase(.relaunchToFinish(version: installed.displayVersion))
        return true
    }

    /// Quits and opens the bundle again once this process has exited. The new
    /// process is started by a detached shell rather than by NSWorkspace from
    /// here, because a second instance launched while this one is still
    /// running would be handed to this one instead of starting.
    private func relaunchIntoInstalledBuild(_ installed: InstalledAppCopy.Build) {
        Self.logger.notice("Relaunching into build \(installed.build, privacy: .public), installed from another account")
        clearUpdateNotification()
        MainActor.assumeIsolated {
            StudioWorkspaceWindowCoordinator.shared.prepareForRelaunch()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            // Bounded, as in the Full Disk Access relaunch: a quit the user
            // cancels leaves this copy running, and nothing is reopened.
            "for _ in $(seq 1 150); do kill -0 \"$1\" 2>/dev/null || break; sleep 0.2; done; "
                + "kill -0 \"$1\" 2>/dev/null || exec /usr/bin/open \"$2\"",
            "relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
        ]
        do {
            try process.run()
        } catch {
            Self.logger.error("Could not start the relaunch helper: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Event-driven checks

    /// Re-check when the user comes back to the app, and when the Mac wakes.
    ///
    /// Sparkle's scheduled interval is a poll, and a poll is the backstop here,
    /// not the mechanism: a release published while this app was already running
    /// stays invisible until the hour happens to turn over, and the rail would
    /// keep showing nothing until someone hit Check for Updates by hand.
    /// Activation and wake are the moments the answer can actually have
    /// changed, so they are what asks.
    ///
    /// Both are silent: `checkForUpdatesInBackground` shows nothing unless it
    /// finds something, and the cooldown keeps app-switching from turning into a
    /// request per click.
    private func observeActivityEvents() {
        let activated = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkForUpdatesOnActivity()
        }
        let woke = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkForUpdatesOnActivity()
        }
        activityObservers = [activated, woke]
        // Signing up for beta releases, here, from MCP or on another Mac,
        // changes which builds the feed offers, so it asks at once rather
        // than at the next activation or hour. Signing out asks too: a pill
        // offering a beta build should fall back to what production offers.
        // The watcher hears the preference store name the key; it never reads
        // defaults on the other writes the process makes.
        betaSignupWatcher = PreferenceKeyWatcher(Prefs.Lifecycle.betaReleases) { [weak self] signedUp in
            self?.checkForUpdatesAfterBetaSignupChange(signedUp)
        }
    }

    private func checkForUpdatesAfterBetaSignupChange(_ signedUp: Bool) {
        Self.logger.notice("Beta releases \(signedUp ? "on" : "off", privacy: .public); checking the feed again")
        guard let updater, updater.canCheckForUpdates else { return }
        switch phase {
        case .downloading, .preparing, .relaunchToFinish:
            return
        case .idle, .available, .readyToInstall:
            break
        }
        lastEventDrivenCheck = Date()
        updater.checkForUpdatesInBackground()
    }

    private func checkForUpdatesOnActivity() {
        guard let updater,
              updater.automaticallyChecksForUpdates,
              updater.canCheckForUpdates else { return }
        // A download or extraction in flight owns the pill; asking again would
        // interrupt it. Every other phase re-asks, because re-asking is how the
        // pill learns that a newer build has shipped since. That includes a
        // staged build waiting for Restart: Sparkle resumes it without reading
        // the appcast, and the user driver's freshness check is what notices
        // the newer release and swaps the pill over to it. Without this the
        // pill would say Restart for a build that is no longer the latest until
        // someone clicked it.
        switch phase {
        case .idle, .available, .readyToInstall:
            break
        case .downloading, .preparing, .relaunchToFinish:
            return
        }
        if let last = lastEventDrivenCheck,
           Date().timeIntervalSince(last) < Self.eventDrivenCheckCooldown {
            return
        }
        lastEventDrivenCheck = Date()
        updater.checkForUpdatesInBackground()
    }

    // MARK: - Update notification

    /// Posts the "an update is waiting" banner for a check the user did not start.
    ///
    /// The rail button alone is a passive surface: it only exists while the app is
    /// on screen and the rail is showing, so an update found in the background
    /// could sit unseen indefinitely. The banner is what actually reaches
    /// someone, and macOS keeps it in Notification Center after it fades.
    private func notifyUpdateAvailable(displayVersion: String, buildVersion: String) {
        guard (Preferences.value(Prefs.Lifecycle.appUpdateLastNotifiedBuild) as? String) != buildVersion else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self?.deliverUpdateNotification(displayVersion: displayVersion, buildVersion: buildVersion)
            case .notDetermined:
                // Asked at the first update rather than at launch: the prompt
                // arrives with something to show for it, and a fresh install
                // is not greeted by a permission dialog it has no context for.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    self?.deliverUpdateNotification(displayVersion: displayVersion, buildVersion: buildVersion)
                }
            default:
                // Denied. The rail button stays, and it is the only surface left.
                return
            }
        }
    }

    private func deliverUpdateNotification(displayVersion: String, buildVersion: String) {
        let content = UNMutableNotificationContent()
        content.title = "ForeverLM \(displayVersion) is available"
        content.body = "Click to install it."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Self.updateNotificationIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            guard error == nil else { return }
            Preferences.set(buildVersion, for: Prefs.Lifecycle.appUpdateLastNotifiedBuild)
        }
    }

    /// Retracts the banner once the user is dealing with the update by any route.
    private func clearUpdateNotification() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.updateNotificationIdentifier])
    }
    #endif
}

#if DIRECT_DOWNLOAD
extension AppUpdateController: SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @objc var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    /// Asked by Sparkle before every check, so a change to the sign-up takes
    /// effect at the next one. See `BetaReleases`.
    @objc(allowedChannelsForUpdater:)
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        BetaReleases.allowedChannels(signedUp: BetaReleases.isSignedUp)
    }

    /// Gates every check, including Sparkle's own hourly one, which never
    /// passes through this controller: a check made while a newer build is
    /// already on disk would offer that build and then fail to install it.
    @objc(updater:mayPerformUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard showRelaunchIfInstalledCopyIsNewer() else { return }
        throw NSError(
            domain: "com.foreverlm.update",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "A newer ForeverLM is already installed. Restart ForeverLM to use it."]
        )
    }

    /// What to call the offered version in the pill and the banner.
    ///
    /// Sparkle reports the marketing version, but a release that fixes something
    /// without changing that string still ships as a new build — telling someone
    /// running 0.4.0 that "0.4.0 is available" reads like a bug. Name the build
    /// in exactly that case, and stay out of the way otherwise.
    private func updateLabel(for item: SUAppcastItem) -> String {
        let running = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard item.displayVersionString == running else { return item.displayVersionString }
        return "\(item.displayVersionString) (build \(item.versionString))"
    }

    @objc(updater:didFindValidUpdate:)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setPhase(.available(version: updateLabel(for: item)))
    }

    @objc(updaterDidNotFindUpdate:error:)
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        if !showRelaunchIfInstalledCopyIsNewer() {
            setPhase(.idle)
        }
    }

    @objc(updater:userDidMakeChoice:forUpdate:state:)
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // The pill's own hand-back: the offer stays on screen, only Sparkle's
        // session ends, so the next check can refresh what is offered.
        if choice == .dismiss, !state.userInitiated, pillOwnedBuild == updateItem.versionString {
            pillOwnedBuild = nil
            return
        }
        // On .install the download/extract delegate callbacks take over the pill.
        if choice != .install {
            setPhase(.idle)
        }
    }

    /// The pill took over a scheduled update from Sparkle. Show it and tell
    /// the user, exactly as `standardUserDriverWillHandleShowingUpdate` does
    /// when Sparkle keeps the offer.
    private func recordPillOwnedUpdate(_ item: SUAppcastItem, stage: AppUpdateOfferPolicy.Stage) {
        pillOwnedBuild = item.versionString
        setPhase(Self.phase(for: stage, version: updateLabel(for: item)))
        notifyUpdateAvailable(
            displayVersion: updateLabel(for: item),
            buildVersion: item.versionString
        )
    }

    /// What the pill says for an offer at a given stage. A staged build is one
    /// Restart away, and the pill should say so rather than "Update" as if the
    /// download still lay ahead. A downloaded archive still has to be extracted
    /// on the click, so it reads as an ordinary update.
    private static func phase(for stage: AppUpdateOfferPolicy.Stage, version: String) -> AppUpdatePhase {
        switch stage {
        case .notDownloaded, .downloaded:
            return .available(version: version)
        case .installing:
            return .readyToInstall(version: version)
        }
    }

    /// The user driver found that the build Sparkle resumed is no longer the
    /// newest in the feed and told Sparkle to skip it. Sparkle is now removing
    /// the archive or cancelling the waiting installer and ending the session;
    /// once `didFinishUpdateCycle` reports that, run the same kind of check
    /// again. With nothing left to resume, that check reads the appcast and
    /// offers the newer build — through Sparkle's dialog for a click, through
    /// the pill for a scheduled check.
    private func recordStaleResumedUpdate(_ item: SUAppcastItem, supersededBy newest: String, state: SPUUserUpdateState) {
        Self.logger.notice("Discarding resumed build \(item.versionString, privacy: .public): the feed now carries build \(newest, privacy: .public)")
        clearUpdateNotification()
        setPhase(.idle)
        // A cancelled installer takes a moment to exit. Re-checking before it
        // has would find it still running and resume the same build again.
        let delay: TimeInterval = AppUpdateUserDriver.stage(for: state) == .installing ? 1.5 : 0.2
        pendingRecheck = (userInitiated: state.userInitiated, delay: delay)
    }

    private func runPendingRecheckIfNeeded() {
        guard let recheck = pendingRecheck, let updater else { return }
        pendingRecheck = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + recheck.delay) {
            guard updater.canCheckForUpdates else { return }
            if recheck.userInitiated {
                updater.checkForUpdates()
            } else {
                updater.checkForUpdatesInBackground()
            }
        }
    }

    /// Reads the feed Sparkle is configured with and reports its newest
    /// installable build on the main thread, or nil when it cannot be read.
    private func readNewestPublishedVersion(completion: @escaping (String?) -> Void) {
        guard let feedURL = updater?.feedURL else {
            completion(nil)
            return
        }
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.feedReadTimeout)
        request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        // The channels Sparkle is told, read here on the main thread.
        let allowedChannels = BetaReleases.allowedChannels(signedUp: BetaReleases.isSignedUp)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            var newest: String?
            if let data, error == nil, (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true {
                newest = AppcastFeed.newestInstallableVersion(
                    in: data,
                    systemVersion: AppcastFeed.currentSystemVersion,
                    allowedChannels: allowedChannels
                )
            } else {
                Self.logger.error("Could not read the appcast to verify a resumed update: \(error?.localizedDescription ?? "unexpected response", privacy: .public)")
            }
            DispatchQueue.main.async {
                completion(newest)
            }
        }
        task.resume()
    }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error != nil, !showRelaunchIfInstalledCopyIsNewer() {
            setPhase(.idle)
        }
        runPendingRecheckIfNeeded()
    }

    @objc(updater:willDownloadUpdate:withRequest:)
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        clearUpdateNotification()
        setPhase(.downloading(version: updateLabel(for: item)))
    }

    @objc(updater:didDownloadUpdate:)
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        setPhase(.preparing(version: updateLabel(for: item)))
    }

    @objc(updater:willExtractUpdate:)
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        setPhase(.preparing(version: updateLabel(for: item)))
    }

    @objc(updater:didExtractUpdate:)
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        setPhase(.readyToInstall(version: updateLabel(for: item)))
    }

    /// Reached only for the offers Sparkle keeps: a user-initiated check, a
    /// resumed download or install, an information-only update, or a scheduled
    /// update found while the rail is hidden. `AppUpdateOfferPolicy` decides
    /// which those are; the rest come through `recordPillOwnedUpdate`.
    @objc(standardUserDriverWillHandleShowingUpdate:forUpdate:state:)
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if state.userInitiated {
            return
        }
        setPhase(Self.phase(for: AppUpdateUserDriver.stage(for: state), version: updateLabel(for: update)))
        // Also notified when Sparkle is showing its own dialog: that window can
        // open behind whatever the user is working in, which is the same silence
        // as no surface at all.
        notifyUpdateAvailable(
            displayVersion: updateLabel(for: update),
            buildVersion: update.versionString
        )
    }

    /// The learner pressed Restart: the app is about to quit and Sparkle will
    /// open the new build. Record what every window is showing, and ask that
    /// launch to put it back rather than open the layout with fresh panes.
    @objc(updaterWillRelaunchApplication:)
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            StudioWorkspaceWindowCoordinator.shared.prepareForRelaunch()
        }
    }

    @objc(standardUserDriverDidReceiveUserAttentionForUpdate:)
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearUpdateNotification()
        // The user is looking at Sparkle's own dialog; hide the "available" nudge
        // but keep progress phases visible — they track an install in flight.
        if case .available = phase {
            setPhase(.idle)
        }
    }
}
#endif

extension AppUpdateController: UNUserNotificationCenterDelegate {
    /// Shows the banner even when ForeverLM is the frontmost app. Without this,
    /// macOS suppresses notifications for the active app — which is exactly when
    /// someone is using the app and the rail button may be off screen or scrolled
    /// past anyway.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Clicking the banner is the whole point: it opens Sparkle's install prompt,
    /// so the update is one click away rather than a hunt through the menu bar.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let identifier = response.notification.request.identifier
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier

        // "Plan your day?" opens the planning chat, which answers the card
        // waiting in the Studio window too; Don't Ask Again is the Settings
        // switch, flipped without bringing the app forward, and takes the
        // card down with it.
        if identifier.hasPrefix(PlanTheDayNotifications.identifierPrefix) {
            if response.actionIdentifier == PlanTheDayNotifications.stopAskingActionIdentifier {
                Task { @MainActor in DayModel.shared.stopAskingToPlanTheDay() }
                return
            }
            let plans = response.actionIdentifier == PlanTheDayNotifications.planActionIdentifier
            guard isDefaultAction || plans else { return }
            DispatchQueue.main.async {
                NSApp.activate()
                NotificationCenter.default.post(name: .requestPlanTheDayChat, object: nil)
                Task { @MainActor in DayModel.shared.answerPlanTheDay() }
            }
            return
        }

        // Nudge Me Back on Track: Not a Distraction allows what was in front
        // for the rest of the goal, without bringing the app forward; a
        // click on the nudge itself only dismisses it.
        if identifier == FocusNudges.identifier {
            guard response.actionIdentifier == FocusNudges.notADistractionActionIdentifier else { return }
            let info = response.notification.request.content.userInfo
            guard let targetID = info[FocusNudges.targetIDKey] as? String,
                  let goalKey = info[FocusNudges.goalKey] as? String else { return }
            Task { @MainActor in FocusWatcher.shared.notADistraction(targetID: targetID, goalKey: goalKey) }
            return
        }

        // "Cards from what you finished" opens the drafts in To Check, or
        // Make Cards for the finished sources that have none; Don't Ask
        // Again is the Settings switch, flipped without bringing the app
        // forward.
        if identifier == CardsToCheckNotifications.identifier {
            if response.actionIdentifier == CardsToCheckNotifications.stopAskingActionIdentifier {
                Task { @MainActor in
                    MemoryCardSettings.setShowsDraftNudges(false)
                    await AppModelBridge.studio?.refreshCardsToCheckBanner()
                }
                return
            }
            guard isDefaultAction else { return }
            let undrafted = response.notification.request.content.userInfo[CardsToCheckNotifications.undraftedSourceIDsKey] as? [String] ?? []
            DispatchQueue.main.async {
                NSApp.activate()
                NotificationCenter.default.post(name: .requestCardsFromFinished, object: undrafted)
            }
            return
        }

        // "A model you use is no longer free" opens Settings › Chat, where
        // the model can be changed; its Switch to a Free Model moves what
        // used it onto another free model without bringing the app forward.
        if identifier.hasPrefix(AIModelPriceWatch.identifierPrefix) {
            if response.actionIdentifier == AIModelPriceWatch.switchActionIdentifier {
                let info = response.notification.request.content.userInfo
                guard let modelID = info[AIModelPriceWatch.modelIDKey] as? String else { return }
                let name = info[AIModelPriceWatch.modelNameKey] as? String ?? modelID
                Task.detached(priority: .userInitiated) {
                    await AIModelPriceWatch.switchToFree(modelID: modelID, name: name)
                }
                return
            }
            guard isDefaultAction else { return }
            DispatchQueue.main.async {
                NSApp.activate()
                NotificationCenter.default.post(name: .requestOpenStudioSettings, object: SettingsPane.aiChatModels)
            }
            return
        }

        guard isDefaultAction else { return }

        // The daily "review is ready" reminder opens the Memory pane: today's
        // cards were selected for this click, so a click that only brought
        // the window forward would leave the learner hunting for them, and
        // the pane's Start Review is how every route into the review begins.
        if response.notification.request.identifier == CohortReviewNotifications.requestIdentifier {
            DispatchQueue.main.async {
                NSApp.activate()
                NotificationCenter.default.post(name: .requestMemoryReview, object: nil)
            }
            return
        }

        // "New in your journals" opens the Notebook's source pool, where the
        // suggestions wait with their add and dismiss controls.
        if response.notification.request.identifier.hasPrefix(JournalWatchNotifications.identifierPrefix) {
            let notebookID = response.notification.request.content.userInfo[JournalWatchNotifications.notebookIDKey] as? String
            DispatchQueue.main.async {
                NSApp.activate()
                NotificationCenter.default.post(name: .requestNotebookJournalSuggestions, object: notebookID)
            }
            return
        }

        guard identifier == Self.updateNotificationIdentifier else { return }
        DispatchQueue.main.async {
            NSApp.activate()
            self.checkForUpdates()
        }
    }
}
