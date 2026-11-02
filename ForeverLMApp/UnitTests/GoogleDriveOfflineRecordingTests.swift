import Foundation
import Testing
@testable import ForeverLM

/// The offline copy of a Drive recording: found before the cache and before the
/// network, removed without touching another recording's copy. The download
/// itself needs a signed-in Google account, so the copy is planted by hand here.
@Suite("Google Drive offline recordings")
struct GoogleDriveOfflineRecordingTests {

    private let modified = Date(timeIntervalSince1970: 1_793_047_419)

    private func uniqueFileID() -> String {
        "offline-test-\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }

    private func driveURL(_ fileID: String) -> String {
        "https://drive.google.com/file/d/\(fileID)/view?usp=drivesdk&foreverlm_drive_account=acct-1"
    }

    /// Plants a file where the service keeps an offline copy, and returns it.
    private func plantOfflineCopy(fileID: String, modifiedAt: Date?) throws -> URL {
        let key = try #require(GoogleDriveService.offlineRecordingKey(
            fileURLOrID: driveURL(fileID),
            mimeType: "video/mp4",
            modifiedAt: modifiedAt,
            accountID: nil
        ))
        let folder = GoogleDriveService.offlineRecordingsFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(key.cacheKey).\(key.fileExtension)")
        try Data("video bytes".utf8).write(to: url)
        return url
    }

    @Test("a kept copy is reported, and playback resolves to it with no network")
    func keptCopyAnswersFirst() async throws {
        let fileID = uniqueFileID()
        #expect(await GoogleDriveService.shared.hasOfflineRecording(
            fileURLOrID: driveURL(fileID), mimeType: "video/mp4", modifiedAt: modified
        ) == false)

        let planted = try plantOfflineCopy(fileID: fileID, modifiedAt: modified)
        defer { try? FileManager.default.removeItem(at: planted) }

        #expect(await GoogleDriveService.shared.hasOfflineRecording(
            fileURLOrID: driveURL(fileID), mimeType: "video/mp4", modifiedAt: modified
        ))
        let resolved = try await GoogleDriveService.shared.cachedRecordingURL(
            fileURLOrID: driveURL(fileID), mimeType: "video/mp4", modifiedAt: modified
        )
        #expect(resolved == planted)
        let existing = await GoogleDriveService.shared.existingCachedRecordingURL(
            fileURLOrID: driveURL(fileID), mimeType: "video/mp4", modifiedAt: modified
        )
        #expect(existing == planted)
    }

    @Test("a copy kept for an older upload of the file is not offered for the new one")
    func changedModificationDateIsNotOffline() async throws {
        let fileID = uniqueFileID()
        let planted = try plantOfflineCopy(fileID: fileID, modifiedAt: modified)
        defer { try? FileManager.default.removeItem(at: planted) }

        #expect(await GoogleDriveService.shared.hasOfflineRecording(
            fileURLOrID: driveURL(fileID),
            mimeType: "video/mp4",
            modifiedAt: modified.addingTimeInterval(3600)
        ) == false)
    }

    @Test("removing a download deletes that recording's copies and no other")
    func removeLeavesOtherRecordings() async throws {
        let base = uniqueFileID()
        // Another file whose id merely begins with this one's.
        let neighbour = "\(base)-extra"
        let mine = try plantOfflineCopy(fileID: base, modifiedAt: modified)
        let olderUpload = try plantOfflineCopy(fileID: base, modifiedAt: modified.addingTimeInterval(-86_400))
        let others = try plantOfflineCopy(fileID: neighbour, modifiedAt: modified)
        defer {
            for url in [mine, olderUpload, others] { try? FileManager.default.removeItem(at: url) }
        }

        await GoogleDriveService.shared.removeOfflineRecording(
            fileURLOrID: driveURL(base), mimeType: "video/mp4", modifiedAt: modified
        )

        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(!FileManager.default.fileExists(atPath: olderUpload.path))
        #expect(FileManager.default.fileExists(atPath: others.path))
    }

    @Test("an empty file is not a kept copy")
    func emptyFileDoesNotCount() async throws {
        let fileID = uniqueFileID()
        let planted = try plantOfflineCopy(fileID: fileID, modifiedAt: modified)
        defer { try? FileManager.default.removeItem(at: planted) }
        try Data().write(to: planted)

        #expect(await GoogleDriveService.shared.hasOfflineRecording(
            fileURLOrID: driveURL(fileID), mimeType: "video/mp4", modifiedAt: modified
        ) == false)
    }
}
