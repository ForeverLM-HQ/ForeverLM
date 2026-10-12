import Foundation

// MARK: - Suggested questions for a chat opened from the Canvas (docs/heptabase-canvas-parity.md, "AI on the whiteboard")
//
// Heptabase starts a chat about a board with a few questions to ask. A chat
// opened beside a canvas (Ask in Chat, a canvas made from sources) offers
// three, drawn from what the learner wrote on it: their Ideas'
// sentences and their regions' names, in templates. No model is asked; a
// canvas with nothing written on it offers none.

enum KnowledgeMapSuggestedQuestions {
    /// How many questions the chat offers.
    static let limit = 3
    /// A title longer than this is cut at a word, so a question stays a line or two.
    static let titleCharacters = 60

    /// The questions for a canvas whose Ideas read `ideas` and whose regions
    /// are named `regions`, each most relevant first (the selected ones
    /// first, then the rest in reading order). The same canvas always
    /// gives the same questions. At most `limit`, fewer when the canvas
    /// gives too little to ask about.
    static func questions(ideas: [String], regions: [String]) -> [String] {
        let ideas = cleaned(ideas)
        let regions = cleaned(regions)
        var out: [String] = []
        func add(_ question: String?) {
            guard let question, out.count < limit, !out.contains(question) else { return }
            out.append(question)
        }
        func connects(_ a: Int, _ b: Int) -> String? {
            ideas.indices.contains(a) && ideas.indices.contains(b) ? "What connects “\(ideas[a])” and “\(ideas[b])”?" : nil
        }
        func leavesOpen(_ index: Int) -> String? {
            regions.indices.contains(index) ? "What does “\(regions[index])” leave open?" : nil
        }
        add(connects(0, 1))
        add(leavesOpen(0))
        add(ideas.first.map { "What in my sources best supports “\($0)”?" })
        add(regions.count >= 2 ? "How do “\(regions[0])” and “\(regions[1])” fit together?" : nil)
        add(connects(1, 2))
        add(leavesOpen(1))
        add(ideas.first.map { "Where do my sources disagree about “\($0)”?" })
        add(regions.first.map { "What is the strongest evidence in “\($0)”?" })
        return out
    }

    /// Words as one line each, none empty, none twice (case aside), each at most
    /// `titleCharacters` characters (cut at a word, marked …).
    static func cleaned(_ titles: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for title in titles {
            let flat = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !flat.isEmpty, seen.insert(flat.lowercased()).inserted else { continue }
            out.append(cut(flat))
        }
        return out
    }

    private static func cut(_ text: String) -> String {
        guard text.count > titleCharacters else { return text }
        var kept = String(text.prefix(titleCharacters - 1))
        if let space = kept.lastIndex(of: " ") { kept = String(kept[..<space]) }
        return kept.trimmingCharacters(in: CharacterSet(charactersIn: ",;:—–- ")) + "…"
    }
}
