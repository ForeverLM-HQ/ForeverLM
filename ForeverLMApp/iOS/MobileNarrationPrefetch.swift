// Narration the listener is likely to want, pulled down before they press play.
//
// A narration's audio is tens of megabytes and arrives from the replica a few
// chunks at a time, so pressing play on one the phone has never held is a wait.
// The library already knows the manifest of every narration; this decides which
// of their audio to fetch ahead, quietly, while the phone is idle on Wi-Fi.
// Nothing is generated and nothing is billed: only audio that already exists.

import Foundation
import Network
import OSLog

/// Which narrations to fetch ahead, in order. Pure, so it can be tested.
enum MobileNarrationPrefetchPlan {
    struct Pick: Equatable {
        let sourceID: String
        /// How many leading chunks to fetch; nil means the whole narration.
        let chunkCount: Int?
    }

    /// Narrations fetched whole, and narrations fetched only as far as an opening.
    static let wholeLimit = 3
    static let openingLimit = 6
    /// Enough of a narration that playback starts at once while the rest arrives.
    static let openingChunks = 4

    /// - Parameters:
    ///   - items: every narration the library holds, newest first or not.
    ///   - resumeIDs: narrations with a saved position, most recently listened first.
    ///   - nextChapterIDs: the chapter after each of those, in the same order.
    ///   - scheduledIDs: narrations of sources planned for today or earlier and not done.
    ///   - isLocal: whether every chunk of a narration is already on the phone.
    static func picks(
        items: [MobileAudioItem],
        resumeIDs: [String],
        nextChapterIDs: [String],
        scheduledIDs: [String],
        isLocal: (MobileAudioItem) -> Bool
    ) -> [Pick] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var picks: [Pick] = []

        func add(_ ids: [String], chunkCount: Int?, limit: Int) {
            var added = picks.filter { $0.chunkCount == chunkCount }.count
            for id in ids where added < limit {
                guard let item = byID[id], !seen.contains(id) else { continue }
                seen.insert(id)
                guard !isLocal(item) else { continue }
                if let chunkCount, item.manifest.chunks.count <= chunkCount {
                    picks.append(Pick(sourceID: id, chunkCount: nil))
                } else {
                    picks.append(Pick(sourceID: id, chunkCount: chunkCount))
                }
                added += 1
            }
        }

        add(resumeIDs, chunkCount: nil, limit: wholeLimit)
        add(nextChapterIDs, chunkCount: nil, limit: wholeLimit)
        add(scheduledIDs, chunkCount: nil, limit: wholeLimit)
        let newest = items.sorted { $0.createdAt > $1.createdAt }.map(\.id)
        add(newest, chunkCount: openingChunks, limit: openingLimit)
        return picks
    }
}

/// Whether the phone is on a network where a quiet background fetch is fair:
/// a connection exists, it is not metered or in Low Data Mode, and the battery
/// is not being saved.
enum MobileNarrationPrefetchConditions {
    static func allowPrefetch() async -> Bool {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        let monitor = NWPathMonitor()
        let paths = AsyncStream<NWPath> { continuation in
            monitor.pathUpdateHandler = { continuation.yield($0) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.foreverlm.mobile.narration-prefetch-path"))
        }
        for await path in paths {
            return path.status == .satisfied && !path.isExpensive && !path.isConstrained
        }
        return false
    }
}

extension MobileAudioReviewViewModel {
    nonisolated private static let prefetchLogger = Logger(subsystem: "com.foreverlm.mobile", category: "NarrationPrefetch")

    /// Starts a quiet pass that pulls down the narrations the listener is most
    /// likely to play next. One pass at a time; a new request while one runs is
    /// ignored, since the running pass already covers the same library.
    func startNarrationPrefetch() {
        guard narrationPrefetchTask == nil, !items.isEmpty else { return }
        narrationPrefetchTask = Task { [weak self] in
            await self?.runNarrationPrefetch()
            self?.narrationPrefetchTask = nil
        }
    }

    private func runNarrationPrefetch() async {
        guard await MobileNarrationPrefetchConditions.allowPrefetch() else { return }

        let items = self.items
        let resumeIDs = await Task.detached(priority: .utility) { () -> [String] in
            let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
            return items.compactMap { item -> (String, Date)? in
                guard let position = SyncedArticleAudioStore.loadLocalPlaybackPosition(sourceID: item.id),
                      position.globalTime > 0, position.updatedAt > cutoff else { return nil }
                return (item.id, position.updatedAt)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        }.value
        let nextChapterIDs = resumeIDs.prefix(MobileNarrationPrefetchPlan.wholeLimit)
            .compactMap { nextBookChapter(after: $0)?.id }
        let endOfToday = Calendar.current.date(
            byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())
        ) ?? Date()
        let scheduledIDs = scheduledSources
            .filter { $0.completedAt == nil && $0.plannedAt < endOfToday }
            .sorted { $0.plannedAt < $1.plannedAt }
            .map(\.sourceID)

        let picks = await Task.detached(priority: .utility) {
            MobileNarrationPrefetchPlan.picks(
                items: items,
                resumeIDs: resumeIDs,
                nextChapterIDs: nextChapterIDs,
                scheduledIDs: scheduledIDs,
                isLocal: { SyncedArticleAudioStore.hasLocalChunks(for: $0.manifest) }
            )
        }.value

        for pick in picks {
            if Task.isCancelled { return }
            // A narration the listener asked for has the connection to itself.
            guard narrationDownloadSourceID == nil, pick.sourceID != narrationDownloadSourceID,
                  let item = itemForSourceID(pick.sourceID) else { return }
            let manifest = pick.chunkCount.map { item.manifest.prefix(chunkCount: $0) } ?? item.manifest
            do {
                try await Task.detached(priority: .utility) {
                    try await SyncedArticleAudioStore.materializeChunks(for: manifest) { _ in }
                }.value
            } catch is CancellationError {
                return
            } catch {
                Self.prefetchLogger.error("Fetching a narration ahead failed: \(error.localizedDescription, privacy: .public)")
            }
            guard await MobileNarrationPrefetchConditions.allowPrefetch() else { return }
        }
    }
}
