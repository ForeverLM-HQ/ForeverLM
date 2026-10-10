import Foundation
import Testing
@testable import ForeverLM

/// Jobs, a stand-in for the Mac's import paths and a runner over one store, for WP14's suites
/// (docs/cloudkit-schema-design.md §3.5.28, §5.4): a Job as a light client writes one, and the work
/// `MacJobRunner` hands the Mac, recorded so a suite can tell what ran where.
enum JobSyncFixture {
    typealias F = NotebookSyncFixture

    /// A Job record as the iPhone or the web writes one (`writeJob`): queued, requested now, kept 7 days.
    static func jobRecord(_ id: String, kind: String, target: String? = nil, params: [String: SyncJSON],
                          zoneKey: String = F.libraryZoneKey) throws -> ReplicaRecord {
        let requested = SyncTime.milliseconds(Date())
        var fields: [String: SyncJSON] = [
            "kind": .string(kind), "params": .object(params), "status": .string("queued"),
            "requestedBy": .object(["device": .string("iphoneaa"), "platform": .string("ios")]),
            "requestedAt": SyncJSON(requested), "expiresAt": SyncJSON(requested + 7 * 86_400_000),
        ]
        if let target { fields["target"] = .string(target) }
        return try F.record(.job, id, fields, zoneKey: zoneKey, device: "iphoneaa")
    }

    /// A PDF as a phone uploads it (D47): its bytes, their hash and the FileRef owned by the file's id.
    static func phonePDF(_ text: String = "%PDF-1.4 a scanned page") -> (bytes: Data, sha: String, file: FileRef) {
        let bytes = Data(text.utf8)
        let sha = SyncIdentity.sha256Hex(bytes)
        let file = FileRef(owner: SourceIdentity.fileID(sha256: sha), role: "pdf", hash: sha, size: Int64(bytes.count),
                           mime: "application/pdf", encoding: BlobStore.Encoding.identity.rawValue, storedParts: [bytes])
        return (bytes, sha, file)
    }

    /// A runner over `store`, its bodies run one at a time on the calling task, as `MacPrivateSyncStore.direct`
    /// runs them.
    static func runner(_ store: KnowledgeStore, work: FakeJobWork, now: @escaping @Sendable () -> Date = { Date() }) -> MacJobRunner {
        let lock = NSRecursiveLock()
        return MacJobRunner(store: { body in try lock.withLock { try body(store) } }, work: work, now: now,
                            scratch: FileManager.default.temporaryDirectory.appendingPathComponent("WP14-jobs-\(UUID().uuidString)"))
    }

    /// Waits for a Job the runner started to settle on this device.
    static func settled(_ store: KnowledgeStore, _ id: String) async throws -> String? {
        for _ in 0..<500 {
            let status = try store.scalarText("SELECT status FROM jobs WHERE id = ?", [.text(id)])
            if status != "running" { return status }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return "running"
    }
}

/// The Mac's import paths, standing in: a link becomes an article, a file a paper, and every call is
/// recorded. Imports write through the store's own insert, so lookup before mint and work keys behave
/// as the app's do under generation 2.
final class FakeJobWork: MacJobWork, @unchecked Sendable {
    private let lock = NSLock()
    private let store: KnowledgeStore
    private var files: [String: Data] = [:]
    private(set) var calls: [String] = []

    init(store: KnowledgeStore) {
        self.store = store
    }

    func holds(_ bytes: Data, for file: FileRef) {
        lock.withLock { files[file.hash] = bytes }
    }

    private func record(_ call: String) {
        lock.withLock { calls.append(call) }
    }

    var recorded: [String] { lock.withLock { calls } }

    func importLink(_ url: String) async throws -> String? {
        record("importLink \(url)")
        var article = StudioArticle(url: url, title: "Fetched page", sourceType: .article)
        _ = try store.insertSourceIfNew(&article)
        return article.id
    }

    func importFile(at file: URL, kind: JobFileKind, title: String?, asBook: Bool) async throws -> String? {
        record("importFile \(kind.rawValue) \(try Data(contentsOf: file).count)")
        var article = StudioArticle(url: file.path, title: title ?? "Imported", sourceType: .paper, localFilePath: file.path)
        _ = try store.insertSourceIfNew(&article)
        return article.id
    }

    func fetchContent(sourceID: String) async throws {
        record("fetchContent \(sourceID)")
    }

    func attachFile(at file: URL, kind: JobFileKind, toSource sourceID: String) async throws {
        record("attachFile \(kind.rawValue) \(sourceID)")
    }

    func callTool(_ name: String, arguments: [String: SyncJSON]) async -> (text: String, isError: Bool) {
        record("callTool \(name)")
        return ("Done: \(name).", false)
    }

    func bytes(of file: FileRef) async throws -> Data {
        guard let bytes = lock.withLock({ files[file.hash] }) else { throw MacJobRunner.Failure(message: "not uploaded") }
        return bytes
    }

    func runAutomation(_ id: String) async throws {
        record("runAutomation \(id)")
    }

    func drawNotebookCover(notebookID: String) async throws -> String {
        record("drawNotebookCover \(notebookID)")
        return "Drew the notebook's cover."
    }

    func libraryDidChange() async {}
}
