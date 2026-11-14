import Foundation
import os

private let logger = Logger(subsystem: "com.foreverlm", category: "ArticleChromeFilter")

/// Removes a publisher's site furniture from a fetched page before ForeverLM
/// derives anything from it.
///
/// A web article produces two artifacts, and both descend from
/// `SourceService.readerHTML(from:)`: the archived reader document
/// (`Articles/<id>/article.html`) and the extracted plain text. That function
/// deliberately sanitizes markup without judging which visible text belongs to
/// the article — class-name heuristics like `<div class="ad-…">` accumulate
/// special cases and mis-nest, so none is kept.
///
/// The judgment still has to happen somewhere. The plain text receives it
/// from the Source Content Cleanup model, which runs downstream of
/// archival; without this stage the reader document keeps every navigation menu, share bar,
/// newsletter appeal, comment form and login dialog the page shipped with. This
/// stage asks the same question one step earlier, where a single answer serves
/// both artifacts.
///
/// The split of responsibility follows the house rule: deterministic code owns
/// identity, the model supplies meaning. Parsing the document, choosing region
/// boundaries, and deleting exact character ranges are all mechanical here. The
/// model only names which regions are the site rather than the article, and a
/// failed, slow, or unconfigured call costs nothing but the cleanup.
enum ArticleChromeFilter {

    /// One structural slice of a page, addressed by a stable ID.
    ///
    /// Regions are disjoint and cover the document in order, so a plan that
    /// names some of them deletes exact ranges without any nesting question.
    struct Region: Sendable, Equatable {
        let id: String
        let tag: String
        let attributes: String
        let text: String
        let range: Range<String.Index>
    }

    /// Element that ends itself; a matching close tag is optional or invalid.
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Tags whose content reads as prose rather than layout. A container filled
    /// with these is the article body itself, so splitting stops there instead
    /// of handing the model one region per paragraph — a question the
    /// downstream text cleanup already answers, line by line.
    private static let proseTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "dl",
        "blockquote", "figure", "pre", "table",
    ]

    /// Tags that start a new block. Publishers leave `<p>` unclosed constantly,
    /// and HTML says any of these ends it — without that rule an unclosed
    /// paragraph swallows the rest of the page, and the footer after it stops
    /// being separately addressable.
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "div", "dl",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hgroup", "hr", "main", "menu", "nav", "ol",
        "p", "pre", "section", "table", "ul",
    ]

    /// Whether opening `opening` ends an already-open `open` element. These are
    /// the tags that cannot legally contain themselves or each other.
    private static func implicitlyCloses(_ opening: String, _ open: String) -> Bool {
        switch open {
        case "p": return blockTags.contains(opening)
        case "li": return opening == "li"
        case "dt", "dd": return opening == "dt" || opening == "dd"
        case "td", "th": return ["td", "th", "tr"].contains(opening)
        case "tr": return opening == "tr"
        case "option": return opening == "option" || opening == "optgroup"
        default: return false
        }
    }

    /// Regions below this size stay whole. Scaled against document length in
    /// `regions(in:)` so a long page yields a comparable region count to a
    /// short one rather than an outline nobody can afford to send.
    private static let minimumSplitCharacters = 1_200

    /// A page nested more deeply than this is layout scaffolding, not structure
    /// worth resolving further.
    private static let maximumSplitDepth = 10

    /// Beyond this the outline stops being a cheap question. Pages this
    /// fragmented are usually indexes rather than articles; keep them whole.
    private static let maximumRegionCount = 300

    /// A plan that leaves less than this share of the page's visible text is
    /// treated as a misread rather than a thorough cleanup, and discarded.
    private static let minimumSurvivingTextFraction = 0.25

    /// The smallest article worth keeping the filter's answer for.
    private static let minimumSurvivingTextCharacters = 400

    // MARK: - Entry point

    /// Return `html` with the publisher's site furniture removed, or `html`
    /// unchanged when the page cannot be filtered.
    ///
    /// Never throws. Ingestion of a readable page must not fail because its
    /// chrome could not be identified — the article still archives, and the
    /// downstream text cleanup still runs over the extracted text.
    static func filteringSiteChrome(
        in html: String,
        source: AIUsageSource,
        pageURL: URL,
        articleTitle: String?,
        aiService: AIService = AIService()
    ) async -> String {
        guard let config = KeychainService.resolveConfig(for: .articleChromeFiltering) else {
            logger.info("Skipping article chrome filtering: no configured model.")
            return html
        }
        let regions = regions(in: html)
        guard regions.count >= 2 else { return html }
        guard regions.count <= maximumRegionCount else {
            logger.info("Skipping article chrome filtering: \(regions.count) regions exceeds the outline budget.")
            return html
        }

        let system = AITask.articleChromeFiltering.effectivePrompt
            ?? Prompts.articleChromeFiltering
        let removedIDs: Set<String>
        do {
            removedIDs = try await aiService.articleChromeRegionPlan(
                source: source,
                pageURL: pageURL,
                articleTitle: articleTitle,
                regions: regions,
                config: config,
                system: system
            )
        } catch {
            logger.warning("Article chrome filtering failed: \(error.localizedDescription)")
            return html
        }
        return applying(removedIDs, to: html, regions: regions)
    }

    /// Delete the named regions, unless doing so would take the article with
    /// them. Separated from the network call so the guard is directly testable.
    static func applying(
        _ removedIDs: Set<String>,
        to html: String,
        regions: [Region]
    ) -> String {
        let removed = regions.filter { removedIDs.contains($0.id) }
        guard !removed.isEmpty else { return html }

        let totalText = regions.reduce(0) { $0 + $1.text.count }
        let removedText = removed.reduce(0) { $0 + $1.text.count }
        let survivingText = totalText - removedText
        guard survivingText >= minimumSurvivingTextCharacters,
              Double(survivingText) >= Double(totalText) * minimumSurvivingTextFraction else {
            logger.warning(
                "Discarding article chrome plan: it would leave \(survivingText) of \(totalText) characters."
            )
            return html
        }

        // Regions are disjoint, so removing them back to front keeps every
        // remaining range valid without recomputing indices.
        var filtered = html
        for region in removed.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            filtered.removeSubrange(region.range)
        }
        logger.info(
            "Article chrome filtering removed \(removed.count) regions (\(removedText) of \(totalText) characters)."
        )
        return filtered
    }

    // MARK: - Structural regions

    /// Split a page into the disjoint regions the model is asked about.
    ///
    /// This is pure document structure: descend through layout wrappers until
    /// the children are individually small enough to classify, and stop at any
    /// container whose children are prose. No tag, class, or role decides
    /// meaning here — those only travel to the model as hints.
    static func regions(in html: String) -> [Region] {
        let nodes = parse(html)
        guard !nodes.isEmpty else { return [] }

        let roots: [Node]
        if let body = firstNode(named: "body", in: nodes) {
            roots = body.children
        } else {
            roots = nodes
        }

        let documentText = roots.reduce(0) { $0 + visibleText(of: html, in: $1.outerRange).count }
        // Long pages get proportionally larger regions so the outline's size
        // tracks the number of distinct page parts, not the word count.
        let threshold = max(minimumSplitCharacters, documentText / 12)

        var collected: [(Node, Int)] = []
        collect(roots, in: html, depth: 1, threshold: threshold, into: &collected)

        return collected.enumerated().compactMap { index, entry in
            let text = visibleText(of: html, in: entry.0.outerRange)
            guard !text.isEmpty else { return nil }
            return Region(
                id: String(format: "R%06d", index + 1),
                tag: entry.0.tag,
                attributes: normalizedAttributes(entry.0.attributes),
                text: text,
                range: entry.0.outerRange
            )
        }
    }

    private static func collect(
        _ nodes: [Node],
        in html: String,
        depth: Int,
        threshold: Int,
        into collected: inout [(Node, Int)]
    ) {
        for node in nodes {
            let text = visibleText(of: html, in: node.outerRange)
            guard !text.isEmpty else { continue }
            let splittable = depth < maximumSplitDepth
                && text.count > threshold
                && !node.children.isEmpty
                && !isProseContainer(node, in: html)
            if splittable {
                collect(node.children, in: html, depth: depth + 1, threshold: threshold, into: &collected)
            } else {
                collected.append((node, depth))
            }
        }
    }

    /// Whether a node's children read as article prose rather than page layout.
    private static func isProseContainer(_ node: Node, in html: String) -> Bool {
        let populated = node.children.filter { !visibleText(of: html, in: $0.outerRange).isEmpty }
        guard populated.count >= 2 else { return false }
        let prose = populated.filter { proseTags.contains($0.tag) }.count
        return Double(prose) >= Double(populated.count) * 0.6
    }

    private static func firstNode(named tag: String, in nodes: [Node]) -> Node? {
        for node in nodes {
            if node.tag == tag { return node }
            if let match = firstNode(named: tag, in: node.children) { return match }
        }
        return nil
    }

    // MARK: - Outline

    /// Serialize the regions as the compact JSON the model is asked about.
    /// Previews carry the head and tail of each region because the boundary
    /// between article and furniture usually shows at one end or the other.
    static func outlineJSON(for regions: [Region]) -> String {
        let entries = regions.map { region -> String in
            let attributes = String(region.attributes.prefix(120))
            let preview: String
            if region.text.count > 240 {
                preview = "\(region.text.prefix(150)) … \(region.text.suffix(60))"
            } else {
                preview = region.text
            }
            return """
            {"id":"\(region.id)","tag":"\(region.tag)","attributes":"\(AIService.jsonEscaped(attributes))","characters":\(region.text.count),"text":"\(AIService.jsonEscaped(preview))"}
            """
        }
        return "[\n\(entries.joined(separator: ",\n"))\n]"
    }

    private static func normalizedAttributes(_ attributes: String) -> String {
        attributes
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Minimal document tree

    /// One element with its byte range in the original document. Ranges index
    /// the untouched HTML so a plan deletes exactly what the model saw.
    struct Node: Sendable {
        let tag: String
        let attributes: String
        let outerRange: Range<String.Index>
        let children: [Node]
    }

    private struct Token {
        let isClose: Bool
        let tag: String
        let attributes: String
        let isSelfClosing: Bool
        let range: Range<String.Index>
    }

    private struct Frame {
        let tag: String
        let attributes: String
        let outerStart: String.Index
        var children: [Node]
    }

    private static let tagExpression = try? NSRegularExpression(
        pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:"[^"]*"|'[^']*'|[^>"'])*?)(/?)>"#,
        options: []
    )

    private static let inertExpression = try? NSRegularExpression(
        pattern: #"<script\b[\s\S]*?</script>|<style\b[\s\S]*?</style>|<noscript\b[\s\S]*?</noscript>|<iframe\b[\s\S]*?</iframe>|<!--[\s\S]*?-->"#,
        options: [.caseInsensitive]
    )

    /// Build a shallow element tree. Malformed markup is expected: a stray
    /// close tag is ignored, an unclosed element is closed by its parent, and a
    /// tag that cannot nest in itself closes the previous one.
    static func parse(_ html: String) -> [Node] {
        guard let tagExpression else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let inertRanges = inertExpression?
            .matches(in: html, options: [], range: range)
            .map(\.range) ?? []

        var tokens: [Token] = []
        tagExpression.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match,
                  let tokenRange = Range(match.range, in: html),
                  let tagRange = Range(match.range(at: 2), in: html) else { return }
            // A `<` inside a script or comment is not markup.
            if inertRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) { return }
            let attributes = Range(match.range(at: 3), in: html).map { String(html[$0]) } ?? ""
            tokens.append(
                Token(
                    isClose: match.range(at: 1).length > 0,
                    tag: String(html[tagRange]).lowercased(),
                    attributes: attributes,
                    isSelfClosing: match.range(at: 4).length > 0,
                    range: tokenRange
                )
            )
        }

        var stack: [Frame] = [
            Frame(tag: "", attributes: "", outerStart: html.startIndex, children: [])
        ]

        func close(upTo index: Int, endingAt end: String.Index) {
            while stack.count > index {
                let frame = stack.removeLast()
                let node = Node(
                    tag: frame.tag,
                    attributes: frame.attributes,
                    outerRange: frame.outerStart..<max(end, frame.outerStart),
                    children: frame.children
                )
                stack[stack.count - 1].children.append(node)
            }
        }

        for token in tokens {
            if token.isClose {
                guard let index = stack.lastIndex(where: { $0.tag == token.tag }), index > 0 else {
                    continue
                }
                close(upTo: index, endingAt: token.range.upperBound)
            } else if token.isSelfClosing || voidTags.contains(token.tag) {
                stack[stack.count - 1].children.append(
                    Node(
                        tag: token.tag,
                        attributes: token.attributes,
                        outerRange: token.range,
                        children: []
                    )
                )
            } else {
                while stack.count > 1,
                      let open = stack.last?.tag,
                      implicitlyCloses(token.tag, open) {
                    close(upTo: stack.count - 1, endingAt: token.range.lowerBound)
                }
                stack.append(
                    Frame(
                        tag: token.tag,
                        attributes: token.attributes,
                        outerStart: token.range.lowerBound,
                        children: []
                    )
                )
            }
        }
        close(upTo: 1, endingAt: html.endIndex)
        return stack[0].children
    }

    // MARK: - Text

    /// The visible text of one range, normalized the way the outline shows it.
    static func visibleText(of html: String, in range: Range<String.Index>) -> String {
        guard range.lowerBound < range.upperBound else { return "" }
        var text = String(html[range])
        if let inertExpression {
            text = inertExpression.stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: " "
            )
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.decodingHTMLCharacterReferences()
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - A learner's reading version of one article

/// How one learner asked to read one article: the exact pieces of its text the
/// Reader hides. The article, its saved page and its text are never touched, so
/// chat, search and the highlights keep the original; this is a view of it.
struct ArticleReadingView: Codable, Equatable, Sendable {
    var instruction: String
    /// Verbatim pieces of the article's text, each hidden wherever it appears.
    var removals: [String]
    var createdAt: Date
    /// Off shows the original page while keeping the list, so switching back is
    /// instant and costs no model call.
    var isShown: Bool
}

extension Notification.Name {
    /// Posted with the source ID in `userInfo["sourceID"]` whenever a source's
    /// reading view is made, switched or removed, so an open Reader redraws.
    static let articleReadingViewChanged = Notification.Name("ForeverLM.articleReadingViewChanged")
}

/// The reading views, one JSON file per source beside the article archives but
/// outside them: refreshing an article replaces its archive directory, and a
/// learner's reading choice must survive that. Mac only; nothing here syncs.
enum ArticleReadingViewStore {
    private static var directoryURL: URL {
        ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent("ArticleReadingViews", isDirectory: true)
    }

    static func fileURL(sourceID: String) -> URL {
        let name = sourceID.replacingOccurrences(of: "/", with: "_")
        return directoryURL.appendingPathComponent("\(name).json")
    }

    static func load(sourceID: String) -> ArticleReadingView? {
        guard let data = try? Data(contentsOf: fileURL(sourceID: sourceID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ArticleReadingView.self, from: data)
    }

    static func save(_ view: ArticleReadingView, sourceID: String) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(view).write(to: fileURL(sourceID: sourceID), options: .atomic)
        announce(sourceID)
    }

    /// Switch between the learner's reading version and the original.
    @discardableResult
    static func setShown(_ shown: Bool, sourceID: String) -> ArticleReadingView? {
        guard var view = load(sourceID: sourceID) else { return nil }
        view.isShown = shown
        try? save(view, sourceID: sourceID)
        return view
    }

    static func remove(sourceID: String) {
        try? FileManager.default.removeItem(at: fileURL(sourceID: sourceID))
        announce(sourceID)
    }

    private static func announce(_ sourceID: String) {
        NotificationCenter.default.post(
            name: .articleReadingViewChanged,
            object: nil,
            userInfo: ["sourceID": sourceID]
        )
    }
}

/// Makes a reading view from the learner's own words. The model reads the
/// article and names verbatim pieces to hide; the app checks each one really is
/// in the text before keeping it. The model's judgment is the whole of what is
/// hidden: nothing here decides, by pattern, what a citation or an ad is.
enum ArticleReadingViewService {
    enum Failure: LocalizedError {
        case emptyInstruction
        case noText
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .emptyInstruction:
                return "Say how you want to read this article, for example: remove the inline citations."
            case .noText:
                return "This article has no saved text to read."
            case .unavailable(let reason):
                return reason
            }
        }
    }

    /// Characters of article text per model call. Smaller windows leave a
    /// model less to skim past, and run side by side.
    static let chunkCharacters = 9_000
    private static let concurrentChunks = 4

    /// Ask the model, save the list, and return it. An answer that hides
    /// nothing is returned but not saved, so a failed attempt never replaces a
    /// reading view that worked.
    static func make(
        sourceID: String,
        title: String,
        instruction rawInstruction: String,
        aiService: AIService = AIService()
    ) async throws -> ArticleReadingView {
        let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { throw Failure.emptyInstruction }
        guard let config = KeychainService.resolveConfig(for: .articleChromeFiltering) else {
            throw Failure.unavailable(
                KeychainService.backgroundAIUnavailableMessage(for: .articleChromeFiltering)
                    ?? "No model is configured for article cleanup. Choose one in Settings."
            )
        }
        let text = (await StorageService().loadSourceContent(sourceID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.noText }

        let chunks = chunks(of: PaperContentPreparationService.semanticBlocks(text))
        let source = AIUsageSource(id: sourceID, sourceType: .article, title: title)
        let removals = try await AIUsageAttribution.withSource(source) {
            try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
                var found: [Int: [String]] = [:]
                var next = 0
                func addNext() {
                    guard next < chunks.count else { return }
                    let index = next
                    next += 1
                    group.addTask {
                        let pieces = try await aiService.articleReadingViewRemovals(
                            source: source,
                            blocks: chunks[index],
                            instruction: instruction,
                            config: config
                        )
                        return (index, pieces)
                    }
                }
                for _ in 0..<min(concurrentChunks, chunks.count) { addNext() }
                while let (index, pieces) = try await group.next() {
                    found[index] = pieces
                    addNext()
                }
                var seen = Set<String>()
                return (0..<chunks.count).flatMap { found[$0] ?? [] }.filter { seen.insert($0).inserted }
            }
        }

        let view = ArticleReadingView(
            instruction: instruction,
            removals: removals,
            createdAt: Date(),
            isShown: true
        )
        if !removals.isEmpty { try ArticleReadingViewStore.save(view, sourceID: sourceID) }
        return view
    }

    static func chunks(of blocks: [AIService.PaperContentBlock]) -> [[AIService.PaperContentBlock]] {
        var chunks: [[AIService.PaperContentBlock]] = []
        var current: [AIService.PaperContentBlock] = []
        var size = 0
        for block in blocks {
            if size + block.text.count > chunkCharacters, !current.isEmpty {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(block)
            size += block.text.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

extension AIService {
    private struct ReadingViewPlan: Decodable {
        struct Removal: Decodable {
            let blockID: String
            let exactText: String
        }
        let removals: [Removal]
    }

    func articleReadingViewRemovals(
        source: AIUsageSource,
        blocks: [PaperContentBlock],
        instruction: String,
        config: AITaskConfig
    ) async throws -> [String] {
        guard !blocks.isEmpty else { return [] }
        let tagged = blocks.map { block in
            "{\"id\":\"\(block.id)\",\"text\":\"\(Self.jsonEscaped(block.text))\"}"
        }.joined(separator: ",\n")
        let user = """
        READER'S INSTRUCTION:
        \(instruction)

        AUTHORITATIVE SOURCE TITLE:
        \(source.title)

        BLOCKS JSON:
        [
        \(tagged)
        ]
        """
        let response = try await call(
            config: config,
            system: Prompts.articleReadingView,
            user: user,
            // A long article can carry hundreds of citations, each one a short
            // verbatim item; the ceiling only has to let the JSON close.
            maxTokens: 16_384,
            temperature: 0,
            allowsReasoningInflation: false,
            disablesReasoning: true,
            allowsResponseCache: false,
            jsonMode: true,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )
        return try Self.validatedReadingViewRemovals(response, blocks: blocks)
    }

    /// Keep only pieces that are really in the block the model named, and long
    /// enough to be unambiguous when they are hidden everywhere they appear.
    nonisolated static func validatedReadingViewRemovals(
        _ response: String,
        blocks: [PaperContentBlock]
    ) throws -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last {
            json = String(trimmed[first...last])
        } else {
            json = trimmed
        }
        guard let data = json.data(using: .utf8),
              let plan = try? JSONDecoder().decode(ReadingViewPlan.self, from: data) else {
            throw AIError.apiError("Reading view returned an invalid plan.")
        }
        let textByID = Dictionary(blocks.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var kept: [String] = []
        for removal in plan.removals {
            guard let text = textByID[removal.blockID],
                  removal.exactText.count <= 400,
                  removal.exactText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3,
                  text.contains(removal.exactText),
                  seen.insert(removal.exactText).inserted else { continue }
            kept.append(removal.exactText)
        }
        return kept
    }
}

// MARK: - A paper's reading view

/// A paper re-set as one flowing column, its inline citations drawn as
/// superscript numbers (product owner, 2026-11-13, of a review article with a
/// paragraph of names in every sentence: "is it possible for you to show them
/// in a way that removes those and replaces them with superscript numbers?";
/// offered the page with gaps, the citations faded, or this, they chose
/// this). A PDF's lines cannot close up, so this is a second way to read the
/// paper beside its PDF, never in place of it: the PDF, the paper's text and
/// its references are not touched, and Show PDF is one click away.
struct PaperReadingView: Codable, Equatable, Sendable {
    /// One inline citation, as the paragraph writes it.
    struct Citation: Codable, Equatable, Sendable {
        var exactText: String
        /// Which occurrence of `exactText` in the paragraph, from 1.
        var occurrence: Int
    }

    struct Paragraph: Codable, Equatable, Sendable {
        var text: String
        var isHeading: Bool
        var citations: [Citation]
    }

    var paragraphs: [Paragraph]
    var createdAt: Date
    /// Off shows the PDF while keeping the view, so switching back is instant
    /// and costs no model call.
    var isShown: Bool

    var citationCount: Int { paragraphs.reduce(0) { $0 + $1.citations.count } }
}

extension Notification.Name {
    /// Posted with the source ID in `userInfo["sourceID"]` whenever a paper's
    /// reading view is made, switched or removed, so an open Reader redraws.
    static let paperReadingViewChanged = Notification.Name("ForeverLM.paperReadingViewChanged")
}

/// The papers' reading views, one JSON file per source. Mac only; nothing
/// here syncs. What was last read or saved is kept in memory, so the Reader
/// asks on every draw without going to the disk again.
enum PaperReadingViewStore {
    /// Each source's view as last read or saved; `.some(nil)` is a source
    /// known to have none.
    private static let cache = OSAllocatedUnfairLock<[String: PaperReadingView?]>(initialState: [:])

    private static var directoryURL: URL {
        ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent("PaperReadingViews", isDirectory: true)
    }

    static func fileURL(sourceID: String) -> URL {
        let name = sourceID.replacingOccurrences(of: "/", with: "_")
        return directoryURL.appendingPathComponent("\(name).json")
    }

    static func load(sourceID: String) -> PaperReadingView? {
        if let known = cache.withLock({ $0[sourceID] }) { return known }
        var view: PaperReadingView?
        if let data = try? Data(contentsOf: fileURL(sourceID: sourceID)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            view = try? decoder.decode(PaperReadingView.self, from: data)
        }
        cache.withLock { $0[sourceID] = .some(view) }
        return view
    }

    static func save(_ view: PaperReadingView, sourceID: String) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(view).write(to: fileURL(sourceID: sourceID), options: .atomic)
        cache.withLock { $0[sourceID] = .some(view) }
        announce(sourceID)
    }

    /// Switch between the reading view and the PDF.
    static func setShown(_ shown: Bool, sourceID: String) throws {
        guard var view = load(sourceID: sourceID) else { return }
        view.isShown = shown
        try save(view, sourceID: sourceID)
    }

    static func remove(sourceID: String) throws {
        let url = fileURL(sourceID: sourceID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        cache.withLock { $0[sourceID] = .some(nil) }
        announce(sourceID)
    }

    private static func announce(_ sourceID: String) {
        NotificationCenter.default.post(
            name: .paperReadingViewChanged,
            object: nil,
            userInfo: ["sourceID": sourceID]
        )
    }
}

/// What the model said of a paper's lines (`Prompts.paperReadingViewLayout`):
/// which begin a paragraph, which are headings, which are page furniture.
struct PaperReadingLayout: Equatable, Sendable {
    var paragraphStarts: Set<String> = []
    var headings: Set<String> = []
    var removed: Set<String> = []

    func merging(_ other: PaperReadingLayout) -> PaperReadingLayout {
        PaperReadingLayout(
            paragraphStarts: paragraphStarts.union(other.paragraphStarts),
            headings: headings.union(other.headings),
            removed: removed.union(other.removed)
        )
    }
}

/// One piece of a paragraph as the reading view draws it.
enum PaperReadingRun: Equatable, Sendable {
    case text(String)
    /// A citation as superscript numbers: each the number shown and the
    /// ordinal of the reference it opens.
    case citation([PaperReadingCitedReference])
}

struct PaperReadingCitedReference: Equatable, Sendable {
    let number: Int
    let ordinal: Int
}

/// Putting a paper's reading view together from what the model named. Pure:
/// the model decides what a paragraph and a citation are; this only joins
/// lines, checks a named citation is really in its paragraph, and counts.
enum PaperReadingViewBuilder {
    /// The paper's lines joined into paragraphs: a removed line is dropped, a
    /// heading stands alone, and a paragraph runs from one start to the next,
    /// its lines joined as Listen joins them (a word broken at a line's end
    /// closed up).
    static func paragraphs(
        lines: [AIService.PaperContentBlock],
        layout: PaperReadingLayout
    ) -> [PaperReadingView.Paragraph] {
        var paragraphs: [PaperReadingView.Paragraph] = []
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            let text = CloudArticleTTS.reflowedForSpeech(current.joined(separator: "\n"))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                paragraphs.append(PaperReadingView.Paragraph(text: text, isHeading: false, citations: []))
            }
            current = []
        }
        for line in lines where !layout.removed.contains(line.id) {
            if layout.headings.contains(line.id) {
                flush()
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    paragraphs.append(PaperReadingView.Paragraph(text: text, isHeading: true, citations: []))
                }
            } else {
                if layout.paragraphStarts.contains(line.id) { flush() }
                current.append(line.text)
            }
        }
        flush()
        return paragraphs
    }

    /// The paragraphs as blocks for the citation pass, numbered in order.
    static func blocks(of paragraphs: [PaperReadingView.Paragraph]) -> [AIService.PaperContentBlock] {
        paragraphs.enumerated().map { index, paragraph in
            AIService.PaperContentBlock(id: String(format: "B%06d", index + 1), text: paragraph.text)
        }
    }

    /// The named citations that really are in `text`, in the order they are
    /// written, none overlapping another.
    static func located(
        _ citations: [PaperReadingView.Citation],
        in text: String
    ) -> [(citation: PaperReadingView.Citation, range: Range<String.Index>)] {
        var found: [(citation: PaperReadingView.Citation, range: Range<String.Index>)] = []
        for citation in citations {
            guard citation.occurrence > 0,
                  !citation.exactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let range = PaperContentPreparationService.occurrenceRange(
                      of: citation.exactText,
                      occurrence: citation.occurrence,
                      in: text
                  ),
                  !found.contains(where: { $0.range.overlaps(range) }) else { continue }
            found.append((citation, range))
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The view as it is drawn: each paragraph's text with its citations as
    /// numbers. A numbered paper keeps its own numbers; an author-year paper
    /// is numbered in the order its references are first cited, as a numbered
    /// journal would. A citation that names no entry of the stored list stays
    /// as the paper wrote it, rather than vanish with nothing to open.
    static func runs(
        of paragraphs: [PaperReadingView.Paragraph],
        index: PaperReferenceIndex
    ) -> [[PaperReadingRun]] {
        var numberOfOrdinal: [Int: Int] = [:]
        func number(_ reference: PaperReference) -> Int {
            if let own = Int(reference.label.trimmingCharacters(in: .whitespaces)) { return own }
            if let given = numberOfOrdinal[reference.ordinal] { return given }
            let next = numberOfOrdinal.count + 1
            numberOfOrdinal[reference.ordinal] = next
            return next
        }
        return paragraphs.map { paragraph in
            guard !paragraph.isHeading else { return [.text(paragraph.text)] }
            var runs: [PaperReadingRun] = []
            var cursor = paragraph.text.startIndex
            for (citation, range) in located(paragraph.citations, in: paragraph.text) {
                let references = index.references(forMarker: citation.exactText)
                guard !references.isEmpty else { continue }
                if cursor < range.lowerBound { runs.append(.text(String(paragraph.text[cursor..<range.lowerBound]))) }
                runs.append(.citation(references.map { PaperReadingCitedReference(number: number($0), ordinal: $0.ordinal) }))
                cursor = range.upperBound
            }
            if cursor < paragraph.text.endIndex { runs.append(.text(String(paragraph.text[cursor...]))) }
            return runs
        }
    }
}

/// Makes a paper's reading view: two model passes over the paper's text, one
/// for its paragraphs and one for its citations, asked for by the learner
/// from the Reader's ⋯ menu and never on a timer. The model's judgment is the
/// whole of what a paragraph or a citation is; nothing here decides by
/// pattern.
enum PaperReadingViewService {
    enum Failure: LocalizedError {
        case noText
        case noParagraphs
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .noText:
                return "This paper has no saved text to re-set yet."
            case .noParagraphs:
                return "The model returned no paragraphs for this paper."
            case .unavailable(let reason):
                return reason
            }
        }
    }

    /// Characters of paper text per model call, and how many calls run side
    /// by side.
    static let chunkCharacters = 12_000
    private static let concurrentChunks = 4

    static func make(
        sourceID: String,
        title: String,
        aiService: AIService = AIService()
    ) async throws -> PaperReadingView {
        guard let config = KeychainService.resolveConfig(for: .paperTextToSpeechPreparation) else {
            throw Failure.unavailable(
                KeychainService.backgroundAIUnavailableMessage(for: .paperTextToSpeechPreparation)
                    ?? "No model is configured for preparing papers. Choose one in Settings."
            )
        }
        let text = (await StorageService().loadSourceContent(sourceID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.noText }

        let lines = PaperContentPreparationService.semanticBlocks(text)
        let source = AIUsageSource(id: sourceID, sourceType: .paper, title: title)
        return try await AIUsageAttribution.withSource(source) {
            let layouts = try await inChunks(of: lines) { chunk in
                try await aiService.paperReadingViewLayout(source: source, blocks: chunk, config: config)
            }
            let layout = layouts.reduce(PaperReadingLayout()) { $0.merging($1) }
            var paragraphs = PaperReadingViewBuilder.paragraphs(lines: lines, layout: layout)
            guard !paragraphs.isEmpty else { throw Failure.noParagraphs }

            let blocks = PaperReadingViewBuilder.blocks(of: paragraphs)
            let cited = try await inChunks(of: blocks) { chunk in
                try await aiService.paperReadingViewCitations(source: source, blocks: chunk, config: config)
            }
            let indexByID = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) })
            for (blockID, citation) in cited.flatMap({ $0 }) {
                guard let index = indexByID[blockID], !paragraphs[index].isHeading else { continue }
                paragraphs[index].citations.append(citation)
            }
            for index in paragraphs.indices {
                paragraphs[index].citations = PaperReadingViewBuilder
                    .located(paragraphs[index].citations, in: paragraphs[index].text)
                    .map(\.citation)
            }
            let view = PaperReadingView(paragraphs: paragraphs, createdAt: Date(), isShown: true)
            try PaperReadingViewStore.save(view, sourceID: sourceID)
            return view
        }
    }

    static func chunks(of blocks: [AIService.PaperContentBlock]) -> [[AIService.PaperContentBlock]] {
        var chunks: [[AIService.PaperContentBlock]] = []
        var current: [AIService.PaperContentBlock] = []
        var size = 0
        for block in blocks {
            if size + block.text.count > chunkCharacters, !current.isEmpty {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(block)
            size += block.text.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// `work` over the blocks' chunks, a few at a time, its results in chunk
    /// order.
    private static func inChunks<Result: Sendable>(
        of blocks: [AIService.PaperContentBlock],
        _ work: @escaping @Sendable ([AIService.PaperContentBlock]) async throws -> Result
    ) async throws -> [Result] {
        let chunks = chunks(of: blocks)
        return try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var found: [Int: Result] = [:]
            var next = 0
            func addNext() {
                guard next < chunks.count else { return }
                let index = next
                next += 1
                group.addTask { (index, try await work(chunks[index])) }
            }
            for _ in 0..<min(concurrentChunks, chunks.count) { addNext() }
            while let (index, result) = try await group.next() {
                found[index] = result
                addNext()
            }
            return (0..<chunks.count).compactMap { found[$0] }
        }
    }
}

extension AIService {
    private struct PaperReadingLayoutPlan: Decodable {
        let paragraphStarts: [String]
        let headings: [String]
        let remove: [String]
    }

    private struct PaperReadingCitationPlan: Decodable {
        struct Item: Decodable {
            let blockID: String
            let exactText: String
            let occurrence: Int
        }
        let citations: [Item]
    }

    private static func taggedBlocksJSON(_ blocks: [PaperContentBlock]) -> String {
        blocks.map { block in
            "{\"id\":\"\(block.id)\",\"text\":\"\(Self.jsonEscaped(block.text))\"}"
        }.joined(separator: ",\n")
    }

    private nonisolated static func jsonObject(in response: String) -> Data? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last {
            return String(trimmed[first...last]).data(using: .utf8)
        }
        return trimmed.data(using: .utf8)
    }

    func paperReadingViewLayout(
        source: AIUsageSource,
        blocks: [PaperContentBlock],
        config: AITaskConfig
    ) async throws -> PaperReadingLayout {
        guard !blocks.isEmpty else { return PaperReadingLayout() }
        let user = """
        AUTHORITATIVE SOURCE TITLE:
        \(source.title)

        BLOCKS JSON:
        [
        \(Self.taggedBlocksJSON(blocks))
        ]
        """
        let response = try await call(
            config: config,
            system: Prompts.paperReadingViewLayout,
            user: user,
            // The answer is block IDs alone; the ceiling only has to let the
            // JSON close on a chunk of short lines.
            maxTokens: 16_384,
            temperature: 0,
            allowsReasoningInflation: false,
            allowsResponseCache: false,
            jsonMode: true,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )
        return try Self.validatedPaperReadingLayout(response, blocks: blocks)
    }

    /// The layout with only this chunk's IDs in it; a line named a heading
    /// or removed is not also a paragraph's start.
    nonisolated static func validatedPaperReadingLayout(
        _ response: String,
        blocks: [PaperContentBlock]
    ) throws -> PaperReadingLayout {
        guard let data = jsonObject(in: response),
              let plan = try? JSONDecoder().decode(PaperReadingLayoutPlan.self, from: data) else {
            throw AIError.apiError("Reading view returned an invalid paragraph plan.")
        }
        let known = Set(blocks.map(\.id))
        let removed = Set(plan.remove).intersection(known)
        let headings = Set(plan.headings).intersection(known).subtracting(removed)
        let starts = Set(plan.paragraphStarts).intersection(known).subtracting(removed).subtracting(headings)
        return PaperReadingLayout(paragraphStarts: starts, headings: headings, removed: removed)
    }

    func paperReadingViewCitations(
        source: AIUsageSource,
        blocks: [PaperContentBlock],
        config: AITaskConfig
    ) async throws -> [(blockID: String, citation: PaperReadingView.Citation)] {
        guard !blocks.isEmpty else { return [] }
        let user = """
        AUTHORITATIVE SOURCE TITLE:
        \(source.title)

        BLOCKS JSON:
        [
        \(Self.taggedBlocksJSON(blocks))
        ]
        """
        let response = try await call(
            config: config,
            system: Prompts.paperReadingViewCitations,
            user: user,
            // A review article cites in every sentence, each citation a
            // verbatim item of up to a few hundred characters.
            maxTokens: 32_768,
            temperature: 0,
            allowsReasoningInflation: false,
            allowsResponseCache: false,
            jsonMode: true,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )
        return try Self.validatedPaperReadingCitations(response, blocks: blocks)
    }

    /// The citations that really are in the block the model named.
    nonisolated static func validatedPaperReadingCitations(
        _ response: String,
        blocks: [PaperContentBlock]
    ) throws -> [(blockID: String, citation: PaperReadingView.Citation)] {
        guard let data = jsonObject(in: response),
              let plan = try? JSONDecoder().decode(PaperReadingCitationPlan.self, from: data) else {
            throw AIError.apiError("Reading view returned an invalid citation plan.")
        }
        let textByID = Dictionary(blocks.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        return plan.citations.compactMap { item in
            guard let text = textByID[item.blockID],
                  item.occurrence > 0,
                  item.exactText.count <= 1_200,
                  PaperContentPreparationService.occurrenceRange(of: item.exactText, occurrence: item.occurrence, in: text) != nil
            else { return nil }
            return (item.blockID, PaperReadingView.Citation(exactText: item.exactText, occurrence: item.occurrence))
        }
    }
}
