import Foundation

extension Notification.Name {
    static let legacyContentDidMigrate = Notification.Name("LegacyContentDidMigrate")
}

/// One historical content tree to drain into the canonical local root. The
/// canonical private-container root is retained because `Audio/` deliberately
/// remains there for iPhone transport; numbered forks and all other legacy roots
/// are removed after their last verified file moves.
struct LegacyContentRoot: Sendable, Equatable {
    let id: String
    let url: URL
    let preservesRootForCanonicalAudio: Bool
}

struct LegacyContentConsolidationReport: Sendable, Equatable {
    var installed = 0
    var deduplicated = 0
    var conflictsPreserved = 0
    var pendingDownloads = 0
    var failures: [String] = []
    var removedRoots: [String] = []

    var changedFileCount: Int {
        installed + deduplicated + conflictsPreserved
    }

    var isComplete: Bool {
        pendingDownloads == 0 && failures.isEmpty
    }
}

/// Idempotent, per-file consolidation for content written before ForeverLM
/// moved its canonical bytes out of iCloud Drive. No source is removed until a
/// byte-identical destination exists. A terminated process therefore resumes
/// from the files that remain in the legacy roots without a separate journal.
enum LegacyContentConsolidator {
    private static let recoveryDirectoryName = "Recovered Conflicts"
    private static let stagingSuffix = ".foreverlm-migrating"

    static func consolidate(
        roots: [LegacyContentRoot],
        contentRoot: URL,
        canonicalAudioRoot: URL,
        fileManager: FileManager = .default,
        progress: (@Sendable (LegacyContentConsolidationReport) -> Void)? = nil
    ) -> LegacyContentConsolidationReport {
        var report = LegacyContentConsolidationReport()

        do {
            try fileManager.createDirectory(at: contentRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: canonicalAudioRoot, withIntermediateDirectories: true)
        } catch {
            report.failures.append("Could not create canonical content roots: \(error.localizedDescription)")
            return report
        }

        for root in roots where fileManager.fileExists(atPath: root.url.path) {
            consolidate(
                root: root,
                contentRoot: contentRoot,
                canonicalAudioRoot: canonicalAudioRoot,
                fileManager: fileManager,
                report: &report,
                progress: progress
            )
        }
        return report
    }

    private static func consolidate(
        root: LegacyContentRoot,
        contentRoot: URL,
        canonicalAudioRoot: URL,
        fileManager: FileManager,
        report: inout LegacyContentConsolidationReport,
        progress: (@Sendable (LegacyContentConsolidationReport) -> Void)?
    ) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isDirectoryKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root.url,
            includingPropertiesForKeys: keys,
            // Notebook attachments may be Finder packages (`.pages`, `.key`,
            // etc.). Their descendants are user data too; enumerate the full
            // tree instead of treating packages as opaque directories.
            options: []
        ) else {
            report.failures.append("Could not enumerate \(root.url.path)")
            return
        }

        var directories: [URL] = []
        while let source = enumerator.nextObject() as? URL {
            let relative = relativePath(of: source, below: root.url)
            guard !relative.isEmpty else { continue }

            do {
                let values = try source.resourceValues(forKeys: Set(keys))
                if values.isDirectory == true, values.isSymbolicLink != true {
                    directories.append(source)
                    continue
                }

                if isICloudPlaceholder(source)
                    || values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try? fileManager.startDownloadingUbiquitousItem(at: source)
                    report.pendingDownloads += 1
                    continue
                }

                let route = destinationRoute(
                    relativePath: relative,
                    contentRoot: contentRoot,
                    canonicalAudioRoot: canonicalAudioRoot
                )
                if source.standardizedFileURL.path == route.destination.standardizedFileURL.path {
                    continue
                }

                try install(
                    source: source,
                    destination: route.destination,
                    recoveryRoot: route.recoveryRoot,
                    recoveryNamespace: root.id,
                    relativePath: route.relativePath,
                    fileManager: fileManager,
                    report: &report
                )
                if report.changedFileCount.isMultiple(of: 100) {
                    progress?(report)
                }
            } catch {
                report.failures.append("\(source.path): \(error.localizedDescription)")
            }
        }

        // Children first. A directory is removed only when every file below it
        // has been verified elsewhere; pending downloads and failures therefore
        // keep their ancestry and the root intact for the next event-driven run.
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if isDirectoryEmpty(directory, fileManager: fileManager) {
                try? fileManager.removeItem(at: directory)
            }
        }

        guard !root.preservesRootForCanonicalAudio,
              isDirectoryEmpty(root.url, fileManager: fileManager) else { return }
        do {
            try fileManager.removeItem(at: root.url)
            report.removedRoots.append(root.url.path)
        } catch {
            report.failures.append("Could not remove empty root \(root.url.path): \(error.localizedDescription)")
        }
    }

    private struct DestinationRoute {
        let destination: URL
        let recoveryRoot: URL
        let relativePath: String
    }

    private static func destinationRoute(
        relativePath: String,
        contentRoot: URL,
        canonicalAudioRoot: URL
    ) -> DestinationRoute {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        if components.first == "Audio" {
            let audioRelative = components.dropFirst().joined(separator: "/")
            return DestinationRoute(
                destination: canonicalAudioRoot.appendingPathComponent(audioRelative),
                recoveryRoot: canonicalAudioRoot.appendingPathComponent(recoveryDirectoryName, isDirectory: true),
                relativePath: audioRelative
            )
        }
        return DestinationRoute(
            destination: contentRoot.appendingPathComponent(relativePath),
            recoveryRoot: contentRoot.appendingPathComponent(recoveryDirectoryName, isDirectory: true),
            relativePath: relativePath
        )
    }

    private static func install(
        source: URL,
        destination: URL,
        recoveryRoot: URL,
        recoveryNamespace: String,
        relativePath: String,
        fileManager: FileManager,
        report: inout LegacyContentConsolidationReport
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            if filesAreIdentical(source, destination, fileManager: fileManager) {
                try fileManager.removeItem(at: source)
                report.deduplicated += 1
                return
            }

            let recoveryDestination = availableRecoveryDestination(
                base: recoveryRoot.appendingPathComponent(recoveryNamespace, isDirectory: true),
                relativePath: relativePath,
                source: source,
                fileManager: fileManager
            )
            if fileManager.fileExists(atPath: recoveryDestination.path),
               filesAreIdentical(source, recoveryDestination, fileManager: fileManager) {
                try fileManager.removeItem(at: source)
                report.deduplicated += 1
                return
            }
            try verifiedCopyThenRemove(
                source: source,
                destination: recoveryDestination,
                fileManager: fileManager
            )
            report.conflictsPreserved += 1
            return
        }

        try verifiedCopyThenRemove(source: source, destination: destination, fileManager: fileManager)
        report.installed += 1
    }

    private static func verifiedCopyThenRemove(
        source: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent)\(stagingSuffix)")
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }

        do {
            try fileManager.copyItem(at: source, to: staging)
            guard filesAreIdentical(source, staging, fileManager: fileManager) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            if fileManager.fileExists(atPath: destination.path) {
                // Another writer won the destination race. Keep its bytes when
                // identical; otherwise leave both source and staging untouched
                // for the caller's next collision-preserving pass.
                guard filesAreIdentical(source, destination, fileManager: fileManager) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try fileManager.removeItem(at: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            try fileManager.removeItem(at: source)
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
            throw error
        }
    }

    private static func availableRecoveryDestination(
        base: URL,
        relativePath: String,
        source: URL,
        fileManager: FileManager
    ) -> URL {
        let preferred = base.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        if filesAreIdentical(source, preferred, fileManager: fileManager) { return preferred }

        let directory = preferred.deletingLastPathComponent()
        let extensionName = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = extensionName.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(extensionName)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path)
                || filesAreIdentical(source, candidate, fileManager: fileManager) {
                return candidate
            }
            index += 1
        }
    }

    private static func filesAreIdentical(
        _ lhs: URL,
        _ rhs: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let lhsSize = try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let rhsSize = try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              lhsSize == rhsSize else { return false }
        return fileManager.contentsEqual(atPath: lhs.path, andPath: rhs.path)
    }

    private static func relativePath(of url: URL, below root: URL) -> String {
        let path = url.standardizedFileURL.path
        // `~/Documents` may itself be a OneDrive/iCloud Drive symlink. A
        // FileManager enumerator returns children under the resolved target,
        // while the configured root retains the symlink spelling; accept both
        // lexical forms or the whole historical tree is silently skipped.
        let rootPaths = [
            root.standardizedFileURL.path,
            root.resolvingSymlinksInPath().standardizedFileURL.path,
        ]
        for rootPath in rootPaths where path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return ""
    }

    private static func isICloudPlaceholder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") && name.hasSuffix(".icloud")
    }

    private static func isDirectoryEmpty(_ url: URL, fileManager: FileManager) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(atPath: url.path) else { return false }
        return children.isEmpty
    }
}
