import Foundation
import Testing
@testable import ForeverLM

/// Lecture titles from what the lectures teach (docs/courses-design.md,
/// *Lecture titles*): the model proposes, `CourseLectureNaming.retitles`
/// decides what is stored.
@Suite("Course Lecture Naming")
struct CourseLectureNamingTests {
    private func brief(_ number: Int, _ title: String, material: String = "Transcript text.") -> CourseLectureNamingBrief {
        CourseLectureNamingBrief(
            lectureID: "lecture-\(number)",
            number: number,
            currentTitle: title,
            itemTitles: [],
            material: material,
            wasCut: false
        )
    }

    private func request(
        _ lectures: [CourseLectureNamingBrief],
        others: [(number: Int, title: String)] = []
    ) -> CourseLectureNamingRequest {
        CourseLectureNamingRequest(
            courseID: "course",
            courseTitle: "Mitochondrial Cell Biology",
            instructors: nil,
            lectures: lectures,
            otherTitles: others
        )
    }

    private func draft(_ json: String) throws -> CourseLectureNamingDraft {
        try JSONDecoder().decode(CourseLectureNamingDraft.self, from: Data(json.utf8))
    }

    @Test("A series label is renamed and an informative title is kept")
    func renamesSeriesLabelsAndKeepsInformativeTitles() throws {
        let request = request([
            brief(1, "Mitochondrial Cell Biology 1"),
            brief(2, "Calcium Uptake by Mitochondria"),
        ])
        let answer = try draft("""
        {"lectures": [
          {"lecture": 1, "title": "Mitochondrial Dynamics and Cristae Structure"},
          {"lecture": 2, "title": "Calcium Uptake by Mitochondria"}
        ]}
        """)
        let retitles = CourseLectureNaming.retitles(
            from: answer,
            request: request,
            storedTitles: ["lecture-1": "1) Mitochondrial Cell Biology 1", "lecture-2": "2) Calcium Uptake by Mitochondria"]
        )
        #expect(retitles.map(\.lectureID) == ["lecture-1"])
        #expect(retitles.first?.storedTitle == "1) Mitochondrial Dynamics and Cristae Structure")
        #expect(retitles.first?.previousTitle == "Mitochondrial Cell Biology 1")
    }

    @Test("A lecture part keeps its ordinal in front of the new name")
    func keepsLecturePartOrdinal() {
        #expect(CourseLectureNaming.storedTitle("Proton Leak", replacing: "3A) Mitochondrial Cell Biology 3") == "3A) Proton Leak")
        #expect(CourseLectureNaming.storedTitle("Proton Leak", replacing: "Mitochondrial Cell Biology") == "Proton Leak")
        #expect(CourseLectureNaming.storedTitle("Proton Leak", replacing: nil) == "Proton Leak")
    }

    @Test("A lecture with nothing to read, or one never offered, is not renamed")
    func ignoresLecturesWithoutMaterialAndUnknownNumbers() throws {
        let request = request([
            brief(1, "Part 1", material: ""),
            brief(2, "Part 2"),
        ])
        let answer = try draft("""
        {"lectures": [
          {"lecture": 1, "title": "Invented Topic"},
          {"lecture": "2", "title": "The Electron Transport Chain"},
          {"lecture": 9, "title": "Not a Lecture"}
        ]}
        """)
        let retitles = CourseLectureNaming.retitles(from: answer, request: request, storedTitles: [:])
        #expect(retitles.map(\.lectureID) == ["lecture-2"])
        #expect(retitles.first?.storedTitle == "The Electron Transport Chain")
    }

    @Test("No two lectures end up under one title")
    func dropsDuplicateTitles() throws {
        let request = request(
            [brief(2, "Part 2"), brief(3, "Part 3"), brief(4, "Part 4")],
            others: [(number: 1, title: "ATP Synthase")]
        )
        let answer = try draft("""
        {"lectures": [
          {"lecture": 2, "title": "atp synthase"},
          {"lecture": 3, "title": "Proton Motive Force"},
          {"lecture": 4, "title": "Proton  Motive Force"}
        ]}
        """)
        let retitles = CourseLectureNaming.retitles(from: answer, request: request, storedTitles: [:])
        #expect(retitles.map(\.lectureID) == ["lecture-3"])
    }

    @Test("A proposal is cleaned of quotes, numbers and a trailing period, and a sentence is refused")
    func cleansProposals() {
        #expect(CourseLectureNaming.cleanedTitle("\u{201C}Lecture 4: Cardiolipin and Cristae.\u{201D}") == "Cardiolipin and Cristae")
        #expect(CourseLectureNaming.cleanedTitle("  Mitophagy \n and   Quality Control ") == "Mitophagy and Quality Control")
        #expect(CourseLectureNaming.cleanedTitle("") == nil)
        #expect(CourseLectureNaming.cleanedTitle(nil) == nil)
        #expect(CourseLectureNaming.cleanedTitle(String(repeating: "word ", count: 30)) == nil)
    }

    @Test("A malformed answer names nothing")
    func malformedDraftIsEmpty() throws {
        let answer = try draft(#"{"titles": ["A", "B"]}"#)
        #expect(answer.lectures.isEmpty)
        #expect(CourseLectureNaming.retitles(from: answer, request: request([brief(1, "Part 1")]), storedTitles: [:]).isEmpty)
    }

    @Test("The toast says what changed and why the rest did not")
    @MainActor
    func summaryNamesTheOutcome() {
        let result = CourseLectureNamingResult(
            courseID: "course",
            retitled: [CourseLectureRetitle(lectureID: "lecture-2", number: 2, previousTitle: "Part 2", storedTitle: "ATP Synthase")],
            kept: 3,
            lecturesWithoutMaterial: [5]
        )
        #expect(StudioViewModel.lectureNamingSummary(result, courseTitle: "Bioenergetics")
            == "Bioenergetics: retitled 1 lecture; 3 kept their titles; 1 lecture has no transcript yet.")
        let unchanged = CourseLectureNamingResult(courseID: "course", retitled: [], kept: 2, lecturesWithoutMaterial: [])
        #expect(StudioViewModel.lectureNamingSummary(unchanged, courseTitle: "Bioenergetics")
            == "Bioenergetics: every lecture's title already says what it teaches.")
    }

    @Test("Lecture Titles is a background course task with its own prompt")
    func taskIsRegistered() {
        #expect(AITask.courseLectureNaming.rawValue == "course_lecture_naming")
        #expect(AITask.courseLectureNaming.effectivePrompt != nil || !Prompts.courseLectureNaming.isEmpty)
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "course_lecture_naming")?.displayName == "Lecture Titles")
        #expect(AIUsageTaskLabel.text(for: "course_lecture_naming") == "Name Course Lectures")
    }
}
