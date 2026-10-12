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
    static let enabledKey = "screenRecordMode.enabled"
    static let notebookIDKey = "screenRecordMode.notebookID"
    static let cutoffKey = "screenRecordMode.cutoff"
    /// Whether the library's public sources show too (`ScreenRecordScope.isPublicLibrarySource`).
    static let librarySourcesKey = "screenRecordMode.librarySources"
    /// Images kept on screen although they were drawn before the take: an
    /// image carries no Notebook or source to earn a pass by.
    static let imageIDsKey = "screenRecordMode.imageIDs"
    /// Older public library sources kept on screen although the library held
    /// them before the take (`ScreenRecordScope.keptSourceIDs`).
    static let sourceIDsKey = "screenRecordMode.sourceIDs"
    /// Meeting folders whose sessions show although meetings never count as
    /// public: a seminar series the admin chooses to film.
    static let meetingGroupIDsKey = "screenRecordMode.meetingGroupIDs"
    /// The last admin answer the proxy gave this Mac's signed-in account.
    /// Written only from a balance that loaded, cleared on sign-out, and left
    /// alone by a transient failure, so a network blip mid-take does not drop
    /// the scope and put the private library on screen.
    static let confirmedAdminKey = "screenRecordMode.confirmedAdmin"

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

    private static var defaults: UserDefaults { overrideDefaults?.defaults ?? .standard }

    /// Whether this account may see and use the mode at all.
    static var isAvailable: Bool {
        defaults.bool(forKey: confirmedAdminKey)
    }

    /// The stored switch, whatever the account. Only Settings and the MCP
    /// entry read it directly; everything that filters asks `isEffective`.
    static var isStoredOn: Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// The one gate: the switch is on and the proxy has said this account is
    /// an admin, or the build forces it.
    static var isEffective: Bool {
        isForcedByBuild || (isStoredOn && isAvailable)
    }

    /// The Notebook whose sources stay on screen, or nil for "none": then only
    /// safe public captures and work made after the cutoff show.
    static var notebookID: String? {
        guard let id = defaults.string(forKey: notebookIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return id
    }

    /// The product owner, 2026-09-24: "the source is not necessarily need to be hidden
    /// … showcase what the app can do, that it can pull the sources
    /// together". On, every public source in the library shows beside the
    /// recording Notebook's: papers, articles, podcasts, books, courses and
    /// public videos. Meetings, X posts, uploads and private hosts still do
    /// not, and the learner's own chats, Docs and Goals are unaffected.
    static var showsLibrarySources: Bool {
        defaults.bool(forKey: librarySourcesKey)
    }

    /// The images kept on screen whatever their date (`imageIDsKey`).
    static var imageIDs: [String] {
        (defaults.stringArray(forKey: imageIDsKey) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The older public library sources kept on screen (`sourceIDsKey`).
    static var sourceIDs: [String] {
        (defaults.stringArray(forKey: sourceIDsKey) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The meeting folders kept on screen (`meetingGroupIDsKey`).
    static var meetingGroupIDs: [String] {
        (defaults.stringArray(forKey: meetingGroupIDsKey) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The moment the mode was turned on. Anything created at or after it is
    /// the take's own work and shows.
    static var cutoff: Date? {
        guard isEffective else { return nil }
        if isStoredOn, let stored = defaults.object(forKey: cutoffKey) as? Date {
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
            defaults.set(now, forKey: cutoffKey)
        } else {
            defaults.removeObject(forKey: cutoffKey)
        }
        defaults.set(enabled, forKey: enabledKey)
        postChange()
    }

    static func setNotebookID(_ notebookID: String?) {
        let trimmed = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard next != self.notebookID else { return }
        if let next {
            defaults.set(next, forKey: notebookIDKey)
        } else {
            defaults.removeObject(forKey: notebookIDKey)
        }
        postChange()
    }

    static func setShowsLibrarySources(_ shows: Bool) {
        guard shows != showsLibrarySources else { return }
        defaults.set(shows, forKey: librarySourcesKey)
        postChange()
    }

    static func setImageIDs(_ ids: [String]) {
        var seen: Set<String> = []
        let next = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard next != imageIDs else { return }
        if next.isEmpty {
            defaults.removeObject(forKey: imageIDsKey)
        } else {
            defaults.set(next, forKey: imageIDsKey)
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
            defaults.removeObject(forKey: sourceIDsKey)
        } else {
            defaults.set(next, forKey: sourceIDsKey)
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
            defaults.removeObject(forKey: meetingGroupIDsKey)
        } else {
            defaults.set(next, forKey: meetingGroupIDsKey)
        }
        postChange()
    }

    /// Records what a successful balance load said. `ManagedAIAccountModel`
    /// calls this; nothing else decides who is an admin.
    static func recordAdminStatus(_ isAdmin: Bool) {
        guard isAdmin != isAvailable else { return }
        defaults.set(isAdmin, forKey: confirmedAdminKey)
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
        if keptSourceIDs.contains(id), Self.isTakeNotebookSource(kind: kind, url: url, show: show) {
            return true
        }
        return showsLibrarySources && Self.isPublicLibrarySource(kind: kind, url: url, show: show)
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
            cutoff: cutoff,
            showsLibrarySources: ScreenRecordMode.showsLibrarySources,
            allowedImageIDs: Set(ScreenRecordMode.imageIDs),
            allowedMeetingGroupIDs: Set(ScreenRecordMode.meetingGroupIDs)
        )
    }
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
