import Foundation

extension StudioViewModel {

    /// Bring the stored memory schedules up to the current scheduler
    /// (`MemoryTutorScheduler.algorithmVersion`): version 2 made never-attempted
    /// items new rather than due, and stopped early successes stretching
    /// intervals. Runs from the launch's `.utility` maintenance in small batches,
    /// so a learner's action never waits behind it; a later launch finishes
    /// whatever an interrupted one left. An item this build cannot read is
    /// skipped and named in the log, and the rest are rebuilt around it.
    func runDeferredMemoryScheduleRebuild() async {
        var rebuilt = 0
        var after: String?
        do {
            while !Task.isCancelled {
                let batch = try await storage.rebuildStaleMemorySchedules(after: after, limit: 100)
                rebuilt += batch.rebuilt
                for id in batch.skippedIDs {
                    logger.error("Memory schedule rebuild skipped item \(id, privacy: .public): it cannot be read")
                }
                guard let next = batch.nextAfterID else { break }
                after = next
                await Task.yield()
            }
        } catch {
            logger.error("Memory schedule rebuild paused: \(error.localizedDescription)")
        }
        if rebuilt > 0 {
            logger.notice("Rebuilt \(rebuilt) memory schedule(s) for scheduler version \(MemoryTutorScheduler.algorithmVersion)")
        }
    }
}
