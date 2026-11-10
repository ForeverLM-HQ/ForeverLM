import AppIntents
import CoreSpotlight
import Foundation
import OSLog

// Apple Intelligence / Siri AI integration.
//
// Exposes ForeverLM sources as App Entities so Siri AI can resolve a spoken
// reference ("quiz me on the cancer-vaccine article") to a specific source, and —
// on iOS 18+ — indexes them into Spotlight's semantic index so the match works
// from vague, meaning-based phrasing. This is Apple's recommended path; see
// https://developer.apple.com/documentation/appintents/apple-intelligence-and-siri-ai
//
// The entity carries the real source_id, which QuizSourceIntent passes
// straight through to MobileAudioReviewViewModel.startReviewQuiz(sourceID:) for an
// exact match (no fuzzy guessing).
struct SourceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Source")
    static let defaultQuery = SourceEntityQuery()

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

    init(id: String, title: String, subtitle: String?, sourceType: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sourceType = sourceType
    }

    init(source: MobileCloudSource) {
        self.init(id: source.id, title: source.title, subtitle: source.subtitle, sourceType: source.sourceType)
    }
}

// IndexedEntity (the Spotlight semantic index) is iOS 18+. The AppEntity above still
// works on iOS 17 via the string query below; this conformance just adds the
// semantic booster on newer systems.
@available(iOS 18.0, *)
extension SourceEntity: IndexedEntity {}

// Resolves source entities for Siri/Apple Intelligence, backed by the same on-device
// CloudKit catalog the rest of the voice companion uses.
struct SourceEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SourceEntity] {
        let byID = Dictionary(
            (await MobileSiriSourceCatalog.loadSources()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { byID[$0] }.map(SourceEntity.init(source:))
    }

    func entities(matching string: String) async throws -> [SourceEntity] {
        // Entity resolution may not silently guess record identity. Spotlight's
        // IndexedEntity integration supplies semantic discovery on supported OSes;
        // this fallback accepts only an exact normalized display title.
        let sources = await MobileSiriSourceCatalog.loadSources()
        let query = Self.exactKey(string)
        return sources.filter { Self.exactKey($0.title) == query }
            .map(SourceEntity.init(source:))
    }

    func suggestedEntities() async throws -> [SourceEntity] {
        (await MobileSiriSourceCatalog.loadSources())
            .prefix(30)
            .map(SourceEntity.init(source:))
    }

    private static func exactKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Pushes sources into Spotlight's semantic index so Apple Intelligence can find them
// by meaning. iOS 18+ only (IndexedEntity); a no-op below that.
@available(iOS 18.0, *)
enum SourceSpotlightIndexer {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "SourceSpotlightIndexer")

    static func index(_ sources: [MobileCloudSource]) async {
        guard !sources.isEmpty else { return }
        let entities = sources.map(SourceEntity.init(source:))
        do {
            try await CSSearchableIndex.default().indexAppEntities(entities)
        } catch {
            // Discoverability booster only — a failed index never breaks a review.
            logger.error("Spotlight indexAppEntities failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
