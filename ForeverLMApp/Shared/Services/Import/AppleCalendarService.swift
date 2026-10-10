import AppKit
import EventKit
import Foundation
import OSLog

enum AppleCalendarServiceError: LocalizedError {
    case accessDenied
    case accessRestricted
    case notConnected
    case readFailed(String)
    case eventNotFound
    /// The event cannot be changed from ForeverLM; the reason is the message.
    case notEditable(String)
    case invalidEvent(String)
    case noCalendarForNewEvents
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "ForeverLM is not allowed to use your calendars. Allow it under System Settings → Privacy & Security → Calendars, then turn the calendar on again."
        case .accessRestricted:
            return "Calendar access is restricted on this Mac, so ForeverLM cannot use the Calendar app."
        case .notConnected:
            return "The Mac's Calendar is not turned on for ForeverLM. Turn it on in Settings › Plugins › Calendar."
        case .readFailed(let message):
            return message
        case .eventNotFound:
            return "That event is no longer in the Mac's Calendar."
        case .notEditable(let reason):
            return reason
        case .invalidEvent(let reason):
            return reason
        case .noCalendarForNewEvents:
            return "The Mac's Calendar has no calendar that takes new events. Add one in the Calendar app, or choose one in Settings › Plugins › Calendar."
        case .writeFailed(let message):
            return "The Calendar app refused the change: \(message)"
        }
    }
}

/// A calendar's colour as sRGB components, so it can cross actors.
struct CalendarColor: Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(_ cgColor: CGColor?) {
        guard let cgColor, let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
    }

    /// `#RRGGBB`, for an assistant reading the day.
    var hex: String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

/// One calendar in the Mac's Calendar app, whichever account holds it.
struct AppleCalendarListEntry: Identifiable, Equatable, Sendable {
    /// `EKCalendar.calendarIdentifier`. Local to this Mac: the same iCloud
    /// calendar has a different identifier on the other Mac.
    let id: String
    let title: String
    /// The account the calendar belongs to: "iCloud", "Google", "On My Mac"…
    let account: String
    /// `EKSource.sourceIdentifier` of that account, or empty when Calendar
    /// names none. Tells a calendar from an account added after the
    /// learner's choice from one they left off.
    var accountID: String = ""
    /// The system's Birthdays calendar. Left off the day until asked for.
    let isBirthdays: Bool
    /// Read from a subscription URL (holidays, a team's published calendar).
    let isSubscribed: Bool
    /// Whether events can be added to it and changed in it.
    var allowsModifications: Bool = false
    var color: CalendarColor? = nil
}

/// One event occurrence in the Mac's Calendar. Recurring events arrive one
/// occurrence at a time, each sharing the series' `eventIdentifier` and
/// carrying its own `occurrenceDate`.
struct AppleCalendarEvent: Equatable, Sendable {
    let calendarID: String
    /// `EKEvent.eventIdentifier`: the series' identifier for a recurring event.
    let eventIdentifier: String
    /// The occurrence's original date when the event recurs; nil for a single
    /// event. Stable when the occurrence is moved, so it names the occurrence.
    let occurrenceDate: Date?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// The learner declined the invitation.
    let isDeclined: Bool
    /// Marked free: the event does not hold the time.
    let isFree: Bool
    let isCancelled: Bool
    /// A birthday from Contacts.
    let isBirthday: Bool
    let location: String?
    /// The event's own URL field, where a conference link usually lives.
    let url: String?
    /// Who the invitation names, as Calendar spells them: each attendee's
    /// name, or their address when Calendar holds no name. Rooms and
    /// resources are left out, and so is anyone who declined. Empty for an
    /// event with no guest list.
    var attendeeNames: [String] = []
    var calendarTitle: String = ""
    var calendarColor: CalendarColor? = nil
    var notes: String? = nil
    /// Someone besides the learner is on the event: an invitation, or a
    /// meeting the learner organised. Changing either sends those people an
    /// update, so ForeverLM leaves it to the Calendar app.
    var hasOtherPeople: Bool = false
    /// Its calendar takes changes.
    var calendarAllowsModifications: Bool = false
    /// When the event was first saved to the calendar, when the account says.
    var createdAt: Date? = nil

    /// Names this occurrence among all others: the event's identifier, and
    /// for a recurring one its original date too.
    var occurrenceKey: String {
        guard let occurrenceDate else { return eventIdentifier }
        return "\(eventIdentifier)@\(Int(occurrenceDate.timeIntervalSince1970))"
    }

    /// Whether ForeverLM may move, rename or delete it.
    var isEditable: Bool { calendarAllowsModifications && !hasOtherPeople }

    /// Whether it holds a stretch of the learner's day: timed, not declined,
    /// not marked free, not cancelled, not a birthday. What the chip counts
    /// as "now" and what a meeting's transcript is matched against.
    var holdsTime: Bool { !isAllDay && !isDeclined && !isFree && !isCancelled && !isBirthday }

    /// The Calendar app's own link to the event, which `open` hands to it.
    var calendarAppURL: URL? { AppleCalendarService.calendarAppURL(eventIdentifier: eventIdentifier) }

    /// Where the meeting is joined: the first link to a meeting service in
    /// its URL field, location or notes — a Teams invitation's notes also
    /// carry help links, and those are not the call — else the first web
    /// link at all.
    var joinLink: TimeBlockLink? {
        let links = TimeBlockLink.links(in: [url, location, notes].compactMap { $0 }.joined(separator: " "))
        return links.first { $0.label.hasPrefix("Join ") } ?? links.first
    }
}

// MARK: - The ForeverLM things an event links to

extension AppleCalendarEvent {
    /// The notebook a block of work is for: the first
    /// `foreverlm://notebook/<id>` link in its URL field or notes, the way the
    /// assistant writes a topic block's notebook into it
    /// (`create_calendar_event`). Nil when the event names none.
    var notebookID: String? { CalendarEventLinks(text: linkText).notebookIDs.first }

    /// The sources a block of work is for: every `foreverlm://source/<id>`
    /// link in its URL field and notes, first occurrence first, each once.
    /// An id may be the short prefix a chat cites a source by.
    var sourceIDs: [String] { CalendarEventLinks(text: linkText).sourceIDs }

    private var linkText: String { [url, notes].compactMap { $0 }.joined(separator: "\n") }
}

/// The ForeverLM links in an event's text: `foreverlm://notebook/<id>` (the older
/// `foreverlm://project/<id>` reads the same) and
/// `foreverlm://source/<id>`, bare or as a Markdown link's target. The
/// product scheme is how links are stored; the running build's own scheme
/// (`foreverlm-dev`) names the same things, as `StudioEntityLink` reads them.
struct CalendarEventLinks: Equatable, Sendable {
    var notebookIDs: [String] = []
    var sourceIDs: [String] = []

    /// A scheme, `://`, and everything up to a space, quote, bracket or
    /// parenthesis — the end of a Markdown link's target. The punctuation of
    /// the sentence a bare link ends is trimmed off each match after
    /// (`ChatSourceEvidence.trimmingTrailingLinkPunctuation`).
    private static let linkPattern = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"'()\[\]]+"#)

    init(text: String) {
        guard !text.isEmpty, let pattern = Self.linkPattern else { return }
        let schemes: Set<String> = [StudioEntityLink.productScheme, ForeverLMRuntimeIdentity.urlScheme.lowercased()]
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text),
                  let url = URL(string: String(ChatSourceEvidence.trimmingTrailingLinkPunctuation(text[matchRange]))),
                  let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { continue }
            if case .notebook(let id) = StudioEntityLink.parse(url) {
                if !notebookIDs.contains(id) { notebookIDs.append(id) }
            } else if url.host?.lowercased() == "source",
                      let id = url.pathComponents.dropFirst().first?.removingPercentEncoding?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty, !sourceIDs.contains(id) {
                sourceIDs.append(id)
            }
        }
    }
}

/// What a new event is, before the Calendar app holds it.
struct CalendarEventDraft: Sendable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var notes: String?
    var location: String?
    var url: URL?
    /// The calendar to put it on; nil for the one new events go to.
    var calendarID: String?
}

/// Changes to an existing event; nil leaves a field as it is, and an empty
/// string clears a text field.
struct CalendarEventChanges: Sendable {
    var title: String?
    var start: Date?
    var end: Date?
    var isAllDay: Bool?
    var notes: String?
    var location: String?
    var url: String?
    var calendarID: String?

    var isEmpty: Bool {
        title == nil && start == nil && end == nil && isAllDay == nil
            && notes == nil && location == nil && url == nil && calendarID == nil
    }
}

/// Which occurrences of a recurring event a change reaches.
enum CalendarEventSpan: String, Sendable {
    case thisEvent = "this"
    case futureEvents = "future"

    var eventKitSpan: EKSpan { self == .thisEvent ? .thisEvent : .futureEvents }
}

/// The Mac's Calendar app, through EventKit: the learner's day. Whatever
/// accounts the Mac's Calendar holds — iCloud, Google, Exchange, a
/// subscription — their events are what the day holds, and the assistant
/// plans the day by writing events into it. ForeverLM holds no grant of its
/// own: the system asks once, per Mac.
///
/// Connected means two things at once: the learner turned the calendar on,
/// and macOS granted full access. Either alone reads nothing. The switch and
/// the chosen calendars live in `UserDefaults`, not the synced Keychain,
/// because both the grant and the calendar identifiers are this Mac's.
///
/// ForeverLM writes only what it is asked to — an event the assistant or the
/// learner adds, moves or removes — and never an event with other people on
/// it, since a change there is a message to them. Accounts themselves are
/// signed in by macOS (System Settings › Internet Accounts); no app can add
/// one, so the Settings pane sends the learner there and shows the new
/// account's calendars when they come back.
actor AppleCalendarService {
    static let shared = AppleCalendarService()

    /// The learner's switch. Off until the Settings pane turns it on. The
    /// key keeps the name the Planner gave it, so a Mac that had the calendar
    /// on keeps it on.
    nonisolated static let enabledKey = "planner.appleCalendar.enabled"
    /// String array of `calendarIdentifier`s the day is read from. Absent
    /// means every calendar but Birthdays.
    ///
    /// Not the Planner's key: a choice made there does not carry over
    /// (`retirePlannerCalendarChoice`).
    nonisolated static let selectedIDsKey = "calendar.dayCalendarIDs"
    /// The `sourceIdentifier`s of the accounts the Mac held when the learner
    /// last chose. A calendar from any other account — an Exchange account
    /// signed in since — is shown until the learner unticks it. Keyed on the
    /// account rather than the calendar because a full re-sync can hand an
    /// existing calendar a new identifier, and that must not bring back a
    /// calendar the learner left off.
    nonisolated static let knownAccountIDsKey = "calendar.dayKnownAccountIDs"
    /// Where the Planner kept the Mac calendars it drew. It drew them beside
    /// the Google Calendar plugin, so a Google account's calendars were often
    /// left off here so as not to draw an event twice, and some Macs kept no
    /// calendar at all. The plugin went with the Planner on 2026-09-30 and
    /// the Mac's Calendar became the whole day, so that choice hid the day:
    /// The product owner's chip said "Nothing on the calendar" over ten events,
    /// six of them the evening a chat had just planned into iCloud.
    nonisolated static let retiredPlannerSelectionKeys = [
        "planner.appleCalendar.selectedIDs",
        "planner.appleCalendar.knownAccountIDs",
    ]
    /// The `calendarIdentifier` new events go to. Absent means the calendar
    /// the Calendar app itself puts new events on.
    nonisolated static let newEventsCalendarIDKey = "calendar.newEventsCalendarID"

    private let logger = Logger(subsystem: "com.foreverlm", category: "AppleCalendarService")
    /// Replaced after a grant: a store made before access was given does not
    /// see the calendars.
    private var store = EKEventStore()
    /// The system prompt in flight, so two presses in one tick — a button
    /// fired twice, two panes — ask macOS once. A second request while the
    /// prompt is up is answered "denied" and recorded as the learner's
    /// answer, orphaning the prompt they never saw.
    private var accessRequest: Task<Bool, Error>?
    private nonisolated var defaults: UserDefaults { .standard }

    // MARK: - State

    nonisolated var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    nonisolated var hasFullAccess: Bool {
        authorizationStatus == .fullAccess
    }

    /// The system will not ask again: the learner said no, or a profile
    /// forbids it. The Settings pane points at System Settings instead.
    nonisolated var isBlockedBySystem: Bool {
        switch authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    nonisolated var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    /// Turned on by the learner and readable.
    nonisolated var isConnected: Bool {
        isEnabled && hasFullAccess
    }

    /// The calendars the day is read from, by identifier; nil until the
    /// learner narrows the list.
    nonisolated var selectedIDs: [String]? {
        get { defaults.stringArray(forKey: Self.selectedIDsKey) }
    }

    nonisolated var knownAccountIDs: [String]? {
        defaults.stringArray(forKey: Self.knownAccountIDsKey)
    }

    /// The learner's choice of `ids`, made while the Mac held `calendars`:
    /// their accounts are the ones the choice covers.
    nonisolated func setSelectedIDs(_ ids: [String], among calendars: [AppleCalendarListEntry]) {
        defaults.set(ids, forKey: Self.selectedIDsKey)
        defaults.set(Self.accountIDs(of: calendars), forKey: Self.knownAccountIDsKey)
        Self.notifyChanged()
    }

    nonisolated static func accountIDs(of calendars: [AppleCalendarListEntry]) -> [String] {
        Array(Set(calendars.map(\.accountID))).sorted()
    }

    /// Drops the Planner's choice of Mac calendars (`retiredPlannerSelectionKeys`),
    /// so every Mac starts the day from every calendar but Birthdays and the
    /// learner narrows it again in Settings › Plugins › Calendar. Nothing
    /// reads those keys any more; removing absent keys is a no-op.
    nonisolated static func retirePlannerCalendarChoice() {
        for key in retiredPlannerSelectionKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The calendar the learner chose for new events; nil for the Calendar
    /// app's own default.
    nonisolated var newEventsCalendarID: String? {
        defaults.string(forKey: Self.newEventsCalendarIDKey)
    }

    nonisolated func setNewEventsCalendarID(_ id: String?) {
        if let id, !id.isEmpty { defaults.set(id, forKey: Self.newEventsCalendarIDKey) }
        else { defaults.removeObject(forKey: Self.newEventsCalendarIDKey) }
        Self.notifyChanged()
    }

    /// Turns the calendar on, asking macOS for access the first time. Throws
    /// when the system has said no, so the pane can point at Privacy &
    /// Security.
    func connect() async throws {
        switch authorizationStatus {
        case .fullAccess:
            break
        case .notDetermined, .writeOnly:
            let request: Task<Bool, Error>
            if let running = accessRequest {
                request = running
            } else {
                let store = self.store
                request = Task { try await store.requestFullAccessToEvents() }
                accessRequest = request
            }
            let granted: Bool
            do {
                granted = try await request.value
            } catch {
                accessRequest = nil
                throw AppleCalendarServiceError.readFailed(error.localizedDescription)
            }
            accessRequest = nil
            guard granted else { throw AppleCalendarServiceError.accessDenied }
            store = EKEventStore()
        case .denied:
            throw AppleCalendarServiceError.accessDenied
        case .restricted:
            throw AppleCalendarServiceError.accessRestricted
        @unknown default:
            throw AppleCalendarServiceError.accessDenied
        }
        defaults.set(true, forKey: Self.enabledKey)
        logger.info("Mac Calendar turned on")
        Self.notifyChanged()
    }

    /// Turns the calendar off. The system grant stays — it is the learner's
    /// to revoke in System Settings — and so does every event in it.
    nonisolated func disconnect() {
        defaults.set(false, forKey: Self.enabledKey)
        defaults.removeObject(forKey: Self.selectedIDsKey)
        defaults.removeObject(forKey: Self.knownAccountIDsKey)
        Self.notifyChanged()
    }

    /// The connection or the calendar choice changed: Settings, the chip and
    /// the plugin list read it again.
    nonisolated static func notifyChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
        }
    }

    /// Asks the accounts behind the Calendar app to fetch what changed on
    /// their servers — a meeting added in Outlook a minute ago. The answer
    /// arrives as `EKEventStoreChanged`.
    func refreshAccounts() {
        guard isConnected else { return }
        store.refreshSourcesIfNecessary()
    }

    /// System Settings → Privacy & Security → Calendars, for a grant the
    /// learner once refused.
    @MainActor
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// System Settings › Internet Accounts, where macOS signs in to
    /// Microsoft Exchange (and Microsoft 365), Google, Yahoo and the rest.
    /// Calendar's own Add Account sheet leads to the same place.
    @MainActor
    static func openInternetAccountsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The Calendar app's own link to an event, which `open` hands to it.
    nonisolated static func calendarAppURL(eventIdentifier: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?&=:")
        guard let encoded = eventIdentifier.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else { return nil }
        return URL(string: "ical://ekevent/\(encoded)?method=show&options=more")
    }

    /// Shows the event in the Calendar app.
    @MainActor
    static func openInCalendarApp(_ event: AppleCalendarEvent) {
        if let url = event.calendarAppURL { NSWorkspace.shared.open(url) }
    }

    /// Brings the Calendar app forward.
    @MainActor
    static func openCalendarApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Reading

    /// Every calendar the Mac's Calendar app holds, by account then title.
    func calendars() throws -> [AppleCalendarListEntry] {
        guard hasFullAccess else { throw AppleCalendarServiceError.accessDenied }
        let calendars = store.calendars(for: .event)
            .map(Self.entry)
            .sorted { lhs, rhs in
                if lhs.account != rhs.account {
                    return lhs.account.localizedCaseInsensitiveCompare(rhs.account) == .orderedAscending
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        // A choice made before accounts were remembered covers the accounts
        // the Mac holds now, so only one signed in from here on is new.
        if selectedIDs != nil, knownAccountIDs == nil {
            defaults.set(Self.accountIDs(of: calendars), forKey: Self.knownAccountIDsKey)
        }
        return calendars
    }

    private static func entry(_ calendar: EKCalendar) -> AppleCalendarListEntry {
        AppleCalendarListEntry(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            account: calendar.source?.title ?? "",
            accountID: calendar.source?.sourceIdentifier ?? "",
            isBirthdays: calendar.type == .birthday,
            isSubscribed: calendar.type == .subscription,
            allowsModifications: calendar.allowsContentModifications,
            color: CalendarColor(calendar.cgColor)
        )
    }

    /// The calendars the day is read from: the learner's choice, or, until
    /// there is one, every calendar but Birthdays. Either way a calendar from
    /// an account signed in after the choice is shown too, Birthdays aside,
    /// and so is the calendar new events go to.
    func shownCalendars() throws -> [AppleCalendarListEntry] {
        let all = try calendars()
        return Self.shown(
            from: all,
            selectedIDs: selectedIDs,
            knownAccountIDs: knownAccountIDs,
            newEventsCalendarID: try resolvedNewEventsCalendar()?.calendarIdentifier
        )
    }

    /// Pure, so the default can be pinned. `knownAccountIDs` nil with a
    /// choice means the accounts were not recorded yet: the choice alone.
    /// `newEventsCalendarID` is shown whatever the choice: a chat plans the
    /// day by writing events there, and a plan the chip cannot read is no
    /// plan.
    nonisolated static func shown(
        from calendars: [AppleCalendarListEntry],
        selectedIDs: [String]?,
        knownAccountIDs: [String]?,
        newEventsCalendarID: String?
    ) -> [AppleCalendarListEntry] {
        calendars.filter { calendar in
            calendar.id == newEventsCalendarID
                || isChosen(calendar, selectedIDs: selectedIDs, knownAccountIDs: knownAccountIDs)
        }
    }

    /// Whether the learner's choice (or, before one, the default) takes in
    /// `calendar`, leaving aside the calendar new events go to: what the
    /// Settings checkboxes store.
    nonisolated static func isChosen(
        _ calendar: AppleCalendarListEntry,
        selectedIDs: [String]?,
        knownAccountIDs: [String]?
    ) -> Bool {
        guard let selectedIDs else { return !calendar.isBirthdays }
        if selectedIDs.contains(calendar.id) { return true }
        guard let knownAccountIDs, !calendar.isBirthdays else { return false }
        return !knownAccountIDs.contains(calendar.accountID)
    }

    /// The calendar new events go to: the learner's choice while it still
    /// takes events, else the one the Calendar app itself uses for new
    /// events. Nil when the Mac has no calendar that takes events.
    func newEventsCalendar() throws -> AppleCalendarListEntry? {
        guard hasFullAccess else { throw AppleCalendarServiceError.accessDenied }
        return try resolvedNewEventsCalendar().map(Self.entry)
    }

    /// The calendar the Calendar app itself puts new events on: where they
    /// go until the learner chooses one.
    func calendarAppNewEventsCalendar() throws -> AppleCalendarListEntry? {
        guard hasFullAccess else { throw AppleCalendarServiceError.accessDenied }
        return store.defaultCalendarForNewEvents.map(Self.entry)
    }

    private func resolvedNewEventsCalendar(requested: String? = nil) throws -> EKCalendar? {
        if let requested {
            guard let calendar = store.calendar(withIdentifier: requested) else {
                throw AppleCalendarServiceError.invalidEvent("No calendar on this Mac has the id \(requested).")
            }
            guard calendar.allowsContentModifications else {
                throw AppleCalendarServiceError.notEditable("“\(calendar.title)” does not take new events.")
            }
            return calendar
        }
        if let chosen = newEventsCalendarID, let calendar = store.calendar(withIdentifier: chosen), calendar.allowsContentModifications {
            return calendar
        }
        return store.defaultCalendarForNewEvents
    }

    /// The occurrences on the shown calendars that touch `[from, to)`.
    func shownEvents(from: Date, to: Date) throws -> [AppleCalendarEvent] {
        try events(calendarIDs: shownCalendars().map(\.id), from: from, to: to)
    }

    /// The occurrences on `calendarIDs` that touch `[from, to)`, by start.
    func events(calendarIDs: [String], from: Date, to: Date) throws -> [AppleCalendarEvent] {
        guard isConnected else { throw AppleCalendarServiceError.notConnected }
        let wanted = Set(calendarIDs)
        let calendars = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate)
            .compactMap(Self.snapshot)
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.end != rhs.end { return lhs.end < rhs.end }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private static func snapshot(_ event: EKEvent) -> AppleCalendarEvent? {
        guard let identifier = event.eventIdentifier, let calendar = event.calendar else { return nil }
        let isRecurring = event.hasRecurrenceRules || event.isDetached
        let me = event.attendees?.first { $0.isCurrentUser }
        let others = (event.attendees ?? []).contains { !$0.isCurrentUser }
            || (event.organizer.map { !$0.isCurrentUser } ?? false)
        return AppleCalendarEvent(
            calendarID: calendar.calendarIdentifier,
            eventIdentifier: identifier,
            occurrenceDate: isRecurring ? (event.occurrenceDate ?? event.startDate) : nil,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            isDeclined: me?.participantStatus == .declined,
            isFree: event.availability == .free,
            isCancelled: event.status == .canceled,
            isBirthday: event.birthdayContactIdentifier != nil || calendar.type == .birthday,
            location: event.location,
            url: event.url?.absoluteString,
            attendeeNames: attendeeNames(from: event.attendees ?? []),
            calendarTitle: calendar.title,
            calendarColor: CalendarColor(calendar.cgColor),
            notes: event.notes,
            hasOtherPeople: others,
            calendarAllowsModifications: calendar.allowsContentModifications,
            createdAt: event.creationDate
        )
    }

    /// The people on an invitation, in Calendar's order: name, or the
    /// address Calendar knows them by when it has no name (a `mailto:` URL
    /// stripped of its scheme). Rooms, resources and groups are not people;
    /// someone who declined was asked, not there.
    nonisolated static func attendeeNames(from participants: [EKParticipant]) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        for participant in participants {
            guard participant.participantType == .person || participant.participantType == .unknown else { continue }
            if participant.participantStatus == .declined { continue }
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var address = participant.url.absoluteString
            if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst("mailto:".count)) }
            let chosen = name.isEmpty ? address : name
            guard !chosen.isEmpty, seen.insert(chosen.lowercased()).inserted else { continue }
            names.append(chosen)
        }
        return names
    }

    /// One event by identifier: for a recurring event, the occurrence whose
    /// original date is `occurrenceDate`; without one, the event itself (the
    /// series' first occurrence).
    func event(identifier: String, occurrenceDate: Date?) throws -> AppleCalendarEvent {
        guard let event = Self.snapshot(try findEvent(identifier: identifier, occurrenceDate: occurrenceDate)) else {
            throw AppleCalendarServiceError.eventNotFound
        }
        return event
    }

    private func findEvent(identifier: String, occurrenceDate: Date?) throws -> EKEvent {
        guard isConnected else { throw AppleCalendarServiceError.notConnected }
        guard let base = store.event(withIdentifier: identifier) else { throw AppleCalendarServiceError.eventNotFound }
        guard let occurrenceDate, base.hasRecurrenceRules || base.isDetached else { return base }
        // An occurrence is found by its original date, which stays put when
        // the occurrence is moved; a moved one may sit a day or two off it.
        guard let calendar = base.calendar,
              let from = Calendar.current.date(byAdding: .day, value: -2, to: occurrenceDate),
              let to = Calendar.current.date(byAdding: .day, value: 3, to: occurrenceDate) else {
            throw AppleCalendarServiceError.eventNotFound
        }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        let match = store.events(matching: predicate).first { candidate in
            guard candidate.eventIdentifier == identifier else { return false }
            let original = candidate.occurrenceDate ?? candidate.startDate
            return original.map { abs($0.timeIntervalSince(occurrenceDate)) < 1 } ?? false
        }
        guard let match else { throw AppleCalendarServiceError.eventNotFound }
        return match
    }

    // MARK: - Writing

    /// Adds an event and returns it as the Calendar app now holds it.
    func createEvent(_ draft: CalendarEventDraft) throws -> AppleCalendarEvent {
        guard isConnected else { throw AppleCalendarServiceError.notConnected }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AppleCalendarServiceError.invalidEvent("An event needs a title.") }
        guard draft.end > draft.start else { throw AppleCalendarServiceError.invalidEvent("An event must end after it starts.") }
        guard let calendar = try resolvedNewEventsCalendar(requested: draft.calendarID) else {
            throw AppleCalendarServiceError.noCalendarForNewEvents
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.notes = Self.nonEmpty(draft.notes)
        event.location = Self.nonEmpty(draft.location)
        event.url = draft.url
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw AppleCalendarServiceError.writeFailed(error.localizedDescription)
        }
        logger.info("Added an event to \(calendar.title, privacy: .private)")
        guard let saved = Self.snapshot(event) else { throw AppleCalendarServiceError.eventNotFound }
        return saved
    }

    /// Moves, renames or rewrites an event the learner owns alone.
    func updateEvent(identifier: String, occurrenceDate: Date?, changes: CalendarEventChanges, span: CalendarEventSpan) throws -> AppleCalendarEvent {
        let event = try findEvent(identifier: identifier, occurrenceDate: occurrenceDate)
        try Self.requireEditable(event)
        if let title = changes.title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AppleCalendarServiceError.invalidEvent("An event needs a title.") }
            event.title = trimmed
        }
        if let isAllDay = changes.isAllDay { event.isAllDay = isAllDay }
        if let start = changes.start { event.startDate = start }
        if let end = changes.end { event.endDate = end }
        guard event.endDate > event.startDate else {
            throw AppleCalendarServiceError.invalidEvent("An event must end after it starts.")
        }
        if let notes = changes.notes { event.notes = Self.nonEmpty(notes) }
        if let location = changes.location { event.location = Self.nonEmpty(location) }
        if let url = changes.url {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                event.url = nil
            } else {
                guard let parsed = URL(string: trimmed), parsed.scheme != nil else {
                    throw AppleCalendarServiceError.invalidEvent("\(trimmed) is not a link.")
                }
                event.url = parsed
            }
        }
        if let calendarID = changes.calendarID, calendarID != event.calendar?.calendarIdentifier {
            guard let calendar = try resolvedNewEventsCalendar(requested: calendarID) else {
                throw AppleCalendarServiceError.noCalendarForNewEvents
            }
            event.calendar = calendar
        }
        do {
            try store.save(event, span: span.eventKitSpan, commit: true)
        } catch {
            throw AppleCalendarServiceError.writeFailed(error.localizedDescription)
        }
        guard let saved = Self.snapshot(event) else { throw AppleCalendarServiceError.eventNotFound }
        return saved
    }

    /// Removes an event the learner owns alone.
    func deleteEvent(identifier: String, occurrenceDate: Date?, span: CalendarEventSpan) throws {
        let event = try findEvent(identifier: identifier, occurrenceDate: occurrenceDate)
        try Self.requireEditable(event)
        do {
            try store.remove(event, span: span.eventKitSpan, commit: true)
        } catch {
            throw AppleCalendarServiceError.writeFailed(error.localizedDescription)
        }
    }

    private static func requireEditable(_ event: EKEvent) throws {
        let title = event.title ?? "This event"
        guard event.calendar?.allowsContentModifications == true else {
            throw AppleCalendarServiceError.notEditable("“\(title)” is on a calendar ForeverLM cannot change (\(event.calendar?.title ?? "read-only")).")
        }
        let others = (event.attendees ?? []).contains { !$0.isCurrentUser }
            || (event.organizer.map { !$0.isCurrentUser } ?? false)
        guard !others else {
            throw AppleCalendarServiceError.notEditable("“\(title)” has other people on it, and changing it would send them an update. Change it in the Calendar app.")
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
