import Foundation
import Testing
@testable import ForeverLM

// MARK: - The policy and the folder (Foundation only)

@Suite("Page version history: policy and folder")
struct PageVersionPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_791_345_600)

    @Test("Typing keeps the body it replaces once every ten minutes")
    func typingIsRateLimited() {
        let old = "A paragraph the learner wrote."
        let new = "A paragraph the learner wrote, and more."
        #expect(PageVersionPolicy.keepsVersion(old: old, new: new, reason: .learnerEdit, newestVersionAt: nil, now: now))
        #expect(!PageVersionPolicy.keepsVersion(old: old, new: new, reason: .learnerEdit, newestVersionAt: now.addingTimeInterval(-9 * 60), now: now))
        #expect(PageVersionPolicy.keepsVersion(old: old, new: new, reason: .learnerEdit, newestVersionAt: now.addingTimeInterval(-10 * 60), now: now))
        #expect(!PageVersionPolicy.keepsVersion(old: old, new: new, reason: .anotherDevice, newestVersionAt: now.addingTimeInterval(-60), now: now))
    }

    @Test("An assistant's edit and a restore always keep the body they replace")
    func assistantAndRestoreAlwaysKeep() {
        let recent = now.addingTimeInterval(-5)
        #expect(PageVersionPolicy.keepsVersion(old: "Mine", new: "Theirs", reason: .assistantEdit, newestVersionAt: recent, now: now))
        #expect(PageVersionPolicy.keepsVersion(old: "Mine", new: "Older", reason: .restore, newestVersionAt: recent, now: now))
    }

    @Test("Losing more than half the page keeps it, however recent the last version")
    func shrinkingByHalfKeeps() {
        let old = String(repeating: "word ", count: 100)
        let recent = now.addingTimeInterval(-30)
        #expect(PageVersionPolicy.keepsVersion(old: old, new: String(old.prefix(240)), reason: .learnerEdit, newestVersionAt: recent, now: now))
        #expect(!PageVersionPolicy.keepsVersion(old: old, new: String(old.prefix(260)), reason: .learnerEdit, newestVersionAt: recent, now: now))
        #expect(PageVersionPolicy.keepsVersion(old: old, new: "", reason: .anotherDevice, newestVersionAt: recent, now: now))
    }

    @Test("An unchanged or empty body is never kept")
    func unchangedOrEmptyIsNotKept() {
        #expect(!PageVersionPolicy.keepsVersion(old: "Same", new: "Same", reason: .assistantEdit, newestVersionAt: nil, now: now))
        #expect(!PageVersionPolicy.keepsVersion(old: "  \n", new: "Text", reason: .restore, newestVersionAt: nil, now: now))
        #expect(!PageVersionPolicy.keepsVersion(old: "", new: "Text", reason: .learnerEdit, newestVersionAt: nil, now: now))
    }

    @Test("A version's file name carries its time and reason")
    func fileNameRoundTrips() throws {
        for reason in PageVersionReason.allCases {
            let name = PageVersionPolicy.fileName(savedAt: now, reason: reason)
            let version = try #require(PageVersionPolicy.version(fileName: name))
            #expect(version.reason == reason)
            #expect(version.savedAt == now)
            #expect(version.id == name)
        }
        #expect(PageVersionPolicy.version(fileName: ".DS_Store") == nil)
        #expect(PageVersionPolicy.version(fileName: "123-unknown.md") == nil)
        #expect(PageVersionPolicy.version(fileName: "abc-learnerEdit.md") == nil)
    }

    @Test("Past a hundred versions the oldest go")
    func pruningKeepsTheNewestHundred() {
        let versions = (0..<105).map { index in
            PageVersion(
                id: PageVersionPolicy.fileName(savedAt: now.addingTimeInterval(Double(index)), reason: .learnerEdit),
                savedAt: now.addingTimeInterval(Double(index)),
                reason: .learnerEdit
            )
        }
        let dropped = PageVersionPolicy.versionsToDrop(versions.shuffled(), byteCounts: [:])
        #expect(dropped.count == 5)
        #expect(Set(dropped.map(\.savedAt)) == Set((0..<5).map { now.addingTimeInterval(Double($0)) }))
    }

    @Test("Past the byte budget the oldest go, and the newest always stays")
    func pruningKeepsTheByteBudget() {
        let versions = (0..<4).map { index in
            PageVersion(id: "v\(index)", savedAt: now.addingTimeInterval(Double(index)), reason: .assistantEdit)
        }
        let sizes = ["v0": 40, "v1": 40, "v2": 40, "v3": 40]
        #expect(PageVersionPolicy.versionsToDrop(versions, byteCounts: sizes, maximumCount: 100, maximumBytes: 100).map(\.id) == ["v1", "v0"])
        // A newest version over the budget on its own stays, alone.
        #expect(PageVersionPolicy.versionsToDrop(versions, byteCounts: ["v3": 500], maximumCount: 100, maximumBytes: 100).map(\.id) == ["v2", "v1", "v0"])
    }

    @Test("Versions are listed by day and time")
    func labels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_GB")
        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 23, minute: 30)))
        func at(_ day: Int, _ hour: Int, _ minute: Int, year: Int = 2026, month: Int = 10) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
        }
        #expect(PageVersionLabel.when(try at(6, 22, 41), now: reference, calendar: calendar, locale: locale) == "Today 22:41")
        #expect(PageVersionLabel.when(try at(5, 21, 10), now: reference, calendar: calendar, locale: locale) == "Yesterday 21:10")
        #expect(PageVersionLabel.when(try at(3, 9, 5), now: reference, calendar: calendar, locale: locale) == "3 Oct 09:05")
        #expect(PageVersionLabel.when(try at(3, 9, 5, year: 2025), now: reference, calendar: calendar, locale: locale) == "3 Oct 2025 09:05")
    }

    @Test("The folder keeps, lists newest first, skips a body it holds, and is removed")
    func folderKeepsAndRemoves() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageVersionHistoryTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = PageVersionHistory(rootDirectory: root)

        #expect(history.keepIfDue(previous: "First", replacedBy: "Second", artifactID: "page", reason: .learnerEdit, now: now))
        // Typing a minute later keeps nothing; an assistant's edit does.
        #expect(!history.keepIfDue(previous: "Second", replacedBy: "Third", artifactID: "page", reason: .learnerEdit, now: now.addingTimeInterval(60)))
        #expect(history.keepIfDue(previous: "Second", replacedBy: "Fourth", artifactID: "page", reason: .assistantEdit, now: now.addingTimeInterval(120)))
        // The newest version already holds this body.
        #expect(!history.keepIfDue(previous: "Second", replacedBy: "Fifth", artifactID: "page", reason: .restore, now: now.addingTimeInterval(180)))

        let versions = history.versions(of: "page")
        #expect(versions.map(\.reason) == [.assistantEdit, .learnerEdit])
        #expect(try history.markdown(of: versions[0], artifactID: "page") == "Second")
        #expect(try history.markdown(of: versions[1], artifactID: "page") == "First")

        // Paths outside the folder are refused.
        #expect(history.directory(for: "../elsewhere") == nil)
        #expect(!history.keepIfDue(previous: "x", replacedBy: "y", artifactID: "a/b", reason: .assistantEdit, now: now))

        history.removeHistory(of: "page")
        #expect(history.versions(of: "page").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("page").path))
    }

    @Test("Two versions in one millisecond are both kept, and the folder prunes to its limit")
    func sameMillisecondAndPruning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageVersionHistoryTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = PageVersionHistory(rootDirectory: root)
        try history.keep("One", artifactID: "page", reason: .assistantEdit, at: now)
        try history.keep("Two", artifactID: "page", reason: .assistantEdit, at: now)
        #expect(history.versions(of: "page").count == 2)

        for index in 0..<(PageVersionPolicy.maximumVersionsPerPage + 3) {
            history.keepIfDue(
                previous: "Body \(index)",
                replacedBy: "Body \(index + 1)",
                artifactID: "page",
                reason: .assistantEdit,
                now: now.addingTimeInterval(Double(index + 1))
            )
        }
        let versions = history.versions(of: "page")
        #expect(versions.count == PageVersionPolicy.maximumVersionsPerPage)
        #expect(try history.markdown(of: versions[0], artifactID: "page") == "Body \(PageVersionPolicy.maximumVersionsPerPage + 2)")
    }
}

// MARK: - Through storage (the app's save, delete and duplicate)

@Suite("Page version history: storage")
struct PageVersionStorageTests {
    private func makeStorage() -> (StorageService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageVersionStorageTests_\(UUID().uuidString)", isDirectory: true)
        return (StorageService(storeRoot: root), root)
    }

    @Test("A save keeps the body it replaces, an assistant's always, and a restore keeps what it replaces")
    func savesKeepVersions() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try await storage.createArtifact(title: "Notes", homeNotebookID: nil, linkedNotebookIDs: [], markdown: "First draft")

        let typed = try await storage.writeArtifactMarkdown(artifactID: created.artifact.id, markdown: "First draft, typed on", expectedRevision: created.revision)
        // Typing again at once keeps nothing new.
        let typedAgain = try await storage.writeArtifactMarkdown(artifactID: created.artifact.id, markdown: "First draft, typed on and on", expectedRevision: typed.revision)
        #expect(try await storage.pageVersions(artifactID: created.artifact.id).map(\.reason) == [.learnerEdit])

        let edited = try await storage.writeArtifactMarkdown(
            artifactID: created.artifact.id,
            markdown: "An assistant's rewrite",
            expectedRevision: typedAgain.revision,
            versionReason: .assistantEdit
        )
        let versions = try await storage.pageVersions(artifactID: created.artifact.id)
        #expect(versions.map(\.reason) == [.assistantEdit, .learnerEdit])
        #expect(try await storage.pageVersionMarkdown(artifactID: created.artifact.id, version: versions[0]) == "First draft, typed on and on")
        #expect(try await storage.pageVersionMarkdown(artifactID: created.artifact.id, version: versions[1]) == "First draft")

        let restored = try await storage.restorePageVersion(artifactID: created.artifact.id, version: versions[1], expectedRevision: edited.revision)
        #expect(restored.markdown == "First draft")
        let afterRestore = try await storage.pageVersions(artifactID: created.artifact.id)
        #expect(afterRestore.first?.reason == .restore)
        #expect(try await storage.pageVersionMarkdown(artifactID: created.artifact.id, version: afterRestore[0]) == "An assistant's rewrite")

        // Kept beside the database, never in the page's own (synced) folder.
        let pageFolder = try await storage.artifactDirectoryURL(artifactID: created.artifact.id, createIfNeeded: false)
        let pageFiles = try FileManager.default.contentsOfDirectory(atPath: pageFolder.path)
        #expect(!pageFiles.contains { $0.hasSuffix("-learnerEdit.md") || $0.hasSuffix("-assistantEdit.md") })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(PageVersionHistory.folderName).appendingPathComponent(created.artifact.id).path))

        try await storage.deleteArtifact(created.artifact.id)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(PageVersionHistory.folderName).appendingPathComponent(created.artifact.id).path))
    }

    @Test("Duplicate copies the body, the attachments, the notebooks and the draft mark")
    func duplicateCopiesThePage() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try await storage.createArtifact(
            title: "Field notes",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            markdown: "![Figure](foreverlm://attachment/abc.png)\n\nText.",
            isDraft: true
        )
        let attachments = try await storage.artifactDirectoryURL(artifactID: created.artifact.id, createIfNeeded: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: attachments.appendingPathComponent("abc.png"))

        let copy = try await storage.duplicateArtifact(artifactID: created.artifact.id)
        #expect(copy.artifact.id != created.artifact.id)
        #expect(copy.artifact.title == "Field notes copy")
        #expect(copy.artifact.isDraft)
        #expect(copy.artifact.teamID == nil)
        #expect(try await storage.artifactMarkdown(copy.artifact.id).markdown == created.markdown)
        let copied = try await storage.artifactDirectoryURL(artifactID: copy.artifact.id, createIfNeeded: false)
            .appendingPathComponent("Attachments/abc.png")
        #expect(try Data(contentsOf: copied) == Data([1, 2, 3]))
    }
}
