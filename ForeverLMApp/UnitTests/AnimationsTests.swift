import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// An animation is a record hosted as a ForeverLM site and told apart from one
/// by its own kind (docs/animations-design.md). What has to hold: the kind
/// outranks the link when a section is derived, the kind and the grounding
/// ride the payload and survive a round trip, a payload from a later build
/// with a kind this build does not know still decodes, and the tool that writes
/// a player page around a lone video writes what a browser plays.
@Suite("Animation records")
struct AnimationRecordTests {
    private func record(linkedURL: String?, kind: ArtifactKind? = nil, sourceIDs: [String] = []) -> ArtifactRecord {
        ArtifactRecord(
            id: "a1", title: "Empagliflozin and the TCA cycle", homeNotebookID: nil, linkedNotebookIDs: [],
            linkedURL: linkedURL, kind: kind, sourceIDs: sourceIDs, createdAt: Date(), updatedAt: Date()
        )
    }

    @Test("The kind outranks the link: an animation kept as a ForeverLM site is an Animation, not a Site")
    func sectionByKind() {
        let kept = "foreverlm-site://empa-krebs/"
        #expect(record(linkedURL: kept).section == .sites)
        #expect(record(linkedURL: kept, kind: .animation).section == .animations)
        #expect(record(linkedURL: kept, kind: .animation).linkedKind == .foreverlmSite, "on the wire it is still a ForeverLM site")
        #expect(record(linkedURL: kept, kind: .animation).isAnimation)
        #expect(record(linkedURL: kept, kind: .animation).kindLabel == "Animation")
        #expect(record(linkedURL: kept).kindLabel == "ForeverLM Site")
        #expect(record(linkedURL: nil).kindLabel == nil)
        #expect(ArtifactSection.animations.centerTab == .animations)
        #expect(ArtifactSection.animations.linkedKinds.isEmpty, "no linked kind lands in Animations; the record kind does")
        #expect(StudioCenterTab.permanentTabs.contains(.animations))
        #expect(StudioCenterTab.permanentTabs.contains(.artifacts))
    }

    @Test("The kind and the grounding ride the payload and come back; a record without them encodes as before")
    func payloadRoundTrip() throws {
        let animation = record(linkedURL: "foreverlm-site://empa-krebs/", kind: .animation, sourceIDs: ["src-empa", "src-review"])
        let data = try JSONEncoder().encode(animation)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "animation")
        #expect(object["sourceIDs"] as? [String] == ["src-empa", "src-review"])
        let decoded = try JSONDecoder().decode(ArtifactRecord.self, from: data)
        #expect(decoded.kind == .animation)
        #expect(decoded.sourceIDs == ["src-empa", "src-review"])
        #expect(decoded.section == .animations)

        // A plain record carries neither key, so its payload is byte-for-byte
        // what a pre-117 build wrote and reads.
        let plain = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(record(linkedURL: nil))) as? [String: Any]
        #expect(plain?["kind"] == nil)
        #expect(plain?["sourceIDs"] == nil)
    }

    @Test("A kind this build does not know decodes as none rather than refusing the record")
    func unknownKindDecodes() throws {
        var object = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(record(linkedURL: "foreverlm-site://x-y-z/"))) as? [String: Any])
        object["kind"] = "hologram"
        object["sourceIDs"] = ["src-1"]
        let decoded = try JSONDecoder().decode(ArtifactRecord.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.kind == nil)
        #expect(decoded.section == .sites, "an unknown kind lists the record by its link")
        #expect(decoded.sourceIDs == ["src-1"])
    }

    @Test("A wrong-section refusal names the section the link belongs to")
    func wrongSectionNamesTheKindsSection() {
        let message = LinkedPageError.wrongSection(kind: .codexSite, section: .docs).errorDescription ?? ""
        #expect(message.contains("Link it from Sites, not Pages."))
        let other = LinkedPageError.wrongSection(kind: .googleDoc, section: .animations).errorDescription ?? ""
        #expect(other.contains("Link it from Pages, not Animations."))
    }

    @Test("A lone video gets a player page that names the video and escapes the words around it")
    func playerPage() {
        let page = MCPDataStore.animationPlayerHTML(
            title: "Electrons & <intermediates>",
            description: "With and without EMPA.",
            videoPath: "renders/tca.mp4"
        )
        #expect(page.contains("<title>Electrons &amp; &lt;intermediates&gt;</title>"))
        #expect(page.contains("<h1>Electrons &amp; &lt;intermediates&gt;</h1>"))
        #expect(page.contains("<p class=\"lede\">With and without EMPA.</p>"))
        #expect(page.contains("<source src=\"renders/tca.mp4\" type=\"video/mp4\">"))
        #expect(page.contains("<video controls autoplay loop muted playsinline"))
        #expect(MCPDataStore.isAnimationVideoPath("a/b.WEBM"))
        #expect(!MCPDataStore.isAnimationVideoPath("index.html"))
        #expect(MCPDataStore.videoMIMEType(forPath: "x.mov") == "video/quicktime")
        #expect(MCPDataStore.videoMIMEType(forPath: "x.svg") == nil)
    }

    @Test("The text copy is the description, the page's words and the sources by name, without repeating itself")
    func textCopy() {
        let copy = MCPDataStore.animationTextCopy(
            description: "How EMPA shifts the TCA cycle.",
            pageText: "Play  Pause  Step 1: citrate",
            sourceTitles: ["Empagliflozin improves cardiac energetics", ""]
        )
        #expect(copy == "How EMPA shifts the TCA cycle.\n\nPlay  Pause  Step 1: citrate\n\nAbout: Empagliflozin improves cardiac energetics")
        #expect(MCPDataStore.animationTextCopy(description: "Same", pageText: "Same", sourceTitles: []) == "Same")
        #expect(MCPDataStore.animationTextCopy(description: "", pageText: "", sourceTitles: []).isEmpty)
    }

    @Test("Files are split by how their bytes arrive, and an entry naming both routes is refused")
    func fileSplitting() throws {
        let split = try MCPDataStore.splitAnimationFiles([
            ["path": "index.html", "content": "<h1>x</h1>"],
            ["path": "tca.mp4", "local_path": "/tmp/tca.mp4"],
        ])
        #expect(split.inline.count == 1)
        #expect(split.local.count == 1)
        #expect(split.local.first?["local_path"] as? String == "/tmp/tca.mp4")
        #expect(throws: (any Error).self) {
            _ = try MCPDataStore.splitAnimationFiles([["path": "a.js", "content": "1", "local_path": "/tmp/a.js"]])
        }
        #expect(throws: (any Error).self) {
            _ = try MCPDataStore.splitAnimationFiles(["not an object"])
        }
    }

    @Test("A local file is read from this Mac and named by its own name, past the inline limit too; a missing path or a folder is refused")
    func localFileOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foreverlm-animation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("krebs-cycle.mp4")
        try Data(repeating: 7, count: 2_500_000).write(to: file)

        let read = try MCPDataStore.localSiteFile(["local_path": file.path]) { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        #expect(read.path == "krebs-cycle.mp4", "with no path the file's own name is the path")
        #expect(read.data.count == 2_500_000, "a file read from this Mac is not held to the 2 MB inline limit")

        // A name the site cannot serve is refused with the way to name it.
        let spaced = directory.appendingPathComponent("Krebs Cycle.mp4")
        try Data(count: 4).write(to: spaced)
        #expect(throws: (any Error).self) {
            _ = try MCPDataStore.localSiteFile(["local_path": spaced.path]) { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        }
        let renamed = try MCPDataStore.localSiteFile(["local_path": spaced.path, "path": "krebs.mp4"]) { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        #expect(renamed.path == "krebs.mp4")

        let named = try MCPDataStore.localSiteFile(["local_path": file.path, "path": "renders/tca.mp4"]) { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        #expect(named.path == "renders/tca.mp4")

        #expect(throws: (any Error).self) {
            _ = try MCPDataStore.localSiteFile(["local_path": directory.appendingPathComponent("missing.mp4").path]) { _ in Data() }
        }
        #expect(throws: (any Error).self) {
            _ = try MCPDataStore.localSiteFile(["local_path": directory.path]) { _ in Data() }
        }
    }
}
