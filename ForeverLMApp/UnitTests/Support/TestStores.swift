import CoreGraphics
import CoreText
import Foundation
@testable import ForeverLM

/// Stores the Mac unit tests share. Each call makes a fresh one, so a test
/// never sees another test's rows.
enum TestStores {
    /// An empty store in memory, with the full schema.
    static func inMemory() throws -> KnowledgeStore {
        try KnowledgeStore(inMemory: true)
    }

    /// An MCP store over a fresh temporary directory, and that directory's path (pass it to
    /// `FileManager.removeItem(atPath:)` to clean up). The store is opened against the empty
    /// file, so `createSchema` takes its full creation path and stamps `user_version`: these
    /// tests run on exactly the schema production creates.
    static func mcp() throws -> (MCPDataStore, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: directory.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, directory.path)
    }

    /// An MCP store with its `KnowledgeStore`, and the temporary directory they live in.
    static func mcpWithKnowledge() throws -> (MCPDataStore, KnowledgeStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: directory.appendingPathComponent("knowledge.db").path)
        return (store, try store.knowledgeStore(), directory)
    }
}

/// A view model over a fresh temporary store root.
@MainActor
func makeViewModel() -> StudioViewModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMTests_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return StudioViewModel(storageService: StorageService(storeRoot: root))
}

/// The unit host's defaults are the real ones: a pane change writes the layout
/// template, and opening a Notebook moves the active Notebook. Call this before a
/// test touches either and run the returned closure to put them back.
@MainActor
func capturingSharedDefaults() -> () -> Void {
    let templateKeys = ["studio.centerTabGroups.v1", "studio.navigationRailVisible"]
    let template = templateKeys.map { UserDefaults.standard.object(forKey: $0) }
    let activeNotebookID = ActiveNotebookPreference.notebookID
    return {
        for (key, value) in zip(templateKeys, template) {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        ActiveNotebookPreference.notebookID = activeNotebookID
    }
}

/// Writes (or, for `nil`, removes) one synced preference row, in the property-list
/// form the app stores it in.
func setPreference(_ store: KnowledgeStore, _ key: String, _ value: Any?) throws {
    guard let value else {
        try store.execute("DELETE FROM user_preferences WHERE key = ?", [.text(key)])
        return
    }
    let data = try PropertyListSerialization.data(fromPropertyList: ["v": value], format: .xml, options: 0)
    try store.execute("""
        INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, 1)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
    """, [.text(key), .text(String(decoding: data, as: UTF8.self))])
}

/// The open library is a preference of the app, and tests that open My Library put the
/// app's choice back: call this first and run the returned closure afterwards.
@MainActor
func capturingOpenLibrary() -> () -> Void {
    let saved = UserDefaults.standard.object(forKey: StudioViewModel.activeTeamPreferenceKey)
    return {
        if let saved {
            UserDefaults.standard.set(saved, forKey: StudioViewModel.activeTeamPreferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: StudioViewModel.activeTeamPreferenceKey)
        }
    }
}

/// Draws one line of text at `point` in a PDF context, for the synthetic pages the
/// figure tests build.
func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
    draw(text, at: point, font: "Helvetica", size: size, in: context)
}

func draw(_ text: String, at point: CGPoint, font: String, size: CGFloat, in context: CGContext) {
    context.textPosition = point
    CTLineDraw(
        CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: CTFontCreateWithName(font as CFString, size, nil)]
        )),
        context
    )
}

@discardableResult
func seedSource(
    _ storage: StorageService,
    url: String,
    title: String,
    type: StudioSourceType = .article,
    content: String?
) async throws -> StudioArticle {
    var article = StudioArticle(url: url, title: title, sourceType: type, discoveryOrigin: .manual)
    if let content {
        article.content = content
        article.wordCount = content.split(separator: " ").count
        article.state = .ready
    }
    try await storage.saveSource(article)
    return article
}

@discardableResult
func makeNotebook(_ storage: StorageService, title: String, sourceIDs: [String]) async throws -> LearningGoalRecord {
    try await storage.createCompanionGoal(
        title: title,
        topic: title,
        startAt: Date(),
        endAt: LearningGoalRecord.openEndedEndAt,
        dailyTarget: 3,
        discoveryEnabled: false,
        seedSourceIDs: sourceIDs
    )
}
