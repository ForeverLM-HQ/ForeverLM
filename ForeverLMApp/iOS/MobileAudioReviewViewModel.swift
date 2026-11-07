import AVFoundation
import Combine
import CryptoKit
import MediaPlayer
import OSLog
import SwiftUI
import CloudKit
import SQLite3
import WidgetKit

/// The alerts the phone raises on its own schedule, and the order in which they
/// are allowed on screen.
///
/// UIKit runs one alert transition at a time. When a second `.alert` flips true
/// while the first is still animating, the running transition resolves a
/// context whose view controller is no longer an alert, and UIKit aborts the
/// process instead of queueing: "A view controller not containing an alert
/// controller was asked for its contained alert controller." That abort is a
/// SIGABRT on the main thread, indistinguishable from a launch crash when it
/// lands during the first load.
///
/// The dialogs a learner opens by hand cannot collide — that would take two
/// taps in one runloop turn. These three can, because each is raised by work
/// finishing rather than by a tap: a text-to-speech that has priced itself, a book
/// that has run out, an offline save that failed. Two of them landing together
/// is ordinary, not exotic — a bulk offline save that fails for several sources
/// raises one per failing row at once.
///
/// So they queue. `resolve` names the single alert allowed on screen; the
/// others keep their state and take their turn as each is dismissed. Every
/// asynchronous alert on iOS must bind its presentation through here — a new
/// one that presents on its own terms reintroduces the crash.
enum MobileAsyncAlert: Equatable {
    /// A text-to-speech waiting for the learner to approve what it will cost.
    case textToSpeechCost
    /// The offer to keep playing through a finished book.
    case bookContinuation
    /// A failed offline save, reported on the row it belongs to.
    case offlineSaveFailure(sourceID: String)

    /// The alert that may present, given everything currently pending.
    ///
    /// Priority runs in declaration order: spending the learner's money is
    /// asked first, and a failure notice — which loses nothing by waiting,
    /// since it stays pending until dismissed — is asked last. Callers pass
    /// only what they can see; an omitted input is simply not pending, which is
    /// safe because nothing outranks an alert that a caller cannot observe.
    static func resolve(
        textToSpeechCostPending: Bool = false,
        bookContinuationPending: Bool = false,
        offlineFailureSourceID: String? = nil
    ) -> MobileAsyncAlert? {
        if textToSpeechCostPending { return .textToSpeechCost }
        if bookContinuationPending { return .bookContinuation }
        if let sourceID = offlineFailureSourceID { return .offlineSaveFailure(sourceID: sourceID) }
        return nil
    }
}

private enum AutomaticAudioConstraintControl: Error {
    case noConstraints
}

private enum MobileAutomaticAudioConstraintMatcher {
    static func matchingIDs(
        constraint: String,
        candidates: [SourceAudioAutomation.FilterCandidate],
        route: ResolvedAITextRoute
    ) async throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        var result = Set<String>()
        for start in stride(from: 0, to: candidates.count, by: 180) {
            let batch = Array(candidates[start..<min(start + 180, candidates.count)])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(batch)
            guard let json = String(data: payload, encoding: .utf8) else {
                throw MobileSourceChatError.badResponse("Automatic audio metadata could not be encoded.")
            }
            let request = try MobileOpenRouterChat.request(
                route: route,
                system: Prompts.automaticAudioFiltering,
                messages: [(role: "user", content: "Rule: \(constraint)\n\nSources:\n\(json)")],
                maxTokens: min(8_000, max(300, batch.count * 24)),
                jsonMode: true
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw MobileSourceChatError.badResponse("Automatic audio filter request failed.")
            }
            let parsed = try MobileOpenRouterChat.text(from: data)
            try MobileOpenRouterChat.requireSelectedModel(parsed.json, route: route)
            guard let first = parsed.text.firstIndex(of: "{"),
                  let last = parsed.text.lastIndex(of: "}"),
                  let responseData = String(parsed.text[first...last]).data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let ids = object["matching_ids"] as? [String] else {
                throw MobileSourceChatError.badResponse("Automatic audio filter returned invalid JSON.")
            }
            let allowed = Set(batch.map(\.id))
            guard ids.allSatisfy(allowed.contains) else {
                throw MobileSourceChatError.badResponse("Automatic audio filter returned an unknown source.")
            }
            result.formUnion(ids)
        }
        return result
    }
}

struct MobileAudioItem: Identifiable, Equatable {
    let manifest: SyncedArticleAudioManifest

    var id: String { manifest.sourceID }
    var title: String { manifest.title }
    var subtitle: String? { manifest.subtitle }
    var createdAt: Date { manifest.createdAt }
    var providerLabel: String { manifest.provider.capitalized }
}

/// Concrete text-to-speech generation state for the iPhone's progress surfaces.
/// A chunk is one bounded speech request group; split retries stay within that
/// group so progress never jumps backwards when a provider rejects long text.
struct MobileTextToSpeechGenerationProgress: Equatable {
    let completedChunks: Int
    let totalChunks: Int
    let startedAt: Date
    /// The catalog name of the model narrating — the resolved one, which a
    /// language substitution may have chosen over the Settings pick.
    let modelName: String

    init(completedChunks: Int, totalChunks: Int, startedAt: Date, model: String) {
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.startedAt = startedAt
        self.modelName = ArticleSpeechCatalog.model(id: model)?.name ?? model
    }

    var fractionCompleted: Double {
        guard totalChunks > 0 else { return 0 }
        return min(max(Double(completedChunks) / Double(totalChunks), 0), 1)
    }

    var percentCompleted: Int {
        Int((fractionCompleted * 100).rounded())
    }

    func estimatedRemaining(at date: Date) -> TimeInterval? {
        guard completedChunks > 0, completedChunks < totalChunks else { return nil }
        let elapsed = max(date.timeIntervalSince(startedAt), 0)
        return (elapsed / Double(completedChunks)) * Double(totalChunks - completedChunks)
    }
}

/// A narration coming down from iCloud for the iPhone's progress surfaces.
/// Its remedy is different from generation's — wait, or find better Wi-Fi —
/// so the UI names it apart, with the count that tells the listener how far
/// the phone is from having the whole chapter.
struct MobileNarrationDownloadProgress: Equatable {
    let title: String
    let readyChunks: Int
    let contiguousChunks: Int
    let totalChunks: Int
    let startedAt: Date
    /// True once the chunks that have arrived are already playing.
    let isPlayingPrefix: Bool

    var fractionCompleted: Double {
        guard totalChunks > 0 else { return 0 }
        return min(max(Double(readyChunks) / Double(totalChunks), 0), 1)
    }

    var percentCompleted: Int {
        Int((fractionCompleted * 100).rounded())
    }

    func estimatedRemaining(at date: Date) -> TimeInterval? {
        guard readyChunks > 0, readyChunks < totalChunks else { return nil }
        let elapsed = max(date.timeIntervalSince(startedAt), 0)
        return (elapsed / Double(readyChunks)) * Double(totalChunks - readyChunks)
    }

    /// The one line a banner shows: what is happening, how far it is, and how
    /// long is left once there is enough history to say.
    func statusLabel(at date: Date) -> String {
        var parts: [String] = [isPlayingPrefix ? "Playing · downloading the rest" : "Downloading narration"]
        parts.append("\(readyChunks) of \(totalChunks) chunks")
        parts.append("\(percentCompleted)%")
        if let remaining = estimatedRemaining(at: date) {
            parts.append(MobileNarrationDownloadProgress.formatDuration(remaining))
        }
        return parts.joined(separator: " · ")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let rounded = max(1, Int(seconds.rounded(.up)))
        if rounded < 60 { return "\(rounded)s left" }
        let minutes = rounded / 60
        let remainder = rounded % 60
        if minutes < 60 {
            return remainder == 0 ? "\(minutes)m left" : "\(minutes)m \(remainder)s left"
        }
        return "\(minutes / 60)h \(minutes % 60)m left"
    }
}

enum MobileTextToSpeechPricingPreferences {
    /// Device-local presentation preference. Automatic generation remains an
    /// explicit Settings opt-in and never blocks on a modal confirmation.
    static let confirmsEstimatedCostKey = "ios.readAloud.confirmsEstimatedCost"

    static var confirmsEstimatedCost: Bool {
        (UserDefaults.standard.object(forKey: confirmsEstimatedCostKey) as? Bool) ?? true
    }
}

/// The price disclosure shown before an uncached, user-initiated narration.
/// Rates are estimates from the app's versioned speech table; the managed
/// ledger remains the exact charge and is visible in Usage.
struct MobileTextToSpeechCostConfirmation: Identifiable, Equatable {
    /// The book a chapter belongs to, when playback will carry on through it.
    /// Continuing to the next chapter generates it without asking again, so the
    /// price quoted here has to be the book's, not this chapter's.
    struct BookScope: Equatable {
        let title: String
        /// Chapters after this one that still have no audio on the phone.
        let remainingChapters: Int
        /// Narration characters for those chapters, sized from their word
        /// counts against the ratio this chapter's own narration measured.
        let remainingCharacters: Int
    }

    let id = UUID()
    let sourceID: String
    let sourceTitle: String
    let modelName: String
    let modelID: String
    let characterCount: Int
    let book: BookScope?
    /// What the language check found, when it found anything: the source is
    /// not in a language the selected voice speaks. It leads the message
    /// because it decides whether the audio is worth any price at all.
    let languageNotice: String?

    init(
        sourceID: String,
        sourceTitle: String,
        characterCount: Int,
        modelID: String,
        languageNotice: String? = nil,
        book: BookScope? = nil
    ) {
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.characterCount = characterCount
        self.modelID = modelID
        self.languageNotice = languageNotice
        self.book = book
        modelName = ArticleSpeechCatalog.model(id: modelID)?.name ?? modelID
    }

    /// This chapter alone.
    var chapterEstimate: ArticleSpeechCostEstimate {
        ArticleSpeechCostEstimate(
            characters: characterCount,
            provider: ArticleSpeechCatalog.provider,
            model: modelID
        )
    }

    /// Everything the listener is agreeing to: this chapter plus the rest of
    /// the book when there is one.
    var totalEstimate: ArticleSpeechCostEstimate {
        guard let book else { return chapterEstimate }
        return chapterEstimate.adding(
            ArticleSpeechCostEstimate(
                characters: book.remainingCharacters,
                sourceCount: book.remainingChapters,
                provider: ArticleSpeechCatalog.provider,
                model: modelID
            )
        )
    }

    var estimatedUSD: Double? { totalEstimate.usd }

    var title: String {
        guard let estimatedUSD else { return "Generate text-to-speech audio?" }
        if estimatedUSD == 0 { return "Generate audio for free?" }
        if book != nil { return "Generate the whole book for about \(Self.priceLabel(estimatedUSD))?" }
        return "Generate audio for about \(Self.priceLabel(estimatedUSD))?"
    }

    var message: String {
        var parts: [String] = []
        if let languageNotice { parts.append(languageNotice) }
        parts.append(sourceTitle)
        if let book {
            let total = totalEstimate
            parts.append(modelName)
            parts.append("This chapter · \(Self.lengthLabel(chapterEstimate))")
            parts.append(
                "\(book.title) · \(total.sourceCount.formatted()) chapters · \(Self.lengthLabel(total))"
            )
            parts.append("Continuing to the next chapter generates it without asking again.")
        } else {
            parts.append("\(modelName) · \(Self.lengthLabel(chapterEstimate))")
        }
        if estimatedUSD == nil {
            parts.append("An estimate is unavailable. The exact charge will appear in Usage.")
        }
        if estimatedUSD == 0 {
            parts.append("This model is free; cached audio is free to replay.")
        } else {
            parts.append("Retries can add cost; cached audio is free to replay.")
        }
        return parts.joined(separator: "\n")
    }

    /// "24,000 characters · about 32 min · 36¢". Money follows the phone's
    /// house unit (cents below a dollar), not the Mac's always-dollars label.
    private static func lengthLabel(_ estimate: ArticleSpeechCostEstimate) -> String {
        var parts = [
            "\(estimate.characters.formatted()) characters",
            estimate.durationLabel,
        ]
        if let usd = estimate.usd, usd > 0 {
            parts.append(priceLabel(usd))
        }
        return parts.joined(separator: " · ")
    }

    private static func priceLabel(_ usd: Double) -> String {
        MobileCostFormat.money(microUSD: Int((usd * 1_000_000).rounded()))
    }
}

private struct MobilePreparedTextToSpeechNarration {
    let text: String
    let sourceContentSignature: String?
    let preparationSignature: String?
}

extension Notification.Name {
    static let mobileListeningCatalogDidChange = Notification.Name("MobileListeningCatalogDidChange")
}

struct MobileSourceSyncDiagnostic: Equatable {
    let accountStatus: String
    let knowledgeZoneStatus: String
    let sourceRecordCount: Int?
    let decodedSourceCount: Int?
    let zoneRecordCount: Int?
    let zoneRecordTypes: String?
    let errorMessage: String?
    let checkedAt: Date

    var lines: [String] {
        var values = [
            "iCloud account: \(accountStatus)",
            "Knowledge zone: \(knowledgeZoneStatus)",
        ]
        if let sourceRecordCount {
            values.append("Source records: \(sourceRecordCount)")
        }
        if let decodedSourceCount {
            values.append("Decoded sources: \(decodedSourceCount)")
        }
        if let zoneRecordCount {
            values.append("Zone records: \(zoneRecordCount)")
        }
        if let zoneRecordTypes {
            values.append("Zone record types: \(zoneRecordTypes)")
        }
        if let errorMessage {
            values.append("Error: \(errorMessage)")
        }
        values.append("Checked: \(checkedAt.formatted(date: .omitted, time: .standard))")
        return values
    }
}

actor MobileCloudSourceCatalog {
    static let shared = MobileCloudSourceCatalog()

    private static let sourceRecordType = "Source"
    private static let sourceHighlightRecordType = "SourceHighlight"
    private static let artifactRecordType = "Artifact"
    private static let learningGoalRecordType = "LearningGoal"
    private static let scheduledSourceRecordType = "ScheduledSource"
    private static let memoryItemRecordType = "MemoryItem"
    private static let memoryAttemptRecordType = "MemoryAttempt"
    private static let reviewSessionRecordType = "ReviewSession"
    /// The ideas a memory review is graded against. Written by whichever
    /// device extracted them; read here so the phone grades with the same
    /// ids the Mac does.
    private static let sourceIdeaRecordType = "SourceIdea"
    // Display-shaping records riding the same zone: book/course metadata for
    // grouped lists, and the hidden sets the visibility rule reads.
    private static let bookRecordType = "Book"
    private static let courseRecordType = "Course"
    private static let hiddenPodcastShowRecordType = "HiddenPodcastShow"
    private static let hiddenYouTubeChannelRecordType = "HiddenYouTubeChannel"
    private static let meetingGroupRecordType = "MeetingGroup"
    /// A doc the learner hid on a Mac (schema 114): its artifact's id. Read
    /// so a notebook's page leaves a hidden audio overview out, as the Mac does.
    private static let hiddenArtifactRecordType = "HiddenArtifact"
    /// A chat the learner hid on a Mac (schema 114): its session's id. Read so
    /// a notebook's Chat tab leaves it out, as the Mac's lists do.
    private static let hiddenReviewSessionRecordType = "HiddenReviewSession"
    private static let sourcePayloadField = "payload"
    /// Where a payload travels once it outgrows the inline field: the Mac and
    /// `MobileReviewSessionRecorder` both move a ReviewSession past
    /// `inlinePayloadByteLimit` into this CKAsset and clear `payload`. A fetch
    /// that asks for `payload` alone gets such a record back empty.
    private static let payloadAssetField = "payloadAsset"
    private static let knowledgeZone = CKRecordZone.ID(zoneName: "Knowledge")
    private static let syncLogger = Logger(subsystem: "com.foreverlm.mobile", category: "SourceCatalogSync")
    /// The record types whose payloads this catalog fetches and parses. Adding
    /// a type here is all a new record type needs: the next load fetches the
    /// already-indexed records of that type by ID and starts collecting its
    /// deltas — no cache invalidation, no zone re-walk.
    private static let collectedRecordTypes: [String] = [
        sourceRecordType, sourceHighlightRecordType, artifactRecordType, learningGoalRecordType, scheduledSourceRecordType, bookRecordType,
        courseRecordType, hiddenPodcastShowRecordType, hiddenYouTubeChannelRecordType,
        meetingGroupRecordType, memoryItemRecordType, memoryAttemptRecordType,
        reviewSessionRecordType, sourceIdeaRecordType, hiddenArtifactRecordType,
        hiddenReviewSessionRecordType,
    ]
    /// The record types the library screens actually render. A long walk
    /// fetches these between pages so the list fills while the zone is still
    /// being paged, instead of staying empty until the last page lands.
    private static let displayRecordTypes: Set<String> = [
        sourceRecordType, bookRecordType, courseRecordType,
        hiddenPodcastShowRecordType, hiddenYouTubeChannelRecordType,
        scheduledSourceRecordType, learningGoalRecordType,
    ]
    private static let cacheTTL: TimeInterval = 90
    private static let recordFetchBatchSize = 100
    /// Version 1 repairs mirrors whose previously checkpointed CloudKit token
    /// skipped records after a partial fetch. Version 2 reconciles the move to
    /// the explicit Production environment and prunes Development-only rows.
    /// Audits are resumable; the existing library stays visible throughout.
    private static let requiredIndexAuditVersion = 2
    fileprivate static let dateEpochCutoff: TimeInterval = 1_000_000_000

    private let dateFormatter = ISO8601DateFormatter()
    private let payloadDecoder: JSONDecoder
    private var cachedSources: [MobileCloudSource] = []
    private var cachedNotebooks: [MobileCloudNotebook] = []
    private var cachedCollections: MobileCatalogCollections = .empty
    private var cachedAt: Date?
    private var activeLoad: (id: UUID, task: Task<[MobileCloudSource], Error>)?
    /// A forced refresh is a freshness contract, not merely permission to skip
    /// the short-lived cache. If it arrives while a zone delta is already in
    /// flight, remember it and run one more delta before releasing waiters.
    private var forcedRefreshRequested = false
    private var lastDecodedSourceCount: Int?
    /// The on-disk zone mirror (raw payloads + change token), memoized.
    private var mirrorState: PersistedZoneMirror?
    /// Any durable-store failure discovered during the first mirror read. Keep
    /// it so `performLoad` can fail loudly instead of silently treating a
    /// corrupt/unavailable database as an empty catalog and re-walking iCloud.
    private var mirrorLoadError: Error?
    /// Opened lazily on this actor, never from the main-actor view-model init.
    private var mirrorStore: MobileZoneMirrorStore?
    /// Rows parsed from the mirror, rebuilt lazily after a cold load and kept
    /// in step with the mirror during a sync.
    private var assembledState: AssembledCatalog?
    /// What the replica's index gave on the last load (`MobileReadModels`): the phone's library.
    private var replicaSnapshot: MobileReadModels.Snapshot?
    /// The member's cards and the answers about them, decoded from the Card and Sitting
    /// payloads on first use and kept until the replica next loads. A write this phone makes adds to it
    /// (`noteRecordedMemoryAttempt`) instead of decoding the library again.
    private var replicaMemory: MobileReadModels.MemoryState?
    /// The replica `replicaMemory` was read from, whose revision says whether it still holds.
    private var replicaMemoryHandle: MobileReplica?
    /// Moves with every replica load, so a decode that began before one never outlives it.
    private var replicaMemoryEpoch = 0
    /// The usage ledger's cache under generation 2, in a file of its own beside where the mirror was.
    private var usageStore: MobileZoneMirrorStore?

    /// The replica's query layer once the session runs (`MobileSyncSession`); nil when it cannot start.
    private let replicaProjection: @Sendable () async -> MobileProjection?
    private let ideaStore: MobileSourceIdeaStore

    init(projection: @escaping @Sendable () async -> MobileProjection? = { await MobileSyncSession.startIfEnabled()?.projection },
         ideas: MobileSourceIdeaStore = .shared) {
        replicaProjection = projection
        ideaStore = ideas
        payloadDecoder = Self.makePayloadDecoder()
    }

    private static func makePayloadDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }

    func loadSources(forceRefresh: Bool = false) async throws -> [MobileCloudSource] {
        if forceRefresh {
            forcedRefreshRequested = true
        }

        // Join an in-flight delta before considering the cache. Otherwise an
        // ordinary reader can publish the old snapshot while a refresh is
        // already bringing newer records onto the phone.
        if let activeLoad {
            return try await activeLoad.task.value
        }

        if !forcedRefreshRequested,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < Self.cacheTTL,
           !cachedSources.isEmpty {
            return cachedSources
        }

        // Launch fires several consumers at once (library, audio review, Siri);
        // one zone pass serves them all. A force request that arrives during
        // that pass is drained as a second delta so it cannot be swallowed.
        let id = UUID()
        let load = Task { [weak self] () throws -> [MobileCloudSource] in
            guard let self else { return [] }
            return try await self.runCoalescedLoad(id: id)
        }
        activeLoad = (id, load)
        return try await load.value
    }

    private func runCoalescedLoad(id: UUID) async throws -> [MobileCloudSource] {
        do {
            var sources: [MobileCloudSource] = []
            repeat {
                forcedRefreshRequested = false
                sources = try await performReplicaLoad()
            } while forcedRefreshRequested
            if activeLoad?.id == id {
                activeLoad = nil
            }
            return sources
        } catch {
            if activeLoad?.id == id {
                activeLoad = nil
            }
            throw error
        }
    }

    /// The Notebooks synced from the Mac (top-level companion goals), newest
    /// activity first, archived ones dropped — the same set the Mac's own
    /// selectors offer. Rides the exact same zone pass as `loadSources`, so
    /// calling both costs one round trip.
    func loadNotebooks(forceRefresh: Bool = false) async throws -> [MobileCloudNotebook] {
        _ = try await loadSources(forceRefresh: forceRefresh)
        return cachedNotebooks
    }

    /// Usage owns no second persistence rail. Its last authoritative server
    /// snapshot lives beside the catalog in the mobile SQLite database, served
    /// immediately while a fresh ledger request runs in the background.
    func loadUsageHistorySnapshot() -> MobileUsageHistorySnapshot? {
        try? usageHistoryStore().loadUsageHistorySnapshot()
    }

    func saveUsageHistorySnapshot(_ snapshot: MobileUsageHistorySnapshot) throws {
        try usageHistoryStore().saveUsageHistorySnapshot(snapshot)
    }

    /// A file of the usage cache's own beside the replica, kept in the zone mirror's table shape.
    private func usageHistoryStore() throws -> MobileZoneMirrorStore {
        if let usageStore { return usageStore }
        let store = try MobileZoneMirrorStore(
            databaseURL: Self.mirrorDatabaseURL().deletingLastPathComponent().appendingPathComponent("usage.db")
        )
        usageStore = store
        return store
    }

    /// Book/course display metadata and the hidden sets, from the same zone
    /// pass as `loadSources` — the grouped lists and the visibility rule read
    /// these together with the sources they shape.
    func loadCollections(forceRefresh: Bool = false) async throws -> MobileCatalogCollections {
        _ = try await loadSources(forceRefresh: forceRefresh)
        return cachedCollections
    }

    func loadSourceHighlights(sourceID: String, forceRefresh: Bool = false) async throws -> [SourceHighlight] {
        _ = try await loadSources(forceRefresh: forceRefresh)
        return currentSourceHighlights(sourceID: sourceID)
    }

    func currentSourceHighlights(sourceID: String) -> [SourceHighlight] {
        return replicaSnapshot?.highlights.filter { $0.sourceID == sourceID } ?? []
    }

    /// Every mark the learner set aside to follow up or doubt (blue, pink),
    /// across the library, as the Follow up screen reads them: the replica's
    /// highlights are already keyed by the source's id on this phone.
    func loadOpenSourceHighlights(forceRefresh: Bool = false) async throws -> [FollowUpMark] {
        _ = try await loadSources(forceRefresh: forceRefresh)
        return currentOpenSourceHighlights()
    }

    func currentOpenSourceHighlights() -> [FollowUpMark] {
        (replicaSnapshot?.highlights ?? [])
            .filter { $0.color.isOpenItem }
            .map { FollowUpMark(highlight: $0, sourceID: $0.sourceID) }
    }

    /// The load (§13.6, WP19b): the replica's index, read through `MobileReadModels` into the rows the
    /// screens already take; the session's rounds keep the replica current.
    private func performReplicaLoad() async throws -> [MobileCloudSource] {
        mirrorStore = nil
        mirrorState = nil
        assembledState = nil
        guard let projection = await replicaProjection() else {
            throw MobileCloudSourceCatalogError.replicaUnavailable
        }
        let snapshot = try await MobileReadModels.snapshot(projection)
        replicaSnapshot = snapshot
        replicaMemoryHandle = projection.replica
        // The cards and answers stay while no Card or Sitting arrived or went: a library read again for a
        // rename or a sync round does not decode every answer the learner ever gave.
        if let held = replicaMemory {
            let rows = try await projection.replica.read { try MobileReadModels.memoryRowCounts(in: $0.connection) }
            if rows.cards != held.cardRows || rows.sittings != held.sittingRows {
                replicaMemory = nil
                replicaMemoryEpoch &+= 1
            }
        }
        let sources = Self.available(snapshot, includingArchived: true)
        lastDecodedSourceCount = sources.count
        cachedSources = sources
        cachedCollections = snapshot.collections
        cachedNotebooks = snapshot.notebooks
        cachedAt = Date()
        return sources
    }

    /// The replica's sources the phone serves: courses once ready, nothing hidden on a Mac, newest
    /// first.
    private static func available(_ snapshot: MobileReadModels.Snapshot, includingArchived: Bool) -> [MobileCloudSource] {
        snapshot.sources
            .filter(isAvailableInMobileLibrary)
            .filter { includingArchived || !$0.isArchived }
            .filter { !MobileSourceVisibility.isHidden($0, collections: snapshot.collections) }
    }

    private static func collections(from catalog: AssembledCatalog) -> MobileCatalogCollections {
        MobileCatalogCollections(
            booksByID: Dictionary(
                catalog.booksByRecordName.values.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            coursesByID: Dictionary(
                catalog.coursesByRecordName.values.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            hiddenPodcastShowNames: Set(catalog.hiddenPodcastShowsByRecordName.values),
            hiddenYouTubeChannelNames: Set(catalog.hiddenYouTubeChannelsByRecordName.values),
            hiddenMeetingGroupIDs: Set(
                catalog.meetingGroupsByRecordName.values.filter(\.isHidden).map(\.id)
            )
        )
    }

    /// A Notebook payload can arrive before or after the Source payloads it
    /// references. Keep not-yet-delivered IDs so the UI can truthfully report
    /// sync progress, but remove IDs whose delivered Source is archived or
    /// hidden. Those are known-unavailable rows, not a sync lag, and counting
    /// them as "not synced" made complete Notebooks look permanently partial.
    /// Each notebook carries its context notebooks, in link order, from their
    /// own records, archived ones included as the Mac's pool counts them
    /// (`MobileNotebookCatalog`); what its chats read of them is the member's
    /// rows', never the catalog's.
    private static func notebooks(
        from catalog: AssembledCatalog,
        collections: MobileCatalogCollections
    ) -> [MobileCloudNotebook] {
        let sourcesByID = Dictionary(
            catalog.sourcesByRecordName.values.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let allNotebooksByID = Dictionary(
            catalog.notebooksByRecordName.values.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let isListed: (String) -> Bool = { sourceID in
            guard let source = sourcesByID[sourceID] else { return true }
            return !source.isArchived
                && isAvailableInMobileLibrary(source)
                && !MobileSourceVisibility.isHidden(source, collections: collections)
        }
        return catalog.notebooksByRecordName.values
            .filter { !$0.isArchived }
            .map { MobileNotebookCatalog.notebook($0, records: allNotebooksByID, isListed: isListed) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The decoded sources exactly as far as the current (possibly still
    /// running) sync has gotten — served from the last checkpoint, no fetch.
    /// Lets the list fill in progressively during the long first pass. Applies
    /// the same visibility rule as the finished load.
    func currentSources() -> [MobileCloudSource] {
        return replicaSnapshot.map { Self.available($0, includingArchived: false) } ?? []
    }

    /// Course imports are the one mobile grouping whose incomplete rows have
    /// no useful phone action: they have no synced text to read, discuss, or
    /// quiz. Keep them out until the Mac publishes `ready` rather than showing
    /// a tappable row that can only fail. Other source types retain their
    /// existing error/queued presentation semantics.
    private static func isAvailableInMobileLibrary(_ source: MobileCloudSource) -> Bool {
        source.sourceType != "course" || source.state == "ready"
    }

    /// Collections as far as the current sync has gotten, for the progressive
    /// first-pass fill — same checkpoint `currentSources()` reads.
    func currentCollections() -> MobileCatalogCollections {
        return replicaSnapshot?.collections ?? .empty
    }

    /// Notebooks from the same disk checkpoint as `currentSources()`. Publishing
    /// this snapshot before CloudKit refresh means a rebuild opens the previous
    /// library immediately instead of presenting sync as an empty first load.
    func currentNotebooks() -> [MobileCloudNotebook] {
        return replicaSnapshot?.notebooks ?? []
    }

    /// Raw goal lifecycle rows for relationship validation. The UI does not
    /// render this collection directly; it uses it to prevent deleting a Notebook
    /// that still owns child Goals.
    func currentGoals() -> [MobileCloudGoal] {
        Array(assembled().goalsByRecordName.values)
    }

    /// Sources a finished review covered, resolved to this phone's source ids:
    /// the Mac's `sourceReviewDates`, which a course's path counts as done for
    /// a lesson sheet or course PDF that can never be watched or marked read.
    func currentReviewedSourceIDs() -> Set<String> {
        return replicaSnapshot?.reviewedSourceIDs ?? []
    }

    func currentReviewSessionIDs(linkedTo goalIDs: Set<String>) -> [String] {
        assembled().reviewSessionsByRecordName.values.compactMap { session in
            guard let goalID = session.goalID, goalIDs.contains(goalID) else { return nil }
            return session.id
        }
    }

    /// Phone-side mirror of the Mac's bounded recent-chat preference. Memory
    /// sessions are excluded because their source list is the launch queue;
    /// ordinary chat/review relationships describe what the learner has chosen
    /// to discuss lately.
    func currentRecentReviewSourceActivity(
        now: Date = Date(),
        sessionLimit: Int = 12,
        maximumAgeDays: Int = 14
    ) -> [MemoryTutorRecentSourceActivity] {
        let catalog = assembled()
        let identityIndex = MobileMemorySourceIdentityResolver.Index(
            sources: Array(catalog.sourcesByRecordName.values),
            normalizeURL: MobileSourceURL.normalize
        )
        let cutoff = now.addingTimeInterval(
            -Double(max(1, min(maximumAgeDays, 90))) * 86_400
        )
        let sessions = catalog.reviewSessionsByRecordName.values
            .filter {
                ["active", "completed", "external_link"].contains($0.status)
                    && $0.cardIDs.isEmpty
                    && (!$0.exchanges.isEmpty || $0.status == "external_link")
            }
            .filter { ($0.endedAt ?? $0.startedAt) >= cutoff }
            .sorted {
                let lhs = $0.endedAt ?? $0.startedAt
                let rhs = $1.endedAt ?? $1.startedAt
                if lhs != rhs { return lhs > rhs }
                return $0.id < $1.id
            }
            .prefix(max(0, min(sessionLimit, 50)))

        let availableSourceIDs = Set(catalog.sourcesByRecordName.values.map(\.id))
        var latestBySourceID: [String: Date] = [:]
        for session in sessions {
            let identities = Dictionary(
                session.sourceIdentities.map { ($0.sourceID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let remoteIDs = Array(Set(
                session.sourceIDs + session.exchanges.flatMap(\.sourceRefs)
            ))
            let activityAt = session.endedAt ?? session.startedAt
            for remoteID in remoteIDs {
                let sourceID = identityIndex.resolvedSourceID(
                    remoteID,
                    identity: identities[remoteID]
                )
                guard availableSourceIDs.contains(sourceID) else { continue }
                latestBySourceID[sourceID] = max(
                    latestBySourceID[sourceID] ?? .distantPast,
                    activityAt
                )
            }
        }
        return latestBySourceID.map {
            MemoryTutorRecentSourceActivity(sourceID: $0.key, discussedAt: $0.value)
        }.sorted {
            if $0.discussedAt != $1.discussedAt { return $0.discussedAt > $1.discussedAt }
            return $0.sourceID < $1.sourceID
        }
    }

    /// Activity days keyed by the placement's *resolved* source id. The rows
    /// carry their own `sourceID`, but only the placement has been through
    /// identity reconciliation, so reading them this way keeps the history of a
    /// source that was deduplicated after the activity was recorded.
    private static func activityDaysBySourceID(
        _ catalog: AssembledCatalog
    ) -> [String: [SourceActivityDay]] {
        catalog.scheduledSourcesByRecordName.values.reduce(into: [:]) { result, placement in
            guard !placement.activityDays.isEmpty else { return }
            result[placement.sourceID, default: []].append(contentsOf: placement.activityDays)
        }
    }

    /// What the learner actually read, listened to, or watched lately, from the
    /// same synced Schedule activity the Mac writes.
    ///
    /// Discussion recency alone answers "what have we been talking about"; it
    /// says nothing about the podcast played on a walk this morning or the paper
    /// read last night. Both are attention signals of the same kind, so they
    /// merge into one recency input to the daily queue — which reorders an
    /// already-due queue and never invents a due date.
    func currentRecentSourceConsumptionActivity(
        now: Date = Date(),
        maximumAgeDays: Int = 14
    ) -> [MemoryTutorRecentSourceActivity] {
        let availableSourceIDs = Set((replicaSnapshot?.sources ?? []).map(\.id))
        let activityDays = replicaSnapshot?.activityDays ?? [:]
        let cutoff = now.addingTimeInterval(
            -Double(max(1, min(maximumAgeDays, 90))) * 86_400
        )
        return activityDays
            .compactMap { sourceID, days -> MemoryTutorRecentSourceActivity? in
                guard availableSourceIDs.contains(sourceID),
                      let consumedAt = SourceActivityDay.lastConsumedAt(in: days),
                      consumedAt >= cutoff else { return nil }
                return MemoryTutorRecentSourceActivity(
                    sourceID: sourceID,
                    discussedAt: consumedAt
                )
            }
            .sorted {
                if $0.discussedAt != $1.discussedAt { return $0.discussedAt > $1.discussedAt }
                return $0.sourceID < $1.sourceID
            }
    }

    /// Everything the learner has attended to lately, from both halves of
    /// "recently": what was discussed, and what was read, listened to, or
    /// watched. Callers fold duplicates by keeping the later timestamp.
    func currentRecentSourceAttention(
        now: Date = Date()
    ) -> [MemoryTutorRecentSourceActivity] {
        currentRecentReviewSourceActivity(now: now)
            + currentRecentSourceConsumptionActivity(now: now)
    }

    func currentMemoryAttemptIDs(linkedToSessionIDs sessionIDs: Set<String>) -> [String] {
        assembled().memoryAttemptsByRecordName.values.compactMap { attempt in
            guard let sessionID = attempt.sessionID, sessionIDs.contains(sessionID) else { return nil }
            return attempt.id
        }
    }

    /// Every audio overview the Mac saved, as the phone lists them under
    /// their notebooks (`MobileAudioReviewViewModel.audioOverviews(inNotebook:)`):
    /// archived and hidden ones left out, as the Mac's notebook leaves them.
    func currentAudioOverviews() -> [MobileAudioOverviewRecord] {
        return replicaSnapshot?.audioOverviews ?? []
    }

    /// Every current Artifact the learner has not hidden: what a notebook's
    /// Studio filters to its Docs (`MobileAudioReviewViewModel.docs(in:)`)
    /// and orders by when each was made (`MobileNotebookOutputOrder`).
    func currentNotebookArtifacts() -> [MobileCloudArtifact] {
        return replicaSnapshot?.artifacts ?? []
    }

    /// The chats filed under each notebook (`goalID`), newest first, as its
    /// Chat tab lists them: a chat hidden on a Mac and one nobody said
    /// anything in are left out. A chat filed on a Goal nested in a notebook
    /// is the notebook's too (homing's filed rule, `MobileNotebookMembership`).
    /// Each carries the sources it read, by this phone's ids, and what it is,
    /// which decide whether the phone continues it
    /// (`MobileNotebookChatContinuation`).
    func currentNotebookChats() -> [String: [MobileNotebookChatSummary]] {
        return replicaSnapshot?.notebookChats ?? [:]
    }

    /// One saved chat's turns for its read-only transcript; nil when the
    /// session is not on this phone.
    func currentChatTranscriptTurns(sessionID: String) async -> [MobileChatTranscriptTurns.Turn]? {
        // Only this chat's exchanges are decoded, a page at a time.
        guard let zoneKey = replicaSnapshot?.chatZones[sessionID], let projection = await replicaProjection() else { return nil }
        return try? await MobileReadModels.transcript(chatID: sessionID, zoneKey: zoneKey, projection: projection)
    }

    func currentArtifactIDs(linkedTo notebookIDs: Set<String>) -> [String] {
        return (replicaSnapshot?.artifacts ?? []).filter { artifact in
            artifact.homeNotebookID.map(notebookIDs.contains) ?? false || !notebookIDs.isDisjoint(with: artifact.linkedNotebookIDs)
        }.map(\.id)
    }

    func currentNotebookIDs(referringTo notebookIDs: Set<String>) -> [String] {
        return (replicaSnapshot?.notebooks ?? []).filter { !notebookIDs.isDisjoint(with: $0.relatedNotebookIDs) }.map(\.id)
    }

    /// Canonical concept-level memory state from the same durable zone mirror as
    /// Sources and Schedule. The phone derives due state from immutable attempts;
    /// it never keeps a second JSON persistence rail or guesses from sessions.
    /// The active ideas of the given sources, in their stored order — what a
    /// memory review's contour is graded against.
    func currentSourceIdeas(sourceIDs: [String]) async -> [String: [SourceIdea]] {
        // Generation 2 keeps a source's ideas in its `ideas` satellite (§10), not in records the catalog holds.
        return await ideaStore.ideas(sourceIDs: sourceIDs)
    }

    /// Every source with real consumption evidence and its review history, the
    /// phone's twin of the Mac's `cohortCandidates` query, from the records
    /// already synced here. Feeds `CohortSelector` unchanged.
    func currentMemoryReviewCandidates(
        now: Date = Date(),
        minimumConfidence: SourceConsumptionConfidence = CohortSelector.selectableConfidence
    ) -> [CohortCandidate] {
        let inputs = memoryReviewInputs()
        return MemoryReviewCandidates.candidates(
            sources: inputs.sources,
            activityDays: inputs.activityDays,
            sessions: inputs.sessions,
            now: now,
            minimumConfidence: minimumConfidence
        )
    }

    /// The day as the ledger recorded it, from the same synced records: totals
    /// since the start of yesterday and what was opened but is not in the
    /// review (`excluding`). The phone's twin of `StorageService.memoryReviewDay`.
    func currentMemoryReviewDay(
        now: Date = Date(),
        excluding: Set<String>
    ) -> (ledger: MemoryReviewLedger, touched: [CohortTouchedSource]) {
        let inputs = memoryReviewInputs()
        let since = MemoryReviewLedger.windowStart(now: now)
        return (
            MemoryReviewCandidates.ledger(
                sources: inputs.sources,
                activityDays: inputs.activityDays,
                sessions: inputs.sessions,
                since: since,
                now: now
            ),
            MemoryReviewCandidates.touched(
                sources: inputs.sources,
                activityDays: inputs.activityDays,
                since: since,
                now: now,
                excluding: excluding
            )
        )
    }

    /// The portable candidate inputs, built once per call: from the replica's index once this install
    /// switched, else from the catalog.
    private func memoryReviewInputs(
    ) -> (sources: [MemoryReviewCandidates.SourceInput], activityDays: [String: [SourceActivityDay]], sessions: [MemoryReviewCandidates.SessionInput]) {
        return Self.memoryReviewInputs(replicaSnapshot ?? MobileReadModels.Snapshot())
    }

    /// Generation 2's candidate inputs, from the replica's index: its sources, the member's highlights
    /// and every source's activity days folded from the ActivityLogs. Its chats' exchanges are not in
    /// the index, so no review session counts yet.
    static func memoryReviewInputs(
        _ snapshot: MobileReadModels.Snapshot
    ) -> (sources: [MemoryReviewCandidates.SourceInput], activityDays: [String: [SourceActivityDay]], sessions: [MemoryReviewCandidates.SessionInput]) {
        (memoryReviewSources(snapshot.sources, collections: snapshot.collections, highlights: snapshot.highlights), snapshot.activityDays, [])
    }

    /// The sources a memory review may pick from, with their highlights counted as annotation evidence.
    private static func memoryReviewSources(
        _ sources: [MobileCloudSource],
        collections: MobileCatalogCollections,
        highlights: some Sequence<SourceHighlight>
    ) -> [MemoryReviewCandidates.SourceInput] {
        // Highlights are the ledger's annotation evidence; the phone syncs them
        // and counts them here the way the Mac counts `source_highlights`.
        let annotationCounts = highlights.reduce(into: [String: Int]()) { counts, highlight in
            // A talk's slide the canvas set down, unwritten on, is no annotation.
            guard !highlight.isBareSlideMark else { return }
            counts[highlight.sourceID, default: 0] += 1
        }
        return sources.map { source in
            MemoryReviewCandidates.SourceInput(
                id: source.id,
                title: source.title,
                sourceType: source.sourceType,
                dateAdded: source.dateAdded,
                readAt: source.readAt,
                // Hiding one source is a list state, not a knowledge state, so
                // it stays reviewable; a hidden show or channel mutes its
                // episodes for the review as well.
                // An audio overview's script retells its notebook's sources,
                // which are what is reviewed (the Mac's `cohortCandidates`).
                isAvailable: !source.isArchived
                    && !MobileSourceVisibility.isCollectionHidden(source, collections: collections)
                    && source.state == "ready"
                    && !TextToSpeechPreparationPolicy.isAudioOverviewScript(url: source.url ?? ""),
                wordCount: source.wordCount,
                annotationCount: annotationCounts[source.id] ?? 0
            )
        }
    }

    /// What the Memory feature reads: the member's items and answers, and the sources and notebooks that
    /// decide which of them the phone may ask, from the replica's Card and Sitting payloads and its
    /// snapshot.
    private struct MemoryInputs {
        var items: [MemoryItem] = []
        var attempts: [MemoryAttempt] = []
        var sources: [MobileCloudSource] = []
        var collections: MobileCatalogCollections = .empty
        /// A notebook's approved sources by its id, archived notebooks too: what a card's notebook is
        /// derived from (`MobileNotebookCards`).
        var notebookMembers: [String: [String]] = [:]
        var goalParents: [String: String] = [:]
    }

    private func memoryInputs() async -> MemoryInputs {
        let memory = await replicaMemoryState()
        let snapshot = replicaSnapshot ?? MobileReadModels.Snapshot()
        return MemoryInputs(items: memory.items, attempts: memory.attempts, sources: snapshot.sources, collections: snapshot.collections,
                            notebookMembers: snapshot.notebookPools, goalParents: snapshot.goalParents)
    }

    /// Generation 2's cards and answers, decoded once per replica load. A read that fails answers what the
    /// phone could not read as nothing held, and says so in the log; the next call tries again.
    /// Adds what the phone just wrote to the cards and answers it holds. With none held yet, the next
    /// read decodes them from the replica, which has the write already; a decode under way began before
    /// it, so it is not kept.
    private func noteReplicaMemory(_ change: (inout MobileReadModels.MemoryState) -> Void) {
        guard replicaMemory != nil else {
            replicaMemoryEpoch &+= 1
            return
        }
        change(&replicaMemory!)
    }

    private func replicaMemoryState() async -> MobileReadModels.MemoryState {
        if let held = replicaMemory {
            if replicaMemoryHandle?.memoryRevision == held.revision { return held }
            replicaMemory = nil
            replicaMemoryEpoch &+= 1
        }
        let epoch = replicaMemoryEpoch
        guard let projection = await replicaProjection() else { return MobileReadModels.MemoryState() }
        do {
            let state = try await MobileReadModels.memory(projection)
            // A load that finished meanwhile read a newer replica; this one is for this call only.
            if epoch == replicaMemoryEpoch {
                replicaMemory = state
                replicaMemoryHandle = projection.replica
            }
            return state
        } catch {
            Self.syncLogger.error("The cards and answers could not be read from the replica: \(error.localizedDescription, privacy: .public)")
            return MobileReadModels.MemoryState()
        }
    }

    func currentMemoryItems() async -> [MemoryItem] {
        await memoryInputs().items
            .filter { $0.status == .active }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
    }

    func currentMemoryAttempts() async -> [MemoryAttempt] {
        await memoryInputs().attempts
            .sorted { lhs, rhs in
                if lhs.attemptedAt != rhs.attemptedAt { return lhs.attemptedAt < rhs.attemptedAt }
                return lhs.id < rhs.id
            }
    }

    /// The synced items the phone may ask: active, and anchored only on library
    /// sources it has (`MobileMemoryReviewScope.eligibleItems`).
    private func reviewableMemoryItems(
        in inputs: MemoryInputs,
        restrictToSourceIDs: Set<String>?
    ) -> [MemoryItem] {
        MobileMemoryReviewScope.eligibleItems(
            inputs.items,
            availableSourceIDs: Self.availableSourceIDs(in: inputs),
            restrictToSourceIDs: restrictToSourceIDs
        )
    }

    /// The library sources a card may stand on here: listed, not archived,
    /// and not an episode of a hidden show or channel. A source hidden by
    /// itself stays reviewable.
    private static func availableSourceIDs(in inputs: MemoryInputs) -> Set<String> {
        Set(
            inputs.sources
                .filter(Self.isAvailableInMobileLibrary)
                .filter { !$0.isArchived && !MobileSourceVisibility.isCollectionHidden($0, collections: inputs.collections) }
                .map(\.id)
        )
    }

    /// Today's card review over the synced items: the one queue every surface
    /// deals and counts from (`MemoryCardQueue.today`, over the items with a
    /// face, as the Mac's card review reads them), so the phone's card
    /// review, its Memory screen, Home's strip, its widget and the Mac agree
    /// on what today holds. The phone receives no calendar blocks or Goal end
    /// dates, so it passes no deadlines: its order skips (a), and a deadline
    /// notebook's new cards wait for the daily allowance.
    func currentTodayMemoryCards(
        now: Date = Date(),
        budgetMinutes: Int?,
        newPerDay: Int
    ) async -> MemoryCardQueue.Today {
        await currentCardReviewRead(now: now, budgetMinutes: budgetMinutes, newPerDay: newPerDay, scope: .allNotebooks).today
    }

    /// What a card sitting reads over `scope` (docs/memory-design.md, "The
    /// card review on the iPhone"): today's cards, the new cards practice
    /// would take, and each one's history, the Mac's
    /// `memoryCardReviewSnapshot` over the synced items the phone may show.
    /// A notebook this phone does not hold narrows to no card. Local only:
    /// it never waits on CloudKit.
    func currentCardReviewRead(
        now: Date = Date(),
        budgetMinutes: Int?,
        newPerDay: Int,
        scope: MemoryReviewScope
    ) async -> MobileCardReviewDealing.Read {
        let inputs = await memoryInputs()
        let cardScope: MemoryCardScope?
        switch scope {
        case .allNotebooks:
            cardScope = nil
        case .notebook(let notebookID):
            guard let found = Self.notebookCardScope(notebookID: notebookID, in: inputs) else { return .empty }
            cardScope = found
        }
        return MobileCardReviewDealing.read(
            items: reviewableMemoryItems(in: inputs, restrictToSourceIDs: nil),
            attempts: inputs.attempts,
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay,
            scope: cardScope
        )
    }

    /// A notebook's Practice: its kept cards, due, then new, then not yet
    /// due (`MemoryCardDeal.notebookPractice`); nil for a notebook this phone
    /// does not hold.
    func currentNotebookPractice(notebookID: String, now: Date = Date()) async -> MobileCardReviewDealing.NotebookPractice? {
        let inputs = await memoryInputs()
        guard let scope = Self.notebookCardScope(notebookID: notebookID, in: inputs) else { return nil }
        return MobileCardReviewDealing.notebookPractice(
            items: reviewableMemoryItems(in: inputs, restrictToSourceIDs: nil),
            attempts: inputs.attempts,
            scope: scope,
            now: now
        )
    }

    /// A notebook's Studio Cards row: "42 kept · 6 due", by the Mac's
    /// `notebookCardCounts`; nil for a notebook this phone does not hold.
    func currentNotebookCardCounts(
        notebookID: String,
        now: Date = Date(),
        budgetMinutes: Int?,
        newPerDay: Int
    ) async -> NotebookCardCounts? {
        let inputs = await memoryInputs()
        guard let scope = Self.notebookCardScope(notebookID: notebookID, in: inputs) else { return nil }
        let counts = MobileCardReviewDealing.notebookCounts(
            items: reviewableMemoryItems(in: inputs, restrictToSourceIDs: nil),
            attempts: inputs.attempts,
            scope: scope,
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay
        )
        let toCheck = await cardsToCheck(in: inputs, scope: scope, now: now)?.count ?? 0
        return NotebookCardCounts(kept: counts.kept, due: counts.due, toCheck: toCheck)
    }

    // MARK: Cards to check and a kept card's Card (generation 2)

    /// The cards to check over `scope` (docs/memory-design.md, "Cards to
    /// check on the iPhone"): the drafts in the replica's Cards whose source
    /// this phone lists, in To Check's order (`MobileCardRecords.toCheck`),
    /// narrowed to a notebook's by the Mac's `MemoryCardScope`. Empty for a
    /// notebook this phone does not hold; nil when the replica could not be
    /// read. Local only.
    func currentCardsToCheck(scope: MemoryReviewScope, now: Date = Date()) async -> [MemoryCardToCheck]? {
        let inputs = await memoryInputs()
        switch scope {
        case .allNotebooks:
            return await cardsToCheck(in: inputs, scope: nil, now: now)
        case .notebook(let notebookID):
            guard let cardScope = Self.notebookCardScope(notebookID: notebookID, in: inputs) else { return [] }
            return await cardsToCheck(in: inputs, scope: cardScope, now: now)
        }
    }

    private func cardsToCheck(in inputs: MemoryInputs, scope: MemoryCardScope?, now: Date) async -> [MemoryCardToCheck]? {
        guard let projection = await replicaProjection() else { return nil }
        do {
            let records = try await projection.replica.read { try MobileReadModels.draftDecks(in: $0) }
            let cards = MobileCardRecords.toCheck(records, availableSourceIDs: Self.availableSourceIDs(in: inputs), now: now)
            guard let scope else { return cards }
            return cards.filter { scope.contains(anchorSourceIDs: [$0.sourceID], goalID: nil) }
        } catch {
            Self.syncLogger.error("The cards to check could not be read from the replica: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The Cards of the kept cards `itemIDs` names, by id: what a card is
    /// worded by (its rewording, rewordings, "always ask it this way").
    /// Empty when the replica could not be read: a card is then asked in its
    /// own words. Local only.
    func currentCardRecords(itemIDs: [String]) async -> [String: MobileCardRecord] {
        guard !itemIDs.isEmpty, let projection = await replicaProjection() else { return [:] }
        do {
            return try await projection.replica.read { try MobileReadModels.cards(itemIDs, in: $0) }
        } catch {
            Self.syncLogger.error("The cards' records could not be read from the replica: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Items this phone just kept, retired or started over: held at once,
    /// so the next read needs no second decode of the library.
    func noteWrittenMemoryItems(_ items: [MemoryItem]) {
        noteReplicaMemory { memory in
            for item in items { memory.note(item) }
        }
    }

    /// The notebooks a card review may be narrowed to: every notebook this
    /// phone holds, archived ones included (their cards are still asked).
    func currentCardReviewNotebookIDs() async -> Set<String> {
        Set(await memoryInputs().notebookMembers.keys)
    }

    /// The notebooks this phone holds with at least one kept card, the ones
    /// a card review's scope menu offers.
    func currentNotebookIDsWithCards() async -> Set<String> {
        let inputs = await memoryInputs()
        let scopes = inputs.notebookMembers.keys.compactMap { Self.notebookCardScope(notebookID: $0, in: inputs) }
        return MobileCardReviewDealing.notebookIDsWithCards(
            items: reviewableMemoryItems(in: inputs, restrictToSourceIDs: nil),
            attempts: inputs.attempts,
            scopes: scopes
        )
    }

    /// One card's item, whatever its status, and its whole history as this
    /// phone holds it: what a self-graded answer is decided from
    /// (`MobileSelfGradedAnswer`). Nil once the item is gone from the phone.
    func currentCardAnswerContext(memoryItemID: String) async -> (item: MemoryItem, history: [MemoryAttempt])? {
        let inputs = await memoryInputs()
        guard let item = inputs.items.first(where: { $0.id == memoryItemID }) else { return nil }
        return (item, inputs.attempts.filter { $0.memoryItemID == memoryItemID })
    }

    /// The items a mnemonic reading's questions kept (`itemIDs`, each
    /// question's `memoryItemID`) and their attempts, as the phone holds them:
    /// where the reading reads each question's standing and decides an
    /// answer. Local only.
    func currentMnemonicReadingHeld(itemIDs: Set<String>) async -> (items: [MemoryItem], attempts: [MemoryAttempt]) {
        guard !itemIDs.isEmpty else { return ([], []) }
        let inputs = await memoryInputs()
        var seen = Set<String>()
        let items = inputs.items.filter { itemIDs.contains($0.id) && seen.insert($0.id).inserted }
        return (items, inputs.attempts.filter { itemIDs.contains($0.memoryItemID) })
    }

    /// Whether today's review chat — made before cards, by the phone's daily
    /// preparation or by voice — holds an answer of the learner's: the one
    /// case the card review offers to continue it (docs/memory-design.md,
    /// "The card review on the iPhone"). A chat no one has answered in is not
    /// being resumed, and nothing prepares one from here.
    func currentDayReviewChatIsUnderway(now: Date = Date()) -> Bool {
        let sessionID = MemoryReviewSession.sessionID(for: now)
        // Generation 2: a chat the learner has answered in is one whose exchanges hold an answer.
        return replicaSnapshot?.memoryChats.contains { $0.id == sessionID && $0.isAnswered } ?? false
    }

    /// Every kept card the phone may show, oldest kept first: the Memory
    /// screen's All Cards (`MobileCardReviewDealing.listings`). Local only.
    func currentKeptCardListings() async -> [MemoryCardListing] {
        let inputs = await memoryInputs()
        return MobileCardReviewDealing.listings(
            items: reviewableMemoryItems(in: inputs, restrictToSourceIDs: nil),
            attempts: inputs.attempts
        )
    }

    /// The day-named review chats the Memory screen's history grid reads:
    /// the earlier days with a chat to open, and the days the learner wrote
    /// in (`MobileMemoryHistoryDays`). Local only.
    /// One of a notebook's two tick rows by its preference key
    /// (`notebook.chatExcluded.<id>`, `notebook.chatContextNotebooks.<id>`), read from this member's
    /// NotebookState in the last snapshot (§5.6, D52); nil when the row would be empty.
    func currentChatSelectionRow(key: String) -> [String]? {
        let excludedPrefix = MobileNotebookChatSelection.preferenceKey(notebookID: "")
        let contextPrefix = MobileNotebookChatSelection.contextNotebooksKey(notebookID: "")
        let row: Set<String>?
        if key.hasPrefix(excludedPrefix) {
            row = replicaSnapshot?.selections[String(key.dropFirst(excludedPrefix.count))]?.excluded
        } else if key.hasPrefix(contextPrefix) {
            row = replicaSnapshot?.selections[String(key.dropFirst(contextPrefix.count))]?.contextNotebookIDs
        } else {
            row = nil
        }
        guard let row, !row.isEmpty else { return nil }
        return row.sorted()
    }

    func currentMemoryReviewChatDays(now: Date = Date()) -> MobileMemoryHistoryDays.Days {
        return MobileMemoryHistoryDays.days(of: replicaSnapshot?.memoryChats ?? [], now: now)
    }

    /// The notebook `notebookID` as a card scope (`MobileNotebookCards`): its
    /// approved pool by this phone's ids and the ids its record names, and
    /// every Goal's notebook.
    private static func notebookCardScope(notebookID: String, in inputs: MemoryInputs) -> MemoryCardScope? {
        guard let members = inputs.notebookMembers[notebookID] else { return nil }
        return MobileNotebookCards.scope(
            notebookID: notebookID,
            memberSourceIDs: members,
            goalParents: inputs.goalParents
        )
    }

    func currentDueMemoryItems(
        now: Date = Date(),
        limit: Int = 12,
        restrictToSourceIDs: Set<String>? = nil
    ) async -> [DueMemoryItem] {
        let inputs = await memoryInputs()
        return dueMemoryItems(
            reviewableMemoryItems(in: inputs, restrictToSourceIDs: restrictToSourceIDs),
            attempts: inputs.attempts,
            now: now,
            limit: limit
        )
    }

    /// Each Goal's notebook (`parentNotebookID`), so a thing filed under a Goal
    /// nested in a notebook is the notebook's.
    private static func goalParents(in catalog: AssembledCatalog) -> [String: String] {
        var parents: [String: String] = [:]
        for goal in catalog.goalsByRecordName.values {
            if let parent = goal.parentNotebookID, !parent.isEmpty { parents[goal.id] = parent }
        }
        return parents
    }

    private func dueMemoryItems(
        _ items: [MemoryItem],
        attempts: [MemoryAttempt],
        now: Date,
        limit: Int
    ) -> [DueMemoryItem] {
        let attemptsByItemID = Dictionary(grouping: attempts) {
            $0.memoryItemID
        }
        let schedules = Dictionary(uniqueKeysWithValues: items.map { item in
            (
                item.id,
                MemoryTutorScheduler.schedule(
                    item: item,
                    attempts: attemptsByItemID[item.id] ?? []
                )
            )
        })
        // Recency is supplied here, where the pool is bounded, and not only to
        // the downstream selection: a pool capped by "most overdue" alone cannot
        // be reordered into containing this week's material afterwards.
        return MemoryTutorScheduler.dueItems(
            items: Array(items),
            schedules: schedules,
            now: now,
            limit: limit,
            recentSourceActivity: currentRecentSourceAttention(now: now)
        )
    }

    /// Rehydrate an app-selected review identity exactly, even when a hard
    /// attempt has already moved its derived due date into the future. This is
    /// used for voice reconnect/resume; selection happened earlier and must not
    /// be silently replaced by a freshly recomputed top-N queue.
    func currentMemoryReviewItems(
        ids: [String],
        now: Date = Date(),
        restrictToSourceIDs: Set<String>? = nil
    ) async -> [DueMemoryItem] {
        let inputs = await memoryInputs()
        let itemsByID = Dictionary(
            reviewableMemoryItems(in: inputs, restrictToSourceIDs: restrictToSourceIDs).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let attemptsByItemID = Dictionary(grouping: inputs.attempts) {
            $0.memoryItemID
        }
        return ids.compactMap { id in
            guard let item = itemsByID[id] else { return nil }
            let schedule = MemoryTutorScheduler.schedule(
                item: item,
                attempts: attemptsByItemID[id] ?? []
            )
            return DueMemoryItem(
                item: item,
                schedule: schedule,
                daysOverdue: max(
                    0,
                    Int(now.timeIntervalSince(schedule.dueAt) / MemoryTutorScheduler.secondsPerDay)
                )
            )
        }
    }

    /// Resolve a bounded set of already-synced source identities without a
    /// network refresh. MemoryItem anchors remain authoritative; this supplies
    /// portable URL metadata for an atomic phone-authored session payload.
    /// One chat as review material — its title and the transcript its ideas
    /// are extracted from, built exactly as the Mac builds it so the two agree
    /// on the ideas' content hash. nil when the session is not a reviewable
    /// chat.
    func currentReviewableChatTranscript(sessionID: String) -> (title: String, text: String)? {
        guard let session = assembled().reviewSessionsByRecordName.values.first(where: { $0.id == sessionID }),
              ReviewableChat.qualifies(id: session.id, status: session.status, summary: session.reviewableChatSummary)
        else { return nil }
        let title = session.reviewableChatSummary.title
        return (title, ReviewableChat.transcript(title: title, exchanges: session.reviewableExchanges))
    }

    func currentSources(ids: [String]) -> [MobileCloudSource] {
        let held = replicaSnapshot?.sources ?? []
        let byID = Dictionary(
            held.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { byID[$0] }
    }

    /// Bounded activation lookup for an already-selected memory item. Unlike
    /// `currentSources(ids:)`, this reapplies the live library visibility rules
    /// so a queued multi-anchor item cannot load partial or newly hidden scope.
    func currentAvailableSources(ids: [String]) -> [MobileCloudSource] {
        let held = replicaSnapshot?.sources ?? []
        let collections = replicaSnapshot?.collections ?? .empty
        let byID = Dictionary(
            held.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { sourceID in
            guard let source = byID[sourceID],
                  !source.isArchived,
                  Self.isAvailableInMobileLibrary(source),
                  !MobileSourceVisibility.isHidden(source, collections: collections) else {
                return nil
            }
            return source
        }
    }

    func memoryStruggleProjection(
        for item: MemoryItem,
        limit: Int = 3
    ) async -> MemoryStruggleProjection {
        let attempts = await memoryInputs().attempts.filter {
            $0.memoryItemID == item.id
        }
        return MemoryTutorStruggleProjector.project(
            item: item,
            attempts: attempts,
            limit: limit
        )
    }

    /// Phone-side first-review intake applies the same `SourceConsumption` rule
    /// as macOS — an explicit `readAt`, or substantial measured depth from the
    /// source's activity days — and excludes every source already represented by
    /// a concept item (including deliberately retired items). Depth matters most
    /// here: a podcast abandoned at 70% and an article scrolled most of the way
    /// through are material the learner actually went through, and neither ever
    /// gets a `readAt`. Canonical source text is fetched only after the learner
    /// starts the bounded voice review.
    func currentFirstReviewMemoryItems(
        now: Date = Date(),
        limit: Int = 12,
        restrictToSourceIDs: Set<String>? = nil
    ) -> [MemoryReviewNewItem] {
        let catalog = assembled()
        let collections = Self.collections(from: catalog)
        let availableSources = catalog.sourcesByRecordName.values
            .filter(Self.isAvailableInMobileLibrary)
            .filter {
                !$0.isArchived
                    && !MobileSourceVisibility.isHidden($0, collections: collections)
                    && $0.state == "ready"
                    && (restrictToSourceIDs?.contains($0.id) ?? true)
            }
        let availableSourceIDs = Set(availableSources.map(\.id))
        let representedSourceIDs = Set(
            catalog.memoryItemsByRecordName.values
                .flatMap { $0.sources.map(\.sourceID) }
        )
        let identityIndex = MobileMemorySourceIdentityResolver.Index(
            sources: Array(catalog.sourcesByRecordName.values),
            normalizeURL: MobileSourceURL.normalize
        )
        let attemptedSourceIDsBySession = MobileMemoryAttemptSourceProjection.bySession(
            items: Array(catalog.memoryItemsByRecordName.values),
            attempts: Array(catalog.memoryAttemptsByRecordName.values)
        )
        let legacySessions = catalog.reviewSessionsByRecordName.values.compactMap {
            session -> MobileLegacyReviewSession? in
            guard session.status == "completed" || session.status == "external_link" else {
                return nil
            }
            let identities = Dictionary(
                session.sourceIdentities.map { ($0.sourceID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let remoteIDs: [String]
            if let attemptedSourceIDs = attemptedSourceIDsBySession[session.id] {
                // Concept evidence is authoritative. The session relationship is
                // the launch queue and may contain items the learner never reached.
                remoteIDs = attemptedSourceIDs.sorted()
            } else {
                var attachedIDs = session.sourceIDs
                var seenRemoteIDs = Set(attachedIDs)
                for sourceID in session.exchanges.flatMap(\.sourceRefs) {
                    if seenRemoteIDs.insert(sourceID).inserted { attachedIDs.append(sourceID) }
                }
                remoteIDs = attachedIDs
            }
            var seenResolvedIDs = Set<String>()
            let resolved = remoteIDs.compactMap { sourceID -> String? in
                let mapped = identityIndex.resolvedSourceID(
                    sourceID,
                    identity: identities[sourceID]
                )
                guard availableSourceIDs.contains(mapped), seenResolvedIDs.insert(mapped).inserted else {
                    return nil
                }
                return mapped
            }
            guard !resolved.isEmpty else { return nil }
            return MobileLegacyReviewSession(
                date: session.endedAt ?? session.startedAt,
                score: session.overallScore,
                sourceIDs: resolved
            )
        }
        let reviewedSourceIDs = Set(legacySessions.flatMap(\.sourceIDs))
        let legacyStats = MobileLegacyMemoryReviewProjector.stats(
            sessions: legacySessions,
            sources: Array(availableSources),
            excludingSourceIDs: representedSourceIDs
        )
        let activityDaysBySourceID = Self.activityDaysBySourceID(catalog)
        let candidates = availableSources.compactMap { source -> MemoryReviewNewCandidate? in
            guard !representedSourceIDs.contains(source.id),
                  !reviewedSourceIDs.contains(source.id) else { return nil }
            let deepest = SourceActivityDay.deepestPoint(
                in: activityDaysBySourceID[source.id] ?? []
            )
            let signals = SourceConsumptionSignals(
                readAt: source.readAt,
                readingPositionPage: nil,
                readingPositionLocator: nil,
                dateAdded: source.dateAdded,
                maxFraction: deepest?.fraction ?? 0,
                deepestActivityAt: deepest?.reachedAt
            )
            guard let consumedAt = SourceConsumption.consumedAt(
                signals,
                minimumConfidence: .substantial
            ) else { return nil }
            return MemoryReviewNewCandidate(
                sourceID: source.id,
                title: source.title,
                sourceType: source.sourceType,
                consumedAt: consumedAt
            )
        }
        // Both buckets are gathered in full and bounded together. Filling the
        // cap from the legacy bucket first spent the entire daily budget on the
        // oldest backlog whenever that backlog was larger than the cap, which is
        // how a podcast finished this week stayed out of the queue outright.
        return MemoryReviewScheduler.firstReviewIntake(
            legacyStats: legacyStats,
            freshCandidates: candidates,
            now: now,
            limit: limit
        )
    }

    /// Publish a successful phone-authored attempt immediately. The key is the
    /// exact CloudKit record name, so the later zone delta replaces this row
    /// rather than duplicating it. CloudKit remains the durable source of truth.
    func noteRecordedMemoryAttempt(_ attempt: MemoryAttempt, recordName: String) {
        noteReplicaMemory { $0.note(attempt) }
    }

    func noteRecordedMemoryItem(_ item: MemoryItem, recordName: String) {
        noteReplicaMemory { $0.note(item) }
    }

    /// Raw Schedule placements for conflict-aware mobile mutations. Display rows
    /// intentionally omit persistence details, while writes need the stable
    /// placement id and complete goal membership.
    func currentScheduledSources() -> [MobileCloudScheduledSource] {
        return replicaSnapshot?.placements ?? []
    }

    /// Resolves every Schedule relationship on the catalog actor so the main
    /// actor only publishes a finished array. Missing/hidden/archived sources
    /// stay out, and unfinished work whose known goals are all inactive follows
    /// the same visibility rule as the Mac Schedule.
    func currentScheduleItems() -> [MobileScheduledCatalogItem] {
        guard let snapshot = replicaSnapshot else { return [] }
        return Self.scheduleItems(placements: snapshot.placements, sources: snapshot.sources, collections: snapshot.collections,
                                  goals: snapshot.scheduleGoals)
    }

    /// The Schedule's rows from its placements, whichever generation fed them.
    static func scheduleItems(placements: [MobileCloudScheduledSource], sources: [MobileCloudSource], collections: MobileCatalogCollections,
                              goals: [MobileCloudGoal]) -> [MobileScheduledCatalogItem] {
        let sourcesByID = Dictionary(
            sources
                .filter { !$0.isArchived && !MobileSourceVisibility.isHidden($0, collections: collections) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let goalsByID = Dictionary(
            goals.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return placements.compactMap { placement in
            guard let source = sourcesByID[placement.sourceID] else { return nil }
            let knownGoals = placement.goalIDs.compactMap { goalsByID[$0] }
            if !placement.isCompleted,
               !knownGoals.isEmpty,
               knownGoals.allSatisfy({ !$0.isActive }) {
                return nil
            }

            var seenTitles = Set<String>()
            let goalTitles = placement.goalIDs
                .compactMap { goalsByID[$0]?.title }
                .filter { !$0.isEmpty && seenTitles.insert($0).inserted }
            let groupTitle = source.parentGroup.flatMap { groupID in
                collections.booksByID[groupID]?.title ?? collections.coursesByID[groupID]?.title
            }
            return MobileScheduledCatalogItem(
                id: placement.id,
                source: source,
                plannedAt: placement.plannedAt,
                isCompleted: placement.isCompleted,
                completedAt: placement.completedAt,
                groupTitle: groupTitle,
                goalTitles: goalTitles,
                goalIDs: placement.goalIDs,
                activityDays: placement.activityDays,
                isAutomatic: placement.isAutomatic
            )
        }
        .sorted { $0.plannedAt < $1.plannedAt }
    }

    /// Posted after every checkpoint write. userInfo: "decoded" (sources so
    /// far), "pending" (records still to fetch), "walking" (true while the
    /// zone enumeration itself is still paging), "scanned" (zone records the
    /// walk has paged past, of every type — the only number that moves while
    /// the walk is crossing the stretches of records it does not collect,
    /// like usage events and chat history; survives interruptions),
    /// "fullPass" (true when the walk started from a nil token), plus when
    /// known "expectedScan" (the last full walk's total, the scan bar's
    /// denominator) and "drainTotal" (records this drain started with).
    static let syncProgressNotification = Notification.Name("MobileCatalogSyncProgress")

    func diagnose() async -> MobileSourceSyncDiagnostic {
        let checkedAt = Date()
        // No old container to ask: the replica is the library, and the session reports its rounds.
        return MobileSourceSyncDiagnostic(
            accountStatus: "not checked", knowledgeZoneStatus: "moved to the new iCloud store",
            sourceRecordCount: replicaSnapshot?.sources.count, decodedSourceCount: lastDecodedSourceCount,
            zoneRecordCount: nil, zoneRecordTypes: nil, errorMessage: nil, checkedAt: checkedAt
        )
    }

    /// Static because decoding a payload needs no CloudKit: the testing entry
    /// point below reaches it without constructing the catalog's container.
    private static func source(
        fromPayloadData payloadData: Data,
        decoder: JSONDecoder,
        dateFormatter: ISO8601DateFormatter
    ) -> MobileCloudSource? {
        if let payload = try? decoder.decode(MobileCloudSourcePayload.self, from: payloadData) {
            return MobileCloudSource(
                id: payload.article.id,
                title: payload.article.title,
                subtitle: MobileCloudSource.subtitle(fromDomain: payload.article.domain),
                sourceType: canonicalSourceType(payload.article.sourceType),
                dateAdded: payload.article.dateAdded ?? .distantPast,
                hasAudio: false,
                isArchived: payload.article.status == "archived",
                state: payload.article.state,
                author: payload.article.author,
                journal: payload.article.journal,
                publishedYear: payload.article.publishedYear,
                wordCount: payload.article.wordCount,
                parentGroup: payload.article.parentGroup,
                courseSortIndex: payload.article.courseSortIndex,
                isHidden: payload.article.isHidden,
                isPaywalled: payload.article.isPaywalled,
                visiblePodcastEpisodeOverride: payload.visiblePodcastEpisodeOverride ?? false,
                visibleYouTubeVideoOverride: payload.visibleYouTubeVideoOverride ?? false,
                artworkURL: payload.article.artworkURL,
                url: payload.article.url,
                localFilePath: payload.article.localFilePath,
                sourceReviewGuide: MobileSourceReviewGuidePayloadParser.reviewGuide(from: payloadData),
                listenableCharacterCount: payload.listenableContentMetadata?.characterCount,
                paperFigures: MobilePaperFigurePayloadParser.figures(from: payloadData),
                walkthroughDeck: MobileWalkthroughPayloadParser.deck(from: payloadData),
                readAt: payload.article.readAt,
                readingPositionLocator: payload.article.readingPositionLocator,
                normalizedURL: payload.sourceIdentity?.normalizedURL
                    ?? payload.article.normalizedURL,
                doi: payload.sourceIdentity?.doi ?? payload.article.doi,
                publishedDOI: payload.sourceIdentity?.publishedDOI
                    ?? payload.article.publishedDOI
            )
        }

        return fallbackSource(from: payloadData, dateFormatter: dateFormatter)
    }

    #if DEBUG
    /// Exercises the exact production catalog decoder from the iOS unit target.
    /// Keeping the fixture entry point here prevents tests from maintaining a
    /// second, subtly different interpretation of the Mac CloudKit envelope.
    /// Static so a test never touches `shared`: its init constructs a
    /// CKContainer, which traps in a test host built without code signing,
    /// since that host carries no iCloud entitlement.
    static func sourceFromCloudKitPayloadForTesting(_ payloadData: Data) -> MobileCloudSource? {
        source(
            fromPayloadData: payloadData,
            decoder: makePayloadDecoder(),
            dateFormatter: ISO8601DateFormatter()
        )
    }
    #endif


    // MARK: - Persistence

    /// Rows parsed from the mirror's raw payloads, rebuilt on demand — this
    /// rebuild is what replaces the old cache-invalidation-and-re-walk when a
    /// new build changes how payloads are read.
    private func assembled() -> AssembledCatalog {
        return AssembledCatalog()
    }

    private static func mirrorDatabaseURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // The mirror and its change token, per CloudKit environment (see above).
        var directory = applicationSupport
            .appendingPathComponent("ForeverLM", isDirectory: true)
            .appendingPathComponent(MobileCloudKitEnvironment.current.scopedName("MobileCatalog"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory.appendingPathComponent("knowledge.db")
    }

    private static func fallbackSource(
        from payloadData: Data,
        dateFormatter: ISO8601DateFormatter
    ) -> MobileCloudSource? {
        guard let object = try? JSONSerialization.jsonObject(with: payloadData, options: []) as? [String: Any],
              let article = object["article"] as? [String: Any],
              let id = article["id"] as? String,
              let title = article["title"] as? String else {
            return nil
        }

        let domain = article["domain"] as? String
        let sourceType = (article["sourceType"] as? String) ?? "article"
        let status = (article["status"] as? String) ?? "active"
        let state = (article["state"] as? String) ?? "ready"
        let parsedType = canonicalSourceType(sourceType)
        let author = article["author"] as? String
        let journal = article["journal"] as? String
        let publishedYear = article["publishedYear"] as? String
        let sourceIdentity = object["sourceIdentity"] as? [String: Any]
        let listenableMetadata = object["listenableContentMetadata"] as? [String: Any]

        let dateAdded: Date
        if let seconds = article["dateAdded"] as? Double {
            dateAdded = Self.decodeDate(from: seconds)
        } else if let seconds = article["dateAdded"] as? Int {
            dateAdded = Self.decodeDate(from: TimeInterval(seconds))
        } else if let timestamp = article["dateAdded"] as? String,
                  let parsed = dateFormatter.date(from: timestamp) {
            dateAdded = parsed
        } else if let timestamp = article["dateAdded"] as? String,
                  let seconds = Double(timestamp) {
            dateAdded = Self.decodeDate(from: seconds)
        } else {
            dateAdded = .distantPast
        }

        return MobileCloudSource(
            id: id,
            title: title,
            subtitle: MobileCloudSource.subtitle(fromDomain: domain),
            sourceType: parsedType,
            dateAdded: dateAdded,
            hasAudio: false,
            isArchived: status == "archived",
            state: state,
            author: author,
            journal: journal,
            publishedYear: publishedYear,
            wordCount: article["wordCount"] as? Int,
            parentGroup: (article["parentGroup"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            courseSortIndex: article["courseSortIndex"] as? Int,
            isHidden: (article["isHidden"] as? Bool) ?? false,
            isPaywalled: MobilePaywallShelf.isPaywalled(
                column: article["isPaywalled"] as? Bool,
                errorMessage: article["errorMessage"] as? String
            ),
            visiblePodcastEpisodeOverride: (object["visiblePodcastEpisodeOverride"] as? Bool) ?? false,
            visibleYouTubeVideoOverride: (object["visibleYouTubeVideoOverride"] as? Bool) ?? false,
            artworkURL: article["artworkURL"] as? String,
            url: article["url"] as? String,
            localFilePath: article["localFilePath"] as? String,
            sourceReviewGuide: MobileSourceReviewGuidePayloadParser.reviewGuide(from: payloadData),
            listenableCharacterCount: listenableMetadata?["characterCount"] as? Int,
            paperFigures: MobilePaperFigurePayloadParser.figures(from: payloadData),
            walkthroughDeck: MobileWalkthroughPayloadParser.deck(from: payloadData),
            readAt: Self.decodeFlexibleDate(article["readAt"]),
            readingPositionLocator: article["readingPositionLocator"] as? String,
            normalizedURL: sourceIdentity?["normalizedURL"] as? String
                ?? article["normalizedURL"] as? String,
            doi: sourceIdentity?["doi"] as? String
                ?? article["doi"] as? String,
            publishedDOI: sourceIdentity?["publishedDOI"] as? String
                ?? article["publishedDOI"] as? String
        )
    }

    private static func decodeDate(from seconds: TimeInterval) -> Date {
        if seconds > dateEpochCutoff {
            return Date(timeIntervalSince1970: seconds)
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func decodeFlexibleDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return decodeDate(from: number.doubleValue)
        }
        if let string = value as? String {
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            if let seconds = Double(string) { return decodeDate(from: seconds) }
        }
        return nil
    }

    // MARK: - Collection payload parses
    //
    // Tolerant JSONSerialization on purpose, like the Notebook parse: the Mac's
    // JSONEncoder authors these, historic payloads may predate fields, and one
    // odd record must never fail the batch. Older Book/Course payloads carried
    // only `name` (which doubled as the id), so both parses fall back to it.

    private static func trimmedNonEmpty(_ value: Any?) -> String? {
        guard let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func book(fromPayloadData data: Data) -> MobileCloudBook? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let name = trimmedNonEmpty(object["name"])
        guard let id = trimmedNonEmpty(object["id"]) ?? name else { return nil }
        return MobileCloudBook(
            id: id,
            title: trimmedNonEmpty(object["title"]) ?? name ?? id,
            author: trimmedNonEmpty(object["author"])
        )
    }

    private static func course(fromPayloadData data: Data) -> MobileCloudCourse? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let name = trimmedNonEmpty(object["name"])
        guard let id = trimmedNonEmpty(object["id"]) ?? name else { return nil }
        return MobileCloudCourse(
            id: id,
            title: trimmedNonEmpty(object["title"]) ?? name ?? id,
            institution: trimmedNonEmpty(object["institution"]),
            isHidden: (object["isHidden"] as? Bool) ?? false,
            lectures: courseLectures(from: object["lectures"]),
            lectureItems: courseLectureItems(from: object["lectureItems"]),
            quizzes: courseQuizzes(fromPayloadData: data)
        )
    }

    private struct CourseQuizzesEnvelope: Decodable {
        let quizzes: [CourseQuiz]?
    }

    /// The course's quizzes, decoded as the Mac encodes them
    /// (`CloudKitCoursePayload.quizzes`, `JSONEncoder` defaults). A course
    /// from a build that carried none, or a quiz this build cannot read, leaves
    /// the course without quizzes rather than without its outline.
    private static func courseQuizzes(fromPayloadData data: Data) -> [CourseQuiz] {
        do {
            return try JSONDecoder().decode(CourseQuizzesEnvelope.self, from: data).quizzes ?? []
        } catch {
            syncLogger.error("Course quizzes could not be decoded: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// The course outline the Mac syncs on the Course record. Membership lives
    /// here rather than on the member sources, so a course with no readable
    /// outline is a course the phone cannot group.
    private static func courseLectures(from value: Any?) -> [MobileCourseLecture] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = trimmedNonEmpty(row["id"]),
                  let number = (row["number"] as? NSNumber)?.intValue else { return nil }
            return MobileCourseLecture(id: id, number: number, title: trimmedNonEmpty(row["title"]))
        }
    }

    /// Items pointing at a source unit rather than a whole source are dropped:
    /// the phone's lists only open whole sources.
    private static func courseLectureItems(from value: Any?) -> [MobileCourseLectureItem] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = trimmedNonEmpty(row["id"]),
                  let lectureID = trimmedNonEmpty(row["lectureId"]),
                  let sourceID = trimmedNonEmpty(row["sourceId"]) else { return nil }
            return MobileCourseLectureItem(
                id: id,
                lectureID: lectureID,
                sourceID: sourceID,
                role: trimmedNonEmpty(row["role"]) ?? "other",
                sortIndex: (row["sortIndex"] as? NSNumber)?.intValue ?? 0
            )
        }
    }

    private static func hiddenPodcastShowName(fromPayloadData data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return trimmedNonEmpty(object["showName"])
    }

    private static func hiddenYouTubeChannelName(fromPayloadData data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return trimmedNonEmpty(object["channelName"])
    }

    /// The Mac's `CloudKitHiddenArtifactPayload`: `{artifactID, hiddenAt}`.
    private static func hiddenArtifactID(fromPayloadData data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return trimmedNonEmpty(object["artifactID"])
    }

    /// `CloudKitHiddenReviewSessionPayload.sessionID`.
    private static func hiddenReviewSessionID(fromPayloadData data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return trimmedNonEmpty(object["sessionID"])
    }

    private static func meetingGroup(fromPayloadData data: Data) -> MeetingGroupVisibility? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = trimmedNonEmpty(object["id"]) else {
            return nil
        }
        return MeetingGroupVisibility(id: id, isHidden: (object["isHidden"] as? Bool) ?? false)
    }

    private static func describe(_ error: Error) -> String {
        if let ckError = error as? CKError {
            return "CloudKit \(ckError.code.rawValue) (\(ckError.code)): \(ckError.localizedDescription)"
        }
        return error.localizedDescription
    }

}

/// One zone record as the walk last saw it: the record type for every record
/// in the zone, plus the raw payload bytes for the types this catalog
/// collects (index-only types carry nil). Persisting bytes instead of parsed
/// rows is what frees app updates from re-walking the zone: a new build
/// re-parses locally, and the change token stays valid.
private struct PersistedZoneRecord: Codable {
    let type: String
    var payload: Data?
}

/// The catalog's on-disk state: a mirror of the Knowledge zone — record
/// names and types, raw payloads for collected types, and the change token
/// that produced them. Lives in Application Support — Xcode rebuilds preserve
/// it, while losing app data costs one slow full pass and never knowledge data.
///
/// Migration invariant, the reverse of the parsed-row cache this replaced:
/// this shape must almost never change. Parsed rows live only in memory
/// (`AssembledCatalog`), so payload-shape churn — new fields, changed parse
/// rules — needs no version bump and keeps the token. A record type newly
/// collected catches up from the name index by ID fetch (`collectedRecordTypes`),
/// not by a re-walk. Only a change to THIS struct still costs a full pass:
/// non-Optional fields are required keys, so an old file fails to decode and
/// falls back to a fresh mirror. Keep additions Optional unless a stale value
/// is genuinely unsafe.
private struct PersistedZoneMirror: Codable {
    var recordsByName: [String: PersistedZoneRecord] = [:]
    /// Record names the zone walk has delivered but whose payloads are not yet
    /// fetched. Non-empty exactly when a sync was interrupted mid-drain; the
    /// change token below is only meaningful together with this list.
    var pendingRecordNames: [String] = []
    /// The record types whose payloads this mirror has been collecting. A
    /// build that starts collecting a new type diffs against this, fetches
    /// the already-indexed records of that type by ID, and moves on — seconds
    /// of catch-up instead of a minutes-long re-walk.
    var collectedRecordTypes: [String] = []
    /// Records scanned so far by the walk in progress. Persisted so a resumed
    /// walk's progress line keeps climbing instead of restarting at zero;
    /// reset when the walk's last page lands.
    var walkScannedCount: Int = 0
    /// True while the walk in progress started from scratch (nil token) —
    /// kept across interruptions so only genuine full passes update
    /// `lastFullWalkScannedCount` below.
    var walkIsFullPass: Bool = false
    /// Total records the last completed from-scratch walk scanned — the
    /// denominator that turns the next full walk's spinner into a real bar.
    var lastFullWalkScannedCount: Int?
    /// True once any pass has completed end to end (walk + drain). The "first
    /// sync" UI treatment keys off this rather than the change token: interim
    /// tokens land with the very first checkpoint, so a first pass resumed
    /// after an interruption still counts as the first sync.
    var hasCompletedInitialSync: Bool = false
    /// Optional for backward decoding. A versioned full name/payload audit can
    /// heal a bad-but-decodable CloudKit token without deleting this mirror.
    var indexAuditVersion: Int?
    /// Persisted so an interrupted reconciliation resumes from its checkpoint
    /// rather than repeatedly restarting the full zone walk.
    var indexAuditInProgress: Bool?
    /// Identifies the audit implementation that owns an in-progress token, so
    /// an app update can safely restart an older audit with its own invariants.
    var indexAuditTargetVersion: Int?
    /// Record names observed during the resumable nil-token audit. The final
    /// page uses this to prune records belonging only to a previously selected
    /// CloudKit environment without hiding the existing catalog mid-walk.
    var indexAuditSeenRecordNames: [String]?
    /// Migration-only copy of the previous parsed-row cache. Optional so
    /// existing SQLite mirrors keep decoding. It keeps the old library usable
    /// while the raw payloads hydrate by record ID, then is cleared.
    var legacyCatalogData: Data?
    /// `CKServerChangeToken` is NSSecureCoding rather than Codable, so it rides
    /// along archived.
    private var changeTokenData: Data?

    var changeToken: CKServerChangeToken? {
        get {
            guard let changeTokenData else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self,
                from: changeTokenData
            )
        }
        set {
            changeTokenData = newValue.flatMap {
                try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
        }
    }
}

/// Decoder for the parsed-row cache written by builds immediately before the
/// durable raw mirror. These types are migration-only: they preserve the last
/// visible catalog and its change token while the original payloads hydrate.
private struct LegacyPersistedCatalog: Decodable {
    var sourcesByRecordName: [String: LegacyPersistedSource]
    var notebooksByRecordName: [String: LegacyPersistedNotebook]
    var booksByRecordName: [String: LegacyPersistedBook]
    var coursesByRecordName: [String: LegacyPersistedCourse]
    var hiddenPodcastShowsByRecordName: [String: String]
    var meetingGroupsByRecordName: [String: LegacyPersistedMeetingGroup]
    var pendingRecordNames: [String]
    private var changeTokenData: Data?

    var changeToken: CKServerChangeToken? {
        guard let changeTokenData else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: changeTokenData
        )
    }

    var assembledCatalog: AssembledCatalog {
        var catalog = AssembledCatalog()
        for (name, source) in sourcesByRecordName {
            catalog.sourcesByRecordName[name] = source.source
        }
        for (name, notebook) in notebooksByRecordName {
            catalog.notebooksByRecordName[name] = notebook.notebook
        }
        for (name, persistedBook) in booksByRecordName {
            var book = persistedBook.book
            book.recordName = name
            catalog.booksByRecordName[name] = book
        }
        for (name, course) in coursesByRecordName {
            catalog.coursesByRecordName[name] = course.course
        }
        catalog.hiddenPodcastShowsByRecordName = hiddenPodcastShowsByRecordName
        catalog.meetingGroupsByRecordName = meetingGroupsByRecordName.mapValues(\.visibility)
        return catalog
    }

    func fillMissingRows(
        in catalog: inout AssembledCatalog,
        recordsByName: [String: PersistedZoneRecord]
    ) {
        for (name, source) in sourcesByRecordName
        where recordsByName[name]?.payload == nil {
            catalog.sourcesByRecordName[name] = source.source
        }
        for (name, notebook) in notebooksByRecordName
        where recordsByName[name]?.payload == nil {
            catalog.notebooksByRecordName[name] = notebook.notebook
        }
        for (name, persistedBook) in booksByRecordName
        where recordsByName[name]?.payload == nil {
            var book = persistedBook.book
            book.recordName = name
            catalog.booksByRecordName[name] = book
        }
        for (name, course) in coursesByRecordName
        where recordsByName[name]?.payload == nil {
            catalog.coursesByRecordName[name] = course.course
        }
        for (name, showName) in hiddenPodcastShowsByRecordName
        where recordsByName[name]?.payload == nil {
            catalog.hiddenPodcastShowsByRecordName[name] = showName
        }
        for (name, group) in meetingGroupsByRecordName
        where recordsByName[name]?.payload == nil {
            catalog.meetingGroupsByRecordName[name] = group.visibility
        }
    }
}

private struct LegacyPersistedSource: Decodable {
    let id: String
    let title: String
    let subtitle: String?
    let sourceType: String
    let dateAdded: Date
    let hasAudio: Bool
    let isArchived: Bool
    let author: String?
    let journal: String?
    let publishedYear: String?
    let parentGroup: String?
    let courseSortIndex: Int?
    let isHidden: Bool
    let visiblePodcastEpisodeOverride: Bool
    let artworkURL: String?
    let url: String?
    let localFilePath: String?

    var source: MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title,
            subtitle: subtitle,
            sourceType: sourceType,
            dateAdded: dateAdded,
            hasAudio: hasAudio,
            isArchived: isArchived,
            author: author,
            journal: journal,
            publishedYear: publishedYear,
            parentGroup: parentGroup,
            courseSortIndex: courseSortIndex,
            isHidden: isHidden,
            visiblePodcastEpisodeOverride: visiblePodcastEpisodeOverride,
            artworkURL: artworkURL,
            url: url,
            localFilePath: localFilePath
        )
    }
}

private struct LegacyPersistedNotebook: Decodable {
    let id: String
    let title: String
    let instructions: String?
    let sourceIDs: [String]
    let isArchived: Bool
    let updatedAt: Date

    var notebook: MobileCloudNotebook {
        MobileCloudNotebook(
            id: id,
            title: title,
            instructions: instructions,
            sourceIDs: sourceIDs,
            isArchived: isArchived,
            updatedAt: updatedAt
        )
    }
}

private struct LegacyPersistedBook: Decodable {
    let id: String
    let title: String
    let author: String?

    var book: MobileCloudBook {
        MobileCloudBook(id: id, title: title, author: author)
    }
}

private struct LegacyPersistedCourse: Decodable {
    let id: String
    let title: String
    let institution: String?
    let isHidden: Bool

    var course: MobileCloudCourse {
        MobileCloudCourse(id: id, title: title, institution: institution, isHidden: isHidden)
    }
}

private struct LegacyPersistedMeetingGroup: Decodable {
    let id: String
    let isHidden: Bool

    var visibility: MeetingGroupVisibility {
        MeetingGroupVisibility(id: id, isHidden: isHidden)
    }
}

/// Durable, non-purgeable storage for the iPhone's CloudKit zone cursor and
/// raw-payload mirror. The whole Codable snapshot is one SQLite row so each
/// checkpoint is atomic: the token can never advance without the pending names
/// and payloads delivered with it. The database lives in Application Support,
/// which Xcode app rebuilds preserve; only uninstalling the app removes it.
private final class MobileZoneMirrorStore {
    private static let schemaVersion: Int32 = 2
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            if let opened { sqlite3_close(opened) }
            throw MobileZoneMirrorStoreError.sqlite(message)
        }
        database = opened

        do {
            try migrateIfNeeded()
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func load() throws -> PersistedZoneMirror? {
        guard let database else { throw MobileZoneMirrorStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT state FROM mobile_cloud_zone_mirror WHERE id = 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw sqliteError()
        }
        let byteCount = Int(sqlite3_column_bytes(statement, 0))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, 0) else {
            throw MobileZoneMirrorStoreError.invalidSnapshot
        }
        let data = Data(bytes: bytes, count: byteCount)
        do {
            return try JSONDecoder().decode(PersistedZoneMirror.self, from: data)
        } catch {
            throw MobileZoneMirrorStoreError.decode(error.localizedDescription)
        }
    }

    func save(_ state: PersistedZoneMirror) throws {
        guard let database else { throw MobileZoneMirrorStoreError.closed }
        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            throw MobileZoneMirrorStoreError.encode(error.localizedDescription)
        }

        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO mobile_cloud_zone_mirror (id, state) VALUES (1, ?) " +
                    "ON CONFLICT(id) DO UPDATE SET state = excluded.state",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw sqliteError()
            }
            defer { sqlite3_finalize(statement) }

            let bindResult = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    1,
                    bytes.baseAddress,
                    Int32(bytes.count),
                    Self.transientDestructor
                )
            }
            guard bindResult == SQLITE_OK else { throw sqliteError() }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func loadUsageHistorySnapshot() throws -> MobileUsageHistorySnapshot? {
        guard let database else { throw MobileZoneMirrorStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT state FROM mobile_usage_history_cache WHERE id = 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError() }
        let byteCount = Int(sqlite3_column_bytes(statement, 0))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, 0) else {
            throw MobileZoneMirrorStoreError.invalidSnapshot
        }
        do {
            return try JSONDecoder().decode(
                MobileUsageHistorySnapshot.self,
                from: Data(bytes: bytes, count: byteCount)
            )
        } catch {
            throw MobileZoneMirrorStoreError.decode(error.localizedDescription)
        }
    }

    func saveUsageHistorySnapshot(_ snapshot: MobileUsageHistorySnapshot) throws {
        guard let database else { throw MobileZoneMirrorStoreError.closed }
        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            throw MobileZoneMirrorStoreError.encode(error.localizedDescription)
        }

        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO mobile_usage_history_cache (id, state) VALUES (1, ?) " +
                    "ON CONFLICT(id) DO UPDATE SET state = excluded.state",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw sqliteError()
            }
            defer { sqlite3_finalize(statement) }
            let bindResult = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    1,
                    bytes.baseAddress,
                    Int32(bytes.count),
                    Self.transientDestructor
                )
            }
            guard bindResult == SQLITE_OK else { throw sqliteError() }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func migrateIfNeeded() throws {
        guard let database else { throw MobileZoneMirrorStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        let version = sqlite3_column_int(statement, 0)

        guard version <= Self.schemaVersion else {
            throw MobileZoneMirrorStoreError.unsupportedSchema(version)
        }
        guard version < Self.schemaVersion else { return }

        try execute("BEGIN IMMEDIATE")
        do {
            if version < 1 {
                try execute(
                    "CREATE TABLE IF NOT EXISTS mobile_cloud_zone_mirror (" +
                        "id INTEGER PRIMARY KEY CHECK (id = 1), " +
                        "state BLOB NOT NULL)"
                )
            }
            if version < 2 {
                try execute(
                    "CREATE TABLE IF NOT EXISTS mobile_usage_history_cache (" +
                        "id INTEGER PRIMARY KEY CHECK (id = 1), " +
                        "state BLOB NOT NULL)"
                )
            }
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw MobileZoneMirrorStoreError.closed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw MobileZoneMirrorStoreError.sqlite(message)
        }
    }

    private func sqliteError() -> MobileZoneMirrorStoreError {
        guard let database else { return .closed }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private enum MobileZoneMirrorStoreError: LocalizedError {
    case closed
    case sqlite(String)
    case encode(String)
    case decode(String)
    case invalidSnapshot
    case unsupportedSchema(Int32)

    var errorDescription: String? {
        switch self {
        case .closed:
            return "The mobile source catalog database is closed."
        case .sqlite(let message):
            return "The mobile source catalog database failed: \(message)"
        case .encode(let message):
            return "The mobile source catalog could not be encoded: \(message)"
        case .decode(let message):
            return "The saved mobile source catalog could not be decoded: \(message)"
        case .invalidSnapshot:
            return "The saved mobile source catalog is empty or corrupt."
        case .unsupportedSchema(let version):
            return "The mobile source catalog database uses unsupported schema version \(version)."
        }
    }
}

/// The rows every consumer reads, parsed from the mirror's raw payloads.
/// In-memory only and deliberately not Codable: its shape can churn freely
/// with the product without ever invalidating the synced mirror on disk.
private struct AssembledCatalog {
    var sourcesByRecordName: [String: MobileCloudSource] = [:]
    var sourceHighlightsByRecordName: [String: SourceHighlight] = [:]
    var rawSourceHighlightsByRecordName: [String: SourceHighlight] = [:]
    var sourceHighlightIdentitiesByRecordName: [String: MobileMemorySourceIdentity] = [:]
    var artifactsByRecordName: [String: MobileCloudArtifactProjection] = [:]
    /// The same records as a notebook's Studio lists them (Docs above all);
    /// archived ones are absent.
    var notebookArtifactsByRecordName: [String: MobileCloudArtifact] = [:]
    /// Hidden docs' artifact ids, by their HiddenArtifact record's name; an
    /// unhide arrives as that record's deletion.
    var hiddenArtifactIDsByRecordName: [String: String] = [:]
    /// Hidden chats' session ids, by their HiddenReviewSession record's name.
    var hiddenReviewSessionIDsByRecordName: [String: String] = [:]
    var notebooksByRecordName: [String: MobileCloudNotebook] = [:]
    var rawNotebooksByRecordName: [String: MobileCloudNotebook] = [:]
    var notebookSourceIdentitiesByRecordName: [String: [MobileMemorySourceIdentity]] = [:]
    var goalsByRecordName: [String: MobileCloudGoal] = [:]
    var scheduledSourcesByRecordName: [String: MobileCloudScheduledSource] = [:]
    var rawScheduledSourcesByRecordName: [String: MobileCloudScheduledSource] = [:]
    var memoryItemsByRecordName: [String: MemoryItem] = [:]
    var rawMemoryItemsByRecordName: [String: MemoryItem] = [:]
    var memoryItemSourceIdentitiesByRecordName: [String: [MobileMemorySourceIdentity]] = [:]
    var memoryAttemptsByRecordName: [String: MemoryAttempt] = [:]
    var rawMemoryAttemptsByRecordName: [String: MobileCloudMemoryAttemptPayload] = [:]
    var reviewSessionsByRecordName: [String: MobileCloudReviewSessionProjection] = [:]
    var sourceIdeasByRecordName: [String: SourceIdea] = [:]
    var booksByRecordName: [String: MobileCloudBook] = [:]
    var coursesByRecordName: [String: MobileCloudCourse] = [:]
    /// Record name → hidden show name (`CloudKitHiddenPodcastShowPayload.showName`).
    var hiddenPodcastShowsByRecordName: [String: String] = [:]
    var hiddenYouTubeChannelsByRecordName: [String: String] = [:]
    var meetingGroupsByRecordName: [String: MeetingGroupVisibility] = [:]

    mutating func removeRecord(named name: String) {
        sourcesByRecordName.removeValue(forKey: name)
        sourceIdeasByRecordName.removeValue(forKey: name)
        sourceHighlightsByRecordName.removeValue(forKey: name)
        rawSourceHighlightsByRecordName.removeValue(forKey: name)
        sourceHighlightIdentitiesByRecordName.removeValue(forKey: name)
        artifactsByRecordName.removeValue(forKey: name)
        notebookArtifactsByRecordName.removeValue(forKey: name)
        hiddenArtifactIDsByRecordName.removeValue(forKey: name)
        hiddenReviewSessionIDsByRecordName.removeValue(forKey: name)
        notebooksByRecordName.removeValue(forKey: name)
        rawNotebooksByRecordName.removeValue(forKey: name)
        notebookSourceIdentitiesByRecordName.removeValue(forKey: name)
        goalsByRecordName.removeValue(forKey: name)
        scheduledSourcesByRecordName.removeValue(forKey: name)
        rawScheduledSourcesByRecordName.removeValue(forKey: name)
        memoryItemsByRecordName.removeValue(forKey: name)
        rawMemoryItemsByRecordName.removeValue(forKey: name)
        memoryItemSourceIdentitiesByRecordName.removeValue(forKey: name)
        memoryAttemptsByRecordName.removeValue(forKey: name)
        rawMemoryAttemptsByRecordName.removeValue(forKey: name)
        reviewSessionsByRecordName.removeValue(forKey: name)
        booksByRecordName.removeValue(forKey: name)
        coursesByRecordName.removeValue(forKey: name)
        hiddenPodcastShowsByRecordName.removeValue(forKey: name)
        hiddenYouTubeChannelsByRecordName.removeValue(forKey: name)
        meetingGroupsByRecordName.removeValue(forKey: name)
    }

    /// Resolve portable MemoryItem and Schedule relationships after all
    /// currently known Source payloads have been parsed. Delivery order is
    /// arbitrary, so this is a projection over the assembled mirror rather
    /// than an apply-time assumption. Exact IDs win; URL/DOI only reconcile a
    /// missing device-local ID.
    mutating func reconcilePortableSourceIdentities() {
        let sources = Array(sourcesByRecordName.values)
        let identityIndex = MobileMemorySourceIdentityResolver.Index(
            sources: sources,
            normalizeURL: MobileSourceURL.normalize
        )
        for recordName in memoryItemsByRecordName.keys.sorted() {
            guard let item = rawMemoryItemsByRecordName[recordName]
                ?? memoryItemsByRecordName[recordName] else { continue }
            memoryItemsByRecordName[recordName] = identityIndex.remap(
                item: item,
                identities: memoryItemSourceIdentitiesByRecordName[recordName] ?? []
            )
        }
        for recordName in sourceHighlightsByRecordName.keys.sorted() {
            guard let highlight = rawSourceHighlightsByRecordName[recordName]
                    ?? sourceHighlightsByRecordName[recordName] else { continue }
            let resolvedSourceID = identityIndex.resolvedSourceID(
                highlight.sourceID,
                identity: sourceHighlightIdentitiesByRecordName[recordName]
            )
            guard resolvedSourceID != highlight.sourceID else { continue }
            sourceHighlightsByRecordName[recordName] = SourceHighlight(
                id: highlight.id,
                sourceID: resolvedSourceID,
                quote: highlight.quote,
                note: highlight.note,
                color: highlight.color,
                anchor: highlight.anchor,
                pdfAnchor: highlight.pdfAnchor,
                imageAnchors: highlight.imageAnchors,
                chatSessionID: highlight.chatSessionID,
                references: highlight.references,
                publicationUpdate: highlight.publicationUpdate,
                publicationUpdateAt: highlight.publicationUpdateAt,
                createdAt: highlight.createdAt,
                updatedAt: highlight.updatedAt
            )
        }
        memoryAttemptsByRecordName = MobileMemoryAttemptCurriculumProjection.compatibleAttempts(
            items: Array(memoryItemsByRecordName.values),
            envelopesByRecordName: rawMemoryAttemptsByRecordName
        )
        for recordName in notebooksByRecordName.keys.sorted() {
            guard let notebook = rawNotebooksByRecordName[recordName]
                ?? notebooksByRecordName[recordName] else { continue }
            notebooksByRecordName[recordName] = MobileNotebookSourceIdentityResolver.remap(
                notebook: notebook,
                identities: notebookSourceIdentitiesByRecordName[recordName] ?? [],
                identityIndex: identityIndex
            )
        }
        for recordName in scheduledSourcesByRecordName.keys.sorted() {
            guard let placement = rawScheduledSourcesByRecordName[recordName]
                ?? scheduledSourcesByRecordName[recordName] else { continue }
            let resolvedSourceID = identityIndex.resolvedSourceID(
                placement.sourceID,
                identity: placement.sourceIdentity
            )
            guard resolvedSourceID != placement.sourceID else { continue }
            scheduledSourcesByRecordName[recordName] = MobileCloudScheduledSource(
                id: placement.id,
                sourceID: resolvedSourceID,
                sourceIdentity: placement.sourceIdentity,
                plannedAt: placement.plannedAt,
                completedAt: placement.completedAt,
                goalIDs: placement.goalIDs,
                updatedAt: placement.updatedAt,
                activityDays: placement.activityDays,
                isAutomatic: placement.isAutomatic
            )
        }
    }
}

/// An audio overview the Mac saved for a notebook (docs/explainer-design.md,
/// "Audio overviews"): its Artifact, read from the synced record, and the id
/// of the carrier source its script and audio live on.
struct MobileAudioOverviewRecord: Identifiable, Equatable, Sendable {
    /// `ArtifactKind.audioOverview`'s raw value. The Mac's `Artifacts.swift`
    /// is not compiled here; `MobileCloudMutationServiceTests` pins the word.
    static let artifactKind = "audio_overview"

    let id: String
    let title: String?
    let notebookIDs: Set<String>
    let createdAt: Date?
    let carrierSourceID: String
}

/// One audio overview as a notebook's page lists it: its title and the
/// carrier source it plays through, the way any source plays here.
struct MobileAudioOverviewListing: Identifiable, Equatable {
    let id: String
    let title: String
    let carrier: MobileCloudSource
}

/// CloudKitRecordMapper is not compiled into the iOS target, so mobile mirrors
/// the small envelope shapes it needs while reusing canonical portable models
/// where the iOS target includes them.
private struct MobileCloudArtifactPayload: Decodable {
    let artifact: MobileCloudArtifactProjection
}

private struct MobileCloudSourceHighlightPayload: Decodable {
    let highlight: SourceHighlight
    let sourceIdentity: MobileMemorySourceIdentity?

    private enum CodingKeys: String, CodingKey {
        case highlight
        case sourceIdentity
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        highlight = try values.decode(SourceHighlight.self, forKey: .highlight)
        sourceIdentity = try values.decodeIfPresent(
            MobileMemorySourceIdentity.self,
            forKey: .sourceIdentity
        )
    }
}

private struct MobileCloudArtifactProjection: Decodable {
    let id: String
    let homeNotebookID: String?
    let linkedNotebookIDs: [String]
    /// What the record is — the Mac's `ArtifactKind` raw value — nil for a
    /// Doc or a linked page. Read so a notebook can list its audio overviews.
    let kind: String?
    let title: String?
    let createdAt: Date?
    /// When the learner archived it; nil while it is current.
    let archivedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case homeNotebookID
        case linkedNotebookIDs
        case kind
        case title
        case createdAt
        case archivedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        homeNotebookID = try container.decodeIfPresent(String.self, forKey: .homeNotebookID)
        linkedNotebookIDs = try container.decodeIfPresent([String].self, forKey: .linkedNotebookIDs) ?? []
        // The fields a listing reads never refuse the record: a value this
        // build cannot read is left out, and the record still links its Notebooks.
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
        archivedAt = (try? container.decodeIfPresent(Date.self, forKey: .archivedAt)) ?? nil
    }
}

private struct MobileCloudMemoryItemPayload: Decodable {
    let payloadVersion: Int
    let item: MemoryItem
    let sourceIdentities: [MobileMemorySourceIdentity]

    private enum CodingKeys: String, CodingKey {
        case payloadVersion
        case item
        case sourceIdentities
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        payloadVersion = try values.decodeIfPresent(Int.self, forKey: .payloadVersion) ?? 0
        item = try values.decode(MemoryItem.self, forKey: .item)
        sourceIdentities = try values.decodeIfPresent(
            [MobileMemorySourceIdentity].self,
            forKey: .sourceIdentities
        ) ?? []
    }
}

/// Minimal whole-source review history needed to bootstrap concept memories on
/// a phone upgraded from the legacy review rail. The full transcript stays in
/// its canonical ReviewSession record; this projection only derives the same
/// per-source dates/counts/scores as the Mac scheduler.
private struct MobileCloudReviewSessionProjection: Decodable {
    let id: String
    /// The chat's title, as the Mac stores it. What a chat is called when it
    /// enters the memory review as material of its own (`ReviewableChat`).
    let topic: String?
    let startedAt: Date
    let endedAt: Date?
    let status: String
    let overallScore: Double?
    let sourceIDs: [String]
    let cardIDs: [String]
    let goalID: String?
    let exchanges: [MobileCloudReviewExchangeProjection]
    let sourceIdentities: [MobileMemorySourceIdentity]
    /// `ReviewSessionKind`; nil from a client older than schema 89.
    let kind: String?
    /// The model the chat's last reply ran on; what a continued chat's model
    /// chip starts on when the learner offers it.
    let modelID: String?

    /// A memory review, by kind or by the day-named id older records carry.
    var isMemoryReview: Bool {
        kind == ReviewSessionKind.memory.rawValue || MemoryReviewSession.isMemorySession(id)
    }

    /// When the learner last wrote in this session: the latest answered
    /// exchange with a message of theirs, else the session's end when they
    /// wrote at all. The chat evidence on its sources dates from this.
    var lastLearnerTurnAt: Date? {
        let spoken = exchanges.filter { !($0.userAnswer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !spoken.isEmpty else { return nil }
        return spoken.compactMap(\.answeredAt).max() ?? endedAt ?? startedAt
    }

    /// The exchanges as a read-only transcript reads them
    /// (`MobileChatTranscriptTurns`).
    var transcriptExchanges: [MobileChatTranscriptTurns.Exchange] {
        exchanges.map {
            MobileChatTranscriptTurns.Exchange(
                sequenceNumber: $0.sequenceNumber,
                question: $0.question,
                userAnswer: $0.userAnswer,
                evaluation: $0.evaluation
            )
        }
    }

    /// The exchanges as the portable chat rules read them.
    var reviewableExchanges: [ReviewableChat.Exchange] {
        exchanges.map {
            ReviewableChat.Exchange(
                sequenceNumber: $0.sequenceNumber,
                question: $0.question,
                userAnswer: $0.userAnswer,
                evaluation: $0.evaluation,
                score: $0.score,
                ideaCoverage: $0.ideaCoverage,
                answeredAt: $0.answeredAt
            )
        }
    }

    /// What would make this session a chat worth recalling. The phone does
    /// not sync scheduled-task runs, so a task's chat is not told apart here.
    var reviewableChatSummary: ReviewableChat.Summary {
        ReviewableChat.summary(
            title: topic ?? "Chat",
            kind: kind,
            hasCardIDs: !cardIDs.isEmpty,
            overallScore: overallScore,
            exchanges: reviewableExchanges,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case topic
        case startedAt
        case endedAt
        case status
        case overallScore
        case sourceIDs
        case cardIDs
        case goalID
        case exchanges
        case sourceIdentities
        case kind
        case modelID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(String.self, forKey: .kind)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID)
        id = try values.decode(String.self, forKey: .id)
        topic = try values.decodeIfPresent(String.self, forKey: .topic)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        status = try values.decode(String.self, forKey: .status)
        overallScore = try values.decodeIfPresent(Double.self, forKey: .overallScore)
        sourceIDs = try values.decodeIfPresent([String].self, forKey: .sourceIDs) ?? []
        cardIDs = try values.decodeIfPresent([String].self, forKey: .cardIDs) ?? []
        goalID = try values.decodeIfPresent(String.self, forKey: .goalID)
        exchanges = try values.decodeIfPresent(
            [MobileCloudReviewExchangeProjection].self,
            forKey: .exchanges
        ) ?? []
        sourceIdentities = try values.decodeIfPresent(
            [MobileMemorySourceIdentity].self,
            forKey: .sourceIdentities
        ) ?? []
    }
}

private struct MobileCloudReviewExchangeProjection: Decodable {
    let sourceRefs: [String]
    let sequenceNumber: Int
    /// The turn's words, for a chat that enters the review as material:
    /// the tutor's question or opening, the learner's message, the reply.
    let question: String
    let userAnswer: String?
    let evaluation: String?
    let score: Double?
    /// The memory review's grade of this exchange, when it was a contour.
    let ideaCoverage: String?
    let questionVerdict: String?
    let answeredAt: Date?

    private enum CodingKeys: String, CodingKey {
        case sourceRefs, sequenceNumber, question, userAnswer, evaluation, score
        case ideaCoverage, questionVerdict, answeredAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceRefs = try values.decodeIfPresent([String].self, forKey: .sourceRefs) ?? []
        sequenceNumber = try values.decodeIfPresent(Int.self, forKey: .sequenceNumber) ?? 0
        question = try values.decodeIfPresent(String.self, forKey: .question) ?? ""
        userAnswer = try values.decodeIfPresent(String.self, forKey: .userAnswer)
        evaluation = try values.decodeIfPresent(String.self, forKey: .evaluation)
        score = try values.decodeIfPresent(Double.self, forKey: .score)
        ideaCoverage = try values.decodeIfPresent(String.self, forKey: .ideaCoverage)
        questionVerdict = try values.decodeIfPresent(String.self, forKey: .questionVerdict)
        answeredAt = try values.decodeIfPresent(Date.self, forKey: .answeredAt)
    }
}

/// The synced idea record: `CloudKitSourceIdeaPayload` as the phone reads it.
private struct MobileCloudSourceIdeaPayload: Decodable {
    let idea: SourceIdea
}

private struct MeetingGroupVisibility {
    let id: String
    let isHidden: Bool
}

/// Reads a synced record's JSON payload in either form it travels in: the
/// encrypted inline `payload` field, or — once a payload outgrows
/// `inlinePayloadByteLimit` — the `payloadAsset` CKAsset the writer moved it
/// into with the inline field cleared. The Mac's
/// `CloudKitRecordMapper.payloadData(from:)` and `MobileReviewSessionRecorder`
/// read the same two places; the catalog sync did not read the asset until
/// 2026-09-10, so an oversized review arrived "without its catalog payload".
enum MobileCloudRecordPayload {
    /// A record's payload, its keys as this build names them (`RetiredNotebookWording`).
    static func data(from record: CKRecord, payloadField: String, assetField: String) -> Data? {
        storedData(from: record, payloadField: payloadField, assetField: assetField)
            .map(RetiredNotebookWording.currentPayload)
    }

    private static func storedData(from record: CKRecord, payloadField: String, assetField: String) -> Data? {
        if let data = record.encryptedValues[payloadField] as? Data {
            return data
        }
        if let data = record.encryptedValues[payloadField] as? NSData {
            return data as Data
        }
        if let data = record[payloadField] as? Data {
            return data
        }
        if let data = record[payloadField] as? NSData {
            return data as Data
        }
        if let asset = record[assetField] as? CKAsset,
           let url = asset.fileURL,
           let data = try? Data(contentsOf: url),
           !data.isEmpty {
            return data
        }
        return nil
    }
}

private enum MobileCloudSourceCatalogError: LocalizedError {
    case missingKnowledgeZone
    case replicaUnavailable

    var errorDescription: String? {
        switch self {
        case .missingKnowledgeZone:
            return "CloudKit returned no Knowledge zone."
        case .replicaUnavailable:
            return "This iPhone's copy of your library could not be opened."
        }
    }
}

/// A source's text on the phone: the canonical `text` satellite (§3.5.30), fetched by name, with the
/// saved-offline copy and the disk cache in front of it.
actor MobileCloudSourceTextStore {
    static let shared = MobileCloudSourceTextStore()

    private var cachedText: [String: String] = [:]

    /// Text this phone wrote itself — an explainer's script — entered the way
    /// a fetch would enter it, so Listen and the reader read it at once rather
    /// than waiting for its satellite to come back.
    func storeSourceText(_ text: String, sourceID: String) async {
        cachedText[sourceID] = text
        await MobileSourceFileStore.shared.storeText(text, sourceID: sourceID)
    }

    func loadSourceText(sourceID: String, expectedSHA256: String? = nil) async throws -> String {
        if let cached = cachedText[sourceID],
           !cached.isEmpty,
           Self.matchesExpectedHash(cached, expectedSHA256: expectedSHA256) {
            return cached
        }

        // A saved-offline copy outranks the cache: it is the only copy the OS
        // cannot purge, and on a plane it is the only copy at all. An expected
        // hash still governs — stale text falls through to the fetch below,
        // which rewrites the saved copy.
        if let saved = await MobileOfflineSourceStore.shared.savedText(sourceID: sourceID),
           Self.matchesExpectedHash(saved, expectedSHA256: expectedSHA256) {
            cachedText[sourceID] = saved
            return saved
        }

        // Disk cache next: a cold launch should not need a round trip for text
        // that was already on this phone yesterday. Pull-to-refresh repopulates
        // it because the memory cache starts empty each launch and a fresh fetch
        // below overwrites the disk copy.
        if let disk = await MobileSourceFileStore.shared.cachedText(sourceID: sourceID),
           Self.matchesExpectedHash(disk, expectedSHA256: expectedSHA256) {
            cachedText[sourceID] = disk
            return disk
        }

        if let text = try await replicaText(sourceID: sourceID) {
            cachedText[sourceID] = text
            await MobileSourceFileStore.shared.storeText(text, sourceID: sourceID)
            // Keep a saved source saved. Without this write-through, text the Mac
            // revised would live on in the durable copy for as long as the pin did.
            if MobileOfflinePins.contains(sourceID) {
                try? await MobileOfflineSourceStore.shared.writeText(text, sourceID: sourceID)
            }
            return text
        }

        throw MobileCloudSourceTextError.missingSourceText
    }

    private func replicaText(sourceID: String) async throws -> String? {
        guard let session = await MobileSyncSession.startIfEnabled(),
              let satellite = try await session.satellites.source(sourceID, matching: { $0 == "text" }),
              let text = String(data: try await session.satellites.data(satellite), encoding: .utf8), !text.isEmpty
        else { return nil }
        // An opened source's text is searchable on this phone for the next 30 days (§8a).
        try? await session.textIndexer.index(text, sourceID: sourceID, hash: satellite.file.hash)
        return text
    }

    /// The source's `listenText` satellite, read only while the text it was prepared from is the
    /// source's text now (§3.5.30).
    func loadSourceListenableContent(sourceID: String) async throws -> StoredSourceListenableContent? {
        guard let satellites = await MobileSatellites.current() else { throw MobileCloudSourceTextError.missingRecord }
        guard let satellite = try await satellites.source(sourceID, matching: { $0 == "listenText" }) else { return nil }
        let narration = String(decoding: try await satellites.data(satellite), as: UTF8.self)
        return MobileListenText.content(narration: narration, file: satellite.file,
                                        canonicalText: try await loadSourceText(sourceID: sourceID))
    }

    private static func matchesExpectedHash(_ text: String, expectedSHA256: String?) -> Bool {
        guard let expectedSHA256 else { return true }
        let digest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return digest == expectedSHA256
    }
}

enum MobileCloudSourceTextError: LocalizedError {
    case missingRecord
    case missingSourceText
    case sourceStillProcessing

    var errorDescription: String? {
        switch self {
        case .missingRecord:
            return "This source has not synced to iCloud yet."
        case .missingSourceText:
            return "This source does not have synced readable text yet."
        case .sourceStillProcessing:
            return "This source is still preparing readable text."
        }
    }
}

private struct MobileCloudSourcePayload: Decodable {
    let article: MobileCloudSourceArticle
    let listenableContentMetadata: SourceListenableContentMetadata?
    /// Optional on payloads from older Macs. This is the canonical source-row
    /// identity and carries paper `published_doi`, which is not a StudioArticle field.
    let sourceIdentity: MobileMemorySourceIdentity?
    /// Root-level sibling of `article` in `CloudKitSourcePayload`: this episode
    /// stays visible even when its show is hidden.
    let visiblePodcastEpisodeOverride: Bool?
    /// Root-level sibling of `article`: this video stays visible when its channel is hidden.
    let visibleYouTubeVideoOverride: Bool?
}

private struct MobileCloudSourceArticle: Decodable {
    let id: String
    let title: String
    let domain: String?
    let sourceType: String
    let status: String
    let state: String
    let dateAdded: Date?
    let author: String?
    let journal: String?
    let publishedYear: String?
    let wordCount: Int?
    let parentGroup: String?
    let courseSortIndex: Int?
    let isHidden: Bool
    let isPaywalled: Bool
    let artworkURL: String?
    let url: String?
    let localFilePath: String?
    let readAt: Date?
    let readingPositionLocator: String?
    let normalizedURL: String?
    let doi: String?
    let publishedDOI: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case domain
        case sourceType
        case status
        case state
        case dateAdded
        case author
        case journal
        case publishedYear
        case wordCount
        case parentGroup
        case courseSortIndex
        case isHidden
        case isPaywalled
        case errorMessage
        case artworkURL
        case url
        case localFilePath
        case readAt
        case readingPositionLocator
        case normalizedURL
        case doi
        case publishedDOI
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        domain = try container.decodeIfPresent(String.self, forKey: .domain)
        sourceType = canonicalSourceType((try container.decodeIfPresent(String.self, forKey: .sourceType)) ?? "article")
        status = (try container.decodeIfPresent(String.self, forKey: .status)) ?? "active"
        state = (try container.decodeIfPresent(String.self, forKey: .state)) ?? "ready"
        author = try container.decodeIfPresent(String.self, forKey: .author)
        journal = try container.decodeIfPresent(String.self, forKey: .journal)
        publishedYear = try container.decodeIfPresent(String.self, forKey: .publishedYear)
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount)
        artworkURL = try container.decodeIfPresent(String.self, forKey: .artworkURL)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        localFilePath = try container.decodeIfPresent(String.self, forKey: .localFilePath)
        normalizedURL = try container.decodeIfPresent(String.self, forKey: .normalizedURL)
        doi = try container.decodeIfPresent(String.self, forKey: .doi)
        publishedDOI = try container.decodeIfPresent(String.self, forKey: .publishedDOI)
        readingPositionLocator = (try? container.decodeIfPresent(String.self, forKey: .readingPositionLocator)) ?? nil
        if let seconds = try? container.decode(Double.self, forKey: .readAt) {
            readAt = Self.decodedDate(from: seconds)
        } else if let seconds = try? container.decode(Int.self, forKey: .readAt) {
            readAt = Self.decodedDate(from: TimeInterval(seconds))
        } else if let iso = try? container.decodeIfPresent(String.self, forKey: .readAt) {
            readAt = ISO8601DateFormatter().date(from: iso)
                ?? Double(iso).map(Self.decodedDate(from:))
        } else {
            readAt = nil
        }
        let rawParentGroup = ((try? container.decodeIfPresent(String.self, forKey: .parentGroup)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        parentGroup = (rawParentGroup?.isEmpty ?? true) ? nil : rawParentGroup
        courseSortIndex = (try? container.decodeIfPresent(Int.self, forKey: .courseSortIndex)) ?? nil
        isHidden = ((try? container.decodeIfPresent(Bool.self, forKey: .isHidden)) ?? nil) ?? false
        isPaywalled = MobilePaywallShelf.isPaywalled(
            column: (try? container.decodeIfPresent(Bool.self, forKey: .isPaywalled)) ?? nil,
            errorMessage: (try? container.decodeIfPresent(String.self, forKey: .errorMessage)) ?? nil
        )

        if let seconds = try? container.decode(Double.self, forKey: .dateAdded) {
            dateAdded = Self.decodedDate(from: seconds)
        } else if let seconds = try? container.decode(Int.self, forKey: .dateAdded) {
            dateAdded = Self.decodedDate(from: TimeInterval(seconds))
        } else if let iso = try? container.decodeIfPresent(String.self, forKey: .dateAdded) {
            if let parsed = ISO8601DateFormatter().date(from: iso) {
                dateAdded = parsed
            } else if let seconds = Double(iso) {
                dateAdded = Self.decodedDate(from: seconds)
            } else {
                dateAdded = nil
            }
        } else {
            dateAdded = nil
        }
    }

    private static func decodedDate(from seconds: TimeInterval) -> Date {
        if seconds > MobileCloudSourceCatalog.dateEpochCutoff {
            return Date(timeIntervalSince1970: seconds)
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}

enum MobileAudioPlaybackSpeed {
    /// Speeds the Listen tab offers. Playback goes through `AVPlayer`, whose
    /// default time-pitch algorithm since iOS 15 (`.timeDomain`) keeps speech
    /// intelligible from 1/32× to 32×, so nothing below caps the table at 2×.
    static let options: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0]
    static let minimum: Float = 0.5
    static let maximum: Float = 3.0
    /// The span a voice agent may pick from: the first and last presets.
    static let agentRange: ClosedRange<Double> = Double(options.first!)...Double(options.last!)
    static let defaultsKey = "ios.listen.playbackSpeed"

    static func clamped(_ speed: Float) -> Float {
        min(max(speed, minimum), maximum)
    }

    static func label(for speed: Float) -> String {
        let value = clamped(speed)
        if value.rounded() == value {
            return "\(Int(value))x"
        }
        var formatted = String(format: "%.2f", value)
        while formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return "\(formatted)x"
    }
}

enum MobileBookPlaybackPreferences {
    static let automaticallyContinuesKey = "ios.listen.automaticallyContinuesBooks"
    static let hasAskedToAutomaticallyContinueKey = "ios.listen.hasAskedToAutomaticallyContinueBooks"

    static var automaticallyContinues: Bool {
        get { UserDefaults.standard.bool(forKey: automaticallyContinuesKey) }
        set { UserDefaults.standard.set(newValue, forKey: automaticallyContinuesKey) }
    }

    static var hasAskedToAutomaticallyContinue: Bool {
        get { UserDefaults.standard.bool(forKey: hasAskedToAutomaticallyContinueKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasAskedToAutomaticallyContinueKey) }
    }
}

struct MobileBookContinuationOffer: Equatable {
    let completedSourceID: String
    let nextSourceID: String
    let nextTitle: String
}

/// One line of catalog sync state for the home screen: which of the two
/// phases is running, step + detail text, and a 0–1 fraction when the phase
/// can honestly estimate one (nil → indeterminate spinner).
struct MobileCatalogSyncStatus: Equatable {
    enum Phase: Equatable {
        case scanning
        case downloading
        /// The iCloud Drive manifest pass, which decides the audio badges. It
        /// runs alongside the two CloudKit phases and is shown only once they
        /// have nothing left to say.
        case narrations
    }

    var phase: Phase
    var stepText: String
    var detailText: String
    var fractionComplete: Double?
}

enum MobileTextToSpeechPreparationError: LocalizedError {
    case alreadyPreparing(String?)
    case sourceNotFound

    var errorDescription: String? {
        switch self {
        case .alreadyPreparing(let title):
            return title.map { "Audio is already being prepared for \($0)." }
                ?? "Another source's audio is already being prepared."
        case .sourceNotFound:
            return "That source is not available on this phone."
        }
    }
}

@MainActor
final class MobileAudioReviewViewModel: NSObject, ObservableObject {
    // One instance shared by every scene. The phone window scene and the CarPlay
    // scene must drive the same review session and audio engine: when the car
    // connects with the phone locked, the SwiftUI WindowGroup scene may never
    // connect, so the CarPlay scene reaches the session through this singleton
    // rather than through a scene-owned @StateObject.
    static let shared = MobileAudioReviewViewModel()

    // The first render precedes the app's launch task. Start in the state the
    // catalog is actually in so Home cannot briefly publish a false empty
    // library before `load()` has had a chance to run.
    @Published private(set) var isLoading = true
    @Published private(set) var items: [MobileAudioItem] = []
    @Published private(set) var currentItem: MobileAudioItem?
    /// Now Playing artwork for `currentItem`, and the source it belongs to.
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingArtworkSourceID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var speed: Float
    @Published private(set) var isSiriVoiceSessionActive = false
    @Published private(set) var isSourceChatActive = false
    @Published private(set) var isChatResponding = false
    @Published private(set) var activeChatTitle: String?
    @Published private(set) var lastVoiceCommand: String?
    @Published private(set) var hasOpenAIKey: Bool
    @Published private(set) var allSources: [MobileCloudSource] = [] {
        didSet {
            sourcesByID = Dictionary(allSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    /// `allSources` by id, kept beside it: Home asks every notebook's sources
    /// on each render, and playback republishes the model twice a second.
    private(set) var sourcesByID: [String: MobileCloudSource] = [:]
    /// Every placement across Notebooks, resolved against `allSources`. The
    /// phone displays only today's pending plan (the home screen's Today card);
    /// the rest feeds the voice Schedule tools, the widget, and reviews.
    @Published private(set) var scheduleItems: [MobileScheduledCatalogItem] = [] {
        didSet { scheduleTodayWidgetSnapshotPublish() }
    }
    /// Today's card review (`MemoryCardQueue.today`), as Home's Memory strip
    /// and the widget count it: how many due and new cards, never a card's
    /// answer. The card review deals the same cards.
    @Published private(set) var todayMemoryCards: MemoryCardQueue.Today = .empty {
        didSet { scheduleTodayWidgetSnapshotPublish() }
    }
    /// Moves on every deal of today's cards from the catalog — a load's
    /// checkpoint, an answer saved — so a notebook's Studio counts its cards
    /// again when a card arrives that today's review does not ask yet.
    @Published private(set) var memoryCardsRevision = 0
    /// How many cards wait in To Check over every notebook, read with today's
    /// cards: what Home's Memory strip adds to them.
    @Published private(set) var cardsToCheckTotal = 0
    /// The learner's synced daily minutes and new cards a day as last read by
    /// `refreshMemoryReviewPreferences`: until the first read lands, today's
    /// cards are dealt uncut, with the Mac's default new cards.
    private var memoryReviewPreferences = MobileMemoryReviewPreferences()
    /// Notebooks synced from the Mac, newest activity first. Talking in one
    /// reads exactly its ticked sources.
    @Published private(set) var notebooks: [MobileCloudNotebook] = []
    /// Includes child Goals and plain Schedules. Kept for relationship checks;
    /// Notebook browsing continues to use the narrower `notebooks` projection.
    @Published private(set) var goals: [MobileCloudGoal] = []
    @Published private(set) var scheduledSources: [MobileCloudScheduledSource] = []
    /// Book/course display metadata for grouped lists. The hidden sets it also
    /// carries are already applied — `allSources` only ever holds visible rows.
    @Published private(set) var collections: MobileCatalogCollections = .empty
    /// Live catalog sync state, for both the full-screen first-sync view and
    /// the in-content banner. nil whenever no walk or drain is in flight.
    @Published private(set) var syncStatus: MobileCatalogSyncStatus?
    /// The two sources `syncStatus` is projected from. CloudKit's readout wins
    /// while it has one; the narration scan fills the gap after it — which is
    /// what stops the shell row from saying "Syncing your library" with no
    /// numbers behind it once the CloudKit passes are done.
    private var catalogSyncStatus: MobileCatalogSyncStatus?
    private var narrationScanStatus: MobileCatalogSyncStatus?
    /// Compatibility line for the existing compact progress UI. The richer
    /// status above drives newer screens, but keeping this projection makes the
    /// catalog persistence change independent of an accompanying view rollout.
    @Published private(set) var syncProgressText: String?
    /// True for the whole span of a from-scratch catalog pass (no change
    /// token yet) — what gates the "first sync takes a few minutes" hint, so
    /// it shows even before the first checkpoint posts any numbers.
    @Published private(set) var isInitialCatalogSync = false
    /// True while a first launch's narration scan (the iCloud Drive manifest
    /// pass) is still running. Keeps the shell's sync row up after CloudKit
    /// finishes, now with that scan's own count in it.
    @Published private(set) var isInitialNarrationScan = false
    /// Set when the learner leaves the first-sync screen rather than waiting it
    /// out. The pass keeps running; only the full-screen readout stands down,
    /// and `MobileCompactPlaybackBar` picks the same progress up from there —
    /// which is why this lives here and not in one screen's `@State`.
    @Published private(set) var hasDismissedInitialSyncScreen = false
    @Published private(set) var sourceSyncDiagnostic: MobileSourceSyncDiagnostic?
    @Published private(set) var activeVoiceSourceID: String?
    /// Title of the source whose narration audio is being generated right now —
    /// the stretch between a text-to-speech request and the first playable chunk,
    /// which the home banner shows so the wait never reads as silence.
    @Published private(set) var textToSpeechPreparingTitle: String?
    @Published private(set) var textToSpeechPreparingSourceID: String?
    @Published private(set) var textToSpeechPreparationDetail: String?
    @Published private(set) var textToSpeechGenerationProgress: MobileTextToSpeechGenerationProgress?
    /// Generate-only jobs are independent of the source currently playing.
    /// Keying them by source keeps every row honest when several articles are
    /// being prepared at once without turning playback into a global lock.
    @Published private(set) var backgroundTextToSpeechPreparingTitles: [String: String] = [:]
    @Published private(set) var backgroundTextToSpeechGenerationProgress: [String: MobileTextToSpeechGenerationProgress] = [:]
    @Published private(set) var automaticAudioProgress: SourceAudioAutomation.GenerationProgress?
    @Published var textToSpeechCostConfirmation: MobileTextToSpeechCostConfirmation?
    /// Explainer ids by the id of the source they explain, derived from the
    /// catalog on every publish; `explainerID(explaining:)` reads it.
    @Published private(set) var explainerIDsByExplainedSourceID: [String: String] = [:]
    /// The audio overviews the Mac saved, read with the Notebooks they are in.
    @Published private(set) var audioOverviewRecords: [MobileAudioOverviewRecord] = []
    /// Every current Artifact not hidden; a notebook's Studio lists the Docs
    /// among them (`docs(in:)`).
    @Published private(set) var notebookArtifacts: [MobileCloudArtifact] = []
    /// The chats filed under each notebook, newest first (`notebookChats(in:)`).
    @Published private(set) var notebookChatsByNotebookID: [String: [MobileNotebookChatSummary]] = [:]
    /// Where the system asked the phone to go, which the shell has yet to
    /// follow: a foreverlm:// link (`ForeverLMMobileApp.onOpenURL` — the
    /// widget's Today and review taps, a notebook in a calendar note, a
    /// source), Siri's "open today" and memory review, the reminder's tap.
    /// Held here rather than posted, so one that arrives before the shell is
    /// on screen (a cold launch, the sign-in wall) is followed when it
    /// appears, before the launch reopens the last notebook. The shell
    /// clears it.
    @Published var pendingDeepLink: MobileDeepLink?
    @Published private(set) var bookContinuationOffer: MobileBookContinuationOffer?
    @Published private(set) var lastDrivingBenchmark: MobileDrivingVoiceBenchmark?
    @Published var apiKeyText: String
    @Published var errorMessage: String?
    @Published private(set) var isMutatingLibrary = false

    // The app constructs this shared model before SwiftUI's first frame. Audio
    // objects can synchronously contact media/speech services during init, so none
    // of them belongs on that launch-critical path. Each one wires itself up on
    // first use instead.
    private var initializedPlayer: AVPlayer?
    private lazy var player: AVPlayer = {
        let player = AVPlayer()
        initializedPlayer = player
        installTimeObserver(for: player)
        installRemoteCommandHandlers()
        registerAudioSessionPreemptionIfNeeded()
        return player
    }()
    lazy var voice: MobileVoiceCommandService = {
        let voice = MobileVoiceCommandService()
        voice.onTranscript = { [weak self] text in
            Task { @MainActor in
                await self?.handleVoiceTranscript(text)
            }
        }
        voice.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
        registerAudioSessionPreemptionIfNeeded()
        return voice
    }()
    lazy var speech: MobileReviewSpeechService = {
        let speech = MobileReviewSpeechService.shared
        speech.onFinishSpeaking = { [weak self] in
            Task { @MainActor in
                await self?.resumeAfterSpeech()
            }
        }
        speech.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
        return speech
    }()
    private lazy var sourceChat = MobileSourceChatService()
    private lazy var voiceAgent = MobileVoiceAgentService()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var completedPlayerItemIdentity: ObjectIdentifier?
    /// The source whose opening section is playing while the rest of its
    /// narration is still being generated. Set only between the opening
    /// starting and the whole composition taking over.
    private var openingPlaybackSourceID: String?
    /// True while an opening section is playing ahead of the rest. The opening
    /// running out is not the end of the source, so it must not announce one.
    private var isAwaitingRemainingNarration = false
    /// Distinguishes automatic buffering from an intentional pause. AVPlayer
    /// reports both as not playing, but only buffering should auto-resume when
    /// a longer contiguous prefix or the final composition arrives.
    private var openingPlaybackRanDry = false
    /// A read request that arrived while TTS was already preparing audio. This
    /// closes the CarPlay race where generate_source_audio could be running and
    /// a later "listen now" request was previously ignored.
    private var pendingTextToSpeechAfterPreparationSourceID: String?
    /// Event-driven handoff when a next chapter was already being prepared at
    /// the moment its predecessor finished. The generation completion consumes
    /// this pair; no timer polls keyed progress state.
    private var pendingAutomaticBookContinuation: (completedSourceID: String, nextSourceID: String)?
    /// Distinguishes an in-flight generation that already owns autoplay from a
    /// background-only preparation that needs the pending handoff above.
    private var textToSpeechAutoplaySourceID: String?
    /// Concurrent generation jobs share one idle-timer lease. Saving/restoring
    /// the raw UIApplication value per task races and can re-enable sleep while
    /// another article is still generating (or leave it disabled forever).
    private var textToSpeechIdleTimerLeaseCount = 0
    private var wasIdleTimerDisabledBeforeTextToSpeechGeneration = false
    /// The background-execution assertion that lease also holds. One identifier
    /// for the whole lease, for the same reason: several jobs, one runway.
    private var textToSpeechBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// Generations that were cut short by something worth retrying, and whether
    /// the listener was waiting to hear each one. Suspension is the common
    /// cause: the speech requests in flight when iOS froze the app fail as soon
    /// as it thaws, which used to end the whole generation for good.
    private var pendingTextToSpeechResumes: [String: Bool] = [:]
    private var automaticTextToSpeechResumeCounts: [String: Int] = [:]
    private var isResumingTextToSpeechGeneration = false
    /// How many times an interrupted generation restarts itself before it waits
    /// for a deliberate Listen. A long absence can strand the same source
    /// several times over; a phone with no network must not loop on it.
    private static let maximumAutomaticTextToSpeechResumes = 3
    /// How long a generation the network ended waits on screen for a path to
    /// come back before leaving the retry to the next foreground. Long enough
    /// for the underground stretch of a commute, short enough that a phone left
    /// in airplane mode is not watched indefinitely.
    private static let offlineResumeNetworkWait: TimeInterval = 120
    /// The one concurrent UI generation whose opening claimed the player.
    /// Holding ownership until that job finishes prevents later openings from
    /// replacing it — or appearing after the listener closes it.
    private var backgroundOpeningPlaybackOwnerSourceID: String?
    private var textToSpeechCostConfirmationContinuation: CheckedContinuation<Bool, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var didRegisterAudioSessionPreemption = false
    private var activeCatalogLoad: (id: UUID, task: Task<Bool, Never>)?
    private var forcedCatalogReloadRequested = false
    /// Whether the next load walks the iCloud Drive audio tree; a reload the replica asked for does not.
    private var narrationScanRequested = false
    /// Turns the replica's changes into at most one library reload per interval (generation 2).
    private var replicaReloads: MobileReloadCoalescer?
    private var lastSourceSyncErrorMessage: String?
    private var shouldResumePlaybackAfterSpeech = false
    private var lastPlaybackPositionSaveAt: Date?
    /// When the account copy of the position was last published. The file
    /// beside the audio is written every few seconds; the CloudKit record only
    /// on `ListeningPositionSync.accountSaveInterval` while playing, and at
    /// once whenever a save is forced (pause, skip, dismiss, backgrounding).
    private var lastAccountPositionSaveAt: Date?
    /// Keeps the audio list current with narrations other devices publish
    /// while this app is running. Started after the first manifest walk.
    private var syncedAudioManifestObserver: SyncedAudioManifestObserver?
    private var syncedAudioObservationTask: Task<Void, Never>?
    /// Suppresses duplicate reader-scroll and AVPlayer completion callbacks for
    /// one source while its CloudKit consumption write is in flight. IDs move
    /// to the completed set only after the durable write succeeds, so a visible
    /// failure can be retried instead of being silently treated as saved.
    private var sourceConsumptionInFlightIDs = Set<String>()
    private var sourceConsumptionRecordedIDs = Set<String>()
    /// Deepest fraction already published per source this launch, so repeated
    /// clock ticks and scroll callbacks collapse into a few writes.
    private var recordedSourceDepths: [String: Double] = [:]
    /// How much deeper the learner must get before another depth write is worth
    /// a CloudKit round trip. Twenty steps across a whole source is plenty to
    /// distinguish "opened it" from "went through most of it".
    private static let depthReportingStep = 0.05
    /// When each source's depth was last reported to `recordSourceDepth`, and
    /// the listening or reading seconds counted since the last write. Time
    /// rides along with the next depth write; what is left when playback
    /// stops short of a step is lost, which is at most one step's worth.
    private var depthTickAt: [String: Date] = [:]
    private var pendingEngagedSeconds: [String: Double] = [:]
    /// A tick gap longer than this is a pause or a background stretch, not time
    /// with the source.
    private static let maxEngagedTickGap: TimeInterval = 15
    private static let activityLogger = Logger(
        subsystem: "com.foreverlm.mobile",
        category: "SourceActivity"
    )
    private var sourceActivityInFlightIDs = Set<String>()
    private var sourceActivityRecordedIDs = Set<String>()
    private lazy var sourceCatalog = MobileCloudSourceCatalog.shared
    private lazy var sourceTextStore = MobileCloudSourceTextStore.shared
    private var activeVoiceSourceTitle: String?

    // Hands-free review quiz (the app quizzes the user and grades with Claude).
    @Published private(set) var isReviewActive = false
    @Published private(set) var reviewTitle: String?
    @Published private(set) var reviewStatus: String?
    @Published var anthropicKeyText: String
    @Published private(set) var hasAnthropicKey: Bool
    // Which grader runs the review. Persisted so the choice survives relaunch.
    @Published var reviewGrader: MobileReviewGrader {
        didSet {
            guard reviewGrader != oldValue else { return }
            UserDefaults.standard.set(reviewGrader.rawValue, forKey: MobileReviewGrader.defaultsKey)
        }
    }
    // Resolved at the start of each review from reviewGrader; held for the whole
    // session so the engine's conversation state stays intact across turns.
    private(set) var reviewBrain: any MobileReviewEngine = MobileReviewBrain()

    // Current availability of Apple's on-device model, for settings UI.
    var appleGraderAvailability: MobileAppleGraderAvailability {
        MobileReviewGraderFactory.appleAvailability()
    }
    lazy var reviewRecorder = MobileReviewSessionRecorder.shared
    var reviewSessionID: String?
    var reviewTopic = ""
    var reviewSourceID: String?
    var reviewSourceType: String?
    var reviewStartedAt: Date?
    var reviewPendingQuestion: String?
    var reviewExchanges: [MobileReviewRecordedExchange] = []

    override init() {
        let storedSpeed = UserDefaults.standard.object(forKey: MobileAudioPlaybackSpeed.defaultsKey) as? Float
        speed = MobileAudioPlaybackSpeed.clamped(storedSpeed ?? 1.0)
        apiKeyText = ""
        anthropicKeyText = ""
        // Deliberately assumed, not read. `ManagedAI.isSignedIn` is a synchronous
        // keychain round trip, and this init runs inside the
        // `MobileAudioReviewViewModel.shared` @StateObject autoclosure — i.e. on the
        // main actor during first body evaluation on cold launch. `load()` publishes
        // the real value off-main, and it runs before any Siri command is handled, so
        // the guards that read these never see the placeholder.
        hasOpenAIKey = false
        hasAnthropicKey = false
        let storedGrader = UserDefaults.standard.string(forKey: MobileReviewGrader.defaultsKey)
        reviewGrader = storedGrader.flatMap(MobileReviewGrader.init(rawValue:)) ?? .default
        super.init()
        // Checkpoint-by-checkpoint sync progress from the catalog actor. The
        // userInfo ints are read here, outside the main-actor hop, because
        // Notification itself is not Sendable.
        NotificationCenter.default
            .publisher(for: MobileCloudSourceCatalog.syncProgressNotification)
            .sink { [weak self] note in
                let pending = note.userInfo?["pending"] as? Int ?? 0
                let walking = note.userInfo?["walking"] as? Bool ?? false
                let scanned = note.userInfo?["scanned"] as? Int ?? 0
                let fullPass = note.userInfo?["fullPass"] as? Bool ?? false
                let expectedScan = note.userInfo?["expectedScan"] as? Int
                let drainTotal = note.userInfo?["drainTotal"] as? Int
                Task { @MainActor in
                    await self?.handleSyncProgress(
                        pending: pending,
                        walking: walking,
                        scanned: scanned,
                        fullPass: fullPass,
                        expectedScan: expectedScan,
                        drainTotal: drainTotal
                    )
                }
            }
            .store(in: &cancellables)
        // A round of the phone's session keeps the replica current; the library is read again whenever it
        // changes. Every write and every settled round posts it, so it is coalesced (`MobileReloadCoalescer`),
        // and the narration folder is not walked again for it: only a launch or a foreground reads that.
        replicaReloads = MobileReloadCoalescer { [weak self] in
            _ = await self?.load(forceRefresh: true, scansNarrations: false)
        }
        NotificationCenter.default
            .publisher(for: .mobileReplicaDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.replicaReloads?.changed()
                }
            }
            .store(in: &cancellables)
        // A read of OpenRouter's speech list that drops the stored pick
        // repairs it at once, as the Mac does; the next use says what changed
        // (`ArticleSpeechSelection.repairAfterDirectoryRead`).
        NotificationCenter.default
            .publisher(for: .openRouterAudioDirectoryDidChange)
            .filter { $0.object as? String == OpenRouterAudioDirectory.Kind.speech.rawValue }
            .sink { _ in
                Task.detached(priority: .utility) {
                    ArticleSpeechSelection.repairAfterDirectoryRead()
                    await ArticleSpeechPreferences.shared.reloadFromStorage()
                }
            }
            .store(in: &cancellables)
    }

    private var widgetSnapshotPublishTask: Task<Void, Never>?
    private var automaticSourceAudioTask: Task<Void, Never>?
    private var automaticSourceAudioPassRequested = false
    /// Sources whose automatic preparation failed this launch. A source the
    /// phone cannot narrate — text that has not synced from the Mac yet, most
    /// often — must not stall every other source behind it, and must not be
    /// retried on every pass. The error still surfaces; only the retry stops.
    private var failedAutomaticSourceAudioIDs: Set<String> = []
    @Published private(set) var narrationDownloadSourceID: String?
    @Published private(set) var narrationDownloadProgress: MobileNarrationDownloadProgress?
    /// True while a streamed opening is being set up from the downloaded
    /// prefix, so two CloudDocs updates cannot both start one.
    private var isStartingDownloadedOpening = false
    /// The next chapter's chunks being pulled down ahead of need, so the book
    /// carries on without a download gap. Replaced whenever playback moves.
    private var nextChapterPrefetchTask: Task<Void, Never>?

    /// Coalesce the three catalog projections into one widget write. Encoding,
    /// app-group UserDefaults, and WidgetCenter invalidation can all block, so
    /// the main actor only captures copy-on-write value snapshots here.
    private func scheduleTodayWidgetSnapshotPublish() {
        widgetSnapshotPublishTask?.cancel()
        let scheduleSnapshot = scheduleItems
        let cardsSnapshot = todayMemoryCards
        widgetSnapshotPublishTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let calendar = Calendar.autoupdatingCurrent
            // Deliberate placements only: an anchor the app wrote to hold a
            // source's activity is history, not something the learner planned,
            // and the widget must never count it as work waiting today.
            let pending = scheduleSnapshot.filter {
                !$0.isAutomatic && calendar.isDateInToday($0.plannedAt) && !$0.isCompleted
            }
            // Only the day's half: the bout's clock is written by
            // MobileLearningBoutTimer into the same record, and neither writer
            // may blank the other's fields.
            MobileTodayWidgetSnapshotStore.saveDay(
                pendingCount: pending.count,
                nextTitle: pending.first?.source.title,
                // Counts only: a card's target is its answer. The review the
                // widget opens is the phone's card review, which deals these
                // due and new cards ("6 due · 4 new").
                memoryDueCount: cardsSnapshot.dueCount,
                memoryNewCount: cardsSnapshot.newCount
            )
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: "ForeverLMTodayWidget")
        }
    }

    /// Streams a sync into the UI: a two-step progress readout, and the list
    /// itself filling in batch by batch — "nothing until minute ten" is the
    /// exact first-run experience this replaces.
    private func handleSyncProgress(
        pending: Int,
        walking: Bool,
        scanned: Int,
        fullPass: Bool,
        expectedScan: Int?,
        drainTotal: Int?
    ) async {
        if walking {
            // The scanned count is the line's spine: the zone is mostly record
            // types the walk skips (usage events, chat history), and on a
            // from-scratch pass whole minutes can go by before the first
            // source-type record appears. "Found" alone would sit at nothing.
            // The previous full walk's total turns the count into a real bar.
            let expected = fullPass ? expectedScan : nil
            let denominator = expected.map { " of ~\($0.formatted())" } ?? ""
            let found = pending > 0 ? " · \(pending.formatted()) to download" : ""
            publishSyncStatus(
                MobileCatalogSyncStatus(
                    phase: .scanning,
                    stepText: "Step 1 of 2 · Scanning your library",
                    detailText: "\(scanned.formatted())\(denominator) records\(found)",
                    fractionComplete: expected.map { min(Double(scanned) / Double(max($0, 1)), 0.98) }
                )
            )
        } else if pending > 0 {
            let total = max(drainTotal ?? pending, pending)
            let done = total - pending
            publishSyncStatus(
                MobileCatalogSyncStatus(
                    phase: .downloading,
                    stepText: "Step 2 of 2 · Downloading sources",
                    detailText: "\(done.formatted()) of \(total.formatted()) records",
                    fractionComplete: Double(done) / Double(max(total, 1))
                )
            )
        } else {
            publishSyncStatus(nil)
        }

        if pending > 0 || allSources.isEmpty {
            notebooks = await sourceCatalog.currentNotebooks()
            goals = await sourceCatalog.currentGoals()
            collections = await sourceCatalog.currentCollections()
            audioOverviewRecords = await sourceCatalog.currentAudioOverviews()
            await publishNotebookCatalog()
            publishCatalogSources(await sourceCatalog.currentSources())
            scheduledSources = await sourceCatalog.currentScheduledSources()
            scheduleItems = await sourceCatalog.currentScheduleItems()
            await refreshMemorySnapshot()
        }
    }

    func dismissInitialSyncScreen() {
        hasDismissedInitialSyncScreen = true
    }

    /// One writer for both projections of sync state, so the compact line and
    /// the structured status can never disagree about whether a sync is running.
    private func publishSyncStatus(_ status: MobileCatalogSyncStatus?) {
        catalogSyncStatus = status
        notebookSyncStatus()
    }

    private func publishNarrationScanStatus(_ status: MobileCatalogSyncStatus?) {
        narrationScanStatus = status
        notebookSyncStatus()
    }

    private func notebookSyncStatus() {
        let status = catalogSyncStatus ?? narrationScanStatus
        syncStatus = status
        syncProgressText = status.map { "\($0.stepText) · \($0.detailText)" }
    }

    /// Maps catalog rows into the published list (archived filter, audio badge
    /// from the synced manifests, newest first). The catalog already dropped
    /// hidden sources. Shared by the finished load and the progressive
    /// first-sync fill.
    private func publishCatalogSources(_ catalog: [MobileCloudSource]) {
        let manifestIDs = Set(items.map { $0.id })
        allSources = catalog
            .filter { !$0.isArchived }
            .map { source in
                var row = source
                row.hasAudio = manifestIDs.contains(source.id)
                return row
            }
            .sorted { $0.dateAdded > $1.dateAdded }
        // Which sources have an explainer, read off the explainers' own URLs
        // (`foreverlm://explainer/<sourceID>`), so a row can answer without a
        // hash and without scanning the list.
        var explainers: [String: String] = [:]
        for source in allSources {
            if let explained = ExplainerScript.explainedSourceID(from: source.url ?? "") {
                explainers[explained] = source.id
            }
        }
        explainerIDsByExplainedSourceID = explainers
    }

    /// The id of the source's explainer when the library has one — an
    /// article-typed source whose URL names this source (explainer-design.md).
    func explainerID(explaining sourceID: String) -> String? {
        explainerIDsByExplainedSourceID[sourceID]
    }

    /// A notebook's audio overviews whose script source has reached this
    /// phone, newest first. An overview whose script has not synced yet is
    /// left out until it has. The phone does not make them yet; the Mac's
    /// Studio and `generate_audio_overview` do.
    func audioOverviews(inNotebook notebookID: String) -> [MobileAudioOverviewListing] {
        let records = audioOverviewRecords.filter { $0.notebookIDs.contains(notebookID) }
        guard !records.isEmpty else { return [] }
        let byID = sourcesByID
        return records
            .sorted { ($0.createdAt ?? .distantPast, $1.id) > ($1.createdAt ?? .distantPast, $0.id) }
            .compactMap { record in
                byID[record.carrierSourceID].map {
                    MobileAudioOverviewListing(id: record.id, title: record.title ?? $0.title, carrier: $0)
                }
            }
    }

    // MARK: - Notebooks

    /// The Docs and chats notebooks list, from the same checkpoint as the
    /// Notebooks published beside them.
    private func publishNotebookCatalog() async {
        notebookArtifacts = await sourceCatalog.currentNotebookArtifacts()
        notebookChatsByNotebookID = await sourceCatalog.currentNotebookChats()
        scheduleShareNotebookListPublish()
    }

    private var shareNotebookListPublishTask: Task<Void, Never>?

    /// The share sheet's notebooks (`MobileShareNotebookStore`), since the
    /// extension cannot read the CloudKit catalog: Home's order, each
    /// notebook's id and title and nothing else, written into the app group
    /// whenever the catalog publishes its notebooks — coalesced, off the main
    /// actor, and only when the list changed.
    private func scheduleShareNotebookListPublish() {
        shareNotebookListPublishTask?.cancel()
        let notebooksSnapshot = notebooks
        let lastChatAt = lastNotebookChatAt
        shareNotebookListPublishTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let notebooks = Self.shareNotebooks(notebooksSnapshot, lastChatAt: lastChatAt)
            MobileShareNotebookStore.shared?.save(notebooks)
        }
    }

    /// Home's notebooks as the share sheet lists them (`MobileNotebookOrdering`).
    nonisolated static func shareNotebooks(
        _ notebooks: [MobileCloudNotebook],
        lastChatAt: [String: Date]
    ) -> [MobileShareNotebook] {
        MobileNotebookOrdering.sorted(notebooks, lastChatAt: lastChatAt)
            .map { MobileShareNotebook(id: $0.id, title: $0.title) }
    }

    /// Home's Memory strip: today's cards, "6 due · 4 new" — what the widget
    /// counts (`saveDay`) and the card review deals — and the cards to check,
    /// "· 9 to check"; nil while nothing waits, or while nothing has synced
    /// yet and no card is known to be waiting, when Home draws no strip, as
    /// the Mac's home does since 2026-10-06.
    var memoryTodayLine: String? {
        allSources.isEmpty ? nil : MobileCardReviewCopy.homeLine(todayMemoryCards, toCheck: cardsToCheckTotal)
    }

    /// The chats filed under a notebook, newest first.
    func notebookChats(in notebookID: String) -> [MobileNotebookChatSummary] {
        notebookChatsByNotebookID[notebookID] ?? []
    }

    /// One of the notebooks' chats by its session id; nil when no notebook
    /// on this phone lists it.
    func notebookChat(sessionID: String) -> MobileNotebookChatSummary? {
        for chats in notebookChatsByNotebookID.values {
            if let chat = chats.first(where: { $0.id == sessionID }) { return chat }
        }
        return nil
    }

    /// Whether the phone continues a notebook's saved chat, or shows it
    /// read-only and why (`MobileNotebookChatContinuation.verdict`).
    func continuation(of chat: MobileNotebookChatSummary) -> MobileNotebookChatContinuation.Verdict {
        MobileNotebookChatContinuation.verdict(shape: chat.shape, sourceIDs: chat.sourceIDs) {
            sourcesByID[$0] != nil
        }
    }

    /// When each notebook's latest chat happened, for Home's order (each list
    /// is newest first).
    var lastNotebookChatAt: [String: Date] {
        notebookChatsByNotebookID.compactMapValues { $0.first?.lastActivityAt }
    }

    /// The Docs a notebook holds — homed on it or linked to it — that the
    /// Mac's Studio lists (`NotebookOutputs.isListed`, `kind(of:)`): an audio
    /// overview is never one of them, even one an older build saved back
    /// without its kind, which its script's carrier source still names.
    func docs(in notebook: MobileCloudNotebook) -> [MobileCloudArtifact] {
        let overviewIDs = Set(audioOverviewRecords.map(\.id))
        return notebookArtifacts.filter { artifact in
            artifact.isListed
                && artifact.isDoc
                && artifact.belongs(toNotebookID: notebook.id)
                && !overviewIDs.contains(artifact.id)
                && sourcesByID[MobileCloudMutationService.audioOverviewSourceID(artifactID: artifact.id)] == nil
        }
    }

    /// The notebook's own sources as this phone has them — never a context
    /// notebook's — which the walkthroughs and spoken explainers in its
    /// Studio ride (the Mac's `notebookOutputMemberIDs`).
    func notebookOwnSources(in notebook: MobileCloudNotebook) -> [MobileCloudSource] {
        let own = Set(notebook.sourceIDs)
        return notebookSources(in: notebook).filter { own.contains($0.id) }
    }

    /// The notebook's context notebooks this phone has a record of, in link
    /// order, each with the sources its group lists under the notebook's own
    /// (the Sources tab, the iPad's column, the chat's Sources sheet).
    func contextNotebookGroups(in notebook: MobileCloudNotebook) -> [MobileNotebookContextGroup] {
        let byID = sourcesByID
        return notebook.contextNotebooks.map { contextNotebook in
            MobileNotebookContextGroup(
                notebook: contextNotebook,
                sources: contextNotebook.sourceIDs.compactMap { byID[$0] }.filter { !MobileSourceListing.isSpokenScript($0) }
            )
        }
    }

    /// The courses a notebook links, in the Mac's order, that this phone has.
    func linkedCourses(in notebook: MobileCloudNotebook) -> [MobileCloudCourse] {
        notebook.linkedCourseIDs.compactMap { collections.coursesByID[$0] }.filter { !$0.isHidden }
    }

    /// One saved chat as the read-only transcript shows it, the tutor's
    /// Markdown parsed once, off the main actor.
    func chatTranscript(sessionID: String) async -> MobileVoiceChatTranscript? {
        guard let turns = await sourceCatalog.currentChatTranscriptTurns(sessionID: sessionID) else { return nil }
        let messages = await Task.detached(priority: .userInitiated) {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            return turns.map { turn in
                MobileChatMessage(
                    id: UUID(),
                    role: turn.role == .user ? .user : .assistant,
                    content: turn.content,
                    isStreaming: false,
                    rendered: turn.role == .user ? nil : try? AttributedString(markdown: turn.content, options: options)
                )
            }
        }.value
        return MobileVoiceChatTranscript(messages: messages)
    }

    /// A notebook's Studio Cards row: "42 kept · 6 due", by the Mac's
    /// `notebookCardCounts`, with the day's minutes and new cards as last
    /// read; nil for a notebook not on this phone.
    func notebookCardCounts(in notebook: MobileCloudNotebook) async -> NotebookCardCounts? {
        await sourceCatalog.currentNotebookCardCounts(
            notebookID: notebook.id,
            budgetMinutes: memoryReviewPreferences.budgetMinutes,
            newPerDay: memoryReviewPreferences.newCardsPerDay
        )
    }

    // MARK: - The card review

    /// What a card sitting over `scope` deals (`MobileCardReviewSession`), with the
    /// day's minutes and new cards as last read. Local only.
    func cardReviewRead(scope: MemoryReviewScope, now: Date = Date()) async -> MobileCardReviewDealing.Read {
        await sourceCatalog.currentCardReviewRead(
            now: now,
            budgetMinutes: memoryReviewPreferences.budgetMinutes,
            newPerDay: memoryReviewPreferences.newCardsPerDay,
            scope: scope
        )
    }

    /// A notebook's Practice: its kept cards; nil for a notebook not on this
    /// phone.
    func notebookPractice(notebookID: String, now: Date = Date()) async -> MobileCardReviewDealing.NotebookPractice? {
        await sourceCatalog.currentNotebookPractice(notebookID: notebookID, now: now)
    }

    /// The notebooks a card review may be narrowed to, archived ones included.
    func cardReviewNotebookIDs() async -> Set<String> {
        await sourceCatalog.currentCardReviewNotebookIDs()
    }

    /// The notebooks holding at least one kept card.
    func cardReviewNotebookIDsWithCards() async -> Set<String> {
        await sourceCatalog.currentNotebookIDsWithCards()
    }

    func cardAnswerContext(memoryItemID: String) async -> (item: MemoryItem, history: [MemoryAttempt])? {
        await sourceCatalog.currentCardAnswerContext(memoryItemID: memoryItemID)
    }

    /// A mnemonic reading's questions' items and their attempts on this
    /// phone (`MobileMnemonicReadingModel`). Local only.
    func mnemonicReadingHeld(itemIDs: Set<String>) async -> (items: [MemoryItem], attempts: [MemoryAttempt]) {
        await sourceCatalog.currentMnemonicReadingHeld(itemIDs: itemIDs)
    }

    /// A card a mnemonic reading just kept, with its first attempt: both
    /// published in the catalog at once, under the record names CloudKit
    /// holds them by, and today's cards dealt again, so the notebook's Cards
    /// row and the card review see it.
    func noteKeptReadingCard(_ item: MemoryItem, firstAttempt attempt: MemoryAttempt) async {
        await sourceCatalog.noteRecordedMemoryItem(
            item,
            recordName: MobileReviewSessionRecorder.memoryItemRecordName(for: item.id)
        )
        await sourceCatalog.noteRecordedMemoryAttempt(
            attempt,
            recordName: MobileMemoryAttemptRecorder.recordName(for: attempt.id)
        )
        await refreshMemorySnapshot()
    }

    func dayReviewChatIsUnderway() async -> Bool {
        await sourceCatalog.currentDayReviewChatIsUnderway()
    }

    /// The Memory screen's All Cards: every kept card on this phone, oldest
    /// kept first. Local only.
    func keptCardListings() async -> [MemoryCardListing] {
        await sourceCatalog.currentKeptCardListings()
    }

    // MARK: - Going through cards (generation 2)

    /// The cards to check over `scope` (To Check), in their order; nil when
    /// the replica could not be read. Local only.
    func cardsToCheck(scope: MemoryReviewScope, now: Date = Date()) async -> [MemoryCardToCheck]? {
        await sourceCatalog.currentCardsToCheck(scope: scope, now: now)
    }

    /// The Cards of kept cards, by item id: what words them. Local only.
    func cardRecords(itemIDs: [String]) async -> [String: MobileCardRecord] {
        await sourceCatalog.currentCardRecords(itemIDs: itemIDs)
    }

    /// Writes what the learner decided in To Check — Keep, Edit then Keep,
    /// Skip, Keep All, Skip All — on each card's Card
    /// (`MobileCardTriageWriter`), then deals today's cards again, so a card
    /// kept here is a card of Memory at once. A card the phone could not
    /// keep stays to check, and the result says why.
    @discardableResult
    func triageCardsToCheck(_ decisions: [MemoryCardTriageDecision]) async -> MemoryCardTriageResult {
        guard !decisions.isEmpty else { return MemoryCardTriageResult() }
        let writer: MobileRecordWriter
        do {
            writer = try await MobileRecordWriter.required()
        } catch {
            var result = MemoryCardTriageResult()
            result.failed = decisions.map { MemoryCardTriageResult.Failure(cardID: $0.card.cardID, reason: error.localizedDescription) }
            return result
        }
        let textStore = sourceTextStore
        let outcome = await MobileCardTriageWriter.apply(decisions, writer: writer) { sourceID in
            try? await textStore.loadSourceText(sourceID: sourceID)
        }
        await sourceCatalog.noteWrittenMemoryItems(outcome.kept)
        await refreshMemorySnapshot()
        return outcome.result
    }

    /// Edit Card on a kept card: a new front alone rewords it; a new back or
    /// why starts it over (`MobileCardEditWriter`), as the Mac's All Cards
    /// does. `wording` is the card's wording as asked now.
    func applyCardEdit(_ edit: MemoryCardEdit, to card: MemoryCardListing, wording: String) async throws {
        if MobileCardEditWriter.startsOver(card, edit) {
            try await startCardOver(card, edit: edit, wording: wording)
            return
        }
        let front = try MobileCardEditWriter.rewording(card, front: edit.front, wording: wording)
        try await MobileRecordWriter.required().transaction { try $0.rewordCard(card.itemID, front: front) }
        await refreshMemorySnapshot()
    }

    /// "Start this card over?": the card retired with its answers and its
    /// revision kept under a new card id on the passages its sources still
    /// print, in `edit`'s words or as it is asked now.
    func startCardOver(_ card: MemoryCardListing, edit: MemoryCardEdit?, wording: String) async throws {
        guard let old = await cardAnswerContext(memoryItemID: card.itemID)?.item else { throw MobileCardRecords.Refusal.gone }
        var texts: [String: String] = [:]
        for sourceID in Set(old.sources.map(\.sourceID)) {
            if let text = try? await sourceTextStore.loadSourceText(sourceID: sourceID) { texts[sourceID] = text }
        }
        let face = MobileCardEditWriter.revisedFace(card, edit: edit, wording: wording, newID: UUID().uuidString.lowercased())
        let now = Date()
        let revision = try MobileCardRecords.revision(of: old, as: face, texts: texts, at: now)
        try await MobileRecordWriter.required().transaction { try $0.startCardOver(old.id, as: revision) }
        await sourceCatalog.noteWrittenMemoryItems([MobileCardRecords.retired(old, at: now), revision])
        await refreshMemorySnapshot()
    }

    /// Retire: the card is never asked again.
    func retireCard(_ card: MemoryCardListing) async throws {
        try await MobileRecordWriter.required().transaction { try $0.retireCard(card.itemID) }
        if let item = await cardAnswerContext(memoryItemID: card.itemID)?.item {
            await sourceCatalog.noteWrittenMemoryItems([MobileCardRecords.retired(item, at: Date())])
        }
        await refreshMemorySnapshot()
    }

    /// "Always Ask in Its Own Words", or "Let Its Wording Vary".
    func setCardAlwaysAsk(_ on: Bool, itemID: String) async throws {
        try await MobileRecordWriter.required().transaction { try $0.setCardAlwaysAsk(itemID, on) }
        await refreshMemorySnapshot()
    }

    /// "This asks something else" on a card asked in a rewording: the
    /// rewording taken out on its Card, and the failed attempt that says so
    /// in this device's Sitting, which moves no schedule. Once a sitting and
    /// wording.
    func reportCardAskedSomethingElse(itemID: String, prompt: String, variantIndex: Int, sessionKey: String, at now: Date = Date()) async throws {
        let fingerprint = await cardAnswerContext(memoryItemID: itemID).map { MemoryTutorIdentity.immutableCurriculumFingerprint($0.item) }
        let attempt = MemoryCardVariation.askedSomethingElseAttempt(
            id: MobileCardEditWriter.askedSomethingElseAttemptID(sessionKey: sessionKey, memoryItemID: itemID, prompt: prompt),
            memoryItemID: itemID,
            prompt: prompt,
            variantIndex: variantIndex,
            at: now
        )
        try await MobileRecordWriter.required().transaction { write in
            try write.retireCardVariant(itemID, text: prompt)
            _ = try write.recordAnswer(attempt, curriculumFingerprint: fingerprint, anyHeldCounts: true)
        }
        await sourceCatalog.noteRecordedMemoryAttempt(attempt, recordName: attempt.id)
        await refreshMemorySnapshot()
    }

    /// The Memory screen's history grid: the earlier days with a review chat
    /// to open, and the days the learner wrote in. Local only.
    func memoryReviewChatDays() async -> MobileMemoryHistoryDays.Days {
        await sourceCatalog.currentMemoryReviewChatDays()
    }

    /// A card answer the card review just saved: published in the catalog at
    /// once, under the record name CloudKit holds it by (the zone delta later
    /// replaces it rather than adding a second), and today's cards dealt
    /// again, so Home, the widget and the next round see it.
    func noteRecordedCardAnswer(_ attempt: MemoryAttempt) async {
        await sourceCatalog.noteRecordedMemoryAttempt(
            attempt,
            recordName: MobileMemoryAttemptRecorder.recordName(for: attempt.id)
        )
        await refreshMemorySnapshot()
    }

    /// The sources a notebook lists as rows: its own sources as synced here
    /// (on a value narrowed for a voice conversation, what that reads),
    /// without the spoken scripts (explainers, an audio overview's carrier),
    /// which belong under their source or the Studio. Its context notebooks'
    /// are their groups' (`contextNotebookGroups`).
    func notebookSources(in notebook: MobileCloudNotebook) -> [MobileCloudSource] {
        sources(in: notebook).filter { !MobileSourceListing.isSpokenScript($0) }
    }

    /// How many sources the notebook's card and list say it holds: a book's
    /// chapters count as the one book, as on the Mac (`NotebookSourceTally`).
    func notebookSourceCount(in notebook: MobileCloudNotebook) -> Int {
        NotebookSourceTally.count(notebookSources(in: notebook)) { source in
            source.sourceType == "book" ? source.parentGroup : nil
        }
    }

    deinit {
        if let player = initializedPlayer, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        syncedAudioObservationTask?.cancel()
    }

    var canSeek: Bool {
        duration > 0
    }

    /// The direct autoplay flow used by voice commands keeps its opening until
    /// the whole narration arrives. UI-started background generation is keyed
    /// separately and may be dismissed without cancelling or reopening it.
    var canDismissPlayback: Bool {
        guard let currentItem else { return false }
        return textToSpeechPreparingSourceID != currentItem.id
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var playerDetailText: String {
        let elapsed = Self.formatTime(currentTime)
        let total = duration > 0 ? Self.formatTime(duration) : "--:--"
        return "\(elapsed) / \(total) - \(MobileAudioPlaybackSpeed.label(for: speed))"
    }

    var voiceStatusText: String {
        if isReviewActive {
            if isChatResponding {
                return "Grading your answer"
            }
            return reviewStatus ?? "review"
        }
        if isChatResponding {
            return "Thinking"
        }
        if isSourceChatActive, let activeChatTitle {
            return "Discussing \(activeChatTitle)"
        }
        if voice.isListening {
            return "Listening for your answer"
        }
        if speech.isSpeaking {
            return "Speaking"
        }
        return "Use Siri to control ForeverLM"
    }

    /// Coalesces the phone window, CarPlay, and lifecycle triggers onto one
    /// publication pass. A launch can activate its scene while the root `.task`
    /// is still loading; allowing both callers through made Home return to the
    /// full-screen "Syncing your sources" state for a second, shorter pass.
    ///
    /// `scansNarrations` is false for a reload the replica asked for (a write or a sync round): the audio
    /// tree in iCloud Drive is walked at launch and when the app comes forward, not for each of those.
    @discardableResult
    func load(forceRefresh: Bool = true, scansNarrations: Bool = true) async -> Bool {
        if forceRefresh {
            forcedCatalogReloadRequested = true
        }
        if scansNarrations {
            narrationScanRequested = true
        }
        if let activeCatalogLoad {
            return await activeCatalogLoad.task.value
        }

        let id = UUID()
        let task: Task<Bool, Never> = Task { @MainActor [weak self] in
            guard let self else { return false }
            var succeeded = false
            repeat {
                let shouldForceRefresh = self.forcedCatalogReloadRequested
                self.forcedCatalogReloadRequested = false
                let shouldScanNarrations = self.narrationScanRequested
                self.narrationScanRequested = false
                succeeded = await self.performLoad(forceRefresh: shouldForceRefresh, scansNarrations: shouldScanNarrations)
            } while self.forcedCatalogReloadRequested
            if self.activeCatalogLoad?.id == id {
                self.activeCatalogLoad = nil
            }
            return succeeded
        }
        activeCatalogLoad = (id, task)
        return await task.value
    }

    /// True while a first sync is running and the full-screen readout is not:
    /// either sources are already on screen behind it, or the learner left it.
    /// Ordinary delta syncs stay silent — this is the multi-minute pass only.
    var showsShellSyncStatus: Bool {
        (isInitialCatalogSync || isInitialNarrationScan)
            && (!allSources.isEmpty || hasDismissedInitialSyncScreen)
    }

    /// Deals today's cards again from the catalog. Local only: it runs before
    /// a recorded voice answer returns to the tutor and on the load's
    /// checkpoint, so it never waits on CloudKit. The minutes and new cards a
    /// day are the account's as last read (`memoryReviewPreferences`); the
    /// new cards are set on the Mac or over MCP, the phone having no control
    /// of its own for them.
    func refreshMemorySnapshot() async {
        todayMemoryCards = await sourceCatalog.currentTodayMemoryCards(
            budgetMinutes: memoryReviewPreferences.budgetMinutes,
            newPerDay: memoryReviewPreferences.newCardsPerDay
        )
        cardsToCheckTotal = await sourceCatalog.currentCardsToCheck(scope: .allNotebooks)?.count ?? cardsToCheckTotal
        memoryCardsRevision &+= 1
    }

    /// The learner changed the day's minutes in the phone's Settings, which
    /// wrote the synced row: today's cards are cut to the new budget now,
    /// rather than at the next load (which re-reads the row, on every
    /// foreground as well).
    func memoryReviewBudgetDidChange(to minutes: Int) async {
        let minutes = MemoryReviewBudget.clamp(minutes)
        guard minutes != memoryReviewPreferences.budgetMinutes else { return }
        memoryReviewPreferences.budgetMinutes = minutes
        await refreshMemorySnapshot()
    }

    /// Re-reads the day's minutes and new cards, two CloudKit fetches side by
    /// side, and deals today's cards again when either changed. A failed read
    /// keeps the value last read; a learner who never set one has the
    /// product's default, the Mac's.
    private func refreshMemoryReviewPreferences() async {
        async let budgetRead = Self.syncedIntRead(MemoryReviewBudget.preferenceKey)
        async let newCardsRead = Self.syncedIntRead(MemoryCardQueue.newPerDayPreferenceKey)
        let budget = await budgetRead
        let newCards = await newCardsRead
        let refreshed = memoryReviewPreferences.refreshed(budgetRead: budget, newCardsRead: newCards)
        guard refreshed != memoryReviewPreferences else { return }
        memoryReviewPreferences = refreshed
        await refreshMemorySnapshot()
    }

    /// One synced whole number's read: nil when the learner never set it, a
    /// failure when iCloud did not answer.
    private nonisolated static func syncedIntRead(_ key: String) async -> Result<Int?, Error> {
        do {
            return .success(try await MobileModelPreferenceStore.shared.int(forKey: key))
        } catch {
            return .failure(error)
        }
    }

    private func performLoad(forceRefresh: Bool, scansNarrations: Bool = true) async -> Bool {
        defer {
            publishSyncStatus(nil)
        }

        await refreshManagedSignInState()
        isLoading = true

        // Publish the durable checkpoint first — before the audio manifests and
        // before asking CloudKit for deltas. It is local SQLite and costs
        // nothing, so rebuilds open on the previously synced library.
        //
        // Order matters here, and it is not cosmetic. The manifest pass below
        // walks the shared iCloud audio tree, and that tree is now thousands of
        // files: it asks CloudDocs to materialize every manifest the Mac has
        // published. Loading it ahead of this publish, with `isLoading` gated
        // behind it, meant one slow or wedged CloudDocs could hide a fully
        // synced library behind the spinner indefinitely — the library was
        // never lost, it was simply never shown. (The same pass used to gate the
        // CloudKit walk too; it now runs alongside it, see below.)
        let checkpointSources = await sourceCatalog.currentSources()
        if !checkpointSources.isEmpty {
            notebooks = await sourceCatalog.currentNotebooks()
            goals = await sourceCatalog.currentGoals()
            collections = await sourceCatalog.currentCollections()
            audioOverviewRecords = await sourceCatalog.currentAudioOverviews()
            await publishNotebookCatalog()
            publishCatalogSources(checkpointSources)
            scheduledSources = await sourceCatalog.currentScheduledSources()
            scheduleItems = await sourceCatalog.currentScheduleItems()
            // The library is on screen. Everything after this point refines it.
            isLoading = false
        }
        await refreshMemorySnapshot()
        // The day's minutes cut today's cards and its new cards cap them;
        // their read waits on CloudKit, so it runs beside the load rather
        // than ahead of it.
        Task { [weak self] in await self?.refreshMemoryReviewPreferences() }

        // The manifest pass rides alongside the CloudKit sync, never ahead of
        // it. It walks the shared iCloud audio tree — hundreds of narrations,
        // gigabytes of chunks — and on a device that has not materialized those
        // files yet every manifest read blocks until CloudDocs delivers it. The
        // checkpoint publish above shields a rebuild from that, but a first
        // launch has no checkpoint: with the manifests awaited first, the zone
        // walk never started, no progress line ever fired, and the setup screen
        // sat on "Connecting to iCloud…" for as long as iCloud Drive took. Now
        // the walk starts immediately and the audio badges land whenever the
        // manifests do, re-stamping whichever rows are on screen by then.
        //
        // On a first launch the scan reports its own count, so that once the
        // CloudKit readout clears the shell row says how many source folders
        // are still to check rather than a bare "Syncing your library".
        let manifestLoad: Task<Void, Error>? = !scansNarrations ? nil : Task { [weak self] () throws -> Void in
            defer {
                Task { @MainActor [weak self] in
                    self?.isInitialNarrationScan = false
                    self?.publishNarrationScanStatus(nil)
                }
            }
            // The replica's narrations are laid into the working folder first, and one this phone made is
            // uploaded in the background (§3.5.30).
            await MobileNarrationLibrary.shared.refresh()
            let manifests = try await Task.detached(priority: .userInitiated) {
                try SyncedArticleAudioStore.loadAvailableManifests(onProgress: { _, _ in })
            }.value
            guard let self else { return }
            self.items = manifests.map(MobileAudioItem.init(manifest:))
            // `hasAudio` is read off `items`, so rows published before this
            // point — the checkpoint, or the walk's progressive fill — carried
            // none. Stamping the published rows again is idempotent.
            if !self.allSources.isEmpty {
                self.publishCatalogSources(self.allSources)
            }
            self.startObservingSyncedAudioManifests()
        }

        var catalogLoadSucceeded = false
        do {
            let catalog = try await sourceCatalog.loadSources(forceRefresh: forceRefresh)
            // Same zone pass as the sources — refreshing here keeps the Notebooks
            // list and the book/course metadata as fresh as the sources they shape.
            notebooks = (try? await sourceCatalog.loadNotebooks()) ?? notebooks
            goals = await sourceCatalog.currentGoals()
            collections = (try? await sourceCatalog.loadCollections()) ?? collections
            audioOverviewRecords = await sourceCatalog.currentAudioOverviews()
            await publishNotebookCatalog()
            publishCatalogSources(catalog)
            scheduledSources = await sourceCatalog.currentScheduledSources()
            scheduleItems = await sourceCatalog.currentScheduleItems()
            await refreshMemorySnapshot()
            // The library is on screen, and what is left (the narration scan beside this load) only refines it.
            // A phone that switched has no checkpoint to publish ahead of this, so the spinner it opened on
            // would otherwise wait for the walk of the iCloud Drive audio tree as well.
            if !allSources.isEmpty { isLoading = false }
            if allSources.isEmpty {
                sourceSyncDiagnostic = await sourceCatalog.diagnose()
            } else {
                sourceSyncDiagnostic = MobileSourceSyncDiagnostic(
                    accountStatus: "not checked",
                    knowledgeZoneStatus: "load succeeded",
                    sourceRecordCount: catalog.count,
                    decodedSourceCount: catalog.count,
                    zoneRecordCount: nil,
                    zoneRecordTypes: nil,
                    errorMessage: nil,
                    checkedAt: Date()
                )
            }
            catalogLoadSucceeded = true
            if errorMessage == lastSourceSyncErrorMessage {
                errorMessage = nil
            }
            lastSourceSyncErrorMessage = nil
        } catch {
            sourceSyncDiagnostic = await sourceCatalog.diagnose()
            let message = "Sources could not sync: \(MobileCloudKitRetry.describe(error))"
            lastSourceSyncErrorMessage = message
            errorMessage = message
        }

        // Home's collections are found through the notebooks just published
        // (`MobileNotebookCollectionsStore`); their reads wait on CloudKit,
        // so they run beside the rest of the load rather than ahead of it.
        Task { [weak self] in await self?.refreshNotebookCollections() }
        // Home's Pinned and the learner's notebook order, the same way.
        Task { [weak self] in await self?.refreshNotebookRail() }

        var manifestError: Error?
        do {
            try await manifestLoad?.value
        } catch {
            manifestError = error
            items = []
        }

        // A library that would not sync still lists the narrations this device
        // holds — decided once both passes have reported, so the fallback rows
        // reflect the manifests that actually arrived.
        if !catalogLoadSucceeded, allSources.isEmpty {
            allSources = items.map {
                MobileCloudSource(
                    id: $0.id,
                    title: $0.title,
                    subtitle: $0.subtitle,
                    sourceType: $0.manifest.sourceType,
                    dateAdded: $0.createdAt,
                    hasAudio: true,
                    isArchived: false
                )
            }
        }

        if allSources.isEmpty,
           lastSourceSyncErrorMessage == nil,
           let error = manifestError {
            errorMessage = error.localizedDescription
        }

        // Source/manifest loading is done; clear the loading overlay before the
        // hands-free voice session starts. Voice startup (mic/speech authorization,
        // continuous listening) must never keep the "Loading Audio" spinner up.
        isLoading = false
        scheduleAutomaticAudioGeneration()

        // Refresh Spotlight's semantic index so Siri AI / Apple Intelligence can resolve
        // "quiz me on <source>" by meaning. Off the main actor, never blocks the UI.
        if #available(iOS 18.0, *) {
            let snapshot = allSources
            Task.detached(priority: .utility) {
                await SourceSpotlightIndexer.index(snapshot)
            }
        }
        return catalogLoadSucceeded
    }

    /// `startAt` overrides the stored resume point. The opening-section handover
    /// uses it to continue at the exact second the listener had reached, which
    /// the saved position cannot express: that position is cleared near the end
    /// of a source, and the opening ending *is* near its own end.
    func play(_ item: MobileAudioItem, startAt: TimeInterval? = nil) async {
        // Deliberately ahead of `isLoading`: a first-time download is a wait
        // with a length and a progress bar, not the library's loading spinner.
        // The download starts the opening itself as soon as the first chunks
        // are here, so by the time it returns the listener may already be
        // some way into the chapter.
        do {
            try await materializeNarrationIfNeeded(item, startAt: startAt)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Narration could not download: \(error.localizedDescription)"
            return
        }

        // Hand over from the streamed opening to the whole composition without
        // moving the listener: same second, and still paused if they paused it.
        var startAt = startAt
        var keepPausedAfterHandover = false
        if openingPlaybackSourceID == item.id, currentItem?.id == item.id {
            startAt = currentTime
            keepPausedAfterHandover = !isPlaying && !openingPlaybackRanDry
            openingPlaybackSourceID = nil
            isAwaitingRemainingNarration = false
            openingPlaybackRanDry = false
        }

        isLoading = true
        defer { isLoading = false }

        do {
            if let openingPlaybackSourceID, openingPlaybackSourceID != item.id {
                self.openingPlaybackSourceID = nil
                isAwaitingRemainingNarration = false
                openingPlaybackRanDry = false
            }
            persistPlaybackPosition(force: true)
            try await configureAudioSession()
            let urls = try await Task.detached(priority: .userInitiated) {
                try SyncedArticleAudioStore.chunkURLs(for: item.manifest)
            }.value
            async let compositionLoad = audioComposition(for: urls)
            // The account copy is what the other device most recently wrote;
            // the file is what CloudDocs happens to have delivered. Newer wins.
            async let savedPositionLoad = Task.detached(priority: .utility) {
                await SyncedArticleAudioStore.loadPlaybackPositionIncludingAccount(sourceID: item.id)
            }.value
            let composition = try await compositionLoad
            let savedPosition = await savedPositionLoad
            let playerItem = await MobileLoudnessAudioMix.playerItem(for: composition.asset)

            removeEndObserver()
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.finishFullPlaybackIfNeeded(
                        playerItem: playerItem,
                        sourceID: item.id
                    )
                }
            }

            let resumeTime = startAt.map { min(max($0, 0), composition.duration) }
                ?? Self.resumeTime(
                    from: savedPosition,
                    manifest: item.manifest,
                    duration: composition.duration
                )
            currentItem = item
            Task { [weak self] in await self?.loadNowPlayingArtwork(for: item) }
            if bookContinuationOffer?.completedSourceID != item.id {
                bookContinuationOffer = nil
            }
            if pendingAutomaticBookContinuation?.completedSourceID != item.id {
                pendingAutomaticBookContinuation = nil
            }
            activeVoiceSourceID = item.id
            activeVoiceSourceTitle = item.title
            duration = composition.duration
            currentTime = resumeTime
            lastPlaybackPositionSaveAt = nil
            player.replaceCurrentItem(with: playerItem)
            if resumeTime > 0 {
                await player.seek(
                    to: CMTime(seconds: resumeTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            player.playImmediately(atRate: speed)
            isPlaying = true
            if keepPausedAfterHandover {
                togglePlayback()
            }
            updateNowPlayingInfo()
            Task { [weak self] in
                await self?.recordSourceActivity(sourceID: item.id, kind: .listening)
            }
            prefetchNextBookChapterAudio(after: item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pulls the next chapter's chunks down while this one plays, so the book
    /// carries on without the download gap this chapter may just have had.
    /// Nothing is generated and nothing is shown: the chunks simply arrive,
    /// and the next `play` finds them local. A chapter without synced audio is
    /// left to the continuation code, which owns the decision to spend money.
    private func prefetchNextBookChapterAudio(after sourceID: String) {
        nextChapterPrefetchTask?.cancel()
        nextChapterPrefetchTask = nil
        guard let nextChapter = nextBookChapter(after: sourceID),
              let nextItem = itemForSourceID(nextChapter.id) else { return }
        let manifest = nextItem.manifest
        nextChapterPrefetchTask = Task.detached(priority: .utility) {
            guard !SyncedArticleAudioStore.hasLocalChunks(for: manifest) else { return }
            try? await SyncedArticleAudioStore.materializeChunks(for: manifest) { _ in }
        }
    }

    func togglePlayback() {
        guard currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            if openingPlaybackSourceID != nil {
                openingPlaybackRanDry = false
            }
            persistPlaybackPosition(force: true)
        } else {
            // An opening section that has run out is not a finished source, so
            // resuming must not replay it from the top while the rest arrives.
            if duration > 0, currentTime >= duration, !isAwaitingRemainingNarration {
                completedPlayerItemIdentity = nil
                seek(to: 0)
            }
            player.playImmediately(atRate: speed)
            isPlaying = true
        }
        updateNowPlayingInfo()
    }

    /// Removes the app-shell player without deleting generated audio. This is
    /// intentionally distinct from pause: a paused or completed item remains
    /// resumable in the mini-player until the learner explicitly closes it.
    func dismissPlayback() {
        guard canDismissPlayback, let dismissedItem = currentItem else { return }
        player.pause()
        isPlaying = false
        if duration - currentTime > 1 {
            persistPlaybackPosition(force: true)
        } else {
            clearPlaybackPosition(for: dismissedItem.id)
        }
        removeEndObserver()
        player.replaceCurrentItem(with: nil)
        if openingPlaybackSourceID == dismissedItem.id {
            openingPlaybackSourceID = nil
            isAwaitingRemainingNarration = false
            openingPlaybackRanDry = false
        }
        currentItem = nil
        bookContinuationOffer = nil
        pendingAutomaticBookContinuation = nil
        nextChapterPrefetchTask?.cancel()
        nextChapterPrefetchTask = nil
        currentTime = 0
        duration = 0
        lastPlaybackPositionSaveAt = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        updateNowPlayingInfo()
    }

    func nextBookChapter(after sourceID: String) -> MobileCloudSource? {
        guard let source = source(for: sourceID),
              source.sourceType == "book",
              let parentGroup = source.parentGroup,
              !parentGroup.isEmpty else { return nil }
        let chapters = allSources
            .filter { $0.sourceType == "book" && $0.parentGroup == parentGroup }
            .sorted(by: MobileSourceGrouping.memberOrder)
        guard let index = chapters.firstIndex(where: { $0.id == sourceID }),
              chapters.indices.contains(index + 1) else { return nil }
        return chapters[index + 1]
    }

    func prepareNextBookChapter(after sourceID: String) async {
        guard let nextChapter = nextBookChapter(after: sourceID),
              !hasSyncedTextToSpeechAudio(sourceID: nextChapter.id),
              !isPreparingAudio(sourceID: nextChapter.id) else { return }
        do {
            _ = try await prepareSourceAudio(sourceID: nextChapter.id)
        } catch {
            errorMessage = "The next chapter could not be generated: \(error.localizedDescription)"
        }
    }

    func playNextBookChapter(after sourceID: String) async {
        guard let nextChapter = nextBookChapter(after: sourceID) else { return }
        await readSourceAloud(sourceID: nextChapter.id)
    }

    func respondToBookContinuationOffer(
        _ offer: MobileBookContinuationOffer,
        enable: Bool
    ) async {
        if bookContinuationOffer == offer {
            bookContinuationOffer = nil
        }
        MobileBookPlaybackPreferences.hasAskedToAutomaticallyContinue = true
        MobileBookPlaybackPreferences.automaticallyContinues = enable
        guard enable else { return }
        await automaticallyContinueBook(
            from: offer.completedSourceID,
            to: offer.nextSourceID
        )
    }

    func dismissBookContinuationOffer() {
        guard bookContinuationOffer != nil else { return }
        bookContinuationOffer = nil
        MobileBookPlaybackPreferences.hasAskedToAutomaticallyContinue = true
    }

    func setSpeed(_ newSpeed: Float) {
        speed = MobileAudioPlaybackSpeed.clamped(newSpeed)
        UserDefaults.standard.set(speed, forKey: MobileAudioPlaybackSpeed.defaultsKey)
        if isPlaying {
            player.rate = speed
        }
        updateNowPlayingInfo()
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        seek(to: duration * min(max(fraction, 0), 1))
    }

    func skip(seconds: TimeInterval) {
        guard duration > 0 else { return }
        seek(to: min(max(currentTime + seconds, 0), duration))
        persistPlaybackPosition(force: true)
    }

    /// The direct UI action used by source rows and the reader. Cached audio
    /// starts immediately. Uncached audio uses the source-keyed concurrent path;
    /// the first ready opening claims playback while every requested source
    /// continues generating in the background.
    func toggleTextToSpeech(sourceID: String) async {
        errorMessage = nil
        // The narration is still coming down and its opening is already the
        // player: a tap means pause or resume, not a second download of the
        // same chapter racing the first.
        if narrationDownloadSourceID == sourceID {
            if currentItem?.id == sourceID { togglePlayback() }
            return
        }
        if currentItem?.id == sourceID {
            // The player can still be holding a truncated prefix from a
            // generation that was interrupted, while the finished audio has
            // since landed in the catalog. Listen means the whole source, not a
            // replay of the fragment — so take the longer composition, at the
            // second the listener is already on.
            if let complete = itemForSourceID(sourceID),
               complete.manifest.chunks.count > (currentItem?.manifest.chunks.count ?? 0) {
                await play(complete, startAt: currentTime)
                return
            }
            togglePlayback()
            return
        }
        guard !isPreparingAudio(sourceID: sourceID) else { return }

        if let item = itemForSourceID(sourceID) {
            await play(item)
            return
        }

        do {
            _ = try await prepareSourceAudio(
                sourceID: sourceID,
                playsOpeningWhenReady: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func flushPlaybackProgress() {
        persistPlaybackPosition(force: true)
    }

    /// The one mobile completion boundary for both reading and listening. It
    /// patches the Source's explicit consumption date and records a completed
    /// Schedule placement, making the source available to tomorrow's MCP
    /// request for yesterday's material.
    @discardableResult
    func recordSourceConsumption(
        sourceID: String,
        kind: SourceActivityKind,
        completedAt: Date = Date()
    ) async -> Bool {
        let activityKey = "\(sourceID):\(Calendar.current.startOfDay(for: completedAt).timeIntervalSinceReferenceDate):\(kind.rawValue)"
        if sourceConsumptionRecordedIDs.contains(activityKey) { return true }
        guard sourceConsumptionInFlightIDs.insert(activityKey).inserted else { return false }
        defer { sourceConsumptionInFlightIDs.remove(activityKey) }

        guard let source = allSources.first(where: { $0.id == sourceID }) else {
            errorMessage = "Finished playback could not be logged because that source is not in the synced library."
            return false
        }
        let existingPlacement = scheduledPlacement(for: sourceID)
        let order = nextScheduleOrder(on: completedAt, excluding: sourceID)
        do {
            let completedPlacement = try await MobileCloudMutationService.shared
                .recordSourceConsumption(
                    source: source,
                    existingPlacement: existingPlacement,
                    completedAt: completedAt,
                    order: order,
                    kind: kind
                )
            sourceConsumptionRecordedIDs.insert(activityKey)
            publishRecordedConsumption(
                source: source,
                placement: completedPlacement,
                completedAt: completedAt
            )
            return true
        } catch {
            if Self.isCancelledCloudWrite(error) {
                // Nothing to act on: the task carrying this write was torn down
                // or CloudKit dropped the operation. The completion key was not
                // recorded, so reaching the end again retries it.
                Self.activityLogger.info(
                    "Cancelled while logging \(kind.rawValue, privacy: .public) completion for \(sourceID, privacy: .public)"
                )
                return false
            }
            errorMessage = "Finished source could not be logged: \(error.localizedDescription)"
            return false
        }
    }

    /// Explicitly records material completed in another app. Source identity is
    /// resolved before this method; mobile writes the same activity-ledger shape
    /// used by in-app reading and playback.
    @discardableResult
    func recordExternalSourceCompletions(
        sourceIDs: [String],
        kind: SourceActivityKind,
        completedAt: Date = Date()
    ) async -> Bool {
        let stableIDs = sourceIDs.reduce(into: [String]()) { result, raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !result.contains(id) { result.append(id) }
        }
        guard !stableIDs.isEmpty else {
            errorMessage = "Choose at least one source to log."
            return false
        }
        let availableIDs = Set(allSources.filter { !$0.isArchived && $0.state == "ready" }.map(\.id))
        if let missingID = stableIDs.first(where: { !availableIDs.contains($0) }) {
            errorMessage = "Source \(missingID) is archived, unavailable, or not in the synced library."
            return false
        }
        for sourceID in stableIDs {
            guard await recordSourceConsumption(
                sourceID: sourceID,
                kind: kind,
                completedAt: completedAt
            ) else { return false }
        }
        return true
    }

    /// Put a source on today's calendar as soon as reading, listening, or a
    /// review starts. Existing planned placements stay on their chosen day.
    func recordSourceActivity(sourceID: String, kind: SourceActivityKind) async {
        let startedAt = Date()
        let activityKey = "\(sourceID):\(Calendar.current.startOfDay(for: startedAt).timeIntervalSinceReferenceDate):\(kind.rawValue)"
        guard !sourceActivityRecordedIDs.contains(activityKey),
              sourceActivityInFlightIDs.insert(activityKey).inserted else { return }
        defer { sourceActivityInFlightIDs.remove(activityKey) }

        guard let source = allSources.first(where: { $0.id == sourceID }) else {
            errorMessage = "Source activity could not be logged because that source is not in the synced library."
            return
        }

        // The reader and chat screens start this write from a SwiftUI `.task`,
        // which is cancelled the moment the screen is dismissed. The learner did
        // open the source, so the ledger write runs in its own task and lands
        // even when the screen is gone before the CloudKit round trip returns.
        // Cancelling the write instead surfaced "Operation … was cancelled" as
        // an error banner over the next screen.
        let existingPlacement = scheduledPlacement(for: sourceID)
        let order = nextScheduleOrder(on: startedAt, excluding: sourceID)
        let write = Task {
            try await MobileCloudMutationService.shared
                .recordSourceActivity(
                    source: source,
                    existingPlacement: existingPlacement,
                    startedAt: startedAt,
                    order: order,
                    kind: kind
                )
        }
        do {
            let placement = try await write.value
            sourceActivityRecordedIDs.insert(activityKey)
            publishRecordedActivity(source: source, placement: placement)
        } catch {
            if Self.isCancelledCloudWrite(error) {
                // CloudKit itself dropped the operation (the app was suspended
                // mid-flight, for instance). Not the learner's problem and not
                // actionable; the key stays unrecorded so the next start retries.
                Self.activityLogger.info(
                    "Cancelled while logging \(kind.rawValue, privacy: .public) activity for \(sourceID, privacy: .public)"
                )
                return
            }
            errorMessage = "Source activity could not be logged: \(error.localizedDescription)"
        }
    }

    /// A write that stopped because its task was cancelled or CloudKit cancelled
    /// the operation. Neither says anything about the request, so neither is
    /// worth a banner; the Mac sync engine excludes the same two from its
    /// failure counts.
    nonisolated static func isCancelledCloudWrite(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let cloudError = error as? CKError { return cloudError.code == .operationCancelled }
        let nsError = error as NSError
        return nsError.domain == CKErrorDomain
            && nsError.code == CKError.Code.operationCancelled.rawValue
    }

    /// Promote resumable playback/scroll position into durable consumption
    /// evidence, mirroring what `ArticleSpeechService` records on the Mac.
    ///
    /// Without this, abandoning a podcast at 70% leaves nothing behind but a
    /// device-local resume position, and the memory tutor cannot tell that
    /// episode apart from one that was never opened — so it never gets quizzed.
    /// Depth merges with MAX everywhere, so repeated calls are safe and a
    /// backwards seek never lowers what was already reached.
    /// Cheap synchronous test of the same threshold `recordSourceDepth` applies,
    /// so a scroll observer firing every frame does not spawn a task per event
    /// only for it to be discarded.
    func shouldRecordDepth(sourceID: String, fraction: Double) -> Bool {
        guard fraction.isFinite else { return false }
        let clamped = SourceActivityDay.clampFraction(fraction)
        return clamped - (recordedSourceDepths[sourceID] ?? 0) >= Self.depthReportingStep
    }

    func recordSourceDepth(
        sourceID: String,
        kind: SourceActivityKind,
        fraction: Double
    ) async {
        guard fraction.isFinite else { return }
        let clamped = SourceActivityDay.clampFraction(fraction)
        guard clamped > 0 else { return }
        // Every tick is time with the source: count it toward the ledger's
        // engaged seconds, to be written with the next depth step.
        let occurredAt = Date()
        if let last = depthTickAt[sourceID] {
            let gap = occurredAt.timeIntervalSince(last)
            if gap > 0, gap <= Self.maxEngagedTickGap {
                pendingEngagedSeconds[sourceID, default: 0] += gap
            }
        }
        depthTickAt[sourceID] = occurredAt
        // A write per clock tick would be one CloudKit round trip per second for
        // no added evidence. Only a materially deeper point is worth publishing.
        guard clamped - (recordedSourceDepths[sourceID] ?? 0) >= Self.depthReportingStep else {
            return
        }
        let depthKey = "\(sourceID):\(kind.rawValue):depth"
        guard sourceActivityInFlightIDs.insert(depthKey).inserted else { return }
        defer { sourceActivityInFlightIDs.remove(depthKey) }

        guard let source = allSources.first(where: { $0.id == sourceID }) else { return }
        let engaged = pendingEngagedSeconds.removeValue(forKey: sourceID) ?? 0
        do {
            let placement = try await MobileCloudMutationService.shared
                .recordSourceActivity(
                    source: source,
                    existingPlacement: scheduledPlacement(for: sourceID),
                    startedAt: occurredAt,
                    order: nextScheduleOrder(on: occurredAt, excluding: sourceID),
                    kind: kind,
                    fraction: clamped,
                    engagedSeconds: engaged
                )
            recordedSourceDepths[sourceID] = max(
                recordedSourceDepths[sourceID] ?? 0,
                clamped
            )
            publishRecordedActivity(source: source, placement: placement)
        } catch {
            // The time counted goes back on the tab for the next write.
            pendingEngagedSeconds[sourceID, default: 0] += engaged
            // Depth is opportunistic background evidence. A failed write must
            // never interrupt playback or reading with a banner; the next
            // threshold crossing retries it.
            Self.activityLogger.error(
                "Failed to log \(kind.rawValue, privacy: .public) depth for \(sourceID, privacy: .public): \(error.localizedDescription)"
            )
        }
    }

    private func publishRecordedActivity(
        source: MobileCloudSource,
        placement: MobileCloudScheduledSource
    ) {
        if let placementIndex = scheduledSources.firstIndex(where: { $0.id == placement.id }) {
            scheduledSources[placementIndex] = placement
        } else {
            scheduledSources.append(placement)
        }
        let row = MobileScheduledCatalogItem(
            id: placement.id,
            source: source,
            plannedAt: placement.plannedAt,
            isCompleted: placement.isCompleted,
            completedAt: placement.completedAt,
            groupTitle: source.parentGroup.flatMap { groupID in
                collections.booksByID[groupID]?.title ?? collections.coursesByID[groupID]?.title
            },
            goalTitles: [],
            goalIDs: placement.goalIDs,
            activityDays: placement.activityDays,
            isAutomatic: placement.isAutomatic
        )
        if let index = scheduleItems.firstIndex(where: { $0.id == placement.id }) {
            scheduleItems[index] = row
        } else {
            scheduleItems.append(row)
            scheduleItems.sort { $0.plannedAt < $1.plannedAt }
        }
    }

    /// Publish the successful write without launching a visible catalog reload
    /// at the exact moment narration ends. The next activation/voice tool's
    /// event-driven delta reconciles the durable CloudKit record normally.
    private func publishRecordedConsumption(
        source: MobileCloudSource,
        placement: MobileCloudScheduledSource,
        completedAt: Date
    ) {
        if let sourceIndex = allSources.firstIndex(where: { $0.id == source.id }) {
            allSources[sourceIndex].readAt = allSources[sourceIndex].readAt ?? completedAt
        }
        if let placementIndex = scheduledSources.firstIndex(where: { $0.id == placement.id }) {
            scheduledSources[placementIndex] = placement
        } else {
            scheduledSources.append(placement)
        }

        let existingItem = scheduleItems.first { $0.id == placement.id }
        let groupTitle = existingItem?.groupTitle ?? source.parentGroup.flatMap { groupID in
            collections.booksByID[groupID]?.title ?? collections.coursesByID[groupID]?.title
        }
        let goalTitles = existingItem?.goalTitles ?? []
        let row = MobileScheduledCatalogItem(
            id: placement.id,
            source: allSources.first(where: { $0.id == source.id }) ?? source,
            plannedAt: placement.plannedAt,
            isCompleted: true,
            completedAt: placement.completedAt ?? completedAt,
            groupTitle: groupTitle,
            goalTitles: goalTitles,
            goalIDs: placement.goalIDs,
            activityDays: placement.activityDays,
            isAutomatic: placement.isAutomatic
        )
        if let index = scheduleItems.firstIndex(where: { $0.id == placement.id }) {
            scheduleItems[index] = row
        } else {
            scheduleItems.append(row)
            scheduleItems.sort { $0.plannedAt < $1.plannedAt }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Mobile Notebook and Schedule mutations

    func scheduledPlacement(for sourceID: String) -> MobileCloudScheduledSource? {
        scheduledSources.first { $0.sourceID == sourceID }
    }

    func scheduledPlacement(id: String) -> MobileCloudScheduledSource? {
        scheduledSources.first { $0.id == id }
    }

    func createNotebook(title: String, instructions: String?, summary: String? = nil) async -> String? {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.createNotebook(
                title: title,
                instructions: instructions,
                summary: summary
            )
        }
    }

    /// New notebook: made at once under the placeholder ("New notebook",
    /// numbered while taken) with the `notebook.naming.<id>` row, so ForeverLM
    /// on the Mac names it, title and card description, once it holds a
    /// source or a chat exchange (`NotebookNaming`).
    func createUnnamedNotebook() async -> String? {
        let placeholder = NotebookNaming.placeholder(existingTitles: notebooks.map(\.title))
        guard let id = await createNotebook(title: placeholder, instructions: nil) else { return nil }
        do {
            let key = NotebookNaming.preferenceKey(notebookID: id)
            let mark = NotebookNaming.Mark.unnamed(title: placeholder).encoded
            try await MobileNotebookRows.write(key, string: mark, writer: MobileRecordWriter.required())
            // Only a notebook with its naming row waits for its name; one without it would be drawn from the placeholder.
            await requestNotebookCover(id)
        } catch {
            // The notebook is made; it keeps the placeholder until renamed.
            errorMessage = "ForeverLM can't name this notebook: \(error.localizedDescription)"
        }
        return id
    }

    /// A notebook made one at a time is drawn a cover by a Mac (D53): a `Job(makeDerived)` a Mac claims
    /// and draws once the notebook has its name, unless Draw notebook covers is off.
    /// Imports and shares never come here.
    private func requestNotebookCover(_ id: String) async {
        guard let writer = await MobileRecordWriter.current() else { return }
        let preferences = MobileModelPreferenceStore.shared
        await MobileNotebookCoverRequest.requestIfWanted(
            notebookID: id,
            writer: writer,
            automatic: { try await preferences.bool(forKey: MobileNotebookCover.automaticSettingKey) }
        )
    }

    /// The phone's New notebook, on Home and the Notebooks screen: an unnamed
    /// notebook (`createUnnamedNotebook`), in `collectionID` when the screen
    /// shows that collection, as the Mac's home files it
    /// (`StudioViewModel.createNotebook`). The caller opens it.
    func createNotebook(inCollection collectionID: String? = nil) async -> String? {
        guard let id = await createUnnamedNotebook() else { return nil }
        if let collectionID {
            await setNotebook(id, inCollection: collectionID, isMember: true)
        }
        return id
    }

    /// `summary` nil keeps the card description; a string (even empty) replaces it.
    func updateNotebook(id: String, title: String, instructions: String, summary: String? = nil) async -> Bool {
        let before = notebooks.first { $0.id == id }
        let updated = await performLibraryMutation {
            try await MobileCloudMutationService.shared.updateNotebook(
                id: id,
                title: title,
                instructions: instructions,
                replaceInstructions: true,
                summary: summary,
                replaceSummary: summary != nil
            )
            return true
        } ?? false
        // A name or description the learner typed: ForeverLM never renames
        // the notebook after it (`NotebookNaming`).
        let renamed = before.map { $0.title != title.trimmingCharacters(in: .whitespacesAndNewlines) } ?? true
        let redescribed = summary.map { NotebookSummary.normalized($0) != before?.summary } ?? false
        if updated, renamed || redescribed {
            let key = NotebookNaming.preferenceKey(notebookID: id)
            if let writer = await MobileRecordWriter.current() { try? await MobileNotebookRows.write(key, string: nil, writer: writer) }
        }
        return updated
    }

    func archiveNotebook(id: String) async -> Bool {
        let archived = await performLibraryMutation {
            try await MobileCloudMutationService.shared.updateNotebook(id: id, status: "archived")
            return true
        } ?? false
        // A notebook put away is not the one the next launch reopens.
        if archived { MobileLastNotebookStore.standard.forget(id) }
        return archived
    }

    /// Links `contextNotebookID` to the notebook `notebookID` as a context
    /// notebook, after its other links. Putting it into the chats is the
    /// member's row (`MobileNotebookContextLinks.add`).
    func linkContextNotebook(_ contextNotebookID: String, toNotebookID notebookID: String) async -> Bool {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.linkContextNotebook(contextNotebookID, toNotebookID: notebookID)
            return true
        } ?? false
    }

    /// Unlinks `contextNotebookID` from the notebook `notebookID`; Take Out of
    /// Context drops it from the chats' row after (`MobileNotebookContextLinks`).
    func unlinkContextNotebook(_ contextNotebookID: String, fromNotebookID notebookID: String) async -> Bool {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.unlinkContextNotebook(contextNotebookID, fromNotebookID: notebookID)
            return true
        } ?? false
    }

    func deleteNotebook(id: String, deleteLinkedChats: Bool = false) async -> Bool {
        let childGoalIDs = goals.filter { $0.parentNotebookID == id }.map(\.id)
        let placements = scheduledSources
        let deletedGoalIDs = Set(
            [id] + childGoalIDs
        )
        let linkedSessionIDs = await sourceCatalog.currentReviewSessionIDs(
            linkedTo: deletedGoalIDs
        )
        let linkedArtifactIDs = await sourceCatalog.currentArtifactIDs(
            linkedTo: deletedGoalIDs
        )
        let referringNotebookIDs = await sourceCatalog.currentNotebookIDs(
            referringTo: deletedGoalIDs
        )
        let linkedMemoryAttemptIDs: [String]
        if deleteLinkedChats {
            linkedMemoryAttemptIDs = await sourceCatalog.currentMemoryAttemptIDs(
                linkedToSessionIDs: Set(linkedSessionIDs)
            )
        } else {
            linkedMemoryAttemptIDs = []
        }
        let deleted = await performLibraryMutation {
            try await MobileCloudMutationService.shared.deleteNotebook(
                id: id,
                scheduledSources: placements,
                childGoalIDs: childGoalIDs,
                linkedSessionIDs: linkedSessionIDs,
                linkedMemoryAttemptIDs: linkedMemoryAttemptIDs,
                linkedArtifactIDs: linkedArtifactIDs,
                referringNotebookIDs: referringNotebookIDs,
                deleteLinkedChats: deleteLinkedChats
            )
            return true
        } ?? false
        if deleted {
            // Its NotebookState and Entries flip, never delete (§6.4): with the notebook gone they read
            // as nothing, ticks and collections included.
            MobileLastNotebookStore.standard.forget(id)
        }
        return deleted
    }

    func addSources(_ sources: [MobileCloudSource], toNotebookID notebookID: String) async -> Bool {
        let added: Bool = await performLibraryMutation {
            try await MobileCloudMutationService.shared.addSources(sources, toNotebookID: notebookID)
            return true
        } ?? false
        if added {
            await tickNotebookArrivals(sources.map(\.id), notebookID: notebookID)
        }
        return added
    }

    /// A source joining a notebook from the phone, by any route (the
    /// notebook's Sources, Add to Notebook, a capture or a Schedule placement
    /// filed into one), arrives ticked for the notebook's chats: its id leaves
    /// the notebook's `notebook.chatExcluded.<notebookID>` row in the same
    /// action, as the Mac's own adds do, so an untick from when it last left
    /// does not outlive its return. The add stands if this fails, and the
    /// error bar says so; the Mac ticks it when the add reaches it
    /// (`NotebookChatSelection.inboundArrivalsToTick`).
    private func tickNotebookArrivals(_ sourceIDs: [String], notebookID: String) async {
        do {
            try await MobileNotebookChatSelection.tickArrivals(
                sourceIDs,
                notebookID: notebookID,
                read: MobileNotebookChatSelectionStore.cloudRead,
                write: MobileNotebookChatSelectionStore.cloudWrite
            )
        } catch {
            errorMessage = "Added to the notebook, but it could not be ticked for its chats: \(error.localizedDescription)"
        }
    }

    func removeSources(_ sourceIDs: Set<String>, fromNotebookID notebookID: String) async -> Bool {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.removeSources(sourceIDs, fromNotebookID: notebookID)
            return true
        } ?? false
    }

    func scheduleSource(
        _ source: MobileCloudSource,
        on date: Date,
        notebookID: String?,
        addToNotebook: Bool
    ) async -> Bool {
        let existing = scheduledPlacement(for: source.id)
        let order = nextScheduleOrder(on: date, excluding: source.id)
        let scheduled: Bool = await performLibraryMutation {
            if addToNotebook, let notebookID {
                try await MobileCloudMutationService.shared.addSources([source], toNotebookID: notebookID)
            }
            try await MobileCloudMutationService.shared.schedule(
                source: source,
                on: date,
                notebookID: notebookID,
                existing: existing,
                order: order
            )
            return true
        } ?? false
        if scheduled, addToNotebook, let notebookID {
            await tickNotebookArrivals([source.id], notebookID: notebookID)
        }
        return scheduled
    }

    func removeScheduleItems(ids: Set<String>, notebookID: String?) async -> Bool {
        let placements = ids.compactMap { scheduledPlacement(id: $0) }
        guard !placements.isEmpty else { return false }
        return await performLibraryMutation {
            for placement in placements {
                try await MobileCloudMutationService.shared.removePlacement(
                    placement,
                    fromNotebookID: notebookID
                )
            }
            return true
        } ?? false
    }

    /// The one hand-driven completion the phone has: today's plan card. Nothing
    /// the app merely observes ever completes a placement — opening or playing a
    /// source records activity, and a graded review completes through the review
    /// flow itself.
    func markScheduleSourceDone(sourceID: String) async -> Bool {
        guard scheduledPlacement(for: sourceID) != nil else { return false }
        return await performLibraryMutation {
            try await MobileCloudMutationService.shared.completeScheduledSource(sourceID: sourceID)
            return true
        } ?? false
    }

    func reopenScheduleItem(id: String) async -> Bool {
        guard let placement = scheduledPlacement(id: id) else { return false }
        return await performLibraryMutation {
            try await MobileCloudMutationService.shared.reopen(placement)
            return true
        } ?? false
    }

    func captureSource(url: URL, title: String?, sourceType: String) async -> String? {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.captureSource(
                url: url,
                title: title,
                sourceType: sourceType
            )
        }
    }

    /// `target` files it into a notebook in the same step (D47).
    func captureFile(url: URL, title: String?, capture: String = "pdf", target: MobileCaptureTarget? = nil) async -> String? {
        await performLibraryMutation {
            try await MobileCloudMutationService.shared.captureFile(url: url, title: title, capture: capture, target: target)
        }
    }

    /// Links pasted together into a notebook's Add sources, each captured as
    /// `captureSource` captures one, in one library change: the library
    /// loads once after them all, not once a link. Each link answers, in
    /// order, with its source's id or why it could not be added, and a link
    /// that fails does not hold up the ones after it; `onEach` hears each
    /// answer as it comes. Nil when another library change is still saving.
    func captureSources(
        urls: [URL],
        sourceType: String,
        filingInto notebookID: String? = nil,
        onEach: (Int, Result<String, Error>) -> Void
    ) async -> [Result<String, Error>]? {
        await performLibraryMutation {
            var outcomes: [Result<String, Error>] = []
            for (index, url) in urls.enumerated() {
                let outcome: Result<String, Error>
                do {
                    outcome = .success(try await MobileCloudMutationService.shared.captureSource(
                        url: url,
                        title: nil,
                        sourceType: sourceType,
                        target: notebookID.map { MobileCaptureTarget(notebookID: $0) }
                    ))
                } catch {
                    outcome = .failure(error)
                }
                outcomes.append(outcome)
                onEach(index, outcome)
            }
            return outcomes
        }
    }

    /// Captures what the share sheet queued, each item filed into the notebook the sheet chose in the
    /// capture itself (D47): the Job's target before the first complete Catalog pass, the Entry after it.
    /// An item whose notebook is gone by then stays in the library, where its capture put it. Nothing is
    /// drained while another library change holds the library.
    func importPendingSharedSources() async {
        guard !isMutatingLibrary else { return }
        isMutatingLibrary = true
        defer { isMutatingLibrary = false }
        do {
            let pending = try await MobileShareInbox.shared.pending()
            guard !pending.isEmpty else { return }
            var refusedItem: String?
            var queuedItem: String?
            for item in pending {
                let target = item.notebookID.map { MobileCaptureTarget(notebookID: $0, origin: "share") }
                do {
                    if let value = item.url, let url = URL(string: value) {
                        _ = try await MobileCloudMutationService.shared.captureSource(
                            url: url,
                            title: item.title,
                            sourceType: item.sourceType,
                            target: target
                        )
                    } else if let path = item.filePath {
                        _ = try await MobileCloudMutationService.shared.captureFile(
                            url: URL(fileURLWithPath: path),
                            title: item.title,
                            capture: "share",
                            target: target
                        )
                    } else {
                        throw MobileShareInboxError.sqlite("A queued item has no URL or file.")
                    }
                } catch let error where MobileShareDrain.answer(to: error) != nil {
                    // A linked page, an address that is not the web's, or a file that is not a PDF can never
                    // become a source, and a link only a Mac can mint an id for is already a Job for it:
                    // retrying either on every drain would hold up the items behind it. Drop it and say why.
                    try await MobileShareInbox.shared.remove(item)
                    switch MobileShareDrain.answer(to: error) {
                    case .refused(let message)?: refusedItem = message
                    case .queuedForMac(let message)?: queuedItem = message
                    case nil: break
                    }
                    continue
                }
                try await MobileShareInbox.shared.remove(item)
            }
            await load()
            if let refusedItem { errorMessage = refusedItem } else if let queuedItem { errorMessage = queuedItem }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSource(_ source: MobileCloudSource) async -> Bool {
        let notebookSnapshot = notebooks
        let scheduleSnapshot = scheduledSources
        let highlightSnapshot = await sourceCatalog.currentSourceHighlights(sourceID: source.id)
        let deleted = await performLibraryMutation {
            try await MobileCloudMutationService.shared.deleteSource(
                source,
                notebooks: notebookSnapshot,
                scheduledSources: scheduleSnapshot,
                highlights: highlightSnapshot
            )
            return true
        } ?? false
        if deleted {
            // A download outlives the source it came from unless it is released
            // here: nothing else ever revisits it, so it would sit in Offline
            // storage under a title the catalog can no longer resolve.
            await MobileOfflineLibrary.shared.remove(sourceID: source.id)
        }
        return deleted
    }

    func archiveSource(_ source: MobileCloudSource) async -> Bool {
        let notebookSnapshot = notebooks
        let scheduleSnapshot = scheduledSources
        let saved = await performLibraryMutation {
            try await MobileCloudMutationService.shared.archiveSource(
                source,
                notebooks: notebookSnapshot,
                scheduledSources: scheduleSnapshot
            )
            return true
        } ?? false
        if saved {
            // DismissedSource is intentionally not part of the phone's catalog;
            // remove the row now while the Mac archives and republishes Source.
            allSources.removeAll { $0.id == source.id }
            // Archiving discards the source's content on the Mac, so a saved copy
            // here can never be refreshed or reopened from the library again.
            await MobileOfflineLibrary.shared.remove(sourceID: source.id)
        }
        return saved
    }

    private func nextScheduleOrder(on date: Date, excluding sourceID: String?) -> Int {
        let calendar = Calendar.current
        return scheduledSources.reduce(into: 0) { count, placement in
            guard placement.sourceID != sourceID,
                  calendar.isDate(placement.plannedAt, inSameDayAs: date) else { return }
            count += 1
        }
    }

    private func performLibraryMutation<T>(_ operation: () async throws -> T) async -> T? {
        guard !isMutatingLibrary else {
            errorMessage = "Another library change is still saving."
            return nil
        }
        isMutatingLibrary = true
        defer { isMutatingLibrary = false }
        do {
            let result = try await operation()
            await load()
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Publishes managed sign-in state read off the main actor. `ManagedAI.isSignedIn`
    /// resolves to synchronous `SecItemCopyMatching` calls, so it can never be read
    /// from `init`, a view body, or any other main-actor path. Same shape as
    /// `MobileChatViewModel.refreshSignInState()`.
    private func refreshManagedSignInState() async {
        let signedIn = await Task.detached(priority: .userInitiated) { ManagedAI.isSignedIn }.value
        guard signedIn != hasOpenAIKey || signedIn != hasAnthropicKey else { return }
        hasOpenAIKey = signedIn
        hasAnthropicKey = signedIn
    }

    func saveOpenAIKey() async {
        apiKeyText = ""
        await refreshManagedSignInState()
    }

    func saveAnthropicKey() async {
        anthropicKeyText = ""
        await refreshManagedSignInState()
    }

    func beginSiriVoiceSessionIfNeeded() async {
        guard !isSiriVoiceSessionActive else { return }
        isSiriVoiceSessionActive = true
        await voice.start()
    }

    func endSiriVoiceSession() async {
        guard isSiriVoiceSessionActive else { return }
        isSiriVoiceSessionActive = false
        await voice.stop()
    }

    private var acceptsInAppVoiceInput: Bool {
        isSiriVoiceSessionActive || isReviewActive || isSourceChatActive
    }

    func handlePendingSiriCommandIfNeeded() async {
        guard let command = MobileSiriCommandCenter.shared.takePendingCommand() else {
            return
        }

        await handleSiriCommand(command)
    }

    private func handleSiriAskQuery(_ query: String) async {
        let utterance = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }
        lastVoiceCommand = utterance

        guard hasOpenAIKey else {
            speakWithoutListening(
                "Add an OpenAI key in the app to use Ask ForeverLM."
            )
            return
        }

        do {
            let decision = try await voiceAgent.decide(
                utterance: utterance,
                state: voiceAgentState()
            )
            await executeVoiceAgentDecision(decision, originalUtterance: utterance)
        } catch {
            speakWithoutListening(error.localizedDescription)
        }
    }

    private func handleVoiceTranscript(_ transcript: String) async {
        let utterance = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty, !isChatResponding, acceptsInAppVoiceInput else { return }
        lastVoiceCommand = utterance

        if isReviewActive {
            await routeReviewUtterance(utterance)
            return
        }

        if isSourceChatActive {
            await sendSourceChatMessage(utterance)
            voice.resetAfterHandledCommand()
            return
        }

        guard hasOpenAIKey else {
            speakAndResumeListening(
                "Add an OpenAI key in the app to ask follow-up questions.",
                pausePlayback: true,
                resumePlaybackAfterSpeech: true
            )
            await endSiriVoiceSession()
            voice.resetAfterHandledCommand()
            return
        }

        do {
            let decision = try await voiceAgent.decide(
                utterance: utterance,
                state: voiceAgentState()
            )
            await executeVoiceAgentDecision(decision, originalUtterance: utterance)
        } catch {
            speakAndResumeListening(error.localizedDescription, pausePlayback: true, resumePlaybackAfterSpeech: true)
        }
        voice.resetAfterHandledCommand()
    }

    private func handleSiriCommand(_ command: MobileSiriCommand) async {
        if allSources.isEmpty && items.isEmpty {
            await load()
        }

        switch command.action {
        case .openToday:
            // Today's plan is a card on Home; the shell goes back to it.
            pendingDeepLink = .today
        case .ask:
            guard let query = command.query else { return }
            await handleSiriAskQuery(query)
        case .askAboutSource:
            if let question = command.query?.trimmingCharacters(in: .whitespacesAndNewlines),
               !question.isEmpty {
                await startSourceChat(sourceID: command.sourceID, announce: false)
                guard isSourceChatActive else { return }
                await sendSourceChatMessage(question)
            } else {
                await startSourceChat(sourceID: command.sourceID, announce: true)
            }
        case .listSources:
            let utterance = command.query.map { "what sources do we have for \($0)" } ?? "list sources"
            speakAndResumeListening(
                naturalListPrompt(for: utterance),
                pausePlayback: true,
                resumePlaybackAfterSpeech: true
            )
        case .playSource:
            if let sourceID = command.sourceID {
                await playVoiceAgentSource(sourceID, utterance: command.query ?? "")
            } else if let query = command.query {
                await playVoiceAgentSource(nil, utterance: "read me \(query) out loud")
            }
        case .playLatestSource:
            await playLatestSource()
        case .playLatestPaper:
            await playLatestSource(sourceType: "paper")
        case .quiz:
            await startReviewQuiz(sourceID: command.sourceID, utterance: command.query ?? "")
        case .memoryReview:
            // Today's card review over every notebook; the shell opens it.
            pendingDeepLink = .review
        case .pausePlayback:
            if speech.isSpeaking {
                speech.stop(owner: .voiceTab)
            } else if isPlaying {
                togglePlayback()
            }
        case .resumePlayback:
            if currentItem == nil, let latest = allSources.first {
                await playVoiceAgentSource(latest.id, utterance: "resume playback")
            } else if !isPlaying {
                togglePlayback()
            }
        case .stopPlayback:
            if speech.isSpeaking {
                speech.stop(owner: .voiceTab)
            }
            if isPlaying {
                togglePlayback()
            }
            await endSiriVoiceSession()
        case .stopReview:
            if isReviewActive {
                await cancelReview(speaking: "Review stopped.")
            } else if isSourceChatActive {
                await endSourceChat(resumeAudio: false)
                speakAndResumeListening("Source chat ended.")
            }
            await endSiriVoiceSession()
        }
    }

    private func executeVoiceAgentDecision(
        _ decision: MobileVoiceAgentDecision,
        originalUtterance: String
    ) async {
        switch decision.tool {
        case "play_source":
            await playVoiceAgentSource(decision.sourceID, utterance: originalUtterance)
        case "pause_audio":
            if speech.isSpeaking {
                speech.stop(owner: .voiceTab)
            } else if isPlaying {
                togglePlayback()
            }
            speakIfNeeded(decision.spokenResponse)
        case "resume_audio":
            if currentItem == nil {
                await playVoiceAgentSource(decision.sourceID, utterance: originalUtterance)
            } else if !isPlaying {
                togglePlayback()
            }
            speakIfNeeded(decision.spokenResponse)
        case "stop_audio":
            if speech.isSpeaking {
                speech.stop(owner: .voiceTab)
            } else if isPlaying {
                togglePlayback()
            }
            speakIfNeeded(decision.spokenResponse)
        case "pause_for_source_chat":
            await pauseForSourceChat(
                sourceID: resolveSourceID(decision.sourceID, from: originalUtterance),
                spokenResponse: decision.spokenResponse
            )
        case "skip_relative":
            skip(seconds: decision.seconds ?? 0)
            speakIfNeeded(decision.spokenResponse)
        case "set_speed":
            if let speed = decision.speed {
                setSpeed(speed)
            }
            speakIfNeeded(decision.spokenResponse)
        case "list_sources":
            let response = decision.spokenResponse
                ?? naturalListPrompt(for: originalUtterance)
            speakAndResumeListening(response, pausePlayback: true, resumePlaybackAfterSpeech: true)
        case "refresh_library":
            await load()
            speakAndResumeListening(decision.spokenResponse ?? librarySummary())
        case "identify_current_source":
            speakAndResumeListening(decision.spokenResponse ?? currentSourceDescription(), pausePlayback: true, resumePlaybackAfterSpeech: true)
        case "start_source_review":
            await startSourceChat(
                sourceID: resolveSourceID(decision.sourceID, from: originalUtterance),
                announce: true
            )
        case "start_review_quiz":
            await startReviewQuiz(
                sourceID: decision.sourceID,
                utterance: decision.message ?? originalUtterance
            )
        case "answer_source_question":
            if !isSourceChatActive {
                await startSourceChat(
                    sourceID: resolveSourceID(decision.sourceID, from: originalUtterance),
                    announce: false
                )
            }
            guard isSourceChatActive else { return }
            await sendSourceChatMessage(decision.message ?? originalUtterance)
        case "end_source_review":
            await endSourceChat(resumeAudio: decision.resumeAudio == true)
        case "no_op":
            if let response = decision.spokenResponse, !response.isEmpty {
                speakAndResumeListening(response)
            }
        default:
            speakAndResumeListening("I could not decide what to do with that.")
        }
    }

    private func voiceAgentState() -> MobileVoiceAgentState {
        MobileVoiceAgentState(
            isPlaying: isPlaying,
            isSourceReviewActive: isSourceChatActive,
            currentSourceID: currentItem?.id ?? activeVoiceSourceID,
            currentSourceTitle: currentItem?.title ?? activeVoiceSourceTitle,
            activeReviewTitle: activeChatTitle,
            playbackSpeed: speed,
            availableSources: allSources.enumerated().map { index, source in
                MobileVoiceAgentSource(
                    id: source.id,
                    position: index + 1,
                    title: source.title,
                    subtitle: [
                        source.sourceType,
                        source.hasAudio ? "Ready to play" : "Text voice available"
                    ]
                        .joined(separator: " • ")
                )
            }
        )
    }

    private func speakIfNeeded(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        speakAndResumeListening(text, pausePlayback: true, resumePlaybackAfterSpeech: true)
    }

    private func resolveSourceID(_ sourceID: String?, from utterance: String) -> String? {
        if let sourceID, allSources.contains(where: { $0.id == sourceID }) {
            return sourceID
        }

        return currentItem?.id ?? activeVoiceSourceID
    }

    private func playVoiceAgentSource(_ sourceID: String?, utterance: String) async {
        let resolvedSourceID = resolveSourceID(sourceID, from: utterance)
        guard let playableSourceID = resolvedSourceID else {
            speakAndResumeListening("I do not have any synced sources to play yet.")
            return
        }

        if let item = itemForSourceID(playableSourceID) {
            await playWithSpokenLeadIn(item)
            return
        }

        guard let source = source(for: playableSourceID) else {
            speakAndResumeListening("I could not find that source.")
            return
        }

        await readCloudSourceAloud(source)
    }

    /// Whether ready-to-play narration audio for this source is already on the
    /// phone (synced from the Mac or generated here earlier), i.e. text-to-speech
    /// can start without a TTS round trip.
    func hasSyncedTextToSpeechAudio(sourceID: String) -> Bool {
        items.contains { $0.id == sourceID }
    }

    /// The narration whose audio is being pulled down from iCloud right now,
    /// and how far along it is. Generation ("preparing") and download are
    /// different waits with different remedies, so the UI names them apart.
    func narrationDownloadFraction(sourceID: String) -> Double? {
        narrationDownloadProgress(sourceID: sourceID)?.fractionCompleted
    }

    func narrationDownloadProgress(sourceID: String) -> MobileNarrationDownloadProgress? {
        narrationDownloadSourceID == sourceID ? narrationDownloadProgress : nil
    }

    /// The title a banner shows for a download that has not produced a
    /// player item yet.
    var narrationDownloadTitle: String? {
        narrationDownloadProgress?.title
    }

    /// Audio the Mac has published but this phone has not pulled down yet is
    /// still audio: the library says so, and pressing play fetches it. Only the
    /// bytes are absent, and only until someone wants them — and playing
    /// starts before the download is over.
    ///
    /// A chapter is tens of megabytes and CloudDocs on a phone is bursty, so
    /// waiting for the last chunk before the first one played was a minute of
    /// spinner for audio the account already owned. Instead the download
    /// reports the contiguous prefix it has, and as soon as that prefix is
    /// playable — and reaches past the saved resume point — the opening starts
    /// through the same machinery fresh generation uses. Each further chunk
    /// extends it; `play` hands over to the whole composition at the end.
    private func materializeNarrationIfNeeded(
        _ item: MobileAudioItem,
        startAt: TimeInterval?
    ) async throws {
        let manifest = item.manifest
        let alreadyLocal = await Task.detached(priority: .userInitiated) {
            SyncedArticleAudioStore.hasLocalChunks(for: manifest)
        }.value
        if alreadyLocal { return }

        let startedAt = Date()
        narrationDownloadSourceID = item.id
        narrationDownloadProgress = MobileNarrationDownloadProgress(
            title: item.title,
            readyChunks: 0,
            contiguousChunks: 0,
            totalChunks: manifest.chunks.count,
            startedAt: startedAt,
            isPlayingPrefix: false
        )
        isStartingDownloadedOpening = false
        defer {
            narrationDownloadSourceID = nil
            narrationDownloadProgress = nil
            isStartingDownloadedOpening = false
        }

        // Where the listener left off, resolved once: the opening may only
        // start when the downloaded prefix reaches past it, or it would start
        // the chapter from the top and jump later.
        let resumeTarget: TimeInterval
        if let startAt {
            resumeTarget = max(startAt, 0)
        } else {
            let saved = await Task.detached(priority: .userInitiated) {
                await SyncedArticleAudioStore.loadPlaybackPositionIncludingAccount(sourceID: manifest.sourceID)
            }.value
            resumeTarget = Self.resumeTime(from: saved, manifest: manifest, duration: .infinity)
        }

        // The weak capture belongs on the outer closure: `materializeChunks`
        // holds this progress handler for the whole iCloud download, so a strong
        // reference here would have outlived the screen no matter what the inner
        // task captured.
        try await SyncedArticleAudioStore.materializeChunks(for: manifest) { [weak self] progress in
            Task { @MainActor in
                guard let self, self.narrationDownloadSourceID == item.id else { return }
                await self.downloadedPrefixDidGrow(
                    progress,
                    for: item,
                    resumeTarget: resumeTarget,
                    startedAt: startedAt
                )
            }
        }
    }

    /// One CloudDocs update during a narration download: republish the count,
    /// and start or extend playback on the contiguous prefix.
    private func downloadedPrefixDidGrow(
        _ progress: SyncedArticleAudioDownloadProgress,
        for item: MobileAudioItem,
        resumeTarget: TimeInterval,
        startedAt: Date
    ) async {
        func publish() {
            guard narrationDownloadSourceID == item.id else { return }
            narrationDownloadProgress = MobileNarrationDownloadProgress(
                title: item.title,
                readyChunks: progress.readyChunks,
                contiguousChunks: progress.contiguousChunks,
                totalChunks: progress.totalChunks,
                startedAt: startedAt,
                isPlayingPrefix: openingPlaybackSourceID == item.id
            )
        }
        publish()

        // The last chunk is `play`'s to handle: it builds the whole
        // composition and hands over at the current second.
        guard progress.contiguousChunks > 0,
              !progress.isComplete,
              !MobileVoiceConversationController.shared.isActive else { return }

        let prefixItem = MobileAudioItem(manifest: item.manifest.prefix(chunkCount: progress.contiguousChunks))
        if openingPlaybackSourceID == item.id {
            _ = await extendOpeningPlayback(prefixItem)
            publish()
            return
        }
        guard !isStartingDownloadedOpening else { return }
        isStartingDownloadedOpening = true
        defer { isStartingDownloadedOpening = false }

        // The prefix has to reach past the resume point with some runway, or
        // the opening would begin at the wrong place and run dry at once.
        if resumeTarget > 0 {
            let prefixDuration = await prefixDurationIfPlayable(prefixItem)
            guard let prefixDuration, prefixDuration > resumeTarget + 5 else { return }
        }

        // Listen on this chapter is an explicit switch: whatever was playing
        // yields the moment this one can make sound, exactly as it would have
        // when the download finished.
        if currentItem?.id != item.id, isPlaying {
            player.pause()
            isPlaying = false
            persistPlaybackPosition(force: true)
        }
        let didStart = await startOpeningPlayback(prefixItem, startAt: resumeTarget)
        if didStart { publish() }
    }

    private func prefixDurationIfPlayable(_ item: MobileAudioItem) async -> TimeInterval? {
        do {
            let urls = try await Task.detached(priority: .userInitiated) {
                try SyncedArticleAudioStore.chunkURLs(for: item.manifest)
            }.value
            return try await audioComposition(for: urls).duration
        } catch {
            return nil
        }
    }

    func isPreparingAudio(sourceID: String) -> Bool {
        textToSpeechPreparingSourceID == sourceID
            || backgroundTextToSpeechPreparingTitles[sourceID] != nil
    }

    func textToSpeechGenerationProgress(sourceID: String) -> MobileTextToSpeechGenerationProgress? {
        if textToSpeechPreparingSourceID == sourceID {
            return textToSpeechGenerationProgress
        }
        return backgroundTextToSpeechGenerationProgress[sourceID]
    }

    /// Reads one source aloud end to end — already-synced audio when it exists,
    /// freshly generated cloud narration otherwise.
    func readSourceAloud(sourceID: String) async {
        if allSources.isEmpty && items.isEmpty {
            await load()
        }
        // Already on its way down, and playing as soon as it can.
        if narrationDownloadSourceID == sourceID { return }
        if let item = itemForSourceID(sourceID) {
            // A conversation started in the meantime outranks this playback:
            // acquiring the audio session here would tear that session down.
            guard !MobileVoiceConversationController.shared.isActive else { return }
            await play(item)
            return
        }
        if backgroundTextToSpeechPreparingTitles[sourceID] != nil {
            // A prepare-only job can be promoted to playback without starting
            // duplicate network work. Its completion performs the cached play.
            pendingTextToSpeechAfterPreparationSourceID = sourceID
            return
        }
        if let preparingSourceID = textToSpeechPreparingSourceID {
            // The direct autoplay path already fulfills a repeated request for
            // this source. Background-only generation does not, so remember the
            // request and start playback as soon as that task publishes audio.
            if preparingSourceID != sourceID || textToSpeechAutoplaySourceID != sourceID {
                pendingTextToSpeechAfterPreparationSourceID = sourceID
            }
            return
        }
        guard let source = source(for: sourceID) else {
            let message = "I could not find that source on this phone anymore."
            errorMessage = message
            speakWithoutListening(message)
            return
        }
        await readCloudSourceAloud(source)
    }

    /// Generates and syncs narration without taking over the audio session,
    /// so the chunks become available to the iPhone, Mac, and CarPlay while
    /// the learner carries on.
    func prepareSourceAudio(
        sourceID: String,
        playsOpeningWhenReady: Bool = false
    ) async throws -> MobileAudioItem {
        if allSources.isEmpty && items.isEmpty {
            await load()
        }
        if let item = itemForSourceID(sourceID) {
            return item
        }
        guard !isPreparingAudio(sourceID: sourceID) else {
            let title = textToSpeechPreparingSourceID == sourceID
                ? textToSpeechPreparingTitle
                : backgroundTextToSpeechPreparingTitles[sourceID]
            throw MobileTextToSpeechPreparationError.alreadyPreparing(title)
        }
        guard let source = source(for: sourceID) else {
            throw MobileTextToSpeechPreparationError.sourceNotFound
        }
        return try await generateBackgroundTextToSpeechAudio(
            for: source,
            playsOpeningWhenReady: playsOpeningWhenReady
        )
    }

    /// Starts an event-driven pass over ready sources. The task is generate-only:
    /// it never claims the player, marks a source listened, or keeps a poller alive.
    ///
    /// `retryFailures` is the deliberate gesture — switching a type on — that
    /// clears sources this launch already failed on, so a fixed sync is picked
    /// up without relaunching the app.
    func scheduleAutomaticAudioGeneration(retryFailures: Bool = false) {
        if retryFailures {
            failedAutomaticSourceAudioIDs.removeAll()
        }
        guard automaticSourceAudioTask == nil else {
            automaticSourceAudioPassRequested = true
            return
        }
        automaticSourceAudioTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.automaticSourceAudioPassRequested = false
                await self.generateAutomaticSourceAudio()
            } while self.automaticSourceAudioPassRequested && !Task.isCancelled
            self.automaticSourceAudioTask = nil
        }
    }

    /// Evaluates one draft rule against the exact pending iPhone catalog. The
    /// same candidate contract and task route are used by the execution pass,
    /// so Check is a genuine dry run rather than an approximate UI search.
    /// The candidate contract both the rule preview and the execution pass hand
    /// to the filter. One function, so Check stays a genuine dry run: the
    /// execution pass had been omitting the word-count fallback, which asked
    /// the model to judge "keep it short" against a length only the preview
    /// could see.
    private func automaticAudioFilterCandidate(
        for source: MobileCloudSource
    ) -> SourceAudioAutomation.FilterCandidate {
        SourceAudioAutomation.FilterCandidate(
            id: source.id,
            // The automation kind, as the Mac sends it: an explainer is judged
            // under the Explainers rule, never the Articles one.
            sourceType: source.audioAutomationKind,
            title: source.title,
            author: source.author,
            journal: source.journal,
            year: source.publishedYear,
            collection: source.parentGroup,
            url: source.url,
            description: source.sourceReviewGuide.map { String($0.guide.prefix(800)) },
            characterCount: source.listenableCharacterCount
                ?? SourceAudioAutomation.estimatedCharacters(
                    wordCount: source.wordCount,
                    contentCharacterCount: nil
                )
        )
    }

    func previewAutomaticAudioConstraint(
        sourceType: String,
        constraint: String
    ) async throws -> SourceAudioAutomation.FilterPreview {
        let candidates = allSources
            .filter {
                $0.audioAutomationKind == sourceType
                    && !$0.hasAudio
                    && !$0.isArchived
                    && $0.state == "ready"
            }
            .map { automaticAudioFilterCandidate(for: $0) }
        let trimmed = constraint.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingIDs: Set<String>
        if trimmed.isEmpty {
            matchingIDs = Set(candidates.map(\.id))
        } else {
            let route = try await MobileModelPreferenceStore.shared.resolve(.automaticAudioFiltering)
            matchingIDs = try await MobileAutomaticAudioConstraintMatcher.matchingIDs(
                constraint: trimmed,
                candidates: candidates,
                route: route
            )
        }
        return SourceAudioAutomation.FilterPreview(
            constraint: trimmed,
            matches: candidates
                .filter { matchingIDs.contains($0.id) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        )
    }

    private func generateAutomaticSourceAudio() async {
        // Read the synced consent before the gate. It starts false each launch,
        // and a stale false here would retire the learner's opt-ins rather than
        // honor a grant they already made.
        await refreshPaidAutomaticVoiceConsent()
        guard !paidAutomaticVoiceConsentIsUnverified else {
            // iCloud did not answer. Nothing generates without a verified
            // consent, and nothing is switched off on a guess; the next pass
            // reads it again.
            automaticAudioProgress = nil
            return
        }
        // The gate below prices the selected model from OpenRouter's speech
        // list, so read the list first: a model picked from it is not among
        // the ones this build records, and would read as unpriced.
        await OpenRouterAudioDirectory.prepare(.speech)
        // A pick the list dropped is repaired before it is priced; the
        // generation that uses it says so.
        ArticleSpeechSelection.repairAfterDirectoryRead()
        ArticleSpeechPreferences.shared.reloadFromStorage()
        let storedModel = UserDefaults.standard.string(forKey: ArticleSpeechSelection.modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard ArticleSpeechCatalog.isDirectoryBacked
                || storedModel.isEmpty
                || ArticleSpeechCatalog.model(id: storedModel) != nil else {
            // The list could not be read and the pick is not in the recorded
            // one. Nothing is priced on a guess and nothing is switched off;
            // the next pass reads the list again.
            automaticAudioProgress = nil
            return
        }
        guard automaticAudioSelectionIsAllowed else {
            automaticAudioProgress = nil
            await disableAutomaticAudioPreferences()
            return
        }
        // One switch per source type, read from the synced preferences rather
        // than from a list held here, so a type added to
        // `SourceAudioAutomation` is picked up without a second place to edit.
        var enabledTypes: Set<String> = []
        do {
            for type in SourceAudioAutomation.automatable {
                let isEnabled = try await MobileModelPreferenceStore.shared
                    .bool(forKey: type.preferenceKey) ?? false
                if isEnabled { enabledTypes.insert(type.sourceType) }
            }
        } catch {
            // A background pass has no one to tell about a transient outage;
            // it re-runs on the next event. Anything else is still surfaced.
            if case .iCloudUnavailable? = error as? MobileModelRouteError {
                automaticAudioProgress = nil
                return
            }
            errorMessage = "Automatic audio settings could not be loaded: \(error.localizedDescription)"
            return
        }
        guard !enabledTypes.isEmpty else {
            automaticAudioProgress = nil
            return
        }

        var candidates = allSources.filter { source in
            guard !source.hasAudio, !source.isArchived, source.state == "ready" else { return false }
            guard !failedAutomaticSourceAudioIDs.contains(source.id) else { return false }
            guard !isPreparingAudio(sourceID: source.id) else { return false }
            // By automation kind, so an explainer follows the Explainers
            // switch and never the Articles one.
            return enabledTypes.contains(source.audioAutomationKind)
        }
        do {
            var constraints: [String: String] = [:]
            for sourceType in enabledTypes {
                guard let key = SourceAudioAutomation.constraintPreferenceKey(for: sourceType),
                      let constraint = try await MobileModelPreferenceStore.shared.string(forKey: key)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !constraint.isEmpty else { continue }
                constraints[sourceType] = constraint
            }
            guard !constraints.isEmpty else { throw AutomaticAudioConstraintControl.noConstraints }
            let route = try await MobileModelPreferenceStore.shared.resolve(.automaticAudioFiltering)
            var allowedIDs = Set(candidates.map(\.id))
            for (sourceType, constraint) in constraints.sorted(by: { $0.key < $1.key }) {
                let typed = candidates.filter { $0.audioAutomationKind == sourceType }
                let filterCandidates = typed.map { automaticAudioFilterCandidate(for: $0) }
                let matches = try await MobileAutomaticAudioConstraintMatcher.matchingIDs(
                    constraint: constraint,
                    candidates: filterCandidates,
                    route: route
                )
                allowedIDs.subtract(typed.map(\.id))
                allowedIDs.formUnion(matches)
            }
            candidates = candidates.filter { allowedIDs.contains($0.id) }
        } catch AutomaticAudioConstraintControl.noConstraints {
            // No semantic filter means the per-type opt-in retains its existing
            // all-sources behavior without making an AI call.
        } catch {
            errorMessage = "Automatic audio filter failed: \(error.localizedDescription)"
            automaticAudioProgress = nil
            return
        }
        guard !candidates.isEmpty else {
            automaticAudioProgress = nil
            return
        }
        var completedCount = 0
        defer { automaticAudioProgress = nil }
        for source in candidates {
            guard !Task.isCancelled else { return }
            // A model selection or the consent can change while a long source
            // is generating. Re-read both before each item so the next source
            // never inherits a route the learner has since withdrawn.
            await refreshPaidAutomaticVoiceConsent()
            guard !paidAutomaticVoiceConsentIsUnverified else { return }
            guard automaticAudioSelectionIsAllowed else {
                await disableAutomaticAudioPreferences()
                return
            }
            automaticAudioProgress = SourceAudioAutomation.GenerationProgress(
                completedCount: completedCount,
                totalCount: candidates.count,
                currentSourceType: source.audioAutomationKind,
                currentTitle: source.title
            )
            do {
                _ = try await prepareSourceAudio(sourceID: source.id)
                completedCount += 1
            } catch {
                failedAutomaticSourceAudioIDs.insert(source.id)
                errorMessage = "Automatic audio for \(source.title) failed: \(error.localizedDescription)"
            }
        }
    }

    /// Whether the current selection may generate: free always, priced only
    /// behind the synced account consent, unpriced never. Re-read between every
    /// source, so a revoked consent or a changed model stops the next item.
    private var automaticAudioSelectionIsAllowed: Bool {
        SourceAudioAutomation.allowsAutomaticGeneration(
            provider: ArticleSpeechCatalog.provider,
            model: ArticleSpeechPreferences.shared.modelID,
            allowsPaidVoices: allowsPaidAutomaticVoices
        )
    }

    /// Mirror of the synced consent, refreshed by the settings screen and
    /// before each pass so the executor never trails a revocation.
    private(set) var allowsPaidAutomaticVoices = false

    /// False when the last consent read did not reach iCloud. The mirror then
    /// holds no answer, and a pass may neither generate nor retire anything.
    /// A transient outage used to read as "consent withdrawn": the pass tried
    /// to switch every opt-in off, that write failed on the same outage, and
    /// the failure was announced as a toast over the source list.
    private(set) var paidAutomaticVoiceConsentIsKnown = false

    func refreshPaidAutomaticVoiceConsent() async {
        do {
            allowsPaidAutomaticVoices = try await MobileModelPreferenceStore.shared
                .bool(forKey: SourceAudioAutomation.paidVoiceConsentPreferenceKey) ?? false
            paidAutomaticVoiceConsentIsKnown = true
        } catch {
            allowsPaidAutomaticVoices = false
            paidAutomaticVoiceConsentIsKnown = false
        }
    }

    /// True when the pass must stop without deciding anything: the selection
    /// is priced, so it runs only behind consent, and iCloud did not say
    /// whether that consent stands. An unpriced voice needs no consent and
    /// is not held up by the outage.
    private var paidAutomaticVoiceConsentIsUnverified: Bool {
        !paidAutomaticVoiceConsentIsKnown
            && SourceAudioAutomation.requiresPaidVoiceConsent(
                provider: ArticleSpeechCatalog.provider,
                model: ArticleSpeechPreferences.shared.modelID
            )
    }

    /// The store's read-side wording ("No request was sent") does not fit a
    /// failed write. Say what the failure means here: the switches stay on in
    /// iCloud while this phone refuses to generate.
    static func automaticAudioDisableFailureMessage(_ error: Error) -> String {
        if case .iCloudUnavailable? = error as? MobileModelRouteError {
            return "Automatic audio is paused but its switches could not be turned off because iCloud could not be reached. Nothing will generate in the meantime; they will be turned off once iCloud is back."
        }
        return "Automatic audio could not be turned off: \(error.localizedDescription)"
    }

    /// User-facing abort for the batch in flight. Leaves the per-type opt-ins
    /// and the consent alone — the message shown afterwards says so.
    func stopCurrentAutomaticAudioRun() -> Int {
        let generated = automaticAudioProgress?.completedCount ?? 0
        automaticSourceAudioPassRequested = false
        automaticSourceAudioTask?.cancel()
        automaticSourceAudioTask = nil
        automaticAudioProgress = nil
        return generated
    }

    /// Prices the whole pending library per type, for the consent dialog. Uses
    /// the same eligibility the pass uses, so the quote matches what would run.
    func automaticAudioLibraryCostPreview(
        ratePerMillionCharacters rate: Double?
    ) -> SourceAudioAutomation.LibraryCostPreview {
        var backlogs: [String: SourceAudioAutomation.Backlog] = [:]
        for type in SourceAudioAutomation.automatableSourceTypes {
            let pending = allSources.filter {
                $0.sourceType == type && !$0.hasAudio && !$0.isArchived && $0.state == "ready"
            }
            guard !pending.isEmpty else { continue }
            let counts = pending.map { source in
                source.listenableCharacterCount
                    ?? SourceAudioAutomation.estimatedCharacters(
                        wordCount: source.wordCount,
                        contentCharacterCount: nil
                    )
            }
            backlogs[type] = SourceAudioAutomation.Backlog(
                sourceCount: pending.count,
                characterCount: counts.contains(where: { $0 == nil })
                    ? nil
                    : counts.compactMap { $0 }.reduce(0, +)
            )
        }
        return SourceAudioAutomation.LibraryCostPreview(
            backlogs: backlogs,
            ratePerMillionCharacters: rate
        )
    }

    private func disableAutomaticAudioPreferences() async {
        do {
            for type in SourceAudioAutomation.automatable {
                let isEnabled = try await MobileModelPreferenceStore.shared
                    .bool(forKey: type.preferenceKey) ?? false
                if isEnabled {
                    try await MobileModelPreferenceStore.shared.setBool(
                        false,
                        forKey: type.preferenceKey
                    )
                }
            }
        } catch {
            // Execution is already blocked locally. Surface a sync failure so
            // the stale preference is not mistaken for an armed paid queue.
            errorMessage = Self.automaticAudioDisableFailureMessage(error)
        }
    }

    private func playLatestSource(sourceType: String? = nil) async {
        let source = MobileLatestSourceSelector.latest(
            in: allSources,
            sourceType: sourceType
        )
        guard let source else {
            let missingKind = sourceType.map { " synced \($0)s" } ?? " synced sources"
            speakAndResumeListening("I do not have any\(missingKind) to play yet.")
            return
        }

        await playVoiceAgentSource(source.id, utterance: "read me the latest source from ForeverLM")
    }

    private func itemForSourceID(_ sourceID: String?) -> MobileAudioItem? {
        guard let sourceID else { return nil }
        return items.first { $0.id == sourceID }
    }

    private func source(for sourceID: String?) -> MobileCloudSource? {
        guard let sourceID else { return nil }
        return allSources.first { $0.id == sourceID }
    }

    private func handleCompletedBookChapter(sourceID: String) async {
        guard let nextChapter = nextBookChapter(after: sourceID) else { return }
        if MobileBookPlaybackPreferences.automaticallyContinues {
            await automaticallyContinueBook(from: sourceID, to: nextChapter.id)
        } else if !MobileBookPlaybackPreferences.hasAskedToAutomaticallyContinue {
            bookContinuationOffer = MobileBookContinuationOffer(
                completedSourceID: sourceID,
                nextSourceID: nextChapter.id,
                nextTitle: nextChapter.title
            )
        }
    }

    private func automaticallyContinueBook(
        from completedSourceID: String,
        to nextSourceID: String
    ) async {
        guard MobileBookPlaybackPreferences.automaticallyContinues,
              currentItem?.id == completedSourceID,
              !isPlaying,
              duration > 0,
              currentTime >= duration - 1 else { return }

        if !hasSyncedTextToSpeechAudio(sourceID: nextSourceID),
           !isPreparingAudio(sourceID: nextSourceID) {
            do {
                _ = try await prepareSourceAudio(sourceID: nextSourceID)
            } catch {
                errorMessage = "The next chapter could not be generated: \(error.localizedDescription)"
                return
            }
        } else if isPreparingAudio(sourceID: nextSourceID) {
            pendingAutomaticBookContinuation = (completedSourceID, nextSourceID)
            return
        }

        // Closing the player, replaying the completed chapter, or starting any
        // other source while generation ran cancels the delayed handoff. Turning
        // the setting off while generation runs leaves the audio prepared but
        // does not start it.
        guard MobileBookPlaybackPreferences.automaticallyContinues,
              currentItem?.id == completedSourceID,
              !isPlaying,
              duration > 0,
              currentTime >= duration - 1 else { return }
        await readSourceAloud(sourceID: nextSourceID)
    }

    /// What a session on the Notebook reads (`contextSourceIDs`: its own
    /// approved pool, or what a voice conversation was narrowed to) narrowed
    /// to what has actually synced to this phone, in pool order. Sources
    /// archived on the Mac (or not yet delivered) drop out here, so the count
    /// shown on a Notebook is what a session can really reach.
    func sources(in notebook: MobileCloudNotebook) -> [MobileCloudSource] {
        let byID = sourcesByID
        let ids = notebook.contextSourceIDs.isEmpty ? notebook.sourceIDs : notebook.contextSourceIDs
        return ids.compactMap { byID[$0] }
    }

    private func currentSourceDescription() -> String {
        if let title = currentItem?.title ?? activeVoiceSourceTitle {
            return "The current source is \(title)."
        }
        return "No source is active."
    }

    private func pauseForSourceChat(sourceID: String?, spokenResponse: String?) async {
        await startSourceChat(sourceID: sourceID, announce: false)
        guard isSourceChatActive else { return }

        let response = spokenResponse?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let response, !response.isEmpty {
            speakAndResumeListening(response, pausePlayback: false)
        } else if let activeChatTitle {
            speakAndResumeListening("Paused. Ask me anything about \(activeChatTitle).", pausePlayback: false)
        } else {
            speakAndResumeListening("Paused. Ask me anything about this source.", pausePlayback: false)
        }
    }

    private func startSourceChat(sourceID: String?, announce: Bool) async {
        await beginSiriVoiceSessionIfNeeded()
        guard let sourceContext = await sourceContext(for: sourceID) else {
            return
        }

        if isPlaying {
            player.pause()
            isPlaying = false
            persistPlaybackPosition(force: true)
            updateNowPlayingInfo()
        }
        activeVoiceSourceID = sourceContext.sourceID
        activeVoiceSourceTitle = sourceContext.title
        await sourceChat.start(
            sourceID: sourceContext.sourceID,
            sourceType: sourceContext.sourceType,
            sourceTitle: sourceContext.title,
            sourceText: sourceContext.text
        )
        isSourceChatActive = true
        activeChatTitle = sourceContext.title
        await recordSourceActivity(sourceID: sourceContext.sourceID, kind: .chat)
        if announce {
            speakAndResumeListening("Reviewing \(sourceContext.title). Ask me anything about it.", pausePlayback: false)
        }
    }

    private func sourceContext(
        for sourceID: String?
    ) async -> (sourceID: String, sourceType: String, title: String, text: String)? {
        let resolvedID = sourceID ?? currentItem?.id ?? activeVoiceSourceID ?? allSources.first?.id
        guard let resolvedID else {
            speakAndResumeListening("I could not find a source to review. Ask what sources are available or play a source first.")
            return nil
        }
        let title = source(for: resolvedID)?.title
            ?? itemForSourceID(resolvedID)?.title
            ?? activeVoiceSourceTitle
            ?? "Source"

        do {
            if let item = itemForSourceID(resolvedID),
               let text = try? SyncedArticleAudioStore.loadSourceText(for: item.manifest) {
                let sourceType = source(for: resolvedID)?.sourceType ?? "source"
                return (resolvedID, sourceType, item.title, text)
            }

            let text = try await sourceTextStore.loadSourceText(sourceID: resolvedID)
            let sourceType = source(for: resolvedID)?.sourceType ?? "source"
            return (resolvedID, sourceType, title, text)
        } catch {
            speakAndResumeListening(error.localizedDescription, pausePlayback: true, resumePlaybackAfterSpeech: true)
            return nil
        }
    }

    private func readCloudSourceAloud(_ source: MobileCloudSource) async {
        do {
            try await generateCloudTextToSpeechAudio(for: source, autoplay: true)
            pendingTextToSpeechResumes[source.id] = nil
            automaticTextToSpeechResumeCounts[source.id] = nil
        } catch {
            recordInterruptedTextToSpeechGeneration(
                sourceID: source.id,
                playsOpeningWhenReady: true,
                error: error
            )
            errorMessage = error.localizedDescription
            if MobileVoiceConversationController.shared.isActive {
                return
            } else {
                speakAndResumeListening(error.localizedDescription, pausePlayback: true, resumePlaybackAfterSpeech: true)
            }
        }
    }

    func resolveTextToSpeechCostConfirmation(approved: Bool) {
        guard let continuation = textToSpeechCostConfirmationContinuation else { return }
        textToSpeechCostConfirmationContinuation = nil
        textToSpeechCostConfirmation = nil
        continuation.resume(returning: approved)
    }

    /// The rest of the book behind a chapter about to be generated. Playback
    /// carries on into the next chapter and generates it in the background
    /// without a second prompt, so this chapter's confirmation is the only
    /// place the book's real cost can be stated.
    ///
    /// Nil when the source is not a book chapter, or when every other chapter
    /// already has audio on the phone — the chapter's own price is then the
    /// whole charge. Sizing comes from each chapter's synced word count, scaled
    /// by the ratio this chapter's prepared narration actually measured; a
    /// chapter with no word count is counted but not priced, which understates
    /// the book rather than inventing a number for it.
    private func textToSpeechBookScope(
        for source: MobileCloudSource,
        narrationCharacters: Int
    ) -> MobileTextToSpeechCostConfirmation.BookScope? {
        guard source.sourceType == "book",
              let parentGroup = source.parentGroup,
              !parentGroup.isEmpty else { return nil }
        let remaining = allSources.filter {
            $0.sourceType == "book"
                && $0.parentGroup == parentGroup
                && $0.id != source.id
                && !$0.isArchived
                && !hasSyncedTextToSpeechAudio(sourceID: $0.id)
        }
        guard !remaining.isEmpty else { return nil }

        let charactersPerWord = ArticleSpeechCostEstimate.charactersPerWord(
            narrationCharacters: narrationCharacters,
            wordCount: source.wordCount
        )
        let characters = remaining.reduce(0) { total, chapter in
            guard let words = chapter.wordCount, words > 0 else { return total }
            return total + Int((Double(words) * charactersPerWord).rounded())
        }
        guard characters > 0 else { return nil }

        return MobileTextToSpeechCostConfirmation.BookScope(
            title: collections.booksByID[parentGroup]?.title ?? "Whole book",
            remainingChapters: remaining.count,
            remainingCharacters: characters
        )
    }

    private func confirmTextToSpeechCost(
        source: MobileCloudSource,
        characterCount: Int,
        modelID: String,
        languageNotice: String? = nil
    ) async -> Bool {
        if let pending = textToSpeechCostConfirmationContinuation {
            textToSpeechCostConfirmationContinuation = nil
            textToSpeechCostConfirmation = nil
            pending.resume(returning: false)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                textToSpeechCostConfirmationContinuation = continuation
                textToSpeechCostConfirmation = MobileTextToSpeechCostConfirmation(
                    sourceID: source.id,
                    sourceTitle: source.title,
                    characterCount: characterCount,
                    modelID: modelID,
                    languageNotice: languageNotice,
                    book: textToSpeechBookScope(for: source, narrationCharacters: characterCount)
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveTextToSpeechCostConfirmation(approved: false)
            }
        }
    }

    /// Held for as long as any text-to-speech generation is running. It keeps the
    /// screen awake and, more importantly, keeps the app out of suspension the
    /// moment it stops being frontmost.
    ///
    /// The `audio` background mode only covers an app that is actually playing
    /// something, and generation runs before there is anything to play — and
    /// again whenever the generated prefix runs dry mid-source. Without the
    /// background task assertion, leaving the reader for the home screen or
    /// another app suspended the process within seconds and froze every
    /// in-flight speech request until the user came back, by which point they
    /// had failed.
    private func acquireTextToSpeechGenerationLease() {
        if textToSpeechIdleTimerLeaseCount == 0 {
            wasIdleTimerDisabledBeforeTextToSpeechGeneration = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        textToSpeechIdleTimerLeaseCount += 1
        // Outside the count check on purpose: an expired assertion has already
        // cleared itself, and the next job deserves a fresh runway even though
        // the lease never dropped to zero.
        beginTextToSpeechBackgroundTask()
    }

    private func releaseTextToSpeechGenerationLease() {
        guard textToSpeechIdleTimerLeaseCount > 0 else { return }
        textToSpeechIdleTimerLeaseCount -= 1
        if textToSpeechIdleTimerLeaseCount == 0 {
            UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabledBeforeTextToSpeechGeneration
            endTextToSpeechBackgroundTask()
        }
    }

    private func beginTextToSpeechBackgroundTask() {
        guard textToSpeechBackgroundTaskID == .invalid else { return }
        textToSpeechBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "text-to-speech-generation"
        ) { [weak self] in
            // iOS calls this synchronously on the main thread when the runway
            // is gone. End the assertion here rather than hopping to a task the
            // system may never schedule: an assertion left open is a kill, and
            // the journaled chunks mean a suspension only costs the requests
            // that were still in flight.
            MainActor.assumeIsolated {
                self?.endTextToSpeechBackgroundTask()
            }
        }
    }

    private func endTextToSpeechBackgroundTask() {
        guard textToSpeechBackgroundTaskID != .invalid else { return }
        let identifier = textToSpeechBackgroundTaskID
        textToSpeechBackgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    /// Resolves the source's durable listen-ready text without touching player
    /// state. Both autoplay and concurrent background jobs use this path so a
    /// second article can prepare while the first keeps its audio session.
    private func prepareTextToSpeechNarration(
        for source: MobileCloudSource,
        onDetail: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> MobilePreparedTextToSpeechNarration {
        // The phone uses what the Mac prepared and synced when there is one.
        // Since 2026-09-24 the Mac prepares Listen only when someone listens
        // there, or at once for the kinds automatic audio covers, so a paper or
        // article nobody has played yet has no synced narration: the phone then
        // runs the same preparation itself, on the same prompt, route and
        // ledger task, because the learner has just asked to listen. A book chapter the Mac prepared because it
        // carries equations or tables uses that narration too; otherwise the
        // chapter's own text is read, as before. An explainer's script is the
        // one article read as it stands: it was written for the ear, and the
        // pass is never run on it anywhere (`MobileTextToSpeechNarrationPolicy`).
        let requiresPreparedNarration = MobileTextToSpeechNarrationPolicy.requiresMacPreparedNarration(
            sourceType: source.sourceType,
            url: source.url
        )
        let mayHavePreparedNarration = MobileTextToSpeechNarrationPolicy.mayHaveMacPreparedNarration(
            sourceType: source.sourceType,
            url: source.url
        )
        if mayHavePreparedNarration {
            onDetail("Loading prepared narration…")
            let savedListenable = try await sourceTextStore.loadSourceListenableContent(
                sourceID: source.id
            )
            if let savedListenable,
               savedListenable.metadata.preparationSignature?
                    .hasPrefix(PaperNarrationFilter.preparationContractPrefix) == true {
                return MobilePreparedTextToSpeechNarration(
                    text: savedListenable.text,
                    sourceContentSignature: savedListenable.metadata.sourceSHA256,
                    preparationSignature: savedListenable.metadata.preparationSignature
                )
            }
            if requiresPreparedNarration {
                onDetail("Loading source…")
                let canonicalText = try await sourceTextStore.loadSourceText(sourceID: source.id)
                let prepared = try await MobilePaperTextToSpeechPreparation.prepare(
                    sourceID: source.id,
                    sourceType: source.sourceType,
                    title: source.title,
                    canonicalText: canonicalText,
                    onProgress: { completed, total in
                        onDetail(completed == 0
                            ? "Preparing text…"
                            : "Preparing text \(completed) of \(total)…")
                    }
                )
                return MobilePreparedTextToSpeechNarration(
                    text: prepared.text,
                    sourceContentSignature: prepared.sourceContentSignature,
                    preparationSignature: prepared.preparationSignature
                )
            }
        }

        onDetail("Loading source…")
        let rawText = try await sourceTextStore.loadSourceText(sourceID: source.id)
        let narrationText = await Task.detached(priority: .userInitiated) {
            MobileReviewSpeechService.narrationText(from: rawText)
        }.value
        return MobilePreparedTextToSpeechNarration(
            text: narrationText,
            sourceContentSignature: nil,
            preparationSignature: nil
        )
    }

    /// The account's text-to-speech selection, refreshed from iCloud immediately
    /// before a billable request, so a model picked on the Mac is the one that
    /// narrates here. iCloud not answering stops the request: never spend on
    /// a selection another device may have replaced.
    ///
    /// A pick OpenRouter stopped offering is repaired first, by the Mac's
    /// rule, and the repair becomes the account's pick; `repairNotice` says
    /// so once ("<old> is no longer offered; using <new>."). A pick applied
    /// while its test could not finish, or whose pass has run out, is tested
    /// beside this request.
    private func refreshedTextToSpeechSelection() async throws -> (
        selection: CloudArticleTTS.Selection,
        repairNotice: String?
    ) {
        try await ArticleSpeechPreferences.shared.refreshFromAccount()
        let repair = ArticleSpeechSelection.repairSelectionForUse()
        if repair != nil {
            ArticleSpeechPreferences.shared.reloadFromStorage()
            // Best effort: the account row still names a model no device can
            // use, and every device repairs that on its own the same way.
            try? await ArticleSpeechPreferences.shared.pushToAccount()
        }
        let selection = try CloudArticleTTS.currentSelection()
        CloudArticleTTS.testPickWhenDue(model: selection.model, voice: selection.voice ?? "")
        return (selection, repair?.message)
    }

    private func generateTextToSpeechManifest(
        for source: MobileCloudSource,
        narration: MobilePreparedTextToSpeechNarration,
        selection: CloudArticleTTS.Selection? = nil,
        onOpeningReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?,
        onMoreAudioReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?,
        onProgress: @escaping @Sendable (_ completedChunks: Int, _ totalChunks: Int) async -> Void
    ) async throws -> SyncedArticleAudioManifest {
        let manifest = try await AIUsageAttribution.withSource(
            AIUsageSource(id: source.id, type: source.sourceType, title: source.title)
        ) {
            try await CloudArticleTTS.generate(
                sourceID: source.id,
                title: source.title,
                subtitle: source.subtitle,
                sourceType: source.sourceType,
                sourceURL: source.url ?? "",
                text: narration.text,
                sourceContentSignature: narration.sourceContentSignature,
                narrationPreparationSignature: narration.preparationSignature,
                createdAt: Date(),
                selection: selection,
                onOpeningReady: onOpeningReady,
                onMoreAudioReady: onMoreAudioReady,
                onProgress: onProgress
            )
        }
        // Generation 2: the finished narration goes up as the source's `audio.*` satellites.
        let sourceID = source.id
        Task { await MobileNarrationLibrary.shared.refresh(only: sourceID) }
        return manifest
    }

    /// Audio another device has published for this source, waited for briefly
    /// when CloudDocs has announced it but not delivered it yet, and entered
    /// into the library exactly as a generation here would be. nil means the
    /// account has no narration for this source and generating is the only way.
    private func adoptPublishedSyncedAudioIfAvailable(
        for source: MobileCloudSource
    ) async -> MobileAudioItem? {
        let sourceID = source.id
        let manifest = await Task.detached(priority: .userInitiated) {
            await SyncedArticleAudioStore.awaitPublishedManifest(sourceID: sourceID)
        }.value
        guard let manifest else { return nil }
        return publishGeneratedTextToSpeechManifest(manifest, sourceID: sourceID)
    }

    /// Starts following CloudDocs' view of the audio tree so a narration the
    /// Mac finishes while this app is open shows up here within seconds, rather
    /// than at whatever later reload happens to run after its manifest landed.
    private func startObservingSyncedAudioManifests() {
        guard syncedAudioManifestObserver == nil,
              SyncedArticleAudioStore.isUbiquitousAudioRootAvailable else { return }
        let observer = SyncedAudioManifestObserver(
            audioRoot: SyncedArticleAudioStore.audioRootURL()
        )
        syncedAudioManifestObserver = observer
        syncedAudioObservationTask = Task { @MainActor [weak self] in
            for await _ in observer.changes {
                guard let self else { return }
                await self.refreshSyncedAudioCatalog()
            }
        }
    }

    /// Re-reads the manifests after CloudDocs reported that the readable set
    /// changed, and republishes the rows' audio badges when it really did.
    private func refreshSyncedAudioCatalog() async {
        let manifests = await Task.detached(priority: .utility) {
            try? SyncedArticleAudioStore.loadAvailableManifests()
        }.value
        guard let manifests, manifests != items.map(\.manifest) else { return }
        items = manifests.map(MobileAudioItem.init(manifest:))
        if !allSources.isEmpty {
            publishCatalogSources(allSources)
        }
        NotificationCenter.default.post(name: .mobileListeningCatalogDidChange, object: nil)
    }

    @discardableResult
    private func publishGeneratedTextToSpeechManifest(
        _ manifest: SyncedArticleAudioManifest,
        sourceID: String
    ) -> MobileAudioItem {
        let generatedItem = MobileAudioItem(manifest: manifest)
        items.removeAll { $0.id == generatedItem.id }
        items.insert(generatedItem, at: 0)
        if let index = allSources.firstIndex(where: { $0.id == sourceID }) {
            allSources[index].hasAudio = true
        }
        NotificationCenter.default.post(name: .mobileListeningCatalogDidChange, object: sourceID)
        return generatedItem
    }

    /// A prepare-only job never claims or modifies the player. Several source
    /// IDs can run together, and each row observes its own keyed progress. UI
    /// Listen requests opt into an opening callback; MCP and automatic cache
    /// preparation keep the default generate-only behavior.
    private func generateBackgroundTextToSpeechAudio(
        for source: MobileCloudSource,
        playsOpeningWhenReady: Bool
    ) async throws -> MobileAudioItem {
        backgroundTextToSpeechPreparingTitles[source.id] = source.title
        backgroundTextToSpeechGenerationProgress[source.id] = nil
        acquireTextToSpeechGenerationLease()
        defer {
            backgroundTextToSpeechPreparingTitles[source.id] = nil
            backgroundTextToSpeechGenerationProgress[source.id] = nil
            releaseTextToSpeechGenerationLease()
        }

        do {
            let item: MobileAudioItem
            if let published = await adoptPublishedSyncedAudioIfAvailable(for: source) {
                // Another device already narrated this source; the list was
                // behind. A Listen tap plays it the way a cache hit would, and
                // a prepare-only request simply has its answer.
                item = published
                if playsOpeningWhenReady, !MobileVoiceConversationController.shared.isActive {
                    await play(item)
                }
            } else {
                let narration = try await prepareTextToSpeechNarration(for: source) { _ in }
                let isSignedIn = await Task.detached(priority: .userInitiated) {
                    ManagedAI.isSignedIn
                }.value
                guard isSignedIn else {
                    throw CloudArticleTTS.GenerationError.missingAPIKey
                }
                let (selection, repairNotice) = try await refreshedTextToSpeechSelection()
                if let repairNotice { errorMessage = repairNotice }
                let generationStartedAt = Date()
                let onOpeningReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?
                let onMoreAudioReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?
                if playsOpeningWhenReady {
                    onOpeningReady = { [weak self] opening in
                        guard let self else { return }
                        _ = await self.startBackgroundOpeningPlaybackIfAvailable(
                            MobileAudioItem(manifest: opening)
                        )
                    }
                    onMoreAudioReady = { [weak self] partial in
                        guard let self else { return }
                        _ = await self.extendOpeningPlayback(MobileAudioItem(manifest: partial))
                    }
                } else {
                    onOpeningReady = nil
                    onMoreAudioReady = nil
                }
                let manifest = try await generateTextToSpeechManifest(
                    for: source,
                    narration: narration,
                    selection: selection,
                    onOpeningReady: onOpeningReady,
                    onMoreAudioReady: onMoreAudioReady,
                    onProgress: { [weak self] completedChunks, totalChunks in
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            // Requests finish in any order and report from two
                            // places; the ring never steps backwards.
                            if let current = self.backgroundTextToSpeechGenerationProgress[source.id],
                               current.totalChunks == totalChunks,
                               current.completedChunks > completedChunks { return }
                            self.backgroundTextToSpeechGenerationProgress[source.id] =
                                MobileTextToSpeechGenerationProgress(
                                    completedChunks: completedChunks,
                                    totalChunks: totalChunks,
                                    startedAt: generationStartedAt,
                                    model: selection.model
                                )
                        }
                    }
                )
                item = publishGeneratedTextToSpeechManifest(manifest, sourceID: source.id)
                if playsOpeningWhenReady {
                    await finishBackgroundOpeningPlaybackIfNeeded(item)
                    if backgroundOpeningPlaybackOwnerSourceID == source.id {
                        backgroundOpeningPlaybackOwnerSourceID = nil
                    }
                }
            }

            if let continuation = pendingAutomaticBookContinuation,
               continuation.nextSourceID == source.id {
                pendingAutomaticBookContinuation = nil
                Task { @MainActor [weak self] in
                    await self?.automaticallyContinueBook(
                        from: continuation.completedSourceID,
                        to: continuation.nextSourceID
                    )
                }
            }

            if pendingTextToSpeechAfterPreparationSourceID == source.id {
                pendingTextToSpeechAfterPreparationSourceID = nil
                Task { @MainActor [weak self] in
                    await self?.readSourceAloud(sourceID: source.id)
                }
            }
            pendingTextToSpeechResumes[source.id] = nil
            automaticTextToSpeechResumeCounts[source.id] = nil
            return item
        } catch {
            // A resume that is still coming keeps the listener's prefix and the
            // player state that lets the rest be appended to it: the second half
            // really is on its way, so this is buffering rather than the end of
            // the source. Only a generation that is over for good hands it back.
            if !recordInterruptedTextToSpeechGeneration(
                sourceID: source.id,
                playsOpeningWhenReady: playsOpeningWhenReady,
                error: error
            ) {
                releaseInterruptedOpeningPlayback(sourceID: source.id)
            }
            if pendingTextToSpeechAfterPreparationSourceID == source.id {
                pendingTextToSpeechAfterPreparationSourceID = nil
                errorMessage = error.localizedDescription
                if !MobileVoiceConversationController.shared.isActive {
                    speakWithoutListening(error.localizedDescription)
                }
            }
            throw error
        }
    }

    /// Whether a failed generation is one worth restarting on its own.
    ///
    /// Only the failures that say nothing about the request survive here: the
    /// network went away, or the work was cancelled. A model that refused the
    /// text, an empty balance, an expired session, or an invalid voice all fail
    /// again identically, and retrying them silently would spend the listener's
    /// credits on the same refusal.
    private static func isResumableTextToSpeechFailure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if error is URLError { return true }
        if let generation = error as? CloudArticleTTS.GenerationError {
            switch generation {
            case .failedAfterRetries, .networkUnavailable:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// A failure that means the device has nowhere to send the next request.
    /// Worth separating from the rest: retrying one of these immediately only
    /// spends the resume budget against an outage that has not ended.
    private static func isOfflineTextToSpeechFailure(_ error: Error) -> Bool {
        if let generation = error as? CloudArticleTTS.GenerationError,
           case .networkUnavailable = generation {
            return true
        }
        return CloudArticleTTS.isOfflineError(error)
    }

    /// Remembers a generation that stopped for a reason worth retrying, and
    /// restarts it right away when the app is on screen to run it. Returns
    /// whether a resume is now pending for this source.
    ///
    /// Suspension is what makes this necessary: iOS freezes the process, the
    /// speech requests that were in flight fail the moment it thaws, and the
    /// generation ends holding a journal of everything already paid for. The
    /// resume picks up from that journal, so a restart costs only the chunks
    /// that never arrived.
    @discardableResult
    private func recordInterruptedTextToSpeechGeneration(
        sourceID: String,
        playsOpeningWhenReady: Bool,
        error: Error
    ) -> Bool {
        guard Self.isResumableTextToSpeechFailure(error) else {
            pendingTextToSpeechResumes[sourceID] = nil
            return false
        }
        guard automaticTextToSpeechResumeCounts[sourceID, default: 0]
                < Self.maximumAutomaticTextToSpeechResumes else {
            pendingTextToSpeechResumes[sourceID] = nil
            return false
        }
        pendingTextToSpeechResumes[sourceID] =
            playsOpeningWhenReady || (pendingTextToSpeechResumes[sourceID] ?? false)
        let waitsForNetwork = Self.isOfflineTextToSpeechFailure(error)
        if UIApplication.shared.applicationState == .active {
            Task { @MainActor [weak self] in
                // A generation the radio ended resumes when the radio is back,
                // not a second later: the tunnel, the lift and the cell
                // handover all end on their own, and an attempt spent before
                // then is one the listener does not get back. The foreground
                // pass still covers a wait that runs out.
                if waitsForNetwork {
                    guard await NetworkPathAvailability.shared.waitForPath(
                        timeout: Self.offlineResumeNetworkWait
                    ) else { return }
                }
                await self?.resumeInterruptedTextToSpeechGeneration()
            }
        }
        return true
    }

    /// Hands the player back after a generation that is not coming back.
    ///
    /// While a resume is pending the listener stays on the prefix they are
    /// hearing, still marked as awaiting the rest, so the resumed tail is
    /// appended to it in place. Once there is no resume left to wait for, that
    /// prefix is ordinary playback again — otherwise the transport would sit in
    /// a buffering state that never resolves, and finishing it would never
    /// count as finishing the source.
    private func releaseInterruptedOpeningPlayback(sourceID: String) {
        if backgroundOpeningPlaybackOwnerSourceID == sourceID {
            backgroundOpeningPlaybackOwnerSourceID = nil
        }
        if openingPlaybackSourceID == sourceID {
            openingPlaybackSourceID = nil
            isAwaitingRemainingNarration = false
            openingPlaybackRanDry = false
        }
    }

    /// Restarts every generation that an interruption left unfinished. Called
    /// when the app comes back to the foreground and immediately after a
    /// resumable failure, so returning to the app is enough to finish a source
    /// the phone suspended part-way through.
    func resumeInterruptedTextToSpeechGeneration() async {
        guard !isResumingTextToSpeechGeneration else { return }
        isResumingTextToSpeechGeneration = true
        defer { isResumingTextToSpeechGeneration = false }

        // Generations fail independently, and one can fail while this pass is
        // awaiting another's resume. The task that failure spawns finds this
        // pass already running and returns, so without draining, the second
        // source would wait for the next foreground to be picked up.
        while await resumeOnePassOfInterruptedTextToSpeechGeneration() {}
    }

    /// One pass over the pending set. Returns whether it consumed anything —
    /// false means every remaining entry is blocked on a generation that is
    /// still running, which is the signal to stop rather than spin.
    private func resumeOnePassOfInterruptedTextToSpeechGeneration() async -> Bool {
        let pending = pendingTextToSpeechResumes
        guard !pending.isEmpty else { return false }

        for (sourceID, playsOpeningWhenReady) in pending {
            if hasSyncedTextToSpeechAudio(sourceID: sourceID) {
                pendingTextToSpeechResumes[sourceID] = nil
                releaseInterruptedOpeningPlayback(sourceID: sourceID)
                continue
            }
            guard !isPreparingAudio(sourceID: sourceID) else { continue }
            // Only resumable work is restarted automatically. Without a journal
            // the retry would re-narrate — and re-bill — the whole source, which
            // is the listener's call to make, not this pass's.
            let hasProgress = await Task.detached(priority: .utility) {
                SyncedArticleAudioStore.hasGenerationProgress(sourceID: sourceID)
            }.value
            guard hasProgress else {
                pendingTextToSpeechResumes[sourceID] = nil
                releaseInterruptedOpeningPlayback(sourceID: sourceID)
                continue
            }

            pendingTextToSpeechResumes[sourceID] = nil
            automaticTextToSpeechResumeCounts[sourceID, default: 0] += 1
            // A failure re-records itself through the ordinary catch path, and
            // the listener already saw the message that stopped it.
            _ = try? await prepareSourceAudio(
                sourceID: sourceID,
                playsOpeningWhenReady: playsOpeningWhenReady
            )
        }

        // Unchanged means every entry was blocked on a running generation, and
        // another identical pass would do nothing but spin. Any other outcome —
        // an entry consumed, a new failure recorded — earns another look.
        return pendingTextToSpeechResumes != pending
    }

    private func generateCloudTextToSpeechAudio(
        for source: MobileCloudSource,
        autoplay: Bool
    ) async throws {
        var generationSucceeded = false
        if autoplay { isLoading = true }
        acquireTextToSpeechGenerationLease()
        textToSpeechPreparingTitle = source.title
        textToSpeechPreparingSourceID = source.id
        textToSpeechAutoplaySourceID = autoplay ? source.id : nil
        textToSpeechPreparationDetail = "Loading source…"
        textToSpeechGenerationProgress = nil
        defer {
            if autoplay { isLoading = false }
            releaseTextToSpeechGenerationLease()
            textToSpeechPreparingTitle = nil
            textToSpeechPreparingSourceID = nil
            textToSpeechAutoplaySourceID = nil
            textToSpeechPreparationDetail = nil
            textToSpeechGenerationProgress = nil
            // A generation that failed after its opening started leaves no
            // second half coming; the opening is ordinary playback again.
            if openingPlaybackSourceID == source.id {
                openingPlaybackSourceID = nil
                isAwaitingRemainingNarration = false
                openingPlaybackRanDry = false
            }
            if autoplay { updateNowPlayingInfo() }
            if let pendingSourceID = pendingTextToSpeechAfterPreparationSourceID {
                if generationSucceeded {
                    pendingTextToSpeechAfterPreparationSourceID = nil
                    // Run after this method releases its preparation state. The
                    // generated source takes the cached fast path; a different
                    // source starts its own TTS job serially.
                    Task { @MainActor [weak self] in
                        await self?.readSourceAloud(sourceID: pendingSourceID)
                    }
                } else if autoplay {
                    // The direct text-to-speech caller owns failure presentation.
                    pendingTextToSpeechAfterPreparationSourceID = nil
                }
            }
        }

        // Audio another device already published for this source outranks any
        // generation: the library's manifest walk may simply not have caught
        // up with it. Waiting here is only ever spent on audio CloudDocs has
        // announced, and it is what stands between a stale list and paying for
        // the same narration twice.
        textToSpeechPreparationDetail = "Checking iCloud for existing audio…"
        if let published = await adoptPublishedSyncedAudioIfAvailable(for: source) {
            generationSucceeded = true
            guard autoplay, !MobileVoiceConversationController.shared.isActive else { return }
            await play(published)
            return
        }

        let narration = try await prepareTextToSpeechNarration(for: source) { [weak self] detail in
            self?.textToSpeechPreparationDetail = detail
        }
        let isSignedIn = await Task.detached(priority: .userInitiated) {
            ManagedAI.isSignedIn
        }.value
        guard isSignedIn else {
            throw CloudArticleTTS.GenerationError.missingAPIKey
        }

        let (selection, repairNotice) = try await refreshedTextToSpeechSelection()
        let narrationText = narration.text
        let narrationPricing = await Task.detached(priority: .userInitiated) {
            let signature = SyncedArticleAudioStore.contentSignature(for: narrationText)
            let hasCachedAudio = CloudArticleTTS.cachedManifest(
                sourceID: source.id,
                signature: signature
            ) != nil
            return (characterCount: narrationText.count, hasCachedAudio: hasCachedAudio)
        }.value
        // Almost every catalog voice is English-only, and handed German text
        // it returns fluent-sounding nonsense — and bills for it. Recognize the
        // narration's own language first: if another catalog voice speaks it,
        // this source gets that voice; if none does, say so before the money
        // goes out, whether or not price confirmation is switched on.
        let language: ArticleSpeechLanguageResolution? = narrationPricing.hasCachedAudio
            ? nil
            : await Task.detached(priority: .userInitiated) {
                ArticleSpeechLanguageResolution.resolve(
                    text: narrationText,
                    model: selection.model,
                    voice: selection.voice ?? ""
                )
            }.value
        // Only a substitution replaces the selection; a language the chosen
        // voice already speaks leaves the validated selection exactly as it is.
        let resolvedSelection: CloudArticleTTS.Selection
        if let language, language.changesSelection {
            resolvedSelection = CloudArticleTTS.Selection(model: language.model, voice: language.voice)
        } else {
            resolvedSelection = selection
        }
        let unnarratableLanguage = language?.outcome == .unsupported

        // Confirmation suppression follows the account. Refresh immediately
        // before a potentially billable request; a CloudKit failure fails safe
        // by asking rather than silently spending.
        let suppressedCostModels = (try? await MobileModelPreferenceStore.shared.stringArray(
            forKey: TextToSpeechCostConfirmationPreferences.suppressedModelIDsKey
        )) ?? []
        let confirmsSelectedModelCost = MobileTextToSpeechPricingPreferences.confirmsEstimatedCost
            && !suppressedCostModels.contains(resolvedSelection.model)
        let asksToConfirmCost = autoplay
            && !narrationPricing.hasCachedAudio
            && (confirmsSelectedModelCost || unnarratableLanguage)
        // A repaired pick is said once: in the price question when there is
        // one, else in the bar's message row.
        if let repairNotice, !asksToConfirmCost {
            errorMessage = repairNotice
        }
        if asksToConfirmCost {
            textToSpeechPreparationDetail = "Waiting for cost confirmation…"
            let notice = [repairNotice, language?.message].compactMap { $0 }.joined(separator: " ")
            guard await confirmTextToSpeechCost(
                source: source,
                characterCount: narrationPricing.characterCount,
                modelID: resolvedSelection.model,
                languageNotice: notice.isEmpty ? nil : notice
            ) else { return }
        }

        textToSpeechPreparationDetail = "Generating first audio chunk…"
        if autoplay {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: source.title,
                MPMediaItemPropertyArtist: "Preparing audio · \(ArticleSpeechCatalog.model(id: resolvedSelection.model)?.name ?? resolvedSelection.model)…",
                MPMediaItemPropertyAlbumTitle: "ForeverLM Listen",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: 0,
            ]
            MPNowPlayingInfoCenter.default().playbackState = .paused
        }

        if autoplay, isPlaying {
            player.pause()
            isPlaying = false
            persistPlaybackPosition(force: true)
            updateNowPlayingInfo()
        }
        if autoplay {
            await voice.stop()
            speech.stop(owner: .voiceTab)
            isSourceChatActive = false
            activeChatTitle = nil
            shouldResumePlaybackAfterSpeech = false
        }

        // Generate cloud audio and save it through the synced-audio pipeline.
        // Listen does not wait for the whole source: the opening section starts
        // playing as soon as it exists, and the whole composition takes over at
        // the same second once the rest is generated.
        let onOpeningReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?
        let onMoreAudioReady: (@Sendable (SyncedArticleAudioManifest) async -> Void)?
        if autoplay {
            onOpeningReady = { [weak self] opening in
                guard let self else { return }
                await MainActor.run {
                    self.textToSpeechPreparationDetail = "First chunk ready · starting playback…"
                }
                let didStart = await self.startOpeningPlayback(MobileAudioItem(manifest: opening))
                await MainActor.run {
                    self.textToSpeechPreparationDetail = didStart
                        ? "Playing · generating remaining audio…"
                        : "First chunk ready · finishing audio…"
                }
            }
            onMoreAudioReady = { [weak self] partial in
                guard let self else { return }
                _ = await self.extendOpeningPlayback(MobileAudioItem(manifest: partial))
            }
        } else {
            onOpeningReady = nil
            onMoreAudioReady = nil
        }
        let generationStartedAt = Date()

        let manifest = try await generateTextToSpeechManifest(
            for: source,
            narration: narration,
            selection: resolvedSelection,
            onOpeningReady: onOpeningReady,
            onMoreAudioReady: onMoreAudioReady,
            onProgress: { [weak self] completedChunks, totalChunks in
                await MainActor.run { [weak self] in
                    if completedChunks == 0 {
                        self?.textToSpeechPreparationDetail = "Generating first audio chunk…"
                    } else if completedChunks < totalChunks,
                              self?.openingPlaybackSourceID != source.id {
                        self?.textToSpeechPreparationDetail = "Generating remaining audio…"
                    } else if completedChunks == totalChunks {
                        self?.textToSpeechPreparationDetail = "Audio ready · starting playback…"
                    }
                    if let current = self?.textToSpeechGenerationProgress,
                       current.totalChunks == totalChunks,
                       current.completedChunks > completedChunks { return }
                    self?.textToSpeechGenerationProgress = MobileTextToSpeechGenerationProgress(
                        completedChunks: completedChunks,
                        totalChunks: totalChunks,
                        startedAt: generationStartedAt,
                        model: resolvedSelection.model
                    )
                }
            }
        )
        let generatedItem = publishGeneratedTextToSpeechManifest(manifest, sourceID: source.id)
        generationSucceeded = true

        guard autoplay, !MobileVoiceConversationController.shared.isActive else { return }

        // Hand the listener over from the opening to the whole source without
        // moving them: same second, and still paused if they paused it.
        var startAt: TimeInterval?
        var keepPaused = false
        if openingPlaybackSourceID == source.id {
            startAt = currentTime
            keepPaused = !isPlaying && !openingPlaybackRanDry
            openingPlaybackSourceID = nil
            isAwaitingRemainingNarration = false
            openingPlaybackRanDry = false
        }

        await play(generatedItem, startAt: startAt)
        if keepPaused, isPlaying {
            togglePlayback()
        }
    }

    /// The earliest ready opening among concurrent UI Listen requests owns the
    /// empty player. Ownership lasts until that job completes even if the
    /// listener closes it, so another already-requested source cannot pop up
    /// immediately afterward.
    private func startBackgroundOpeningPlaybackIfAvailable(
        _ item: MobileAudioItem
    ) async -> Bool {
        guard currentItem == nil,
              backgroundOpeningPlaybackOwnerSourceID == nil,
              !MobileVoiceConversationController.shared.isActive else { return false }

        backgroundOpeningPlaybackOwnerSourceID = item.id
        let didStart = await startOpeningPlayback(item)
        if !didStart, backgroundOpeningPlaybackOwnerSourceID == item.id {
            backgroundOpeningPlaybackOwnerSourceID = nil
        }
        return didStart
    }

    /// Replaces a progressively growing opening with the final durable
    /// manifest without moving the playback cursor. A dismissed opening has
    /// already cleared `openingPlaybackSourceID`, so completion stays silent.
    private func finishBackgroundOpeningPlaybackIfNeeded(
        _ item: MobileAudioItem
    ) async {
        guard openingPlaybackSourceID == item.id,
              currentItem?.id == item.id,
              !MobileVoiceConversationController.shared.isActive else { return }

        let startAt = currentTime
        let keepPaused = !isPlaying && !openingPlaybackRanDry
        openingPlaybackSourceID = nil
        isAwaitingRemainingNarration = false
        openingPlaybackRanDry = false

        await play(item, startAt: startAt)
        if keepPaused, isPlaying {
            togglePlayback()
        }
    }

    /// Plays the opening section the moment its audio lands, so tapping Listen
    /// makes sound in a couple of seconds instead of holding a spinner for as
    /// long as a whole paper takes to narrate.
    ///
    /// The manifest here describes only the opening and is never saved — it
    /// exists so playback, Now Playing, and the transport controls have the
    /// same shape they always do. `generateCloudTextToSpeechAudio` replaces it
    /// with the whole composition as soon as the rest is generated.
    private func startOpeningPlayback(
        _ item: MobileAudioItem,
        startAt: TimeInterval = 0
    ) async -> Bool {
        guard !MobileVoiceConversationController.shared.isActive else { return false }
        // A listener who started something else during generation keeps it.
        guard currentItem == nil || currentItem?.id == item.id || !isPlaying else { return false }

        do {
            try await configureAudioSession()
            let urls = try await Task.detached(priority: .userInitiated) {
                try SyncedArticleAudioStore.chunkURLs(for: item.manifest)
            }.value
            let composition = try await audioComposition(for: urls)
            let playerItem = await MobileLoudnessAudioMix.playerItem(for: composition.asset)

            installOpeningEndObserver(for: playerItem)

            let resumeTime = min(max(startAt, 0), composition.duration)
            openingPlaybackSourceID = item.id
            isAwaitingRemainingNarration = true
            openingPlaybackRanDry = false
            currentItem = item
            activeVoiceSourceID = item.id
            activeVoiceSourceTitle = item.title
            duration = composition.duration
            currentTime = resumeTime
            lastPlaybackPositionSaveAt = nil
            player.replaceCurrentItem(with: playerItem)
            if resumeTime > 0 {
                await player.seek(
                    to: CMTime(seconds: resumeTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            player.playImmediately(atRate: speed)
            isPlaying = true
            isLoading = false
            updateNowPlayingInfo()
            Task { [weak self] in
                await self?.recordSourceActivity(sourceID: item.id, kind: .listening)
            }
            return true
        } catch {
            // Nothing is lost: generation continues, and the whole source plays
            // through the ordinary path when it finishes. Returning the result
            // lets the progress surface explain why playback has not started yet.
            openingPlaybackSourceID = nil
            isAwaitingRemainingNarration = false
            openingPlaybackRanDry = false
            return false
        }
    }

    /// Replaces the temporary composition with its longer contiguous prefix.
    /// Requests may finish out of order, but `CloudArticleTTS` only calls this
    /// with gap-free audio, so the current global playback second is stable.
    /// If the old prefix ran dry, the new audio resumes automatically; an
    /// intentional pause inside the prefix remains paused.
    private func extendOpeningPlayback(_ item: MobileAudioItem) async -> Bool {
        guard openingPlaybackSourceID == item.id,
              currentItem?.id == item.id,
              !MobileVoiceConversationController.shared.isActive else { return false }

        do {
            let urls = try await Task.detached(priority: .userInitiated) {
                try SyncedArticleAudioStore.chunkURLs(for: item.manifest)
            }.value
            let composition = try await audioComposition(for: urls)
            // The whole composition may have taken over while this prefix was
            // being assembled; installing the shorter one now would move the
            // listener backwards.
            guard openingPlaybackSourceID == item.id, currentItem?.id == item.id else { return false }
            guard composition.duration > duration + 0.05 else { return true }

            let resumeTime = min(max(currentTime, 0), composition.duration)
            let shouldPlay = isPlaying || openingPlaybackRanDry
            let playerItem = await MobileLoudnessAudioMix.playerItem(for: composition.asset)

            installOpeningEndObserver(for: playerItem)
            currentItem = item
            duration = composition.duration
            currentTime = resumeTime
            player.replaceCurrentItem(with: playerItem)
            if resumeTime > 0 {
                await player.seek(
                    to: CMTime(seconds: resumeTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            if shouldPlay {
                player.playImmediately(atRate: speed)
                isPlaying = true
                if openingPlaybackRanDry {
                    textToSpeechPreparationDetail = "Playing · generating remaining audio…"
                }
                openingPlaybackRanDry = false
            } else {
                isPlaying = false
            }
            updateNowPlayingInfo()
            return true
        } catch {
            // Keep the shorter prefix playing. Final generation still performs
            // the ordinary whole-source handoff and surfaces any real failure.
            return false
        }
    }

    private func installOpeningEndObserver(for playerItem: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Running out of the generated prefix is buffering, not source
                // completion. Hold the global second so the next prefix resumes.
                self.isPlaying = false
                self.currentTime = self.duration
                self.openingPlaybackRanDry = true
                // The bar was saying "Playing"; it is not. Say what it is
                // waiting for, so the silence reads as a gap, not a stop. A
                // download's banner reads its own counts and needs no text.
                if self.narrationDownloadSourceID == nil {
                    self.textToSpeechPreparationDetail = "Waiting for the next section…"
                }
                self.updateNowPlayingInfo()
            }
        }
    }

    private func sendSourceChatMessage(_ message: String) async {
        let totalStart = Date()
        guard !isChatResponding else { return }
        isChatResponding = true
        if isPlaying {
            player.pause()
            isPlaying = false
            persistPlaybackPosition(force: true)
            updateNowPlayingInfo()
        }
        await voice.stop()

        do {
            let response = try await sourceChat.send(message)
            if let chatBenchmark = await sourceChat.lastBenchmark() {
                lastDrivingBenchmark = MobileDrivingVoiceBenchmark(
                    utterance: message,
                    route: "source_chat",
                    sourceResolutionStrategy: "active_source",
                    sourceResolutionMilliseconds: 0,
                    sourceTextLoadMilliseconds: 0,
                    firstModelTurnMilliseconds: chatBenchmark.llmMilliseconds,
                    totalMilliseconds: MobileBenchmarkClock.milliseconds(since: totalStart),
                    selectedSourceTitle: chatBenchmark.sourceTitle
                )
            }
            isChatResponding = false
            speakAndResumeListening(response)
        } catch {
            isChatResponding = false
            speakAndResumeListening(error.localizedDescription)
        }
    }

    private func endSourceChat(resumeAudio: Bool) async {
        await sourceChat.reset()
        isSourceChatActive = false
        activeChatTitle = nil
        if resumeAudio, currentItem != nil {
            player.playImmediately(atRate: speed)
            isPlaying = true
            updateNowPlayingInfo()
            voice.resetAfterHandledCommand()
        } else {
            speakAndResumeListening("Review stopped.")
        }
    }

    private func playWithSpokenLeadIn(_ item: MobileAudioItem) async {
        speech.stop(owner: .voiceTab)
        voice.resetAfterHandledCommand()
        await play(item)
    }

    private func speakWithoutListening(_ text: String) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.configureAudioSession()
            await self.voice.stop()
            self.speech.speak(text, owner: .voiceTab)
        }
    }

    private func speakAndResumeListening(
        _ text: String,
        pausePlayback: Bool = false,
        resumePlaybackAfterSpeech: Bool = false
    ) {
        if pausePlayback, isPlaying {
            player.pause()
            isPlaying = false
            shouldResumePlaybackAfterSpeech = resumePlaybackAfterSpeech
            updateNowPlayingInfo()
        } else {
            shouldResumePlaybackAfterSpeech = false
        }
        Task { [weak self] in
            guard let self else { return }
            try? await self.configureAudioSession()
            await self.voice.stop()
            self.speech.speak(text, owner: .voiceTab)
        }
    }

    private func resumeAfterSpeech() async {
        if shouldResumePlaybackAfterSpeech {
            shouldResumePlaybackAfterSpeech = false
            if currentItem != nil {
                player.playImmediately(atRate: speed)
                isPlaying = true
                updateNowPlayingInfo()
            }
        }

        guard isSiriVoiceSessionActive || isReviewActive || isSourceChatActive else { return }
        // Our own flags can still say "listening" after another surface took the
        // session mid-sentence; the arbiter is the authority on who may hold a mic.
        guard await MobileAudioSessionArbiter.shared.holds(.voiceTab) else { return }
        await voice.start()
    }

    private func librarySummary() -> String {
        MobileSourceVoiceFormatter.librarySummary(for: allSources)
    }

    private func naturalListPrompt(for utterance: String) -> String {
        MobileSourceVoiceFormatter.listPrompt(for: utterance, sources: allSources)
    }

    private func configureAudioSession() async throws {
        try await MobileAudioSessionArbiter.shared.acquire(.voiceTab, for: .playback)
    }

    private func registerAudioSessionPreemptionIfNeeded() {
        guard !didRegisterAudioSessionPreemption else { return }
        didRegisterAudioSessionPreemption = true
        Task { [weak self] in
            await MobileAudioSessionArbiter.shared.register(.voiceTab) { [weak self] in
                await self?.yieldAudioSession()
            }
        }
    }

    /// Driven by the arbiter when another surface takes the audio session. Half-duplex
    /// is the invariant, so the mic tap and any in-flight speech must be gone before
    /// the session is reconfigured underneath us.
    private func yieldAudioSession() async {
        // The cheap main-actor state settles first; the mic teardown is awaited last
        // so a tab switch landing mid-handoff cannot clobber it on resume. The
        // arbiter awaits this whole handler, so half-duplex still holds.
        speech.stop(owner: .voiceTab)
        shouldResumePlaybackAfterSpeech = false
        if isPlaying {
            player.pause()
            isPlaying = false
            persistPlaybackPosition(force: true)
            updateNowPlayingInfo()
        }
        await voice.stop()
    }

    private nonisolated func audioComposition(
        for urls: [URL]
    ) async throws -> (asset: AVMutableComposition, duration: TimeInterval) {
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MobileAudioPlayerError.couldNotBuildComposition
        }

        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = tracks.first else {
                throw MobileAudioPlayerError.missingAudioTrack(url.lastPathComponent)
            }
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: cursor
            )
            cursor = cursor + duration
        }

        return (composition, cursor.seconds.isFinite ? cursor.seconds : 0)
    }

    private func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
        updateNowPlayingInfo()
    }

    private static func resumeTime(
        from position: ArticleSpeechPlaybackPosition?,
        manifest: SyncedArticleAudioManifest,
        duration: TimeInterval
    ) -> TimeInterval {
        guard let position,
              position.globalTime.isFinite,
              position.globalTime > 0,
              position.contentSignature == nil || position.contentSignature == manifest.contentSignature else {
            return 0
        }
        let clamped = min(position.globalTime, duration)
        return duration - clamped > 5 ? clamped : 0
    }

    private func persistPlaybackPosition(force: Bool) {
        guard let currentItem, duration > 0, currentTime.isFinite else { return }
        let now = Date()
        if !force,
           let lastPlaybackPositionSaveAt,
           now.timeIntervalSince(lastPlaybackPositionSaveAt) < 5 {
            return
        }
        lastPlaybackPositionSaveAt = now

        let sourceID = currentItem.id
        let signature = currentItem.manifest.contentSignature
        let elapsed = min(max(currentTime, 0), duration)

        // Depth rides the same throttle as the position save, exactly as it does
        // on the Mac. A prefix-only opening plays against the prefix's duration
        // rather than the whole source's, so its inflated fraction must never
        // reach the MAX merge that can only ever move forward.
        let fraction = elapsed / duration
        if openingPlaybackSourceID == nil,
           !isAwaitingRemainingNarration,
           shouldRecordDepth(sourceID: sourceID, fraction: fraction) {
            Task { @MainActor [weak self] in
                await self?.recordSourceDepth(
                    sourceID: sourceID,
                    kind: .listening,
                    fraction: fraction
                )
            }
        }

        if duration - elapsed <= 1 {
            clearPlaybackPosition(for: sourceID)
            return
        }
        let position = ArticleSpeechPlaybackPosition(
            globalTime: elapsed,
            appleCharacterOffset: nil,
            contentSignature: signature,
            updatedAt: now
        )
        // A forced save is a pause, a skip, a dismissal, or the app leaving the
        // screen — each the moment a listener is likeliest to pick up the Mac —
        // so it reaches the account at once. Steady playback republishes on
        // the account interval so the other device is never far behind.
        let publishesToAccount = force
            || lastAccountPositionSaveAt.map {
                now.timeIntervalSince($0) >= ListeningPositionSync.accountSaveInterval
            } ?? true
        if publishesToAccount {
            lastAccountPositionSaveAt = now
        }
        Task.detached(priority: .utility) {
            try? SyncedArticleAudioStore.savePlaybackPosition(position, sourceID: sourceID)
            if publishesToAccount {
                await SyncedArticleAudioStore.publishPlaybackPositionToAccount(position, sourceID: sourceID)
            }
        }
    }

    private func clearPlaybackPosition(for sourceID: String) {
        Task.detached(priority: .utility) {
            SyncedArticleAudioStore.clearPlaybackPosition(sourceID: sourceID)
        }
    }

    private func installTimeObserver(for player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if self.isPlaying {
                    self.persistPlaybackPosition(force: false)
                    if self.openingPlaybackSourceID == nil,
                       let playerItem = player.currentItem,
                       let sourceID = self.currentItem?.id,
                       MobileAudioPlaybackCompletion.reachedEnd(
                           elapsed: self.currentTime,
                           duration: self.duration
                       ) {
                        self.finishFullPlaybackIfNeeded(
                            playerItem: playerItem,
                            sourceID: sourceID
                        )
                    }
                }
                self.updateNowPlayingInfo()
            }
        }
    }

    /// One idempotent completion boundary shared by AVPlayer's end notification
    /// and the final periodic clock tick. Temporary opening prefixes never reach
    /// this path: exhausting one means buffering, not finishing the source.
    private func finishFullPlaybackIfNeeded(
        playerItem: AVPlayerItem,
        sourceID: String
    ) {
        let identity = ObjectIdentifier(playerItem)
        guard openingPlaybackSourceID == nil,
              player.currentItem === playerItem,
              currentItem?.id == sourceID,
              completedPlayerItemIdentity != identity else { return }

        completedPlayerItemIdentity = identity
        isPlaying = false
        currentTime = duration
        clearPlaybackPosition(for: sourceID)
        updateNowPlayingInfo()
        Task { @MainActor [weak self] in
            await self?.handleCompletedBookChapter(sourceID: sourceID)
        }
        Task { @MainActor [weak self] in
            await self?.recordSourceConsumption(sourceID: sourceID, kind: .listening)
        }
    }

    private func installRemoteCommandHandlers() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // AirPods and other headset controls can deliver the combined command
        // instead of the discrete play/pause commands. Register all three so a
        // stem press always reaches the text-to-speech transport.
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentItem != nil else { return }
                self.togglePlayback()
            }
            return .success
        }

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isPlaying == false {
                    self?.togglePlayback()
                }
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isPlaying == true {
                    self?.togglePlayback()
                }
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(seconds: 15) }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(seconds: -15) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentItem.title,
            MPMediaItemPropertyArtist: currentItem.subtitle ?? "ForeverLM",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0
        ]
        if let subtitle = currentItem.subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        if let nowPlayingArtwork, nowPlayingArtworkSourceID == currentItem.id {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The picture CarPlay, the lock screen and Control Center show beside the
    /// narration: a chapter's book cover or a paper's first page from the
    /// synced assets the rows already use, an article's artwork, and the
    /// ForeverLM mark when the source has no image. Loaded once per source and
    /// applied only while that source is still the one playing.
    private func loadNowPlayingArtwork(for item: MobileAudioItem) async {
        if nowPlayingArtworkSourceID != item.id {
            nowPlayingArtwork = nil
        }
        nowPlayingArtworkSourceID = item.id
        var image: UIImage?
        if let source = source(for: item.id) {
            image = await MobileSourceArtworkLoader.localArtwork(for: source, collections: collections)
            if image == nil, let artworkURL = source.artworkURL, let url = URL(string: artworkURL),
               url.scheme?.hasPrefix("http") == true {
                let key = "now-playing-artwork:\(url.absoluteString)"
                if let cached = ImageCache.shared.image(for: key) {
                    image = cached
                } else if let (data, _) = try? await URLSession.shared.data(from: url),
                          let downloaded = UIImage(data: data) {
                    ImageCache.shared.set(downloaded, for: key)
                    image = downloaded
                }
            }
        }
        guard let final = image ?? UIImage(named: "BrandMark") else { return }
        guard nowPlayingArtworkSourceID == item.id else { return }
        nowPlayingArtwork = MPMediaItemArtwork(boundsSize: final.size) { _ in final }
        if currentItem?.id == item.id {
            updateNowPlayingInfo()
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

}

enum MobileAudioPlayerError: LocalizedError {
    case couldNotBuildComposition
    case missingAudioTrack(String)

    var errorDescription: String? {
        switch self {
        case .couldNotBuildComposition:
            return "Could not prepare the synced audio for playback."
        case .missingAudioTrack(let fileName):
            return "The audio file \(fileName) does not contain a playable audio track."
        }
    }
}

// MARK: - Hands-free review quiz
//
// This lives in the same file as the view model (not a separate extension file)
// so it can reach the model's private speak/listen helpers — speakAndResumeListening,
// sourceContext(for:), resolveSourceID(_:from:) — which drive the existing
// speak → listen → transcript loop. The quiz reuses that loop: each question is
// spoken, listening resumes, and the next transcript is routed back here as the
// learner's answer.
extension MobileAudioReviewViewModel {
    func startReviewQuiz(sourceID: String?, utterance: String) async {
        let totalStart = Date()
        guard !isReviewActive else { return }
        await beginSiriVoiceSessionIfNeeded()
        // Only the Claude grader needs a managed session. The Apple on-device grader is
        // checked when the engine begins (it fails loudly if unavailable).
        if reviewGrader.requiresAnthropicKey, !hasAnthropicKey {
            speakAndResumeListening(
                MobileReviewError.missingAnthropicKey.errorDescription
                    ?? "Sign in with Apple to run a review.",
                pausePlayback: true,
                resumePlaybackAfterSpeech: false
            )
            await endSiriVoiceSession()
            return
        }

        // Record identity is never inferred from a spoken phrase. Siri/App Intents pass
        // an exact source id; an in-app follow-up may use the source already playing.
        let resolutionStart = Date()
        var resolution = MobileVoiceSourceResolver.resolve(
            sourceID: sourceID,
            utterance: utterance,
            sources: allSources,
            currentSourceID: nil,
            activeVoiceSourceID: nil
        )
        if resolution.strategy == .none {
            if let currentID = currentItem?.id ?? activeVoiceSourceID {
                resolution = MobileVoiceSourceResolution(sourceID: currentID, strategy: .currentSource)
            }
        }
        let sourceResolutionMilliseconds = MobileBenchmarkClock.milliseconds(since: resolutionStart)

        guard let resolved = resolution.sourceID else {
            speakAndResumeListening(
                "I could not tell which source to quiz you on. Ask Siri to quiz you on a specific source.",
                pausePlayback: true,
                resumePlaybackAfterSpeech: false
            )
            return
        }

        // sourceContext speaks its own error (e.g. text not synced yet) and returns nil.
        let sourceTextStart = Date()
        guard let context = await sourceContext(for: resolved) else { return }
        let sourceTextLoadMilliseconds = MobileBenchmarkClock.milliseconds(since: sourceTextStart)

        if isSourceChatActive {
            await sourceChat.reset()
            isSourceChatActive = false
            activeChatTitle = nil
        }
        if isPlaying {
            player.pause()
            isPlaying = false
            updateNowPlayingInfo()
        }

        reviewBrain = MobileReviewGraderFactory.makeEngine(for: reviewGrader)
        await reviewBrain.reset()
        reviewSessionID = Self.makeReviewSessionID()
        reviewTopic = context.title
        reviewSourceID = context.sourceID
        reviewSourceType = context.sourceType
        reviewStartedAt = Date()
        reviewPendingQuestion = nil
        reviewExchanges = []
        isReviewActive = true
        reviewTitle = context.title
        reviewStatus = "Reviewing \(context.title)"
        isChatResponding = true
        Task { [weak self] in
            await self?.recordSourceActivity(sourceID: context.sourceID, kind: .review)
        }

        do {
            let modelStart = Date()
            let turn = try await withReviewSourceUsageAttribution {
                try await reviewBrain.begin(
                    sourceTitle: context.title,
                    sourceText: context.text,
                    topic: context.title
                )
            }
            let firstModelTurnMilliseconds = MobileBenchmarkClock.milliseconds(since: modelStart)
            lastDrivingBenchmark = MobileDrivingVoiceBenchmark(
                utterance: utterance,
                route: "chat",
                sourceResolutionStrategy: resolution.strategy.rawValue,
                sourceResolutionMilliseconds: sourceResolutionMilliseconds,
                sourceTextLoadMilliseconds: sourceTextLoadMilliseconds,
                firstModelTurnMilliseconds: firstModelTurnMilliseconds,
                totalMilliseconds: MobileBenchmarkClock.milliseconds(since: totalStart),
                selectedSourceTitle: context.title
            )
            isChatResponding = false
            reviewPendingQuestion = turn.spoken
            reviewStatus = "Reviewing \(context.title)"
            speakAndResumeListening("Let's review \(context.title). \(turn.spoken)", pausePlayback: false)
        } catch {
            isChatResponding = false
            await cancelReview(speaking: error.localizedDescription)
        }
    }

    private func withReviewSourceUsageAttribution<Result>(
        operation: () async throws -> Result
    ) async rethrows -> Result {
        guard let sourceID = reviewSourceID,
              let sourceType = reviewSourceType else {
            return try await operation()
        }
        return try await AIUsageAttribution.withSource(
            AIUsageSource(
                id: sourceID,
                type: sourceType,
                title: reviewTitle ?? reviewTopic
            ),
            activityID: reviewSessionID ?? UUID().uuidString,
            operation: operation
        )
    }

    func routeReviewUtterance(_ utterance: String) async {
        if Self.isReviewExitCommand(utterance) {
            await finishReviewAtLearnerRequest()
            return
        }
        guard !isChatResponding, let question = reviewPendingQuestion else { return }

        isChatResponding = true
        reviewStatus = "Grading your answer"
        await voice.stop()

        do {
            var turn = try await withReviewSourceUsageAttribution {
                try await reviewBrain.answer(utterance)
            }
            reviewExchanges.append(
                MobileReviewRecordedExchange(
                    question: question,
                    userAnswer: utterance,
                    evaluation: turn.lastEvaluation,
                    score: turn.lastScore,
                    answeredAt: Date()
                )
            )
            if turn.isComplete {
                // A normal answer never authorizes closure. Suppress the
                // model's premature wrap-up and regenerate the next question;
                // only finishReviewAtLearnerRequest may persist/end.
                turn = try await withReviewSourceUsageAttribution {
                    try await reviewBrain.continueAfterPrematureCompletion()
                }
                guard !turn.isComplete else {
                    throw MobileReviewError.badResponse(
                        "The grader tried to end the review before the learner asked to stop."
                    )
                }
            }
            isChatResponding = false
            reviewPendingQuestion = turn.spoken
            reviewStatus = "Reviewing \(reviewTitle ?? "source")"
            speakAndResumeListening(turn.spoken, pausePlayback: false)
        } catch {
            isChatResponding = false
            await cancelReview(speaking: error.localizedDescription)
        }
    }

    /// The model never owns session closure. This path is reachable only after
    /// `isReviewExitCommand` recognized an explicit learner request, and gives
    /// the grader a separate final-verdict turn without misrecording "I'm done"
    /// as an answer to the pending quiz question.
    private func finishReviewAtLearnerRequest() async {
        guard !isChatResponding else { return }

        isChatResponding = true
        reviewStatus = "Saving review"
        await voice.stop()

        do {
            let turn = try await withReviewSourceUsageAttribution {
                try await reviewBrain.finish()
            }
            guard turn.isComplete else {
                throw MobileReviewError.badResponse(
                    "The grader did not return a final verdict after the learner asked to stop."
                )
            }
            isChatResponding = false
            await finalizeReview(turn: turn)
        } catch {
            isChatResponding = false
            errorMessage = error.localizedDescription
            reviewStatus = "Review still open"
            speakAndResumeListening(
                "I couldn't save the review yet. It's still open.",
                pausePlayback: false,
                resumePlaybackAfterSpeech: false
            )
        }
    }

    private func finalizeReview(turn: MobileReviewTurn) async {
        let title = reviewTitle ?? reviewTopic
        // Only the grader's own overall score counts. Averaging the per-turn scores —
        // or falling back to 0 when there are none — would invent a grade, and the Mac
        // reads this field as the source's most recent recall score: a fabricated 0
        // marks the source as failed recall and pulls it forward in the memory-review
        // schedule. MemoryReviewSchedule.intervalDays treats a nil score as ungraded
        // and neutral, which is what an ungraded session actually is. The per-turn
        // scores still ride along on the exchanges, so nothing real is dropped.
        let score = turn.overallScore
        let summary = turn.summary ?? "Completed a hands-free review of \(title)."

        if let sessionID = reviewSessionID,
           let sourceID = reviewSourceID,
           let startedAt = reviewStartedAt {
            // The engine that graded this session, not the grader preference:
            // resetReviewState() has not run yet, so this is still the brain
            // makeEngine(for:) actually handed back at review start.
            do {
                let provenance = try await reviewBrain.provenance()
                var result = MobileReviewResult(
                    sessionID: sessionID,
                    topic: reviewTopic,
                    sourceID: sourceID,
                    goalID: nil,
                    startedAt: startedAt,
                    endedAt: Date(),
                    overallScore: score,
                    summary: summary,
                    exchanges: reviewExchanges,
                    gaps: turn.gaps,
                    knowledgeNote: "Recorded from a hands-free iOS review.",
                    modelProvider: provenance.provider,
                    modelID: provenance.modelID
                )
                result.kind = .review
                try await reviewRecorder.record(result)
                try await MobileCloudMutationService.shared.completeScheduledSource(sourceID: sourceID)
                await load()
            } catch {
                // Never fake a successful save (CLAUDE.md: surface AI/sync failures loudly).
                errorMessage = "This review or its Schedule completion could not be saved yet: \(error.localizedDescription)"
            }
        }

        // No grade, nothing to read out — saying "you scored 0 percent" would be the
        // same invention, just spoken.
        let scoreSentence = score.map { " You scored \(Int((max(0, min(1, $0)) * 100).rounded())) percent." } ?? ""
        let spoken = turn.spoken.isEmpty
            ? "\(summary)\(scoreSentence)"
            : turn.spoken
        resetReviewState()
        await endSiriVoiceSession()
        speakAndResumeListening(spoken, pausePlayback: false)
    }

    func cancelReview(speaking message: String) async {
        await reviewBrain.reset()
        resetReviewState()
        await endSiriVoiceSession()
        speakAndResumeListening(message, pausePlayback: false, resumePlaybackAfterSpeech: false)
    }

    private func resetReviewState() {
        isReviewActive = false
        reviewStatus = nil
        reviewTitle = nil
        reviewPendingQuestion = nil
        reviewSessionID = nil
        reviewSourceID = nil
        reviewSourceType = nil
        reviewStartedAt = nil
        reviewTopic = ""
        reviewExchanges = []
    }

    private static func isReviewExitCommand(_ utterance: String) -> Bool {
        let normalized = utterance.lowercased()
        let phrases = [
            "stop the review", "stop review", "end the review", "end review",
            "stop quizzing", "stop the quiz", "end the quiz", "i'm done",
            "im done", "that's enough", "thats enough", "exit review",
            "quit the review", "cancel the review", "stop the review"
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private static func makeReviewSessionID() -> String {
        "ios-\(UUID().uuidString.lowercased())"
    }
}
