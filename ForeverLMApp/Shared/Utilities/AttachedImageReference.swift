import Foundation

/// A picture the learner dropped or pasted into a chat, named so the message
/// that carries it holds no file path and no bytes.
///
/// `foreverlm://image/attached/<id>` sits beside `GeneratedImageReference`'s
/// `foreverlm://image/generated/<id>`: the same two-segment grammar with its
/// own reserved first segment, so neither can be mistaken for the other or for
/// a source picture's three segments. The learner's message text carries the
/// Markdown line `![name](foreverlm://image/attached/<id>)` and syncs as
/// ordinary `review_exchanges` text; the bytes stay in this device's
/// `AttachedImageStore`, the same documented local-only exception generated
/// pictures use. Another device that never held the picture says so in its
/// place rather than drawing nothing.
struct AttachedImageReference: Hashable, Sendable {
    static let segment = "attached"

    let id: String

    /// Nil for an id that could not name a file safely.
    init?(id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard GeneratedImageReference.isValidID(trimmed) else { return nil }
        self.id = trimmed
    }

    /// Parses `foreverlm://image/attached/<id>`; anything else is nil.
    init?(urlString: String) {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == SourceImageReference.scheme,
              components.host?.lowercased() == SourceImageReference.host else { return nil }
        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard segments.count == 2, segments[0].lowercased() == Self.segment else { return nil }
        self.init(id: segments[1])
    }

    var urlString: String {
        "\(SourceImageReference.scheme)://\(SourceImageReference.host)/\(Self.segment)/\(id)"
    }

    /// The line written into the learner's message. Alt text is the file's
    /// name, kept to one bracket-free line exactly as the other references do.
    func markdown(alt: String) -> String {
        "![\(Self.cleanedAlt(alt))](\(urlString))"
    }

    static func cleanedAlt(_ alt: String) -> String {
        let cleaned = alt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Attached image" : cleaned
    }

    static func newID() -> String {
        GeneratedImageReference.newID()
    }

    // MARK: - Reading a message

    /// One attached picture named in a message, with the alt text it was
    /// written with — the file name the learner dropped.
    struct Occurrence: Hashable, Sendable {
        let reference: AttachedImageReference
        let alt: String
    }

    /// The message split into what the learner typed and the pictures they
    /// attached. The image lines are removed from `text` wholesale, so a
    /// message that was only pictures comes back with empty text.
    ///
    /// This reads the structural Markdown image syntax the app itself wrote —
    /// `![alt](url)` with this reference's URL — never the prose around it.
    struct Split: Equatable, Sendable {
        let text: String
        let images: [Occurrence]
    }

    /// Matches `![alt](foreverlm://image/attached/<id>)`. The alt may not
    /// contain a closing bracket or a newline, and the URL runs to the closing
    /// parenthesis, which the id grammar cannot contain.
    private static let markdownPattern: NSRegularExpression = {
        let url = "\(SourceImageReference.scheme)://\(SourceImageReference.host)/\(segment)/[A-Za-z0-9-]+"
        return try! NSRegularExpression(pattern: "!\\[([^\\]\\n]*)\\]\\(\\s*(\(url))\\s*\\)")
    }()

    static func split(_ content: String) -> Split {
        let nsContent = content as NSString
        let matches = markdownPattern.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        guard !matches.isEmpty else { return Split(text: content, images: []) }

        var images: [Occurrence] = []
        var text = ""
        var cursor = 0
        for match in matches {
            let url = nsContent.substring(with: match.range(at: 2))
            guard let reference = AttachedImageReference(urlString: url) else { continue }
            let alt = nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            images.append(Occurrence(reference: reference, alt: alt))
            text += nsContent.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
        }
        text += nsContent.substring(from: cursor)
        guard !images.isEmpty else { return Split(text: content, images: []) }
        return Split(text: Self.collapsingBlankLines(text), images: images)
    }

    /// True when the message names at least one attached picture.
    static func containsReference(_ content: String) -> Bool {
        !split(content).images.isEmpty
    }

    /// The message with each picture line replaced by a bracketed note naming
    /// it, for places that carry text only: the compacted history, a copied
    /// transcript, a route that cannot take image parts.
    static func textOnly(_ content: String, note: (Occurrence) -> String = { "[Attached image: \($0.alt)]" }) -> String {
        let nsContent = content as NSString
        let matches = markdownPattern.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        guard !matches.isEmpty else { return content }
        var result = ""
        var cursor = 0
        for match in matches {
            let url = nsContent.substring(with: match.range(at: 2))
            guard let reference = AttachedImageReference(urlString: url) else { continue }
            let alt = nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            result += nsContent.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += note(Occurrence(reference: reference, alt: alt))
            cursor = match.range.location + match.range.length
        }
        result += nsContent.substring(from: cursor)
        return result
    }

    /// Removing image lines leaves their surrounding blank lines behind; three
    /// or more newlines in a row read as a hole where the picture was.
    private static func collapsingBlankLines(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The bytes of one attached picture, as the provider will receive them.
struct AttachedImage: Equatable, Sendable {
    let data: Data
    /// One of the four types every vision route reads: `image/png`,
    /// `image/jpeg`, `image/gif`, `image/webp`. `ChatImagePreparation` makes
    /// sure of that before anything is stored.
    let mediaType: String
}

/// A picture waiting in the composer: prepared bytes plus the name the
/// learner will see under it, which becomes the image line's alt text.
struct ChatImageAttachment: Identifiable, Equatable, Sendable {
    /// The reference id the picture will be written under.
    let id: String
    let image: AttachedImage
    /// The dropped file's name, or a stand-in for pasted bytes.
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int

    init(id: String = AttachedImageReference.newID(), prepared: ChatImagePreparation.Prepared, name: String) {
        self.id = id
        self.image = prepared.image
        self.name = name
        self.pixelWidth = prepared.pixelWidth
        self.pixelHeight = prepared.pixelHeight
    }
}

/// Where this device keeps the pictures dropped into its chats.
///
/// One file per picture under the content root, beside `Generated Images`.
/// The file is the whole state: the message carries the id, the file carries
/// the bytes, and nothing else has to agree with either. A picture is also
/// held in memory from the moment it is staged, so the bubble it belongs to
/// draws before the disk write lands and the model receives the bytes this
/// session even if that write fails.
enum AttachedImageStore {
    static let directory = "Attached Images"

    private static let knownExtensions: [(extension: String, mediaType: String)] = [
        ("png", "image/png"),
        ("jpg", "image/jpeg"),
        ("gif", "image/gif"),
        ("webp", "image/webp"),
    ]

    private static let memoryLock = AppLock()
    /// Pictures this process has staged or read, keyed by id. Bounded by the
    /// chats open in one session; a transcript of hundreds of pictures is not
    /// something the composer produces.
    nonisolated(unsafe) private static var memory: [String: AttachedImage] = [:]

    static func relativePath(id: String, mediaType: String) -> String {
        "\(directory)/\(id).\(fileExtension(for: mediaType))"
    }

    static func fileExtension(for mediaType: String) -> String {
        knownExtensions.first { $0.mediaType == mediaType.lowercased() }?.extension ?? "png"
    }

    /// Makes the picture resolvable at once, before any disk write.
    static func stage(_ image: AttachedImage, id: String) {
        memoryLock.lock()
        memory[id] = image
        memoryLock.unlock()
    }

    /// Forgets a staged picture that was never sent.
    static func unstage(id: String) {
        memoryLock.lock()
        memory[id] = nil
        memoryLock.unlock()
    }

    static func cached(id: String) -> AttachedImage? {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        return memory[id]
    }

    /// Writes the picture and returns its path relative to the content root.
    /// Never called on the main actor: it touches the disk.
    static func write(_ image: AttachedImage, id: String) throws -> String {
        let relative = relativePath(id: id, mediaType: image.mediaType)
        let destination = URL(fileURLWithPath: StorageService.absoluteSourcePath(relative))
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try image.data.write(to: destination, options: .atomic)
        stage(image, id: id)
        return relative
    }

    /// The stored picture, or nil when this device never held it. Memory
    /// first, then each extension the store writes; a disk hit is kept in
    /// memory for the next request.
    static func read(id: String) -> AttachedImage? {
        guard GeneratedImageReference.isValidID(id) else { return nil }
        if let cached = cached(id: id) { return cached }
        for candidate in knownExtensions {
            let path = StorageService.absoluteSourcePath("\(directory)/\(id).\(candidate.extension)")
            if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
                let image = AttachedImage(data: data, mediaType: candidate.mediaType)
                stage(image, id: id)
                return image
            }
        }
        return nil
    }

    /// Whether this device holds the picture, staged or on disk, without
    /// reading its bytes. Never called on the main actor: it touches the disk.
    static func holds(id: String) -> Bool {
        guard GeneratedImageReference.isValidID(id) else { return false }
        if cached(id: id) != nil { return true }
        return knownExtensions.contains { candidate in
            FileManager.default.fileExists(
                atPath: StorageService.absoluteSourcePath("\(directory)/\(id).\(candidate.extension)")
            )
        }
    }
}

// MARK: - Frames of the moment a question was asked at

/// The frames of videos the learner asked about, held for the turns that send
/// them as pictures.
///
/// A question typed beside a video carries the moment (`ChatContextAdditions.VideoMoment`),
/// and the tutor is handed the frame on screen then as a picture. The turn's
/// framing names it with the frame's own address,
/// `![alt](foreverlm://image/<sourceID>/at/<seconds>)`, and `ReviewSessionManager.userTurn`
/// swaps that line for the image. The bytes are read into memory off the main
/// actor before a turn is assembled, the way attached pictures are, so the
/// assembly never touches the disk. The frame file itself is the one
/// `show_source_image` captures (`SlideFrameExtraction`), and stays the truth.
enum VideoMomentFrames {
    private static let memoryLock = AppLock()
    nonisolated(unsafe) private static var memory: [String: AttachedImage] = [:]

    private static func key(_ reference: SourceImageReference) -> String {
        reference.urlString
    }

    static func stage(_ image: AttachedImage, for reference: SourceImageReference) {
        memoryLock.lock()
        memory[key(reference)] = image
        memoryLock.unlock()
    }

    static func cached(_ reference: SourceImageReference) -> AttachedImage? {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        return memory[key(reference)]
    }

    /// One frame named in a message: its address and the alt text it was written with.
    struct Occurrence: Hashable, Sendable {
        let reference: SourceImageReference
        let alt: String
    }

    /// Matches `![alt](foreverlm://image/<sourceID>/at/<seconds>)`, a crop
    /// included — only the moment grammar, so a slide or page line in the
    /// same text is left alone.
    private static let markdownPattern: NSRegularExpression = {
        let url = "\(SourceImageReference.scheme)://\(SourceImageReference.host)/[^/\\s)]+/at/\\d+(?:\\?crop=[0-9.,]+)?"
        return try! NSRegularExpression(pattern: "!\\[([^\\]\\n]*)\\]\\(\\s*(\(url))\\s*\\)")
    }()

    /// The text with every moment line taken out, and the frames they named,
    /// in order. Text with no such line comes back unchanged.
    static func split(_ content: String) -> (text: String, frames: [Occurrence]) {
        let nsContent = content as NSString
        let matches = markdownPattern.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        guard !matches.isEmpty else { return (content, []) }
        var frames: [Occurrence] = []
        var text = ""
        var cursor = 0
        for match in matches {
            let url = nsContent.substring(with: match.range(at: 2))
            guard let reference = SourceImageReference(urlString: url),
                  case .moment = reference.location else { continue }
            let alt = nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            frames.append(Occurrence(reference: reference, alt: alt))
            text += nsContent.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
        }
        guard !frames.isEmpty else { return (content, []) }
        text += nsContent.substring(from: cursor)
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), frames)
    }

    /// The message with each moment line replaced by `note`, for a route that
    /// carries text only.
    static func textOnly(_ content: String, note: (Occurrence) -> String) -> String {
        let nsContent = content as NSString
        let matches = markdownPattern.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        guard !matches.isEmpty else { return content }
        var result = ""
        var cursor = 0
        for match in matches {
            let url = nsContent.substring(with: match.range(at: 2))
            guard let reference = SourceImageReference(urlString: url),
                  case .moment = reference.location else { continue }
            let alt = nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            result += nsContent.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += note(Occurrence(reference: reference, alt: alt))
            cursor = match.range.location + match.range.length
        }
        result += nsContent.substring(from: cursor)
        return result
    }
}

// MARK: - What a picture address in a reply names

/// What a `foreverlm://image` address in a chat reply names, by what can
/// vouch for it: a source in the library, or a picture in a device's own
/// store, drawn or kept (`generated`) or attached by the learner. A target
/// none of the three grammars reads names nothing any client could draw.
///
/// A model copies these addresses from tool results, and it can also make
/// one up. A quiz tutor on a flash model that had not called
/// the grader pasted `foreverlm://image/generated/8e4d5b2c-…` beside its own
/// verdict, an id no tool had given it, and the chat drew "picture
/// unavailable on this device" where question 6's picture belonged.
/// `ReviewSessionManager.unresolvedPictureAddresses` holds a reply to the
/// rule source links already follow: what it shows has to exist, here.
enum ChatPictureAddress: Equatable, Sendable {
    /// A page, figure, slide or moment of this source.
    case source(id: String)
    /// A picture drawn or kept in a device's image store.
    case generated(id: String)
    /// A picture the learner attached to a message.
    case attached(id: String)
    /// No grammar reads it.
    case unreadable

    init(_ target: String) {
        if let generated = GeneratedImageReference(urlString: target) {
            self = .generated(id: generated.id)
        } else if let attached = AttachedImageReference(urlString: target) {
            self = .attached(id: attached.id)
        } else if let source = SourceImageReference(urlString: target) {
            self = .source(id: source.sourceID)
        } else {
            self = .unreadable
        }
    }

    /// The stored picture's id, for a drawn, kept or attached picture.
    var storedID: String? {
        switch self {
        case .generated(let id), .attached(let id): return id
        case .source, .unreadable: return nil
        }
    }

    /// The targets among `targets` that name a stored picture `held` says
    /// this device does not have. Every tool that hands the model a drawn,
    /// kept, captured or attached picture stores it first, so a new reply
    /// that shows one this device lacks shows the "picture unavailable on this
    /// device" note, whatever else says the id exists. An id merely present in
    /// the text the model was handed does not count, even for a picture drawn
    /// on the other Mac. A made-up id that a reply saved before the
    /// check then passed it as soon as the chat went on: the same quiz chat
    /// reused `generated/8e4d5b2c-…`, which it had made up at 15:18, for
    /// question 13's picture at 18:08. Source and unreadable targets are not
    /// judged here.
    static func unheldStoredPictures(
        in targets: [String],
        held: (ChatPictureAddress) -> Bool
    ) -> [String] {
        targets.filter { target in
            let address = ChatPictureAddress(target)
            guard address.storedID != nil else { return false }
            return !held(address)
        }
    }
}
