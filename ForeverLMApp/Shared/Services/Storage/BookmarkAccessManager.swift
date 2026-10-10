#if os(macOS)
import Foundation
import os

/// Resolves security-scoped bookmarks saved by older builds for TCC-protected
/// files. New builds use Full Disk Access and never request folder grants.
///
/// Thread-safe (not `@MainActor`): resolving security-scoped bookmarks does
/// filesystem / TCC work, which must never run on the main actor (it
/// beachballs). `activeResources` is guarded by `resourcesLock` so resolve/stop
/// are safe from any executor.
final class BookmarkAccessManager: @unchecked Sendable {
    static let shared = BookmarkAccessManager()

    private let logger = Logger(subsystem: "com.foreverlm", category: "BookmarkAccess")

    enum BookmarkKey: String, CaseIterable, Sendable {
        /// Legacy bookmark keys remain readable so an upgrade does not revoke
        /// access that the user previously granted.
        case appDataLibrary = "securityBookmark_appDataLibrary"
        case safariBookmarks = "securityBookmark_safariBookmarks"
        case podcastsContainer = "securityBookmark_podcastsContainer"
        case chromeData = "securityBookmark_chromeData"
        case braveData = "securityBookmark_braveData"
    }

    /// URLs currently being accessed via startAccessingSecurityScopedResource.
    /// Guarded by `resourcesLock` so resolve/stop can run off the main actor.
    private let resourcesLock = NSLock()
    private var activeResources: [BookmarkKey: URL] = [:]

    private func recordActiveResource(_ url: URL, for key: BookmarkKey) {
        resourcesLock.lock()
        defer { resourcesLock.unlock() }
        activeResources[key] = url
    }

    private func activeResource(for key: BookmarkKey) -> URL? {
        resourcesLock.lock()
        defer { resourcesLock.unlock() }
        return activeResources[key]
    }

    private func removeActiveResource(for key: BookmarkKey) -> URL? {
        resourcesLock.lock()
        defer { resourcesLock.unlock() }
        return activeResources.removeValue(forKey: key)
    }

    // MARK: - Public API

    /// Whether a stored bookmark exists and can be resolved.
    func hasAccess(for key: BookmarkKey) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else {
            return false
        }

        var isStale: ObjCBool = false
        do {
            let url = try NSURL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) as URL

            if isStale.boolValue {
                logger.info("Bookmark stale for \(key.rawValue), refreshing")
                if let refreshed = try? (url as NSURL).bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(refreshed, forKey: key.rawValue)
                }
            }
            return true
        } catch {
            logger.warning("[\(key.rawValue)] Access check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Resolve a stored bookmark. Returns the URL with security scope started,
    /// or nil if no bookmark or resolution fails. Caller must call `stopAccessing`
    /// when done.
    @discardableResult
    func resolveBookmark(for key: BookmarkKey) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else {
            logger.info("[\(key.rawValue)] No bookmark data in UserDefaults")
            return nil
        }

        logger.info("[\(key.rawValue)] Bookmark data found (\(data.count) bytes)")

        var isStale: ObjCBool = false
        do {
            let url = try NSURL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) as URL

            logger.info("[\(key.rawValue)] Resolved to: \(url.path) (stale=\(isStale.boolValue))")

            if isStale.boolValue {
                logger.info("Bookmark stale for \(key.rawValue), refreshing")
                if let refreshed = try? (url as NSURL).bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(refreshed, forKey: key.rawValue)
                }
            }

            let started = url.startAccessingSecurityScopedResource()
            logger.info("[\(key.rawValue)] startAccessingSecurityScopedResource = \(started)")

            guard started else {
                // If already accessing (e.g. double-resolve), the URL may still be usable
                logger.warning("[\(key.rawValue)] startAccessing failed — checking if already active")
                if let existing = activeResource(for: key), existing.path == url.path {
                    logger.info("[\(key.rawValue)] Already active, returning existing URL")
                    return existing
                }
                return nil
            }

            recordActiveResource(url, for: key)
            return url
        } catch {
            logger.warning("[\(key.rawValue)] Resolution failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Stop accessing the security-scoped resource.
    func stopAccessing(for key: BookmarkKey) {
        if let url = removeActiveResource(for: key) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Diagnostic: test bookmark end-to-end by resolving, accessing, and reading a file.
    func diagnose(for key: BookmarkKey) {
        logger.info("=== BOOKMARK DIAGNOSTIC: \(key.rawValue) ===")
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else {
            logger.error("DIAG: No bookmark data stored")
            return
        }
        logger.info("DIAG: Bookmark data = \(data.count) bytes")

        var isStale: ObjCBool = false
        do {
            let url = try NSURL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) as URL
            logger.info("DIAG: Resolved URL = \(url.path)")
            logger.info("DIAG: Stale = \(isStale.boolValue)")

            let started = url.startAccessingSecurityScopedResource()
            logger.info("DIAG: startAccessing = \(started)")

            let fm = FileManager.default
            logger.info("DIAG: Directory exists = \(fm.fileExists(atPath: url.path))")

            if key == .appDataLibrary {
                logger.info("DIAG: Library readable = \(fm.isReadableFile(atPath: url.path))")
            } else if key == .podcastsContainer {
                let dbPath = url.appendingPathComponent("Documents/MTLibrary.sqlite").path
                logger.info("DIAG: DB exists = \(fm.fileExists(atPath: dbPath))")
                let ttmlDir = url.appendingPathComponent("Library/Cache/Assets/TTML").path
                logger.info("DIAG: TTML dir exists = \(fm.fileExists(atPath: ttmlDir))")
                if fm.fileExists(atPath: dbPath) {
                    let readable = fm.isReadableFile(atPath: dbPath)
                    logger.info("DIAG: DB readable = \(readable)")
                    if let dbData = fm.contents(atPath: dbPath) {
                        logger.info("DIAG: DB read OK (\(dbData.count) bytes)")
                    } else {
                        logger.error("DIAG: DB read FAILED")
                    }
                }
            } else if key == .safariBookmarks {
                let plistPath = url.appendingPathComponent("Bookmarks.plist").path
                logger.info("DIAG: Plist exists = \(fm.fileExists(atPath: plistPath))")
            }

            if started {
                url.stopAccessingSecurityScopedResource()
            }
        } catch {
            logger.error("DIAG: Resolution error: \(error)")
        }
        logger.info("=== END DIAGNOSTIC ===")
    }

    /// Remove a stored bookmark.
    func revokeAccess(for key: BookmarkKey) {
        stopAccessing(for: key)
        UserDefaults.standard.removeObject(forKey: key.rawValue)
    }

    // MARK: - Helpers

    /// The real user home directory (not the sandbox container).
    static var realHomeDirectory: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }
}
#endif
