import Foundation
import Testing
@testable import ForeverLM

/// Lookup before mint (docs/cloudkit-schema-design.md §4.2, D22, D47): under generation 2 an import
/// looks every key it knows up in the work-key index of its library before it mints a source, and a
/// hit is that source, which gains the new keys. Generation 1 mints as build 177 does
/// (`SourceSchema155MigrationTests`).
@Suite("Work key lookup")
struct WorkKeyLookupTests {
    private typealias Fixture = SourceSyncFixture

    @Test("A DOI-then-URL import lands on one Source, which gains the second address")
    func doiThenURL() throws {
        let (root, store) = try Fixture.makeStore("doi-then-url")
        defer { try? FileManager.default.removeItem(at: root) }
        var byDOI = Fixture.article("https://doi.org/10.1038/s41586-020-2649-2", title: "Array programming with NumPy", type: .paper)
        #expect(try store.insertSourceIfNew(&byDOI))
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM source_work_keys WHERE source_id = ? AND work_key = 'doi:10.1038/s41586-020-2649-2'",
                                  [.text(byDOI.id)]) == 1, "the DOI the address names is a key of the first import")

        // The publisher's page, with the DOI its metadata gave: a different address, so generation 1's
        // URL checks miss it, and the first source holds no DOI column for its DOI check.
        var byURL = Fixture.article("https://www.nature.com/articles/s41586-020-2649-2", title: "Array programming with NumPy", type: .paper)
        byURL.doi = "10.1038/s41586-020-2649-2"
        #expect(try !store.insertSourceIfNew(&byURL), "no second source")
        #expect(byURL.id == byDOI.id, "the import is that source")
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM sources") == 1)
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM source_work_keys WHERE source_id = ? AND work_key = 'url:' || ?",
                                  [.text(byDOI.id), .text(URLNormalizer.normalize("https://www.nature.com/articles/s41586-020-2649-2"))]) == 1,
                "the source gains the second address as a key")
    }

    @Test("A source the iPhone minted under its own form of an address is found by its historical key")
    func iPhoneMintedSource() throws {
        let (root, store) = try Fixture.makeStore("iphone", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        // An address the two normalizers write differently (the Mac drops a publisher PDF's `.pdf`), so
        // the phone's id is not the Mac's.
        let raw = "https://www.nature.com/articles/s41586-020-2649-2.pdf"
        let phoneForm = MobileURLNormalizer.normalize(raw)
        #expect(phoneForm != URLNormalizer.normalize(raw))
        let phoneID = SyncIdentity.sourceID(normalizedURL: phoneForm)
        #expect(phoneID != SourceIdentity.stableID(for: raw))
        // As generation 1 left the phone's capture on the Mac, then the activation's work keys.
        try Fixture.save(store, StudioArticle(url: raw, title: "Array programming with NumPy", sourceType: .article, id: phoneID))
        try store.execForTesting("DELETE FROM source_work_keys")
        try store.deriveSourceWorkKeys()
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM source_work_keys WHERE source_id = ? AND work_key = ?",
                                  [.text(phoneID), .text("url:" + phoneForm)]) == 1, "the phone's form is a key")

        var again = Fixture.article(raw, title: "Array programming with NumPy")
        #expect(try !store.insertSourceIfNew(&again))
        #expect(again.id == phoneID)
        #expect(try store.sourceID(forWorkKeys: ["url:" + phoneForm], teamID: nil) == phoneID, "the historical key alone finds it")
    }

    @Test("A phone capture of a PDF the Mac holds is found by its file key")
    func phoneCaptureFoundByFileKey() throws {
        let (root, store) = try Fixture.makeStore("file-key")
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("Imported paper.pdf")
        let bytes = Data("%PDF-1.7 a paper's bytes".utf8)
        try bytes.write(to: pdf)
        var local = StudioArticle(url: pdf.path, title: "A local paper", sourceType: .paper, localFilePath: pdf.path)
        #expect(try store.insertSourceIfNew(&local))

        let hash = SyncIdentity.sha256Hex(bytes)
        #expect(try SourceFileHash.sha256Hex(ofFileAt: pdf) == hash)
        // The Mac's own import keeps its path-based id; the phone names the same bytes by their hash.
        #expect(local.id != SourceIdentity.fileID(sha256: hash))
        #expect(try store.sourceID(forWorkKeys: ["file:" + hash], teamID: nil) == local.id)
    }

    @Test("A key in a team's copy is not a hit for the learner's own library")
    func lookupStaysInItsLibrary() throws {
        let (root, store) = try Fixture.makeStore("team-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://example.org/team-only"
        var copy = StudioArticle(url: url, title: "The team's", sourceType: .article, id: TeamContentIdentity.sourceID(teamID: "team-1", url: url))
        copy.teamID = "team-1"
        try store.saveSource(copy)
        let keys = store.workKeys(for: copy, hashingFile: false)
        #expect(try store.sourceID(forWorkKeys: keys, teamID: "team-1") == copy.id)
        #expect(try store.sourceID(forWorkKeys: keys, teamID: nil) == nil)
    }

    @Test("A preprint's published DOI is no work key, so its journal version imports as a source of its own")
    func journalVersionOfASavedPreprint() throws {
        let (root, store) = try Fixture.makeStore("preprint-then-journal")
        defer { try? FileManager.default.removeItem(at: root) }
        var preprint = Fixture.article("https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1", title: "PeptiVerse", type: .paper)
        preprint.doi = "10.1101/2025.01.02.631000"
        preprint.publishedDOI = "10.1038/s41586-025-09429-6"
        #expect(try store.insertSourceIfNew(&preprint))
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM source_work_keys WHERE source_id = ? AND work_key = 'doi:10.1038/s41586-025-09429-6'",
                                  [.text(preprint.id)]) == 0, "the published DOI links the rows and names neither")

        var journal = Fixture.article("https://www.nature.com/articles/s41586-025-09429-6", title: "PeptiVerse", type: .paper)
        journal.doi = "10.1038/s41586-025-09429-6"
        #expect(try store.insertSourceIfNew(&journal), "the journal version is new")
        #expect(journal.id != preprint.id)
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM sources") == 2)
    }

    @Test("The repair takes a published DOI that an older build wrote out of a preprint's keys, and keeps the rest")
    func repairRemovesThePublishedDOIKey() throws {
        let (root, store) = try Fixture.makeStore("published-key-repair")
        defer { try? FileManager.default.removeItem(at: root) }
        var preprint = Fixture.article("https://www.biorxiv.org/content/10.1101/2025.01.02.631000v1", title: "PeptiVerse", type: .paper)
        preprint.doi = "10.1101/2025.01.02.631000"
        preprint.publishedDOI = "10.1038/s41586-025-09429-6"
        #expect(try store.insertSourceIfNew(&preprint))
        // What the build before wrote: the journal's DOI as a key of the preprint.
        try store.addWorkKeys(["doi:10.1038/s41586-025-09429-6"], to: preprint.id)

        #expect(try store.removePublishedDOIWorkKeys() == 1)
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM source_work_keys WHERE source_id = ? AND work_key = 'doi:10.1038/s41586-025-09429-6'",
                                  [.text(preprint.id)]) == 0)
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM source_work_keys WHERE source_id = ? AND work_key = 'doi:10.1101/2025.01.02.631000'",
                                  [.text(preprint.id)]) == 1, "its own DOI stays")
        #expect(try store.removePublishedDOIWorkKeys() == 0, "a second run has nothing to do")
    }

    @Test("The work keys of an address: v1, the iPhone's form where it differs, and the identifiers it names")
    func keysOfAnAddress() {
        let keys = SourceWorkKeys.keys(url: "https://arxiv.org/abs/2503.09427v2", normalizedURL: nil)
        #expect(keys.contains("arxiv:2503.09427"))
        #expect(keys.contains("url:" + URLNormalizer.normalize("https://arxiv.org/abs/2503.09427v2")))
        #expect(SourceWorkKeys.keys(url: "https://www.youtube.com/watch?v=abcdefghijk", normalizedURL: nil).contains("yt:abcdefghijk"))
        #expect(SourceWorkKeys.keys(url: "https://x.com/someone/status/1234567890", normalizedURL: nil).contains("x:1234567890"))
        #expect(SourceWorkKeys.keys(url: "https://github.com/Apple/Swift.git", normalizedURL: nil).contains("gh:apple/swift"))
        #expect(SourceWorkKeys.keys(url: nil, normalizedURL: nil, doi: "https://doi.org/10.1101/2024.11.04.615786v3") == ["doi:10.1101/2024.11.04.615786"])
        #expect(SourceWorkKeys.keys(url: nil, normalizedURL: nil, fileHash: String(repeating: "A", count: 64)) == ["file:" + String(repeating: "a", count: 64)])
        // A page that only mentions a repository is no repository.
        #expect(!SourceWorkKeys.keys(url: "https://example.org/apple/swift", normalizedURL: nil).contains { $0.hasPrefix("gh:") })
    }
}
