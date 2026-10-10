import CloudKit
import CoreGraphics
import Foundation
import Testing
@testable import ForeverLM

/// The member's highlights on the phone (docs/cloudkit-schema-design.md §3.5.17, D18;
/// §14.2 WP20c): a Highlight record per mark in `Library`, written as the web writes it and read in the
/// shape the Mac's `HighlightProjection` writes.
@Suite("iPhone highlight records", .serialized)
struct MobileHighlightRecordTests {
    typealias Fixture = MobileWriterFixture

    static let made = Date(timeIntervalSince1970: 1_799_000_000)

    static func mark(_ id: String = "hl_1", quote: String = "Mitochondria divide.", pdf: ReaderPDFAnchor? = nil,
                     images: [ReaderImageAnchor] = []) -> SourceHighlight {
        SourceHighlight(id: id, sourceID: "srcA", quote: quote, note: "", color: .green,
                        anchor: ReaderTextAnchor(exact: quote, prefix: "In cells, ", suffix: " Then", offset: 40), pdfAnchor: pdf,
                        imageAnchors: images, createdAt: made, updatedAt: made)
    }

    static func snapshot(_ replica: MobileReplica) async throws -> MobileReadModels.Snapshot {
        try await replica.read { try MobileReadModels.snapshot(in: $0) }
    }

    @Test("A text highlight's source, quote and creation are written once; its locator, colour, note, chat and references with each edit")
    func textHighlight() async throws {
        let replica = try await Fixture.replica()
        let writer = Fixture.writer(replica)
        try await writer.transaction { try $0.saveHighlight(Self.mark()) }
        let record = try #require(try await Fixture.held(replica, .highlight, "hl_1", in: Fixture.library))
        #expect(record.fields["sourceID"] == .string("srcA"))
        #expect(record.fields["text"] == .string("Mitochondria divide."))
        #expect(record.fields["createdAt"] == SyncJSON(SyncTime.milliseconds(Self.made)))
        #expect(record.fields["locator"] == .object([
            "t": "text", "offset": 40, "len": 20, "quote": "Mitochondria divide.", "prefix": "In cells, ", "suffix": " Then",
        ]))
        #expect(record.fields["color"] == .string("green"))
        #expect(record.fields["note"] == .string(""))
        #expect(record.fields["chatID"] == .null)
        #expect(record.fields["refs"] == .null)
        #expect(record.fields["editedAt"] != nil)

        var edited = Self.mark(quote: "Mitochondria divide by fission.")
        edited.note = "The key step."
        edited.color = .blue
        edited.chatSessionID = "chat-9"
        edited.references = [SourceHighlightReference(citation: "Vozza et al., PNAS 2014", url: "https://doi.org/10.1073/pnas.1")]
        edited.setPublicationUpdate("Since then, Drp1 was shown to act first.", at: Self.made.addingTimeInterval(60))
        try await writer.transaction { try $0.saveHighlight(edited) }
        let after = try #require(try await Fixture.held(replica, .highlight, "hl_1", in: Fixture.library))
        #expect(after.fields["text"] == .string("Mitochondria divide."), "the quote is written once (S)")
        #expect(after.fields["locator"]?["quote"] == .string("Mitochondria divide by fission."))
        #expect(after.fields["note"] == .string("The key step."))
        #expect(after.fields["color"] == .string("blue"))
        #expect(after.fields["chatID"] == .string("chat-9"))
        #expect(after.fields["refs"] == .object([
            "references": .array([.object(["citation": "Vozza et al., PNAS 2014", "url": "https://doi.org/10.1073/pnas.1"])]),
            "publicationUpdate": "Since then, Drp1 was shown to act first.",
            "publicationUpdateAt": SyncJSON(SyncTime.milliseconds(Self.made.addingTimeInterval(60))),
        ]))

        let read = try #require(try await Self.snapshot(replica).highlights.first)
        #expect(read.id == "hl_1")
        #expect(read.sourceID == "srcA")
        #expect(read.quote == "Mitochondria divide.")
        #expect(read.anchor == ReaderTextAnchor(exact: "Mitochondria divide by fission.", prefix: "In cells, ", suffix: " Then", offset: 40))
        #expect(read.note == "The key step.")
        #expect(read.color == .blue)
        #expect(read.linkedChatID == "chat-9")
        #expect(read.references == edited.references)
        #expect(read.publicationUpdate == edited.publicationUpdate)
        #expect(read.publicationUpdateAt == edited.publicationUpdateAt)
        #expect(read.createdAt == Self.made)
        #expect(read.pdfAnchor == nil)
    }

    @Test("A PDF mark keeps its page and quads and a mark on pictures its images, and each reads back as the Reader made it; a mark of nothing is refused")
    func pdfAndPictures() async throws {
        let replica = try await Fixture.replica()
        let writer = Fixture.writer(replica)
        let pdf = ReaderPDFAnchor(pageIndex: 3, rects: [CGRect(x: 1, y: 2, width: 3, height: 4), CGRect(x: 5, y: 6, width: 7, height: 8)])
        let picture = ReaderImageAnchor(src: "https://example.org/fig1.png", alt: "Figure 1", width: 640, height: 480)
        try await writer.transaction { write in
            try write.saveHighlight(Self.mark("hl_pdf", pdf: pdf))
            try write.saveHighlight(Self.mark("hl_pic", quote: "", images: [picture]))
        }
        let locator = try #require(try await Fixture.held(replica, .highlight, "hl_pdf", in: Fixture.library)?.fields["locator"])
        #expect(locator["t"] == .string("pdf"))
        #expect(locator["page"] == SyncJSON(Int64(3)))
        #expect(locator["quads"] == .array([
            .object(["x": 1, "y": 2, "width": 3, "height": 4]), .object(["x": 5, "y": 6, "width": 7, "height": 8]),
        ]), "the Mac's quads as they are")
        let pictureLocator = try #require(try await Fixture.held(replica, .highlight, "hl_pic", in: Fixture.library)?.fields["locator"])
        #expect(pictureLocator["t"] == .string("text"))
        #expect(pictureLocator["images"] == .array([.object(["src": "https://example.org/fig1.png", "alt": "Figure 1", "width": 640, "height": 480])]))

        let read = try await Self.snapshot(replica).highlights
        #expect(read.first { $0.id == "hl_pdf" }?.pdfAnchor == pdf)
        #expect(read.first { $0.id == "hl_pic" }?.imageAnchors == [picture])
        #expect(read.first { $0.id == "hl_pic" }?.isPictureOnly == true)

        let patches = try await Fixture.patchCount(replica)
        await #expect(throws: MobileRecordWriterError.self) { try await writer.transaction { try $0.saveHighlight(Self.mark("hl_none", quote: " ")) } }
        #expect(try await Fixture.patchCount(replica) == patches)
    }

    @Test("A Highlight the Mac's projection wrote reads back whole, and a source's highlights are only its own")
    func macRecordReadsBack() async throws {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileSyncFixture.envelope(.highlight, "hl_mac", [
                "sourceID": "srcA",
                "locator": .object(["t": "pdf", "page": 0, "quads": .array([.object(["x": 10, "y": 20, "width": 30, "height": 40])]),
                                    "offset": 7, "len": 4, "quote": "ATP.", "prefix": "makes ", "suffix": ""]),
                "text": "ATP.", "color": "pink", "note": "", "chatID": .null,
                "refs": .object(["references": .array([.object(["citation": "Smith 2020", "title": "On ATP", "url": "https://example.org/atp"])])]),
                "createdAt": 1_700_000_000_000, "editedAt": 1_700_000_100_000,
            ])),
            (Fixture.library, try MobileSyncFixture.envelope(.highlight, "hl_other", [
                "sourceID": "srcB", "locator": .object(["t": "text", "quote": "Other."]), "text": "Other.", "createdAt": 1_600_000_000_000,
                "editedAt": 1_600_000_000_000,
            ])),
        ])
        let read = try await Self.snapshot(replica).highlights
        #expect(read.map(\.id) == ["hl_other", "hl_mac"], "oldest first")
        let mark = try #require(read.first { $0.id == "hl_mac" })
        #expect(mark.quote == "ATP.")
        #expect(mark.color == .pink)
        #expect(mark.note.isEmpty)
        #expect(mark.chatSessionID == nil)
        #expect(mark.pdfAnchor == ReaderPDFAnchor(pageIndex: 0, rects: [CGRect(x: 10, y: 20, width: 30, height: 40)]))
        #expect(mark.anchor.offset == 7)
        #expect(mark.references == [SourceHighlightReference(citation: "Smith 2020", title: "On ATP", url: "https://example.org/atp")])
        #expect(mark.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(mark.updatedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(read.filter { $0.sourceID == "srcA" }.map(\.id) == ["hl_mac"])
    }

    @Test("A colour edited on a highlight whose note spilled above 32 KiB leaves the note alone, since the Reader could only read it as empty")
    func spilledNoteSurvivesAnEdit() async throws {
        let replica = try await Fixture.replica()
        let writer = Fixture.writer(replica, at: Date().addingTimeInterval(-60))
        let spill = SyncEnvelope.spillMarker(MobileSyncFixture.fileRef(owner: "hl_big", role: "field.note", bytes: Data("long".utf8)))
        try await Fixture.apply(replica, [(Fixture.library, try MobileSyncFixture.envelope(.highlight, "hl_big", [
            "sourceID": "srcA", "locator": .object(["t": "text", "quote": "Q."]), "text": "Q.", "color": "yellow", "note": spill,
            "createdAt": 1, "editedAt": 1,
        ]))])
        var read = try #require(try await Self.snapshot(replica).highlights.first { $0.id == "hl_big" })
        #expect(read.note.isEmpty, "the Reader is handed an empty note")

        read.color = .blue
        try await writer.transaction { try $0.saveHighlight(read) }
        let after = try #require(try await Fixture.held(replica, .highlight, "hl_big", in: Fixture.library))
        #expect(after.fields["color"] == .string("blue"))
        #expect(after.fields["note"] == spill, "an empty note over a spilled one is the unread note, not a cleared one")

        read.note = "Now a short note."
        try await writer.transaction { try $0.saveHighlight(read) }
        #expect(try await Fixture.held(replica, .highlight, "hl_big", in: Fixture.library)?.fields["note"] == .string("Now a short note."),
                "a note the learner wrote replaces it")
    }

    @Test("Deleting a highlight deletes its record; one the phone does not hold writes nothing")
    func delete() async throws {
        let replica = try await Fixture.replica()
        let writer = Fixture.writer(replica, at: Date().addingTimeInterval(-60))
        try await writer.transaction { try $0.saveHighlight(Self.mark()) }
        try await writer.transaction { try $0.deleteHighlight("hl_1") }
        #expect(try await writer.read { try $0.held(.highlight, "hl_1", in: Fixture.library) } == nil)
        #expect(try await Self.snapshot(replica).highlights.isEmpty)
        try await writer.transaction { try $0.deleteHighlight("hl_unknown") }
        #expect(try await Fixture.patchCount(replica) == 0)

        try await Fixture.apply(replica, [(Fixture.library, try MobileSyncFixture.envelope(.highlight, "hl_2", [
            "sourceID": "srcA", "locator": .object(["t": "text", "quote": "Q."]), "text": "Q.", "createdAt": 1, "editedAt": 1,
        ]))])
        try await writer.transaction { try $0.deleteHighlight("hl_2") }
        #expect(try await Fixture.changes(replica).filter { $0.action == .delete }.map(\.wireID) == ["hl_2"])
    }

}
