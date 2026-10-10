import Foundation
import Testing
@testable import ForeverLM

@Suite("Runtime identity isolation")
struct ForeverLMRuntimeIdentityTests {
    @Test("Development and production have disjoint mutable identities")
    func mutableIdentitiesAreDisjoint() {
        let production = ForeverLMRuntimeIdentity.profile(isDevelopment: false)
        let development = ForeverLMRuntimeIdentity.profile(isDevelopment: true)

        #expect(production.displayName == "ForeverLM")
        #expect(development.displayName == "ForeverLM (Dev)")
        #expect(production.productFolderName != development.productFolderName)
        #expect(production.urlScheme != development.urlScheme)
        #expect(production.keychainService != development.keychainService)
        #expect(production.keychainVaultAccount != development.keychainVaultAccount)
        #expect(production.keychainAccessGroupSuffix != development.keychainAccessGroupSuffix)
        #expect(production.mcpLoopbackPort != development.mcpLoopbackPort)
    }

    @Test("The First Run app shares no mutable identity with Dev or production")
    func firstRunIdentityIsDisjoint() {
        let firstRun = ForeverLMRuntimeIdentity.profile(isDevelopment: true, isFirstRun: true)
        let others = [
            ForeverLMRuntimeIdentity.profile(isDevelopment: false),
            ForeverLMRuntimeIdentity.profile(isDevelopment: true),
        ]

        #expect(firstRun.isDevelopment)
        #expect(firstRun.isFirstRun)
        #expect(firstRun.productFolderName == "ForeverLM First Run")
        for other in others {
            #expect(!other.isFirstRun)
            #expect(firstRun.productFolderName != other.productFolderName)
            #expect(firstRun.urlScheme != other.urlScheme)
            #expect(firstRun.keychainService != other.keychainService)
            #expect(firstRun.keychainVaultAccount != other.keychainVaultAccount)
            #expect(firstRun.keychainAccessGroupSuffix != other.keychainAccessGroupSuffix)
            #expect(firstRun.mcpLoopbackPort != other.mcpLoopbackPort)
        }
    }
}

@Suite("Legacy FeynmanLM identity adoption")
struct LegacyIdentityAdoptionTests {
    @Test("Retired Doc links are adopted without changing prose or unrelated URLs")
    func retiredDocLinksAreAdopted() {
        let markdown = """
        [Named](feynmanlm://source/src_1)
        [Attached]( <feynmanlm://grounding/src_1,book:book_2>)
        ![Image](feynmanlm://attachment/image.png)

        A prose example says feynmanlm://source/src_example.
        [Website](https://feynmanlm.com/source/src_web)
        [Unknown](feynmanlm://other/value)
        """

        let adopted = LegacyIdentityAdoption.adoptingRetiredArtifactLinks(in: markdown)

        #expect(adopted.contains("[Named](foreverlm://source/src_1)"))
        #expect(adopted.contains("[Attached]( <foreverlm://grounding/src_1,book:book_2>)"))
        #expect(adopted.contains("![Image](foreverlm://attachment/image.png)"))
        #expect(adopted.contains("prose example says feynmanlm://source/src_example"))
        #expect(adopted.contains("[Website](https://feynmanlm.com/source/src_web)"))
        #expect(adopted.contains("[Unknown](feynmanlm://other/value)"))
    }

    @Test("Moves a retired library when ForeverLM has no knowledge database")
    func movesRetiredLibraryWhenCurrentIsMissing() throws {
        let env = try Sandbox()
        defer { env.tearDown() }

        try env.writeKnowledgeDatabase(at: env.retiredAppSupport, contents: "legacy-library")
        try env.writeFile(
            at: env.retiredAppSupport.appendingPathComponent("Content/Papers/a.pdf"),
            contents: "pdf"
        )

        let report = LegacyIdentityAdoption.adopt(locations: env.locations, defaults: env.defaults)

        #expect(report.movedAppSupport)
        #expect(!report.skippedBecauseCurrentLibraryExists)
        #expect(LegacyIdentityAdoption.hasKnowledgeDatabase(at: env.currentAppSupport))
        #expect(!FileManager.default.fileExists(atPath: env.retiredAppSupport.path))
        #expect(try env.read(env.currentAppSupport.appendingPathComponent("Content/Papers/a.pdf")) == "pdf")
        #expect(try env.read(env.currentAppSupport.appendingPathComponent(".appdata/knowledge.db")) == "legacy-library")
    }

    @Test("Moves a retired library over an empty ForeverLM stub")
    func movesRetiredLibraryOverEmptyStub() throws {
        let env = try Sandbox()
        defer { env.tearDown() }

        try FileManager.default.createDirectory(at: env.currentAppSupport, withIntermediateDirectories: true)
        try env.writeFile(
            at: env.currentAppSupport.appendingPathComponent("Diagnostics/note.txt"),
            contents: "stub"
        )
        try env.writeKnowledgeDatabase(at: env.retiredAppSupport, contents: "legacy-library")

        let report = LegacyIdentityAdoption.adopt(locations: env.locations, defaults: env.defaults)

        #expect(report.movedAppSupport)
        #expect(report.preservedCurrentStub != nil)
        #expect(LegacyIdentityAdoption.hasKnowledgeDatabase(at: env.currentAppSupport))
        #expect(try env.read(env.currentAppSupport.appendingPathComponent(".appdata/knowledge.db")) == "legacy-library")
        if let stub = report.preservedCurrentStub {
            let aside = env.currentAppSupport.deletingLastPathComponent().appendingPathComponent(stub)
            #expect(try env.read(aside.appendingPathComponent("Diagnostics/note.txt")) == "stub")
        }
    }

    @Test("Does not overwrite a real ForeverLM library")
    func leavesBothLibrariesWhenBothHaveDatabases() throws {
        let env = try Sandbox()
        defer { env.tearDown() }

        try env.writeKnowledgeDatabase(at: env.currentAppSupport, contents: "current-library")
        try env.writeKnowledgeDatabase(at: env.retiredAppSupport, contents: "legacy-library")

        let report = LegacyIdentityAdoption.adopt(locations: env.locations, defaults: env.defaults)

        #expect(!report.movedAppSupport)
        #expect(report.skippedBecauseCurrentLibraryExists)
        #expect(try env.read(env.currentAppSupport.appendingPathComponent(".appdata/knowledge.db")) == "current-library")
        #expect(try env.read(env.retiredAppSupport.appendingPathComponent(".appdata/knowledge.db")) == "legacy-library")
    }

    @Test("Copies missing UserDefaults keys from the retired suite once")
    func copiesMissingDefaultsOnce() throws {
        let env = try Sandbox()
        defer { env.tearDown() }

        let retired = try #require(UserDefaults(suiteName: env.retiredSuite))
        retired.set("from-legacy", forKey: "onlyInLegacy")
        retired.set("legacy-zoom", forKey: "uiZoomStep")
        env.defaults.set("current-zoom", forKey: "uiZoomStep")

        let first = LegacyIdentityAdoption.adopt(locations: env.locations, defaults: env.defaults)
        #expect(first.copiedDefaultsKeys == 1)
        #expect(env.defaults.string(forKey: "onlyInLegacy") == "from-legacy")
        #expect(env.defaults.string(forKey: "uiZoomStep") == "current-zoom")

        retired.set("later", forKey: "addedAfterCopy")
        let second = LegacyIdentityAdoption.adopt(locations: env.locations, defaults: env.defaults)
        #expect(second.copiedDefaultsKeys == 0)
        #expect(env.defaults.string(forKey: "addedAfterCopy") == nil)
    }

    @Test("Copies the share inbox when the current app group does not have one")
    func copiesShareInbox() throws {
        let env = try Sandbox()
        defer { env.tearDown() }

        try env.writeFile(
            at: env.retiredAppGroup.appendingPathComponent("mobile-share-inbox.sqlite"),
            contents: "inbox"
        )

        let report = LegacyIdentityAdoption.adopt(locations: env.locations, defaults: env.defaults)
        #expect(report.copiedAppGroupInbox)
        #expect(try env.read(env.currentAppGroup.appendingPathComponent("mobile-share-inbox.sqlite")) == "inbox")

        let second = LegacyIdentityAdoption.adopt(locations: env.locations, defaults: env.defaults)
        #expect(!second.copiedAppGroupInbox)
    }

    @Test("Content roots drop the drained container but keep the reachable ones")
    func knownContentRootsDropRetiredContainerOnly() {
        let roots = StorageService.knownContentRoots

        // `~/Documents` is never a root: with Desktop & Documents syncing it is
        // the CloudDocs `Documents` already listed, without it nothing synced
        // there, and every lookup under it costs a TCC prompt.
        let realDocuments = (NSHomeDirectory() as NSString).appendingPathComponent("Documents") + "/"
        #expect(!roots.contains { $0.hasPrefix(realDocuments) })

        if ForeverLMRuntimeIdentity.isDevelopment {
            #expect(roots.allSatisfy { $0.contains("ForeverLM Dev") })
            #expect(!roots.contains { $0.contains("/ForeverLM/") })
            #expect(!roots.contains { $0.contains("FeynmanLM") })
            #expect(roots.first == StorageService.libraryRootPath)
            return
        }

        // The retired container is drained and its Documents is empty, so these
        // could only ever be a stat that misses.
        #expect(!roots.contains { $0.contains("iCloud~com~feynmanlm") })

        // Everything a file can still legitimately be sitting in stays searchable:
        // an iCloud Drive fork or manual move under either product name, and the
        // pre-rename Application Support content directory.
        #expect(roots.contains { $0.hasSuffix("FeynmanLM/Content") })
        #expect(roots.contains { $0.hasSuffix("com~apple~CloudDocs/Documents/FeynmanLM") })
        #expect(roots.contains { $0.hasSuffix("Documents/FeynmanLM") })
        #expect(roots.first == StorageService.libraryRootPath)
    }

    @Test("CloudKit rebases when the container identifier changes")
    func cloudKitRebasesOnContainerRename() {
        #expect(
            CloudKitSyncEngine.needsReplicaRebase(
                previousEnvironment: "production",
                currentEnvironment: "production",
                previousContainer: "iCloud.com.feynmanlm",
                currentContainer: "iCloud.com.foreverlm"
            )
        )
        #expect(
            !CloudKitSyncEngine.needsReplicaRebase(
                previousEnvironment: "production",
                currentEnvironment: "production",
                previousContainer: "iCloud.com.foreverlm",
                currentContainer: "iCloud.com.foreverlm"
            )
        )
        #expect(
            CloudKitSyncEngine.needsReplicaRebase(
                previousEnvironment: "production",
                currentEnvironment: "production",
                previousContainer: nil,
                currentContainer: "iCloud.com.foreverlm"
            )
        )
    }

    @Test("A zero-byte knowledge.db does not count as a real library")
    func ignoresEmptyDatabaseFile() throws {
        let env = try Sandbox()
        defer { env.tearDown() }

        try FileManager.default.createDirectory(
            at: env.currentAppSupport.appendingPathComponent(".appdata", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(
            to: env.currentAppSupport.appendingPathComponent(".appdata/knowledge.db")
        )
        try env.writeKnowledgeDatabase(at: env.retiredAppSupport, contents: "legacy-library")

        let report = LegacyIdentityAdoption.adopt(locations: env.locations, defaults: env.defaults)
        #expect(report.movedAppSupport)
        #expect(try env.read(env.currentAppSupport.appendingPathComponent(".appdata/knowledge.db")) == "legacy-library")
    }

    private struct Sandbox {
        let root: URL
        let currentAppSupport: URL
        let retiredAppSupport: URL
        let currentAppGroup: URL
        let retiredAppGroup: URL
        let retiredSuite: String
        let defaultsSuite: String
        let defaults: UserDefaults
        let locations: LegacyIdentityAdoption.Locations

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("legacy-identity-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            currentAppSupport = root.appendingPathComponent("ForeverLM", isDirectory: true)
            retiredAppSupport = root.appendingPathComponent("FeynmanLM", isDirectory: true)
            currentAppGroup = root.appendingPathComponent("group.com.foreverlm", isDirectory: true)
            retiredAppGroup = root.appendingPathComponent("group.com.feynmanlm.shared", isDirectory: true)
            retiredSuite = "legacy.identity.retired.\(UUID().uuidString)"
            defaultsSuite = "legacy.identity.current.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
                throw CocoaError(.fileNoSuchFile)
            }
            self.defaults = defaults
            locations = LegacyIdentityAdoption.Locations(
                currentAppSupport: currentAppSupport,
                retiredAppSupport: retiredAppSupport,
                currentAppGroup: currentAppGroup,
                retiredAppGroup: retiredAppGroup,
                currentDefaultsSuite: defaultsSuite,
                retiredDefaultsSuite: retiredSuite
            )
            self.root = root
        }

        func writeKnowledgeDatabase(at appSupport: URL, contents: String) throws {
            try writeFile(
                at: appSupport.appendingPathComponent(".appdata/knowledge.db"),
                contents: contents
            )
        }

        func writeFile(at url: URL, contents: String) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }

        func read(_ url: URL) throws -> String {
            String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: defaultsSuite)
            UserDefaults(suiteName: retiredSuite)?.removePersistentDomain(forName: retiredSuite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
