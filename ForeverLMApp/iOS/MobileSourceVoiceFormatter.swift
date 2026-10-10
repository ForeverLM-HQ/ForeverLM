import Foundation

enum MobileSourceVoiceFormatter {
    static func librarySummary(for sources: [MobileCloudSource]) -> String {
        if sources.isEmpty {
            return "No synced sources are available yet."
        }
        if sources.count == 1 {
            return "One source is available in your library."
        }
        let readyAudio = sources.filter(\.hasAudio).count
        if readyAudio == 0 {
            return "\(sources.count) sources are synced, but none have generated audio yet."
        }
        if readyAudio == sources.count {
            return "\(sources.count) sources are ready for playback."
        }
        return "\(sources.count) sources are available, with \(readyAudio) ready for playback."
    }

    static func listPrompt(for utterance: String, sources: [MobileCloudSource]) -> String {
        let normalized = utterance.lowercased()
        guard sources.contains(where: { !$0.isArchived }) else {
            return librarySummary(for: sources)
        }

        let candidates = filteredSources(for: normalized, sources: sources)

        guard !candidates.isEmpty else {
            return "I don't see a matching source yet."
        }

        let defaultLimit = requestedSourceDefaultLimit(from: normalized)
        let displayLimit = defaultLimit ?? 8
        let entries = candidates.prefix(displayLimit).enumerated().map { index, source in
            let extras = [
                source.sourceType,
                source.hasAudio ? "audio ready" : "no audio yet"
            ]
            .joined(separator: ", ")
            return "Number \(index + 1): \(source.title) (\(extras))"
        }.joined(separator: ". ")
        let extra = candidates.count > displayLimit ? ". There are \(candidates.count - displayLimit) more matches." : ""

        if let sourceType = requestedSourceType(from: normalized) {
            if let limit = defaultLimit {
                return "Here are the last \(min(limit, candidates.count)) \(sourceType) sources: \(entries)\(extra)"
            }
            return "I found \(candidates.count) \(sourceType) sources: \(entries)\(extra)"
        }

        if let term = requestedSearchTerm(from: normalized) {
            return "I found \(candidates.count) sources for \(term): \(entries)\(extra)"
        }

        return "Here are your latest sources: \(entries)\(extra)"
    }

    private static func filteredSources(
        for utterance: String,
        sources: [MobileCloudSource]
    ) -> [MobileCloudSource] {
        let all = sources.filter { !$0.isArchived }
        let requestedType = requestedSourceType(from: utterance)
        let searchTerm = requestedSearchTerm(from: utterance)

        var filtered = all
        if let requestedType {
            filtered = filtered.filter {
                normalizedSourceType($0.sourceType) == requestedType
            }
        }

        if let searchTerm {
            filtered = filtered.filter { source in
                sourceMatches(term: searchTerm, source: source)
            }
        }

        if let limit = requestedSourceDefaultLimit(from: utterance) {
            return filtered
                .sorted { $0.dateAdded > $1.dateAdded }
                .prefix(limit)
                .map { $0 }
        }

        return filtered
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    private static func requestedSourceType(from utterance: String) -> String? {
        let lower = utterance.lowercased()
        if lower.contains("article") {
            return "article"
        }
        if lower.contains("paper") {
            return "paper"
        }
        if lower.contains("podcast") {
            return "podcast"
        }
        if lower.contains("book") {
            return "book"
        }
        if lower.contains("video") {
            return "video"
        }
        if lower.contains("manual") {
            return "article"
        }
        if lower.contains("unclassified") {
            return "article"
        }
        return nil
    }

    private static func normalizedSourceType(_ sourceType: String) -> String {
        canonicalSourceType(sourceType)
    }

    private static func requestedSourceDefaultLimit(from utterance: String) -> Int? {
        if let explicit = requestedSourceLimit(from: utterance) {
            return explicit
        }

        if lowerHasLastRequest(utterance) {
            return 5
        }

        return nil
    }

    private static func sourceMatches(term: String, source: MobileCloudSource) -> Bool {
        let normalized = term
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })

        guard !normalized.isEmpty else { return true }

        let haystack = [source.title, source.subtitle ?? "", source.sourceType]
            .joined(separator: " ")
            .lowercased()

        return normalized.allSatisfy { token in
            haystack.contains(token)
        }
    }

    private static func requestedSourceLimit(from utterance: String) -> Int? {
        let pattern = #"\b(?:last|top|first)\s+(\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(location: 0, length: utterance.utf16.count)
        guard let match = regex.firstMatch(in: utterance, options: [], range: range),
              let range = Range(match.range(at: 1), in: utterance) else {
            return nil
        }

        let parsed = Int(utterance[range])
        return parsed.flatMap { max(1, min($0, 50)) }
    }

    private static func lowerHasLastRequest(_ utterance: String) -> Bool {
        utterance.contains("last") || utterance.contains("most recent")
    }

    private static func requestedSearchTerm(from utterance: String) -> String? {
        let phrases = [" for ", " about ", " with ", " related to "]
        for phrase in phrases {
            if let range = utterance.range(of: phrase) {
                let suffix = String(utterance[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if suffix.count > 2 {
                    return suffix
                }
            }
        }

        return nil
    }
}
