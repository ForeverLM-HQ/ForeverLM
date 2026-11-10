import Foundation

/// A picture inside a source, named so the reference survives leaving the Mac
/// that produced it.
///
/// Chat transcripts are text that syncs to every device, so an image the
/// assistant shows has to be addressed by something every client can resolve
/// on its own: the source's stable ID plus a location *inside* that source.
/// Two locations exist.
///
/// - `page/<n>` — a one-based page of a PDF-backed source (a paper, a chapter
///   of a PDF-split book, a course hand-out). Clients render it from the PDF
///   they already hold for the reader.
/// - `img/<n>` — the n-th `<img>`/`<image>` tag, in document order, of a
///   markup-backed source (an EPUB chapter, an archived article). The Mac
///   reads the file beside the chapter.
/// - `slide/<n>` — slide frame `n` of a video or meeting recording, as numbered
///   in the "Extracted video slide frames" block of its stored content. The
///   frame's file lives under the library's content root on the device that
///   captured it; a client without the file shows the reference unavailable.
/// - `at/<seconds>` — the frame of a video or recording at that many seconds
///   from its start, captured on request rather than by slide detection: the
///   moment the learner asked about, whatever was on screen. The Mac that
///   captured it keeps the frame beside the video's slides; a Mac without the
///   file captures a YouTube video's frame again from the stream.
///
/// An optional `crop` narrows a page to a figure, or a slide or frame to the
/// part of the screen that matters. It is normalized to the
/// rendered page with a top-left origin — the same frame `PaperFigureRect`
/// uses — so a paper's vision analysis can hand its rectangle straight over.
///
/// The Markdown form is `![alt](foreverlm://image/<sourceID>/page/9)`. Absolute
/// `file://` links were tried before this and are what this replaces: they
/// named one home directory and were dead everywhere else.
struct SourceImageReference: Hashable, Sendable {
    enum Location: Hashable, Sendable {
        /// One-based page number of a PDF-backed source.
        case page(Int)
        /// One-based ordinal of an `<img>`/`<image>` tag in a markup source.
        case image(Int)
        /// Slide frame number of a video or recording, from its stored slide block.
        case slide(Int)
        /// Whole seconds from the start of a video or recording.
        case moment(Int)
    }

    static let scheme = "foreverlm"
    static let host = "image"

    let sourceID: String
    let location: Location
    let crop: PaperFigureRect?

    init(sourceID: String, location: Location, crop: PaperFigureRect? = nil) {
        self.sourceID = sourceID
        self.location = location
        self.crop = crop?.isValid == true ? crop : nil
    }

    /// Parses `foreverlm://image/<sourceID>/(page|img|slide|at)/<n>[?crop=x,y,w,h]`.
    /// Anything else — another host, a missing ordinal, a zero page — is nil so
    /// a renderer never treats a malformed link as a picture.
    init?(urlString: String) {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.host else { return nil }
        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard segments.count == 3, let ordinal = Int(segments[2]) else { return nil }
        let sourceID = segments[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceID.isEmpty else { return nil }
        switch segments[1].lowercased() {
        case "page" where ordinal > 0: location = .page(ordinal)
        case "img" where ordinal > 0: location = .image(ordinal)
        case "slide" where ordinal > 0: location = .slide(ordinal)
        // The opening frame of a talk is second zero.
        case "at" where ordinal >= 0: location = .moment(ordinal)
        default: return nil
        }
        self.sourceID = sourceID
        crop = components.queryItems?
            .first { $0.name == "crop" }
            .flatMap { Self.parseCrop($0.value) }
    }

    var urlString: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        let segment: String
        let ordinal: Int
        switch location {
        case .page(let page):
            segment = "page"
            ordinal = page
        case .image(let index):
            segment = "img"
            ordinal = index
        case .slide(let index):
            segment = "slide"
            ordinal = index
        case .moment(let seconds):
            segment = "at"
            ordinal = seconds
        }
        components.path = "/\(sourceID)/\(segment)/\(ordinal)"
        if let crop {
            components.queryItems = [URLQueryItem(name: "crop", value: Self.formatCrop(crop))]
        }
        return components.string ?? "\(Self.scheme)://\(Self.host)/\(sourceID)/\(segment)/\(ordinal)"
    }

    /// The line the assistant pastes into its answer. Alt text is kept to one
    /// line without brackets so the Markdown image cannot be broken by a caption.
    func markdown(alt: String) -> String {
        let cleaned = alt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "![\(cleaned.isEmpty ? "Image" : cleaned)](\(urlString))"
    }

    /// A crop as a tool call gives it: an object with x, y, width and height,
    /// or the `x,y,w,h` string a reference carries, each a fraction of the
    /// picture with a top-left origin. Nil for anything else, including a
    /// rectangle that leaves the picture.
    static func cropArgument(_ value: Any?) -> PaperFigureRect? {
        if let text = value as? String { return parseCrop(text) }
        guard let object = value as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            if let value = object[key] as? Double { return value }
            if let value = object[key] as? Int { return Double(value) }
            if let value = object[key] as? String { return Double(value.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        guard let x = number("x"), let y = number("y"),
              let width = number("width") ?? number("w"),
              let height = number("height") ?? number("h") else { return nil }
        let rect = PaperFigureRect(x: x, y: y, width: width, height: height)
        return rect.isValid ? rect : nil
    }

    /// A moment in a video as a tool call gives it: seconds as a number, or a
    /// clock reading — `75`, `"1:15"`, `"1:02:03"`, `"4m25s"`. Whole seconds;
    /// nil for anything negative or unreadable.
    static func timestampSeconds(_ value: Any?) -> Int? {
        if let seconds = value as? Int { return seconds >= 0 ? seconds : nil }
        if let seconds = value as? Double {
            // `Int(exactly:)`, never `Int(_:)`: a huge or infinite number from a
            // tool call would trap and take the app down with it.
            return seconds >= 0 ? Int(exactly: seconds.rounded(.down)) : nil
        }
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        if let seconds = Double(raw) { return timestampSeconds(seconds) }
        if raw.contains(":") {
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
            guard (2...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
            let total = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
            return Int(exactly: total.rounded(.down))
        }
        // 1h2m3s, 4m25s, 90s
        var total = 0.0
        var digits = ""
        var sawUnit = false
        for character in raw where character != " " {
            if character.isNumber || character == "." {
                digits.append(character)
                continue
            }
            guard let amount = Double(digits) else { return nil }
            switch character {
            case "h": total += amount * 3600
            case "m": total += amount * 60
            case "s": total += amount
            default: return nil
            }
            digits = ""
            sawUnit = true
        }
        guard sawUnit, digits.isEmpty else { return nil }
        return Int(exactly: total.rounded(.down))
    }

    private static func parseCrop(_ value: String?) -> PaperFigureRect? {
        guard let value else { return nil }
        let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        let rect = PaperFigureRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        return rect.isValid ? rect : nil
    }

    private static func formatCrop(_ rect: PaperFigureRect) -> String {
        [rect.x, rect.y, rect.width, rect.height]
            .map { String(format: "%.4f", $0) }
            .joined(separator: ",")
    }
}

// MARK: - Slide frame files named by path

extension SourceImageReference {
    /// A slide frame named by the file its capture wrote, the way a video's
    /// stored slide block names it: `Videos/<sourceID>/Slides/slide_013_000450s.jpg`,
    /// relative to the library's content root, or the same path made absolute
    /// or written as a `file://` URL.
    ///
    /// This is not a reference the chat hands out — `slide/<n>` is — but it is
    /// what a model writes when it reads the slide block in a transcript and
    /// pastes the path it finds there (2026-09-10: a reply carried exactly
    /// that, and the chat drew a broken picture). Recognising the path lets
    /// the app turn it into the portable reference before the reply is kept,
    /// and lets a transcript that already carries one still show the slide.
    struct SlideFramePath: Hashable, Sendable {
        let sourceID: String
        let fileName: String

        init(sourceID: String, fileName: String) {
            self.sourceID = sourceID
            self.fileName = fileName
        }

        /// Parses a relative content path, an absolute path, or a `file://`
        /// URL ending in `Videos/<sourceID>/Slides/<file>`. Anything else is nil.
        init?(pathOrURL: String) {
            var candidate = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return nil }
            if candidate.lowercased().hasPrefix("file://") {
                guard let url = URL(string: candidate) else { return nil }
                candidate = url.path
            } else if let decoded = candidate.removingPercentEncoding {
                candidate = decoded
            }
            let components = candidate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard components.count >= 4,
                  components[components.count - 4] == "Videos",
                  components[components.count - 2] == "Slides" else { return nil }
            let sourceID = components[components.count - 3]
            let fileName = components[components.count - 1]
            guard !sourceID.isEmpty, !fileName.isEmpty, fileName.contains(".") else { return nil }
            self.sourceID = sourceID
            self.fileName = fileName
        }

        /// The frame number the capture wrote into the file name
        /// (`slide_013_000450s.jpg` → 13). The stored block is the authority;
        /// this is the fallback when the block is not at hand.
        var fileNameIndex: Int? {
            guard fileName.hasPrefix("slide_") else { return nil }
            let digits = fileName.dropFirst("slide_".count).prefix { $0.isNumber }
            guard let index = Int(digits), index > 0 else { return nil }
            return index
        }

        /// The second of the video the frame was captured at, as the capture
        /// wrote it into the file name (`slide_013_000450s.jpg` → 450). Nil
        /// for a name without one (`slide_013.jpg`).
        var fileNameSeconds: Int? {
            guard fileName.hasPrefix("slide_") else { return nil }
            let afterIndex = fileName.dropFirst("slide_".count).drop { $0.isNumber }
            guard afterIndex.hasPrefix("_") else { return nil }
            let digits = afterIndex.dropFirst().prefix { $0.isNumber }
            guard !digits.isEmpty, afterIndex.dropFirst(1 + digits.count).hasPrefix("s") else { return nil }
            return Int(digits)
        }
    }

    /// Every Markdown image in `text` whose target is a slide frame path.
    static func slideFramePaths(in text: String) -> [SlideFramePath] {
        var found: [SlideFramePath] = []
        var seen = Set<SlideFramePath>()
        for match in markdownImagePattern().matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let targetRange = Range(match.range(at: 2), in: text),
                  let path = SlideFramePath(pathOrURL: String(text[targetRange])),
                  seen.insert(path).inserted else { continue }
            found.append(path)
        }
        return found
    }

    /// Rewrites every Markdown image that targets a slide frame path into the
    /// portable `slide/<n>` reference, keeping the alt text. `slideIndex`
    /// answers with the frame number the video's stored block gives that file;
    /// a path it cannot place is left exactly as written.
    static func rewritingSlideFramePaths(in text: String, slideIndex: (SlideFramePath) -> Int?) -> String {
        let matches = markdownImagePattern().matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let targetRange = Range(match.range(at: 2), in: result),
                  let path = SlideFramePath(pathOrURL: String(result[targetRange])),
                  let index = slideIndex(path) else { continue }
            let reference = SourceImageReference(sourceID: path.sourceID, location: .slide(index))
            result.replaceSubrange(targetRange, with: reference.urlString)
        }
        return result
    }

    /// The `foreverlm://image` target of every Markdown image in `text`, each
    /// once, in the order written. A web picture or a frame file's path is
    /// not a picture address and is left out.
    static func pictureAddresses(in text: String) -> [String] {
        let prefix = "\(scheme)://\(host)/"
        var found: [String] = []
        var seen = Set<String>()
        for match in markdownImagePattern().matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let targetRange = Range(match.range(at: 2), in: text) else { continue }
            let target = String(text[targetRange])
            guard target.lowercased().hasPrefix(prefix), seen.insert(target).inserted else { continue }
            found.append(target)
        }
        return found
    }

    /// `text` without the Markdown images whose `foreverlm://image` target
    /// `shouldRemove` picks. A line a picture stood on alone goes with it,
    /// and the blank lines left around it close up to one.
    static func removingPictures(from text: String, where shouldRemove: (String) -> Bool) -> String {
        let prefix = "\(scheme)://\(host)/"
        var result = text
        var removed = false
        for match in markdownImagePattern().matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let targetRange = Range(match.range(at: 2), in: result) else { continue }
            let target = String(result[targetRange])
            guard target.lowercased().hasPrefix(prefix), shouldRemove(target) else { continue }
            result.removeSubrange(whole)
            removed = true
        }
        guard removed else { return text }
        return result
            .replacingOccurrences(of: #"\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `![alt](target)`, with the target free of whitespace and closing
    /// parentheses — the shape the assistant writes and the renderer reads.
    private static func markdownImagePattern() -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(<?([^)\s>]+)>?\)"#)
    }
}
