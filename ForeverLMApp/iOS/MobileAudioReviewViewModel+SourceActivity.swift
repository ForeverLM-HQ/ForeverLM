// Recording source consumption, depth and activity.

import CloudKit
import Foundation

extension MobileAudioReviewViewModel {
    /// The one mobile completion boundary for both reading and listening. It
    /// patches the Source's explicit consumption date and records a completed
    /// Schedule placement, making the source available to tomorrow's MCP
    /// request for yesterday's material.
    @discardableResult
    func recordSourceConsumption(
        sourceID: String,
        kind: SourceActivityKind,
        completedAt: Date = Date()
    ) async -> Bool {
        let activityKey = "\(sourceID):\(Calendar.current.startOfDay(for: completedAt).timeIntervalSinceReferenceDate):\(kind.rawValue)"
        if sourceConsumptionRecordedIDs.contains(activityKey) { return true }
        guard sourceConsumptionInFlightIDs.insert(activityKey).inserted else { return false }
        defer { sourceConsumptionInFlightIDs.remove(activityKey) }

        guard let source = allSources.first(where: { $0.id == sourceID }) else {
            errorMessage = "Finished playback could not be logged because that source is not in the synced library."
            return false
        }
        let existingPlacement = scheduledPlacement(for: sourceID)
        let order = nextScheduleOrder(on: completedAt, excluding: sourceID)
        do {
            let completedPlacement = try await MobileCloudMutationService.shared
                .recordSourceConsumption(
                    source: source,
                    existingPlacement: existingPlacement,
                    completedAt: completedAt,
                    order: order,
                    kind: kind
                )
            sourceConsumptionRecordedIDs.insert(activityKey)
            publishRecordedConsumption(
                source: source,
                placement: completedPlacement,
                completedAt: completedAt
            )
            return true
        } catch {
            if Self.isCancelledCloudWrite(error) {
                // Nothing to act on: the task carrying this write was torn down
                // or CloudKit dropped the operation. The completion key was not
                // recorded, so reaching the end again retries it.
                Self.activityLogger.info(
                    "Cancelled while logging \(kind.rawValue, privacy: .public) completion for \(sourceID, privacy: .public)"
                )
                return false
            }
            errorMessage = "Finished source could not be logged: \(error.localizedDescription)"
            return false
        }
    }

    /// Explicitly records material completed in another app. Source identity is
    /// resolved before this method; mobile writes the same activity-ledger shape
    /// used by in-app reading and playback.
    @discardableResult
    func recordExternalSourceCompletions(
        sourceIDs: [String],
        kind: SourceActivityKind,
        completedAt: Date = Date()
    ) async -> Bool {
        let stableIDs = sourceIDs.reduce(into: [String]()) { result, raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !result.contains(id) { result.append(id) }
        }
        guard !stableIDs.isEmpty else {
            errorMessage = "Choose at least one source to log."
            return false
        }
        let availableIDs = Set(allSources.filter { !$0.isArchived && $0.state == "ready" }.map(\.id))
        if let missingID = stableIDs.first(where: { !availableIDs.contains($0) }) {
            errorMessage = "Source \(missingID) is archived, unavailable, or not in the synced library."
            return false
        }
        for sourceID in stableIDs {
            guard await recordSourceConsumption(
                sourceID: sourceID,
                kind: kind,
                completedAt: completedAt
            ) else { return false }
        }
        return true
    }

    /// Put a source on today's calendar as soon as reading, listening, or a
    /// review starts. Existing planned placements stay on their chosen day.
    func recordSourceActivity(sourceID: String, kind: SourceActivityKind) async {
        let startedAt = Date()
        let activityKey = "\(sourceID):\(Calendar.current.startOfDay(for: startedAt).timeIntervalSinceReferenceDate):\(kind.rawValue)"
        guard !sourceActivityRecordedIDs.contains(activityKey),
              sourceActivityInFlightIDs.insert(activityKey).inserted else { return }
        defer { sourceActivityInFlightIDs.remove(activityKey) }

        guard let source = allSources.first(where: { $0.id == sourceID }) else {
            errorMessage = "Source activity could not be logged because that source is not in the synced library."
            return
        }

        // The reader and chat screens start this write from a SwiftUI `.task`,
        // which is cancelled the moment the screen is dismissed. The learner did
        // open the source, so the ledger write runs in its own task and lands
        // even when the screen is gone before the CloudKit round trip returns.
        // Cancelling the write instead surfaced "Operation … was cancelled" as
        // an error banner over the next screen.
        let existingPlacement = scheduledPlacement(for: sourceID)
        let order = nextScheduleOrder(on: startedAt, excluding: sourceID)
        let write = Task {
            try await MobileCloudMutationService.shared
                .recordSourceActivity(
                    source: source,
                    existingPlacement: existingPlacement,
                    startedAt: startedAt,
                    order: order,
                    kind: kind
                )
        }
        do {
            let placement = try await write.value
            sourceActivityRecordedIDs.insert(activityKey)
            publishRecordedActivity(source: source, placement: placement)
        } catch {
            if Self.isCancelledCloudWrite(error) {
                // CloudKit itself dropped the operation (the app was suspended
                // mid-flight, for instance). Not the learner's problem and not
                // actionable; the key stays unrecorded so the next start retries.
                Self.activityLogger.info(
                    "Cancelled while logging \(kind.rawValue, privacy: .public) activity for \(sourceID, privacy: .public)"
                )
                return
            }
            errorMessage = "Source activity could not be logged: \(error.localizedDescription)"
        }
    }

    /// A write that stopped because its task was cancelled or CloudKit cancelled
    /// the operation. Neither says anything about the request, so neither is
    /// worth a banner; the Mac sync engine excludes the same two from its
    /// failure counts.
    nonisolated static func isCancelledCloudWrite(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let cloudError = error as? CKError { return cloudError.code == .operationCancelled }
        let nsError = error as NSError
        return nsError.domain == CKErrorDomain
            && nsError.code == CKError.Code.operationCancelled.rawValue
    }

    /// Promote resumable playback/scroll position into durable consumption
    /// evidence, mirroring what `ArticleSpeechService` records on the Mac.
    ///
    /// Without this, abandoning a podcast at 70% leaves nothing behind but a
    /// device-local resume position, and the memory tutor cannot tell that
    /// episode apart from one that was never opened — so it never gets quizzed.
    /// Depth merges with MAX everywhere, so repeated calls are safe and a
    /// backwards seek never lowers what was already reached.
    /// Cheap synchronous test of the same threshold `recordSourceDepth` applies,
    /// so a scroll observer firing every frame does not spawn a task per event
    /// only for it to be discarded.
    func shouldRecordDepth(sourceID: String, fraction: Double) -> Bool {
        guard fraction.isFinite else { return false }
        let clamped = SourceActivityDay.clampFraction(fraction)
        return clamped - (recordedSourceDepths[sourceID] ?? 0) >= Self.depthReportingStep
    }

    func recordSourceDepth(
        sourceID: String,
        kind: SourceActivityKind,
        fraction: Double
    ) async {
        guard fraction.isFinite else { return }
        let clamped = SourceActivityDay.clampFraction(fraction)
        guard clamped > 0 else { return }
        // Every tick is time with the source: count it toward the ledger's
        // engaged seconds, to be written with the next depth step.
        let occurredAt = Date()
        if let last = depthTickAt[sourceID] {
            let gap = occurredAt.timeIntervalSince(last)
            if gap > 0, gap <= Self.maxEngagedTickGap {
                pendingEngagedSeconds[sourceID, default: 0] += gap
            }
        }
        depthTickAt[sourceID] = occurredAt
        // A write per clock tick would be one CloudKit round trip per second for
        // no added evidence. Only a materially deeper point is worth publishing.
        guard clamped - (recordedSourceDepths[sourceID] ?? 0) >= Self.depthReportingStep else {
            return
        }
        let depthKey = "\(sourceID):\(kind.rawValue):depth"
        guard sourceActivityInFlightIDs.insert(depthKey).inserted else { return }
        defer { sourceActivityInFlightIDs.remove(depthKey) }

        guard let source = allSources.first(where: { $0.id == sourceID }) else { return }
        let engaged = pendingEngagedSeconds.removeValue(forKey: sourceID) ?? 0
        do {
            let placement = try await MobileCloudMutationService.shared
                .recordSourceActivity(
                    source: source,
                    existingPlacement: scheduledPlacement(for: sourceID),
                    startedAt: occurredAt,
                    order: nextScheduleOrder(on: occurredAt, excluding: sourceID),
                    kind: kind,
                    fraction: clamped,
                    engagedSeconds: engaged
                )
            recordedSourceDepths[sourceID] = max(
                recordedSourceDepths[sourceID] ?? 0,
                clamped
            )
            publishRecordedActivity(source: source, placement: placement)
        } catch {
            // The time counted goes back on the tab for the next write.
            pendingEngagedSeconds[sourceID, default: 0] += engaged
            // Depth is opportunistic background evidence. A failed write must
            // never interrupt playback or reading with a banner; the next
            // threshold crossing retries it.
            Self.activityLogger.error(
                "Failed to log \(kind.rawValue, privacy: .public) depth for \(sourceID, privacy: .public): \(error.localizedDescription)"
            )
        }
    }

    private func publishRecordedActivity(
        source: MobileCloudSource,
        placement: MobileCloudScheduledSource
    ) {
        if let placementIndex = scheduledSources.firstIndex(where: { $0.id == placement.id }) {
            scheduledSources[placementIndex] = placement
        } else {
            scheduledSources.append(placement)
        }
        let row = MobileScheduledCatalogItem(
            id: placement.id,
            source: source,
            plannedAt: placement.plannedAt,
            isCompleted: placement.isCompleted,
            completedAt: placement.completedAt,
            groupTitle: source.parentGroup.flatMap { groupID in
                collections.booksByID[groupID]?.title ?? collections.coursesByID[groupID]?.title
            },
            goalTitles: [],
            goalIDs: placement.goalIDs,
            activityDays: placement.activityDays,
            isAutomatic: placement.isAutomatic
        )
        if let index = scheduleItems.firstIndex(where: { $0.id == placement.id }) {
            scheduleItems[index] = row
        } else {
            scheduleItems.append(row)
            scheduleItems.sort { $0.plannedAt < $1.plannedAt }
        }
    }

    /// Publish the successful write without launching a visible catalog reload
    /// at the exact moment narration ends. The next activation/voice tool's
    /// event-driven delta reconciles the durable CloudKit record normally.
    private func publishRecordedConsumption(
        source: MobileCloudSource,
        placement: MobileCloudScheduledSource,
        completedAt: Date
    ) {
        if let sourceIndex = allSources.firstIndex(where: { $0.id == source.id }) {
            allSources[sourceIndex].readAt = allSources[sourceIndex].readAt ?? completedAt
        }
        if let placementIndex = scheduledSources.firstIndex(where: { $0.id == placement.id }) {
            scheduledSources[placementIndex] = placement
        } else {
            scheduledSources.append(placement)
        }

        let existingItem = scheduleItems.first { $0.id == placement.id }
        let groupTitle = existingItem?.groupTitle ?? source.parentGroup.flatMap { groupID in
            collections.booksByID[groupID]?.title ?? collections.coursesByID[groupID]?.title
        }
        let goalTitles = existingItem?.goalTitles ?? []
        let row = MobileScheduledCatalogItem(
            id: placement.id,
            source: allSources.first(where: { $0.id == source.id }) ?? source,
            plannedAt: placement.plannedAt,
            isCompleted: true,
            completedAt: placement.completedAt ?? completedAt,
            groupTitle: groupTitle,
            goalTitles: goalTitles,
            goalIDs: placement.goalIDs,
            activityDays: placement.activityDays,
            isAutomatic: placement.isAutomatic
        )
        if let index = scheduleItems.firstIndex(where: { $0.id == placement.id }) {
            scheduleItems[index] = row
        } else {
            scheduleItems.append(row)
            scheduleItems.sort { $0.plannedAt < $1.plannedAt }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Mobile Notebook and Schedule mutations

    func scheduledPlacement(for sourceID: String) -> MobileCloudScheduledSource? {
        scheduledSources.first { $0.sourceID == sourceID }
    }
}
