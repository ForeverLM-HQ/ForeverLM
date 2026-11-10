import Foundation
import OSLog

/// One-time move of the retired FeynmanLM on-disk identity into ForeverLM.
///
/// The product rename changed Application Support, the ubiquity container,
/// UserDefaults suite, app group, and Keychain service in the same commit and
/// did not adopt the previous locations. A launch after that commit created a
/// second empty library beside the real one. This is a move, not a dual-read
/// alias: after it runs, only ForeverLM names are used.
enum LegacyIdentityAdoption {
    static let retiredProductFolderName = "FeynmanLM"
    static let retiredDefaultsSuite = "com.feynmanlm"
    static let retiredAppGroup = "group.com.feynmanlm.shared"
    static let retiredUbiquityContainerDirName = "iCloud~com~feynmanlm"
    static let retiredKeychainService = "com.feynmanlm"
    static let retiredKeychainVaultAccount = "__feynmanlm_keychain_vault_v1"

    static let currentProductFolderName = "ForeverLM"
    static let currentDefaultsSuite = "com.foreverlm"
    static let currentAppGroup = "group.com.foreverlm"
    static let currentUbiquityContainerDirName = "iCloud~com~foreverlm"

    private static let defaultsCopiedKey = "LegacyIdentityAdoption.copiedRetiredDefaults.v1"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "StorageMigration"
    )

    struct Locations: Equatable, Sendable {
        var currentAppSupport: URL
        var retiredAppSupport: URL
        var currentAppGroup: URL?
        var retiredAppGroup: URL?
        var currentDefaultsSuite: String
        var retiredDefaultsSuite: String
    }

    struct Report: Equatable, Sendable {
        var movedAppSupport = false
        var preservedCurrentStub: String?
        var skippedBecauseCurrentLibraryExists = false
        var copiedDefaultsKeys = 0
        var copiedAppGroupInbox = false
    }

    static var isRunningAutomatedTests: Bool {
        let process = ProcessInfo.processInfo
        if process.environment["XCTestConfigurationFilePath"] != nil { return true }
        if process.arguments.contains(where: { $0.contains("xctest") }) { return true }
        if Bundle.main.bundlePath.hasSuffix(".xctest") { return true }
        return false
    }

    static func productionLocations(fileManager: FileManager = .default) -> Locations {
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory()
        let appSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let groupParent = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
        return Locations(
            currentAppSupport: appSupport.appendingPathComponent(currentProductFolderName, isDirectory: true),
            retiredAppSupport: appSupport.appendingPathComponent(retiredProductFolderName, isDirectory: true),
            currentAppGroup: fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: currentAppGroup
            ) ?? groupParent.appendingPathComponent(currentAppGroup, isDirectory: true),
            retiredAppGroup: fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: retiredAppGroup
            ) ?? groupParent.appendingPathComponent(retiredAppGroup, isDirectory: true),
            currentDefaultsSuite: currentDefaultsSuite,
            retiredDefaultsSuite: retiredDefaultsSuite
        )
    }

    /// Production entry point. Tests call `adopt(locations:)` directly so they
    /// never touch the developer's library.
    static func adoptIfNeeded() {
        // The development app is a deliberately separate library. Letting it
        // run the production rename adopter could move the daily app's real
        // database into the Dev folder on first launch.
        guard !ForeverLMRuntimeIdentity.isDevelopment,
              !isRunningAutomatedTests else { return }
        let report = adopt(locations: productionLocations())
        if report.movedAppSupport {
            logger.notice("Adopted retired FeynmanLM Application Support into ForeverLM")
        } else if report.skippedBecauseCurrentLibraryExists {
            logger.info("ForeverLM library already present; left retired FeynmanLM Application Support untouched")
        }
        if report.copiedDefaultsKeys > 0 {
            logger.notice("Copied \(report.copiedDefaultsKeys) retired FeynmanLM preference keys")
        }
        if report.copiedAppGroupInbox {
            logger.notice("Copied retired FeynmanLM share inbox into the ForeverLM app group")
        }
    }

    @discardableResult
    static func adopt(
        locations: Locations,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Report {
        var report = Report()
        adoptApplicationSupport(
            locations: locations,
            fileManager: fileManager,
            report: &report
        )
        report.copiedDefaultsKeys = copyMissingDefaults(
            from: locations.retiredDefaultsSuite,
            into: defaults,
            alreadyCopiedKey: defaultsCopiedKey
        )
        report.copiedAppGroupInbox = copyAppGroupInbox(
            from: locations.retiredAppGroup,
            to: locations.currentAppGroup,
            fileManager: fileManager
        )
        return report
    }

    static func hasKnowledgeDatabase(at appSupportRoot: URL, fileManager: FileManager = .default) -> Bool {
        let db = appSupportRoot
            .appendingPathComponent(".appdata", isDirectory: true)
            .appendingPathComponent("knowledge.db")
        guard fileManager.fileExists(atPath: db.path) else { return false }
        let size = (try? fileManager.attributesOfItem(atPath: db.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0
    }

    private static func adoptApplicationSupport(
        locations: Locations,
        fileManager: FileManager,
        report: inout Report
    ) {
        let current = locations.currentAppSupport
        let retired = locations.retiredAppSupport
        guard hasKnowledgeDatabase(at: retired, fileManager: fileManager) else { return }

        if hasKnowledgeDatabase(at: current, fileManager: fileManager) {
            report.skippedBecauseCurrentLibraryExists = true
            return
        }

        if fileManager.fileExists(atPath: current.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let asideName = "ForeverLM-empty-stub-\(stamp)"
            let aside = current.deletingLastPathComponent().appendingPathComponent(asideName, isDirectory: true)
            do {
                try fileManager.moveItem(at: current, to: aside)
                report.preservedCurrentStub = aside.lastPathComponent
            } catch {
                logger.error(
                    "Could not move empty ForeverLM stub aside: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }

        do {
            try fileManager.moveItem(at: retired, to: current)
            report.movedAppSupport = true
        } catch {
            logger.error(
                "Could not adopt FeynmanLM Application Support: \(error.localizedDescription, privacy: .public)"
            )
            if let stub = report.preservedCurrentStub {
                let aside = current.deletingLastPathComponent().appendingPathComponent(stub, isDirectory: true)
                try? fileManager.moveItem(at: aside, to: current)
            }
            report.preservedCurrentStub = nil
        }
    }

    static func copyMissingDefaults(
        from retiredSuite: String,
        into defaults: UserDefaults,
        alreadyCopiedKey: String
    ) -> Int {
        if defaults.bool(forKey: alreadyCopiedKey) { return 0 }
        guard let retired = UserDefaults(suiteName: retiredSuite),
              let domain = retired.persistentDomain(forName: retiredSuite) else {
            defaults.set(true, forKey: alreadyCopiedKey)
            return 0
        }

        var copied = 0
        for (key, value) in domain {
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
        }
        defaults.set(true, forKey: alreadyCopiedKey)
        return copied
    }

    private static func copyAppGroupInbox(
        from retiredGroup: URL?,
        to currentGroup: URL?,
        fileManager: FileManager
    ) -> Bool {
        guard let retiredGroup, let currentGroup else { return false }
        let inboxName = "mobile-share-inbox.sqlite"
        let source = retiredGroup.appendingPathComponent(inboxName)
        let destination = currentGroup.appendingPathComponent(inboxName)
        guard fileManager.fileExists(atPath: source.path) else { return false }
        if fileManager.fileExists(atPath: destination.path) { return false }
        do {
            try fileManager.createDirectory(at: currentGroup, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            return true
        } catch {
            logger.error(
                "Could not copy retired share inbox: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

// MARK: - Retired method-name preference keys

extension LegacyIdentityAdoption {
    private static let retiredMethodKeysAdoptedMarker = "foreverlm.retiredMethodPreferenceKeysAdopted.v1"

    /// Schema 98 dropped the method name from two `AITask` raw values and one
    /// iOS grader key. Model choices live in `UserDefaults` under those raw
    /// values, so a learner's chosen chat model would otherwise reset to the
    /// default on the first launch of this build. Moved once, here, on both
    /// platforms; the old keys are removed so nothing reads them again.
    static func adoptRetiredMethodPreferenceKeysIfNeeded(
        defaults: UserDefaults = .standard
    ) -> Int {
        guard !defaults.bool(forKey: retiredMethodKeysAdoptedMarker) else { return 0 }
        var moves: [(String, String)] = [("feynman.grader.v1", "foreverlm.grader.v1")]
        for (old, new) in [("feynman_quiz", "chat"), ("mobile_feynman_review", "mobile_review")] {
            moves.append(("aiRoute.task.\(old)", "aiRoute.task.\(new)"))
            for suffix in ["provider", "model", "effort", "speed"] {
                moves.append(("aiTask.\(old).\(suffix)", "aiTask.\(new).\(suffix)"))
            }
        }
        var moved = 0
        for (old, new) in moves {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil {
                defaults.set(value, forKey: new)
                moved += 1
            }
            defaults.removeObject(forKey: old)
        }
        defaults.set(true, forKey: retiredMethodKeysAdoptedMarker)
        return moved
    }
}

// MARK: - Retired notebook-name preference keys

extension LegacyIdentityAdoption {
    private static let retiredNotebookKeysAdoptedMarker = "foreverlm.retiredNotebookPreferenceKeysAdopted.v1"

    /// A notebook was called a project until 2026-10-04. Two device-local
    /// preferences carried the word in their keys (which notebook this Mac's
    /// own MCP endpoint serves, which notebook Screen record mode films), so a
    /// learner's choice would reset on the first launch of this build. Moved
    /// once, here; the old keys are removed so nothing reads them again. The
    /// synced `studio.projectOrder` and `studio.navigation.expandedProjectIDs.v1`
    /// keep their names: they are keys of the generation-2 settings catalog.
    /// The device-local keys that carried the retired word, as `(old, new)`.
    static let retiredNotebookPreferenceKeys: [(old: String, new: String)] = [
        ("studio.activeMCPProjectID", "studio.activeMCPNotebookID"),
        ("screenRecordMode.projectID", "screenRecordMode.notebookID"),
    ]

    @discardableResult
    static func adoptRetiredNotebookPreferenceKeysIfNeeded(
        defaults: UserDefaults = .standard
    ) -> Int {
        guard !defaults.bool(forKey: retiredNotebookKeysAdoptedMarker) else { return 0 }
        var moved = 0
        for (old, new) in retiredNotebookPreferenceKeys {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil {
                defaults.set(value, forKey: new)
                moved += 1
            }
            defaults.removeObject(forKey: old)
        }
        defaults.set(true, forKey: retiredNotebookKeysAdoptedMarker)
        return moved
    }
}
