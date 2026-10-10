import Foundation

/// Off-main access to Directions (docs/directions-design.md).
///
/// Thin pass-throughs to `KnowledgeStore` plus the sync urgency: an answer
/// given on one Mac is what the next search on the other reads first, so
/// every write pushes at once.
extension StorageService {

    func loadResearchDirections(homeID: String? = nil) throws -> [ResearchDirection] {
        try notebookFilesKnowledgeStore().loadResearchDirections(homeID: homeID)
    }

    @discardableResult
    func updateResearchDirection(_ directionID: String, change: ResearchDirectionChange) throws -> ResearchDirection {
        let direction = try notebookFilesKnowledgeStore().updateResearchDirection(directionID, change: change)
        researchDirectionsDidChange()
        return direction
    }

    func deleteResearchDirection(_ directionID: String) throws {
        try notebookFilesKnowledgeStore().deleteResearchDirection(directionID)
        researchDirectionsDidChange()
    }

    /// The library source each piece of evidence names, keyed by the
    /// evidence's DOI or address, for the Directions on screen.
    func librarySourceIDs(for evidence: [DirectionEvidence]) throws -> [DirectionEvidence: String] {
        let store = try notebookFilesKnowledgeStore()
        var matches: [DirectionEvidence: String] = [:]
        for item in evidence {
            if let sourceID = try store.librarySourceID(for: item) { matches[item] = sourceID }
        }
        return matches
    }

    private func researchDirectionsDidChange() {
        scheduleImmediateCloudKitSyncForDayPlans()
        NotificationCenter.default.post(name: .researchDirectionsDidChange, object: nil)
    }
}

extension Notification.Name {
    /// A Direction was written on this Mac: the lists that show them read
    /// again.
    static let researchDirectionsDidChange = Notification.Name("foreverlm.researchDirectionsDidChange")
}
