import Foundation

/// The Map's levels of abstraction, written by the Map Summaries model
/// (`AITask.mapSummaries`, docs/knowledge-map-design.md): each cluster's gist
/// for when the learner is zoomed far out and its thread for closer in, and a
/// caption for what is on screen. Clusters are a notebook's cards waiting on
/// the shore, or a region the learner drew; a summary is kept against the
/// cluster's fingerprint (its name and cards) and written again only when that
/// changes.
enum KnowledgeMapSummaries {
    /// A cluster as the model reads it.
    struct Cluster: Equatable, Sendable {
        /// `nb:<notebook name>` or `r:<region id>`.
        var key: String
        var name: String
        var titles: [String]
        /// For a notebook's frame, what the notebook says beside its titles
        /// (`KnowledgeMapModel.notebookContext`); its takeaways are written from it.
        var context: String = ""

        /// What the summary was written from; a change asks for a new one.
        var fingerprint: String {
            let base = name + "\u{1F}" + titles.sorted().joined(separator: "\u{1E}")
            return context.isEmpty ? base : base + "\u{1D}" + context
        }
    }

    struct Summary: Codable, Equatable, Sendable {
        var short: String
        var long: String
        var fingerprint: String
        /// A notebook frame's takeaways, read when the Canvas is zoomed out to
        /// the bigger story: what the learner comes away with, in a few lines.
        /// nil for a region that is not a notebook's.
        var takeaways: [String]? = nil
    }

    /// What is on screen, as the model reads it.
    struct View: Equatable, Sendable {
        var level: String
        var regions: [String]
        var cards: [String]
    }

    /// Most clusters summarized in one call, and most titles read per cluster.
    static let clustersPerCall = 12
    static let titlesPerCluster = 40
    /// A cluster smaller than this needs no summary: its cards say it.
    static let minimumCards = 3
    /// Most takeaways kept for a notebook's frame.
    static let maximumTakeaways = 4

    static func clustersMessage(_ clusters: [Cluster]) -> String {
        let entries: [[String: Any]] = clusters.map {
            var entry: [String: Any] = ["key": $0.key, "name": $0.name, "titles": Array($0.titles.prefix(titlesPerCluster))]
            if !$0.context.isEmpty { entry["notebook"] = $0.context }
            return entry
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["clusters": entries], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func viewMessage(_ view: View) -> String {
        let object: [String: Any] = ["view": ["zoom_level": view.level, "regions_in_view": view.regions, "cards_in_view": view.cards]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    enum ParseError: Error { case unreadable }

    /// The model's summaries by cluster key; an entry missing a line or
    /// naming a key that was not asked for is dropped.
    static func summaries(from response: String, asked: [Cluster]) throws -> [String: Summary] {
        guard let object = jsonObject(response), let list = object["clusters"] as? [[String: Any]] else {
            throw ParseError.unreadable
        }
        let byKey = Dictionary(asked.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Summary] = [:]
        for entry in list {
            guard let key = entry["key"] as? String, let cluster = byKey[key],
                  let short = (entry["short"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !short.isEmpty else { continue }
            let long = (entry["long"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let takeaways = (entry["takeaways"] as? [Any] ?? [])
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(maximumTakeaways)
            result[key] = Summary(
                short: short,
                long: long.isEmpty ? short : long,
                fingerprint: cluster.fingerprint,
                takeaways: cluster.context.isEmpty || takeaways.isEmpty ? nil : Array(takeaways)
            )
        }
        return result
    }

    static func caption(from response: String) throws -> String {
        guard let object = jsonObject(response),
              let caption = (object["caption"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !caption.isEmpty else { throw ParseError.unreadable }
        return caption
    }

    /// The JSON object in a reply, tolerating a fenced block around it.
    private static func jsonObject(_ response: String) -> [String: Any]? {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    // MARK: The device's cache

    /// Summaries already written, by cluster key, kept on this Mac so the Map
    /// opens with them. Derived and rewritable: nothing syncs it.
    static let cacheKey = "knowledgeMap.summaryCache.v1"

    static func loadCache(_ defaults: UserDefaults = .standard) -> [String: Summary] {
        guard let data = defaults.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode([String: Summary].self, from: data) else { return [:] }
        return cache
    }

    static func saveCache(_ cache: [String: Summary], _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: cacheKey)
    }
}

extension AIService {
    /// One call for up to `clustersPerCall` clusters' summaries.
    func knowledgeMapClusterSummaries(
        _ clusters: [KnowledgeMapSummaries.Cluster],
        config: AITaskConfig
    ) async throws -> [String: KnowledgeMapSummaries.Summary] {
        let system = AITask.mapSummaries.effectivePrompt ?? Prompts.mapSummaries
        let response = try await call(
            config: config,
            system: system,
            user: KnowledgeMapSummaries.clustersMessage(clusters),
            maxTokens: clusters.reduce(0) { $0 + ($1.context.isEmpty ? 220 : 420) },
            temperature: 0.3,
            jsonMode: true,
            sourceTitle: "Canvas",
            subjectID: "map"
        )
        do {
            return try KnowledgeMapSummaries.summaries(from: response, asked: clusters)
        } catch {
            throw AIError.invalidResponse
        }
    }

    /// A caption for what is on screen.
    func knowledgeMapViewCaption(
        _ view: KnowledgeMapSummaries.View,
        config: AITaskConfig
    ) async throws -> String {
        let system = AITask.mapSummaries.effectivePrompt ?? Prompts.mapSummaries
        let response = try await call(
            config: config,
            system: system,
            user: KnowledgeMapSummaries.viewMessage(view),
            maxTokens: 200,
            temperature: 0.3,
            jsonMode: true,
            sourceTitle: "Canvas",
            subjectID: "map"
        )
        do {
            return try KnowledgeMapSummaries.caption(from: response)
        } catch {
            throw AIError.invalidResponse
        }
    }
}
