import Foundation
import ImageIO
import OSLog

extension Notification.Name {
    /// A picture in this Mac's store changed in a way another device shows:
    /// a new version of an image (a revision or a redraw), a rename, or a
    /// version moved to the Trash. `userInfo[GeneratedImageStore.changedIDsKey]`
    /// names the image and the versions involved. Posted off the main actor.
    static let generatedImagesChanged = Notification.Name("ForeverLM.generatedImagesChanged")
    /// Pictures another device holds arrived in this Mac's store with a
    /// synced record. `userInfo[GeneratedImageStore.changedIDsKey]` names
    /// each arrived file's id and its image's id. Posted on the main actor.
    static let generatedImagesArrived = Notification.Name("ForeverLM.generatedImagesArrived")
}

/// Where this device keeps the pictures its chats drew.
///
/// One file per picture under the content root, beside the other bytes this
/// app writes for itself (`Meetings/<id>/icon.jpg` is the precedent), so a
/// library that moves roots keeps its pictures. The file is the whole state:
/// the chat line carries the id, the file carries the bytes, and nothing else
/// has to agree with either.
enum GeneratedImageStore {
    static let directory = "Generated Images"

    /// Extensions a stored picture may carry, in the order a lookup tries them.
    private static let knownExtensions: [(extension: String, mediaType: String)] = [
        ("png", "image/png"),
        ("jpg", "image/jpeg"),
        ("webp", "image/webp"),
    ]

    static func relativePath(id: String, mediaType: String) -> String {
        "\(directory)/\(id).\(fileExtension(for: mediaType))"
    }

    static func fileExtension(for mediaType: String) -> String {
        knownExtensions.first { $0.mediaType == mediaType.lowercased() }?.extension ?? "png"
    }

    /// Writes the picture with what made it and returns its path relative to
    /// the content root. A picture is never stored without its prompt
    /// (product owner, 2026-09-22: "the prompts need to be stored with them"): a
    /// file whose own format cannot carry the details (WebP, which ImageIO
    /// cannot write) is kept as a lossless PNG instead, the details are read
    /// back before anything is written, and a picture that still cannot hold
    /// them is refused with an error rather than saved bare. Never called on
    /// the main actor: it touches the disk.
    static func write(_ image: GeneratedImage, id: String, details: Details) throws -> String {
        var details = details
        if details.imageID == nil { details.imageID = id }
        let stored = try withDetails(image, details)
        let relative = relativePath(id: id, mediaType: stored.mediaType)
        let destination = URL(fileURLWithPath: StorageService.absoluteSourcePath(relative))
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try stored.data.write(to: destination, options: .atomic)
        return relative
    }

    enum WriteFailure: LocalizedError, Equatable {
        case cannotRecordDetails

        var errorDescription: String? {
            switch self {
            case .cannotRecordDetails:
                return "The picture could not be stored with its prompt: it is not an image this Mac can read."
            }
        }
    }

    /// The picture as it will be stored: its own bytes with the details
    /// merged in, or a PNG of its pixels carrying them when its format cannot.
    /// Throws when neither holds the details on reading back.
    static func withDetails(_ image: GeneratedImage, _ details: Details) throws -> GeneratedImage {
        // The bytes say what they are; a declared type is not trusted, so a
        // file's extension always matches its contents. PNG and JPEG are
        // tagged in place; anything else becomes a PNG.
        if let actual = mediaType(of: image.data), ["image/png", "image/jpeg"].contains(actual),
           let tagged = tagged(image.data, with: details), self.details(of: tagged) == details {
            return GeneratedImage(data: tagged, mediaType: actual)
        }
        if let png = pngTagged(image.data, with: details), self.details(of: png) == details {
            logger.info("Generated image kept as PNG so it can carry its prompt (was \(image.mediaType, privacy: .public))")
            return GeneratedImage(data: png, mediaType: "image/png")
        }
        throw WriteFailure.cannotRecordDetails
    }
    /// The stored picture, or nil when this device never drew it. Tries each
    /// extension the store writes rather than recording the type anywhere.
    static func read(id: String) -> GeneratedImage? {
        guard GeneratedImageReference.isValidID(id) else { return nil }
        for candidate in knownExtensions {
            let path = StorageService.absoluteSourcePath("\(directory)/\(id).\(candidate.extension)")
            if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
                return GeneratedImage(data: data, mediaType: candidate.mediaType)
            }
        }
        return nil
    }

    /// Whether this device holds the picture, without reading its bytes.
    /// Never called on the main actor: it touches the disk.
    static func holds(id: String) -> Bool {
        guard GeneratedImageReference.isValidID(id) else { return false }
        return knownExtensions.contains { candidate in
            FileManager.default.fileExists(
                atPath: StorageService.absoluteSourcePath("\(directory)/\(id).\(candidate.extension)")
            )
        }
    }

    /// Moves the stored picture to the Trash. A chat that shows it then says
    /// in place that this device does not hold it, as it does on a device
    /// that never drew it.
    static func trash(id: String) throws {
        guard let listing = listing(id: id) else { return }
        try FileManager.default.trashItem(at: URL(fileURLWithPath: listing.path), resultingItemURL: nil)
        announceChange(ids: [listing.id, listing.imageID])
    }

    /// Moves every version of the image to the Trash.
    static func trash(group: ImageGroup) throws {
        for version in group.versions {
            try trash(id: version.id)
        }
    }

    // MARK: Telling other devices

    /// The ids a `generatedImagesChanged` notice names, under this key.
    static let changedIDsKey = "ids"

    /// Says that the image `id` belongs to changed: the image's id and every
    /// version's. Lists the store; never called on the main actor.
    static func announceChange(ofImageContaining id: String) {
        let ids = group(containing: id).map { [$0.imageID] + $0.versions.map(\.id) } ?? [id]
        announceChange(ids: ids)
    }

    /// Posts `generatedImagesChanged` for `ids`. The sync engine re-sends
    /// each walk that names one, so the pictures it carries
    /// (`StoredPicturePackage`) follow the change.
    static func announceChange(ids: [String]) {
        let unique = Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .filter(GeneratedImageReference.isValidID)
            .sorted()
        guard !unique.isEmpty else { return }
        NotificationCenter.default.post(name: .generatedImagesChanged, object: nil, userInfo: [changedIDsKey: unique])
    }

    // MARK: Renaming

    enum RenameFailure: LocalizedError, Equatable {
        case emptyTitle

        var errorDescription: String? {
            switch self {
            case .emptyTitle: return "An image's title cannot be empty."
            }
        }
    }

    /// The title as it is kept: one line, trimmed; nil when nothing is left.
    static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// Names the image `title` by rewriting every version's metadata, pixels
    /// untouched and each file's dates kept, so the gallery's order and the
    /// sheet's "made" date do not move with a rename.
    static func rename(group: ImageGroup, to title: String) throws {
        guard let title = cleanTitle(title) else { throw RenameFailure.emptyTitle }
        for version in group.versions {
            try rewriteDetails(ofFileAt: URL(fileURLWithPath: version.path), id: version.id) { $0.title = title }
        }
        announceChange(ids: [group.imageID] + group.versions.map(\.id))
    }

    /// Puts the image in `notebookID`'s notebook, or with nil in none, by
    /// rewriting every version's `Details.notebookID`, pixels untouched and
    /// each file's dates kept, as a rename does: the learner's Add to
    /// Notebook ▸ or Remove from Notebook on the picture's card, one image at
    /// a time. Nothing is ever filed in bulk (artifacts.md §3).
    static func setNotebook(group: ImageGroup, to notebookID: String?) throws {
        let notebookID = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = notebookID.flatMap { $0.isEmpty ? nil : $0 }
        for version in group.versions {
            try rewriteDetails(ofFileAt: URL(fileURLWithPath: version.path), id: version.id) { $0.notebookID = stored }
        }
        announceChange(ids: [group.imageID] + group.versions.map(\.id))
    }

    /// Rewrites one stored file's details with `change`, pixels untouched and
    /// the file's dates kept; nothing is written when the change leaves them
    /// as they were. A picture stored before details were written is a drawn
    /// one: screenshots always carried theirs. Throws
    /// for a file whose format cannot carry the details in place (WebP),
    /// rather than writing a PNG under its name.
    static func rewriteDetails(ofFileAt url: URL, id: String, _ change: (inout Details) -> Void) throws {
        let data = try Data(contentsOf: url)
        let before = Self.details(of: data) ?? Details(origin: .drawn, text: "", imageID: id)
        var updated = before
        change(&updated)
        guard updated != before else { return }
        let stored = try withDetails(GeneratedImage(data: data, mediaType: mediaType(of: data) ?? "image/png"), updated)
        guard stored.mediaType == mediaType(of: data) else { throw WriteFailure.cannotRecordDetails }
        let dates = try FileManager.default.attributesOfItem(atPath: url.path)
            .filter { $0.key == .creationDate || $0.key == .modificationDate }
        try stored.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(dates, ofItemAtPath: url.path)
    }

    // MARK: Redrawing

    /// How many redraws a lookup follows before it stops: a picture redrawn
    /// that often is still shown, as its latest redraw within the cap.
    static let maximumRedrawChain = 32

    /// The version shown wherever `id` is named: the one it was redrawn as
    /// (`Details.replacedBy`), followed through every later redraw this
    /// device holds, or `id` itself. A chat line names the version it showed,
    /// and a redraw is a replacement the learner asked for (product owner,
    /// 2026-09-29: regenerate a picture "with a different model … if they
    /// are bad quality"), so the line shows the redraw rather than the
    /// picture that was redrawn. Reads one file's details a step; never
    /// called on the main actor.
    static func shownVersion(for id: String) -> String {
        var current = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen: Set<String> = [current]
        for _ in 0..<maximumRedrawChain {
            guard let next = listing(id: current)?.details?.replacedBy,
                  seen.insert(next).inserted, holds(id: next) else { break }
            current = next
        }
        return current
    }

    /// The version shown for `id` with its bytes: `shownVersion`, read.
    /// Nil when this device holds no such picture.
    static func readShown(id: String) -> (image: GeneratedImage, listing: Listing)? {
        guard GeneratedImageReference.isValidID(id.lowercased()) else { return nil }
        let shown = shownVersion(for: id)
        guard let listing = listing(id: shown),
              let data = FileManager.default.contents(atPath: listing.path), !data.isEmpty else { return nil }
        let type = mediaType(of: data) ?? "image/\(URL(fileURLWithPath: listing.path).pathExtension)"
        return (GeneratedImage(data: data, mediaType: type), listing)
    }

    /// The picture's size in pixels, from its header; nil when the file is
    /// not a picture ImageIO reads.
    static func pixelSize(ofFileAt path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// A redraw that arrived from another device (a quiz's pictures ride its
    /// Course record, `CourseQuizPicturePackage`) names the version it
    /// replaces. When `folder` holds that version and nothing here redrew it
    /// already, it is marked replaced by the arrival, so a chat line that
    /// shows it shows the redraw here as it does on the device that drew it.
    /// Reads and writes files: the sync engine's background path.
    static func adoptArrivedRedraw(id: String, fileAt url: URL, in folder: URL) {
        guard let replaced = details(ofFileAt: url)?.replaces else { return }
        for candidate in knownExtensions {
            let target = folder.appendingPathComponent("\(replaced).\(candidate.extension)", isDirectory: false)
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            guard details(ofFileAt: target)?.replacedBy == nil else { return }
            do {
                try rewriteDetails(ofFileAt: target, id: replaced) { $0.replacedBy = id }
            } catch {
                logger.warning("Arrived redraw \(id, privacy: .public) could not mark \(replaced, privacy: .public) replaced: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
    }

    /// Stores `image`, drawn afresh with `model` from the prompt of the
    /// version `id` names, as the image's next version, and marks that
    /// version replaced by it, so every line and card that showed it shows
    /// the redraw. The replaced version stays in the store as the version it
    /// was. `prompt` replaces the one kept with it, when the learner changed it.
    /// Throws when the store holds no such version or it recorded no
    /// prompt; a version whose file cannot carry the mark (WebP, stored
    /// before details were written) keeps showing where it is named, and the redraw is
    /// still the image's latest. Never called on the main actor.
    static func storeRedraw(
        _ image: GeneratedImage,
        replacing id: String,
        model: String,
        modelID: String?,
        prompt edited: String? = nil
    ) throws -> Listing {
        let replaced = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let old = listing(id: replaced) else { throw RevisionFailure.unknownImage(id) }
        guard let prompt = old.details?.text, !prompt.isEmpty, old.details?.origin != .screenshot else {
            throw RedrawFailure.noPrompt
        }
        // A redraw from a prompt the learner changed keeps the change, so the
        // next redraw starts from it.
        let trimmedEdit = edited?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = trimmedEdit.isEmpty ? prompt : trimmedEdit
        var details = try revisionDetails(origin: .drawn, text: text, model: model, revising: replaced)
        details.modelID = modelID.flatMap { $0.isEmpty ? nil : $0 }
        details.replaces = replaced
        let newID = GeneratedImageReference.newID()
        _ = try write(image, id: newID, details: details)
        guard let stored = listing(id: newID) else { throw WriteFailure.cannotRecordDetails }
        do {
            try rewriteDetails(ofFileAt: URL(fileURLWithPath: old.path), id: old.id) { $0.replacedBy = newID }
        } catch {
            logger.warning("Redrawn picture \(replaced, privacy: .public) could not be marked replaced: \(error.localizedDescription, privacy: .public)")
        }
        announceChange(ofImageContaining: newID)
        return stored
    }

    enum RedrawFailure: LocalizedError, Equatable {
        case noPrompt

        var errorDescription: String? {
            switch self {
            case .noPrompt:
                return "This picture has no prompt recorded, so it cannot be drawn again."
            }
        }
    }

    // MARK: Details

    /// What made a stored picture, carried in the file's own XMP rather than
    /// beside it: the file stays the whole state, the prompt travels with a
    /// picture dragged out of the app, and there is no second record to keep
    /// in step with the bytes.
    ///
    /// A picture iterated on is one image in versions (product owner, 2026-09-22:
    /// "if I want to iterate on the same image, then only store that one …
    /// in a version manner, but you shouldn't show like 10 versions of the
    /// same image"): every version is its own file, so each chat line that
    /// showed one keeps showing exactly that one, and `imageID` — the first
    /// version's file id — ties them together for the gallery and MCP.
    struct Details: Sendable, Equatable {
        enum Origin: String, Sendable {
            /// `generate_image`: ForeverLM's image model drew it from a prompt.
            case drawn
            /// `save_image`: made elsewhere — ChatGPT, Claude, another tool —
            /// and saved here through MCP.
            case saved
            /// `browser_screenshot`: a photograph of the chat's Browser tab.
            case screenshot
        }

        let origin: Origin
        /// The prompt the picture was made from, or a screenshot's caption.
        let text: String
        /// A few words naming the picture, as a file is named (product owner,
        /// 2026-09-24: "they should just have a title, not the entire prompt
        /// as the title"). Given by whoever made it and renamable; nil for a
        /// screenshot and a picture stored before titles were kept.
        var title: String? = nil
        /// The image model's display name; nil for a screenshot, and for a
        /// saved picture whose caller did not say.
        var model: String? = nil
        /// The image this is a version of; nil until `write` fills it with the
        /// file's own id for a first version.
        var imageID: String? = nil
        /// 1 for a first version, one more than the latest for a revision.
        var version: Int = 1
        /// The image model's OpenRouter slug, beside its display name, which
        /// can change; nil for a picture stored before the slug was kept and
        /// for one made elsewhere.
        var modelID: String? = nil
        /// For a redraw: the version it was drawn to replace, from the same
        /// prompt with another model.
        var replaces: String? = nil
        /// For a version that was redrawn: the version shown in its place
        /// (`GeneratedImageStore.shownVersion`).
        var replacedBy: String? = nil
        /// The notebook a standalone picture lives in
        /// (docs/notebooks-design.md, "Homing"): the one it was drawn or kept
        /// in, written once when the image is made. Every later version
        /// carries the image's, so the image lives in one notebook. Nil for a
        /// picture made in no notebook and for every picture stored before
        /// notebooks were kept. A picture inside a quiz or a walkthrough belongs to
        /// that, not to a notebook of its own.
        var notebookID: String? = nil
    }

    /// The details for a revision of `revising` (any version's id, or the
    /// image's): its image id, and the version after the image's latest.
    /// Throws when the store holds no picture by that id.
    /// A revision without a title of its own keeps the image's.
    static func revisionDetails(
        origin: Details.Origin,
        text: String,
        title: String? = nil,
        model: String?,
        revising: String
    ) throws -> Details {
        guard let group = group(containing: revising) else {
            throw RevisionFailure.unknownImage(revising)
        }
        return Details(
            origin: origin,
            text: text,
            title: title ?? group.title,
            model: model,
            imageID: group.imageID,
            version: (group.versions.map(\.version).max() ?? 0) + 1,
            notebookID: group.notebookID
        )
    }

    enum RevisionFailure: LocalizedError, Equatable {
        case unknownImage(String)

        var errorDescription: String? {
            switch self {
            case .unknownImage(let id):
                return "No stored picture on this Mac is named \(id). Pass an image_id from list_images or list_generated_images, or leave revises out to make a new image."
            }
        }
    }

    static let metadataNamespace = "https://foreverlm.com/ns/generated-image/1.0/"
    static let metadataPrefix = "foreverlm"

    private static let logger = Logger(subsystem: "com.foreverlm.app", category: "GeneratedImageStore")

    /// The same image with `details` merged into its metadata, pixels
    /// untouched; nil when ImageIO cannot rewrite this kind of file (WebP).
    static func tagged(_ data: Data, with details: Details) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let metadata = metadata(for: details) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else { return nil }
        return output as Data
    }

    /// `image/png` or `image/jpeg` for bytes of that format, another image
    /// type's media type, or nil for bytes that are not an image.
    static func mediaType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return nil }
        switch type {
        case "public.png": return "image/png"
        case "public.jpeg": return "image/jpeg"
        case "org.webmnotebook.webp": return "image/webp"
        default: return "image/\(type.split(separator: ".").last ?? "unknown")"
        }
    }

    /// The image's pixels as a PNG carrying `details` — lossless, for a
    /// format `tagged` cannot rewrite; nil when the bytes are not an image.
    static func pngTagged(_ data: Data, with details: Details) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let metadata = metadata(for: details) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func metadata(for details: Details) -> CGMutableImageMetadata? {
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(
            metadata, metadataNamespace as CFString, metadataPrefix as CFString, nil
        ) else { return nil }
        var fields: [(String, String)] = [
            ("origin", details.origin.rawValue),
            ("text", details.text),
            ("version", String(details.version)),
        ]
        if let title = details.title { fields.append(("title", title)) }
        if let model = details.model { fields.append(("model", model)) }
        if let imageID = details.imageID { fields.append(("image", imageID)) }
        if let modelID = details.modelID, !modelID.isEmpty { fields.append(("modelID", modelID)) }
        if let replaces = details.replaces { fields.append(("replaces", replaces)) }
        if let replacedBy = details.replacedBy { fields.append(("replacedBy", replacedBy)) }
        if let notebookID = details.notebookID, !notebookID.isEmpty { fields.append(("notebook", notebookID)) }
        for (name, value) in fields {
            guard let tag = CGImageMetadataTagCreate(
                metadataNamespace as CFString, metadataPrefix as CFString, name as CFString,
                .string, value as CFString
            ), CGImageMetadataSetTagWithPath(metadata, nil, "\(metadataPrefix):\(name)" as CFString, tag)
            else { return nil }
        }
        return metadata
    }

    /// The details a stored file carries; nil for a picture stored before
    /// they were written.
    static func details(ofFileAt url: URL) -> Details? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return details(in: source)
    }

    static func details(of data: Data) -> Details? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return details(in: source)
    }

    private static func details(in source: CGImageSource) -> Details? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        func value(_ name: String) -> String? {
            CGImageMetadataCopyStringValueWithPath(metadata, nil, "\(metadataPrefix):\(name)" as CFString) as String?
        }
        guard let origin = value("origin").flatMap(Details.Origin.init(rawValue:)) else { return nil }
        return Details(
            origin: origin,
            text: value("text") ?? "",
            title: value("title").flatMap { $0.isEmpty ? nil : $0 },
            model: value("model"),
            imageID: value("image"),
            version: value("version").flatMap(Int.init) ?? 1,
            modelID: value("modelID").flatMap { $0.isEmpty ? nil : $0 },
            replaces: value("replaces").flatMap { GeneratedImageReference.isValidID($0) ? $0 : nil },
            replacedBy: value("replacedBy").flatMap { GeneratedImageReference.isValidID($0) ? $0 : nil },
            // A picture stored before a notebook stopped being called a project
            // carries the filing under that word.
            notebookID: (value("notebook") ?? value("project")).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: Listing

    /// One picture in the store, as a notebook's Studio lists it.
    struct Listing: Identifiable, Sendable, Equatable {
        let id: String
        let path: String
        let createdAt: Date
        let details: Details?

        var reference: GeneratedImageReference? { GeneratedImageReference(id: id) }

        /// The image this version belongs to: its own id for a first version
        /// and for a picture stored before versions were written.
        var imageID: String { details?.imageID ?? id }
        var version: Int { details?.version ?? 1 }

        /// A picture made from a prompt — drawn here or saved from elsewhere —
        /// or one stored before details were written, which cannot be told
        /// from a screenshot and is kept.
        var isDrawn: Bool { details?.origin != .screenshot }
    }

    /// One image and every version of it, newest version first.
    struct ImageGroup: Identifiable, Sendable, Equatable {
        let imageID: String
        /// Never empty; the first is the latest version.
        let versions: [Listing]

        var id: String { imageID }
        var latest: Listing { versions[0] }
        var updatedAt: Date { latest.createdAt }
        /// The newest title any version carries: a rename writes every
        /// version, and a revision keeps the image's.
        var title: String? { versions.lazy.compactMap { $0.details?.title }.first }
        /// The notebook the image lives in, written with its first version and
        /// carried by every later one (`Details.notebookID`); nil for one made
        /// in no notebook.
        var notebookID: String? { versions.lazy.compactMap { $0.details?.notebookID }.first }

        /// The version shown where `id` is named: that version as redrawn,
        /// through every redraw the group holds (`Details.replacedBy`), or
        /// the latest when `id` is none of the group's versions.
        func shown(for id: String) -> Listing {
            let byID = Dictionary(versions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard var current = byID[id.lowercased()] else { return latest }
            var seen: Set<String> = [current.id]
            for _ in 0..<GeneratedImageStore.maximumRedrawChain {
                guard let next = current.details?.replacedBy.flatMap({ byID[$0] }),
                      seen.insert(next.id).inserted else { break }
                current = next
            }
            return current
        }

        /// The versions shown as `id`: `id` and every version whose redraws
        /// lead to it. A quiz that pinned any of them shows `id`'s redraw.
        func versions(showingAs id: String) -> [String] {
            let wanted = id.lowercased()
            return versions.map(\.id).filter { shown(for: $0).id == wanted }
        }
    }

    /// The listings as images: each image once, its versions newest first,
    /// the most recently changed image first.
    static func groups(_ listings: [Listing]) -> [ImageGroup] {
        Dictionary(grouping: listings, by: \.imageID)
            .map { imageID, versions in
                ImageGroup(
                    imageID: imageID,
                    versions: versions.sorted {
                        ($0.version, $0.createdAt) > ($1.version, $1.createdAt)
                    }
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Every made picture this Mac holds, as images; screenshots left out.
    static func imageGroups() -> [ImageGroup] {
        groups(list().filter(\.isDrawn))
    }

    /// The picture a revision of `id` edits: the version it names (as
    /// redrawn, `ImageGroup.shown(for:)`), or the image's latest when it
    /// names the image (whose id is also its first version's). Nil when the
    /// store holds no such picture.
    static func revisionBase(for id: String) -> GeneratedImage? {
        readImageOrVersion(id)?.image
    }

    /// What a surface that names an image or one of its versions shows — a
    /// walkthrough card, which names the image so a revision shows revised —
    /// with the version it is: the image's latest when `id` names the image,
    /// else the version `id` names as redrawn. Nil when the store holds no
    /// such picture. Lists the store; never called on the main actor.
    static func readImageOrVersion(_ id: String) -> (image: GeneratedImage, listing: Listing)? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let group = group(containing: wanted) else { return nil }
        let version = wanted == group.imageID ? group.latest : group.shown(for: wanted)
        guard let data = FileManager.default.contents(atPath: version.path), !data.isEmpty,
              let mediaType = mediaType(of: data) else { return nil }
        return (GeneratedImage(data: data, mediaType: mediaType), version)
    }

    /// The image `id` names — the image's id or any version's file id.
    static func group(containing id: String) -> ImageGroup? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard GeneratedImageReference.isValidID(wanted) else { return nil }
        let all = groups(list())
        return all.first { $0.imageID == wanted } ?? all.first { group in
            group.versions.contains { $0.id == wanted }
        }
    }

    /// A cheap fingerprint of what the store holds: every file's name and
    /// modification time, read in one pass over the folder, with none of the
    /// metadata inside the files. It moves when a picture is added, rewritten
    /// (a rename) or removed, so a reader of the whole store can tell it has
    /// not changed since it last looked. Never called on the main actor.
    static func folderStamp() -> Int {
        let folder = URL(fileURLWithPath: StorageService.absoluteSourcePath(directory), isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var hasher = Hasher()
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            hasher.combine(url.lastPathComponent)
            hasher.combine((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        return hasher.finalize()
    }

    /// Every picture this device holds, newest first. Reads each file's
    /// metadata, not its pixels; never called on the main actor.
    static func list() -> [Listing] {
        list(in: URL(fileURLWithPath: StorageService.absoluteSourcePath(directory), isDirectory: true))
    }

    /// Every picture a store folder holds, newest first: this Mac's store, or
    /// another root's in a test.
    static func list(in folder: URL) -> [Listing] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap(listing(at:)).sorted { $0.createdAt > $1.createdAt }
    }

    static func listing(id: String) -> Listing? {
        guard GeneratedImageReference.isValidID(id) else { return nil }
        for candidate in knownExtensions {
            let path = StorageService.absoluteSourcePath("\(directory)/\(id).\(candidate.extension)")
            if FileManager.default.fileExists(atPath: path) {
                return listing(at: URL(fileURLWithPath: path))
            }
        }
        return nil
    }

    private static func listing(at url: URL) -> Listing? {
        let id = url.deletingPathExtension().lastPathComponent
        guard GeneratedImageReference.isValidID(id),
              knownExtensions.contains(where: { $0.extension == url.pathExtension.lowercased() }) else { return nil }
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        return Listing(id: id, path: url.path, createdAt: created, details: details(ofFileAt: url))
    }

    // MARK: Storing a made picture

    /// Stores a picture made from `text`: a new image, or with `revising` the
    /// next version of the image that id names. Returns what was stored.
    /// `notebookID` is the notebook a new image lives in; a revision keeps the
    /// image's and ignores it, since an image lives in one notebook from the
    /// day it is made. Never called on the main actor.
    static func store(
        _ image: GeneratedImage,
        origin: Details.Origin,
        text: String,
        title: String? = nil,
        model: String?,
        modelID: String? = nil,
        revising: String?,
        notebookID: String? = nil
    ) throws -> Listing {
        let id = GeneratedImageReference.newID()
        var details: Details
        if let revising {
            details = try revisionDetails(origin: origin, text: text, title: title, model: model, revising: revising)
        } else {
            details = Details(origin: origin, text: text, title: title, model: model)
            details.notebookID = notebookID.flatMap { $0.isEmpty ? nil : $0 }
        }
        details.modelID = modelID.flatMap { $0.isEmpty ? nil : $0 }
        _ = try write(image, id: id, details: details)
        guard let stored = listing(id: id) else { throw WriteFailure.cannotRecordDetails }
        // A new image is named nowhere yet; a revision is the image's latest
        // wherever the image is named.
        if revising != nil { announceChange(ofImageContaining: id) }
        return stored
    }

    // MARK: Catalog

    /// The images as text for a model: each image once, with its latest
    /// version's prompt and line, and — with `forMCP` — its ids, versions
    /// and file path. `query` keeps images whose title or any version's
    /// prompt holds every word.
    static func catalog(_ groups: [ImageGroup], query: String?, limit: Int, forMCP: Bool) -> String {
        let words = (query ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = groups.filter { group in
            words.allSatisfy { word in
                (group.title ?? "").localizedCaseInsensitiveContains(word)
                    || group.versions.contains { ($0.details?.text ?? "").localizedCaseInsensitiveContains(word) }
            }
        }
        guard !matching.isEmpty else {
            return words.isEmpty
                ? "No images are stored on this Mac yet."
                : "No stored image's title or prompt matches \"\(query ?? "")\"."
        }
        let shown = matching.prefix(limit)
        var lines = [
            "\(matching.count) image\(matching.count == 1 ? "" : "s")"
                + (words.isEmpty ? "" : " matching \"\(query ?? "")\"")
                + ", most recently changed first"
                + (matching.count > shown.count ? "; the first \(shown.count)" : "")
                + ":"
        ]
        for group in shown {
            let latest = group.latest
            let prompt = latest.details?.text ?? ""
            var header = "- \(group.title.map { "\"\($0)\" · " } ?? "")"
            if forMCP { header += "image_id \(group.imageID) · " }
            header += latest.createdAt.formatted(date: .abbreviated, time: .shortened)
            if forMCP, let notebookID = group.notebookID { header += " · notebook_id \(notebookID)" }
            if let model = latest.details?.model { header += " · \(model)" }
            if latest.details?.origin == .saved { header += " · saved from elsewhere" }
            if group.versions.count > 1 { header += " · \(group.versions.count) versions, showing v\(latest.version)" }
            lines.append(header)
            lines.append("  Prompt: \(prompt.isEmpty ? "(not recorded; stored before prompts were kept)" : prompt)")
            if let reference = latest.reference {
                lines.append("  \(reference.markdown(alt: altText(for: group)))")
            }
            if forMCP {
                lines.append("  File: \(latest.path)")
                if group.versions.count > 1 {
                    let older = group.versions.dropFirst().map { "v\($0.version) \($0.id)" }.joined(separator: ", ")
                    lines.append("  Earlier versions: \(older)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Alt text for an image: its title, or for one stored before titles
    /// were kept the opening of its prompt.
    static func altText(for group: ImageGroup) -> String {
        if let title = group.title { return title }
        let prompt = group.latest.details?.text ?? ""
        return prompt.isEmpty ? "Generated image" : altText(prompt)
    }

    /// Alt text for a picture: the opening of its prompt, capped so a
    /// paragraph-long description does not become the caption.
    static func altText(_ prompt: String) -> String {
        let flattened = prompt
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > 90 else { return flattened }
        let head = String(flattened.prefix(90))
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head[...]
        return String(cut).trimmingCharacters(in: .punctuationCharacters) + "…"
    }
}
