import Foundation

/// The screens' models under generation 2 (docs/cloudkit-schema-design.md D33, D52, §3.5, §5.6, §8b–§8d,
/// §14.1; §14.2 WP19b): what generation 1 assembled from the old zone's payloads, read instead from the
/// index columns `MobileReplica` extracted when each record was applied. The screens keep their models
/// (`MobileCloudSource`, `MobileCloudNotebook`, `MobileCatalogCollections`, `MobileCloudArtifact`,
/// `MobileNotebookChatSummary`), so a screen reads the same shape whichever generation fed it.
///
/// One read of the index builds the snapshot; no payload is decoded for it but each space's root. A
/// chat's transcript decodes only that chat's exchanges, and the Memory grid folds the ActivityLog
/// index. Per-member state is this member's own (`Library`): marks, reading states and NotebookStates
/// never come from a space.
enum MobileReadModels {
    static let libraryKey = MobileProjection.libraryKey
    static let catalogKey = MobileProjection.catalogKey

    /// Everything the catalog serves under generation 2.
    struct Snapshot: Sendable {
        var structure = MobileProjection.LibraryStructure()
        /// Every source the phone holds, one per id (`Catalog` first, then each space), merged duplicates
        /// left out. Hidden and archived ones stay, flagged, as generation 1 kept them: the lists filter.
        var sources: [MobileCloudSource] = []
        var collections = MobileCatalogCollections.empty
        /// The notebooks Home lists, newest first: archived, hidden and redirect stubs left out.
        var notebooks: [MobileCloudNotebook] = []
        /// This member's ticks per notebook, in the shape generation 1's two rows have: the sources whose
        /// untick still names their Entry's stamps, and the context notebooks ticked in (§5.6, D52).
        var selections: [String: NotebookChatContext.Selection] = [:]
        var artifacts: [MobileCloudArtifact] = []
        var audioOverviews: [MobileAudioOverviewRecord] = []
        /// Each notebook's chats, newest first, by notebook id.
        var notebookChats: [String: [MobileNotebookChatSummary]] = [:]
        /// The zone each chat sits in, for its transcript.
        var chatZones: [String: String] = [:]
        /// The day-named memory review chats, for the history grid.
        var memoryChats: [MobileMemoryHistoryDays.Session] = []
        /// The Schedule's live placements, each with its source's activity days (WP20c).
        var placements: [MobileCloudScheduledSource] = []
        /// The notebooks and Goals a placement's tags name.
        var scheduleGoals: [MobileCloudGoal] = []
        /// The member's highlights, oldest first (WP20c).
        var highlights: [SourceHighlight] = []
        /// Every source's activity days, folded from every device's ActivityLog, whether or not it is on
        /// the Schedule: what memory review counts as consumption.
        var activityDays: [String: [SourceActivityDay]] = [:]

        /// Every notebook's approved sources by id, archived and hidden ones too (the card review narrows to
        /// a notebook whatever its state; `MobileNotebookCards`), the ids held or not.
        var notebookPools: [String: [String]] = [:]
        /// Each Goal's notebook (`Goal.notebookID`), so a thing filed under a Goal is its notebook's.
        var goalParents: [String: String] = [:]
        /// The sources a finished chat named (`Chat.contextSourceIDs` of an ended one): what a course's
        /// lessons count as reviewed.
        var reviewedSourceIDs: Set<String> = []

        var isEmpty: Bool { sources.isEmpty && notebooks.isEmpty }
    }

    static func snapshot(_ projection: MobileProjection) async throws -> Snapshot {
        try await projection.replica.read { try snapshot(in: $0) }
    }

    static func snapshot(in replica: MobileReplica) throws -> Snapshot {
        let connection = replica.connection
        var snapshot = Snapshot()
        let structure = try MobileProjection.structure(in: replica)
        snapshot.structure = structure
        let marks = try Marks(in: connection)

        let collections = try self.collections(in: connection, structure: structure, marks: marks)
        snapshot.collections = collections
        snapshot.sources = try sources(in: connection, structure: structure, marks: marks)
        let sourcesByID = Dictionary(snapshot.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let notebooks = try notebookPart(in: connection, structure: structure, sourcesByID: sourcesByID, collections: collections, marks: marks)
        snapshot.notebooks = notebooks.notebooks
        snapshot.selections = notebooks.selections
        snapshot.notebookPools = notebooks.pools

        let artifacts = try self.artifacts(in: connection, structure: structure, marks: marks)
        snapshot.artifacts = artifacts.listed
        snapshot.audioOverviews = artifacts.audioOverviews

        let chats = try self.chats(in: connection, structure: structure, marks: marks)
        snapshot.notebookChats = chats.byNotebook
        snapshot.chatZones = chats.zones
        snapshot.memoryChats = chats.memory
        snapshot.reviewedSourceIDs = chats.reviewedSourceIDs
        snapshot.goalParents = try goalParents(in: connection)

        snapshot.activityDays = try activityDays(in: connection)
        snapshot.placements = try placements(in: connection, activityDays: snapshot.activityDays)
        snapshot.scheduleGoals = try scheduleGoals(in: connection)
        snapshot.highlights = try highlights(in: connection)
        return snapshot
    }

    // MARK: - Marks

    /// This member's marks that shape what is listed (§3.5.19): hidden targets and visible overrides.
    struct Marks {
        var hidden = Set<String>()
        var visibleOverride = Set<String>()

        init(hidden: Set<String> = [], visibleOverride: Set<String> = []) {
            self.hidden = hidden
            self.visibleOverride = visibleOverride
        }

        init(in connection: SQLiteConnection) throws {
            try connection.query("""
                SELECT kind, target FROM m_marks WHERE zone_key = ? AND on_flag = 1 AND kind IN ('hidden', 'visibleOverride')
            """, [.text(libraryKey)]) { row in
                let target = row.text(1) ?? ""
                if row.text(0) == "hidden" { hidden.insert(target) } else { visibleOverride.insert(target) }
            }
        }

        func isHidden(_ prefix: String, _ id: String) -> Bool { hidden.contains("\(prefix):\(id)") }
    }

    // MARK: - Sources

    static func sources(in connection: SQLiteConnection, structure: MobileProjection.LibraryStructure, marks: Marks) throws -> [MobileCloudSource] {
        var readAt: [String: Int64] = [:]
        try connection.query("""
            SELECT target_id, read_at FROM m_reading_states WHERE zone_key = ? AND target_kind = 'source' AND read_at IS NOT NULL
        """, [.text(libraryKey)]) { readAt[$0.text(0) ?? ""] = $0.integer(1) }

        let keys = [catalogKey] + structure.spaces.map(\.zoneKey)
        var seen = Set<String>()
        var rows: [(source: MobileCloudSource, collectionOrder: String?)] = []
        // `Catalog` first: a source the learner holds and a space holds too is listed once, as theirs.
        try connection.query("""
            SELECT id, type, title, authors, venue, url, collection_id, collection_order, status, ingest_state, added_at,
                   published_at, subtitle, doi, word_count, has_audio
            FROM m_sources WHERE zone_key IN (\(placeholders(keys.count))) AND (merged_into IS NULL OR merged_into = '')
            ORDER BY CASE zone_key WHEN ? THEN 0 ELSE 1 END, zone_key, added_at DESC, id
        """, keys.map { .text($0) } + [.text(catalogKey)]) { row in
            let id = row.text(0) ?? ""
            guard !id.isEmpty, seen.insert(id).inserted else { return }
            let type = row.text(1) ?? "article"
            let url = row.text(5)
            let ingest = row.text(9)
            var source = MobileCloudSource(
                id: id, title: row.text(2) ?? "", subtitle: row.text(4) ?? row.text(12) ?? url.flatMap(host(of:)),
                sourceType: type, dateAdded: date(row.integer(10)) ?? .distantPast, hasAudio: row.integer(15) == 1,
                isArchived: row.text(8) == "archived"
            )
            source.state = state(ofIngest: ingest)
            source.isPaywalled = ingest == "paywalled"
            source.author = row.text(3)?.replacingOccurrences(of: "; ", with: ", ")
            source.journal = type == "paper" ? row.text(4) : nil
            source.publishedYear = row.integer(11).map { String(Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: date($0)!).year ?? 0) }
            source.wordCount = row.integer(14).map(Int.init)
            source.parentGroup = row.text(6)
            source.url = url
            source.doi = row.text(13)
            source.isHidden = marks.isHidden("src", id)
            source.visiblePodcastEpisodeOverride = type == "podcast" && marks.visibleOverride.contains("src:\(id)")
            source.visibleYouTubeVideoOverride = type == "video" && marks.visibleOverride.contains("src:\(id)")
            source.readAt = date(readAt[id])
            rows.append((source, row.text(7)))
        }
        // A chapter's or an episode's place in its collection, from the collection's fractional order.
        var byCollection: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() where row.collectionOrder != nil {
            if let group = row.source.parentGroup { byCollection[group, default: []].append(index) }
        }
        for indices in byCollection.values {
            let ordered = indices.sorted { (rows[$0].collectionOrder ?? "", rows[$0].source.id) < (rows[$1].collectionOrder ?? "", rows[$1].source.id) }
            for (rank, index) in ordered.enumerated() { rows[index].source.courseSortIndex = rank }
        }
        return rows.map(\.source).sorted { $0.dateAdded > $1.dateAdded }
    }

    /// Generation 1's three states from the ingest's (§3.5.4): a paywalled source is ready, and marked.
    static func state(ofIngest ingest: String?) -> String {
        switch ingest {
        case "queued"?, "fetching"?: return "queued"
        case "error"?: return "error"
        default: return "ready"
        }
    }

    // MARK: - Collections and courses

    static func collections(in connection: SQLiteConnection, structure: MobileProjection.LibraryStructure, marks: Marks) throws -> MobileCatalogCollections {
        var collections = MobileCatalogCollections()
        try connection.query("SELECT id, kind, title, author FROM m_collections ORDER BY zone_key, id", []) { row in
            let id = row.text(0) ?? ""
            let title = row.text(2) ?? ""
            let hidden = marks.isHidden("col", id)
            switch row.text(1) {
            case "book"?:
                // The cover's handle is the Collection's id (`MobileSourceFileStore.fetchBookCover`).
                if collections.booksByID[id] == nil { collections.booksByID[id] = MobileCloudBook(id: id, title: title, author: row.text(3), recordName: id) }
            case "podcastShow"? where hidden:
                collections.hiddenPodcastShowNames.insert(title)
            case "youtubeChannel"? where hidden:
                collections.hiddenYouTubeChannelNames.insert(title)
            case "meetingSeries"? where hidden:
                collections.hiddenMeetingGroupIDs.insert(id)
            default:
                break
            }
        }
        collections.coursesByID = try courses(in: connection)
        return collections
    }

    /// Courses with their lessons in path order and each lesson's sources (§3.5.9, §3.5.10, §8d). An
    /// archived course is hidden, as a hidden course is on generation 1. Quizzes wait for their
    /// `questions` satellites, which the course page fetches when it opens (`MobileCourseQuizzes`).
    static func courses(in connection: SQLiteConnection) throws -> [String: MobileCloudCourse] {
        var courses: [String: MobileCloudCourse] = [:]
        var zones: [String: String] = [:]
        try connection.query("SELECT id, zone_key, title, status, provider FROM m_courses ORDER BY created_at DESC, id", []) { row in
            let id = row.text(0) ?? ""
            guard courses[id] == nil else { return }
            zones[id] = row.text(1)
            courses[id] = MobileCloudCourse(id: id, title: row.text(2) ?? "", institution: row.text(4), isHidden: row.text(3) == "archived")
        }
        var lessonCourse: [String: String] = [:]
        try connection.query("SELECT id, zone_key, course_id FROM m_lessons ORDER BY order_key, id", []) { row in
            guard let courseID = row.text(2), zones[courseID] == row.text(1), var course = courses[courseID] else { return }
            let id = row.text(0) ?? ""
            lessonCourse[id] = courseID
            course.lectures.append(MobileCourseLecture(id: id, number: course.lectures.count + 1, title: nil))
            courses[courseID] = course
        }
        // Titles separately, so a lesson with none keeps its number.
        try connection.query("SELECT id, title, label FROM m_lessons", []) { row in
            guard let id = row.text(0), let courseID = lessonCourse[id], var course = courses[courseID],
                  let index = course.lectures.firstIndex(where: { $0.id == id }) else { return }
            let lecture = course.lectures[index]
            course.lectures[index] = MobileCourseLecture(id: id, number: lecture.number, title: row.text(1) ?? row.text(2))
            courses[courseID] = course
        }
        try connection.query("""
            SELECT id, container_id, item_id, role FROM m_entries
            WHERE container_kind = 'lesson' AND item_kind = 'source' AND state = 'active' ORDER BY order_key, id
        """, []) { row in
            guard let lessonID = row.text(1), let courseID = lessonCourse[lessonID], var course = courses[courseID],
                  let sourceID = row.text(2) else { return }
            let sortIndex = course.lectureItems.filter { $0.lectureID == lessonID }.count
            course.lectureItems.append(MobileCourseLectureItem(id: row.text(0) ?? "", lectureID: lessonID, sourceID: sourceID,
                                                               role: row.text(3) ?? "reading", sortIndex: sortIndex))
            courses[courseID] = course
        }
        // Items in path order: by their lesson's place, then their own.
        for (id, var course) in courses where !course.lectureItems.isEmpty {
            let number = Dictionary(uniqueKeysWithValues: course.lectures.map { ($0.id, $0.number) })
            course.lectureItems.sort { (number[$0.lectureID] ?? 0, $0.sortIndex) < (number[$1.lectureID] ?? 0, $1.sortIndex) }
            courses[id] = course
        }
        return courses
    }

    // MARK: - Notebooks

    /// A notebook's Entry as the snapshot reads it: the tick rule's shape, and its order.
    struct EntryRow {
        let entry: SyncNotebookChatContext.Entry
        let orderKey: String
    }

    static func notebookPart(in connection: SQLiteConnection, structure: MobileProjection.LibraryStructure,
                             sourcesByID: [String: MobileCloudSource], collections: MobileCatalogCollections,
                             marks: Marks) throws -> (notebooks: [MobileCloudNotebook], selections: [String: NotebookChatContext.Selection],
                                                      pools: [String: [String]]) {
        var details: [String: (instructions: String?, summary: String?, repository: String?, related: [String])] = [:]
        try connection.query("SELECT zone_key, id, instructions, summary, repository, related_json FROM m_notebooks", []) { row in
            details[key(row.text(0), row.text(1))] = (row.text(2), row.text(3), row.text(4), members(row.text(5)))
        }
        var entries: [String: [EntryRow]] = [:]
        var courseEntries: [String: [String]] = [:]
        try connection.query("""
            SELECT zone_key, container_id, item_kind, item_id, state, approval, order_key, state_stamp, approval_stamp
            FROM m_entries WHERE container_kind = 'notebook' ORDER BY order_key, id
        """, []) { row in
            let container = key(row.text(0), row.text(1))
            if row.text(2) == "course", row.text(4) == "active", let id = row.text(3) { courseEntries[container, default: []].append(id) }
            guard let stateStamp = row.text(7).flatMap(SyncStamp.init) else { return }
            entries[container, default: []].append(EntryRow(entry: SyncNotebookChatContext.Entry(
                containerID: row.text(1) ?? "", itemKind: row.text(2) ?? "", itemID: row.text(3) ?? "", state: row.text(4) ?? "",
                approval: row.text(5), stateStamp: stateStamp, approvalStamp: row.text(8).flatMap(SyncStamp.init)
            ), orderKey: row.text(6) ?? ""))
        }
        var states: [String: (excluded: [String: SyncJSON], context: [String])] = [:]
        try connection.query("SELECT notebook_id, excluded_json, context_json FROM m_notebook_states WHERE zone_key = ?", [.text(libraryKey)]) { row in
            let excluded = row.text(1).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue ?? [:]
            states[row.text(0) ?? ""] = (excluded, members(row.text(2)))
        }

        let isListed: (String) -> Bool = { sourceID in
            guard let source = sourcesByID[sourceID] else { return false }
            return !source.isArchived && !MobileSourceVisibility.isHidden(source, collections: collections)
        }
        /// The notebook's own active approved sources in study order, by id.
        func pool(of notebook: MobileProjection.Notebook) -> [String] {
            var seen = Set<String>()
            return (entries[key(notebook.zoneKey, notebook.notebookID)] ?? [])
                .filter { $0.entry.isInContext && seen.insert($0.entry.itemID).inserted }
                .map(\.entry.itemID)
        }
        func zone(of notebook: MobileProjection.Notebook) -> SyncZoneName { MobileProjection.LibraryStructure.zoneName(of: notebook) }

        var notebooks: [MobileCloudNotebook] = []
        var selections: [String: NotebookChatContext.Selection] = [:]
        var pools: [String: [String]] = [:]
        for notebook in structure.notebooks {
            let detail = details[key(notebook.zoneKey, notebook.notebookID)]
            let resolve: (String) -> String = { structure.resolve($0, in: zone(of: notebook))?.notebookID ?? $0 }
            let related = (detail?.related ?? []).map(resolve).reduce(into: [String]()) { list, id in
                if id != notebook.notebookID, !list.contains(id) { list.append(id) }
            }
            let ownPool = pool(of: notebook)
            pools[notebook.notebookID] = ownPool
            let contextNotebooks = related.compactMap { id -> MobileCloudContextNotebook? in
                guard let linked = structure.resolve(id, in: zone(of: notebook)) else { return nil }
                let linkedPool = pool(of: linked)
                return MobileCloudContextNotebook(id: linked.notebookID, title: linked.title, sourceIDs: linkedPool.filter(isListed), poolSourceIDs: linkedPool)
            }
            let ownKey = key(notebook.zoneKey, notebook.notebookID)
            // A course lives in no notebook: the notebook's courses are the ones it follows (§5.5).
            let courseIDs = (courseEntries[ownKey] ?? []).reduce(into: [String]()) { list, id in
                if !list.contains(id) { list.append(id) }
            }

            // This member's ticks (§5.6, D52): the context notebooks they ticked that the notebook still
            // lists, resolved; an untick holds while its stamps are still its compared Entry's.
            let state = states[notebook.notebookID]
            let ticked = SyncNotebookChatContext.contextNotebookIDs(
                notebookID: notebook.notebookID,
                contextNotebooks: Dictionary(uniqueKeysWithValues: (state?.context ?? []).map { ($0, SyncJSON.bool(true)) }),
                relatedNotebookIDs: Dictionary(uniqueKeysWithValues: (detail?.related ?? []).map { ($0, SyncJSON.bool(true)) }),
                resolve: resolve
            )
            var held = (entries[ownKey] ?? []).map(\.entry)
            for id in ticked {
                if let linked = structure.resolve(id, in: zone(of: notebook)) {
                    held += (entries[key(linked.zoneKey, linked.notebookID)] ?? []).map(\.entry)
                }
            }
            var excluded = Set<String>()
            for (sourceID, value) in state?.excluded ?? [:] {
                guard let pair = value.stringValue,
                      let compared = SyncNotebookChatContext.comparedEntry(for: sourceID, notebookID: notebook.notebookID,
                                                                           contextNotebookIDs: ticked, entries: held),
                      SyncNotebookChatContext.stampPair(compared) == pair
                else { continue }
                excluded.insert(sourceID)
            }
            selections[notebook.notebookID] = NotebookChatContext.Selection(excluded: excluded, contextNotebookIDs: Set(ticked))

            guard !notebook.isArchived, !notebook.hidden else { continue }
            notebooks.append(MobileCloudNotebook(
                id: notebook.notebookID, title: notebook.title, instructions: detail?.instructions, summary: detail?.summary,
                repository: detail?.repository.flatMap(repositoryName(of:)), sourceIDs: ownPool.filter(isListed),
                relatedNotebookIDs: related, contextSourceIDs: nil, poolSourceIDs: ownPool, contextNotebooks: contextNotebooks,
                linkedCourseIDs: courseIDs, approvedSourceCount: ownPool.count, isArchived: false,
                updatedAt: date(notebook.editedAt) ?? .distantPast
            ))
        }
        return (notebooks, selections, pools)
    }

    /// `owner/repo` from a repository's URL (§3.5.6), as generation 1 named it.
    static func repositoryName(of url: String) -> String? {
        guard let parsed = URL(string: url), parsed.host?.lowercased().hasSuffix("github.com") == true else {
            return url.isEmpty ? nil : url
        }
        let parts = parsed.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return parts[0] + "/" + (parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1])
    }

    // MARK: - Artifacts

    /// Generation 1's kind words for the kinds a notebook's Studio lists (§3.5.15): a Doc, a linked
    /// page, a report, an explainer or a lesson reads as a kindless Doc, an animation and an audio
    /// overview keep theirs. Notes Docs, sites, files, pictures and skills have no place on the phone.
    static func phoneKind(of kind: String?) -> (listed: Bool, kind: String?) {
        switch kind {
        case nil, "doc"?, "linkedDoc"?, "report"?, "explainer"?, "lesson"?: return (true, nil)
        case "animation"?: return (true, MobileCloudArtifact.animationKind)
        case "audioOverview"?: return (true, MobileCloudArtifact.audioOverviewKind)
        default: return (false, nil)
        }
    }

    static func artifacts(in connection: SQLiteConnection, structure: MobileProjection.LibraryStructure,
                          marks: Marks) throws -> (listed: [MobileCloudArtifact], audioOverviews: [MobileAudioOverviewRecord]) {
        let spaceIDs = Dictionary(uniqueKeysWithValues: structure.spaces.map { ($0.zoneKey, $0.spaceID) })
        var listed: [MobileCloudArtifact] = []
        var overviews: [MobileAudioOverviewRecord] = []
        var seen = Set<String>()
        try connection.query("""
            SELECT id, zone_key, kind, title, notebook_id, status, created_at, edited_at, linked_json, source_ids_json, linked_url,
                   body_hash, is_draft
            FROM m_artifacts ORDER BY id, zone_key
        """, []) { row in
            let id = row.text(0) ?? ""
            let phone = phoneKind(of: row.text(2))
            guard phone.listed, !id.isEmpty, !id.hasPrefix("draft:"), row.text(5) != "archived", !marks.isHidden("art", id),
                  seen.insert(id).inserted else { return }
            let createdAt = date(row.integer(6))
            let artifact = MobileCloudArtifact(
                id: id, title: row.text(3) ?? "", kind: phone.kind, homeNotebookID: row.text(4), linkedNotebookIDs: members(row.text(8)),
                sourceIDs: members(row.text(9)), linkedURL: row.text(10), isDraft: row.integer(12) == 1,
                teamID: row.text(1).flatMap { spaceIDs[$0] }, createdAt: createdAt,
                updatedAt: date(row.integer(7)) ?? createdAt ?? .distantPast, bodyRevision: row.text(11)
            )
            listed.append(artifact)
            if phone.kind == MobileCloudArtifact.audioOverviewKind {
                overviews.append(MobileAudioOverviewRecord(
                    id: id, title: artifact.title, notebookIDs: Set([artifact.homeNotebookID].compactMap { $0 } + artifact.linkedNotebookIDs),
                    createdAt: createdAt, carrierSourceID: MobileCloudMutationService.audioOverviewSourceID(artifactID: id)
                ))
            }
        }
        return (listed, overviews)
    }

    // MARK: - Chats

    /// What a saved chat is, from its kind (D50): every chat carries one under generation 2, so the
    /// shape needs no guess from its exchanges.
    static func shape(ofKind kind: String?, chatID: String) -> MobileNotebookChatContinuation.Shape {
        switch kind {
        case "memory"?: return .memoryReview
        case "review"?, "quizSitting"?: return .tutoredReview
        case "walkthrough"?: return .walkthrough
        default:
            if MemoryReviewSession.isMemorySession(chatID) { return .memoryReview }
            return chatID.hasPrefix(MobileNotebookChatContinuation.courseQuizSessionPrefix) ? .tutoredReview : .chat
        }
    }

    static func chats(in connection: SQLiteConnection, structure: MobileProjection.LibraryStructure, marks: Marks)
        throws -> (byNotebook: [String: [MobileNotebookChatSummary]], zones: [String: String], memory: [MobileMemoryHistoryDays.Session],
                   reviewedSourceIDs: Set<String>) {
        var counts: [String: (exchanges: Int, answered: Int)] = [:]
        try connection.query("SELECT zone_key, chat_id, COUNT(*), SUM(has_answer) FROM m_exchanges GROUP BY zone_key, chat_id", []) { row in
            counts[key(row.text(0), row.text(1))] = (Int(row.integer(2) ?? 0), Int(row.integer(3) ?? 0))
        }
        var extras: [String: (context: [String], model: String?)] = [:]
        try connection.query("SELECT zone_key, id, context_json, model_id FROM m_chats", []) { row in
            extras[key(row.text(0), row.text(1))] = (members(row.text(2)), row.text(3))
        }

        var byNotebook: [String: [MobileNotebookChatSummary]] = [:]
        var zones: [String: String] = [:]
        var memory: [MobileMemoryHistoryDays.Session] = []
        var reviewed = Set<String>()
        for chat in structure.chats {
            let chatKey = key(chat.zoneKey, chat.chatID)
            // A finished chat's own sources count as reviewed, as an ended generation-1 session's did.
            if chat.status == "ended" || chat.status == "archived" { reviewed.formUnion(extras[chatKey]?.context ?? []) }
            let count = counts[chatKey] ?? (0, 0)
            let hidden = marks.isHidden("cht", chat.chatID)
            if zones[chat.chatID] == nil { zones[chat.chatID] = chat.zoneKey }
            let isMemory = chat.kind == "memory" || MemoryReviewSession.isMemorySession(chat.chatID)
            if isMemory {
                memory.append(MobileMemoryHistoryDays.Session(id: chat.chatID, hasTurns: count.exchanges > 0,
                                                              isAnswered: count.answered > 0, isHidden: hidden))
            }
            guard !hidden, count.exchanges > 0, let filed = chat.notebookID, !filed.isEmpty else { continue }
            let zone = ProjectionZones.zone(ofKey: chat.zoneKey) ?? .library
            // A `Library` chat may name a space notebook by its id (§3.5.13).
            guard let home = structure.resolve(filed, in: zone)
                ?? (zone == .library ? structure.notebooks.first { $0.notebookID == filed && $0.space != nil } : nil)
            else { continue }
            let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let started = date(chat.createdAt) ?? .distantPast
            let kind: MobileNotebookChatSummary.Kind = isMemory ? .memory
                : (chat.kind == "voice" || chat.chatID.contains("-live-") ? .voice : .text)
            byNotebook[home.notebookID, default: []].append(MobileNotebookChatSummary(
                id: chat.chatID, title: title.isEmpty ? "Chat" : title, kind: kind, turnCount: count.exchanges,
                startedAt: started, lastActivityAt: date(chat.editedAt) ?? started,
                sourceIDs: extras[chatKey]?.context ?? [], shape: shape(ofKind: chat.kind, chatID: chat.chatID),
                modelID: extras[chatKey]?.model
            ))
        }
        for id in byNotebook.keys {
            byNotebook[id]?.sort {
                if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
                return $0.id < $1.id
            }
        }
        return (byNotebook, zones, memory, reviewed)
    }

    /// A chat's turns for its read-only transcript, from its exchanges in display order; nil when the
    /// phone does not hold the chat.
    static func transcript(chatID: String, zoneKey: String, projection: MobileProjection) async throws -> [MobileChatTranscriptTurns.Turn]? {
        var exchanges: [MobileChatTranscriptTurns.Exchange] = []
        var page = MobileProjection.Page.first(200)
        while true {
            let batch = try await projection.exchanges(ofChat: chatID, zoneKey: zoneKey, page: page)
            for envelope in batch {
                exchanges.append(MobileChatTranscriptTurns.Exchange(
                    sequenceNumber: exchanges.count, question: envelope.fields["question"]?.stringValue ?? "",
                    userAnswer: envelope.fields["userAnswer"]?.stringValue, evaluation: envelope.fields["evaluation"]?.stringValue
                ))
            }
            guard batch.count == page.limit else { break }
            page = page.next
        }
        if exchanges.isEmpty {
            guard try await projection.envelope(.chat, id: chatID, zoneKey: zoneKey) != nil else { return nil }
        }
        return MobileChatTranscriptTurns.turns(sessionID: chatID, exchanges: exchanges)
    }

    // MARK: - Narration

    /// Where this member left a narration (`ReadingState.listen`, §3.5.18): its seconds, when it was
    /// saved against this narration's text or names none, as generation 1 reads the position file.
    static func listenPosition(_ listen: SyncJSON?, contentSignature: String) -> TimeInterval? {
        guard let seconds = listen?["globalTime"]?.numberValue, seconds > 0 else { return nil }
        if let saved = listen?["contentSignature"]?.stringValue, saved != contentSignature { return nil }
        return seconds
    }

    /// The narration manifest of a source's `files.audio.*` satellite, whichever voice made it.
    static func narrationFile(of source: SyncEnvelope?) -> FileRef? {
        file(of: source) { $0.hasPrefix("audio.") }
    }

    /// The first FileRef of a source's `files` whose role `matches`, by role name.
    static func file(of source: SyncEnvelope?, matching matches: (String) -> Bool) -> FileRef? {
        guard let files = source?.fields["files"]?.objectValue else { return nil }
        return files.keys.filter(matches).sorted().lazy.compactMap { files[$0].flatMap(FileRef.init(json:)) }.first
    }

    // MARK: - Satellites

    /// Where a source's satellites live (§2.2, §3.5.30): the private `Content` zone for the learner's
    /// own `Catalog` copy, a space's own zone for a space's copy.
    static func satelliteZoneKey(forSourceIn zoneKey: String) -> String {
        zoneKey == catalogKey ? PrivateSyncZones.key(PrivateSyncZones.content) : zoneKey
    }

    /// The decoded bytes of a source's satellite whose role `matches` (its canonical `text`, a
    /// narration's manifest), fetched by name through `blobs` from wherever the phone holds the source,
    /// the learner's copy first; nil when no held copy names one.
    static func sourceSatellite(_ sourceID: String, matching matches: @escaping (String) -> Bool, projection: MobileProjection,
                                blobs: BlobStore) async throws -> Data? {
        let zones = try await projection.replica.read { replica -> [String] in
            var keys: [String] = []
            try replica.connection.query("""
                SELECT zone_key FROM m_sources WHERE id = ? ORDER BY CASE zone_key WHEN ? THEN 0 ELSE 1 END, zone_key
            """, [.text(sourceID), .text(catalogKey)]) { keys.append($0.text(0) ?? "") }
            return keys
        }
        for zoneKey in zones {
            guard let file = file(of: try await projection.envelope(.source, id: sourceID, zoneKey: zoneKey), matching: matches),
                  let zone = try await projection.replica.perform({ try BlobZone.resolve(zoneKey: satelliteZoneKey(forSourceIn: zoneKey), in: $0) })
            else { continue }
            return try await blobs.fetch(file, from: zone)
        }
        return nil
    }

    // MARK: - Memory

    /// The review clock of every ActivityLog (§3.5.24), as the rows generation 1's arithmetic folds
    /// (`MemoryReviewProgress.days`, `MobileMemoryGoalModel`): one row per device log with review time,
    /// judged by `goalSecondsNow`, since a device log records no goal; and one row per old device of a
    /// `legacy22` log, with the goal it had. A device log's row is dated `now`, so on a day both kinds
    /// hold (around the move), the goal in force now is the day's, as generation 1 takes the goal of
    /// the row written last. The fold sums the seconds; nothing is counted twice, since a device records
    /// under one generation at a time.
    static func reviewActivity(_ projection: MobileProjection, goalSecondsNow: TimeInterval, now: Date = Date()) async throws -> [MemoryReviewActivity] {
        try await projection.replica.read { try reviewActivity(in: $0.connection, goalSecondsNow: goalSecondsNow, now: now) }
    }

    static func reviewActivity(in connection: SQLiteConnection, goalSecondsNow: TimeInterval, now: Date) throws -> [MemoryReviewActivity] {
        var rows: [MemoryReviewActivity] = []
        try connection.query("""
            SELECT day, device_id, review_json, review_by_device_json FROM m_activity_logs WHERE zone_key = ? ORDER BY day, id
        """, [.text(libraryKey)]) { row in
            guard let day = row.text(0), let device = row.text(1) else { return }
            let review = row.text(2).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }
            if let seconds = review?["seconds"]?.numberValue, seconds > 0 {
                rows.append(MemoryReviewActivity(day: day, deviceID: device, activeSeconds: seconds, goalSeconds: goalSecondsNow, updatedAt: now))
            }
            let byDevice = row.text(3).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue ?? [:]
            for (oldDevice, value) in byDevice.sorted(by: { $0.key < $1.key }) {
                guard let seconds = value["activeSeconds"]?.numberValue else { continue }
                rows.append(MemoryReviewActivity(day: day, deviceID: oldDevice, activeSeconds: seconds,
                                                 goalSeconds: value["goalSeconds"]?.numberValue ?? goalSecondsNow,
                                                 updatedAt: Date(timeIntervalSince1970: 0)))
            }
        }
        return rows
    }

    // MARK: - Cards and answers (§3.5.22, §3.5.23)

    /// The member's Memory as generation 1 held it: every kept card as the item it is, and every answer
    /// about a card as the attempt it is. Decoded from the Card and Sitting payloads, which the index
    /// leaves alone (a Sitting's answers can run to 100 KiB each), so it is read once and kept until the
    /// replica changes, not with every snapshot.
    struct MemoryState: Sendable {
        var items: [MemoryItem] = []
        var attempts: [MemoryAttempt] = []
        /// What this was read against: the replica's `memoryRevision` before the read, and how many Card and
        /// Sitting rows the index held in it (a purge removes rows without applying anything).
        var revision = 0
        var cardRows = 0
        var sittingRows = 0

        /// Adds what this phone just wrote, so the next read needs no second decode of the library.
        mutating func note(_ item: MemoryItem) {
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
        }

        mutating func note(_ attempt: MemoryAttempt) {
            guard !attempts.contains(where: { $0.id == attempt.id }) else { return }
            attempts.append(attempt)
        }
    }

    static func memory(_ projection: MobileProjection) async throws -> MemoryState {
        try await projection.replica.read { try memory(in: $0) }
    }

    /// The Sittings that hold no answer about a card: a quiz's score and a learning bout.
    private static let answerlessSittingKinds = "'bout', 'courseQuiz', 'lectureQuiz'"

    static func memory(in replica: MobileReplica) throws -> MemoryState {
        let connection = replica.connection
        var state = MemoryState()
        state.revision = replica.memoryRevision
        (state.cardRows, state.sittingRows) = try memoryRowCounts(in: connection)
        var cardIDs: [String] = []
        // A card kept anywhere is the member's; a draft that was never kept is no Memory item yet.
        try connection.query("""
            SELECT id FROM m_cards WHERE zone_key = ? AND (kept_at IS NOT NULL OR status IN ('kept', 'retired')) ORDER BY id
        """, [.text(libraryKey)]) { cardIDs.append($0.text(0) ?? "") }
        for id in cardIDs {
            guard let card = try MobileProjection.held(.card, id, zoneKey: libraryKey, in: replica),
                  let item = MobileMemoryRecords.item(fromCard: card.fields, id: id) else { continue }
            state.items.append(item)
        }
        var sittings: [(id: String, chatID: String?)] = []
        try connection.query("""
            SELECT id, chat_id FROM m_sittings WHERE zone_key = ? AND (kind IS NULL OR kind NOT IN (\(answerlessSittingKinds)))
            ORDER BY started_at, id
        """, [.text(libraryKey)]) { sittings.append(($0.text(0) ?? "", $0.text(1))) }
        var seen = Set<String>()
        for sitting in sittings {
            guard let held = try MobileProjection.held(.sitting, sitting.id, zoneKey: libraryKey, in: replica),
                  let answers = held.fields["answers"]?.objectValue else { continue }
            let chatID = sitting.chatID.flatMap { $0.isEmpty ? nil : $0 }
            for (answerID, answer) in answers.sorted(by: { $0.key < $1.key }) {
                guard let object = answer.objectValue, seen.insert(answerID).inserted,
                      let attempt = MobileMemoryRecords.attempt(answerID: answerID, answer: object, sessionID: chatID) else { continue }
                state.attempts.append(attempt)
            }
        }
        state.attempts.sort { ($0.attemptedAt, $0.id) < ($1.attemptedAt, $1.id) }
        return state
    }

    /// How many Card and Sitting rows the index holds.
    static func memoryRowCounts(in connection: SQLiteConnection) throws -> (cards: Int, sittings: Int) {
        let cards = try connection.scalarInteger("SELECT COUNT(*) FROM m_cards") ?? 0
        let sittings = try connection.scalarInteger("SELECT COUNT(*) FROM m_sittings") ?? 0
        return (Int(cards), Int(sittings))
    }

    /// Each Goal's notebook, for the Goals that name one (`Goal.notebookID`).
    static func goalParents(in connection: SQLiteConnection) throws -> [String: String] {
        var parents: [String: String] = [:]
        try connection.query("SELECT id, notebook_id FROM m_goals WHERE zone_key = ? AND notebook_id IS NOT NULL AND notebook_id <> ''",
                             [.text(libraryKey)]) { row in
            if let id = row.text(0), let notebook = row.text(1) { parents[id] = notebook }
        }
        return parents
    }

    // MARK: - Helpers

    static func key(_ zoneKey: String?, _ id: String?) -> String { (zoneKey ?? "") + "\u{1F}" + (id ?? "") }

    /// The ids a `members` column holds.
    static func members(_ json: String?) -> [String] {
        guard let json, let value = try? SyncJSON(parsing: Data(json.utf8)) else { return [] }
        return value.arrayValue?.compactMap(\.stringValue) ?? []
    }

    static func date(_ milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

    static func host(of url: String) -> String? {
        URL(string: url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: max(count, 1)).joined(separator: ", ")
    }
}
