import CryptoKit
import Foundation

/// A notebook's suggested questions, kept once they are made
/// (docs/notebooks-design.md, "The notebook guide"). The guide's Suggest
/// questions used to call a model and save a chat every time it was pressed;
/// now the questions its answer suggested stay with the notebook, the guide
/// offers them in every new chat without a model call, a question once asked
/// is not offered again, and new questions are suggested only when the
/// notebook's sources change.
///
/// Kept as one synced preference row per notebook,
/// `notebook.questions.<notebookID>` (a JSON string, the way
/// `notebook.naming.<notebookID>` is kept): per member, so a team's notebook
/// never carries one member's questions, and one row a notebook, so the
/// iPhone can name it from the notebook's id. It is an
/// account Setting the settings catalog leaves out (`leftOut`): only the
/// guide writes it, never `set_app_setting`. Foundation-only, so every client
/// compiles the same rules.
enum NotebookSuggestedQuestions {
    static let preferenceKeyPrefix = "notebook.questions."

    static func preferenceKey(notebookID: String) -> String {
        preferenceKeyPrefix + notebookID
    }

    /// How many questions a notebook keeps, and how many it remembers asked:
    /// a row stays a few hundred bytes, whatever is asked over the years.
    static let maximumQuestions = 6
    static let maximumAsked = 60

    /// What one notebook keeps.
    struct Kept: Codable, Equatable, Sendable {
        /// The notebook's sources when the questions were suggested
        /// (`fingerprint(of:)`).
        var sources: String
        /// The questions suggested for those sources, in their order.
        var questions: [String]
        /// The questions asked in this notebook, newest last: kept across a
        /// change of sources, so a question asked once is never offered again.
        var asked: [String]

        /// The kept questions not asked yet.
        var unasked: [String] {
            let done = Set(asked.map(NotebookSuggestedQuestions.folded))
            return questions.filter { !done.contains(NotebookSuggestedQuestions.folded($0)) }
        }

        /// The row's stored form: a JSON string, which every client reads.
        var encoded: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
                preconditionFailure("Kept notebook questions always encode")
            }
            return text
        }

        /// nil for anything that is not a kept row, which reads as no row.
        static func decoded(_ raw: Any?) -> Kept? {
            guard let text = raw as? String, let data = text.data(using: .utf8),
                  let kept = try? JSONDecoder().decode(Kept.self, from: data),
                  !kept.sources.isEmpty else { return nil }
            return kept
        }
    }

    /// What the guide offers for a notebook whose sources are `fingerprint`.
    enum Offer: Equatable, Sendable {
        /// Nothing kept for these sources: the Suggest questions chip, which
        /// asks a model once.
        case suggest
        /// The kept questions not asked yet, shown as cards; no model call.
        case questions([String])
        /// Every question kept for these sources was asked: nothing new is
        /// suggested until the sources change.
        case askedAll
    }

    static func offer(_ kept: Kept?, sourcesFingerprint fingerprint: String) -> Offer {
        guard let kept, kept.sources == fingerprint, !kept.questions.isEmpty else { return .suggest }
        let unasked = kept.unasked
        return unasked.isEmpty ? .askedAll : .questions(unasked)
    }

    /// The row once a Suggest questions answer suggested `questions` for the
    /// sources `fingerprint`: they replace what was kept, those already
    /// asked left out, and what was asked is remembered. Nil when nothing
    /// is left to keep and nothing was kept before.
    static func keeping(_ questions: [String], sourcesFingerprint fingerprint: String, previous: Kept?) -> Kept? {
        let asked = previous?.asked ?? []
        let done = Set(asked.map(folded))
        var seen = Set<String>()
        let fresh = questions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !done.contains(folded($0)) && seen.insert(folded($0)).inserted }
        guard !fresh.isEmpty || previous != nil else { return nil }
        return Kept(sources: fingerprint, questions: Array(fresh.prefix(maximumQuestions)), asked: asked)
    }

    /// The row once `question` was asked in one of the notebook's chats; nil
    /// when the row is unchanged — no row, or a question it never suggested.
    static func asking(_ question: String, in kept: Kept?) -> Kept? {
        guard var kept else { return nil }
        let key = folded(question)
        guard kept.questions.contains(where: { folded($0) == key }),
              !kept.asked.contains(where: { folded($0) == key }) else { return nil }
        kept.asked.append(question.trimmingCharacters(in: .whitespacesAndNewlines))
        if kept.asked.count > maximumAsked { kept.asked.removeFirst(kept.asked.count - maximumAsked) }
        return kept
    }

    /// The notebook's sources as one value: the same set of ids, in any
    /// order, gives the same fingerprint on every device.
    static func fingerprint(of sourceIDs: some Sequence<String>) -> String {
        let joined = Set(sourceIDs).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// A question as two askings of it compare: case, accents, spacing and
    /// a closing question mark do not make it another question.
    static func folded(_ question: String) -> String {
        var text = question
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        while let last = text.last, last == "?" || last == "." { text.removeLast() }
        return text
    }
}
