import Foundation

/// How much retrieval support the learner used for one judged answer. The
/// model supplies this structured semantic judgment; deterministic code turns
/// it into scheduling state without parsing feedback prose.
enum MemoryRetrievalQuality: String, Codable, CaseIterable, Equatable, Sendable {
    case independent
    case hinted
    case notRecalled = "not_recalled"
}

enum MemoryTutorGradeMapping {
    /// Invalid scores are rejected by returning nil. Callers must surface that
    /// as a grading/tool error; silently clamping a model's malformed grade
    /// would create evidence the model did not actually author.
    static func rating(
        quality: MemoryRetrievalQuality,
        score: Double
    ) -> MemoryScheduleRating? {
        guard score.isFinite, (0...1).contains(score) else { return nil }
        switch quality {
        case .notRecalled:
            return .again
        case .hinted:
            return .hard
        case .independent where score >= 0.9:
            return .easy
        case .independent where score >= 0.7:
            return .good
        case .independent:
            return .hard
        }
    }

    static func shouldAdvance(
        quality: MemoryRetrievalQuality,
        score: Double
    ) -> Bool {
        guard rating(quality: quality, score: score) != nil else { return false }
        return quality == .independent && score >= 0.7
    }
}

/// A numeric tool argument as JSON actually delivers it.
///
/// `JSONSerialization` hands back every number as an `NSNumber`, and on Darwin
/// an `NSNumber` holding exactly 0 or 1 bridges to `Bool`, so the once-common
/// `!(value is Bool)` guard rejected a score of 0 (nothing recalled) and 1 (a
/// perfect answer) while letting 0.5 through. A boolean is told apart by its
/// encoding instead: JSON `true`/`false` arrive as `c`, numbers as `q` or `d`.
enum ToolArgumentNumber {
    /// The argument as a double, or nil for a boolean, a string, null, or a
    /// missing key. Range and finiteness are the caller's rule to state.
    static func value(_ argument: Any?) -> Double? {
        guard let number = argument as? NSNumber, !isBoolean(number) else { return nil }
        return number.doubleValue
    }

    /// How a rejected argument is read back to the model: what arrived, in
    /// words it can act on.
    static func describe(_ argument: Any?) -> String {
        switch argument {
        case nil:
            return "nothing (the key was omitted)"
        case is NSNull:
            return "null"
        case let number as NSNumber:
            return isBoolean(number) ? "the boolean \(number.boolValue)" : "the number \(number)"
        case let string as String:
            return "the string \"\(string)\""
        case let other?:
            return "a value of type \(type(of: other))"
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        let encoding = String(cString: number.objCType)
        return encoding == "c" || encoding == "B"
    }
}
