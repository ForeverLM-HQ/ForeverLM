import CloudKit
import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Schema 74 stages the one-time refilter of reader documents archived before
/// `ArticleChromeFilter` existed.
@Suite("Article chrome refilter migration")
struct ArticleChromeRefilterTests {

    private static func archivedArticle(
        id: String,
        url: String = "https://example.com/article",
        localPath: String? = nil,
        title: String = "Archived Article"
    ) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: .article, id: id)
        article.localFilePath = localPath ?? "Articles/\(id)/article.html"
        return article
    }

    /// The pre-74 shape is exactly today's minus this one local table, because
    /// that is the entire schema delta.
    private static func makeVersion73Store(at root: URL, populate: (KnowledgeStore) throws -> Void) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        try populate(store)
        try store.clearAllPendingSyncChanges()
        try store.execForTesting("DROP TABLE article_chrome_refilter_queue")
        try store.execForTesting("PRAGMA user_version = 73")
    }

    private static func userVersion(at root: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            root.appendingPathComponent("knowledge.db").path,
            &db,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var version: Int32 = -1
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return version
    }

    @Test("A drained article leaves the queue; a failing one retires after four tries")
    func queueLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-refilter-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.makeVersion73Store(at: root) { store in
            try store.saveSource(Self.archivedArticle(id: "keeps-failing"))
            try store.saveSource(Self.archivedArticle(id: "succeeds"))
        }
        let store = try KnowledgeStore(storeDirectory: root)
        #expect(try store.articleChromeRefilterQueueCount() == 2)

        try store.completeArticleChromeRefilter(sourceID: "succeeds")
        #expect(try store.articleChromeRefilterQueueCount() == 1)

        for attempt in 1...KnowledgeStore.maximumArticleChromeRefilterAttempts {
            try store.recordArticleChromeRefilterFailure(
                sourceID: "keeps-failing",
                message: "HTTP 403 on attempt \(attempt)"
            )
        }
        // Exhausted rows stop being offered rather than retrying forever.
        #expect(try store.articleChromeRefilterQueueCount() == 0)
        #expect(try store.articleChromeRefilterCandidates(limit: 10).isEmpty)

        // The record of what failed stays, so a later build can inspect it.
        var remaining = 0
        var lastError: String?
        try store.query("SELECT COUNT(*), MAX(last_error) FROM article_chrome_refilter_queue") { stmt in
            remaining = Int(sqlite3_column_int64(stmt, 0))
            lastError = store.string(stmt, 1)
        }
        #expect(remaining == 1)
        #expect(lastError?.contains("403") == true)
    }

    @Test("Republishing a reader document clears the digest that would suppress it")
    func republishInvalidatesTheAssetDigest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-refilter-republish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceID = "republished-article"
        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveSource(Self.archivedArticle(id: sourceID))
        let recordName = CloudKitRecordMapper.recordName(for: .source, logicalKey: sourceID)
        try store.stageAssetDigests(
            [CKRecord.FieldKey.sourceReaderHTMLAsset: "stale-digest"],
            recordName: recordName
        )
        try store.commitStagedAssetDigests(recordName: recordName)
        try store.clearAllPendingSyncChanges()
        #expect(try store.committedAssetDigests(recordName: recordName).isEmpty == false)

        try store.republishArticleReaderDocument(sourceID: sourceID)

        // Without clearing the digest the rewritten archive would upload nothing.
        #expect(try store.committedAssetDigests(recordName: recordName)[
            CKRecord.FieldKey.sourceReaderHTMLAsset
        ] == nil)
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .source && $0.logicalKey == sourceID
        })
    }
}
