import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// A production-shaped old world for `LegacyMappingParityTests` (docs/cloudkit-schema-design.md §10,
/// R17): the old container's records as another Mac wrote them, each kind the library holds, applied to
/// a generation-1 store the way generation 1 applies them (`CloudKitRecordMapper.apply`), so the store
/// holds exactly what the activation derives from. The same records are what `LegacyV2Mapping` maps.
enum LegacyParityFixture {
    static let notebookID = "nb-legacy"
    static let goalID = "goal-legacy"
    static let playlistGroup = "playlist_youtube.com/playlist?list=PLlegacy"
    static let followedPlaylist = "playlist_youtube.com/playlist?list=PLfollowed"
    static let followedCourse = "course-followed"
    static let homedCourse = "course-homed"
    static let quizChatID = CourseQuizSitting.sessionIDPrefix + "quiz-1-" + "8F2D1C3B-1E4A-4B5C-9D7E-0A1B2C3D4E5F"
    static let walkChatID = "chat-walk"
    static let docID = "doc-legacy"
    /// 2100-01-01: the deadline a notebook is stored with (`LearningGoalShape`).
    static let openEnd = Date(timeIntervalSinceReferenceDate: 3_124_137_600)

    static func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: 780_000_000 + seconds) }

    // MARK: Stores

    /// A generation-1 store in a folder of its own: what a Mac holds before its activation.
    static func makeStore(_ name: String) throws -> (root: URL, store: KnowledgeStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WP15c-\(name)-\(UUID().uuidString)", isDirectory: true)
        let store = try KnowledgeStore(
            storeDirectory: root.appendingPathComponent(".appdata", isDirectory: true),
            contentDirectory: root.appendingPathComponent("Content", isDirectory: true),
            syncGeneration: .one, freeSpace: { _ in 1_000_000_000_000 }
        )
        return (root, store)
    }

    /// Every derivation the activation runs, in its order (§13.3 step 3c).
    static func activate(_ store: KnowledgeStore) throws {
        // No narration folder is looked at: the resume points are the `listen.position.*` rows'.
        try KnowledgeStore.$listenFileProbeOverride.withValue({ _ in [:] }) {
            for derivation in KnowledgeStore.activationDerivations { try derivation.run(store) }
        }
    }

    /// A v2 record's fields as the activation's projections encode it from the store.
    static func encoded(_ store: KnowledgeStore, _ type: SyncRecordType, _ id: String) throws -> [String: SyncJSON]? {
        guard let projection = KnowledgeStore.projectionRegistry.projection(for: type) else { return nil }
        let reference = ProjectionRecordRef(
            zoneKey: StoreLegacyMappingContext.libraryZoneKey, zone: .library, type: type, wireID: id, localID: id
        )
        return try projection.encode(reference, connection: store)
    }

    // MARK: Old records

    /// An old record as the old container holds it: its payload in `payload`, or in `payloadAsset` when
    /// `payloadInAsset` (a chat over 512 KiB), and any asset fields beside it.
    static func record(
        _ entity: CloudKitSyncEntity, _ key: String, _ payload: Data, payloadInAsset: Bool = false, assets: [String: Data] = [:],
        zone: String = CloudKitZoneHome.knowledgeZoneName, in folder: URL
    ) throws -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: entity.recordType, recordID: CKRecord.ID(recordName: CloudKitRecordMapper.recordName(for: entity, logicalKey: key), zoneID: zoneID))
        var files = assets
        if payloadInAsset { files[CKRecord.FieldKey.payloadAsset] = payload } else { record.encryptedValues[CKRecord.FieldKey.payload] = payload as NSData }
        for (field, bytes) in files {
            let url = folder.appendingPathComponent("\(UUID().uuidString).asset")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: url)
            record[field] = CKAsset(fileURL: url)
        }
        return record
    }

    static func json<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    /// An article as another Mac's payload carries it.
    static func article(_ id: String, url: String, title: String, type: String, domain: String, group: String? = nil,
                        sortIndex: Int? = nil, state: String = "queued", author: String? = nil, added: Double,
                        extras: [String: Any] = [:]) throws -> StudioArticle {
        var object: [String: Any] = [
            "id": id, "url": url, "title": title, "domain": domain, "dateAdded": date(added).timeIntervalSinceReferenceDate,
            "state": state, "sourceType": type, "status": "active",
        ]
        if let group { object["parentGroup"] = group }
        if let sortIndex { object["courseSortIndex"] = sortIndex }
        if let author { object["author"] = author }
        object.merge(extras) { _, new in new }
        return try JSONDecoder().decode(StudioArticle.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func source(_ article: StudioArticle, content: String? = nil, reviewDepth: String? = nil, visibleOverride: Bool = false,
                       in folder: URL) throws -> CKRecord {
        var assets: [String: Data] = [:]
        if let content { assets[CKRecord.FieldKey.sourceContentAsset] = Data(content.utf8) }
        let payload = CloudKitSourcePayload(article: article, visiblePodcastEpisodeOverride: visibleOverride, reviewDepth: reviewDepth)
        return try record(.source, article.id, json(payload), assets: assets, in: folder)
    }

    /// A Doc's body package as the old record carries it in `payloadAsset`.
    static func docPackage(_ markdown: String) throws -> ArtifactBodyPackage.Encoded {
        try ArtifactBodyPackage.encode(markdown: markdown, attachmentDirectory: nil)
    }

    static func preference(_ key: String, _ value: Any, at seconds: Double, in folder: URL) throws -> CKRecord {
        let xml = try #require(PreferenceStore.encodePlist(value))
        return try record(.preference, key, json(CloudKitPreferencePayload(key: key, valuePlistXML: xml, updatedAt: date(seconds))), in: folder)
    }

    /// The old world: every kind of record the library holds, in the order a fetch could bring them.
    static func oldWorld(in folder: URL) throws -> [CKRecord] {
        var records: [CKRecord] = []
        records.append(try record(.book, "book-1", json(CloudKitBookPayload(id: "book-1", title: "Cell Biology", author: "B. Alberts", coverPath: nil)), in: folder))
        records.append(try record(.videoPlaylist, followedPlaylist, json(CloudKitVideoPlaylistPayload(id: followedPlaylist, metadata: VideoPlaylistMetadata(
            title: "Liked videos", playlistURL: "https://www.youtube.com/playlist?list=PLfollowed", lastRefreshedAt: nil, isHidden: false, autoImport: true,
            connectorKind: "liked"
        ))), in: folder))
        records.append(try record(.meetingGroup, "mg-1", json(CloudKitMeetingGroupPayload(
            id: "mg-1", metadata: MeetingMetadata(title: "Journal club", recurrenceRule: "FREQ=WEEKLY", timezone: "Europe/Amsterdam"),
            artifacts: [MeetingArtifact(id: "ma-1", sourceId: "src-meeting", groupId: "mg-1", kind: .attachment, title: "Slides", url: "https://example.com/slides", sortIndex: 0)],
            actionItems: [MeetingActionItem(groupID: "mg-1", sourceID: "src-meeting", position: 0, text: "Read the paper", createdAt: date(50), updatedAt: date(50))]
        )), in: folder))

        let sources: [StudioArticle] = [
            try article("src-article", url: "https://example.com/essay", title: "An essay", type: "article", domain: "example.com", state: "ready", author: "A. Writer", added: 10,
                        extras: ["readAt": date(30).timeIntervalSinceReferenceDate, "readingPositionLocator": "{\"webScrollFraction\":0.4}"]),
            try article("src-video-pl", url: "https://www.youtube.com/watch?v=aaaaaaaaaaa", title: "Lecture one", type: "video", domain: "Bio Channel", group: playlistGroup, sortIndex: 2, added: 11),
            try article("src-video-ch", url: "https://www.youtube.com/watch?v=bbbbbbbbbbb", title: "Lecture two", type: "video", domain: "Bio Channel", added: 12,
                        extras: ["likedAt": date(31).timeIntervalSinceReferenceDate, "discoveryOrigin": "safari"]),
            try article("src-podcast", url: "https://podcasts.example.com/ep1", title: "Episode one", type: "podcast", domain: "The Mito Show", added: 13, extras: ["discoveryOrigin": "applePodcasts"]),
            try article("src-chapter", url: "Books/cell-biology/ch1.pdf", title: "Chapter 1", type: "book", domain: "", group: "book-1", sortIndex: 1, added: 14),
            try article("src-meeting", url: "meeting://mg-1/2026-09-01", title: "Session 1", type: "meeting", domain: "", group: "mg-1", added: 15),
            try article("src-course-member", url: "https://example.com/reading", title: "A reading", type: "article", domain: "example.com", group: followedCourse, added: 16),
        ]
        for source in sources {
            records.append(try self.source(
                source, content: source.state == .ready ? "Readable text of the essay." : nil,
                reviewDepth: source.id == "src-article" ? "standard" : nil, visibleOverride: source.id == "src-podcast", in: folder
            ))
        }

        // The course first: a notebook's payload links only courses this Mac holds, and pulls their
        // readings into its pool, which its own payload lists too (`saveLearningGoalRecord`).
        let lectures = [
            CourseSession(id: "lec-1", courseName: followedCourse, number: 1, title: "Intro", createdAt: date(40)),
            CourseSession(id: "lec-2", courseName: followedCourse, number: 2, title: nil, createdAt: date(41)),
        ]
        let items = [
            CourseLectureItem(id: "li-1", lectureId: "lec-1", sourceId: "src-course-member", role: .reading, label: "Read first", sortIndex: 0, createdAt: date(42)),
            CourseLectureItem(id: "li-2", lectureId: "lec-1", sourceId: "src-video-ch", role: .video, sortIndex: 1, createdAt: date(43)),
            CourseLectureItem(id: "li-3", lectureId: "lec-2", sourceId: "src-chapter", role: .reading, sortIndex: 0, createdAt: date(44)),
        ]
        let quiz = CourseQuiz(
            id: "quiz-1", courseID: followedCourse, kind: .practice, title: "Quiz: Intro", lectureIDs: ["lec-1"], afterLectureID: "lec-1",
            questions: [], author: .foreverlm, createdAt: date(45), updatedAt: date(45)
        )
        records.append(try record(.course, followedCourse, json(CloudKitCoursePayload(
            id: followedCourse, title: "Bioenergetics", courseCode: "BIO101", institution: "Example University", instructors: "Prof. A",
            playlistURL: nil, lectures: lectures, lectureItems: items, quizzes: [quiz]
        )), in: folder))
        records.append(try record(.course, homedCourse, homedCoursePayload(), in: folder))

        let notebook = LearningGoalRecord(
            id: notebookID, title: "Mitochondria", startAt: date(1), endAt: openEnd, createdAt: date(1), updatedAt: date(90), status: "active",
            items: [
                LearningGoalItem(id: "item-1", goalID: notebookID, sourceID: "src-article", addedAt: date(20), completedAt: date(26), origin: "seed", reviewState: "approved", sequence: 2),
                LearningGoalItem(id: "item-2", goalID: notebookID, sourceID: "src-podcast", addedAt: date(21), origin: "discovered", reviewState: "pending", relevance: 0.8, sequence: 1),
                LearningGoalItem(id: "item-3", goalID: notebookID, sourceID: "src-video-ch", addedAt: date(22), origin: "added"),
                LearningGoalItem(id: "item-4", goalID: notebookID, sourceID: "src-course-member", addedAt: date(24), origin: "course"),
                LearningGoalItem(id: "item-5", goalID: notebookID, sourceID: "src-chapter", addedAt: date(25), origin: "course"),
            ],
            kind: "companion", description: "Read carefully", summary: "Energy", topic: "mitochondria", discoveryEnabled: true,
            gaps: [LearningGoalGap(id: "gap-1", goalID: notebookID, summary: "How is ATP made?", sourceID: "src-article", status: "open", firstSeenAt: date(30), lastSeenAt: date(31))],
            notes: "# Notes\n\nComplex IV.", researchQuestions: ["Why?", "How?"], relatedNotebookIDs: [], repository: "", artifactID: nil
        )
        records.append(try record(.learningGoal, notebookID, json(CloudKitLearningGoalPayload(goal: notebook, linkedCourseIDs: [followedCourse])), in: folder))
        let goal = LearningGoalRecord(
            id: goalID, title: "Finish the review", startAt: date(2), endAt: date(800_000), createdAt: date(2), updatedAt: date(3), status: "active",
            items: [LearningGoalItem(id: "item-g", goalID: goalID, sourceID: "src-article", addedAt: date(23))],
            kind: "companion", dailyTarget: 2, parentNotebookID: notebookID
        )
        records.append(try record(.learningGoal, goalID, json(CloudKitLearningGoalPayload(goal: goal)), in: folder))

        let exchange = { (id: String, chat: String, sequence: Int, score: Double?) in
            CloudKitReviewExchangePayload(
                id: id, sessionID: chat, sequenceNumber: sequence, question: "What does Complex IV do?", userAnswer: "It reduces oxygen.",
                evaluation: "Right.", score: score, sourceRefs: ["src-article"], knowledgeNote: nil, answeredAt: date(60 + Double(sequence)),
                rating: id == "ex-1" ? "liked" : nil, ratingReason: id == "ex-1" ? "Clear" : nil, ratingField: id == "ex-1" ? "evaluation" : nil,
                ratedAt: id == "ex-1" ? date(71) : nil
            )
        }
        let chats: [CloudKitReviewSessionPayload] = [
            CloudKitReviewSessionPayload(id: "chat-plain", topic: "Mitochondria", startedAt: date(60), endedAt: date(70), status: "completed",
                                         overallScore: nil, summary: nil, sourceIDs: ["src-article"], cardIDs: [], exchangeCount: 2, goalID: notebookID,
                                         exchanges: [exchange("ex-1", "chat-plain", 0, nil), exchange("ex-2", "chat-plain", 1, nil)]),
            CloudKitReviewSessionPayload(id: "chat-review", topic: "Review", startedAt: date(61), endedAt: nil, status: "active",
                                         overallScore: 0.8, summary: "Good", sourceIDs: [], cardIDs: [], exchangeCount: 1, goalID: goalID,
                                         exchanges: [exchange("ex-3", "chat-review", 0, 0.8)], kind: "review"),
            CloudKitReviewSessionPayload(id: quizChatID, topic: "Quiz", startedAt: date(62), endedAt: nil, status: "completed",
                                         overallScore: nil, summary: nil, sourceIDs: [], cardIDs: [], exchangeCount: 1, exchanges: [exchange("ex-4", quizChatID, 0, nil)]),
            CloudKitReviewSessionPayload(id: "mac-live-1", topic: "Voice", startedAt: date(63), endedAt: nil, status: "completed",
                                         overallScore: nil, summary: nil, sourceIDs: [], cardIDs: [], exchangeCount: 0, exchanges: []),
            CloudKitReviewSessionPayload(id: "memory-1", topic: "Memory", startedAt: date(64), endedAt: nil, status: "completed",
                                         overallScore: nil, summary: nil, sourceIDs: [], cardIDs: ["mi-1"], exchangeCount: 0, exchanges: [], kind: "memory"),
            CloudKitReviewSessionPayload(id: walkChatID, topic: "Walk", startedAt: date(65), endedAt: nil, status: "completed",
                                         overallScore: nil, summary: nil, sourceIDs: [], cardIDs: [], exchangeCount: 0, exchanges: []),
        ]
        for chat in chats { records.append(try record(.reviewSession, chat.id, json(chat), in: folder)) }

        let package = try docPackage("# The landscape\n\nComplex IV reduces oxygen.\n")
        let doc = ArtifactRecord(id: docID, title: "Landscape", homeNotebookID: notebookID, linkedNotebookIDs: [notebookID], sourceIDs: ["src-article"],
                                 createdAt: date(80), updatedAt: date(81))
        records.append(try record(.artifact, docID, json(CloudKitArtifactPayload(
            artifact: doc, bodyRevision: package.revision, bodyByteCount: package.byteCount, bodyFormatVersion: ArtifactBodyPackage.formatVersion
        )), assets: [CKRecord.FieldKey.payloadAsset: package.data], in: folder))
        records.append(try record(.artifactComment, "cm-1", json(ArtifactCommentRecord(
            id: "cm-1", artifactID: docID, parentCommentID: nil, authorRecordName: "_owner", authorDisplayName: "Robin", body: "Source?",
            anchorRevision: package.revision, anchorStart: 2, anchorEnd: 15, anchorQuote: "The landscape", createdAt: date(82), updatedAt: date(82), resolvedAt: nil
        )), in: folder))

        let placement = ScheduledSource(id: "ss-1", sourceID: "src-article", plannedAt: date(86_400 * 3 + 120), addedAt: date(85), completedAt: nil,
                                        createdAt: date(85), updatedAt: date(85))
        let day = Calendar.current.startOfDay(for: date(86_400 * 2))
        let activity = SourceActivityDay(
            id: "sad-1", sourceID: "src-article", dayStart: day, firstActivityAt: day.addingTimeInterval(3_600), lastActivityAt: day.addingTimeInterval(4_200),
            kinds: [.reading, .chat], completedKinds: [.reading], maxFraction: 0.6, engagedSeconds: 240
        )
        records.append(try record(.scheduledSource, "ss-1", json(CloudKitScheduledSourcePayload(placement: placement, goalIDs: [goalID], activityDays: [activity])), in: folder))
        records.append(try record(.memoryItem, "mi-1", json(CloudKitMemoryItemPayload(item: MemoryItem(
            id: "mi-1", kind: .concept, target: "Complex IV reduces oxygen to water.", rubricJSON: "{}",
            sources: [MemoryItemSource(id: "anchor-1", memoryItemID: "mi-1", sourceID: "src-article", excerpt: "Complex IV", sourceSHA256: "abc", sortIndex: 0)],
            createdAt: date(86), updatedAt: date(86)
        ))), in: folder))

        records += try memberRecords(in: folder)
        records.append(try preference("account.displayName", "Robin", at: 87, in: folder))
        records.append(try preference("notebookCollection.nbc-1", "Bioenergetics", at: 88, in: folder))
        records.append(try preference(NotebookCollections.membershipPreferenceKeyPrefix + notebookID, ["nbc-1", "nbc-2"], at: 88, in: folder))
        records.append(try preference(NotebookChatContext.preferenceKeyPrefix + notebookID, ["nb-other"], at: 89, in: folder))
        records.append(try preference("studio.projectOrder", [notebookID], at: 89, in: folder))
        records.append(try preference(NotebookPins.preferenceKey, [notebookID], at: 89, in: folder))
        records += try memberPreferences(in: folder)
        return records
    }

    /// The learner's own state and history: hides, a dismissal, a highlight, answers and review time, an
    /// idea, a cited paper and a walk (each an old record type with no owner of its v2 record).
    static func memberRecords(in folder: URL) throws -> [CKRecord] {
        var records: [CKRecord] = []
        records.append(try record(.hiddenSource, "src-chapter", json(CloudKitHiddenSourcePayload(sourceID: "src-chapter", hiddenAt: date(33))), in: folder))
        records.append(try record(.hiddenPodcastShow, "Hidden Show", json(CloudKitHiddenPodcastShowPayload(showName: "Hidden Show", hiddenAt: date(34))), in: folder))
        records.append(try record(.hiddenYouTubeChannel, "Old Channel", json(CloudKitHiddenYouTubeChannelPayload(channelName: "Old Channel", hiddenAt: date(34))), in: folder))
        records.append(try record(.hiddenArtifact, docID, json(CloudKitHiddenArtifactPayload(artifactID: docID, hiddenAt: date(35))), in: folder))
        records.append(try record(.hiddenReviewSession, "chat-plain", json(CloudKitHiddenReviewSessionPayload(sessionID: "chat-plain", hiddenAt: date(35))), in: folder))
        records.append(try record(.dismissedSource, "https://example.com/nope", json(CloudKitDismissedSourcePayload(url: "https://example.com/nope", title: "Nope", dismissedAt: date(36))), in: folder))
        records.append(try record(.sourceHighlight, "hl-1", json(CloudKitSourceHighlightPayload(highlight: SourceHighlight(
            id: "hl-1", sourceID: "src-article", quote: "Complex IV", note: "Key step", color: .default,
            anchor: ReaderTextAnchor(exact: "Complex IV", prefix: "the ", suffix: " reduces", offset: 10), createdAt: date(37), updatedAt: date(38)
        ), sourceIdentity: nil)), in: folder))
        // An answer made in a chat names its exchange, and says what that exchange says (its score included).
        let attempt = { (id: String, exchange: String?, at: Double) in
            MemoryAttempt(
                id: id, memoryItemID: "mi-1", sessionID: exchange == nil ? nil : "chat-review", exchangeID: exchange, attemptType: .review,
                prompt: "What does Complex IV do?", learnerAnswer: "It reduces oxygen.", feedback: "Right.", score: 0.8, scheduleRating: .good,
                gradeState: .graded, gradingError: nil, evidenceJSON: nil, attemptedAt: date(at), modelProvider: nil, modelID: nil, modelMetadataJSON: nil
            )
        }
        records.append(try record(.memoryAttempt, "att-1", json(CloudKitMemoryAttemptPayload(attempt: attempt("att-1", "ex-3", 40))), in: folder))
        records.append(try record(.memoryAttempt, "att-2", json(CloudKitMemoryAttemptPayload(attempt: attempt("att-2", nil, 86_400 * 5))), in: folder))
        let activity = MemoryReviewActivity(day: "2026-09-01", deviceID: "old-device-1", activeSeconds: 300, goalSeconds: 600, updatedAt: date(41))
        records.append(try record(.memoryReviewActivity, activity.id, json(CloudKitMemoryReviewActivityPayload(activity: activity)), in: folder))
        let ideas = [
            SourceIdea(id: "idea-1", sourceID: "src-article", statement: "Complex IV reduces oxygen.", recallNote: "Oxygen to water", wanted: true,
                       contentHash: "hash-1", sortIndex: 0, createdAt: date(42), updatedAt: date(43)),
            SourceIdea(id: "idea-2", sourceID: "src-article", statement: "Cytochrome c carries electrons.", recallNote: "Carrier", wanted: false,
                       contentHash: "hash-1", sortIndex: 1, createdAt: date(42), updatedAt: date(43)),
        ]
        for idea in ideas { records.append(try record(.sourceIdea, idea.id, json(CloudKitSourceIdeaPayload(idea: idea)), in: folder)) }
        let cited = VideoCitedPaper(id: "vcp-1", sourceID: "src-video-ch", title: "A cited paper", status: .dismissed, kind: .paper, createdAt: date(44), updatedAt: date(45))
        records.append(try record(.videoCitedPaper, cited.id, json(CloudKitVideoCitedPaperPayload(paper: cited)), in: folder))
        let progress = WalkthroughProgress(
            subjectID: "src-article", currentStepID: "step-1", revealedBeats: ["step-1": 2], playedStepIDs: ["step-1"],
            outcomes: ["step-1": .remembered], chatSessionID: walkChatID, updatedAt: date(66)
        )
        records.append(try record(.walkthroughProgress, "src-article", json(CloudKitWalkthroughProgressPayload(progress: progress)), in: folder))
        return records
    }

    /// The domain-prefix preference rows that feed the learner's own records (§10).
    static func memberPreferences(in folder: URL) throws -> [CKRecord] {
        let taken = Date(timeIntervalSince1970: 1_790_000_000)
        let deck = MemoryCardDeckState(cards: [
            "card-kept": MemoryCardState(status: .kept, memoryItemID: "mi-1", variants: ["What reduces oxygen?"], alwaysAsk: true, seed: "idea:abc", updatedAt: taken),
            "card-skipped": MemoryCardState(status: .skipped, variants: ["Another wording"], seed: "walk:step-2", updatedAt: taken),
        ])
        let position = ArticleSpeechPlaybackPosition(globalTime: 12.5, appleCharacterOffset: nil, contentSignature: "sig", updatedAt: taken)
        return [
            try preference(LectureQuizScore.courseQuizPreferenceKeyPrefix + "quiz-1", LectureQuizScore(right: 3, total: 4, takenAt: taken).preferenceValue, at: 90, in: folder),
            try preference(LectureQuizScore.preferenceKeyPrefix + "src-video-ch", LectureQuizScore(right: 1, total: 4, takenAt: taken).preferenceValue, at: 90, in: folder),
            try preference(MemoryCardDeckState.preferenceKeyPrefix + MemoryCard.draftDeckID(sourceID: "src-article"), deck.preferenceValue, at: 91, in: folder),
            try preference(LearnerProfile.courseFocusPreferenceKeyPrefix + followedCourse, "How the electron chain is built", at: 92, in: folder),
            try preference(ListeningPositionSync.preferenceKeyPrefix + "src-article", try #require(ListeningPositionSync.encode(position)), at: 93, in: folder),
            try preference(SourceDiscovery.blockedPodcastShowsPreferenceKey, ["Bad Show"], at: 94, in: folder),
            try preference("connectorHealth.zoom.state", "healthy", at: 95, in: folder),
        ]
    }

    /// A course an older build homed in the notebook, whose notebook does not list it: its payload
    /// carries `homeNotebookID`, which gives nothing (revision 9).
    static func homedCoursePayload() throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: json(CloudKitCoursePayload(
            id: homedCourse, title: "Homed course", courseCode: nil, institution: nil, instructors: nil, playlistURL: nil,
            lectures: [CourseSession(id: "lec-h", courseName: homedCourse, number: 1, title: "Only", createdAt: date(46))], lectureItems: [], quizzes: []
        ))) as? [String: Any])
        object["homeNotebookID"] = notebookID
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Applies the old world to a generation-1 store, as generation 1's sync applies what it fetches.
    static func apply(_ records: [CKRecord], to store: KnowledgeStore) throws {
        // A record whose rows name a Source that has not arrived (a meeting group's files) fails on its
        // foreign key and is applied again once the rest has, as generation 1's sync retries a record.
        var waiting: [CKRecord] = []
        for record in records {
            do { _ = try store.withoutSyncTracking { try CloudKitRecordMapper.apply(record: record, to: store) } } catch { waiting.append(record) }
        }
        for record in waiting {
            _ = try store.withoutSyncTracking { try CloudKitRecordMapper.apply(record: record, to: store) }
        }
    }

    /// Every mapping the old world gives, in order, against `store` as it stands.
    static func mappings(_ records: [CKRecord], store: KnowledgeStore) throws -> [LegacyMapping] {
        let context = StoreLegacyMappingContext(connection: store)
        return try records.map { try LegacyV2Mapping.map(LegacyRecordDecoder.decode($0), context: context) }
    }

    // MARK: Comparing

    /// The records the mappings give, merged as late import applies them: each owner's fields first,
    /// then every other giver's, a map or set per element and a minimum (N) or maximum (X) by its policy.
    static func merged(_ mappings: [LegacyMapping]) -> [String: (type: SyncRecordType, id: String, fields: [String: SyncJSON])] {
        var result: [String: (type: SyncRecordType, id: String, fields: [String: SyncJSON])] = [:]
        // A `clears` record makes nothing, so the activation derives none.
        let records = mappings.flatMap(\.records).filter { $0.giving != .clears }.sorted { ($0.owned ? 0 : 1) < ($1.owned ? 0 : 1) }
        for record in records {
            var fields = result[record.key]?.fields ?? [:]
            let isNew = result[record.key] == nil
            guard record.giving != .createsOnly || isNew else { continue }
            for (field, value) in record.fields {
                guard let held = fields[field] else { fields[field] = value; continue }
                let spec = record.type.spec.field(field)
                if spec?.kind != .scalar, var elements = held.objectValue, let given = value.objectValue {
                    for (key, element) in given { elements[key] = element }
                    fields[field] = .object(elements)
                } else if spec?.policy == .minimum, let a = held.numberValue, let b = value.numberValue {
                    fields[field] = .number(min(a, b))
                } else if spec?.policy == .maximum, let a = held.numberValue, let b = value.numberValue {
                    fields[field] = .number(max(a, b))
                }
            }
            result[record.key] = (record.type, record.id, fields)
        }
        return result
    }

    /// Fields as compared: a null and an empty map say nothing, as an absent field says nothing.
    static func normalized(_ fields: [String: SyncJSON], dropping: Set<String> = []) -> [String: SyncJSON] {
        fields.filter { field, value in
            !dropping.contains(field) && !value.isNull && value.objectValue.map { !$0.isEmpty } ?? true
        }
    }

    /// What only the activation gives: the satellites and generation-2 values an old record never gives.
    static let activationOnly: [SyncRecordType: Set<String>] = [
        .source: LegacyV2Mapping.sourceFieldsNotGiven, .artifact: LegacyV2Mapping.artifactFieldsNotGiven,
        .automation: LegacyV2Mapping.automationFieldsNotGiven, .notebook: LegacyV2Mapping.notebookFieldsNotGiven,
    ]
}
