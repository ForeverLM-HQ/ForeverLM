import SwiftUI
import AppKit

// MARK: - Settings › Chat

/// Settings › Chat, as the product owner redrew it on 2026-09-28 ("let's just do a
/// basically list with banners"): a Suggested list with one model per maker
/// (`AIModelDefaults.suggestedChatModels`), a Free list (OpenRouter's Free
/// Models Router and the best single free models), the backups, and under
/// them OpenRouter's whole directory as a table (`OpenRouterModelTable`), narrowed to free or
/// discounted models or to what a search finds. The list of the other
/// models the learner offered went the same day ("why is that even there?"):
/// the table shows each of them. Every row turns
/// the model on or off in the chat's model picker; its context menu sets the
/// Default Model and the backups a scheduled task's run moves to, and its
/// provider button chooses who runs it. It replaced the maker-by-maker card
/// grid; Settings › Background draws the same list (`BackgroundModelsPane`).
/// Since 2026-11-07 Suggested and Free are one list the learner keeps, Your
/// Models (`ChatModelShortlist`): they start as its rows, and a model is
/// taken off it, added to it from the table, or moved up and down it.
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
    /// What the table's Refresh last found.
    @State private var lastRefresh: ModelDirectoryRefresh?
    @State private var lists = ChatModelLists.Built.empty
    /// Narrows the table to free or discounted models.
    @State private var browserFilters: Set<ModelBrowserFilter> = []
    /// "provider|model" of the row whose test run is under way.
    @State private var testingKey: String?
    /// Several of the table's rows are being offered, one test at a time.
    @State private var isOfferingMany = false
    @State private var pickRefusal: String?

    private static let role = AIModelQualification.Role.chat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 18) {
                    yourModelsSection
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
            // A model turned on or off here or elsewhere, a key added, or the
            // Data & Privacy switch flipped: all land here.
            Task { await reload() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            Task { await reload() }
        }
        // Your Models edited on another Mac, or from chat (`chat.your_models`).
        .onReceive(
            NotificationCenter.default.publisher(for: PreferenceStore.didChangeRemotely)
                .merge(with: NotificationCenter.default.publisher(for: PreferenceStore.didChangeLocally).filter {
                    ($0.userInfo?[PreferenceStore.changedKeysKey] as? Set<String>)?.contains(ChatModelShortlist.preferenceKey) == true
                })
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

    /// `forceRefresh` reads past the directory's few-minute cache: the
    /// table's Refresh, for a model OpenRouter has just listed.
    @MainActor
    private func loadDirectory(forceRefresh: Bool = false) async {
        guard !isLoadingDirectory else { return }
        isLoadingDirectory = true
        directoryLoadError = nil
        defer { isLoadingDirectory = false }
        do {
            let before = directory
            let fresh = try await OpenRouterCatalogAvailability.shared.models(forceRefresh: forceRefresh)
            directory = fresh
            if forceRefresh, let before {
                lastRefresh = ModelDirectoryRefresh(before: before, after: fresh)
            }
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
            pinned: snapshot.yourModels,
            entries: snapshot.entries,
            enabledIDs: snapshot.enabledIDs,
            directory: directory,
            filters: browserFilters,
            isOffered: { AIModelCatalog.wouldOffer(provider: .openRouter, modelID: $0) }
        )
    }

    // MARK: Lists

    /// The Free list: OpenRouter's Free Models Router and the best single free
    /// models beside it, less any that failed a test run of chat. The
    /// preferred models stand in, waiting, until the directory answers.
    private static func freeSlugs(in directory: [OpenRouterDirectoryModel]?) -> [String] {
        let count = FreeModelsSetup.chatAlternatives + 1
        guard let directory else { return Array(FreeModelsSetup.preferredChat.prefix(count)) }
        return FreeModelsSetup.rankedFreeForChat(from: directory)
            .filter { FreeModelsSetup.storedQualification($0.id, .chat) }
            .prefix(count)
            .map(\.id)
    }

    // MARK: Your Models

    /// Your Models (product owner, 2026-11-07: "I should be able to pop models
    /// up higher and the ones that are recommended higher up should also be
    /// able to be deleted"): one list the learner keeps, in their order, in
    /// place of the fixed Suggested and Free lists. Until it is first edited it
    /// is those picks; a × or the menu takes a model off, the table's menu
    /// adds one (Add to Your Models), and a drag or Move Up / Move Down sets
    /// the order. Being on the list is not being offered: the row's check is
    /// still what the chat's picker offers. But every model the picker offers
    /// is on it: one the lists leave out shows after them, and taking an
    /// offered model off the list stops offering it, or the picker would
    /// offer a model this pane has no row for.
    private var yourModelsSection: some View {
        let rows = yourModelRows
        return YourModelsSection(
            suggestions: rows,
            isEdited: snapshot.yourModels != nil,
            caption: rows.contains(where: { lists.isFree($0.slug) }) ? snapshot.freeModelBlocker : nil,
            restore: {
                ChatModelShortlist.restoreSuggested()
                snapshot.yourModels = nil
                rebuild()
            },
            move: { moved, target in
                editYourModels { ChatModelShortlist.moving(moved, onto: target, in: $0) }
            }
        ) { suggestion, index in
            suggestionRow(suggestion, listActions: listActions(for: suggestion.slug, at: index, count: rows.count))
        }
    }

    /// The slugs the list shows now, in order: what an edit starts from
    /// while the learner has not edited it yet.
    private var shownSlugs: [String] {
        yourModelRows.map(\.slug)
    }

    private var yourModelRows: [ChatModelLists.Suggestion] {
        lists.suggestions + lists.free + lists.offered
    }

    /// Takes a model off Your Models, and out of the chat's picker: an
    /// offered model left off the list would come straight back as a row.
    /// The Default Model stays offered (`AIModelCatalog.setEnabled`).
    private func removeFromYourModels(_ slug: String) {
        editYourModels { ChatModelShortlist.removing(slug, from: $0) }
        if let entry = lists.entryBySlug[slug.lowercased()],
           snapshot.enabledIDs.contains(entry.id), snapshot.defaultID != entry.id {
            setOffered(false, entry)
        }
    }

    /// Edits the stored list, or, the first time, the suggested picks as the
    /// pane shows them, so nothing the learner sees moves but what they moved.
    private func editYourModels(_ edit: ([String]) -> [String]) {
        let edited = ChatModelShortlist.normalized(edit(snapshot.yourModels ?? shownSlugs))
        ChatModelShortlist.save(edited)
        snapshot.yourModels = edited
        rebuild()
    }

    private func isOnYourModels(_ slug: String) -> Bool {
        let slug = slug.lowercased()
        return shownSlugs.contains(slug)
    }

    private func listActions(for slug: String, at index: Int, count: Int) -> ChatModelRow.ListActions {
        ChatModelRow.ListActions(
            remove: { removeFromYourModels(slug) },
            moveUp: index == 0 ? nil : { editYourModels { ChatModelShortlist.moving(slug, by: -1, in: $0) } },
            moveDown: index == count - 1 ? nil : { editYourModels { ChatModelShortlist.moving(slug, by: 1, in: $0) } }
        )
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: ChatModelLists.Suggestion, listActions: ChatModelRow.ListActions?) -> some View {
        switch suggestion {
        case .catalog(let entry, _):
            catalogRow(entry, listActions: listActions)
        case .directory(let model):
            directoryRow(model, listActions: listActions)
        case .pending(let slug):
            let maker = lists.identity(ofSlug: slug)
            ChatModelRow(
                entry: AIModelCatalogEntry(maker: maker.logo ?? .other, provider: .openRouter, modelID: slug),
                maker: maker,
                isOffered: false,
                isDefault: false,
                isConfigured: true,
                isPending: true,
                listActions: listActions,
                action: {}
            )
        }
    }

    /// A catalogued model: the row turns it on or off in the chat's picker.
    private func catalogRow(_ entry: AIModelCatalogEntry, listActions: ChatModelRow.ListActions?) -> some View {
        let slug = ChatModelLists.slug(of: entry)
        let offered = snapshot.enabledIDs.contains(entry.id)
        let isDefault = snapshot.defaultID == entry.id
        return ChatModelRow(
            entry: entry,
            maker: lists.identity(ofSlug: slug),
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
            listActions: listActions,
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
    private func directoryRow(_ model: OpenRouterDirectoryModel, listActions: ChatModelRow.ListActions?) -> some View {
        let maker = lists.identity(ofSlug: model.id)
        return ChatModelRow(
            entry: AIModelCatalogEntry(
                maker: maker.logo ?? .other,
                provider: .openRouter,
                modelID: model.id,
                customName: model.name
            ),
            maker: maker,
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
            listActions: listActions,
            action: {
                testThen(.openRouter, model.id, name: model.name) { add(model) }
            }
        )
    }

    // MARK: Browser

    /// OpenRouter's directory as a table (`OpenRouterModelTable`), with a
    /// search. With Free or Discounted on, only those models are listed.
    private var browser: some View {
        OpenRouterModelTable(
            rows: tableRows,
            state: browserState,
            subject: ModelBrowserFilter.subject("chat models", filters: browserFilters),
            refresh: { Task { await loadDirectory(forceRefresh: true) } },
            lastRefresh: lastRefresh,
            purpose: .chat,
            toggle: toggle,
            accessory: {
                if directory != nil {
                    ModelBrowserFilterChips(filters: $browserFilters, counts: lists.filterCounts)
                }
            },
            actions: { rows in
                tableActions(rows)
            }
        )
    }

    private var browserState: ModelBrowserState {
        if let directoryLoadError { return .failed(directoryLoadError) }
        return directory == nil || isLoadingDirectory ? .loading : .loaded
    }

    /// Every model the table lists, maker by maker, newest first, each
    /// under its catalog identity where the catalog carries it.
    private var tableRows: [ModelTableRow] {
        lists.makers.flatMap(\.models).map { model in
            var row = ModelTableRow(model, in: lists)
            row.isOn = row.isCatalogued && snapshot.enabledIDs.contains(row.entry.id)
            row.isDefault = row.isCatalogued && snapshot.defaultID == row.entry.id
            row.isConfigured = snapshot.configuredProviders.contains(row.entry.provider)
            row.isTesting = testingKey == Self.testingKey(row.entry.provider, row.entry.modelID)
            row.backupRank = backupRank(provider: row.entry.provider, model: row.entry.modelID)
            return row
        }
    }

    /// The table's check, or a double-click: one row turns on or off as a
    /// Suggested row does; several are all offered, or all taken off when
    /// every one of them already is.
    private func toggle(_ rows: [ModelTableRow]) {
        if rows.count == 1, let row = rows.first {
            if row.isOn {
                setOffered(false, row.entry)
            } else if row.isCatalogued {
                testThen(row.entry.provider, row.entry.modelID, name: row.name) { setOffered(true, row.entry) }
            } else {
                testThen(.openRouter, row.model.id, name: row.name) { add(row.model) }
            }
        } else if rows.contains(where: { !$0.isOn }) {
            offer(rows.filter { !$0.isOn })
        } else {
            for row in rows { setOffered(false, row.entry) }
        }
    }

    /// Offers each model, testing the ones not yet tried one after another.
    /// One that fails stays off, and a single alert names every one that did.
    private func offer(_ rows: [ModelTableRow]) {
        guard testingKey == nil, !isOfferingMany else { return }
        let role = Self.role
        isOfferingMany = true
        pickRefusal = nil
        Task {
            var refusals: [String] = []
            for row in rows {
                let (provider, model) = (row.entry.provider, row.entry.modelID)
                if !AIModelQualification.isPassed(provider: provider, model: model, role: role) {
                    testingKey = Self.testingKey(provider, model)
                    let verdict = await Task.detached(priority: .userInitiated) {
                        await AIModelQualification.testBeforeSelecting(provider: provider, model: model, role: role)
                    }.value
                    testingKey = nil
                    // Nil for a model that passed.
                    if let refusal = AIModelQualification.refusalText(name: row.name, role: role, verdict: verdict) {
                        refusals.append(refusal)
                        continue
                    }
                }
                if row.isCatalogued {
                    setOffered(true, row.entry)
                } else {
                    add(row.model)
                }
            }
            isOfferingMany = false
            if !refusals.isEmpty {
                pickRefusal = refusals.joined(separator: "\n\n")
            }
        }
    }

    /// The table's context menu: for one row what a Suggested row's menu
    /// holds; for several, offering them all or taking them all off.
    private func tableActions(_ rows: [ModelTableRow]) -> [ModelTableMenuItem] {
        guard rows.count == 1, let row = rows.first else {
            let off = rows.filter { !$0.isOn }
            let on = rows.filter { $0.isOn && !$0.isDefault }
            var items: [ModelTableMenuItem] = []
            if !off.isEmpty {
                items.append(.button("Offer \(ModelTableRow.count(off.count)) in Chat", systemImage: "plus.circle") {
                    offer(off)
                })
            }
            if !on.isEmpty {
                items.append(.button("Stop Offering \(ModelTableRow.count(on.count))", systemImage: "minus.circle") {
                    for row in on { setOffered(false, row.entry) }
                })
            }
            let unlisted = rows.map { $0.model.id.lowercased() }.filter { !isOnYourModels($0) }
            if !unlisted.isEmpty {
                items.append(.button("Add \(ModelTableRow.count(unlisted.count)) to Your Models", systemImage: "text.badge.plus") {
                    editYourModels { ChatModelShortlist.adding(unlisted, to: $0) }
                })
            }
            return items
        }
        // The Default Model cannot be turned off.
        var items: [ModelTableMenuItem] = [
            .button(
                row.isOn ? "Stop Offering in Chat" : "Offer in Chat",
                systemImage: row.isOn ? "minus.circle" : "plus.circle",
                isEnabled: !row.isDefault
            ) {
                toggle([row])
            },
        ]
        let slug = row.model.id.lowercased()
        if isOnYourModels(slug) {
            items.append(.button("Remove from Your Models", systemImage: "text.badge.minus") {
                removeFromYourModels(slug)
            })
        } else {
            items.append(.button("Add to Your Models", systemImage: "text.badge.plus") {
                editYourModels { ChatModelShortlist.adding([slug], to: $0) }
            })
        }
        if row.isCatalogued {
            items.append(.button(
                row.isDefault ? "Default Model" : "Set as Default",
                systemImage: row.isDefault ? "checkmark" : "star",
                isEnabled: !row.isDefault
            ) {
                testThen(row.entry.provider, row.entry.modelID, name: row.name) { setAsDefault(row.entry) }
            })
        }
        if !row.isDefault {
            items.append(.backup(rank: row.backupRank, isFull: snapshot.backups.count >= AIBackupModels.limit) {
                toggleBackup(
                    provider: row.entry.provider,
                    model: row.entry.modelID,
                    name: row.name,
                    directoryModel: row.isCatalogued ? nil : row.model
                )
            })
        }
        if AIModelCatalog.isCustom(row.entry) {
            items.append(.button("Remove from Catalog", isEnabled: !row.isDefault) {
                AIModelCatalog.removeCustomOpenRouterModel(id: row.entry.modelID)
            })
        }
        return items
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
        guard testingKey == nil, !isOfferingMany else { return }
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
    /// Your Models as the learner left it; nil until they first edit it.
    var yourModels: [String]?

    static let empty = ChatModelsSnapshot(
        entries: [], enabledIDs: [], defaultID: nil, configuredProviders: [], backups: [], freeModelBlocker: nil,
        yourModels: nil
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
            freeModelBlocker: FreeModelsSetup.pickBlocker(),
            yourModels: ChatModelShortlist.stored
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
        /// The Free list's chat picks, as Suggested rows are drawn.
        let free: [Suggestion]
        /// Models the chat's picker offers that neither list above shows,
        /// in catalog order: Your Models lists them after the rest, so a
        /// model the picker offers always has a row to turn it off on.
        let offered: [Suggestion]
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
            suggestions: [], free: [], offered: [], makers: [], filterCounts: [:],
            entryBySlug: [:], directoryBySlug: [:], makerNames: [:]
        )

        func identity(ofSlug slug: String) -> MakerIdentity {
            ChatModelLists.identity(ofSlug: slug, makerNames: makerNames)
        }

        /// A router or model OpenRouter serves at no charge, for the caption
        /// that says why free models cannot be picked yet.
        func isFree(_ slug: String) -> Bool {
            if let model = directoryBySlug[slug] { return model.isZeroPriced }
            return slug.hasSuffix(":free") || slug == "openrouter/free"
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
    ///   - pinned: the list the learner keeps (Settings › Chat's Your
    ///     Models), in their order; when set, it replaces `suggested` and
    ///     `free` as they stand, newer releases not swapped in.
    ///   - entries: the offered catalog entries, in catalog order.
    ///   - enabledIDs: what the chat's picker offers; one of those neither
    ///     list shows is listed after them (`Built.offered`).
    ///   - directory: nil while it is still loading.
    ///   - filters: what the browser is narrowed to; empty for everything.
    ///   - isOffered: whether the learner's settings allow a model the
    ///     catalog does not carry (the Data & Privacy switch).
    ///   - allowsNewerRelease: whether a newer release may take a
    ///     suggestion's place; Background's tier cap (`isTierBelow`).
    static func build(
        suggested: [String],
        free: [String] = [],
        pinned: [String]? = nil,
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
            pinned.map(ChatModelShortlist.normalized)
                ?? Self.newestReleases(of: suggested, in: usable, allows: allowsNewerRelease),
            entryBySlug: entryBySlug, directoryBySlug: directoryBySlug,
            directoryLoaded: directory != nil, isOffered: isOffered
        )
        let suggestedSlugs = Set(suggestions.map(\.slug))
        let freeRows = pinned != nil ? [] : Self.suggestions(
            free.filter { !suggestedSlugs.contains($0.lowercased()) },
            entryBySlug: entryBySlug, directoryBySlug: directoryBySlug,
            directoryLoaded: directory != nil, isOffered: isOffered
        )
        // An offered model the lists leave out (switched on in an earlier
        // build, or Your Models edited without it) would be offered in the
        // chat's picker with no row here to turn it off.
        var listedSlugs = suggestedSlugs.union(freeRows.map(\.slug))
        let offeredRows: [Suggestion] = entries.compactMap { entry in
            let slug = Self.slug(of: entry)
            guard enabledIDs.contains(entry.id), entryBySlug[slug] == entry,
                  listedSlugs.insert(slug).inserted else { return nil }
            return .catalog(entry, slug: slug)
        }
        let usableIDs = Set(usable.map(\.id))
        var filterCounts: [ModelBrowserFilter: Int] = [:]
        for filter in ModelBrowserFilter.allCases {
            filterCounts[filter] = usable.filter { filter.matches($0) }.count
        }
        return Built(
            suggestions: suggestions,
            free: freeRows,
            offered: offeredRows,
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

// MARK: - Your Models

/// Your Models: the OpenRouter slugs the learner keeps at the top of
/// Settings › Chat, and of Settings › Background (one list for text work, one
/// for work that reads images, each task sharing its kind's), in their order.
/// Nothing is stored until a list is first edited, and until then the pane
/// lists its suggested and free picks (`ChatModelLists.build`). Account
/// settings, synced like the offered set beside them; `set_app_setting`
/// `chat.your_models`, `background.your_models_text` and
/// `background.your_models_images` write them.
enum ChatModelShortlist {
    static let preferenceKey = "chatModels.shortlist"
    static let backgroundTextKey = "backgroundModels.shortlist.text"
    static let backgroundImagesKey = "backgroundModels.shortlist.images"

    /// The Background list a slot shows: its kind's.
    static func backgroundKey(readsImages: Bool) -> String {
        readsImages ? backgroundImagesKey : backgroundTextKey
    }

    /// Settings › Chat's, nil until the learner first edits it.
    static var stored: [String]? { stored(key: preferenceKey) }

    /// Nil until the learner first edits the list.
    static func stored(key: String) -> [String]? {
        UserDefaults.standard.stringArray(forKey: key).map(normalized)
    }

    /// The list as it stands, for a reader that has no directory to resolve
    /// the suggestions' newest releases: the stored list, else the
    /// suggested picks and the preferred free ones as written.
    static var current: [String] {
        stored ?? normalized(
            AIModelDefaults.suggestedChatModels
                + FreeModelsSetup.preferredChat.prefix(FreeModelsSetup.chatAlternatives + 1)
        )
    }

    /// A Background list as it stands, as `current` reads Chat's.
    static func currentBackground(readsImages: Bool) -> [String] {
        stored(key: backgroundKey(readsImages: readsImages)) ?? normalized(
            (readsImages ? AIModelDefaults.suggestedBackgroundImageModels : AIModelDefaults.suggestedBackgroundModels)
                + (readsImages ? FreeModelsSetup.preferredVision : FreeModelsSetup.preferredBackground).prefix(3)
        )
    }

    static func save(_ slugs: [String], key: String = preferenceKey) {
        PreferenceStore.set(normalized(slugs), forKey: key)
    }

    /// Forgets the learner's list, so the suggested picks show again.
    static func restoreSuggested(key: String = preferenceKey) {
        PreferenceStore.remove(forKey: key)
    }

    /// Lowercased, trimmed, each slug once, in the order first given.
    static func normalized(_ slugs: [String]) -> [String] {
        var seen: Set<String> = []
        return slugs.compactMap { raw in
            let slug = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !slug.isEmpty, seen.insert(slug).inserted else { return nil }
            return slug
        }
    }

    /// Appends the slugs the list does not hold yet, at its end.
    static func adding(_ slugs: [String], to list: [String]) -> [String] {
        normalized(list + slugs)
    }

    static func removing(_ slug: String, from list: [String]) -> [String] {
        let slug = slug.lowercased()
        return normalized(list).filter { $0 != slug }
    }

    /// Moves `slug` by `offset` places, kept within the list; unchanged when
    /// the list does not hold it.
    static func moving(_ slug: String, by offset: Int, in list: [String]) -> [String] {
        var list = normalized(list)
        guard let from = list.firstIndex(of: slug.lowercased()) else { return list }
        let to = min(max(from + offset, 0), list.count - 1)
        list.insert(list.remove(at: from), at: to)
        return list
    }

    /// A dragged slug dropped on another row takes that row's place: the
    /// rows between move one towards where it came from. A slug the list
    /// lacks goes in before the row; onto a row the list lacks, at the end.
    static func moving(_ slug: String, onto target: String, in list: [String]) -> [String] {
        let (slug, target) = (slug.lowercased(), target.lowercased())
        let original = normalized(list)
        var rest = original.filter { $0 != slug }
        guard let targetIndex = rest.firstIndex(of: target) else { return rest + [slug] }
        let movesDown = (original.firstIndex(of: slug) ?? .max) < (original.firstIndex(of: target) ?? 0)
        rest.insert(slug, at: movesDown ? targetIndex + 1 : targetIndex)
        return rest
    }
}

/// The Your Models list as Settings › Chat and Settings › Background draw
/// it: its title, Restore Suggested once it was edited, a caption, and the
/// rows, each dragged onto another to take its place. The pane draws each
/// row (`row`), since what a row's check means is the pane's.
struct YourModelsSection<Row: View>: View {
    let suggestions: [ChatModelLists.Suggestion]
    /// Whether the learner has edited the list, so Restore Suggested shows.
    let isEdited: Bool
    /// Why some rows cannot be used yet, when they cannot.
    var caption: String? = nil
    let restore: () -> Void
    /// The slug dragged, then the slug of the row it was dropped on.
    let move: (String, String) -> Void
    @ViewBuilder let row: (ChatModelLists.Suggestion, Int) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Models")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if isEdited {
                    Button("Restore Suggested", action: restore)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Put back the suggested and free models this list started with, in their order")
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if suggestions.isEmpty {
                Text("Add a model from the table below: right-click it and choose Add to Your Models.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        row(suggestion, index)
                            .draggable(suggestion.slug)
                            .dropDestination(for: String.self) { dropped, _ in
                                guard let moved = dropped.first, moved != suggestion.slug else { return false }
                                move(moved, suggestion.slug)
                                return true
                            }
                    }
                }
            }
        }
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

        /// The slot whose provider a row sets (`OpenRouterHostPreference`).
        var hostSlotID: String {
            switch self {
            case .chat: return ModelPickerSlot.chat.id
            case .background(let slot): return slot.sharedSlotID
            }
        }
    }

    let entry: AIModelCatalogEntry
    let maker: ChatModelLists.MakerIdentity
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
    /// Taking the model off Settings › Chat's Your Models and moving it
    /// there; nil for a row on no such list.
    var listActions: ListActions? = nil
    let action: () -> Void

    /// What a row on Your Models can do to its place there.
    struct ListActions {
        let remove: () -> Void
        /// Nil for the first row.
        let moveUp: (() -> Void)?
        /// Nil for the last row.
        let moveDown: (() -> Void)?
    }

    @State private var tokensPerSecond: Double?
    @State private var showsHost = false
    @State private var isHovered = false
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
                logoTile
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
            .padding(.vertical, 10)
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
        .onHover { isHovered = $0 }
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
                ChatModelHostButton(entry: entry, slotID: purpose.hostSlotID, isPresented: $showsHost)
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
            if let listActions {
                // Under the pointer only (quiet chrome); always laid out, so
                // the row's text does not shift when it shows.
                Button(action: listActions.remove) {
                    Image(systemName: "xmark")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 4, inset: -1))
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .help("Take \(name) off Your Models")
                .accessibilityLabel("Remove \(name) from Your Models")
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
            ModelBackupMenuItem(backupRank: backupRank, backupsAreFull: backupsAreFull, toggle: toggleBackup)
        }
        if AIModelCatalog.isCustom(entry) {
            Button("Remove from Catalog") {
                AIModelCatalog.removeCustomOpenRouterModel(id: entry.modelID)
            }
            .disabled(isDefault)
        }
        if let listActions {
            Divider()
            Button {
                listActions.moveUp?()
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(listActions.moveUp == nil)
            Button {
                listActions.moveDown?()
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(listActions.moveDown == nil)
            Button {
                listActions.remove()
            } label: {
                Label("Remove from Your Models", systemImage: "text.badge.minus")
            }
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
        return tokens.map(Self.contextLabel(tokens:))
    }

    /// "262k", "1M".
    nonisolated static func contextLabel(tokens: Int) -> String {
        tokens >= 1_000_000 ? "\(tokens / 1_000_000)M" : "\(tokens / 1_000)k"
    }

    /// "Anthropic · $4/$20 · 78 tok/s · 1M". No monospaced digits: tabular
    /// figures pad a narrow "1", which reads as a stray space in "$0.1".
    private var subtitle: Text {
        var parts: [Text] = [Text(maker.name)]
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

    @MainActor
    private func loadSpeed() async {
        guard !isPending else { return }
        await Self.loadSpeed(of: entry) { tokensPerSecond = $0 }
    }

    /// The speed the chat's picker quotes for the model: the cached figure
    /// at once, then OpenRouter's statistics once they arrive. Rows load it
    /// as they scroll into view.
    @MainActor
    static func loadSpeed(of entry: AIModelCatalogEntry, update: (Double?) -> Void) async {
        let speedSlug = Self.speedSlug(of: entry)
        update(OpenRouterModelSpeedCatalog.cachedTokensPerSecond(slug: speedSlug, speed: .standard))
        guard let speeds = try? await OpenRouterModelSpeedCatalog.shared.speeds(for: speedSlug),
              !Task.isCancelled else { return }
        update(OpenRouterModelSpeed.tokensPerSecond(for: .standard, slug: speedSlug, in: speeds))
    }

    /// The slug OpenRouter files the model's speed statistics under.
    static func speedSlug(of entry: AIModelCatalogEntry) -> String {
        AIRequestOptionSupport.openRouterSpeedSlug(
            provider: entry.provider, model: entry.modelID, routingMode: .openRouter
        ) ?? OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID)
    }
}

/// Use as Backup, or Stop Using as Backup, in a model's context menu.
struct ModelBackupMenuItem: View {
    let backupRank: Int?
    let backupsAreFull: Bool
    let toggle: () -> Void

    var body: some View {
        if backupRank != nil {
            Button(action: toggle) {
                Label("Stop Using as Backup", systemImage: "minus.circle")
            }
        } else {
            Button(action: toggle) {
                Label(
                    backupsAreFull ? "Use as Backup (\(AIBackupModels.limit) at most)" : "Use as Backup",
                    systemImage: "arrow.triangle.branch"
                )
            }
            .disabled(backupsAreFull)
        }
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
