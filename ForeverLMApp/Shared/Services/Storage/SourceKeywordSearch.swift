import Foundation

/// Literal keyword matching: the spelling the learner asked for, found
/// wherever it occurs in a source's text.
///
/// It sits beside `SourceSearchEngine` rather than in `Shared/Portable`
/// deliberately. Portable is compiled into the WebAssembly core the website
/// runs, and the Foundation string APIs this needs — `range(of:options:)` and
/// a regular expression — drag ICU and NSRegularExpression into that module,
/// which took the shipped `.wasm` from 8 MB to 46 MB and past Cloudflare
/// Pages' 25 MB per-file limit. Nothing in the browser calls this: the
/// keyword sweep needs the local full text, which only the Mac has.
///
/// This is deliberately *not* the ranked hybrid search in `SourceSearchEngine`.
/// That engine tokenizes, so its full-text branch indexes `source_fts` with no
/// stemming — on purpose, so a gene symbol survives — which means a query for
/// `uncoupler` never matches a body that only says `uncouplers`, and the terms
/// it does match are then rank-fused with semantic neighbours and cut to a
/// page. Asking "what in my library mentions uncouplers?" wants the opposite
/// contract: a substring, every source that has it, and nothing inferred.
///
/// Substring is the whole rule. `uncoupler` finds `uncouplers` and
/// `uncoupler-treated`; `uncouplers` does not find `uncoupler`, because the
/// learner asked for the longer spelling. Case is ignored the way Unicode
/// folds it, not only in ASCII: `δψ` finds `Δψ`, `µM` finds `μM`, and a
/// ligature or `ß` is the letters it folds to, so `effect` finds the `eﬀect`
/// a PDF extracts and `strasse` finds `Straße`. Nothing else is ignored:
/// accents, hyphens and spaces all count.
enum SourceKeywordSearch {

    /// The most keywords one sweep takes. A cap of 10 made a chat asked about the
    /// 25 compounds in one paper spend two calls on the refusal.
    /// A whole-library sweep of 30 that match nothing — the worst case, since
    /// every keyword is looked for in every text — measured 2.5 s over 3,916
    /// sources and 190 MB of text when a SQL `LIKE` did the looking, and 0.3 s
    /// over a 188 MB fixture with `Screen`; scoped to a
    /// chat's sources it costs nothing.
    static let maximumKeywords = 30

    /// One keyword's presence in one source.
    struct KeywordCount: Equatable, Sendable {
        let keyword: String
        let count: Int
    }

    /// A keyword as a sweep uses it: the learner's spelling, which every report
    /// quotes, the folded needle the text is compared against, and what any
    /// text that holds it must contain, which `Screen` checks first.
    ///
    /// The comparison runs on `needle`, the keyword case-folded in full, and
    /// Foundation's case-insensitive search needs that. Handed a keyword whose
    /// fold is longer than the keyword — `ß` folds to `ss`, `ﬁ` to `fi` — it
    /// compares the first letter of the fold and then accepts any character at
    /// all, so `ß` would be counted ×500 in every paper that had one,
    /// once per "s " and "si". Folded first, the keyword holds no such
    /// character, and the text's own `ß` and `ﬁ` still match `ss` and `fi`.
    struct Keyword: Equatable, Sendable {
        /// As the learner wrote it.
        let text: String
        /// `text` case-folded in full: `Δψ` becomes `δψ`, `µM` becomes `μm`,
        /// `Straße` becomes `strasse`.
        let needle: String
        /// The needle's runs of plain ASCII, lowercased. A text that holds the
        /// keyword holds every run byte for byte, up to ASCII case, unless it
        /// spells part of one with a hazard.
        let asciiRuns: [[UInt8]]
        /// For each character of the needle that is not plain ASCII, its first
        /// non-ASCII scalar once decomposed. However a text spells that
        /// character, one of the text's scalars folds to something holding it.
        let requiredScalars: Set<UInt32>
        /// The hazards whose fold occurs in the needle: the only characters that
        /// can stand in a text for some of its ASCII letters.
        let hazards: Set<UInt32>

        init(_ text: String) {
            self.text = text
            needle = text.folding(options: [.caseInsensitive], locale: nil)
            let folded = SourceKeywordSearch.canonicalFold(text)
            var runs: [[UInt8]] = []
            var run: [UInt8] = []
            var required: Set<UInt32> = []
            for character in folded {
                let scalars = character.unicodeScalars
                if scalars.allSatisfy(\.isASCII) {
                    run.append(contentsOf: scalars.map { SourceKeywordSearch.asciiLowercased(UInt8($0.value)) })
                    continue
                }
                if !run.isEmpty {
                    runs.append(run)
                    run = []
                }
                if let scalar = scalars.first(where: { !$0.isASCII }) {
                    required.insert(scalar.value)
                }
            }
            if !run.isEmpty { runs.append(run) }
            asciiRuns = runs
            requiredScalars = required
            let foldedScalars = folded.unicodeScalars.map(\.value)
            hazards = Set(SourceKeywordSearch.hazards.compactMap { hazard, spelling in
                SourceKeywordSearch.contains(foldedScalars, spelling.unicodeScalars.map(\.value)) ? hazard : nil
            })
        }
    }

    /// Every character whose case fold spells plain ASCII, with the letters it
    /// folds to: the only way a text can hold a keyword's ASCII letters without
    /// holding those letters. The search reads `eﬀect` as `effect`, which is
    /// right — the ligature is what PDF extraction hands back, and 91 sources in
    /// one library spelled "ff" only as U+FB00 — so ruling a source
    /// out on its ASCII bytes alone has to know them. Found by folding every
    /// assigned scalar; `SourceKeywordSearchTests` folds them all again, so a
    /// Unicode revision that adds one fails there rather than in a sweep.
    static let hazards: [UInt32: String] = [
        0x00DF: "ss",        // ß
        0x0149: "\u{2BC}n",  // ŉ
        0x017F: "s",         // ſ, long s
        0x037E: ";",         // Greek question mark
        0x1E9A: "a\u{2BE}",  // ẚ
        0x1E9E: "ss",        // ẞ
        0x1FEF: "`",         // Greek varia
        0x212A: "k",         // Kelvin sign
        0xFB00: "ff",
        0xFB01: "fi",
        0xFB02: "fl",
        0xFB03: "ffi",
        0xFB04: "ffl",
        0xFB05: "st",
        0xFB06: "st",
    ]

    /// Unicode's canonical caseless form: decomposed, case-folded in full, and
    /// decomposed again. Two spellings the case-insensitive comparison treats
    /// as the same text have the same form.
    static func canonicalFold(_ text: String) -> String {
        text.decomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
            .decomposedStringWithCanonicalMapping
    }

    /// Rules texts out before the comparison, which runs at a few megabytes a
    /// second on a Swift string: a whole-library pass of it took 17 s for
    /// `uncoupler` and 37 s for `δψ` over 190 MB, while this pass reads the
    /// same bytes in a fraction of a second. It is never stricter than the
    /// comparison — a text it rules out cannot hold the keyword under any
    /// spelling the comparison accepts — so it only decides where the
    /// comparison is worth running.
    struct Screen {
        let keywords: [Keyword]
        private let watchedHazards: Set<UInt32>
        private let watchedScalars: Set<UInt32>
        /// Per scalar met so far: whether it is a hazard this sweep watches,
        /// and which watched scalars its fold holds.
        private var verdicts: [UInt32: (isHazard: Bool, holds: [UInt32])] = [:]

        init(_ keywords: [Keyword]) {
            self.keywords = keywords
            watchedHazards = keywords.reduce(into: []) { $0.formUnion($1.hazards) }
            watchedScalars = keywords.reduce(into: []) { $0.formUnion($1.requiredScalars) }
        }

        /// For each keyword, whether `bytes` (UTF-8) could hold it. `false` is
        /// certain; `true` leaves the answer to the comparison.
        mutating func mayContain(_ bytes: UnsafeRawBufferPointer) -> [Bool] {
            var result = [Bool](repeating: false, count: keywords.count)
            var present: (hazards: Set<UInt32>, scalars: Set<UInt32>)?
            var expanded: [UInt8]?
            for (index, keyword) in keywords.enumerated() {
                if !keyword.requiredScalars.isEmpty {
                    let found = present ?? scalarsPresent(in: bytes)
                    present = found
                    guard keyword.requiredScalars.isSubset(of: found.scalars) else { continue }
                }
                if SourceKeywordSearch.containsAll(keyword.asciiRuns, in: bytes) {
                    result[index] = true
                    continue
                }
                guard !keyword.hazards.isEmpty else { continue }
                let found = present ?? scalarsPresent(in: bytes)
                present = found
                guard !keyword.hazards.isDisjoint(with: found.hazards) else { continue }
                // A hazard in the text may be spelling part of a run: read the
                // text again with every hazard written out as its letters.
                let letters = expanded ?? SourceKeywordSearch.expanding(found.hazards, in: bytes)
                expanded = letters
                result[index] = letters.withUnsafeBytes {
                    SourceKeywordSearch.containsAll(keyword.asciiRuns, in: $0)
                }
            }
            return result
        }

        mutating func mayContain(_ text: String) -> [Bool] {
            var text = text
            return text.withUTF8 { mayContain(UnsafeRawBufferPointer($0)) }
        }

        private mutating func scalarsPresent(in bytes: UnsafeRawBufferPointer) -> (hazards: Set<UInt32>, scalars: Set<UInt32>) {
            var hazards: Set<UInt32> = []
            var scalars: Set<UInt32> = []
            guard !(watchedHazards.isEmpty && watchedScalars.isEmpty) else { return (hazards, scalars) }
            SourceKeywordSearch.forEachNonASCIIScalar(in: bytes) { scalar in
                let verdict = verdict(for: scalar)
                if verdict.isHazard { hazards.insert(scalar) }
                for held in verdict.holds { scalars.insert(held) }
            }
            return (hazards, scalars)
        }

        private mutating func verdict(for scalar: UInt32) -> (isHazard: Bool, holds: [UInt32]) {
            if let known = verdicts[scalar] { return known }
            var holds: [UInt32] = []
            if !watchedScalars.isEmpty, let value = Unicode.Scalar(scalar) {
                holds = SourceKeywordSearch.canonicalFold(String(Character(value)))
                    .unicodeScalars
                    .map(\.value)
                    .filter { watchedScalars.contains($0) }
            }
            let verdict = (isHazard: watchedHazards.contains(scalar), holds: holds)
            verdicts[scalar] = verdict
            return verdict
        }
    }

    /// Where a keyword sits in a text, in the text's own indices, so a snippet
    /// can be cut from the original rather than from a lowercased copy —
    /// lowercasing is not length-preserving for every scalar, and reusing its
    /// offsets against the original silently slices mid-character.
    static func ranges(of keyword: String, in text: String, limit: Int = Int.max) -> [Range<String.Index>] {
        ranges(of: Keyword(keyword), in: text, limit: limit)
    }

    static func ranges(of keyword: Keyword, in text: String, limit: Int = Int.max) -> [Range<String.Index>] {
        guard !keyword.needle.isEmpty, limit > 0 else { return [] }
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex, found.count < limit {
            guard let range = text.range(
                of: keyword.needle,
                options: [.caseInsensitive],
                range: searchStart..<text.endIndex
            ) else { break }
            found.append(range)
            // Advance by one character, not past the whole match, so
            // overlapping occurrences of a repeating keyword still count.
            searchStart = range.lowerBound < range.upperBound
                ? text.index(after: range.lowerBound)
                : text.index(after: searchStart)
        }
        return found
    }

    /// How many times each keyword occurs, keeping only the ones that do.
    /// `countCeiling` stops counting a keyword that clearly saturates the text,
    /// so a common word in a book-length source cannot turn one search into a
    /// million range scans; the reported count is then that ceiling.
    static func counts(
        of keywords: [String],
        in text: String,
        countCeiling: Int = 500
    ) -> [KeywordCount] {
        counts(of: keywords.map(Keyword.init), inFields: [text], countCeiling: countCeiling)
    }

    /// The counts summed over a source's fields — title, author, text — each
    /// searched on its own, so no match runs from one field into the next.
    static func counts(
        of keywords: [Keyword],
        inFields fields: [String],
        countCeiling: Int = 500
    ) -> [KeywordCount] {
        keywords.compactMap { keyword in
            var count = 0
            for field in fields where count < countCeiling {
                count += ranges(of: keyword, in: field, limit: countCeiling - count).count
            }
            return count > 0 ? KeywordCount(keyword: keyword.text, count: count) : nil
        }
    }

    /// A few passages showing the keywords in place, so whoever reads the
    /// result can throw out the irrelevant hits without opening each source.
    /// Passages are taken in the order they occur, one per occurrence, spread
    /// across the keywords that matched rather than spent on the first one.
    static func snippets(
        for keywords: [String],
        in text: String,
        limit: Int,
        radius: Int = 110
    ) -> [String] {
        snippets(for: keywords.map(Keyword.init), in: text, limit: limit, radius: radius)
    }

    static func snippets(
        for keywords: [Keyword],
        in text: String,
        limit: Int,
        radius: Int = 110
    ) -> [String] {
        guard limit > 0 else { return [] }
        var occurrences: [Range<String.Index>] = []
        for keyword in keywords {
            occurrences.append(contentsOf: ranges(of: keyword, in: text, limit: limit))
        }
        guard !occurrences.isEmpty else { return [] }
        occurrences.sort { $0.lowerBound < $1.lowerBound }

        var snippets: [String] = []
        var consumedThrough: String.Index?
        for range in occurrences {
            guard snippets.count < limit else { break }
            // Two keywords a few words apart describe one passage, not two.
            if let consumedThrough, range.lowerBound < consumedThrough { continue }
            let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
                ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex)
                ?? text.endIndex
            consumedThrough = end
            let passage = text[start..<end]
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !passage.isEmpty else { continue }
            let leading = start > text.startIndex ? "…" : ""
            let trailing = end < text.endIndex ? "…" : ""
            snippets.append(leading + passage + trailing)
        }
        return snippets
    }

    /// The keywords as the search will use them: trimmed, empty ones dropped,
    /// and one kept of any that match the same text — `UNCOUPLER` and
    /// `uncoupler`, `µM` and `μM`, `Straße` and `STRASSE`. A keyword of one
    /// character is kept — a learner searching for a symbol means it.
    static func normalized(_ keywords: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for keyword in keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(canonicalFold(trimmed)).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    // MARK: - Bytes

    /// Whether every run occurs in `bytes`, ignoring ASCII case.
    static func containsAll(_ runs: [[UInt8]], in bytes: UnsafeRawBufferPointer) -> Bool {
        runs.allSatisfy { containsIgnoringASCIICase($0, in: bytes) }
    }

    /// Whether `run` (lowercase ASCII) occurs in `bytes`, ignoring ASCII case.
    /// It finds the run's least common byte with `memchr` and compares the rest
    /// around each hit — the way SQLite's `LIKE` scans, anchored on a rarer
    /// byte than the first.
    static func containsIgnoringASCIICase(_ run: [UInt8], in bytes: UnsafeRawBufferPointer) -> Bool {
        guard !run.isEmpty else { return true }
        guard let base = bytes.baseAddress, bytes.count >= run.count else { return false }
        let anchor = run.indices.min { commonness[Int(run[$0])] < commonness[Int(run[$1])] } ?? 0
        let lower = run[anchor]
        let upper = asciiUppercased(lower)
        // The anchor can only sit where the whole run still fits around it.
        let lastAnchor = bytes.count - run.count + anchor
        func next(_ byte: UInt8, from start: Int) -> Int? {
            guard start <= lastAnchor,
                  let hit = memchr(base + start, Int32(byte), lastAnchor - start + 1) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
        var nextLower = next(lower, from: anchor)
        var nextUpper = upper == lower ? nil : next(upper, from: anchor)
        while true {
            let position: Int
            switch (nextLower, nextUpper) {
            case (nil, nil): return false
            case let (lowerHit?, nil): position = lowerHit
            case let (nil, upperHit?): position = upperHit
            case let (lowerHit?, upperHit?): position = min(lowerHit, upperHit)
            }
            let start = position - anchor
            var matched = true
            for offset in run.indices where offset != anchor {
                if asciiLowercased(base.load(fromByteOffset: start + offset, as: UInt8.self)) != run[offset] {
                    matched = false
                    break
                }
            }
            if matched { return true }
            if position == nextLower {
                nextLower = next(lower, from: position + 1)
            } else {
                nextUpper = next(upper, from: position + 1)
            }
        }
    }

    /// Calls `body` with every scalar in `bytes` (UTF-8) that is not ASCII,
    /// passing over ASCII eight bytes at a time. A malformed sequence is
    /// reported as U+FFFD, which is what it reads as once decoded.
    static func forEachNonASCIIScalar(in bytes: UnsafeRawBufferPointer, _ body: (UInt32) -> Void) {
        let count = bytes.count
        var index = 0
        while index < count {
            while index + 8 <= count,
                  bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self) & 0x8080_8080_8080_8080 == 0 {
                index += 8
            }
            guard index < count else { return }
            if bytes[index] < 0x80 {
                index += 1
                continue
            }
            let (scalar, length) = decodedScalar(in: bytes, at: index)
            body(scalar)
            index += length
        }
    }

    /// `bytes` with each of `hazards` written out as the letters it folds to.
    static func expanding(_ hazards: Set<UInt32>, in bytes: UnsafeRawBufferPointer) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count + 16)
        var index = 0
        while index < bytes.count {
            if bytes[index] < 0x80 {
                result.append(bytes[index])
                index += 1
                continue
            }
            let (scalar, length) = decodedScalar(in: bytes, at: index)
            if hazards.contains(scalar), let letters = Self.hazards[scalar] {
                result.append(contentsOf: letters.utf8)
            } else {
                result.append(contentsOf: bytes[index..<(index + length)])
            }
            index += length
        }
        return result
    }

    /// The scalar whose UTF-8 sequence starts at `index` (a byte of 0x80 or
    /// more) and how many bytes it takes; a malformed sequence is U+FFFD and
    /// one byte, so decoding picks up again at the next byte.
    private static func decodedScalar(in bytes: UnsafeRawBufferPointer, at index: Int) -> (UInt32, Int) {
        let lead = UInt32(bytes[index])
        let length: Int
        switch lead {
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default: return (0xFFFD, 1)
        }
        var value = lead & (0x7F >> length)
        guard index + length <= bytes.count else { return (0xFFFD, 1) }
        for offset in 1..<length {
            let byte = UInt32(bytes[index + offset])
            guard byte & 0xC0 == 0x80 else { return (0xFFFD, 1) }
            value = value << 6 | (byte & 0x3F)
        }
        let smallest: UInt32 = length == 2 ? 0x80 : length == 3 ? 0x800 : 0x10000
        guard value >= smallest, value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else { return (0xFFFD, 1) }
        return (value, length)
    }

    /// Whether `part` occurs in `scalars` as a contiguous run.
    private static func contains(_ scalars: [UInt32], _ part: [UInt32]) -> Bool {
        guard !part.isEmpty else { return true }
        guard part.count <= scalars.count else { return false }
        return (0...(scalars.count - part.count)).contains { start in
            scalars[start..<(start + part.count)].elementsEqual(part)
        }
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
    }

    private static func asciiUppercased(_ byte: UInt8) -> UInt8 {
        (0x61...0x7A).contains(byte) ? byte & ~0x20 : byte
    }

    /// Roughly how often each byte turns up in English prose, so a scan can
    /// anchor on the one it will meet least. Only speed depends on it.
    private static let commonness: [UInt8] = {
        var table = [UInt8](repeating: 8, count: 256)
        for (rank, byte) in "zqxjkvbpygfwmucldrhsnioate".utf8.enumerated() {
            table[Int(byte)] = UInt8(rank + 1)
        }
        for byte in UInt8(ascii: "0")...UInt8(ascii: "9") { table[Int(byte)] = 12 }
        table[Int(UInt8(ascii: "."))] = 20
        table[Int(UInt8(ascii: ","))] = 20
        table[Int(UInt8(ascii: "\n"))] = 20
        table[Int(UInt8(ascii: " "))] = 40
        return table
    }()
}

/// One source that contains the keywords, with the evidence that it does.
struct SourceKeywordMatch: Equatable, Sendable {
    let sourceID: String
    let title: String
    let sourceType: String
    let author: String?
    /// The book or course a chapter belongs to, when it belongs to one.
    let groupName: String?
    let keywordCounts: [SourceKeywordSearch.KeywordCount]
    let snippets: [String]

    var totalMentions: Int { keywordCounts.reduce(0) { $0 + $1.count } }
    var matchedKeywords: [String] { keywordCounts.map(\.keyword) }
}
