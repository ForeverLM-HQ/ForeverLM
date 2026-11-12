import AppIntents
import CoreSpotlight
import Foundation
import SQLite3
import SwiftUI

// Siri AI / Apple Intelligence integration for the macOS app.
//
// The rebuilt Siri (macOS 27+) reaches third-party apps exclusively through
// App Intents: entities donated to Spotlight's semantic index give Siri
// personal context ("open my thermodynamics paper in ForeverLM"), and the
// intents below let it act. Everything also works as plain Shortcuts and
// classic Siri phrases on macOS 14–26; the semantic-index donation is the
// macOS 15+ booster, mirroring the iOS companion's SourceEntity setup
// in iOS/MobileSourceAppEntity.swift.
//
// Entity queries read knowledge.db directly in read-only mode: they can run
// while the app is launching in the background for an intent, so they must
// never create the database or contend with the main actor.

// MARK: - Intents → UI notifications

extension Notification.Name {
    /// Posted by Siri intents to open a source reader window.
    /// userInfo[SiriSourceNavigation.sourceIDKey] selects the source.
    static let openSourceReader = Notification.Name("openSourceReader")

    /// Posted by Siri's Open Notebook intent to open one notebook in the
    /// Studio window in front. userInfo[SiriNotebookNavigation.notebookIDKey]
    /// names it.
    static let openStudioNotebook = Notification.Name("openStudioNotebook")

    /// Posted by the View menu's Space (⌘P) and Siri's Show Notebooks intent:
    /// the Space's All list, where every notebook is listed, in the Studio
    /// window in front.
    static let openStudioSpace = Notification.Name("openStudioSpace")

    /// Posted by the Today menu and the "Plan your day?" notification: open
    /// the chat that plans the day into the Mac's Calendar, in the Studio
    /// window in front.
    static let requestPlanTheDayChat = Notification.Name("requestPlanTheDayChat")
}

enum SiriSourceNavigation {
    static let sourceIDKey = "sourceID"
}

enum SiriNotebookNavigation {
    static let notebookIDKey = "notebookID"
}

// MARK: - Read-only catalog over knowledge.db

struct SiriSourceItem: Sendable {
    let id: String
    let title: String
    let author: String?
    let domain: String?
    let sourceType: String
    let groupTitle: String?
}

struct SiriNotebookItem: Sendable {
    let id: String
    let title: String
    let status: String
}

enum SiriCatalogError: Error {
    case databaseUnavailable(String)
}

enum SiriKnowledgeCatalog {
    static func loadSources() throws -> [SiriSourceItem] {
        try withReadOnlyDB { db in
            let sql = """
                SELECT id, title, author, domain, source_type,
                       COALESCE(parent_group_title, '') AS group_title
                FROM source_projection
                WHERE COALESCE(is_hidden, 0) = 0
                  AND (archived_at IS NULL OR archived_at = '')
                  AND title IS NOT NULL AND TRIM(title) <> ''
                ORDER BY date_added DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SiriCatalogError.databaseUnavailable(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            var items: [SiriSourceItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = text(stmt, 0), let title = text(stmt, 1) else { continue }
                items.append(SiriSourceItem(
                    id: id,
                    title: title,
                    author: text(stmt, 2),
                    domain: text(stmt, 3),
                    sourceType: text(stmt, 4) ?? "article",
                    groupTitle: text(stmt, 5)
                ))
            }
            return items
        }
    }

    static func loadNotebooks() throws -> [SiriNotebookItem] {
        try withReadOnlyDB { db in
            let sql = """
                SELECT id, title, status
                FROM learning_goals
                WHERE kind = 'companion'
                ORDER BY updated_at DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SiriCatalogError.databaseUnavailable(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            var items: [SiriNotebookItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = text(stmt, 0), let title = text(stmt, 1) else { continue }
                items.append(SiriNotebookItem(id: id, title: title, status: text(stmt, 2) ?? "active"))
            }
            return items
        }
    }

    /// Resolve only exact normalized metadata values. Semantic discovery belongs
    /// to Spotlight; this fallback must never guess which stored record was meant.
    static func rank(_ query: String, in items: [SiriSourceItem], limit: Int) -> [SiriSourceItem] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return Array(items.prefix(limit)) }
        return items.filter { item in
            [item.title, item.author, item.domain, item.groupTitle]
                .compactMap { $0 }
                .contains { normalize($0) == normalizedQuery }
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        let value = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func withReadOnlyDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let path = MCPDataStore().knowledgeDBPath
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SiriCatalogError.databaseUnavailable(message)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }
}

// MARK: - View Annotations (Siri on-screen awareness)

/// Activity types that carry an on-screen entity to Siri. Both are declared in
/// `NSUserActivityTypes`; an undeclared type is silently never advertised.
enum SiriEntityActivity {
    static let source = "com.foreverlm.viewing-source"
    static let notebook = "com.foreverlm.viewing-notebook"
}

extension View {
    /// Tags a view with the source it displays so Siri resolves on-screen
    /// references like "summarize this" or "quiz me on this".
    ///
    /// The entity travels on an advertised `NSUserActivity` — that is the only
    /// mechanism App Intents offers for this. There is no `View`-level
    /// annotation modifier; `appEntityIdentifier` is a property of
    /// `AppEntityAnnotatable`, which `NSUserActivity` conforms to (macOS 15.2+).
    @ViewBuilder
    func siriSourceAnnotation(_ sourceID: String?) -> some View {
        if #available(macOS 15.2, *) {
            userActivity(
                SiriEntityActivity.source,
                isActive: sourceID != nil,
                { activity in
                    activity.appEntityIdentifier = sourceID.map {
                        EntityIdentifier(for: StudioSourceEntity.self, identifier: $0)
                    }
                }
            )
        } else {
            self
        }
    }

    /// Tags a view with the Notebook it displays.
    @ViewBuilder
    func siriNotebookAnnotation(_ notebookID: String?) -> some View {
        if #available(macOS 15.2, *) {
            userActivity(
                SiriEntityActivity.notebook,
                isActive: notebookID != nil,
                { activity in
                    activity.appEntityIdentifier = notebookID.map {
                        EntityIdentifier(for: StudioNotebookEntity.self, identifier: $0)
                    }
                }
            )
        } else {
            self
        }
    }
}

// MARK: - Source entity

struct StudioSourceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Source")
    static let defaultQuery = StudioSourceQuery()

    let id: String
    let title: String
    let subtitle: String?
    let sourceType: String

    var displayRepresentation: DisplayRepresentation {
        if let subtitle, !subtitle.isEmpty {
            return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
        }
        return DisplayRepresentation(title: "\(title)")
    }

    init(item: SiriSourceItem) {
        self.id = item.id
        self.title = item.title
        // Chapters surface their book so Siri disambiguation reads naturally.
        self.subtitle = item.groupTitle ?? item.author ?? item.domain
        self.sourceType = item.sourceType
    }
}

// The Spotlight semantic index (IndexedEntity) is macOS 15+. The entity still
// resolves on macOS 14 through the string query below; this conformance adds
// the meaning-based matching the new Siri leans on.
@available(macOS 15.0, *)
extension StudioSourceEntity: IndexedEntity {}

struct StudioSourceQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StudioSourceEntity] {
        let byID = Dictionary(
            (try SiriKnowledgeCatalog.loadSources()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { byID[$0] }.map(StudioSourceEntity.init(item:))
    }

    func entities(matching string: String) async throws -> [StudioSourceEntity] {
        let sources = try SiriKnowledgeCatalog.loadSources()
        return SiriKnowledgeCatalog.rank(string, in: sources, limit: 20)
            .map(StudioSourceEntity.init(item:))
    }

    func suggestedEntities() async throws -> [StudioSourceEntity] {
        (try SiriKnowledgeCatalog.loadSources())
            .prefix(30)
            .map(StudioSourceEntity.init(item:))
    }
}

// MARK: - Notebook entity

struct StudioNotebookEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Notebook")
    static let defaultQuery = StudioNotebookQuery()

    let id: String
    let title: String
    let status: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(item: SiriNotebookItem) {
        self.id = item.id
        self.title = item.title
        self.status = item.status
    }
}

struct StudioNotebookQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StudioNotebookEntity] {
        let byID = Dictionary(
            (try SiriKnowledgeCatalog.loadNotebooks()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { byID[$0] }.map(StudioNotebookEntity.init(item:))
    }

    func entities(matching string: String) async throws -> [StudioNotebookEntity] {
        let needle = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return (try SiriKnowledgeCatalog.loadNotebooks())
            .filter {
                $0.title
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .contains(needle)
            }
            .map(StudioNotebookEntity.init(item:))
    }

    func suggestedEntities() async throws -> [StudioNotebookEntity] {
        (try SiriKnowledgeCatalog.loadNotebooks())
            .filter { $0.status == "active" }
            .prefix(20)
            .map(StudioNotebookEntity.init(item:))
    }
}

// MARK: - Intents

enum SiriIntentError: Error, CustomLocalizedStringResourceConvertible {
    case invalidSource

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidSource:
            return "That source could not be opened."
        }
    }
}

struct OpenSourceIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Source"
    static let description = IntentDescription(
        "Opens a source from your ForeverLM knowledge base in a reader window.",
        categoryName: "Studio"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Source")
    var source: StudioSourceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$source)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SiriIntentError.invalidSource
        }
        NotificationCenter.default.post(
            name: .openSourceReader,
            object: nil,
            userInfo: [SiriSourceNavigation.sourceIDKey: source.id]
        )
        return .result()
    }
}

struct OpenNotebookIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Notebook"
    static let description = IntentDescription(
        "Opens a notebook in ForeverLM.",
        categoryName: "Studio"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Notebook")
    var notebook: StudioNotebookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$notebook)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .openStudioNotebook,
            object: nil,
            userInfo: [SiriNotebookNavigation.notebookIDKey: notebook.id]
        )
        return .result()
    }
}

struct OpenNotebooksIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Notebooks"
    static let description = IntentDescription(
        "Opens the ForeverLM Space, where every notebook is listed.",
        categoryName: "Studio"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .openStudioSpace, object: nil)
        return .result()
    }
}

// MARK: - App Shortcuts (Siri phrases)

struct ForeverLMMacAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSourceIntent(),
            phrases: [
                "Open \(\.$source) in \(.applicationName)",
                "Show \(\.$source) in \(.applicationName)",
                "Read \(\.$source) in \(.applicationName)"
            ],
            shortTitle: "Open Source",
            systemImageName: "doc.text"
        )

        AppShortcut(
            intent: OpenNotebooksIntent(),
            phrases: [
                "Show my notebooks in \(.applicationName)"
            ],
            shortTitle: "Notebooks",
            systemImageName: "map"
        )
    }
}

// MARK: - Spotlight semantic-index donation

/// Donates the source catalog to Spotlight's semantic index so the new Siri
/// resolves meaning-based references. Runs entirely off the main actor: once
/// shortly after launch, then debounced after `.foreverLMDataDidChange`
/// (posted whenever the assistant or an MCP client mutates persisted state).
@available(macOS 15.0, *)
final class SiriSpotlightDonationCoordinator: @unchecked Sendable {
    static let shared = SiriSpotlightDonationCoordinator()

    private let lock = AppLock()
    private var started = false
    private var pendingDonation: Task<Void, Never>?

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        NotificationCenter.default.addObserver(
            forName: .foreverLMDataDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.scheduleDonation(after: .seconds(8))
        }
        scheduleDonationLocked(after: .seconds(6))
    }

    private func scheduleDonation(after delay: Duration) {
        lock.lock()
        defer { lock.unlock() }
        scheduleDonationLocked(after: delay)
    }

    private func scheduleDonationLocked(after delay: Duration) {
        pendingDonation?.cancel()
        pendingDonation = Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await Self.donate()
        }
    }

    private static func donate() async {
        guard let sources = try? SiriKnowledgeCatalog.loadSources(), !sources.isEmpty else { return }
        do {
            try await CSSearchableIndex.default().indexAppEntities(sources.map(StudioSourceEntity.init(item:)))
        } catch {
            // Discoverability booster only — a failed donation never surfaces as an app error.
            NSLog("ForeverLM: Siri Spotlight donation failed: \(error.localizedDescription)")
        }
        // Refresh parameterized App Shortcut phrases with the current catalog.
        ForeverLMMacAppShortcuts.updateAppShortcutParameters()
    }
}
