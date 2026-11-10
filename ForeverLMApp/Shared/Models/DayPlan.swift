import Foundation

enum TimeBlockStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case done
    /// Deliberately not done. Recorded rather than deleted so the shutdown
    /// review sees what was let go.
    case skipped

    var displayName: String {
        switch self {
        case .planned: return "Planned"
        case .done: return "Done"
        case .skipped: return "Skipped"
        }
    }
}

/// What kind of hour a block is: what the learner will be doing in it, which
/// decides what the block's one button does.
///
/// The product owner (2026-09-19), asking to plan work from a Goal: "like put reviews on
/// the planner for example". Reading a paper and being reviewed on it are two
/// different hours, and until this build the Planner could only tell them apart
/// by what the learner had typed in the title. Three, because there are three
/// things an hour on this clock is. The retired `kind` (deep, shallow, meeting,
/// break) was a mode of *work*, not this, and stays retired.
enum TimeBlockPurpose: String, Codable, CaseIterable, Sendable {
    /// Time given to doing something — writing the doc, making the site,
    /// email. Its button is a chat. The default, and what every block drawn
    /// before this build is: nothing about them said otherwise.
    case work
    /// The hour reads the block's sources. Its button opens the reading.
    case read
    /// The hour is reviewed on the block's sources: explaining them back and
    /// being asked about them. Its button starts a review with them in
    /// context.
    case review

    /// Tolerant parse for the stored column, the synced key and the MCP
    /// argument: nil, empty or anything unrecognized reads as `.work`, which
    /// is what a block with nothing said about it has always been.
    static func parse(_ raw: String?) -> TimeBlockPurpose {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let parsed = TimeBlockPurpose(rawValue: raw) else { return .work }
        return parsed
    }

    /// What the hour is, in the Planner's words.
    var displayName: String {
        switch self {
        case .work: return "Work"
        case .read: return "Read"
        case .review: return "Review"
        }
    }

    /// Whether an hour of this kind is about material the block names. The
    /// MCP tools refuse a read or a review that names none: an assistant
    /// planning one has to say what is being read. The day's own Memory
    /// review block is the single review drawn without sources, because what
    /// it reviews is the day's memory rather than a reading.
    var needsSources: Bool { self != .work }

    /// The mark the Planner draws beside the hour's name: the open book for a
    /// read, the brain the Memory review already wears for a review. Work is
    /// the default and wears nothing, so the two hours that are not work are
    /// the ones that stand out.
    var symbolName: String? {
        switch self {
        case .work: return nil
        case .read: return "book"
        case .review: return "brain"
        }
    }
}

/// The card's word for an open block past its end (`TimeBlock.openNote`).
enum OpenBlockNote: Equatable, Sendable {
    /// Over by less than its own length: plausibly still in progress.
    case runningLong(minutesOver: Int)
    /// Over by more than its own length, or the day is shut: it did not run
    /// long, it was never closed out, and the honest answers are done or skipped.
    case leftOpen(endMinute: Int)

    /// "Running long · 25m over", or "Not closed out · ended 14:30".
    var text: String {
        switch self {
        case .runningLong(let over):
            return "Running long · \(DayNow.durationText(max(1, over))) over"
        case .leftOpen(let end):
            return "Not closed out · ended \(DayPlan.clockString(minute: end))"
        }
    }

    /// Whether the card wears orange: only a block that may still be running
    /// is worth an alarm; one left open is a question, not an emergency.
    var isRunningLong: Bool {
        if case .runningLong = self { return true }
        return false
    }
}

/// One block of time on one day's plan.
///
/// A day has one plan, and every edit lands on the block's own row (product owner,
/// 2026-09-29: "there should just be 1 planner; not separate versions").
/// A deleted block is tombstoned rather than removed, so two devices merging
/// the same day never resurrect it.
///
/// Until then a day was redrawn in numbered columns: a redraw left the rows
/// it replaced in their old column, marked superseded, and an edit after a
/// redraw drew a new row. Rows an older build wrote that way still carry
/// `supersededInRevision` and are not part of the plan (`isCurrent`), so such
/// a day reads as its last column.
struct TimeBlock: Identifiable, Codable, Equatable, Sendable {
    let id: String
    /// The `DayPlan.id` this block belongs to, which is the plan's date.
    var dayPlanID: String
    /// Minutes after local midnight, 0...1440.
    var startMinute: Int
    var endMinute: Int
    var title: String
    /// The learner's own words on the hour: for a meeting, what to bring up;
    /// for a reading, where to pick up. Never written by an import — the
    /// calendar's say about the hour is `location`.
    var notes: String?
    /// Where the hour happens, as the calendar says it: the event's
    /// conference link (Zoom, Meet, Teams) or else its room. Set by the
    /// calendar import and followed on every re-import, the way the time and
    /// title are, so it never crowds `notes`; the editor draws a link here as
    /// a Join button and a room as a line. Nil on a block drawn by hand.
    var location: String?
    /// The Notebook this block works on, when it has one. No foreign key: the
    /// block outlives the Notebook the way a Schedule placement does.
    var notebookID: String?
    /// The Goal this hour is meant to serve, when the learner said so. A block
    /// may name a Goal, a Notebook, both, or neither: the Goal is what the time
    /// is *toward*, the Notebook only which pool the reading comes from. No
    /// foreign key, for the same reason as `notebookID`.
    var goalID: String?
    /// The sources this block is for — the papers or chapters the block reads,
    /// in the order they were added — so the block can open its reading and
    /// start a chat with it in context. Set by dropping sources on the clock
    /// or on the block. No foreign key, for the same reason as `notebookID`.
    var sourceIDs: [String]
    /// What kind of hour this is — work, a read, or a review of the sources
    /// it names. Drawn by hand as `work` unless the editor says otherwise,
    /// and set over MCP when the assistant plans a reading or a review toward
    /// a Goal.
    var purpose: TimeBlockPurpose
    /// The calendar event this block mirrors, when a connected calendar drew
    /// it: `google:<calendar id>/<event id>`. The import finds the block again
    /// by it, so an event moved or renamed in the calendar updates the block
    /// instead of drawing a second one, and a block the learner removed is
    /// not drawn back. No foreign key: the calendar is outside the library.
    var calendarEventID: String?
    /// The event's own page in the calendar, so the block can open it.
    var calendarEventURL: String?
    var status: TimeBlockStatus
    /// The day's stored `DayPlan.revision` when the row was written. Nothing
    /// here reads it: it is written so a build that still draws columns, on
    /// another device, shows the row in its current one.
    var revision: Int
    /// Set only by builds that drew columns: the column that replaced this
    /// row. A row carrying it is not part of the plan. Never written now.
    var supersededInRevision: Int?
    /// Set when the block was deleted, or replaced by a redraw.
    var deletedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        dayPlanID: String,
        startMinute: Int,
        endMinute: Int,
        title: String,
        notes: String? = nil,
        location: String? = nil,
        notebookID: String? = nil,
        goalID: String? = nil,
        sourceIDs: [String] = [],
        purpose: TimeBlockPurpose = .work,
        calendarEventID: String? = nil,
        calendarEventURL: String? = nil,
        status: TimeBlockStatus = .planned,
        revision: Int = 1,
        supersededInRevision: Int? = nil,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.dayPlanID = dayPlanID
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.title = title
        self.notes = notes
        self.location = location
        self.notebookID = notebookID
        self.goalID = goalID
        self.sourceIDs = sourceIDs
        self.purpose = purpose
        self.calendarEventID = calendarEventID
        self.calendarEventURL = calendarEventURL
        self.status = status
        self.revision = revision
        self.supersededInRevision = supersededInRevision
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `kind` (deep, shallow, meeting, break) was written by builds up to 99
    /// and is ignored on the way in. `sourceID` is the single source those
    /// builds carried; it is read when `sourceIDs` is absent and written as
    /// the first source so a record drawn here still opens its reading on an
    /// older client.
    private enum CodingKeys: String, CodingKey {
        case id, dayPlanID, startMinute, endMinute, title, notes, location, notebookID, goalID, sourceID, sourceIDs, purpose, status
        case calendarEventID, calendarEventURL
        case revision, supersededInRevision, deletedAt, createdAt, updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(dayPlanID, forKey: .dayPlanID)
        try c.encode(startMinute, forKey: .startMinute)
        try c.encode(endMinute, forKey: .endMinute)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(notes, forKey: .notes)
        // A new key from build 128 on: an older client decodes past it and
        // keeps the block's notes as they are, and the next calendar import
        // on this Mac writes the location again if that client dropped it.
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(notebookID, forKey: .notebookID)
        try c.encodeIfPresent(goalID, forKey: .goalID)
        try c.encode(sourceIDs, forKey: .sourceIDs)
        try c.encodeIfPresent(sourceIDs.first, forKey: .sourceID)
        try c.encode(purpose, forKey: .purpose)
        try c.encodeIfPresent(calendarEventID, forKey: .calendarEventID)
        try c.encodeIfPresent(calendarEventURL, forKey: .calendarEventURL)
        try c.encode(status, forKey: .status)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(supersededInRevision, forKey: .supersededInRevision)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        dayPlanID = try c.decode(String.self, forKey: .dayPlanID)
        startMinute = try c.decode(Int.self, forKey: .startMinute)
        endMinute = try c.decode(Int.self, forKey: .endMinute)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        notebookID = try c.decodeIfPresent(String.self, forKey: .notebookID)
        goalID = try c.decodeIfPresent(String.self, forKey: .goalID)
        if let ids = try c.decodeIfPresent([String].self, forKey: .sourceIDs) {
            sourceIDs = TimeBlock.normalizedSourceIDs(ids)
        } else {
            sourceIDs = TimeBlock.normalizedSourceIDs([try c.decodeIfPresent(String.self, forKey: .sourceID)].compactMap { $0 })
        }
        // A block from a client that has no purpose is work, which is what
        // every block was before this build.
        purpose = TimeBlockPurpose.parse(try c.decodeIfPresent(String.self, forKey: .purpose))
        calendarEventID = try c.decodeIfPresent(String.self, forKey: .calendarEventID)
        calendarEventURL = try c.decodeIfPresent(String.self, forKey: .calendarEventURL)
        status = TimeBlockStatus(rawValue: try c.decodeIfPresent(String.self, forKey: .status) ?? "") ?? .planned
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        supersededInRevision = try c.decodeIfPresent(Int.self, forKey: .supersededInRevision)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    var durationMinutes: Int { max(0, endMinute - startMinute) }

    /// The ids trimmed, blanks dropped, duplicates folded to their first place.
    static func normalizedSourceIDs(_ ids: [String]) -> [String] {
        SourceIDList.normalized(ids)
    }

    /// The JSON text `time_blocks.source_ids` stores: a JSON array of ids.
    var sourceIDsJSON: String {
        let data = (try? JSONEncoder().encode(sourceIDs)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads `sourceIDsJSON` back; a blank, or a column written by an older
    /// build, falls back to the single `source_id` it also kept.
    static func sourceIDs(fromJSON json: String?, legacySourceID: String?) -> [String] {
        if let json, let data = json.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data), !ids.isEmpty {
            return normalizedSourceIDs(ids)
        }
        return normalizedSourceIDs([legacySourceID].compactMap { $0 })
    }

    /// Part of the day's plan: not deleted, and not left behind in a column
    /// by a build that drew them.
    var isCurrent: Bool { supersededInRevision == nil && deletedAt == nil }

    /// Drawn by a connected calendar rather than by hand. Its time and title
    /// follow the event, and it is what the day is fixed around: Extend and
    /// the assistant's redraw leave it where the calendar put it. Everything
    /// else on it is the learner's.
    var isFromCalendar: Bool { calendarEventID != nil }

    /// The web links the block carries, in order and without repeats: the
    /// calendar's conference link from `location` first, then any the
    /// learner wrote into the notes. The editor draws each one as a button
    /// rather than leaving it as text to copy out.
    var links: [TimeBlockLink] {
        var seen = Set<String>()
        return (TimeBlockLink.links(in: location) + TimeBlockLink.links(in: notes)).filter { link in
            seen.insert(link.url.absoluteString).inserted
        }
    }

    /// The calendar's word on where the hour is when it is not a link: a
    /// room, an address. Nil when there is no location or it is the link the
    /// Join button already covers.
    var locationText: String? {
        guard let location, !location.isEmpty, TimeBlockLink.links(in: location).isEmpty else { return nil }
        return location
    }

    /// Whether this block should have finished by `minute` and has not been
    /// closed out — the planner's "running behind" signal.
    func isOverdue(atMinute minute: Int) -> Bool {
        isCurrent && status == .planned && endMinute <= minute
    }

    /// Whether an open block is over by more than its own length. Inside that
    /// span it is running long and fifteen more minutes is a fair offer; past
    /// it the block did not run long, it did not happen, and the honest
    /// answers are done or skipped (product owner, 2026-09-20, on a fifteen-minute
    /// Memory review "55m over": "this is not so helpful for the planner").
    /// Mirrored by `timeBlockWasLeftOpen` on the web.
    func wasLeftOpen(atMinute minute: Int) -> Bool {
        isOverdue(atMinute: minute) && minute - endMinute > durationMinutes
    }

    /// What the card says under the title of an open block past its end, or
    /// nil while the block is inside its grace or already answered for.
    /// Inside its own length the block is running long and the minutes over
    /// are the point; past it — or once the day is shut, when nothing can be
    /// running — the block did not run long, it was left open, and the card
    /// asks rather than blames. Until 2026-09-20 the card had one word for
    /// both, "Running late", and said it of a block from the afternoon at
    /// ten in the evening (the product owner: "why I running late"). Mirrored by
    /// `openTimeBlockNote` on the web.
    func openNote(nowMinute: Int, dayIsShut: Bool) -> OpenBlockNote? {
        guard isCurrent, status == .planned else { return nil }
        if dayIsShut {
            return startMinute <= nowMinute ? .leftOpen(endMinute: endMinute) : nil
        }
        guard isOverdue(atMinute: nowMinute - DayPlan.overdueGraceMinutes) else { return nil }
        if wasLeftOpen(atMinute: nowMinute) { return .leftOpen(endMinute: endMinute) }
        return .runningLong(minutesOver: nowMinute - endMinute)
    }

    /// Whether `minute` falls inside the block.
    func contains(minute: Int) -> Bool {
        startMinute <= minute && minute < endMinute
    }

    /// Whether this row and `other` share any minute. Two blocks that only
    /// touch — one ending at 10:00, the next starting there — do not.
    func overlaps(_ other: TimeBlock) -> Bool {
        startMinute < other.endMinute && other.startMinute < endMinute
    }

    /// Whether the day's rule against overlapping blocks is this block's to
    /// keep. A block a connected calendar drew is where the calendar put it:
    /// two calendars' meetings at one hour are both real, and a meeting laid
    /// over a planned block is the calendar's news, not a block the learner
    /// drew wrong. Every other block is placed by hand, by the assistant or
    /// over MCP, and none of those may be drawn over another.
    var keepsClearOfOtherBlocks: Bool { !isFromCalendar }

    /// Trims the title, clamps the times to the day, and guarantees a positive
    /// duration. Blocks shorter than five minutes cannot be drawn or read.
    func normalized(now: Date = Date()) -> TimeBlock {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.notes?.isEmpty == true { copy.notes = nil }
        copy.location = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.location?.isEmpty == true { copy.location = nil }
        copy.notebookID = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.notebookID?.isEmpty == true { copy.notebookID = nil }
        copy.goalID = goalID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.goalID?.isEmpty == true { copy.goalID = nil }
        copy.sourceIDs = Self.normalizedSourceIDs(sourceIDs)
        copy.calendarEventID = calendarEventID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.calendarEventID?.isEmpty == true { copy.calendarEventID = nil }
        copy.calendarEventURL = calendarEventURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.calendarEventURL?.isEmpty == true { copy.calendarEventURL = nil }
        copy.startMinute = min(max(0, startMinute), DayPlan.minutesPerDay - DayPlan.minimumBlockMinutes)
        copy.endMinute = min(max(copy.startMinute + DayPlan.minimumBlockMinutes, endMinute), DayPlan.minutesPerDay)
        copy.revision = max(1, revision)
        copy.updatedAt = now
        return copy
    }
}

/// A web link found in a block's location or notes, with the name it is drawn under.
struct TimeBlockLink: Equatable, Sendable {
    let url: URL
    /// "Join Zoom", "Join Google Meet", or "Open <host>" for anything else.
    let label: String

    /// Every http(s) link in `text`, first occurrence first, each once.
    static func links(in text: String?) -> [TimeBlockLink] {
        guard let text, !text.isEmpty else { return [] }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var links: [TimeBlockLink] = []
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty else { continue }
            let key = url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            links.append(TimeBlockLink(url: url, label: label(forHost: host)))
        }
        return links
    }

    /// The button title for a link on `host`. The meeting services people
    /// actually put in calendar events get their name; the rest get the host.
    static func label(forHost host: String) -> String {
        let host = host.lowercased()
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bare == "zoom.us" || bare.hasSuffix(".zoom.us") || bare.hasSuffix(".zoomgov.com") { return "Join Zoom" }
        if bare == "meet.google.com" { return "Join Google Meet" }
        if bare == "teams.microsoft.com" || bare == "teams.live.com" || bare.hasSuffix(".teams.microsoft.com") { return "Join Teams" }
        if bare == "meet.jit.si" || bare.hasSuffix(".jitsi.net") { return "Join Jitsi" }
        if bare == "whereby.com" || bare.hasSuffix(".whereby.com") { return "Join Whereby" }
        if bare == "webex.com" || bare.hasSuffix(".webex.com") { return "Join Webex" }
        if bare == "facetime.apple.com" { return "Join FaceTime" }
        return "Open \(bare)"
    }
}

/// One day's time-block plan.
///
/// The id *is* the local date (`2026-09-09`), so two devices that each plan the
/// same day offline produce one record rather than two, and CloudKit merges
/// them block by block. Everything about the day that is not a block — the
/// scratch notes, whether the shutdown was done — lives here.
struct DayPlan: Identifiable, Codable, Equatable, Sendable {
    /// Same as `date`.
    let id: String
    /// Local calendar date, `YYYY-MM-DD`.
    let date: String
    /// The column a build that drew columns was drawing in; 1 unless such a
    /// build redrew the day. Nothing moves it now, and new rows are stamped
    /// with it (`TimeBlock.revision`) so that build keeps showing them.
    var revision: Int
    /// Free text for the day: the task list, ideas, the shutdown note.
    var notes: String?
    /// When the shutdown ritual was completed. Nil until the day is closed.
    var shutdownAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        date: String,
        revision: Int = 1,
        notes: String? = nil,
        shutdownAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = date
        self.date = date
        self.revision = revision
        self.notes = notes
        self.shutdownAt = shutdownAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, revision, notes, shutdownAt, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDate = try c.decodeIfPresent(String.self, forKey: .date)
        let decodedID = try c.decodeIfPresent(String.self, forKey: .id)
        guard let date = decodedDate ?? decodedID else {
            throw DecodingError.keyNotFound(
                CodingKeys.date,
                .init(codingPath: decoder.codingPath, debugDescription: "A day plan needs a date.")
            )
        }
        self.date = date
        id = date
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        shutdownAt = try c.decodeIfPresent(Date.self, forKey: .shutdownAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    static let minutesPerDay = 24 * 60
    static let minimumBlockMinutes = 5
    /// The hours a day has: the outer bound of what any clock may draw.
    /// The Mac's clock draws `PlannerDayHours` — the learner's own window,
    /// six to midnight unless they set it — widened to hold whatever the day
    /// contains (`DayPlanDetail.clockHourRange`). Web Studio still draws all
    /// of this, as `DAY_PLAN_HOUR_RANGE`.
    static let dayHourRange = 0...24
    /// A block that has run this far past its end without being closed is the
    /// signal that the day needs redrawing.
    static let overdueGraceMinutes = 10
    /// An observation of the same thing this soon after a log span ended
    /// extends the span; a longer silence starts a new one. Wide enough to
    /// cover the reader's two-minute ledger batches and the wait for a long
    /// chat answer, short enough that lunch shows as a gap.
    static let activityMergeGapMinutes = 10
    /// A log span seen this recently is still going. The reader writes its
    /// time in two-minute batches, so the sitting in progress can end a
    /// minute or two behind the clock, or on the minute after it.
    static let activityOngoingMinutes = 3
    /// Spans of one thing closer together than this — the paper read, a chat
    /// about it, the paper again — are drawn as one sitting in the lane, the
    /// logged minutes banded inside it. Storage keeps the spans; only the
    /// drawing joins them.
    static let activitySittingGapMinutes = 30
    /// A thing the day never spent this many minutes on is a glance: a paper
    /// opened and closed, a chat with one turn. Glances are folded out of the
    /// lane and counted in the side panel instead of drawn as slivers.
    static let activityGlanceMinutes = 2

    // MARK: - The closing block

    /// The block every drawn day ends with: shut the day down, and draw the
    /// next one.
    ///
    /// Planning tomorrow is part of today's plan rather than a card that
    /// interrupts tomorrow (product owner, 2026-09-18: "it should be planned as
    /// part of the daily plan at the end of the day; then in the morning we
    /// can just get started"). This is the same habit the plan nudge was
    /// built to teach, moved onto the clock where the rest of the day's
    /// intentions already live: a day that ends by drawing the next one needs
    /// nothing to ask it in the morning, which is why nothing does any more.
    static let closingBlockTitle = "Shut down · plan tomorrow"
    /// Long enough to carry what is left and draw the next day, short enough
    /// that it is never the reason the day ran over.
    static let closingBlockMinutes = 20

    /// Whether a block is that closing block.
    ///
    /// By title, because a block has no kind — `kind` was dropped after build
    /// 99 and nothing replaced it. The consequence is the right one: a
    /// renamed closing block is simply the learner's own block again, and the
    /// day draws a new one the next time it is redrawn.
    static func isClosingBlock(_ block: TimeBlock) -> Bool {
        block.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(closingBlockTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// The closing block for `date`, drawn after everything already on it.
    ///
    /// Nil when there is nothing to close (an empty day asks for nothing), when
    /// the day already ends by planning the next one, or when the last block
    /// runs so close to midnight that there is no room — a day drawn to the end
    /// of the clock is not given a block that would not fit on it.
    static func closingBlock(for date: String, after blocks: [TimeBlock], now: Date = Date()) -> TimeBlock? {
        guard !blocks.isEmpty, !blocks.contains(where: isClosingBlock) else { return nil }
        guard let start = blocks.map(\.endMinute).max(), start + closingBlockMinutes <= minutesPerDay else {
            return nil
        }
        return TimeBlock(
            dayPlanID: date,
            startMinute: start,
            endMinute: start + closingBlockMinutes,
            title: closingBlockTitle,
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - The memory review block

    /// The block every day holds for its memory review: the day's goal, on
    /// the clock.
    ///
    /// The product owner (2026-09-19), right after asking for the review to be a
    /// committed session: "that also needs to be planned on the planner every
    /// day i think". So the fifteen minutes have a place in the day rather
    /// than being owed to a badge. Like the closing block it is recognised by
    /// its title, because a block has no kind; renamed, it is the learner's
    /// own block again.
    static let memoryReviewBlockTitle = "Memory review"

    /// Whether a block is the day's memory review block.
    static func isMemoryReviewBlock(_ block: TimeBlock) -> Bool {
        isMemoryReviewTitle(block.title)
    }

    /// The same test on a title alone, for a block that is still being drawn:
    /// the MCP tools let a review with this title go without sources, because
    /// it is the one review whose material is the day's memory.
    static func isMemoryReviewTitle(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(memoryReviewBlockTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// The id every device gives the memory review block it draws for
    /// `date`. Each Mac draws the block when its Planner shows the day, and
    /// before CloudKit has carried one Mac's block to the other both see a day
    /// without one: on 2026-09-22 that put two blocks on the clock, at 00:15
    /// and 00:30. With one id per day the two draws are the same row, and the
    /// sync's union by id keeps one of them.
    static func memoryReviewBlockID(for date: String) -> String {
        "memory-review-\(date)"
    }

    /// The memory review block for `date`, on the first free stretch of
    /// `minutes` at or after `earliestMinute`, snapped up to the quarter hour.
    ///
    /// Nil when the day already holds one in any row, deleted ones included,
    /// so a block the learner took off the day, or redrew away, is
    /// not put back, and a block renamed away still holds the day's id — and
    /// nil when no stretch of `minutes` is free before midnight: a day drawn
    /// to the end of the clock is not given a block that would not fit on
    /// it. Free means clear of every current block.
    static func memoryReviewBlock(
        for date: String,
        among blocks: [TimeBlock],
        minutes: Int,
        earliestMinute: Int,
        now: Date = Date()
    ) -> TimeBlock? {
        let id = memoryReviewBlockID(for: date)
        guard minutes >= minimumBlockMinutes,
              !blocks.contains(where: { $0.id == id || isMemoryReviewBlock($0) }) else { return nil }
        guard let start = firstFreeQuarterHour(minutes: minutes, from: earliestMinute, among: blocks) else { return nil }
        return TimeBlock(
            id: id,
            dayPlanID: date,
            startMinute: start,
            endMinute: start + minutes,
            title: memoryReviewBlockTitle,
            // The one review drawn with no sources: what it reviews is
            // the day's memory, not a reading.
            purpose: .review,
            createdAt: now,
            updatedAt: now
        )
    }

    /// The first quarter hour at or after `earliestMinute` from which
    /// `minutes` are clear of every current block, or nil when no such
    /// stretch is left before midnight: a day drawn to the end of the clock
    /// is not given a block that would not fit on it.
    static func firstFreeQuarterHour(minutes: Int, from earliestMinute: Int, among blocks: [TimeBlock]) -> Int? {
        let quarter = 15
        var start = max(0, ((max(0, earliestMinute) + quarter - 1) / quarter) * quarter)
        let occupied = blocks.filter(\.isCurrent).sorted { $0.startMinute < $1.startMinute }
        while start + minutes <= minutesPerDay {
            // The first current block that overlaps the stretch pushes the
            // start past its own end; a stretch nothing overlaps is the one.
            if let blocking = occupied.first(where: { $0.startMinute < start + minutes && $0.endMinute > start }) {
                start = max(start + quarter, ((blocking.endMinute + quarter - 1) / quarter) * quarter)
                continue
            }
            return start
        }
        return nil
    }

    // MARK: - One block at a time

    /// No two blocks share a minute of the day (product owner, 2026-09-19:
    /// "overlapping sessions on the planner are not allowed"). The clock is
    /// what the day is going to be, and an hour given to two things is given
    /// to neither. The store refuses a block drawn over another
    /// (`KnowledgeStore.addTimeBlock`, `updateTimeBlock`, `reviseDayPlan`),
    /// and every place a block is put finds the free time first, so the
    /// refusal is the last line and rarely the one that speaks: a dragged
    /// block stops against its neighbour, a drawn block is cut where the next
    /// block starts, a dropped source takes the room there is. Calendar-drawn
    /// blocks are the exception, in both directions — see
    /// `TimeBlock.keepsClearOfOtherBlocks`.

    /// The quarter hour the clock snaps to. `DayTimelineView.snapMinutes` is
    /// this, and the memory review block lands on it too.
    static let gridMinutes = 15

    /// The current blocks among `blocks` that share a minute with `block`,
    /// by start, `block` itself excluded. Empty when `block` is a calendar
    /// block, which is never in the wrong.
    static func blocksOverlapping(_ block: TimeBlock, among blocks: [TimeBlock]) -> [TimeBlock] {
        guard block.keepsClearOfOtherBlocks else { return [] }
        return blocks
            .filter { $0.id != block.id && $0.isCurrent && $0.overlaps(block) }
            .sorted { $0.startMinute < $1.startMinute }
    }

    /// What the store says when it refuses `block` for the blocks in its way.
    static func overlapMessage(for block: TimeBlock, overlapping others: [TimeBlock]) -> String {
        let inTheWay = others.map { "‘\($0.title)’ \(clockString(minute: $0.startMinute))–\(clockString(minute: $0.endMinute))" }
        return "‘\(block.title)’ \(clockString(minute: block.startMinute))–\(clockString(minute: block.endMinute)) overlaps \(inTheWay.joined(separator: " and ")). Blocks on a day do not overlap; move or shorten one first."
    }

    /// The free stretch of the day around `minute`: from the end of the last
    /// current block that ends at or before it to the start of the first
    /// that starts after it, or the day's edges. Nil when `minute` is inside
    /// a block. Every block counts here, calendar ones included: the block
    /// being placed is the one that has to keep clear.
    static func freeStretch(around minute: Int, among blocks: [TimeBlock], excluding excludedID: String? = nil) -> ClosedRange<Int>? {
        let occupied = blocks.filter { $0.isCurrent && $0.id != excludedID }
        guard !occupied.contains(where: { $0.contains(minute: minute) }) else { return nil }
        let lower = occupied.filter { $0.endMinute <= minute }.map(\.endMinute).max() ?? 0
        let upper = occupied.filter { $0.startMinute > minute }.map(\.startMinute).min() ?? minutesPerDay
        guard upper - lower >= minimumBlockMinutes else { return nil }
        return lower...upper
    }

    /// The first free stretch of at least the minimum block at or after
    /// `minute`, pushed past any block that holds `minute`; nil when the rest
    /// of the day is spoken for.
    static func firstFreeStretch(from minute: Int, among blocks: [TimeBlock]) -> ClosedRange<Int>? {
        var cursor = max(0, minute)
        let occupied = blocks.filter(\.isCurrent).sorted { $0.startMinute < $1.startMinute }
        while cursor <= minutesPerDay - minimumBlockMinutes {
            if let holding = occupied.first(where: { $0.contains(minute: cursor) }) {
                cursor = max(cursor + 1, holding.endMinute)
                continue
            }
            if let stretch = freeStretch(around: cursor, among: blocks) {
                return max(cursor, stretch.lowerBound)...stretch.upperBound
            }
            // Free, but too little of it: the next block's end is the next chance.
            guard let next = occupied.first(where: { $0.startMinute >= cursor }) else { return nil }
            cursor = next.endMinute
        }
        return nil
    }

    /// Every stretch from `start` to `end` that no current block holds, in
    /// order, each at least `minimumMinutes` long. It is what `get_day_plan`
    /// says is left of today, so an assistant draws into time the clock has
    /// not passed yet. Calendar blocks count, as every block does here.
    static func freeStretches(from start: Int, to end: Int, among blocks: [TimeBlock], minimumMinutes: Int = gridMinutes) -> [Range<Int>] {
        let limit = min(end, minutesPerDay)
        var cursor = max(0, start)
        var stretches: [Range<Int>] = []
        for block in blocks.filter(\.isCurrent).sorted(by: { $0.startMinute < $1.startMinute }) {
            guard cursor < limit else { break }
            guard block.endMinute > cursor else { continue }
            let gapEnd = min(block.startMinute, limit)
            if gapEnd - cursor >= minimumMinutes { stretches.append(cursor..<gapEnd) }
            cursor = max(cursor, block.endMinute)
        }
        if limit - cursor >= minimumMinutes { stretches.append(cursor..<limit) }
        return stretches
    }

    /// Where a block `minutes` long asked to start at `start` lands so it is
    /// clear of every current block: `start` itself when the stretch is free,
    /// otherwise the free start nearest to it — flush against the block in
    /// the way on whichever side is closer, or over it into the free time
    /// beyond. Ties go to the earlier start. Nil when no stretch of `minutes`
    /// is free anywhere in the day. `excludedID` is the block being moved,
    /// which does not stand in its own way.
    static func nearestFreeStart(forDuration minutes: Int, near start: Int, among blocks: [TimeBlock], excluding excludedID: String? = nil) -> Int? {
        let minutes = max(minimumBlockMinutes, minutes)
        let latest = minutesPerDay - minutes
        guard latest >= 0 else { return nil }
        let occupied = blocks.filter { $0.isCurrent && $0.id != excludedID }
        func isFree(_ candidate: Int) -> Bool {
            (0...latest).contains(candidate)
                && !occupied.contains { $0.startMinute < candidate + minutes && candidate < $0.endMinute }
        }
        let wanted = min(max(0, start), latest)
        if isFree(wanted) { return wanted }
        var candidates: Set<Int> = [0, latest]
        for block in occupied {
            candidates.insert(block.endMinute)
            candidates.insert(block.startMinute - minutes)
        }
        return candidates
            .filter(isFree)
            .min { lhs, rhs in
                let (dl, dr) = (abs(lhs - wanted), abs(rhs - wanted))
                return dl != dr ? dl < dr : lhs < rhs
            }
    }

    var isShutDown: Bool { shutdownAt != nil }

    /// How a day is named. The implementation is `PlanDate`, which the phone
    /// compiles too; these four are the names the rest of the app already uses.
    static func dateString(for date: Date, calendar: Calendar = .current) -> String {
        PlanDate.string(for: date, calendar: calendar)
    }

    static func startOfDay(_ dateString: String, calendar: Calendar = .current) -> Date? {
        PlanDate.startOfDay(dateString, calendar: calendar)
    }

    static func isValidDateString(_ dateString: String, calendar: Calendar = .current) -> Bool {
        PlanDate.isValid(dateString, calendar: calendar)
    }

    static func dateString(_ dateString: String, offsetBy days: Int, calendar: Calendar = .current) -> String? {
        PlanDate.string(dateString, offsetBy: days, calendar: calendar)
    }

    /// Minutes since local midnight for a moment on `dateString`; nil when the
    /// moment is on another day.
    static func minuteOfDay(for moment: Date, on dateString: String, calendar: Calendar = .current) -> Int? {
        guard Self.dateString(for: moment, calendar: calendar) == dateString else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: moment)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// `HH:MM` for a minute of the day. 1440 renders as `24:00`.
    static func clockString(minute: Int) -> String {
        let clamped = min(max(0, minute), minutesPerDay)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    /// Minutes for `HH:MM` (also `H:MM`, `HHMM` is not accepted). Nil when the
    /// text is not a clock time inside one day.
    static func minute(fromClock text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0...59).contains(minute) else { return nil }
        let total = hour * 60 + minute
        return total <= minutesPerDay ? total : nil
    }
}

/// What the app saw the learner doing: the kinds of activity the Planner's
/// log lane records beside the plan. Reading, listening and watching are a
/// source's own activity kinds as the Schedule ledger names them; a chat is a
/// conversation in the chat panel; a doc is a Doc being written. Off track is
/// time the learner drifted from a bout's or a calendar block's goal to an
/// app or a site outside it (`FocusWatch`); its `targetID` is that site's
/// host or that app's bundle id, and it is the one kind that is not learning.
///
/// The log stays on the Mac that saw it (`day_activities` does not sync), so a
/// new kind reaches no other device.
enum DayActivityKind: String, Codable, CaseIterable, Sendable {
    case reading
    case listening
    case watching
    case chat
    case doc
    case offTrack = "off_track"

    var displayName: String {
        switch self {
        case .reading: return "Reading"
        case .listening: return "Listening"
        case .watching: return "Watching"
        case .chat: return "Chat"
        case .doc: return "Page"
        case .offTrack: return "Off track"
        }
    }

    /// The kind of thing `DayActivity.targetID` names, as the link scheme
    /// spells it: `foreverlm://source/…`, `foreverlm://chat/…`, `foreverlm://doc/…`.
    /// Off track names an app or a site outside ForeverLM, which no link opens.
    var targetKind: String {
        switch self {
        case .reading, .listening, .watching: return "source"
        case .chat: return "chat"
        case .doc: return "doc"
        case .offTrack: return "app"
        }
    }

    /// Time spent learning, as against drifting off it.
    var isLearning: Bool { self != .offTrack }
}

/// One stretch of the clock the app saw the learner spend on one thing: a
/// paper open in the Reader, a podcast playing, a chat being had, a Doc being
/// written. The log is what actually happened, drawn beside what was planned,
/// and it links back to the thing itself.
///
/// Spans are recorded by observation, a minute at a time: an observation of
/// the same thing within `DayPlan.activityMergeGapMinutes` of a span's end
/// extends that span; a later one starts a new span. Nothing here ever changes
/// a block — a block is done when the learner says so, whatever the log shows.
struct DayActivity: Identifiable, Codable, Equatable, Sendable {
    let id: String
    /// The `DayPlan.id` (the date) this span belongs to.
    var dayPlanID: String
    /// Minutes after local midnight; `endMinute` is exclusive and at least
    /// one minute after the start.
    var startMinute: Int
    var endMinute: Int
    var kind: DayActivityKind
    /// The source, chat session or Doc id the span is about.
    var targetID: String
    /// What the thing was called when it was seen, so the log still reads
    /// after the thing is renamed or gone.
    var title: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        dayPlanID: String,
        startMinute: Int,
        endMinute: Int,
        kind: DayActivityKind,
        targetID: String,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.dayPlanID = dayPlanID
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.kind = kind
        self.targetID = targetID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, dayPlanID, startMinute, endMinute, kind, targetID, title, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        dayPlanID = try c.decode(String.self, forKey: .dayPlanID)
        startMinute = try c.decode(Int.self, forKey: .startMinute)
        endMinute = try c.decodeIfPresent(Int.self, forKey: .endMinute) ?? (startMinute + 1)
        kind = DayActivityKind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .reading
        targetID = try c.decode(String.self, forKey: .targetID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    var durationMinutes: Int { max(0, endMinute - startMinute) }

    /// Whether today's span is still going at `minute`: begun, and seen within
    /// `DayPlan.activityOngoingMinutes`. Only meaningful on today's log.
    func isOngoing(atMinute minute: Int) -> Bool {
        startMinute <= minute && endMinute >= minute - DayPlan.activityOngoingMinutes + 1
    }

    /// The link that opens the thing: the product scheme, so it reads the same
    /// in a chat, a Doc and over MCP. Nil for time off track, which was spent
    /// outside ForeverLM.
    var link: String? {
        guard kind.isLearning else { return nil }
        return "\(StudioEntityLink.productScheme)://\(kind.targetKind)/\(StudioEntityLink.encode(targetID))"
    }

    /// Whether an observation of the same thing at `minute` continues this
    /// span rather than starting another.
    func continues(atMinute minute: Int) -> Bool {
        minute >= startMinute && minute - endMinute <= DayPlan.activityMergeGapMinutes
    }

    /// Whether an observation of the same thing at `minute`, under `name`,
    /// changes nothing: the span already covers the minute and carries the
    /// name (an empty name renames nothing). `recordDayActivity` answers one
    /// with nil.
    func absorbs(minute: Int, named name: String) -> Bool {
        continues(atMinute: minute)
            && min(DayPlan.minutesPerDay, minute + 1) <= endMinute
            && (name.isEmpty || name == title)
    }

    /// The minutes something was seen at, joined into spans by the rule above:
    /// each observation is a minute of the thing, and one within
    /// `DayPlan.activityMergeGapMinutes` of a span's end extends it. What
    /// `recordDayActivity` builds a minute at a time, built at once from a
    /// record's stamps. End-exclusive, by start; a minute outside the day is
    /// dropped.
    static func observedRuns(atMinutes minutes: [Int]) -> [(start: Int, end: Int)] {
        var runs: [(start: Int, end: Int)] = []
        for minute in minutes.sorted() where (0..<DayPlan.minutesPerDay).contains(minute) {
            let end = minute + 1
            if let last = runs.last, minute - last.end <= DayPlan.activityMergeGapMinutes {
                runs[runs.count - 1].end = max(last.end, end)
            } else {
                runs.append((start: minute, end: end))
            }
        }
        return runs
    }

    func overlaps(_ other: DayActivity) -> Bool {
        startMinute < other.endMinute && other.startMinute < endMinute
    }
}

extension Notification.Name {
    /// Posted after any planner write in this process — the pane, MCP, or the
    /// storage actor — so the Planner republishes at once.
    static let dayPlansDidChange = Notification.Name("DayPlansDidChange")
    /// A meeting series' schedule was set or cleared, so the Planner should
    /// import the day again without waiting out the cooldown.
    static let meetingSchedulesDidChange = Notification.Name("MeetingSchedulesDidChange")
}

/// Lets through the first observation of a thing in each minute, and one that
/// names it anew: the log counts minutes (`recordDayActivity`), so a second
/// observation inside the same minute could only be dropped there, after a
/// trip to storage. A writer that observes often — a page saved at each pause
/// in typing — asks here first.
struct DayActivityMinuteGate {
    private var lastAdmitted: [String: (minute: String, title: String)] = [:]

    /// Whether an observation of `targetID` at `moment` under `title` can
    /// change the log; when it can, it is noted as the minute's.
    mutating func admits(_ targetID: String, title: String, at moment: Date, calendar: Calendar = .current) -> Bool {
        let date = DayPlan.dateString(for: moment, calendar: calendar)
        let minute = DayPlan.minuteOfDay(for: moment, on: date, calendar: calendar) ?? 0
        let stamp = "\(date) \(minute)"
        if let last = lastAdmitted[targetID], last.minute == stamp, last.title == title { return false }
        lastAdmitted[targetID] = (stamp, title)
        return true
    }

    /// The observation let through did not reach the log: the next one in the
    /// same minute goes through again.
    mutating func forget(_ targetID: String) {
        lastAdmitted[targetID] = nil
    }
}

/// One thing a day was spent on, as the log reads back: a paper with its
/// reading and the chats about it, a video, a chat with no single source, a
/// Doc. `kind` is what opens it — the source's own kind, `.chat` or `.doc` —
/// and `targetID` names it. Built by `DayPlanDetail.activityGroups`.
struct DayActivityGroup: Identifiable, Equatable, Sendable {
    /// `source/<id>`, `chat/<id>` or `doc/<id>`.
    let id: String
    let kind: DayActivityKind
    let targetID: String
    let title: String
    /// The stored spans, by start.
    let spans: [DayActivity]
    let minutesByKind: [DayActivityKind: Int]
    let startMinute: Int
    let endMinute: Int

    var totalMinutes: Int { minutesByKind.values.reduce(0, +) }

    /// Opened and closed, one chat turn: not worth a card.
    var isGlance: Bool { totalMinutes < DayPlan.activityGlanceMinutes }

    /// The spans joined across gaps shorter than
    /// `DayPlan.activitySittingGapMinutes`, by start. What the lane draws.
    var sittings: [DayActivitySitting] {
        var result: [DayActivitySitting] = []
        var current: [DayActivity] = []
        func close() {
            guard let first = current.first else { return }
            result.append(DayActivitySitting(
                id: "\(id)@\(first.startMinute)",
                groupID: id,
                kind: DayActivityGroup.dominantKind(DayActivityGroup.minutesByKind(current)) ?? first.kind,
                title: title,
                startMinute: first.startMinute,
                endMinute: current.map(\.endMinute).max() ?? first.endMinute,
                spans: current
            ))
            current = []
        }
        for span in spans.sorted(by: Self.byStart) {
            if let end = current.map(\.endMinute).max(), span.startMinute - end > DayPlan.activitySittingGapMinutes {
                close()
            }
            current.append(span)
        }
        close()
        return result
    }

    static func byStart(_ lhs: DayActivity, _ rhs: DayActivity) -> Bool {
        if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
        if lhs.endMinute != rhs.endMinute { return lhs.endMinute > rhs.endMinute }
        return lhs.id < rhs.id
    }

    static func minutesByKind(_ spans: [DayActivity]) -> [DayActivityKind: Int] {
        spans.reduce(into: [:]) { totals, span in
            totals[span.kind, default: 0] += span.durationMinutes
        }
    }

    /// The kind with the most minutes; a tie goes to the lane's order.
    static func dominantKind(_ minutes: [DayActivityKind: Int]) -> DayActivityKind? {
        DayActivityKind.allCases
            .filter { (minutes[$0] ?? 0) > 0 }
            .max { (minutes[$0] ?? 0) < (minutes[$1] ?? 0) }
            ?? DayActivityKind.allCases.first { minutes[$0] != nil }
    }
}

/// One card in the lane: a group's spans joined across short gaps, tinted
/// by the kind that took most of it, the logged minutes banded inside.
struct DayActivitySitting: Identifiable, Equatable, Sendable {
    let id: String
    let groupID: String
    let kind: DayActivityKind
    let title: String
    let startMinute: Int
    let endMinute: Int
    let spans: [DayActivity]

    var minutesByKind: [DayActivityKind: Int] { DayActivityGroup.minutesByKind(spans) }
    var loggedMinutes: Int { spans.reduce(0) { $0 + $1.durationMinutes } }
    var durationMinutes: Int { max(0, endMinute - startMinute) }

    static func byStart(_ lhs: DayActivitySitting, _ rhs: DayActivitySitting) -> Bool {
        if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
        if lhs.endMinute != rhs.endMinute { return lhs.endMinute > rhs.endMinute }
        return lhs.id < rhs.id
    }
}

/// Where the clock draws one sitting: inside a block, or in the free stretch
/// between blocks, and the minutes of it that fall inside that host. See
/// `DayPlanDetail.activityPlacements`.
struct DayActivityPlacement: Equatable, Sendable {
    enum Host: Equatable, Sendable {
        case block(id: String)
        case free(startMinute: Int, endMinute: Int)
    }

    let host: Host
    /// The sitting cut to its host: what the card is drawn over.
    let drawnStartMinute: Int
    let drawnEndMinute: Int

    var drawnMinutes: Int { max(0, drawnEndMinute - drawnStartMinute) }

    /// The block this sitting is drawn in, nil when it stands free.
    var blockID: String? {
        if case .block(let id) = host { return id }
        return nil
    }
}

/// A day with every row it has ever held, tombstones included. Callers read
/// the plan through `currentBlocks`.
struct DayPlanDetail: Identifiable, Equatable, Sendable {
    var plan: DayPlan
    var blocks: [TimeBlock]
    /// What the app saw the learner do that day, by start time.
    var activities: [DayActivity]
    /// The day's timed bouts, newest first. The learner's own record of the
    /// day, as against the plan (blocks) and the observation (activities).
    var bouts: [LearningBout]

    var id: String { plan.id }

    init(
        plan: DayPlan,
        blocks: [TimeBlock],
        activities: [DayActivity] = [],
        bouts: [LearningBout] = []
    ) {
        self.plan = plan
        self.blocks = blocks
        self.activities = activities
        self.bouts = bouts
    }

    /// The bout the panes draw: the most recent one still learning, owing its
    /// write-up, or resting.
    func liveBout(now: Date = Date()) -> LearningBout? {
        LearningBout.live(in: bouts, now: now)
    }

    /// The bouts of the day, newest first.
    var boutsByRecency: [LearningBout] { bouts.sorted(by: LearningBout.byRecency) }

    /// Minutes the day was actually learned in, counting every bout that is
    /// over. A bout still running counts to now, so the figure only ever rises
    /// while the learner works.
    func minutesLearned(now: Date = Date()) -> Int {
        bouts
            .filter { $0.abandonedAt == nil }
            .reduce(0) { $0 + $1.minutesLearned(now: now) }
    }

    /// Minutes the log holds for each kind of activity, kinds with none omitted.
    var loggedMinutesByKind: [DayActivityKind: Int] {
        activities.reduce(into: [:]) { totals, activity in
            totals[activity.kind, default: 0] += activity.durationMinutes
        }
    }

    /// The lane column each span is drawn in, so spans that overlap in time —
    /// a chat about the paper that is open — sit side by side instead of on
    /// top of each other. Greedy: a span takes the first column whose last
    /// span ended before it starts. A span shorter than `minimumMinutes`
    /// holds its column for that long, because the card it becomes is never
    /// drawn shorter than that: without it a three-minute span's 14-point
    /// card spilled onto the next card in its column (2026-09-10, "Jared…"
    /// under "Rutte…"). Pure, so it can be tested and mirrored.
    static func activityColumns(_ activities: [DayActivity], minimumMinutes: Int = 0) -> [String: Int] {
        activityColumns(placing: activities.map { ($0.id, $0.startMinute, $0.endMinute) }, minimumMinutes: minimumMinutes)
    }

    static func activityColumns(_ sittings: [DayActivitySitting], minimumMinutes: Int = 0) -> [String: Int] {
        activityColumns(placing: sittings.map { ($0.id, $0.startMinute, $0.endMinute) }, minimumMinutes: minimumMinutes)
    }

    static func activityColumns(placing items: [(id: String, startMinute: Int, endMinute: Int)], minimumMinutes: Int = 0) -> [String: Int] {
        activityLayout(placing: items, minimumMinutes: minimumMinutes).mapValues(\.column)
    }

    /// Where each item sits and how many columns its own cluster of
    /// overlapping items needs — so one three-way overlap at 19:00 does not
    /// squeeze a lone card at 15:00 to a third of the lane. Items whose drawn
    /// extents touch form a cluster; columns are assigned greedily within it.
    static func activityLayout(_ sittings: [DayActivitySitting], minimumMinutes: Int = 0) -> [String: (column: Int, columnCount: Int)] {
        activityLayout(placing: sittings.map { ($0.id, $0.startMinute, $0.endMinute) }, minimumMinutes: minimumMinutes)
    }

    static func activityLayout(placing items: [(id: String, startMinute: Int, endMinute: Int)], minimumMinutes: Int = 0) -> [String: (column: Int, columnCount: Int)] {
        let ordered = items.sorted { lhs, rhs in
            if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
            if lhs.endMinute != rhs.endMinute { return lhs.endMinute > rhs.endMinute }
            return lhs.id < rhs.id
        }
        var result: [String: (column: Int, columnCount: Int)] = [:]
        var columnEnds: [Int] = []
        var cluster: [String] = []
        var clusterEnd = Int.min
        func closeCluster() {
            for id in cluster { result[id]?.columnCount = columnEnds.count }
            cluster = []
            columnEnds = []
        }
        for item in ordered {
            let end = max(item.endMinute, item.startMinute + minimumMinutes)
            if item.startMinute >= clusterEnd { closeCluster() }
            clusterEnd = max(clusterEnd, end)
            if let column = columnEnds.indices.first(where: { columnEnds[$0] <= item.startMinute }) {
                columnEnds[column] = end
                result[item.id] = (column, 0)
            } else {
                columnEnds.append(end)
                result[item.id] = (columnEnds.count - 1, 0)
            }
            cluster.append(item.id)
        }
        closeCluster()
        return result
    }

    /// Where a sitting is drawn on the one-column clock. Since 2026-09-20 the
    /// log is not a lane beside the plan but is drawn inside it: a sitting
    /// sits in the block that held most of it, cut to that block's frame, or
    /// in the free stretch between blocks that held most of it, cut to that
    /// stretch — so a block with nothing inside is visibly empty and a
    /// sitting between blocks visibly unplanned, without a divider or a
    /// legend (product owner, on the two-lane screenshot: "you might propose
    /// redesigning this"). The card's own text still says the true times.
    /// Pure; mirrored by `dayActivityPlacements` on the web.
    static func activityPlacements(
        _ sittings: [DayActivitySitting],
        blocks: [TimeBlock],
        clockStartMinute: Int,
        clockEndMinute: Int
    ) -> [String: DayActivityPlacement] {
        let ordered = blocks.sorted { lhs, rhs in
            if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
            if lhs.endMinute != rhs.endMinute { return lhs.endMinute > rhs.endMinute }
            return lhs.id < rhs.id
        }
        // The free stretches: the clock with every block's minutes taken out.
        var stretches: [(start: Int, end: Int)] = []
        var cursor = clockStartMinute
        for block in ordered {
            if block.startMinute > cursor { stretches.append((cursor, block.startMinute)) }
            cursor = max(cursor, block.endMinute)
        }
        if clockEndMinute > cursor { stretches.append((cursor, clockEndMinute)) }

        func overlap(_ start: Int, _ end: Int, with sitting: DayActivitySitting) -> Int {
            max(0, min(end, sitting.endMinute) - max(start, sitting.startMinute))
        }
        var result: [String: DayActivityPlacement] = [:]
        for sitting in sittings {
            var bestBlock: (block: TimeBlock, minutes: Int)?
            for block in ordered {
                let minutes = overlap(block.startMinute, block.endMinute, with: sitting)
                if minutes > (bestBlock?.minutes ?? 0) { bestBlock = (block, minutes) }
            }
            var bestStretch: (stretch: (start: Int, end: Int), minutes: Int)?
            for stretch in stretches {
                let minutes = overlap(stretch.start, stretch.end, with: sitting)
                if minutes > (bestStretch?.minutes ?? 0) { bestStretch = (stretch, minutes) }
            }
            if let bestBlock, bestBlock.minutes >= (bestStretch?.minutes ?? 0) {
                result[sitting.id] = DayActivityPlacement(
                    host: .block(id: bestBlock.block.id),
                    drawnStartMinute: max(bestBlock.block.startMinute, sitting.startMinute),
                    drawnEndMinute: min(bestBlock.block.endMinute, sitting.endMinute)
                )
            } else if let bestStretch {
                result[sitting.id] = DayActivityPlacement(
                    host: .free(startMinute: bestStretch.stretch.start, endMinute: bestStretch.stretch.end),
                    drawnStartMinute: max(bestStretch.stretch.start, sitting.startMinute),
                    drawnEndMinute: min(bestStretch.stretch.end, sitting.endMinute)
                )
            } else {
                // Nothing overlaps a sitting with no minutes: it goes where
                // its start falls, a block first, then the stretch, then the
                // clock itself.
                let start = sitting.startMinute
                if let block = ordered.first(where: { $0.contains(minute: start) }) {
                    result[sitting.id] = DayActivityPlacement(host: .block(id: block.id), drawnStartMinute: start, drawnEndMinute: start)
                } else if let stretch = stretches.first(where: { $0.start <= start && start < $0.end }) {
                    result[sitting.id] = DayActivityPlacement(host: .free(startMinute: stretch.start, endMinute: stretch.end), drawnStartMinute: start, drawnEndMinute: start)
                } else {
                    result[sitting.id] = DayActivityPlacement(host: .free(startMinute: clockStartMinute, endMinute: clockEndMinute), drawnStartMinute: start, drawnEndMinute: start)
                }
            }
        }
        return result
    }

    /// The minutes the log holds between `start` and `end`: what a block's
    /// footer says was inside it ("55m inside"). Every span counts, whichever
    /// thing it was on and whether or not the block named it; glances
    /// included, because a minute inside is a minute inside. Pure; mirrored
    /// by `dayLoggedMinutesBetween` on the web.
    static func loggedMinutes(of groups: [DayActivityGroup], between start: Int, and end: Int) -> Int {
        groups.reduce(0) { total, group in
            total + group.spans.reduce(0) { $0 + max(0, min(end, $1.endMinute) - max(start, $1.startMinute)) }
        }
    }

    /// The log with every span's title taken from the thing it names as that
    /// thing is called now, so a paper saved under its file URL and named
    /// later reads by its name rather than the URL. `currentTitles` is keyed
    /// the way a span links — `source/<id>`, `chat/<id>`, `doc/<id>` — and a
    /// span whose thing is gone, or has no name of its own, keeps the name it
    /// was seen under, which is the whole point of storing one. Pure;
    /// mirrored by `dayActivitiesWithCurrentTitles` on the web.
    static func resolvingCurrentTitles(_ activities: [DayActivity], currentTitles: [String: String]) -> [DayActivity] {
        guard !currentTitles.isEmpty else { return activities }
        return activities.map { activity in
            let key = "\(activity.kind.targetKind)/\(activity.targetID)"
            let current = (currentTitles[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !current.isEmpty, current != activity.title else { return activity }
            var renamed = activity
            renamed.title = current
            return renamed
        }
    }

    /// The day's log read back by what it was spent on rather than span by
    /// span: one group per paper, video, chat or Doc, longest first. A chat
    /// linked to exactly one source belongs to that source (`chatSources`
    /// maps a chat id to the ids of the sources it was about); a chat about
    /// several, or none, is its own thing. Pure; mirrored by
    /// `dayActivityGroups` on the web.
    static func activityGroups(_ activities: [DayActivity], chatSources: [String: [String]] = [:]) -> [DayActivityGroup] {
        var order: [String] = []
        var spansByKey: [String: [DayActivity]] = [:]
        for activity in activities.sorted(by: DayActivityGroup.byStart) {
            let key: String
            switch activity.kind {
            case .reading, .listening, .watching:
                key = "source/\(activity.targetID)"
            case .chat:
                if let sources = chatSources[activity.targetID], sources.count == 1, let source = sources.first, !source.isEmpty {
                    key = "source/\(source)"
                } else {
                    key = "chat/\(activity.targetID)"
                }
            case .doc:
                key = "doc/\(activity.targetID)"
            case .offTrack:
                key = "app/\(activity.targetID)"
            }
            if spansByKey[key] == nil { order.append(key) }
            spansByKey[key, default: []].append(activity)
        }
        let groups = order.compactMap { key -> DayActivityGroup? in
            guard let spans = spansByKey[key], let first = spans.first else { return nil }
            let slash = key.firstIndex(of: "/") ?? key.endIndex
            let targetKind = String(key[..<slash])
            let targetID = String(key[key.index(after: slash)...])
            let minutes = DayActivityGroup.minutesByKind(spans)
            let kind: DayActivityKind
            let title: String
            switch targetKind {
            case "source":
                let sourceSpans = spans.filter { $0.kind != .chat && $0.kind != .doc }
                kind = DayActivityGroup.dominantKind(DayActivityGroup.minutesByKind(sourceSpans)) ?? .reading
                title = sourceSpans.first { !$0.title.isEmpty }?.title ?? spans.first { !$0.title.isEmpty }?.title ?? ""
            case "doc":
                kind = .doc
                title = spans.first { !$0.title.isEmpty }?.title ?? ""
            case "app":
                kind = .offTrack
                title = spans.first { !$0.title.isEmpty }?.title ?? ""
            default:
                kind = .chat
                title = spans.first { !$0.title.isEmpty }?.title ?? ""
            }
            return DayActivityGroup(
                id: key,
                kind: kind,
                targetID: targetID,
                title: title.isEmpty ? kind.displayName : title,
                spans: spans,
                minutesByKind: minutes,
                startMinute: first.startMinute,
                endMinute: spans.map(\.endMinute).max() ?? first.endMinute
            )
        }
        return groups.sorted { lhs, rhs in
            if lhs.totalMinutes != rhs.totalMinutes { return lhs.totalMinutes > rhs.totalMinutes }
            if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
            return lhs.id < rhs.id
        }
    }

    /// The lane's cards: every sitting of every group that is more than a
    /// glance, by start.
    static func activitySittings(_ groups: [DayActivityGroup]) -> [DayActivitySitting] {
        groups.filter { !$0.isGlance }.flatMap(\.sittings).sorted(by: DayActivitySitting.byStart)
    }

    /// The day's plan: its current blocks, by start time.
    var currentBlocks: [TimeBlock] {
        blocks
            .filter(\.isCurrent)
            .sorted { lhs, rhs in
                if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
                if lhs.endMinute != rhs.endMinute { return lhs.endMinute < rhs.endMinute }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Minutes of the plan marked done.
    var minutesDone: Int {
        currentBlocks
            .filter { $0.status == .done }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    /// Minutes drawn on the plan and not skipped, whatever their status.
    var minutesPlanned: Int {
        currentBlocks
            .filter { $0.status != .skipped }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    /// Current blocks that should have ended by `minute` and are still open,
    /// past the grace the planner gives a block that is merely running long.
    func overdueBlocks(atMinute minute: Int) -> [TimeBlock] {
        currentBlocks.filter { $0.isOverdue(atMinute: minute - DayPlan.overdueGraceMinutes) }
    }

    /// The current block that contains `minute`, if any.
    func block(atMinute minute: Int) -> TimeBlock? {
        currentBlocks.first { $0.contains(minute: minute) }
    }

    /// The hours the clock draws: the learner's day window (`PlannerDayHours`,
    /// six to midnight unless they set it), widened to hold every block and
    /// every span of the log, so a block drawn at five in the morning — from a
    /// chat, the other Mac, or before the window was narrowed — is never off
    /// the clock. The hours outside the window are not drawn: a day that
    /// starts at six has nothing at three to scroll past.
    func clockHourRange(dayStart: Int, dayEnd: Int) -> ClosedRange<Int> {
        Self.clockHourRange(dayStart: dayStart, dayEnd: dayEnd, blocks: currentBlocks, activities: activities)
    }

    /// `clockHourRange` for an unloaded day: the window itself, once the two
    /// ends are put in order. Static so the pane can draw before the plan has
    /// loaded and the tests can ask without a detail.
    static func clockHourRange(dayStart: Int, dayEnd: Int, blocks: [TimeBlock] = [], activities: [DayActivity] = []) -> ClosedRange<Int> {
        let window = PlannerDayHours.ordered(start: dayStart, end: dayEnd)
        var start = window.lowerBound
        var end = window.upperBound
        for block in blocks where block.isCurrent {
            start = min(start, block.startMinute / 60)
            end = max(end, Int((Double(block.endMinute) / 60).rounded(.up)))
        }
        for activity in activities {
            start = min(start, activity.startMinute / 60)
            end = max(end, Int((Double(activity.endMinute) / 60).rounded(.up)))
        }
        return max(0, start)...min(24, max(end, start + 1))
    }

    /// The hours the day opens on: the working day, widened to hold every
    /// block and every span of the log. The clock itself draws the learner's
    /// day window (`clockHourRange`); this is where it is scrolled to inside
    /// that, and the scale the log strips use.
    func focusHourRange(defaultStart: Int = 7, defaultEnd: Int = 19) -> ClosedRange<Int> {
        var start = defaultStart
        var end = defaultEnd
        for block in blocks where block.isCurrent {
            start = min(start, block.startMinute / 60)
            end = max(end, Int((Double(block.endMinute) / 60).rounded(.up)))
        }
        for activity in activities {
            start = min(start, activity.startMinute / 60)
            end = max(end, Int((Double(activity.endMinute) / 60).rounded(.up)))
        }
        return max(0, start)...min(24, max(end, start + 1))
    }
}
