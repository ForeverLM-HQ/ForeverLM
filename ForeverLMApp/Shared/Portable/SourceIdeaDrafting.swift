#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// What the extraction model returns for one idea, before the app gives it
/// identity. Decoded on every client that extracts.
struct SourceIdeaDraft: Decodable, Equatable, Sendable {
    let statement: String
    let recallNote: String
    let anchors: [String]

    private enum CodingKeys: String, CodingKey {
        case statement
        case recallNote = "recall_note"
        case anchors
    }

    init(statement: String, recallNote: String, anchors: [String]) {
        self.statement = statement
        self.recallNote = recallNote
        self.anchors = anchors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statement = try container.decode(String.self, forKey: .statement)
        recallNote = try container.decodeIfPresent(String.self, forKey: .recallNote) ?? ""
        anchors = try container.decodeIfPresent([String].self, forKey: .anchors) ?? []
    }
}

struct SourceIdeaExtractionResponse: Decodable {
    let ideas: [SourceIdeaDraft]
}

/// Why a source could not be turned into ideas, in the words the tutor and
/// the Settings receipt show. Shared so the phone's preparation fails the same
/// way the Mac's does.
enum SourceIdeaExtractionError: LocalizedError, Sendable {
    case noConfiguredModel
    case noReadableText(String)
    case noIdeas(String)
    /// The model failed on this exact text earlier today; see
    /// `SourceIdeaExtractionFailures`.
    case recentlyFailed(String, String)
    /// The source is a notebook's audio overview: a spoken retelling of
    /// other sources, whose own ideas are what is remembered.
    case retelling(String)

    var errorDescription: String? {
        switch self {
        case .noConfiguredModel:
            return "Idea Extraction has no configured model. Check your OpenRouter key and plan in Settings."
        case .noReadableText(let title):
            return "\(title) has no readable text to extract ideas from."
        case .noIdeas(let title):
            return "No ideas could be extracted from \(title)."
        case .recentlyFailed(let title, let message):
            return "\(title) could not be turned into ideas earlier today (\(message)). It will be tried again tomorrow."
        case .retelling(let title):
            return "\(title) is an audio overview that retells its notebook's sources; their own ideas are what is reviewed."
        }
    }
}

/// Turning a source's text into its ideas, identically on every client.
///
/// The model drafts; the app decides identity. `SourceIdea.id` is derived from
/// the source, the hash of the text it was read from, and the position, so the
/// Mac and the phone extracting the same text arrive at the same ids — and a
/// grade recorded on one device names ideas the other device recognises.
enum SourceIdeaDrafting {

    /// Which part of a source one extraction call reads, when the text is
    /// longer than the model's window takes in one request (`sourceTextParts`).
    struct Part: Equatable, Sendable {
        /// Zero-based, in source order.
        let index: Int
        let count: Int
    }

    /// The hash every client stamps on a source's ideas: SHA-256 of the UTF-8
    /// text, hex. The Mac's `PaperContentPreparationService.sha256` is this.
    /// The website compiles this file to WebAssembly, where there is no
    /// CryptoKit, so the digest is computed in Swift there; `PortableSHA256`
    /// is the same function and the two are pinned equal by test.
    static func contentHash(_ text: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return PortableSHA256.hexDigest(of: Array(text.utf8))
        #endif
    }

    /// How much of a source extraction read until 2026-09-30, while it stamped
    /// the hash of the whole text. Ideas on a longer source made before then
    /// match its hash yet may leave its tail out, so a reader that needs the
    /// whole source (an audio overview) does not take them for it. A record of
    /// what old builds did, not a limit on reading.
    static let singleReadCharacterLimit = 240_000

    /// The extraction request's user message: title, type, the learner's own
    /// highlights, then the text — all of the text it is given. Nothing here
    /// cuts it (product owner, 2026-09-23: source text is never truncated). Until
    /// 2026-09-30 only the first 240,000 characters were sent while the ideas
    /// were stamped with the hash of the whole text. A source longer than the
    /// model's window takes in one request is read in consecutive parts
    /// (`sourceTextParts`), and `part` says which one this request carries.
    static func userMessage(
        title: String,
        sourceType: String,
        highlightLines: [String],
        sourceText: String,
        part: Part? = nil
    ) -> String {
        var user = """
        SOURCE TITLE: \(title)
        SOURCE TYPE: \(sourceType)
        """
        if !highlightLines.isEmpty {
            user += "\n\nTHE LEARNER'S OWN HIGHLIGHTS:\n"
            user += highlightLines.prefix(CohortSourceBrief.maxHighlights).map { "- \($0)" }.joined(separator: "\n")
        }
        if let part {
            user += "\n\nSOURCE TEXT, PART \(part.index + 1) OF \(part.count) (the source is read in consecutive parts, each in a request of its own; write down the ideas this part makes):\n\(sourceText)"
        } else {
            user += "\n\nSOURCE TEXT:\n\(sourceText)"
        }
        return user
    }

    /// The text in consecutive parts of at most `characterBudget` characters
    /// each, which together are exactly the text: nothing is dropped and
    /// nothing repeated. A part ends after the last paragraph break in its
    /// stretch, else the last line break, else the last space, provided that
    /// falls in the stretch's second half, so parts rarely stop mid-sentence
    /// and there are never many more of them than the length requires. Only a
    /// stretch with no break in its second half is cut at the budget. A nil
    /// budget (the model publishes no window), or a text that fits, is one
    /// part.
    static func sourceTextParts(_ text: String, characterBudget: Int?) -> [String] {
        guard let characterBudget, characterBudget > 0 else { return [text] }
        var parts: [String] = []
        var rest = Substring(text)
        while let limit = rest.index(rest.startIndex, offsetBy: characterBudget, limitedBy: rest.endIndex),
              limit < rest.endIndex {
            let midpoint = rest.index(rest.startIndex, offsetBy: characterBudget / 2)
            var paragraphEnd: String.Index?
            var lineEnd: String.Index?
            var spaceEnd: String.Index?
            var cursor = limit
            while cursor > midpoint {
                let previous = rest.index(before: cursor)
                let character = rest[previous]
                if character.isNewline {
                    if lineEnd == nil { lineEnd = cursor }
                    if previous > rest.startIndex, rest[rest.index(before: previous)].isNewline {
                        paragraphEnd = cursor
                        break
                    }
                } else if character.isWhitespace, spaceEnd == nil {
                    spaceEnd = cursor
                }
                cursor = previous
            }
            let end = paragraphEnd ?? lineEnd ?? spaceEnd ?? limit
            parts.append(String(rest[rest.startIndex..<end]))
            rest = rest[end...]
        }
        parts.append(String(rest))
        return parts
    }

    /// The drafts of a source read in parts, as one list. When the parts
    /// together drafted no more distinct ideas than a source keeps
    /// (`SourceIdea.maximumPerSource`) they are all kept, in source order.
    /// Past that, the parts take turns — each part's first draft, then each
    /// part's second — until the limit, so the end of a long source is heard
    /// as well as its opening, and what is kept stays in source order. A
    /// statement an earlier part already drafted counts once, as `ideas`
    /// counts it. One part's drafts come back as they are.
    static func mergedDrafts(_ parts: [[SourceIdeaDraft]], limit: Int = SourceIdea.maximumPerSource) -> [SourceIdeaDraft] {
        guard parts.count > 1 else { return parts.first ?? [] }
        var seen = Set<String>()
        let distinct: [[SourceIdeaDraft]] = parts.map { drafts in
            drafts.filter { draft in
                let key = normalized(draft.statement)
                return !key.isEmpty && seen.insert(key).inserted
            }
        }
        guard distinct.reduce(0, { $0 + $1.count }) > limit else { return distinct.flatMap { $0 } }
        var kept = Array(repeating: 0, count: distinct.count)
        var remaining = limit
        var rank = 0
        while remaining > 0 {
            var tookOne = false
            for partIndex in distinct.indices where remaining > 0 && rank < distinct[partIndex].count {
                kept[partIndex] += 1
                remaining -= 1
                tookOne = true
            }
            guard tookOne else { break }
            rank += 1
        }
        return distinct.indices.flatMap { distinct[$0].prefix(kept[$0]) }
    }

    /// A highlight as the extraction and the briefing show it: the quote, and
    /// the learner's note when they wrote one, behind a tag for what its color
    /// means once the learner has used colors (`SourceHighlightColor`). The
    /// marks they set aside to follow up or doubt come first, so the cap on how
    /// many a prompt takes (`CohortSourceBrief.maxHighlights`) never drops the
    /// ones they meant to come back to; then the noted ones, then the newest.
    static func highlightLines(_ highlights: [SourceHighlight]) -> [String] {
        let marks = highlights.filter { !$0.isBareSlideMark }
        let tagged = SourceHighlightColor.learnerChoseColors(in: marks)
        return marks
            .sorted { lhs, rhs in
                if lhs.color.isOpenItem != rhs.color.isOpenItem { return lhs.color.isOpenItem }
                if lhs.hasNote != rhs.hasNote { return lhs.hasNote }
                return lhs.createdAt > rhs.createdAt
            }
            .map { mark in
                let line = mark.note.isEmpty ? mark.quote : "\(mark.quote) — THEIR OWN NOTE: \(mark.note)"
                return tagged ? "\(mark.color.promptTag) \(line)" : line
            }
    }

    /// Gives drafts their deterministic identity and weights them by attention:
    /// an idea anchored on a highlighted passage is `wanted`. Pure, so it is
    /// tested without a model.
    ///
    /// `originSessionID` names the chat an idea was born in, when the "source"
    /// is a conversation rather than a text (`ReviewableChat`).
    static func ideas(
        from drafts: [SourceIdeaDraft],
        sourceID: String,
        contentHash: String,
        highlights: [SourceHighlight],
        originSessionID: String? = nil,
        now: Date = Date()
    ) -> [SourceIdea] {
        var result: [SourceIdea] = []
        var seenStatements = Set<String>()
        for draft in drafts {
            let statement = draft.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty, seenStatements.insert(normalized(statement)).inserted else { continue }
            guard result.count < SourceIdea.maximumPerSource else { break }
            var wanted = false
            let anchors: [SourceIdeaAnchor] = draft.anchors
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(3)
                .map { quote in
                    let highlight = highlights.first { overlaps($0.quote, quote) }
                    if highlight != nil { wanted = true }
                    return SourceIdeaAnchor(quote: String(quote.prefix(400)), highlightID: highlight?.id)
                }
            if !wanted, highlights.contains(where: { overlaps($0.quote, statement) || overlaps($0.note, statement) }) {
                wanted = true
            }
            result.append(SourceIdea(
                id: SourceIdea.id(sourceID: sourceID, contentHash: contentHash, index: result.count),
                sourceID: sourceID,
                statement: statement,
                recallNote: draft.recallNote.trimmingCharacters(in: .whitespacesAndNewlines),
                anchors: anchors,
                wanted: wanted,
                originSessionID: originSessionID,
                contentHash: contentHash,
                sortIndex: result.count,
                createdAt: now,
                updatedAt: now
            ))
        }
        return result
    }

    /// Whether two passages are the same words, allowing for the model quoting
    /// a little more or less than the learner marked. Short fragments never
    /// match: a five-word overlap is a coincidence, not attention.
    static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalized(lhs)
        let b = normalized(rhs)
        guard a.count >= 24, b.count >= 24 else { return false }
        return a.contains(b) || b.contains(a)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }
}

/// SHA-256 (FIPS 180-4) in plain Swift, for the one client with no CryptoKit:
/// the WebAssembly build of the portable core. Byte-for-byte the digest
/// CryptoKit produces, which is what lets an idea id minted on the web match
/// the Mac's and the phone's.
enum PortableSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func digest(of message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }

        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(padded[j]) << 24 | UInt32(padded[j + 1]) << 16 | UInt32(padded[j + 2]) << 8 | UInt32(padded[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in h { out += [UInt8(word >> 24), UInt8((word >> 16) & 0xff), UInt8((word >> 8) & 0xff), UInt8(word & 0xff)] }
        return out
    }

    static func hexDigest(of message: [UInt8]) -> String {
        digest(of: message).map { String(format: "%02x", $0) }.joined()
    }

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
