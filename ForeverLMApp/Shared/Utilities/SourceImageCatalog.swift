import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif

/// One picture the catalog found, with enough words for a model to pick it and
/// for the transcript to label it.
struct SourceImageEntry: Equatable, Sendable {
    let reference: SourceImageReference
    /// What names the picture: a `<figcaption>`, alt text, or the printed
    /// "Figure 3-4 …" line on the page. Empty when the source gave it no name.
    let caption: String
    /// Text found right after the picture, so a caption the publisher set as
    /// an ordinary paragraph still lets a query find the figure.
    let context: String

    var locationDescription: String {
        switch reference.location {
        case .page(let page): return "page \(page)"
        case .image(let ordinal): return "image \(ordinal)"
        case .slide(let index): return "slide \(index)"
        case .moment(let seconds): return "frame at \(SlideFrameExtraction.displayTime(Double(seconds)))"
        }
    }

    /// The Markdown line the assistant includes verbatim.
    var markdown: String {
        let alt = caption.isEmpty ? "Image, \(locationDescription)" : caption
        return reference.markdown(alt: Self.shortened(alt, limit: 120))
    }

    static func shortened(_ text: String, limit: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Finds and renders the pictures inside a source file.
///
/// Two file shapes carry pictures. A markup chapter (EPUB `.xhtml`, an archived
/// article) holds `<img>` tags whose files sit beside it; a PDF (a paper, a
/// chapter of a PDF-split book) holds figures on pages. The catalog speaks
/// about both through `SourceImageReference`, so the chat tool, the Mac
/// renderer, and the web client all agree on what "image 2" or "page 9" is.
///
/// Every function here does file and PDF work: callers stay off the main actor.
enum SourceImageCatalog {
    /// Listing more than this without a query buries the one the learner meant.
    static let maxEntries = 12
    /// Longest side of a rendered page or crop. A chat column is narrower than
    /// this; the headroom is for the copy the learner pastes elsewhere.
    static let maxRenderedPixelSize = 1600

    enum Failure: Error, Equatable {
        case fileUnavailable
        case unsupportedFormat(String)
        case noImages
        case noMatch(query: String, available: [String])
        /// The words are in the file, but only on pages of prose.
        case noPictureMatching(query: String, available: [String])
        case pageOutOfRange(requested: Int, pageCount: Int)
        /// The page exists and carries no picture: a title page, a page of
        /// paragraphs. Showing it hands the learner a wall of text.
        case pageWithoutPicture(requested: Int, available: [String])
        case slideOutOfRange(requested: Int, available: [Int])

        var message: String {
            switch self {
            case .fileUnavailable:
                return "The source file is not on this device, so its pictures cannot be listed."
            case .unsupportedFormat(let ext):
                return "Pictures can be shown from PDF and EPUB chapter files; this source is a .\(ext) file."
            case .noImages:
                return "This source has no pictures in it."
            case .noMatch(let query, let available):
                return "Nothing in this source matches \"\(query)\". \(Self.availableSuffix(available))"
            case .noPictureMatching(let query, let available):
                // Said precisely, because the model reads this and speaks to
                // the learner from it: the words *are* in the source. What is
                // missing is a picture on the pages carrying them, and saying
                // "no match" here had the tutor report the topic as absent.
                return """
                "\(query)" appears in this source, but only in its text: no page that mentions it \
                has a picture on it. Answer from the text instead of showing a page. \
                \(Self.availableSuffix(available))
                """
            case .pageOutOfRange(let requested, let pageCount):
                return "Page \(requested) does not exist; the file has \(pageCount) pages."
            case .pageWithoutPicture(let requested, let available):
                return """
                Page \(requested) has no picture on it, only text, so showing it would put a page \
                of prose in the answer. \(Self.availableSuffix(available))
                """
            case .slideOutOfRange(let requested, let available):
                let numbers = available.map(String.init).joined(separator: ", ")
                return "Slide \(requested) does not exist; the captured slides are numbered \(numbers)."
            }
        }

        /// Names the figures the file does have, so a refusal is also the
        /// listing the caller needs to ask again correctly.
        private static func availableSuffix(_ available: [String]) -> String {
            available.isEmpty
                ? "The source has no captioned figures to show."
                : "Available: \(available.joined(separator: "; "))."
        }
    }

    // MARK: - Listing

    /// Lists the pictures of the file at `filePath`, narrowed by `query`
    /// (figure label or caption words) or pinned to one PDF `page`. A book
    /// chapter's `filePath` names its pages of the book's file
    /// (`StudioArticle.resolvedFileLocation`), and its pages count from the
    /// chapter's first.
    static func entries(
        sourceID: String,
        filePath: String,
        query: String?,
        page: Int?
    ) throws -> [SourceImageEntry] {
        let location = SourcePDFPages(stored: filePath)
        // A file on disk, or a chapter of an EPUB book kept as one file (`EPUBBookFiles`).
        guard EPUBBookFiles.exists(atPath: location.path) else { throw Failure.fileUnavailable }
        let ext = URL(fileURLWithPath: location.path).pathExtension.lowercased()
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ext == "pdf" {
            #if os(macOS)
            guard let document = location.document() else {
                throw Failure.fileUnavailable
            }
            return try pdfEntries(sourceID: sourceID, document: document, query: trimmedQuery, page: page)
            #else
            throw Failure.unsupportedFormat(ext)
            #endif
        }
        if EPUBParser.isMarkupChapter(filePath) {
            guard let html = readMarkup(at: filePath) else { throw Failure.fileUnavailable }
            return try markupEntries(sourceID: sourceID, html: html, query: trimmedQuery)
        }
        throw Failure.unsupportedFormat(ext.isEmpty ? "unknown" : ext)
    }

    // MARK: Slides

    /// The slide frames captured from a video or recording, read from the
    /// "Extracted video slide frames" block of its stored `content`.
    ///
    /// The frame number a slide's file has in the video's stored block — the
    /// identity a `slide/<n>` reference needs when all that is known is the
    /// file a model or an old transcript named. The block is the authority; a
    /// file it does not name (a re-extraction renamed the deck, say) falls back
    /// to the number the capture wrote into the file name itself.
    static func slideFrameIndex(for path: SourceImageReference.SlideFramePath, in content: String) -> Int? {
        if SlideFrameExtraction.containsSlideSection(content) {
            let named = YouTubeSlideContentParser.parse(content).slides.first { frame in
                frame.imagePath.split(separator: "/").last.map(String.init) == path.fileName
            }
            if let named { return named.index }
        }
        return path.fileNameIndex
    }

    /// A frame carries no text of its own, so what a query is matched against is
    /// what the frame *is* to a listener: its number and the stretches of the
    /// talk it was on screen for (the caption), and the words spoken during
    /// those stretches (the context) — "the slide that shows the electron
    /// transport chain" is the one on screen while the speaker was explaining
    /// it. Frames the vision pass marked as camera shots of the room are left
    /// out, the way the reader leaves them out. `slide` pins one frame by the
    /// number a previous listing gave it.
    static func slideEntries(
        sourceID: String,
        content: String,
        query: String?,
        slide: Int?
    ) throws -> [SourceImageEntry] {
        let parsed = YouTubeSlideContentParser.parse(content)
        let slides = parsed.displaySlides
        guard !slides.isEmpty else { throw Failure.noImages }
        let spoken = spokenWords(during: slides, transcript: parsed.transcriptContent)
        let all = slides.map { frame in
            SourceImageEntry(
                reference: SourceImageReference(sourceID: sourceID, location: .slide(frame.index)),
                caption: slideCaption(frame),
                context: spoken[frame.index] ?? ""
            )
        }
        if let slide {
            guard let pinned = all.first(where: { $0.reference.location == .slide(slide) }) else {
                throw Failure.slideOutOfRange(requested: slide, available: slides.map(\.index))
            }
            return [pinned]
        }
        return try narrowed(all, query: query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// "Slide 4 (12:03–13:10, 21:00–21:40)", plus any text a vision pass has
    /// already read off the frame.
    static func slideCaption(_ frame: YouTubeSlideFrameContext) -> String {
        let windows = frame.windows.map { window -> String in
            guard let end = window.end else { return SlideFrameExtraction.displayTime(window.start) }
            return "\(SlideFrameExtraction.displayTime(window.start))–\(SlideFrameExtraction.displayTime(end))"
        }
        var caption = "Slide \(frame.index)"
        if !windows.isEmpty {
            caption += " (\(windows.joined(separator: ", ")))"
        } else if let time = frame.timeSeconds {
            caption += " (\(SlideFrameExtraction.displayTime(time)))"
        }
        let recognized = frame.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !recognized.isEmpty {
            caption += " — \(SourceImageEntry.shortened(recognized, limit: 160))"
        }
        return caption
    }

    /// The transcript words spoken while each slide was on screen, keyed by
    /// slide number. A window written without an end closes
    /// at the next slide's start, as the reader closes it. The segment already
    /// being spoken when a slide appears belongs to it too: a presenter puts a
    /// slide up mid-sentence, and that sentence is usually what names it.
    static func spokenWords(
        during slides: [YouTubeSlideFrameContext],
        transcript: String
    ) -> [Int: String] {
        let segments = YouTubeTranscriptDisplayParser.parse(transcript).segments
        let timed = segments.compactMap { segment -> (start: Double, text: String)? in
            guard let start = YouTubeTranscriptTime.seconds(from: segment.startTime) else { return nil }
            return (start, segment.text)
        }
        guard !timed.isEmpty else { return [:] }
        let starts = slides.compactMap(\.timeSeconds).sorted()

        var result: [Int: String] = [:]
        for frame in slides {
            var windows = frame.windows.map { window -> (start: Double, end: Double) in
                if let end = window.end { return (window.start, max(window.start, end)) }
                let next = starts.first(where: { $0 > window.start + 0.25 })
                return (window.start, next ?? window.start + 45)
            }
            if windows.isEmpty, let time = frame.timeSeconds {
                let next = starts.first(where: { $0 > time + 0.25 })
                windows = [(time, next ?? time + 45)]
            }
            guard !windows.isEmpty else { continue }

            var picked: [String] = []
            var seen = Set<Int>()
            for window in windows {
                // The segment under way as the slide comes up, then every
                // segment that starts while it stays up.
                if let current = timed.lastIndex(where: { $0.start <= window.start + 0.25 }),
                   seen.insert(current).inserted {
                    picked.append(timed[current].text)
                }
                for (index, segment) in timed.enumerated()
                where segment.start > window.start + 0.25 && segment.start < window.end && seen.insert(index).inserted {
                    picked.append(segment.text)
                }
            }
            let words = picked.joined(separator: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !words.isEmpty { result[frame.index] = words }
        }
        return result
    }

    // MARK: Markup

    /// Every `<img>`/`<image>` tag in the body, in document order, which is
    /// what makes the ordinal the same on every device that holds the markup.
    static func markupImageTags(inBody body: String) -> [(tag: String, range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<(img|image)\b[^>]*?/?>"#,
            options: .caseInsensitive
        ) else { return [] }
        return regex.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body))
            .compactMap { match in
                guard let range = Range(match.range(at: 0), in: body) else { return nil }
                return (String(body[range]), range)
            }
    }

    /// The body every client works from: the same normalization and body
    /// extraction as the reader document, media kept.
    static func markupBody(fromHTML html: String) -> String {
        EPUBParser.extractBodyHTML(EPUBParser.normalizeImageDataURIs(in: html), removesMedia: false)
    }

    static func markupEntries(sourceID: String, html: String, query: String) throws -> [SourceImageEntry] {
        let body = markupBody(fromHTML: html)
        let tags = markupImageTags(inBody: body)
        guard !tags.isEmpty else { throw Failure.noImages }

        var all: [SourceImageEntry] = []
        for (index, item) in tags.enumerated() {
            let caption = markupCaption(for: item, in: body)
            // The text after a picture belongs to it only up to the next
            // picture: otherwise every figure's context would quote the
            // captions of the ones that follow, and a query for a later figure
            // would match them all.
            let nextTagStart = index + 1 < tags.count ? tags[index + 1].range.lowerBound : body.endIndex
            let context = markupContext(after: item.range, in: body, upTo: nextTagStart)
            all.append(SourceImageEntry(
                reference: SourceImageReference(sourceID: sourceID, location: .image(index + 1)),
                caption: caption,
                context: context
            ))
        }
        return try narrowed(all, query: query)
    }

    /// A `<figcaption>` inside the enclosing `<figure>` names the picture best;
    /// alt text is next; otherwise the picture stays unnamed and `context`
    /// carries whatever text follows it.
    private static func markupCaption(for item: (tag: String, range: Range<String.Index>), in body: String) -> String {
        if let figcaption = enclosingFigureCaption(around: item.range, in: body) {
            return figcaption
        }
        if let alt = EPUBParser.attributeValue("alt", in: item.tag)?
            .decodingHTMLCharacterReferences()
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !alt.isEmpty, alt.lowercased() != "image" {
            return SourceImageEntry.shortened(alt, limit: 200)
        }
        return ""
    }

    private static func enclosingFigureCaption(around range: Range<String.Index>, in body: String) -> String? {
        // Search back for the nearest <figure> open tag, then confirm its close
        // tag lies after the image; otherwise the image is not inside it.
        guard let openRegex = try? NSRegularExpression(pattern: #"<figure\b[^>]*>"#, options: .caseInsensitive),
              let closeRegex = try? NSRegularExpression(pattern: #"</figure\s*>"#, options: .caseInsensitive),
              let captionRegex = try? NSRegularExpression(
                pattern: #"<figcaption\b[^>]*>([\s\S]*?)</figcaption\s*>"#,
                options: .caseInsensitive
              ) else { return nil }
        let before = NSRange(body.startIndex..<range.lowerBound, in: body)
        guard let open = openRegex.matches(in: body, range: before).last,
              let openRange = Range(open.range, in: body) else { return nil }
        let afterOpen = NSRange(openRange.upperBound..<body.endIndex, in: body)
        guard let close = closeRegex.firstMatch(in: body, range: afterOpen),
              let closeRange = Range(close.range, in: body),
              closeRange.lowerBound > range.upperBound else { return nil }
        let figureRange = NSRange(openRange.upperBound..<closeRange.lowerBound, in: body)
        guard let caption = captionRegex.firstMatch(in: body, range: figureRange),
              caption.numberOfRanges > 1,
              let inner = Range(caption.range(at: 1), in: body) else { return nil }
        let text = EPUBParser.stripHTML(String(body[inner]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : SourceImageEntry.shortened(text, limit: 300)
    }

    /// Up to ~600 characters of markup after the tag, as text. Long enough to
    /// reach a caption paragraph; short enough not to swallow the next section.
    private static func markupContext(
        after range: Range<String.Index>,
        in body: String,
        upTo limit: String.Index
    ) -> String {
        let start = range.upperBound
        guard start < body.endIndex, start < limit else { return "" }
        let end = min(body.index(start, offsetBy: 600, limitedBy: body.endIndex) ?? body.endIndex, limit)
        let text = EPUBParser.stripHTML(String(body[start..<end]))
        return SourceImageEntry.shortened(text, limit: 220)
    }

    // MARK: PDF

    #if os(macOS)
    static func pdfEntries(sourceID: String, document: PDFDocument, query: String, page: Int?) throws -> [SourceImageEntry] {
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw Failure.noImages }

        if let page {
            guard page >= 1, page <= pageCount else {
                throw Failure.pageOutOfRange(requested: page, pageCount: pageCount)
            }
            guard let pdfPage = document.page(at: page - 1) else {
                throw Failure.pageOutOfRange(requested: page, pageCount: pageCount)
            }
            let text = pdfPage.string ?? ""
            let captions = PDFTextExtractor.figureCaptionRecords(in: text)
            // A page number is the one argument a model can produce without
            // having seen anything, and page 1 of a paper is the guess it
            // reaches for. That page is a title block: masthead, authors,
            // abstract. Rendering it as "a picture" is what put a journal's
            // front page in an answer about electron transport.
            guard pageCarriesPicture(pdfPage, text: text, captions: captions) else {
                throw Failure.pageWithoutPicture(
                    requested: page,
                    available: captionedFigureLabels(in: document)
                )
            }
            let caption = captions.first?.caption
                ?? firstLine(of: text, matching: query)
                ?? ""
            return [SourceImageEntry(
                reference: SourceImageReference(sourceID: sourceID, location: .page(page)),
                caption: SourceImageEntry.shortened(caption, limit: 300),
                context: ""
            )]
        }

        if !query.isEmpty {
            var matches: [SourceImageEntry] = []
            var matchedProse = false
            for index in 0..<pageCount {
                guard let pdfPage = document.page(at: index) else { continue }
                let text = pdfPage.string ?? ""
                guard text.isEmpty == false, textMatches(text, query: query) else { continue }
                // A PDF query searches page *text*, so the pages that come back
                // are wherever the words appear — usually the prose discussing
                // a figure rather than the figure. Only pages that carry a
                // picture can answer a request for one.
                guard pageCarriesPicture(pdfPage, text: text) else {
                    matchedProse = true
                    continue
                }
                let caption = firstLine(of: text, matching: query) ?? ""
                matches.append(SourceImageEntry(
                    reference: SourceImageReference(sourceID: sourceID, location: .page(index + 1)),
                    caption: SourceImageEntry.shortened(caption, limit: 300),
                    context: ""
                ))
                if matches.count == maxEntries { break }
            }
            guard !matches.isEmpty else {
                let available = captionedFigureLabels(in: document)
                throw matchedProse
                    ? Failure.noPictureMatching(query: query, available: available)
                    : Failure.noMatch(query: query, available: available)
            }
            return matches
        }

        // No query, no page: the captioned figures the file declares.
        var listed: [SourceImageEntry] = []
        var seen = Set<String>()
        for index in 0..<pageCount {
            let text = document.page(at: index)?.string ?? ""
            for record in PDFTextExtractor.figureCaptionRecords(in: text) {
                let key = "\(record.label.lowercased())\u{1F}\(index)"
                guard seen.insert(key).inserted else { continue }
                listed.append(SourceImageEntry(
                    reference: SourceImageReference(sourceID: sourceID, location: .page(index + 1)),
                    caption: SourceImageEntry.shortened(record.caption, limit: 300),
                    context: ""
                ))
                if listed.count == maxEntries { return listed }
            }
        }
        guard !listed.isEmpty else { throw Failure.noImages }
        return listed
    }

    private static func captionedFigureLabels(in document: PDFDocument) -> [String] {
        var labels: [String] = []
        var seen = Set<String>()
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            for record in PDFTextExtractor.figureCaptionRecords(in: text) {
                let line = SourceImageEntry.shortened(record.caption, limit: 60) + " (page \(index + 1))"
                guard seen.insert(line.lowercased()).inserted else { continue }
                labels.append(line)
                if labels.count == maxEntries { return labels }
            }
        }
        return labels
    }

    // MARK: Pictures on a page

    /// How much of a page raster images must cover before the page counts as
    /// having a picture on it, when nothing on it is captioned.
    ///
    /// Measured on this library rather than guessed. A journal's front page
    /// draws a publisher logo, a cover thumbnail and an update badge: together
    /// 1.9% of the page. A textbook's front matter draws a rule and a device
    /// glyph: 1.9%. The two figure pages of the paper that started this cover
    /// 24.9% and 31.3%, and a book cover covers the page. Nothing landed in
    /// between, so the line sits well clear of the chrome.
    static let pictureCoverageThreshold = 0.08

    /// Whether the page has a picture on it, as opposed to being text.
    ///
    /// Two signals, because either alone is wrong. A figure drawn as vector art
    /// places no image at all and is found only by the caption printed under
    /// it; a picture with no caption — a book cover, a plate, a photo in a
    /// chapter — is a picture nonetheless. So: a caption on the page, or images
    /// covering a real part of it.
    static func pageCarriesPicture(
        _ page: PDFPage,
        text: String? = nil,
        captions: [(label: String, caption: String)]? = nil
    ) -> Bool {
        let captionRecords = captions ?? PDFTextExtractor.figureCaptionRecords(in: text ?? page.string ?? "")
        if !captionRecords.isEmpty { return true }
        return rasterImageCoverage(of: page) >= pictureCoverageThreshold
    }

    /// The share of the page covered by the images it draws, 0 when it draws
    /// none and never above 1. Vector drawing is not counted: this measures
    /// pictures placed on the page, and `pageCarriesPicture` reads captions for
    /// the rest.
    static func rasterImageCoverage(of page: PDFPage) -> Double {
        guard let pageRef = page.pageRef else { return 0 }
        let bounds = page.bounds(for: .mediaBox)
        let area = Double(bounds.width) * Double(bounds.height)
        guard area > 0 else { return 0 }
        let scan = PDFImageCoverageScan(page: pageRef)
        scan.run()
        return min(scan.covered / area, 1)
    }
    #endif

    // MARK: Matching

    private static func narrowed(_ entries: [SourceImageEntry], query: String) throws -> [SourceImageEntry] {
        guard !query.isEmpty else { return Array(entries.prefix(maxEntries)) }
        var matches = entries.filter { entry in
            textMatches(entry.caption, query: query)
                || textMatches(entry.context, query: query)
        }
        if matches.isEmpty {
            matches = entriesMatchingMostWords(of: query, in: entries)
        }
        guard !matches.isEmpty else {
            var available = entries.prefix(maxEntries).map { entry in
                entry.caption.isEmpty
                    ? "image \(entry.locationDescription.split(separator: " ").last ?? "")"
                    : SourceImageEntry.shortened(entry.caption, limit: 60)
            }
            // A talk captures eighty slides and the listing names twelve: say
            // the rest exist, or a caller reads the twelve as the whole deck
            // (a refusal naming slides 1–12 of 86 reads as a capture that
            // stopped at 12).
            if entries.count > maxEntries {
                available.append(moreEntriesNote(entries.dropFirst(maxEntries)))
            }
            throw Failure.noMatch(query: query, available: available)
        }
        return Array(matches.prefix(maxEntries))
    }

    /// Words too common to tell one picture from another.
    private static let unhelpfulQueryWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "what", "where", "which", "about", "into",
        "slide", "slides", "image", "picture", "figure", "shows", "showing",
    ]

    /// For a query of several words none of the entries holds together:
    /// the entries holding most of them, most first. The words spoken over a
    /// slide are rarely in the order a question names them — "Helmholtz
    /// resonator drum eigen frequencies" found nothing though slide 22 was on
    /// screen for all but one of those words — and a caption
    /// rarely repeats a query's phrase whole. Two words must both be there;
    /// longer queries need three in five, so one misheard word does not hide
    /// the slide and one common word does not claim every slide.
    private static func entriesMatchingMostWords(of query: String, in entries: [SourceImageEntry]) -> [SourceImageEntry] {
        var seen = Set<String>()
        let words = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { word in
                let key = folded(word)
                return key.count >= 3 && !unhelpfulQueryWords.contains(key) && seen.insert(key).inserted
            }
        guard words.count >= 2 else { return [] }
        let needed = max(2, Int((Double(words.count) * 0.6).rounded(.up)))
        let scored = entries.enumerated().compactMap { index, entry -> (index: Int, score: Int, entry: SourceImageEntry)? in
            let text = entry.caption + " " + entry.context
            let score = words.filter { textMatches(text, query: $0) }.count
            return score >= needed ? (index, score, entry) : nil
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.entry)
    }

    /// "and 74 more, slides 13–86: pass slide with a number to see one".
    private static func moreEntriesNote(_ rest: ArraySlice<SourceImageEntry>) -> String {
        let slides = rest.compactMap { entry -> Int? in
            if case .slide(let number) = entry.reference.location { return number }
            return nil
        }
        if slides.count == rest.count, let first = slides.first, let last = slides.last {
            return "and \(rest.count) more, slides \(first)–\(last): pass slide with a number to see one"
        }
        return "and \(rest.count) more"
    }

    /// Whether `text` contains `query`, comparing both in a folded form where
    /// case, "Fig." versus "Figure", and every dash, dot, or space between the
    /// parts of an identifier are irrelevant — so "Figure 3-4", "FIGURE 3–4",
    /// "Fig. 3.4" all find the same caption. A digit right after the match is
    /// rejected so "Figure 3-4" does not claim "Figure 3-40".
    static func textMatches(_ text: String, query: String) -> Bool {
        let needle = folded(query)
        guard !needle.isEmpty else { return false }
        let haystack = folded(text)
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let endsCleanly = found.upperBound == haystack.endIndex
                || !haystack[found.upperBound].isNumber
                || !(needle.last?.isNumber ?? false)
            if endsCleanly { return true }
            searchStart = haystack.index(after: found.lowerBound)
        }
        return false
    }

    static func folded(_ text: String) -> String {
        var value = text.lowercased()
        for dash in ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}"] {
            value = value.replacingOccurrences(of: dash, with: "-")
        }
        value = value.replacingOccurrences(of: "fig.", with: "figure")
        value = value.replacingOccurrences(of: #"\bfig\b"#, with: "figure", options: .regularExpression)
        // Drop everything that separates parts: spaces, dashes, dots, colons.
        return value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func firstLine(of text: String, matching query: String) -> String? {
        guard !query.isEmpty else { return nil }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && textMatches($0, query: query) }
    }

    // MARK: - Rendering

    struct RenderedImage: Equatable, Sendable {
        let data: Data
        let mediaType: String

        var dataURL: String { "data:\(mediaType);base64,\(data.base64EncodedString())" }
    }

    /// Renders one reference from the file at `filePath`. Pages come back as
    /// JPEG on white at up to `maxRenderedPixelSize`; markup images come back in
    /// their own encoding, downscaled only when the reader document would have.
    static func render(_ reference: SourceImageReference, filePath: String) -> RenderedImage? {
        switch reference.location {
        case .page(let page):
            #if os(macOS)
            guard let document = SourcePDFPages(stored: filePath).document(),
                  page >= 1, page <= document.pageCount,
                  let pdfPage = document.page(at: page - 1) else { return nil }
            return renderPage(pdfPage, crop: reference.crop)
            #else
            return nil
            #endif
        case .image(let ordinal):
            guard EPUBParser.isMarkupChapter(filePath), let html = readMarkup(at: filePath) else { return nil }
            let tags = markupImageTags(inBody: markupBody(fromHTML: html))
            guard ordinal >= 1, ordinal <= tags.count else { return nil }
            return renderMarkupImage(tag: tags[ordinal - 1].tag, chapterPath: filePath)
        case .slide, .moment:
            // A slide or a moment is not inside the source's file; it is
            // rendered from the frame captured beside the video — see
            // `renderSlide` and `renderMoment`.
            return nil
        }
    }

    /// Renders a slide reference from the stored `content` of its video: the
    /// frame the slide block names, downscaled to the chat's ceiling. The
    /// frame's path is relative to the library's content root and is resolved
    /// across every root the way source files are, so a build without the
    /// iCloud entitlement still finds it.
    static func renderSlide(_ reference: SourceImageReference, content: String) -> RenderedImage? {
        guard let frame = slideFrame(for: reference, in: content) else { return nil }
        return renderSlideFrame(frame, crop: reference.crop)
    }

    /// The captured frame a slide reference names in its video's stored block,
    /// or nil when the reference is not a slide or the block has no such frame.
    static func slideFrame(for reference: SourceImageReference, in content: String) -> YouTubeSlideFrameContext? {
        guard case .slide(let index) = reference.location else { return nil }
        return YouTubeSlideContentParser.parse(content).slides.first { $0.index == index }
    }

    /// Renders one parsed slide frame — see `renderSlide`.
    static func renderSlideFrame(_ frame: YouTubeSlideFrameContext, crop: PaperFigureRect?) -> RenderedImage? {
        let path = frame.imagePath
        let resolvedPath = StorageService.locateSourceFile(path)
            ?? (path.hasPrefix("/") ? path : StorageService.absoluteSourcePath(path))
        return renderFrameFile(atPath: resolvedPath, crop: crop)
    }

    /// Renders a moment reference from the frame `SlideFrameExtraction`
    /// captured for it, cropped when the reference says so. Nil when this Mac
    /// holds no such frame: the caller captures it and asks again.
    static func renderMoment(_ reference: SourceImageReference) -> RenderedImage? {
        guard case .moment(let seconds) = reference.location,
              let path = SlideFrameExtraction.existingMomentFramePath(sourceID: reference.sourceID, seconds: seconds) else {
            return nil
        }
        return renderFrameFile(atPath: path, crop: reference.crop)
    }

    /// A captured video frame, cropped to the normalized top-left `crop` when
    /// one is given and downscaled to the chat's ceiling. The crop is taken
    /// from the full frame first, so a zoomed-in part of the screen keeps
    /// every pixel the capture has.
    static func renderFrameFile(atPath path: String, crop: PaperFigureRect?) -> RenderedImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let crop else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxRenderedPixelSize,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return encodeJPEG(image, quality: 0.86)
        }
        guard let full = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropped = cropped(full, to: crop) else { return nil }
        return encodeJPEG(downscaled(cropped, maxPixelSize: maxRenderedPixelSize), quality: 0.9)
    }

    /// The part of `image` a normalized, top-left-origin rectangle names —
    /// the frame `PaperFigureRect` uses — clamped to the image.
    static func cropped(_ image: CGImage, to crop: PaperFigureRect) -> CGImage? {
        let width = Double(image.width)
        let height = Double(image.height)
        let rect = CGRect(
            x: (crop.x * width).rounded(.down),
            y: (crop.y * height).rounded(.down),
            width: (crop.width * width).rounded(),
            height: (crop.height * height).rounded()
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return image.cropping(to: rect)
    }

    private static func downscaled(_ image: CGImage, maxPixelSize: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize else { return image }
        let scale = Double(maxPixelSize) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func renderMarkupImage(tag: String, chapterPath: String) -> RenderedImage? {
        let referenceAttributes = ["src", "data-src", "xlink:href", "href"]
        guard let attribute = referenceAttributes.first(where: { EPUBParser.attributeValue($0, in: tag) != nil }),
              let value = EPUBParser.attributeValue(attribute, in: tag) else { return nil }
        if value.lowercased().hasPrefix("data:") {
            return parseDataURL(value)
        }
        guard let imagePath = EPUBParser.resolveImageReference(value, relativeTo: chapterPath),
              let dataURI = EPUBParser.imageDataURI(atPath: imagePath) else { return nil }
        return parseDataURL(dataURI)
    }

    static func parseDataURL(_ value: String) -> RenderedImage? {
        guard value.lowercased().hasPrefix("data:"),
              let comma = value.firstIndex(of: ",") else { return nil }
        let header = String(value[value.index(value.startIndex, offsetBy: 5)..<comma])
        let payload = String(value[value.index(after: comma)...])
        let parts = header.split(separator: ";").map(String.init)
        let mediaType = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
        let data: Data?
        if parts.contains(where: { $0.lowercased() == "base64" }) {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data, !data.isEmpty else { return nil }
        return RenderedImage(data: data, mediaType: mediaType)
    }

    #if os(macOS)
    /// Draws the page (or the cropped part of it) into a white bitmap. The crop
    /// is normalized with a top-left origin; PDF space has its origin at the
    /// bottom-left, so the vertical axis is flipped once here.
    static func renderPage(_ page: PDFPage, crop: PaperFigureRect?, maxPixelSize: Int = maxRenderedPixelSize) -> RenderedImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var region = bounds
        if let crop, crop.isValid {
            region = CGRect(
                x: bounds.minX + crop.x * bounds.width,
                y: bounds.maxY - (crop.y + crop.height) * bounds.height,
                width: crop.width * bounds.width,
                height: crop.height * bounds.height
            )
        }
        let longest = max(region.width, region.height)
        let scale = min(3.0, CGFloat(maxPixelSize) / longest)
        let pixelWidth = max(1, Int((region.width * scale).rounded()))
        let pixelHeight = max(1, Int((region.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.drawMediaBox(region, to: context)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return encodeJPEG(image, quality: 0.86)
    }

    #endif

    static func encodeJPEG(_ image: CGImage, quality: Double) -> RenderedImage? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), encoded.length > 0 else { return nil }
        return RenderedImage(data: encoded as Data, mediaType: "image/jpeg")
    }

    // MARK: - Files

    /// Chapters are usually UTF-8; a few older exports are Latin-1, and reading
    /// those as UTF-8 fails outright rather than producing mojibake.
    static func readMarkup(at path: String) -> String? {
        EPUBBookFiles.text(atPath: path)
    }
}

#if os(macOS)
/// Adds up the area the images drawn on one PDF page cover, so a caller can
/// tell a page with a picture on it from a page of paragraphs.
///
/// PDFKit will not answer that question, so this walks the page's content
/// stream: `cm` multiplies the transform in force, `q`/`Q` push and pop it,
/// `Do` draws a named XObject, and an inline image ends at `EI`. An image is
/// drawn into the unit square, so the area it covers on the page is the
/// determinant of the transform in force when it is drawn.
///
/// Form XObjects are followed, carrying their own `/Matrix` and resources,
/// because that is where journals put their figures: measuring this paper
/// without following forms scored its two figure pages 0 and its logo-bearing
/// front page highest, which is exactly backwards.
private final class PDFImageCoverageScan {
    /// A form inside a form inside a form is a real document; deeper than this
    /// is a loop or a generator, and neither is worth the walk.
    private static let maximumFormDepth = 4

    private let page: CGPDFPage
    /// The graphics state stack, transforms only: everything else a PDF tracks
    /// is irrelevant to how much of the page an image covers.
    private var transforms: [CGAffineTransform] = [.identity]
    private var formDepth = 0
    /// Area in page units, summed over every image drawn. Overlapping images
    /// are counted twice, which can only push a page over the threshold — a
    /// page that draws pictures twice over is not the text page this guards
    /// against.
    private(set) var covered: Double = 0

    init(page: CGPDFPage) { self.page = page }

    func run() {
        let stream = CGPDFContentStreamCreateWithPage(page)
        scan(stream)
        CGPDFContentStreamRelease(stream)
    }

    // MARK: State, as the operators change it

    fileprivate var currentTransform: CGAffineTransform { transforms.last ?? .identity }

    fileprivate func concatenate(_ transform: CGAffineTransform) {
        transforms[transforms.count - 1] = transform.concatenating(currentTransform)
    }

    fileprivate func pushState() { transforms.append(currentTransform) }

    /// A `Q` with no matching `q` is malformed; keeping the base transform is
    /// better than trapping on a file the reader still renders.
    fileprivate func popState() { if transforms.count > 1 { transforms.removeLast() } }

    fileprivate func addDrawnImage() {
        let transform = currentTransform
        covered += Double(abs(transform.a * transform.d - transform.b * transform.c))
    }

    fileprivate func enterForm(_ formStream: CGPDFStreamRef, parent: CGPDFContentStreamRef) {
        guard formDepth < Self.maximumFormDepth,
              let dictionary = CGPDFStreamGetDictionary(formStream) else { return }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
              let resources else { return }
        var matrix = CGAffineTransform.identity
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
            var values = [CGFloat](repeating: 0, count: 6)
            for index in 0..<6 {
                var number: CGPDFReal = 0
                guard CGPDFArrayGetNumber(array, index, &number) else { return }
                values[index] = CGFloat(number)
            }
            matrix = CGAffineTransform(
                a: values[0], b: values[1], c: values[2],
                d: values[3], tx: values[4], ty: values[5]
            )
        }
        formDepth += 1
        transforms.append(matrix.concatenating(currentTransform))
        let nested = CGPDFContentStreamCreateWithStream(formStream, resources, parent)
        scan(nested)
        CGPDFContentStreamRelease(nested)
        transforms.removeLast()
        formDepth -= 1
    }

    private func scan(_ stream: CGPDFContentStreamRef) {
        guard let table = Self.operatorTable else { return }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    /// The callbacks are C function pointers, so they capture nothing and reach
    /// the scan through the pointer handed to `CGPDFScannerCreate`.
    private static let operatorTable: CGPDFOperatorTableRef? = {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let scan = PDFImageCoverageScan.scan(from: info) else { return }
            // Operands come off the stack last one first.
            var values = [CGFloat](repeating: 0, count: 6)
            for index in (0..<6).reversed() {
                var number: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &number) else { return }
                values[index] = CGFloat(number)
            }
            scan.concatenate(CGAffineTransform(
                a: values[0], b: values[1], c: values[2],
                d: values[3], tx: values[4], ty: values[5]
            ))
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            PDFImageCoverageScan.scan(from: info)?.pushState()
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            PDFImageCoverageScan.scan(from: info)?.popState()
        }
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in
            PDFImageCoverageScan.scan(from: info)?.addDrawnImage()
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let scan = PDFImageCoverageScan.scan(from: info) else { return }
            var namePointer: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &namePointer), let namePointer else { return }
            // Asking the content stream resolves the name against the
            // resources actually in scope, which inside a form are the form's.
            let contentStream = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(contentStream, "XObject", namePointer) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image": scan.addDrawnImage()
            case "Form": scan.enterForm(stream, parent: contentStream)
            default: break
            }
        }
        return table
    }()

    private static func scan(from info: UnsafeMutableRawPointer?) -> PDFImageCoverageScan? {
        guard let info else { return nil }
        return Unmanaged<PDFImageCoverageScan>.fromOpaque(info).takeUnretainedValue()
    }
}
#endif
