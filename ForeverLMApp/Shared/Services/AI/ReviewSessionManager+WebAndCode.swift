// Part of ReviewSessionManager: code, browser and web search tools.

import Foundation
import Observation
import PDFKit
import os

extension ReviewSessionManager {
    /// Run the chat's `run_code` tool: the script on the Mac, then every
    /// picture it saved stored in the image store, so the answer can show it
    /// with the same Markdown line a drawn picture uses.
    func runCodeTool(arguments: [String: Any]) async -> AppToolResult {
        guard let codeRunner else {
            return AppToolResult(text: "Error: Code cannot be run in this chat.", isError: true)
        }
        let request: ChatCode.Request
        do {
            request = try ChatCode.parse(arguments)
        } catch {
            return AppToolResult(text: "Error: \(error.localizedDescription)", isError: true)
        }
        let outcome = await codeRunner.run(request, sessionKey: sessionID ?? codeFallbackKey)
        let (lines, unstored) = await storeCodePictures(outcome.files, summary: request.summary)
        let formatted = ChatCode.modelText(for: outcome, request: request, pictureLines: lines, unstored: unstored)
        return AppToolResult(text: formatted.text, isError: formatted.isError)
    }

    /// Keeps the pictures a script saved, off the main actor. A script that
    /// rewrites one file on every call stores a new image each time: the
    /// answer shows the one from this run.
    private func storeCodePictures(_ files: [ChatCode.OutputFile], summary: String?) async -> (lines: [String], unstored: [String]) {
        let pictures = files.filter(\.isPicture)
        guard !pictures.isEmpty else { return ([], []) }
        let notebookID = madeThingNotebookID
        let prompt = summary.map { "Made by a Python script: \($0)" } ?? "Made by a Python script run in a chat"
        return await Task.detached(priority: .userInitiated) {
            var lines: [String] = []
            var unstored: [String] = []
            for file in pictures.prefix(ChatCode.maxImagesPerRun) {
                guard file.byteCount <= ChatCode.maxImageBytes else {
                    unstored.append("\(file.name) is \(ChatCode.byteDescription(file.byteCount)), over the \(ChatCode.byteDescription(ChatCode.maxImageBytes)) a picture may be")
                    continue
                }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)),
                      let mediaType = GeneratedImageStore.mediaType(of: data) else {
                    unstored.append("\(file.name) is not an image this Mac can read")
                    continue
                }
                let base = ((file.name as NSString).lastPathComponent as NSString).deletingPathExtension
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                do {
                    let stored = try GeneratedImageStore.store(
                        GeneratedImage(data: data, mediaType: mediaType),
                        origin: .saved,
                        text: prompt,
                        title: GeneratedImageStore.cleanTitle(base),
                        model: "Python",
                        revising: nil,
                        notebookID: notebookID
                    )
                    guard let reference = stored.reference else {
                        unstored.append("\(file.name) could not be recorded")
                        continue
                    }
                    lines.append(reference.markdown(alt: base.isEmpty ? "Chart" : base))
                } catch {
                    unstored.append("\(file.name): \(error.localizedDescription)")
                }
            }
            if pictures.count > ChatCode.maxImagesPerRun {
                unstored.append("\(pictures.count - ChatCode.maxImagesPerRun) more pictures past the limit of \(ChatCode.maxImagesPerRun) a run")
            }
            return (lines, unstored)
        }.value
    }

    /// Puts the script above its output on the row, so the learner can open
    /// the step and read what ran, as in ChatGPT's code tool.
    func showCodeOnActivity(_ id: UUID, arguments: [String: Any], result: AppToolResult) {
        guard let index = chatMessages.firstIndex(where: { $0.id == id }),
              var activity = chatMessages[index].toolActivity,
              let code = (arguments["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else { return }
        let shownCode = code.count > 1_500 ? String(code.prefix(1_500)) + "\n…" : code
        let output = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        activity.resultPreview = "\(shownCode)\n\n— Output —\n\(output.prefix(1_500))"
        chatMessages[index].toolActivity = activity
    }

    /// Put a picture of the Browser tab on a running or finished browser row.
    func updateToolActivityPreview(_ id: UUID, image: Data) {
        guard let index = chatMessages.firstIndex(where: { $0.id == id }),
              var activity = chatMessages[index].toolActivity else { return }
        activity.previewImage = image
        chatMessages[index].toolActivity = activity
    }

    /// Run one `browser_*` tool through the app's Browser. The page is
    /// pictured for the learner's row as soon as it settles; a screenshot goes
    /// to the model only when the selected model reads images, and is named
    /// in the text otherwise so the model knows what the learner was shown.
    func runBrowserTool(
        name: String,
        arguments: [String: Any],
        activityID: UUID,
        config: AITaskConfig
    ) async -> ChatBrowserToolOutcome {
        guard let browserAgent else {
            return ChatBrowserToolOutcome(text: "Error: The Browser is not available in this chat.", isError: true)
        }
        var outcome = await browserAgent.run(tool: name, arguments: arguments) { [weak self] preview in
            self?.updateToolActivityPreview(activityID, image: preview)
        }
        if outcome.screenshot != nil,
           KeychainService.modelSupportsVision(provider: config.provider, model: config.model) == false {
            outcome.screenshot = nil
            outcome.text += "\n\nThe selected model reads text only, so the screenshot is shown to the learner but not to you; describe the page from browser_read_page instead of guessing at the picture."
        }
        return outcome
    }

    /// Run the chat's `fetch_web_page` tool: the page's text for the model and,
    /// on success, a citation for the reply's Web sources list.
    func fetchWebPage(arguments: [String: Any]) async -> (result: AppToolResult, citation: AIWebCitation?) {
        let rawURL = (arguments["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawURL.isEmpty else {
            return (AppToolResult(text: "Error: fetch_web_page requires a url.", isError: true), nil)
        }
        let offset: Int
        if let number = arguments["offset"] as? NSNumber {
            offset = max(0, number.intValue)
        } else if let text = arguments["offset"] as? String, let parsed = Int(text) {
            offset = max(0, parsed)
        } else {
            offset = 0
        }
        do {
            let page = try await WebPageReader.read(rawURL)
            return (
                AppToolResult(text: WebPageReader.toolResult(for: page, offset: offset), isError: false),
                AIWebCitation(url: page.url, title: page.title)
            )
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (
                AppToolResult(
                    text: "Error: Could not read \(rawURL). \(reason) Do not describe this page's content; find the information on another page or say it could not be read.",
                    isError: true
                ),
                nil
            )
        }
    }

    /// Record one round's web-search results: fold the citations into the
    /// turn's list and, when the provider searched, add a "Searched the web"
    /// row so the search is as visible in the transcript as a library lookup.
    /// The provider's search runs server-side, so the queries themselves are
    /// not available; the pages it returned are what the row can show.
    func recordWebSearchResults(
        _ found: [AIWebCitation],
        into turnCitations: inout [AIWebCitation],
        before anchorMessageID: UUID
    ) {
        let before = turnCitations.count
        turnCitations = Self.mergingWebCitations(turnCitations, adding: found)
        guard !found.isEmpty else { return }
        // Pages, not URLs: a round that returned the same paper under a second
        // publisher's link added nothing the learner can keep.
        let added = turnCitations.count - before
        let preview = found.prefix(12).map { citation -> String in
            let title = citation.title.isEmpty ? (URL(string: citation.url)?.host ?? citation.url) : citation.title
            return "• \(title) — \(citation.url)"
        }.joined(separator: "\n")
        let count = added == 0 ? found.count : added
        appendSystemActivity(
            .tool,
            slug: "web_search",
            title: "Searched the web",
            detail: "\(count) page\(count == 1 ? "" : "s")\(added == 0 ? ", all seen before" : "")",
            resultPreview: preview,
            before: anchorMessageID
        )
    }

    /// Fold a round's citations into the turn's list, one row per page. The
    /// existing list is folded too, so a turn that started before this rule
    /// still ends with one row per page.
    static func mergingWebCitations(
        _ existing: [AIWebCitation],
        adding new: [AIWebCitation]
    ) -> [AIWebCitation] {
        AIWebCitation.deduplicated(existing + new)
    }

    /// Rounds of one Deep Research turn that may carry the provider's web tool.
    /// Each round is already bounded by `AIWebSearchDepth.deepResearch`; this
    /// bounds the turn. Forty rounds is what a thorough run over a broad
    /// question takes — a plan, a few dozen search-and-read rounds, the
    /// notes, the report — without letting a loop that never converges buy
    /// search bundles indefinitely. Page reads are app tools and not counted.
    static let deepResearchWebSearchRoundBudget = 40

    /// The heading that introduces the cited-pages list under a web-searched
    /// reply. `splitWebSourcesFooter` finds the list by it, so the two stay in
    /// step.
    static let webSourcesFooterHeading = "**Web sources**"

    /// Most cited pages listed under one reply. The Mac renders the list as
    /// native rows with an Add action, so it is compact even at this size; the
    /// cap is a final guard against citation-heavy answers, not a design target.
    static let webSourcesFooterMaximum = 20

    /// Appends a "Web sources" list of citation links to a reply, in plain
    /// markdown so it persists through the ordinary transcript path and syncs
    /// like any other text. Every cited page is listed, including ones the
    /// reply links inline: the list is the place a learner keeps a page from,
    /// so a page must not disappear from it because the model also linked it
    /// mid-sentence. The stream parser feeds this only output annotations,
    /// never the provider's raw search pool.
    static func appendingWebSourcesFooter(to text: String, citations: [AIWebCitation]) -> String {
        let listed = AIWebCitation.deduplicated(citations).prefix(webSourcesFooterMaximum)
        guard !listed.isEmpty else { return text }
        let lines = listed.enumerated().map { index, citation -> String in
            let fallbackTitle = URL(string: citation.url)?.host ?? citation.url
            let title = citation.title.isEmpty ? fallbackTitle : citation.title
            // Square brackets inside a link label would end it early.
            let safeTitle = title
                .replacingOccurrences(of: "[", with: "(")
                .replacingOccurrences(of: "]", with: ")")
            return "\(index + 1). [\(safeTitle)](\(citation.url))"
        }
        return text + "\n\n\(webSourcesFooterHeading)\n" + lines.joined(separator: "\n")
    }

    /// A markdown link to a web page: its label and its http(s) target. Image
    /// references are not links, and a link whose target holds whitespace or
    /// parentheses is left for the renderer as it is.
    private nonisolated static func webLinkPattern() -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]*)\]\((https?://[^\s()<>]+)\)"#)
    }

    /// The distinct http(s) targets of the markdown links in `text`, in order.
    nonisolated static func webLinkTargets(in text: String) -> [String] {
        var seen = Set<String>()
        var targets: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in webLinkPattern().matches(in: text, range: range) {
            guard let targetRange = Range(match.range(at: 2), in: text) else { continue }
            let target = String(text[targetRange])
            if seen.insert(target).inserted { targets.append(target) }
        }
        return targets
    }

    /// Web links to pages the learner already keeps become library citations:
    /// `[label](https://…)` turns into `[label](foreverlm://source/ID)` when
    /// `sourceID` knows the page, so the chat draws the numbered citation and
    /// source card it draws for any library source, not a bare link out to the
    /// web. A web-searched reply reaches for the page on the web even when the
    /// same page sits in the library; this puts the citation where the learner's
    /// copy is. Links the lookup does not know are left as they are, and so is
    /// the Web sources footer, which stays the place a page is kept from —
    /// apply this to the body before the footer goes on.
    nonisolated static func linkingLibrarySources(in text: String, sourceID: (String) -> String?) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = webLinkPattern().matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let targetRange = Range(match.range(at: 2), in: result),
                  let id = sourceID(String(result[targetRange])),
                  !id.isEmpty else { continue }
            result.replaceSubrange(targetRange, with: "foreverlm://source/\(id)")
        }
        return result
    }

    /// `linkingLibrarySources(in:sourceID:)` against the library: a page counts
    /// when an active source has its normalized URL.
    func linkingLibrarySources(in text: String) async -> String {
        let targets = Self.webLinkTargets(in: text)
        guard !targets.isEmpty else { return text }
        var ids: [String: String] = [:]
        for target in targets {
            if let record = await storage.sourceRecordByNormalizedURL(URLNormalizer.normalize(target)),
               record.status == .active {
                ids[target] = record.id
            }
        }
        guard !ids.isEmpty else { return text }
        return Self.linkingLibrarySources(in: text) { ids[$0] }
    }

    /// The inverse of `appendingWebSourcesFooter`: the reply body without the
    /// footer, and the cited pages the footer listed. Replies without a footer
    /// come back whole with no citations, so a caller can always render the
    /// body and decide separately whether there is a list to show.
    ///
    /// The footer is recognised only at the end of the reply — a heading and
    /// then nothing but numbered markdown links — so a reply that merely
    /// mentions "Web sources" in prose is left alone.
    static func splitWebSourcesFooter(_ content: String) -> (body: String, citations: [AIWebCitation]) {
        guard let headingRange = content.range(of: "\n\n\(webSourcesFooterHeading)\n", options: .backwards) else {
            return (content, [])
        }
        let tail = content[headingRange.upperBound...]
        var citations: [AIWebCitation] = []
        for rawLine in tail.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let dot = line.firstIndex(of: "."),
                  Int(line[..<dot]) != nil,
                  let open = line[dot...].firstIndex(of: "["),
                  let close = line[open...].range(of: "]("),
                  line.hasSuffix(")") else {
                return (content, [])
            }
            let title = String(line[line.index(after: open)..<close.lowerBound])
            let url = String(line[close.upperBound..<line.index(before: line.endIndex)])
            guard let parsed = URL(string: url),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return (content, [])
            }
            citations.append(AIWebCitation(url: url, title: title))
        }
        guard !citations.isEmpty else { return (content, []) }
        // Replies written before citations were deduplicated by page carry the
        // duplicates in their saved markdown, so the list is folded on the way
        // out as well as on the way in.
        return (String(content[..<headingRange.lowerBound]), AIWebCitation.deduplicated(citations))
    }
}
