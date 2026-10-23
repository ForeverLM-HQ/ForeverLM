import SwiftUI
import AppKit
import Observation

// MARK: - The directory as a table

/// One OpenRouter model as a line of the table Settings › Chat and
/// Background list the directory in.
struct ModelTableRow: Identifiable, Equatable {
    let model: OpenRouterDirectoryModel
    /// The catalog's entry when it carries the model, so the row a learner
    /// turns on is the one Suggested and the chat's picker show; else one
    /// made from the directory's row.
    let entry: AIModelCatalogEntry
    let isCatalogued: Bool
    let maker: ChatModelLists.MakerIdentity
    /// The entry's display name, worked out once: sorting asks for it often.
    let name: String
    /// Offered in the chat's picker, or the model a Background slot runs on.
    var isOn = false
    var isDefault = false
    /// Whether the model's host has usable credentials. A row without them
    /// is dimmed; turning it on walks the learner to them.
    var isConfigured = true
    var isTesting = false
    var backupRank: Int? = nil

    init(_ model: OpenRouterDirectoryModel, in lists: ChatModelLists.Built) {
        self.model = model
        let maker = lists.identity(ofSlug: model.id)
        self.maker = maker
        if let entry = lists.entryBySlug[model.id.lowercased()] {
            self.entry = entry
            isCatalogued = true
        } else {
            entry = AIModelCatalogEntry(
                maker: maker.logo ?? .other,
                provider: .openRouter,
                modelID: model.id,
                customName: model.name
            )
            isCatalogued = false
        }
        name = entry.displayName
    }

    var id: String { model.id }
    var makerName: String { maker.name }
    /// What the Price column sorts on: input and output blended as a chat
    /// runs them (`ModelCostOrder.blended`). A model with no price sorts
    /// after every priced one.
    var cost: Double {
        ModelCostOrder.blended(input: model.inputUSDPerMTokens, output: model.outputUSDPerMTokens) ?? .infinity
    }
    /// What the Context column sorts on; an unpublished window counts as none.
    var context: Int { model.contextLength ?? 0 }

    /// A router (`openrouter/free`, `openrouter/auto`) has no providers of
    /// its own to choose from.
    var offersHost: Bool { !model.id.lowercased().hasPrefix("openrouter/") }

    /// How long after OpenRouter first lists a model the table marks it New.
    static let newFor: TimeInterval = 7 * 24 * 60 * 60

    /// Whether OpenRouter first listed the model within `newFor`.
    func isListedRecently(asOf now: Date = Date()) -> Bool {
        guard let createdAt = model.createdAt else { return false }
        return now.timeIntervalSince(createdAt) < Self.newFor
    }

    /// "1 Model", "3 Models": a context menu's count.
    static func count(_ count: Int) -> String {
        count == 1 ? "1 Model" : "\(count) Models"
    }
}

/// The table's columns, by the identifier AppKit files each under.
enum ModelTableColumn: String, CaseIterable {
    case check
    case model
    case maker
    case price
    case context
    case speed
    case provider

    var title: String {
        switch self {
        case .check: ""
        case .model: "Model"
        case .maker: "Maker"
        case .price: "Price"
        case .context: "Context"
        case .speed: "Speed"
        case .provider: "Provider"
        }
    }

    /// Every column but the check narrows the table from its header.
    var isFilterable: Bool { self != .check }

    /// The columns a click on the header sorts. Speeds arrive line by line
    /// and a provider is a choice, so neither sorts.
    var sorts: Bool {
        switch self {
        case .model, .maker, .price, .context: true
        case .check, .speed, .provider: false
        }
    }
}

/// The order a header click puts the table in. Ties keep the order the
/// pane gives: maker by maker, newest first.
enum ModelTableSort {
    static func sorted(_ rows: [ModelTableRow], by column: ModelTableColumn, ascending: Bool) -> [ModelTableRow] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch column {
        case .model: return rows.sorted(using: KeyPathComparator(\ModelTableRow.name, order: order))
        case .maker: return rows.sorted(using: KeyPathComparator(\ModelTableRow.makerName, order: order))
        case .price: return rows.sorted(using: KeyPathComparator(\ModelTableRow.cost, order: order))
        case .context: return rows.sorted(using: KeyPathComparator(\ModelTableRow.context, order: order))
        case .check, .speed, .provider: return rows
        }
    }
}

// MARK: Column filters

/// What a model can do, as OpenRouter's directory lists it: part of the
/// Model column's filter.
enum ModelTableFeature: String, CaseIterable, Identifiable, Hashable {
    case readsImages
    case reasoning
    case openWeights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readsImages: return "Reads images"
        case .reasoning: return "Reasoning effort"
        case .openWeights: return "Open weights"
        }
    }

    func matches(_ model: OpenRouterDirectoryModel) -> Bool {
        switch self {
        case .readsImages: return model.supportsVision == true
        case .reasoning: return model.reasoningEfforts != nil
        case .openWeights: return model.huggingFaceID != nil
        }
    }
}

/// The Price column's filter: what a model costs per 1M tokens, blended as
/// the column sorts (`ModelCostOrder.blended`).
enum ModelTablePriceBand: String, CaseIterable, Identifiable, Hashable {
    case free
    case underOne
    case oneToFive
    case fiveToTwenty
    case twentyAndUp
    case unlisted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .underOne: "Under $1"
        case .oneToFive: "$1 to $5"
        case .fiveToTwenty: "$5 to $20"
        case .twentyAndUp: "$20 and up"
        case .unlisted: "No list price"
        }
    }

    static func of(_ model: OpenRouterDirectoryModel) -> Self {
        if model.isZeroPriced { return .free }
        guard let cost = ModelCostOrder.blended(input: model.inputUSDPerMTokens, output: model.outputUSDPerMTokens) else {
            return .unlisted
        }
        switch cost {
        case ..<1: return .underOne
        case ..<5: return .oneToFive
        case ..<20: return .fiveToTwenty
        default: return .twentyAndUp
        }
    }
}

/// The Provider column's filter.
enum ModelTableProviderChoice: String, CaseIterable, Identifiable, Hashable {
    /// OpenRouter picks who runs the model.
    case automatic
    /// The learner chose a provider, a cheapest one or a region.
    case chosen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .chosen: "Chosen provider"
        }
    }
}

/// What the column filters narrow the table to, one filter a column
/// (product owner, 2026-10-13: "each of those columns should have a filter
/// option; should be different for each column").
struct ModelTableFilters: Equatable {
    /// Model: only the models offered in the chat's picker.
    var onlyOn = false
    /// Model: only the models the table marks New.
    var onlyNew = false
    /// Model: what every listed model must do.
    var features: Set<ModelTableFeature> = []
    /// Maker: the makers listed, by name; empty for every maker.
    var makers: Set<String> = []
    /// Price: the bands listed; empty for any price.
    var prices: Set<ModelTablePriceBand> = []
    /// Context: the smallest window listed, in tokens.
    var minimumContext: Int?
    /// Speed: the slowest output listed, in tokens per second.
    var minimumSpeed: Int?
    /// Provider: Automatic or a chosen provider; nil for either.
    var provider: ModelTableProviderChoice?

    static let contextFloors = [32_000, 128_000, 256_000, 1_000_000]
    static let speedFloors = [25, 50, 100, 200]

    var isEmpty: Bool { self == ModelTableFilters() }

    func isActive(_ column: ModelTableColumn) -> Bool {
        switch column {
        case .check: false
        case .model: onlyOn || onlyNew || !features.isEmpty
        case .maker: !makers.isEmpty
        case .price: !prices.isEmpty
        case .context: minimumContext != nil
        case .speed: minimumSpeed != nil
        case .provider: provider != nil
        }
    }

    mutating func clear(_ column: ModelTableColumn) {
        switch column {
        case .check: break
        case .model:
            onlyOn = false
            onlyNew = false
            features = []
        case .maker: makers = []
        case .price: prices = []
        case .context: minimumContext = nil
        case .speed: minimumSpeed = nil
        case .provider: provider = nil
        }
    }

    /// Whether a row passes every column's filter. The rest is what the
    /// table knows of the row beyond the directory: `speed` is nil until
    /// read, and a row with no speed read does not pass a Speed filter.
    func admits(_ row: ModelTableRow, isNew: Bool, speed: Double?, hasChosenProvider: Bool) -> Bool {
        if onlyOn, !row.isOn { return false }
        if onlyNew, !isNew { return false }
        if !features.allSatisfy({ $0.matches(row.model) }) { return false }
        if !makers.isEmpty, !makers.contains(row.makerName) { return false }
        if !prices.isEmpty, !prices.contains(.of(row.model)) { return false }
        if let minimumContext, row.context < minimumContext { return false }
        if let minimumSpeed {
            guard let speed, speed >= Double(minimumSpeed) else { return false }
        }
        if let provider, (provider == .chosen) != hasChosenProvider { return false }
        return true
    }
}

/// What a Refresh of OpenRouter's directory found: the models it lists now
/// that the read before it did not.
struct ModelDirectoryRefresh: Equatable {
    let newIDs: Set<String>

    init(before: [OpenRouterDirectoryModel], after: [OpenRouterDirectoryModel]) {
        let known = Set(before.map { $0.id.lowercased() })
        newIDs = Set(after.map(\.id).filter { !known.contains($0.lowercased()) })
    }

    /// "No new models on OpenRouter.", "New on OpenRouter: A and B.", or
    /// "12 new models on OpenRouter." for the names of what it found.
    static func summary(_ names: [String]) -> String {
        switch names.count {
        case 0: return "No new models on OpenRouter."
        case 1...3: return "New on OpenRouter: \(ListFormatter.localizedString(byJoining: names))."
        default: return "\(names.count) new models on OpenRouter."
        }
    }
}

// MARK: Menus

/// One line of a menu the table draws in AppKit: its context menu, and the
/// filter menu under each header.
struct ModelTableMenuItem {
    enum Kind {
        case action(() -> Void)
        case header
        case divider
    }

    let kind: Kind
    var title = ""
    var systemImage: String? = nil
    var isOn = false
    var isEnabled = true

    static func button(
        _ title: String,
        systemImage: String? = nil,
        isOn: Bool = false,
        isEnabled: Bool = true,
        perform: @escaping () -> Void
    ) -> Self {
        Self(kind: .action(perform), title: title, systemImage: systemImage, isOn: isOn, isEnabled: isEnabled)
    }

    static func header(_ title: String) -> Self {
        Self(kind: .header, title: title)
    }

    static var divider: Self { Self(kind: .divider) }

    /// Use as Backup, or Stop Using as Backup, as `ModelBackupMenuItem`
    /// words it.
    static func backup(rank: Int?, isFull: Bool, toggle: @escaping () -> Void) -> Self {
        if rank != nil {
            return .button("Stop Using as Backup", systemImage: "minus.circle", perform: toggle)
        }
        return .button(
            isFull ? "Use as Backup (\(AIBackupModels.limit) at most)" : "Use as Backup",
            systemImage: "arrow.triangle.branch",
            isEnabled: !isFull,
            perform: toggle
        )
    }
}

@MainActor
private enum ModelTableMenus {
    /// Fills `menu` with `items`, dropping a divider that would lead, trail
    /// or follow another.
    static func fill(_ menu: NSMenu, with items: [ModelTableMenuItem]) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        var dividerWaits = false
        for item in items {
            switch item.kind {
            case .divider:
                dividerWaits = menu.numberOfItems > 0
            case .header:
                if dividerWaits { menu.addItem(.separator()) }
                dividerWaits = false
                menu.addItem(.sectionHeader(title: item.title))
            case .action(let perform):
                if dividerWaits { menu.addItem(.separator()) }
                dividerWaits = false
                let menuItem = NSMenuItem(title: item.title, action: #selector(ModelTableMenuTarget.runAction(_:)), keyEquivalent: "")
                menuItem.target = ModelTableMenuTarget.shared
                menuItem.representedObject = ModelTableMenuTarget.Action(perform)
                menuItem.state = item.isOn ? .on : .off
                menuItem.isEnabled = item.isEnabled
                menuItem.image = item.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                menu.addItem(menuItem)
            }
        }
    }
}

/// Runs a table menu item's closure. A menu item holds its target weakly,
/// so the target is one object that lives as long as the app.
private final class ModelTableMenuTarget: NSObject {
    static let shared = ModelTableMenuTarget()

    final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc func runAction(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run()
    }
}

// MARK: Speeds

/// The table's output speeds, read from OpenRouter line by line: as a line
/// scrolls into view, or for every line while the Speed column filters. A
/// few reads run at once, the latest asked first, so the lines on screen
/// fill before the rest.
@MainActor
@Observable
final class ModelTableSpeeds {
    /// Bumped as each read lands. Only a body that filters on speed reads
    /// it, so a landing redraws nothing else.
    private(set) var revision = 0

    @ObservationIgnored private var figures: [String: Double] = [:]
    @ObservationIgnored private var finished: Set<String> = []
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var waiting: [(id: String, slug: String)] = []
    @ObservationIgnored private var running = 0
    /// Told the row id of each read that lands, so its cell redraws.
    @ObservationIgnored var onRead: ((String) -> Void)?

    private static let concurrentReads = 6

    /// Tokens per second; nil until read, and for a model OpenRouter has
    /// too little traffic on to say.
    func figure(for id: String) -> Double? { figures[id] }

    func hasRead(_ id: String) -> Bool { finished.contains(id) }

    func request(_ row: ModelTableRow) {
        guard !asked.contains(row.id) else { return }
        asked.insert(row.id)
        waiting.append((row.id, ChatModelRow.speedSlug(of: row.entry)))
        pump()
    }

    func requestAll(_ rows: [ModelTableRow]) {
        // Last asked, first read: the top of the list goes in last.
        for row in rows.reversed() { request(row) }
    }

    /// Forgets every figure, so a refreshed directory reads them again.
    func reset() {
        figures = [:]
        finished = []
        asked = []
        waiting = []
        revision += 1
    }

    private func pump() {
        while running < Self.concurrentReads, let next = waiting.popLast() {
            running += 1
            Task { [weak self] in
                let figure = await Self.read(slug: next.slug)
                self?.land(next.id, figure)
            }
        }
    }

    private static func read(slug: String) async -> Double? {
        let cached = OpenRouterModelSpeedCatalog.cachedTokensPerSecond(slug: slug, speed: .standard)
        guard let speeds = try? await OpenRouterModelSpeedCatalog.shared.speeds(for: slug) else { return cached }
        return OpenRouterModelSpeed.tokensPerSecond(for: .standard, slug: slug, in: speeds)
    }

    private func land(_ id: String, _ figure: Double?) {
        running -= 1
        figures[id] = figure
        finished.insert(id)
        revision += 1
        onRead?(id)
        pump()
    }
}

// MARK: - The table

/// "All models on OpenRouter" in Settings › Chat and Background, as a table
/// (product owner, 2026-10-10: "can this maybe be a bigger table where you
/// can select stuff?", and "i need to be able to filter in that table by
/// model provider etc; and be able to sort by price"). One line per model, a
/// check that offers it in the chat's picker or picks it for the work, and
/// columns that sort on a click of their header, cheapest first until one is
/// clicked. Each header but the check's has its own filter behind a funnel
/// (2026-10-13), and the Refresh beside the title reads OpenRouter's
/// directory again, saying what it found. Rows select, several at once with
/// ⌘ or ⇧, for the context menu to act on together, and a double-click does
/// what the check does. Collapsed until opened, as the list it replaced was
/// (2026-10-06: "just a table that we can expand; pre-sorted by costs").
struct OpenRouterModelTable<Accessory: View>: View {
    /// Maker by maker, newest first: the order ties keep.
    let rows: [ModelTableRow]
    let state: ModelBrowserState
    /// "chat models": what the loading, empty and search lines name.
    let subject: String
    /// Reads OpenRouter's directory again, past its few-minute cache: the
    /// Refresh beside the title, and Retry after a failed read.
    let refresh: () -> Void
    /// What the last Refresh found; nil before one.
    let lastRefresh: ModelDirectoryRefresh?
    let purpose: ChatModelRow.Purpose
    /// The check, or a double-click, on these rows.
    let toggle: ([ModelTableRow]) -> Void
    /// Controls at the trailing end of the title line.
    @ViewBuilder let accessory: () -> Accessory
    /// The pane's own menu items for the rows a right-click took in; the
    /// table adds Choose Provider and the OpenRouter page for one row.
    let actions: ([ModelTableRow]) -> [ModelTableMenuItem]

    @Environment(\.uiZoomScale) private var uiZoomScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var isExpanded = false
    @State private var query = ""
    @State private var filters = ModelTableFilters()
    @State private var speeds = ModelTableSpeeds()
    /// Bumped when a provider is chosen, so a Provider filter reads again.
    @State private var providerRevision = 0

    var body: some View {
        let newModelIDs = self.newIDs
        let shown = isExpanded ? shownRows(newIDs: newModelIDs) : rows
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .zoomedSystemFont(size: 10, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Text("All models on OpenRouter")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if !rows.isEmpty {
                            Text(shown.count == rows.count ? "\(rows.count)" : "\(shown.count) of \(rows.count)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isExpanded ? "expanded" : "collapsed")
                if state == .loading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    refreshButton
                }
                Spacer()
                accessory()
            }
            if isExpanded {
                content(shown, newIDs: newModelIDs)
            }
        }
        .onChange(of: filters.minimumSpeed) { _, floor in
            if floor != nil { speeds.requestAll(rows) }
        }
        .onChange(of: rows.count) { _, _ in
            if filters.minimumSpeed != nil { speeds.requestAll(rows) }
        }
        .onChange(of: lastRefresh) { _, _ in
            speeds.reset()
            if filters.minimumSpeed != nil { speeds.requestAll(rows) }
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            Image(systemName: "arrow.clockwise")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0))
        .help("Read OpenRouter's models again")
        .accessibilityLabel("Refresh OpenRouter's models")
    }

    @ViewBuilder
    private func content(_ shown: [ModelTableRow], newIDs: Set<String>) -> some View {
        switch state {
        case .failed(let message):
            ModelBrowserFailure(message: message, retry: refresh)
        case .loading where rows.isEmpty:
            Text("Reading OpenRouter's \(subject)…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        default:
            if rows.isEmpty {
                Text("OpenRouter lists no \(subject) ForeverLM can use right now.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 8) {
                    ModelSearchField(text: $query, prompt: "Search \(subject)")
                    if !filters.isEmpty {
                        Button("Clear Filters") {
                            filters = ModelTableFilters()
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
                        .font(.caption.weight(.medium))
                        .fixedSize()
                    }
                }
                notes
                table(shown, newIDs: newIDs)
            }
        }
    }

    /// The Speed filter's reading, and what the last Refresh found.
    @ViewBuilder
    private var notes: some View {
        if filters.minimumSpeed != nil {
            let read = rows.reduce(0) { $0 + (speeds.hasRead($1.id) ? 1 : 0) }
            if read < rows.count {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Reading speeds, \(read) of \(rows.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let lastRefresh {
            let found = rows.filter { lastRefresh.newIDs.contains($0.id) }
            HStack(spacing: 6) {
                Text(ModelDirectoryRefresh.summary(found.map(\.name)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !found.isEmpty, !filters.onlyNew {
                    Button("Show") {
                        filters.onlyNew = true
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3))
                    .font(.caption.weight(.medium))
                }
            }
        }
    }

    private func table(_ shown: [ModelTableRow], newIDs: Set<String>) -> some View {
        ModelDirectoryTableView(
            rows: shown,
            purpose: purpose,
            newIDs: newIDs,
            activeFilters: Set(ModelTableColumn.allCases.filter(filters.isActive)),
            speeds: speeds,
            zoom: uiZoomScale,
            dynamicTypeSize: dynamicTypeSize,
            filterMenu: filterMenu,
            actions: actions,
            toggle: toggle,
            providerDidChange: { providerRevision += 1 }
        )
        // Some 18 lines at once, where the banners showed five.
        .frame(height: 460)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .overlay {
            // Over the table, not in its place: the headers hold the
            // filters that would bring the lines back.
            if shown.isEmpty {
                Text(emptyLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The rows marked New: listed by OpenRouter this past week, or found by
    /// the last Refresh.
    private var newIDs: Set<String> {
        let now = Date()
        var ids = Set(rows.lazy.filter { $0.isListedRecently(asOf: now) }.map(\.id))
        if let lastRefresh { ids.formUnion(lastRefresh.newIDs) }
        return ids
    }

    /// The rows the search and the column filters let through, in the
    /// pane's order; the table sorts them.
    private func shownRows(newIDs: Set<String>) -> [ModelTableRow] {
        let terms = ModelSearch.terms(query)
        if filters.minimumSpeed != nil {
            // Redrawn as speeds land, only while the filter needs them.
            _ = speeds.revision
        }
        let chosen = filters.provider == nil ? [] : rowsWithChosenProvider()
        return rows.filter { row in
            filters.admits(
                row,
                isNew: newIDs.contains(row.id),
                speed: speeds.figure(for: row.id),
                hasChosenProvider: chosen.contains(row.id)
            ) && ModelSearch.matches(terms: terms, fields: [row.name, row.id, row.makerName])
        }
    }

    /// The rows whose provider the learner chose for this work. Read only
    /// while the Provider column filters: one preference lookup a row.
    private func rowsWithChosenProvider() -> Set<String> {
        _ = providerRevision
        let slot = purpose.hostSlotID
        return Set(rows.filter { row in
            row.offersHost && OpenRouterHostPreference.stored(
                slot: slot,
                slug: OpenRouterModelID.slug(provider: row.entry.provider, model: row.entry.modelID)
            ) != nil
        }.map(\.id))
    }

    private var emptyLine: String {
        let query = query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return "No model matches these filters." }
        return "No model matches “\(query)”\(filters.isEmpty ? "" : " with these filters")."
    }

    // MARK: Filter menus

    /// The menu under a column's funnel: an "all" line that clears it, then
    /// that column's own choices.
    private func filterMenu(_ column: ModelTableColumn) -> [ModelTableMenuItem] {
        let isActive = filters.isActive(column)
        let clear = { (title: String) in
            ModelTableMenuItem.button(title, isOn: !isActive) { filters.clear(column) }
        }
        switch column {
        case .check:
            return []
        case .model:
            var items: [ModelTableMenuItem] = [clear("All Models"), .divider]
            if purpose.isChat {
                items.append(.button("Offered in Chat", isOn: filters.onlyOn) { filters.onlyOn.toggle() })
            }
            let newCount = newIDs.count
            items.append(.button("New (\(newCount))", isOn: filters.onlyNew, isEnabled: newCount > 0 || filters.onlyNew) {
                filters.onlyNew.toggle()
            })
            items.append(.divider)
            for feature in ModelTableFeature.allCases {
                let count = rows.reduce(0) { $0 + (feature.matches($1.model) ? 1 : 0) }
                items.append(.button("\(feature.title) (\(count))", isOn: filters.features.contains(feature)) {
                    filters.features.formSymmetricDifference([feature])
                })
            }
            return items
        case .maker:
            var countByName: [String: Int] = [:]
            for row in rows { countByName[row.makerName, default: 0] += 1 }
            // The most models first, then by name.
            let counts: [(name: String, count: Int)] = countByName
                .map { (name: $0.key, count: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            return [clear("All Makers"), .divider] + counts.map { maker -> ModelTableMenuItem in
                .button("\(maker.name) (\(maker.count))", isOn: filters.makers.contains(maker.name)) {
                    filters.makers.formSymmetricDifference([maker.name])
                }
            }
        case .price:
            let counts = Dictionary(grouping: rows) { ModelTablePriceBand.of($0.model) }.mapValues(\.count)
            return [clear("Any Price"), .header("Per 1M tokens, 3 input to 1 output")] + ModelTablePriceBand.allCases.compactMap { band -> ModelTableMenuItem? in
                guard let count = counts[band] else { return nil }
                return .button("\(band.title) (\(count))", isOn: filters.prices.contains(band)) {
                    filters.prices.formSymmetricDifference([band])
                }
            }
        case .context:
            return [clear("Any Length"), .divider] + ModelTableFilters.contextFloors.map { floor -> ModelTableMenuItem in
                let count = rows.reduce(0) { $0 + ($1.context >= floor ? 1 : 0) }
                return .button(
                    "At least \(ChatModelRow.contextLabel(tokens: floor)) (\(count))",
                    isOn: filters.minimumContext == floor
                ) {
                    filters.minimumContext = floor
                }
            }
        case .speed:
            return [clear("Any Speed"), .divider] + ModelTableFilters.speedFloors.map { floor -> ModelTableMenuItem in
                .button("At least \(floor) tok/s", isOn: filters.minimumSpeed == floor) {
                    filters.minimumSpeed = floor
                }
            }
        case .provider:
            return [clear("Any Provider"), .divider] + ModelTableProviderChoice.allCases.map { choice -> ModelTableMenuItem in
                .button(choice.title, isOn: filters.provider == choice) {
                    filters.provider = choice
                }
            }
        }
    }
}

// MARK: - The table in AppKit

/// The table itself, drawn by AppKit at a fixed row height, so scrolling
/// never measures a line. SwiftUI's `Table` sized every line it scrolled to
/// and re-measured the lines around one whose height it had guessed, which
/// held the main thread for seconds over the directory's 360-odd models
/// (2026-10-13 stall sample: `NSTableRowData
/// _automaticRowHeightsUpdateVisibleRowViews` under each scroll step). It
/// also draws the funnel in each header that `Table` has no room for.
struct ModelDirectoryTableView: NSViewRepresentable {
    /// What the filters let through, in the pane's order.
    let rows: [ModelTableRow]
    let purpose: ChatModelRow.Purpose
    let newIDs: Set<String>
    let activeFilters: Set<ModelTableColumn>
    let speeds: ModelTableSpeeds
    let zoom: CGFloat
    let dynamicTypeSize: DynamicTypeSize
    let filterMenu: (ModelTableColumn) -> [ModelTableMenuItem]
    let actions: ([ModelTableRow]) -> [ModelTableMenuItem]
    let toggle: ([ModelTableRow]) -> Void
    let providerDidChange: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private var view: ModelDirectoryTableView
        /// The rows as the table lists them: `view.rows`, sorted.
        private var lines: [ModelTableRow] = []
        private var lineIndex: [String: Int] = [:]
        private var sortColumn = ModelTableColumn.price
        private var ascending = true
        private var zoom: CGFloat
        private weak var tableView: NSTableView?
        private var popover: NSPopover?
        /// openrouter.ai's logos for makers with none bundled, by vendor.
        private var fetchedLogos: [String: NSImage] = [:]
        private var logoReads: Set<String> = []
        private var remoteObserver: NSObjectProtocol?

        private static let rowHeight: CGFloat = 24
        private static let headerHeight: CGFloat = 28
        /// Minimum and starting widths, each with room for its title, sort
        /// arrow and funnel. With the spacing they leave the Model column
        /// some 150 pt of the 660 a Settings card has, and it takes
        /// whatever a wider pane adds.
        private static let widths: [ModelTableColumn: (minimum: CGFloat, width: CGFloat)] = [
            .check: (20, 20),
            .model: (120, 150),
            .maker: (76, 92),
            .price: (72, 82),
            .context: (66, 78),
            .speed: (56, 64),
            .provider: (72, 80),
        ]

        init(_ view: ModelDirectoryTableView) {
            self.view = view
            zoom = view.zoom
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            let tableView = NSTableView()
            tableView.style = .inset
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.usesAutomaticRowHeights = false
            tableView.rowHeight = Self.rowHeight * zoom
            tableView.intercellSpacing = NSSize(width: 8, height: 0)
            tableView.allowsMultipleSelection = true
            tableView.allowsColumnReordering = false
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            let header = ModelTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: Self.headerHeight * zoom))
            header.coordinator = self
            tableView.headerView = header
            for column in ModelTableColumn.allCases {
                tableView.addTableColumn(makeColumn(column))
            }
            tableView.dataSource = self
            tableView.delegate = self
            tableView.target = self
            tableView.doubleAction = #selector(doubleClicked(_:))
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            tableView.menu = menu
            tableView.setAccessibilityIdentifier("settings.models.browser.table")
            tableView.setAccessibilityCustomActions(filterActions())
            self.tableView = tableView
            tableView.sortDescriptors = [NSSortDescriptor(key: sortColumn.rawValue, ascending: ascending)]
            applyFilterMarks()

            let scrollView = ModelTableScrollView()
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder

            view.speeds.onRead = { [weak self] id in self?.speedRead(id) }
            remoteObserver = NotificationCenter.default.addObserver(
                forName: PreferenceStore.didChangeRemotely,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.providersChanged() }
            }
            reload()
            return scrollView
        }

        private func makeColumn(_ column: ModelTableColumn) -> NSTableColumn {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            let cell = ModelTableHeaderCell(textCell: column.title)
            cell.isFilterable = column.isFilterable
            cell.baseFontSize = cell.font?.pointSize ?? 0
            tableColumn.headerCell = cell
            tableColumn.title = column.title
            if let widths = Self.widths[column] {
                tableColumn.minWidth = widths.minimum
                tableColumn.width = widths.width
            }
            switch column {
            case .check:
                tableColumn.maxWidth = tableColumn.width
                tableColumn.resizingMask = []
            case .model:
                tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            default:
                tableColumn.resizingMask = .userResizingMask
            }
            if column.sorts {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            }
            applyZoom(to: cell)
            return tableColumn
        }

        func update(_ view: ModelDirectoryTableView) {
            let previous = self.view
            self.view = view
            view.speeds.onRead = { [weak self] id in self?.speedRead(id) }
            guard let tableView else { return }
            if view.zoom != zoom {
                zoom = view.zoom
                tableView.rowHeight = Self.rowHeight * zoom
                if let header = tableView.headerView {
                    header.frame.size.height = Self.headerHeight * zoom
                }
                for column in tableView.tableColumns {
                    if let cell = column.headerCell as? ModelTableHeaderCell { applyZoom(to: cell) }
                }
                tableView.tile()
                reload()
            } else if view.rows != previous.rows
                || view.newIDs != previous.newIDs
                || view.purpose.hostSlotID != previous.purpose.hostSlotID
                || view.purpose.isChat != previous.purpose.isChat {
                reload()
            }
            if view.activeFilters != previous.activeFilters {
                applyFilterMarks()
            }
        }

        func dismantle() {
            popover?.performClose(nil)
            if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
            remoteObserver = nil
        }

        private func applyZoom(to cell: ModelTableHeaderCell) {
            guard cell.baseFontSize > 0, let font = cell.font else { return }
            cell.font = NSFont(descriptor: font.fontDescriptor, size: cell.baseFontSize * zoom) ?? font
        }

        private func applyFilterMarks() {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                guard let cell = column.headerCell as? ModelTableHeaderCell,
                      let kind = ModelTableColumn(rawValue: column.identifier.rawValue) else { continue }
                cell.isFilterActive = view.activeFilters.contains(kind)
            }
            tableView.headerView?.needsDisplay = true
        }

        /// Lists `view.rows` in the header's order, keeping the selection
        /// on the same models and the scroll where it was.
        private func reload() {
            guard let tableView else { return }
            let selected = Set(tableView.selectedRowIndexes.compactMap { $0 < lines.count ? lines[$0].id : nil })
            lines = ModelTableSort.sorted(view.rows, by: sortColumn, ascending: ascending)
            lineIndex = Dictionary(lines.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            tableView.reloadData()
            let kept = IndexSet(lines.indices.filter { selected.contains(lines[$0].id) })
            tableView.selectRowIndexes(kept, byExtendingSelection: false)
        }

        private func columnIndex(_ column: ModelTableColumn) -> Int? {
            guard let tableView else { return nil }
            let index = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
            return index >= 0 ? index : nil
        }

        /// Redraws one column on the lines on screen.
        private func redraw(_ column: ModelTableColumn, rows: IndexSet? = nil) {
            guard let tableView, let index = columnIndex(column) else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            var indexes = IndexSet(integersIn: visible.location..<(visible.location + visible.length))
            if let rows { indexes.formIntersection(rows) }
            guard !indexes.isEmpty else { return }
            tableView.reloadData(forRowIndexes: indexes, columnIndexes: [index])
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            lines.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard let tableColumn, index < lines.count,
                  let column = ModelTableColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let row = lines[index]
            switch column {
            case .check:
                let isChat = view.purpose.isChat
                let cell = reusable(tableView, isChat ? "check.chat" : "check.pick") { ModelTableCheckCell(isChat: isChat) }
                cell.configure(row, zoom: zoom) { [weak self] in self?.view.toggle([row]) }
                return cell
            case .model:
                let cell = reusable(tableView, "model") { ModelTableModelCell() }
                let marks = ChatModelRow.marks(
                    isDefault: row.isDefault,
                    isRecommended: row.entry.provider == .openRouter && FreeModelsSetup.isRecommended(row.entry.modelID),
                    promotion: row.model.promotion?.label,
                    backupRank: row.backupRank
                )
                let isNew = view.newIDs.contains(row.id)
                let help = ([row.model.id] + (isNew ? ["New"] : []) + (marks.map { [$0] } ?? [])).joined(separator: " · ")
                cell.configure(name: row.name, marks: marks, isNew: isNew, dimmed: !row.isConfigured, help: help, zoom: zoom)
                return cell
            case .maker:
                let cell = reusable(tableView, "maker") { ModelTableMakerCell() }
                let logo = logo(for: row.maker)
                cell.configure(name: row.makerName, logo: logo.image, tint: logo.tint, rounded: logo.rounded, zoom: zoom)
                return cell
            case .price:
                let cell = reusable(tableView, "text") { ModelTableTextCell() }
                if let input = row.model.inputUSDPerMTokens, let output = row.model.outputUSDPerMTokens {
                    let pair = AIModelListPrice.pairLabel(input: input, output: output)
                    let was = row.model.promotion?.listPriceLabel(effectiveInput: input, effectiveOutput: output)
                        .map { ", down from \($0)" } ?? ""
                    cell.configure(row.model.isZeroPriced ? "Free" : pair, color: .labelColor, zoom: zoom, help: "\(pair) input/output per 1M tokens\(was)")
                } else {
                    cell.configure("—", color: .tertiaryLabelColor, zoom: zoom, help: "No published list price")
                }
                return cell
            case .context:
                let cell = reusable(tableView, "text") { ModelTableTextCell() }
                if let tokens = row.model.contextLength {
                    let label = ChatModelRow.contextLabel(tokens: tokens)
                    cell.configure(label, color: .secondaryLabelColor, zoom: zoom, help: "\(label) token context window")
                } else {
                    cell.configure("—", color: .tertiaryLabelColor, zoom: zoom, help: "Context window not published")
                }
                return cell
            case .speed:
                let cell = reusable(tableView, "text") { ModelTableTextCell() }
                if let figure = view.speeds.figure(for: row.id) {
                    cell.configure(OpenRouterModelSpeed.label(tokensPerSecond: figure), color: .secondaryLabelColor, zoom: zoom, help: OpenRouterModelSpeed.explanation)
                } else {
                    cell.configure("—", color: .tertiaryLabelColor, zoom: zoom, help: OpenRouterModelSpeed.explanation)
                    view.speeds.request(row)
                }
                return cell
            case .provider:
                guard row.offersHost else { return nil }
                let cell = reusable(tableView, "provider") { ModelTableProviderCell() }
                let slug = OpenRouterModelID.slug(provider: row.entry.provider, model: row.entry.modelID)
                let chosen = OpenRouterHostPreference.stored(slot: view.purpose.hostSlotID, slug: slug)?.label
                cell.configure(title: chosen ?? "Automatic", isChosen: chosen != nil, modelName: row.name, zoom: zoom) { [weak self] in
                    self?.showProvider(for: row.id)
                }
                return cell
            }
        }

        private func reusable<Cell: NSView>(_ tableView: NSTableView, _ identifier: String, make: () -> Cell) -> Cell {
            let id = NSUserInterfaceItemIdentifier(identifier)
            if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? Cell { return cell }
            let cell = make()
            cell.identifier = id
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let column = ModelTableColumn(rawValue: key) else { return }
            sortColumn = column
            ascending = descriptor.ascending
            reload()
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard tableColumn?.identifier.rawValue == ModelTableColumn.model.rawValue, row < lines.count else { return nil }
            return lines[row].name
        }

        // MARK: Actions

        /// The clicked line, with the rest of the selection when it is part
        /// of it.
        private func rows(around clicked: Int) -> [ModelTableRow] {
            guard let tableView, clicked >= 0, clicked < lines.count else { return [] }
            let indexes = tableView.selectedRowIndexes.contains(clicked) ? tableView.selectedRowIndexes : IndexSet(integer: clicked)
            return indexes.compactMap { $0 < lines.count ? lines[$0] : nil }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let picked = rows(around: sender.clickedRow)
            if !picked.isEmpty { view.toggle(picked) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView else { return }
            let picked = rows(around: tableView.clickedRow)
            guard !picked.isEmpty else {
                menu.removeAllItems()
                return
            }
            var items = view.actions(picked)
            if picked.count == 1, let row = picked.first {
                items.append(.divider)
                if row.offersHost {
                    items.append(.button("Choose Provider…", systemImage: "server.rack") { [weak self] in
                        self?.showProvider(for: row.id)
                    })
                }
                if let url = OpenRouterModelPage.url(slug: row.model.id) {
                    items.append(.button("About \(row.name) on OpenRouter", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(url)
                    })
                }
            }
            ModelTableMenus.fill(menu, with: items)
        }

        /// The menu under a column's funnel; nil for the check's column.
        func filterMenu(forColumnAt index: Int) -> NSMenu? {
            guard let tableView, index >= 0, index < tableView.tableColumns.count,
                  let column = ModelTableColumn(rawValue: tableView.tableColumns[index].identifier.rawValue),
                  column.isFilterable else { return nil }
            let menu = NSMenu()
            ModelTableMenus.fill(menu, with: view.filterMenu(column))
            return menu
        }

        /// Each funnel, for VoiceOver, which cannot reach a header's glyph.
        private func filterActions() -> [NSAccessibilityCustomAction] {
            ModelTableColumn.allCases.filter(\.isFilterable).map { column in
                NSAccessibilityCustomAction(name: "Filter by \(column.title)") { [weak self] in
                    guard let self, let index = self.columnIndex(column),
                          let header = self.tableView?.headerView as? ModelTableHeaderView else { return false }
                    header.showFilterMenu(at: index)
                    return true
                }
            }
        }

        /// The provider panel for a line, under its Provider cell.
        private func showProvider(for id: String) {
            guard let tableView, let index = lineIndex[id], let column = columnIndex(.provider) else { return }
            let row = lines[index]
            popover?.performClose(nil)
            tableView.scrollRowToVisible(index)
            let panel = ModelHostPanel(
                slotID: view.purpose.hostSlotID,
                provider: row.entry.provider,
                model: row.entry.modelID,
                onHostChange: { [weak self] in self?.providersChanged() }
            )
            .frame(width: 560)
            .padding(16)
            .environment(\.uiZoomScale, zoom)
            .dynamicTypeSize(view.dynamicTypeSize)
            let controller = NSHostingController(rootView: panel)
            controller.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            // Anchored to the table, not the cell, which a redraw may reuse.
            popover.show(relativeTo: tableView.frameOfCell(atColumn: column, row: index), of: tableView, preferredEdge: .maxY)
            self.popover = popover
        }

        private func providersChanged() {
            redraw(.provider)
            view.providerDidChange()
        }

        private func speedRead(_ id: String) {
            guard let index = lineIndex[id] else { return }
            redraw(.speed, rows: IndexSet(integer: index))
        }

        // MARK: Logos

        private struct Logo {
            let image: NSImage?
            /// The tint of a symbol standing in for a logo; nil for a logo.
            let tint: NSColor?
            let rounded: Bool
        }

        private func logo(for maker: ChatModelLists.MakerIdentity) -> Logo {
            if let bundled = maker.logo {
                if let image = Self.bundledLogo(bundled) {
                    return Logo(image: image, tint: nil, rounded: false)
                }
                return Self.symbol(bundled.systemImageFallback)
            }
            if let fetched = fetchedLogos[maker.vendor] {
                return Logo(image: fetched, tint: nil, rounded: true)
            }
            let vendor = maker.vendor
            if !logoReads.contains(vendor) {
                logoReads.insert(vendor)
                Task { [weak self] in
                    guard let data = await OpenRouterMakerIcon.data(forMaker: vendor),
                          let image = NSImage(data: data) else { return }
                    self?.logoArrived(image, vendor: vendor)
                }
            }
            return Self.symbol("sparkles")
        }

        private func logoArrived(_ image: NSImage, vendor: String) {
            fetchedLogos[vendor] = image
            redraw(.maker)
        }

        private static var bundledLogos: [AIModelMaker: NSImage] = [:]

        /// The asset catalog's logo, drawn in its own colours as `MakerLogo`
        /// draws it.
        private static func bundledLogo(_ maker: AIModelMaker) -> NSImage? {
            if let known = bundledLogos[maker] { return known }
            guard let image = (NSImage(named: maker.iconName)?.copy() as? NSImage) else { return nil }
            image.isTemplate = false
            bundledLogos[maker] = image
            return image
        }

        private static func symbol(_ name: String) -> Logo {
            Logo(image: NSImage(systemSymbolName: name, accessibilityDescription: nil), tint: .secondaryLabelColor, rounded: false)
        }
    }
}

// MARK: Header

/// The table's header: a click on a column's funnel opens its filter menu, a
/// right-click anywhere on the column does too, and a click elsewhere sorts.
private final class ModelTableHeaderView: NSTableHeaderView {
    weak var coordinator: ModelDirectoryTableView.Coordinator?
    private var hoveredColumn: Int?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    private func filterColumn(at point: NSPoint) -> Int? {
        let index = column(at: point)
        guard let tableView, index >= 0, index < tableView.tableColumns.count,
              let cell = tableView.tableColumns[index].headerCell as? ModelTableHeaderCell,
              cell.isFilterable,
              !cell.stringValue.isEmpty,
              cell.filterRect(forBounds: headerRect(ofColumn: index)).insetBy(dx: -3, dy: -3).contains(point) else { return nil }
        return index
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHovered(filterColumn(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
    }

    private func setHovered(_ index: Int?) {
        guard index != hoveredColumn, let tableView else { return }
        for (offset, column) in tableView.tableColumns.enumerated() {
            (column.headerCell as? ModelTableHeaderCell)?.isFilterHovered = offset == index
        }
        hoveredColumn = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if let index = filterColumn(at: convert(event.locationInWindow, from: nil)) {
            showFilterMenu(at: index)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.filterMenu(forColumnAt: column(at: convert(event.locationInWindow, from: nil)))
    }

    func showFilterMenu(at index: Int) {
        guard let menu = coordinator?.filterMenu(forColumnAt: index) else { return }
        let rect = headerRect(ofColumn: index)
        let origin = NSPoint(x: rect.minX + 2, y: isFlipped ? rect.maxY + 2 : rect.minY - 2)
        menu.popUp(positioning: nil, at: origin, in: self)
        setHovered(nil)
    }
}

/// A header cell with room for a funnel at its trailing end: outlined while
/// the column lists everything, filled in the accent colour while it filters.
private final class ModelTableHeaderCell: NSTableHeaderCell {
    var isFilterable = false
    var isFilterActive = false
    var isFilterHovered = false
    /// The font size before the app's zoom. AppKit copies a cell with
    /// `NSCopyObject`, which duplicates stored properties without retaining
    /// them, so a cell keeps only plain values here, never an object.
    var baseFontSize: CGFloat = 0
    /// Set while AppKit lays out the title in the narrowed frame, which
    /// already leaves the funnel its room.
    private var drawsTitle = false

    private static let side: CGFloat = 16
    private static let trailing: CGFloat = 3

    /// AppKit paints the header's empty ends with untitled copies of a
    /// column's cell; only a column's own cell carries its funnel.
    private var showsFilter: Bool { isFilterable && !stringValue.isEmpty }

    func filterRect(forBounds rect: NSRect) -> NSRect {
        NSRect(
            x: rect.maxX - Self.side - Self.trailing,
            y: rect.midY - Self.side / 2,
            width: Self.side,
            height: Self.side
        )
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard showsFilter else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        var titleFrame = cellFrame
        titleFrame.size.width = max(0, titleFrame.width - Self.side - Self.trailing)
        drawsTitle = true
        super.drawInterior(withFrame: titleFrame, in: controlView)
        drawsTitle = false
        drawFilter(in: filterRect(forBounds: cellFrame))
    }

    /// The sort arrow sits just before the funnel. The title, laid out in
    /// the narrowed frame, already ends there.
    override func sortIndicatorRect(forBounds rect: NSRect) -> NSRect {
        var indicator = super.sortIndicatorRect(forBounds: rect)
        if showsFilter, !drawsTitle { indicator.origin.x -= Self.side + Self.trailing }
        return indicator
    }

    private func drawFilter(in rect: NSRect) {
        if isFilterHovered {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4).fill()
        }
        let name = isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        // The filled symbol's lines are its first layer, the disc its second.
        let colors: [NSColor] = isFilterActive ? [.white, .controlAccentColor] : [.secondaryLabelColor]
        let configuration = NSImage.SymbolConfiguration(pointSize: (font?.pointSize ?? 11) + 1, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let frame = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// The table's scroll view, which keeps the columns inside its width: an
/// `NSTableView` sizes itself to the columns it was given until told to fit.
private final class ModelTableScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let tableView = documentView as? NSTableView,
              abs(tableView.frame.width - contentView.bounds.width) > 0.5 else { return }
        tableView.sizeToFit()
    }
}

private extension NSTextField {
    /// One line that ends in an ellipsis rather than wrapping.
    func singleLine() {
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.truncatesLastVisibleLine = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

private extension NSParagraphStyle {
    static let truncatingTail: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
}

// MARK: Cells

/// A borderless button that washes under the pointer, as `.hoverWash` does
/// in SwiftUI.
private final class ModelTableHoverButton: NSButton {
    var padding: CGFloat = 0
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var hoverArea: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += padding * 2
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered, isEnabled {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            let radius = min(bounds.height / 2, 6)
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        super.draw(dirtyRect)
    }
}

/// The check: a box where the chat offers several models, a single pick's
/// circle where Background runs on one, a spinner while a test runs.
private final class ModelTableCheckCell: NSTableCellView {
    private let isChat: Bool
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let pickButton = ModelTableHoverButton()
    private let spinner = NSProgressIndicator()
    private var isOn = false
    private var onToggle: (() -> Void)?

    init(isChat: Bool) {
        self.isChat = isChat
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        pickButton.isBordered = false
        pickButton.imagePosition = .imageOnly
        let control: NSButton = isChat ? checkbox : pickButton
        control.target = self
        control.action = #selector(pressed)
        for subview in [control, spinner] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
            NSLayoutConstraint.activate([
                subview.centerXAnchor.constraint(equalTo: centerXAnchor),
                subview.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ row: ModelTableRow, zoom: CGFloat, toggle: @escaping () -> Void) {
        onToggle = toggle
        isOn = row.isOn
        let control: NSButton = isChat ? checkbox : pickButton
        control.isHidden = row.isTesting
        if row.isTesting {
            spinner.startAnimation(nil)
            spinner.toolTip = "Testing \(row.name) before \(isChat ? "offering" : "using") it"
        } else {
            spinner.stopAnimation(nil)
        }
        if isChat {
            checkbox.state = row.isOn ? .on : .off
            // The Default Model cannot be turned off.
            checkbox.isEnabled = !row.isDefault
            checkbox.toolTip = row.isOn ? "Offered in the chat's model picker" : "Offer \(row.name) in the chat's model picker"
            checkbox.setAccessibilityLabel("Offer \(row.name) in the chat model picker")
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13 * zoom, weight: .regular)
            pickButton.image = NSImage(systemSymbolName: row.isOn ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            pickButton.contentTintColor = row.isOn ? .controlAccentColor : .tertiaryLabelColor
            pickButton.toolTip = row.isOn ? "This work runs on \(row.name)" : "Run this work on \(row.name)"
            pickButton.setAccessibilityLabel("Use \(row.name)")
            pickButton.setAccessibilityValue(row.isOn ? "selected" : nil)
        }
    }

    @objc private func pressed() {
        // The box shows what the pane stores, never the click itself: a
        // pick that runs a test first, or is refused, must not look done.
        checkbox.state = isOn ? .on : .off
        onToggle?()
    }
}

/// A model's name with its marks after it in small grey type; the marks
/// make way when the name needs the room, and stay in the tooltip.
private final class ModelTableModelCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var name = ""
    private var marks: String?
    private var isNew = false
    private var zoom: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.singleLine()
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(name: String, marks: String?, isNew: Bool, dimmed: Bool, help: String, zoom: CGFloat) {
        self.name = name
        self.marks = marks
        self.isNew = isNew
        self.zoom = zoom
        // The label sizes its line by its own font, whatever the string says.
        label.font = .systemFont(ofSize: 13 * zoom)
        alphaValue = dimmed ? 0.55 : 1
        toolTip = help
        render()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    override func layout() {
        super.layout()
        render()
    }

    private func render() {
        let emphasized = backgroundStyle == .emphasized
        let selected = NSColor.alternateSelectedControlTextColor
        let line = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13 * zoom),
            .foregroundColor: emphasized ? selected : NSColor.labelColor,
            .paragraphStyle: NSParagraphStyle.truncatingTail,
        ])
        let bare = NSAttributedString(attributedString: line)
        var tail: [(String, NSFont, NSColor)] = []
        if isNew {
            tail.append(("New", .systemFont(ofSize: 10 * zoom, weight: .semibold), emphasized ? selected : .controlAccentColor))
        }
        if let marks {
            tail.append((marks, .systemFont(ofSize: 10 * zoom), emphasized ? selected : .secondaryLabelColor))
        }
        for (text, font, color) in tail {
            line.append(NSAttributedString(string: "  " + text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: NSParagraphStyle.truncatingTail,
            ]))
        }
        let chosen = tail.isEmpty || line.size().width <= bounds.width - 2 ? line : bare
        if !label.attributedStringValue.isEqual(to: chosen) {
            label.attributedStringValue = chosen
        }
    }
}

/// The maker's logo and name.
private final class ModelTableMakerCell: NSTableCellView {
    private let logo = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var logoWidth: NSLayoutConstraint?
    private var logoHeight: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.wantsLayer = true
        logo.layer?.masksToBounds = true
        label.singleLine()
        label.textColor = .secondaryLabelColor
        for subview in [logo, label] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        textField = label
        imageView = logo
        let width = logo.widthAnchor.constraint(equalToConstant: 14)
        let height = logo.heightAnchor.constraint(equalToConstant: 14)
        logoWidth = width
        logoHeight = height
        NSLayoutConstraint.activate([
            width,
            height,
            logo.leadingAnchor.constraint(equalTo: leadingAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(name: String, logo image: NSImage?, tint: NSColor?, rounded: Bool, zoom: CGFloat) {
        label.stringValue = name
        label.font = .systemFont(ofSize: 13 * zoom)
        logo.image = image
        logo.contentTintColor = tint
        logo.layer?.cornerRadius = rounded ? 3 : 0
        logoWidth?.constant = 14 * zoom
        logoHeight?.constant = 14 * zoom
    }
}

/// One line of text: a price, a context window, a speed.
private final class ModelTableTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.singleLine()
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ text: String, color: NSColor, zoom: CGFloat, help: String) {
        label.stringValue = text
        label.textColor = color
        label.font = .systemFont(ofSize: 13 * zoom)
        toolTip = help
    }
}

/// Who runs the model: "Automatic" while OpenRouter picks, else the choice,
/// opening the provider panel on a click.
private final class ModelTableProviderCell: NSTableCellView {
    private let button = ModelTableHoverButton()
    private var title = ""
    private var isChosen = false
    private var zoom: CGFloat = 1
    private var onPress: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.padding = 3
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.wraps = false
        button.imagePosition = .imageTrailing
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(pressed)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -3),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, isChosen: Bool, modelName: String, zoom: CGFloat, press: @escaping () -> Void) {
        self.title = title
        self.isChosen = isChosen
        self.zoom = zoom
        onPress = press
        button.toolTip = "Choose which provider runs \(modelName)"
        button.setAccessibilityLabel("Provider for \(modelName)")
        button.setAccessibilityValue(title)
        render()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    private func render() {
        let color: NSColor = backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor
            : isChosen ? .labelColor : .secondaryLabelColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10 * zoom),
            .foregroundColor: color,
            .paragraphStyle: NSParagraphStyle.truncatingTail,
        ])
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8 * zoom, weight: .semibold))
        button.contentTintColor = color
        button.invalidateIntrinsicContentSize()
    }

    @objc private func pressed() {
        onPress?()
    }
}
