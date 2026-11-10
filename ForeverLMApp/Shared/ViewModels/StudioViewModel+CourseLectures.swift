// Course lectures: creating, ordering and titling them, and the title parsers.

import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import AppKit

/// Immutable parsers shared by course-title normalization. Compiling them inside the
/// per-video helpers below would make a 500-item YouTube refresh spend seconds
/// compiling the same ICU programs on the main actor.
private enum CourseTitleParserCache {
    private static let lessonLabel = #"(?:lecture|lec|chapter|chap|ch|session|week|class|unit|section)"#

    static let materialPartRegexes: [NSRegularExpression] = [
        #"(?i)\b\#(lessonLabel)\s*[_#.:\\-–—]*\s*(\d{1,3})\s*(?:[_#.:\\-–—]\s*)?part\s*[_#.:\\-–—]*\s*([a-z]|\d{1,2})\b"#,
        #"(?i)\b\#(lessonLabel)\s*[_#.:\\-–—]*\s*(\d{1,3})([a-z])\b"#,
        #"(?i)\b\#(lessonLabel)\s*[_#.:\\-–—]*\s*(\d{1,3})\s+([a-z])\s*(?:[\)_#.:\\-–—]|$)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static let materialRegexes: [(kind: String, regex: NSRegularExpression)] = [
        ("lesson", #"(?i)\b(?:lecture|lec|chapter|chap|ch|session|week|class|unit|section)\s*[_#.:\\-–—]*\s*(\d{1,3}(?:\.\d{1,2}|[a-z]\b)?)"#),
        ("assignment", #"(?i)\b(?:hw|homework|pset|problem\s*set|assignment)\s*[_#.:\\-–—]*\s*(\d{1,3})"#),
        ("worksheet", #"(?i)\b(?:worksheet|work\s*sheet|solutions?\s+to\s+worksheet)\s*[_#.:\\-–—]*\s*(\d{1,3})"#),
        ("lesson", #"(?i)^\s*(\d{1,3}(?:\.\d{1,2}|[a-z]\b)?)\s*[\)_#.:\\-–—\s]"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// A title that already opens with its own lecture ordinal. Deliberately
    /// strict: a row decides from this whether
    /// numbering the title would repeat a number the title already carries, so
    /// "3 Body Problem" must not read as lecture 3.
    static let displayLectureOrdinalPrefixes: [NSRegularExpression] = [
        // The normalized form `Prompts.courseLectureTitleCleanup` emits.
        #"^\s*\d{1,3}(?:[a-z]|\.\d{1,3})?\)\s*"#,
        // A title the cleanup never saw, still naming its own lecture number.
        // The hyphen is escaped with one backslash on purpose: `\\-` in a raw
        // string is a literal backslash followed by a range operator, which
        // widens the class to every character between "\" and "–".
        #"^\s*\#(lessonLabel)s?\s*[_#.:\-–—]*\s*\d{1,3}(?:[a-z]|\.\d{1,3})?\s*(?:[\)_#.:\-–—]\s*|\s)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    static let leadingDanglingSeparators = try! NSRegularExpression(
        pattern: #"^[\s/\\|:;,\-–—·•]+"#
    )
    static let trailingDanglingSeparators = try! NSRegularExpression(
        pattern: #"[\s/\\|:;,\-–—·•]+$"#
    )
    static let nonAlphanumeric = CharacterSet.alphanumerics.inverted
}

extension StudioViewModel {

    func createLecture(in courseName: String, title: String? = nil, number requestedNumber: Int? = nil) async -> CourseSession? {
        let existingNumbers = Set(courseLecturesByCourse[courseName]?.map(\.number) ?? [])
        let fallbackNumber = (existingNumbers.max() ?? 0) + 1
        let number: Int
        if let requestedNumber, requestedNumber > 0, !existingNumbers.contains(requestedNumber) {
            number = requestedNumber
        } else {
            number = fallbackNumber
        }
        let lecture = CourseSession(courseName: courseName, number: number, title: title)
        do {
            try await storage.saveCourseLecture(lecture)
            courseLecturesByCourse[courseName, default: []].append(lecture)
            courseLecturesByCourse[courseName]?.sort { $0.number < $1.number }
            userCourseNames.insert(courseName)
            saveUserCourseNames()
            if courseMetadata[courseName] == nil {
                courseMetadata[courseName] = CourseMetadata()
                do {
                    try await storage.saveCourseGroup(name: courseName, metadata: CourseMetadata())
                } catch {
                    logger.error("saveCourseGroup failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return lecture
        } catch {
            logger.error("Failed to create lecture in '\(courseName)': \(error.localizedDescription)")
            return nil
        }
    }

    func renameCourseLecture(_ lectureId: String, title: String?) async {
        await updateCourseLectureTitle(lectureId, title: title)
    }

    func firstOrCreateLecture(in courseName: String) async -> CourseSession? {
        if let first = courseLectures(for: courseName).first {
            return first
        }
        return await createLecture(in: courseName)
    }

    func matchingOrFirstLecture(in courseName: String, for article: StudioArticle) async -> CourseSession? {
        if let existing = existingLecture(containing: article.id, in: courseName) {
            return existing
        }
        if let matched = matchingLecture(in: courseName, title: article.title, article: article) {
            return matched
        }
        return await firstOrCreateLecture(in: courseName)
    }

    func playlistItemLecture(
        in courseName: String,
        title: String?,
        playlistPosition: Int,
        existingArticle: StudioArticle?,
        usedLectureIds: Set<String>
    ) async -> CourseSession? {
        if let existingArticle,
           let existing = existingLecture(containing: existingArticle.id, in: courseName),
           !usedLectureIds.contains(existing.id) {
            return existing
        }

        // Playlist imports should show every video the playlist is adding. Do
        // not merge by numbers found in conference/session titles; attached
        // course materials can still match these lectures later by ordinal.
        return await createLecture(in: courseName, title: title, number: playlistPosition)
    }

    func normalizePlaylistLectureOrder(_ lectureIdsInOrder: [String], in courseName: String) async {
        let playlistIds = Array(NSOrderedSet(array: lectureIdsInOrder).compactMap { $0 as? String })
        guard !playlistIds.isEmpty else { return }

        let playlistIdSet = Set(playlistIds)
        var lectures = courseLecturesByCourse[courseName] ?? []

        // An empty playlist lecture leaves the outline only once the store has
        // deleted it; one that could not be deleted stays, as it is stored.
        var deletedLectureIds = Set<String>()
        for lecture in lectures where playlistIdSet.contains(lecture.id) {
            if (courseLectureItemsByLectureId[lecture.id] ?? []).isEmpty {
                do {
                    try await storage.deleteCourseLecture(lecture.id)
                    courseLectureItemsByLectureId[lecture.id] = nil
                    deletedLectureIds.insert(lecture.id)
                } catch {
                    logger.error("Could not delete empty playlist lecture \(lecture.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    showToast("Could not remove an empty lecture: \(error.localizedDescription)")
                }
            }
        }

        lectures = courseLecturesByCourse[courseName]?.filter { !deletedLectureIds.contains($0.id) } ?? []
        courseLecturesByCourse[courseName] = lectures

        let orderedPlaylistLectures = playlistIds.compactMap { id in
            lectures.first { $0.id == id }
        }
        let remainingLectures = lectures
            .filter { !playlistIdSet.contains($0.id) }
            .sorted { $0.number < $1.number }

        let reordered = orderedPlaylistLectures + remainingLectures
        for (index, lecture) in reordered.enumerated() {
            let nextNumber = index + 1
            guard let currentIndex = courseLecturesByCourse[courseName]?.firstIndex(where: { $0.id == lecture.id }),
                  courseLecturesByCourse[courseName]?[currentIndex].number != nextNumber else {
                continue
            }

            courseLecturesByCourse[courseName]?[currentIndex].number = nextNumber
            if let updated = courseLecturesByCourse[courseName]?[currentIndex] {
                do {
                    try await storage.saveCourseLecture(updated)
                } catch {
                    logger.error("Failed to renumber playlist lecture: \(error.localizedDescription)")
                }
            }
        }
        courseLecturesByCourse[courseName]?.sort { $0.number < $1.number }
    }

    func updateLectureItemSortIndex(articleId: String, lectureId: String, sortIndex: Int) async {
        guard var items = courseLectureItemsByLectureId[lectureId],
              let itemIndex = items.firstIndex(where: { $0.sourceId == articleId }),
              items[itemIndex].sortIndex != sortIndex else {
            return
        }

        items[itemIndex].sortIndex = sortIndex
        courseLectureItemsByLectureId[lectureId] = items.sorted { $0.sortIndex < $1.sortIndex }
        do {
            try await storage.saveCourseLectureItem(items[itemIndex])
        } catch {
            logger.error("Failed to update playlist lecture item order: \(error.localizedDescription)")
        }
    }

    func updateCourseLectureTitle(_ lectureId: String, title: String?) async {
        guard let courseName = courseLecturesByCourse.first(where: { _, lectures in
            lectures.contains { $0.id == lectureId }
        })?.key,
              let index = courseLecturesByCourse[courseName]?.firstIndex(where: { $0.id == lectureId }) else {
            return
        }

        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTitle = normalizedTitle?.isEmpty == true ? nil : normalizedTitle
        guard courseLecturesByCourse[courseName]?[index].title != nextTitle else { return }

        courseLecturesByCourse[courseName]?[index].title = nextTitle
        if let lecture = courseLecturesByCourse[courseName]?[index] {
            do {
                try await storage.saveCourseLecture(lecture)
            } catch {
                logger.error("Failed to update lecture title: \(error.localizedDescription)")
            }
        }
    }

    func removeEmptyPlaceholderLectureIfNeeded(in courseName: String, importedLectureNumbers: [Int]) async {
        guard importedLectureNumbers.contains(where: { $0 > 1 }),
              !importedLectureNumbers.contains(1),
              let placeholder = courseLecturesByCourse[courseName]?.first(where: isEmptyPlaceholderLecture) else {
            return
        }

        do {
            try await storage.deleteCourseLecture(placeholder.id)
            courseLecturesByCourse[courseName]?.removeAll { $0.id == placeholder.id }
            courseLectureItemsByLectureId[placeholder.id] = nil
        } catch {
            logger.error("Failed to remove empty placeholder lecture: \(error.localizedDescription)")
        }
    }

    func isEmptyPlaceholderLecture(_ lecture: CourseSession) -> Bool {
        lecture.number == 1
            && (lecture.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (courseLectureItemsByLectureId[lecture.id]?.isEmpty ?? true)
    }

    func existingLecture(containing sourceId: String, in courseName: String) -> CourseSession? {
        courseLectures(for: courseName).first { lecture in
            courseLectureItems(for: lecture.id).contains { $0.sourceId == sourceId }
        }
    }

    func matchingLecture(
        in courseName: String,
        title: String?,
        preferredNumber: Int? = nil,
        article: StudioArticle? = nil
    ) -> CourseSession? {
        let lectures = courseLectures(for: courseName)
        guard !lectures.isEmpty else { return nil }

        let explicitOrdinal = article.flatMap { Self.materialOrdinal(for: $0, courseName: courseName) }
            ?? title.flatMap { Self.materialOrdinal(in: Self.stripCoursePrefix($0, courseName: courseName)) }
        let candidateOrdinals: [Int]
        if let explicitOrdinal {
            candidateOrdinals = [explicitOrdinal.major]
        } else if let preferredNumber {
            candidateOrdinals = [preferredNumber]
        } else {
            candidateOrdinals = []
        }

        for ordinal in candidateOrdinals {
            let matches = lectures.filter { lecture in
                if let lectureTitle = lecture.title,
                   Self.materialOrdinal(in: Self.stripCoursePrefix(lectureTitle, courseName: courseName))?.major == ordinal {
                    return true
                }
                return lecture.number == ordinal
            }
            if matches.count == 1 { return matches[0] }
        }

        guard candidateOrdinals.isEmpty else { return nil }

        if let title {
            let normalizedTitle = Self.normalizedLectureTitle(title, courseName: courseName)
            let exactMatches = lectures.filter {
                guard let lectureTitle = $0.title else { return false }
                return Self.normalizedLectureTitle(lectureTitle, courseName: courseName) == normalizedTitle
            }
            if exactMatches.count == 1 { return exactMatches[0] }
        }
        return nil
    }

    /// Move a source to another lecture of its course. The new lecture takes
    /// it first, and only then do the old lectures let it go, each item as
    /// the store deletes it: a failure leaves the source in both lectures,
    /// shown, never in neither. (Not one transaction: the item writes are the
    /// store's own `saveCourseLectureItem`/`deleteCourseLectureItem`, each
    /// committed on its own.)
    func moveArticle(_ articleId: String, toLecture targetLectureId: String, inCourse courseName: String) async {
        guard await addArticleToLecture(articleId: articleId, lectureId: targetLectureId) else { return }
        for lecture in courseLectures(for: courseName) where lecture.id != targetLectureId {
            let removed = (courseLectureItemsByLectureId[lecture.id] ?? []).filter { $0.sourceId == articleId }
            for item in removed {
                do {
                    try await storage.deleteCourseLectureItem(item.id)
                } catch {
                    logger.error("Could not take source \(articleId, privacy: .public) out of lecture \(lecture.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    showToast("Could not take it out of its old lecture: \(error.localizedDescription)")
                    continue
                }
                courseLectureItemsByLectureId[lecture.id]?.removeAll { $0.id == item.id }
            }
        }
    }

    static func materialOrdinal(for article: StudioArticle, courseName: String) -> CourseMaterialOrdinal? {
        var candidates = [stripCoursePrefix(article.title, courseName: courseName)]
        if let localFilePath = article.localFilePath {
            candidates.append((localFilePath as NSString).lastPathComponent)
            candidates.append((localFilePath as NSString).deletingPathExtension)
        }
        if article.url.hasPrefix("/") || article.url.contains("/") {
            candidates.append((article.url as NSString).lastPathComponent)
            candidates.append((article.url as NSString).deletingPathExtension)
        }
        for candidate in candidates {
            if let ordinal = materialOrdinal(in: candidate) {
                return ordinal
            }
        }
        return nil
    }

    nonisolated static func materialOrdinal(in rawTitle: String) -> CourseMaterialOrdinal? {
        let text = rawTitle.replacingOccurrences(of: "_", with: " ")

        // A sub-part is structural course metadata, not title meaning. Parse the
        // explicit shapes before the general ordinal patterns so "Lecture 3
        // Part a" and "Lecture 4 a - Topic" retain the detail that distinguishes
        // multiple videos belonging to the same lecture.
        for regex in CourseTitleParserCache.materialPartRegexes {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 2,
                  let majorRange = Range(match.range(at: 1), in: text),
                  let detailRange = Range(match.range(at: 2), in: text),
                  let major = Int(text[majorRange]),
                  major > 0 else { continue }
            return CourseMaterialOrdinal(
                kind: "lesson",
                major: major,
                detail: String(text[detailRange]).lowercased()
            )
        }

        for (kind, regex) in CourseTitleParserCache.materialRegexes {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[tokenRange]).lowercased()
            let majorString = token.prefix { $0.isNumber }
            guard let ordinal = Int(majorString),
                  ordinal > 0 else { continue }
            let detail: String?
            let suffix = token.dropFirst(majorString.count)
            if suffix.hasPrefix(".") {
                detail = String(suffix.dropFirst())
            } else if suffix.count == 1, suffix.first?.isLetter == true {
                detail = String(suffix)
            } else {
                detail = nil
            }
            return CourseMaterialOrdinal(kind: kind, major: ordinal, detail: detail)
        }
        return nil
    }

    static func playlistLectureNumber(from title: String, fallback: Int) -> Int {
        materialOrdinal(in: title)?.major ?? fallback
    }

    /// The range of a title's own leading lecture ordinal, if it has one: the
    /// normalized "3A) " prefix `Prompts.courseLectureTitleCleanup` puts on
    /// every title it can number, or an un-normalized "Lecture 3 - " on a title
    /// the cleanup never saw.
    nonisolated static func leadingLectureOrdinalRange(in title: String) -> Range<String.Index>? {
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        for regex in CourseTitleParserCache.displayLectureOrdinalPrefixes {
            guard let match = regex.firstMatch(in: title, range: range),
                  match.range.location == 0,
                  let matched = Range(match.range, in: title) else { continue }
            return matched
        }
        return nil
    }

    nonisolated static func titleLeadsWithLectureOrdinal(_ title: String) -> Bool {
        leadingLectureOrdinalRange(in: title) != nil
    }

    /// Number one row of a course or playlist outline. Cleaned lecture titles
    /// carry their own ordinal — that prefix is where a lecture *part* like
    /// "3A" lives, and it is what `materialOrdinal` reads back out — so a row
    /// that prepends `number` unconditionally numbered every imported lecture
    /// twice: "1) 1) Universal Patterns of Aging". The title's own ordinal
    /// wins; `number` fills in only for a title that names no lecture at all.
    nonisolated static func numberedOutlineRowTitle(_ title: String, number: Int) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\(number))" }
        guard !titleLeadsWithLectureOrdinal(trimmed) else { return trimmed }
        return "\(number)) \(trimmed)"
    }

    /// A numbered title's topic, for telling two titles that differ only by
    /// their ordinal ("3) Feed Forward Loops" and "3A) Feed Forward Loops")
    /// apart from a lecture whose title somebody rewrote. Comparison only —
    /// never stored, never displayed.
    nonisolated static func lectureTitleTopicKey(_ title: String) -> String {
        var topic = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ordinal = leadingLectureOrdinalRange(in: topic) {
            topic.removeSubrange(ordinal)
        }
        return normalizedCourseLabel(topic)
    }

    /// The title for one video row inside a course's Lectures folder. Rows are
    /// numbered by lecture, but a lecture split across several videos records
    /// the split in the videos' own titles ("3A)", "3B)") while the lecture
    /// keeps the major number — so the video's title wins when it names the
    /// same topic, and a lecture somebody retitled keeps winning.
    nonisolated static func courseLectureRowTitle(
        lectureNumber: Int,
        lectureTitle: String?,
        itemTitle: String
    ) -> String {
        let lecture = (lectureTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let item = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred: String
        if lecture.isEmpty {
            preferred = item
        } else if !item.isEmpty,
                  titleLeadsWithLectureOrdinal(item),
                  lectureTitleTopicKey(item) == lectureTitleTopicKey(lecture) {
            preferred = item
        } else {
            preferred = lecture
        }
        return numberedOutlineRowTitle(preferred, number: lectureNumber)
    }

    static func normalizedLectureTitle(_ title: String, courseName: String) -> String {
        stripCoursePrefix(title, courseName: courseName)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive])
            .components(separatedBy: CourseTitleParserCache.nonAlphanumeric)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated static func stripCoursePrefix(_ title: String, courseName: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func normalizedCourseLabel(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: CourseTitleParserCache.nonAlphanumeric)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated static func stripDanglingLectureSeparators(_ title: String) -> String {
        let fullRange = NSRange(title.startIndex..<title.endIndex, in: title)
        let withoutLeading = CourseTitleParserCache.leadingDanglingSeparators
            .stringByReplacingMatches(in: title, range: fullRange, withTemplate: "")
        let trailingRange = NSRange(withoutLeading.startIndex..<withoutLeading.endIndex, in: withoutLeading)
        return CourseTitleParserCache.trailingDanglingSeparators
            .stringByReplacingMatches(in: withoutLeading, range: trailingRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func inferredLectureItemRole(for article: StudioArticle) -> CourseLectureItemRole {
        switch article.sourceType {
        case .video: return .video
        case .podcast: return .podcast
        case .meeting: return .reference
        case .article, .xPost, .manual, .unclassified: return .article
        case .paper: return .reading
        case .book: return .reading
        case .course:
            let title = article.title.lowercased()
            let path = (article.localFilePath ?? article.url).lowercased()
            if title.contains("slide") || path.contains("slide") { return .slides }
            if title.contains("exercise") || title.contains("problem") || title.contains("assignment")
                || path.contains("exercise") || path.contains("problem") || path.contains("assignment") {
                return .exercise
            }
            return .notes
        }
    }

}
