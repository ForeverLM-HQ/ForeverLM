import SwiftUI
import AppKit

// MARK: - Settings › Background

/// One of Settings › Background's two models, Text-only or Multimodal, or the
/// model one task runs on instead of them, drawn as
/// Settings › Chat draws its own (product owner, 2026-09-28: the chat's "setup with
/// suggested models and then all at the bottom" for Background too): a
/// Suggested list, one model per maker a price tier below the chat's
/// (`AIModelDefaults.suggestedBackgroundModels`,
/// `suggestedBackgroundImageModels`), the free models, the backups, and under
/// them all of OpenRouter as a table (`OpenRouterModelTable`), with a search.
/// It replaced the card grid.
///
/// A slot runs on one model, so a row picks it (after a test run of this
/// work) rather than turning it on and off; its context menu adds or removes
/// a backup, and its provider button chooses who runs it for this slot. The
/// model the pane opened on, when neither list shows it, stays above them
/// for the visit, so a pick in the table does not push the table down
/// under the pointer.
struct BackgroundModelsPane: View {
    let slot: ModelPickerSlot
    /// Walks the learner to the key or sign-in when a picked model's host has
    /// no credentials yet; nil where that pane is hidden.
    let onRequestAPIKey: (() -> Void)?
    /// A model choice here changed, so the pane rereads what follows it.
    var onPick: () -> Void = {}

    // Empty until `reload()` lands: every value reaches `KeychainService`,
    // which is not work for a view initializer.
    @State private var snapshot: ModelSlotStore.Snapshot?
    /// OpenRouter's directory; nil until the first read answers.
    @State private var directory: [OpenRouterDirectoryModel]?
    @State private var isLoadingDirectory = false
    @State private var directoryLoadError: String?
    @State private var lists = ChatModelLists.Built.empty
    /// The slot's model when the pane opened; nil until the first read.
    @State private var openedOn: AITaskModelRoute?
    /// "provider|model" of the row whose test run is under way.
    @State private var testingKey: String?
    @State private var pickRefusal: String?

    private var route: AITaskModelRoute? { snapshot?.route }
    private var backups: [AITaskModelRoute] { snapshot?.backups ?? [] }
    private var configuredProviders: Set<AIProvider> { snapshot?.configuredProviders ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 18) {
                    if let task = slot.ownTask {
                        followsNote(task)
                    }
                    warnings
                    if let pinned = pinnedRow {
                        SettingsModelListSection(title: "Your model") {
                            pinned
                        }
                    }
                    let suggestions = lists.suggestions.filter(canDoThisWork)
                    if !suggestions.isEmpty {
                        SettingsModelListSection(title: "Suggested") {
                            ForEach(suggestions) { suggestion in
                                suggestionRow(suggestion)
                            }
                        }
                    }
                    let free = lists.free.filter(canDoThisWork)
                    if !free.isEmpty {
                        SettingsModelListSection(title: "Free", caption: snapshot?.freeBlocker) {
                            ForEach(free) { suggestion in
                                suggestionRow(suggestion)
                            }
                        }
                    }
                    if slot.ownTask == nil {
                        backupsSummary
                    }
                }
            }
            SettingsCard {
                OpenRouterModelTable(
                    rows: tableRows,
                    state: browserState,
                    subject: slot.requiresVision ? "models that read images" : "models",
                    retry: { Task { await loadDirectory() } },
                    purpose: .background(slot),
                    toggle: { rows in
                        // A slot runs on one model: only a single row picks.
                        if rows.count == 1, let row = rows.first { pick(row) }
                    },
                    accessory: { EmptyView() },
                    actions: { rows in
                        tableActions(rows)
                    }
                )
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
        .onReceive(
            NotificationCenter.default.publisher(for: .aiProviderDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            // A key added or removed, a model catalogued elsewhere, Free mode
            // or the Data & Privacy switch flipped: all land here.
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
        let slot = slot
        let loaded = await Task.detached(priority: .userInitiated) {
            ModelSlotStore.load(slot)
        }.value
        snapshot = loaded
        if openedOn == nil { openedOn = loaded.route }
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

    /// Recomputes the lists from the loaded catalog and directory. Work that
    /// reads images sees only the directory's models that do. A suggestion
    /// moves on to a newer release only while it stays a tier below what
    /// Settings › Chat suggests from the same maker.
    private func rebuild() {
        let needsVision = slot.requiresVision
        let chatCapable = (directory ?? []).filter(\.supportsTools)
        let chatSuggestions = ChatModelLists.newestReleases(of: AIModelDefaults.suggestedChatModels, in: chatCapable)
            .compactMap { slug in chatCapable.first { $0.id.lowercased() == slug.lowercased() } }
        lists = ChatModelLists.build(
            suggested: needsVision ? AIModelDefaults.suggestedBackgroundImageModels : AIModelDefaults.suggestedBackgroundModels,
            free: freeSlugs,
            entries: snapshot?.makerGroups.flatMap(\.entries) ?? [],
            enabledIDs: [],
            directory: directory?.filter { !needsVision || $0.supportsVision == true },
            isOffered: { AIModelCatalog.wouldOffer(provider: .openRouter, modelID: $0) },
            allowsNewerRelease: { ChatModelLists.isTierBelow($0, chatSuggestions: chatSuggestions) }
        )
    }

    /// The free models that can do this work, best first, less any that
    /// failed a test run of it; the preferred ones stand in, waiting, until
    /// the directory answers.
    private var freeSlugs: [String] {
        let count = 3
        guard let directory else {
            let preferred = slot.requiresVision ? FreeModelsSetup.preferredVision : FreeModelsSetup.preferredBackground
            return Array(preferred.prefix(count))
        }
        return FreeModelsSetup.candidates(needsVision: slot.requiresVision, from: directory)
            .prefix(count)
            .map(\.id)
    }

    private var browserState: ModelBrowserState {
        if let directoryLoadError { return .failed(directoryLoadError) }
        return directory == nil || isLoadingDirectory ? .loading : .loaded
    }

    // MARK: Lists

    /// A suggestion the catalog carries is kept for work that reads images
    /// only when the model is known to; the directory's own rows were
    /// filtered already.
    private func canDoThisWork(_ suggestion: ChatModelLists.Suggestion) -> Bool {
        guard slot.requiresVision, case .catalog(let entry, _) = suggestion else { return true }
        return snapshot?.visionIDs.contains(entry.id) == true
    }

    /// The model the pane opened on, when neither list shows it.
    private var pinnedRow: AnyView? {
        guard let openedOn else { return nil }
        let slug = OpenRouterModelID.slug(provider: openedOn.provider, model: openedOn.model).lowercased()
        let listed = Set((lists.suggestions + lists.free).map(\.slug))
        guard !listed.contains(slug) else { return nil }
        if let entry = lists.entryBySlug[slug] {
            return AnyView(catalogRow(entry))
        }
        if let model = lists.directoryBySlug[slug] {
            return AnyView(directoryRow(model))
        }
        let maker = lists.identity(ofSlug: slug)
        return AnyView(catalogRow(
            AIModelCatalogEntry(maker: maker.logo ?? .other, provider: openedOn.provider, modelID: openedOn.model)
        ))
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: ChatModelLists.Suggestion) -> some View {
        switch suggestion {
        case .catalog(let entry, _):
            catalogRow(entry)
        case .directory(let model):
            directoryRow(model)
        case .pending(let slug):
            let maker = lists.identity(ofSlug: slug)
            ChatModelRow(
                entry: AIModelCatalogEntry(maker: maker.logo ?? .other, provider: .openRouter, modelID: slug),
                maker: maker,
                isOffered: false,
                isDefault: false,
                isConfigured: true,
                isPending: true,
                purpose: .background(slot),
                action: {}
            )
        }
    }

    /// A catalogued model: the row picks it for this work.
    private func catalogRow(_ entry: AIModelCatalogEntry) -> some View {
        let slug = ChatModelLists.slug(of: entry)
        let selected = isPicked(provider: entry.provider, model: entry.modelID)
        return ChatModelRow(
            entry: entry,
            maker: lists.identity(ofSlug: slug),
            isOffered: selected,
            isDefault: false,
            isConfigured: configuredProviders.contains(entry.provider),
            directoryModel: lists.directoryBySlug[slug],
            isTesting: testingKey == Self.testingKey(entry.provider, entry.modelID),
            backupRank: backupRank(provider: entry.provider, model: entry.modelID),
            backupsAreFull: backups.count >= AIBackupModels.limit,
            // The model the work runs on is not its own backup.
            toggleBackup: selected || slot.ownTask != nil ? nil : {
                toggleBackup(provider: entry.provider, model: entry.modelID, name: entry.displayName)
            },
            purpose: .background(slot),
            action: {
                testThen(entry.provider, entry.modelID, name: entry.displayName) {
                    pick(provider: entry.provider, model: entry.modelID)
                }
            }
        )
    }

    /// A directory model the catalog does not carry yet: picking it
    /// catalogues it, without offering it in the chat, and picks it.
    private func directoryRow(_ model: OpenRouterDirectoryModel) -> some View {
        let maker = lists.identity(ofSlug: model.id)
        let selected = isPicked(provider: .openRouter, model: model.id)
        return ChatModelRow(
            entry: AIModelCatalogEntry(
                maker: maker.logo ?? .other,
                provider: .openRouter,
                modelID: model.id,
                customName: model.name
            ),
            maker: maker,
            isOffered: selected,
            isDefault: false,
            isConfigured: configuredProviders.contains(.openRouter),
            directoryModel: model,
            isTesting: testingKey == Self.testingKey(.openRouter, model.id),
            backupRank: backupRank(provider: .openRouter, model: model.id),
            backupsAreFull: backups.count >= AIBackupModels.limit,
            toggleBackup: selected || slot.ownTask != nil ? nil : {
                toggleBackup(provider: .openRouter, model: model.id, name: model.name, directoryModel: model)
            },
            purpose: .background(slot),
            action: {
                testThen(.openRouter, model.id, name: model.name) {
                    FreeModelsSetup.catalog(model)
                    pick(provider: .openRouter, model: model.id)
                }
            }
        )
    }

    // MARK: Table

    /// Every model the table lists, maker by maker, newest first, each under
    /// its catalog identity where the catalog carries it, so the row picked
    /// here is the one Suggested shows.
    private var tableRows: [ModelTableRow] {
        lists.makers.flatMap(\.models).map { model in
            var row = ModelTableRow(model, in: lists)
            row.isOn = isPicked(provider: row.entry.provider, model: row.entry.modelID)
            row.isConfigured = configuredProviders.contains(row.entry.provider)
            row.isTesting = testingKey == Self.testingKey(row.entry.provider, row.entry.modelID)
            row.backupRank = backupRank(provider: row.entry.provider, model: row.entry.modelID)
            return row
        }
    }

    /// Picks the row's model once it passed a test run of this work; a
    /// directory model is catalogued first, without being offered in the chat.
    private func pick(_ row: ModelTableRow) {
        testThen(row.entry.provider, row.entry.modelID, name: row.name) {
            if !row.isCatalogued { FreeModelsSetup.catalog(row.model) }
            pick(provider: row.entry.provider, model: row.entry.modelID)
        }
    }

    /// The table's context menu for one row: what a Suggested row's menu
    /// holds, and the pick itself.
    @ViewBuilder
    private func tableActions(_ rows: [ModelTableRow]) -> some View {
        if rows.count == 1, let row = rows.first {
            Button {
                pick(row)
            } label: {
                Label("Use for \(slot.title)", systemImage: "checkmark.circle")
            }
            .disabled(row.isOn)
            // The model the work runs on is not its own backup.
            if !row.isOn, slot.ownTask == nil {
                ModelBackupMenuItem(backupRank: row.backupRank, backupsAreFull: backups.count >= AIBackupModels.limit) {
                    toggleBackup(
                        provider: row.entry.provider,
                        model: row.entry.modelID,
                        name: row.name,
                        directoryModel: row.isCatalogued ? nil : row.model
                    )
                }
            }
            if AIModelCatalog.isCustom(row.entry) {
                Button("Remove from Catalog") {
                    AIModelCatalog.removeCustomOpenRouterModel(id: row.entry.modelID)
                }
            }
        }
    }

    /// A task: whether it follows Background or runs on the model picked
    /// below, and the way back to following.
    @ViewBuilder
    private func followsNote(_ task: AITask) -> some View {
        let followed = snapshot?.followed
        let followedName = followed.map { AIModelCatalog.pickerName(provider: $0.provider, modelID: $0.model) } ?? "Background's model"
        let kind = task.usesMultimodalBackgroundModelDefault ? "Multimodal" : "Text-only"
        VStack(alignment: .leading, spacing: 6) {
            if route == nil {
                Label("Follows Background › \(kind): \(followedName)", systemImage: "arrow.turn.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if snapshot?.waitsForPaidModel == true {
                    Label(
                        "Waiting for a paid model. Meetings stay off free models, and \(followedName) is free. Pick a model for this task below, or give Background a paid backup.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Pick a model below to run this task on it instead.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Runs on the model picked below, not Background's.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Follow Background again") {
                        snapshot?.route = nil
                        Task {
                            await Task.detached(priority: .userInitiated) {
                                KeychainService.setOwnRoute(nil, for: task)
                            }.value
                            await reload()
                        }
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.models.task.followBackground")
                }
                if task.sourceType == .meeting, let route, MeetingModels.isFree(route) {
                    Label(MeetingModels.privacyReason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var warnings: some View {
        if snapshot?.routeIsBlind == true, let route {
            Label(
                "\(AIModelDisplayName.textModelName(route.model, provider: route.provider)) can't read images, so this work fails when it runs. Pick a model below.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let failure = snapshot?.routeQualificationFailure, let route {
            Label(
                "\(AIModelDisplayName.textModelName(route.model, provider: route.provider)) failed a test run of \(slot.qualificationRole.label), so this work fails when it runs. Pick a model below. OpenRouter said: \(failure)",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Choices

    private func isPicked(provider: AIProvider, model: String) -> Bool {
        guard let route else { return false }
        return ModelSlotStore.isSameModel(route, provider: provider, model: model)
    }

    /// Runs `apply` once the model has passed a test run of this slot's work:
    /// at once when it already has, after a small request on the spot when
    /// it has not been tried yet, or failed before. A model that fails is not
    /// applied, and the alert says why.
    private func testThen(_ provider: AIProvider, _ model: String, name: String, apply: @escaping () -> Void) {
        guard testingKey == nil else { return }
        let role = slot.qualificationRole
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
                await reload()
            }
        }
    }

    private static func testingKey(_ provider: AIProvider, _ model: String) -> String {
        "\(provider.rawValue)|\(model)"
    }

    /// Points the slot at one model. The row checks at once; the write and
    /// the read-back run off the main actor.
    private func pick(provider: AIProvider, model: String) {
        let slot = slot
        let picked = AITaskModelRoute(provider: provider, model: model)
        let freeCandidates = directory.map { FreeModelsSetup.candidates(needsVision: slot.requiresVision, from: $0) } ?? []
        snapshot?.route = picked
        if !configuredProviders.contains(provider) {
            onRequestAPIKey?()
        }
        Task {
            await Task.detached(priority: .userInitiated) {
                ModelSlotStore.write(provider: provider, model: model, to: slot)
                ModelSlotStore.backupsAfterPicking(picked, slot: slot, freeCandidates: freeCandidates)
            }.value
            await reload()
            onPick()
        }
    }

    // MARK: Backups

    /// A backup's place in the order it is tried, from 1; nil otherwise.
    private func backupRank(provider: AIProvider, model: String) -> Int? {
        let identity = AIBackupModels.identity(provider, model)
        return backups.firstIndex { AIBackupModels.identity($0.provider, $0.model) == identity }.map { $0 + 1 }
    }

    /// Adds the model as the last backup, once it passed a test run of this
    /// slot's work like any pick, or takes it off the list. A directory model
    /// is catalogued first, so its name and price resolve.
    private func toggleBackup(
        provider: AIProvider,
        model: String,
        name: String,
        directoryModel: OpenRouterDirectoryModel? = nil
    ) {
        let identity = AIBackupModels.identity(provider, model)
        if backups.contains(where: { AIBackupModels.identity($0.provider, $0.model) == identity }) {
            saveBackups(backups.filter { AIBackupModels.identity($0.provider, $0.model) != identity })
            return
        }
        guard backups.count < AIBackupModels.limit else { return }
        testThen(provider, model, name: name) {
            if let directoryModel { FreeModelsSetup.catalog(directoryModel) }
            saveBackups(backups + [AITaskModelRoute(provider: provider, model: model)])
        }
    }

    private func saveBackups(_ routes: [AITaskModelRoute]) {
        let slotID = slot.id
        snapshot?.backups = routes
        Task {
            await Task.detached(priority: .userInitiated) {
                AIBackupModels.set(routes, slot: slotID)
            }.value
            await reload()
            onPick()
        }
    }

    /// What happens when the slot's model cannot answer, and the backups
    /// that take over, each removable. The chips wrap onto more lines: a
    /// setting can list up to ten.
    private var backupsSummary: some View {
        let chosen = route.map { AIModelCatalog.displayName(provider: $0.provider, modelID: $0.model) } ?? "this model"
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
                ForEach(Array(backups.enumerated()), id: \.offset) { index, backup in
                    backupChip(index: index, backup: backup)
                }
            }
            Text(backups.isEmpty
                ? "None. Right-click a model and choose Use as Backup: when \(chosen) is busy, fails or sends back nothing usable, the work moves to it. Up to \(AIBackupModels.limit), tried in order."
                : "When \(chosen) is busy, fails or sends back nothing usable, the work moves to \(backups.count == 1 ? "this model" : "these, in order"). A backup is billed at its own price. Right-click a model to add or remove one.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.models.backups")
    }

    /// "3. Gemma 4 26B (free)", with a × to take it off.
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
                saveBackups(backups.filter {
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

// MARK: - Settings › Background › Tasks

/// Every background task and the model it runs on: Background's Text-only or
/// Multimodal model until the learner gives it one of its own. A row opens
/// the same model list the Background models use (`BackgroundModelsPane`,
/// on `ModelPickerSlot.task`). Grouped as the Studio sidebar groups source
/// types, "Other" last.
struct BackgroundTasksList: View {
    let onOpen: (AITask) -> Void

    struct Row: Identifiable, Sendable {
        let task: AITask
        let modelName: String
        let isOwn: Bool
        let isWaiting: Bool
        var id: String { task.rawValue }
    }

    struct TaskSection: Identifiable, Sendable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    @State private var groups: [TaskSection]?

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                if let groups {
                    Text("Each task runs on Background's Text-only or Multimodal model unless you give it one of its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(groups) { group in
                        SettingsModelListSection(title: group.title) {
                            ForEach(group.rows) { row in
                                taskRow(row)
                            }
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .task { await reload() }
        .onReceive(
            NotificationCenter.default.publisher(for: .aiProviderDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            Task { await reload() }
        }
    }

    private func taskRow(_ row: Row) -> some View {
        Button {
            onOpen(row.task)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.task.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if row.isWaiting {
                        Label("Waiting for a paid model", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(row.isOwn ? row.modelName : "Background · \(row.modelName)")
                            .font(.caption)
                            .foregroundStyle(row.isOwn ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.models.task.\(row.task.rawValue)")
    }

    /// Resolving a model can reach `KeychainService.load`; off the main actor.
    private func reload() async {
        groups = await Task.detached(priority: .userInitiated) { Self.load() }.value
    }

    private nonisolated static func load() -> [TaskSection] {
        let rows = AITask.advancedTasks
            .filter(KeychainService.canHaveOwnRoute)
            .map { task -> Row in
                let own = KeychainService.ownRoute(for: task)
                let route = own ?? KeychainService.backgroundRoute(for: task)
                return Row(
                    task: task,
                    modelName: AIModelCatalog.pickerName(provider: route.provider, modelID: route.model),
                    isOwn: own != nil,
                    isWaiting: KeychainService.isWaitingForPaidModel(task)
                )
            }
        return Dictionary(grouping: rows) { sectionRank($0.task.sourceType) }
            .sorted { $0.key < $1.key }
            .map { _, sectionRows in
                TaskSection(
                    title: sectionTitle(sectionRows[0].task.sourceType),
                    rows: sectionRows.sorted {
                        $0.task.displayName.localizedStandardCompare($1.task.displayName) == .orderedAscending
                    }
                )
            }
    }

    /// The Studio sidebar's source order, "Other" last.
    private nonisolated static func sectionRank(_ type: StudioSourceType?) -> Int {
        switch type {
        case .article, .unclassified, .manual: return 0
        case .paper: return 1
        case .book: return 2
        case .course: return 3
        case .meeting: return 4
        case .podcast: return 5
        case .video: return 6
        case .xPost: return 7
        case nil: return 8
        }
    }

    private nonisolated static func sectionTitle(_ type: StudioSourceType?) -> String {
        switch type {
        case .article, .unclassified, .manual: return "Articles"
        case .paper: return "Papers"
        case .book: return "Books"
        case .course: return "Courses"
        case .meeting: return "Meetings"
        case .podcast: return "Podcasts"
        case .video: return "Videos"
        case .xPost: return "Posts"
        case nil: return "Other"
        }
    }
}

// MARK: - Background model slots

/// Writes and reads for Settings › Background's single-choice slots. Every
/// call reaches `KeychainService.load`; call them off the main actor.
private enum ModelSlotStore {
    struct Snapshot: Sendable {
        let makerGroups: [AIModelCatalog.MakerGroup]
        let configuredProviders: Set<AIProvider>
        /// The model a single-choice slot runs on; nil for the chat. Set at
        /// once on a pick, ahead of the read-back.
        var route: AITaskModelRoute?
        /// Catalog entries known to read images, for a slot that needs them.
        let visionIDs: Set<String>
        /// The slot reads images but runs on a model known not to.
        let routeIsBlind: Bool
        let freeBlocker: String?
        /// Why the slot's own model failed its test for this work; nil when
        /// it passed or is untested.
        let routeQualificationFailure: String?
        /// The slot's backup models in order (`AIBackupModels`). A task's are
        /// its Background model's.
        var backups: [AITaskModelRoute]
        /// A task: the Background model it follows while it has none of its own.
        let followed: AITaskModelRoute?
        /// A task: a meeting that waits for a paid model.
        let waitsForPaidModel: Bool
    }

    static func load(_ slot: ModelPickerSlot) -> Snapshot {
        let route: AITaskModelRoute?
        switch slot {
        case .chat:
            route = nil
        case .backgroundText:
            route = KeychainService.displayedBackgroundTaskRoute
        case .backgroundImages:
            route = KeychainService.displayedBackgroundMultimodalTaskRoute
        case .task(let task):
            route = KeychainService.ownRoute(for: task)
        }
        // A model that failed a test run stays offered: choosing it again
        // tests it again (`AIModelQualification`).
        let groups = AIModelCatalog.makerGroups
        let visionIDs: Set<String> = slot.requiresVision
            ? Set(groups.flatMap(\.entries)
                .filter { KeychainService.modelSupportsVision(provider: $0.provider, model: $0.modelID) == true }
                .map(\.id))
            : []
        return Snapshot(
            makerGroups: groups,
            configuredProviders: Set(AIProvider.allCases.filter {
                KeychainService.hasUsableTextProviderCredentials(for: $0)
            }),
            route: route,
            visionIDs: visionIDs,
            routeIsBlind: slot.requiresVision && route.map {
                KeychainService.modelSupportsVision(provider: $0.provider, model: $0.model) == false
            } == true,
            freeBlocker: slot == .chat ? nil : FreeModelsSetup.pickBlocker(),
            routeQualificationFailure: route.flatMap {
                AIModelQualification.failureMessage(provider: $0.provider, model: $0.model, role: slot.qualificationRole)
            },
            // The chat's serve only a scheduled task's runs (`AIBackupModels.chatSlot`).
            backups: AIBackupModels.stored(slot: slot.sharedSlotID),
            followed: slot.ownTask.map { KeychainService.displayedBackgroundTaskRoute(for: $0) },
            waitsForPaidModel: slot.ownTask.map { KeychainService.isWaitingForPaidModel($0) } ?? false
        )
    }

    /// The backups after the learner picks `route` for the slot: the new
    /// pick is no longer its own backup, and a free pick on a slot without
    /// backups gets the next two free models for the same work
    /// (`FreeModelsSetup.freeBackups`).
    static func backupsAfterPicking(
        _ route: AITaskModelRoute,
        slot: ModelPickerSlot,
        freeCandidates: [OpenRouterDirectoryModel]
    ) {
        // A task's backups are its Background model's, and picking its own
        // model leaves them as they are.
        guard slot != .chat, slot.ownTask == nil else { return }
        let identity = AIBackupModels.identity(route.provider, route.model)
        let current = AIBackupModels.stored(slot: slot.id)
        let kept = current.filter { AIBackupModels.identity($0.provider, $0.model) != identity }
        if kept.count != current.count {
            AIBackupModels.set(kept, slot: slot.id)
        }
        if kept.isEmpty, AIFreeMode.isFreeSelection(provider: route.provider, model: route.model) {
            FreeModelsSetup.giveFreeBackups(freeCandidates, to: slot.id, primaryID: route.model)
        }
    }

    static func write(provider: AIProvider, model: String, to slot: ModelPickerSlot) {
        switch slot {
        case .chat:
            return
        case .backgroundText:
            KeychainService.setBackgroundTaskRoute(provider: provider, model: model)
        case .backgroundImages:
            KeychainService.setBackgroundMultimodalTaskRoute(provider: provider, model: model)
        case .task(let task):
            KeychainService.setOwnRoute(AITaskModelRoute(provider: provider, model: model), for: task)
        }
    }

    /// One model under two hosts' names ("gpt-5.6" and "openai/gpt-5.6") is
    /// one pick.
    static func isSameModel(_ route: AITaskModelRoute, provider: AIProvider, model: String) -> Bool {
        if route.provider == provider, route.model == model { return true }
        return OpenRouterModelID.slug(provider: route.provider, model: route.model).lowercased()
            == OpenRouterModelID.slug(provider: provider, model: model).lowercased()
    }
}
