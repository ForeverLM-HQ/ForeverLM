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

/// One comment thread on a page, as Codex's Comments panel shows it: the
/// comment that opened it on a passage, and the replies under it, oldest first.
/// A reply whose thread is gone (its opening comment deleted on another
/// device before the promotion reached it) opens a thread of its own.
struct ArtifactCommentThread: Identifiable, Equatable, Sendable {
    let root: ArtifactCommentRecord
    let replies: [ArtifactCommentRecord]

    var id: String { root.id }
    var isResolved: Bool { root.isResolved }
    /// Everything said in the thread, the opening comment first.
    var messages: [ArtifactCommentRecord] { [root] + replies }
    /// When anyone last wrote in it.
    var lastActivity: Date { messages.map(\.updatedAt).max() ?? root.updatedAt }

    /// The page's threads in reading order of their passages (where they
    /// start), a thread made earlier first where two start together.
    static func threads(from comments: [ArtifactCommentRecord]) -> [ArtifactCommentThread] {
        let ids = Set(comments.map(\.id))
        var repliesByRoot: [String: [ArtifactCommentRecord]] = [:]
        var roots: [ArtifactCommentRecord] = []
        for comment in comments {
            if let parent = comment.parentCommentID, ids.contains(parent) {
                repliesByRoot[rootID(of: comment, in: comments), default: []].append(comment)
            } else {
                roots.append(comment)
            }
        }
        return roots
            .sorted { ($0.anchorStart, $0.createdAt, $0.id) < ($1.anchorStart, $1.createdAt, $1.id) }
            .map { root in
                ArtifactCommentThread(
                    root: root,
                    replies: (repliesByRoot[root.id] ?? []).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
                )
            }
    }

    /// The comment a reply's chain of parents ends at.
    static func rootID(of comment: ArtifactCommentRecord, in comments: [ArtifactCommentRecord]) -> String {
        let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current = comment
        var seen: Set<String> = [comment.id]
        while let parent = current.parentCommentID, let next = byID[parent], seen.insert(next.id).inserted {
            current = next
        }
        return current.id
    }
}

/// What the page editor marks for one thread (`setCommentAnchors`): the
/// passage's stored place and words, which the editor finds again in the page
/// as it stands now, and whether the thread is resolved.
struct ArtifactCommentAnchor: Encodable, Equatable, Sendable {
    let id: String
    let from: Int
    let to: Int
    let resolved: Bool
    let quote: String

    init(thread: ArtifactCommentThread) {
        id = thread.id
        from = thread.root.anchorStart
        to = thread.root.anchorEnd
        resolved = thread.isResolved
        quote = thread.root.anchorQuote
    }

    /// The editor's script for these anchors.
    static func script(for anchors: [ArtifactCommentAnchor]) -> String {
        let data = (try? JSONEncoder().encode(anchors)) ?? Data("[]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        return "window.foreverLMArtifactEditor.setCommentAnchors(\(json));"
    }
}
