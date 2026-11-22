import Foundation
import Testing
@testable import ForeverLM

/// The Mac's side of the notes graph (docs/notes-graph-design.md, "Editor and
/// host"): what the Docs pane reads from the editor's requests, what it hands
/// the editor, and the pure rules behind Daily Notes and the lists.
@Suite("Notes graph host: the Docs pane's side of the editor")
struct NotesGraphHostTests {

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func block(
        docID: String = "doc-a",
        key: String = "2",
        blockID: String? = nil,
        markdown: String = "PINK1 builds up on damaged mitochondria"
    ) -> DocGraphBlock {
        DocGraphBlock(
            docID: docID,
            key: key,
            kind: .listItem,
            blockID: blockID,
            markdown: markdown,
            plainText: markdown,
            breadcrumbs: ["Mitophagy"],
            childrenMarkdown: "",
            line: 4
        )
    }

    private static func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: Requests from the editor

    @Test("Block requests keep only real block ids, each once")
    func blocksRequested() {
        let message = ArtifactNotesGraphMessage.parse(
            type: "blocksRequested",
            payload: ["blockIDs": ["a1b2c3d4e", "NOTANID", "a1b2c3d4e", 7, "zz9zz9zz9"]]
        )
        #expect(message == .blocksRequested(blockIDs: ["a1b2c3d4e", "zz9zz9zz9"]))
        #expect(ArtifactNotesGraphMessage.parse(type: "blocksRequested", payload: ["blockIDs": ["nope"]]) == nil)
    }

    @Test("A request missing what it needs is not a request")
    func malformedRequests() {
        #expect(ArtifactNotesGraphMessage.parse(type: "blockSearchRequested", payload: ["query": "pink"]) == nil, "no request id")
        #expect(ArtifactNotesGraphMessage.parse(type: "blockSearchRequested", payload: ["requestID": "r1"]) == .blockSearchRequested(requestID: "r1", query: ""))
        #expect(ArtifactNotesGraphMessage.parse(type: "openBlockRequested", payload: ["blockID": "short"]) == nil)
        #expect(ArtifactNotesGraphMessage.parse(type: "openReferenceRequested", payload: ["kind": "notebook", "id": "x"]) == nil)
        #expect(ArtifactNotesGraphMessage.parse(type: "dailyNoteRequested", payload: ["dayKey": "2026-02-30"]) == nil)
        #expect(ArtifactNotesGraphMessage.parse(type: "blockIDAssigned", payload: ["docID": "d", "key": "1", "blockID": "BAD"]) == nil)
        #expect(ArtifactNotesGraphMessage.parse(type: "makeIdeaRequested", payload: ["text": "   "]) == nil)
        #expect(ArtifactNotesGraphMessage.parse(type: "somethingElse", payload: [:]) == nil)
    }

    @Test("Every message type the protocol names is heard")
    func messageTypes() {
        let samples: [(String, [String: Any])] = [
            ("blocksRequested", ["blockIDs": ["a1b2c3d4e"]]),
            ("blockSearchRequested", ["requestID": "r", "query": "q"]),
            ("blockIDAssigned", ["docID": "d", "key": "1.0", "revision": "rev", "plainText": "t", "blockID": "a1b2c3d4e"]),
            ("pageCreationRequested", ["docID": "6f1c0e8e-2a52-4d5e-8a3b-5d3f2b8c9e10", "title": "Mitophagy"]),
            ("openTitleRequested", ["title": "Mitophagy"]),
            ("openBlockRequested", ["blockID": "a1b2c3d4e"]),
            ("openReferenceRequested", ["kind": "doc", "id": "d"]),
            ("copyToPasteboardRequested", ["text": "((a1b2c3d4e))"]),
            ("makeIdeaRequested", ["text": "An idea"]),
            ("dailyNoteRequested", ["dayKey": "2026-10-06"]),
            ("dailyNotesMoreRequested", ["before": "2026-10-01"]),
            ("blockReferencesRequested", ["blockID": "a1b2c3d4e"]),
        ]
        #expect(Set(samples.map(\.0)) == ArtifactNotesGraphMessage.messageTypes)
        for (type, payload) in samples {
            #expect(ArtifactNotesGraphMessage.parse(type: type, payload: payload) != nil, "\(type)")
        }
    }

    @Test("A day's page is named by its day when the editor sends no title")
    func pageCreationForADay() {
        let message = ArtifactNotesGraphMessage.parse(
            type: "pageCreationRequested",
            payload: ["docID": "daily-2026-10-07", "dayKey": "2026-10-07"]
        )
        #expect(message == .pageCreationRequested(docID: "daily-2026-10-07", title: "October 7th, 2026", dayKey: "2026-10-07", open: false, nested: false))
        let newPage = ArtifactNotesGraphMessage.parse(
            type: "pageCreationRequested",
            payload: ["docID": "6f1c0e8e-2a52-4d5e-8a3b-5d3f2b8c9e10", "title": "  Mitophagy  ", "dayKey": "not a day"]
        )
        #expect(newPage == .pageCreationRequested(docID: "6f1c0e8e-2a52-4d5e-8a3b-5d3f2b8c9e10", title: "Mitophagy", dayKey: nil, open: false, nested: false))
    }

    @Test("A page made from the slash menu says it is to be opened; a [[link]]'s page, with no flag, is not")
    func pageCreationOpens() {
        let id = "6f1c0e8e-2a52-4d5e-8a3b-5d3f2b8c9e10"
        let opened = ArtifactNotesGraphMessage.parse(
            type: "pageCreationRequested",
            payload: ["docID": id, "title": "Untitled", "open": true]
        )
        #expect(opened == .pageCreationRequested(docID: id, title: "Untitled", dayKey: nil, open: true, nested: true))
        let declined = ArtifactNotesGraphMessage.parse(
            type: "pageCreationRequested",
            payload: ["docID": id, "title": "Untitled", "open": false]
        )
        #expect(declined == .pageCreationRequested(docID: id, title: "Untitled", dayKey: nil, open: false, nested: false))
        let absent = ArtifactNotesGraphMessage.parse(type: "pageCreationRequested", payload: ["docID": id, "title": "Untitled"])
        #expect(absent == .pageCreationRequested(docID: id, title: "Untitled", dayKey: nil, open: false, nested: false))
        // Anything but a boolean is not a yes.
        let notABool = ArtifactNotesGraphMessage.parse(type: "pageCreationRequested", payload: ["docID": id, "title": "Untitled", "open": "yes"])
        #expect(notABool == .pageCreationRequested(docID: id, title: "Untitled", dayKey: nil, open: false, nested: false))
    }

    @Test("Only the Page row's page is nested: the one that asks to be opened, unless the editor says otherwise")
    func pageCreationNests() {
        let id = "6f1c0e8e-2a52-4d5e-8a3b-5d3f2b8c9e10"
        let slashRow = ArtifactNotesGraphMessage.parse(
            type: "pageCreationRequested",
            payload: ["docID": id, "title": "Untitled", "open": true]
        )
        #expect(slashRow == .pageCreationRequested(docID: id, title: "Untitled", dayKey: nil, open: true, nested: true))
        let wikiLink = ArtifactNotesGraphMessage.parse(type: "pageCreationRequested", payload: ["docID": id, "title": "Mitophagy"])
        #expect(wikiLink == .pageCreationRequested(docID: id, title: "Mitophagy", dayKey: nil, open: false, nested: false))
        let dayLink = ArtifactNotesGraphMessage.parse(
            type: "pageCreationRequested",
            payload: ["docID": "daily-2026-10-07", "dayKey": "2026-10-07", "open": true]
        )
        #expect(dayLink == .pageCreationRequested(docID: "daily-2026-10-07", title: "October 7th, 2026", dayKey: "2026-10-07", open: true, nested: false))
        // A field the editor sends decides.
        let explicitNo = ArtifactNotesGraphMessage.parse(
            type: "pageCreationRequested",
            payload: ["docID": id, "title": "Untitled", "open": true, "nested": false]
        )
        #expect(explicitNo == .pageCreationRequested(docID: id, title: "Untitled", dayKey: nil, open: true, nested: false))
        let explicitYes = ArtifactNotesGraphMessage.parse(
            type: "pageCreationRequested",
            payload: ["docID": id, "title": "Untitled", "nested": true]
        )
        #expect(explicitYes == .pageCreationRequested(docID: id, title: "Untitled", dayKey: nil, open: false, nested: true))
    }

    // MARK: What the editor is handed

    @Test("A block without an id is written null, a page's time as seconds since 1970")
    func wireShapes() throws {
        let block = try Self.object(NotesGraphWire.json(NotesGraphWire.Block(Self.block())))
        #expect(block["blockID"] is NSNull)
        #expect(block["docTitle"] == nil, "a block names its page only where the editor shows it")
        #expect(block["kind"] as? String == "listItem")
        #expect(block["breadcrumbs"] as? [String] == ["Mitophagy"])

        let titled = try Self.object(NotesGraphWire.json(NotesGraphWire.Block(Self.block(blockID: "a1b2c3d4e"), docTitle: "Mitophagy")))
        #expect(titled["blockID"] as? String == "a1b2c3d4e")
        #expect(titled["docTitle"] as? String == "Mitophagy")

        let updated = Date(timeIntervalSince1970: 1_791_000_000)
        let group = DocGraphReferenceGroup(kind: .dailyNote, id: "daily-2026-10-06", title: "October 6th, 2026", updatedAt: updated, blocks: [Self.block()])
        let wire = try Self.object(NotesGraphWire.json(NotesGraphWire.Group(group)))
        #expect(wire["kind"] as? String == "dailyNote")
        #expect((wire["updatedAt"] as? NSNumber)?.doubleValue == 1_791_000_000)
        #expect((wire["blocks"] as? [Any])?.count == 1)
    }

    @Test("The context names its doc, and pages by their normalized titles")
    func graphContextShape() throws {
        let context = NotesGraphWire.GraphContext(
            docID: "doc-a",
            isDailyNote: false,
            allowsDates: true,
            blocks: ["a1b2c3d4e": NotesGraphWire.Block(Self.block(blockID: "a1b2c3d4e"), docTitle: "Mitophagy")],
            titles: ["mitophagy": NotesGraphWire.TitleTarget(id: "doc-m")],
            refCounts: ["a1b2c3d4e": 3]
        )
        let object = try Self.object(NotesGraphWire.json(context))
        #expect(object["docID"] as? String == "doc-a")
        #expect((object["titles"] as? [String: [String: String]])?["mitophagy"] == ["kind": "doc", "id": "doc-m"])
        #expect((object["refCounts"] as? [String: Int])?["a1b2c3d4e"] == 3)

        let provisional = try Self.object(NotesGraphWire.json(NotesGraphWire.GraphContext.provisional(docID: "daily-2026-10-06", isDailyNote: true, allowsDates: true)))
        #expect(provisional["isDailyNote"] as? Bool == true)
        #expect((provisional["blocks"] as? [String: Any])?.isEmpty == true)
    }

    @Test("A call into the editor does nothing on a page without the function")
    func guardedCalls() {
        let script = ArtifactNotesGraphScript.call("setBlocks", ["{}"])
        #expect(script == "(function(e){if(e&&typeof e.setBlocks==='function'){e.setBlocks({});}})(window.foreverLMArtifactEditor);true;")
        #expect(ArtifactNotesGraphScript.call("setBlockSearchResults", [ArtifactNotesGraphScript.string("r\"1"), "[]"]).contains(#"e.setBlockSearchResults("r\"1",[]);"#))
    }

    // MARK: The bridge

    @MainActor
    final class RecordingPage: ArtifactNotesGraphPage {
        var docID: String
        var scripts: [String] = []
        /// The docs the pane asked this page to hand its text over for.
        var syncedDocs: [String] = []

        init(docID: String) { self.docID = docID }

        func runNotesGraphScript(_ script: String, forDoc docID: String) -> Bool {
            guard docID == self.docID else { return false }
            scripts.append(script)
            return true
        }

        func syncMarkdown(forDoc docID: String) async throws {
            syncedDocs.append(docID)
        }
    }

    @MainActor
    @Test("A page that becomes ready is told about its own doc first, provisional context included, and a pooled page's sections are cleared")
    func bridgeReadiness() {
        let bridge = ArtifactNotesGraphBridge()
        bridge.open(docID: "doc-a", isDailyNote: false, allowsDates: true)
        let page = RecordingPage(docID: "doc-a")
        bridge.attach(page)
        bridge.setDailyContext(#"{"dayKey":"2026-11-22"}"#)
        #expect(page.scripts.isEmpty, "nothing reaches a page before it is ready")
        bridge.setDailyContext("null")

        bridge.pageBecameReady(page)
        #expect(page.scripts.count == 2)
        #expect(page.scripts[0].contains(#"e.setGraphContext({"allowsDates":true,"blocks":{},"docID":"doc-a""#))
        #expect(page.scripts[1].contains("e.setDailyContext(null)"))

        bridge.setContext(#"{"docID":"doc-a"}"#)
        #expect(page.scripts.count == 3)
        bridge.setContext(#"{"docID":"doc-a"}"#)
        #expect(page.scripts.count == 3, "the same answer twice is said once")
    }

    @MainActor
    @Test("A block to reveal waits for the page, is shown once, and only in its own doc")
    func bridgeReveal() {
        let bridge = ArtifactNotesGraphBridge()
        let request = ArtifactBlockRevealRequest(artifactID: "doc-a", reveal: DocBlockReveal(blockID: "a1b2c3d4e"))
        // Asked for while the doc is still loading.
        bridge.reveal(request)
        bridge.open(docID: "doc-a", isDailyNote: false, allowsDates: true)
        let page = RecordingPage(docID: "doc-a")
        bridge.attach(page)
        bridge.pageBecameReady(page)
        #expect(page.scripts.last?.contains(#"e.revealBlock({"blockID":"a1b2c3d4e"})"#) == true)

        let count = page.scripts.count
        bridge.reveal(request)
        bridge.pageBecameReady(page)
        #expect(page.scripts.filter { $0.contains("revealBlock") }.count == 1, "one request is shown once")
        #expect(page.scripts.count == count + 3)

        let other = ArtifactBlockRevealRequest(artifactID: "doc-b", reveal: DocBlockReveal(plainText: "PINK1"))
        bridge.reveal(other)
        #expect(!page.scripts.contains { $0.contains("PINK1") }, "a block of another doc is not looked for here")
    }

    @MainActor
    @Test("The pane asks a page for its text only once the page is ready, and gets no script run for it")
    func bridgeSyncsMarkdownFromTheReadyPage() async throws {
        let bridge = ArtifactNotesGraphBridge()
        bridge.open(docID: "doc-a", isDailyNote: false, allowsDates: true)
        let page = RecordingPage(docID: "doc-a")
        bridge.attach(page)
        try await bridge.syncMarkdownFromPage()
        #expect(page.syncedDocs.isEmpty, "a page that is not ready is not asked")

        bridge.pageBecameReady(page)
        let scripts = page.scripts.count
        try await bridge.syncMarkdownFromPage()
        #expect(page.syncedDocs == ["doc-a"])
        #expect(page.scripts.count == scripts)

        bridge.detach(page)
        try await bridge.syncMarkdownFromPage()
        #expect(page.syncedDocs == ["doc-a"], "a detached page is not asked")
    }

    @MainActor
    @Test("An answer for a doc the bridge has left is dropped")
    func bridgeDropsLateAnswers() throws {
        let bridge = ArtifactNotesGraphBridge()
        bridge.open(docID: "doc-a", isDailyNote: false, allowsDates: true)
        let page = RecordingPage(docID: "doc-a")
        bridge.attach(page)
        bridge.pageBecameReady(page)
        var replies: [ArtifactNotesGraphReply] = []
        bridge.onMessage = { _, reply in replies.append(reply) }
        bridge.receive(.blocksRequested(blockIDs: ["a1b2c3d4e"]))
        let reply = try #require(replies.first)

        reply.setBlocks("{}")
        #expect(page.scripts.last?.contains("e.setBlocks({})") == true)

        let before = page.scripts.count
        bridge.open(docID: "doc-b", isDailyNote: false, allowsDates: true)
        reply.setBlockSearchResults(requestID: "r", hitsJSON: "[]")
        #expect(page.scripts.count == before)
        bridge.detach(page)
        bridge.setContext("{}")
        #expect(page.scripts.count == before, "a detached page hears nothing")
    }

    // MARK: Addresses

    @Test("A source's address, and a highlight's, read back the way they were written")
    func sourceLinks() {
        let plain = NotesGraphSourceLink.href(sourceID: "paper 1")
        #expect(plain == "foreverlm://source/paper%201")
        #expect(NotesGraphSourceLink.parse(plain) == NotesGraphSourceLink(sourceID: "paper 1"))

        let marked = NotesGraphSourceLink.href(sourceID: "s1", highlightID: "h-9")
        #expect(marked == "foreverlm://source/s1?highlight=h-9")
        #expect(NotesGraphSourceLink.parse(marked) == NotesGraphSourceLink(sourceID: "s1", highlightID: "h-9"))

        #expect(NotesGraphSourceLink.parse("https://foreverlm.invalid/source/s2") == NotesGraphSourceLink(sourceID: "s2"))
        #expect(NotesGraphSourceLink.parse("foreverlm://doc/s2") == nil)
        #expect(NotesGraphSourceLink.parse("https://example.com/source/s2") == nil)
    }

    // MARK: Text

    @Test("The blocks a doc references are listed once each, embeds included, in order")
    func referencedBlockIDs() {
        let markdown = """
        As ((a1b2c3d4e)) says, and again ((a1b2c3d4e)).
        {{embed: ((zz9zz9zz9))}}
        Not a reference: ((short)).
        """
        #expect(NotesGraphHostText.referencedBlockIDs(in: markdown) == ["a1b2c3d4e", "zz9zz9zz9"])
        #expect(NotesGraphHostText.referencedBlockIDs(in: "Nothing here").isEmpty)
    }

    @Test("The page draws a resolution only when it keeps every line where it was")
    func resolutionKeepsLines() {
        #expect(NotesGraphHostText.lineKeepingResolution(original: "a\nb", resolved: "A\nB") == "A\nB")
        #expect(NotesGraphHostText.lineKeepingResolution(original: "a\nb", resolved: "A\nchild\nB") == "a\nb", "a resolution that moves lines is not drawn")
    }

    @Test("An Idea is titled by one line of the words, at most 280 characters, without a block id")
    func ideaTitle() {
        #expect(NotesGraphHostText.ideaTitle(from: "  PINK1   builds up\n on damaged\tmitochondria ^a1b2c3d4e\n") == "PINK1 builds up on damaged mitochondria")
        let long = String(repeating: "word ", count: 100)
        #expect(NotesGraphHostText.ideaTitle(from: long).count == 280)
        #expect(NotesGraphHostText.ideaTitle(from: " \n ").isEmpty)
    }

    @Test("The copy toast says what was copied")
    func copyConfirmation() {
        #expect(NotesGraphHostText.copyConfirmation(for: "((a1b2c3d4e))") == "Block reference copied")
        #expect(NotesGraphHostText.copyConfirmation(for: "{{embed: ((a1b2c3d4e))}}") == "Block embed copied")
        #expect(NotesGraphHostText.copyConfirmation(for: "Some words") == "Copied")
    }

    // MARK: Daily notes

    @Test("The day stepper walks across months and years, and Today is the calendar's day")
    func dayStepping() {
        let calendar = Self.utc
        #expect(DailyNoteDays.dayKey("2026-10-06", offsetBy: -1, calendar: calendar) == "2026-10-05")
        #expect(DailyNoteDays.dayKey("2026-10-31", offsetBy: 1, calendar: calendar) == "2026-11-01")
        #expect(DailyNoteDays.dayKey("2026-12-31", offsetBy: 1, calendar: calendar) == "2027-01-01")
        #expect(DailyNoteDays.dayKey("2028-03-01", offsetBy: -1, calendar: calendar) == "2028-02-29")
        #expect(DailyNoteDays.dayKey("not-a-day", offsetBy: 1, calendar: calendar) == nil)

        let now = Date(timeIntervalSince1970: 1_791_288_000) // 2026-10-06 12:00 UTC
        #expect(DailyNoteDays.today(now: now, calendar: calendar) == "2026-10-06")
        #expect(DailyNoteDays.isToday("2026-10-06", now: now, calendar: calendar))
        #expect(!DailyNoteDays.isToday("2026-10-05", now: now, calendar: calendar))
    }

    @Test("An empty daily note keeps out of the lists, one with writing is listed, and a search finds any")
    func listing() {
        let made = Date(timeIntervalSince1970: 1_000_000)
        func listed(_ id: String, title: String = "", made: Date = made, saved: Date = made, search: String = "") -> Bool {
            NotesGraphDocListing.isListed(id: id, title: title, createdAt: made, updatedAt: saved, searchQuery: search)
        }
        #expect(listed("doc-1"))
        #expect(!listed("daily-2026-10-06", title: "October 6th, 2026"))
        #expect(!listed("daily-2026-10-06", title: "October 6th, 2026", search: "   "))
        #expect(listed("daily-2026-10-06", title: "October 6th, 2026", search: "October 6"))
        #expect(listed("daily-notes-plan"), "an id that names no day is an ordinary doc")
        // The 2026-10-07 note: titled by the learner, and saved after it was made.
        #expect(listed("daily-2026-10-07", title: "Shifting from virtual cells to mitochondria"))
        #expect(listed("daily-2026-10-07", title: "October 7th, 2026", saved: made.addingTimeInterval(600)),
                "a day saved after it was made holds writing")
    }

    private static func doc(
        _ id: String,
        title: String,
        teamID: String? = nil,
        archived: Bool = false,
        hidden: Bool = false,
        updatedAt: TimeInterval
    ) -> ArtifactRecord {
        ArtifactRecord(
            id: id,
            title: title,
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            teamID: teamID,
            archivedAt: archived ? Date() : nil,
            hiddenAt: hidden ? Date() : nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    @Test("`[[` offers the library's other docs newest first, never a daily note, then the open Ideas")
    func linkTargets() {
        let docs = [
            Self.doc("open", title: "This doc", updatedAt: 50),
            Self.doc("older", title: "Older", updatedAt: 10),
            Self.doc("newer", title: "Newer", updatedAt: 40),
            Self.doc("daily-2026-10-06", title: "October 6th, 2026", updatedAt: 60),
            Self.doc("team", title: "Team doc", teamID: "t1", updatedAt: 70),
            Self.doc("gone", title: "Archived", archived: true, updatedAt: 80),
            Self.doc("away", title: "Hidden", hidden: true, updatedAt: 90),
            Self.doc("overview", title: "Audio overview", updatedAt: 95),
        ]
        let targets = ArtifactPageLinkTargets.docs(
            docs,
            openDocID: "open",
            teamID: nil,
            isAudioOverview: { $0.id == "overview" },
            filedUnder: { _ in "Unfiled" }
        )
        #expect(targets.map(\.id) == ["newer", "older"])
        #expect(targets.allSatisfy { $0.kind == "doc" && $0.detail == "Unfiled" })

        let ideas = [
            IdeaRecord(id: "i1", title: "Mitophagy as inference", createdAt: Date(timeIntervalSince1970: 1)),
            IdeaRecord(id: "i2", title: "Put away", status: .archived, createdAt: Date(timeIntervalSince1970: 2)),
            IdeaRecord(id: "i3", title: "Newest idea", createdAt: Date(timeIntervalSince1970: 3)),
        ]
        let ideaTargets = ArtifactPageLinkTargets.ideas(ideas)
        #expect(ideaTargets.map(\.id) == ["i3", "i1"])
        #expect(ideaTargets.allSatisfy { $0.kind == "idea" && $0.detail == "Idea" })
    }

    @Test("`@` offers the learner's own chats newest first, never a hidden, shared or external one")
    func chatMentionTargets() {
        func chat(_ id: String, _ title: String, at seconds: TimeInterval, teamID: String? = nil, url: String? = nil, hidden: Bool = false) -> ReviewSessionRecord {
            var record = ReviewSessionRecord(id: id, title: title, url: url, createdAt: Date(timeIntervalSince1970: seconds), status: "active", sourceIDs: [])
            record.teamID = teamID
            record.hiddenAt = hidden ? Date(timeIntervalSince1970: seconds) : nil
            return record
        }
        let targets = ArtifactPageLinkTargets.chats([
            chat("old", "Old chat", at: 10),
            chat("new", "New chat", at: 30),
            chat("team", "Shared", at: 40, teamID: "t1"),
            chat("link", "External", at: 50, url: "https://example.com"),
            chat("away", "Hidden", at: 60, hidden: true),
            chat("blank", "  ", at: 70),
        ])
        #expect(targets.map(\.id) == ["new", "old"])
        #expect(targets.allSatisfy { $0.kind == "chat" && $0.detail == "Chat" })
        #expect(ArtifactPageLinkTargets.chats([chat("a", "A", at: 1), chat("b", "B", at: 2)], limit: 1).map(\.id) == ["b"])
    }

    @Test("A day's page foot lists what was read, chatted and written, and the passages highlighted, in the day's order")
    func dailyActivity() {
        let calendar = Self.utc
        let dayKey = "2026-10-06"
        let day = PlanDate.startOfDay(dayKey, calendar: calendar)!
        func highlight(_ id: String, minute: Int, quote: String) -> SourceHighlight {
            let moment = day.addingTimeInterval(TimeInterval(minute * 60))
            return SourceHighlight(
                id: id,
                sourceID: "paper",
                quote: quote,
                note: "",
                color: SourceHighlightColor(storedValue: nil),
                anchor: ReaderTextAnchor(exact: quote, prefix: "", suffix: "", offset: 0),
                createdAt: moment,
                updatedAt: moment
            )
        }
        let activities = [
            DayActivity(dayPlanID: dayKey, startMinute: 540, endMinute: 565, kind: .reading, targetID: "paper", title: "Old name"),
            DayActivity(dayPlanID: dayKey, startMinute: 600, endMinute: 610, kind: .listening, targetID: "paper", title: "Old name"),
            DayActivity(dayPlanID: dayKey, startMinute: 570, endMinute: 571, kind: .reading, targetID: "glance", title: "A glance"),
            DayActivity(dayPlanID: dayKey, startMinute: 700, endMinute: 720, kind: .chat, targetID: "chat-1", title: "Why PINK1?"),
            DayActivity(dayPlanID: dayKey, startMinute: 800, endMinute: 830, kind: .doc, targetID: "daily-2026-10-06", title: "October 6th, 2026"),
            DayActivity(dayPlanID: dayKey, startMinute: 840, endMinute: 850, kind: .doc, targetID: "report", title: "Report"),
        ]
        let items = NotesGraphDailyActivity.items(
            activities: activities,
            highlights: [highlight("h1", minute: 545, quote: "PINK1   accumulates\non the outer membrane")],
            dayKey: dayKey,
            excludingDocID: "daily-2026-10-06",
            title: { kind, id, logged in id == "paper" ? "The PINK1 paper" : logged },
            sourceTitle: { $0 == "paper" ? "The PINK1 paper" : nil },
            calendar: calendar
        )
        #expect(items.map(\.kind) == ["read", "highlight", "chat", "doc"])
        #expect(items[0] == NotesGraphWire.Activity(kind: "read", title: "The PINK1 paper", detail: "09:00 · 35m", href: "foreverlm://source/paper"))
        #expect(items[1] == NotesGraphWire.Activity(
            kind: "highlight",
            title: "PINK1 accumulates on the outer membrane",
            detail: "The PINK1 paper",
            href: "foreverlm://source/paper?highlight=h1"
        ))
        #expect(items[2].href == "foreverlm://chat/chat-1")
        #expect(items[3].href == "foreverlm://doc/report", "the daily note's own writing is not listed on it")
    }

    @Test("Earlier days skip the days with nothing written, page by page, and say when more are left")
    func earlierDays() async throws {
        let notes = (1...20).map { day -> ArtifactRecord in
            let key = String(format: "2026-09-%02d", day)
            return Self.doc("daily-\(key)", title: key, updatedAt: TimeInterval(day))
        }
        // Every third day has nothing written in it.
        let bodies = Dictionary(uniqueKeysWithValues: notes.enumerated().map { index, note in
            (note.id, index % 3 == 0 ? "  \n" : "Wrote on \(note.id)")
        })
        let fetch: (String, Int) async throws -> [ArtifactRecord] = { before, limit in
            Array(notes.filter { DailyNote.dayKey(ofID: $0.id)! < before }.reversed().prefix(limit))
        }
        let first = try await NotesGraphEarlierDays.collect(
            before: "2026-09-21",
            wanted: 7,
            notes: fetch,
            markdown: { bodies[$0] ?? "" }
        )
        #expect(first.days.count == 7)
        #expect(first.days.first?.dayKey == "2026-09-20")
        #expect(first.days.allSatisfy { !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        #expect(first.days.first?.title == "September 20th, 2026")
        #expect(first.hasMore)

        let rest = try await NotesGraphEarlierDays.collect(
            before: try #require(first.cursor),
            wanted: 7,
            notes: fetch,
            markdown: { bodies[$0] ?? "" }
        )
        let seen = Set(first.days.map(\.docID))
        #expect(rest.days.allSatisfy { !seen.contains($0.docID) })
        #expect(first.days.count + rest.days.count == notes.count - 7, "every written day once, the seven empty ones never")
        #expect(!rest.hasMore)
    }

    @Test("The library signature hears other docs and Ideas change, not the open doc's own saves")
    func librarySignature() {
        let open = Self.doc("open", title: "This doc", updatedAt: 1)
        let other = Self.doc("other", title: "Other", updatedAt: 1)
        let ideas = [IdeaRecord(id: "i1", title: "Idea", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))]
        let base = ArtifactNotesGraphHost.librarySignature(artifacts: [open, other], ideas: ideas, openDocID: "open", teamID: nil)

        var savedOpen = open
        savedOpen.updatedAt = Date(timeIntervalSince1970: 9)
        #expect(ArtifactNotesGraphHost.librarySignature(artifacts: [savedOpen, other], ideas: ideas, openDocID: "open", teamID: nil) == base)

        var savedOther = other
        savedOther.updatedAt = Date(timeIntervalSince1970: 9)
        #expect(ArtifactNotesGraphHost.librarySignature(artifacts: [open, savedOther], ideas: ideas, openDocID: "open", teamID: nil) != base)

        var linkedIdea = ideas[0]
        linkedIdea.links = [IdeaLink(kind: .artifact, targetID: "open")]
        #expect(ArtifactNotesGraphHost.librarySignature(artifacts: [open, other], ideas: [linkedIdea], openDocID: "open", teamID: nil) != base)
    }
}
