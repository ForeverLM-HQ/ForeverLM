import Foundation

/// The identity a device signs its review-time rows with.
///
/// Each device accrues time towards the day's goal in its own
/// `MemoryReviewActivity` row (`MemoryReviewGoal.activityID`), so the rows sum
/// across devices instead of one overwriting the other. The id is minted once
/// and kept in this device's `UserDefaults`; it is device-local by nature and
/// listed in `SyncedPreferenceKeys.excluded`. It carries no meaning beyond
/// telling one device's row from another's: a reinstall becomes a new device,
/// and its old row still counts towards the days it was written on.
enum MemoryReviewActivityDevice {
    static let preferenceKey = "memoryReview.activity.deviceID.v1"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: preferenceKey), !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString.lowercased()
        UserDefaults.standard.set(minted, forKey: preferenceKey)
        return minted
    }
}
