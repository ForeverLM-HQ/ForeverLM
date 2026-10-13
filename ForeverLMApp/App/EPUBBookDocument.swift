#if os(macOS)
import Foundation

/// A whole EPUB book as one document, so the Mac reader scrolls through it the
/// way it scrolls through a PDF book (`BookPDFAssembly`).
///
/// An EPUB import stores one file per chapter under the book's `Chapters`
/// folder, and the reader used to show one of them at a time: the end of a
/// chapter was a footer to click, and Find stopped there. Here every chapter's
/// body is copied, in reading order, into one page, each inside its own
/// `<section data-flm-chapter="<source id>">`. The chapter stays the unit
/// everything is stored in — its highlights are anchored in its own section's
/// text, and its reading position is a fraction of its own section — so
/// nothing is written back to the chapter files and a chapter's notes mean the
/// same thing here as on a device that reads it alone.
///
/// Resource references are rewritten relative to the `Chapters` folder, the
/// root a chapter's address names. A book kept as one file (`EPUBBookFiles`)
/// has no such folder on disk: its page is served from memory, and its
/// pictures and stylesheets from the book's file, under `EPUBBookScheme` at
/// the same paths. A book still unpacked has the page written into its
/// `Chapters` folder as a hidden file (`writingFile()`) and loaded with read
/// access to that folder: WebKit gives a page loaded from a string no access
/// to `file:` pictures or stylesheets at all, whatever its base URL.
struct EPUBBookDocument: Equatable, Sendable {
    struct Input: Sendable {
        let sourceID: String
        let title: String
        /// Absolute path of the chapter's file.
        let path: String
    }

    struct Chapter: Equatable, Sendable {
        let sourceID: String
        let title: String
        /// Absolute path of the chapter's file, standardized.
        let path: String
    }

    /// The book's `Chapters` folder, as a directory URL: a `file:` URL for a
    /// book still unpacked, an `EPUBBookScheme` URL for one kept as one file.
    let baseURL: URL
    let html: String
    /// The chapters in the document, in reading order: those whose file could
    /// be read. A chapter whose file is not on this Mac is left out rather
    /// than blocking the book.
    let chapters: [Chapter]
    /// Where `html` was written, once `writingFile()` has; nil before, or
    /// when the folder could not be written to.
    var fileURL: URL?

    /// The hidden file the page is written to, in the `Chapters` folder.
    static let fileName = ".foreverlm-book.html"

    /// The URL WebKit shows the book at: the written file, else the folder.
    var documentURL: URL { fileURL ?? baseURL }

    /// Writes the page into the `Chapters` folder, only when it changed —
    /// reopening a book rewrites nothing. File work: off the main actor. A
    /// folder that refuses the write leaves `fileURL` nil, and the book still
    /// reads, without its pictures and publisher styles. A book kept as one
    /// file writes nothing: its page is served from memory at that path.
    func writingFile() -> EPUBBookDocument {
        var written = self
        if !baseURL.isFileURL, let folder = EPUBBookScheme.path(of: baseURL) {
            let path = (folder as NSString).appendingPathComponent(Self.fileName)
            EPUBBookScheme.register(page: html, atPath: path)
            written.fileURL = EPUBBookScheme.url(forPath: path)
            return written
        }
        let url = baseURL.appendingPathComponent(Self.fileName, isDirectory: false)
        let data = Data(html.utf8)
        if FileManager.default.contents(atPath: url.path) != data {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return written
            }
        }
        written.fileURL = url
        return written
    }

    /// The attribute every chapter section carries, valued with its source id.
    static let chapterAttribute = "data-flm-chapter"
    /// The chapter file's path relative to `baseURL`, so a link to it can be
    /// followed inside the book.
    static let chapterPathAttribute = "data-flm-chapter-path"

    /// Identifies the document for the web view, which reloads only when it
    /// changes.
    var key: String {
        "epub-book:\(baseURL.path)#\(chapters.map(\.sourceID).joined(separator: ","))"
    }

    func index(ofSourceID sourceID: String) -> Int? {
        chapters.firstIndex { $0.sourceID == sourceID }
    }

    func contains(sourceID: String) -> Bool {
        index(ofSourceID: sourceID) != nil
    }

    /// Reads every chapter file and writes the book. File work: callers stay
    /// off the main actor.
    ///
    /// The book is the chapters in the `Chapters` folder of `anchorPath` — the
    /// chapter being opened — or else of the first chapter; one filed from
    /// another folder is left out. Nil when no chapter could be read.
    static func assemble(_ inputs: [Input], anchoredAt anchorPath: String? = nil) -> EPUBBookDocument? {
        let standardized = inputs.map { input in
            Input(
                sourceID: input.sourceID,
                title: input.title,
                path: URL(fileURLWithPath: input.path).standardizedFileURL.path
            )
        }
        guard let anchor = anchorPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) ?? standardized.first?.path,
              let chaptersURL = EPUBKitReaderSupport.chaptersDirectory(containing: anchor) else { return nil }
        let chaptersDir = chaptersURL.path

        var stylesheets: [String] = []
        var seenStylesheets = Set<String>()
        var headStyles: [String] = []
        var seenHeadStyles = Set<String>()
        var sections: [String] = []
        var chapters: [Chapter] = []
        var language: String?

        for input in standardized {
            // The base URL grants read access to this one folder, so a chapter
            // from anywhere else could not load its pictures or styles.
            guard input.path.hasPrefix(chaptersDir + "/"),
                  let raw = readMarkup(at: input.path) else { continue }

            let head = headHTML(of: raw)
            for tag in HTMLTagAttributes.tags(named: "link", in: head) {
                guard let rel = tag["rel"]?.lowercased(),
                      rel.split(whereSeparator: { $0.isWhitespace }).contains("stylesheet"),
                      let href = tag["href"],
                      let rebased = EPUBParser.rebasedLocalReference(href, from: input.path, toDirectory: chaptersDir),
                      seenStylesheets.insert(rebased).inserted else { continue }
                stylesheets.append(rebased)
            }
            for style in inlineStyles(in: head) {
                let rebased = rebasingCSSURLs(in: style, from: input.path, toDirectory: chaptersDir)
                guard seenHeadStyles.insert(rebased).inserted else { continue }
                headStyles.append(rebased)
            }
            if language == nil {
                language = HTMLTagAttributes.tags(named: "html", in: raw).first.flatMap { $0["lang"] ?? $0["xml:lang"] }
            }

            let bodyTag = HTMLTagAttributes.tags(named: "body", in: raw).first
            var body = EPUBParser.extractBodyHTML(raw, removesMedia: false)
            body = EPUBParser.rebaseLocalResourceReferences(in: body, from: input.path, toDirectory: chaptersDir)
            body = expandingSelfClosingTags(in: body)

            let relativePath = String(input.path.dropFirst(chaptersDir.count + 1))
            var attributes = [
                "class=\"\(escapeAttribute((["flm-book-chapter"] + [bodyTag?["class"]].compactMap { $0 }).joined(separator: " ")))\"",
            ]
            // The body's own id stays on its section: publisher CSS and
            // links (`chapter.xhtml#body-id`) name it.
            if let id = bodyTag?["id"], !id.isEmpty {
                attributes.append("id=\"\(escapeAttribute(id))\"")
            }
            attributes.append("\(chapterAttribute)=\"\(escapeAttribute(input.sourceID))\"")
            attributes.append("\(chapterPathAttribute)=\"\(escapeAttribute(relativePath))\"")
            sections.append("<section \(attributes.joined(separator: " "))>\n\(body)\n</section>")
            chapters.append(Chapter(sourceID: input.sourceID, title: input.title, path: input.path))
        }

        guard !chapters.isEmpty else { return nil }

        // No `Chapters` folder on disk: the book is its one file, read through the scheme.
        var isDirectory: ObjCBool = false
        let unpacked = FileManager.default.fileExists(atPath: chaptersDir, isDirectory: &isDirectory) && isDirectory.boolValue
        guard let baseURL = unpacked
            ? URL(fileURLWithPath: chaptersDir, isDirectory: true)
            : EPUBBookScheme.url(forPath: chaptersDir, isDirectory: true) else { return nil }

        let links = stylesheets
            .map { "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(escapeAttribute($0))\"/>" }
            .joined(separator: "\n")
        let styles = headStyles.map { "<style>\n\($0)\n</style>" }.joined(separator: "\n")
        let lang = language.map { " lang=\"\(escapeAttribute($0))\"" } ?? ""
        let html = """
        <!DOCTYPE html>
        <html\(lang)>
        <head>
        <meta charset="utf-8"/>
        \(links)
        \(styles)
        </head>
        <body class="flm-book">
        \(sections.joined(separator: "\n"))
        </body>
        </html>
        """
        return EPUBBookDocument(
            baseURL: baseURL,
            html: html,
            chapters: chapters,
            fileURL: nil
        )
    }

    // MARK: - Markup

    /// EPUB chapters are usually UTF-8; a few older exports are Latin-1. Read
    /// from the book's file when the book is kept as one.
    private static func readMarkup(at path: String) -> String? {
        EPUBBookFiles.text(atPath: path)
    }

    private static func headHTML(of html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<head\b[^>]*>([\s\S]*?)</head>"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html) else { return "" }
        return String(html[range])
    }

    private static func inlineStyles(in head: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<style\b[^>]*>([\s\S]*?)</style>"#, options: .caseInsensitive) else { return [] }
        return regex.matches(in: head, range: NSRange(head.startIndex..<head.endIndex, in: head)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: head) else { return nil }
            let css = String(head[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return css.isEmpty ? nil : css
        }
    }

    /// A stylesheet written into a chapter's head resolved `url(…)` against
    /// the chapter's folder; in the book it resolves against `Chapters`.
    private static func rebasingCSSURLs(in css: String, from sourcePath: String, toDirectory targetDir: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"url\(\s*(["']?)([^"')]+)\1\s*\)"#, options: .caseInsensitive) else { return css }
        var rebased = css
        for match in regex.matches(in: css, range: NSRange(css.startIndex..<css.endIndex, in: css)).reversed() {
            guard let whole = Range(match.range(at: 0), in: rebased),
                  let valueRange = Range(match.range(at: 2), in: rebased),
                  let newValue = EPUBParser.rebasedLocalReference(
                    String(rebased[valueRange]),
                    from: sourcePath,
                    toDirectory: targetDir
                  ) else { continue }
            rebased.replaceSubrange(whole, with: "url(\"\(newValue)\")")
        }
        return rebased
    }

    /// Chapter files are XHTML, where `<a id="x"/>` is an empty element. The
    /// book is parsed as HTML, which reads that as an *open* `<a>` and wraps
    /// the rest of the chapter in it. Write every self-closed element that is
    /// not void in HTML as an explicit open-close pair.
    static func expandingSelfClosingTags(in html: String) -> String {
        let pattern = #"<(?!(?:area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)[\s/>])([A-Za-z][A-Za-z0-9:_.-]*)(\s[^<>]*?)?\s*/>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return html }
        return regex.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..<html.endIndex, in: html),
            withTemplate: "<$1$2></$1>"
        )
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Where the reader is in an assembled book: a chapter, and how far through
/// its section the reading line is (0 at its top, 1 past its end).
struct EPUBBookPosition: Equatable, Sendable {
    let sourceID: String
    let fraction: Double
}

/// What the book page reports over `bookPosition` as the learner scrolls.
struct EPUBBookPositionReport: Equatable, Sendable {
    let position: EPUBBookPosition
    /// Chapters scrolled past to their end since the last report, in order:
    /// each is read to its end. Only after a scroll the learner made, and
    /// never across more than a couple of chapters at once.
    let passedSourceIDs: [String]
    let userInitiated: Bool

    init(position: EPUBBookPosition, passedSourceIDs: [String] = [], userInitiated: Bool = false) {
        self.position = position
        self.passedSourceIDs = passedSourceIDs
        self.userInitiated = userInitiated
    }

    init?(body: Any) {
        guard let payload = body as? [String: Any],
              let chapter = payload["chapter"] as? String, !chapter.isEmpty,
              let fraction = (payload["fraction"] as? NSNumber)?.doubleValue,
              fraction.isFinite else { return nil }
        self.init(
            position: EPUBBookPosition(sourceID: chapter, fraction: min(max(fraction, 0), 1)),
            passedSourceIDs: (payload["passed"] as? [String] ?? []).filter { !$0.isEmpty && $0 != chapter },
            userInitiated: (payload["userInitiated"] as? NSNumber)?.boolValue ?? false
        )
    }
}

/// A scroll the host asks of the book on screen. `token` makes asking for the
/// same place twice a second request.
struct EPUBBookJump: Equatable, Sendable {
    enum Mode: String, Sendable {
        /// The chapter's top at the top of the window: Contents, the chevrons.
        case start
        /// The saved reading line: a chapter chosen outside the reader.
        case resume
    }

    let position: EPUBBookPosition
    let mode: Mode
    let token: Int
}
#endif
