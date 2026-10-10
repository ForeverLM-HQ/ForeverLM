import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Whether a downloaded PDF is the paper an import asked for.
///
/// Every PDF an import tries — the publisher's link, a PubMed Central copy,
/// an Unpaywall or OpenAlex location, a preprint — is somebody's claim that
/// the file is this paper, and the indexes are wrong often enough to matter.
/// On 2026-09-28 OpenAlex listed an LSE repository copy of Ginsburg et al.,
/// "The global burden of women's cancers" (Lancet 2017), under the DOI
/// `10.1016/s0140-6736`, and importing Luoma et al. (Lancet 2004) saved it.
/// The Paper Metadata model then read the wrong PDF faithfully and rewrote the
/// title, DOI, authors and year to match it, so the mistake looked like a
/// legitimate source.
///
/// So a PDF is compared with what was asked for before it is accepted, on
/// what the file itself prints in its opening pages: the requested DOI, and a
/// requested title, whose words must stand together as a title's do unless
/// the file prints no other paper's DOI. What a paper *is* stays deterministic
/// code (AGENTS.md: never let an LLM decide identity). The check leans toward
/// accepting where it cannot see: a scan without a text layer, or a request
/// naming no DOI and no title long enough to recognise, is `unverifiable`,
/// never a mismatch. Its known blind spot is a letter or comment about the
/// paper, which prints the paper's title and DOI in its references.
///
/// Measured on 2026-09-28 against the library's own 701 PDFs: every one
/// confirmed under its stored DOI and title, 75 of 75 sampled under
/// Crossref's registered title alone, and 375 of 375 turned away when offered
/// for a different paper of the library (mostly the same field).
enum PaperPDFIdentity {
    /// What the import asked for.
    struct Request: Equatable, Sendable {
        var doi: String?
        /// Titles the paper is known by: a caller's override, the landing
        /// page's citation title, the DOI's registered title.
        var titles: [String]
        /// The DOI's registered title has been asked for, found or not, so a
        /// later candidate does not ask again.
        var askedForRegisteredTitle = false

        init(doi: String?, titles: [String]) {
            self.doi = doi.flatMap { PaperPDFIdentity.nilIfBlank($0) }
            self.titles = titles.compactMap { PaperPDFIdentity.nilIfBlank($0) }
        }

        /// Whether there is anything to compare a file with.
        var asksForAnything: Bool { doi != nil || !titles.isEmpty }
    }

    /// What a PDF prints: its document attributes (title, subject, keywords)
    /// and the text of its opening pages.
    struct Evidence: Equatable, Sendable {
        var openingText: String
    }

    enum Verdict: Equatable, Sendable {
        /// The PDF prints a requested title, or the requested DOI with no
        /// requested title against it.
        case confirmed
        /// Nothing to compare: no DOI or recognisable title was asked for,
        /// the file has too little text to read, or it prints neither.
        case unverifiable
        /// The PDF is some other paper. The reason says what it prints
        /// instead, in words fit for the learner.
        case mismatch(String)
    }

    /// Pages read for evidence. A repository's cover sheet can stand before
    /// the paper's own first page, as LSE Research Online's did.
    static let openingPageCount = 3

    /// Fewer words than this is a scan or a stub, not text to judge by.
    static let minimumReadableWords = 25

    /// A title needs this many distinct content words before its absence says
    /// anything. It also keeps chrome a landing page wore — "Just a moment…",
    /// "View article", "Client Request Error" — from refuting a file.
    static let minimumTitleWords = 4

    /// The share of a title's content words one stretch of the opening pages
    /// must print. An accepted manuscript's own title can differ a little
    /// from the published one ("an unmet grand challenge" for "a grand
    /// challenge"); a different paper shares next to none (1 of 11 words,
    /// 2026-09-28).
    static let titleCoverageThreshold = 0.6

    /// The share needed when the words may lie anywhere in the pages, which is
    /// weaker evidence and so asks for more: three quarters kept Nature's
    /// energy Comment (7 of 8) and turned away a Comment on genes offered for
    /// the Evo 2 paper (5 of 8) in the 2026-09-28 library sweep.
    static let scatteredTitleCoverageThreshold = 0.75

    static func verdict(for request: Request, evidence: Evidence) -> Verdict {
        let text = evidence.openingText
        let requestedDOI = request.doi.map(comparableDOI)
        let printed = PaperService.printedDOIs(in: text)
        let printsRequestedDOI = requestedDOI.map { doi in
            printed.contains { sameDOI(comparableDOI($0), doi) } || printsDOIAcrossLines(doi, in: text)
        } ?? false

        let words = tokens(in: text)
        guard words.count >= minimumReadableWords else {
            return printsRequestedDOI ? .confirmed : .unverifiable
        }
        let letters = words.joined()

        let checkableTitles = request.titles.filter { contentWords(of: $0).count >= minimumTitleWords }
        if request.titles.contains(where: { printsWholeTitle($0, letters: letters) })
            || checkableTitles.contains(where: { coverage(of: $0, in: words) >= titleCoverageThreshold }) {
            return .confirmed
        }
        let otherDOIs = printed.filter { doi in requestedDOI.map { !sameDOI(comparableDOI(doi), $0) } ?? true }
        // A file that prints no other paper's DOI offers nothing against the
        // title but its own headline, and a magazine piece's print headline
        // can be another sentence entirely: Nature's "Should we reconsider
        // how we think about energy?" is registered as "From cancer to
        // Alzheimer's: could a renewed focus on energy transform biomedicine?".
        // There most of the title's words anywhere in the pages are enough.
        if otherDOIs.isEmpty {
            let wordSet = Set(words)
            if checkableTitles.contains(where: { scatteredCoverage(of: $0, in: wordSet) >= scatteredTitleCoverageThreshold }) {
                return .confirmed
            }
        }
        let printsClause = otherDOIs.first.map { " and prints the DOI \($0)" } ?? ""
        if let title = checkableTitles.first {
            // A requested title the file does not carry outweighs a DOI it
            // prints: the DOI asked for can itself be a truncated one, which
            // the wrong paper's cover sheet printed (`10.1016/S0140-6736`).
            return .mismatch("its opening pages do not carry the title “\(title)”\(printsClause)")
        }
        if printsRequestedDOI { return .confirmed }
        if let requested = request.doi, let other = otherDOIs.first {
            return .mismatch("it prints the DOI \(other), not \(requested)")
        }
        return .unverifiable
    }

    /// Whether the file has enough text for a title to be looked for in it.
    /// Without it no further title can change the verdict, so a caller need
    /// not go and fetch one.
    static func hasReadableText(_ evidence: Evidence) -> Bool {
        tokens(in: evidence.openingText).count >= minimumReadableWords
    }

    #if canImport(PDFKit)
    /// The evidence a PDF on disk offers, or nil when PDFKit cannot open it.
    /// Reads the file, so callers stay off the main actor.
    static func evidence(fromPDFAt url: URL) -> Evidence? {
        guard let document = PDFDocument(url: url) else { return nil }
        var parts: [String] = []
        if let attributes = document.documentAttributes {
            for key in [PDFDocumentAttribute.titleAttribute, .subjectAttribute, .keywordsAttribute] {
                if let value = attributes[key] as? String { parts.append(value) }
            }
        }
        for index in 0..<min(document.pageCount, openingPageCount) {
            if let text = document.page(at: index)?.string { parts.append(text) }
        }
        return Evidence(openingText: parts.joined(separator: "\n"))
    }

    /// Whether the PDF at `file` is the paper `request` names. When what was
    /// already known does not confirm the file, the DOI's registered title is
    /// asked for once and kept on `request`, so the next candidate is judged
    /// with it too. The file is read on a detached task, so a main-actor
    /// caller never waits on PDFKit.
    static func verdict(
        forPDFAt file: URL,
        request: inout Request,
        registeredTitle: (String) async -> String? = { await PaperService.registeredTitleIfKnown(forDOI: $0) }
    ) async -> Verdict {
        guard request.asksForAnything,
              let evidence = await Task.detached(priority: .utility, operation: {
                  PaperPDFIdentity.evidence(fromPDFAt: file)
              }).value else {
            return .unverifiable
        }
        let firstVerdict = PaperPDFIdentity.verdict(for: request, evidence: evidence)
        guard firstVerdict != .confirmed,
              hasReadableText(evidence),
              !request.askedForRegisteredTitle,
              let doi = request.doi else {
            return firstVerdict
        }
        request.askedForRegisteredTitle = true
        guard let registered = await registeredTitle(doi) else { return firstVerdict }
        request.titles.append(registered)
        return PaperPDFIdentity.verdict(for: request, evidence: evidence)
    }
    #endif

    // MARK: - Comparison

    /// A DOI as compared: bare, lower case, without its sentence punctuation.
    static func comparableDOI(_ raw: String) -> String {
        var doi = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:"]
        where doi.hasPrefix(prefix) {
            doi.removeFirst(prefix.count)
        }
        while let last = doi.last, ".,;:".contains(last) {
            doi.removeLast()
        }
        return doi.trimmingCharacters(in: .whitespaces)
    }

    /// Equal, or equal once a bioRxiv-style version suffix is set aside: a
    /// preprint server's address carries `v2` where the DOI it prints does not.
    private static func sameDOI(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || unversioned(lhs) == unversioned(rhs)
    }

    private static func unversioned(_ doi: String) -> String {
        doi.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
    }

    /// A DOI the page broke across lines ("…S0140-" then "6736(04)…") is
    /// still printed. Whitespace is closed up to find it, and the DOI must end
    /// where the printed run ends — at whitespace, the end, or a character no
    /// DOI would go on with — so a longer DOI that merely starts with it is
    /// not it.
    private static func printsDOIAcrossLines(_ doi: String, in text: String) -> Bool {
        let wanted = Array(doi)
        var closed: [Character] = []
        // Whether whitespace followed `closed[i]` in the text.
        var endsRun: [Bool] = []
        for character in text.lowercased() {
            if character.isWhitespace {
                if !endsRun.isEmpty { endsRun[endsRun.count - 1] = true }
            } else {
                closed.append(character)
                endsRun.append(false)
            }
        }
        guard !wanted.isEmpty, closed.count >= wanted.count else { return false }
        for start in 0...(closed.count - wanted.count)
        where closed[start] == wanted[0] && closed[start..<(start + wanted.count)].elementsEqual(wanted) {
            let last = start + wanted.count - 1
            if last == closed.count - 1 || endsRun[last] { return true }
            let next = closed[last + 1]
            if !(next.isLetter || next.isNumber || "(-_/".contains(next)) { return true }
        }
        return false
    }

    /// The whole title printed, letters and digits run together, as a
    /// reference list's entry is matched (`PDFReferenceEntries.entry(_:printsTitle:)`).
    /// It recognises a title too short to count words in: a Research
    /// Highlight called "Alternative cycle for citrate" prints the DOI of the
    /// paper it highlights and not its own, and was the one file of 701 in
    /// the library the DOI rule alone turned away (2026-09-28).
    private static func printsWholeTitle(_ title: String, letters: String) -> Bool {
        let key = tokens(in: title.decodingTitleMarkup()).joined()
        return key.count >= 16 && letters.contains(key)
    }

    /// The best share of a title's content words that one stretch of the text
    /// prints. The stretch is about twice the title's length, so the words
    /// have to stand together as a title's do: counted anywhere in three
    /// pages, a paper in the same field printed enough of another's title
    /// words to pass for it (5 of 75 wrong pairings in the library,
    /// 2026-09-28). A word of four letters or more counts inside the
    /// stretch's letters run together, which is how "mito-" + "chondrial"
    /// and "tissue-specific" still read.
    private static func coverage(of title: String, in textWords: [String]) -> Double {
        let titleWords = tokens(in: title.decodingTitleMarkup())
        let wanted = contentWords(ofTokens: titleWords)
        guard !wanted.isEmpty, !textWords.isEmpty else { return 0 }
        let step = titleWords.count + 4
        let width = 2 * step
        var best = 0
        var start = 0
        while best < wanted.count {
            let stretch = textWords[start..<min(start + width, textWords.count)]
            let letters = stretch.joined()
            best = max(best, wanted.filter { $0.count >= 4 ? letters.contains($0) : stretch.contains($0) }.count)
            guard start + width < textWords.count else { break }
            start += step
        }
        return Double(best) / Double(wanted.count)
    }

    /// The share of a title's content words printed anywhere in the text.
    private static func scatteredCoverage(of title: String, in textWords: Set<String>) -> Double {
        let wanted = contentWords(of: title)
        guard !wanted.isEmpty else { return 0 }
        return Double(wanted.filter { textWords.contains($0) }.count) / Double(wanted.count)
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "via", "its", "their", "are",
        "not", "this", "that", "than", "but", "our", "who", "how", "why", "what",
    ]

    /// A title's distinct words of three letters or more, less the glue.
    private static func contentWords(of title: String) -> [String] {
        contentWords(ofTokens: tokens(in: title.decodingTitleMarkup()))
    }

    private static func contentWords(ofTokens tokens: [String]) -> [String] {
        var seen = Set<String>()
        return tokens.filter { word in
            word.count >= 3 && !stopWords.contains(word) && seen.insert(word).inserted
        }
    }

    /// Lower-case letters-and-digits runs, compatibility forms and accents
    /// folded, so a PDF's "ﬁ" ligature is "fi" and "Müller" is "muller".
    private static func tokens(in text: String) -> [String] {
        text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    fileprivate static func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A PDF offered for a paper is some other paper (`PaperPDFIdentity`). Typed
/// like `PaperPDFUnavailableError`, so the download pipeline counts it as no
/// PDF of this paper — paywall evidence — and tries its next candidate.
struct PaperPDFIdentityMismatchError: LocalizedError {
    /// Where the file came from: the address it was downloaded from, or the
    /// `file:` URL of one already on disk.
    let pdfURL: String
    /// What the file prints instead (`PaperPDFIdentity.Verdict.mismatch`).
    let reason: String

    /// The file's origin as the learner would name it: the host it came from,
    /// or the name of a file already in the Papers folder. A `blob:` address,
    /// which WebKit gives a download a page's script assembled, is named by
    /// the page that made it.
    var origin: String {
        guard let url = URL(string: pdfURL) else { return pdfURL }
        if url.isFileURL { return url.lastPathComponent }
        let hostURL = url.scheme?.lowercased() == "blob"
            ? URL(string: String(pdfURL.dropFirst("blob:".count)))
            : url
        guard let host = hostURL?.host else { return pdfURL }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var evidence: String { "the PDF found at \(origin) is a different paper: \(reason)" }
    var errorDescription: String? { "The PDF found at \(origin) is a different paper: \(reason)" }
}
