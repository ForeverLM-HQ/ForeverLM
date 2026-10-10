import CoreGraphics
import Foundation
import Testing
@testable import ForeverLM

/// The Highlight projection (docs/cloudkit-schema-design.md §3.5.17, §4.3, §5.7, WP12b): a PDF mark, a text
/// mark and a mark on pictures round-trip; a highlight made on the personal copy shows on a team copy and
/// one made on the team copy is kept on the wire id; a Highlight applied before its Source; a source
/// delete keeps the row and the record; the activation moves team copies' highlights onto the wire id.
@Suite("Highlight projection")
struct HighlightProjectionTests {
    typealias F = NotebookSyncFixture

    static func highlight(_ id: String, source: String, quote: String = "Mitochondria divide by fission", pdf: Bool = true,
                          note: String = "", images: [ReaderImageAnchor] = []) -> SourceHighlight {
        SourceHighlight(
            id: id, sourceID: source, quote: images.isEmpty ? quote : "", note: note, color: .green,
            anchor: ReaderTextAnchor(exact: images.isEmpty ? quote : "", prefix: "before ", suffix: " after", offset: 120),
            pdfAnchor: pdf ? ReaderPDFAnchor(pageIndex: 3, rects: [CGRect(x: 10, y: 20, width: 300, height: 14)]) : nil,
            imageAnchors: images,
            chatSessionID: "chat-1",
            references: [SourceHighlightReference(citation: "Vozza et al., PNAS 2014", url: "https://doi.org/10.1073/x")],
            publicationUpdate: "Confirmed since.", publicationUpdateAt: Date(timeIntervalSince1970: 1_759_000_000),
            createdAt: Date(timeIntervalSince1970: 1_758_000_000), updatedAt: Date(timeIntervalSince1970: 1_758_500_000)
        )
    }

    /// A team copy of `personal` (its wire id the personal copy's), as WP7's activation leaves one.
    static func addTeamCopy(_ store: KnowledgeStore, _ id: String, of personal: String) throws {
        try store.execute("""
            INSERT INTO teams (id, name, role, permission, zone_scope, zone_name, created_at, joined_at, updated_at)
            VALUES ('team-1', 'Lab', 'owner', 'readWrite', 'private', 'Team-team-1', 1, 1, 1) ON CONFLICT(id) DO NOTHING
        """)
        try F.addSource(store, id)
        try store.execute("UPDATE sources SET team_id = 'team-1', wire_id = ? WHERE id = ?", [.text(personal), .text(id)])
    }

    @Test("A PDF mark, a text mark and a mark on pictures encode the web's locator and come back whole on another Mac")
    func roundTrip() throws {
        let (root, store) = try F.makeStore("hl-round")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-a")
        try store.saveSourceHighlight(Self.highlight("hl-pdf", source: "src-a", note: "my note"))
        try store.saveSourceHighlight(Self.highlight("hl-text", source: "src-a", pdf: false))
        try store.saveSourceHighlight(Self.highlight("hl-pic", source: "src-a", pdf: false,
                                                     images: [ReaderImageAnchor(src: "https://example.com/fig1.png", alt: "Figure 1", width: 640, height: 480)]))
        let pending = try F.pending(store)

        let pdf = try #require(F.savedFields(pending["Highlight:hl-pdf"]))
        #expect(pdf["sourceID"] == .string("src-a") && pdf["text"] == .string("Mitochondria divide by fission"))
        let locator = try #require(pdf["locator"]?.objectValue)
        #expect(locator["t"] == .string("pdf") && locator["page"] == SyncJSON(3))
        #expect(locator["quads"]?.arrayValue?.first?.objectValue?["width"] == SyncJSON(300))
        #expect(locator["offset"] == SyncJSON(120) && locator["prefix"] == .string("before ") && locator["len"] == SyncJSON(30))
        #expect(pdf["note"] == .string("my note") && pdf["color"] == .string("green") && pdf["chatID"] == .string("chat-1"))
        #expect(pdf["refs"]?.objectValue?["publicationUpdateAt"] == SyncJSON(Int64(1_759_000_000_000)))
        #expect(pdf["createdAt"] == SyncJSON(Int64(1_758_000_000_000)) && pdf["editedAt"] == SyncJSON(Int64(1_758_500_000_000)))
        #expect(F.savedFields(pending["Highlight:hl-text"])?["locator"]?.objectValue?["t"] == .string("text"))
        #expect(F.savedFields(pending["Highlight:hl-pic"])?["locator"]?.objectValue?["images"]?.arrayValue?.count == 1)

        let (otherRoot, other) = try F.makeStore("hl-round-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try F.prepareReplica(other)
        try F.apply(other, try ["hl-pdf", "hl-text", "hl-pic"].map { try OutboxTestProjections.serverRecord(for: try #require(pending["Highlight:\($0)"])) })
        let mine = try store.sourceHighlights(sourceID: "src-a")
        try F.addSource(other, "src-a")
        let theirs = try other.sourceHighlights(sourceID: "src-a")
        #expect(theirs == mine, "every field the Mac keeps comes back")
        #expect(try F.pending(other).keys.filter { $0.hasPrefix("Highlight:") }.isEmpty, "an apply sends nothing back")
    }

    @Test("A highlight made on the personal copy shows on the team copy, and one made on the team copy is kept on the wire id")
    func personalAndTeamCopyShareHighlights() throws {
        let (root, store) = try F.makeStore("hl-team")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-a")
        try Self.addTeamCopy(store, "team-copy-a", of: "src-a")
        try store.saveSourceHighlight(Self.highlight("hl-1", source: "src-a"))
        #expect(try store.sourceHighlights(sourceID: "team-copy-a").map(\.id) == ["hl-1"])
        #expect(try store.sourceHighlightCount(sourceID: "team-copy-a") == 1)
        #expect(try store.sourceHighlights(sourceIDs: ["team-copy-a"])["team-copy-a"]?.map(\.id) == ["hl-1"])

        try store.saveSourceHighlight(Self.highlight("hl-2", source: "team-copy-a", quote: "Cristae fold"))
        #expect(try F.text(store, "SELECT source_id FROM source_highlights WHERE highlight_id = 'hl-2'") == "src-a")
        #expect(F.savedFields(try F.pending(store)["Highlight:hl-2"])?["sourceID"] == .string("src-a"))
        #expect(try store.sourceHighlightIDs(sourceID: "src-a") == ["hl-1", "hl-2"])
    }

    @Test("A Highlight applied before its Source is kept, and shows once the source arrives")
    func highlightBeforeItsSource() throws {
        let (root, store) = try F.makeStore("hl-order")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.apply(store, [try F.record(.highlight, "hl-early", [
            "sourceID": .string("src-late"), "text": .string("Early"), "color": .string("yellow"), "note": .string(""),
            "locator": .object(["t": .string("text"), "offset": SyncJSON(4), "quote": .string("Early"), "prefix": .string(""), "suffix": .string("")]),
            "createdAt": SyncJSON(Int64(1_758_000_000_000)), "editedAt": SyncJSON(Int64(1_758_000_000_000)),
        ])])
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_highlights WHERE highlight_id = 'hl-early' AND source_id = 'src-late'") == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0)
        try F.addSource(store, "src-late")
        #expect(try store.sourceHighlights(sourceID: "src-late").map(\.quote) == ["Early"])
    }

    @Test("A source deleted here keeps its highlight row and record")
    func sourceDeleteKeepsHighlight() throws {
        let (root, store) = try F.makeStore("hl-source-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-a")
        try store.saveSourceHighlight(Self.highlight("hl-1", source: "src-a"))
        try F.sendAll(store)
        try store.deleteSourceRows("src-a")
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_highlights WHERE highlight_id = 'hl-1'") == 1)
        #expect(try F.pending(store)["Highlight:hl-1"] == nil, "nothing is sent for the highlight")
        try store.deleteSourceHighlight(id: "hl-1")
        guard case .delete? = try F.pending(store)["Highlight:hl-1"]?.action else { Issue.record("a highlight deleted here is deleted"); return }
    }

    @Test("The activation moves a team copy's highlights onto the wire id, and a second run changes nothing")
    func activationRekeysTeamCopies() throws {
        let (root, store) = try F.makeStore("hl-rekey", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addSource(store, "src-a")
        try Self.addTeamCopy(store, "team-copy-a", of: "src-a")
        try store.execute("""
            INSERT INTO source_highlights (highlight_id, source_id, page_index, quads_json, text, color, created_at, updated_at)
            VALUES ('hl-team', 'team-copy-a', 0, '[]', 'On the copy', 'yellow', 1, 2), ('hl-own', 'src-a', 0, '[]', 'Mine', 'yellow', 1, 2)
        """)
        try store.inDerivationTransaction { try $0.rekeyPersonalStateRows() }
        #expect(try F.text(store, "SELECT group_concat(highlight_id || ':' || source_id, ',') FROM (SELECT * FROM source_highlights ORDER BY highlight_id)")
                == "hl-own:src-a,hl-team:src-a")
        try store.inDerivationTransaction { try $0.rekeyPersonalStateRows() }
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_highlights WHERE source_id = 'src-a'") == 2)
    }
}
