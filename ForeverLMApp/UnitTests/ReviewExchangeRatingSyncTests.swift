import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The thumbs left the chat footer and the question calibration they fed was
/// retired (2026-09-27), but the ratings older builds made stay on their
/// exchanges (schema 93) and keep round-tripping inside the ReviewSession
/// payload, keyed on `rated_at`. What this pins is that nothing here blanks
/// them, and that the calibration's synced leftover is cleared once.
@Suite("Review exchange rating sync")
struct ReviewExchangeRatingSyncTests {

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-exchange-rating-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func userVersion(at root: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            root.appendingPathComponent("knowledge.db").path, &db, SQLITE_OPEN_READONLY, nil
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

    /// A chat with one asked-and-answered exchange, as the review writes it.
    private static func addReviewExchange(_ store: KnowledgeStore, sessionID: String) throws {
        _ = try store.addReviewPrompt(
            sessionID: sessionID,
            question: "Why must the biomarker be causal rather than correlated?",
            sourceRefs: []
        )
        _ = try store.answerPendingReviewExchange(
            sessionID: sessionID,
            answer: "Otherwise lowering it does not lower the risk.",
            evaluation: "Correct. A correlated marker can move without the disease moving.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: []
        )
    }

    /// `exchange` as another device sends it: with the rating unit it
    /// carries, or with none at all, as a client that cannot carry one does.
    private static func exchange(
        _ exchange: CloudKitReviewExchangePayload,
        rating: String? = nil,
        reason: String? = nil,
        field: String? = nil,
        ratedAt: Date? = nil
    ) -> CloudKitReviewExchangePayload {
        CloudKitReviewExchangePayload(
            id: exchange.id, sessionID: exchange.sessionID, sequenceNumber: exchange.sequenceNumber,
            question: exchange.question, userAnswer: exchange.userAnswer, evaluation: exchange.evaluation,
            score: exchange.score, sourceRefs: exchange.sourceRefs, knowledgeNote: exchange.knowledgeNote,
            answeredAt: exchange.answeredAt, contextContent: exchange.contextContent,
            rating: rating, ratingReason: reason, ratingField: field, ratedAt: ratedAt
        )
    }

    private static func session(
        _ payload: CloudKitReviewSessionPayload,
        exchanges: [CloudKitReviewExchangePayload]
    ) -> CloudKitReviewSessionPayload {
        CloudKitReviewSessionPayload(
            id: payload.id, topic: payload.topic, startedAt: payload.startedAt, endedAt: payload.endedAt,
            status: payload.status, overallScore: payload.overallScore, summary: payload.summary,
            sourceIDs: payload.sourceIDs, cardIDs: payload.cardIDs, exchangeCount: payload.exchangeCount,
            modelProvider: payload.modelProvider, modelID: payload.modelID, goalID: payload.goalID,
            exchanges: exchanges, sourceIdentities: payload.sourceIdentities
        )
    }

    @Test("An inbound rating is kept and sent back out; a payload with no rated_at leaves it alone")
    func inboundRatingSemantics() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        try store.createReviewSession(id: "chat-1", topic: "Prevention", sourceIDs: [])
        try Self.addReviewExchange(store, sessionID: "chat-1")
        let outbound = try #require(try store.loadReviewSessionForSync("chat-1"))
        let ratedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

        // An older build rated the tutor's reply.
        try store.saveReviewSessionRecord(Self.session(outbound, exchanges: outbound.exchanges.map {
            Self.exchange($0, rating: "liked", reason: "Clear", field: "evaluation", ratedAt: ratedAt)
        }))
        let stored = try #require(try store.loadReviewSessionExchanges(sessionID: "chat-1").last)
        #expect(stored.rating == .liked)
        #expect(stored.ratingField == .evaluation)
        #expect(stored.ratingReason == "Clear")

        // This build sends the session on with the unit intact.
        let resent = try #require(try store.loadReviewSessionForSync("chat-1")?.exchanges.last)
        #expect(resent.rating == "liked")
        #expect(resent.ratingField == "evaluation")
        #expect(resent.ratingReason == "Clear")
        #expect(resent.ratedAt.map { abs($0.timeIntervalSince(ratedAt)) < 1 } == true)

        // A client that carries no rating round-trips the session.
        try store.saveReviewSessionRecord(Self.session(outbound, exchanges: outbound.exchanges.map {
            Self.exchange($0)
        }))
        #expect(try store.loadReviewSessionExchanges(sessionID: "chat-1").last?.rating == .liked)

        // The older build took the thumb back: rating nil, rated_at newer.
        let later = ratedAt.addingTimeInterval(60)
        try store.saveReviewSessionRecord(Self.session(outbound, exchanges: outbound.exchanges.map {
            Self.exchange($0, ratedAt: later)
        }))
        let cleared = try #require(try store.loadReviewSessionExchanges(sessionID: "chat-1").last)
        #expect(cleared.rating == nil)
        #expect(cleared.ratingReason == nil)
        #expect(cleared.ratedAt.map { abs($0.timeIntervalSince(later)) < 1 } == true)

        // And a fresh thumb from there replaces the whole unit.
        try store.saveReviewSessionRecord(Self.session(outbound, exchanges: outbound.exchanges.map {
            Self.exchange($0, rating: "disliked", reason: "Too easy", field: "question", ratedAt: later)
        }))
        let replaced = try #require(try store.loadReviewSessionExchanges(sessionID: "chat-1").last)
        #expect(replaced.rating == .disliked)
        #expect(replaced.ratingField == .question)
        #expect(replaced.ratingReason == "Too easy")
    }

    // MARK: - The retired calibration

    @Test("The retired calibration is cleared once, as a synced deletion, and stays out of sync")
    func retiredCalibrationClearsOnce() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ReviewExchangeRatingSyncTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = RetiredQuestionCalibration.preferenceKey
        #expect(key == "review.questionCalibration.v1")
        #expect(!SyncedPreferenceKeys.isSynced(key))
        #expect(!SyncedPreferenceKeys.isSynced(RetiredQuestionCalibration.clearedKey))

        // The one value seen in the wild, as the pass stored it.
        let json = #"{"version":1,"good":[],"bad":[],"guidance":["Do not include images when they are not relevant."],"ratingsFingerprint":"f","updatedAt":0}"#
        let xml = try #require(PreferenceStore.encodePlist(json))
        let store = try KnowledgeStore(storeDirectory: root)
        try store.writePreference(key: key, valuePlistXML: xml)
        defaults.set(json, forKey: key)

        let storage = StorageService(storeRoot: root)
        await RetiredQuestionCalibration.clearOnce(storage: storage, defaults: defaults)
        #expect(try store.loadAllPreferences()[key] == nil)
        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.bool(forKey: RetiredQuestionCalibration.clearedKey))

        // Once only: a copy an older Mac writes back afterwards is left alone.
        try store.writePreference(key: key, valuePlistXML: xml)
        await RetiredQuestionCalibration.clearOnce(storage: storage, defaults: defaults)
        #expect(try store.loadAllPreferences()[key] != nil)
    }

    @Test("A library that never had a calibration is marked cleared")
    func retiredCalibrationAbsentQueuesNothing() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ReviewExchangeRatingSyncTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        await RetiredQuestionCalibration.clearOnce(storage: StorageService(storeRoot: root), defaults: defaults)
        #expect(defaults.bool(forKey: RetiredQuestionCalibration.clearedKey))
    }
}
