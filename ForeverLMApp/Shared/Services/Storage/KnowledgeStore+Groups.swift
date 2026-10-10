import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    // MARK: - Course Groups

    func loadCourseGroups() throws -> [String: CourseMetadata] {
        var result: [String: CourseMetadata] = [:]
        try query("SELECT id, title, course_code, institution, instructors, playlist_url, is_hidden, pending_playlist_import FROM courses") { stmt in
            guard let id = string(stmt, 0) else { return }
            result[id] = CourseMetadata(
                courseCode: string(stmt, 2),
                title: string(stmt, 1),
                institution: string(stmt, 3),
                instructors: string(stmt, 4),
                playlistURL: string(stmt, 5),
                isHidden: sqlite3_column_int(stmt, 6) != 0,
                pendingPlaylistImport: sqlite3_column_int(stmt, 7) != 0
            )
        }
        return result
    }

    /// An upsert rather than `INSERT OR REPLACE`: a replace deletes the row
    /// first, and would take the course's `team_id` (schema 145) with it on
    /// every rename, hide or inbound apply.
    ///
    /// Whether a member hid a team's course is theirs (docs/teams-design.md,
    /// decision 21): the team's record never carries it, so a save that
    /// changes only that stays on this Mac instead of queueing the team's
    /// course — which a read-only member could not do at all.
    func saveCourseGroup(name: String, metadata: CourseMetadata) throws {
        var hidesOnlyForThisMember = false
        try queryBind("""
            SELECT title, course_code, institution, instructors, playlist_url,
                   is_hidden, pending_playlist_import, team_id
            FROM courses WHERE id = ?
        """, bind: { stmt in
            self.bind(stmt, 1, name)
        }) { stmt in
            guard self.string(stmt, 7) != nil else { return }
            let stored = CourseMetadata(
                courseCode: self.string(stmt, 1),
                title: self.string(stmt, 0),
                institution: self.string(stmt, 2),
                instructors: self.string(stmt, 3),
                playlistURL: self.string(stmt, 4),
                isHidden: metadata.isHidden,
                pendingPlaylistImport: sqlite3_column_int(stmt, 6) != 0
            )
            var incoming = metadata
            incoming.title = metadata.title ?? name
            hidesOnlyForThisMember = stored == incoming
        }
        try execBind("""
            INSERT INTO courses (
                id, title, course_code, institution, instructors, playlist_url,
                is_hidden, pending_playlist_import
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                course_code = excluded.course_code,
                institution = excluded.institution,
                instructors = excluded.instructors,
                playlist_url = excluded.playlist_url,
                is_hidden = excluded.is_hidden,
                pending_playlist_import = excluded.pending_playlist_import
        """) { stmt in
            bind(stmt, 1, name)
            bind(stmt, 2, metadata.title ?? name)
            bind(stmt, 3, metadata.courseCode)
            bind(stmt, 4, metadata.institution)
            bind(stmt, 5, metadata.instructors)
            bind(stmt, 6, metadata.playlistURL)
            sqlite3_bind_int(stmt, 7, metadata.isHidden ? 1 : 0)
            sqlite3_bind_int(stmt, 8, metadata.pendingPlaylistImport ? 1 : 0)
        }
        try keepCourseRowsForGeneration2(courseIDs: [name])
        guard !hidesOnlyForThisMember else { return }
        try markRecordChanged(entity: .course, logicalKey: name)
    }

    /// The team a course is a copy in, or nil for the learner's own.
    func courseTeamID(_ courseID: String) throws -> String? {
        var teamID: String?
        try queryBind("SELECT team_id FROM courses WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, courseID)
        }) { stmt in
            teamID = self.string(stmt, 0)
        }
        return teamID
    }

    /// The team of every course that is a team's (docs/teams-design.md,
    /// decision 21). A course of the learner's own library has no entry.
    func loadCourseTeamIDs() throws -> [String: String] {
        var result: [String: String] = [:]
        try query("SELECT id, team_id FROM courses WHERE team_id IS NOT NULL") { stmt in
            guard let id = string(stmt, 0), let teamID = string(stmt, 1) else { return }
            result[id] = teamID
        }
        return result
    }

    func loadCourseLectures() throws -> [CourseSession] {
        var result: [CourseSession] = []
        try query("""
            SELECT id, course_id, lecture_number, title, created_at
            FROM course_lectures
            ORDER BY course_id, lecture_number
        """) { stmt in
            guard let id = string(stmt, 0),
                  let courseName = string(stmt, 1) else { return }
            result.append(CourseSession(
                id: id,
                courseName: courseName,
                number: Int(sqlite3_column_int(stmt, 2)),
                title: string(stmt, 3),
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            ))
        }
        return result
    }

    func loadCourseLectureItems() throws -> [CourseLectureItem] {
        var result: [CourseLectureItem] = []
        try query("""
            SELECT id, lecture_id, source_id, source_unit_id, role, label, sort_index, created_at
            FROM course_lecture_items
            ORDER BY lecture_id, sort_index
        """) { stmt in
            guard let id = string(stmt, 0),
                  let lectureId = string(stmt, 1) else { return }
            let role = string(stmt, 4).flatMap(CourseLectureItemRole.init(rawValue:)) ?? .other
            result.append(CourseLectureItem(
                id: id,
                lectureId: lectureId,
                sourceId: string(stmt, 2),
                sourceUnitId: string(stmt, 3),
                role: role,
                label: string(stmt, 5),
                sortIndex: Int(sqlite3_column_int(stmt, 6)),
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7))
            ))
        }
        return result
    }

    /// Course covers come from the first video in each persisted outline. This
    /// intentionally reads archived sources too: archiving a lecture keeps its
    /// course relationship, and the course row should keep the video's artwork
    /// even though the source is absent from the active library index.
    func loadCourseArtworkURLs() throws -> [String: String] {
        var result: [String: String] = [:]
        try query("""
            SELECT cl.course_id, sp.url, sp.artwork_url
            FROM course_lectures cl
            JOIN course_lecture_items cli ON cli.lecture_id = cl.id
            JOIN source_projection sp ON sp.id = cli.source_id
            WHERE sp.source_type = 'video'
            ORDER BY cl.course_id, cl.lecture_number, cli.sort_index
        """) { stmt in
            guard let courseID = string(stmt, 0),
                  result[courseID] == nil,
                  let sourceURL = string(stmt, 1) else { return }
            let storedArtworkURL = string(stmt, 2)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let artworkURL = storedArtworkURL,
               !artworkURL.isEmpty {
                result[courseID] = artworkURL
            } else if let thumbnailURL = StudioArticle.youtubeThumbnailURL(for: sourceURL) {
                result[courseID] = thumbnailURL
            }
        }
        return result
    }

    func saveCourseLecture(_ lecture: CourseSession) throws {
        try execBind("""
            INSERT INTO course_lectures (id, course_id, lecture_number, title, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                course_id = excluded.course_id,
                lecture_number = excluded.lecture_number,
                title = excluded.title,
                created_at = excluded.created_at
        """) { stmt in
            bind(stmt, 1, lecture.id)
            bind(stmt, 2, lecture.courseName)
            bind(stmt, 3, lecture.number)
            bind(stmt, 4, lecture.title)
            sqlite3_bind_double(stmt, 5, lecture.createdAt.timeIntervalSinceReferenceDate)
        }
        try keepCourseRowsForGeneration2(courseIDs: [lecture.courseName])
        try markRecordChanged(entity: .course, logicalKey: lecture.courseName)
    }

    @discardableResult
    func saveCourseLectureItem(_ item: CourseLectureItem) throws -> Int {
        // A team's course names only the team's rows (docs/teams-design.md,
        // decision 21).
        var item = item
        if syncTrackingSuppressionDepth == 0, let courseID = try courseNameForLecture(item.lectureId) {
            item = try lectureItemFiledInCourse(item, courseID: courseID)
        }
        try exec("BEGIN IMMEDIATE")
        var notebookSourcesAdded = 0
        do {
            try execBind("""
                INSERT INTO course_lecture_items
                    (id, lecture_id, source_id, source_unit_id, role, label, sort_index, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    lecture_id = excluded.lecture_id,
                    source_id = excluded.source_id,
                    source_unit_id = excluded.source_unit_id,
                    role = excluded.role,
                    label = excluded.label,
                    sort_index = excluded.sort_index,
                    created_at = excluded.created_at
            """) { stmt in
                bind(stmt, 1, item.id)
                bind(stmt, 2, item.lectureId)
                bind(stmt, 3, item.sourceId)
                bind(stmt, 4, item.sourceUnitId)
                bind(stmt, 5, item.role.rawValue)
                bind(stmt, 6, item.label)
                bind(stmt, 7, item.sortIndex)
                sqlite3_bind_double(stmt, 8, item.createdAt.timeIntervalSinceReferenceDate)
            }
            if let courseName = try courseNameForLecture(item.lectureId) {
                if let sourceID = item.sourceId {
                    notebookSourcesAdded = try addSourcesToNotebooksLinkedToCourseInCurrentTransaction(
                        courseID: courseName,
                        sourceIDs: [sourceID]
                    )
                }
                try keepCourseRowsForGeneration2(courseIDs: [courseName])
                try markRecordChanged(entity: .course, logicalKey: courseName)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return notebookSourcesAdded
    }

    func deleteCourseLectureItem(_ itemId: String) throws {
        let courseName = try courseNameForLectureItem(itemId)
        try execBind("DELETE FROM course_lecture_items WHERE id = ?") { stmt in
            bind(stmt, 1, itemId)
        }
        if let courseName {
            try markRecordChanged(entity: .course, logicalKey: courseName)
        }
    }

    func deleteCourseLecture(_ lectureId: String) throws {
        let courseName = try courseNameForLecture(lectureId)
        try execBind("DELETE FROM course_lectures WHERE id = ?") { stmt in
            bind(stmt, 1, lectureId)
        }
        if let courseName {
            try markRecordChanged(entity: .course, logicalKey: courseName)
        }
    }

    func saveSourceUnit(_ unit: SourceUnit) throws {
        try execBind("""
            INSERT INTO source_units (id, source_id, kind, locator, title)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source_id = excluded.source_id,
                kind = excluded.kind,
                locator = excluded.locator,
                title = excluded.title
        """) { stmt in
            bind(stmt, 1, unit.id)
            bind(stmt, 2, unit.sourceId)
            bind(stmt, 3, unit.kind)
            bind(stmt, 4, unit.locator)
            bind(stmt, 5, unit.title)
        }
        try markRecordChanged(entity: .source, logicalKey: unit.sourceId)
    }

    func loadSourceUnitsForSync(_ sourceID: String) throws -> [SourceUnit] {
        var units: [SourceUnit] = []
        try queryBind("""
            SELECT id, source_id, kind, locator, title
            FROM source_units
            WHERE source_id = ?
            ORDER BY kind, locator, id
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let sourceID = self.string(stmt, 1),
                  let kind = self.string(stmt, 2),
                  let locator = self.string(stmt, 3) else { return }
            units.append(
                SourceUnit(
                    id: id,
                    sourceId: sourceID,
                    kind: kind,
                    locator: locator,
                    title: self.string(stmt, 4)
                )
            )
        }
        return units
    }

    /// A source record's units, as another Mac sent them. Merged, never
    /// replaced: a lecture item names its unit with `ON DELETE CASCADE`, so
    /// deleting and re-inserting the same unit deleted every reading that used
    /// it, and a peer that had not heard of a unit yet would have taken the
    /// reading with it. A unit the record does not carry goes only when no
    /// lecture item names it.
    func saveSourceUnitsRecord(sourceID: String, units: [SourceUnit]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for unit in units {
                try execBind("""
                    INSERT INTO source_units (id, source_id, kind, locator, title)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        source_id = excluded.source_id,
                        kind = excluded.kind,
                        locator = excluded.locator,
                        title = excluded.title
                """) { stmt in
                    bind(stmt, 1, unit.id)
                    bind(stmt, 2, sourceID)
                    bind(stmt, 3, unit.kind)
                    bind(stmt, 4, unit.locator)
                    bind(stmt, 5, unit.title)
                }
            }
            let carried = Set(units.map(\.id))
            var stale: [String] = []
            try queryBind("""
                SELECT su.id FROM source_units su
                WHERE su.source_id = ?
                  AND NOT EXISTS (
                        SELECT 1 FROM course_lecture_items cli WHERE cli.source_unit_id = su.id
                  )
            """, bind: { stmt in
                self.bind(stmt, 1, sourceID)
            }) { stmt in
                if let id = self.string(stmt, 0), !carried.contains(id) { stale.append(id) }
            }
            for id in stale {
                try execBind("DELETE FROM source_units WHERE id = ?") { stmt in
                    bind(stmt, 1, id)
                }
            }
            try markRecordChanged(entity: .source, logicalKey: sourceID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func saveCourseOutline(courseName: String, lectures: [CourseSession], items: [CourseLectureItem]) throws {
        // A team's course names only the team's rows (docs/teams-design.md,
        // decision 21); two items that become one row are one item. A record
        // arriving from the team's zone is stored as it says.
        var items = items
        if syncTrackingSuppressionDepth == 0, try courseTeamID(courseName) != nil {
            var keys = Set<String>()
            items = try items
                .map { try lectureItemFiledInCourse($0, courseID: courseName) }
                .filter { keys.insert("\($0.lectureId)|\($0.sourceId ?? "")|\($0.sourceUnitId ?? "")").inserted }
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM course_lecture_items WHERE lecture_id IN (SELECT id FROM course_lectures WHERE course_id = ?)") { stmt in
                bind(stmt, 1, courseName)
            }
            try execBind("DELETE FROM course_lectures WHERE course_id = ?") { stmt in
                bind(stmt, 1, courseName)
            }
            for lecture in lectures {
                try execBind("""
                    INSERT INTO course_lectures (id, course_id, lecture_number, title, created_at)
                    VALUES (?, ?, ?, ?, ?)
                """) { stmt in
                    bind(stmt, 1, lecture.id)
                    bind(stmt, 2, lecture.courseName)
                    bind(stmt, 3, lecture.number)
                    bind(stmt, 4, lecture.title)
                    sqlite3_bind_double(stmt, 5, lecture.createdAt.timeIntervalSinceReferenceDate)
                }
            }
            for item in items {
                try execBind("""
                    INSERT INTO course_lecture_items
                        (id, lecture_id, source_id, source_unit_id, role, label, sort_index, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """) { stmt in
                    bind(stmt, 1, item.id)
                    bind(stmt, 2, item.lectureId)
                    bind(stmt, 3, item.sourceId)
                    bind(stmt, 4, item.sourceUnitId)
                    bind(stmt, 5, item.role.rawValue)
                    bind(stmt, 6, item.label)
                    bind(stmt, 7, item.sortIndex)
                    sqlite3_bind_double(stmt, 8, item.createdAt.timeIntervalSinceReferenceDate)
                }
            }
            _ = try addSourcesToNotebooksLinkedToCourseInCurrentTransaction(
                courseID: courseName,
                sourceIDs: items.compactMap(\.sourceId)
            )
            try keepCourseRowsForGeneration2(courseIDs: [courseName])
            try markRecordChanged(entity: .course, logicalKey: courseName)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Course-typed sources reachable from no course at all.
    ///
    /// The Courses tab lists courses and nothing else, so a `source_type =
    /// 'course'` source appears in it only through a course, either as an item in
    /// one of its lectures or as a direct member of its group. A course source
    /// attached to neither is in the library without being in any list — still
    /// indexed, searchable and eligible for review, but absent from every sidebar
    /// tab and from the phone.
    ///
    /// "A course" means what `StudioViewModel.allCourseGroupNames` means by it: a
    /// `courses` row, or a `course_lectures` row naming that course. So a lecture
    /// item always counts (its lecture is itself a course group), while a
    /// membership counts only when its `group_id` still names one — a membership
    /// pointing at a course that is gone entirely is as unreachable as none.
    /// A hidden course is deliberately still a course: unhiding it has to bring
    /// its material back, which it cannot do if that material was hidden too.
    ///
    /// A lecture item may name a source unit rather than the source itself. That
    /// still attaches the source to the course, so those are excluded too.
    func courseSourceIDsWithoutCourse() throws -> [String] {
        var sourceIDs: [String] = []
        try query("""
            SELECT s.id
            FROM sources s
            WHERE s.source_type = 'course'
              AND s.status = 'active'
              AND NOT EXISTS (
                    SELECT 1
                    FROM group_members gm
                    WHERE gm.source_id = s.id
                      AND (
                            EXISTS (SELECT 1 FROM courses c WHERE c.id = gm.group_id)
                         OR EXISTS (
                                SELECT 1 FROM course_lectures cl
                                WHERE cl.course_id = gm.group_id
                            )
                      )
                  )
              AND NOT EXISTS (
                    SELECT 1
                    FROM course_lecture_items cli
                    JOIN course_lectures cl ON cl.id = cli.lecture_id
                    WHERE cli.source_id = s.id
                  )
              AND NOT EXISTS (
                    SELECT 1
                    FROM course_lecture_items cli
                    JOIN source_units su ON su.id = cli.source_unit_id
                    JOIN course_lectures cl ON cl.id = cli.lecture_id
                    WHERE su.source_id = s.id
                  )
              AND NOT EXISTS (
                    SELECT 1 FROM hidden_sources hs WHERE hs.source_id IN (s.id, s.wire_key)
                  )
            ORDER BY s.id
        """) { stmt in
            if let sourceID = string(stmt, 0) {
                sourceIDs.append(sourceID)
            }
        }
        return sourceIDs
    }

    /// Hide the course sources `courseSourceIDsWithoutCourse()` finds, so "not in
    /// a course" and "not surfaced anywhere" stay the same statement. Removing a
    /// course used to leave its own PDFs and notes behind as active library rows
    /// no list could show — 104 of them, from twelve courses, on the first
    /// library that hit it.
    ///
    /// Hidden rather than archived: the source keeps its text and its place, the
    /// Courses tab's hidden menu lists it, and unhiding is one click. Archiving
    /// would take the text with it.
    ///
    /// `limitedTo` scopes the sweep to sources the caller just detached, so
    /// deleting one course can never hide material belonging to an import still
    /// in flight. Passing nil sweeps the whole library, which is what the
    /// one-time version 73 migration does for the historical backlog.
    ///
    /// Callers hold the surrounding write transaction.
    @discardableResult
    func hideCourseSourcesWithoutCourse(
        limitedTo sourceIDs: [String]? = nil,
        at now: Date = Date()
    ) throws -> [String] {
        var detached = try courseSourceIDsWithoutCourse()
        if let sourceIDs {
            let scope = Set(sourceIDs)
            detached = detached.filter { scope.contains($0) }
        }
        for sourceID in detached {
            try writeSourceHidden(sourceID, hidden: true, hiddenAt: now)
            // `upsertSyncSave` rather than `markRecordChanged`: same rows, minus
            // one store-changed notification per source. Inbound course
            // deletions run under `withoutSyncTracking`, where the local hide
            // still has to happen but must not echo back as a change of ours.
            guard syncTrackingSuppressionDepth == 0 else { continue }
            try upsertSyncSave(entity: .hiddenSource, logicalKey: sourceID, at: now)
            try upsertSyncSave(entity: .source, logicalKey: sourceID, at: now)
        }
        return detached
    }

    /// A `group_members` row whose source is not a book chapter. A chapter has
    /// one membership, its book's, whichever table also uses that id.
    static let groupMemberIsNotBookChapterSQL = """
        NOT EXISTS (
            SELECT 1 FROM sources s
            WHERE s.id = group_members.source_id AND s.source_type = 'book'
        )
        """

    /// Delete a course and everything that made it a course. Returns the course
    /// sources hidden because the deletion left them in no course — see
    /// `hideCourseSourcesWithoutCourse`.
    ///
    /// A book chapter's membership is never the course's. Books and courses
    /// share the `group_members` id space, and a legacy `courses` row can carry
    /// a book's own id: deleting the hidden "Molecular Biology of the Cell"
    /// course on 2026-09-27 took all 24 of that book's chapters out of it, and
    /// each one showed as a separate book with its file path for a subtitle.
    @discardableResult
    func deleteCourseGroup(name: String) throws -> [String] {
        var affectedSourceIDs: [String] = []
        try queryBind("""
            SELECT source_id
            FROM group_members
            WHERE group_id = ?
              AND \(Self.groupMemberIsNotBookChapterSQL)
        """, bind: { stmt in
            bind(stmt, 1, name)
        }) { stmt in
            if let sourceID = self.string(stmt, 0) {
                affectedSourceIDs.append(sourceID)
            }
        }

        // The sweep below only considers sources this course held, so an import
        // that has not reached its own course yet is never caught by it.
        var detachedSourceIDs = Set(affectedSourceIDs)
        try queryBind("""
            SELECT cli.source_id
            FROM course_lecture_items cli
            JOIN course_lectures cl ON cl.id = cli.lecture_id
            WHERE cl.course_id = ? AND cli.source_id IS NOT NULL
        """, bind: { stmt in
            bind(stmt, 1, name)
        }) { stmt in
            if let sourceID = self.string(stmt, 0) {
                detachedSourceIDs.insert(sourceID)
            }
        }

        var linkedNotebookIDs: [String] = []
        try queryBind(
            "SELECT goal_id FROM notebook_course_links WHERE course_id = ? ORDER BY goal_id",
            bind: { stmt in bind(stmt, 1, name) }
        ) { stmt in
            if let notebookID = self.string(stmt, 0) {
                linkedNotebookIDs.append(notebookID)
            }
        }

        var hiddenSourceIDs: [String] = []
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM course_lecture_items WHERE lecture_id IN (SELECT id FROM course_lectures WHERE course_id = ?)") { stmt in
                bind(stmt, 1, name)
            }
            try execBind("DELETE FROM course_lectures WHERE course_id = ?") { stmt in
                bind(stmt, 1, name)
            }
            try execBind("DELETE FROM courses WHERE id = ?") { stmt in
                bind(stmt, 1, name)
            }
            try deleteCourseQuizzesInCurrentTransaction(courseID: name)
            // Also remove group memberships and Notebook subscriptions. Existing
            // Notebook source rows remain — deleting a course must not delete the
            // learner's accumulated Notebook context.
            try execBind("""
                DELETE FROM group_members
                WHERE group_id = ?
                  AND \(Self.groupMemberIsNotBookChapterSQL)
            """) { stmt in
                bind(stmt, 1, name)
            }
            try execBind("DELETE FROM notebook_course_links WHERE course_id = ?") { stmt in
                bind(stmt, 1, name)
            }
            let now = Date()
            for notebookID in linkedNotebookIDs {
                try touchLearningGoal(notebookID, at: now)
                try markRecordChanged(entity: .learningGoal, logicalKey: notebookID)
            }
            try markRecordDeleted(entity: .course, logicalKey: name)
            for sourceID in affectedSourceIDs {
                try markRecordChanged(entity: .source, logicalKey: sourceID)
            }
            // The course is gone, so its own material has nowhere left to show.
            hiddenSourceIDs = try hideCourseSourcesWithoutCourse(
                limitedTo: Array(detachedSourceIDs),
                at: now
            )
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return hiddenSourceIDs
    }

    /// Every canonical source currently attached to a course, with lecture items
    /// first in pedagogical order and direct group members appended in their stored
    /// order. De-duplication keeps sources linked through both representations once.
    func sourceIDsForCourse(_ courseID: String) throws -> [String] {
        var sourceIDs: [String] = []
        var seen = Set<String>()
        try queryBind("""
            SELECT cli.source_id
            FROM course_lectures cl
            JOIN course_lecture_items cli ON cli.lecture_id = cl.id
            JOIN sources s ON s.id = cli.source_id
            WHERE cl.course_id = ?
              AND cli.source_id IS NOT NULL
              AND s.status = 'active'
            ORDER BY cl.lecture_number, cli.sort_index, cli.created_at, cli.id
        """, bind: { stmt in
            bind(stmt, 1, courseID)
        }) { stmt in
            guard let sourceID = self.string(stmt, 0), seen.insert(sourceID).inserted else { return }
            sourceIDs.append(sourceID)
        }
        try queryBind("""
            SELECT gm.source_id
            FROM group_members gm
            JOIN sources s ON s.id = gm.source_id
            WHERE gm.group_id = ?
              AND s.status = 'active'
            ORDER BY COALESCE(gm.sort_index, 2147483647), gm.source_id
        """, bind: { stmt in
            bind(stmt, 1, courseID)
        }) { stmt in
            guard let sourceID = self.string(stmt, 0), seen.insert(sourceID).inserted else { return }
            sourceIDs.append(sourceID)
        }
        return sourceIDs
    }

    func courseNameForLecture(_ lectureId: String) throws -> String? {
        var courseName: String?
        try queryBind("SELECT course_id FROM course_lectures WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, lectureId)
        }) { stmt in
            courseName = string(stmt, 0)
        }
        return courseName
    }

    // MARK: - Video Playlist Groups

    func loadVideoPlaylistGroups() throws -> [String: VideoPlaylistMetadata] {
        var result: [String: VideoPlaylistMetadata] = [:]
        try query("""
            SELECT id, title, playlist_url, last_refreshed_at, is_hidden, auto_import, connector_kind
            FROM video_playlists
        """) { stmt in
            guard let id = string(stmt, 0),
                  let title = string(stmt, 1),
                  let playlistURL = string(stmt, 2) else { return }
            let lastRefreshedAt: Date?
            if sqlite3_column_type(stmt, 3) == SQLITE_NULL {
                lastRefreshedAt = nil
            } else {
                lastRefreshedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            }
            result[id] = VideoPlaylistMetadata(
                title: title,
                playlistURL: playlistURL,
                lastRefreshedAt: lastRefreshedAt,
                isHidden: sqlite3_column_int(stmt, 4) != 0,
                autoImport: sqlite3_column_int(stmt, 5) != 0,
                connectorKind: string(stmt, 6)
            )
        }
        return result
    }

    func saveVideoPlaylistGroup(id: String, metadata: VideoPlaylistMetadata) throws {
        // An upsert, never a replace: a replace fires only the row's INSERT trigger and would
        // re-date every column of the playlist's Collection under generation 2 (schema v2 §6.6).
        try execBind("""
            INSERT INTO video_playlists (id, title, playlist_url, last_refreshed_at, is_hidden, auto_import, connector_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                playlist_url = excluded.playlist_url,
                last_refreshed_at = excluded.last_refreshed_at,
                is_hidden = excluded.is_hidden,
                auto_import = excluded.auto_import,
                connector_kind = excluded.connector_kind
        """) { stmt in
            bind(stmt, 1, id)
            bind(stmt, 2, metadata.title)
            bind(stmt, 3, metadata.playlistURL)
            if let lastRefreshedAt = metadata.lastRefreshedAt {
                sqlite3_bind_double(stmt, 4, lastRefreshedAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int(stmt, 5, metadata.isHidden ? 1 : 0)
            sqlite3_bind_int(stmt, 6, metadata.autoImport ? 1 : 0)
            if let connectorKind = metadata.connectorKind {
                bind(stmt, 7, connectorKind)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
        }
        try markRecordChanged(entity: .videoPlaylist, logicalKey: id)
    }

    func loadVideoPlaylistForSync(_ id: String) throws -> CloudKitVideoPlaylistPayload? {
        guard let metadata = try loadVideoPlaylistGroups()[id] else { return nil }
        return CloudKitVideoPlaylistPayload(id: id, metadata: metadata)
    }

    func deleteVideoPlaylistGroup(id: String) throws {
        var affectedSourceIDs: [String] = []
        try queryBind("SELECT source_id FROM group_members WHERE group_id = ?", bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            if let sourceID = self.string(stmt, 0) {
                affectedSourceIDs.append(sourceID)
            }
        }
        try execBind("DELETE FROM video_playlists WHERE id = ?") { stmt in
            bind(stmt, 1, id)
        }
        try execBind("DELETE FROM group_members WHERE group_id = ?") { stmt in
            bind(stmt, 1, id)
        }
        try markRecordDeleted(entity: .videoPlaylist, logicalKey: id)
        for sourceID in affectedSourceIDs {
            try markRecordChanged(entity: .source, logicalKey: sourceID)
        }
    }

    func courseNameForLectureItem(_ itemId: String) throws -> String? {
        var courseName: String?
        try queryBind("""
            SELECT cl.course_id
            FROM course_lecture_items cli
            JOIN course_lectures cl ON cl.id = cli.lecture_id
            WHERE cli.id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, itemId)
        }) { stmt in
            courseName = string(stmt, 0)
        }
        return courseName
    }

    // MARK: - Meeting Groups

    func loadMeetingGroups() throws -> [String: MeetingMetadata] {
        var result: [String: MeetingMetadata] = [:]
        try query("""
            SELECT id, title, drive_folder_url, local_folder_path, recurrence_rule, timezone, is_hidden,
                   merged_into_group_id, schedule_json
            FROM meeting_groups
        """) { stmt in
            guard let id = string(stmt, 0) else { return }
            result[id] = MeetingMetadata(
                title: string(stmt, 1),
                driveFolderURL: string(stmt, 2),
                localFolderPath: string(stmt, 3),
                recurrenceRule: string(stmt, 4),
                timezone: string(stmt, 5),
                isHidden: sqlite3_column_int(stmt, 6) != 0,
                mergedIntoGroupID: string(stmt, 7),
                schedule: MeetingSchedule(jsonString: string(stmt, 8))
            )
        }
        return result
    }

    /// The series that meet at a fixed time, canonical ids only (a merged-away
    /// alias never draws), for the Planner to put on the clock.
    func scheduledMeetingGroups() throws -> [(id: String, title: String, schedule: MeetingSchedule)] {
        var result: [(id: String, title: String, schedule: MeetingSchedule)] = []
        try query("""
            SELECT id, title, schedule_json
            FROM meeting_groups
            WHERE schedule_json IS NOT NULL AND is_hidden = 0
              AND (merged_into_group_id IS NULL OR merged_into_group_id = '')
            ORDER BY id
        """) { stmt in
            guard let id = string(stmt, 0), let schedule = MeetingSchedule(jsonString: string(stmt, 2)), schedule.isValid else { return }
            result.append((id: id, title: string(stmt, 1) ?? id, schedule: schedule))
        }
        return result
    }

    /// Every meeting group id, for the Planner's reconcile: a series whose
    /// schedule was cleared must have its occurrences taken off the clock.
    func meetingGroupIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM meeting_groups") { stmt in
            if let id = string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    func saveMeetingGroup(name: String, metadata: MeetingMetadata) throws {
        // An upsert, never a replace (schema v2 §6.6): the same row, and only the columns that
        // changed are dated.
        try execBind("""
            INSERT INTO meeting_groups
                (id, title, drive_folder_url, local_folder_path, recurrence_rule, timezone, is_hidden,
                 merged_into_group_id, schedule_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                drive_folder_url = excluded.drive_folder_url,
                local_folder_path = excluded.local_folder_path,
                recurrence_rule = excluded.recurrence_rule,
                timezone = excluded.timezone,
                is_hidden = excluded.is_hidden,
                merged_into_group_id = excluded.merged_into_group_id,
                schedule_json = excluded.schedule_json
        """) { stmt in
            bind(stmt, 1, name)
            bind(stmt, 2, metadata.title ?? name)
            bind(stmt, 3, metadata.driveFolderURL)
            bind(stmt, 4, metadata.localFolderPath)
            bind(stmt, 5, metadata.recurrenceRule)
            bind(stmt, 6, metadata.timezone)
            sqlite3_bind_int(stmt, 7, metadata.isHidden ? 1 : 0)
            bind(stmt, 8, metadata.mergedIntoGroupID)
            bind(stmt, 9, metadata.schedule?.jsonString)
        }
        try markRecordChanged(entity: .meetingGroup, logicalKey: name)
    }

    /// Follow a durable meeting-group alias to the active destination. Chains
    /// are supported because a destination can itself be merged later. A cycle
    /// is corrupt data and fails loudly instead of routing an import arbitrarily.
    func canonicalMeetingGroupID(_ groupID: String) throws -> String {
        var current = groupID
        var visited = Set<String>()
        while true {
            guard visited.insert(current).inserted else {
                throw KnowledgeStoreError.invalidData("Meeting group aliases contain a cycle at \(current).")
            }
            var next: String?
            try queryBind(
                "SELECT merged_into_group_id FROM meeting_groups WHERE id = ? LIMIT 1",
                bind: { stmt in bind(stmt, 1, current) }
            ) { stmt in
                next = string(stmt, 0)
            }
            guard let next, !next.isEmpty else { return current }
            current = next
        }
    }

    /// Resolve either the stable ID or human title used by an incoming meeting
    /// plugin, then follow any merge alias to its active destination.
    func resolvedMeetingGroupID(matching input: String) throws -> String? {
        var match: String?
        try queryBind(
            "SELECT id FROM meeting_groups WHERE id = ? OR title = ? COLLATE NOCASE ORDER BY CASE WHEN id = ? THEN 0 ELSE 1 END LIMIT 1",
            bind: { stmt in
                bind(stmt, 1, input)
                bind(stmt, 2, input)
                bind(stmt, 3, input)
            }
        ) { stmt in
            match = string(stmt, 0)
        }
        guard let match else { return nil }
        return try canonicalMeetingGroupID(match)
    }

    /// Move a meeting group into another without discarding the source identity.
    /// Sources, artifacts, aliasing, and CloudKit change rows commit together.
    func mergeMeetingGroup(_ sourceGroupID: String, into targetGroupID: String) throws {
        let canonicalSource = try canonicalMeetingGroupID(sourceGroupID)
        let canonicalTarget = try canonicalMeetingGroupID(targetGroupID)
        guard canonicalSource != canonicalTarget else { return }
        let groups = try loadMeetingGroups()
        guard groups[canonicalSource] != nil, groups[canonicalTarget] != nil else {
            throw KnowledgeStoreError.invalidData("Both meeting groups must exist before they can be merged.")
        }

        var sourceIDs: [String] = []
        try queryBind("SELECT source_id FROM group_members WHERE group_id = ?", bind: { stmt in
            bind(stmt, 1, canonicalSource)
        }) { stmt in
            if let sourceID = string(stmt, 0) { sourceIDs.append(sourceID) }
        }

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT OR IGNORE INTO group_members (source_id, group_id, sort_index, lecture_group_id)
                SELECT source_id, ?, sort_index, lecture_group_id
                FROM group_members WHERE group_id = ?
            """) { stmt in
                bind(stmt, 1, canonicalTarget)
                bind(stmt, 2, canonicalSource)
            }
            try execBind("DELETE FROM group_members WHERE group_id = ?") { stmt in
                bind(stmt, 1, canonicalSource)
            }
            try execBind("UPDATE meeting_artifacts SET group_id = ? WHERE group_id = ?") { stmt in
                bind(stmt, 1, canonicalTarget)
                bind(stmt, 2, canonicalSource)
            }
            // The sessions' action items follow them into the target series,
            // so the Planner's block for the merged series still lists them.
            try execBind("UPDATE meeting_action_items SET group_id = ? WHERE group_id = ?") { stmt in
                bind(stmt, 1, canonicalTarget)
                bind(stmt, 2, canonicalSource)
            }
            try execBind("""
                UPDATE meeting_groups
                SET is_hidden = 1, merged_into_group_id = ?
                WHERE id = ?
            """) { stmt in
                bind(stmt, 1, canonicalTarget)
                bind(stmt, 2, canonicalSource)
            }
            for sourceID in sourceIDs {
                try markRecordChanged(entity: .source, logicalKey: sourceID)
            }
            try markRecordChanged(entity: .meetingGroup, logicalKey: canonicalSource)
            try markRecordChanged(entity: .meetingGroup, logicalKey: canonicalTarget)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// A session moved to another series takes its recording and transcript
    /// rows with it. Their `group_id` names the series too — a series'
    /// listing and its Delete Series read it — so rows left naming the old
    /// series would hide from a listing of the new one and go with the old
    /// folder when it is deleted. Returns the series the rows named before.
    @discardableResult
    func moveMeetingArtifacts(sourceID: String, toGroupID groupID: String) throws -> Set<String> {
        var previous: Set<String> = []
        try queryBind(
            "SELECT DISTINCT group_id FROM meeting_artifacts WHERE source_id = ? AND group_id != ?",
            bind: { stmt in
                bind(stmt, 1, sourceID)
                bind(stmt, 2, groupID)
            }
        ) { stmt in
            if let id = string(stmt, 0) { previous.insert(id) }
        }
        guard !previous.isEmpty else { return previous }
        try execBind("UPDATE meeting_artifacts SET group_id = ? WHERE source_id = ? AND group_id != ?") { stmt in
            bind(stmt, 1, groupID)
            bind(stmt, 2, sourceID)
            bind(stmt, 3, groupID)
        }
        for id in previous.union([groupID]) {
            try markRecordChanged(entity: .meetingGroup, logicalKey: id)
        }
        return previous
    }

    func loadMeetingArtifacts(groupID: String? = nil, sourceID: String? = nil) throws -> [MeetingArtifact] {
        var clauses: [String] = []
        var params: [String] = []
        if let groupID {
            clauses.append("group_id = ?")
            params.append(groupID)
        }
        if let sourceID {
            clauses.append("source_id = ?")
            params.append(sourceID)
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        var result: [MeetingArtifact] = []
        try queryBind("""
            SELECT id, source_id, group_id, kind, title, url, local_file_path, mime_type, modified_at, sort_index
            FROM meeting_artifacts
            \(whereClause)
            ORDER BY group_id, source_id, sort_index, title
        """, bind: { stmt in
            for (index, param) in params.enumerated() {
                bind(stmt, index + 1, param)
            }
        }) { stmt in
            guard let id = string(stmt, 0),
                  let sourceID = string(stmt, 1),
                  let groupID = string(stmt, 2),
                  let kindRaw = string(stmt, 3),
                  let title = string(stmt, 4) else { return }
            let modifiedAt: Date?
            if sqlite3_column_type(stmt, 8) == SQLITE_NULL {
                modifiedAt = nil
            } else {
                modifiedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8))
            }
            result.append(MeetingArtifact(
                id: id,
                sourceId: sourceID,
                groupId: groupID,
                kind: MeetingArtifactKind(rawValue: kindRaw) ?? .attachment,
                title: title,
                url: string(stmt, 5),
                localFilePath: string(stmt, 6),
                mimeType: string(stmt, 7),
                modifiedAt: modifiedAt,
                sortIndex: Int(sqlite3_column_int(stmt, 9))
            ))
        }
        return result
    }

    func saveMeetingArtifact(_ artifact: MeetingArtifact) throws {
        try execBind("""
            INSERT INTO meeting_artifacts
                (id, source_id, group_id, kind, title, url, local_file_path, mime_type, modified_at, sort_index)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source_id = excluded.source_id,
                group_id = excluded.group_id,
                kind = excluded.kind,
                title = excluded.title,
                url = excluded.url,
                local_file_path = excluded.local_file_path,
                mime_type = excluded.mime_type,
                modified_at = excluded.modified_at,
                sort_index = excluded.sort_index
        """) { stmt in
            bind(stmt, 1, artifact.id)
            bind(stmt, 2, artifact.sourceId)
            bind(stmt, 3, artifact.groupId)
            bind(stmt, 4, artifact.kind.rawValue)
            bind(stmt, 5, artifact.title)
            bind(stmt, 6, artifact.url)
            bind(stmt, 7, artifact.localFilePath.map { StorageService.relativeSourcePath($0) })
            bind(stmt, 8, artifact.mimeType)
            if let modifiedAt = artifact.modifiedAt {
                sqlite3_bind_double(stmt, 9, modifiedAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            bind(stmt, 10, artifact.sortIndex)
        }
        try markRecordChanged(entity: .meetingGroup, logicalKey: artifact.groupId)
    }

    func saveMeetingArtifactsRecord(groupID: String, artifacts: [MeetingArtifact]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM meeting_artifacts WHERE group_id = ?") { stmt in
                bind(stmt, 1, groupID)
            }
            for artifact in artifacts {
                try execBind("""
                    INSERT INTO meeting_artifacts
                        (id, source_id, group_id, kind, title, url, local_file_path, mime_type, modified_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { stmt in
                    bind(stmt, 1, artifact.id)
                    bind(stmt, 2, artifact.sourceId)
                    bind(stmt, 3, groupID)
                    bind(stmt, 4, artifact.kind.rawValue)
                    bind(stmt, 5, artifact.title)
                    bind(stmt, 6, artifact.url)
                    bind(stmt, 7, artifact.localFilePath)
                    bind(stmt, 8, artifact.mimeType)
                    if let modifiedAt = artifact.modifiedAt {
                        sqlite3_bind_double(stmt, 9, modifiedAt.timeIntervalSinceReferenceDate)
                    } else {
                        sqlite3_bind_null(stmt, 9)
                    }
                    bind(stmt, 10, artifact.sortIndex)
                }
            }
            try markRecordChanged(entity: .meetingGroup, logicalKey: groupID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func loadMeetingGroupForSync(_ name: String) throws -> CloudKitMeetingGroupPayload? {
        guard let metadata = try loadMeetingGroups()[name] else { return nil }
        return CloudKitMeetingGroupPayload(
            id: name,
            metadata: metadata,
            artifacts: try loadMeetingArtifacts(groupID: name),
            actionItems: try loadMeetingActionItems(groupID: name)
        )
    }

    func deleteMeetingGroup(name: String) throws {
        var affectedSourceIDs: [String] = []
        try queryBind("SELECT source_id FROM group_members WHERE group_id = ?", bind: { stmt in
            bind(stmt, 1, name)
        }) { stmt in
            if let sourceID = self.string(stmt, 0) {
                affectedSourceIDs.append(sourceID)
            }
        }
        try execBind("DELETE FROM meeting_artifacts WHERE group_id = ?") { stmt in
            bind(stmt, 1, name)
        }
        try deleteMeetingActionItems(groupID: name)
        try execBind("DELETE FROM meeting_groups WHERE id = ?") { stmt in
            bind(stmt, 1, name)
        }
        try execBind("DELETE FROM group_members WHERE group_id = ?") { stmt in
            bind(stmt, 1, name)
        }
        try markRecordDeleted(entity: .meetingGroup, logicalKey: name)
        for sourceID in affectedSourceIDs {
            try markRecordChanged(entity: .source, logicalKey: sourceID)
        }
    }

    /// Delete a meeting series outright: every session it holds — archived ones
    /// included — their artifacts, the group row, and any retired alias rows
    /// that were merged into it. Returns the source IDs that were deleted.
    ///
    /// `deleteMeetingGroup` only drops the series' own rows, which is what an
    /// inbound CloudKit deletion wants: the peer sends the sessions' own
    /// deletions separately. A learner deleting the folder here has no such
    /// second half, and archiving the sessions instead left them in the
    /// database — text cleared, invisible, and only reachable through Hidden
    /// Items as a series that could never be brought back with its content. So
    /// this is the destructive twin, and the sessions go with the folder.
    ///
    /// `additionalSessionIDs` covers sessions the caller can see that
    /// `group_members` no longer lists. They are held to the same rule as the
    /// rest: a session that also belongs to a group outside this series is
    /// kept, and only loses its membership here.
    ///
    /// The learner's own files are not touched — this deletes ForeverLM's copy
    /// of the series, not the Drive folder or the recordings behind it.
    func deleteMeetingGroupWithSessions(
        name: String,
        additionalSessionIDs: Set<String> = []
    ) throws -> [String] {
        var deletedSourceIDs: [String] = []
        try exec("BEGIN IMMEDIATE")
        do {
            let groupIDs = try meetingGroupIdentityClosure(of: name)
            var memberships: [String: Set<String>] = [:]
            // Read each extra session's own memberships rather than assuming it
            // has none: one whose row moved to another group is that group's
            // session now, and the rule below has to see that.
            for sessionID in additionalSessionIDs {
                var groups = Set<String>()
                try queryBind("SELECT group_id FROM group_members WHERE source_id = ?", bind: { stmt in
                    bind(stmt, 1, sessionID)
                }) { stmt in
                    if let groupID = self.string(stmt, 0) { groups.insert(groupID) }
                }
                memberships[sessionID] = groups
            }
            let groupPlaceholders = groupIDs.map { _ in "?" }.joined(separator: ", ")
            let orderedGroupIDs = Array(groupIDs)
            try queryBind(
                """
                SELECT source_id, group_id FROM group_members
                WHERE source_id IN (
                    SELECT source_id FROM group_members WHERE group_id IN (\(groupPlaceholders))
                )
                """,
                bind: { stmt in
                    for (offset, groupID) in orderedGroupIDs.enumerated() {
                        bind(stmt, offset + 1, groupID)
                    }
                }
            ) { stmt in
                guard let sourceID = self.string(stmt, 0), let groupID = self.string(stmt, 1) else { return }
                memberships[sourceID, default: []].insert(groupID)
            }
            // A session shared with a group outside this series is not this
            // series' to delete; it just stops being a member here.
            for (sourceID, groups) in memberships {
                if groups.subtracting(groupIDs).isEmpty {
                    try deleteSourceRows(sourceID)
                    deletedSourceIDs.append(sourceID)
                } else {
                    for groupID in groups.intersection(groupIDs) {
                        try execBind("DELETE FROM group_members WHERE source_id = ? AND group_id = ?") { stmt in
                            bind(stmt, 1, sourceID)
                            bind(stmt, 2, groupID)
                        }
                    }
                    try markRecordChanged(entity: .source, logicalKey: sourceID)
                }
            }
            // Artifacts and memberships of the deleted sessions went with them
            // through the schema's cascades; these clear what a session no
            // longer standing behind them would have left.
            for groupID in groupIDs {
                try execBind("DELETE FROM meeting_artifacts WHERE group_id = ?") { stmt in
                    bind(stmt, 1, groupID)
                }
                try deleteMeetingActionItems(groupID: groupID)
                try execBind("DELETE FROM group_members WHERE group_id = ?") { stmt in
                    bind(stmt, 1, groupID)
                }
                try execBind("DELETE FROM meeting_groups WHERE id = ?") { stmt in
                    bind(stmt, 1, groupID)
                }
                try markRecordDeleted(entity: .meetingGroup, logicalKey: groupID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        for sourceID in deletedSourceIDs {
            KeychainService.deleteZoomRecordingPasscode(forSourceID: sourceID)
        }
        return deletedSourceIDs
    }

    /// A meeting series plus every alias row that a merge pointed at it, so a
    /// deletion cannot leave an alias behind that still claims the sessions.
    private func meetingGroupIdentityClosure(of name: String) throws -> Set<String> {
        var groupIDs: Set<String> = [name]
        var frontier = [name]
        while let current = frontier.popLast() {
            var aliases: [String] = []
            try queryBind("SELECT id FROM meeting_groups WHERE merged_into_group_id = ?", bind: { stmt in
                bind(stmt, 1, current)
            }) { stmt in
                if let id = self.string(stmt, 0) { aliases.append(id) }
            }
            for alias in aliases where groupIDs.insert(alias).inserted {
                frontier.append(alias)
            }
        }
        return groupIDs
    }

    // MARK: - Book Metadata

    func saveBooks(
        titles: [String: String] = [:],
        subtitles: [String: String] = [:],
        authors: [String: String],
        editions: [String: String] = [:],
        coverPaths: [String: String] = [:],
        kinds: [String: String] = [:]
    ) throws {
        let bookColumns = try tableColumnNames("books")
        let hasSubtitle = bookColumns.contains("subtitle")
        let hasEdition = bookColumns.contains("edition")
        let persistedCoverPaths = coverPaths.mapValues(StorageService.relativeSourcePath)
        let existing = try loadBooks()
        let existingKeys = Set(existing.titles.keys)
            .union(existing.subtitles.keys)
            .union(existing.authors.keys)
            .union(existing.editions.keys)
            .union(existing.coverPaths.keys)
            .union(existing.kinds.keys)
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM books")
            let allKeys = Set(authors.keys)
                .union(titles.keys)
                .union(subtitles.keys)
                .union(editions.keys)
                .union(coverPaths.keys)
                .union(kinds.keys)
            for key in allKeys {
                if hasSubtitle && hasEdition {
                    try execBind("""
                        INSERT INTO books (id, title, subtitle, author, edition, cover_path, kind)
                        VALUES (?,?,?,?,?,?,?)
                    """) { stmt in
                        bind(stmt, 1, key)
                        bind(stmt, 2, titles[key] ?? existing.titles[key] ?? key)
                        bind(stmt, 3, subtitles[key])
                        bind(stmt, 4, SourceAuthor.storable(authors[key]))
                        bind(stmt, 5, editions[key])
                        bind(stmt, 6, persistedCoverPaths[key])
                        bind(stmt, 7, kinds[key])
                    }
                } else {
                    try execBind("""
                        INSERT INTO books (id, title, author, cover_path, kind)
                        VALUES (?,?,?,?,?)
                    """) { stmt in
                        bind(stmt, 1, key)
                        bind(stmt, 2, titles[key] ?? existing.titles[key] ?? key)
                        bind(stmt, 3, SourceAuthor.storable(authors[key]))
                        bind(stmt, 4, persistedCoverPaths[key])
                        bind(stmt, 5, kinds[key])
                    }
                }
            }
            for key in allKeys {
                try markRecordChanged(entity: .book, logicalKey: key)
            }
            for deletedKey in existingKeys.subtracting(allKeys) {
                try markRecordDeleted(entity: .book, logicalKey: deletedKey)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    struct BookRow {
        var titles: [String: String]
        var subtitles: [String: String]
        var authors: [String: String]
        var editions: [String: String]
        var coverPaths: [String: String]
        var kinds: [String: String]
    }

    func loadBooks() throws -> BookRow {
        var titles: [String: String] = [:]
        var subtitles: [String: String] = [:]
        var authors: [String: String] = [:]
        var editions: [String: String] = [:]
        var coverPaths: [String: String] = [:]
        var kinds: [String: String] = [:]
        let bookColumns = try tableColumnNames("books")
        let subtitleExpression = bookColumns.contains("subtitle") ? "subtitle" : "NULL AS subtitle"
        let editionExpression = bookColumns.contains("edition") ? "edition" : "NULL AS edition"
        try query("SELECT id, title, \(subtitleExpression), author, \(editionExpression), cover_path, kind FROM books") { stmt in
            guard let key = self.string(stmt, 0) else { return }
            let title = self.string(stmt, 1)
            let subtitle = self.string(stmt, 2)
            let author = self.string(stmt, 3)
            let edition = self.string(stmt, 4)
            let cover = self.string(stmt, 5)
            let kind = self.string(stmt, 6)
            if let title { titles[key] = title }
            if let subtitle { subtitles[key] = subtitle }
            if let author { authors[key] = author }
            if let edition { editions[key] = edition }
            if let cover {
                let absolute = StorageService.absoluteSourcePath(cover)
                coverPaths[key] = normalizePathForCurrentUser(absolute) ?? absolute
            }
            if let kind { kinds[key] = kind }
        }
        return BookRow(titles: titles, subtitles: subtitles, authors: authors, editions: editions, coverPaths: coverPaths, kinds: kinds)
    }

    /// Upsert a single book's metadata.
    func saveBookMetadata(
        groupName: String,
        title: String? = nil,
        subtitle: String? = nil,
        author: String? = nil,
        edition: String? = nil,
        coverPath: String?,
        kind: String? = nil
    ) throws {
        let persistedCoverPath = coverPath.map(StorageService.relativeSourcePath)
        let bookColumns = try tableColumnNames("books")
        if bookColumns.contains("subtitle") && bookColumns.contains("edition") {
            try execBind("""
                INSERT INTO books (id, title, subtitle, author, edition, cover_path, kind)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = COALESCE(excluded.title, title),
                    subtitle = COALESCE(excluded.subtitle, subtitle),
                    author = COALESCE(excluded.author, author),
                    edition = COALESCE(excluded.edition, edition),
                    cover_path = COALESCE(excluded.cover_path, cover_path),
                    kind = COALESCE(excluded.kind, kind)
            """) { stmt in
                bind(stmt, 1, groupName)
                bind(stmt, 2, title ?? groupName)
                bind(stmt, 3, subtitle)
                bind(stmt, 4, SourceAuthor.storable(author))
                bind(stmt, 5, edition)
                bind(stmt, 6, persistedCoverPath)
                bind(stmt, 7, kind)
            }
        } else {
            try execBind("""
                INSERT INTO books (id, title, author, cover_path, kind)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = COALESCE(excluded.title, title),
                    author = COALESCE(excluded.author, author),
                    cover_path = COALESCE(excluded.cover_path, cover_path),
                    kind = COALESCE(excluded.kind, kind)
            """) { stmt in
                bind(stmt, 1, groupName)
                bind(stmt, 2, title ?? groupName)
                bind(stmt, 3, SourceAuthor.storable(author))
                bind(stmt, 4, persistedCoverPath)
                bind(stmt, 5, kind)
            }
        }
        try markRecordChanged(entity: .book, logicalKey: groupName)
    }

    /// The editable title of a book, by its stable group id. Nil when the group
    /// has no `books` row or an empty title; callers show the id only as a last
    /// resort, because for imported books it is a bare UUID.
    func bookTitle(forGroupID groupID: String) throws -> String? {
        var title: String?
        try queryBind("SELECT title FROM books WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, groupID)
        }) { stmt in
            title = self.string(stmt, 0)
        }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Update the editable book title without changing the stable book identity.
    func renameBookGroup(from oldName: String, to newName: String) throws {
        let oldName = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldName.isEmpty, !newName.isEmpty, oldName != newName else { return }

        var oldTitle = oldName
        try queryBind("SELECT title FROM books WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, oldName)
        }) { stmt in
            oldTitle = self.string(stmt, 0) ?? oldName
        }
        guard oldTitle != newName else { return }

        var sourceIDs: [String] = []
        try queryBind("SELECT source_id FROM group_members WHERE group_id = ?", bind: { stmt in
            bind(stmt, 1, oldName)
        }) { stmt in
            if let sourceID = self.string(stmt, 0) {
                sourceIDs.append(sourceID)
            }
        }

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                UPDATE books
                SET title = ?
                WHERE id = ?
            """) { stmt in
                bind(stmt, 1, newName)
                bind(stmt, 2, oldName)
            }
            try execBind("""
                UPDATE book_sources
                SET title = ? || substr(title, length(?) + 1)
                WHERE source_id IN (SELECT source_id FROM group_members WHERE group_id = ?)
                  AND title LIKE ? || '%'
            """) { stmt in
                bind(stmt, 1, newName)
                bind(stmt, 2, oldTitle)
                bind(stmt, 3, oldName)
                bind(stmt, 4, oldTitle)
            }
            try markRecordChanged(entity: .book, logicalKey: oldName)
            for sourceID in sourceIDs {
                try markRecordChanged(entity: .source, logicalKey: sourceID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

extension KnowledgeStore {

    /// Stage historical Zoom recordings set-wise during version 79. Per-source
    /// relationship and sync work belongs to the post-launch drain below.
    @discardableResult
    func enqueueZoomMeetingAdoption() throws -> Int {
        let now = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO zoom_meeting_adoption_queue (source_id, enqueued_at)
            SELECT source_id, ?
            FROM videos
            WHERE url LIKE '%zoom.us/rec/%' OR url LIKE '%zoom.us/recording/%'
            ON CONFLICT(source_id) DO NOTHING
        """) { stmt in
            sqlite3_bind_double(stmt, 1, now)
        }
        return try zoomMeetingAdoptionQueueCount()
    }

    func zoomMeetingAdoptionQueueCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM zoom_meeting_adoption_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Re-file one bounded batch of Zoom cloud recordings as the meeting sessions they always were,
    /// each in the meeting series for the Zoom account that hosted it.
    ///
    /// Zoom used to be a sidebar tab of its own, so a recording was stored as a
    /// `video` and told apart from a YouTube one by its URL shape. That made the
    /// tab axis the provider again — the mistake the Google Drive and Read AI
    /// tabs were merged to undo — and it left a recording unable to sit in the
    /// recurring series it was an occurrence of, because series live in Meetings
    /// and the recording was not a meeting.
    ///
    /// Three writes per recording: the type on `sources`, the row moved from
    /// `videos` to `meeting_sources`, and membership of a series. The series is
    /// derived deterministically from the hosting Zoom account
    /// (`ForeverLMCore.zoomMeetingSeries`) so two Macs migrating the same
    /// library agree on one group id instead of syncing two; where a series of
    /// that title already exists it adopts the sessions rather than a second row
    /// appearing beside it. The learner renames the row to whatever the seminar
    /// is really called, and later recordings from that account join it.
    ///
    /// The queue is durable and each batch is one transaction. No step reads
    /// content, touches a file, or calls the network.
    @discardableResult
    func drainZoomMeetingAdoptionBatch(limit: Int = 50, at now: Date = Date()) throws -> [String] {
        let boundedLimit = max(1, min(limit, 200))
        var candidates: [(sourceID: String, url: String)] = []
        try query("""
            SELECT q.source_id, v.url
            FROM zoom_meeting_adoption_queue q
            JOIN videos v ON v.source_id = q.source_id
            ORDER BY q.enqueued_at, q.source_id
            LIMIT \(boundedLimit)
        """) { stmt in
            guard let sourceID = self.string(stmt, 0), let url = self.string(stmt, 1) else { return }
            candidates.append((sourceID, url))
        }
        var orphanedIDs: [String] = []
        try query("""
            SELECT q.source_id
            FROM zoom_meeting_adoption_queue q
            WHERE NOT EXISTS (SELECT 1 FROM videos v WHERE v.source_id = q.source_id)
            ORDER BY q.enqueued_at, q.source_id
            LIMIT \(boundedLimit)
        """) { stmt in
            if let sourceID = self.string(stmt, 0) { orphanedIDs.append(sourceID) }
        }
        guard !candidates.isEmpty || !orphanedIDs.isEmpty else { return [] }

        try exec("BEGIN IMMEDIATE")
        var migrated: [String] = []
        do {
            // Title match first, so a Drive or Read AI series already standing
            // under this name adopts the recordings instead of gaining a twin.
            var groupIDByTitle: [String: String] = [:]
            try query("SELECT id, title FROM meeting_groups") { stmt in
                guard let id = self.string(stmt, 0), let title = self.string(stmt, 1) else { return }
                groupIDByTitle[title.lowercased()] = id
            }

            for (sourceID, url) in candidates {
                guard let series = ForeverLMCore.zoomMeetingSeries(forRecordingURL: url) else {
                    try execBind("DELETE FROM zoom_meeting_adoption_queue WHERE source_id = ?") { stmt in
                        bind(stmt, 1, sourceID)
                    }
                    continue
                }
                let titleKey = series.title.lowercased()
                let groupID = groupIDByTitle[titleKey] ?? series.id

                if groupIDByTitle[titleKey] == nil {
                    try execBind("""
                        INSERT INTO meeting_groups (id, title, timezone, is_hidden)
                        VALUES (?, ?, ?, 0)
                        ON CONFLICT(id) DO NOTHING
                    """) { stmt in
                        bind(stmt, 1, groupID)
                        bind(stmt, 2, series.title)
                        bind(stmt, 3, TimeZone.current.identifier)
                    }
                    groupIDByTitle[titleKey] = groupID
                    try markRecordChanged(entity: .meetingGroup, logicalKey: groupID)
                }

                try execBind("""
                    INSERT INTO meeting_sources
                        (source_id, url, local_file_path, normalized_url, title, domain,
                         discovery_origin, word_count, artwork_url)
                    SELECT source_id, url, local_file_path, normalized_url, title, ?,
                           'zoom', word_count, artwork_url
                    FROM videos
                    WHERE source_id = ?
                    ON CONFLICT(source_id) DO NOTHING
                """) { stmt in
                    bind(stmt, 1, series.title)
                    bind(stmt, 2, sourceID)
                }
                try execBind("DELETE FROM videos WHERE source_id = ?") { stmt in bind(stmt, 1, sourceID) }
                try execBind("UPDATE sources SET source_type = 'meeting' WHERE id = ?") { stmt in bind(stmt, 1, sourceID) }
                // Adoption *moves* the recording into its series. Adding a second
                // membership instead left the source filed under both its old
                // group and the series — and a source in two groups fans
                // `source_projection` out into two rows, which every id-keyed
                // caller reads as a duplicate (2026-08-31).
                try execBind("DELETE FROM group_members WHERE source_id = ? AND group_id <> ?") { stmt in
                    bind(stmt, 1, sourceID)
                    bind(stmt, 2, groupID)
                }
                try execBind("""
                    INSERT OR IGNORE INTO group_members (source_id, group_id, sort_index, lecture_group_id)
                    VALUES (?, ?, NULL, NULL)
                """) { stmt in
                    bind(stmt, 1, sourceID)
                    bind(stmt, 2, groupID)
                }
                try upsertSyncSave(entity: .source, logicalKey: sourceID, at: now)
                try execBind("DELETE FROM zoom_meeting_adoption_queue WHERE source_id = ?") { stmt in bind(stmt, 1, sourceID) }
                migrated.append(sourceID)
            }
            for sourceID in orphanedIDs {
                try execBind("DELETE FROM zoom_meeting_adoption_queue WHERE source_id = ?") { stmt in bind(stmt, 1, sourceID) }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return migrated
    }
}
