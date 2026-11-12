import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether what is in front of the learner serves the goal they set: Apple's
/// on-device model, asked once per new thing in front.
///
/// The one model in the Mac app that is not an `AITask` routed through
/// OpenRouter, deliberately: the product owner chose it for Nudge Me Back on
/// Track (2026-11-08) over a paid model asked on a timer, which the rule
/// against unattended model spending forbids (2026-10-15). It runs on the
/// Mac, bills nothing, sends nothing anywhere, and has no setting to pick.
/// When it cannot run (no Apple Intelligence, an older macOS) the watcher
/// says so and does not watch: there is no other judge to fall back to.
actor FocusJudge {
    enum Availability: Equatable, Sendable {
        case available
        case unavailable(String)
    }

    enum JudgeError: LocalizedError {
        case unavailable(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason), .failed(let reason): return reason
            }
        }
    }

    static let shared = FocusJudge()

    /// Verdicts already given, by goal and thing in front: switching back to
    /// a tab already judged asks nothing. Cleared when the goal changes.
    private var verdicts: [String: Bool] = [:]
    private var verdictsGoal: FocusGoal?
    private static let verdictLimit = 200

    static func availability() -> Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable("This Mac does not support Apple Intelligence, which judges what is in front on the Mac itself.")
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Turn on Apple Intelligence in System Settings: it judges what is in front on the Mac itself.")
                case .modelNotReady:
                    return .unavailable("Apple Intelligence is still downloading its model.")
                @unknown default:
                    return .unavailable("Apple Intelligence is unavailable right now.")
                }
            @unknown default:
                return .unavailable("Apple Intelligence is unavailable right now.")
            }
        }
        #endif
        return .unavailable("Needs macOS 26 or later with Apple Intelligence.")
    }

    /// True when `scene` serves `goal`. `readScreen`, when given, reads the
    /// words in the window in front (`FocusScreenReader`); it is called only
    /// when the window has not been judged under this goal, so the screen is
    /// read once per new thing in front, not on every look.
    func isOnTrack(
        _ scene: FocusScene,
        goal: FocusGoal,
        readScreen: (@Sendable () async -> String?)? = nil
    ) async throws -> Bool {
        if verdictsGoal != goal {
            verdicts = [:]
            verdictsGoal = goal
        }
        if let known = verdicts[scene.verdictKey] { return known }
        let screenText = await readScreen?()
        let verdict = try await ask(scene: scene, goal: goal, screenText: screenText)
        if verdicts.count >= Self.verdictLimit { verdicts.removeAll() }
        verdicts[scene.verdictKey] = verdict
        return verdict
    }

    private func ask(scene: FocusScene, goal: FocusGoal, screenText: String?) async throws -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .unavailable(let reason) = Self.availability() { throw JudgeError.unavailable(reason) }
            // A fresh session per question: each verdict stands alone, and a
            // transcript of the learner's afternoon is kept nowhere.
            let session = LanguageModelSession(instructions: Self.instructions)
            do {
                let verdict = try await session.respond(
                    to: Prompt(Self.prompt(scene: scene, goal: goal, screenText: screenText)),
                    generating: FocusVerdict.self
                ).content
                return verdict.onTrack
            } catch {
                throw JudgeError.failed("Apple Intelligence could not judge \(scene.displayName): \(error.localizedDescription)")
            }
        }
        #endif
        throw JudgeError.unavailable("Needs macOS 26 or later with Apple Intelligence.")
    }

    static let instructions = """
    You decide whether what a learner has in front of them on their Mac serves what they set out to do right now.
    On track: anything that works on the goal or supports it — its sources, papers, notes, writing, a search or a page \
    or a video about its topic, the tools the work needs (an editor, a terminal, a reference manager, a calculator), \
    and a quick look at the calendar or a timer.
    Off track: social feeds, news, shopping, sport, games, entertainment, chatting or email about other things, and \
    pages or videos on unrelated topics.
    Judge by the topic, not by the site: a lecture on YouTube about the goal is on track, the YouTube home feed is not.
    When the words in the window are given, judge by them: they say what the window is about better than its title. \
    A chat or a mailbox is on track only when its words are about the goal.
    When you cannot tell, answer on track.
    """

    /// How much of the window's words the judge reads: enough to know the
    /// topic, little enough to keep each verdict quick.
    static let screenTextLimit = 600

    static func prompt(scene: FocusScene, goal: FocusGoal, screenText: String? = nil) -> String {
        var lines = ["Goal: \(goal.title)"]
        if !goal.context.isEmpty {
            lines.append("About the goal: \(goal.context.prefix(6).joined(separator: "; "))")
        }
        lines.append("App in front: \(scene.appName)")
        if let title = scene.windowTitle { lines.append("Window title: \(String(title.prefix(200)))") }
        if let page = scene.pageText { lines.append("Page: \(page)") }
        let words = (screenText ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !words.isEmpty { lines.append("Words in the window: \(String(words.prefix(Self.screenTextLimit)))") }
        return lines.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)
/// The verdict's shape, settled by asking the on-device model 16 cases
/// against "Read the ESM3 paper". A plain on/off answer judged
/// the paper's own explainer on YouTube and its Wikipedia topic off track; a
/// three-way category scored 7–10 of 16; this shape — name the topic, then
/// two questions, off track only when it is a distraction and not the goal's
/// subject — scored 13–14 of 16 run after run. What it still gets wrong is a
/// music app or a neighbouring topic's video judged a distraction.
@available(macOS 26.0, *)
@Generable
struct FocusVerdict {
    @Guide(description: "What the window or page is about, in a few words, from its title and address.")
    var topic: String
    @Guide(description: "true when that topic is the same subject as the goal, or part of it.")
    var sameSubject: Bool
    @Guide(description: "true only when the topic has nothing to do with the goal: a feed or home page, news, shopping, sport, games, films and shows, or chat and email about other things. An app the work uses — an editor, a terminal, a search, the calendar, a timer, music to work to — is never a distraction, whatever its title.")
    var distraction: Bool

    /// Off track only when it is a distraction and not the goal's subject:
    /// a missed drift costs less than a nudge the learner did not earn.
    var onTrack: Bool { sameSubject || !distraction }
}
#endif
