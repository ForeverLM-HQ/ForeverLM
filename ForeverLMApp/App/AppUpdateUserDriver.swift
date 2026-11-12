import AppKit
import Foundation

#if DIRECT_DOWNLOAD
import Sparkle
#endif

/// Decides who shows a found update, and whether a resumed one may be shown at
/// all. Pure so the rules can be tested without Sparkle.
///
/// Two surfaces, two costs. Sparkle's dialog keeps the update session open
/// until the user answers it, and while a session is open the updater refuses
/// every further check — scheduled, on-activation, and manual alike. That is
/// fine for a dialog on screen, and ruinous for the pill: a pill that parked
/// the session would keep offering whatever build the check found the day it
/// appeared. So an update the pill shows is recorded and immediately handed
/// back to Sparkle as dismissed. Dismissing closes the session and nothing
/// else: a downloaded archive stays cached and an installer already waiting
/// for the app to quit keeps waiting, which is why the pill can own those
/// stages too and label them by stage (Update, Restart).
///
/// Closing the session is not enough on its own, because of how Sparkle
/// resumes. Once it holds a downloaded archive, or an installer is waiting,
/// every later check resumes that build without reading the appcast, so a
/// release published in between is invisible until the resumed build is
/// installed — and the freshly installed build then announces the next one
/// at once. `resumedOfferIsStale` is the check that closes that gap: before a
/// resumed build is shown, the app reads the appcast itself (`AppcastFeed`),
/// and a resumed build that is no longer the newest is discarded — Sparkle's
/// "skip" reply, which removes the archive or cancels the waiting installer
/// and ends the session — so the check that follows reads the appcast again
/// and offers the latest. That is the guarantee behind "update means update
/// to the latest": whichever route installs, the build installed is the newest
/// the feed had when the user acted.
enum AppUpdateOfferPolicy {
    enum Stage: Equatable {
        /// Nothing downloaded yet: the ordinary "a new version exists" case.
        case notDownloaded
        /// Sparkle already holds the archive from an earlier session.
        case downloaded
        /// The update is extracted and its installer waits for a relaunch.
        case installing
    }

    /// True when the pill owns this offer and Sparkle's session should be
    /// released; false when Sparkle's own dialog must handle it.
    ///
    /// - A user-initiated check is the pill click or the menu item: the user is
    ///   waiting for Sparkle's dialog, so it shows.
    /// - An information-only update has no installer to run, only a link, and
    ///   the pill cannot express that.
    /// - With the rail hidden the pill has no surface, and Sparkle's dialog is
    ///   the only thing left that can tell the user anything.
    ///
    /// The stage does not matter: dismissing a downloaded or staged update
    /// keeps the archive and the waiting installer, and the pill's click runs a
    /// user-initiated check that resumes exactly what Sparkle holds.
    static func pillOwnsOffer(
        userInitiated: Bool,
        isInformationOnly: Bool,
        railVisible: Bool
    ) -> Bool {
        guard !userInitiated, !isInformationOnly else { return false }
        return railVisible
    }

    /// Only a resumed offer can be stale: a fresh check has just read the feed,
    /// so what it found is by definition the newest.
    static func needsFreshnessCheck(stage: Stage, isInformationOnly: Bool) -> Bool {
        stage != .notDownloaded && !isInformationOnly
    }

    /// True when the feed now carries a build newer than the one Sparkle
    /// resumed. An unreadable feed (nil) is not evidence of anything, so the
    /// resumed build is shown as before rather than thrown away.
    static func resumedOfferIsStale(resumedVersion: String, newestPublished: String?) -> Bool {
        guard let newestPublished else { return false }
        return AppcastFeed.isVersion(newestPublished, newerThan: resumedVersion)
    }

    /// How many times the same build may be discarded before it is shown
    /// anyway. A cancelled installer takes a moment to exit; if the re-check
    /// probes before it has, Sparkle resumes the same build once more. Two
    /// attempts cover that; a third would be a loop, not a fix.
    static let maximumDiscardsPerBuild = 2
}

#if DIRECT_DOWNLOAD
/// Sparkle user driver that lets the navigation rail's pill announce scheduled
/// updates, and that refuses to show a resumed update the feed has since
/// superseded, while every other interaction stays with
/// `SPUStandardUserDriver`.
///
/// Every protocol method forwards to the standard driver except
/// `showUpdateFound`, which applies `AppUpdateOfferPolicy`:
///
/// - A resumed offer (downloaded or installing) is first checked against the
///   feed through `newestPublishedVersion`. A stale one is reported through
///   `onStaleResumedUpdate` and answered `.skip`, which makes Sparkle drop it
///   and end the session; `AppUpdateController` then starts the check that
///   finds the newer build.
/// - When the pill owns the offer, `onPillOwnedUpdate` records it and the
///   reply is `.dismiss`, so no session lingers. Sparkle's delegate still
///   hears that dismissal through `updater(_:userDidMake:forUpdate:state:)`;
///   the controller tells it apart from a real "Remind Me Later" by the build
///   it just recorded.
/// - Otherwise the standard driver shows its dialog.
@MainActor
final class AppUpdateUserDriver: NSObject, SPUUserDriver {
    private let standardDriver: SPUStandardUserDriver
    /// Fires on the main thread with the update the pill is about to show and
    /// its stage, before Sparkle is told the offer was dismissed.
    var onPillOwnedUpdate: ((SUAppcastItem, AppUpdateOfferPolicy.Stage) -> Void)?
    /// Fires on the main thread with a resumed update the feed has superseded,
    /// the newer build's version, and the check's state, before Sparkle is told
    /// to skip it.
    var onStaleResumedUpdate: ((SUAppcastItem, String, SPUUserUpdateState) -> Void)?
    /// Reads the feed and reports the newest installable build, or nil when
    /// the feed cannot be read. Called on the main thread; must complete on it.
    var newestPublishedVersion: (@escaping (String?) -> Void) -> Void = { completion in completion(nil) }
    /// Whether the icon strip, whose footer holds the update pill, is on
    /// screen: always, because the sidebar toggle does not fold it. Injected
    /// so tests and previews can drive the rule.
    var isRailVisible: () -> Bool = { true }

    /// Builds discarded as stale this session, with how often. See
    /// `AppUpdateOfferPolicy.maximumDiscardsPerBuild`.
    private var discards: [String: Int] = [:]

    init(hostBundle: Bundle, delegate: SPUStandardUserDriverDelegate?) {
        standardDriver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: delegate)
        super.init()
    }

    nonisolated static func stage(for state: SPUUserUpdateState) -> AppUpdateOfferPolicy.Stage {
        switch state.stage {
        case .notDownloaded:
            return .notDownloaded
        case .downloaded:
            return .downloaded
        case .installing:
            return .installing
        @unknown default:
            return .installing
        }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standardDriver.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standardDriver.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let stage = Self.stage(for: state)
        let build = appcastItem.versionString
        guard AppUpdateOfferPolicy.needsFreshnessCheck(stage: stage, isInformationOnly: appcastItem.isInformationOnlyUpdate),
              discards[build, default: 0] < AppUpdateOfferPolicy.maximumDiscardsPerBuild else {
            present(appcastItem, stage: stage, state: state, reply: reply)
            return
        }
        // Sparkle resumed this build without reading the feed. Read it, and
        // only then decide whether this is still the update to offer.
        newestPublishedVersion { [weak self] newest in
            guard let self else {
                reply(.dismiss)
                return
            }
            if AppUpdateOfferPolicy.resumedOfferIsStale(resumedVersion: build, newestPublished: newest), let newest {
                self.discards[build, default: 0] += 1
                self.onStaleResumedUpdate?(appcastItem, newest, state)
                // Skip removes a downloaded archive or cancels a waiting
                // installer, then ends the session. It also marks this build
                // skipped for background checks, which only ever hides a build
                // older than the one the feed now carries.
                reply(.skip)
            } else {
                self.present(appcastItem, stage: stage, state: state, reply: reply)
            }
        }
    }

    private func present(
        _ appcastItem: SUAppcastItem,
        stage: AppUpdateOfferPolicy.Stage,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let pillOwnsOffer = AppUpdateOfferPolicy.pillOwnsOffer(
            userInitiated: state.userInitiated,
            isInformationOnly: appcastItem.isInformationOnlyUpdate,
            railVisible: isRailVisible()
        )
        guard pillOwnsOffer else {
            standardDriver.showUpdateFound(with: appcastItem, state: state, reply: reply)
            return
        }
        onPillOwnedUpdate?(appcastItem, stage)
        reply(.dismiss)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        standardDriver.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        standardDriver.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standardDriver.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standardDriver.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        standardDriver.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standardDriver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standardDriver.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        standardDriver.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standardDriver.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standardDriver.showReady(toInstallAndRelaunch: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standardDriver.showInstallingUpdate(
            withApplicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication
        )
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standardDriver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        standardDriver.dismissUpdateInstallation()
    }

    func showUpdateInFocus() {
        standardDriver.showUpdateInFocus()
    }
}
#endif
