import Foundation
import OSLog

/// One fused search hit: a source, its combined rank score, and the per-branch
/// evidence that produced it.
///
/// `score` is a Reciprocal Rank Fusion score. It is comparable only against other
/// hits from the *same* search — it has no absolute meaning and must never be
/// compared to a similarity threshold or shown to the user as a percentage.
struct SourceSearchHit: Sendable {
    let sourceId: String
    let score: Float
    /// Cosine similarity of the best-matching chunk, when the semantic branch hit.
    let semanticScore: Float?
    /// Negated BM25 (larger is better), when the full-text branch hit.
    let lexicalScore: Float?
    /// Metadata match score, when the metadata branch hit.
    let metadataScore: Float?
    /// Best-matching chunk embedding id, when the semantic branch contributed.
    let bestChunkId: String?
}

/// The single hybrid source-search algorithm, shared by the MCP tools and the in-app
/// Studio search.
///
/// Both entry points must rank identically: a learner who asks an assistant "what do I
/// have on GDF15?" and one who types the same thing into the app are asking the same
/// question, and getting different orderings from the two surfaces made search feel
/// unreliable in a way neither ranking alone explained. Previously MCP ran weighted RRF
/// while the UI added hand-tuned constants (`min(score * 0.20, 0.35)`) on top of raw
/// scores drawn from incomparable scales, and never consulted the full-text index at all.
///
/// Three branches are retrieved and fused:
///
///   1. **Semantic** — nearest chunk vectors, scored per source by its best chunk.
///   2. **Full text** — BM25 over `source_fts` (title/author/body).
///   3. **Metadata** — domain and parent group (book/course/show), which the full-text
///      index does not cover.
///
/// Fusion is by *rank*, not score, because the branches live on incomparable scales
/// (cosine similarity vs BM25 vs a match count) and the contextual embedding is
/// anisotropic — unrelated texts still score ~0.8, so only rank carries signal.
enum SourceSearchEngine {

    // MARK: - Tuning

    /// Standard RRF constant. The optimum is flat across k in 20…100, so it is not
    /// worth tuning.
    static let rrfK: Float = 60

    /// IDF at or above which a term is treated as rare. ~4.0 corresponds to a term in
    /// well under 2% of sources — e.g. GDF15 across a few thousand.
    static let rareTermIDF = 4.0
    /// IDF at or below which a term is treated as ordinary vocabulary.
    static let commonTermIDF = 1.5

    /// Lexical weight when the query contains a rare term — an exact match dominates.
    static let rareTermLexicalWeight: Float = 0.8
    /// Lexical weight when every query term is common — meaning dominates.
    static let commonTermLexicalWeight: Float = 0.35
    /// Used when the corpus has no full-text index yet.
    static let balancedLexicalWeight: Float = 0.5

    /// Weight for the metadata branch. Deliberately outside the lexical/semantic split,
    /// which sums to 1: metadata is a narrow precision signal (does this domain or book
    /// title match?) rather than a ranking of the whole corpus, so it should lift a
    /// match above nothing without ever outranking a strong body match.
    static let metadataWeight: Float = 0.4

    /// Exact DOI identity is stronger than either textual or semantic resemblance.
    /// This mirrors Grout's identifier route: a bare DOI or doi.org URL goes directly
    /// to the indexed identity columns instead of hoping token search reconstructs it.
    static let identifierWeight: Float = 1.0

    /// A proximity hit is a precision signal layered onto the lexical branch. FTS5's
    /// BM25 does not account for term distance, unlike Grout's cover-density rank, so a
    /// bounded NEAR query supplies that missing evidence without changing recall.
    static let proximityWeight: Float = 0.2

    /// Grout performs one indexed text-search operation regardless of query length.
    /// ForeverLM additionally probes document frequency per term, so bound that work.
    /// Keeping both ends preserves the usual question prefix and a trailing rare anchor.
    static let maximumStatisticalTerms = 16
    static let maximumProximityTerms = 8

    /// Retrieval is deliberately wider than the requested page but never grows without
    /// bound. The sidebar itself returns at most 300 rows, so a larger fusion pool only
    /// adds SQLite, vector-selection, and sorting work the caller cannot display.
    static let maximumCandidatePool = 300

    /// Maximum number of exact terms used to verify a targeted lookup. This keeps one
    /// natural-language query from turning into an unbounded number of FTS probes while
    /// preserving far more constraints than a normal title/author lookup contains.
    static let maximumPrecisionTerms = 12

    // MARK: - Word-Delimiter Analysis

    /// One whitespace-delimited word of a query, split the way a tokenizer splits the
    /// text it indexed.
    ///
    /// This is standard word-delimiter analysis — Lucene ships it as
    /// `WordDelimiterGraphFilter` with `catenateWords`/`catenateNumbers` — and it exists
    /// because one term gets written more than one way. "GDF-15" and "GDF15" name the
    /// same protein, and `unicode61` stores them differently: the first as two adjacent
    /// tokens `gdf` `15`, the second as one token `gdf15`. Analyzing both spellings down
    /// to the same parts is what makes retrieval symmetric, rather than depending on
    /// which spelling the learner happened to type.
    struct AnalyzedWord: Equatable, Sendable {
        /// Runs of alphanumerics as typed — exactly what `searchTerms` yields for this
        /// word, and therefore the keys term statistics are measured under.
        let typedTokens: [String]

        /// The same word split further at every letter↔digit transition, so "gdf-15",
        /// "gdf15" and "GDF15" all reduce to `["gdf", "15"]`.
        let parts: [String]

        /// Every spelling the index may hold for this word. A space inside a quoted
        /// FTS5 string is a *phrase* — adjacent tokens — which is precisely how the
        /// tokenizer stored the hyphenated spelling, so `"gdf 15"` retrieves "GDF-15"
        /// while `"gdf15"` retrieves "GDF15".
        var variants: [String] {
            guard parts.count > 1 else { return parts }
            return [parts.joined(), parts.joined(separator: " ")]
        }
    }

    /// Analyze a raw query into words. Bounded the same way `searchTerms` is, so one
    /// long question cannot turn into an unbounded MATCH expression.
    static func analyzedWords(for query: String) -> [AnalyzedWord] {
        let words = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map {
                AnalyzedWord(
                    typedTokens: alphanumericRuns(in: $0),
                    parts: alphanumericParts(in: $0)
                )
            }
            .filter { !$0.parts.isEmpty }
        // Single characters are dropped unless that would empty the query, the same
        // rule `searchTerms` applies — it matters more here, because the strict filter
        // AND-s these together and a stray "a" would then have to appear in the body.
        let substantial = words.filter { word in word.parts.contains { $0.count >= 2 } }
        let kept = substantial.isEmpty ? words : substantial

        var seen = Set<[String]>()
        let distinct = kept.filter { seen.insert($0.parts).inserted }
        guard distinct.count > maximumStatisticalTerms else { return distinct }

        let prefixCount = maximumStatisticalTerms / 2
        let suffixCount = maximumStatisticalTerms - prefixCount
        return Array(distinct.prefix(prefixCount)) + Array(distinct.suffix(suffixCount))
    }

    /// Maximal runs of letters and digits, splitting only where the writer put
    /// punctuation. Mirrors `searchTerms`, which is why these are the tokens the
    /// corpus-statistics keys are drawn from.
    static func alphanumericRuns(in word: some StringProtocol) -> [String] {
        String(word).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The same runs, split again wherever letters meet digits. This is the half that
    /// makes hyphenation irrelevant: it cannot know where to divide a run of letters
    /// ("cfmtDNA" stays one part), but a letter/digit boundary is unambiguous.
    static func alphanumericParts(in word: some StringProtocol) -> [String] {
        var parts: [String] = []
        var current = ""
        var previous: Character?
        for character in word {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { parts.append(current) }
                current = ""
                previous = nil
                continue
            }
            if let previous, previous.isNumber != character.isNumber, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - Index-Time Analysis

    /// Version of the index-time analysis below. Stamped per source in
    /// `source_fts_state`; raising it makes every full-text row stale and the indexer
    /// rewrites them — text only, no embeddings, so a reanalysis costs no model time.
    static let indexAnalyzerVersion = 1

    /// The tokens to store for one word of indexed text.
    ///
    /// Every token `unicode61` would produce, plus the closed-up spelling wherever
    /// punctuation separated letters from digits: "GDF-15" is stored as `gdf` `15`
    /// `gdf15`. That third token is what makes rarity and term frequency come out right
    /// — `df("gdf15")` counts the hyphenated sources too, and a paper naming GDF-15 ten
    /// times now scores like one naming GDF15 ten times, which no amount of query
    /// rewriting could fix from the outside.
    ///
    /// The original tokens stay, which is the whole reason to add rather than replace.
    /// Storing only `gdf15` would canonicalize "Windows-10" to `windows10` and lose
    /// "Windows 10" — Lucene keeps both for the same reason (`preserveOriginal` beside
    /// `catenateWords`), and emits them at one position. FTS5 can only do that through a
    /// custom tokenizer, which every connection would have to register before touching
    /// the table — including the raw-SQL paths in tools and tests — so the extra token
    /// goes in adjacent instead. The cost is one position of drift: an exact phrase
    /// query that reads *through* such a word ("circulating gdf-15 rises") no longer
    /// matches as a phrase. `NEAR` and BM25 are unaffected, and phrases that stop at the
    /// word still match.
    static func indexAnalyzedTokens(in word: some StringProtocol) -> [String] {
        let groups = alphanumericRuns(in: word)
        guard groups.count > 1 else { return groups }

        var tokens = groups
        for index in 0..<(groups.count - 1) {
            let left = groups[index]
            let right = groups[index + 1]
            // Only a letters/digits pair: a symbol written with a separator (GDF-15,
            // COVID-19, IL-6, 5-HT). Merging anything else would mangle structured text
            // — a DOI's "1038" and "s41586" are not one word.
            let isSymbolBoundary =
                (left.allSatisfy(\.isLetter) && right.allSatisfy(\.isNumber))
                || (left.allSatisfy(\.isNumber) && right.allSatisfy(\.isLetter))
            guard isSymbolBoundary else { continue }
            tokens.append(left + right)
        }
        return tokens
    }

    /// Indexed text with the analysis above applied. Words the tokenizer would split the
    /// same way either way pass through untouched, so ordinary prose is stored verbatim
    /// and only symbol-like words gain a token.
    static func indexAnalyzedText(_ text: String) -> String {
        var analyzed: [String] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            // Fast path for the overwhelming majority of words: nothing to close up.
            if word.allSatisfy({ $0.isLetter || $0.isNumber }) {
                analyzed.append(String(word))
                continue
            }
            analyzed.append(contentsOf: indexAnalyzedTokens(in: word))
        }
        return analyzed.joined(separator: " ")
    }

    /// Free text reduced to one canonical spelling per word: punctuation inside a word
    /// closes up, whitespace between words survives.
    ///
    /// The same analysis as `AnalyzedWord`, for the in-app filters that compare strings
    /// instead of querying an index — so "GDF15" finds a source titled "GDF-15 …"
    /// there too, and one definition of "the same term" serves both. Whitespace is
    /// deliberately kept: erasing it as well would let a query match across a boundary
    /// it never crossed, so that "the rapist" found "therapist".
    static func catenatedFold(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .map { alphanumericParts(in: $0).joined() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Query Terms

    /// Split a raw query into search terms. Single characters are dropped unless that
    /// would empty the query.
    static func searchTerms(for query: String) -> [String] {
        let rawTerms = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let filtered = rawTerms.filter { $0.count >= 2 }
        let terms = filtered.isEmpty ? rawTerms : filtered

        var seen = Set<String>()
        let distinct = terms.filter { seen.insert($0).inserted }
        guard distinct.count > maximumStatisticalTerms else { return distinct }

        let prefixCount = maximumStatisticalTerms / 2
        let suffixCount = maximumStatisticalTerms - prefixCount
        return Array(distinct.prefix(prefixCount)) + Array(distinct.suffix(suffixCount))
    }

    /// Build a safe FTS5 MATCH expression from already-tokenized query terms.
    ///
    /// Each term is wrapped in double quotes so it is treated as a literal string. This
    /// is both an injection guard — a raw query containing `AND`, `*`, `:`, `(` or `"`
    /// would otherwise be parsed as FTS5 operators and either error or silently change
    /// the meaning of the search — and the reason an exact term stays exact.
    ///
    /// Terms are OR-ed rather than AND-ed: a source matching only the rare term should
    /// still be found, and BM25 already ranks by how many terms hit and how rare they
    /// are. AND-ing would drop the very sources we are trying to surface.
    static func ftsMatchExpression(for terms: [String]) -> String? {
        let quoted = terms
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }
        guard !quoted.isEmpty else { return nil }
        return quoted.joined(separator: " OR ")
    }

    /// Build the strict FTS expression used by a filtering UI.
    ///
    /// Hybrid discovery intentionally treats terms as alternatives and uses semantic
    /// similarity to broaden recall. A search field that is filtering an already-known
    /// list has the opposite contract: every row added after the initial metadata pass
    /// must still satisfy everything the learner typed. Joining the same safely quoted
    /// tokens with AND preserves that distinction without provider- or query-specific
    /// branches.
    static func ftsAllTermsMatchExpression(for terms: [String]) -> String? {
        let quoted = terms
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }
        guard !quoted.isEmpty else { return nil }
        return quoted.joined(separator: " AND ")
    }

    /// The FTS5 expression for one analyzed word: its spellings as alternatives.
    ///
    /// Parts are alphanumeric by construction, so quoting is structural here rather
    /// than a filter — there is no character left in a variant that FTS5 could read as
    /// an operator.
    static func ftsAlternativeGroup(for word: AnalyzedWord) -> String? {
        let quoted = word.variants.filter { !$0.isEmpty }.map { "\"\($0)\"" }
        guard !quoted.isEmpty else { return nil }
        guard quoted.count > 1 else { return quoted[0] }
        return "(\(quoted.joined(separator: " OR ")))"
    }

    /// Build the broad discovery expression from analyzed words: alternatives within a
    /// word, alternatives across words. Same contract as the term-based overload — a
    /// source matching only the rare word should still be found, and BM25 ranks — with
    /// the spelling of each word no longer deciding whether it can match at all.
    static func ftsMatchExpression(for words: [AnalyzedWord]) -> String? {
        let groups = words.compactMap(ftsAlternativeGroup(for:))
        guard !groups.isEmpty else { return nil }
        return groups.joined(separator: " OR ")
    }

    /// Build the strict filtering expression from analyzed words: every word must be
    /// present, in any of its spellings.
    static func ftsAllTermsMatchExpression(for words: [AnalyzedWord]) -> String? {
        let groups = words.compactMap(ftsAlternativeGroup(for:))
        guard !groups.isEmpty else { return nil }
        return groups.joined(separator: " AND ")
    }

    /// Fill in IDF for a word the corpus spells differently than the learner typed it.
    ///
    /// `termIDFs` omits a term the index has never seen, which is right for a word that
    /// simply is not in the library — but "GDF15" typed against a library that writes
    /// "GDF-15" is not absent, only spelled another way. Left unmeasured it would drop
    /// out of `informativeTerms` and `precisionTerms` and, worse, make `lexicalWeight`
    /// treat the query as ordinary language — handing the ranking to a semantic branch
    /// that cannot represent a rare token at all. So when no typed token of a word is in
    /// the index, measure the word's other spellings and record the best of them under
    /// the typed tokens.
    static func variantFilledIDFs(
        _ idfs: [String: Double],
        words: [AnalyzedWord],
        corpusSize: Int,
        store: KnowledgeStore
    ) -> [String: Double] {
        guard corpusSize > 0 else { return idfs }
        var filled = idfs
        for word in words where word.parts.count > 1 {
            guard !word.typedTokens.contains(where: { filled[$0] != nil }) else { continue }
            let frequencies = word.variants.compactMap {
                try? store.sourceFTSDocumentFrequency(term: $0)
            }
            guard let frequency = frequencies.max(), frequency > 0 else { continue }
            let n = Double(corpusSize)
            let df = Double(frequency)
            let idf = log((n - df + 0.5) / (df + 0.5) + 1)
            for token in word.typedTokens {
                filled[token] = max(filled[token] ?? 0, idf)
            }
        }
        return filled
    }

    /// The analyzed words behind a chosen set of terms, so the branch that dropped
    /// common vocabulary keeps every spelling of what it kept. Falls back to the whole
    /// query when term selection and word analysis disagree — a bounded query is better
    /// than an empty one.
    static func words(_ words: [AnalyzedWord], matching terms: [String]) -> [AnalyzedWord] {
        let kept = Set(terms)
        let matching = words.filter { $0.typedTokens.contains(where: kept.contains) }
        return matching.isEmpty ? words : matching
    }

    /// The single word a term was typed as part of, for probing one constraint. Nil
    /// rather than a fallback: a probe that widened to the whole query would report
    /// every source as satisfying the constraint.
    static func word(in words: [AnalyzedWord], owning term: String) -> AnalyzedWord? {
        let owners = words.filter { $0.typedTokens.contains(term) }
        return owners.count == 1 ? owners[0] : nil
    }

    /// Build a bounded FTS5 NEAR expression. It is a ranking-only companion to the
    /// broad OR query: no result is excluded merely because its terms are farther apart.
    static func ftsProximityExpression(for terms: [String]) -> String? {
        guard terms.count >= 2, terms.count <= maximumProximityTerms else { return nil }
        let quoted = terms
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }
        guard quoted.count >= 2 else { return nil }
        return "NEAR(\(quoted.joined(separator: " ")), 10)"
    }

    /// Extract a DOI only when the complete query is structurally a DOI or doi.org URL.
    /// DOI is durable source identity, so this remains deterministic code rather than an
    /// LLM interpretation. Surrounding prose intentionally falls through to text search.
    static func doiIdentifier(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed
        if trimmed.lowercased().hasPrefix("doi:") {
            candidate = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let components = URLComponents(string: trimmed),
                  let host = components.host?.lowercased(),
                  host == "doi.org" || host == "dx.doi.org" {
            candidate = components.percentEncodedPath.removingPercentEncoding
                ?? components.percentEncodedPath
            candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        let normalized = candidate.lowercased()
        guard normalized.hasPrefix("10."),
              normalized.contains("/"),
              !normalized.contains(where: \.isWhitespace) else { return nil }
        return normalized
    }

    // MARK: - Term Statistics

    /// Inverse document frequency per query term, measured against the full-text index.
    ///
    ///     idf = ln((N - df + 0.5) / (df + 0.5) + 1)
    ///
    /// IDF rather than a raw document fraction, because a fraction misjudges rarity when
    /// the corpus is small — a term in 1 of 3 sources is "33%", which looks common, yet
    /// matching it is highly informative. IDF accounts for corpus size directly, so the
    /// same thresholds behave correctly whether the library holds 30 sources or 30,000.
    ///
    /// Computed once per search and reused for both weighting and term selection, so a
    /// query costs one document-frequency probe per term rather than one per use.
    /// Terms absent from the corpus are omitted — they say nothing about which branch to
    /// trust, and they cannot match anything in the full-text index either.
    static func termIDFs(terms: [String], corpusSize: Int, store: KnowledgeStore) -> [String: Double] {
        guard corpusSize > 0 else { return [:] }
        var idfs: [String: Double] = [:]
        for term in terms {
            guard let frequency = try? store.sourceFTSDocumentFrequency(term: term), frequency > 0 else { continue }
            let n = Double(corpusSize)
            let df = Double(frequency)
            idfs[term] = log((n - df + 0.5) / (df + 0.5) + 1)
        }
        return idfs
    }

    /// How much to trust the lexical ranking for this query, in 0…1, driven by the
    /// *rarest* query term.
    ///
    /// A high-IDF term (a gene symbol, an acronym, a proper noun) means an exact match is
    /// strong evidence and the lexical side should lead: a pooled 512-dim vector cannot
    /// represent a rare token — swapping GDF15 for GFRAL moves the vector 0.6% — so for a
    /// gene-symbol query the semantic ranking is close to noise and would otherwise let
    /// arbitrary sources outrank the true exact match. When every term is common the
    /// query is conceptual ("what raises this in the blood?") and meaning should lead.
    static func lexicalWeight(idfs: [String: Double], hasFullTextIndex: Bool) -> Float {
        guard hasFullTextIndex else { return balancedLexicalWeight }
        let highestIDF = idfs.values.max() ?? 0
        if highestIDF >= rareTermIDF { return rareTermLexicalWeight }
        if highestIDF <= commonTermIDF { return commonTermLexicalWeight }
        let t = (highestIDF - commonTermIDF) / (rareTermIDF - commonTermIDF)
        return commonTermLexicalWeight + Float(t) * (rareTermLexicalWeight - commonTermLexicalWeight)
    }

    /// The terms actually worth matching on, given what the corpus says about them.
    ///
    /// When a query carries a rare term, the ordinary words around it are noise: "what
    /// sources do I have on GDF15?" OR-ed in full retrieves every source containing
    /// "sources" or "have" and leans entirely on BM25 to dig the real answer back out.
    /// Dropping the common words in that case makes the full-text branch retrieve the
    /// GDF15 sources and little else. When *no* term is rare the query is ordinary
    /// language and every term is kept, since there is nothing to single out.
    static func informativeTerms(_ terms: [String], idfs: [String: Double]) -> [String] {
        guard let highestIDF = idfs.values.max(), highestIDF >= rareTermIDF else { return terms }
        let informative = terms.filter { (idfs[$0] ?? 0) >= commonTermIDF }
        return informative.isEmpty ? terms : informative
    }

    /// Distinct exact constraints that should lead a targeted lookup.
    ///
    /// BM25 is excellent at ranking one text query, but its document-length
    /// normalization can rank a short source matching only an author surname above a
    /// long paper matching the surname plus several topic terms. When the corpus says a
    /// query contains a genuinely rare anchor, count how many informative constraints
    /// each source satisfies before consulting BM25 or semantic rank. Conceptual queries
    /// never enter this path and continue to be led by semantic similarity.
    static func precisionTerms(_ terms: [String], idfs: [String: Double]) -> [String] {
        guard idfs.values.max() ?? 0 >= rareTermIDF else { return [] }

        var seen = Set<String>()
        let candidates = terms.enumerated().compactMap { offset, term -> (offset: Int, term: String, idf: Double)? in
            guard seen.insert(term).inserted else { return nil }
            guard let idf = idfs[term], idf >= commonTermIDF else { return nil }
            return (offset, term, idf)
        }
        guard candidates.count > 1 else { return [] }

        return candidates
            .sorted { lhs, rhs in
                if lhs.idf == rhs.idf { return lhs.offset < rhs.offset }
                return lhs.idf > rhs.idf
            }
            .prefix(maximumPrecisionTerms)
            .map(\.term)
    }

    // MARK: - Search

    /// Chunk-level nearest-neighbour lookup, injected so each call site can serve it from
    /// the process-shared in-memory vector index it already holds. `allowedSources`
    /// scopes the search and must be honored inside the index, not by filtering
    /// its output — see `SourceVectorIndex.search`.
    typealias SemanticChunkSearch = (
        _ queryVector: [Float],
        _ topK: Int,
        _ threshold: Float,
        _ allowedSources: Set<String>?,
        _ excludedSources: Set<String>
    ) -> [(sourceId: String, chunkId: String, score: Float)]

    /// Find canonical source text that satisfies every term in a list-filter query.
    ///
    /// This is intentionally not the hybrid discovery algorithm below. The sidebar is
    /// a narrowing filter, so vector-near sources and partial lexical matches must not
    /// appear a moment after the learner types. FTS serves the steady state; the same
    /// set-based content scan used by hybrid search covers the short window while the
    /// durable index is catching up.
    static func strictContentMatchIDs(
        queryText: String,
        limit: Int,
        store: KnowledgeStore,
        restrictedTo: Set<String>? = nil,
        excludedSources: Set<String> = []
    ) throws -> Set<String> {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        let allowedSources = restrictedTo.map { $0.subtracting(excludedSources) }
        if let allowedSources, allowedSources.isEmpty { return [] }

        let words = analyzedWords(for: trimmed)
        guard let expression = ftsAllTermsMatchExpression(for: words) else { return [] }

        var matches = Set(
            (try? store.searchSourceFTS(
                matchExpression: expression,
                limit: limit,
                restrictedTo: allowedSources,
                excludedSources: excludedSources
            ))?.map(\.id) ?? []
        )

        let coverage = try? store.indexCoverage(model: StorageService.sourceEmbeddingModel)
        let corpusSize = (try? store.sourceFTSDocumentCount()) ?? 0
        let indexIsBehind = (coverage.map { $0.ftsRows < $0.activeSources }) ?? (corpusSize == 0)
        if indexIsBehind, matches.count < limit {
            let scanned = (try? store.searchSourceContent(
                query: trimmed,
                maxResults: limit - matches.count,
                restrictedTo: allowedSources,
                excludedSources: excludedSources.union(matches)
            )) ?? [:]
            matches.formUnion(scanned.keys)
        }

        return matches
    }

    /// Run the full hybrid search and return fused hits, best first.
    ///
    /// `queryVector` may be nil when embedding is unavailable; search then degrades to
    /// the lexical and metadata branches rather than failing.
    ///
    /// `restrictedTo` limits every branch to an explicit set of sources, for
    /// callers ranking within a pool they have already chosen — "which of this
    /// chat's attached sources answers this?" rather than "what in the library
    /// answers this?". Each branch applies it during retrieval, so the subset
    /// gets its own ranking instead of whatever fragment of it survives a
    /// corpus-wide top-N.
    static func search(
        queryText: String,
        queryVector: [Float]?,
        limit: Int,
        threshold: Float,
        store: KnowledgeStore,
        restrictedTo: Set<String>? = nil,
        excludedSources: Set<String> = [],
        semanticChunkSearch: SemanticChunkSearch
    ) throws -> [SourceSearchHit] {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let allowedSources = restrictedTo.map { $0.subtracting(excludedSources) }
        if let allowedSources, allowedSources.isEmpty { return [] }

        let terms = searchTerms(for: trimmed)
        let words = analyzedWords(for: trimmed)
        // Fuse a wider candidate pool than we ultimately return so a strong semantic hit
        // that ranks, say, #20 lexically still survives into the fusion step.
        let poolSize = max(limit, min(max(limit * 3, 40), maximumCandidatePool))

        // Term rarity is measured against the whole library even for a scoped
        // search. Rarity is a property of the corpus — GDF15 is a rare token
        // because few sources mention it — and recomputing it over a pool of
        // 71 would call ordinary words rare and swing the branch weighting on
        // sample noise.
        let corpusSize = (try? store.sourceFTSDocumentCount()) ?? 0
        let idfs = variantFilledIDFs(
            termIDFs(terms: terms, corpusSize: corpusSize, store: store),
            words: words,
            corpusSize: corpusSize,
            store: store
        )
        let matchTerms = informativeTerms(terms, idfs: idfs)
        let matchWords = Self.words(words, matching: matchTerms)
        let exactConstraints = precisionTerms(matchTerms, idfs: idfs)
        var constraintMatchesBySource: [String: Set<String>] = [:]

        // MARK: Identifier branch — direct, indexed DOI identity lookup.
        let identifierResults: [String]
        if let doi = doiIdentifier(from: trimmed) {
            identifierResults = (try? store.searchPaperDOI(
                doi,
                limit: poolSize,
                restrictedTo: allowedSources,
                excludedSources: excludedSources
            )) ?? []
        } else {
            identifierResults = []
        }
        let identifierMatches = Set(identifierResults)

        // MARK: Semantic branch — each source scored by its best-matching chunk.
        var semanticResults: [(id: String, score: Float)] = []
        var bestChunkBySource: [String: (chunkId: String, score: Float)] = [:]
        if let queryVector {
            let chunkHits = semanticChunkSearch(
                queryVector,
                max(poolSize * 3, 120),
                threshold,
                allowedSources,
                excludedSources
            )
            var bestBySource: [String: Float] = [:]
            for hit in chunkHits {
                bestBySource[hit.sourceId] = max(bestBySource[hit.sourceId] ?? -.greatestFiniteMagnitude, hit.score)
                if hit.score > (bestChunkBySource[hit.sourceId]?.score ?? -.greatestFiniteMagnitude) {
                    bestChunkBySource[hit.sourceId] = (chunkId: hit.chunkId, score: hit.score)
                }
            }

            if bestBySource.isEmpty,
               (try? store.embeddingCount(entityType: .sourceChunk, model: StorageService.sourceEmbeddingModel)) ?? 0 == 0 {
                // A library embedded before chunk-level indexing has one vector per
                // source and no chunks at all. Fall back to those so search still works
                // while the indexer backfills. Guarded on the chunk count rather than on
                // an empty result, so a corpus that *has* chunks but where none cleared
                // the threshold stays empty instead of quietly reintroducing them.
                for hit in (try? store.findSimilar(
                    queryVector: queryVector,
                    entityType: .source,
                    model: StorageService.sourceEmbeddingModel,
                    topK: poolSize + excludedSources.count,
                    threshold: threshold
                )) ?? [] where (allowedSources?.contains(hit.id) ?? true)
                    && !excludedSources.contains(hit.id) {
                    bestBySource[hit.id] = max(bestBySource[hit.id] ?? -.greatestFiniteMagnitude, hit.score)
                }
            }

            semanticResults = bestBySource
                .map { (id: $0.key, score: $0.value) }
                .sorted(by: rankOrder)
                .prefix(poolSize)
                .map { $0 }
        }

        // MARK: Lexical branch — BM25 over the full-text index.
        // This is the half that can actually retrieve an exact term.
        var lexicalResults: [(id: String, score: Float)] = []
        if corpusSize > 0, let expression = ftsMatchExpression(for: matchWords) {
            lexicalResults = (try? store.searchSourceFTS(
                matchExpression: expression,
                limit: poolSize,
                restrictedTo: allowedSources,
                excludedSources: excludedSources
            )) ?? []

            // One bounded FTS probe per constraint records exact term coverage. The
            // normal OR query above remains the BM25 source of truth; these probes only
            // answer the narrower deterministic question "how many requested facts did
            // this source actually match?" and may contribute candidates that BM25's
            // document-length normalization pushed just outside the pool.
            if !exactConstraints.isEmpty {
                var lexicalScoreBySource = Dictionary(
                    lexicalResults.map { ($0.id, $0.score) },
                    uniquingKeysWith: { max($0, $1) }
                )
                let termPoolSize = max(poolSize * 3, 120)
                for term in exactConstraints {
                    // Probe with every spelling of the word the constraint came from,
                    // so a source that satisfies it in the other spelling still counts.
                    let constraintExpression = word(in: words, owning: term)
                        .flatMap { ftsAlternativeGroup(for: $0) }
                    guard let termExpression = constraintExpression
                            ?? ftsMatchExpression(for: [term]) else { continue }
                    let termResults = (try? store.searchSourceFTS(
                        matchExpression: termExpression,
                        limit: termPoolSize,
                        restrictedTo: allowedSources,
                        excludedSources: excludedSources
                    )) ?? []
                    for result in termResults {
                        constraintMatchesBySource[result.id, default: []].insert(term)
                        lexicalScoreBySource[result.id] = max(
                            lexicalScoreBySource[result.id] ?? -.greatestFiniteMagnitude,
                            result.score
                        )
                    }
                }
                lexicalResults = lexicalScoreBySource.map { (id: $0.key, score: $0.value) }
            }
        }

        // Grout's `ts_rank_cd` naturally lifts nearby terms. FTS5 BM25 does not,
        // so retrieve one bounded NEAR ranking and fuse it as additional evidence.
        let proximityResults: [(id: String, score: Float)]
        if corpusSize > 0, let expression = ftsProximityExpression(for: matchTerms) {
            proximityResults = (try? store.searchSourceFTS(
                matchExpression: expression,
                limit: poolSize,
                restrictedTo: allowedSources,
                excludedSources: excludedSources
            )) ?? []
        } else {
            proximityResults = []
        }

        // A source is only in the full-text index once the background indexer has reached
        // it, so a library that has just gained sources has a window where BM25 cannot
        // see them at all. While the index is behind, supplement it with a direct content
        // scan and merge on rank, so a source added moments ago is still findable by its
        // text. Once coverage catches up — the steady state — this costs one count query
        // and the scan never runs.
        let coverage = try? store.indexCoverage(model: StorageService.sourceEmbeddingModel)
        let indexIsBehind = (coverage.map { $0.ftsRows < $0.activeSources }) ?? (corpusSize == 0)
        if indexIsBehind {
            let scanQuery = exactConstraints.isEmpty
                ? trimmed
                : exactConstraints.joined(separator: " ")
            let scanned = ((try? store.searchSourceContent(
                query: scanQuery,
                maxResults: poolSize,
                restrictedTo: allowedSources,
                excludedSources: excludedSources
            )) ?? [:])
                .map { (id: $0.key, score: $0.value) }
                .sorted(by: rankOrder)
            let alreadyRanked = Set(lexicalResults.map(\.id))
            lexicalResults.append(contentsOf: scanned.filter { !alreadyRanked.contains($0.id) })
            if !exactConstraints.isEmpty {
                for result in scanned {
                    // `searchSourceContent` admits this row only when the complete scan
                    // query or every one of its terms is present.
                    constraintMatchesBySource[result.id, default: []].formUnion(exactConstraints)
                }
            }
        }

        if !exactConstraints.isEmpty {
            lexicalResults = lexicalResults
                .sorted { lhs, rhs in
                    if let covers = coversMore(
                        constraintMatchesBySource[lhs.id],
                        than: constraintMatchesBySource[rhs.id],
                        idfs: idfs
                    ) { return covers }
                    return rankOrder(lhs, rhs)
                }
                .prefix(poolSize)
                .map { $0 }
        }

        // MARK: Metadata branch — domain and parent group, which FTS does not index.
        // Fed the same informative terms as the lexical branch, so an ordinary word in a
        // question cannot pull in every source whose title happens to contain it.
        let metadataResults = (try? store.searchSourceMetadata(
            terms: exactConstraints.isEmpty ? matchTerms : exactConstraints,
            query: trimmed,
            limit: poolSize,
            restrictedTo: allowedSources,
            excludedSources: excludedSources
        )) ?? []
        if !exactConstraints.isEmpty {
            for result in metadataResults {
                constraintMatchesBySource[result.id, default: []].formUnion(result.matchedTerms)
            }
        }

        // MARK: Weighted Reciprocal Rank Fusion
        let lexical = lexicalWeight(idfs: idfs, hasFullTextIndex: corpusSize > 0)
        let semantic = 1 - lexical

        var merged: [String: (semantic: Float?, lexical: Float?, metadata: Float?, rrf: Float)] = [:]
        for (rank, result) in semanticResults.enumerated() {
            merged[result.id, default: (nil, nil, nil, 0)].semantic = result.score
            merged[result.id]!.rrf += semantic / (rrfK + Float(rank + 1))
        }
        for (rank, result) in lexicalResults.enumerated() {
            merged[result.id, default: (nil, nil, nil, 0)].lexical = result.score
            merged[result.id]!.rrf += lexical / (rrfK + Float(rank + 1))
        }
        for (rank, result) in proximityResults.enumerated() {
            var scores = merged[result.id, default: (nil, nil, nil, 0)]
            scores.lexical = max(scores.lexical ?? -.greatestFiniteMagnitude, result.score)
            scores.rrf += proximityWeight / (rrfK + Float(rank + 1))
            merged[result.id] = scores
        }
        for (rank, result) in metadataResults.enumerated() {
            merged[result.id, default: (nil, nil, nil, 0)].metadata = result.score
            merged[result.id]!.rrf += metadataWeight / (rrfK + Float(rank + 1))
        }
        for (rank, id) in identifierResults.enumerated() {
            merged[id, default: (nil, nil, nil, 0)].rrf +=
                identifierWeight / (rrfK + Float(rank + 1))
        }

        return merged
            .compactMap { id, scores in
                guard !excludedSources.contains(id) else { return nil }
                return SourceSearchHit(
                    sourceId: id,
                    score: scores.rrf,
                    semanticScore: scores.semantic,
                    lexicalScore: scores.lexical,
                    metadataScore: scores.metadata,
                    bestChunkId: bestChunkBySource[id]?.chunkId
                )
            }
            .sorted { lhs, rhs in
                let lhsIdentifier = identifierMatches.contains(lhs.sourceId)
                let rhsIdentifier = identifierMatches.contains(rhs.sourceId)
                if lhsIdentifier != rhsIdentifier { return lhsIdentifier }
                if !exactConstraints.isEmpty, let covers = coversMore(
                    constraintMatchesBySource[lhs.sourceId],
                    than: constraintMatchesBySource[rhs.sourceId],
                    idfs: idfs
                ) { return covers }
                if lhs.score == rhs.score { return lhs.sourceId < rhs.sourceId }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Whether one source's matched constraints outrank another's, nil when they
    /// tie. More constraints win; between equally many, the rarer ones do.
    ///
    /// Counting alone treats every informative term alike. "Chris Masterjohn statins
    /// criticism" has four, and a video of Masterjohn on SSRIs matches "chris" and
    /// "masterjohn" while Chris Hemsworth's episode matches "chris" and "criticism":
    /// two apiece, so semantic noise decided, and the Masterjohn video fell out of
    /// the top eight behind Hemsworth and a paper by a Chris. "masterjohn" is in 9 of
    /// 4,250 sources and "criticism" in 209, so the summed IDF of the matched terms
    /// says which pair is the stronger evidence.
    static func coversMore(
        _ lhs: Set<String>?,
        than rhs: Set<String>?,
        idfs: [String: Double]
    ) -> Bool? {
        let lhsCount = lhs?.count ?? 0
        let rhsCount = rhs?.count ?? 0
        if lhsCount != rhsCount { return lhsCount > rhsCount }
        // Summed in sorted order, so two equal sets weigh exactly the same
        // whatever order each happens to iterate in.
        func weight(_ terms: Set<String>?) -> Double {
            (terms ?? []).map { idfs[$0] ?? 0 }.sorted().reduce(0, +)
        }
        let lhsWeight = weight(lhs)
        let rhsWeight = weight(rhs)
        if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
        return nil
    }

    private static func rankOrder(_ lhs: (id: String, score: Float), _ rhs: (id: String, score: Float)) -> Bool {
        if lhs.score == rhs.score { return lhs.id < rhs.id }
        return lhs.score > rhs.score
    }
}
