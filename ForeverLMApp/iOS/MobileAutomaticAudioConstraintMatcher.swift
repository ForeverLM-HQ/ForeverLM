// Matches a spoken constraint against the automatic audio filters.

import AVFoundation
import Combine
import CryptoKit
import MediaPlayer
import OSLog
import SwiftUI
import CloudKit
import SQLite3
import WidgetKit

enum AutomaticAudioConstraintControl: Error {
    case noConstraints
}

enum MobileAutomaticAudioConstraintMatcher {
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
