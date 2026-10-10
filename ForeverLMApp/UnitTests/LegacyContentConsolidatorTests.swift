import Foundation
import Testing
@testable import ForeverLM

@Suite("Legacy content consolidation")
struct LegacyContentConsolidatorTests {
    @Test("Publishes migration notifications on the main thread")
    func publishesMigrationNotificationsOnMainThread() async {
        let recorder = NotificationThreadRecorder()
        let center = NotificationCenter.default
        let coverToken = center.addObserver(
            forName: .syncedArtworkDidInstall,
            object: nil,
            queue: nil
        ) { _ in
            recorder.recordDelivery()
        }
        let migrationToken = center.addObserver(
            forName: .legacyContentDidMigrate,
            object: nil,
            queue: nil
        ) { _ in
            recorder.recordDelivery()
        }
        defer {
            center.removeObserver(coverToken)
            center.removeObserver(migrationToken)
        }

        await Task.detached {
            await StorageService.publishLegacyContentMigration()
        }.value

        let result = recorder.result
        #expect(result.deliveryCount == 2)
        #expect(result.allDeliveriesWereMainThread)
    }

    @Test("Moves unique files, deduplicates matches, and preserves divergent collisions")
    func consolidatesWithoutDataLoss() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-content-\(UUID())", isDirectory: true)
        let legacy = base.appendingPathComponent("ForeverLM 2", isDirectory: true)
        let content = base.appendingPathComponent("Content", isDirectory: true)
        let audio = base.appendingPathComponent("Canonical Audio", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try write("paper", to: legacy.appendingPathComponent("Papers/paper.pdf"))
        try write("same", to: legacy.appendingPathComponent("Books/same.txt"))
        try write("same", to: content.appendingPathComponent("Books/same.txt"))
        try write("legacy version", to: legacy.appendingPathComponent("Articles/conflict.html"))
        try write("canonical version", to: content.appendingPathComponent("Articles/conflict.html"))
        try write("audio", to: legacy.appendingPathComponent("Audio/source.m4a"))

        let report = LegacyContentConsolidator.consolidate(
            roots: [LegacyContentRoot(
                id: "Private iCloud ForeverLM 2",
                url: legacy,
                preservesRootForCanonicalAudio: false
            )],
            contentRoot: content,
            canonicalAudioRoot: audio
        )

        #expect(report.installed == 2)
        #expect(report.deduplicated == 1)
        #expect(report.conflictsPreserved == 1)
        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try read(content.appendingPathComponent("Papers/paper.pdf")) == "paper")
        #expect(try read(audio.appendingPathComponent("source.m4a")) == "audio")
        #expect(try read(content.appendingPathComponent("Articles/conflict.html")) == "canonical version")
        #expect(try read(content.appendingPathComponent(
            "Recovered Conflicts/Private iCloud ForeverLM 2/Articles/conflict.html"
        )) == "legacy version")
    }

    @Test("Retains only canonical Audio in the private-container root")
    func canonicalPrivateRootKeepsAudioOnly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-audio-\(UUID())", isDirectory: true)
        let privateRoot = base.appendingPathComponent("ForeverLM", isDirectory: true)
        let content = base.appendingPathComponent("Content", isDirectory: true)
        let audio = privateRoot.appendingPathComponent("Audio", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try write("audio", to: audio.appendingPathComponent("kept.m4a"))
        try write("paper", to: privateRoot.appendingPathComponent("Papers/moved.pdf"))

        let report = LegacyContentConsolidator.consolidate(
            roots: [LegacyContentRoot(
                id: "Private iCloud",
                url: privateRoot,
                preservesRootForCanonicalAudio: true
            )],
            contentRoot: content,
            canonicalAudioRoot: audio
        )

        #expect(report.installed == 1)
        #expect(report.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: privateRoot.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: privateRoot.path) == ["Audio"])
        #expect(try read(audio.appendingPathComponent("kept.m4a")) == "audio")
        #expect(try read(content.appendingPathComponent("Papers/moved.pdf")) == "paper")
    }

    @Test("Drains a legacy root reached through a Documents symlink")
    func drainsSymlinkedRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlinked-content-\(UUID())", isDirectory: true)
        let cloudStorage = base.appendingPathComponent("CloudStorage/Documents", isDirectory: true)
        let documentsLink = base.appendingPathComponent("Documents")
        let legacy = documentsLink.appendingPathComponent("ForeverLM", isDirectory: true)
        let content = base.appendingPathComponent("Content", isDirectory: true)
        let audio = base.appendingPathComponent("Audio", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: cloudStorage, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: documentsLink, withDestinationURL: cloudStorage)
        try write("paper", to: legacy.appendingPathComponent("Papers/symlinked.pdf"))

        let report = LegacyContentConsolidator.consolidate(
            roots: [LegacyContentRoot(
                id: "Documents",
                url: legacy,
                preservesRootForCanonicalAudio: false
            )],
            contentRoot: content,
            canonicalAudioRoot: audio
        )

        #expect(report.installed == 1)
        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try read(content.appendingPathComponent("Papers/symlinked.pdf")) == "paper")
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

private final class NotificationThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveryCount = 0
    private var allDeliveriesWereMainThread = true

    func recordDelivery() {
        lock.lock()
        deliveryCount += 1
        allDeliveriesWereMainThread = allDeliveriesWereMainThread && Thread.isMainThread
        lock.unlock()
    }

    var result: (deliveryCount: Int, allDeliveriesWereMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (deliveryCount, allDeliveriesWereMainThread)
    }
}
