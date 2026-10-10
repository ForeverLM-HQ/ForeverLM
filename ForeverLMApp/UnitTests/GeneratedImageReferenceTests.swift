import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import ForeverLM

@Suite("Generated image references")
struct GeneratedImageReferenceTests {
    @Test("A drawn picture's reference round-trips through its URL")
    func roundTrip() {
        let id = GeneratedImageReference.newID()
        let reference = GeneratedImageReference(id: id)
        #expect(reference?.urlString == "foreverlm://image/generated/\(id)")
        #expect(GeneratedImageReference(urlString: reference!.urlString) == reference)
        #expect(reference?.markdown(alt: "Mitochondria as [control] knobs\nfor the cell")
            == "![Mitochondria as (control) knobs for the cell](foreverlm://image/generated/\(id))")
        #expect(reference?.markdown(alt: "   ") == "![Generated image](foreverlm://image/generated/\(id))")
    }

    @Test("Generated and source references never claim each other's URLs")
    func grammarsAreDisjoint() {
        let generated = "foreverlm://image/generated/0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        #expect(GeneratedImageReference(urlString: generated) != nil)
        #expect(SourceImageReference(urlString: generated) == nil)

        let source = "foreverlm://image/generated/page/3"
        #expect(GeneratedImageReference(urlString: source) == nil)
        #expect(SourceImageReference(urlString: source)?.sourceID == "generated")
    }

    @Test("An id that could name a path outside the store is refused")
    func unsafeIDsAreRefused() {
        #expect(GeneratedImageReference(id: "../etc/passwd") == nil)
        #expect(GeneratedImageReference(id: "short") == nil)
        #expect(GeneratedImageReference(id: "ABCDEF12-3456") != nil, "uppercase hex is folded, not refused")
        #expect(GeneratedImageReference(id: "ABCDEF12-3456")?.id == "abcdef12-3456")
        #expect(GeneratedImageReference(urlString: "foreverlm://image/generated/") == nil)
        #expect(GeneratedImageReference(urlString: "foreverlm://image/generated/a1b2c3d4/extra") == nil)
        #expect(GeneratedImageReference(urlString: "https://example.com/image/generated/a1b2c3d4") == nil)
    }

    /// A real 4×4 picture in `type`, since the details ride ImageIO.
    private static func pictureData(_ type: UTType, red: CGFloat = 0.8) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: 0.2, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func pixels(_ data: Data) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(image.dataProvider?.data as Data?)
    }

    /// Removes every file a test stored.
    private static func remove(_ ids: [String]) {
        for id in ids {
            if let listing = GeneratedImageStore.listing(id: id) {
                try? FileManager.default.removeItem(atPath: listing.path)
            }
        }
    }

    @Test("The store finds a picture by id whatever type it was written as")
    func storeRoundTrip() throws {
        let id = GeneratedImageReference.newID()
        let relative = try GeneratedImageStore.write(
            GeneratedImage(data: try Self.pictureData(.png), mediaType: "image/png"),
            id: id,
            details: .init(origin: .drawn, text: "A red square")
        )
        defer { Self.remove([id]) }
        #expect(relative == "Generated Images/\(id).png")

        let read = GeneratedImageStore.read(id: id)
        #expect(read?.mediaType == "image/png")
        #expect(GeneratedImageStore.read(id: GeneratedImageReference.newID()) == nil)
        #expect(GeneratedImageStore.read(id: "../\(id)") == nil)
    }

    @Test("The transcript resolves a drawn picture from the store without an article")
    @MainActor
    func transcriptResolvesGeneratedPicture() async throws {
        let id = GeneratedImageReference.newID()
        _ = try GeneratedImageStore.write(
            GeneratedImage(data: try Self.pictureData(.png), mediaType: "image/png"),
            id: id,
            details: .init(origin: .drawn, text: "A red square")
        )
        defer { Self.remove([id]) }
        let reference = try #require(GeneratedImageReference(id: id))
        let stored = try #require(GeneratedImageStore.read(id: id))

        var askedForArticle = false
        let resolved = await ChatSourceImage.resolved(token: reference.urlString) { _ in
            askedForArticle = true
            return nil
        }
        #expect(resolved?.data == stored.data)
        #expect(resolved?.mediaType == "image/png")
        #expect(resolved?.dataURL.hasPrefix("data:image/png;base64,") == true)
        #expect(!askedForArticle, "a drawn picture needs no source to resolve through")

        let missing = await ChatSourceImage.resolved(token: "foreverlm://image/generated/\(GeneratedImageReference.newID())") { _ in nil }
        #expect(missing == nil)
    }

    @Test("Alt text is the opening of the prompt, cut at a word")
    func altText() {
        #expect(ReviewSessionManager.generatedImageAlt("A short prompt") == "A short prompt")
        let long = "A cutaway illustration of a cell in which each mitochondrion is drawn as a brass control knob on a mixing desk, warm studio light, no text anywhere"
        let alt = ReviewSessionManager.generatedImageAlt(long)
        #expect(alt.hasSuffix("…"))
        #expect(alt.count <= 92)
        #expect(!alt.contains("\n"))
        #expect(alt == "A cutaway illustration of a cell in which each mitochondrion is drawn as a brass control…")
    }

    @Test("A picture keeps its prompt, model and image id in its own file, pixels untouched", arguments: [UTType.png, UTType.jpeg])
    func detailsRoundTrip(type: UTType) throws {
        let id = GeneratedImageReference.newID()
        let bytes = try Self.pictureData(type)
        let details = GeneratedImageStore.Details(origin: .drawn, text: "A mitochondrion as a “power plant”, ünïcode", model: "GPT Image 2")
        let relative = try GeneratedImageStore.write(
            GeneratedImage(data: bytes, mediaType: type.preferredMIMEType ?? "image/png"),
            id: id,
            details: details
        )
        defer { Self.remove([id]) }
        let url = URL(fileURLWithPath: StorageService.absoluteSourcePath(relative))
        #expect(url.pathExtension == (type == .png ? "png" : "jpg"), "a PNG or JPEG keeps its own format")

        var expected = details
        expected.imageID = id
        #expect(GeneratedImageStore.details(ofFileAt: url) == expected, "a first version is its own image")
        let listing = try #require(GeneratedImageStore.listing(id: id))
        #expect(listing.imageID == id)
        #expect(listing.version == 1)
        #expect(listing.isDrawn)
        #expect(try Self.pixels(Data(contentsOf: url)) == Self.pixels(bytes))
    }

    @Test("A picture whose format cannot carry a prompt is kept as a PNG that does")
    func untaggableFormatBecomesPNG() throws {
        // Only PNG and JPEG are tagged in place; any other format — GIF here,
        // WebP from a model, HEIC from a phone — is kept as a lossless PNG so
        // the prompt is always stored with it.
        let gif = try Self.pictureData(.gif)
        #expect(GeneratedImageStore.mediaType(of: gif) != "image/png")
        let id = GeneratedImageReference.newID()
        let relative = try GeneratedImageStore.write(
            GeneratedImage(data: gif, mediaType: "image/gif"),
            id: id,
            details: .init(origin: .saved, text: "A pink square", model: "ChatGPT")
        )
        defer { Self.remove([id]) }
        #expect(relative == "Generated Images/\(id).png")
        let stored = try #require(GeneratedImageStore.read(id: id))
        #expect(GeneratedImageStore.mediaType(of: stored.data) == "image/png")
        #expect(GeneratedImageStore.details(of: stored.data)?.text == "A pink square")
        #expect(GeneratedImageStore.details(of: stored.data)?.origin == .saved)
    }

    @Test("A declared type is not trusted: JPEG bytes named PNG are stored as a .jpg")
    func declaredTypeIsNotTrusted() throws {
        let id = GeneratedImageReference.newID()
        let relative = try GeneratedImageStore.write(
            GeneratedImage(data: try Self.pictureData(.jpeg), mediaType: "image/png"),
            id: id,
            details: .init(origin: .saved, text: "Mislabelled")
        )
        defer { Self.remove([id]) }
        #expect(relative == "Generated Images/\(id).jpg")
    }

    @Test("Bytes that are not an image are refused, never stored without a prompt")
    func nonImageIsRefused() throws {
        let id = GeneratedImageReference.newID()
        #expect(throws: GeneratedImageStore.WriteFailure.cannotRecordDetails) {
            try GeneratedImageStore.write(
                GeneratedImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x00]), mediaType: "image/png"),
                id: id,
                details: .init(origin: .drawn, text: "unreadable")
            )
        }
        #expect(GeneratedImageStore.listing(id: id) == nil)
    }

    @Test("A screenshot is stored beside the pictures but not listed as an image")
    func screenshotsAreNotImages() throws {
        let stored = try GeneratedImageStore.store(
            GeneratedImage(data: try Self.pictureData(.png), mediaType: "image/png"),
            origin: .screenshot, text: "Example Domain", model: nil, revising: nil
        )
        defer { Self.remove([stored.id]) }
        #expect(stored.details?.origin == .screenshot)
        #expect(!stored.isDrawn)
        #expect(!GeneratedImageStore.imageGroups().contains { $0.imageID == stored.imageID })
    }

    @Test("A revision is the next version of one image, and the image is listed once at its latest")
    func revisionsAreVersionsOfOneImage() throws {
        let first = try GeneratedImageStore.store(
            GeneratedImage(data: try Self.pictureData(.png, red: 0.9), mediaType: "image/png"),
            origin: .drawn, text: "Krebs cycle as a clock face", model: "GPT Image 2", revising: nil
        )
        // Revising by an older version's id, or by the image's, lands on the
        // same image: versions do not fork.
        let second = try GeneratedImageStore.store(
            GeneratedImage(data: try Self.pictureData(.png, red: 0.5), mediaType: "image/png"),
            origin: .drawn, text: "Krebs cycle as a clock face, bluer", model: "GPT Image 2", revising: first.id
        )
        let third = try GeneratedImageStore.store(
            GeneratedImage(data: try Self.pictureData(.jpeg, red: 0.1), mediaType: "image/jpeg"),
            origin: .saved, text: "Krebs cycle as a clock face, from ChatGPT", model: "ChatGPT", revising: first.id
        )
        let other = try GeneratedImageStore.store(
            GeneratedImage(data: try Self.pictureData(.png), mediaType: "image/png"),
            origin: .drawn, text: "Electron transport chain", model: nil, revising: nil
        )
        defer { Self.remove([first.id, second.id, third.id, other.id]) }

        #expect(first.imageID == first.id)
        #expect(second.imageID == first.id)
        #expect(third.imageID == first.id)
        let versions: [Int] = [first.version, second.version, third.version]
        #expect(versions == [1, 2, 3])

        let group = try #require(GeneratedImageStore.group(containing: second.id))
        #expect(group.imageID == first.id)
        #expect(group.versions.map(\.id) == [third.id, second.id, first.id], "newest version first")
        #expect(group.latest.id == third.id)
        #expect(GeneratedImageStore.group(containing: first.id) == group)

        let mine = GeneratedImageStore.imageGroups().filter { [first.imageID, other.imageID].contains($0.imageID) }
        #expect(mine.count == 2, "three versions are one image, beside the other image")

        #expect(throws: GeneratedImageStore.RevisionFailure.unknownImage("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")) {
            try GeneratedImageStore.store(
                GeneratedImage(data: try Self.pictureData(.png), mediaType: "image/png"),
                origin: .drawn, text: "x", model: nil, revising: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
            )
        }

        try GeneratedImageStore.trash(id: third.id)
        #expect(GeneratedImageStore.group(containing: first.id)?.latest.id == second.id, "trashing the latest shows the one before")
    }

    @Test("A revision edits the version it names, or the image's latest when it names the image")
    func revisionEditsTheNamedVersion() throws {
        let firstBytes = try Self.pictureData(.png, red: 0.9)
        let secondBytes = try Self.pictureData(.jpeg, red: 0.2)
        let first = try GeneratedImageStore.store(
            GeneratedImage(data: firstBytes, mediaType: "image/png"),
            origin: .drawn, text: "Krebs cycle as a clock face", model: nil, revising: nil
        )
        let second = try GeneratedImageStore.store(
            GeneratedImage(data: secondBytes, mediaType: "image/jpeg"),
            origin: .drawn, text: "Bluer", model: nil, revising: first.id
        )
        defer { Self.remove([first.id, second.id]) }

        // The image's id is its first version's file id too; named as the
        // image, the revision edits the picture as it is now.
        let latest = try #require(GeneratedImageStore.revisionBase(for: first.imageID))
        #expect(latest.mediaType == "image/jpeg")
        #expect(try Self.pixels(latest.data) == Self.pixels(secondBytes))
        let named = try #require(GeneratedImageStore.revisionBase(for: second.id.uppercased()))
        #expect(named.mediaType == "image/jpeg")
        #expect(GeneratedImageStore.revisionBase(for: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0") == nil)
    }

    @Test("An image is named by its title, which a revision keeps and a rename writes to every version")
    func titlesNameImagesAndRenameEveryVersion() throws {
        let firstBytes = try Self.pictureData(.png, red: 0.9)
        let first = try GeneratedImageStore.store(
            GeneratedImage(data: firstBytes, mediaType: "image/png"),
            origin: .drawn,
            text: "Create a clean landscape scientific teaching diagram comparing forward electron transport with reverse electron transport",
            title: "Forward vs reverse electron transport",
            model: "Gemini 3 Pro Image",
            revising: nil
        )
        let second = try GeneratedImageStore.store(
            GeneratedImage(data: try Self.pictureData(.jpeg, red: 0.2), mediaType: "image/jpeg"),
            origin: .drawn, text: "Make the ROS burst smaller", model: "Gemini 3 Pro Image", revising: first.id
        )
        defer { Self.remove([first.id, second.id]) }

        #expect(first.details?.title == "Forward vs reverse electron transport")
        #expect(second.details?.title == "Forward vs reverse electron transport", "a revision without a title keeps the image's")
        var group = try #require(GeneratedImageStore.group(containing: first.id))
        #expect(group.title == "Forward vs reverse electron transport")
        #expect(GeneratedImageStore.altText(for: group) == "Forward vs reverse electron transport")

        let dates = try FileManager.default.attributesOfItem(atPath: first.path)[.creationDate] as? Date
        try GeneratedImageStore.rename(group: group, to: "  Electron transport,\nboth ways ")
        group = try #require(GeneratedImageStore.group(containing: first.id))
        #expect(group.title == "Electron transport, both ways")
        #expect(group.versions.allSatisfy { $0.details?.title == "Electron transport, both ways" })
        #expect(group.versions.map(\.id) == [second.id, first.id], "a rename moves no version")
        let renamedFirst = try #require(GeneratedImageStore.listing(id: first.id))
        #expect(renamedFirst.details?.text == first.details?.text, "the prompt is kept")
        #expect(renamedFirst.details?.model == "Gemini 3 Pro Image")
        #expect(renamedFirst.createdAt == first.createdAt)
        #expect((try FileManager.default.attributesOfItem(atPath: first.path)[.creationDate] as? Date) == dates)
        #expect(try Self.pixels(Data(contentsOf: URL(fileURLWithPath: first.path))) == Self.pixels(firstBytes))

        #expect(throws: GeneratedImageStore.RenameFailure.emptyTitle) {
            try GeneratedImageStore.rename(group: group, to: " \n ")
        }
        #expect(GeneratedImageStore.catalog([group], query: "both ways", limit: 5, forMCP: true).contains("\"Electron transport, both ways\""))

        let untitled = try GeneratedImageStore.store(
            GeneratedImage(data: try Self.pictureData(.png), mediaType: "image/png"),
            origin: .saved, text: "Krebs cycle", model: nil, revising: nil
        )
        defer { Self.remove([untitled.id]) }
        #expect(GeneratedImageStore.group(containing: untitled.id)?.title == nil)
    }

    @Test("The picture being revised travels as a data: URL, and only in a format the makers read")
    func referenceDataURL() throws {
        let png = GeneratedImage(data: Data([1, 2, 3]), mediaType: "image/png")
        #expect(try ManagedImageGeneration.referenceDataURL(png) == "data:image/png;base64,AQID")
        #expect(throws: (any Error).self) {
            try ManagedImageGeneration.referenceDataURL(GeneratedImage(data: Data([1]), mediaType: "image/heic"))
        }
        #expect(throws: (any Error).self) {
            try ManagedImageGeneration.referenceDataURL(GeneratedImage(data: Data(), mediaType: "image/png"))
        }
    }

    @Test("The catalog lists each image once, with its latest prompt, line and versions")
    func catalogListsImagesOnce() throws {
        func listing(_ id: String, _ text: String?, version: Int = 1, image: String? = nil, at seconds: TimeInterval, model: String? = nil) -> GeneratedImageStore.Listing {
            GeneratedImageStore.Listing(
                id: id,
                path: "/tmp/\(id).png",
                createdAt: Date(timeIntervalSince1970: seconds),
                details: text.map { .init(origin: .drawn, text: $0, model: model, imageID: image ?? id, version: version) }
            )
        }
        let krebs1 = listing("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", "Krebs cycle as a clock face", at: 1_790_000_000, model: "GPT Image 2")
        let krebs2 = listing("2f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", "Krebs cycle as a clock face, bluer", version: 2, image: krebs1.id, at: 1_790_200_000, model: "GPT Image 2")
        let untagged = listing("1f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", nil, at: 1_790_100_000)
        let groups = GeneratedImageStore.groups([krebs1, untagged, krebs2])
        #expect(groups.map(\.imageID) == [krebs1.id, untagged.id], "most recently changed first, each image once")

        let chat = GeneratedImageStore.catalog(groups, query: nil, limit: 20, forMCP: false)
        #expect(chat.contains("2 images"))
        #expect(chat.contains("![Krebs cycle as a clock face, bluer](foreverlm://image/generated/\(krebs2.id))"), "the latest version's line")
        #expect(!chat.contains("foreverlm://image/generated/\(krebs1.id))"), "an older version is not offered as the image")
        #expect(chat.contains("2 versions, showing v2"))
        #expect(chat.contains("foreverlm://image/generated/\(untagged.id)"))
        #expect(!chat.contains("image_id"), "ids and paths are for MCP")

        let mcp = GeneratedImageStore.catalog(groups, query: nil, limit: 20, forMCP: true)
        #expect(mcp.contains("image_id \(krebs1.id)"))
        #expect(mcp.contains("Earlier versions: v1 \(krebs1.id)"))
        #expect(mcp.contains("File: /tmp/\(krebs2.id).png"))

        let matched = GeneratedImageStore.catalog(groups, query: "krebs CLOCK", limit: 20, forMCP: false)
        #expect(matched.contains("1 image matching"))
        #expect(!matched.contains(untagged.id))
        #expect(GeneratedImageStore.catalog(groups, query: nil, limit: 1, forMCP: false).contains("the first 1"))
        #expect(GeneratedImageStore.catalog(groups, query: "ATP", limit: 20, forMCP: false).contains("No stored image"))
        #expect(GeneratedImageStore.catalog([], query: nil, limit: 20, forMCP: false).contains("No images are stored"))
    }

    @Test("revises accepts an id, an address or the picture's whole Markdown line")
    func revisesArgumentForms() {
        let id = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        #expect(ReviewSessionManager.imageID(fromArgument: id) == id)
        #expect(ReviewSessionManager.imageID(fromArgument: id.uppercased()) == id)
        #expect(ReviewSessionManager.imageID(fromArgument: "foreverlm://image/generated/\(id)") == id)
        #expect(ReviewSessionManager.imageID(fromArgument: "![Krebs](foreverlm://image/generated/\(id))") == id)
        #expect(ReviewSessionManager.imageID(fromArgument: "  ") == nil)
        #expect(ReviewSessionManager.imageID(fromArgument: nil) == nil)
    }
}

/// The chat draws a video's slide from the frame its stored content names.
/// The sidebar catalog's rows carry no content, and on 2026-09-25 every slide
/// the chat showed from a library video drew as "picture unavailable" because
/// the resolver read the row's missing content and gave up.
@Suite("Chat slide resolution")
struct ChatSlideResolutionTests {
    @Test("A slide resolves through stored content when the article row carries none")
    @MainActor
    func slideResolvesThroughStoredContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-slide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let framePath = directory.appendingPathComponent("slide_001_000000s.jpg").path
        let context = try #require(CGContext(
            data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let frame = try #require(context.makeImage())
        try SlideFrameExtraction.writeJPEG(frame, to: URL(fileURLWithPath: framePath))

        let sourceID = "video-\(UUID().uuidString)"
        let content = """
        [0:00] Welcome.

        ## Extracted video slide frames

        Representative slide screenshots extracted from this video's frames.

        ### Slide frame 1 [0:00–0:40]
        Image: \(framePath)
        """
        let row = StudioArticle(url: "https://www.youtube.com/watch?v=abcdefghijk", title: "Talk", sourceType: .article, id: sourceID)
        #expect(row.content == nil)
        let token = SourceImageReference(sourceID: sourceID, location: .slide(1)).urlString

        let withoutStore = await ChatSourceImage.resolved(token: token, articleForSourceID: { _ in row })
        #expect(withoutStore == nil)

        let resolved = await ChatSourceImage.resolved(
            token: token,
            articleForSourceID: { _ in row },
            contentForSourceID: { id in id == sourceID ? content : nil }
        )
        #expect(resolved?.mediaType == "image/jpeg")
        #expect((resolved?.data.count ?? 0) > 0)
    }
}

/// Drawing a quiz's, a walkthrough card's or a chat's picture again with
/// another model (product owner, 2026-09-29: "right click and see which model
/// generated them; then regenerate them with a different model").
@Suite("Generated image redraws")
struct GeneratedImageRedrawTests {
    /// A real `width`×`height` picture in `type`, since the details ride ImageIO.
    private static func pictureData(_ type: UTType = .png, width: Int = 4, height: Int = 4, red: CGFloat = 0.8) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: 0.2, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func pixels(_ data: Data) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(image.dataProvider?.data as Data?)
    }

    private static func remove(_ ids: [String]) {
        for id in ids {
            if let listing = GeneratedImageStore.listing(id: id) {
                try? FileManager.default.removeItem(atPath: listing.path)
            }
        }
    }

    private static func model(_ id: String, _ name: String, listedOn day: Double? = nil) -> ImageGenerationModel {
        ImageGenerationModel(
            id: id, name: name, maker: "Maker", detail: "",
            createdAt: day.map { Date(timeIntervalSince1970: $0 * 86_400) },
            aspectRatios: [], qualities: [], resolutions: [], outputFormats: [],
            takesCount: false, maximumReferences: 0
        )
    }

    @Test("A redraw is the image's next version, shown wherever the version it replaced is named")
    func redrawReplacesInPlace() throws {
        let oldBytes = try Self.pictureData(red: 0.9)
        let first = try GeneratedImageStore.store(
            GeneratedImage(data: oldBytes, mediaType: "image/png"),
            origin: .drawn, text: "The Krebs cycle as a clock face", title: "Krebs clock",
            model: "GPT Image 2", modelID: "openai/gpt-image-2", revising: nil
        )
        let newBytes = try Self.pictureData(.jpeg, red: 0.1)
        let redraw = try GeneratedImageStore.storeRedraw(
            GeneratedImage(data: newBytes, mediaType: "image/jpeg"),
            replacing: first.id.uppercased(), model: "Nano Banana 2", modelID: "google/gemini-3.1-flash-image"
        )
        defer { Self.remove([first.id, redraw.id]) }

        #expect(first.details?.modelID == "openai/gpt-image-2")
        #expect(redraw.imageID == first.imageID)
        #expect(redraw.version == 2)
        #expect(redraw.details?.origin == .drawn)
        #expect(redraw.details?.text == "The Krebs cycle as a clock face", "drawn again from the same prompt")
        #expect(redraw.details?.title == "Krebs clock")
        #expect(redraw.details?.model == "Nano Banana 2")
        #expect(redraw.details?.modelID == "google/gemini-3.1-flash-image")
        #expect(redraw.details?.replaces == first.id)

        let marked = try #require(GeneratedImageStore.listing(id: first.id))
        #expect(marked.details?.replacedBy == redraw.id)
        #expect(marked.details?.text == first.details?.text, "the replaced version keeps its prompt")
        #expect(marked.details?.model == "GPT Image 2")
        #expect(marked.createdAt == first.createdAt)
        #expect(try Self.pixels(Data(contentsOf: URL(fileURLWithPath: marked.path))) == Self.pixels(oldBytes), "its pixels are untouched")

        // A chat line names the version it showed; it shows the redraw.
        #expect(GeneratedImageStore.shownVersion(for: first.id) == redraw.id)
        #expect(GeneratedImageStore.shownVersion(for: redraw.id) == redraw.id)
        let shown = try #require(GeneratedImageStore.readShown(id: first.id))
        #expect(shown.listing.id == redraw.id)
        #expect(try Self.pixels(shown.image.data) == Self.pixels(newBytes))
        #expect(GeneratedImageStore.read(id: first.id)?.data == (try Data(contentsOf: URL(fileURLWithPath: marked.path))), "the exact version stays readable")

        // A card naming the image shows its latest; one naming the replaced
        // version shows the redraw too.
        #expect(GeneratedImageStore.readImageOrVersion(first.imageID)?.listing.id == redraw.id)
        let group = try #require(GeneratedImageStore.group(containing: first.id))
        #expect(group.versions.count == 2, "the replaced version stays one of the image's versions")
        #expect(group.shown(for: first.id).id == redraw.id)
        #expect(Set(group.versions(showingAs: redraw.id)) == [first.id, redraw.id])
        #expect(group.versions(showingAs: first.id).isEmpty)
    }

    @Test("Redraws chain, and a trashed redraw gives its place back to the one before")
    func redrawsChain() throws {
        let first = try GeneratedImageStore.store(
            GeneratedImage(data: try Self.pictureData(red: 0.9), mediaType: "image/png"),
            origin: .drawn, text: "ATP synthase as a turbine", model: "GPT Image 2", revising: nil
        )
        let second = try GeneratedImageStore.storeRedraw(
            GeneratedImage(data: try Self.pictureData(red: 0.5), mediaType: "image/png"),
            replacing: first.id, model: "Nano Banana 2", modelID: nil
        )
        let third = try GeneratedImageStore.storeRedraw(
            GeneratedImage(data: try Self.pictureData(red: 0.2), mediaType: "image/png"),
            replacing: first.id, model: "FLUX.2 Pro", modelID: "black-forest-labs/flux.2-pro"
        )
        defer { Self.remove([first.id, second.id, third.id]) }

        #expect(third.details?.replaces == first.id)
        #expect(third.version == 3)
        #expect(GeneratedImageStore.listing(id: first.id)?.details?.replacedBy == third.id, "the latest redraw of a version is the one it shows")
        #expect(GeneratedImageStore.shownVersion(for: first.id) == third.id)

        let fourth = try GeneratedImageStore.storeRedraw(
            GeneratedImage(data: try Self.pictureData(red: 0.3), mediaType: "image/png"),
            replacing: third.id, model: "Seedream 5.0 Lite", modelID: nil
        )
        defer { Self.remove([fourth.id]) }
        #expect(GeneratedImageStore.shownVersion(for: first.id) == fourth.id, "a redraw of a redraw is followed")
        let group = try #require(GeneratedImageStore.group(containing: first.id))
        #expect(group.shown(for: first.id).id == fourth.id)
        #expect(Set(group.versions(showingAs: fourth.id)) == [first.id, third.id, fourth.id])

        try GeneratedImageStore.trash(id: fourth.id)
        #expect(GeneratedImageStore.shownVersion(for: first.id) == third.id, "a redraw this Mac no longer holds is not followed")
    }

    @Test("A picture with no prompt kept, or a screenshot, is not redrawn and nothing is stored")
    func noPromptNoRedraw() throws {
        let bare = GeneratedImageReference.newID()
        _ = try GeneratedImageStore.write(
            GeneratedImage(data: try Self.pictureData(), mediaType: "image/png"),
            id: bare,
            details: .init(origin: .drawn, text: "")
        )
        let screenshot = GeneratedImageReference.newID()
        _ = try GeneratedImageStore.write(
            GeneratedImage(data: try Self.pictureData(), mediaType: "image/png"),
            id: screenshot,
            details: .init(origin: .screenshot, text: "The Browser tab")
        )
        defer { Self.remove([bare, screenshot]) }
        for id in [bare, screenshot] {
            #expect(throws: GeneratedImageStore.RedrawFailure.noPrompt) {
                try GeneratedImageStore.storeRedraw(
                    GeneratedImage(data: try Self.pictureData(), mediaType: "image/png"),
                    replacing: id, model: "Nano Banana 2", modelID: nil
                )
            }
            #expect(GeneratedImageStore.group(containing: id)?.versions.count == 1)
            #expect(!GeneratedImageRedraw.canRedraw(GeneratedImageStore.listing(id: id)?.details))
        }
        #expect(throws: GeneratedImageStore.RevisionFailure.unknownImage("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")) {
            try GeneratedImageStore.storeRedraw(
                GeneratedImage(data: try Self.pictureData(), mediaType: "image/png"),
                replacing: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", model: "Nano Banana 2", modelID: nil
            )
        }
    }

    @Test("A redraw arriving in a quiz's package marks the version it replaces on the receiving Mac, once")
    func arrivingRedrawIsAdopted() throws {
        let receiver = FileManager.default.temporaryDirectory.appendingPathComponent("redraw_arrival_\(UUID().uuidString)")
        let folder = receiver.appendingPathComponent(GeneratedImageStore.directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: receiver) }

        let old = "1a2b3c4d-0000-4000-8000-0000000000a1"
        let oldBytes = try GeneratedImageStore.withDetails(
            GeneratedImage(data: try Self.pictureData(red: 0.9), mediaType: "image/png"),
            .init(origin: .drawn, text: "Cristae as folds", model: "GPT Image 2", imageID: old)
        ).data
        try oldBytes.write(to: folder.appendingPathComponent("\(old).png"))

        let redraw = "1a2b3c4d-0000-4000-8000-0000000000a2"
        let redrawBytes = try GeneratedImageStore.withDetails(
            GeneratedImage(data: try Self.pictureData(.jpeg, red: 0.1), mediaType: "image/jpeg"),
            .init(origin: .drawn, text: "Cristae as folds", model: "Nano Banana 2", imageID: old, version: 2, replaces: old)
        ).data
        let package = receiver.appendingPathComponent("package.plist")
        try PropertyListSerialization.data(fromPropertyList: ["\(redraw).jpg": redrawBytes], format: .binary, options: 0)
            .write(to: package)

        #expect(CourseQuizPicturePackage.materialize(packageAt: package, root: receiver) == [redraw])
        let marked = try Data(contentsOf: folder.appendingPathComponent("\(old).png"))
        #expect(GeneratedImageStore.details(of: marked)?.replacedBy == redraw)
        #expect(GeneratedImageStore.details(of: marked)?.text == "Cristae as folds")
        #expect(try Self.pixels(marked) == Self.pixels(oldBytes), "only the mark is written")

        // A version this Mac already redrew keeps its own redraw.
        let later = "1a2b3c4d-0000-4000-8000-0000000000a3"
        let laterBytes = try GeneratedImageStore.withDetails(
            GeneratedImage(data: try Self.pictureData(red: 0.4), mediaType: "image/png"),
            .init(origin: .drawn, text: "Cristae as folds", model: "FLUX.2 Pro", imageID: old, version: 2, replaces: old)
        ).data
        try PropertyListSerialization.data(fromPropertyList: ["\(later).png": laterBytes], format: .binary, options: 0)
            .write(to: package)
        #expect(CourseQuizPicturePackage.materialize(packageAt: package, root: receiver) == [later])
        #expect(GeneratedImageStore.details(of: try Data(contentsOf: folder.appendingPathComponent("\(old).png")))?.replacedBy == redraw)
    }

    @Test("Redraw With offers the Settings choice first, then one model per maker, each once and only while served")
    func offeredModels() {
        let directory = [
            Self.model("openai/gpt-image-1-mini", "GPT Image 1 Mini"),
            Self.model("google/gemini-3.1-flash-image", "Nano Banana 2"),
            Self.model("black-forest-labs/flux.2-pro", "FLUX.2 Pro"),
        ]
        let offered = GeneratedImageRedraw.offeredModels(
            settingsChoice: "gpt-image-1-mini",
            suggested: ["google/gemini-3.1-flash-image", "openai/gpt-image-1-mini", "x-ai/grok-imagine-image-2.0", "black-forest-labs/flux.2-pro"],
            directory: directory
        )
        #expect(offered.map(\.id) == ["openai/gpt-image-1-mini", "google/gemini-3.1-flash-image", "black-forest-labs/flux.2-pro"],
                "a maker-native id is read as its OpenRouter slug, and a model OpenRouter stopped serving is left out")
        #expect(GeneratedImageRedraw.offeredModels(settingsChoice: "openai/gpt-image-1-mini", directory: []).isEmpty)

        // A newer release of a suggested family is offered in its place, as
        // Settings › Images suggests it.
        let released = [
            Self.model("google/gemini-3.1-flash-image", "Nano Banana 2", listedOn: 1),
            Self.model("google/gemini-3.5-flash-image", "Nano Banana 3", listedOn: 2),
        ]
        #expect(GeneratedImageRedraw.offeredModels(
            settingsChoice: "google/gemini-3.5-flash-image", suggested: ["google/gemini-3.1-flash-image"], directory: released
        ).map(\.id) == ["google/gemini-3.5-flash-image"])
    }

    @Test("The model that drew a picture is known by its slug, or by its name for an older picture")
    func drewBy() {
        let banana = Self.model("google/gemini-3.1-flash-image", "Nano Banana 2")
        let flux = Self.model("black-forest-labs/flux.2-pro", "FLUX.2 Pro")
        var details = GeneratedImageStore.Details(origin: .drawn, text: "x", model: "Nano Banana 2", modelID: "google/gemini-3.1-flash-image")
        #expect(GeneratedImageRedraw.drew(details, banana))
        #expect(!GeneratedImageRedraw.drew(details, flux))
        details.modelID = nil
        #expect(GeneratedImageRedraw.drew(details, banana), "a picture stored before slugs were kept matches by name")
        details.model = "FLUX.2 Pro"
        #expect(GeneratedImageRedraw.drew(details, flux))
        let saved = GeneratedImageStore.Details(origin: .saved, text: "x", model: "FLUX.2 Pro")
        #expect(!GeneratedImageRedraw.drew(saved, flux), "a picture made elsewhere was not drawn by a model here")
    }

    @Test("The menu's first line says what made the picture")
    func madeByLine() {
        #expect(GeneratedImageRedraw.madeByLine(.init(origin: .drawn, text: "x", model: "Nano Banana 2")) == "Drawn by Nano Banana 2")
        #expect(GeneratedImageRedraw.madeByLine(.init(origin: .drawn, text: "x")) == "Model not recorded")
        #expect(GeneratedImageRedraw.madeByLine(nil) == "Model not recorded")
        #expect(GeneratedImageRedraw.madeByLine(.init(origin: .saved, text: "x", model: "ChatGPT")) == "Made with ChatGPT, saved from elsewhere")
        #expect(GeneratedImageRedraw.madeByLine(.init(origin: .saved, text: "x")) == "Saved from elsewhere")
        #expect(GeneratedImageRedraw.canRedraw(.init(origin: .saved, text: "A prompt from ChatGPT")), "a picture made elsewhere with its prompt can be drawn here")
    }

    @Test("A redraw is drawn at the shape nearest the picture it replaces")
    func shapeFollowsThePicture() {
        #expect(GeneratedImageRedraw.shape(width: 1536, height: 1024) == .landscape)
        #expect(GeneratedImageRedraw.shape(width: 1280, height: 720) == .landscape)
        #expect(GeneratedImageRedraw.shape(width: 1024, height: 1024) == .square)
        #expect(GeneratedImageRedraw.shape(width: 1100, height: 1000) == .square)
        #expect(GeneratedImageRedraw.shape(width: 1024, height: 1536) == .portrait)
        #expect(GeneratedImageRedraw.shape(width: 0, height: 0) == .square)
    }

    private static func quiz(_ id: String = "quiz", pictures: [CourseQuizPicture?]) -> CourseQuiz {
        CourseQuiz(
            id: id, courseID: "course", kind: .practice, title: "Rotors", lectureIDs: ["l1"], afterLectureID: "l1",
            questions: pictures.enumerated().map { offset, picture in
                CourseQuizQuestion(
                    id: "q\(offset)", sourceID: "video", firstLine: nil, lastLine: nil, startSeconds: nil,
                    question: "Q\(offset)?", answer: "A.", keyPoints: [], quote: nil, picture: picture
                )
            },
            author: .foreverlm,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_100)
        )
    }

    @Test("A quiz that pinned a redrawn picture pins the redraw, caption, placement and brief kept")
    func quizzesFollowTheRedraw() throws {
        let old = "1a2b3c4d-0000-4000-8000-0000000000b1"
        let older = "1a2b3c4d-0000-4000-8000-0000000000b0"
        let other = "1a2b3c4d-0000-4000-8000-0000000000c1"
        let redraw = CourseQuizPicture.storedImageURL(id: "1a2b3c4d-0000-4000-8000-0000000000b2")
        let quiz = Self.quiz(pictures: [
            CourseQuizPicture(storedImage: CourseQuizPicture.storedImageURL(id: old), caption: "The rotor", placement: .question, brief: "A rotor turning"),
            CourseQuizPicture(storedImage: CourseQuizPicture.storedImageURL(id: other), caption: nil, placement: .answer),
            CourseQuizPicture(storedImage: CourseQuizPicture.storedImageURL(id: older), caption: nil, placement: .answer),
            CourseQuizPicture(reference: SourceImageReference(sourceID: "video", location: .moment(30)), caption: nil, placement: .answer),
            nil,
        ])
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let moved = try #require(GeneratedImageRedraw.repointing(quiz, from: [old, older], to: redraw, at: now))
        #expect(moved.questions[0].picture?.image == redraw)
        #expect(moved.questions[0].picture?.caption == "The rotor")
        #expect(moved.questions[0].picture?.placement == .question)
        #expect(moved.questions[0].picture?.brief == "A rotor turning")
        #expect(moved.questions[1].picture == quiz.questions[1].picture, "another picture stays")
        #expect(moved.questions[2].picture?.image == redraw)
        #expect(moved.questions[3].picture == quiz.questions[3].picture, "a source's picture stays")
        #expect(moved.questions[4].picture == nil)
        #expect(moved.updatedAt == now)
        #expect(GeneratedImageRedraw.repointing(quiz, from: ["1a2b3c4d-0000-4000-8000-0000000000d1"], to: redraw) == nil)

        // The store finds the quizzes that pin a version without decoding the rest.
        let store = try KnowledgeStore(inMemory: true)
        try store.saveCourseQuiz(quiz)
        try store.saveCourseQuiz(Self.quiz("plain", pictures: [nil]))
        #expect(try store.loadCourseQuizzes(mentioning: [old]).map(\.id) == ["quiz"])
        #expect(try store.loadCourseQuizzes(mentioning: [older, other, old]).map(\.id) == ["quiz"])
        #expect(try store.loadCourseQuizzes(mentioning: ["1a2b3c4d-0000-4000-8000-0000000000d1"]).isEmpty)
        #expect(try store.loadCourseQuizzes(mentioning: []).isEmpty)
    }
}
