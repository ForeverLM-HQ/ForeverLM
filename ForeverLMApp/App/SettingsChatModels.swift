import SwiftUI
import AppKit

// MARK: - Settings › Chat

/// Settings › Chat, as the product owner redrew it on 2026-09-28 ("let's just do a
/// basically list with banners"): a Suggested list with one model per maker
/// (`AIModelDefaults.suggestedChatModels`), a Free list (the free models Free
/// mode itself would offer), the backups, and under them OpenRouter's whole
/// directory, one maker at a time, picked from a row of the makers' logos,
/// every maker's free or discounted models at once, or whatever a search
/// finds (`OpenRouterModelBrowser`). The list of the other
/// models the learner offered went the same day ("why is that even there?"):
/// the browser shows each of them under its maker. Every row turns
/// the model on or off in the chat's model picker; its context menu sets the
/// Default Model and the backups a scheduled task's run moves to, and its
/// provider button chooses who runs it. It replaced the maker-by-maker card
/// grid; Settings › Background draws the same list (`BackgroundModelsPane`).
struct ChatModelsPane: View {
    /// Walks the learner to the key or sign-in when a model's host has no
    /// credentials yet; nil where that pane is hidden.
    let onRequestAPIKey: (() -> Void)?

    // Empty until `reload()` lands: every value reaches `KeychainService`,
    // which is not work for a view initializer.
    @State private var snapshot = ChatModelsSnapshot.empty
    /// OpenRouter's directory; nil until the first read answers.
    @State private var directory: [OpenRouterDirectoryModel]?
    @State private var isLoadingDirectory = false
    @State private var directoryLoadError: String?
    @State private var lists = ChatModelLists.Built.empty
    /// Narrows the browser to free or discounted models, across every maker
    /// until one is picked.
    @State private var browserFilters: Set<ModelBrowserFilter> = []
    /// "provider|model" of the row whose test run is under way.
    @State private var testingKey: String?
    @State private var pickRefusal: String?

    private static let role = AIModelQualification.Role.chat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 18) {
                    if !lists.suggestions.isEmpty {
                        listSection("Suggested") {
                            ForEach(lists.suggestions) { suggestion in
                                suggestionRow(suggestion)
                            }
                        }
                    }
                    if !lists.free.isEmpty {
                        listSection("Free", caption: snapshot.freeModelBlocker) {
                            ForEach(lists.free) { suggestion in
                                suggestionRow(suggestion)
                            }
                        }
                    }
                    if !snapshot.backups.isEmpty {
                        backupsSummary
                    }
                }
            }
            SettingsCard {
                browser
            }
        }
        .onAppear {
            AIModelPriceRefresher.refreshIfStale()
        }
        .task {
            await reload()
        }
        .task {
            await loadDirectory()
        }
        .onChange(of: browserFilters) { _, _ in
            rebuild()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .aiProviderDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            // A model turned on or off here or elsewhere, a key added, Free
            // mode or the Data & Privacy switch flipped: all land here.
            Task { await reload() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            Task { await reload() }
        }
        // A refused pick is said where the learner is looking: the row they
        // pressed may be far down the maker's list.
        .alert(
            "Not selected",
            isPresented: Binding(
                get: { pickRefusal != nil },
                set: { if !$0 { pickRefusal = nil } }
            )
        ) {
            Button("OK", role: .cancel) { pickRefusal = nil }
        } message: {
            Text(pickRefusal ?? "")
        }
    }

    // MARK: Loading

    private func reload() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            ChatModelsSnapshot.load()
        }.value
        snapshot = loaded
        rebuild()
    }

    @MainActor
    private func loadDirectory() async {
        guard !isLoadingDirectory else { return }
        isLoadingDirectory = true
        directoryLoadError = nil
        defer { isLoadingDirectory = false }
        do {
            directory = try await OpenRouterCatalogAvailability.shared.models()
            rebuild()
        } catch {
            directoryLoadError = error.localizedDescription
        }
    }

    /// Recomputes the lists from the loaded catalog and directory, only when
    /// one of them changed: the directory holds some 450 rows.
    private func rebuild() {
        lists = ChatModelLists.build(
            suggested: AIModelDefaults.suggestedChatModels,
            free: Self.freeSlugs(in: directory),
            entries: snapshot.entries,
            enabledIDs: snapshot.enabledIDs,
            directory: directory,
            filters: browserFilters,
            isOffered: { AIModelCatalog.wouldOffer(provider: .openRouter, modelID: $0) }
        )
    }

    // MARK: Lists

    /// Free mode's own chat picks: its router and the single free models it
    /// adds beside it, less any that failed a test run of chat. Its preferred
    /// models stand in, waiting, until the directory answers.
    private static func freeSlugs(in directory: [OpenRouterDirectoryModel]?) -> [String] {
        let count = FreeModelsSetup.chatAlternatives + 1
        guard let directory else { return Array(FreeModelsSetup.preferredChat.prefix(count)) }
        return FreeModelsSetup.rankedFreeForChat(from: directory)
            .filter { FreeModelsSetup.storedQualification($0.id, .chat) }
            .prefix(count)
            .map(\.id)
    }

    /// `caption` says why the rows cannot be used yet, when they cannot.
    private func listSection<Rows: View>(
        _ title: String,
        caption: String? = nil,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                rows()
            }
        }
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: ChatModelLists.Suggestion) -> some View {
        switch suggestion {
        case .catalog(let entry, _):
            catalogRow(entry, showsMaker: true)
        case .directory(let model):
            directoryRow(model, showsMaker: true)
        case .pending(let slug):
            let maker = lists.identity(ofSlug: slug)
            ChatModelRow(
                entry: AIModelCatalogEntry(maker: maker.logo ?? .other, provider: .openRouter, modelID: slug),
                maker: maker,
                showsMaker: true,
                isOffered: false,
                isDefault: false,
                isConfigured: true,
                isPending: true,
                action: {}
            )
        }
    }

    /// A catalogued model: the row turns it on or off in the chat's picker.
    private func catalogRow(_ entry: AIModelCatalogEntry, showsMaker: Bool) -> some View {
        let slug = ChatModelLists.slug(of: entry)
        let offered = snapshot.enabledIDs.contains(entry.id)
        let isDefault = snapshot.defaultID == entry.id
        return ChatModelRow(
            entry: entry,
            maker: lists.identity(ofSlug: slug),
            showsMaker: showsMaker,
            isOffered: offered,
            isDefault: isDefault,
            isConfigured: snapshot.configuredProviders.contains(entry.provider),
            directoryModel: lists.directoryBySlug[slug],
            isTesting: testingKey == Self.testingKey(entry.provider, entry.modelID),
            backupRank: backupRank(provider: entry.provider, model: entry.modelID),
            backupsAreFull: snapshot.backups.count >= AIBackupModels.limit,
            toggleBackup: isDefault ? nil : {
                toggleBackup(provider: entry.provider, model: entry.modelID, name: entry.displayName)
            },
            setAsDefault: {
                testThen(entry.provider, entry.modelID, name: entry.displayName) { setAsDefault(entry) }
            },
            action: {
                // Turning a model off needs no test.
                if offered {
                    setOffered(false, entry)
                } else {
                    testThen(entry.provider, entry.modelID, name: entry.displayName) { setOffered(true, entry) }
                }
            }
        )
    }

    /// A directory model the catalog does not carry yet: turning it on adds
    /// it, after which it is a catalogued row like any other.
    private func directoryRow(_ model: OpenRouterDirectoryModel, showsMaker: Bool) -> some View {
        let maker = lists.identity(ofSlug: model.id)
        return ChatModelRow(
            entry: AIModelCatalogEntry(
                maker: maker.logo ?? .other,
                provider: .openRouter,
                modelID: model.id,
                customName: model.name
            ),
            maker: maker,
            showsMaker: showsMaker,
            isOffered: false,
            isDefault: false,
            isConfigured: snapshot.configuredProviders.contains(.openRouter),
            directoryModel: model,
            isTesting: testingKey == Self.testingKey(.openRouter, model.id),
            backupRank: backupRank(provider: .openRouter, model: model.id),
            backupsAreFull: snapshot.backups.count >= AIBackupModels.limit,
            toggleBackup: {
                toggleBackup(provider: .openRouter, model: model.id, name: model.name, directoryModel: model)
            },
            action: {
                testThen(.openRouter, model.id, name: model.name) { add(model) }
            }
        )
    }

    // MARK: Browser

    /// OpenRouter's directory, one maker at a time, with a search
    /// (`OpenRouterModelBrowser`): every maker it lists, by logo, and under
    /// the one picked all of its models, newest first. With Free or
    /// Discounted on, only those count, and until a maker is picked every
    /// maker's are listed at once.
    private var browser: some View {
        OpenRouterModelBrowser(
            makers: lists.makers.map { ModelBrowserMaker(id: $0.id, identity: $0.identity, models: $0.models) },
            state: browserState,
            subject: ModelBrowserFilter.subject("chat models", filters: browserFilters),
            retry: { Task { await loadDirectory() } },
            listsEveryMaker: !browserFilters.isEmpty,
            cost: { ModelCostOrder.blended(input: $0.inputUSDPerMTokens, output: $0.outputUSDPerMTokens) },
            searchFields: { [$0.name, $0.id] },
            accessory: {
                if directory != nil {
                    ModelBrowserFilterChips(filters: $browserFilters, counts: lists.filterCounts)
                }
            },
            row: { model, showsMaker in
                browserRow(model, showsMaker: showsMaker)
            }
        )
    }

    private var browserState: ModelBrowserState {
        if let directoryLoadError { return .failed(directoryLoadError) }
        return directory == nil || isLoadingDirectory ? .loading : .loaded
    }

    /// A catalogued model keeps its catalog identity, so the row a learner
    /// turns on here is the one Suggested and the chat's picker show. Rows
    /// from every maker at once name their maker.
    @ViewBuilder
    private func browserRow(_ model: OpenRouterDirectoryModel, showsMaker: Bool) -> some View {
        if let entry = lists.entryBySlug[model.id.lowercased()] {
            catalogRow(entry, showsMaker: showsMaker)
        } else {
            directoryRow(model, showsMaker: showsMaker)
        }
    }

    // MARK: Choices

    private func setOffered(_ enabled: Bool, _ entry: AIModelCatalogEntry) {
        AIModelCatalog.setEnabled(enabled, for: entry)
        // Read back the normalized set: the default cannot be turned off, so
        // the row must never briefly say it was.
        snapshot.enabledIDs = AIModelCatalog.enabledIDs
        if enabled, !snapshot.configuredProviders.contains(entry.provider) {
            onRequestAPIKey?()
        }
    }

    private func add(_ model: OpenRouterDirectoryModel) {
        AIModelCatalog.addCustomOpenRouterModel(FreeModelsSetup.customModel(model))
        // Directory models are served by OpenRouter: turning one on without
        // a way to pay for it walks the learner there, as `setOffered` does.
        if !snapshot.configuredProviders.contains(.openRouter) {
            onRequestAPIKey?()
        }
    }

    private func setAsDefault(_ entry: AIModelCatalogEntry) {
        // The new Default Model is no longer its own backup.
        let identity = AIBackupModels.identity(entry.provider, entry.modelID)
        if snapshot.backups.contains(where: { AIBackupModels.identity($0.provider, $0.model) == identity }) {
            saveBackups(snapshot.backups.filter { AIBackupModels.identity($0.provider, $0.model) != identity })
        }
        AIModelCatalog.setDefault(entry)
        snapshot.enabledIDs = AIModelCatalog.enabledIDs
        // Read back the stored identity: the badge must name the real default.
        snapshot.defaultID = AIModelCatalog.defaultEntry?.id
    }

    /// Runs `apply` once the model has passed a test run of chat: at once
    /// when it already has, after a small request when it has not been
    /// tried, or failed before. A model that fails is not applied, and the
    /// alert says why.
    private func testThen(_ provider: AIProvider, _ model: String, name: String, apply: @escaping () -> Void) {
        guard testingKey == nil else { return }
        let role = Self.role
        pickRefusal = nil
        if AIModelQualification.isPassed(provider: provider, model: model, role: role) {
            apply()
            return
        }
        testingKey = Self.testingKey(provider, model)
        Task {
            let verdict = await Task.detached(priority: .userInitiated) {
                await AIModelQualification.testBeforeSelecting(provider: provider, model: model, role: role)
            }.value
            testingKey = nil
            if verdict == .go {
                apply()
            } else {
                pickRefusal = AIModelQualification.refusalText(name: name, role: role, verdict: verdict)
            }
        }
    }

    private static func testingKey(_ provider: AIProvider, _ model: String) -> String {
        "\(provider.rawValue)|\(model)"
    }

    // MARK: Backups

    /// A backup's place in the order it is tried, from 1; nil otherwise.
    private func backupRank(provider: AIProvider, model: String) -> Int? {
        let identity = AIBackupModels.identity(provider, model)
        return snapshot.backups.firstIndex { AIBackupModels.identity($0.provider, $0.model) == identity }.map { $0 + 1 }
    }

    /// Adds the model as the last backup once it passed a test run, like any
    /// pick, or takes it off the list. A directory model is catalogued first,
    /// so its name and price resolve, without being offered in the picker.
    private func toggleBackup(
        provider: AIProvider,
        model: String,
        name: String,
        directoryModel: OpenRouterDirectoryModel? = nil
    ) {
        let identity = AIBackupModels.identity(provider, model)
        if snapshot.backups.contains(where: { AIBackupModels.identity($0.provider, $0.model) == identity }) {
            saveBackups(snapshot.backups.filter { AIBackupModels.identity($0.provider, $0.model) != identity })
            return
        }
        guard snapshot.backups.count < AIBackupModels.limit else { return }
        testThen(provider, model, name: name) {
            if let directoryModel { FreeModelsSetup.catalog(directoryModel) }
            saveBackups(snapshot.backups + [AITaskModelRoute(provider: provider, model: model)])
        }
    }

    private func saveBackups(_ routes: [AITaskModelRoute]) {
        snapshot.backups = routes
        Task {
            await Task.detached(priority: .userInitiated) {
                AIBackupModels.set(routes, slot: AIBackupModels.chatSlot)
            }.value
            await reload()
        }
    }

    /// The Default Model's backups, each removable. They serve only a
    /// scheduled task's run: a chat the learner types in stays on its model.
    /// Drawn only while there is one (2026-10-06, Quiet chrome); a model's
    /// menu has Use as Backup.
    private var backupsSummary: some View {
        let chosen = snapshot.entries.first { $0.id == snapshot.defaultID }?.displayName ?? "the Default Model"
        return VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                    Text("Backups")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(snapshot.backups.enumerated()), id: \.offset) { index, backup in
                    backupChip(index: index, backup: backup)
                }
            }
            Text(snapshot.backups.count == 1
                ? "A scheduled task moves to it when \(chosen) fails, at its own price."
                : "A scheduled task moves to these, in order, when \(chosen) fails, each at its own price.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.models.backups")
    }

    /// "2. Gemma 4 26B (free)", with a × to take it off.
    private func backupChip(index: Int, backup: AITaskModelRoute) -> some View {
        let name = AIModelCatalog.displayName(provider: backup.provider, modelID: backup.model)
        return HStack(spacing: 4) {
            Text("\(index + 1). \(name)")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                // One long name cannot push a chip past its line.
                .frame(maxWidth: 240, alignment: .leading)
            Button {
                saveBackups(snapshot.backups.filter {
                    AIBackupModels.identity($0.provider, $0.model) != AIBackupModels.identity(backup.provider, backup.model)
                })
            } label: {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 8, weight: .bold)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: -2))
            .help("Stop using \(name) as a backup")
            .accessibilityLabel("Remove backup \(name)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(.fill.quaternary))
    }
}

/// What Settings › Chat reads from the catalog and the keychain; built off
/// the main actor.
private struct ChatModelsSnapshot: Sendable {
    /// Every offered catalog entry, maker by maker, newest first.
    var entries: [AIModelCatalogEntry]
    var enabledIDs: Set<String>
    var defaultID: String?
    var configuredProviders: Set<AIProvider>
    /// The Default Model's backups, in order (`AIBackupModels.chatSlot`).
    var backups: [AITaskModelRoute]
    /// Why no free model can be picked yet (no OpenRouter key of the
    /// learner's own, or the Data & Privacy switch); nil when one can.
    var freeModelBlocker: String?

    static let empty = ChatModelsSnapshot(
        entries: [], enabledIDs: [], defaultID: nil, configuredProviders: [], backups: [], freeModelBlocker: nil
    )

    static func load() -> ChatModelsSnapshot {
        ChatModelsSnapshot(
            entries: AIModelCatalog.makerGroups.flatMap(\.entries),
            enabledIDs: AIModelCatalog.enabledIDs,
            defaultID: AIModelCatalog.defaultEntry?.id,
            configuredProviders: Set(AIProvider.allCases.filter {
                KeychainService.hasUsableTextProviderCredentials(for: $0)
            }),
            backups: AIBackupModels.stored(slot: AIBackupModels.chatSlot),
            freeModelBlocker: FreeModelsSetup.pickBlocker()
        )
    }
}

// MARK: - Lists

/// Settings › Chat's three lists, worked out as pure functions so a test can
/// pin them: the Suggested rows, the Free rows, and the directory by maker.
/// Every model is matched by its OpenRouter slug, the
/// identity the catalog's native ids translate to, so a model the catalog
/// carries is never offered a second time from the directory.
enum ChatModelLists {
    /// One Suggested row.
    enum Suggestion: Identifiable, Equatable {
        /// The catalog carries it, so the row turns it on and off.
        case catalog(AIModelCatalogEntry, slug: String)
        /// Only the directory lists it; turning it on adds it.
        case directory(OpenRouterDirectoryModel)
        /// Not catalogued, and the directory is still loading.
        case pending(slug: String)

        var id: String { slug }

        var slug: String {
            switch self {
            case .catalog(_, let slug): return slug
            case .directory(let model): return model.id.lowercased()
            case .pending(let slug): return slug
            }
        }
    }

    /// Who made a model, as the pane shows it.
    struct MakerIdentity: Equatable, Sendable {
        let name: String
        /// A bundled logo; nil where openrouter.ai's is drawn.
        let logo: AIModelMaker?
        /// The slug's vendor, whose openrouter.ai page supplies that logo.
        let vendor: String
    }

    struct Maker: Identifiable, Equatable {
        /// "maker:anthropic" for a maker the catalog knows, else the vendor.
        let id: String
        let identity: MakerIdentity
        /// Newest first.
        let models: [OpenRouterDirectoryModel]
    }

    /// Everything the pane draws, built at once.
    struct Built {
        let suggestions: [Suggestion]
        /// Free mode's chat picks, as Suggested rows are drawn.
        let free: [Suggestion]
        /// With the browser's filters on, only the models they let through.
        let makers: [Maker]
        /// How many of the chat's directory models each filter would list.
        let filterCounts: [ModelBrowserFilter: Int]
        /// Lowercased slug → the catalog entry that carries it.
        let entryBySlug: [String: AIModelCatalogEntry]
        /// Lowercased slug → its directory row.
        let directoryBySlug: [String: OpenRouterDirectoryModel]
        /// Vendor → the maker name OpenRouter gives it most often.
        let makerNames: [String: String]

        static let empty = Built(
            suggestions: [], free: [], makers: [], filterCounts: [:],
            entryBySlug: [:], directoryBySlug: [:], makerNames: [:]
        )

        func identity(ofSlug slug: String) -> MakerIdentity {
            ChatModelLists.identity(ofSlug: slug, makerNames: makerNames)
        }
    }

    static func slug(of entry: AIModelCatalogEntry) -> String {
        OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID).lowercased()
    }

    /// "~anthropic/claude-opus-latest" → "anthropic": a moving alias files
    /// under the maker it points into.
    static func vendor(ofSlug slug: String) -> String {
        let author = slug.split(separator: "/", maxSplits: 1).first.map(String.init) ?? slug
        return String(author.drop(while: { $0 == "~" })).lowercased()
    }

    /// A maker the catalog knows is named and drawn as the catalog does,
    /// under whichever vendor slug it publishes (Meta's `meta` and
    /// `meta-llama`); OpenRouter's own routers carry OpenRouter's mark; any
    /// other maker takes the name OpenRouter gives it, or its slug when the
    /// directory gives none.
    static func identity(ofSlug slug: String, makerNames: [String: String]) -> MakerIdentity {
        let vendor = Self.vendor(ofSlug: slug)
        let known = AIModelCatalog.maker(forOpenRouterSlug: vendor)
        if known != .other {
            return MakerIdentity(name: known.displayName, logo: known, vendor: vendor)
        }
        if vendor == "openrouter" {
            return MakerIdentity(name: AIProvider.openRouter.shortName, logo: .other, vendor: vendor)
        }
        return MakerIdentity(name: makerNames[vendor] ?? vendor, logo: nil, vendor: vendor)
    }

    /// - Parameters:
    ///   - suggested: the Suggested list's slugs, in order; each shows as
    ///     the newest release of its family the directory lists
    ///     (`newestReleases`).
    ///   - free: the Free list's slugs, in order; one Suggested already
    ///     lists is not listed twice.
    ///   - entries: the offered catalog entries, in catalog order.
    ///   - directory: nil while it is still loading.
    ///   - filters: what the browser is narrowed to; empty for everything.
    ///   - isOffered: whether the learner's settings allow a model the
    ///     catalog does not carry (Free mode, the Data & Privacy switch).
    ///   - allowsNewerRelease: whether a newer release may take a
    ///     suggestion's place; Background's tier cap (`isTierBelow`).
    static func build(
        suggested: [String],
        free: [String] = [],
        entries: [AIModelCatalogEntry],
        enabledIDs: Set<String>,
        directory: [OpenRouterDirectoryModel]?,
        filters: Set<ModelBrowserFilter> = [],
        isOffered: (String) -> Bool,
        allowsNewerRelease: (OpenRouterDirectoryModel) -> Bool = { _ in true }
    ) -> Built {
        var entryBySlug: [String: AIModelCatalogEntry] = [:]
        for entry in entries {
            let slug = Self.slug(of: entry)
            // An offered entry wins over a second, unoffered one for the
            // same model, so the row shows what the picker offers.
            if let current = entryBySlug[slug], enabledIDs.contains(current.id) || !enabledIDs.contains(entry.id) {
                continue
            }
            entryBySlug[slug] = entry
        }
        var directoryBySlug: [String: OpenRouterDirectoryModel] = [:]
        var authorCounts: [String: [String: Int]] = [:]
        for model in directory ?? [] {
            directoryBySlug[model.id.lowercased()] = model
            if let author = model.makerName {
                authorCounts[Self.vendor(ofSlug: model.id), default: [:]][author, default: 0] += 1
            }
        }
        let makerNames = authorCounts.mapValues { counts in
            counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
        }.filter { !$0.value.isEmpty }

        // Every directory model the chat could offer, before the filters.
        let usable = (directory ?? []).filter { model in
            model.supportsTools && (entryBySlug[model.id.lowercased()] != nil || isOffered(model.id))
        }
        let suggestions = Self.suggestions(
            Self.newestReleases(of: suggested, in: usable, allows: allowsNewerRelease),
            entryBySlug: entryBySlug, directoryBySlug: directoryBySlug,
            directoryLoaded: directory != nil, isOffered: isOffered
        )
        let suggestedSlugs = Set(suggestions.map(\.slug))
        let freeRows = Self.suggestions(
            free.filter { !suggestedSlugs.contains($0.lowercased()) },
            entryBySlug: entryBySlug, directoryBySlug: directoryBySlug,
            directoryLoaded: directory != nil, isOffered: isOffered
        )
        let usableIDs = Set(usable.map(\.id))
        var filterCounts: [ModelBrowserFilter: Int] = [:]
        for filter in ModelBrowserFilter.allCases {
            filterCounts[filter] = usable.filter { filter.matches($0) }.count
        }
        return Built(
            suggestions: suggestions,
            free: freeRows,
            makers: Self.makers(in: usable, makerNames: makerNames, isOffered: { model in
                usableIDs.contains(model.id) && (filters.isEmpty || filters.contains { $0.matches(model) })
            }),
            filterCounts: filterCounts,
            entryBySlug: entryBySlug,
            directoryBySlug: directoryBySlug,
            makerNames: makerNames
        )
    }

    /// Each suggested slug as the catalog entry that carries it, else the
    /// directory's row, else, while the directory is loading, a row waiting
    /// for it. A suggestion the loaded directory lacks, that cannot call
    /// tools, or that the learner's settings rule out is left out: the
    /// catalog has already dropped an entry those settings hide.
    static func suggestions(
        _ slugs: [String],
        entryBySlug: [String: AIModelCatalogEntry],
        directoryBySlug: [String: OpenRouterDirectoryModel],
        directoryLoaded: Bool,
        isOffered: (String) -> Bool
    ) -> [Suggestion] {
        slugs.compactMap { raw in
            let slug = raw.lowercased()
            if let entry = entryBySlug[slug] { return .catalog(entry, slug: slug) }
            guard isOffered(raw) else { return nil }
            if let model = directoryBySlug[slug] { return model.supportsTools ? .directory(model) : nil }
            return directoryLoaded ? nil : .pending(slug: slug)
        }
    }

    /// The suggested slugs, each moved on to the newest release of its
    /// family among `offered` that `allows` lets take its place
    /// (`AIModelCatalog.newestReleases`). Unchanged while the directory is
    /// loading, as nothing is dated yet.
    static func newestReleases(
        of suggested: [String],
        in offered: [OpenRouterDirectoryModel],
        allows: (OpenRouterDirectoryModel) -> Bool = { _ in true }
    ) -> [String] {
        let byID = Dictionary(offered.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return AIModelCatalog.newestReleases(
            of: suggested,
            listed: AIModelCatalog.listingDates(offered, slug: \.id, listedAt: \.createdAt)
        ) { successor, _ in
            byID[successor].map(allows) ?? false
        }
    }

    /// Whether `model` sits a price tier below its maker's Chat suggestion:
    /// cheaper for input and for output. A Background suggestion is its
    /// maker's cheap tier, and a family name does not always say the tier —
    /// xAI names every Grok `grok-#`, so the releases after Grok 4.3 are the
    /// $2/$6 models Chat suggests — so a newer release takes a Background
    /// pick's place only while this holds. False when either price, or the
    /// maker's Chat suggestion, is unknown.
    static func isTierBelow(
        _ model: OpenRouterDirectoryModel,
        chatSuggestions: [OpenRouterDirectoryModel]
    ) -> Bool {
        let vendor = Self.vendor(ofSlug: model.id)
        guard let pick = chatSuggestions.first(where: { Self.vendor(ofSlug: $0.id) == vendor }),
              let input = model.inputUSDPerMTokens, let output = model.outputUSDPerMTokens,
              let pickInput = pick.inputUSDPerMTokens, let pickOutput = pick.outputUSDPerMTokens
        else { return false }
        return input < pickInput && output < pickOutput
    }

    /// The directory by maker: every model the chat can use (tool calling,
    /// and what `isOffered` allows), newest first. The catalog's makers lead,
    /// in its order, then the rest by how many models they list.
    static func makers(
        in directory: [OpenRouterDirectoryModel],
        makerNames: [String: String],
        isOffered: (OpenRouterDirectoryModel) -> Bool
    ) -> [Maker] {
        var identities: [String: MakerIdentity] = [:]
        var grouped: [String: [OpenRouterDirectoryModel]] = [:]
        for model in directory where model.supportsTools && isOffered(model) {
            let identity = Self.identity(ofSlug: model.id, makerNames: makerNames)
            let key = identity.logo.map { "maker:\($0.rawValue)" } ?? identity.vendor
            identities[key] = identities[key] ?? identity
            grouped[key, default: []].append(model)
        }
        // OpenRouter's own routers draw the `.other` mark but are no lab of
        // the catalog's, so they sort with the rest.
        let catalogOrder = AIModelMaker.allCases.filter { $0 != .other }
        func rank(_ key: String) -> Int {
            identities[key]?.logo.flatMap { catalogOrder.firstIndex(of: $0) } ?? catalogOrder.count
        }
        let keys = grouped.keys.sorted { lhs, rhs in
            let (l, r) = (rank(lhs), rank(rhs))
            if l != r { return l < r }
            let (lc, rc) = (grouped[lhs]?.count ?? 0, grouped[rhs]?.count ?? 0)
            if lc != rc { return lc > rc }
            return (identities[lhs]?.name ?? lhs).localizedCaseInsensitiveCompare(identities[rhs]?.name ?? rhs) == .orderedAscending
        }
        return keys.compactMap { key in
            guard let identity = identities[key], let models = grouped[key] else { return nil }
            return Maker(id: key, identity: identity, models: Self.newestFirst(models))
        }
    }

    /// The catalog's rule for a maker's models (`AIModelCatalog.orderedNewestFirst`):
    /// newest listing first, then the dearer, then by name.
    static func newestFirst(_ models: [OpenRouterDirectoryModel]) -> [OpenRouterDirectoryModel] {
        AIModelCatalog.orderedNewestFirst(
            models,
            releaseDate: \.createdAt,
            rates: { model in model.inputUSDPerMTokens.map { (input: $0, output: model.outputUSDPerMTokens ?? 0) } },
            tieBreak: { lhs, rhs in
                let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
            }
        )
    }
}

extension ModelBrowserFilter {
    /// Free is the price the directory lists today, `:free` or not (a stealth
    /// model is free without the suffix); discounted is a promotion OpenRouter
    /// runs on it.
    func matches(_ model: OpenRouterDirectoryModel) -> Bool {
        matches(isFree: model.isZeroPriced, isDiscounted: model.promotion != nil)
    }
}

// MARK: - A model's row

/// One model as a banner across the pane: the maker's logo, the model's
/// name and badges, its price, speed and context window, and a check when
/// the chat's picker offers it, or, in Settings › Background, when the work
/// runs on it. The whole row is the switch; its provider button chooses
/// which of the model's OpenRouter providers runs it, and its context menu
/// holds the rest.
struct ChatModelRow: View {
    /// What the row's check means.
    enum Purpose {
        /// The chat's model picker offers the model.
        case chat
        /// A Background slot runs on the model.
        case background(ModelPickerSlot)

        var isChat: Bool {
            if case .chat = self { return true }
            return false
        }
    }

    let entry: AIModelCatalogEntry
    let maker: ChatModelLists.MakerIdentity
    /// The maker's logo and name lead the row. The browser, which lists one
    /// maker at a time, leaves them out.
    let showsMaker: Bool
    let isOffered: Bool
    let isDefault: Bool
    /// Whether the model's host has usable credentials. A row without them
    /// is dimmed; turning it on walks the learner to them.
    let isConfigured: Bool
    /// A suggestion still waiting for the directory: named, not yet usable.
    var isPending = false
    /// The directory's row for the model: the live price, promotion and
    /// context window.
    var directoryModel: OpenRouterDirectoryModel? = nil
    var isTesting = false
    var backupRank: Int? = nil
    var backupsAreFull = false
    /// Adds the model to the backups or takes it off; nil for the Default
    /// Model, which the backups stand in for.
    var toggleBackup: (() -> Void)? = nil
    var setAsDefault: (() -> Void)? = nil
    var purpose: Purpose = .chat
    let action: () -> Void

    @State private var tokensPerSecond: Double?
    @State private var showsHost = false
    /// Room kept at the trailing edge for the controls laid over the row, as
    /// wide as they last measured.
    @State private var trailingIconsWidth: CGFloat = 0

    private var slug: String { OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID) }
    /// Offered or not (product owner, 2026-09-28: "regardless of whether the model
    /// is selected"): the choice is kept per model, so one made first is
    /// waiting when the model is offered.
    /// A router (`openrouter/free`, `openrouter/auto`) has no providers of its
    /// own: OpenRouter lists none for it, so there is nothing to choose.
    private var offersHost: Bool { !isPending && !slug.lowercased().hasPrefix("openrouter/") }
    private var openRouterURL: URL? { OpenRouterModelPage.url(slug: slug) }
    private var name: String { entry.displayName }

    /// The slot whose provider the row's button sets (`OpenRouterHostPreference`).
    private var hostSlotID: String {
        switch purpose {
        case .chat: return ModelPickerSlot.chat.id
        case .background(let slot): return slot.sharedSlotID
        }
    }

    /// The check, said aloud.
    private var checkDescription: String {
        switch purpose {
        case .chat: return "\(isOffered ? "offered" : "not offered") in the chat model picker"
        case .background(let slot): return "\(isOffered ? "selected" : "not selected") for Background, \(slot.title)"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if showsMaker {
                    logoTile
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        badges
                    }
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Color.clear
                    .frame(width: trailingIconsWidth, height: 1)
                statusMark
                    .frame(width: 16)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, showsMaker ? 10 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOffered ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.fill.quaternary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isOffered ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0, opacity: 0.10))
        .disabled(isPending)
        // On the row's Button, ahead of the overlay: set on the whole, they
        // would replace the provider button's and the link's own.
        .help(tooltip)
        .accessibilityLabel(
            "\(name), \(checkDescription)"
                + (isDefault ? ", default model" : "")
                + (backupRank.map { ", backup \($0)" } ?? "")
        )
        // Over the row, not inside its label: a control nested in the row's
        // Button would hand its click to the row.
        .overlay(alignment: .trailing) {
            // Left of the check: the row's padding, the check's width and the
            // spacing before it.
            trailingIcons
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    trailingIconsWidth = width
                }
                .padding(.trailing, 14 + 16 + 12)
        }
        .opacity(isConfigured && !isPending ? 1 : 0.55)
        // A suggestion that waited for the directory loads its speed once
        // it resolves.
        .task(id: isPending ? "" : slug) {
            await loadSpeed()
        }
        .contextMenu { rowMenu }
    }

    private var logoTile: some View {
        OpenRouterMakerLogo(bundled: maker.logo, openRouterSlug: maker.vendor, fallbackSymbol: "sparkles")
            .frame(width: 18, height: 18)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    /// What the row is to the learner, in one grey line beside its name:
    /// "Default · Recommended · 50% off · Backup 1". All of it is grey
    /// (lists are monochrome, docs/ui-design.md; the product owner, 2026-10-06: "fewer
    /// buttons and bells and whistles"). Whether a host trains on prompts is
    /// not said here: that is OpenRouter's to say (2026-10-07).
    @ViewBuilder
    private var badges: some View {
        if let marks = Self.marks(
            isDefault: isDefault,
            isRecommended: entry.provider == .openRouter && FreeModelsSetup.isRecommended(entry.modelID),
            promotion: directoryModel?.promotion?.label,
            backupRank: backupRank
        ) {
            Text(marks)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(FreeModelsSetup.isRecommended(entry.modelID) ? FreeModelsSetup.recommendation : marks)
        }
    }

    /// The row's grey marks joined, nil when it has none. Pure.
    nonisolated static func marks(isDefault: Bool, isRecommended: Bool, promotion: String?, backupRank: Int?) -> String? {
        var marks: [String] = []
        if isDefault { marks.append("Default") }
        if isRecommended { marks.append("Recommended") }
        if let promotion, !promotion.isEmpty { marks.append(promotion) }
        if let backupRank { marks.append("Backup \(backupRank)") }
        return marks.isEmpty ? nil : marks.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusMark: some View {
        if isTesting || isPending {
            ProgressView()
                .controlSize(.mini)
                .help(isPending ? "Reading OpenRouter's directory" : "Testing \(name) before \(purpose.isChat ? "offering" : "using") it")
        } else if isOffered {
            // Only offered rows carry a mark: the tint already says "on", and
            // a hollow circle on every row reads as noise.
            Image(systemName: "checkmark.circle.fill")
                .zoomedSystemFont(size: 14, weight: .regular)
                .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private var trailingIcons: some View {
        HStack(spacing: 6) {
            if offersHost {
                ChatModelHostButton(entry: entry, slotID: hostSlotID, isPresented: $showsHost)
            }
            if let openRouterURL {
                Link(destination: openRouterURL) {
                    Image(systemName: "arrow.up.right.square")
                        .zoomedSystemFont(size: 11, weight: .regular)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 4, inset: -1))
                .help("Read about \(name) on OpenRouter")
                .accessibilityLabel("\(name) on OpenRouter")
            }
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if offersHost {
            Button {
                showsHost = true
            } label: {
                Label("Choose Provider…", systemImage: "server.rack")
            }
        }
        if let openRouterURL {
            Link(destination: openRouterURL) {
                Label("About \(name) on OpenRouter", systemImage: "arrow.up.right.square")
            }
        }
        if let setAsDefault {
            Button {
                setAsDefault()
            } label: {
                Label(isDefault ? "Default Model" : "Set as Default", systemImage: isDefault ? "checkmark" : "star")
            }
            .disabled(isDefault)
        }
        if let toggleBackup, !isPending {
            if backupRank != nil {
                Button {
                    toggleBackup()
                } label: {
                    Label("Stop Using as Backup", systemImage: "minus.circle")
                }
            } else {
                Button {
                    toggleBackup()
                } label: {
                    Label(
                        backupsAreFull ? "Use as Backup (\(AIBackupModels.limit) at most)" : "Use as Backup",
                        systemImage: "arrow.triangle.branch"
                    )
                }
                .disabled(backupsAreFull)
            }
        }
        if AIModelCatalog.isCustom(entry) {
            Button("Remove from Catalog") {
                AIModelCatalog.removeCustomOpenRouterModel(id: entry.modelID)
            }
            .disabled(isDefault)
        }
    }

    // MARK: Figures

    private var priceLabel: String? {
        if let input = directoryModel?.inputUSDPerMTokens, let output = directoryModel?.outputUSDPerMTokens {
            return AIModelListPrice.pairLabel(input: input, output: output)
        }
        return AIModelListPrice.label(for: entry)
    }

    /// The list pair a promotion cuts, struck through ahead of the price so
    /// nobody has to guess whether "50% off" is still to come.
    private var listPriceLabel: String? {
        guard let model = directoryModel, let promotion = model.promotion,
              let input = model.inputUSDPerMTokens, let output = model.outputUSDPerMTokens else { return nil }
        return promotion.listPriceLabel(effectiveInput: input, effectiveOutput: output)
    }

    /// Nil when no host has published a window for the model.
    private var contextLabel: String? {
        let tokens = directoryModel?.contextLength.flatMap { $0 > 0 ? $0 : nil }
            ?? AIService.contextWindowTokens(provider: entry.provider, model: entry.modelID)
        return tokens.map { $0 >= 1_000_000 ? "\($0 / 1_000_000)M" : "\($0 / 1_000)k" }
    }

    /// "Anthropic · $4/$20 · 78 tok/s · 1M". No monospaced digits: tabular
    /// figures pad a narrow "1", which reads as a stray space in "$0.1".
    private var subtitle: Text {
        var parts: [Text] = []
        if showsMaker {
            parts.append(Text(maker.name))
        }
        if isPending {
            return parts.reduce(Text(verbatim: "")) { $0 + $1 }
        }
        if let price = priceLabel {
            if let listPriceLabel {
                parts.append(Text(listPriceLabel).strikethrough().foregroundStyle(.tertiary) + Text(verbatim: " ") + Text(price))
            } else {
                parts.append(Text(price))
            }
        } else {
            parts.append(Text("No published list price"))
        }
        if let tokensPerSecond {
            parts.append(Text(verbatim: OpenRouterModelSpeed.label(tokensPerSecond: tokensPerSecond)))
        }
        parts.append(Text(contextLabel ?? "Context window not published"))
        return parts.enumerated().reduce(Text(verbatim: "")) { text, part in
            part.offset == 0 ? part.element : text + Text(verbatim: " · ") + part.element
        }
    }

    private var tooltip: String {
        let context = contextLabel.map { "\($0) token context window" } ?? "context window not published"
        guard let price = priceLabel else { return "\(slug) · \(context)" }
        let was = listPriceLabel.map { ", down from \($0)" } ?? ""
        let speed = tokensPerSecond.map {
            " · \(OpenRouterModelSpeed.label(tokensPerSecond: $0)). \(OpenRouterModelSpeed.explanation)"
        } ?? ""
        return "\(price) input/output per 1M tokens\(was) · \(context)\(speed)"
    }

    /// The speed the chat's picker quotes for the model, once OpenRouter's
    /// statistics arrive. Rows load it as they scroll into view.
    @MainActor
    private func loadSpeed() async {
        guard !isPending else { return }
        let speedSlug = AIRequestOptionSupport.openRouterSpeedSlug(
            provider: entry.provider, model: entry.modelID, routingMode: .openRouter
        ) ?? slug
        tokensPerSecond = OpenRouterModelSpeedCatalog.cachedTokensPerSecond(slug: speedSlug, speed: .standard)
        guard let speeds = try? await OpenRouterModelSpeedCatalog.shared.speeds(for: speedSlug),
              !Task.isCancelled else { return }
        tokensPerSecond = OpenRouterModelSpeed.tokensPerSecond(for: .standard, slug: speedSlug, in: speeds)
    }
}

/// A row's provider button: which of the model's OpenRouter providers runs
/// it, named once one is chosen, "Choose provider" while OpenRouter picks
/// (Automatic). The product owner, 2026-09-28, of the ⋯ it replaced: "it should be like
/// choose provider".
private struct ChatModelHostButton: View {
    let entry: AIModelCatalogEntry
    let slotID: String
    @Binding var isPresented: Bool

    /// "DeepInfra", "Cheapest provider" or "US providers"; nil for Automatic.
    @State private var label: String?

    private var slug: String { OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID) }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 3) {
                Text(label ?? "Choose provider")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .zoomedSystemFont(size: 8, weight: .semibold)
            }
            .font(.caption)
            .foregroundStyle(label == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(.fill.tertiary))
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.10))
        .fixedSize()
        .help("Choose which provider runs \(entry.displayName)")
        .accessibilityLabel("Provider for \(entry.displayName)")
        .accessibilityValue(label ?? "Automatic")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelHostPanel(
                slotID: slotID,
                provider: entry.provider,
                model: entry.modelID,
                onHostChange: refresh
            )
            .frame(width: 560)
            .padding(16)
        }
        .onAppear(perform: refresh)
        .onReceive(
            NotificationCenter.default.publisher(for: PreferenceStore.didChangeRemotely)
                .receive(on: RunLoop.main)
        ) { _ in
            refresh()
        }
    }

    private func refresh() {
        label = OpenRouterHostPreference.stored(slot: slotID, slug: slug)?.label
    }
}
