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
/// special cases and mis-nest, so they were removed rather than maintained.
///
/// The judgment still has to happen somewhere. Until now only the plain text
/// received it, from the Source Content Cleanup model, which runs downstream of
/// archival; the reader document kept every navigation menu, share bar,
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
