import Foundation
import Testing
@testable import ForeverLM

extension SyncVectorRunner {
    /// Runs one vector file and records an issue for every case that fails.
    static func expectCases(_ name: String, normalizeURL: (String) -> String = defaultNormalizeURL,
                            textMerge: ((String, String, String) -> String?)? = nil) {
        guard let directory else {
            Issue.record("schema/vectors is not in the test bundle: ForeverLMApp/project.yml lists it as a resource folder")
            return
        }
        let report = run(name, in: directory, normalizeURL: normalizeURL, textMerge: textMerge)
        if pendingFiles[name] == nil, report.cases == 0 { Issue.record(Comment(rawValue: "\(name).json has no cases")) }
        for failure in report.failures { Issue.record(Comment(rawValue: failure.description)) }
    }
}

/// Every file in `schema/vectors` (docs/cloudkit-schema-design.md §12.1, P12) passes through the
/// Swift sync core, so the Swift and JS cores (which run the same files) cannot drift apart.
@Suite("Sync vector conformance")
struct SyncVectorConformanceTests {
    @Test("Every vector file in the bundle has a runner, and the folder is the one the schema ships")
    func everyFileIsRun() throws {
        let directory = try #require(SyncVectorRunner.directory, "schema/vectors is not in the test bundle")
        let names = SyncVectorRunner.fileNames(in: directory)
        #expect(names.count >= 15)
        for name in names {
            #expect(SyncVectorRunner.handledFiles.contains(name) || SyncVectorRunner.pendingFiles[name] != nil,
                    Comment(rawValue: "\(name).json has no runner"))
        }
        #expect(Set(names).isSuperset(of: SyncVectorRunner.handledFiles))
    }

    @Test("Every case of every vector file holds", arguments: [
        "chat-kind", "chat-ticks", "envelope", "fractional-index", "locator", "merge", "naming", "placement",
        "resolve", "stamp-clock", "text-merge", "url-normalize", "work-key", "card-schedule", "replica-audit",
    ])
    func vectorFile(_ name: String) {
        SyncVectorRunner.expectCases(name, normalizeURL: URLNormalizer.normalize, textMerge: { base, mine, theirs in
            if case .merged(let text) = ArtifactThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) { return text }
            return nil
        })
    }

    @Test("merge.json holds the 200 and more cases §6.2 asks for")
    func mergeCoverage() throws {
        let directory = try #require(SyncVectorRunner.directory)
        let report = SyncVectorRunner.run("merge", in: directory)
        #expect(report.cases >= 200)
    }

    @Test("A broken expectation is reported, not passed (the runner can fail)")
    func runnerFailsOnAWrongCase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-vectors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file: SyncJSON = [
            "vectors": "work-key", "spec": "test", "format": "test",
            "cases": [["name": "lowercase", "input": "doi:10.1/A", "expect": "doi:10.1/A"]],
        ]
        try file.serialized().write(to: directory.appendingPathComponent("work-key.json"))
        let report = SyncVectorRunner.run("work-key", in: directory)
        #expect(report.cases == 1)
        #expect(report.failures.count == 1)
    }
}
