import Foundation

// MARK: - Working notes (docs/planner-design.md, "The day is planned from a running log")
//
// What ForeverLM remembers about how the learner is working, kept as many small
// notes rather than one growing page: one sentence each, with a kind, the
// sources it came from, when it was written and last recalled, and an
// on-device embedding. A chat is handed the few notes nearest what it is
// about (`WorkingNoteRanking`), not all of them; a background pass writes new
// ones from the day's activity and merges or retires old ones
// (`WorkingNoteOps`, `WorkingNoteConsolidation`). The working log Doc stays
// the readable summary on top.
//
// Not "Memory": that is the spaced-repetition review. These are notes about
// the learner's own work.

enum WorkingNoteKind: String, Codable, CaseIterable, Sendable {
    /// A line of work in progress: "reading the NAD+ papers for Berlin".
    case thread
    /// A topic they keep coming back to.
    case interest
    /// How they like things done: "wants a review after every paper".
    case preference
    /// Something true about their situation: "Berlin conference on Oct 21".
    case fact
    /// Something finished or learned: "finished the half-center oscillator paper".
    case outcome
}

struct WorkingNote: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var kind: WorkingNoteKind
    /// One sentence, in the learner's own terms. Short enough to embed whole:
    /// the on-device model reads 256 tokens and drops the rest.
    var text: String
    var sourceIDs: [String]
    let createdAt: Date
    var updatedAt: Date
    var lastRecalledAt: Date?
    var recallCount: Int
    /// Local derived data, never the truth: recomputed when `embeddingModel`
    /// is not the current model, and absent until it is first computed.
    var vector: [Float]?
    var embeddingModel: String?

    static let maximumTextCharacters = 400

    init(
        id: String = UUID().uuidString,
        kind: WorkingNoteKind,
        text: String,
        sourceIDs: [String] = [],
        now: Date
    ) {
        self.id = id
        self.kind = kind
        self.text = Self.cleaned(text)
        self.sourceIDs = sourceIDs
        self.createdAt = now
        self.updatedAt = now
        self.lastRecalledAt = nil
        self.recallCount = 0
        self.vector = nil
        self.embeddingModel = nil
    }

    /// Whitespace folded and the length bounded, at a word where it can be.
    static func cleaned(_ text: String) -> String {
        let folded = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard folded.count > maximumTextCharacters else { return folded }
        let head = String(folded.prefix(maximumTextCharacters))
        return head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
    }

    /// What two notes are compared by when asking whether they say the same.
    var normalizedText: String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Recall

/// Which notes a chat is handed. Rank-fused, never thresholded: the on-device
/// contextual embedding is anisotropic (unrelated texts score 0.78–0.93), so
/// an absolute cosine cutoff means nothing (`EmbeddingSettings`).
///
/// Three rankings are fused by reciprocal rank: closeness to the query (when
/// there is a query vector and the note has one), recency of the last write or
/// recall, and how often the note has been useful. Closeness counts double;
/// the other two keep a fresh thread findable when the query is vague and let
/// a note that keeps being recalled outlast one that never is.
enum WorkingNoteRanking {
    static let fusionConstant = 60.0

    static func rank(
        _ notes: [WorkingNote],
        queryVector: [Float]?,
        embeddingModel: String,
        topK: Int
    ) -> [WorkingNote] {
        guard topK > 0, !notes.isEmpty else { return [] }

        var scores = [String: Double]()
        func fuse(_ ordered: [WorkingNote], weight: Double) {
            for (index, note) in ordered.enumerated() {
                scores[note.id, default: 0] += weight / (fusionConstant + Double(index + 1))
            }
        }

        if let queryVector, !queryVector.isEmpty {
            let similar = notes
                .compactMap { note -> (WorkingNote, Float)? in
                    guard note.embeddingModel == embeddingModel, let vector = note.vector,
                          vector.count == queryVector.count else { return nil }
                    return (note, dot(queryVector, vector))
                }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
                .map(\.0)
            fuse(similar, weight: 2)
        }
        fuse(
            notes.sorted { lastTouched($0) != lastTouched($1) ? lastTouched($0) > lastTouched($1) : $0.id < $1.id },
            weight: 1
        )
        fuse(
            notes.filter { $0.recallCount > 0 }
                .sorted { $0.recallCount != $1.recallCount ? $0.recallCount > $1.recallCount : $0.id < $1.id },
            weight: 0.5
        )

        return notes
            .sorted {
                let a = scores[$0.id] ?? 0, b = scores[$1.id] ?? 0
                return a != b ? a > b : $0.id < $1.id
            }
            .prefix(topK)
            .map { $0 }
    }

    static func lastTouched(_ note: WorkingNote) -> Date {
        max(note.updatedAt, note.lastRecalledAt ?? .distantPast)
    }

    /// Cosine similarity of two L2-normalized vectors (`AppleTextEmbedder`
    /// returns them so): the dot product.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }
}

// MARK: - What the extraction pass may do

/// The operations a model proposes after reading the day's activity and the
/// notes nearest it. Decoded leniently and applied only after `validated`:
/// an id the model made up, an empty sentence or an unknown kind is dropped,
/// not guessed at.
struct WorkingNoteOps: Decodable, Equatable, Sendable {
    struct Addition: Decodable, Equatable, Sendable {
        let kind: String
        let text: String
        let sourceIDs: [String]

        enum CodingKeys: String, CodingKey { case kind, text, sourceIDs = "source_ids" }

        init(kind: String, text: String, sourceIDs: [String] = []) {
            self.kind = kind
            self.text = text
            self.sourceIDs = sourceIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            text = try container.decode(String.self, forKey: .text)
            sourceIDs = try container.decodeIfPresent([String].self, forKey: .sourceIDs) ?? []
        }
    }

    struct Revision: Decodable, Equatable, Sendable {
        let id: String
        let text: String
    }

    var add: [Addition]
    var update: [Revision]
    var forget: [String]

    static let empty = WorkingNoteOps(add: [], update: [], forget: [])

    init(add: [Addition], update: [Revision], forget: [String]) {
        self.add = add
        self.update = update
        self.forget = forget
    }

    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case add, update, forget }
        let container = try decoder.container(keyedBy: Keys.self)
        add = try container.decodeIfPresent([Addition].self, forKey: .add) ?? []
        update = try container.decodeIfPresent([Revision].self, forKey: .update) ?? []
        forget = try container.decodeIfPresent([String].self, forKey: .forget) ?? []
    }

    /// One run writes a handful of notes; more than this is a model that did
    /// not understand the job, and the rest is dropped.
    static let maximumAdditions = 12

    /// Only what can be applied to `existing`.
    func validated(against existing: [WorkingNote]) -> WorkingNoteOps {
        let known = Set(existing.map(\.id))
        var seenUpdates = Set<String>()
        return WorkingNoteOps(
            add: add
                .filter { WorkingNoteKind(rawValue: $0.kind) != nil && !WorkingNote.cleaned($0.text).isEmpty }
                .prefix(Self.maximumAdditions)
                .map { $0 },
            update: update.filter {
                known.contains($0.id) && !WorkingNote.cleaned($0.text).isEmpty && seenUpdates.insert($0.id).inserted
            },
            forget: Array(Set(forget.filter { known.contains($0) })).sorted()
        )
    }

    var isEmpty: Bool { add.isEmpty && update.isEmpty && forget.isEmpty }
}

// MARK: - Consolidation

/// Keeps the store small and honest without a model call: the same sentence
/// written twice is one note, a line of work nobody has touched for two
/// months is over, and the store is bounded. What needs judgement — two
/// differently worded notes that say one thing, a fact that is no longer
/// true — is the extraction pass's job (`WorkingNoteOps.forget` and
/// `.update`), because it sees the notes beside the day's activity.
enum WorkingNoteConsolidation {
    /// A thread nobody recalled or rewrote in this long has ended.
    static let threadLifetime: TimeInterval = 60 * 86_400
    static let maximumNotes = 200

    static func consolidate(_ notes: [WorkingNote], now: Date) -> [WorkingNote] {
        // The same sentence twice: the older note takes the newer's kind and
        // sources, and keeps its recall history.
        var byText = [String: WorkingNote]()
        var order = [String]()
        for note in notes.sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = note.normalizedText
            guard !key.isEmpty else { continue }
            if var kept = byText[key] {
                kept.kind = note.kind
                kept.sourceIDs = Array(Set(kept.sourceIDs + note.sourceIDs)).sorted()
                kept.updatedAt = max(kept.updatedAt, note.updatedAt)
                kept.recallCount += note.recallCount
                if let recalled = note.lastRecalledAt {
                    kept.lastRecalledAt = max(kept.lastRecalledAt ?? .distantPast, recalled)
                }
                byText[key] = kept
            } else {
                byText[key] = note
                order.append(key)
            }
        }
        var result = order.compactMap { byText[$0] }.filter { note in
            note.kind != .thread || now.timeIntervalSince(WorkingNoteRanking.lastTouched(note)) < threadLifetime
        }
        if result.count > maximumNotes {
            result.sort { WorkingNoteRanking.lastTouched($0) > WorkingNoteRanking.lastTouched($1) }
            result = Array(result.prefix(maximumNotes))
        }
        return result.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
    }
}

// MARK: - The switch

/// Whether ForeverLM keeps notes about the learner's work at all: writes them
/// the learner adds or asks for, hands the nearest to every chat, and carries
/// the running log in a chat's prompt. On unless switched off; off, nothing new is
/// written or sent and what exists is kept until the learner forgets it.
/// Synced (`SyncedPreferenceKeys`): a statement about the learner, not the
/// Mac it was said on.
enum WorkingNotesPreference {
    static let enabledKey = "workingNotes.enabled.v1"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledKey) as? NSNumber)?.boolValue ?? true
    }

    static var isEnabled: Bool { isEnabled(defaults: .standard) }

    static func setEnabled(_ enabled: Bool) {
        PreferenceStore.set(enabled, forKey: enabledKey)
    }
}

// MARK: - The record that carries the notes to another Mac

/// The notes as a background record, "Working notes" (id `working-notes`,
/// never listed: `WorkingMemoryRecords`): one bullet per note,
/// `- thread: Reading the NAD+ papers`. The record syncs, the JSON file does
/// not, so this is how a second Mac gets the notes. A line changed there
/// corrects a note, a line gone forgets it, and a new line (with or without
/// its kind) teaches one. The record owns what a note says and which notes
/// exist; each Mac's file keeps what only it knows (vectors, recall counts,
/// when). The learner edits the notes in Settings, never here.
///
/// Merging is by sentence, not id. The file remembers which sentences it last
/// wrote into the record (`exported`): one the record has lost since was
/// forgotten (here or on another Mac); one the record never held is new on
/// this Mac and is written out.
enum WorkingNoteMirror {
    static let docID = WorkingMemoryRecords.notesID
    static let docTitle = "Working notes"
    static let heading = "## Working notes"

    struct Line: Equatable, Sendable {
        let kind: WorkingNoteKind
        let text: String
    }

    static func render(_ notes: [WorkingNote]) -> String {
        let order = Dictionary(uniqueKeysWithValues: WorkingNoteKind.allCases.enumerated().map { ($1, $0) })
        let sorted = notes.sorted {
            let a = order[$0.kind] ?? 0, b = order[$1.kind] ?? 0
            if a != b { return a < b }
            return $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id
        }
        let body = sorted.map { "- \($0.kind.rawValue): \($0.text)" }.joined(separator: "\n")
        return body.isEmpty ? "" : body + "\n"
    }

    /// The bullets of a body, in order. A bullet starting with a kind and a
    /// colon takes that kind; any other is a fact. Headings, blank lines and
    /// prose are ignored, and a bullet with no sentence is dropped.
    static func parse(_ markdown: String) -> [Line] {
        var lines: [Line] = []
        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { continue }
            var content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            var kind = WorkingNoteKind.fact
            if let colon = content.firstIndex(of: ":"),
               let named = WorkingNoteKind(rawValue: content[..<colon].lowercased()) {
                kind = named
                content = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            let text = WorkingNote.cleaned(content)
            if !text.isEmpty { lines.append(Line(kind: kind, text: text)) }
        }
        return lines
    }

    /// The notes after reading the Doc's lines. `exported` is the normalized
    /// sentences last written into the Doc.
    static func merge(
        local: [WorkingNote],
        doc: [Line],
        exported: Set<String>,
        now: Date
    ) -> [WorkingNote] {
        var byText = [String: WorkingNote]()
        for note in local { byText[note.normalizedText] = byText[note.normalizedText] ?? note }

        var result: [WorkingNote] = []
        var seen = Set<String>()
        for line in doc {
            let probe = WorkingNote(kind: line.kind, text: line.text, now: now)
            let key = probe.normalizedText
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if var existing = byText[key] {
                existing.kind = line.kind
                result.append(existing)
            } else {
                result.append(probe)
            }
        }
        for note in local {
            let key = note.normalizedText
            guard !seen.contains(key) else { continue }
            // Written into the Doc before and gone from it now: deleted there.
            if exported.contains(key) { continue }
            seen.insert(key)
            result.append(note)
        }
        return result
    }
}
