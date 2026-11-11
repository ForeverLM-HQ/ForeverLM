import Foundation

// The Mac-only edges of the memory review models: the preference store the
// per-type review depth lives in, and the SQLite exchange record. The models
// themselves are Foundation-only and compiled into the phone; these
// extensions are not, so the phone supplies the same values from its own
// stores instead.

extension MemoryReviewDepth {
    /// The chosen default for a kind of source, or nil when none was chosen.
    static func typeDefault(sourceType: String) -> MemoryReviewDepth? {
        Preferences.value(typeKey(sourceType: sourceType))
            .flatMap(MemoryReviewDepth.init(rawValue:))
    }

    /// Sets or clears the default for a kind of source. Written through
    /// `PreferenceStore` so the other devices hear "keep podcasts quick" too.
    static func setTypeDefault(_ depth: MemoryReviewDepth?, sourceType: String) {
        let key = typeKey(sourceType: sourceType)
        if let depth {
            Preferences.set(depth.rawValue, for: key)
        } else {
            Preferences.reset(key)
        }
    }

    /// The row of a kind of source, named as `typePreferenceKey(sourceType:)` names it.
    private static func typeKey(sourceType: String) -> AccountKey<String?> {
        Prefs.Families.reviewDepthByType.key(sourceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The depth a source is reviewed at: its own, else its type's, else the
    /// fallback, with the type default read from this Mac's preferences.
    static func effective(sourceDepth: MemoryReviewDepth?, sourceType: String) -> MemoryReviewDepth {
        effective(sourceDepth: sourceDepth, typeDefault: typeDefault(sourceType: sourceType))
    }
}

extension MemoryReviewSourceStatus {
    static func statuses(
        from exchanges: [ReviewExchangeRecord],
        topics: [MemoryReviewTopic] = []
    ) -> [String: MemoryReviewSourceStatus] {
        statuses(from: exchanges.map {
            GradedExchange(
                sequenceNumber: $0.sequenceNumber,
                ideaCoverage: $0.ideaCoverage,
                questionVerdict: $0.questionVerdict,
                answeredAt: $0.answeredAt,
                operation: $0.operation
            )
        }, topics: topics)
    }
}
