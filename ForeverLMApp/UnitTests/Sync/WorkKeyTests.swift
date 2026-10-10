import Foundation
import Testing
@testable import ForeverLM

/// Work keys (§4.2): the identity keys every import route looks up before it mints a source.
@Suite("Work keys")
struct WorkKeyTests {
    @Test("The work-key vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("work-key")
    }

    @Test("One paper reached by DOI resolver, DOI label and version suffix gives one key")
    func oneDOI() {
        let keys = [
            "doi:10.1101/2024.11.04.615786",
            "doi:https://doi.org/10.1101/2024.11.04.615786v3",
            "DOI:doi:10.1101/2024.11.04.615786.",
        ].map { WorkKey.normalizeRemote($0) }
        #expect(Set(keys) == ["doi:10.1101/2024.11.04.615786"])
    }

    @Test("A v after a letter is the DOI's own: two Oxford papers of 2015 keep two keys, a preprint's versions keep one")
    func doiVersions() {
        #expect(WorkKey.normalizeRemote("doi:10.1093/nar/gkv1344") == "doi:10.1093/nar/gkv1344")
        #expect(WorkKey.normalizeRemote("doi:10.1093/nar/gkv1344") != WorkKey.normalizeRemote("doi:10.1093/nar/gkv1157"))
        #expect(WorkKey.normalizeRemote("doi:10.21203/rs.3.rs-4356493/v2") == WorkKey.normalizeRemote("doi:10.21203/rs.3.rs-4356493/v1"))
        #expect(WorkKey.normalizeRemote("doi:10.20944/preprints202608.1166.v1") == "doi:10.20944/preprints202608.1166")
    }

    @Test("An ISBN-10 and its ISBN-13 are one key")
    func oneISBN() {
        #expect(WorkKey.normalizeRemote("isbn:0-306-40615-2") == WorkKey.normalizeRemote("isbn:978-0-306-40615-7"))
    }

    @Test("A url: key is URL normalization v1, and a local path is normalized only where the client's roots are given")
    func urlKeys() {
        #expect(WorkKey.normalizeRemote("url:https://www.Example.COM/page/?utm_source=x") == "url:example.com/page")
        #expect(WorkKey.normalizeRemote("url:/Users/someone/Papers/x.pdf") == nil)
        #expect(WorkKey.normalize("url:/Users/someone/Papers/x.pdf", localPath: { _ in "Papers/x.pdf" }) == "url:Papers/x.pdf")
    }

    @Test("A dismissal's target is the address's url work key, the address itself when it has none; the web's twin agrees")
    func dismissalTargets() {
        #expect(WorkKey.dismissalTarget(url: "https://www.Example.COM/page/?utm_source=x") == "wk:url:example.com/page")
        #expect(WorkKey.dismissalTarget(url: "https://youtube.com/watch?v=abc&list=x") == "wk:url:youtube.com/watch?v=abc")
        #expect(WorkKey.dismissalTarget(url: "/papers/a.pdf") == "wk:url:/papers/a.pdf")
    }

    @Test("A normalized key is a fixed point")
    func idempotent() throws {
        let directory = try #require(SyncVectorRunner.directory)
        let file = try SyncJSON(parsing: Data(contentsOf: directory.appendingPathComponent("work-key.json")))
        for entry in file["cases"]?.arrayValue ?? [] {
            guard let key = entry["expect"]?.stringValue else { continue }
            #expect(WorkKey.normalizeRemote(key) == key, Comment(rawValue: key))
        }
    }
}
