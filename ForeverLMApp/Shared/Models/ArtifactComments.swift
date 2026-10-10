import Foundation

struct ArtifactCommentRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let artifactID: String
    let parentCommentID: String?
    let authorRecordName: String
    let authorDisplayName: String
    var body: String
    let anchorRevision: String
    let anchorStart: Int
    let anchorEnd: Int
    let anchorQuote: String
    let createdAt: Date
    var updatedAt: Date
    var resolvedAt: Date?

    var isResolved: Bool { resolvedAt != nil }

    init(
        id: String,
        artifactID: String,
        parentCommentID: String?,
        authorRecordName: String,
        authorDisplayName: String,
        body: String,
        anchorRevision: String,
        anchorStart: Int,
        anchorEnd: Int,
        anchorQuote: String,
        createdAt: Date,
        updatedAt: Date,
        resolvedAt: Date?
    ) {
        self.id = id
        self.artifactID = artifactID
        self.parentCommentID = parentCommentID
        self.authorRecordName = authorRecordName
        self.authorDisplayName = authorDisplayName
        self.body = body
        self.anchorRevision = anchorRevision
        self.anchorStart = anchorStart
        self.anchorEnd = anchorEnd
        self.anchorQuote = anchorQuote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        artifactID = try container.decode(String.self, forKey: .artifactID)
        parentCommentID = try container.decodeIfPresent(String.self, forKey: .parentCommentID)
        authorRecordName = try container.decodeIfPresent(String.self, forKey: .authorRecordName) ?? "unknown"
        authorDisplayName = try container.decodeIfPresent(String.self, forKey: .authorDisplayName) ?? "Collaborator"
        body = try container.decode(String.self, forKey: .body)
        anchorRevision = try container.decodeIfPresent(String.self, forKey: .anchorRevision) ?? ""
        anchorStart = try container.decodeIfPresent(Int.self, forKey: .anchorStart) ?? 0
        anchorEnd = try container.decodeIfPresent(Int.self, forKey: .anchorEnd) ?? anchorStart
        anchorQuote = try container.decodeIfPresent(String.self, forKey: .anchorQuote) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
    }
}

struct ArtifactCollaborationRecord: Equatable, Sendable {
    enum DatabaseScope: String, Sendable {
        case privateScope = "private"
        case shared
    }

    enum Permission: String, Sendable {
        case readOnly
        case readWrite
    }

    let artifactID: String
    let databaseScope: DatabaseScope
    let zoneName: String
    let ownerName: String
    let shareRecordName: String?
    let permission: Permission
    let isOwner: Bool
    let lastBodyRevision: String?
    let updatedAt: Date
}

enum ArtifactCommentError: LocalizedError, Equatable {
    case emptyBody
    case missingSelection
    case unavailable

    var errorDescription: String? {
        switch self {
        case .emptyBody:
            return "A comment cannot be empty."
        case .missingSelection:
            return "Select text to start a comment."
        case .unavailable:
            return "This comment is no longer available."
        }
    }
}
