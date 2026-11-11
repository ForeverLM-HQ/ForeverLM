// The actor that stores the text of synced sources on the phone.

import CryptoKit
import Foundation
import OSLog

/// A source's text on the phone: the canonical `text` satellite (§3.5.30), fetched by name, with the
/// saved-offline copy and the disk cache in front of it.
actor MobileCloudSourceTextStore {
    static let shared = MobileCloudSourceTextStore()

    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "CloudSourceTextStore")

    private var cachedText: [String: String] = [:]

    /// Text this phone wrote itself — an explainer's script — entered the way
    /// a fetch would enter it, so Listen and the reader read it at once rather
    /// than waiting for its satellite to come back.
    func storeSourceText(_ text: String, sourceID: String) async {
        cachedText[sourceID] = text
        await MobileSourceFileStore.shared.storeText(text, sourceID: sourceID)
    }

    func loadSourceText(sourceID: String, expectedSHA256: String? = nil) async throws -> String {
        if let cached = cachedText[sourceID],
           !cached.isEmpty,
           Self.matchesExpectedHash(cached, expectedSHA256: expectedSHA256) {
            return cached
        }

        // A saved-offline copy outranks the cache: it is the only copy the OS
        // cannot purge, and on a plane it is the only copy at all. An expected
        // hash still governs — stale text falls through to the fetch below,
        // which rewrites the saved copy.
        if let saved = await MobileOfflineSourceStore.shared.savedText(sourceID: sourceID),
           Self.matchesExpectedHash(saved, expectedSHA256: expectedSHA256) {
            cachedText[sourceID] = saved
            return saved
        }

        // Disk cache next: a cold launch should not need a round trip for text
        // that was already on this phone yesterday. Pull-to-refresh repopulates
        // it because the memory cache starts empty each launch and a fresh fetch
        // below overwrites the disk copy.
        if let disk = await MobileSourceFileStore.shared.cachedText(sourceID: sourceID),
           Self.matchesExpectedHash(disk, expectedSHA256: expectedSHA256) {
            cachedText[sourceID] = disk
            return disk
        }

        if let text = try await replicaText(sourceID: sourceID) {
            cachedText[sourceID] = text
            await MobileSourceFileStore.shared.storeText(text, sourceID: sourceID)
            // Keep a saved source saved. Without this write-through, text the Mac
            // revised would live on in the durable copy for as long as the pin did.
            if MobileOfflinePins.contains(sourceID) {
                do {
                    try await MobileOfflineSourceStore.shared.writeText(text, sourceID: sourceID)
                } catch {
                    Self.logger.error("Refreshing the saved copy of a source's text failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return text
        }

        throw MobileCloudSourceTextError.missingSourceText
    }

    private func replicaText(sourceID: String) async throws -> String? {
        guard let session = await MobileSyncSession.startIfEnabled(),
              let satellite = try await session.satellites.source(sourceID, matching: { $0 == "text" }),
              let text = String(data: try await session.satellites.data(satellite), encoding: .utf8), !text.isEmpty
        else { return nil }
        // An opened source's text is searchable on this phone for the next 30 days (§8a).
        do {
            try await session.textIndexer.index(text, sourceID: sourceID, hash: satellite.file.hash)
        } catch {
            Self.logger.error("Indexing a source's text failed: \(error.localizedDescription, privacy: .public)")
        }
        return text
    }

    /// The source's `listenText` satellite, read only while the text it was prepared from is the
    /// source's text now (§3.5.30).
    func loadSourceListenableContent(sourceID: String) async throws -> StoredSourceListenableContent? {
        guard let satellites = await MobileSatellites.current() else { throw MobileCloudSourceTextError.missingRecord }
        guard let satellite = try await satellites.source(sourceID, matching: { $0 == "listenText" }) else { return nil }
        let narration = String(decoding: try await satellites.data(satellite), as: UTF8.self)
        return MobileListenText.content(narration: narration, file: satellite.file,
                                        canonicalText: try await loadSourceText(sourceID: sourceID))
    }

    private static func matchesExpectedHash(_ text: String, expectedSHA256: String?) -> Bool {
        guard let expectedSHA256 else { return true }
        let digest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return digest == expectedSHA256
    }
}

enum MobileCloudSourceTextError: LocalizedError {
    case missingRecord
    case missingSourceText
    case sourceStillProcessing

    var errorDescription: String? {
        switch self {
        case .missingRecord:
            return "This source has not synced to iCloud yet."
        case .missingSourceText:
            return "This source does not have synced readable text yet."
        case .sourceStillProcessing:
            return "This source is still preparing readable text."
        }
    }
}
