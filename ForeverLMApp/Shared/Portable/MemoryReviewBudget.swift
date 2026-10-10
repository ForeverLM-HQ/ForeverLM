#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// How long today's memory review gets, in minutes a day.
///
/// One number the learner sets in Settings → Memory on the Mac or the iPhone,
/// fifteen minutes by default, and the app plans around it in two places:
///
/// - **Sizing.** `CohortSelector` turns the budget into a number of source
///   slots (`sourceSlots(minutes:)`) and fills them, most of them with recent
///   reading and about a third with material due again, so the review that is
///   planned is one that fits rather than one the tutor has to cut short.
/// - **Conduct.** The tutor's briefing names the budget and the time the review
///   started, works breadth first, and names what did not fit when it closes.
///
/// The number follows the account (`SyncedPreferenceKeys.synced`): it is a
/// statement about the learner's day, not about the device they said it on.
/// It is read when a review is planned, so a change applies to the next review
/// that is prepared, never to one already under way.
///
/// Portable: compiled into the iPhone app too, which writes the same synced
/// row through `MobileModelPreferenceStore` and has no local `UserDefaults`
/// view of it; the Mac-side accessor lives with `DailyReviewPreparation`.
enum MemoryReviewBudget {
    /// Synced. Listed in `SyncedPreferenceKeys.synced`.
    static let preferenceKey = "memoryReview.budgetMinutes.v1"

    static let defaultMinutes = 15

    /// What Settings offers. A value outside this list, set by another client
    /// or a future one, is still honoured after clamping.
    static let choices = [5, 10, 15, 20, 30, 45, 60]

    static let minimumMinutes = 5
    static let maximumMinutes = 120

    static func clamp(_ minutes: Int) -> Int {
        min(max(minutes, minimumMinutes), maximumMinutes)
    }

    /// Minutes one source takes at the standard depth: a contour answered in a
    /// sentence or three, its grade and the tutor's reply, and one probe. A
    /// quick source takes less and a deep one more, and the tutor evens that
    /// out live; this is the planning rate, not a promise.
    static let minutesPerSource = 3

    /// How many sources a review of `minutes` covers before bridges. Never
    /// fewer than two, so the shortest budget still keeps both recent reading
    /// and material due again in play.
    static func sourceSlots(minutes: Int) -> Int {
        max(2, clamp(minutes) / minutesPerSource)
    }

    /// Bridges are a connect question at the end, when the budget allows: one
    /// once there is room for five sources, two once there is room for ten.
    static func bridgeSlots(minutes: Int) -> Int {
        let slots = sourceSlots(minutes: minutes)
        if slots >= 10 { return 2 }
        if slots >= 5 { return 1 }
        return 0
    }

    /// What the budget buys, for Settings: "15 minutes is room for about five
    /// sources and one bridge question."
    static func summary(minutes: Int) -> String {
        let slots = sourceSlots(minutes: minutes)
        let bridges = bridgeSlots(minutes: minutes)
        var text = "\(label(minutes)) is room for about \(spelled(slots)) sources"
        switch bridges {
        case 0: text += ", with no bridge question."
        case 1: text += " and one bridge question."
        default: text += " and \(spelled(bridges)) bridge questions."
        }
        return text
    }

    /// Small counts read as words in prose; larger ones as digits.
    private static func spelled(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                     "nineteen", "twenty"]
        return count >= 0 && count < words.count ? words[count] : String(count)
    }

    /// "15 minutes", "1 hour", "1 hour 30 minutes".
    static func label(_ minutes: Int) -> String {
        let clamped = clamp(minutes)
        let hours = clamped / 60
        let rest = clamped % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if rest > 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return parts.joined(separator: " ")
    }
}
