import Foundation

/// The `MemoryReviewActivity` record one device writes for one day: the
/// encrypted payload generation 1's Mac sync encodes with `JSONEncoder`'s
/// defaults. No source identity to remap — the row names a day and a device,
/// nothing in the library. The phone no longer reads it: its review clock is
/// the replica's ActivityLog.
struct CloudKitMemoryReviewActivityPayload: Codable, Equatable, Sendable {
    let activity: MemoryReviewActivity
}
