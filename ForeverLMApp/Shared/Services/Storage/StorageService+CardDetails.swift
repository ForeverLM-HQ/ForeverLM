import Foundation

// MARK: - A card's details (KnowledgeStore+CardDetails.swift)

extension StorageService {
    /// The Card id `id` names, or nil (`KnowledgeStore.cardRecordID(naming:)`).
    func cardRecordID(naming id: String) throws -> String? {
        try knowledgeStore().cardRecordID(naming: id)
    }

    /// Each overview's details, in order (`KnowledgeStore.cardDetails(ofParents:)`).
    func cardDetails(ofParents parentIDs: [String]) throws -> [String: [MemoryCardDetailLink]] {
        guard !parentIDs.isEmpty else { return [:] }
        return try knowledgeStore().cardDetails(ofParents: parentIDs)
    }

    /// The overviews each detail belongs to (`KnowledgeStore.cardOverviews(ofChildren:)`).
    func cardOverviews(ofChildren childIDs: [String]) throws -> [String: [MemoryCardDetailLink]] {
        guard !childIDs.isEmpty else { return [:] }
        return try knowledgeStore().cardOverviews(ofChildren: childIDs)
    }

    /// Sets an overview's details (`KnowledgeStore.setCardDetails`), and syncs.
    @discardableResult
    func setCardDetails(
        parentID: String,
        _ details: [MemoryCardDetailSpec],
        at now: Date = Date()
    ) throws -> (linked: [MemoryCardDetailLink], refused: [MemoryCardDetailRefusal]) {
        let result = try knowledgeStore().setCardDetails(parentID: parentID, details, at: now)
        scheduleCloudKitSync(.soon)
        return result
    }
}
