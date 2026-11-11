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
