import Combine
import SwiftUI

/// History as time: what the app watched the learner do, day by day, laid out
/// as the stretches of the clock it happened in.
///
/// It reads the day's log (`day_activities`) — the minute-by-minute record the
/// Activity pane draws — and not the per-day ledger it used to list. The ledger
/// (`source_activity_days`) says a source was *touched* on a day, and too many
/// things touch a source: a memory review created at 07:00 with thirty
/// candidates attached stamped all thirty "Reviewed" (product owner, 2026-09-22: "it
/// says ... a bunch of stuff has been reviewed already at 7 a.m., but that's
/// not true at all"). The log only holds what was seen happening, a minute at
/// a time: a source open in the Reader while the app is in front, audio
/// playing, a chat turn, a Doc being saved. So every row here has a start, an
/// end and the minutes behind it, and nothing claims more than that.
///
/// The ledger survives in one place: time it holds for a source the log has no
/// minute of that day, which is reading on the phone (the log is written on
/// the Mac) or a completion logged by hand. That is listed under the day
/// without clock times, and only when it carries real evidence — a minute of
/// measured time or a finish — never a bare "opened", "discussed" or
/// "reviewed" stamp.
enum ActivityHistory {

    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case read = "Read"
        case listened = "Listened"
        case watched = "Watched"
        case chats = "Chats"

        var id: String { rawValue }

        fileprivate func admits(_ parts: Set<Part>) -> Bool {
            switch self {
            case .all: return true
            case .read: return parts.contains(.read)
            case .listened: return parts.contains(.listened)
            case .watched: return parts.contains(.watched)
            case .chats: return parts.contains(.chat) || parts.contains(.review)
            }
        }
    }

    /// What a stretch of minutes was spent doing, worded for History. A chat
    /// in the day's memory review is a review; any other chat is a chat.
    enum Part: String, CaseIterable, Sendable {
        case read, listened, watched, chat, review, wrote

        var label: String {
            switch self {
            case .read: return "Read"
            case .listened: return "Listened"
            case .watched: return "Watched"
            case .chat: return "Chat"
            case .review: return "Review"
            case .wrote: return "Wrote"
            }
        }

        /// Nil for time off track: History is what the learner took in.
        static func of(_ span: DayActivity) -> Part? {
            switch span.kind {
            case .reading: return .read
            case .listening: return .listened
            case .watching: return .watched
            case .doc: return .wrote
            case .chat: return ActivityHistory.isMemoryReview(span.targetID) ? .review : .chat
            case .offTrack: return nil
            }
        }
    }

    /// One stretch of the clock given to one thing: a sitting, in the
    /// Activity pane's sense — its spans joined across gaps under half an hour.
    struct Block: Identifiable, Equatable, Sendable {
        let id: String
        /// What opens it: the source's own kind, `.chat` or `.doc`.
        let kind: DayActivityKind
        let targetID: String
        let title: String
        let startMinute: Int
        let endMinute: Int
        /// Minutes actually logged, by part. Less than the span from start to
        /// end whenever the sitting joined across a gap.
        let minutes: [Part: Int]

        var loggedMinutes: Int { minutes.values.reduce(0, +) }

        /// The parts with minutes, in reading order.
        var orderedParts: [(part: Part, minutes: Int)] {
            Part.allCases.compactMap { part in
                guard let value = minutes[part], value > 0 else { return nil }
                return (part, value)
            }
        }
    }

    /// Time the ledger holds for a source that has no minute on the day's
    /// clock: the phone's reading, or a finish logged by hand.
    struct Untimed: Identifiable, Equatable, Sendable {
        let id: String
        let sourceID: String
        let title: String?
        let part: Part
        let engagedMinutes: Int
        let isFinished: Bool
    }

    struct Day: Identifiable, Equatable, Sendable {
        /// The `DayPlan` id, `YYYY-MM-DD`.
        let id: String
        let date: Date
        /// Sittings of two minutes or more, by start.
        let blocks: [Block]
        /// Things the day spent under two minutes on, by start.
        let glances: [Block]
        let untimed: [Untimed]
        /// Minutes of the day with anything logged in them. Reading with a
        /// chat open beside it is one minute, not two.
        let loggedMinutes: Int

        var isEmpty: Bool { blocks.isEmpty && glances.isEmpty && untimed.isEmpty }
    }

    /// A ledger row counts only with this much measured time, or a finish.
    /// The Reader books its first thirty seconds on a dwell, which alone is a
    /// glance and not a sitting.
    static let untimedFloorSeconds: Double = 60

    static func isMemoryReview(_ sessionID: String) -> Bool {
        MemoryReviewSession.isMemorySession(sessionID) || sessionID.hasPrefix("mcp-memory-review-")
    }

    /// The filters other than All that would keep something of `days`, in
    /// the menu's order. History offers its filter menu only when this holds
    /// two or more: a month of reading alone has nothing to filter. Pure.
    static func filters(in days: [Day]) -> [Filter] {
        var parts = Set<Part>()
        for day in days {
            for block in day.blocks + day.glances { parts.formUnion(block.minutes.keys) }
            parts.formUnion(day.untimed.map(\.part))
        }
        return Filter.allCases.filter { $0 != .all && $0.admits(parts) }
    }

    /// The days, newest first, each holding only what `filter` admits; a day
    /// left with nothing is dropped.
    ///
    /// `chatSources` maps a chat id to the sources it was about, so a chat
    /// about exactly one source is part of that source's sitting — the paper
    /// and the conversation about it are one thing — as the Activity pane reads it.
    /// `currentTitles` is keyed `source/<id>`, `chat/<id>`, `doc/<id>`.
    static func days(
        details: [DayPlanDetail],
        ledger: [SourceConsumptionEntry],
        chatSources: [String: [String]] = [:],
        currentTitles: [String: String] = [:],
        filter: Filter = .all,
        calendar: Calendar = .current
    ) -> [Day] {
        var activitiesByDay: [String: [DayActivity]] = [:]
        // Time off track is the Activity pane's; History is what was taken in.
        for detail in details {
            let learning = detail.activities.filter(\.kind.isLearning)
            guard !learning.isEmpty else { continue }
            activitiesByDay[detail.id, default: []].append(contentsOf: learning)
        }
        var ledgerByDay: [String: [SourceConsumptionEntry]] = [:]
        for entry in ledger {
            ledgerByDay[DayPlan.dateString(for: entry.dayStart, calendar: calendar), default: []].append(entry)
        }

        let dayIDs = Set(activitiesByDay.keys).union(ledgerByDay.keys)
        return dayIDs.sorted(by: >).compactMap { dayID -> Day? in
            guard let date = DayPlan.startOfDay(dayID, calendar: calendar) else { return nil }
            let activities = DayPlanDetail.resolvingCurrentTitles(
                activitiesByDay[dayID] ?? [],
                currentTitles: currentTitles
            )
            let groups = DayPlanDetail.activityGroups(activities, chatSources: chatSources)

            var blocks: [Block] = []
            var glances: [Block] = []
            var shownSpans: [DayActivity] = []
            for group in groups {
                let title = displayTitle(for: group)
                if group.isGlance {
                    let block = makeBlock(
                        id: group.id, kind: group.kind, targetID: group.targetID, title: title,
                        startMinute: group.startMinute, endMinute: group.endMinute, spans: group.spans
                    )
                    if filter.admits(Set(block.minutes.keys)) {
                        glances.append(block)
                        shownSpans += group.spans
                    }
                    continue
                }
                for sitting in group.sittings {
                    let block = makeBlock(
                        id: sitting.id, kind: group.kind, targetID: group.targetID, title: title,
                        startMinute: sitting.startMinute, endMinute: sitting.endMinute, spans: sitting.spans
                    )
                    if filter.admits(Set(block.minutes.keys)) {
                        blocks.append(block)
                        shownSpans += sitting.spans
                    }
                }
            }

            let clockedSources = Set(
                activities
                    .filter { $0.kind == .reading || $0.kind == .listening || $0.kind == .watching }
                    .map(\.targetID)
            )
            let untimed = (ledgerByDay[dayID] ?? [])
                .compactMap { untimedEntry(for: $0, clockedSources: clockedSources) }
                .filter { filter.admits([$0.part]) }
                .sorted { ($0.title ?? "") < ($1.title ?? "") }

            let day = Day(
                id: dayID,
                date: date,
                blocks: blocks.sorted(by: byStart),
                glances: glances.sorted(by: byStart),
                untimed: untimed,
                loggedMinutes: coveredMinutes(shownSpans)
            )
            return day.isEmpty ? nil : day
        }
    }

    private static func makeBlock(
        id: String,
        kind: DayActivityKind,
        targetID: String,
        title: String,
        startMinute: Int,
        endMinute: Int,
        spans: [DayActivity]
    ) -> Block {
        let minutes = spans.reduce(into: [Part: Int]()) { totals, span in
            guard let part = Part.of(span) else { return }
            totals[part, default: 0] += span.durationMinutes
        }
        return Block(
            id: id, kind: kind, targetID: targetID, title: title,
            startMinute: startMinute, endMinute: endMinute, minutes: minutes
        )
    }

    /// The day's memory review chat is titled by its date alone, which says
    /// nothing in a list of days.
    private static func displayTitle(for group: DayActivityGroup) -> String {
        if group.kind == .chat, isMemoryReview(group.targetID) { return "Memory review" }
        return group.title
    }

    private static func untimedEntry(
        for entry: SourceConsumptionEntry,
        clockedSources: Set<String>
    ) -> Untimed? {
        guard !clockedSources.contains(entry.sourceID) else { return nil }
        let consumption: [(SourceActivityKind, Part)] = [(.reading, .read), (.listening, .listened), (.watching, .watched)]
        let finished = consumption.first { entry.completedKinds.contains($0.0) }
        guard let (_, part) = finished ?? consumption.first(where: { entry.kinds.contains($0.0) }) else {
            return nil
        }
        guard finished != nil || entry.engagedSeconds >= untimedFloorSeconds else { return nil }
        return Untimed(
            id: entry.id,
            sourceID: entry.sourceID,
            title: entry.title,
            part: part,
            engagedMinutes: Int((entry.engagedSeconds / 60).rounded()),
            isFinished: finished != nil
        )
    }

    private static func coveredMinutes(_ spans: [DayActivity]) -> Int {
        var covered = Set<Int>()
        for span in spans where span.endMinute > span.startMinute {
            covered.formUnion(span.startMinute..<span.endMinute)
        }
        return covered.count
    }

    private static func byStart(_ lhs: Block, _ rhs: Block) -> Bool {
        if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
        if lhs.endMinute != rhs.endMinute { return lhs.endMinute > rhs.endMinute }
        return lhs.id < rhs.id
    }

    static func durationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }
}

/// Activity › History: every day's time spent, a month at a time. Lived in
/// Settings until 2026-09-24; it is a log, not a setting, so it is the
/// Activity pane's third layout now.
struct ActivityHistoryListView: View {
    @Environment(StudioViewModel.self) private var vm

    /// Days read per page. The log is a few dozen spans a day, so a month is
    /// cheap; "Show earlier" reaches back another month at a time.
    private static let pageDays = 30

    @State private var details: [DayPlanDetail] = []
    @State private var ledger: [SourceConsumptionEntry] = []
    @State private var daysBack = Self.pageDays
    @State private var filter: ActivityHistory.Filter = .all
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

    /// Every day loaded, and the ones `filter` keeps.
    private var listing: (all: [ActivityHistory.Day], shown: [ActivityHistory.Day]) {
        let activities = details.flatMap(\.activities)
        let chatSources = chatSources(for: activities)
        let currentTitles = currentTitles(for: activities)
        let all = ActivityHistory.days(
            details: details,
            ledger: ledger,
            chatSources: chatSources,
            currentTitles: currentTitles
        )
        guard filter != .all else { return (all, all) }
        let shown = ActivityHistory.days(
            details: details,
            ledger: ledger,
            chatSources: chatSources,
            currentTitles: currentTitles,
            filter: filter
        )
        return (all, shown)
    }

    /// Where each source's row says it is from, and which glyph it wears.
    private var sourceFacts: [String: SourceConsumptionEntry] {
        ledger.reduce(into: [:]) { facts, entry in
            if facts[entry.sourceID] == nil { facts[entry.sourceID] = entry }
        }
    }

    var body: some View {
        let listing = self.listing
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // A small menu, and only while the days hold more than one
                // kind to tell apart (or a filter is on, so it can be taken
                // off): a segmented control of five until 2026-10-06.
                if filter != .all || ActivityHistory.filters(in: listing.all).count > 1 {
                    filterMenu(ActivityHistory.filters(in: listing.all))
                }

                content(listing.shown)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            guard !hasLoadedOnce else { return }
            await load()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .dayPlansDidChange)
                .receive(on: RunLoop.main)
                .debounce(for: .seconds(5), scheduler: RunLoop.main)
        ) { _ in
            Task { await load() }
        }
    }

    /// All ▾, with the kinds the days hold.
    private func filterMenu(_ offered: [ActivityHistory.Filter]) -> some View {
        Menu {
            ForEach([ActivityHistory.Filter.all] + offered) { option in
                Button {
                    filter = option
                } label: {
                    if option == filter {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(filter.rawValue)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverHighlight()
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show only one kind of time")
        .accessibilityLabel("Show")
        .accessibilityValue(filter.rawValue)
        .accessibilityIdentifier("studio.activity.history.filter")
    }

    @ViewBuilder
    private func content(_ days: [ActivityHistory.Day]) -> some View {
        if let loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load your history.")
                    .font(.headline)
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
            .padding(.leading, 4)
        } else if isLoading && !hasLoadedOnce {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
        } else if days.isEmpty {
            Text(
                filter == .all
                    ? "Nothing logged in the last \(daysBack) days."
                    : "Nothing under \u{201C}\(filter.rawValue)\u{201D} in the last \(daysBack) days."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            showEarlierButton
        } else {
            // Lazy for the reason the old pane found the hard way: an eager
            // stack of a month of rows is walked on every accessibility focus
            // update, which beachballed the window it sat in.
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(days) { day in
                    HistoryDaySection(day: day, sourceFacts: sourceFacts, articles: vm.articlesById)
                }
            }

            showEarlierButton
        }
    }

    private var showEarlierButton: some View {
        Button("Show earlier") {
            daysBack += Self.pageDays
            Task { await load() }
        }
        .buttonStyle(.link)
        .padding(.leading, 4)
        .disabled(isLoading)
    }

    /// The sources each chat was about, from the chat records, so a chat
    /// about one paper sits with that paper.
    private func chatSources(for activities: [DayActivity]) -> [String: [String]] {
        let chatIDs = Set(activities.filter { $0.kind == .chat }.map(\.targetID))
        guard !chatIDs.isEmpty else { return [:] }
        var result: [String: [String]] = [:]
        for session in vm.reviewSessionLinks where chatIDs.contains(session.id) {
            result[session.id] = session.sourceIDs
        }
        return result
    }

    private func currentTitles(for activities: [DayActivity]) -> [String: String] {
        var titles: [String: String] = [:]
        let articles = vm.articlesById
        let chats = Dictionary(vm.reviewSessionLinks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let docs = Dictionary(vm.artifacts.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for activity in activities {
            let key = "\(activity.kind.targetKind)/\(activity.targetID)"
            guard titles[key] == nil else { continue }
            switch activity.kind {
            case .reading, .listening, .watching:
                if let article = articles[activity.targetID] { titles[key] = vm.displayTitle(for: article) }
            case .chat:
                if let title = chats[activity.targetID] { titles[key] = title }
            case .doc:
                if let title = docs[activity.targetID] { titles[key] = title }
            case .offTrack:
                break
            }
        }
        return titles
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        let today = DayPlan.dateString(for: Date())
        guard let from = DayPlan.dateString(today, offsetBy: -(daysBack - 1)),
              let since = DayPlan.startOfDay(from) else { return }
        do {
            let storage = StorageService()
            details = try await storage.loadDayPlans(from: from, to: today)
            ledger = try await storage.loadSourceConsumptionHistory(limit: 5_000, since: since)
            loadError = nil
        } catch {
            details = []
            ledger = []
            loadError = error.localizedDescription
        }
    }
}

/// One day: its time blocks in the order they happened, the glances folded
/// under them, and any time the clock has no minutes for.
private struct HistoryDaySection: View {
    let day: ActivityHistory.Day
    let sourceFacts: [String: SourceConsumptionEntry]
    let articles: [String: StudioArticle]

    @State private var showsGlances = false

    private var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day.date) { return "Today" }
        if calendar.isDateInYesterday(day.date) { return "Yesterday" }
        return day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    /// What the times are, on the day's total rather than under every list
    /// (a footnote under History until 2026-10-06).
    private static let clockExplanation = "Times are what ForeverLM saw on this Mac: a source open in the Reader while the app is in front, audio playing, a chat turn, a Page being saved. Opening something and leaving within two minutes is a glance. Being material for a memory review, or cited in a chat, is not time spent."

    /// The day's heading, then its rows grouped under it with no card
    /// around them (a Settings card each until 2026-10-06).
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(dayLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if day.loggedMinutes > 0 {
                    Text("· \(ActivityHistory.durationText(day.loggedMinutes)) on the clock")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .textSelection(.disabled)
                        .help(Self.clockExplanation)
                }
            }

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(day.blocks.enumerated()), id: \.element.id) { index, block in
                    if index > 0 { Divider().padding(.vertical, 6) }
                    HistoryBlockRow(block: block, day: day.date, subtitle: subtitle(for: block), glyph: glyph(for: block))
                }

                if !day.glances.isEmpty {
                    if !day.blocks.isEmpty { Divider().padding(.vertical, 6) }
                    DisclosureGroup(isExpanded: $showsGlances) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(day.glances) { glance in
                                HistoryBlockRow(block: glance, day: day.date, subtitle: nil, glyph: glyph(for: glance), compact: true)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(day.glances.count == 1 ? "1 glance under 2 minutes" : "\(day.glances.count) glances under 2 minutes")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                if !day.untimed.isEmpty {
                    if !day.blocks.isEmpty || !day.glances.isEmpty { Divider().padding(.vertical, 6) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No clock times")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                            .help("Read on another device, or logged by hand")
                        ForEach(day.untimed) { entry in
                            HistoryUntimedRow(entry: entry, glyph: glyph(forSource: entry.sourceID, fallback: entry.part))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func subtitle(for block: ActivityHistory.Block) -> String? {
        switch block.kind {
        case .reading, .listening, .watching:
            let facts = sourceFacts[block.targetID]
            var parts: [String] = []
            if let group = facts?.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
                parts.append(group)
            } else if let domain = facts?.domain?.trimmingCharacters(in: .whitespacesAndNewlines), !domain.isEmpty {
                parts.append(domain)
            }
            if facts?.isArchived == true { parts.append("Archived") }
            if facts == nil, articles[block.targetID] == nil { parts.append("No longer in your library") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .chat:
            return ActivityHistory.isMemoryReview(block.targetID) ? nil : "Chat"
        case .doc:
            return "Page"
        case .offTrack:
            return nil
        }
    }

    private func glyph(for block: ActivityHistory.Block) -> String {
        switch block.kind {
        case .chat:
            return ActivityHistory.isMemoryReview(block.targetID) ? "brain.head.profile" : "bubble.left.and.bubble.right"
        case .doc:
            return "doc.plaintext"
        case .offTrack:
            return DayActivityKind.offTrack.systemImage
        case .reading, .listening, .watching:
            return glyph(forSource: block.targetID, fallback: nil)
        }
    }

    private func glyph(forSource sourceID: String, fallback: ActivityHistory.Part?) -> String {
        let type = sourceFacts[sourceID]?.sourceType ?? articles[sourceID]?.sourceType.rawValue
        switch type {
        case "podcast": return "waveform"
        case "video": return "play.rectangle"
        case "book": return "book"
        case "paper": return "doc.richtext"
        case .some: return "doc.text"
        case .none:
            switch fallback {
            case .listened: return "waveform"
            case .watched: return "play.rectangle"
            default: return "doc.text"
            }
        }
    }
}

/// One time block: when, what, and the minutes behind it.
private struct HistoryBlockRow: View {
    let block: ActivityHistory.Block
    let day: Date
    let subtitle: String?
    let glyph: String
    var compact = false

    private var timeRange: String {
        let start = Self.clock(block.startMinute, on: day)
        let end = Self.clock(block.endMinute, on: day)
        return start == end ? start : "\(start)–\(end)"
    }

    private static func clock(_ minute: Int, on day: Date) -> String {
        let moment = day.addingTimeInterval(TimeInterval(minute * 60))
        return moment.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timeRange)
                .font(.system(size: compact ? 11 : 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            Image(systemName: glyph)
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(block.title)
                    .font(.system(size: compact ? 12 : 13))
                    .lineLimit(2)
                if let subtitle, !compact {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 4) {
                ForEach(block.orderedParts, id: \.part) { entry in
                    HistoryChip(text: "\(entry.part.label) \(ActivityHistory.durationText(entry.minutes))")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryUntimedRow: View {
    let entry: ActivityHistory.Untimed
    let glyph: String

    private var label: String {
        if entry.engagedMinutes > 0 {
            let time = "\(entry.part.label) \(ActivityHistory.durationText(entry.engagedMinutes))"
            return entry.isFinished ? "\(time), finished" : time
        }
        return "\(entry.part.label), finished"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 96, alignment: .leading)
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(entry.title ?? "Source no longer in your library")
                .font(.system(size: 12))
                .foregroundStyle(entry.title == nil ? .secondary : .primary)
                .lineLimit(2)
            Spacer(minLength: 12)
            HistoryChip(text: label)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .fixedSize()
    }
}
