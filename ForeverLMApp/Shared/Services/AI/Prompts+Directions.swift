import Foundation

// The direction search's prompts (docs/directions-design.md), in a file of
// their own because Prompts.swift is also compiled by the iPhone target,
// which has no Directions: the types these name are Mac-only.
extension Prompts {

    /// The steps `find_directions` hands back with its brief: how a chat —
    /// ForeverLM's own or an assistant connected over MCP — looks for
    /// research directions toward one Goal, Notebook or Idea and saves what it
    /// found. Model-facing; the learner reads the chat's answer, not this.
    static func directionSearchSteps(homeKind: DirectionHomeKind, homeID: String, homeTitle: String, focus: String?) -> String {
        let angles = DirectionAngle.allCases
            .filter { $0 != .other }
            .map { "   - \($0.rawValue): \($0.meaning);" }
            .joined(separator: "\n")
        var lines: [String] = []
        lines.append("Direction search for the \(homeKind.noun) “\(homeTitle)” (home_id \(homeID)). A Direction is something the learner could pursue next toward this aim — a specific approach, aimed at a specific population, system or problem, with a reason it is worth a look now. It is not a summary of the field.")
        if let focus, !focus.isEmpty {
            lines.append("The learner asked for: \(focus)")
        }
        lines.append("""
        1. Take stock. Read what this brief lists: the home's standing instructions, its sources (open the ones that matter with get_source_content), the related sources in the library, the learner's Ideas and chats, and every Direction already answered. A pursued Direction says what this learner wants more of; a set-aside one, with its reason, says what they do not want. Propose nothing already listed, even reworded.
        2. Establish the baseline: what is already being done toward this aim — approved and trialled approaches, active programmes and companies, the standard reviews. Use search_literature for the published and preprint record (reviews first, then primary papers), and web search for trial registries, company pipelines and news when this chat can search the web; if it cannot, say that those were not checked. Read before relying on anything: the abstract at least, the paper or page when a claim rests on it. A Direction must go beyond this baseline, not restate it.
        3. Generate candidates from each angle that applies, at least one per angle where the evidence allows:
        \(angles)
        4. Attack every candidate before keeping it. Search for prior art ("has this been tried?") and for the strongest evidence against it, and work out the cheapest experiment, analysis or reading that would tell whether it holds. Drop a candidate that is already being done, that rests on one unreplicated claim and nothing else, or whose only support is that it sounds plausible.
        5. Keep the best three to seven — the ones that would most change what the learner does next — and save them in one propose_directions call with home_id \(homeID). Each needs a title (one sentence naming the specific mechanism or approach and the specific population, system or problem), a rationale (why it is worth a look now, two to four sentences), its angle, evidence (one to five papers or pages you actually opened, each with its citation, its DOI or address, and the one thing it shows for this Direction), the objection (the strongest case against it), and the next_step. Never invent a paper, DOI, address or finding; cite only what you opened.
        6. Answer in the chat: a line or two per Direction, grouped by angle, saying why it is interesting and what would test it; say which angles produced nothing that survived step 4; then ask which to pursue. The learner answers here or in the \(homeKind.noun)'s Directions list. Record an answer given here with update_direction — status pursued or set_aside, with their reason in their own words. Do not add papers to the library yourself: each piece of evidence has Add to Library in the app, and import_paper_from_url is for when the learner asks.
        """)
        return lines.joined(separator: "\n\n")
    }

    /// The model-only block a **Find directions** press sends under the
    /// learner's visible line, so the chat starts from the brief rather than
    /// from what the line alone suggests.
    ///
    /// `learnerCandidate` is what the learner wrote they would try, asked
    /// before the search (Think first): one candidate among the rest, put
    /// through the same attack and kept only if it holds, credited to them.
    static func directionSearchRequest(homeKind: DirectionHomeKind, homeID: String, learnerCandidate: String? = nil) -> String {
        var request = "Direction search request for the \(homeKind.noun) with home_id \(homeID). Call find_directions with that home_id before anything else, then follow the steps it returns."
        if let candidate = learnerCandidate?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty {
            request += " Before this search the learner wrote what they would try, in their words: \u{201C}\(candidate)\u{201D}. Weigh it as one of your candidates: put it through steps 4 and 5 like any other, keep it if it survives (crediting it to them in its rationale), and in your answer say plainly what you found about it, what holds and what does not, without grading or praising it."
        }
        return request
    }
}
