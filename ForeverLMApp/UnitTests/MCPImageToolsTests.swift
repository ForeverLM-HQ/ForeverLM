import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ForeverLM

/// `list_images`, `get_image`, `save_image`, `rename_image` and
/// `delete_image` over MCP: a picture made in ChatGPT or Claude is kept with
/// its title and prompt, iterating on it makes versions of one image, and the
/// tools speak in images.
@Suite("MCP image tools")
struct MCPImageToolsTests {
    private static func picture(red: CGFloat) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: 0.3, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// The image_id a result names.
    private static func imageID(in text: String) throws -> String {
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("image_id: ") })
        return String(line.dropFirst("image_id: ".count))
    }

    private static func cleanUp(_ imageID: String) {
        if let group = GeneratedImageStore.group(containing: imageID) {
            for version in group.versions { try? FileManager.default.removeItem(atPath: version.path) }
        }
    }

    @Test("the six image tools are registered, and none needs knowledge.db")
    func registered() {
        let names = Set(MCPToolRegistry(store: MCPDataStore()).tools.map(\.name))
        #expect(names.isSuperset(of: MCPDataStore.imageToolNames))
        #expect(MCPToolRegistry.storeGateExemptToolNames.isSuperset(of: MCPDataStore.imageToolNames))
        let save = MCPDataStore.imageToolDefs.first { $0.name == "save_image" }
        #expect((save?.inputSchema["required"] as? [String]) == ["prompt"], "a picture is never kept without its prompt")
    }

    @Test("save_image keeps a picture with its prompt; a revision is its next version")
    func saveAndRevise() async throws {
        let store = MCPDataStore()
        let first = await store.saveImage(arguments: [
            "prompt": "A mitochondrion as a power plant, isometric",
            "title": "Mitochondrial power plant",
            "image_base64": "data:image/png;base64," + (try Self.picture(red: 0.9)).base64EncodedString(),
            "model": "ChatGPT (GPT Image 2)",
        ])
        #expect(!first.isError, "\(first.text)")
        let imageID = try Self.imageID(in: first.text)
        defer { Self.cleanUp(imageID) }
        #expect(first.text.contains("Saved a new image"))
        #expect(first.text.contains("Prompt: A mitochondrion as a power plant, isometric"))
        #expect(first.text.contains("Title: Mitochondrial power plant"))

        let revised = await store.saveImage(arguments: [
            "prompt": "A mitochondrion as a power plant, isometric, at night",
            "image_base64": (try Self.picture(red: 0.2)).base64EncodedString(),
            "revises": "foreverlm://image/generated/\(imageID)",
        ])
        #expect(!revised.isError, "\(revised.text)")
        #expect(try Self.imageID(in: revised.text) == imageID, "a revision is the same image")
        #expect(revised.text.contains("version 2 of image \(imageID)"))

        let listed = await store.listImages(arguments: ["query": "mitochondrion power plant"])
        #expect(listed.text.contains("image_id \(imageID)"))
        #expect(listed.text.contains("2 versions, showing v2"))
        #expect(listed.text.components(separatedBy: "image_id \(imageID)").count == 2, "listed once")

        let latest = await store.getImage(arguments: ["image": imageID])
        #expect(!latest.isError)
        #expect(latest.images.count == 1)
        #expect(latest.images.first?.mimeType == "image/png")
        #expect(latest.text.contains("Showing: version 2 of 2"))
        #expect(latest.text.contains("at night"))
        let firstVersion = await store.getImage(arguments: ["image": imageID, "version": 1])
        #expect(firstVersion.text.contains("Showing: version 1 of 2"))
        #expect(firstVersion.text.contains("Model: ChatGPT (GPT Image 2)"))
        #expect(latest.text.contains("Title: Mitochondrial power plant"), "a revision keeps the image's title")

        let renamed = await store.renameImage(arguments: ["image": "foreverlm://image/generated/\(imageID)", "title": "The cell's power plant"])
        #expect(!renamed.isError, "\(renamed.text)")
        #expect(GeneratedImageStore.group(containing: imageID)?.versions.allSatisfy { $0.details?.title == "The cell's power plant" } == true)
        let byTitle = await store.listImages(arguments: ["query": "cell's power"])
        #expect(byTitle.text.contains("\"The cell's power plant\" · image_id \(imageID)"))
        let emptyTitle = await store.renameImage(arguments: ["image": imageID, "title": "  "])
        #expect(emptyTitle.isError)

        let droppedOne = await store.deleteImage(arguments: ["image": imageID, "version": 2])
        #expect(!droppedOne.isError, "\(droppedOne.text)")
        #expect(GeneratedImageStore.group(containing: imageID)?.versions.count == 1)
        let droppedAll = await store.deleteImage(arguments: ["image": imageID])
        #expect(!droppedAll.isError, "\(droppedAll.text)")
        #expect(GeneratedImageStore.group(containing: imageID) == nil)
    }

    @Test("save_image refuses a picture without a prompt, bytes that are not an image, and an unknown revises")
    func saveRefusals() async throws {
        let store = MCPDataStore()
        let png = try Self.picture(red: 0.5).base64EncodedString()
        let noPrompt = await store.saveImage(arguments: ["image_base64": png])
        #expect(noPrompt.isError)
        #expect(noPrompt.text.contains("never kept without"))

        let neither = await store.saveImage(arguments: ["prompt": "x"])
        #expect(neither.isError)
        let notImage = await store.saveImage(arguments: ["prompt": "x", "image_base64": Data("hello".utf8).base64EncodedString()])
        #expect(notImage.isError)
        #expect(notImage.text.contains("not an image"))

        let noTitle = await store.saveImage(arguments: ["prompt": "x", "image_base64": png])
        #expect(noTitle.isError)
        #expect(noTitle.text.contains("needs a title"))

        let unknown = await store.saveImage(arguments: [
            "prompt": "x", "image_base64": png, "revises": "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0",
        ])
        #expect(unknown.isError)
        #expect(unknown.text.contains("No stored picture"))
    }

    @Test("save_image reads a local file on this Mac")
    func saveFromLocalPath() async throws {
        let bytes = try Self.picture(red: 0.7)
        let result = await MCPDataStore().saveImage(
            arguments: ["prompt": "Rendered by a script", "title": "Script render", "local_path": "/tmp/rendered.png"],
            readLocalFile: { path in
                #expect(path == "/tmp/rendered.png")
                return bytes
            }
        )
        #expect(!result.isError, "\(result.text)")
        Self.cleanUp(try Self.imageID(in: result.text))
    }
}
