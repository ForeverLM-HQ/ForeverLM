import Foundation

/// Lecture titles from what the lectures teach (docs/courses-design.md,
/// *Lecture titles*): the course menu's Retitle Lectures from Content, and
/// the step after a playlist import that names the lectures it added.
extension StudioViewModel {

    /// Names `lectureIDs` of `courseID` (every lecture when nil) for what
    /// each teaches. From the menu (`reportsResult`) it fetches transcripts
    /// never fetched first and says what changed in a toast. After an import
    /// it runs quietly: the transcripts were just fetched, and a failure costs
    /// only the names, which stay the videos' own.
    @discardableResult
    func retitleCourseLectures(
        courseID: String,
        lectureIDs: Set<String>? = nil,
        reportsResult: Bool = true
    ) async -> CourseLectureNamingResult? {
        guard !courseLectureNamingIDs.contains(courseID) else { return nil }
        let title = courseDisplayName(courseID)
        let namer: CourseLectureNamingService.Namer
        do {
            // Resolved before anything else, so a run never starts on a route
            // that cannot finish it.
            namer = try CourseLectureNamingService.liveNamer(aiService: aiService)
        } catch {
            report("Couldn't retitle the lectures of \(title): \(error.localizedDescription)", toast: reportsResult)
            return nil
        }
        courseLectureNamingIDs.insert(courseID)
        defer { courseLectureNamingIDs.remove(courseID) }

        if reportsResult {
            await fetchMissingLectureTranscripts(courseID: courseID, lectureIDs: lectureIDs)
        }
        do {
            let result = try await CourseLectureNamingService(storage: storage, name: namer)
                .run(courseID: courseID, lectureIDs: lectureIDs)
            await refreshCourseOutline()
            if reportsResult {
                showToast(Self.lectureNamingSummary(result, courseTitle: title))
            } else {
                logger.info("Named \(result.retitled.count) lecture(s) of '\(title)' from their content")
            }
            return result
        } catch {
            report("Couldn't retitle the lectures of \(title): \(error.localizedDescription)", toast: reportsResult)
            return nil
        }
    }

    private func report(_ message: String, toast: Bool) {
        if toast {
            showToast(message)
        } else {
            logger.warning("\(message)")
        }
    }

    /// The toast after a run: how many lectures were renamed, and why the
    /// others were not.
    static func lectureNamingSummary(_ result: CourseLectureNamingResult, courseTitle: String) -> String {
        var parts: [String] = []
        let renamed = result.retitled.count
        if renamed > 0 {
            parts.append("retitled \(renamed) lecture\(renamed == 1 ? "" : "s")")
        }
        if result.kept > 0 {
            parts.append(renamed == 0
                ? "every lecture's title already says what it teaches"
                : "\(result.kept) kept \(result.kept == 1 ? "its title" : "their titles")")
        }
        if !result.lecturesWithoutMaterial.isEmpty {
            let count = result.lecturesWithoutMaterial.count
            parts.append("\(count) lecture\(count == 1 ? " has" : "s have") no transcript yet")
        }
        return "\(courseTitle): " + (parts.isEmpty ? "no lectures to retitle" : parts.joined(separator: "; ")) + "."
    }
}
