import Foundation

/// Selects the newest saved source for direct Siri and CarPlay shortcuts. Voice
/// search has the same newest-first contract, but keeping this deterministic
/// avoids asking an LLM to decide identity for the dedicated "latest paper"
/// action.
enum MobileLatestSourceSelector {
    static func latest(
        in sources: [MobileCloudSource],
        sourceType: String? = nil
    ) -> MobileCloudSource? {
        let normalizedType = sourceType.map(canonicalSourceType)
        return sources
            .filter { source in
                normalizedType == nil || canonicalSourceType(source.sourceType) == normalizedType
            }
            .enumerated()
            .max { lhs, rhs in
                if lhs.element.dateAdded != rhs.element.dateAdded {
                    return lhs.element.dateAdded < rhs.element.dateAdded
                }
                // Preserve catalog order when timestamps tie.
                return lhs.offset > rhs.offset
            }?
            .element
    }
}

struct MobileVoiceSourceResolution: Equatable {
    enum Strategy: String, Equatable {
        case explicitID
        case currentSource
        case none
    }

    let sourceID: String?
    let strategy: Strategy
}

enum MobileVoiceSourceResolver {
    static func resolve(
        sourceID: String?,
        utterance _: String,
        sources: [MobileCloudSource],
        currentSourceID: String?,
        activeVoiceSourceID: String?
    ) -> MobileVoiceSourceResolution {
        if let sourceID, sources.contains(where: { $0.id == sourceID }) {
            return MobileVoiceSourceResolution(sourceID: sourceID, strategy: .explicitID)
        }

        if let currentSourceID {
            return MobileVoiceSourceResolution(sourceID: currentSourceID, strategy: .currentSource)
        }

        if let activeVoiceSourceID {
            return MobileVoiceSourceResolution(sourceID: activeVoiceSourceID, strategy: .currentSource)
        }

        return MobileVoiceSourceResolution(sourceID: nil, strategy: .none)
    }

}
