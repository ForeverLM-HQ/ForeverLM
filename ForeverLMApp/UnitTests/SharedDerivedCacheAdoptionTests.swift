import Foundation
import Testing
@testable import ForeverLM

@Suite("Shared derived cache location")
struct SharedDerivedCacheLocationTests {
    @Test("The shared cache root is the same folder for both profiles")
    func sharedRootIsProfileIndependent() {
        // The whole point: production and Dev resolve to one directory, while
        // everything that carries identity stays split.
        let production = ForeverLMRuntimeIdentity.profile(isDevelopment: false)
        let development = ForeverLMRuntimeIdentity.profile(isDevelopment: true)
        #expect(production.productFolderName != development.productFolderName)

        let shared = ForeverLMRuntimeIdentity.sharedProductFolderName
        #expect(shared != production.productFolderName)
        #expect(shared != development.productFolderName)

        // `sharedTTSAudioCacheURL` reads no profile state, so a single value is
        // what both builds see.
        #expect(
            ForeverLMRuntimeIdentity.sharedTTSAudioCacheURL.path
                == ForeverLMRuntimeIdentity.sharedDerivedCacheRootURL
                    .appendingPathComponent("TTSAudioCache", isDirectory: true).path
        )
        #expect(
            ForeverLMRuntimeIdentity.sharedDerivedCacheRootURL.lastPathComponent == shared
        )
    }

    @Test("The shared folder is not mistaken for a library root")
    func sharedFolderIsNotALibraryRoot() {
        // `StorageService` strips a leading product-folder component off stored
        // content paths. The shared folder holds no content sources, so it must
        // fall outside that pattern — a match would silently eat the first
        // segment of a path that begins with its name.
        let stored = "\(ForeverLMRuntimeIdentity.sharedProductFolderName)/Papers/Example.pdf"
        #expect(StorageService.relativeSourcePath(stored) == stored)

        // The real product folders still normalize, so this is a statement about
        // the shared name and not a regression in the stripper.
        #expect(StorageService.relativeSourcePath("ForeverLM/Papers/Example.pdf") == "Papers/Example.pdf")
        #expect(StorageService.relativeSourcePath("ForeverLM Dev/Papers/Example.pdf") == "Papers/Example.pdf")
    }

    @Test("Voice previews resolve to the shared folder")
    func voicePreviewsAreShared() {
        // Same argument as the TTS cache: the key is a hash of model, voice and
        // the fixed sample text, and the warm-up walks the whole catalog.
        let previews = ForeverLMRuntimeIdentity.sharedVoicePreviewCacheURL.path
        #expect(previews.hasPrefix(ForeverLMRuntimeIdentity.sharedDerivedCacheRootURL.path + "/"))
        #expect(!previews.hasPrefix(ForeverLMRuntimeIdentity.applicationSupportRootURL.path + "/"))

        let model = try? #require(ArticleSpeechCatalog.models.first)
        let voice = model?.voices.first
        if let model, let voice {
            let file = ArticleSpeechVoicePreviewRepository.fileURL(modelID: model.id, voiceID: voice.id)
            #expect(file.deletingLastPathComponent().path == previews)
        }
    }

    @Test("Every shared cache is content-addressed and re-derivable")
    func cacheTableStaysHonest() {
        // The table is the place a future directory gets added by reflex. These
        // two are safe to share because a name is a hash of what produced it and
        // a lost entry costs a re-derivation. Content, ArticleArchives and the
        // article markers are none of those things.
        let names = SharedDerivedCacheAdoption.caches.map(\.directoryName)
        #expect(names == ["TTSAudioCache", "ReadAloudVoicePreviews"])
        for cache in SharedDerivedCacheAdoption.caches {
            #expect(!cache.fileExtensions.isEmpty)
            #expect(!cache.fileExtensions.contains("cached"))
        }
    }

    @Test("Article markers stay under the per-profile folder")
    func markersRemainPerProfile() {
        // Markers assert that this profile's iCloud document root holds a
        // finished export. The two roots are separate by design, so a shared
        // marker would be a false positive.
        let markers = ArticleSpeechAudioCache.markerDirectory().path
        #expect(markers.hasPrefix(ForeverLMRuntimeIdentity.applicationSupportRootURL.path + "/"))
        #expect(!markers.hasPrefix(ForeverLMRuntimeIdentity.sharedDerivedCacheRootURL.path + "/"))
        #expect(markers.hasSuffix("/TTSAudioCache/ArticleMarkers"))
    }
}

@Suite("Shared derived cache adoption")
struct SharedDerivedCacheAdoptionTests {
    @Test("Entries move into the shared folder instead of being re-derived")
    func entriesMoveRatherThanCopy() throws {
        let env = try Environment()
        defer { env.tearDown() }

        try env.writeProfileEntry(named: "aaa.mp3", contents: "one")
        try env.writeProfileEntry(named: "bbb.mp3", contents: "two")

        let report = env.adopt()

        #expect(report.movedEntries == 2)
        #expect(report.discardedDuplicates == 0)
        #expect(report.failedEntries == 0)
        #expect(env.sharedContents(named: "aaa.mp3") == "one")
        #expect(env.sharedContents(named: "bbb.mp3") == "two")
        // A move, not a copy: 1.7GB of duplication is the bug being fixed, so
        // leaving the originals behind would be no better than doing nothing.
        #expect(env.profileContents(named: "aaa.mp3") == nil)
        #expect(env.profileContents(named: "bbb.mp3") == nil)
    }

    @Test("Article markers are left in the per-profile folder")
    func markersAreNotAdopted() throws {
        let env = try Environment()
        defer { env.tearDown() }

        try env.writeProfileEntry(named: "aaa.mp3", contents: "one")
        let markers = env.profileCache.appendingPathComponent("ArticleMarkers", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try Data().write(to: markers.appendingPathComponent("ffff.cached"))

        let report = env.adopt()

        #expect(report.movedEntries == 1)
        #expect(FileManager.default.fileExists(atPath: markers.appendingPathComponent("ffff.cached").path))
        #expect(!FileManager.default.fileExists(
            atPath: env.sharedCache.appendingPathComponent("ArticleMarkers").path
        ))
    }

    @Test("The other profile's identical entry is dropped, not overwritten")
    func duplicatesAreDiscarded() throws {
        let env = try Environment()
        defer { env.tearDown() }

        // Same content-addressed name already contributed by the other profile.
        // Its bytes are authoritative for a concurrent reader holding that path;
        // ours are by definition the same, so ours is the copy to drop.
        try FileManager.default.createDirectory(at: env.sharedCache, withIntermediateDirectories: true)
        try "shared".write(
            to: env.sharedCache.appendingPathComponent("aaa.mp3"),
            atomically: true,
            encoding: .utf8
        )
        try env.writeProfileEntry(named: "aaa.mp3", contents: "shared")
        try env.writeProfileEntry(named: "bbb.mp3", contents: "two")

        let report = env.adopt()

        #expect(report.movedEntries == 1)
        #expect(report.discardedDuplicates == 1)
        #expect(report.failedEntries == 0)
        #expect(env.sharedContents(named: "aaa.mp3") == "shared")
        #expect(env.profileContents(named: "aaa.mp3") == nil)
        #expect(env.sharedContents(named: "bbb.mp3") == "two")
    }

    @Test("Adoption is idempotent and cheap once the folder is drained")
    func secondPassDoesNothing() throws {
        let env = try Environment()
        defer { env.tearDown() }

        try env.writeProfileEntry(named: "aaa.mp3", contents: "one")
        #expect(env.adopt().movedEntries == 1)

        let second = env.adopt()
        #expect(second == SharedDerivedCacheAdoption.Report())
        #expect(env.sharedContents(named: "aaa.mp3") == "one")
    }

    @Test("An older build writing to the per-profile folder self-heals")
    func lateArrivalsAreAdopted() throws {
        let env = try Environment()
        defer { env.tearDown() }

        try env.writeProfileEntry(named: "aaa.mp3", contents: "one")
        #expect(env.adopt().movedEntries == 1)

        // No "already migrated" flag gates this, so an entry that appears later
        // is picked up rather than stranded forever.
        try env.writeProfileEntry(named: "ccc.mp3", contents: "three")
        #expect(env.adopt().movedEntries == 1)
        #expect(env.sharedContents(named: "ccc.mp3") == "three")
    }

    @Test("A missing per-profile folder is a no-op, not a failure")
    func missingSourceIsHarmless() throws {
        let env = try Environment(createProfileCache: false)
        defer { env.tearDown() }

        #expect(env.adopt() == SharedDerivedCacheAdoption.Report())
        // A fresh install has nothing to adopt and should not be made to create
        // a shared folder it may never write to.
        #expect(!FileManager.default.fileExists(atPath: env.sharedCache.path))
    }

    @Test("A cache carrying two extensions moves both")
    func multipleExtensionsAreAdopted() throws {
        // Voice previews are mp3 or m4a depending on the model's response
        // format, so a single hardcoded extension would strand half the folder.
        let env = try Environment()
        defer { env.tearDown() }

        try env.writeProfileEntry(named: "aaa.mp3", contents: "one")
        try env.writeProfileEntry(named: "bbb.m4a", contents: "two")
        try env.writeProfileEntry(named: "ccc.wav", contents: "three")

        let report = SharedDerivedCacheAdoption.adopt(
            profileCache: env.profileCache,
            sharedCache: env.sharedCache,
            fileExtensions: ["mp3", "m4a"]
        )

        #expect(report.movedEntries == 2)
        #expect(env.sharedContents(named: "aaa.mp3") == "one")
        #expect(env.sharedContents(named: "bbb.m4a") == "two")
        #expect(env.profileContents(named: "ccc.wav") == "three")
    }

    @Test("Non-audio entries are ignored")
    func onlyAudioEntriesMove() throws {
        let env = try Environment()
        defer { env.tearDown() }

        try env.writeProfileEntry(named: "aaa.mp3", contents: "one")
        try env.writeProfileEntry(named: "notes.txt", contents: "keep")

        #expect(env.adopt().movedEntries == 1)
        #expect(env.profileContents(named: "notes.txt") == "keep")
        #expect(env.sharedContents(named: "notes.txt") == nil)
    }

    private struct Environment {
        let root: URL
        let profileCache: URL
        let sharedCache: URL

        init(createProfileCache: Bool = true) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("SharedDerivedCacheAdoptionTests-\(UUID().uuidString)", isDirectory: true)
            profileCache = root
                .appendingPathComponent("ForeverLM", isDirectory: true)
                .appendingPathComponent("TTSAudioCache", isDirectory: true)
            sharedCache = root
                .appendingPathComponent("ForeverLM Shared", isDirectory: true)
                .appendingPathComponent("TTSAudioCache", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if createProfileCache {
                try FileManager.default.createDirectory(at: profileCache, withIntermediateDirectories: true)
            }
        }

        func adopt() -> SharedDerivedCacheAdoption.Report {
            SharedDerivedCacheAdoption.adopt(profileCache: profileCache, sharedCache: sharedCache)
        }

        func writeProfileEntry(named name: String, contents: String) throws {
            try contents.write(
                to: profileCache.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        func profileContents(named name: String) -> String? {
            try? String(contentsOf: profileCache.appendingPathComponent(name), encoding: .utf8)
        }

        func sharedContents(named name: String) -> String? {
            try? String(contentsOf: sharedCache.appendingPathComponent(name), encoding: .utf8)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
