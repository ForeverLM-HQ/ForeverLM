import Foundation
import OSLog

// A page's earlier bodies, kept on this Mac only: ChatGPT's version history
// for a page (docs/docs-design.md, "Version history"; the product owner, 2026-10-06:
// "make sure the docs etc work equally nicely and have feature parity").
//
// Each version is the body as it stood just before something replaced it,
// in a file of its own under the library's `.appdata/PageHistory/<page id>/`,
// beside `knowledge.db`: outside the page's folder, whose files the sync
// engine fingerprints and sends, and outside anything iCloud or CloudKit
// carries. Another Mac keeps its own. The file's name is the version: when
// the body was replaced, in milliseconds since 1970, and why
// (`1791345600123-learnerEdit.md`), so a listing needs no index to keep in
// step. Foundation only, so the policy runs in a test without the app.

/// What was about to replace the body a version keeps.
enum PageVersionReason: String, CaseIterable, Sendable {
    /// The learner's own typing: kept at most once every ten minutes.
    case learnerEdit
    /// An assistant's write — `write_doc`, `edit_doc`, a chat's tools, Edit on
    /// the page kept — always kept.
    case assistantEdit
    /// A body from another device, through sync, replacing this Mac's or
    /// merged into it: kept as typing is, since sync never drops what this Mac
    /// wrote that the server does not hold.
    case anotherDevice
    /// The learner restoring an earlier version: always kept, so a restore is
    /// undone from the same list.
    case restore

    /// Whose change followed the version, as the history's row says it.
    var summary: String {
        switch self {
        case .learnerEdit: return "You"
        case .assistantEdit: return "Before an AI edit"
        case .anotherDevice: return "Before a change from another device"
        case .restore: return "Before restoring an earlier version"
        }
    }
}

/// One kept body, named by its file.
struct PageVersion: Identifiable, Hashable, Sendable {
    /// The file's name, which is the version's identity.
    let id: String
    /// When the body stopped being the page's.
    let savedAt: Date
    let reason: PageVersionReason
}

/// When a body is kept and which versions go: pure, so the tests read it.
enum PageVersionPolicy {
    /// Typing keeps the body it replaces once the newest version is this old.
    static let learnerEditInterval: TimeInterval = 10 * 60
    static let maximumVersionsPerPage = 100
    /// A page's versions together; a body may be 5 MB, and a hundred of those
    /// is more than a history is worth. The newest version is kept whatever
    /// its size.
    static let maximumBytesPerPage = 50 * 1_024 * 1_024

    /// Whether `old`, about to be replaced by `new` for `reason`, is kept. An
    /// unchanged or empty body never is. An assistant's edit and a restore
    /// always are; typing and another device's body when the newest version is
    /// ten minutes old or there is none, or when the page loses more than half
    /// its text at once.
    static func keepsVersion(
        old: String,
        new: String,
        reason: PageVersionReason,
        newestVersionAt: Date?,
        now: Date
    ) -> Bool {
        guard old != new,
              !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch reason {
        case .assistantEdit, .restore:
            return true
        case .learnerEdit, .anotherDevice:
            if shrinksByMoreThanHalf(old: old, new: new) { return true }
            guard let newestVersionAt else { return true }
            return now.timeIntervalSince(newestVersionAt) >= learnerEditInterval
        }
    }

    static func shrinksByMoreThanHalf(old: String, new: String) -> Bool {
        new.utf8.count * 2 < old.utf8.count
    }

    /// The versions a page no longer keeps, oldest last: past the newest
    /// `maximumCount`, or past `maximumBytes` counted from the newest. The
    /// newest version always stays.
    static func versionsToDrop(
        _ versions: [PageVersion],
        byteCounts: [String: Int],
        maximumCount: Int = maximumVersionsPerPage,
        maximumBytes: Int = maximumBytesPerPage
    ) -> [PageVersion] {
        let newestFirst = sortedNewestFirst(versions)
        var kept = 0
        var bytes = 0
        var dropped: [PageVersion] = []
        for version in newestFirst {
            let size = byteCounts[version.id] ?? 0
            if kept == 0 || (kept < maximumCount && bytes + size <= maximumBytes) {
                kept += 1
                bytes += size
            } else {
                dropped.append(version)
            }
        }
        return dropped
    }

    static func sortedNewestFirst(_ versions: [PageVersion]) -> [PageVersion] {
        versions.sorted { lhs, rhs in
            lhs.savedAt != rhs.savedAt ? lhs.savedAt > rhs.savedAt : lhs.id > rhs.id
        }
    }

    static func fileName(savedAt: Date, reason: PageVersionReason) -> String {
        "\(Int64((savedAt.timeIntervalSince1970 * 1_000).rounded()))-\(reason.rawValue).md"
    }

    /// The version a file's name describes; nil for anything else in the folder.
    static func version(fileName: String) -> PageVersion? {
        guard fileName.hasSuffix(".md") else { return nil }
        let stem = fileName.dropLast(3)
        guard let dash = stem.firstIndex(of: "-"),
              let milliseconds = Int64(stem[..<dash]),
              let reason = PageVersionReason(rawValue: String(stem[stem.index(after: dash)...])) else { return nil }
        return PageVersion(
            id: fileName,
            savedAt: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000),
            reason: reason
        )
    }
}

/// A version's day and time as the history lists it: "Today 22:41",
/// "Yesterday 21:10", "3 Oct 09:05", with the year once it is another year's.
enum PageVersionLabel {
    static func when(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(clock)"
        }
        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        day.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return "\(day.string(from: date)) \(clock)"
    }
}

/// The folder of every page's versions on this Mac, and what it keeps.
/// Every call that a write passes through logs and swallows its own failure:
/// a version is a convenience, and a page's save never waits on it or fails
/// for it.
struct PageVersionHistory: Sendable {
    static let folderName = "PageHistory"

    let rootDirectory: URL

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "PageVersionHistory"
    )

    /// The page's folder; nil for an id that could name a path elsewhere.
    func directory(for artifactID: String) -> URL? {
        guard !artifactID.isEmpty,
              !artifactID.contains("/"),
              !artifactID.contains(".."),
              !artifactID.hasPrefix(".") else { return nil }
        return rootDirectory.appendingPathComponent(artifactID, isDirectory: true)
    }

    /// The page's versions, newest first.
    func versions(of artifactID: String) -> [PageVersion] {
        guard let directory = directory(for: artifactID),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return PageVersionPolicy.sortedNewestFirst(names.compactMap(PageVersionPolicy.version(fileName:)))
    }

    func markdown(of version: PageVersion, artifactID: String) throws -> String {
        guard let directory = directory(for: artifactID),
              PageVersionPolicy.version(fileName: version.id) != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: directory.appendingPathComponent(version.id, isDirectory: false))
        return String(decoding: data, as: UTF8.self)
    }

    /// Keeps `old` when the policy says to, before `new` replaces it, and
    /// prunes the page's oldest versions. A body the newest version already
    /// holds is not kept twice. True when a version was written.
    @discardableResult
    func keepIfDue(
        previous old: String,
        replacedBy new: String,
        artifactID: String,
        reason: PageVersionReason,
        now: Date = Date()
    ) -> Bool {
        let existing = versions(of: artifactID)
        guard PageVersionPolicy.keepsVersion(
            old: old,
            new: new,
            reason: reason,
            newestVersionAt: existing.first?.savedAt,
            now: now
        ) else { return false }
        if let newest = existing.first, (try? markdown(of: newest, artifactID: artifactID)) == old {
            return false
        }
        do {
            try keep(old, artifactID: artifactID, reason: reason, at: now)
            prune(artifactID)
            return true
        } catch {
            Self.logger.error("Keeping a version of page \(artifactID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Writes `markdown` as a version of the page, whatever the policy says.
    func keep(_ markdown: String, artifactID: String, reason: PageVersionReason, at date: Date) throws {
        guard let directory = directory(for: artifactID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Two versions in one millisecond take the next free one.
        var savedAt = date
        var url = directory.appendingPathComponent(PageVersionPolicy.fileName(savedAt: savedAt, reason: reason))
        while FileManager.default.fileExists(atPath: url.path) {
            savedAt = savedAt.addingTimeInterval(0.001)
            url = directory.appendingPathComponent(PageVersionPolicy.fileName(savedAt: savedAt, reason: reason))
        }
        try Data(markdown.utf8).write(to: url, options: .atomic)
    }

    /// Each version's size on disk in bytes, by version id; a file that
    /// cannot be measured counts 0.
    func byteCounts(of versions: [PageVersion], artifactID: String) -> [String: Int] {
        guard let directory = directory(for: artifactID) else { return [:] }
        var byteCounts: [String: Int] = [:]
        for version in versions {
            let url = directory.appendingPathComponent(version.id, isDirectory: false)
            byteCounts[version.id] = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return byteCounts
    }

    /// Drops the versions past the page's limits, oldest first.
    func prune(_ artifactID: String) {
        guard let directory = directory(for: artifactID) else { return }
        let versions = versions(of: artifactID)
        let byteCounts = byteCounts(of: versions, artifactID: artifactID)
        for version in PageVersionPolicy.versionsToDrop(versions, byteCounts: byteCounts) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(version.id, isDirectory: false))
        }
    }

    /// The page is gone for good, and its versions go with it.
    func removeHistory(of artifactID: String) {
        guard let directory = directory(for: artifactID),
              FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Self.logger.error("Removing the versions of page \(artifactID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
