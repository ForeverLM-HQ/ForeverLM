import Foundation

/// Two web articles whose stored text is the same, and what that means.
///
/// The same article reached at two addresses is one work: Asimov Press moved
/// from asimov.press to press.asimov.com, a Substack post is also on its
/// author's own domain, a share link carries a different path. No address
/// connects them, so the duplicate check never saw them, and the library held
/// "Stories We'd Like to Publish (Part II)" twice, added five minutes apart
/// (2026-11-26). A survey that day found 12 such pairs.
///
/// The same text under two different titles is not one work: one of the two
/// was saved with the other's page (the Reader's wrong-page capture, fixed in
/// 3b2bfd65). Five such pairs were found, among them Elliot Hershberg's "The
/// genetics of immunity" holding "CAR-T combinatorics". Folding those would
/// lose an article; the one holding the other's text is read again instead.
///
/// Which it is follows from the titles: the same title (allowing for a
/// publication or byline suffix) is the same work; different titles, and the
/// copy whose text opens with its own title is the right one.
enum DuplicateArticleText {
    /// Below this many words a text is too short for its likeness to say
    /// anything: a stub, a paywall preview, a page's furniture.
    static let minimumWords = 300
    /// Word five-grams one text shares with the other, as a share of the
    /// smaller text's. A Source Content Cleanup run rewords a few lines; two
    /// different articles share almost none (the closest unrelated pair in the
    /// library shared under half).
    static let sameTextShare = 0.9
    /// Two copies of one text are within a quarter of each other's length.
    static let lengthRatio = 1.25

    struct Fingerprint: Sendable {
        let wordCount: Int
        let shingles: Set<Int>
    }

    struct Copy: Sendable {
        let id: String
        let title: String
        let text: String
    }

    enum Verdict: Equatable, Sendable {
        /// Not the same text.
        case different
        /// One work at two addresses: fold them.
        case sameWork
        /// The source with this id holds the other's text.
        case holdsOthersText(String)
        /// The same text, and nothing says which copy is right.
        case undecided
    }

    static func words(_ text: String) -> [Substring] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
    }

    static func fingerprint(_ text: String) -> Fingerprint? {
        let words = words(text)
        guard words.count >= minimumWords else { return nil }
        var shingles = Set<Int>()
        shingles.reserveCapacity(words.count)
        for index in 0...(words.count - 5) {
            var hasher = Hasher()
            for word in words[index..<(index + 5)] { hasher.combine(word) }
            shingles.insert(hasher.finalize())
        }
        return Fingerprint(wordCount: words.count, shingles: shingles)
    }

    /// Whether two lengths are close enough for their texts to be one.
    static func lengthsCouldMatch(_ a: Int, _ b: Int) -> Bool {
        let (small, large) = (min(a, b), max(a, b))
        return small > 0 && Double(large) <= Double(small) * lengthRatio
    }

    static func isSameText(_ a: Fingerprint, _ b: Fingerprint) -> Bool {
        guard lengthsCouldMatch(a.wordCount, b.wordCount) else { return false }
        let (small, large) = a.shingles.count <= b.shingles.count ? (a, b) : (b, a)
        guard !small.shingles.isEmpty else { return false }
        let shared = small.shingles.reduce(0) { large.shingles.contains($1) ? $0 + 1 : $0 }
        return Double(shared) / Double(small.shingles.count) >= sameTextShare
    }

    static func verdict(_ a: Copy, _ b: Copy) -> Verdict {
        guard let fa = fingerprint(a.text), let fb = fingerprint(b.text), isSameText(fa, fb) else { return .different }
        return verdict(sameText: a, b)
    }

    /// The verdict on two copies already known to hold the same text.
    static func verdict(sameText a: Copy, _ b: Copy) -> Verdict {
        if titlesAgree(a.title, b.title) { return .sameWork }
        let aOpensWithOwnTitle = heading(of: a.text, title: a.title).map { titlesAgree($0, a.title) } ?? false
        let bOpensWithOwnTitle = heading(of: b.text, title: b.title).map { titlesAgree($0, b.title) } ?? false
        switch (aOpensWithOwnTitle, bOpensWithOwnTitle) {
        case (true, false): return .holdsOthersText(b.id)
        case (false, true): return .holdsOthersText(a.id)
        default: return .undecided
        }
    }

    /// The line a text opens with: its first `# ` heading, else its first line
    /// other than the stored title line Source Content Cleanup puts on top.
    static func heading(of text: String, title: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let marked = lines.first(where: { $0.hasPrefix("# ") }) { return String(marked.dropFirst(2)) }
        let stored = title.trimmingCharacters(in: .whitespaces).lowercased()
        return lines.first { $0.lowercased() != stored }
    }

    /// Whether two titles name one article, allowing for a byline ("- by
    /// Elliot Hershberg"), a publication ("- Asimov Press", "| Science") and a
    /// notification count ("(1) ").
    static func titlesAgree(_ a: String, _ b: String) -> Bool {
        let ta = titleWords(a), tb = titleWords(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let ja = ta.joined(separator: " "), jb = tb.joined(separator: " ")
        if ja.contains(jb) || jb.contains(ja) { return true }
        let sa = Set(ta), sb = Set(tb)
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count) >= 0.6
    }

    static func titleWords(_ title: String) -> [String] {
        var head = title
        if let byline = head.range(of: #"\s+-\s+by\s+"#, options: [.regularExpression, .caseInsensitive]) {
            head = String(head[..<byline.lowerBound])
        }
        for separator in [" | ", " – ", " — "] {
            if let range = head.range(of: separator) { head = String(head[..<range.lowerBound]) }
        }
        if let range = head.range(of: " - ", options: .backwards) { head = String(head[..<range.lowerBound]) }
        return words(head).map(String.init)
    }
}
