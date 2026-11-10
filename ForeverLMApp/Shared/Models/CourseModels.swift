// Course and lecture models, moved out of Models.swift.

import Foundation

// MARK: - Courses

struct CourseMetadata: Codable, Equatable, Hashable, Sendable {
    var courseCode: String?
    var title: String?
    var institution: String?
    var instructors: String?
    var playlistURL: String?
    var isHidden: Bool = false
    /// Browser-authored course shell awaiting one native playlist expansion.
    /// Explicit so an intentionally empty course is never re-imported.
    var pendingPlaylistImport: Bool = false

    init(
        courseCode: String? = nil,
        title: String? = nil,
        institution: String? = nil,
        instructors: String? = nil,
        playlistURL: String? = nil,
        isHidden: Bool = false,
        pendingPlaylistImport: Bool = false
    ) {
        self.courseCode = courseCode
        self.title = title
        self.institution = institution
        self.instructors = instructors
        self.playlistURL = playlistURL
        self.isHidden = isHidden
        self.pendingPlaylistImport = pendingPlaylistImport
    }
}

/// A numbered pedagogical unit inside a course. Sources are attached through
/// CourseLectureItem records so a lecture can contain arbitrary materials.
struct CourseSession: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var courseName: String
    var number: Int
    var title: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        courseName: String,
        number: Int,
        title: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.courseName = courseName
        self.number = number
        self.title = title
        self.createdAt = createdAt
    }
}

enum CourseLectureItemRole: String, Codable, CaseIterable, Sendable {
    case video
    case notes
    case slides
    case exercise
    case reading
    case article
    case podcast
    case code
    case reference
    case other

    var label: String {
        switch self {
        case .video: return "Video"
        case .notes: return "Notes"
        case .slides: return "Slides"
        case .exercise: return "Exercise"
        case .reading: return "Reading"
        case .article: return "Article"
        case .podcast: return "Podcast"
        case .code: return "Code"
        case .reference: return "Reference"
        case .other: return "Material"
        }
    }
}

/// An addressable unit inside a source, such as a repo subfolder, book chapter,
/// or page range. The initial UI attaches whole sources, but the model supports
/// finer units for exercises/code paths.
struct SourceUnit: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var sourceId: String
    var kind: String
    var locator: String
    var title: String?

    init(
        id: String = UUID().uuidString,
        sourceId: String,
        kind: String,
        locator: String,
        title: String? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.kind = kind
        self.locator = locator
        self.title = title
    }
}

/// A material attached to a course lecture. It can point to a whole source or
/// to a SourceUnit for things like GitHub subfolders.
struct CourseLectureItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var lectureId: String
    var sourceId: String?
    var sourceUnitId: String?
    var role: CourseLectureItemRole
    var label: String?
    var sortIndex: Int
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        lectureId: String,
        sourceId: String? = nil,
        sourceUnitId: String? = nil,
        role: CourseLectureItemRole = .other,
        label: String? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.lectureId = lectureId
        self.sourceId = sourceId
        self.sourceUnitId = sourceUnitId
        self.role = role
        self.label = label
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}
