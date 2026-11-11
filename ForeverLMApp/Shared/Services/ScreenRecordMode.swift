import Foundation
import SQLite3

// MARK: - Screen record mode
//
// The product owner, 2026-09-24: "a setting that only applies to me as the admin …
// Screen record mode … that setting should never show up for any other
// users … only a subset of the sources would be shown just for the purposes
// of screen recording". Product videos are filmed against the real library,
// so while the mode is on every list the app, the in-app chat and the MCP
// connector show is cut down to one scope: the recording Notebook's sources,
// safe public browser captures made after the mode was turned on, the public
// sources the learner adds during the take to a Notebook or Goal also made
// during it, plus the learner's own work made during the take.
//
// Invariants:
// - Presentation only. Nothing is deleted, hidden in the database, or kept
//   from sync; in-memory source arrays stay whole (source discovery dedups
//   against them), and only what is listed, searched or picked is narrowed.
// - Device-local. The keys below live in `UserDefaults.standard` under the
//   `screenRecordMode.` prefix, which `SyncedPreferenceKeys.excludedPrefixes`
//   keeps out of `user_preferences`, so the mode reaches no other Mac, phone,
//   team or account.
// - Admin only. The effective mode is the stored switch AND the last
//   server-confirmed admin answer (`ManagedAI.Balance.isAdmin`). A learner the
//   proxy does not call admin never sees the toggle, never gets it in
//   `get_app_settings`, and `set_app_setting` answers it as an unknown setting.
// - The `RECORDING_PRIVACY` compilation condition still forces the mode on
//   (with the launch as its cutoff) for the screenshot builds that set it; it
//   is the same scope, not a second mechanism.

enum ScreenRecordMode {
    static let enabledKey = Prefs.Lifecycle.screenRecordEnabled.name
    static let notebookIDKey = Prefs.Lifecycle.screenRecordNotebookID.name
    static let cutoffKey = Prefs.Lifecycle.screenRecordCutoff.name
    /// Whether the library's public sources show too (`ScreenRecordScope.isPublicLibrarySource`).
    static let librarySourcesKey = Prefs.Lifecycle.screenRecordLibrarySources.name
    /// Images kept on screen although they were drawn before the take: an
    /// image carries no Notebook or source to earn a pass by.
    static let imageIDsKey = Prefs.Lifecycle.screenRecordImageIDs.name
    /// Older public library sources kept on screen although the library held
    /// them before the take (`ScreenRecordScope.keptSourceIDs`).
    static let sourceIDsKey = Prefs.Lifecycle.screenRecordSourceIDs.name
    /// Meeting folders whose sessions show although meetings never count as
    /// public: a seminar series the admin chooses to film.
    static let meetingGroupIDsKey = Prefs.Lifecycle.screenRecordMeetingGroupIDs.name
    /// The last admin answer the proxy gave this Mac's signed-in account.
    /// Written only from a balance that loaded, cleared on sign-out, and left
    /// alone by a transient failure, so a network blip mid-take does not drop
    /// the scope and put the private library on screen.
    static let confirmedAdminKey = Prefs.Lifecycle.screenRecordConfirmedAdmin.name

    /// Posted on the main thread whenever the switch, the Notebook, or the
    /// admin answer changes. Studio windows re-derive their scope from it.
    static let didChangeNotification = Notification.Name("ForeverLMScreenRecordModeDidChange")

    #if RECORDING_PRIVACY
    static let isForcedByBuild = true
    /// Each launch of a `RECORDING_PRIVACY` build establishes a fresh boundary.
    private static let buildLaunchCutoff = Date()
    #else
    static let isForcedByBuild = false
    #endif

    /// A test's own defaults, bound for the task that runs it. The switch
    /// otherwise lives in `UserDefaults.standard`, which every test in the
    /// process shares with every other one running in parallel (and with the
    /// Dev build's own settings), so a test that turned the mode on would
    /// narrow the library under its neighbours.
    @TaskLocal static var overrideDefaults: DefaultsOverride? = nil

    /// A Sendable carrier for `overrideDefaults`; a task-local's value must be
    /// Sendable, and the suite is only ever touched by the task that bound it.
    struct DefaultsOverride: @unchecked Sendable {
        let defaults: UserDefaults
    }

    /// Runs a typed read or write against the bound test defaults, or the
    /// Mac's own when none is bound.
    private static func scoped<Result>(_ body: () -> Result) -> Result {
        guard let override = overrideDefaults else { return body() }
        return Preferences.withStorage(override.defaults, body)
    }

    /// Whether this account may see and use the mode at all.
    static var isAvailable: Bool {
        scoped { Preferences.value(Prefs.Lifecycle.screenRecordConfirmedAdmin) }
    }

    /// The stored switch, whatever the account. Only Settings and the MCP
    /// entry read it directly; everything that filters asks `isEffective`.
    static var isStoredOn: Bool {
        scoped { Preferences.value(Prefs.Lifecycle.screenRecordEnabled) }
    }

    /// The one gate: the switch is on and the proxy has said this account is
    /// an admin, or the build forces it.
    static var isEffective: Bool {
        isForcedByBuild || (isStoredOn && isAvailable)
    }

    /// The Notebook whose sources stay on screen, or nil for "none": then only
    /// safe public captures and work made after the cutoff show.
    static var notebookID: String? {
        let id = scoped { Preferences.value(Prefs.Lifecycle.screenRecordNotebookID) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// The product owner, 2026-09-24: "the source is not necessarily need to be hidden
    /// … showcase what the app can do, that it can pull the sources
    /// together". On, every public source in the library shows beside the
    /// recording Notebook's: papers, articles, podcasts, books, courses and
    /// public videos. Meetings, X posts, uploads and private hosts still do
    /// not, and the learner's own chats, Docs and Goals are unaffected.
    static var showsLibrarySources: Bool {
        scoped { Preferences.value(Prefs.Lifecycle.screenRecordLibrarySources) }
    }

    /// The images kept on screen whatever their date (`imageIDsKey`).
    static var imageIDs: [String] {
        (scoped { Preferences.value(Prefs.Lifecycle.screenRecordImageIDs) } ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The older public library sources kept on screen (`sourceIDsKey`).
    static var sourceIDs: [String] {
        (scoped { Preferences.value(Prefs.Lifecycle.screenRecordSourceIDs) } ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The meeting folders kept on screen (`meetingGroupIDsKey`).
    static var meetingGroupIDs: [String] {
        (scoped { Preferences.value(Prefs.Lifecycle.screenRecordMeetingGroupIDs) } ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The moment the mode was turned on. Anything created at or after it is
    /// the take's own work and shows.
    static var cutoff: Date? {
        guard isEffective else { return nil }
        if isStoredOn, let stored = scoped({ Preferences.value(Prefs.Lifecycle.screenRecordCutoff) }) {
            return stored
        }
        #if RECORDING_PRIVACY
        return buildLaunchCutoff
        #else
        // On with no stamp (a hand-edited plist): the safest boundary is now.
        return Date()
        #endif
    }

    /// Whether a row draws its relative date: every date with the mode off, and
    /// with it on only a date from the take (`ScreenRecordScope.showsDateStamp`).
    /// For views with no view model in reach, such as a popover's rows.
    static func showsDateStamp(_ date: Date) -> Bool {
        cutoff.map { date >= $0 } ?? true
    }

    // MARK: Writes

    /// Turning the mode on stamps the cutoff; turning it on again while it is
    /// on keeps the stamp, so a second `set_app_setting` does not shift the
    /// boundary under a take already in progress.
    static func setEnabled(_ enabled: Bool, now: Date = Date()) {
        guard enabled != isStoredOn else { return }
        if enabled {
            scoped { Preferences.set(now, for: Prefs.Lifecycle.screenRecordCutoff) }
        } else {
            scoped { Preferences.reset(Prefs.Lifecycle.screenRecordCutoff) }
        }
        scoped { Preferences.set(enabled, for: Prefs.Lifecycle.screenRecordEnabled) }
        postChange()
    }

    static func setNotebookID(_ notebookID: String?) {
        let trimmed = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard next != self.notebookID else { return }
        if let next {
            scoped { Preferences.set(next, for: Prefs.Lifecycle.screenRecordNotebookID) }
        } else {
            scoped { Preferences.reset(Prefs.Lifecycle.screenRecordNotebookID) }
        }
        postChange()
    }

    static func setShowsLibrarySources(_ shows: Bool) {
        guard shows != showsLibrarySources else { return }
        scoped { Preferences.set(shows, for: Prefs.Lifecycle.screenRecordLibrarySources) }
        postChange()
    }

    static func setImageIDs(_ ids: [String]) {
        var seen: Set<String> = []
        let next = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard next != imageIDs else { return }
        if next.isEmpty {
            scoped { Preferences.reset(Prefs.Lifecycle.screenRecordImageIDs) }
        } else {
            scoped { Preferences.set(next, for: Prefs.Lifecycle.screenRecordImageIDs) }
        }
        postChange()
    }

    static func setSourceIDs(_ ids: [String]) {
        var seen: Set<String> = []
        let next = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard next != sourceIDs else { return }
        if next.isEmpty {
            scoped { Preferences.reset(Prefs.Lifecycle.screenRecordSourceIDs) }
        } else {
            scoped { Preferences.set(next, for: Prefs.Lifecycle.screenRecordSourceIDs) }
        }
        postChange()
    }

    static func setMeetingGroupIDs(_ ids: [String]) {
        var seen: Set<String> = []
        let next = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard next != meetingGroupIDs else { return }
        if next.isEmpty {
            scoped { Preferences.reset(Prefs.Lifecycle.screenRecordMeetingGroupIDs) }
        } else {
            scoped { Preferences.set(next, for: Prefs.Lifecycle.screenRecordMeetingGroupIDs) }
        }
        postChange()
    }

    /// Records what a successful balance load said. `ManagedAIAccountModel`
    /// calls this; nothing else decides who is an admin.
    static func recordAdminStatus(_ isAdmin: Bool) {
        guard isAdmin != isAvailable else { return }
        scoped { Preferences.set(isAdmin, for: Prefs.Lifecycle.screenRecordConfirmedAdmin) }
        postChange()
    }

    /// Sign-out, or a session the proxy refused: the next account has to be
    /// confirmed afresh before the mode can apply.
    static func clearAdminStatus() {
        recordAdminStatus(false)
    }

    private static func postChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

/// What may be on screen while `ScreenRecordMode` is effective. Nil means the
/// mode is off and nothing is filtered; every list asks the same three
/// questions of the same value, so the app, the in-app chat and the MCP
/// connector show one subset.
struct ScreenRecordScope: Sendable, Equatable {
    /// The recording Notebook, always shown.
    let notebookID: String?
    /// The recording Notebook's own sources.
    let allowedSourceIDs: Set<String>
    /// The sources of every Notebook and Goal made at or after the cutoff: the
    /// membership half of a from-scratch take, where the learner starts an empty
    /// Notebook and Discover or Add sources fills it. Membership alone earns
    /// nothing (`isTakeNotebookSource`).
    var takeSourceIDs: Set<String> = []
    /// Older public library sources kept on screen whatever their date
    /// (`ScreenRecordMode.sourceIDs`): a book the library already held, which
    /// Discover files into a take's Notebook rather than imports. Kept shows
    /// without being filed, so the learner can find it to file it.
    var keptSourceIDs: Set<String> = []
    /// The built-in recording library (`ScreenRecordLibrary.sourceIDs`), kept
    /// like `keptSourceIDs` whatever the settings say.
    var curatedSourceIDs: Set<String> = []
    /// Books kept whole (`ScreenRecordLibrary.bookIDs`): a book's chapters are
    /// its sources, grouped under the book's id.
    var curatedBookIDs: Set<String> = []
    /// Safe public sources captured, and the learner's own work created, at or
    /// after this moment show.
    let cutoff: Date
    /// The library's public sources show too (`ScreenRecordMode.showsLibrarySources`).
    var showsLibrarySources = false
    /// Images shown whatever their date (`ScreenRecordMode.imageIDs`).
    var allowedImageIDs: Set<String> = []
    /// Meeting folders whose sessions show (`ScreenRecordMode.meetingGroupIDs`).
    var allowedMeetingGroupIDs: Set<String> = []

    /// A source shows when it is one of the recording Notebook's, is a safe
    /// public browser capture added after the mode went on, is a new public
    /// source in a Notebook or Goal made during the take, is a session of a
    /// meeting folder on the kept list, or, with library sources on, is public
    /// by `isPublicLibrarySource`. A caller that cannot say the kind, address
    /// folder and discovery origin passes nil and gets the narrow answer.
    ///
    /// The source type and address are checked before the cutoff earns a pass.
    /// Otherwise an unrelated meeting, Drive page or local upload that happened
    /// to sync during a take would appear beside the deliberate X bookmark or
    /// Reading List page the take is filming.
    func allowsSource(
        id: String,
        addedAt: Date,
        kind: String? = nil,
        url: String? = nil,
        group: String? = nil,
        show: String? = nil,
        origin: DiscoveryOrigin? = nil
    ) -> Bool {
        if allowedSourceIDs.contains(id) { return true }
        if kind == StudioSourceType.meeting.rawValue, let group, allowedMeetingGroupIDs.contains(group) { return true }
        if addedAt >= cutoff,
           Self.isSafeNewCaptureSource(kind: kind, url: url, show: show, origin: origin) {
            return true
        }
        if addedAt >= cutoff, takeSourceIDs.contains(id),
           Self.isTakeNotebookSource(kind: kind, url: url, show: show) {
            return true
        }
        if isKept(id: id, kind: kind, group: group), Self.isTakeNotebookSource(kind: kind, url: url, show: show) {
            return true
        }
        return showsLibrarySources && Self.isPublicLibrarySource(kind: kind, url: url, show: show)
    }

    /// Kept on screen whatever its date: on the admin's kept list, in the
    /// built-in recording library, or a chapter of a book that library keeps.
    private func isKept(id: String, kind: String?, group: String?) -> Bool {
        if keptSourceIDs.contains(id) || curatedSourceIDs.contains(id) { return true }
        guard kind == StudioSourceType.book.rawValue, let group else { return false }
        return curatedBookIDs.contains(group)
    }

    /// What may arrive automatically while a take is running. Only a source
    /// whose discovery origin proves it came from a browser Reading List, or a
    /// public X status fetched from X bookmarks, earns the cutoff pass. A
    /// podcast subscription, followed video channel, plugin or cloud sync may
    /// also add a public URL during the take; none of those are the deliberate
    /// browser action being filmed.
    ///
    /// Books do not pass here. A newly imported EPUB/PDF has no public address
    /// with which to prove it is safe; put the two books for a take in the
    /// recording Notebook instead. Meetings likewise require their explicit
    /// folder allow-list.
    static func isSafeNewCaptureSource(
        kind: String?,
        url: String?,
        show: String? = nil,
        origin: DiscoveryOrigin?
    ) -> Bool {
        guard let kind = kind.flatMap(StudioSourceType.init(rawValue:)) else { return false }
        if kind == .course, let url, let components = URLComponents(string: url),
           components.scheme == GeneratedCourseLesson.scheme,
           components.host == GeneratedCourseLesson.host {
            return true
        }
        let isReadingList = origin == .safari || origin == .chrome || origin == .brave
        switch kind {
        case .meeting, .book:
            return false
        case .xPost:
            return (origin == .xBookmarks || isReadingList) && isPublicXStatus(url)
        case .article, .paper, .podcast, .course, .video, .manual, .unclassified:
            guard isReadingList else { return false }
            return isPublicLibrarySource(kind: kind.rawValue, url: url, show: show)
        }
    }

    /// What the learner may add by hand during a take to a Notebook or Goal
    /// made during it: a source with a public address (a paper, article, talk,
    /// podcast episode, public X status), or a book. The Discover and Add
    /// sources routes give such a source no Reading List origin, so the origin
    /// cannot vouch for it; the Notebook made in the take does. A meeting, an
    /// upload, pasted text and a private host stay off screen, and so does a
    /// source the library already held (`allowsSource` checks `addedAt`, unless
    /// the admin kept it on `ScreenRecordMode.sourceIDs`, which shows it with or
    /// without a Notebook): a Discover candidate the learner saved long before is
    /// filed into the Notebook, but their other reading never joins the take.
    static func isTakeNotebookSource(kind: String?, url: String?, show: String? = nil) -> Bool {
        guard let kind else { return false }
        if kind == StudioSourceType.xPost.rawValue { return isPublicXStatus(url) }
        return isPublicLibrarySource(kind: kind, url: url, show: show)
    }

    /// A public X status address: a post, not a profile, search or look-alike host.
    private static func isPublicXStatus(_ url: String?) -> Bool {
        guard let components = publicWebAddress(url),
              let host = components.host?.lowercased(),
              host == "x.com" || host.hasSuffix(".x.com")
                || host == "twitter.com" || host.hasSuffix(".twitter.com") else { return false }
        let parts = components.path.split(separator: "/")
        guard let status = parts.firstIndex(where: { $0.lowercased() == "status" }) else { return false }
        return parts.index(after: status) < parts.endIndex
    }

    /// An image shows when it is on the kept list or was drawn during the take.
    func allowsImage(id: String, createdAt: Date?) -> Bool {
        allowedImageIDs.contains(id) || allowsItem(createdAt: createdAt)
    }

    /// Whether a source is something anyone could read: a published paper,
    /// article, podcast episode, book or course at a public address, or a
    /// video on a public video site. Meetings, X posts (the learner's
    /// bookmarks), anything without a web address (uploads, pasted text,
    /// local PDFs) and pages on private hosts (Zoom, Drive, Slack, Notion …)
    /// never are. Books pass without an address: their chapters are split
    /// from an imported EPUB or PDF of a published book. An episode from a
    /// paid subscriber feed is not public either, whatever its page address:
    /// the feed's name carries the subscriber's own name.
    static func isPublicLibrarySource(kind: String?, url: String?, show: String? = nil) -> Bool {
        guard let kind = kind.flatMap(StudioSourceType.init(rawValue:)) else { return false }
        // SourceDiscovery stores public Apple catalog episodes under a numeric
        // identity URI; private RSS and local episodes use different path shapes.
        if kind == .podcast {
            if let show, isPrivateFeedShow(show) { return false }
            if let url, let address = URLComponents(string: url),
               address.scheme?.lowercased() == "apple-podcast" {
                guard address.host == "episode", address.user == nil,
                      address.password == nil, address.port == nil,
                      address.query == nil, address.fragment == nil,
                      let trackID = Int64(address.path.dropFirst()), trackID > 0,
                      address.path == "/\(trackID)" else { return false }
                return true
            }
        }
        switch kind {
        case .meeting, .xPost:
            return false
        case .book:
            return true
        case .paper, .article, .manual, .unclassified, .podcast, .course, .video:
            guard let components = publicWebAddress(url),
                  let host = components.host?.lowercased() else { return false }
            let matches: (Set<String>) -> Bool = { hosts in
                hosts.contains { host == $0 || host.hasSuffix("." + $0) }
            }
            if kind == .podcast, let show, isPrivateFeedShow(show) { return false }
            // A video is public only on a public video site; the rest are
            // Zoom and read.ai recordings of the learner's own meetings.
            if kind == .video { return matches(publicVideoHosts) }
            return true
        }
    }

    private static func publicWebAddress(_ value: String?) -> URLComponents? {
        guard let value, let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty,
              !privateHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return components
    }

    /// A subscriber feed's show name, as Supercast and the like title it:
    /// "The Peter Attia Drive - Private Subscriber Feed (🔓 for <name>)".
    static func isPrivateFeedShow(_ show: String) -> Bool {
        let lower = show.lowercased()
        return show.contains("🔓")
            || lower.contains("private feed")
            || lower.contains("subscriber feed")
            || lower.contains("private podcast")
    }

    private static let publicVideoHosts: Set<String> = [
        "youtube.com", "youtu.be", "vimeo.com", "ted.com",
    ]

    private static let privateHosts: Set<String> = [
        "zoom.us", "read.ai", "docs.google.com", "drive.google.com", "mail.google.com",
        "slack.com", "notion.so", "notion.site", "dropbox.com", "sharepoint.com",
        "onedrive.live.com", "box.com", "icloud.com", "linear.app", "github.com",
        "foreverlm.com", "chatgpt.site", "claude.ai",
    ]

    /// A Notebook shows when it is the recording Notebook or was made during
    /// the take.
    func allowsNotebook(id: String, createdAt: Date) -> Bool {
        id == notebookID || createdAt >= cutoff
    }

    /// The learner's own work shows only when created during this take.
    /// Notebook membership and visible source citations never expose older work.
    /// Missing dates fail closed; turning recording off leaves stored work intact.
    func allowsItem(createdAt: Date?, notebookIDs: [String?] = []) -> Bool {
        guard let createdAt else { return false }
        return createdAt >= cutoff
    }

    /// Generated walkthroughs and overviews follow the same creation boundary,
    /// even when their source is one of the curated recording sources.
    func allowsSourceDerived(createdAt: Date, sourceID: String) -> Bool {
        allowsItem(createdAt: createdAt)
    }

    /// Filter individual drafts, not whole decks: a source's deck can contain
    /// cards from both before and during this take. This is a presentation read;
    /// drafting, sync and persisted deck contents remain unchanged.
    func scopedCardDrafts(_ decks: [MemoryCardDraftDeck]) -> [MemoryCardDraftDeck] {
        decks.compactMap { record in
            var deck = record.deck
            deck.cards = deck.cards.filter { allowsItem(createdAt: $0.draftedAt) }
            guard !deck.cards.isEmpty else { return nil }
            return MemoryCardDraftDeck(deckID: record.deckID, sourceID: record.sourceID, deck: deck)
        }
    }

    /// A course shows when the recording Notebook follows it — a course is
    /// linked to notebooks (`NotebookMembership`), and it keeps no date of its
    /// own, so it follows notebook membership — or when one of
    /// its lessons, the course-typed sources it groups, is a source the take
    /// may show (`allowsSource`): filmed, safely captured during the take, or
    /// public with library sources on. A lecture's other sources earn it
    /// nothing, as a cited source earns a Page nothing: a course put together
    /// from the learner's papers is their own. The caller answers
    /// `hasShownLesson` from the store it reads
    /// (`KnowledgeStore.screenRecordCoursesWithShownLesson`).
    func allowsCourse(followedBy notebookIDs: [String], hasShownLesson: Bool) -> Bool {
        hasShownLesson || NotebookMembership.isFiled(
            in: notebookID,
            notebookIDs: NotebookMembership.filingNotebookIDs(followedBy: notebookIDs)
        )
    }

    /// Whether a row may carry a date stamp ("3 weeks ago"). A stamp from before
    /// the take reads as abandoned data on a film of someone starting out, and a
    /// curated Notebook's rows all share the day it was built; only what the take
    /// itself made keeps its stamp.
    func showsDateStamp(_ date: Date) -> Bool {
        date >= cutoff
    }

    /// A team shows when it was made during the take or holds something the
    /// take may show — the recording Notebook, a Notebook or page made during
    /// the take, a page filed under the Notebook — since its name is the
    /// learner's own (one showed under the Space sidebar's Spaces on build
    /// 208, 2026-10-10). Made, not joined: a team row that arrives by
    /// sync is stamped joined at that moment. The caller answers
    /// `holdsShownItem` from what it lists (`StudioViewModel.shownTeams`).
    func allowsTeam(createdAt: Date, holdsShownItem: Bool) -> Bool {
        holdsShownItem || createdAt >= cutoff
    }

    /// The scope as settings describe it now. `notebookSourceIDs` answers the
    /// recording Notebook's direct sources from whichever store the caller
    /// holds (the view model's loaded Notebooks, or a `KnowledgeStore`), so the
    /// storage layer and MCP need no Studio window to be scoped.
    /// `takeSourceIDs` answers, given the cutoff, the sources of the Notebooks
    /// and Goals made at or after it.
    static func resolve(
        notebookSourceIDs: (String) -> [String],
        takeSourceIDs: (_ cutoff: Date) -> [String] = { _ in [] }
    ) -> ScreenRecordScope? {
        guard ScreenRecordMode.isEffective, let cutoff = ScreenRecordMode.cutoff else { return nil }
        let notebookID = ScreenRecordMode.notebookID
        return ScreenRecordScope(
            notebookID: notebookID,
            allowedSourceIDs: Set(notebookID.map(notebookSourceIDs) ?? []),
            takeSourceIDs: Set(takeSourceIDs(cutoff)),
            keptSourceIDs: Set(ScreenRecordMode.sourceIDs),
            curatedSourceIDs: ScreenRecordLibrary.sourceIDs,
            curatedBookIDs: ScreenRecordLibrary.bookIDs,
            cutoff: cutoff,
            showsLibrarySources: ScreenRecordMode.showsLibrarySources,
            allowedImageIDs: Set(ScreenRecordMode.imageIDs),
            allowedMeetingGroupIDs: Set(ScreenRecordMode.meetingGroupIDs)
        )
    }
}

/// The library a take films, built in. The product owner, 2026-10-12: "for the
/// screen recording mode, we shouldn't show all books. We should only show a
/// few books … Similarly for YouTube, papers and articles … same with podcasts
/// too … make sure that you hardcode that somewhere in the app". One theme
/// (bioelectricity, bioenergetics, systems biology) across every library tab,
/// so a film shows a plausible library and nothing else of the admin's.
///
/// The ids are the admin's own library rows, so another library matches none
/// of them, and they apply only through `ScreenRecordScope.resolve`, which
/// answers nil unless the mode is effective: the proxy-confirmed admin's Mac.
/// Each still passes `isTakeNotebookSource`, so a row that loses its public
/// address drops out rather than showing. Add to the take with the
/// `recording.source_ids` setting; change this set for every take.
enum ScreenRecordLibrary {
    /// Books shown whole, by the book's id (its chapters' `parent_group`).
    static let bookIDs: Set<String> = [
        "2113A94E-BCC1-4670-9AAC-8E38EE9D7234",
        "2AF71614-8017-4509-A990-D0EA1EC58BC7",
        "5581CEE9-D41D-4D55-BCB8-E89D838A1594",
        "733505FA-4D91-45A6-A8DE-F496CBAAC2A1",
        "A7766C03-EC19-47BF-8B54-5F99047FFA06",
    ]

    /// Papers, articles, podcast episodes, YouTube videos and X posts.
    static let sourceIDs: Set<String> = [
        // papers
        "src_00bbb3f26f409809ce6704ec2d2bd9c7ac56695d7867e50690d18383a10d89c4",
        "src_047cad93011ec73d62d4701bdaa5a4d46ca9356e4f66258718c2baaa6a00688f",
        "src_0f5378ae5124f0a15f3fb7f32c89b3a13f478c5011224278a9888199e6e91d27",
        "src_1f6403f32c3fc55aff61f2e8334556de054322e186b63394ca4793767e5c245d",
        "src_24cc87801cd619d76bee73d43c3636c69be9dc9edbc231f232a1d0cf31177bd7",
        "src_428d864856741cfb50757bb48b4bed95cc3015dc4530e1699bfbe551edc187e6",
        "src_5272d4e975a8a4d3f663257080f11c5b8097656dd25cc2f26f9d6c9684496c0e",
        "src_67449368fc7d654830c07b72c181684b3e425592e4782fa2616a7b68391df97e",
        "src_a228c9cca3e41dde558e76865777fe3fe99c3b6dea8cbb7b274dd77ed77f39e9",
        "src_a60964959c34d98aadc5af76c2b1a91e68800e40452e917e42fb28f1aa2a683f",
        "src_abbf77be11ecbcac3e74973526fbde8c9eedb59a73cec0a270820d0481a75ba2",
        "src_afc126fb1937cdb19c1b651ec099ee413d0ec737f98d3cf081c94fee357fd3ab",
        "src_c5110ca7b624b6ffd64f9748d30f5e4f9a0910025e093bc5c493b639dc11b701",
        "src_d8f8662cce414c4e0fff35626a2431d04d349cbaf30d8bc7f5dfe94590c76e0c",
        "src_ddce1a177e8488dc3bf01ecdf42c6bf993cecb4e5e3486f4487b04a4daa4e3d9",
        // articles
        "6B4CE18C-2719-45B0-90F9-D6C34216999C",
        "AA85ABEA-9590-4087-90A6-02310BC4D322",
        "EAA74749-4D5E-4C41-B737-C99454AEBF2E",
        "src_04e23bcbbb3f651974acee79c2549907f8ad8058fd426e212fcb234e42f6043c",
        "src_1ec0acca4dc0f3bdc972077f3f3ab8015d806a10b8fb610a33c28f62c63cde8d",
        "src_3ae49ad91a362a7b68dba3895d003eb0147a5315778c0372733be177fb61c0ac",
        "src_3b9fd00c35d0c2274dec14c804e3b5511a55a954ef54cc4495fb9354950bbbad",
        "src_40b582bd84fa5eb0f08a9a9c3c980cbfc3306b295750770280d0ab7d7021f70d",
        "src_53c3f094a14d8c58c6be0e7d81b3b24dcd6fac50c30af57a2a84db136b418380",
        "src_5fb6906fa1ff0b451ca5612430f51507449eaccde2b8c4640fcefcdbf159d9ad",
        "src_878e4a2935628d5d29b920398ea4b388d829550b99b053f67fe4a80de8240195",
        "src_aecbb967547415878c36cbefb339db94f5b7e51078cf8114608c0449fcdd26a1",
        "src_db6dc525c99651132951664fe3d9304cd141d2c1161938980719c443acf34f57",
        // podcasts
        "src_071bfd17f8edfaee1150403491a80470ac84ee081c2112fa8a69c7354d9e53c8",
        "src_21e12a8888177ad466a1c3687d96d115894b6bec901bd0f87588f966e427d90d",
        "src_26443097db2139a3a2fcb7d8d9028c8128f3ebc0a20ec1eea7584575aa495aec",
        "src_28e31f19adc6938cef99647334106a8ca05aeae70bea408616e6343942bf2c8e",
        "src_479c62d39e04497ad570cdffb357067561a4a76f63ec0d748347896e6cd32f85",
        "src_49ed5bf371282821fd32de1ed5c02f797e8d4a2555ff0f9f6effcad5dda13de8",
        "src_5531e2abf77d62334ebe5ddf83ab67ca970ee9aab9dcfd7fd6ab6048253598de",
        "src_62230a2d237c58715c810a697e1a9eec3423be5c1f77984813b18fc62fef0c08",
        "src_85a23586cdcefa35f5e0ab9e0d54a9a955ce69bec397e00c5243198c860ac0e4",
        "src_8e570af07e8b0bd537a8c44c443aaa58bdaf87d4d79b3e4670422f231e80d78f",
        "src_8ee655298ff02997a14493c723ceb87e6a38e45fe9fb73d1f5e2fc6bf0d41989",
        "src_a809a7efe4664b50578b56b29b8dbc88ea88ac164b4588172f4ab6bd8235371b",
        "src_b2479553e0f004aea3d82356e589c819b69b60ec802b9b2417e28499e9ea124e",
        "src_bfe7d81f207b909ca8f5359079cf95b15792a534e97ad8ede6e98f5cad8de7d7",
        "src_c084cb61bbe8418dabe9df5f0c7ca25734472424d389fb3226548e9934c7902f",
        "src_ccd6266a8986702d3ec6c22eeb78b05e76faae0fdb087f7bd00729bdafebebd0",
        "src_d370f388f9b57e26272b7921409dfd4212c5ed03a9da12340f304da9ecde8627",
        "src_decb1b64e3728a022b2d033cae072ec0898fde33abe29eb4781cad3c04a2013f",
        "src_f682e8fe927a8c1ba42e65d149a1e46332d20b65556e942af5a4254155cf1383",
        // videos
        "src_03354e55eca8860dbac8cac4070763cdd6f525085644f463de61c410d29bcf11",
        "src_0b897732cf36f49307210cbc01741b0733655e31b370939aa9e5acc7dc7e408a",
        "src_12417feb807e723547614b8e6fff5829724c31bc3f3c7ea6a30f7d25b5390b71",
        "src_142f9e48914e0b9357e9739d43acfcc50341a89a9783ec4a1869ca7986960940",
        "src_15da44757a065ba0c09f5e5b4526459bc5d2cae16648f551c62616456be0d56c",
        "src_197b996e6609988d8fb41ef85c6c2b357bcba7e84c1be23e00d2841e36405416",
        "src_199ba55d777acba4826518994076873ebceec4a0f53e1513b3d9c44b86dbf282",
        "src_213cadbe6dcdec9708b23889f53c3c89389a956b9f212682769dcf959c07f78a",
        "src_21664cde85229be33021c0baa18caa7adef4406b199308c7ad587b9ec475c5b8",
        "src_22b59ef6317c920bcd3b4dee68cbb1fa3faf47413f632bf2dc46438dd5bdbed6",
        "src_2487e17d540379a86259c409d7209424070647327619ffb29148c8434410fbd9",
        "src_250851dc6e7b8d98aa748129591a8e0b6450137b7e1ea4fabec41c8220bcc7d0",
        "src_2cd99bacc5f729534d794b85b951dab5c522bd73a3efb87a60bbe4015f209ebc",
        "src_325dd45e1f9d3016a0a753ac2331932c80a245cddf484cc9440d90fd08b7079f",
        "src_39e251e6ed335bc627b4c5de77b5d4e59e5f131388b3ce9aeedf008f12eaef0e",
        "src_3ca9fdbc457769288e62014f21dbba93485b97471276f32e8cde0371194c59ad",
        "src_3f1dcc277e81cae86c94b33a72baece69e376674fdf5b6f676cdb15f866ad7bc",
        "src_4228c4aa050f03f286a67b5b515b0d04c187c6bcfec5d9ad855d868ed35426f9",
        "src_72a5252561aedfd3f03fd4cc4be1579d6786bbc46cbc0773f37c53d99a419c18",
        "src_7756ee435c55301fa2d2014e4ccff14ccfa9a192c701e813cadf3b5e32912313",
        "src_7beb17cbbff8c4f28b85cadc352eb067559b8b2ead09a6a070bf374eece3de9f",
        "src_8546276613a41f9783d5e7ea4fdb408eda9aff971827eddaf437809a3d0a986f",
        "src_8f8e9042a220a70232309ec021e01e1f12ade2d6f59f0cd4095aeb8ffadb4539",
        "src_93e3d10982ad9fc7d87ec7eef8e32ffd1ba502b98b4eff9c11733d23cbdb0bdd",
        "src_9a03814eead93bb36296fc129705121d6b4248e0d296ba556f41bdb9ebcbda7a",
        "src_ad27f87a2cad2d1ae05e02979da40dd097b19865fb13ea51a88dcc3ea74a0799",
        "src_b0306862f59f8a9e495928806e5573064b32fb4908adcc3cd4647aafd1e25b98",
        "src_d7b3e0d5169fd2d38a4422e07aeeff47eb6856de19bcdbd2d04515fcf92a4c0e",
        "src_dc6d2c6cc6221fe66a4d6c6d359baf42e3bf5eb7bbd02ed17add0cc657dba69c",
        "src_ddd4ea506ec99e292cd9eef9cb8738e2fba66ea146b7539f565e721adefc3c72",
        "src_dff9f5c51e262dcd726bfb034deb6c57ea504a98b11bcf4e39be86a341034094",
        "src_e2faeb17a954406c57e24dce0324b8b3402ed77670dba74835090f89b1d2b860",
        "src_e7bd3567d018870b010200fa77ef2011345d663b61d039f72023574c9df7bf2c",
        "src_f51476ccb79e395622c0b2f66459c5f5314f4ecc24bc669df2c749358071d44b",
        "src_fcc78382680aa9456c3cdc7a48db7c0d308668b5e2581f79ea15ab41180bec54",
        // xPosts
        "src_45c49d5f9bf1fff75af5ac700dc3a6ba14d6eb35fc2a70087bf7673f2ad99657",
        "src_7c54f59e0040cee5920cf65fe2b79289bf4f3b7b788c5a913dc537a5d4e44b49",
        "src_c8459fbf736fd2ad4730bca844fbb82e8fd6ff4510d33140b594b093b76f5380",
        "src_cd145eb526bb835d20f5386f3322c93fe72c8049a7a1b218c8226ad97b84f194",
        "src_cf473e330722d15cd03599d1ce7b0c97a0a3afe05a812c15125e5b74c6c3535f",
        "src_dff0122434b229b8b35579f8c3f3190b36a4abcaae65620e4d189927f279dc60",
    ]
}

extension ScreenRecordScope {
    /// A Planner block shows only when it was drawn during the take. The product owner,
    /// 2026-09-24: "my planner should also be private". The day is his diary,
    /// so a block earns nothing by being about the recording Notebook or a
    /// filmed source, and a calendar event never shows: its title is his own,
    /// synced in at any moment.
    ///
    /// Drawn during the take is not enough on its own: the app draws blocks
    /// by itself (a review suggested after half an hour of reading), and one
    /// drawn at 23:45 on 2026-09-24 named a paper the product owner had open in his
    /// other window. So a block's sources, if it has any, must all be the
    /// recording Notebook's.
    func allowsBlock(_ block: TimeBlock) -> Bool {
        block.calendarEventID == nil
            && block.createdAt >= cutoff
            && block.sourceIDs.allSatisfy { allowedSourceIDs.contains($0) }
    }

    /// A calendar event shows only when it was added to the calendar during
    /// the take and names nobody else: the day is the learner's own, and a
    /// meeting's title and guests are other people's too. An event whose
    /// account keeps no creation date never shows.
    func allowsCalendarEvent(_ event: AppleCalendarEvent) -> Bool {
        guard let createdAt = event.createdAt else { return false }
        return createdAt >= cutoff && !event.hasOtherPeople
    }

    /// An observed span shows when it happened during the take and, for a
    /// span spent in a source, when that source is the recording Notebook's:
    /// another window may be reading something of the learner's own.
    func allowsActivity(_ activity: DayActivity) -> Bool {
        guard activity.createdAt >= cutoff else { return false }
        switch activity.kind {
        case .reading, .listening, .watching: return allowedSourceIDs.contains(activity.targetID)
        case .chat, .doc: return true
        // The other apps and sites the learner had in front are their own.
        case .offTrack: return false
        }
    }

    /// A day as the Activity pane and `get_day_activity` show it while
    /// recording: only the take's own blocks, learning bouts and observed
    /// activity, and the
    /// day's notes only when the plan itself was started during the take. The
    /// stored plan is untouched; only this copy is narrowed, so revising the
    /// day still sees every block.
    func scoped(_ detail: DayPlanDetail) -> DayPlanDetail {
        var scoped = detail
        scoped.blocks = detail.blocks.filter(allowsBlock)
        scoped.activities = detail.activities.filter(allowsActivity)
        scoped.bouts = detail.bouts.filter { bout in
            bout.createdAt >= cutoff && bout.sourceIDs.allSatisfy { allowedSourceIDs.contains($0) }
        }
        if scoped.plan.createdAt < cutoff {
            scoped.plan.notes = nil
        }
        return scoped
    }
}

extension KnowledgeStore {
    /// The screen-record scope resolved against this store's own Notebooks.
    /// Nil when the mode is off, which is every learner but the admin.
    func screenRecordScope() -> ScreenRecordScope? {
        ScreenRecordScope.resolve(
            notebookSourceIDs: { notebookID in
                (try? self.loadLearningGoal(notebookID))?.approvedSourceIDs ?? []
            },
            takeSourceIDs: { cutoff in
                (try? self.screenRecordTakeSourceIDs(since: cutoff)) ?? []
            }
        )
    }

    /// The sources of every Notebook and Goal made at or after `cutoff`: a
    /// from-scratch take's own Notebooks. Few rows, so each is loaded whole.
    func screenRecordTakeSourceIDs(since cutoff: Date) throws -> [String] {
        var goalIDs: [String] = []
        try queryBind("SELECT id FROM learning_goals WHERE created_at >= ?", bind: { stmt in
            self.bind(stmt, 1, cutoff.timeIntervalSinceReferenceDate)
        }) { stmt in
            if let id = self.string(stmt, 0) { goalIDs.append(id) }
        }
        return try goalIDs.flatMap { try self.loadLearningGoal($0)?.approvedSourceIDs ?? [] }
    }

    /// Every stored source id the scope keeps off screen. Empty when the mode
    /// is off. One indexed pass over `source_projection`, the same shape as
    /// `knowledgeSearchExcludedSourceIDs`, which folds this in.
    func screenRecordExcludedSourceIDs(scope: ScreenRecordScope?) throws -> Set<String> {
        guard let scope else { return [] }
        var excluded: Set<String> = []
        try queryBind("""
            SELECT id, date_added, source_type, url, parent_group, domain, discovery_origin
            FROM source_projection
        """, bind: { _ in }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            let addedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            if !scope.allowsSource(
                id: id, addedAt: addedAt,
                kind: self.string(stmt, 2), url: self.string(stmt, 3), group: self.string(stmt, 4),
                show: self.string(stmt, 5),
                origin: self.string(stmt, 6).flatMap { DiscoveryOrigin(rawValue: $0) }
            ) {
                excluded.insert(id)
            }
        }
        return excluded
    }

    /// The courses holding a lesson — an active course-typed source grouped
    /// under the course — that the scope lets on screen: the half of
    /// `ScreenRecordScope.allowsCourse` a course's sources answer. One pass
    /// over the lessons in `source_projection`.
    func screenRecordCoursesWithShownLesson(scope: ScreenRecordScope) throws -> Set<String> {
        let kind = StudioSourceType.course.rawValue
        var courseIDs: Set<String> = []
        try queryBind("""
            SELECT id, date_added, url, parent_group, domain, discovery_origin
            FROM source_projection
            WHERE source_type = ? AND status = 'active' AND parent_group IS NOT NULL
        """, bind: { stmt in
            self.bind(stmt, 1, kind)
        }) { stmt in
            guard let id = self.string(stmt, 0), let courseID = self.string(stmt, 3) else { return }
            let addedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            if scope.allowsSource(
                id: id, addedAt: addedAt,
                kind: kind, url: self.string(stmt, 2), group: courseID, show: self.string(stmt, 4),
                origin: self.string(stmt, 5).flatMap { DiscoveryOrigin(rawValue: $0) }
            ) {
                courseIDs.insert(courseID)
            }
        }
        return courseIDs
    }
}
