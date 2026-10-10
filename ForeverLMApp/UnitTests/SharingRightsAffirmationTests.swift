import Foundation
import Testing
@testable import ForeverLM

/// docs/teams-design.md, decision 22: the learner affirms once, before the
/// first share, that they may share the sources they share. The row
/// (`sharing.rightsAffirmation`) holds the statement's version and when; no
/// row, one that does not read, or an older version asks again. The Mac, the
/// iPhone and the web read the same row and say the same words.
@Suite("Sharing rights affirmation")
struct SharingRightsAffirmationTests {
    /// 2026-10-03T12:00:00Z.
    private let noon = Date(timeIntervalSince1970: 1_791_028_800)

    @Test("No row asks; once the learner affirms, they are not asked again")
    func askedOnceThenNotAgain() {
        #expect(SharingRightsAffirmation.needsAsking(rowValue: nil))
        let affirmed = SharingRightsAffirmation(affirmedAt: noon)
        #expect(affirmed.version == SharingRightsAffirmation.currentVersion)
        #expect(!SharingRightsAffirmation.needsAsking(rowValue: affirmed.rowValue))
        #expect(affirmed.isCurrent())
    }

    @Test("The row is the JSON every client writes, UTC to the second, and reads back whole")
    func rowShape() throws {
        let affirmed = SharingRightsAffirmation(affirmedAt: noon.addingTimeInterval(0.75))
        #expect(affirmed.rowValue == #"{"version":1,"affirmedAt":"2026-10-03T12:00:00Z"}"#)
        #expect(affirmed.affirmedAt == noon)
        let read = try #require(SharingRightsAffirmation(rowValue: affirmed.rowValue))
        #expect(read == affirmed)
        // A fraction of a second still reads, as on every client.
        let fraction = try #require(SharingRightsAffirmation(rowValue: #"{"version":1,"affirmedAt":"2026-10-03T12:00:00.123Z"}"#))
        #expect(fraction.version == 1)
        #expect(fraction.affirmedAt == noon)
        // Key order and spacing are the writer's; the row is read by meaning.
        #expect(SharingRightsAffirmation(rowValue: #"{ "affirmedAt" : "2026-10-03T12:00:00Z", "version" : 1 }"#) == affirmed)
    }

    @Test("A new version of the statement asks again, and an older client takes a newer answer")
    func newVersionAsksAgain() {
        let first = SharingRightsAffirmation(version: 1, affirmedAt: noon).rowValue
        #expect(SharingRightsAffirmation.needsAsking(rowValue: first, currentVersion: 2))
        let second = SharingRightsAffirmation(version: 2, affirmedAt: noon).rowValue
        #expect(!SharingRightsAffirmation.needsAsking(rowValue: second, currentVersion: 2))
        #expect(!SharingRightsAffirmation.needsAsking(rowValue: second, currentVersion: 1))
        #expect(SharingRightsAffirmation.needsAsking(rowValue: #"{"version":0,"affirmedAt":"2026-10-03T12:00:00Z"}"#))
    }

    @Test("A row that does not read asks")
    func malformedRowAsks() {
        let unreadable: [Any] = [
            "",
            "yes",
            "{}",
            #"{"version":1}"#,
            #"{"affirmedAt":"2026-10-03T12:00:00Z"}"#,
            #"{"version":"1","affirmedAt":"2026-10-03T12:00:00Z"}"#,
            #"{"version":true,"affirmedAt":"2026-10-03T12:00:00Z"}"#,
            #"{"version":1.5,"affirmedAt":"2026-10-03T12:00:00Z"}"#,
            #"{"version":1,"affirmedAt":"yesterday"}"#,
            #"{"version":1,"affirmedAt":1791028800}"#,
            #"["version",1]"#,
            1,
            true,
            ["version": 1, "affirmedAt": "2026-10-03T12:00:00Z"] as [String: Any],
            Data(#"{"version":1,"affirmedAt":"2026-10-03T12:00:00Z"}"#.utf8),
        ]
        for value in unreadable {
            #expect(SharingRightsAffirmation(rowValue: value) == nil, "\(value) read as an affirmation")
            #expect(SharingRightsAffirmation.needsAsking(rowValue: value), "\(value) did not ask")
        }
    }

    /// docs-site/website/test/sharing-rights-affirmation-vectors.json, which
    /// the web's `sharingAffirmation` runs too.
    private static func vectors() throws -> Any {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("docs-site/website/test/sharing-rights-affirmation-vectors.json"))
        return try JSONSerialization.jsonObject(with: data)
    }

    @Test("Every shared vector reads and writes as the web does")
    func sharedVectors() throws {
        let vectors = try #require(try Self.vectors() as? [String: Any])
        let reads = try #require(vectors["reads"] as? [[String: Any]])
        #expect(reads.count >= 30)
        for vector in reads {
            let name = vector["case"] as? String ?? "?"
            // JSON null is no row.
            let value: Any? = vector["value"] is NSNull ? nil : vector["value"]
            let asksAtVersion1 = try #require(vector["asksAtVersion1"] as? Bool)
            let asksAtVersion2 = try #require(vector["asksAtVersion2"] as? Bool)
            #expect(SharingRightsAffirmation.needsAsking(rowValue: value, currentVersion: 1) == asksAtVersion1, "\(name)")
            #expect(SharingRightsAffirmation.needsAsking(rowValue: value, currentVersion: 2) == asksAtVersion2, "\(name)")
        }
        let writes = try #require(vectors["writes"] as? [[String: Any]])
        #expect(!writes.isEmpty)
        for vector in writes {
            let name = vector["case"] as? String ?? "?"
            let milliseconds = try #require(vector["ms"] as? Double)
            let written = SharingRightsAffirmation(affirmedAt: Date(timeIntervalSince1970: milliseconds / 1000)).rowValue
            #expect(written == vector["value"] as? String, "\(name)")
        }
    }

    @Test("The words are the ones every client shows and every assistant is told")
    func wording() {
        #expect(SharingRightsAffirmation.preferenceKey == "sharing.rightsAffirmation")
        #expect(SharingRightsAffirmation.title == "Before you share")
        #expect(SharingRightsAffirmation.statement == "Sharing a notebook gives the people you invite copies of its sources. Share only sources you have the right to share, in line with copyright and each source's terms.")
        #expect(SharingRightsAffirmation.checkboxLabel == "I have the rights to share these sources")
        #expect(SharingRightsAffirmation.shareButtonTitle == "Share")
        #expect(SharingRightsAffirmation.cancelButtonTitle == "Cancel")
        #expect(SharingRightsAffirmation.assistantRefusal == #"Before sharing, ask the learner: "Do you have the rights to share these sources with the people you invite, in line with copyright and each source's terms?" Pass rights_affirmed_by_learner: true only if they say yes."#)
    }

    @Test("The row follows the account")
    func rowSyncs() {
        #expect(SyncedPreferenceKeys.isSynced(SharingRightsAffirmation.preferenceKey))
        #expect(SyncedPreferenceKeys.synced.contains(SharingRightsAffirmation.preferenceKey))
    }

    // MARK: - The Mac's row and its sheet

    /// The test's own defaults, so nothing here reaches the learner's row.
    private func withOwnDefaults<R>(_ body: (UserDefaults) throws -> R) throws -> R {
        let suite = "SharingRightsAffirmationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        return try SharingRightsRow.$overrideDefaults.withValue(SharingRightsRow.DefaultsOverride(defaults: defaults)) {
            try body(defaults)
        }
    }

    @Test("The Mac's row: reading writes nothing, Share records the current version, an older or unreadable row asks again")
    func macRow() throws {
        let key = SharingRightsAffirmation.preferenceKey
        try withOwnDefaults { defaults in
            #expect(SharingRightsRow.needsAsking)
            #expect(SharingRightsRow.stored == nil)
            #expect(defaults.object(forKey: key) == nil, "reading wrote the row")

            let affirmed = SharingRightsRow.affirm(at: noon)
            #expect(defaults.string(forKey: key) == #"{"version":1,"affirmedAt":"2026-10-03T12:00:00Z"}"#)
            #expect(SharingRightsRow.stored == affirmed)
            #expect(!SharingRightsRow.needsAsking)

            defaults.set(#"{"version":0,"affirmedAt":"2026-10-03T12:00:00Z"}"#, forKey: key)
            #expect(SharingRightsRow.needsAsking)
            defaults.set("not an affirmation", forKey: key)
            #expect(SharingRightsRow.needsAsking)
        }
    }

    @Test("A share asks first and runs only after Share; Cancel shares nothing; once affirmed the next share runs at once")
    @MainActor
    func promptGatesTheShare() throws {
        try withOwnDefaults { _ in
            let prompt = SharingRightsPrompt()
            var shared: [String] = []

            prompt.askIfNeeded { shared.append("first") }
            #expect(prompt.isPresented)
            #expect(shared.isEmpty)
            prompt.cancel()
            #expect(!prompt.isPresented)
            #expect(shared.isEmpty)
            #expect(SharingRightsRow.needsAsking, "Cancel recorded an affirmation")

            prompt.askIfNeeded { shared.append("second") }
            #expect(prompt.isPresented)
            prompt.confirm()
            #expect(!prompt.isPresented)
            #expect(shared == ["second"])
            #expect(!SharingRightsRow.needsAsking)

            prompt.askIfNeeded { shared.append("third") }
            #expect(!prompt.isPresented)
            #expect(shared == ["second", "third"])
        }
    }
}
