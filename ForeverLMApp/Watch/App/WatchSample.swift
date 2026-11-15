#if DEBUG
import Foundation

// A sample day for screenshots and the Simulator, which has no iPhone to pair
// with: `-foreverlm-watch-sample` loads it instead of talking to the phone.
// `-foreverlm-watch-route cards|listen` opens a screen, and
// `-foreverlm-watch-reveal` shows the first card's back. The sources are real
// public ones, as every product shot uses (never a learner's own library).

enum WatchSample {
    static var isOn: Bool { arguments.contains("-foreverlm-watch-sample") }
    static var revealsBack: Bool { arguments.contains("-foreverlm-watch-reveal") }

    static var route: WatchRoute? {
        guard let index = arguments.firstIndex(of: "-foreverlm-watch-route"), index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "cards": return .cards
        case "listen": return .listen
        default: return nil
        }
    }

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static let cell = "Bioelectric signaling: reprogrammable circuits underlying embryogenesis, regeneration, and cancer"

    static func day(now: Date = Date()) -> WatchDay {
        WatchDay(
            dayKey: "sample",
            sittingKey: "cards-sample",
            cards: [
                WatchCard(
                    itemID: "sample-2",
                    prompt: "What is a resting potential?",
                    back: "The steady voltage across a cell's membrane, set by ion channels and pumps.",
                    why: [],
                    sourceTitle: "Levin · Cell, 2021",
                    isNew: false
                ),
                WatchCard(
                    itemID: "sample-1",
                    prompt: "What tells a cut planarian fragment which end should grow a head?",
                    back: "Its bioelectric pattern: the voltage across the tissue marks one end as head and the other as tail.",
                    why: ["Change the pattern and the same fragment grows two heads, with no change to its genes."],
                    sourceTitle: "Levin · Cell, 2021",
                    isNew: false
                ),
                WatchCard(
                    itemID: "sample-3",
                    prompt: "Why can a two-headed planarian stay two-headed after it is cut again?",
                    back: "The altered voltage pattern is stored and restored at each regeneration: a memory outside the genome.",
                    why: [],
                    sourceTitle: "Levin · J. Physiol., 2014",
                    isNew: true
                ),
                WatchCard(
                    itemID: "sample-4",
                    prompt: "What does a gap junction let neighbouring cells share?",
                    back: "Ions and small molecules, so cells can pool their voltage into a tissue-wide pattern.",
                    why: [],
                    sourceTitle: "Levin · Cell, 2021",
                    isNew: true
                ),
            ],
            bout: WatchBout(title: "Bioelectricity reading", endsAt: now.addingTimeInterval(18 * 60 + 24), isOnBreak: false, needsAttention: false),
            listen: [
                WatchListenItem(sourceID: "sample-cell", title: cell, subtitle: "Cell · 2021", isToday: true),
                WatchListenItem(
                    sourceID: "sample-jphys",
                    title: "Endogenous bioelectrical networks store non-genetic patterning information during development and regeneration",
                    subtitle: "The Journal of Physiology · 2014",
                    isToday: true
                ),
                WatchListenItem(sourceID: "sample-body", title: "The Body Electric", subtitle: "Robert O. Becker · Book", isToday: false),
            ],
            nowPlaying: WatchNowPlaying(sourceID: "sample-cell", title: cell, isPlaying: true, elapsed: 11 * 60 + 42, duration: 38 * 60 + 10, readAt: now),
            updatedAt: now
        )
    }
}
#endif
