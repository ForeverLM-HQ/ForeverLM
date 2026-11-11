import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A prefix is the head of the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// Keys built at runtime from a prefix and an id: one row per member. The
    /// account families come first, in the order `SyncedPreferenceKeys.syncedPrefixes`
    /// lists them; the device families after.
    enum Families {
        /// One row per named workspace view, so independently saved monitor
        /// arrangements never contend in a shared preference blob.
        static let workspaceViews = AccountFamily<String, Any?>(prefix: "studio.workspaceView.", coding: .any)
        /// `aiTask.<task>.{provider,model,effort,speed,prompt}` — the per-task
        /// Advanced overrides. Built in KeychainService from the AITask case.
        static let aiTask = AccountFamily<String, Any?>(prefix: "aiTask.", coding: .any)
        static let aiTaskRoute = AccountFamily<String, Any?>(prefix: "aiRoute.task.", coding: .any)
        /// `aiHost.<slot>|<model slug>` — which OpenRouter host serves one
        /// model for one task (`OpenRouterHostPreference`). A choice about the
        /// account's work and spend, like the routes beside it.
        static let openRouterHost = AccountFamily<String, Any?>(prefix: "aiHost.", coding: .any)
        /// `aiBackups.<slot>` — the models a Background setting falls back to
        /// when its own cannot answer (`AIBackupModels`). Account spend too.
        static let aiBackups = AccountFamily<String, Any?>(prefix: "aiBackups.", coding: .any)
        /// `aiBackground.provider` plus `aiBackground.model.<provider>`, the latter
        /// built by KeychainService.backgroundTaskModelKey(for:).
        static let aiBackground = AccountFamily<String, Any?>(prefix: "aiBackground.", coding: .any)
        /// One row per model/voice pair. Keeping reactions independent prevents
        /// a thumb changed on one device from overwriting reactions to other voices.
        static let voiceRating = AccountFamily<String, String?>(prefix: "readAloud.voiceRating.", .phoneWritable)
        /// `meetingFolder.image.<groupID>` — one row per meeting folder that has
        /// been given its own sidebar tile, for the same reason.
        static let meetingFolderImage = AccountFamily<String, Any?>(prefix: "meetingFolder.image.", coding: .any)
        /// `lectureQuiz.score.<sourceID>` — the latest sitting of each course
        /// lecture's quiz. Per-member state kept in the private database, so a
        /// team's copy of the course never carries it; one row per lecture so
        /// two Macs finishing two quizzes never collide.
        static let lectureQuizScore = AccountFamily<String, Any?>(prefix: "lectureQuiz.score.", coding: .any, .record(.sitting))
        /// `courseQuiz.score.<quizID>` — the latest sitting of each stored course
        /// quiz (practice, checkpoint, course test), for the same reasons.
        static let courseQuizScore = AccountFamily<String, Any?>(prefix: "courseQuiz.score.", coding: .any, .record(.sitting))
        /// `course.focus.<courseID>` — what the learner wants from one course, in
        /// their words. Per-member like the scores above, so a team's copy of
        /// the course never carries it; one row per course.
        static let courseFocus = AccountFamily<String, Any?>(prefix: "course.focus.", coding: .any, .record(.enrollment))
        /// Operational meeting-plugin health contains no credentials. Syncing
        /// it lets Web Studio warn about a dead Mac-side feed instead of showing
        /// historical meetings as though they were current.
        static let connectorHealth = AccountFamily<String, Any?>(prefix: "connectorHealth.", coding: .any, .record(.device))
        /// `memory.reviewDepth.type.<sourceType>` — how much of a memory review a
        /// kind of source gets by default ("keep podcasts quick"). Said about
        /// the material, not the Mac it was said on, so it follows the account.
        static let reviewDepthByType = AccountFamily<String, String?>(prefix: "memory.reviewDepth.type.", .phoneWritable)
        /// `listen.position.<sourceID>` — where the listener stopped in a
        /// narration, so the next device resumes there. One row per source; the
        /// file beside the audio in iCloud Drive is the offline copy and this
        /// is the one that actually arrives in time. See `ListeningPositionSync`.
        static let listeningPosition = AccountFamily<String, String?>(prefix: "listen.position.", .record(.readingState))
        /// `notebook.chatExcluded.<notebookID>` — the sources a notebook's chats
        /// leave out, as the learner unticked them. Per member like the course
        /// focus above, so a team's copy never carries it; one row per notebook
        /// (`NotebookChatSelection`).
        static let notebookChatExcluded = AccountFamily<String, Any?>(prefix: "notebook.chatExcluded.", coding: .any, .record(.notebookState))
        /// `notebook.chatContextNotebooks.<notebookID>` — the context notebooks
        /// whose sources a notebook's chats read, as the learner put them in.
        /// Per member for the same reason; the link itself rides the Notebook
        /// record (`NotebookChatContext`).
        static let notebookChatContextNotebooks = AccountFamily<String, Any?>(prefix: "notebook.chatContextNotebooks.", coding: .any, .record(.notebookState))
        /// `notebookCollection.<collectionID>` (a collection's name) and
        /// `notebook.collections.<notebookID>` (the collections one notebook is
        /// in): the learner's collections of notebooks, grouped in the Space's
        /// All and on the iPhone's Home (`NotebookCollections`). Their own taxonomy, like the course and
        /// meeting-group names above, so it follows the account; one row per
        /// collection and one per notebook, so two devices filing two
        /// notebooks at once both keep theirs, and per member, so a team's
        /// notebook never carries one member's collections.
        static let notebookCollectionName = AccountFamily<String, Any?>(prefix: "notebookCollection.", coding: .any)
        static let notebookCollectionMembership = AccountFamily<String, Any?>(prefix: "notebook.collections.", coding: .any, .record(.notebookState))
        /// `pageSpace.<spaceID>` (a space's name) and `page.space.<artifactID>`
        /// (the one space a page is in): the learner's spaces of pages in the
        /// Space sidebar (`PageSpaces`), ChatGPT's spaces. Their own grouping,
        /// like the collections above, so it follows the account; one row per
        /// space and one per page, so two devices moving two pages at once
        /// both keep theirs, and per member, never on the Artifact record.
        static let pageSpaceName = AccountFamily<String, Any?>(prefix: "pageSpace.", coding: .any)
        static let pageSpaceMembership = AccountFamily<String, Any?>(prefix: "page.space.", coding: .any)
        /// `pageSpaceTrash.<spaceID>`: when one of those spaces went to Trash
        /// (Codex's Trash holds spaces); one row per space, per member.
        static let pageSpaceTrash = AccountFamily<String, Any?>(prefix: "pageSpaceTrash.", coding: .any)
        /// `page.pinned.<artifactID>`: when the learner pinned a page
        /// (`PagePins`), ChatGPT's Pin. One row per page, per member.
        static let pagePins = AccountFamily<String, Any?>(prefix: "page.pinned.", coding: .any)
        /// `page.parent.<childArtifactID>`: the page a page is nested under
        /// (`PageParents`), ChatGPT's subpages. One row per child, per member.
        static let pageParents = AccountFamily<String, Any?>(prefix: "page.parent.", coding: .any)
        /// `chat.pinned.<sessionID>`: a chat in Home's Pinned section and its
        /// place there (`ChatPins`), Codex's Pin chat. One row per chat, per
        /// member, never on the chat's record.
        static let chatPins = AccountFamily<String, Any?>(prefix: "chat.pinned.", coding: .any)
        /// `aiSeeded.task.<task>` — that ForeverLM gave a task its starting
        /// model of its own (`KeychainService.seedCanvasVoiceRoute`), once for
        /// the account, so a learner who sends it back to Background is not
        /// given it again on another Mac.
        static let aiSeededTask = AccountFamily<String, Any?>(prefix: "aiSeeded.task.", coding: .any)
        /// `notebook.naming.<notebookID>` — the name and description ForeverLM
        /// last put on a notebook made without one, which it may replace while
        /// the notebook still carries them (`NotebookNaming`). Follows the
        /// account so a notebook made on the phone is named on the Mac, and so
        /// a second Mac never renames what the learner named on the first;
        /// one row per notebook.
        static let notebookNaming = AccountFamily<String, Any?>(prefix: "notebook.naming.", coding: .any)
        /// `notebook.thinkFirst.<notebookID>` — one notebook's own Think first
        /// level over the library's (`ThinkFirst`). Per member, like the
        /// notebook rows above, so a teammate's choice never changes it; one
        /// row per notebook.
        static let notebookThinkFirst = AccountFamily<String, Any?>(prefix: "notebook.thinkFirst.", coding: .any)
        /// `notebook.questions.<notebookID>` — the questions the notebook's
        /// guide suggested for its sources and which of them were asked
        /// (`NotebookSuggestedQuestions`), so a new chat on any device offers
        /// what is left without a model call. Per member, one row per notebook.
        static let notebookQuestions = AccountFamily<String, Any?>(prefix: "notebook.questions.", coding: .any)
        /// `cards.state.<deckID>` — what the learner changed about each card of
        /// one deck outside its Memory item: kept, skipped or still a draft, an
        /// edited front, variants, "always ask it this way", the seed it was
        /// drafted from (`MemoryCardDeckState`). Per member, in the private
        /// database, so a team's notebook never carries it; one row per deck,
        /// merged card by card on every write.
        static let cardDeckState = AccountFamily<String, Any?>(prefix: "cards.state.", coding: .any, .record(.card))
        /// `map.layout.<mapID>` — one of the learner's canvases: the cards
        /// they placed, the regions they drew and the arrows between them,
        /// and the canvas's name and Trash mark (`KnowledgeMapLayout`). Their
        /// own arrangement, so it follows the account; one row per canvas,
        /// merged entry by entry on receipt so two Macs that moved different
        /// cards both keep their moves.
        static let mapLayout = AccountFamily<String, Any?>(prefix: "map.layout.", coding: .any)
        /// `spaceList.<listID>` (a list of goals or ideas in the Space: its
        /// kind, name, made time and Trash mark) and `spaceListItem.<recordID>`
        /// (the one list a goal or an idea is in), `SpaceLists`. Per member.
        static let spaceList = AccountFamily<String, Any?>(prefix: "spaceList.", coding: .any)
        static let spaceListItem = AccountFamily<String, Any?>(prefix: "spaceListItem.", coding: .any)
        /// `reader.pdfRotations.<sourceID>` — the pages of one PDF source the
        /// learner turned, as JSON `{"<page>": <degrees>}`
        /// (`PDFPageRotations`). The file in the library is never rewritten for
        /// a reading preference, so a turn is the member's own state, keyed by
        /// the source's id and never on its record; one row per source, so two
        /// devices turning two papers both keep theirs.
        static let pdfRotations = AccountFamily<String, Any?>(prefix: "reader.pdfRotations.", coding: .any)
        static let movableOverlay = DeviceFamily<String, Any?>(prefix: "studio.movableOverlay.", coding: .any, reason: "dragged overlay positions, absolute pixels")
        static let screenRecordMode = DeviceFamily<String, Any?>(prefix: "screenRecordMode.", coding: .any, reason: "admin-only filming scope; must reach no other device or account")
        static let securityBookmark = DeviceFamily<String, Any?>(prefix: "securityBookmark_", coding: .any, reason: "security-scoped bookmarks are machine-local")
        static let aiPricing = DeviceFamily<String, Any?>(prefix: "aiPricing.", coding: .any, reason: "remote price cache, ~50 KB")
        static let aiCapabilities = DeviceFamily<String, Any?>(prefix: "aiCapabilities.", coding: .any, reason: "remote capability cache, refetched")
        static let xBookmarks = DeviceFamily<String, Any?>(prefix: "x_bookmarks_", coding: .any, reason: "sync cursor")
        static let aiUsageLedger = DeviceFamily<String, Any?>(prefix: "ai.usage.ledger_", coding: .any, reason: "diagnostics counters")
        static let retiredUsageDailyTotal = DeviceFamily<String, Any?>.unread(prefix: "usage_daily_total_", reason: "cache")
        static let retiredUsageRecords = DeviceFamily<String, Any?>.unread(prefix: "usage_records_", reason: "cache")
        static let retiredBillingTrialStart = DeviceFamily<String, Any?>.unread(prefix: "billing_trial_start_", reason: "anti-tamper")
        static let mobile = DeviceFamily<String, Any?>(prefix: "ios.", coding: .any, reason: "iOS-local; reader progress must never sync back")
        static let retiredOpenAISlidesSkill = DeviceFamily<String, Any?>.unread(prefix: "openai_slides_skill_", reason: "cache")
        static let walkthroughDeckPosition = DeviceFamily<String, Any?>(prefix: "walkthroughDeck.position.", coding: .any, reason: "where this phone left each walkthrough deck")

        static let all: [AnyPreferenceFamily] = [
            workspaceViews.erased,
            aiTask.erased,
            aiTaskRoute.erased,
            openRouterHost.erased,
            aiBackups.erased,
            aiBackground.erased,
            voiceRating.erased,
            meetingFolderImage.erased,
            lectureQuizScore.erased,
            courseQuizScore.erased,
            courseFocus.erased,
            connectorHealth.erased,
            reviewDepthByType.erased,
            listeningPosition.erased,
            notebookChatExcluded.erased,
            notebookChatContextNotebooks.erased,
            notebookCollectionName.erased,
            notebookCollectionMembership.erased,
            pageSpaceName.erased,
            pageSpaceMembership.erased,
            pageSpaceTrash.erased,
            pagePins.erased,
            pageParents.erased,
            chatPins.erased,
            aiSeededTask.erased,
            notebookNaming.erased,
            notebookThinkFirst.erased,
            notebookQuestions.erased,
            cardDeckState.erased,
            mapLayout.erased,
            spaceList.erased,
            spaceListItem.erased,
            pdfRotations.erased,
            movableOverlay.erased,
            screenRecordMode.erased,
            securityBookmark.erased,
            aiPricing.erased,
            aiCapabilities.erased,
            xBookmarks.erased,
            aiUsageLedger.erased,
            retiredUsageDailyTotal.erased,
            retiredUsageRecords.erased,
            retiredBillingTrialStart.erased,
            mobile.erased,
            retiredOpenAISlidesSkill.erased,
            walkthroughDeckPosition.erased,
        ]
    }
}
