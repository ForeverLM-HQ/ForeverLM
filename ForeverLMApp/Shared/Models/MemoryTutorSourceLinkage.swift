import CryptoKit
import Foundation

/// One kind of learner-driven interaction with a source. These values are stored
/// as durable SQLite rows and travel inside the source's ScheduledSource payload,
/// so older clients safely ignore them while newer clients can reconstruct an
/// honest day-by-day activity history.
enum SourceActivityKind: String, Codable, CaseIterable, Hashable, Sendable {
    case reading
    case listening
    case watching
    case chat
    case review
}

/// A compact daily aggregate rather than an event-per-scroll/callback log. One
/// source can have one row per local calendar day, with interaction kinds unioned
/// and first/last timestamps retained for deterministic cross-device merging.
struct SourceActivityDay: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let dayStart: Date
    var firstActivityAt: Date
    var lastActivityAt: Date
    var kinds: Set<SourceActivityKind>
    var completedKinds: Set<SourceActivityKind>
    /// Deepest point of the source reached on this day, as a 0...1 fraction of
    /// its content. Merges across devices with MAX, exactly as `kinds` merges
    /// with OR, so a day split between phone and Mac keeps the furthest point.
    ///
    /// 0 means *unmeasured*, not "read nothing": rows written before v66, and
    /// modalities that expose no position, legitimately have no depth. Read it
    /// through `hasMeasuredDepth` before treating it as evidence.
    var maxFraction: Double

    var hasCompletion: Bool { !completedKinds.isEmpty }

    /// A completion is depth 1.0 whatever the position tracking managed to see:
    /// finishing a podcast is proof the whole thing was played, even though the
    /// player may only have sampled to 0.98 before the track ended.
    var effectiveFraction: Double {
        hasCompletion ? 1 : maxFraction
    }

    var hasMeasuredDepth: Bool { effectiveFraction > 0 }

    /// Seconds the learner actually spent with the source on this day (schema
    /// 94): the reader heartbeat while frontmost, playback time from the
    /// players. Accrues locally by addition and merges across devices with MAX,
    /// which undercounts a day split between two devices rather than counting
    /// a synced day twice. 0 means *unmeasured* on rows written before the
    /// column existed; read time through `engagedTime`.
    var engagedSeconds: Double

    /// The time evidence for this day. Measured seconds when there are any;
    /// otherwise the span between the first and last activity, which is what
    /// rows from before the heartbeat have to offer. A row with a single
    /// event has a span of zero, and that is the honest answer for it.
    var engagedTime: TimeInterval {
        if engagedSeconds > 0 { return engagedSeconds }
        return max(0, lastActivityAt.timeIntervalSince(firstActivityAt))
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceID, dayStart, firstActivityAt, lastActivityAt
        case kinds, completedKinds, maxFraction, engagedSeconds
    }

    init(
        id: String,
        sourceID: String,
        dayStart: Date,
        firstActivityAt: Date,
        lastActivityAt: Date,
        kinds: Set<SourceActivityKind>,
        completedKinds: Set<SourceActivityKind>,
        maxFraction: Double = 0,
        engagedSeconds: Double = 0
    ) {
        self.id = id
        self.sourceID = sourceID
        self.dayStart = dayStart
        self.firstActivityAt = firstActivityAt
        self.lastActivityAt = lastActivityAt
        self.kinds = kinds
        self.completedKinds = completedKinds
        self.maxFraction = maxFraction
        self.engagedSeconds = SourceActivityDay.clampSeconds(engagedSeconds)
    }

    /// `maxFraction` and `engagedSeconds` are decoded leniently so an older
    /// device's ScheduledSource payload keeps decoding here instead of failing
    /// the whole activity list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        dayStart = try container.decode(Date.self, forKey: .dayStart)
        firstActivityAt = try container.decode(Date.self, forKey: .firstActivityAt)
        lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        kinds = try container.decode(Set<SourceActivityKind>.self, forKey: .kinds)
        completedKinds = try container.decode(Set<SourceActivityKind>.self, forKey: .completedKinds)
        maxFraction = SourceActivityDay.clampFraction(
            try container.decodeIfPresent(Double.self, forKey: .maxFraction) ?? 0
        )
        engagedSeconds = SourceActivityDay.clampSeconds(
            try container.decodeIfPresent(Double.self, forKey: .engagedSeconds) ?? 0
        )
    }

    /// A day has 86 400 seconds; nothing engaged can exceed it, and a NaN or a
    /// negative from a clock jump must never reach the additive merge.
    static func clampSeconds(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 86_400)
    }

    /// Time spent across one source's activity days, for `SourceConsumptionSignals`.
    static func engagedSeconds(in days: [SourceActivityDay]) -> Double {
        days.reduce(0) { $0 + $1.engagedTime }
    }

    /// One place decides what a storable fraction is, so a NaN from a zero-length
    /// audio duration or an over-1 estimate from progressive generation can never
    /// reach SQLite and poison the MAX merge.
    static func clampFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// The kinds that mean the learner went through the material itself, as
    /// opposed to talking about it or being quizzed on it.
    static let consumptionKinds: Set<SourceActivityKind> = [.reading, .listening, .watching]

    /// Deepest point reached across one source's activity days, and the day it
    /// was reached. This is the value-level twin of the `MAX(...)` /
    /// `last_activity_at` pair the macOS first-review intake computes in SQL, so
    /// a client reading activity out of synced ScheduledSource payloads dates
    /// depth-only consumption exactly as the Mac's own query does.
    static func deepestPoint(in days: [SourceActivityDay]) -> (fraction: Double, reachedAt: Date)? {
        let deepest = days.max { lhs, rhs in
            if lhs.effectiveFraction != rhs.effectiveFraction {
                return lhs.effectiveFraction < rhs.effectiveFraction
            }
            return lhs.lastActivityAt < rhs.lastActivityAt
        }
        guard let deepest else { return nil }
        return (deepest.effectiveFraction, deepest.lastActivityAt)
    }

    /// When the learner last read, listened to, or watched this source. Chat and
    /// review days are excluded: those are attention paid to the *concept*, and
    /// the review queue already accounts for them separately.
    static func lastConsumedAt(in days: [SourceActivityDay]) -> Date? {
        days
            .filter { !$0.kinds.isDisjoint(with: consumptionKinds) }
            .map(\.lastActivityAt)
            .max()
    }
}

/// App-owned identity for the one initial concept trace a source can acquire.
/// Deriving this from canonical source identity (not a device, session, model, or
/// prompt) makes simultaneous phone/Mac intake converge on one row. A divergent
/// curriculum under that identity is rejected atomically by storage.
enum MemoryTutorIdentity {
    static let firstReviewVersion = 2

    /// Stable source identity used by first-review curriculum on every device.
    /// Prefer publication identity over a device-local SQLite ID; the exact ID
    /// is deliberately only the final fallback for sources without a portable
    /// DOI or URL (for example, a local note).
    static func portableSourceKey(
        sourceID: String,
        normalizedURL: String? = nil,
        doi: String? = nil,
        publishedDOI: String? = nil
    ) -> String {
        let field: String
        if let publishedDOI = normalizedDOI(publishedDOI) {
            field = "doi:\(publishedDOI)"
        } else if let doi = normalizedDOI(doi) {
            field = "doi:\(doi)"
        } else if let normalizedURL = cleaned(normalizedURL) {
            field = "url:\(normalizedURL)"
        } else {
            field = "source-id:\(sourceID)"
        }
        return digestID(namespace: "memory-source-v1", fields: [field])
    }

    static func firstReviewItemID(portableSourceKey: String) -> String {
        digestID(
            namespace: "memory-first-review-v\(firstReviewVersion)",
            fields: [portableSourceKey]
        )
    }

    static func firstReviewAnchorID(
        memoryItemID: String,
        sortIndex: Int = 0
    ) -> String {
        digestID(
            namespace: "memory-anchor-v\(firstReviewVersion)",
            fields: [memoryItemID, String(sortIndex)]
        )
    }

    /// One walkthrough question of one source, as a Memory item: the same on
    /// every device, so two Macs grading the same card converge on one item.
    /// The question's words are part of it, so a walk written again asks a
    /// new question as a new item rather than scoring the old one.
    static func walkthroughQuestionItemID(portableSourceKey: String, stepID: String, question: String) -> String {
        digestID(
            namespace: "memory-walkthrough-question-v1",
            fields: [portableSourceKey, stepID, question.trimmingCharacters(in: .whitespacesAndNewlines)]
        )
    }

    /// A kept card, as a Memory item: one per card id, which is minted when
    /// the card is drafted (`MemoryCard.cardID`), so two Macs keeping the same
    /// draft converge on one item. A card started over is a new card id, and
    /// so a new item. Cards kept when they were missed keep their question's
    /// own id (`walkthroughQuestionItemID`), the items from before cards
    /// among them.
    static func cardItemID(cardID: String) -> String {
        digestID(
            namespace: "memory-card-v1",
            fields: [cardID.trimmingCharacters(in: .whitespacesAndNewlines)]
        )
    }

    /// A self-graded answer to one card in one sitting (`sessionKey`, the
    /// caller's id for the sitting): the same for every answer to that card in
    /// that sitting, so a card answered again ("Review forgotten") is written
    /// once (`KnowledgeStore.recordSelfGradedMemoryCardAttempt`).
    static func selfGradedAttemptID(sessionKey: String, memoryItemID: String) -> String {
        digestID(
            namespace: "memory-self-graded-v1",
            fields: [
                sessionKey.trimmingCharacters(in: .whitespacesAndNewlines),
                memoryItemID.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        )
    }

    /// One cross-device identity for a source's global Schedule placement. Both
    /// phone and Mac use this only when no existing placement has synced yet;
    /// concurrent creation therefore converges on the same CloudKit record.
    static func scheduledSourcePlacementID(portableSourceKey: String) -> String {
        digestID(
            namespace: "scheduled-source-v1",
            fields: [portableSourceKey]
        )
    }

    /// Stable identity for one source's activity on one absolute local-day
    /// boundary. The source placement already owns portable cross-device source
    /// identity, while the timestamp preserves the day on which the interaction
    /// actually happened.
    static func sourceActivityDayID(portableSourceKey: String, dayStart: Date) -> String {
        digestID(
            namespace: "source-activity-day-v1",
            fields: [portableSourceKey, String(dayStart.timeIntervalSinceReferenceDate)]
        )
    }

    /// Local-only fallback retained for sources that truly have no portable
    /// identity. Production intake should obtain a portable key from storage or
    /// a synced source payload and call `firstReviewItemID(portableSourceKey:)`.
    static func firstReviewItemID(sourceID: String) -> String {
        firstReviewItemID(portableSourceKey: portableSourceKey(sourceID: sourceID))
    }

    /// Source IDs do not participate in anchor identity. This overload keeps
    /// older callers source-compatible while producing the portable v2 ID.
    static func firstReviewAnchorID(
        memoryItemID: String,
        sourceID _: String,
        sortIndex: Int = 0
    ) -> String {
        firstReviewAnchorID(memoryItemID: memoryItemID, sortIndex: sortIndex)
    }

    /// Create-once convergence contract shared by Mac, iPhone, MCP, and SQLite.
    /// Device-local discovery times are intentionally excluded; once the same
    /// deterministic ID exists, its stored timestamps remain authoritative.
    static func hasSameImmutableCurriculum(
        _ lhs: MemoryItem,
        _ rhs: MemoryItem
    ) -> Bool {
        immutableCurriculumFingerprint(lhs)
            == immutableCurriculumFingerprint(rhs)
    }

    /// Portable snapshot token for optimistic curriculum validation at attempt
    /// commit. Source SQLite IDs are deliberately excluded: an anchor may remap
    /// to the same portable Source while a review is open without changing what
    /// the learner was asked. Anchor identity/content and the rubric remain part
    /// of the token, so a server-winner curriculum swap fails before evidence or
    /// transcript state is mutated.
    static func immutableCurriculumFingerprint(_ item: MemoryItem) -> String {
        var fields = [
            item.id,
            item.kind.rawValue,
            item.target,
            item.rubricJSON,
            item.goalID ?? "",
        ]
        for anchor in canonicalAnchors(item.sources) {
            fields.append(anchor.id)
            fields.append(String(anchor.sortIndex))
            fields.append(anchor.locatorJSON ?? "")
            fields.append(anchor.excerpt)
            fields.append(anchor.sourceSHA256)
        }
        return digestID(namespace: "memory-curriculum-v1", fields: fields)
    }

    private static func digestID(namespace: String, fields: [String]) -> String {
        var bytes = Data(namespace.utf8)
        for field in fields {
            bytes.append(0)
            bytes.append(contentsOf: field.utf8)
        }
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(namespace)-\(digest)"
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func normalizedDOI(_ value: String?) -> String? {
        cleaned(value)?.lowercased()
    }

    private static func canonicalAnchors(
        _ anchors: [MemoryItemSource]
    ) -> [MemoryItemSource] {
        anchors.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.id < $1.id
        }
    }
}

/// The deterministic source relationship projection shared by session writers.
/// An item may carry several excerpts from one source; a ReviewSession links
/// the source once, in the order of the item's canonical anchors.
enum MemoryTutorSourceLinkage {
    static func orderedSourceIDs(for item: MemoryItem) -> [String] {
        let anchors = item.sources.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.id < $1.id
        }
        return anchors.reduce(into: [String]()) { result, anchor in
            guard !result.contains(anchor.sourceID) else { return }
            result.append(anchor.sourceID)
        }
    }
}

/// One day's activity on one source, joined to enough of the source to render a
/// row: the History pane's unit of display.
///
/// This is deliberately *not* the schedule's item type. History records what the
/// app observed — that a source was opened, played, discussed, or reviewed on a
/// given day — and says nothing about whether it was planned or finished.
struct SourceConsumptionEntry: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let dayStart: Date
    let firstActivityAt: Date
    let lastActivityAt: Date
    let kinds: Set<SourceActivityKind>
    let completedKinds: Set<SourceActivityKind>
    let maxFraction: Double
    /// Nil when the source has since been deleted; the row still stands as
    /// evidence of the day, so it renders with a placeholder rather than
    /// vanishing from the record.
    let title: String?
    let sourceType: String?
    let domain: String?
    let groupTitle: String?
    let isArchived: Bool
    /// Measured time with the source that day; 0 on rows from before schema 94.
    var engagedSeconds: Double = 0

    var effectiveFraction: Double {
        completedKinds.isEmpty ? maxFraction : 1
    }

    /// The day's time evidence, measured seconds or the activity span.
    var engagedTime: TimeInterval {
        if engagedSeconds > 0 { return engagedSeconds }
        return max(0, lastActivityAt.timeIntervalSince(firstActivityAt))
    }

    /// Whether the learner went through the material itself on this day, rather
    /// than only talking about it or being quizzed on it.
    var isConsumption: Bool {
        !kinds.isDisjoint(with: SourceActivityDay.consumptionKinds)
    }
}
