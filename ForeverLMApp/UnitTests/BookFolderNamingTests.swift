import Foundation
import SQLite3
import Testing
@testable import ForeverLM

private let taggedName = "Why We Die_ The New Science of Aging and the Quest for -- Venki Ramakrishnan -- 2023 -- HarperCollins -- 7dade272a2ea6fd87772ae38a5dde4ce -- Anna’s Archive"
private let cleanName = "Why We Die_ The New Science of Aging and the Quest for"

@Suite("Book folder naming")
struct BookFolderNamingTests {
    @Test("An archive-tagged download name reduces to its title segment")
    func taggedNameReducesToTitle() {
        #expect(BookFolderNaming.cleanedFolderName(fromFileBaseName: taggedName) == cleanName)
        #expect(BookFolderNaming.isArchiveTaggedName(taggedName))
    }

    @Test("The tag is recognised with a straight apostrophe or none at all")
    func tagSpellings() {
        for tag in ["Anna's Archive", "Annas Archive", "anna’s archive", " Anna's Archive "] {
            let name = "Life on the Edge -- Johnjoe McFadden -- 66dc71a8ff7ec56b4868f40761ceb592 -- \(tag)"
            #expect(BookFolderNaming.isArchiveTaggedName(name), "\(tag)")
            #expect(BookFolderNaming.cleanedFolderName(fromFileBaseName: name) == "Life on the Edge", "\(tag)")
        }
    }

    @Test("Names without the tag come back untouched, separators and all")
    func untaggedNamesAreLeftAlone() {
        for name in [
            "Molecular Biology of the Cell-W W Norton Company 2022",
            "Radical Life Extension - Kristopher Borer",
            "Notes -- Volume 2",
            " padded name ",
            "Anna’s Archive Guide",
        ] {
            #expect(!BookFolderNaming.isArchiveTaggedName(name), "\(name)")
            #expect(BookFolderNaming.cleanedFolderName(fromFileBaseName: name) == name, "\(name)")
        }
    }

    @Test("A tagged name with no title segment still loses the tag and the hash")
    func tagWithoutTitle() {
        let cleaned = BookFolderNaming.cleanedFolderName(
            fromFileBaseName: "-- Some Author -- 7dade272a2ea6fd87772ae38a5dde4ce -- Anna’s Archive"
        )
        #expect(!cleaned.contains("Anna"))
        #expect(!cleaned.contains("7dade272a2ea6fd87772ae38a5dde4ce"))
        #expect(cleaned.contains("Some Author"))
    }

    @Test("The folder segment is read out of a stored path")
    func folderSegmentParsing() {
        #expect(KnowledgeStore.bookFolderName(inStoredPath: "Books/\(taggedName)/Chapters/01.xhtml") == taggedName)
        #expect(KnowledgeStore.bookFolderName(inStoredPath: "/Users/x/Library/Application Support/ForeverLM/Content/Books/Immune/cover.jpg") == "Immune")
        #expect(KnowledgeStore.bookFolderName(inStoredPath: "Papers/x.pdf") == nil)
        #expect(KnowledgeStore.bookFolderName(inStoredPath: "Books/Immune") == nil)
        #expect(KnowledgeStore.bookFolderName(inStoredPath: nil) == nil)
    }
}

@Suite("Book folder reference rewrite")
struct BookFolderReferenceRewriteTests {
    private func makeChapter(_ folder: String, file: String, group: String) -> StudioArticle {
        let path = "Books/\(folder)/Chapters/\(file)"
        var article = StudioArticle(
            url: path,
            title: file,
            sourceType: .book,
            parentGroup: group,
            localFilePath: path
        )
        article.normalizedURL = URLNormalizer.normalize(path)
        return article
    }

    @Test("Every column that names the folder moves, and the records are queued for sync")
    func rewritesEveryColumnAndQueuesSync() throws {
        let store = try KnowledgeStore(inMemory: true)
        var ch1 = makeChapter(taggedName, file: "01.xhtml", group: "book-1")
        // Books imported before the private container was retired carry the
        // absolute path in `domain`.
        ch1.domain = "/Users/x/Library/Mobile Documents/iCloud~com~feynmanlm/Documents/FeynmanLM/Books/\(taggedName)/Chapters/01.xhtml"
        let ch2 = makeChapter(taggedName, file: "02.xhtml", group: "book-1")
        let other = makeChapter("Immune", file: "01.xhtml", group: "book-2")
        for article in [ch1, ch2, other] {
            try store.saveSource(article)
        }
        try store.saveBookMetadata(groupName: "book-1", title: "Why We Die", coverPath: "Books/\(taggedName)/cover.jpg")
        try store.saveBookMetadata(groupName: "book-2", title: "Immune", coverPath: "Books/Immune/cover.jpg")
        try store.execBind("""
            INSERT OR REPLACE INTO source_index_state (source_id, model, content_length, file_path, indexed_at)
            VALUES (?, 'test-model', 10, ?, 0)
        """) { stmt in
            store.bind(stmt, 1, ch1.id)
            store.bind(stmt, 2, "Books/\(taggedName)/Chapters/01.xhtml")
        }
        try store.execBind("""
            INSERT INTO scheduled_sources (id, source_id, source_url, source_normalized_url, planned_at, added_at, created_at, updated_at)
            VALUES ('sched-1', ?, ?, ?, 0, 0, 0, 0)
        """) { stmt in
            store.bind(stmt, 1, ch2.id)
            store.bind(stmt, 2, "Books/\(taggedName)/Chapters/02.xhtml")
            store.bind(stmt, 3, "Books/\(taggedName)/Chapters/02.xhtml")
        }
        // Saving queued these already; start from a clean queue so the rewrite's
        // own enqueues are what the assertions see.

        #expect(try store.referencedTaggedBookFolderNames() == [taggedName])

        let rewritten = try store.rewriteBookFolderReferences(from: taggedName, to: cleanName)
        #expect(rewritten == 2)

        let sources = try store.loadActiveSources()
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        #expect(byID[ch1.id]?.url.hasSuffix("Books/\(cleanName)/Chapters/01.xhtml") == true)
        #expect(byID[ch1.id]?.localFilePath?.contains("/\(cleanName)/") == true)
        #expect(byID[ch1.id]?.domain.contains("/\(cleanName)/Chapters/01.xhtml") == true)
        #expect(byID[ch1.id]?.domain.contains("Anna") == false)
        #expect(byID[ch2.id]?.url.hasSuffix("Books/\(cleanName)/Chapters/02.xhtml") == true)
        #expect(byID[other.id]?.url.hasSuffix("Books/Immune/Chapters/01.xhtml") == true)

        let covers = try store.loadBooks().coverPaths
        #expect(covers["book-1"]?.hasSuffix("/Books/\(cleanName)/cover.jpg") == true)
        #expect(covers["book-2"]?.hasSuffix("/Books/Immune/cover.jpg") == true)

        var indexPath: String?
        try store.query("SELECT file_path FROM source_index_state") { stmt in indexPath = store.string(stmt, 0) }
        #expect(indexPath == "Books/\(cleanName)/Chapters/01.xhtml")

        var scheduledURL: String?
        try store.query("SELECT source_url FROM scheduled_sources") { stmt in scheduledURL = store.string(stmt, 0) }
        #expect(scheduledURL == "Books/\(cleanName)/Chapters/02.xhtml")


        #expect(try store.referencedTaggedBookFolderNames().isEmpty)
    }

    @Test("A folder nothing points at rewrites nothing and queues nothing")
    func noMatchIsANoOp() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveSource(makeChapter("Immune", file: "01.xhtml", group: "book-2"))
        #expect(try store.rewriteBookFolderReferences(from: taggedName, to: cleanName) == 0)
    }

    @Test("The original book file is renamed with its folder")
    func originalFileFollowsFolder() throws {
        let store = try KnowledgeStore(inMemory: true)
        var chapter = makeChapter(taggedName, file: "01.pdf", group: "book-1")
        chapter.localFilePath = "Books/\(taggedName)/\(taggedName).pdf"
        try store.saveSource(chapter)
        try store.rewriteBookFolderReferences(from: taggedName, to: cleanName)
        let saved = try store.loadActiveSources().first
        #expect(saved?.localFilePath?.hasSuffix("Books/\(cleanName)/\(cleanName).pdf") == true)
    }
}

@Suite("Book folder adoption")
struct BookFolderAdoptionTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BookFolderAdoptionTests_\(UUID().uuidString)", isDirectory: true)
    }

    private func seedBook(folder: String, in root: URL, fileManager: FileManager = .default) throws {
        let bookDir = root.appendingPathComponent("Books/\(folder)", isDirectory: true)
        try fileManager.createDirectory(at: bookDir.appendingPathComponent("Chapters"), withIntermediateDirectories: true)
        try Data("chapter".utf8).write(to: bookDir.appendingPathComponent("Chapters/01.xhtml"))
        try Data("epub".utf8).write(to: bookDir.appendingPathComponent("\(folder).epub"))
        try Data("jpg".utf8).write(to: bookDir.appendingPathComponent("cover.jpg"))
    }

    private func seedRows(folder: String, group: String, on storage: StorageService) async throws -> StudioArticle {
        let path = "Books/\(folder)/Chapters/01.xhtml"
        var chapter = StudioArticle(url: path, title: "Ch 1", sourceType: .book, parentGroup: group, localFilePath: path)
        chapter.normalizedURL = URLNormalizer.normalize(path)
        try await storage.saveSource(chapter)
        try await storage.saveBookMetadata(groupName: group, title: group, coverPath: "Books/\(folder)/cover.jpg")
        return chapter
    }

    @Test("A tagged folder is renamed on disk, its rows follow, and a second run does nothing")
    func renamesFolderAndRowsOnce() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try seedBook(folder: taggedName, in: root)
        try seedBook(folder: "Immune", in: root)
        let storage = StorageService(storeRoot: root)
        let tagged = try await seedRows(folder: taggedName, group: "book-1", on: storage)
        let other = try await seedRows(folder: "Immune", group: "book-2", on: storage)

        let report = try await storage.adoptTaggedBookFolders()
        #expect(report.renamed == [BookFolderAdoption.Rename(oldName: taggedName, newName: cleanName)])
        #expect(report.rewrittenChapterCount == 1)
        #expect(report.isComplete)
        #expect(report.didChangeAnything)

        let books = root.appendingPathComponent("Books", isDirectory: true)
        #expect(!fm.fileExists(atPath: books.appendingPathComponent(taggedName).path))
        #expect(fm.fileExists(atPath: books.appendingPathComponent("\(cleanName)/Chapters/01.xhtml").path))
        #expect(fm.fileExists(atPath: books.appendingPathComponent("\(cleanName)/\(cleanName).epub").path))
        #expect(fm.fileExists(atPath: books.appendingPathComponent("\(cleanName)/cover.jpg").path))
        #expect(fm.fileExists(atPath: books.appendingPathComponent("Immune/Chapters/01.xhtml").path))

        let sources = try await storage.loadActiveSources()
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        #expect(byID[tagged.id]?.url.hasSuffix("Books/\(cleanName)/Chapters/01.xhtml") == true)
        #expect(byID[tagged.id]?.url.contains("Anna") == false)
        #expect(byID[other.id]?.url.hasSuffix("Books/Immune/Chapters/01.xhtml") == true)
        let covers = try await storage.loadBooks().coverPaths
        #expect(covers["book-1"]?.hasSuffix("/Books/\(cleanName)/cover.jpg") == true)

        let second = try await storage.adoptTaggedBookFolders()
        #expect(second == BookFolderAdoption.Report())
        #expect(second.isComplete)
    }

    @Test("A tagged folder whose clean name is taken is left alone, rows included")
    func leavesFolderWhenCleanNameIsTaken() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try seedBook(folder: taggedName, in: root)
        try seedBook(folder: cleanName, in: root)
        let storage = StorageService(storeRoot: root)
        let tagged = try await seedRows(folder: taggedName, group: "book-1", on: storage)

        let report = try await storage.adoptTaggedBookFolders()
        #expect(report.renamed.isEmpty)
        #expect(report.skippedBecauseDestinationExists == [taggedName])
        #expect(report.rewrittenChapterCount == 0)
        #expect(!report.isComplete)

        let books = root.appendingPathComponent("Books", isDirectory: true)
        #expect(fm.fileExists(atPath: books.appendingPathComponent("\(taggedName)/Chapters/01.xhtml").path))
        let sources = try await storage.loadActiveSources()
        #expect(sources.first { $0.id == tagged.id }?.url.hasSuffix("Books/\(taggedName)/Chapters/01.xhtml") == true)
    }

    @Test("Rows that still name a folder already renamed on disk are finished on the next run")
    func finishesRowsWhenFolderWasAlreadyRenamed() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBook(folder: cleanName, in: root)
        let storage = StorageService(storeRoot: root)
        let tagged = try await seedRows(folder: taggedName, group: "book-1", on: storage)

        let report = try await storage.adoptTaggedBookFolders()
        #expect(report.renamed.isEmpty)
        #expect(report.rewrittenChapterCount == 1)
        #expect(report.isComplete)
        let sources = try await storage.loadActiveSources()
        #expect(sources.first { $0.id == tagged.id }?.url.hasSuffix("Books/\(cleanName)/Chapters/01.xhtml") == true)
    }

    @Test("Rows naming a folder that exists under neither name are reported, not rewritten")
    func reportsUnresolvedReferences() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let tagged = try await seedRows(folder: taggedName, group: "book-1", on: storage)

        let report = try await storage.adoptTaggedBookFolders()
        #expect(report.unresolvedReferences == [taggedName])
        #expect(!report.isComplete)
        #expect(!report.didChangeAnything)
        let sources = try await storage.loadActiveSources()
        #expect(sources.first { $0.id == tagged.id }?.url.hasSuffix("Books/\(taggedName)/Chapters/01.xhtml") == true)
    }
}
