import Foundation
import PDFKit
import Testing
@testable import ForeverLM

// A learner's turned PDF pages: the synced row (`PDFPageRotations`), where a
// page of a book is filed (`PDFPageRotationOwner`), the geometry of a turned
// page (`PDFPageTurn`, measured against PDFKit's own rendering), and the
// controller that applies a row to the document the reader shows without
// touching the file.

@Suite("PDF page rotations: the row")
struct PDFPageRotationsRowTests {
    @Test("A page turns a quarter at a time, back as well, and a full circle leaves no entry")
    func quarterTurns() {
        var turns = PDFPageRotations()
        #expect(turns.isEmpty && turns.storedValue == nil)
        turns = turns.turned(2, by: 90)
        #expect(turns.degrees(of: 2) == 90)
        turns = turns.turned(2, by: 90).turned(2, by: 90)
        #expect(turns.degrees(of: 2) == 270)
        turns = turns.turned(2, by: 90)
        #expect(turns.isEmpty)
        #expect(turns.turned(5, by: -90).degrees(of: 5) == 270)
        #expect(PDFPageRotations.normalized(-450) == 270)
        #expect(PDFPageRotations.normalized(30) == 0)
    }

    @Test("The row round-trips as sorted JSON, and anything unreadable is no turns")
    func storedValue() {
        let turns = PDFPageRotations().turned(-3, by: 180).turned(12, by: 90).turned(5, by: -90)
        let text = turns.storedValue
        #expect(PDFPageRotations(storedValue: text) == turns)
        #expect(PDFPageRotations(storedValue: text).storedValue == text, "a re-save is no change")
        #expect(PDFPageRotations(storedValue: "not json").isEmpty)
        #expect(PDFPageRotations(storedValue: nil).isEmpty)
        #expect(PDFPageRotations(storedValue: 7).isEmpty)
        #expect(PDFPageRotations(storedValue: "{\"1\":45,\"2\":90,\"x\":90}") == PDFPageRotations(turns: [2: 90]),
                "only quarter turns of a numbered page")
    }

    @Test("The row is one per source, under its own prefix, and a synced preference")
    func key() {
        #expect(PDFPageRotations.key(sourceID: "src_a") == "reader.pdfRotations.src_a")
        #expect(PDFPageRotations.sourceID(fromKey: "reader.pdfRotations.src_a") == "src_a")
        #expect(PDFPageRotations.sourceID(fromKey: "reader.pdfRotations.") == nil)
        #expect(PDFPageRotations.sourceID(fromKey: "listen.position.src_a") == nil)
        #expect(SyncedPreferenceKeys.syncedPrefixes.contains(PDFPageRotations.preferenceKeyPrefix))
        #expect(SyncedPreferenceKeys.isSynced(PDFPageRotations.key(sourceID: "src_a")))
    }
}

@Suite("PDF page rotations: where a page is filed")
struct PDFPageRotationOwnerTests {
    @Test("A page belongs to the last chapter begun by then, and front matter to the first, numbered from it")
    func homes() throws {
        let owner = PDFPageRotationOwner(runs: [.init(sourceID: "b", firstPage: 10), .init(sourceID: "a", firstPage: 4)])
        let front = try #require(owner.home(ofPage: 0))
        #expect(front.sourceID == "a" && front.pageInSource == -4)
        let inA = try #require(owner.home(ofPage: 9))
        #expect(inA.sourceID == "a" && inA.pageInSource == 5)
        let inB = try #require(owner.home(ofPage: 25))
        #expect(inB.sourceID == "b" && inB.pageInSource == 15)
        #expect(owner.page(ofSource: "a", pageInSource: -4) == 0)
        #expect(owner.page(ofSource: "b", pageInSource: 3) == 13)
        #expect(owner.page(ofSource: "zzz", pageInSource: 0) == nil)
        #expect(PDFPageRotationOwner(runs: []).home(ofPage: 0) == nil)
    }
}

@Suite("PDF page rotations: a turned page's geometry")
struct PDFPageTurnTests {
    /// "Hello" on a 300 by 200 page, as PDFKit reports it at every rotation, and where the ink
    /// landed on pages rendered at 90, 180 and 270 (measured with `PDFPage.thumbnail`).
    private let line = (x: 40.0, y: 144.936, width: 57.5472, height: 28.272)

    private func near(_ rect: (x: Double, y: Double, width: Double, height: Double), _ expected: (Double, Double, Double, Double)) -> Bool {
        abs(rect.x - expected.0) < 0.01 && abs(rect.y - expected.1) < 0.01
            && abs(rect.width - expected.2) < 0.01 && abs(rect.height - expected.3) < 0.01
    }

    @Test("A rect of the stored page lands where the page shows it at each quarter turn")
    func displayedRects() {
        func shown(_ degrees: Int) -> (x: Double, y: Double, width: Double, height: Double) {
            PDFPageTurn.displayedRect(line, pageWidth: 300, pageHeight: 200, degrees: degrees)
        }
        #expect(near(shown(0), (40, 144.936, 57.5472, 28.272)))
        #expect(near(shown(90), (144.936, 202.4528, 28.272, 57.5472)))
        #expect(near(shown(180), (202.4528, 26.792, 57.5472, 28.272)))
        #expect(near(shown(270), (26.792, 40, 28.272, 57.5472)))
        #expect(PDFPageTurn.displayedSize(pageWidth: 300, pageHeight: 200, degrees: 90) == (200, 300))
        #expect(PDFPageTurn.displayedSize(pageWidth: 300, pageHeight: 200, degrees: 180) == (300, 200))
    }
}

@Suite("PDF page rotations: the controller")
@MainActor
struct PDFPageRotationControllerTests {
    /// A PDF of `count` pages, saved to a temporary file; the second page carries its own /Rotate 90.
    private func makeFile(pages count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rotations-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 0..<count {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string: "Page \(index + 1) text", attributes: [.font: NSFont.systemFont(ofSize: 20)])
            context.textPosition = CGPoint(x: 30, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        let seed = try #require(PDFDocument(url: url))
        seed.page(at: 1)?.rotation = 90
        #expect(seed.write(to: url))
        return url
    }

    /// The reader's document: a copy of the file's pages, as `BookPDFAssembly` makes it.
    private func openCopy(of url: URL) throws -> PDFDocument {
        let source = try #require(PDFDocument(url: url))
        let copy = PDFDocument()
        for index in 0..<source.pageCount {
            let page = try #require(source.page(at: index)?.copy() as? PDFPage)
            copy.insert(page, at: index)
        }
        return copy
    }

    @Test("A turn is kept for the next open, sits on the file's own rotation, and never touches the file")
    func turnsPersist() throws {
        let url = try makeFile(pages: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let sourceID = "rotation-test-\(UUID().uuidString)"
        let key = PDFPageRotations.key(sourceID: sourceID)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let runs = [PDFPageRotationOwner.Run(sourceID: sourceID, firstPage: 0)]

        var document = try openCopy(of: url)
        var controller = PDFPageRotationController(document: document, runs: runs)
        #expect(document.page(at: 0)?.rotation == 0 && document.page(at: 1)?.rotation == 90)

        controller.turn(try #require(document.page(at: 0)), by: 90)
        controller.turn(try #require(document.page(at: 1)), by: -90)
        #expect(document.page(at: 0)?.rotation == 90)
        #expect(document.page(at: 1)?.rotation == 0, "the file's 90 and a turn of 270 come full circle")

        document = try openCopy(of: url)
        #expect(document.page(at: 1)?.rotation == 90, "a fresh copy starts at the file's own rotation")
        controller = PDFPageRotationController(document: document, runs: runs)
        #expect(document.page(at: 0)?.rotation == 90 && document.page(at: 1)?.rotation == 0 && document.page(at: 2)?.rotation == 0)

        controller.turn(try #require(document.page(at: 0)), by: -90)
        controller.turn(try #require(document.page(at: 1)), by: 90)
        #expect(document.page(at: 1)?.rotation == 90, "turned back to the file's own rotation")
        #expect(UserDefaults.standard.object(forKey: key) == nil, "no turns, no row")
        #expect(try Data(contentsOf: url) == original, "the library file is untouched")
    }

    @Test("A turn filed under a chapter that no longer holds the page is not applied to the next chapter")
    func staleTurnsAreLeftAlone() throws {
        let url = try makeFile(pages: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = "rotation-test-a-\(UUID().uuidString)"
        let second = "rotation-test-b-\(UUID().uuidString)"
        let keys = [first, second].map(PDFPageRotations.key(sourceID:))
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        UserDefaults.standard.set("{\"2\":180}", forKey: keys[0])
        UserDefaults.standard.set("{\"1\":180}", forKey: keys[1])

        let document = try openCopy(of: url)
        _ = PDFPageRotationController(
            document: document,
            runs: [.init(sourceID: first, firstPage: 0), .init(sourceID: second, firstPage: 2)]
        )
        #expect(document.page(at: 2)?.rotation == 0, "the first chapter ends before page 2")
        #expect(document.page(at: 3)?.rotation == 180, "the second chapter's page 1 is the book's page 3")
    }

    @Test("The page's context menu offers both turns, and the keys are command R and command L")
    func menuAndKeys() throws {
        let url = try makeFile(pages: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceID = "rotation-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: PDFPageRotations.key(sourceID: sourceID)) }
        let document = try openCopy(of: url)
        let controller = PDFPageRotationController(document: document, runs: [.init(sourceID: sourceID, firstPage: 0)])

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))
        controller.addMenuItems(to: menu, page: document.page(at: 3))
        #expect(menu.items.map(\.title) == ["Copy", "", "Rotate Page Right", "Rotate Page Left"])
        let right = try #require(menu.items[safe: 2])
        _ = right.target?.perform(try #require(right.action), with: right)
        #expect(document.page(at: 3)?.rotation == 90, "the page under the pointer turns")

        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
            ))
        }
        #expect(try key("r", .command).readerPageTurnShortcut == 90)
        #expect(try key("l", .command).readerPageTurnShortcut == -90)
        #expect(try key("r", [.command, .shift]).readerPageTurnShortcut == nil)
        #expect(try key("f", .command).readerPageTurnShortcut == nil)
    }
}
