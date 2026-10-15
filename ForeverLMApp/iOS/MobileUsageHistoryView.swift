import SwiftUI

/// Last complete server-ledger snapshot for immediate, offline-safe rendering.
/// Stored as a blob inside the versioned mobile `knowledge.db`, never as a JSON
/// file or as an alternate billing truth. A successful refresh always replaces
/// it atomically; the proxy remains authoritative.
struct MobileUsageHistorySnapshot: Codable, Sendable {
    let events: [ManagedAI.UsageLedgerEvent]
    let updatedAt: Date
}

/// What ran: every AI request the managed proxy has recorded for this account,
/// grouped by day, then by task and model. It shows tasks and request counts,
/// never dollars: spend is OpenRouter's monitor, linked at the top (product
/// owner, 2026-10-15: "we shouldn't maintain our own spend stuff"). Realtime
/// voice (until 2026-10-01) ran per reply; a day of those rows reads as one
/// line with a reply count rather than dozens of tiny rows.
struct MobileUsageHistoryView: View {
    private enum Phase {
        case loading
        case loaded(LoadedUsage)
        case failed(String)
    }

    private struct LoadedUsage {
        let events: [ManagedAI.UsageLedgerEvent]
        let updatedAt: Date
    }

    private struct Filters: Equatable {
        var platform: String?
        var task: String?
        var model: String?

        var activeCount: Int {
            [platform, task, model].compactMap { $0 }.count
        }
    }

    struct Day: Identifiable {
        /// Start of day — stable across reloads, unlike a synthesized UUID.
        let id: Date
        let label: String
        let requestCount: Int
        let lines: [Line]
    }

    struct Line: Identifiable {
        // Synthesized identity: two lines can render identically (a
        // pre-attribution row with no platform next to an iOS one of the same
        // task) and must still be distinct to ForEach.
        let id = UUID()
        let title: String
        let detail: String
        let requestCount: Int
    }

    @State private var phase: Phase = .loading
    @State private var filters = Filters()
    @State private var refreshError: String?

    var body: some View {
        Group {
            switch phase {
            case .loading:
                loadingList
            case .failed(let message):
                // Unlike the home screen's balance label, silence is wrong
                // here: the user opened this screen to see the numbers, so a
                // failure must say so and offer another try.
                ContentUnavailableView {
                    Label("Couldn't Load Usage", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        phase = .loading
                        refreshError = nil
                        Task { await load() }
                    }
                }
            case .loaded(let usage):
                list(usage)
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
        }
        .task { await load() }
    }

    private func list(_ usage: LoadedUsage) -> some View {
        let visibleEvents = Self.filtered(usage.events, by: filters)
        let days = Self.days(of: visibleEvents, now: Date())
        return List {
            if let refreshError {
                Section {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Showing saved usage", systemImage: "arrow.clockwise.circle")
                    }
                    .foregroundStyle(.orange)
                } footer: {
                    Text("Last updated \(usage.updatedAt.formatted(date: .abbreviated, time: .shortened)). \(refreshError)")
                }
            }

            Section {
                Link(destination: ManagedAI.openRouterActivityURL) {
                    LabeledContent("Spend") {
                        Text("Open OpenRouter")
                    }
                }
                .accessibilityIdentifier("usage.openRouter")
            } footer: {
                Text("What your key has cost, by model and day, is in OpenRouter.")
            }

            if days.isEmpty {
                Section {
                    Text("Nothing has run yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(days) { day in
                Section {
                    ForEach(day.lines) { line in
                        LabeledContent {
                            Text(line.requestCount.formatted())
                                .monospacedDigit()
                        } label: {
                            Text(line.title)
                            Text(line.detail)
                        }
                        .accessibilityIdentifier("usage.line")
                    }
                } header: {
                    HStack {
                        Text(day.label)
                        Spacer()
                        Text(day.requestCount.formatted())
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refresh() }
    }

    private var loadingList: some View {
        List {
            Section {
                LabeledContent("Spend") { Text("Open OpenRouter") }
            }
            Section("Recent") {
                ForEach(0..<3, id: \.self) { _ in
                    LabeledContent("Managed AI") { Text("0") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading usage")
        .accessibilityIdentifier("usage.loadingPlaceholder")
    }

    @ViewBuilder
    private var filterMenu: some View {
        let facets = filterFacets
        Menu {
            facetMenu(
                title: "Platform",
                values: facets.platforms,
                selection: filters.platform
            ) { filters.platform = $0 }
            facetMenu(
                title: "Task",
                values: facets.tasks,
                selection: filters.task,
                display: Self.taskLabel
            ) { filters.task = $0 }
            facetMenu(
                title: "Model",
                values: facets.models,
                selection: filters.model
            ) { filters.model = $0 }

            if filters.activeCount > 0 {
                Divider()
                Button("Clear Filters") {
                    filters = Filters()
                }
            }
        } label: {
            Image(systemName: filters.activeCount > 0
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .disabled(facets.platforms.isEmpty && facets.tasks.isEmpty && facets.models.isEmpty)
        .accessibilityLabel(filters.activeCount == 0 ? "Filter usage" : "Usage filters, \(filters.activeCount) active")
    }

    private func facetMenu(
        title: String,
        values: [String],
        selection: String?,
        display: @escaping (String) -> String = { $0 },
        select: @escaping (String?) -> Void
    ) -> some View {
        Menu(title) {
            Button {
                select(nil)
            } label: {
                if selection == nil {
                    Label("All \(title.lowercased())s", systemImage: "checkmark")
                } else {
                    Text("All \(title.lowercased())s")
                }
            }

            ForEach(values, id: \.self) { value in
                Button {
                    select(value)
                } label: {
                    if selection == value {
                        Label(display(value), systemImage: "checkmark")
                    } else {
                        Text(display(value))
                    }
                }
            }
        }
        .disabled(values.isEmpty)
    }

    private var filterFacets: (platforms: [String], tasks: [String], models: [String]) {
        guard case .loaded(let usage) = phase else { return ([], [], []) }
        return (
            Set(usage.events.compactMap(\.clientPlatform)).sorted(),
            Set(usage.events.compactMap(\.task)).sorted { Self.taskLabel($0) < Self.taskLabel($1) },
            Set(usage.events.map(\.model)).sorted()
        )
    }

    private func load() async {
        if let cached = await MobileCloudSourceCatalog.shared.loadUsageHistorySnapshot() {
            phase = .loaded(LoadedUsage(
                events: cached.events,
                updatedAt: cached.updatedAt
            ))
        }
        await refresh()
    }

    private func refresh() async {
        let hadLoadedUsage: Bool
        if case .loaded = phase {
            hadLoadedUsage = true
        } else {
            hadLoadedUsage = false
        }
        do {
            // The events endpoint pages forward from a cursor (it exists for
            // the Mac's ledger reconciliation), so completeness means walking
            // it to the end — there is no "latest first" to stop early on.
            var events: [ManagedAI.UsageLedgerEvent] = []
            var cursor: Int64 = 0
            while true {
                let page = try await ManagedAI.usageEvents(after: cursor)
                events.append(contentsOf: page.events)
                // A cursor that stops advancing would loop forever; treat it
                // as the end rather than trusting `hasMore` unconditionally.
                guard page.hasMore, page.nextAfterID > cursor else { break }
                cursor = page.nextAfterID
            }
            let loaded = LoadedUsage(
                events: events,
                updatedAt: Date()
            )
            phase = .loaded(loaded)
            refreshError = nil
            do {
                try await MobileCloudSourceCatalog.shared.saveUsageHistorySnapshot(
                    MobileUsageHistorySnapshot(
                        events: loaded.events,
                        updatedAt: loaded.updatedAt
                    )
                )
            } catch {
                refreshError = "Couldn’t save this snapshot for offline loading: \(error.localizedDescription)"
            }
        } catch is CancellationError {
            return
        } catch {
            if hadLoadedUsage {
                refreshError = error.localizedDescription
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Grouping

    private static func filtered(
        _ events: [ManagedAI.UsageLedgerEvent],
        by filters: Filters
    ) -> [ManagedAI.UsageLedgerEvent] {
        events.filter { event in
            (filters.platform == nil || event.clientPlatform == filters.platform)
                && (filters.task == nil || event.task == filters.task)
                && (filters.model == nil || event.model == filters.model)
        }
    }

    static func days(of events: [ManagedAI.UsageLedgerEvent], now: Date) -> [Day] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: events) {
            calendar.startOfDay(for: Date(timeIntervalSince1970: $0.createdAtUnix))
        }
        return byDay.keys.sorted(by: >).map { day in
            let rows = byDay[day] ?? []
            return Day(
                id: day,
                label: label(for: day, now: now, calendar: calendar),
                requestCount: rows.count,
                lines: lines(for: rows)
            )
        }
    }

    /// One line per (task, model, platform) within a day. A voice session
    /// runs per reply, so without this fold a single conversation would fill
    /// the screen with rows too small to mean anything.
    private static func lines(for events: [ManagedAI.UsageLedgerEvent]) -> [Line] {
        struct Key: Hashable {
            let task: String?
            let model: String
            let platform: String?
        }
        let grouped = Dictionary(grouping: events) {
            Key(task: $0.task, model: $0.model, platform: $0.clientPlatform)
        }
        return grouped
            .map { key, rows -> Line in
                let title = key.task.map(taskLabel) ?? key.model
                let noun = key.model.contains("realtime")
                    ? (rows.count == 1 ? "reply" : "replies")
                    : (rows.count == 1 ? "request" : "requests")
                var parts = [String]()
                if title != key.model { parts.append(key.model) }
                parts.append("\(rows.count.formatted()) \(noun)")
                // Only foreign platforms get named: this ledger is shared with
                // the Mac and the watch, and a Mac row that looked local would
                // misattribute work the phone never did.
                if let platform = key.platform, platform != "iOS" {
                    parts.append(platform)
                }
                return Line(
                    title: title,
                    detail: parts.joined(separator: " · "),
                    requestCount: rows.count
                )
            }
            .sorted { lhs, rhs in
                if lhs.requestCount != rhs.requestCount { return lhs.requestCount > rhs.requestCount }
                return lhs.title < rhs.title
            }
    }

    private static func taskLabel(_ task: String) -> String {
        AIUsageTaskLabel.text(for: task)
    }

    private static func label(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            return day.formatted(.dateTime.month(.abbreviated).day())
        }
        return day.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
