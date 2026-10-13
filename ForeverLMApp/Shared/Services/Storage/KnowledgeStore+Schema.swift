import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    // MARK: - Pragmas & Schema

    func pragmas() throws {
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA busy_timeout = 10000")
    }

    /// The schema installed into a brand-new database and the target for one-time,
    /// transactional startup migrations. A store already at this version takes the
    /// read-only fast path apart from the code-owned `source_projection` view drift
    /// check.
    // 100: learning_goals.summary — a Notebook's short card description. Additive;
    // the column lands through addMissingColumnsForCurrentSchema.
    // 101: share_requests — a team member's request that a cited source be
    // shared into the team (teams-design.md, decision 14). CREATE TABLE only.
    // 102: learning_goals.repository — the GitHub repository a Notebook is
    // about, as owner/repo. Additive like summary; the < 102 probe below proves
    // the column landed before the version stamp commits.
    // 103: never shipped — main skipped it while the planner branch held it.
    // 104: review_sessions.loaded_source_ids — which sources a chat had read,
    // so a reopened chat holds them. Additive, local to this Mac, never synced.
    // 105: day_plans and time_blocks — the time-block planner (planner-design.md).
    // CREATE TABLE only, probed so a same-named foreign table rolls back. The
    // planner was written against 103, but builds 88 and 89 shipped stores at
    // 104, and createSchema returns before any CREATE TABLE when the stored
    // version already equals the current one — so the planner's tables need a
    // version those stores have not reached.
    // 106: global_artifacts.archived_at — when a doc or site was put away
    // (Archive on its ⋯ menu). One nullable column; NULL is the truth about
    // every existing row, so nothing is backfilled. Rides the Artifact payload.
    // 107: time_blocks.source_id — the source a block is for, set by dropping a
    // source on the Planner's clock — and day_activities, the Planner's log of
    // what the app saw the learner do. Additive; the column lands through
    // addMissingColumnsForCurrentSchema on a build-90 store and through CREATE
    // TABLE on an older one, the table through CREATE TABLE IF NOT EXISTS, and
    // the < 107 probes prove both before the stamp.
    // 108: time_blocks.source_ids — a block reads several sources, as a JSON
    // array of ids (planner-design.md, "A block's sources"). Additive: the
    // column lands through addMissingColumnsForCurrentSchema, then one
    // set-based UPDATE folds every existing source_id into it; time_blocks
    // holds a human's hand-drawn rows, tens per day, so the UPDATE is bounded
    // and reads no source. source_id stays as the first source, for the older
    // clients that still read it. The block kind (deep, shallow, meeting,
    // break) is retired in the same build: the column stays on stores that
    // have it, defaulted, and is neither read nor written any more.
    // 109: time_blocks.calendar_event_id and calendar_event_url — the calendar
    // event a block mirrors when a connected Google Calendar drew it, and the
    // event's page (planner-design.md, "Calendar"). Additive: NULL on every
    // existing row is the truth, no block came from a calendar before; the
    // columns land through addMissingColumnsForCurrentSchema on a v107 or
    // v108 store and through CREATE TABLE on an older one, and the < 109
    // probe proves both before the stamp.
    // 110: papers.paywall_suspicion — what the AI browser saw that made it
    // think a paper is paywalled when the explicit evidence it needs to mark
    // the paper itself was not on the page; the attention row turns it into a
    // one-click Mark as Paywalled. One nullable column; NULL is the truth
    // about every existing row (no browser run has said so), so nothing is
    // backfilled. Lands through addMissingColumnsForCurrentSchema, probed by
    // the < 110 step. Rides the source payload like is_paywalled.
    // 111: global_artifacts.hidden_at — when the learner hid a doc or site
    // from this Mac's lists (Hide on its ⋯ menu; the Hidden filter lists it
    // again). One nullable column; NULL is the truth about every existing row,
    // so nothing is backfilled. Unlike archived_at it never rides the Artifact
    // payload: hiding is this Mac's own view (teams-design.md, per-member
    // state), so the record upsert leaves the column alone and only
    // setArtifactHidden writes it.
    // 112: review_sessions.hidden_at — when the learner hid a chat from this
    // Mac's sidebar (Hide on its row menu; the Hidden fold under Chats lists
    // it again, with Show). One nullable column; NULL is the truth about every
    // existing row, so nothing is backfilled. Like global_artifacts.hidden_at
    // it never rides the ReviewSession payload: hiding is this Mac's own view
    // of the chat, so the sync upsert leaves the column alone and only
    // setReviewSessionHidden writes it.
    // 113: meeting_groups.schedule_json — when a meeting series meets
    // (weekdays, start, duration, zone; `MeetingSchedule`), so the Planner
    // draws its occurrence on every day it covers; and meeting_action_items —
    // what each session's transcript asked someone to do, one row per item,
    // extracted once per session by the Meeting Action Items task and ticked
    // off in the Planner (planner-design.md, "A meeting series on the
    // clock"). Both ride the MeetingGroup record. One nullable column and one
    // empty table with two indexes: NULL is the truth about every existing
    // group (no series had a fixed time before), nothing is backfilled, and
    // the < 113 probes prove the ALTER and the CREATE TABLE landed. DDL only.
    // 114: hidden_artifacts and hidden_review_sessions — the docs, sites and
    // chats the learner hid, one row each, no foreign key. The product owner
    // (2026-09-13): "all hidden items (docs, chats, podcasts, etc) should be
    // consistent across multiple macbooks". Hiding stays the learner's view
    // rather than the record's state — a teammate never sees it — but the
    // view is the account's, not one Mac's, so each row syncs as a
    // private-zone HiddenArtifact / HiddenReviewSession record, the shape
    // hidden sources, shows and channels already take. The columns 111 and
    // 112 added are retired: neither is read or written any more, a store
    // that has them keeps them, and this step copies their rows into the
    // tables (bounded by what a person hid by hand) and queues each for
    // CloudKit so the other Macs learn of hides made before this build. Two
    // CREATE TABLE IF NOT EXISTS, probed. Two new record types: create both
    // in Development, deploy to Production before shipping.
    // 115: video_cited_papers.kind and .context — the sources an article links
    // to join the candidate rows that already hold the papers a video's slides,
    // a meeting's transcript and a paper's reference list cite ("Find Linked
    // Sources"). `kind` says what a candidate is (paper, article, video,
    // podcast, post) and decides the import pipeline; its default 'paper' is
    // the truth about every existing row. `context` is one line on what the
    // article says about the link; NULL on every existing row. Two ALTER TABLE
    // ADD COLUMN with constant defaults, which SQLite applies without
    // rewriting the table, probed. The rows ride the existing VideoCitedPaper
    // record as JSON, so no CloudKit schema change.
    // 116: the display preferences that started following the account are
    // adopted from UserDefaults once.
    // 117: global_artifacts.kind and global_artifact_source_links — an
    // animation (docs/animations-design.md) is hosted as a ForeverLM site and
    // is told apart from one by the record's own kind, and every artifact may
    // name the sources it is about, one row a link, no foreign key on the
    // source (a source can arrive from CloudKit after the record, or be
    // deleted before it). One nullable column — NULL is the truth about
    // every existing row, none is an animation — and one empty table with an
    // index by source; both land through addMissingColumnsForCurrentSchema
    // and CREATE TABLE IF NOT EXISTS, and the < 117 probes prove them before
    // the stamp. DDL only; no row is read. Both ride the Artifact record's
    // encrypted payload as keys, so no CloudKit schema change.
    // 118: ai_usage_events.own_key — a call the learner's own router key paid
    // for now goes straight to that router, so the proxy never sees it and no
    // authoritative D1 row will ever arrive for it. The accounting predicate
    // hides client rows once server coverage begins, to stop a proxied call
    // being counted twice; without a column saying which rail paid, every
    // own-key call would be recorded and then silently dropped from the usage
    // pane, its totals and its CSV export. 0 is the truth about every existing
    // row: until this build every billable call went through the proxy. One
    // ALTER TABLE ADD COLUMN with a constant default, which SQLite applies
    // without rewriting the table, probed by the < 118 step. The flag rides
    // the existing AIUsageEvent record as a new field, so CloudKit gains a
    // field: create it in Development and deploy to Production before
    // shipping.
    // 119: learning_bouts — the timed learning bout, its write-up and the
    // break the write-up earns (planner-design.md, "A bout on the clock").
    // One empty table with an index by day; no store had a bout before, so
    // nothing is backfilled and nothing is read. CREATE TABLE IF NOT EXISTS
    // plus one CREATE INDEX, probed by the < 119 step before the stamp. The
    // rows ride the day's existing DayPlan record as a new `bouts` key, which
    // an older client decodes to an empty list, so CloudKit gains no field
    // and no schema deploy is needed.
    // 120: Goals leave Notebooks. A Goal is now discriminated by its deadline
    // rather than by having a parent, so a learner can set one without first
    // naming a Notebook (goals-design.md). Two parts, both additive: every
    // parentless companion record an older store holds is a Notebook — that is
    // what parentless meant until this build — so the < 120 step stamps them
    // `openEndedEndAt`, which is what `create_notebook` over MCP already wrote
    // and what the app now writes too; and `time_blocks.goal_id` records the
    // Goal a block serves. The Goal id rides the day's existing DayPlan
    // record as a new key on each block, which an older client decodes to nil,
    // so CloudKit gains no field and no schema deploy is needed. The end_at
    // rewrite travels as an ordinary value change on records that already
    // sync. Only rows created before Goals shipped (`goalsShippedAt`) are
    // promoted: a dated parentless row created later is a Goal set on a newer
    // build and synced in, and on 2026-09-19 a second Mac's first launch of
    // build 115 turned four such Goals into Notebooks before this guard existed.
    // 121: learning_goals.artifact_id — the Doc, Site or animation a Goal is
    // for ("Make a site of the rare mitochondrial diseases", and the site).
    // Additive like repository: NULL on every existing row is the truth, no
    // Goal named one before; the column lands through
    // addMissingColumnsForCurrentSchema and the < 121 probe proves it before
    // the stamp. Rides the learningGoal payload as a new Codable key an older
    // client decodes to nil, so CloudKit gains no field and no schema deploy
    // is needed.
    // 122: source_walkthroughs — a paper's guided walkthrough, the steps the
    // Reader follows beside the PDF (walkthrough-design.md). One empty table
    // keyed by source; no store had a walkthrough before, so nothing is
    // backfilled and nothing is read. CREATE TABLE IF NOT EXISTS, probed by
    // the < 122 step before the stamp; a same-named table of another shape
    // rolls the migration back. The record rides the encrypted Source payload
    // as a new `paperWalkthrough` key an older client decodes to nil, so
    // CloudKit gains no field and no schema deploy is needed.
    // 123: time_blocks.purpose — what kind of hour a block is (work, read,
    // review), so the Planner can draw a reading and a review as the
    // different hours they are and the assistant can plan one toward a Goal
    // over MCP. 'work' is the truth about every existing row: nothing about a
    // block said otherwise before this build, so the column carries a
    // constant default and nothing is backfilled. One ALTER TABLE ADD COLUMN,
    // which SQLite applies without rewriting the table, probed by the < 123
    // step before the stamp. The purpose rides the day's existing DayPlan
    // record as a new key on each block, which an older client decodes to
    // work, so CloudKit gains no field and no schema deploy is needed.
    // 124: artifact_walkthroughs — a saved animation's guided walkthrough, the
    // steps the chat plays beside the animation with each step pinning the
    // page to one of its own steps (walkthrough-design.md, "Animations are
    // walked through"; the product owner, 2026-09-20). One empty table keyed by
    // artifact, the shape of source_walkthroughs; no store had one before, so
    // nothing is backfilled or read. CREATE TABLE IF NOT EXISTS, probed by the
    // < 124 step before the stamp. The record rides the encrypted Artifact
    // payload as a new `walkthrough` key an older client decodes to nil, so
    // CloudKit gains no field and no schema deploy is needed.
    // 125: learning_goals.sort_order — where the learner put a Goal in the
    // Goals tab (product owner, 2026-09-20: "allow me to reshuffle these"). NULL
    // on every existing row is the truth: no Goal was ever placed by hand,
    // and a NULL row reads by deadline after the placed ones. The column
    // lands through addMissingColumnsForCurrentSchema and the < 125 probe
    // proves it before the stamp; DDL only, no row is read. The placement
    // rides the learningGoal payload as a new Codable key an older client
    // decodes to nil, which the sync upsert's COALESCE keeps local, so
    // CloudKit gains no field and no schema deploy is needed.
    // 126: ideas and idea_links — the Ideas tab (product owner, 2026-09-20: "i can
    // jot down my ideas there and then link relevant research and
    // explorations. i just need a place to jot them down"). Two new tables
    // and two indexes, all empty on an older store: CREATE TABLE IF NOT
    // EXISTS, probed by the < 126 step before the stamp, no row read. The
    // Idea and its links travel as one new `Idea` CloudKit record, which is
    // a schema gate: create it in Development, deploy to Production before
    // the build that writes it ships (docs/ideas-design.md).
    // 127: memory_day_close_state and chat_consolidations — the day close
    // (product owner, 2026-09-20: "at the end of the day ... let's process
    // everything that was done today, and let's come up with a good memory
    // review for tomorrow"). The one-row state table holds this device's
    // consolidation watermark; chat_consolidations records which chats were
    // folded into understanding documents and through which turn, so a run
    // that repeats finds nothing to do. Both device-local and regenerable:
    // never synced, no CloudKit field. CREATE TABLE IF NOT EXISTS, probed by
    // the < 127 step before the stamp, no row read (docs/memory-design.md,
    // "The day close").
    // 128: time_blocks.location — where the hour is as the calendar says it,
    // the event's conference link or else its room (product owner, 2026-09-20, on
    // the Zoom URL filling a meeting's notes: "let me jot down some notes,
    // what I want to talk about ... instead of showing the zoom link because
    // there's already a join zoom button"). Until this build the import wrote
    // that link into `notes`, the field that is the learner's. The column
    // lands through addMissingColumnsForCurrentSchema, then one set-based
    // UPDATE moves every Google and Apple calendar block's notes into it and
    // clears the notes — those imports wrote the notes and nothing else did,
    // so what is there is the calendar's; a meeting-series block
    // (`meeting:` key) never had its notes written by an import and keeps
    // them. time_blocks holds a human's hand-drawn rows, tens per day, so
    // the UPDATE is bounded, reads no source, and the < 128 probe proves the
    // column before the stamp. Rides the DayPlan payload as a new Codable
    // key an older client decodes past, so CloudKit gains no field.
    // Schema 129: `source_understanding.discussed_idea_ids`. A chat is rarely
    // about a whole paper, but a chat was enough to put the whole paper into a
    // review and grade the learner on all of it (2026-09-21). The day close now
    // records which ideas a conversation reached, and a source that is in the
    // review only because it was discussed is asked about only those. Nothing
    // is backfilled: an empty list reads as "nothing known", which is the old
    // behaviour, and the next close writes the truth. Local only — the column
    // rides no CloudKit field, so an older client is unaffected.
    // Schema 130: artifact_lessons — a tutored lesson on a source, kept as an
    // artifact of its own (product owner, 2026-09-22: "perhaps paper walkthroughs
    // should be their own artifact"). One row a lesson artifact
    // (`global_artifacts.kind = 'lesson'`), holding the chapters as JSON
    // beside the source it teaches. Never released.
    // Schema 131: lessons folded into walkthroughs (product owner, 2026-09-23:
    // "merge lessons and walkthroughs into one feature"). A store that has
    // the 130 table converts each lesson into its source's walkthrough —
    // chapters, moments as one-beat steps, the four question kinds, the Say
    // more chips — where the source has none or the lesson is newer, archives
    // the lesson artifact (a synced state, so no tombstone is needed and
    // nothing comes back), and drops the table. Bounded by the lessons a Dev
    // build wrote in the one day the feature existed: no store outside the
    // developer's own ever had a row. A store that never reached 130 has no
    // table and skips the block.
    // 132: cleaner v19 — a paper is cleaned from its whole PDF; the step only
    // queues ids for the post-launch drain.
    // 133: walkthrough_progress — where the learner is in each walk and how
    // its questions went, kept for the walk rather than read back out of the
    // chat that played it (product owner, 2026-09-23: "why is a walkthrough with
    // cards still kind of a chat?"; walkthrough-design.md, "the walk leaves
    // the chat"). One empty table keyed by the walk's subject: CREATE TABLE
    // IF NOT EXISTS, probed by the < 133 step before the stamp, no row read.
    // A walk played in a chat before this build is taken up from the chat's
    // step turns the first time it is opened, not here. The progress
    // travels as one new `WalkthroughProgress` CloudKit record, which is a
    // schema gate: create it in Development, deploy to Production before the
    // build that writes it ships.
    // 134: text survives SQLite whole (2026-09-23). A text bind stopped at the
    // string's first U+0000, which PDFKit returns for an unmapped glyph, so
    // three papers re-extracted by cleaner v19 stored 1,631 / 16,241 / 91,591
    // characters of 65k / 114k / 140k under hashes and word counts of the
    // whole paper. Binds and reads now carry explicit lengths (`SQLiteText`)
    // and PDF extraction marks the glyph U+FFFD. The step only copies every
    // paper and article preparation id into
    // `canonical_content_integrity_audit_queue` — one set-based INSERT, no
    // text read; the cleanup drain hashes the stored raw text off-main in
    // batches of 50 and re-queues a row whose text disagrees with its hash.
    //
    // 135: spend control for background AI (2026-09-24). Two local-only
    // tables, `background_ai_bulk_jobs` and `background_ai_bulk_job_sources`,
    // hold a bulk re-queue into a paid queue for the learner's decision
    // (`holdingBulkRequeue`). Created empty and proved before the stamp;
    // nothing is backfilled, and no queued row of an older re-queue is held.
    //
    // 136: the learner's own chat skills (2026-09-24; chat-design.md,
    // "Skills"). One empty table, `skills`: a name the composer calls with
    // `/`, a description the chat reads to decide when a skill applies, and
    // markdown instructions. CREATE TABLE IF NOT EXISTS, probed by the < 136
    // step before the stamp, no row read. A skill travels as one new `Skill`
    // CloudKit record, which is a schema gate: create it in Development,
    // deploy to Production before the build that writes it ships.
    //
    // 137: family plans (2026-09-25; family-design.md). One nullable column,
    // `teams.family_plan_code`: the code the owner's plan hands a family
    // team so each member's Mac joins it at the proxy. NULL on every existing
    // row is the truth — no team was a family before. ALTER TABLE ADD COLUMN,
    // probed by the < 137 step before the stamp, no row read. It rides the
    // existing `Team` record's payload, so there is no CloudKit schema gate.
    //
    // 138: course quizzes written ahead of time (2026-09-26;
    // lecture-quiz-design.md). One empty table, `course_quizzes`: a course's
    // practice quizzes, checkpoint quizzes and course test, each with its
    // questions as JSON and the lecture it follows in the outline. CREATE
    // TABLE IF NOT EXISTS, probed by the < 138 step before the stamp, no row
    // read, nothing backfilled. Quizzes ride the existing `Course` record's
    // payload (`quizzes`, decodeIfPresent), so there is no CloudKit schema gate.
    //
    // 139: a reader mark can link the chat its note came from (2026-09-26;
    // chat-design.md, "What's New"). One nullable column,
    // `source_highlights.chat_session_id`: the chat that researched what has
    // changed since the source was written, or one an assistant saved and
    // linked over MCP. NULL on every existing row is the truth — no mark
    // linked a chat before. ALTER TABLE ADD COLUMN, probed by the < 139 step
    // before the stamp, no row read. It rides the existing `SourceHighlight`
    // record's encrypted payload (`chatSessionID`, decodeIfPresent), so there
    // is no CloudKit schema gate.
    //
    // 140: the papers a mark's note cites (2026-09-26; chat-design.md, "What's
    // New"). One nullable column, `source_highlights.references_json`: the
    // citation, title and address of each paper the note names, which the
    // reader offers to open or add to the library from the mark. NULL on every
    // existing row is the truth. ALTER TABLE ADD COLUMN, probed by the < 140
    // step before the stamp, no row read. It rides the `SourceHighlight`
    // payload (`references`, decodeIfPresent), so there is no CloudKit schema
    // gate. 139 had shipped to main an hour earlier, so this is its own step.
    //
    // 141: a mark's "since publication" update, kept apart from the learner's
    // own note (2026-09-26; chat-design.md, "What's New"). Two nullable
    // columns, `source_highlights.publication_update` (what has been learned
    // since the source was written, which What's New writes) and
    // `publication_update_at` (when it was last written). `note` stays the
    // learner's. NULL on every existing row is the truth: nothing is moved
    // out of `note`, because a note's author is not recorded and guessing it
    // would rewrite the learner's words. ALTER TABLE ADD COLUMN, probed by the
    // < 141 step before the stamp, no row read. It rides the `SourceHighlight`
    // payload (`publicationUpdate`, decodeIfPresent), so there is no CloudKit
    // schema gate.
    //
    // 142: a course quiz's symbol and picture (2026-09-26;
    // lecture-quiz-design.md, "Titles, symbols and pictures"). Two nullable
    // columns, `course_quizzes.symbol` (the SF Symbol its writer chose for
    // the topics) and `course_quizzes.artwork` (a small JPEG drawn when the
    // learner asks). NULL on every existing row is the truth. ALTER TABLE ADD
    // COLUMN, probed by the < 142 step before the stamp, no row read. They
    // ride the existing `Course` record's payload inside each quiz
    // (`symbol`, `artwork`, decodeIfPresent), so there is no CloudKit schema
    // gate.
    //
    // 143: titles are plain text (2026-09-27). A scholarly catalog hands over
    // a title with its inline markup — Crossref's
    // `Respiratory chain linked H<sub>2</sub>O<sub>2</sub> production`,
    // `ATP‐sensitive K<sup>+</sup> channel` — and every surface drew the tags
    // as text, the chat's Sources list among them. Every title now takes
    // `decodingTitleMarkup()` on its way in (`H₂O₂`, `K⁺`); the < 143 step
    // gives the stored ones the same fold (`foldStoredSourceTitleMarkup`).
    // No DDL: it reads only subtype rows whose title holds a `<` (three on
    // the largest library, one scan of each title column), rewrites those the
    // fold changes, stages them in `source_sync_repair_queue` so the deferred
    // drain republishes the clean title to the phone and the other Mac, and
    // drops their `source_fts_state` so the indexer rewrites their full-text
    // row. A `<` that is not markup (`Zara <> Alan`) is left as written.
    //
    // 144: an author is a name, and a paper's title is not a glyph-damaged
    // copy of the one its DOI registered (2026-09-27; sources-sidebar-design.md,
    // "Row and collection contract"). Two repairs in one step. First, stored
    // authors that are some other field misread as one — markup, a web
    // address, a "name" longer than any name (`SourceAuthor`) — are cleared:
    // two articles held a kilobyte of their page's head, eleven an Open
    // Graph profile link. It reads only author cells holding `<`, `=`, `://`,
    // a leading `www.` or more than 256 characters, sets the ones the rule
    // refuses to NULL, stages their sources in `source_sync_repair_queue` for
    // the deferred republish and drops their `source_fts_state` so the
    // indexer rewrites the full-text row that indexed the markup. Nothing
    // stored holds the real byline, so none is invented; Extract Missing
    // Authors and a website refresh fill it as for any article without one.
    // Second, one empty local-only table, `paper_registered_title_queue`, and
    // one set-based INSERT staging every paper with a DOI: after launch
    // `RegisteredPaperTitleCheckService` asks Crossref and DataCite for each
    // DOI's registered title and restores it where the stored one is it with
    // characters the PDF's text lost (`RegisteredPaperTitle`). The network
    // never runs in the migration. No CloudKit schema change.
    //
    // 145: a course can be shared with a team (2026-09-27; teams-design.md,
    // decision 21). One nullable column, `courses.team_id`, and its index:
    // the team whose library a course is a copy in, as `sources.team_id` is
    // for a source. NULL on every existing row is the truth — no course was
    // a team's before. ALTER TABLE ADD COLUMN, probed by the < 145 step
    // before the stamp, no row read. A team's course rides the existing
    // `Course` record in the team's zone, and the zone it arrives from is
    // what stamps the column, so there is no payload field and no CloudKit
    // schema gate.
    //
    // 146: a scheduled task's failed run is tried again (2026-09-27;
    // scheduled-tasks-design.md, "Failure behavior"). Two columns on
    // `scheduled_task_runs`: `attempt` (which try the receipt describes,
    // `INTEGER NOT NULL DEFAULT 1`, the truth for every existing receipt:
    // no run was tried twice before) and `retry_at` (when the next try is
    // due, nullable; NULL on every existing row, since none is waiting).
    // ALTER TABLE ADD COLUMN with a constant default, probed by the < 146
    // step before the stamp, no row read. They ride the existing
    // `ScheduledTask` record's payload inside each run (`attempt`,
    // `retryAt`, decodeIfPresent), so there is no CloudKit schema gate.
    //
    // 147: research_directions — Directions (product owner, 2026-09-28: "a user
    // identifies a goal, and it helps to do research, and come up with
    // potentially interesting directions"; docs/directions-design.md). One
    // new table and one index, empty on an older store: CREATE TABLE IF NOT
    // EXISTS, probed by the < 147 step before the stamp, no row read. Each
    // Direction travels as one new `ResearchDirection` CloudKit record, which
    // is a schema gate: create it in Development, deploy to Production before
    // the build that writes it ships.
    //
    // 148: a formatted YouTube transcript says what its captions say
    // (2026-09-28; backend-storage-sync.md, "Formatted YouTube transcripts
    // held to their captions"). Transcript Formatting dropped, repeated and
    // invented text, and put markers on the wrong words, in transcripts
    // stored before `ReadableTranscriptMarkers.checked` held new ones to
    // their captions. One empty local-only table,
    // `youtube_transcript_check_queue`, and one set-based INSERT staging every
    // personal YouTube video by its `videos` row: after launch
    // `YouTubeTranscriptCheckService` fetches each video's captions and
    // rewrites the stored text where the check changes it and nothing anchored
    // to it would move. Ids only; the migration reads no text and fetches
    // nothing. No CloudKit schema change.
    //
    // 149: a reopened chat keeps its effort and speed (product owner, 2026-09-28:
    // "upon rebuild of the app, not only should the model we were using be
    // saved, we also the reasoning effort that we had chosen"). Two nullable
    // columns on `review_sessions` beside `model_provider`/`model_id`:
    // `model_effort` (an `AIEffort` raw value) and `model_speed` (an
    // `AISpeed` raw value), stamped whenever the model is. NULL is the
    // model's own default effort and standard speed, which is the truth for
    // every existing chat: none recorded a pick before. ALTER TABLE ADD
    // COLUMN, probed by the < 149 step before the stamp, no row read. They
    // ride the existing `ReviewSession` record's payload (`modelEffort`,
    // `modelSpeed`, decodeIfPresent), so there is no CloudKit schema gate.
    //
    // 150: a course lives in a notebook (2026-10-01; notebooks-design.md,
    // "Homing"; the product owner: "artifacts and courses should live on a per notebook
    // basis"). One nullable column, `courses.home_notebook_id`, and its
    // index: the Notebook the course lives in, an organizational label like
    // `global_artifacts.home_notebook_id`, with no foreign key because CloudKit
    // may deliver the course before its Notebook. `notebook_course_links` stays
    // the "this notebook's sources follow the course" relation, which the
    // home always has. NULL on every existing row is the truth — no course
    // had a home before — and the learner-confirmed "Make a notebook for
    // each course" (`makeNotebooksForCourses`) fills it later, never the
    // migration. ALTER TABLE ADD COLUMN, probed by the < 150 step before the
    // stamp, no row read. The home rode the existing `Course` record's
    // encrypted payload (`homeNotebookID`, decodeIfPresent), so there was no
    // CloudKit schema gate.
    //
    // Retired 2026-10-03 (the product owner: "courses should not be a part of
    // notebooks"): a course is its own thing and has no home. The column and
    // its index stay, unread and unwritten, until the schema-v2 store
    // replaces this one; a home a course already had also had its
    // `notebook_course_links` row, so its notebook keeps following it.
    //
    // 152: a team notebook's approval reaches the team (2026-10-02;
    // teams-design.md, decision 7). Builds before 152 blanked
    // `learning_goal_items.review_state` from every outbound team
    // LearningGoal together with the member's progress, and nil reads as
    // approved, so a pending suggestion or a rejected tombstone reached every
    // teammate as an approved source; inbound applies then put back whatever
    // each member already held. The record now carries approval and inbound
    // follows it. No DDL: one set-based UPDATE and one INSERT … SELECT stage,
    // for one republish, each team Notebook this Mac holds a pending or
    // rejected item in, in a team it may edit, whose record sync already
    // tracks (`stageTeamNotebookApprovalRepublish`). A team Notebook whose
    // items all read as approved here is left alone, since the team's record
    // already says so and this Mac's view could only overwrite a teammate's
    // verdict. Nothing is read item by item and nothing reaches the network.
    // `reviewState` already rides the existing LearningGoal payload, so there
    // is no CloudKit schema gate. A Mac on build 177 or older still blanks
    // approval on every team Notebook it saves, and a 152 Mac now takes that
    // nil as approved; there is no compatibility path, the team updates
    // together (CHANGELOG, teams-design.md decision 7).
    // 153: links left pointing at a notebook that is gone are released
    // (2026-10-02; notebooks-design.md, "Merging and splitting"). Merging
    // Notebooks and a split with `keep_parent` false removed the emptied
    // notebook by a raw DELETE, so its chats, nested Goals, Docs, courses,
    // Ideas' links and the rest kept the dead id; both now move everything to
    // the notebook kept first (`moveNotebookContentsInTransaction`). No DDL.
    // One bounded, set-based repair (`releaseLinksToDeletedNotebooks`): for
    // each id carrying a `learningGoal` tombstone with no row — never an id
    // merely not delivered yet — the chats, courses, scheduled tasks, Memory
    // items and Planner rows lose it, nested Goals stand alone, Docs lose the
    // home and the link, other Notebooks their related link, placements the
    // tag and Ideas the link, each record republished through `sync_metadata`
    // / `sync_changes` before the stamp. Nothing is deleted but link rows; a
    // read-only team's rows are left alone. Measured on the production
    // library (36 notebooks, 4 tombstones): nothing pointed at a tombstoned
    // id, 0 rows changed, about 5 ms. Two chats there name an id with no
    // row and no tombstone; that reads like a Notebook not delivered yet, so
    // they stay as they are (the rail already lists them under Chats). No
    // CloudKit schema change.
    // 154: the schema-v2 local store (docs/cloudkit-schema-design.md §12.7,
    // WP4). DDL only, plus one row-preserving rebuild, and nothing is filled:
    // - the replica tables, empty: `ck_zones`, `ck_records` and the rest
    //   (`ReplicaStore.sharedTables`, `KnowledgeStore.macReplicaTables`);
    // - `wire_id` on sources, learning_goals, review_sessions,
    //   global_artifacts and courses, NULL until the generation-2
    //   activation fills it, and the indexed virtual column
    //   `wire_key = COALESCE(wire_id, id)` every v2 join uses, so no row
    //   drops out of a join while wire_id is NULL;
    // - learning_goals.entity_kind, merged_into, fold_kind, moving_to and
    //   moved_to, NULL until the activation;
    // - the per-member tables that held `ON DELETE CASCADE` keys to content
    //   (source_highlights, hidden_sources, hidden_podcast_episodes, the two
    //   visible overrides, source_understanding, and notebook_files, whose
    //   notebook_id becomes nullable) are rebuilt without them, row for row
    //   (`rebuildPerMemberTablesWithoutContentForeignKeys`): a few thousand
    //   rows on the largest library. Nothing references them, so
    //   foreign_keys stays on. Generation 1 still removes those rows with
    //   their source or notebook, now explicitly in deleteSourceRows,
    //   deleteLocalDuplicateRows and the notebook delete, so it behaves as
    //   before; generation 2 keeps them (D18).
    // No trigger is created here: the generation-2 activation installs them,
    // so a generation-1 build never grows an outbox. Before this step runs,
    // the store open takes `knowledge.pre-154.db` (§13.3 step 1,
    // `KnowledgeRollbackCopy`). A disk with no room for that copy holds the
    // store below 154 for the launch: every earlier step still runs, as none
    // of them ever needed a copy, and the store is stamped 153
    // (`createSchema(stoppingBeforeSchema154:)`). No CloudKit schema change in
    // the old container; the new one's schema is `schema/cloudkit-schema.json`.
    // 155: the Source and Collection records' local tables (§12.7, WP7), DDL
    // only and empty: source_work_keys (the work-key index lookup-before-mint
    // reads), source_files and source_derived (FileRefs by role and kind),
    // source_collections (podcast shows, YouTube channels and playlists no
    // table holds) and source_wire_fields (the Source fields no column holds)
    // (`KnowledgeStore.sourceSyncTables`). Generation 1 never touches them;
    // the generation-2 activation fills them. Like every step from 154 on, it
    // waits with 154 on a store held below it for want of room.
    // 156: the Notebook, Goal, Entry and NotebookState records' local tables
    // (§12.7, WP8), DDL only and empty: learning_goal_items.order_key (an
    // Entry's fractional key), notebook_states (the member's own state per
    // notebook: chat ticks, context notebooks, collections, sidebar), the
    // notebook_resolution table `resolveNotebook()` keeps, and
    // notebook_research_questions (one row per question), plus the
    // back-pointer view ck_notebook_children
    // (`KnowledgeStore.notebookSyncTables`). Generation 1 never touches
    // them; the generation-2 activation fills them. Like every step from 154
    // on, it waits with 154 on a store held below it for want of room.
    // 157: the Course, Lesson, Quiz and Enrollment records' local columns and
    // table (§12.7, WP9), DDL only and empty: courses.created_at,
    // course_lectures.order_key, course_lecture_items.order_key, span_json
    // and span_slot (a lesson Entry's key, its span and the n of its `#n`),
    // course_quizzes.revision (1 on every row), and course_enrollments (the
    // member's own Enrollment per course) (`KnowledgeStore.courseSyncTables`).
    // A course lives in no notebook since 2026-10-03, so there is no homing
    // column and the back-pointer view no longer lists courses by their
    // retired home. Generation 1 never touches them; the generation-2
    // activation fills them. Like every step from 154 on, it waits with 154
    // on a store held below it for want of room.
    // 158: the Chat and Exchange records' local columns (§12.7, WP10), DDL
    // only and NULL: review_sessions.chat_kind (the v2 kind, D50; today's
    // `kind` keeps its generation-1 meaning), marks_reviewed and
    // context_mode, and review_exchanges.anchor_json and cited_source_ids
    // (`KnowledgeStore.chatSyncColumns`). Generation 1 never reads or writes
    // them; the generation-2 activation derives the three on review_sessions.
    // Like every step from 154 on, it waits with 154 on a store held below it
    // for want of room.
    // 159: the Artifact and Comment records' local tables (§12.7, WP11), DDL
    // only and empty: global_artifacts.body_ref (the Doc body's FileRef the
    // body publisher writes), artifact_files (an Artifact's other satellites,
    // and a Notes Doc's body) and ck_legacy_bodies (the notes bases the
    // catch-ups take from the old world, by wire id)
    // (`KnowledgeStore.artifactSyncTables`). Generation 1 never touches them.
    // Like every step from 154 on, it waits with 154 on a store held below it
    // for want of room.
    // 160: the member's reading state (§12.7, WP12), DDL only and empty:
    // reading_states, one row per ReadingState record keyed by the source's
    // wire id (`KnowledgeStore.readingSyncTables`). Generation 1 never touches
    // it, and its `sources` columns stay the reading state's truth; the
    // generation-2 activation fills it. Like every step from 154 on, it waits
    // with 154 on a store held below it for want of room.
    // 161: the memory records' local tables (§12.7, WP13), DDL only and
    // empty: memory_sittings and memory_sitting_answers (Sittings and their
    // answers), memory_card_states (a card's state outside its kept wording),
    // device_activity_days and activity_logs (this Mac's and every other
    // log), practices (`KnowledgeStore.memorySyncTables`). Generation 1 never
    // touches them; the generation-2 activation fills them. Like every step
    // from 154 on, it waits with 154 on a store held below it for want of
    // room.
    // 162: the Task, Job and Automation records' local table and columns
    // (§12.7, WP14), DDL only and empty: jobs (the work a Mac does for the
    // iPhone, the web and the hosted MCP, one row per Job record),
    // notebook_tasks.order_key (a task's board key),
    // scheduled_tasks.runner_device_id (the Mac that runs an automation) and
    // scheduled_task_runs.ring_slot (the run's slot in its 20-slot ring)
    // (`KnowledgeStore.tasksSyncTables`). Generation 1 never touches them;
    // the generation-2 activation fills them. Like every step from 154 on, it
    // waits with 154 on a store held below it for want of room.
    // 163: the Device record's and the import-blocked shows' local tables
    // (§12.7, WP12b), DDL only and empty: devices (one row per Device record)
    // and blocked_podcast_shows (one row per show whose episodes are never
    // imported) (`KnowledgeStore.personalStateSyncTables`). Generation 1 never
    // touches them; its connectorHealth.* and podcasts.blockedShows rows stay
    // their truth, and the generation-2 activation fills them. Like every
    // step from 154 on, it waits with 154 on a store held below it for want
    // of room.
    // 164: a notebook is no longer called a project in storage
    // (product owner, 2026-10-04: "they shouldn't be called projects internally
    // anymore"). Six tables and thirteen columns that said project say
    // notebook (`renameProjectStorageForSchema164`: ALTER TABLE RENAME,
    // so rows, indexes, foreign keys and triggers stay; the indexes that
    // carried the old word are dropped and made again by the installer; the
    // back-pointer view ck_notebook_children is made again, since its rows
    // name tables; the generation-2 outbox's table and column names follow),
    // and the stored kind values that said 'project' (`idea_links.kind`,
    // `research_directions.home_kind`) read 'notebook'; the usage ledger keeps
    // the subject type each row was written with. It runs before any statement
    // names the new tables, for the reason schema 98's rename does, and it
    // does not wait with 154 on a store held below it: this build's queries
    // name the new tables, and a rename needs no rollback copy. 0.16 s on a
    // clone of the 3.3 GB Dev store. The settings catalog's keys
    // (`studio.projectOrder`, `studio.navigation.expandedProjectIDs.v1`,
    // `studio.unpinnedProjects`) keep their names. No CloudKit schema change.
    // 165: three local tables for the sensemaking shapes
    // (docs/sensemaking-design.md), DDL only and empty: `atlases` (one row an
    // Atlas, its concepts as JSON), `source_levels` (a source's reading levels
    // for the Reader, keyed to the text they were written from) and
    // `source_faces` (a source card's written faces on the Canvas). Each is
    // derived and rewritable, never synced (docs/backend-storage-sync.md,
    // "Not synced"), so no CloudKit schema change.
    // 166: the soft hyphens older builds left in stored text go
    // (docs/source-content-integrity.md, "Soft hyphens are not text";
    // docs/backend-storage-sync.md, "Soft hyphens repaired"). One empty
    // local-only table, `source_text_soft_hyphen_repair_queue`, probed, and
    // one set-based INSERT staging every source of the learner's own library
    // by id: after launch, before sync starts, `drainStoredSoftHyphenRepairBatch`
    // finds the few whose text holds U+00AD or a literal `&shy;` and repairs
    // each with what was derived from its old text. The migration reads no
    // text. Like every step from 154 on, it waits with 154 on a store held
    // below it for want of room. No CloudKit schema change.
    // 167: podcast transcripts still cut at the retired 50,000-character
    // import cap are found by where they stop (2026-10-06;
    // docs/source-content-integrity.md). Schema 85's audit counted a
    // transcript as complete when it held 85% of its TTML text, so every
    // episode of 50,000 to 58,800 characters passed with its end missing and
    // was stamped `podcasts.detruncated_ttml_sha256`, which exempted it for
    // good; an episode with no stored TTML was never measured at all. The new
    // audit (`PodcastTranscriptCompleteness`) finds where the stored
    // transcript's last words sit in the episode text and restores only one
    // the cap cut. Its findings go in a new local-only table,
    // `podcast_transcript_audits` (one row an episode: what it found, against
    // which TTML), so the old marker is retired, unread and unwritten, and no
    // `podcasts` row is rewritten: an UPDATE of that row rewrites its TTML,
    // 1.4 GB over the largest library. `podcast_transcript_detruncation_queue`
    // gains `retry_after`, since an episode with no stored TTML is measured
    // against one fetch of Apple's and a failed fetch waits before it is
    // tried again. The step is ids only: every active podcast with stored
    // TTML, and every public Apple episode without it whose text did not
    // come from YouTube, is queued (a row left there by schema 85 starts its
    // attempts again); the drain after launch extracts, fetches and
    // restores. The `podcasts` columns it reads are answered without reading
    // a TTML (`octet_length`). Neither table syncs, so no CloudKit schema
    // change, and nothing is republished until an episode is restored.
    // 168: where each source's full-text row is (docs/backend-storage-sync.md,
    // "Full-text rows found by rowid"). Two local tables, DDL only:
    // `source_fts_rows` (a source's FTS5 rowid, so its row is deleted by rowid
    // instead of reading every row's text for an UNINDEXED `source_id`) and
    // `source_fts_row_backfill` (one row, enqueued here, while rows written
    // before 168 have no rowid recorded; `recordSourceFTSRows` records them
    // after launch). The migration reads no full-text row. It does not wait
    // with 154 on a store held below it: this build's full-text writes read
    // the map. Never synced, so no CloudKit schema change.
    // 169: a PDF book is one file (docs/backend-storage-sync.md, "A book is
    // one file"). `book_sources` gains `page_start` and `page_count`: the
    // run of the book file's pages that is the chapter. NULL on every
    // existing row is the truth, since every chapter there is a file of its
    // own. A local-only queue, `book_file_merge_queue`, takes the id of every
    // book with a chapter that is a PDF file (set-based, one row a book), and
    // after launch `BookFileMerge` puts each book back into one file, points
    // its chapters at their pages and deletes the chapter files. The
    // migration reads no file. Like 168 it does not wait with 154 on a store
    // held below it, since this build's book writes name the columns. They
    // travel as `Source.meta.pageStart` and `pageCount`, inside the encrypted
    // payload, so no CloudKit schema change.
    // 170: an EPUB book is one file too. An older build unpacked each EPUB
    // into `Books/<book>/Chapters/`; a chapter keeps that address, which now
    // names the entry inside the book's `.epub` (`EPUBBookFiles`). The
    // migration queues, in 169's queue, every book with a chapter addressed
    // in an unpacked folder (ids only, no file read), and after launch the
    // drain packs each folder into the book's file, reads every entry back,
    // and removes the folder. No column, nothing synced: a chapter's file
    // never travelled, only its text.
    static let schemaVersion: Int32 = 170
    static let minimumMigratableSchemaVersion: Int32 = 1

    /// The day Goals shipped — schema 120, build 114, 2026-09-19 — as midnight
    /// UTC. No build wrote a dated parentless companion record as a Goal before
    /// it, so the `< 120` step promotes only rows created earlier; a row created
    /// on or after this day is read by the new rule wherever it came from. The
    /// day rather than the build's exact minute, because Dev builds ran the
    /// new rule before the cut, and a Notebook mistaken for a Goal shows up due
    /// in a month, while a Goal mistaken for a Notebook loses its deadline.
    static let goalsShippedAt = Date(timeIntervalSince1970: 1_789_776_000)

    /// Migrates the store to `schemaVersion`, or creates it there. With
    /// `stoppingBeforeSchema154`, for a store whose open found no room for its
    /// rollback copy (§13.3 step 1), every step below 154 runs and the store is
    /// stamped 153: 154's tables, columns, indexes and rebuild, and every step
    /// after it, wait for a launch with room. A brand-new store has nothing to
    /// copy and is always created whole.
    func createSchema(stoppingBeforeSchema154: Bool = false) throws {
        var currentVersion: Int32 = 0
        try query("PRAGMA user_version") { stmt in
            currentVersion = sqlite3_column_int(stmt, 0)
        }
        guard currentVersion != Self.schemaVersion else {
            try reconcileSourceProjectionView()
            return
        }

        var hasApplicationTables = false
        try query("""
            SELECT EXISTS(
                SELECT 1
                FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%'
            )
        """) { stmt in
            hasApplicationTables = sqlite3_column_int(stmt, 0) != 0
        }
        guard currentVersion <= Self.schemaVersion else {
            throw KnowledgeStoreError.invalidData(
                "Knowledge database schema version \(currentVersion) is newer than this build supports (\(Self.schemaVersion)). Update ForeverLM before opening this database."
            )
        }
        // Held below 154 and already at 153: as current as this open makes it.
        if stoppingBeforeSchema154, currentVersion >= 153 {
            // Schema 164's rename is not one of the steps that wait: this
            // build's queries name the notebook tables, and the rename is a
            // few catalog writes that need no rollback copy.
            if try holdsRetiredProjectStorageNames() {
                try exec("BEGIN IMMEDIATE")
                do {
                    try renameProjectStorageForSchema164(dropsRetiredIndexes: false)
                    try exec("COMMIT")
                } catch {
                    try? exec("ROLLBACK")
                    throw error
                }
            }
            // Nor is schema 168's map of full-text rows, which this build's
            // full-text writes read: a store an older build held here has none.
            if try !holdsSourceFTSRowTables() {
                try exec("BEGIN IMMEDIATE")
                do {
                    try createSourceFTSRowTables()
                    try enqueueSourceFTSRowBackfill()
                    try exec("COMMIT")
                } catch {
                    try? exec("ROLLBACK")
                    throw error
                }
            }
            // Nor are schema 169's chapter pages, which this build's book
            // writes name.
            if try !holdsBookFileSchema() {
                try exec("BEGIN IMMEDIATE")
                do {
                    try addBookPageColumns()
                    try createBookFileMergeQueue()
                    try enqueueSplitBookMerge()
                    try exec("COMMIT")
                } catch {
                    try? exec("ROLLBACK")
                    throw error
                }
            }
            try reconcileSourceProjectionView()
            return
        }

        let isFreshDatabase = currentVersion == 0 && !hasApplicationTables
        let isMigration = !isFreshDatabase
        guard isFreshDatabase || currentVersion >= Self.minimumMigratableSchemaVersion else {
            throw KnowledgeStoreError.invalidData(
                "Knowledge database has an unversioned legacy schema. Open it with an earlier ForeverLM release before upgrading to this build."
            )
        }
        // 154 and every step after it, unless the store waits for room for its
        // rollback copy; then it is stamped 153, the last version without them.
        let laysDownSchema154 = isFreshDatabase || !stoppingBeforeSchema154
        let stampedVersion = laysDownSchema154 ? Self.schemaVersion : 153

        var migrationNeedsRollback = false
        var reactivatedCourseSourceCount = 0
        var republishedVideoProgressCount = 0
        var migratedPaperIngestionCount = 0
        var queuedPaperFigureMarkdownRepairCount = 0
        var restoredCourseMaterialCount = 0
        var migratedModelPreferenceCount = 0
        var migratedMeetingFolderImageCount = 0
        var adoptedDisplayPreferenceCount = 0
        var queuedPodcastDetruncationCount = 0
        var republishedDismissedArchiveCount = 0
        var queuedCanonicalCleanupCount = 0
        var queuedContentIntegrityAuditCount = 0
        var queuedArticleChromeRefilterCount = 0
        var republishedArchivedSourceCount = 0
        var removedArchivedGoalLinkCount = 0
        var repairedOrphanedAssetStagingCount = 0
        var queuedReviewGuideCount = 0
        var cancelledReviewGuideCount = 0
        var queuedPaperMetadataRepublishCount = 0
        var queuedTextlessSourceReingestionCount = 0
        var attributedRealtimeUsageCount = 0
        var queuedPaperFigureIndexCount = 0
        var queuedListenableContentCount = 0
        var retiredIneligibleListenableContentCount = 0
        var retiredSlackSourceCount = 0
        var requeuedPaperListenableContentCount = 0
        var requeuedStalePaperListenableContentCount = 0
        var queuedUnattestedListenableContentCount = 0
        var queuedTextReferenceRepairCount = 0
        var queuedSourcePDFAssetRepublishCount = 0
        var hiddenCourselessCourseSourceCount = 0
        var adoptedHiddenItemCount = 0
        var queuedPodcastTranscriptCleanupCount = 0
        var queuedZoomRecordingCount = 0
        var demotedPodcastPageTextCount = 0
        var foldedTitleMarkupCount = 0
        var clearedImplausibleAuthorCount = 0
        var queuedRegisteredTitleCheckCount = 0
        var queuedYouTubeTranscriptCheckCount = 0
        var queuedSoftHyphenRepairCount = 0
        var queuedSplitBookMergeCount = 0
        var queuedUnpackedEPUBBookCount = 0
        var stagedTeamApprovalRepublishCount = 0
        var releasedDeletedNotebookLinks = (deletedNotebooks: 0, republished: 0)
        var rebuiltPerMemberRows: [String: Int] = [:]
        if isMigration {
            try exec("BEGIN IMMEDIATE")
            migrationNeedsRollback = true
        }
        defer {
            if migrationNeedsRollback {
                try? exec("ROLLBACK")
            }
        }

        // Existing tables need their additive columns before the shared schema
        // installer creates indexes that may reference those columns. Tables
        // absent from an older store are created below with their full shape.
        if isMigration {
            // Schema 98: the review tables shed the retired method name. This
            // has to run before any statement below names the new tables,
            // otherwise CREATE TABLE IF NOT EXISTS would build empty
            // `review_*` tables beside the full `feynman_*` ones.
            if currentVersion < 98 {
                try renameReviewTablesForSchema98()
            }
            // Schema 164: the storage names that said project say notebook.
            // Before any statement below names the new tables or columns.
            if currentVersion < 164 {
                try renameProjectStorageForSchema164()
            }
            try addMissingColumnsForCurrentSchema(includingSchema154: laysDownSchema154)
        }

        // A rule for every CREATE TABLE below: no comma inside a `--` comment
        // that sits between a table's second-to-last column and its last one.
        // SQLite's `ALTER TABLE … DROP COLUMN` of the last column removes the
        // text from the nearest preceding comma to the column's end by raw
        // character scan, so a comma inside such a comment leaves the closing
        // paren commented out ("incomplete input", SQLite 3.51). The migration
        // fixtures drop columns exactly this way to rebuild released shapes;
        // `sources.team_id`, `global_artifacts.archived_at` and
        // `review_sessions.loaded_source_ids` each hit it on 2026-09-13.
        try exec("""
            CREATE TABLE IF NOT EXISTS sources (
                id TEXT PRIMARY KEY,
                date_added REAL NOT NULL,
                state TEXT NOT NULL DEFAULT 'queued',
                error_message TEXT,
                source_type TEXT NOT NULL DEFAULT 'article',
                existing_card_count INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'active',
                archived_at TEXT,
                public_url TEXT,
                is_consumed INTEGER,
                reading_position_page INTEGER,
                reading_position_locator TEXT,
                connector_label TEXT,
                read_at REAL,
                -- How much of a memory review this source gets: quick,
                -- standard or deep (schema 89). NULL means the default.
                review_depth TEXT,
                -- The team whose library this source is a copy in (schema 96).
                -- NULL is the learner's own library. A team copy has a
                -- team-scoped id so the same paper shared by two members is
                -- one team row and never collides with anyone's own copy.
                team_id TEXT,
                -- The schema-v2 logical id (154) and what every v2 join reads
                wire_id TEXT,
                wire_key TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_sources_team ON sources(team_id, status)")

        try exec("""
            CREATE TABLE IF NOT EXISTS source_content (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                content TEXT NOT NULL
            )
        """)

        // Listen consumes a second, source-hash-bound derivative instead of
        // preparing long documents after the user presses Play. Its queue is
        // local-only resumable work; the completed derivative syncs with Source.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_listenable_content (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                source_sha256 TEXT NOT NULL,
                content TEXT NOT NULL,
                generator_version INTEGER NOT NULL,
                preparation_signature TEXT,
                prepared_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS source_listenable_content_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                target_version INTEGER NOT NULL,
                source_sha256 TEXT,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_source_listenable_content_queue_order
            ON source_listenable_content_queue(enqueued_at, source_id)
        """)

        // The original extraction is retained separately from the canonical,
        // cleaned source_content derivative. Consumers never query this table;
        // it exists for auditability and versioned reprocessing only.
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_content_preparations (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                raw_content TEXT NOT NULL,
                raw_sha256 TEXT NOT NULL,
                clean_sha256 TEXT,
                cleaner_version INTEGER NOT NULL DEFAULT 0,
                prepared_at REAL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS article_content_preparations (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                raw_content TEXT NOT NULL,
                raw_sha256 TEXT NOT NULL,
                clean_sha256 TEXT,
                cleaner_version INTEGER NOT NULL DEFAULT 0,
                prepared_at REAL
            )
        """)

        // Original readable transcript plus version/hash proof for the
        // deletion-only podcast ad cleanup. This derivative metadata syncs with
        // Source; the queue below is local resumable work.
        try exec("""
            CREATE TABLE IF NOT EXISTS podcast_transcript_preparations (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                input_content TEXT NOT NULL,
                input_sha256 TEXT NOT NULL,
                clean_sha256 TEXT NOT NULL,
                cleaner_version INTEGER NOT NULL DEFAULT 0,
                prepared_at REAL
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS podcast_transcript_cleanup_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                target_version INTEGER NOT NULL,
                source_sha256 TEXT,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_podcast_transcript_cleanup_queue_order
            ON podcast_transcript_cleanup_queue(attempt_count, enqueued_at, source_id)
        """)

        // Local-only completeness audit (`PodcastTranscriptDetruncationService`).
        // Every podcast transcript the retired 50,000-character import cap may
        // have cut is measured once against its episode's TTML text, stored or
        // fetched once from Apple: where the transcript stops in that text says
        // whether the cap cut it (`PodcastTranscriptCompleteness`), and only a
        // cut one is rewritten. Bookkeeping is resumable derived state; a
        // restored transcript syncs as part of Source.
        try exec("""
            CREATE TABLE IF NOT EXISTS podcast_transcript_detruncation_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                -- When a failed attempt may be tried again (schema 167)
                retry_after REAL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_podcast_transcript_detruncation_queue_order
            ON podcast_transcript_detruncation_queue(attempt_count, enqueued_at, source_id)
        """)
        // What the audit found for each episode (schema 167): `hydrated` (made
        // from a whole extraction of the TTML), `complete`, `restored`,
        // `unplaced` or `no_transcript`, and the TTML it measured. An episode
        // with a row here is not audited again, so the ad pass's deletions
        // after a restore never send it back.
        try exec("""
            CREATE TABLE IF NOT EXISTS podcast_transcript_audits (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                ttml_sha256 TEXT,
                outcome TEXT NOT NULL,
                audited_at REAL NOT NULL
            )
        """)

        // Local-only durable work queue. The canonical result itself syncs as
        // part of Source; queue bookkeeping is resumable derived state and must
        // not become another cross-device identity surface.
        try exec("""
            CREATE TABLE IF NOT EXISTS canonical_content_cleanup_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                target_version INTEGER NOT NULL,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                -- Hash of the text the queued attempts were made against, so
                -- re-saving a source's metadata cannot revive an exhausted
                -- attempt budget while re-extracting its text does.
                source_sha256 TEXT
            )
        """)

        // Local-only, one-time (schema 134): preparations whose stored raw text
        // may be shorter than the hash beside it says. See
        // `auditCanonicalContentIntegrity`; the queue empties once per library.
        try exec("""
            CREATE TABLE IF NOT EXISTS canonical_content_integrity_audit_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL
            )
        """)

        // Local-only (schema 135): a bulk re-queue into a paid background
        // queue waiting for the learner's decision, and the sources it holds.
        // See `holdingBulkRequeue`. Each Mac drains its own queues, so each
        // Mac asks; nothing here syncs.
        try exec("""
            CREATE TABLE IF NOT EXISTS background_ai_bulk_jobs (
                id TEXT PRIMARY KEY,
                queue TEXT NOT NULL,
                reason TEXT NOT NULL,
                created_at REAL NOT NULL,
                -- pending | run_all | run_affected | skip | released
                status TEXT NOT NULL DEFAULT 'pending',
                decided_at REAL
            )
        """)
        try exec("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_background_ai_bulk_jobs_pending
            ON background_ai_bulk_jobs(queue) WHERE status = 'pending'
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS background_ai_bulk_job_sources (
                job_id TEXT NOT NULL REFERENCES background_ai_bulk_jobs(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                -- 1 or 0 when the change can say whether it reaches this
                -- source; NULL when it cannot.
                affected INTEGER,
                held_at REAL NOT NULL,
                PRIMARY KEY (job_id, source_id)
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_background_ai_bulk_job_sources_source
            ON background_ai_bulk_job_sources(source_id)
        """)

        // Local-only durable work queue for the one-time chrome refilter of
        // archives written before ArticleChromeFilter existed. The result is the
        // article's own reader document, which syncs as a Source asset; the
        // queue itself is resumable derived state and stays on this device.
        try exec("""
            CREATE TABLE IF NOT EXISTS article_chrome_refilter_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)

        // Per-member, so no foreign key to the source since schema 154
        // (`perMemberTablesWithoutContentKeys`).
        try createPerMemberTable(Self.sourceUnderstandingTable)

        // Identity, staleness, and the source relationship live here; the prose
        // itself is a markdown file the learner can open and edit.
        // body_sha256 is what the model last wrote, so a file that
        // no longer matches is a hand edit to read back rather than overwrite.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_review_guides (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                source_sha256 TEXT NOT NULL,
                guide TEXT NOT NULL,
                generator_version INTEGER NOT NULL,
                generated_at REAL NOT NULL
            )
        """)

        // Local-only resumable work. The resulting guide syncs in the encrypted
        // Source payload; attempts and errors are device-local derived state.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_review_guide_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                source_sha256 TEXT NOT NULL,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)

        // A paper's guided walkthrough (schema 122, walkthrough-design.md): the
        // steps the Reader follows beside the PDF, as one JSON document keyed by
        // the text they were written against. One row a paper; it syncs inside
        // the encrypted Source payload like the review guide above, and goes
        // with the source when the source is deleted.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_walkthroughs (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                source_sha256 TEXT NOT NULL,
                walkthrough_json TEXT NOT NULL,
                walkthrough_version INTEGER NOT NULL,
                generated_at REAL NOT NULL
            )
        """)

        // A saved animation's guided walkthrough (schema 124): the steps the chat
        // plays beside the animation, each pinning the page to one of its own
        // steps. One row an animation, keyed by the artifact; the fingerprint
        // is the animation's address, so a re-addressed animation reads as
        // stale. Syncs inside the encrypted Artifact payload and goes with
        // the artifact when it is deleted.
        try exec("""
            CREATE TABLE IF NOT EXISTS artifact_walkthroughs (
                artifact_id TEXT PRIMARY KEY REFERENCES global_artifacts(id) ON DELETE CASCADE,
                artifact_sha256 TEXT NOT NULL,
                walkthrough_json TEXT NOT NULL,
                walkthrough_version INTEGER NOT NULL,
                generated_at REAL NOT NULL
            )
        """)

        // The Ideas tab (schema 126): a thought the learner jotted down, and
        // the sources, chats, Docs, Goals and Notebooks it is linked to. The
        // links carry no foreign keys — a link is to a record's id whatever
        // table holds it, and CloudKit may deliver the Idea before the record
        // — so a row resolves each link against the library and a record
        // that is gone reads as no chip. Both travel in one `Idea` CloudKit
        // record (docs/ideas-design.md).
        try exec("""
            CREATE TABLE IF NOT EXISTS ideas (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                notes TEXT,
                status TEXT NOT NULL DEFAULT 'open',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ideas_status_created ON ideas(status, created_at DESC)")
        try exec("""
            CREATE TABLE IF NOT EXISTS idea_links (
                idea_id TEXT NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                target_id TEXT NOT NULL,
                added_at REAL NOT NULL,
                PRIMARY KEY (idea_id, kind, target_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_idea_links_target ON idea_links(kind, target_id)")

        // Sensemaking (schema 165, docs/sensemaking-design.md): what ForeverLM
        // wrote to help the learner see a topic, a source and a card at more
        // than one level of abstraction. All three are derived, rewritable and
        // local to this Mac; none is a record of the learner's.
        // An Atlas: a topic laid out as concepts, its whole body one JSON
        // payload (`Atlas`), read and written whole.
        try exec("""
            CREATE TABLE IF NOT EXISTS atlases (
                id TEXT PRIMARY KEY,
                topic TEXT NOT NULL,
                notebook_id TEXT,
                scope_json TEXT NOT NULL DEFAULT '{}',
                payload_json TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_atlases_updated ON atlases(updated_at DESC)")
        // A source's reading levels for the Reader, written from the text
        // whose SHA-256 is `content_sha256`; a change of text makes them stale.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_levels (
                source_id TEXT PRIMARY KEY,
                content_sha256 TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                model TEXT,
                created_at REAL NOT NULL
            )
        """)
        // A source card's written faces on the Canvas: far (a few words), mid
        // (a sentence) and near (two or three lines), from the card's text
        // whose fingerprint is `fingerprint`.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_faces (
                source_id TEXT PRIMARY KEY,
                fingerprint TEXT NOT NULL,
                far TEXT NOT NULL,
                mid TEXT NOT NULL,
                near_json TEXT NOT NULL DEFAULT '[]',
                model TEXT,
                created_at REAL NOT NULL
            )
        """)

        // Directions (schema 147): what a search proposed toward a Goal,
        // Notebook or Idea, and the learner's answer. The home carries no
        // foreign key — it is a `learning_goals` or `ideas` id, and CloudKit
        // may deliver the Direction before its home — so a Direction whose
        // home is gone is shown nowhere; deleting a Goal or an Idea deletes
        // its Directions in the same transaction. Evidence is a JSON array in
        // the row: it is only ever read and written with its Direction. One
        // `ResearchDirection` CloudKit record per row
        // (docs/directions-design.md).
        try exec("""
            CREATE TABLE IF NOT EXISTS research_directions (
                id TEXT PRIMARY KEY,
                home_kind TEXT NOT NULL,
                home_id TEXT NOT NULL,
                title TEXT NOT NULL,
                rationale TEXT NOT NULL DEFAULT '',
                angle TEXT NOT NULL DEFAULT 'other',
                evidence_json TEXT NOT NULL DEFAULT '[]',
                objection TEXT,
                next_step TEXT,
                status TEXT NOT NULL DEFAULT 'proposed',
                verdict_reason TEXT,
                chat_session_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                decided_at REAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_research_directions_home ON research_directions(home_id, status)")

        // The learner's chat skills (schema 136): a `/` name, the one
        // description the chat reads to decide when a skill applies, and the
        // instructions it reads when it does. The name is not UNIQUE: two
        // Macs can each write one of the same name, and an inbound record
        // must not fail on the other's row; local writes refuse a taken name
        // and a lookup takes the newest edit. One `Skill` CloudKit record a
        // row, private zone only.
        try exec("""
            CREATE TABLE IF NOT EXISTS skills (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT NOT NULL,
                instructions TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_skills_name ON skills(name, updated_at DESC)")

        // A walk's progress (schema 133): the card the learner is on, the
        // steps dealt, the questions' outcomes and the chat questions went
        // to, one row a walk keyed by its source or animation. Per learner,
        // never in a team; one `WalkthroughProgress` CloudKit record a row.
        try exec("""
            CREATE TABLE IF NOT EXISTS walkthrough_progress (
                subject_id TEXT PRIMARY KEY,
                progress_json TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        // The day close (schema 127): what this device has already folded
        // into understanding documents, so the pass that runs at shutdown, at
        // the evening hour and again before the morning's review can each
        // pick up only what is new. `watermark` is the instant everything
        // before it was consolidated; a chat row records the last turn its
        // consolidation read, because a chat may go on the next day. Local
        // derived state: the documents it produces sync as files, the
        // summaries it writes ride the ReviewSession record, and another Mac
        // running the same pass rewrites rather than duplicates.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_day_close_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                watermark REAL NOT NULL,
                last_run_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS chat_consolidations (
                session_id TEXT PRIMARY KEY REFERENCES review_sessions(id) ON DELETE CASCADE,
                through_sequence INTEGER NOT NULL,
                consolidated_at REAL NOT NULL,
                source_count INTEGER NOT NULL DEFAULT 0
            )
        """)

        // Regenerable visual index: which page carries which labelled figure, and
        // what a vision model made of it. Every column is portable and projects
        // through the encrypted Source sync payload.
        //
        // There is no image column. Until schema 75 each figure also owned a
        // rendered page JPEG on disk, which was pure duplication — the pixels
        // were already in the PDF a page index away — and cost this library
        // 4.9 GB across 9,030 files. Clients render the page on demand instead.
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_figures (
                figure_id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                figure_label TEXT NOT NULL,
                page_index INTEGER NOT NULL CHECK(page_index >= 0),
                caption TEXT NOT NULL,
                analysis_json TEXT,
                UNIQUE(source_id, figure_label, page_index)
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_figure_index_state (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                pdf_path TEXT NOT NULL,
                index_version INTEGER NOT NULL,
                page_count INTEGER NOT NULL,
                indexed_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_figure_index_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                target_version INTEGER NOT NULL,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                pdf_path TEXT NOT NULL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_paper_figures_source_page
            ON paper_figures(source_id, page_index)
        """)

        // Canonical text written before schema 75 ends in a `## Figures` block of
        // `![caption](file:///…)` links to rendered page JPEGs. Those paths are
        // absolute, so they named whichever Mac did the extraction and were dead
        // everywhere else — including in the model context and embeddings that
        // read this text. Stripping them is proportional to the library, so the
        // migration only stages ids here and a bounded post-launch drain does the
        // rewriting.
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_figure_markdown_repair_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_paper_figure_markdown_repair_order
            ON paper_figure_markdown_repair_queue(attempt_count, enqueued_at)
        """)

        // One-time removal of the rendered page JPEGs that schema 75 stopped
        // producing. Deliberately local and unsynced: the files are this Mac's,
        // so each device has to run its own sweep — a synced "done" flag would
        // let the second Mac skip a library it still holds gigabytes of.
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_figure_image_sweep_state (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                enqueued_at REAL NOT NULL,
                completed_at REAL,
                removed_directory_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)

        // User-authored highlights and the notes written on them are durable
        // source annotations. The table predates the reader UI that writes it,
        // so a database upgraded by one of those builds is already the right
        // shape apart from the anchor columns the column migration below adds.
        //
        // `page_index`/`quads_json` are the PDF fast path: PDFKit paints those
        // quads without re-reading the document. Every reader — web, EPUB,
        // transcript, PDF — additionally stores the portable text-quote anchor
        // (`anchor_prefix`/`anchor_suffix`/`anchor_offset`), which is what
        // survives a re-fetch or a reflow. Non-PDF rows park at page 0 with no
        // quads. A highlight is the learner's own, so since schema 154 it has
        // no foreign key to its source (`perMemberTablesWithoutContentKeys`).
        try createPerMemberTable(Self.sourceHighlightsTable)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_paper_figure_index_queue_order
            ON paper_figure_index_queue(attempt_count, enqueued_at)
        """)

        try exec("CREATE INDEX IF NOT EXISTS idx_sources_status ON sources(status)")

        try exec("""
            CREATE TABLE IF NOT EXISTS chat_context (
                key TEXT PRIMARY KEY,
                source_ids TEXT NOT NULL DEFAULT '[]',
                last_updated REAL NOT NULL
            )
        """)

        // Account-level user preferences (see SyncedPreferenceKeys for which keys
        // qualify). One row — and so one CloudKit record — per preference key,
        // deliberately not a single blob row like chat_context above: conflict
        // resolution is row-level last-write-wins over an opaque payload, so a
        // shared row would mean one Mac changing the theme and the other changing
        // the font size silently loses one of the two edits.
        //
        // `value` holds an XML property list, not JSON. UserDefaults distinguishes
        // Bool from Int (`object(forKey:) as? Bool` returns nil for a plain
        // NSNumber), and JSON does not — round-tripping a Bool through JSON would
        // silently flip several settings to their defaults.
        try exec("""
            CREATE TABLE IF NOT EXISTS user_preferences (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
        """)


        try exec("""
            CREATE TABLE IF NOT EXISTS embeddings (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                model TEXT NOT NULL DEFAULT 'default',
                vector BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (entity_type, entity_id, model)
            )
        """)

        // Full-text index over source text, ranked by BM25. This is the half of search
        // the embedding cannot do: a pooled 512-dim vector dilutes a rare token like a
        // gene symbol until it carries no signal (swapping GDF15 for GFRAL moves the
        // vector 0.6%), so exact/rare terms — gene names, acronyms, proper nouns — are
        // retrieved lexically and fused with the semantic hits. Inverse document
        // frequency does the opposite of pooling: the rarer the term, the stronger it
        // scores, which is exactly the behaviour an exact match needs.
        //
        // Local derived data, like `embeddings`: never synced to CloudKit, rebuilt on
        // each device by `SourceEmbeddingIndexer`. That is what lets the indexer feed it
        // text extracted on the fly from a paper's PDF without writing that text back
        // into `source_content` (which would re-push every paper as a new CloudKit asset).
        //
        // Tokenizer: `unicode61` keeps "GDF15" as a single token. Porter stemming is
        // deliberately NOT used — it mangles symbol-like tokens. `remove_diacritics 2`
        // folds accents so "Müller" matches "Muller".
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS source_fts USING fts5(
                source_id UNINDEXED,
                title,
                author,
                body,
                tokenize = "unicode61 remove_diacritics 2"
            )
        """)

        // Which version of the index-time analysis wrote each full-text row.
        //
        // Separate from `source_index_state` because the two go stale for different
        // reasons and cost different amounts to repair. That table tracks the *text* a
        // source was indexed from, and clearing it re-embeds — model time, and money.
        // This one tracks how that text was analyzed, and a raised
        // `SourceSearchEngine.indexAnalyzerVersion` needs nothing but the full-text rows
        // rewritten. Keeping them apart is what lets the analyzer improve without
        // re-embedding the library.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_fts_state (
                source_id TEXT PRIMARY KEY,
                analyzer_version INTEGER NOT NULL,
                written_at REAL NOT NULL
            )
        """)

        // Where each source's full-text row is, by rowid (schema 168).
        try createSourceFTSRowTables()

        // The PDF books still split into chapter files (schema 169).
        try createBookFileMergeQueue()

        // What the indexer has already done, and for which version of a source's text.
        //
        // "Has an embedding" is not a sufficient completion test: a source indexed while
        // it was still title-only (a podcast before its transcript arrives, a paper before
        // its PDF is attached) would look done forever and never pick up its real content.
        // So the indexer records a fingerprint of the text it actually indexed — the stored
        // content length and the local file path — and re-indexes whenever that changes.
        // The model id is part of the key, so switching embedding models retires every row.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_index_state (
                source_id TEXT NOT NULL,
                model TEXT NOT NULL,
                content_length INTEGER NOT NULL,
                file_path TEXT NOT NULL DEFAULT '',
                indexed_at REAL NOT NULL,
                PRIMARY KEY (source_id, model)
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS ai_usage_events (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                operation TEXT NOT NULL,
                task TEXT, -- feature that made the call (AIUsageEvent.task); NULL on rows from before the column
                session_id TEXT,
                activity_id TEXT,
                subject_id TEXT,
                subject_type TEXT,
                subject_title TEXT,
                created_at REAL NOT NULL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cached_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER,
                reasoning_tokens INTEGER,
                audio_input_tokens INTEGER,
                audio_output_tokens INTEGER,
                image_count INTEGER,
                total_tokens INTEGER,
                character_count INTEGER,
                duration_seconds REAL,
                provider_reported_cost REAL,
                estimated_cost REAL,
                currency TEXT,
                raw_usage_json TEXT,
                client_platform TEXT,
                server_ledger_id INTEGER,
                server_request_id TEXT,
                latency_ms INTEGER,
                -- 1 when the learner's own router key paid for this call
                -- and it went straight to that router. Such a call never
                -- reached the proxy so no server row will stand in for it
                -- and it stays visible on its own merit.
                own_key INTEGER NOT NULL DEFAULT 0
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ai_usage_events_created ON ai_usage_events(created_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_ai_usage_events_model ON ai_usage_events(provider, model)")
        // Chat/review session attribution (AIUsageAttribution). Partial index:
        // background work leaves session_id NULL, so only attributed rows —
        // a small fraction of the ledger — pay for the per-session cost sum.
        try exec("CREATE INDEX IF NOT EXISTS idx_ai_usage_events_session ON ai_usage_events(session_id) WHERE session_id IS NOT NULL")
        try exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_usage_events_server_ledger ON ai_usage_events(server_ledger_id) WHERE server_ledger_id IS NOT NULL")

        // Exact one-shot task results, keyed by a digest of model + complete
        // request. Prompts are never persisted. Reads enforce the TTL, so a
        // repeated background event reuses completed work without inference.
        try exec("""
            CREATE TABLE IF NOT EXISTS ai_response_cache (
                request_key TEXT PRIMARY KEY,
                response TEXT NOT NULL,
                created_at REAL NOT NULL
            )
        """)

        // Local cursor for the authoritative managed-proxy ledger mirror. It is
        // local-only accounting state, not user content and not CloudKit synced.
        try exec("""
            CREATE TABLE IF NOT EXISTS managed_ai_usage_sync_state (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                last_ledger_id INTEGER NOT NULL DEFAULT 0
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS dismissed_sources (
                url TEXT PRIMARY KEY,
                title TEXT,
                dismissed_at REAL NOT NULL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS hidden_podcast_shows (
                show_name TEXT PRIMARY KEY,
                hidden_at REAL NOT NULL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS hidden_youtube_channels (
                channel_name TEXT PRIMARY KEY COLLATE NOCASE,
                hidden_at REAL NOT NULL
            )
        """)

        // The hidden and visible marks are the learner's own; since schema 154
        // none has a foreign key to its source (`perMemberTablesWithoutContentKeys`).
        try createPerMemberTable(Self.hiddenSourcesTable)

        try exec("""
            CREATE TABLE IF NOT EXISTS pending_hidden_sources (
                source_id TEXT PRIMARY KEY,
                hidden_at REAL NOT NULL
            )
        """)

        try createPerMemberTable(Self.hiddenPodcastEpisodesTable)

        // The docs, sites and chats the learner hid (schema 114), synced as
        // HiddenArtifact and HiddenReviewSession records in the private zone.
        // No foreign key on purpose: a hide can arrive from CloudKit before
        // the record it is about, and the row waits for it; the record's own
        // delete removes the row.
        try exec("""
            CREATE TABLE IF NOT EXISTS hidden_artifacts (
                artifact_id TEXT PRIMARY KEY,
                hidden_at REAL NOT NULL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS hidden_review_sessions (
                session_id TEXT PRIMARY KEY,
                hidden_at REAL NOT NULL
            )
        """)

        try createPerMemberTable(Self.visiblePodcastEpisodeOverridesTable)
        try createPerMemberTable(Self.visibleYouTubeVideoOverridesTable)

        try exec("""
            CREATE TABLE IF NOT EXISTS review_sessions (
                id TEXT PRIMARY KEY,
                topic TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                status TEXT NOT NULL DEFAULT 'active',
                overall_score REAL,
                summary TEXT,
                source_ids TEXT NOT NULL DEFAULT '[]',
                card_ids TEXT NOT NULL DEFAULT '[]',
                exchange_count INTEGER NOT NULL DEFAULT 0,
                model_provider TEXT,
                model_id TEXT,
                -- Links the session back to the Learning Companion goal it belongs to.
                goal_id TEXT,
                -- chat / review / memory (schema 89). NULL on older rows, whose
                -- kind is read from the id prefix instead.
                kind TEXT,
                -- A memory review's stable tutor briefing: the day's plan, its
                -- ideas and material. Syncs inside the session record so a
                -- prepared chat opens the same review on either device.
                briefing TEXT,
                -- The team this chat was shared into as a read-only transcript
                -- snapshot (schema 96). NULL is a live chat of the learner's own.
                team_id TEXT,
                -- Which of source_ids the model had actually read when the chat
                -- was last open (schema 104) as a JSON list so a reopened chat
                -- holds what it held instead of coming back catalog-only. Local
                -- to this Mac and never synced: it describes this process's
                -- prompt rather than the conversation. NULL is a chat recorded
                -- before the column; its loaded set is read off the transcript's
                -- citations on resume. '[]' is a chat that had read nothing.
                -- Schema 112's hidden_at column is retired (114): a hidden
                -- chat is a hidden_review_sessions row and a store that has
                -- the column keeps it unread and unwritten.
                loaded_source_ids TEXT,
                -- The reasoning effort and output speed the chat's last reply
                -- was asked for (schema 149) beside the model it names so a
                -- reopened chat goes on with the whole route it was held in.
                -- NULL is the model's own default effort and standard speed
                -- and every chat recorded before the columns.
                model_effort TEXT,
                model_speed TEXT,
                -- The schema-v2 logical id (154) and what every v2 join reads
                wire_id TEXT,
                wire_key TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL,
                -- The Chat record's kind; whether an import's later appends
                -- mark sources reviewed; and its context mode (158). NULL until
                -- the generation-2 activation derives them and then written by
                -- every generation-2 creation site. (No commas in comments
                -- before a dropped column: SQLite 3.51 and older mishandle them.)
                chat_kind TEXT,
                marks_reviewed INTEGER,
                context_mode TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_review_sessions_team ON review_sessions(team_id)")

        try exec("""
            CREATE TABLE IF NOT EXISTS review_exchanges (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES review_sessions(id) ON DELETE CASCADE,
                sequence_number INTEGER NOT NULL,
                question TEXT NOT NULL,
                user_answer TEXT,
                evaluation TEXT,
                score REAL,
                source_refs TEXT DEFAULT '[]',
                knowledge_note TEXT,
                answered_at REAL,
                context_content TEXT,
                -- Memory review grading (schema 89): which ideas came back in
                -- this answer, whether the question was fit to grade, the
                -- operation it asked for, and the learner's steer afterwards.
                idea_coverage TEXT,
                question_verdict TEXT,
                operation TEXT,
                steer TEXT,
                -- The learner's thumb on one of this exchange's tutor turns
                -- (schema 93): liked/disliked, their reason, which field they
                -- rated, and the unit's clock for sync.
                rating TEXT,
                rating_reason TEXT,
                rating_field TEXT,
                rated_at REAL,
                -- The Exchange record's passage anchor and the sources its
                -- reply cited (158), JSON, as another device sent them.
                anchor_json TEXT,
                cited_source_ids TEXT,
                UNIQUE(session_id, sequence_number)
            )
        """)

        // Junction table: many-to-many between review sessions and sources
        try exec("""
            CREATE TABLE IF NOT EXISTS review_session_sources (
                session_id TEXT NOT NULL REFERENCES review_sessions(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                PRIMARY KEY (session_id, source_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_fss_source ON review_session_sources(source_id)")

        // The rolling summary of a chat's older turns (schema 88). Before it
        // was stored, every reopen of a long chat rebuilt the summary from
        // scratch in one oversized model call. Local-only and regenerable —
        // the exchanges it summarises are what syncs — so it is never
        // published to CloudKit and carries no sync metadata. The cursor is
        // an (exchange, field) pair, not a message index; see
        // `ReviewSessionHistoryDigest`.
        try exec("""
            CREATE TABLE IF NOT EXISTS review_session_history_digests (
                session_id TEXT PRIMARY KEY REFERENCES review_sessions(id) ON DELETE CASCADE,
                digest TEXT NOT NULL,
                through_exchange_id TEXT NOT NULL,
                through_field TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        // The ideas a consumed source asks to be remembered (schema 89): the
        // unit of memory review. Extracted once per source text, synced as
        // their own `SourceIdea` record, retired rather than deleted when the
        // text changes. source_id has no FK for the reason memory_item_sources
        // gives: CloudKit may deliver an idea before its Source, and the id is
        // remapped by portable identity on arrival.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_ideas (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                statement TEXT NOT NULL,
                recall_note TEXT NOT NULL,
                anchors_json TEXT NOT NULL DEFAULT '[]',
                wanted INTEGER NOT NULL DEFAULT 0,
                origin_session_id TEXT,
                content_hash TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                sort_index INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_source_ideas_source
            ON source_ideas(source_id, status, sort_index)
        """)

        // Time spent on the day's memory review (schema 91): one row per device
        // per day, summed by `MemoryReviewProgress` into today's progress and
        // the streak. A device only writes its own row, so two devices working
        // the same day add up instead of racing. Synced as `MemoryReviewActivity`.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_review_activity (
                id TEXT PRIMARY KEY,
                day TEXT NOT NULL,
                device_id TEXT NOT NULL,
                active_seconds REAL NOT NULL DEFAULT 0,
                goal_seconds REAL NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_memory_review_activity_day
            ON memory_review_activity(day)
        """)

        // AI-native memory targets. These are source-grounded concepts rather
        // than static flashcards: the tutor generates a fresh prompt from the
        // target, rubric, learner context, and one or more anchors at review time.
        // goal_id intentionally has no FK because CloudKit may deliver the item
        // before its Notebook record.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_items (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                target TEXT NOT NULL,
                rubric_json TEXT NOT NULL,
                learner_context TEXT,
                goal_id TEXT,
                status TEXT NOT NULL DEFAULT 'active',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                -- The idea this target is a weak spot of (schema 89). NULL for
                -- the items the external assistant created before ideas existed.
                idea_id TEXT
            )
        """)

        // Anchors travel inside their parent MemoryItem CloudKit record. source_id
        // has no FK because source IDs are remapped by portable identity on arrival
        // and the Source record may be delivered in a later batch.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_item_sources (
                id TEXT PRIMARY KEY,
                memory_item_id TEXT NOT NULL REFERENCES memory_items(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL,
                locator_json TEXT,
                excerpt TEXT NOT NULL,
                source_sha256 TEXT NOT NULL,
                source_url TEXT,
                source_normalized_url TEXT,
                source_doi TEXT,
                source_published_doi TEXT,
                sort_index INTEGER NOT NULL
            )
        """)

        // Attempts are immutable top-level sync events. Deliberately omit foreign
        // keys to the item/session/exchange: CloudKit does not guarantee delivery
        // order, and preserving an orphaned attempt is safer than dropping history.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_attempts (
                id TEXT PRIMARY KEY,
                memory_item_id TEXT NOT NULL,
                session_id TEXT,
                exchange_id TEXT,
                attempt_type TEXT NOT NULL,
                prompt TEXT NOT NULL,
                learner_answer TEXT NOT NULL,
                feedback TEXT,
                score REAL CHECK (score IS NULL OR (score >= 0 AND score <= 1)),
                schedule_rating TEXT,
                grade_state TEXT NOT NULL,
                grading_error TEXT,
                evidence_json TEXT,
                attempted_at REAL NOT NULL,
                model_provider TEXT,
                model_id TEXT,
                model_metadata_json TEXT,
                parent_curriculum_fingerprint TEXT,
                UNIQUE(session_id, exchange_id)
            )
        """)

        // Local-only, regenerable projection. CloudKit syncs immutable attempts;
        // each device applies the portable scheduler to rebuild this row.
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_schedules (
                memory_item_id TEXT PRIMARY KEY REFERENCES memory_items(id) ON DELETE CASCADE,
                due_at REAL NOT NULL,
                last_attempt_at REAL,
                last_success_at REAL,
                stability REAL NOT NULL DEFAULT 0,
                difficulty REAL NOT NULL DEFAULT 0.5,
                repetition_count INTEGER NOT NULL DEFAULT 0,
                lapse_count INTEGER NOT NULL DEFAULT 0,
                algorithm_version INTEGER NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_items_goal_status ON memory_items(goal_id, status, updated_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_item_sources_item ON memory_item_sources(memory_item_id, sort_index)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_item_sources_source ON memory_item_sources(source_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_item_sources_identity_url ON memory_item_sources(source_normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_item_sources_identity_doi ON memory_item_sources(source_doi)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_item_sources_identity_published_doi ON memory_item_sources(source_published_doi)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_attempts_item_date ON memory_attempts(memory_item_id, attempted_at, id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_attempts_session ON memory_attempts(session_id, exchange_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_memory_schedules_due ON memory_schedules(due_at, memory_item_id)")

        try exec("""
            CREATE TABLE IF NOT EXISTS learning_goals (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                start_at REAL NOT NULL,
                end_at REAL NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                -- Learning Companion fields (proactive daily-quiz goals). Plain
                -- Schedule goals leave them NULL; companion goals are tagged
                -- kind = 'companion'.
                kind TEXT,
                description TEXT,
                topic TEXT,
                discovery_enabled INTEGER,
                daily_target INTEGER,
                last_quiz_date TEXT,
                last_discovery_at REAL,
                -- A Notebook's short description: display copy for the gallery
                -- card and overview. description above is the standing chat
                -- Instructions, so the two never share a column. Carried in the
                -- learningGoal CloudKit payload.
                summary TEXT,
                -- Notebook synthesis notes (markdown): the Internal Review
                -- accumulates what's been learned here. Carried in the learningGoal
                -- CloudKit payload.
                notes TEXT,
                -- When set, this companion goal is a timebound Goal nested inside the
                -- named Notebook (another companion goal). NULL = a top-level Notebook.
                -- Carried in the learningGoal CloudKit payload.
                parent_notebook_id TEXT,
                -- The Notebook's defining research questions as a JSON string array, in
                -- priority order. NULL = never set (and syncs as no-opinion); an
                -- explicitly cleared list is stored as "[]". Carried in the
                -- learningGoal CloudKit payload.
                research_questions TEXT,
                -- The GitHub repository a Notebook is about, as owner/repo
                -- (schema 102). Only the name lives here: chats read the
                -- repository live through the GitHub tools and nothing from it
                -- is stored. NULL = never set (syncs as no-opinion); an explicit
                -- unlink is stored as ''. Carried in the learningGoal CloudKit
                -- payload.
                repository TEXT,
                -- The artifact a Goal is for (schema 121): the id of the Doc,
                -- Site or animation that is its deliverable. Only the id lives
                -- here; the row resolves the record from the library. NULL =
                -- never set (syncs as no-opinion); an explicit unlink is stored
                -- as ''. Carried in the learningGoal CloudKit payload.
                artifact_id TEXT,
                -- Where the learner put a Goal in the Goals tab (schema 125):
                -- its index in the order last made by hand. NULL = never
                -- placed, which reads by deadline after the placed rows and
                -- syncs as no-opinion. Carried in the learningGoal CloudKit
                -- payload.
                sort_order INTEGER,
                -- The team whose library this Notebook belongs to (schema 96);
                -- NULL is My Library. Routes the record to the team's zone.
                team_id TEXT,
                -- Schema v2 (154): NULL until the generation-2 activation
                -- derives them (a Notebook or a Goal and its redirects)
                entity_kind TEXT,
                merged_into TEXT,
                fold_kind TEXT,
                moving_to TEXT,
                moved_to TEXT,
                -- The schema-v2 logical id and what every v2 join reads
                wire_id TEXT,
                wire_key TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goals_team ON learning_goals(team_id, status)")

        try exec("""
            CREATE TABLE IF NOT EXISTS learning_goal_items (
                id TEXT PRIMARY KEY,
                goal_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL,
                added_at REAL NOT NULL,
                completed_at REAL,
                origin TEXT,
                review_state TEXT,
                relevance REAL,
                last_quizzed_at REAL,
                quiz_count INTEGER,
                last_score REAL,
                -- User-defined study order within a Notebook pool. NULL = unsequenced
                -- (sorts after sequenced items, by added_at). Kept separate from
                -- added_at, which the retired per-goal planner stamped as a planned date.
                sequence REAL,
                order_key TEXT,
                UNIQUE(goal_id, source_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goals_status ON learning_goals(status)")
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goal_items_goal ON learning_goal_items(goal_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goal_items_source ON learning_goal_items(source_id)")

        // Older experimental builds briefly used the same table name with an
        // incompatible shape. This is derived state, so a pre-v12 migration can
        // safely discard it and rebuild from the workspace rather than guessing
        // at identity or attempting an unsafe structural repair.
        if isMigration, currentVersion < 12 {
            try exec("DROP TABLE IF EXISTS notebook_files")
        }

        // A local, regenerable projection over the iCloud Drive Notebook workspace.
        // The actual file plus its user-owned relative path is the cross-device
        // source of truth; scanning `Projects/<notebook id>/` rebuilds these rows.
        // `role` remains only for v12 schema compatibility and carries "file".
        // Since schema 154 no foreign key ties a row to its notebook, and
        // `notebook_id` may be NULL: generation 2 leaves a deleted notebook's
        // files unfiled (`releaseFilesOfDeletedNotebook`).
        try createPerMemberTable(Self.notebookFilesTable)

        // Canonical Markdown artifacts are global documents. Keep the `global_`
        // prefix: released databases can contain an older, unrelated `artifacts`
        // table (`type`, `content`, `generated_at`). Reusing that name made the
        // first v61 migration fail closed before the library could open.
        // `home_notebook_id` is only an organizational label and Notebook links are
        // many-to-many; neither references learning_goals because CloudKit may
        // deliver an artifact before the linked Notebook.
        try exec("""
            CREATE TABLE IF NOT EXISTS global_artifacts (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                home_notebook_id TEXT,
                is_draft INTEGER NOT NULL DEFAULT 0,
                linked_url TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                -- The team whose library this Doc belongs to (schema 96).
                team_id TEXT,
                -- When the learner archived it; NULL while current (schema 106).
                -- Schema 111's hidden_at column is retired (114): a hidden doc
                -- is a hidden_artifacts row and a store that has the column
                -- keeps it unread and unwritten.
                archived_at REAL,
                -- What the record is when its link would misname it: 'animation'
                -- (schema 117); NULL for a Markdown doc and every linked page.
                kind TEXT,
                -- The schema-v2 logical id (154) and what every v2 join reads
                wire_id TEXT,
                wire_key TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL,
                -- The body's FileRef (159) written by the generation-2 body
                -- publisher once its satellites are acknowledged; NULL under
                -- generation 1 (no commas in comments before a dropped column)
                body_ref TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_global_artifacts_team ON global_artifacts(team_id, updated_at DESC)")
        try exec("CREATE INDEX IF NOT EXISTS idx_global_artifacts_updated ON global_artifacts(updated_at DESC, id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_global_artifacts_home_notebook ON global_artifacts(home_notebook_id, updated_at DESC)")
        try exec("""
            CREATE TABLE IF NOT EXISTS global_artifact_notebook_links (
                artifact_id TEXT NOT NULL REFERENCES global_artifacts(id) ON DELETE CASCADE,
                notebook_id TEXT NOT NULL,
                linked_at REAL NOT NULL,
                PRIMARY KEY (artifact_id, notebook_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_global_artifact_notebook_links_notebook ON global_artifact_notebook_links(notebook_id, artifact_id)")
        // The sources a record is about (schema 117): an animation's paper,
        // one row a link. No foreign key on the source — a source can arrive
        // from CloudKit after the record that names it, or be deleted before
        // it — so a dangling id is simply one no source answers to.
        try exec("""
            CREATE TABLE IF NOT EXISTS global_artifact_source_links (
                artifact_id TEXT NOT NULL REFERENCES global_artifacts(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL,
                linked_at REAL NOT NULL,
                PRIMARY KEY (artifact_id, source_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_global_artifact_source_links_source ON global_artifact_source_links(source_id, artifact_id)")

        // Threaded comments are independent child records so sharing an
        // Artifact hierarchy includes discussion without modifying Markdown.
        // Anchors are revision-bound; a detached quote remains reviewable after
        // edits instead of being silently moved to unrelated prose.
        try exec("""
            CREATE TABLE IF NOT EXISTS artifact_comments (
                id TEXT PRIMARY KEY,
                artifact_id TEXT NOT NULL REFERENCES global_artifacts(id) ON DELETE CASCADE,
                parent_comment_id TEXT REFERENCES artifact_comments(id) ON DELETE CASCADE,
                author_record_name TEXT NOT NULL,
                author_display_name TEXT NOT NULL,
                body TEXT NOT NULL,
                anchor_revision TEXT NOT NULL,
                anchor_start INTEGER NOT NULL,
                anchor_end INTEGER NOT NULL,
                anchor_quote TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                resolved_at REAL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_artifact_comments_artifact
            ON artifact_comments(artifact_id, created_at, id)
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_artifact_comments_parent
            ON artifact_comments(parent_comment_id, created_at, id)
        """)

        // Where a chat came from. A conversation opened on a highlighted passage
        // is about that passage, and nothing else recorded that: the session kept
        // the passage's sources and the doc's Notebook, so a chat could be traced
        // to what it stood on but never to the sentence that prompted it.
        //
        // Anchors are revision-bound and never re-anchored, exactly like
        // artifact_comments above. Offsets into a doc that has since been
        // rewritten cannot be trusted, so the quote is the durable identity and
        // the offsets are a hint the reader uses only while the revision still
        // matches.
        //
        // artifact_id deliberately carries no foreign key, for the same reason
        // learning_goal_items.goal_id does not: CloudKit can deliver the chat
        // before the doc it points at, and a link that refuses to land is worse
        // than one that waits for its doc to arrive. `deleteArtifactRecord`
        // sweeps the rows a deleted doc leaves behind.
        //
        // UNIQUE keeps asking twice about one passage from stacking rows; a later
        // revision genuinely is a different anchor, and gets its own.
        try exec("""
            CREATE TABLE IF NOT EXISTS artifact_chat_links (
                id TEXT PRIMARY KEY,
                artifact_id TEXT NOT NULL,
                session_id TEXT NOT NULL REFERENCES review_sessions(id) ON DELETE CASCADE,
                anchor_revision TEXT NOT NULL,
                anchor_start INTEGER NOT NULL,
                anchor_end INTEGER NOT NULL,
                anchor_quote TEXT NOT NULL,
                section_title TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                UNIQUE(session_id, artifact_id, anchor_revision, anchor_start, anchor_end)
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_artifact_chat_links_artifact
            ON artifact_chat_links(artifact_id, created_at, id)
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_artifact_chat_links_session
            ON artifact_chat_links(session_id)
        """)

        // A row marks a received shared hierarchy and is the routing authority:
        // participant edits must return to the owner's shared zone and must
        // never be published as a lookalike in the participant's private zone.
        try exec("""
            CREATE TABLE IF NOT EXISTS artifact_collaboration (
                artifact_id TEXT PRIMARY KEY REFERENCES global_artifacts(id) ON DELETE CASCADE,
                database_scope TEXT NOT NULL,
                zone_name TEXT NOT NULL,
                owner_name TEXT NOT NULL,
                share_record_name TEXT,
                permission TEXT NOT NULL,
                is_owner INTEGER NOT NULL DEFAULT 0,
                last_body_revision TEXT,
                updated_at REAL NOT NULL
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_artifact_collaboration_zone
            ON artifact_collaboration(database_scope, owner_name, zone_name)
        """)

        // v61 briefly shipped the global feature under the colliding legacy
        // names. A database on which that migration succeeded has the new column
        // shape, so copy it forward without touching a genuine legacy table.
        if isMigration, currentVersion == 61 {
            let v61ArtifactColumns = try tableColumnNames("artifacts")
            // The pre-v61 tables keep the names they were written with.
            if ["id", "title", "home_project_id", "created_at", "updated_at"]
                .allSatisfy(v61ArtifactColumns.contains) {
                try exec("""
                    INSERT OR IGNORE INTO global_artifacts (
                        id, title, home_notebook_id, created_at, updated_at
                    )
                    SELECT id, title, home_project_id, created_at, updated_at
                    FROM artifacts
                    """)
                let v61LinkColumns = try tableColumnNames("artifact_project_links")
                if ["artifact_id", "project_id", "linked_at"]
                    .allSatisfy(v61LinkColumns.contains) {
                    try exec("""
                        INSERT OR IGNORE INTO global_artifact_notebook_links (
                            artifact_id, notebook_id, linked_at
                        )
                        SELECT artifact_id, project_id, linked_at
                        FROM artifact_project_links
                        """)
                }
            }
        }

        // Durable Notebook-to-course subscriptions. A linked course contributes its
        // current sources to the Notebook immediately, and future course additions are
        // materialized into learning_goal_items by the course/source write paths.
        //
        // course_id deliberately has no FK: CloudKit may deliver the Notebook before
        // the course record. The relationship remains valid and begins contributing
        // as soon as the matching course arrives.
        try exec("""
            CREATE TABLE IF NOT EXISTS notebook_course_links (
                goal_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
                course_id TEXT NOT NULL,
                PRIMARY KEY (goal_id, course_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_notebook_course_links_course ON notebook_course_links(course_id)")

        // Directional, non-hierarchical Notebook references. A Notebook can draw
        // contextual material from another Notebook without copying its sources
        // or making it a child. The destination deliberately has no FK because
        // CloudKit may deliver the referring Notebook first.
        try exec("""
            CREATE TABLE IF NOT EXISTS notebook_related_notebook_links (
                notebook_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
                related_notebook_id TEXT NOT NULL,
                linked_at REAL NOT NULL,
                PRIMARY KEY (notebook_id, related_notebook_id),
                CHECK (notebook_id <> related_notebook_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_notebook_related_notebook_links_related ON notebook_related_notebook_links(related_notebook_id, notebook_id)")

        // Child-Goal lookups filter on the parent, so index it (the older
        // idx_learning_goals_status indexes a column that only ever held 'active'
        // until Goals gained real lifecycle state).
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goals_parent ON learning_goals(parent_notebook_id)")

        // Evolving "gaps in understanding" per companion goal; carried inside the
        // learningGoal CloudKit payload (no separate synced entity).
        try exec("""
            CREATE TABLE IF NOT EXISTS learning_goal_gaps (
                id TEXT PRIMARY KEY,
                goal_id TEXT NOT NULL REFERENCES learning_goals(id) ON DELETE CASCADE,
                summary TEXT NOT NULL,
                source_id TEXT,
                status TEXT NOT NULL DEFAULT 'open',
                severity REAL,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                resolved_at REAL,
                session_id TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_goal_gaps_goal ON learning_goal_gaps(goal_id, status)")

        // Shared calendar placement: a source sits on the Schedule once (one planned
        // day, one completion state) and is tagged with one or more plain Schedule
        // goals via scheduled_source_goals. source_id has no FK on purpose (mirrors
        // learning_goal_items: CloudKit can deliver a placement before its source).
        try exec("""
            CREATE TABLE IF NOT EXISTS scheduled_sources (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL UNIQUE,
                source_url TEXT,
                source_normalized_url TEXT,
                source_doi TEXT,
                source_published_doi TEXT,
                planned_at REAL NOT NULL,
                added_at REAL NOT NULL,
                completed_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                is_automatic INTEGER NOT NULL DEFAULT 0
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_sources_source ON scheduled_sources(source_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_sources_planned ON scheduled_sources(planned_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_sources_identity_url ON scheduled_sources(source_normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_sources_identity_doi ON scheduled_sources(source_doi)")
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_sources_identity_published_doi ON scheduled_sources(source_published_doi)")

        // Daily source activity is the automatic half of Schedule. It is kept
        // separate from the one editable planned placement so reading, listening,
        // chat, and review history never destroy a future plan or one another.
        // No FK by design: ScheduledSource/Source CloudKit delivery order is not
        // guaranteed, and reconciliation is performed by the storage actor.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_activity_days (
                id TEXT PRIMARY KEY,
                scheduled_source_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                day_start REAL NOT NULL,
                first_activity_at REAL NOT NULL,
                last_activity_at REAL NOT NULL,
                kinds INTEGER NOT NULL,
                completed_kinds INTEGER NOT NULL,
                max_fraction REAL NOT NULL DEFAULT 0,
                engaged_seconds REAL NOT NULL DEFAULT 0,
                UNIQUE(source_id, day_start)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_source_activity_days_source_day ON source_activity_days(source_id, day_start)")
        try exec("CREATE INDEX IF NOT EXISTS idx_source_activity_days_placement ON source_activity_days(scheduled_source_id)")

        // Many-to-many membership between a shared placement and plain Schedule goals.
        // Neither column has an FK: goal/placement deletion is handled in app code so
        // CloudKit delivery order can't fail an INSERT.
        try exec("""
            CREATE TABLE IF NOT EXISTS scheduled_source_goals (
                scheduled_source_id TEXT NOT NULL,
                goal_id TEXT NOT NULL,
                added_at REAL NOT NULL,
                PRIMARY KEY (scheduled_source_id, goal_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ssg_goal ON scheduled_source_goals(goal_id)")

        // Recurring instructions the app sends to itself. Distinct from
        // `scheduled_sources`, which places library material on a study day:
        // these place an *action* on a clock. `notebook_id` deliberately carries
        // no FK — CloudKit may deliver a task before its Notebook — and Notebook
        // deletion detaches the reference in app code, exactly as it does for
        // Schedule placements.
        try exec("""
            CREATE TABLE IF NOT EXISTS scheduled_tasks (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                instruction TEXT NOT NULL,
                notebook_id TEXT,
                source_ids TEXT NOT NULL DEFAULT '[]',
                cadence TEXT NOT NULL DEFAULT 'daily',
                weekday INTEGER,
                day_of_month INTEGER,
                hour INTEGER NOT NULL DEFAULT 8,
                minute INTEGER NOT NULL DEFAULT 0,
                time_zone TEXT,
                start_date REAL,
                is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_occurrence_at REAL,
                last_run_at REAL,
                last_run_status TEXT,
                run_now_requested_at REAL,
                runner_device_id TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_enabled ON scheduled_tasks(is_enabled)")
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_notebook ON scheduled_tasks(notebook_id)")

        // One receipt per occurrence. The UNIQUE constraint is the duplicate
        // guard: two Macs awake at 7am both try to claim the same instant and
        // exactly one INSERT survives, so one morning can only ever produce one
        // chat. Receipts also ride along in the task's CloudKit payload, so a
        // second device sees the same history rather than "never run".
        try exec("""
            CREATE TABLE IF NOT EXISTS scheduled_task_runs (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL REFERENCES scheduled_tasks(id) ON DELETE CASCADE,
                occurrence_at REAL NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL,
                status TEXT NOT NULL,
                session_id TEXT,
                message TEXT,
                device_name TEXT,
                attempt INTEGER NOT NULL DEFAULT 1,
                retry_at REAL,
                ring_slot TEXT,
                UNIQUE(task_id, occurrence_at)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_task_runs_task ON scheduled_task_runs(task_id, occurrence_at DESC)")

        // The time-block planner: one row per local date and the blocks drawn
        // on it. The day's id *is* its date so two devices planning the same
        // day offline produce one record; the day and its blocks travel in one
        // `DayPlan` CloudKit record. Rows are never destroyed: an edit lands on
        // the row, and `deleted_at` tombstones a block removed or replaced by a
        // redraw, so a merge can union by id. `revision` and
        // `superseded_in_revision` are the numbered columns builds before
        // 2026-09-30 drew; a row with the latter set is not part of the plan.
        // `notebook_id` carries no FK, like scheduled_tasks.
        try exec("""
            CREATE TABLE IF NOT EXISTS day_plans (
                id TEXT PRIMARY KEY,
                plan_date TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 1,
                notes TEXT,
                shutdown_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_day_plans_date ON day_plans(plan_date)")
        try exec("""
            CREATE TABLE IF NOT EXISTS time_blocks (
                id TEXT PRIMARY KEY,
                day_plan_id TEXT NOT NULL REFERENCES day_plans(id) ON DELETE CASCADE,
                start_minute INTEGER NOT NULL,
                end_minute INTEGER NOT NULL,
                title TEXT NOT NULL,
                notes TEXT,
                notebook_id TEXT,
                -- The Goal this hour is meant to serve, when the learner said.
                -- No FK, for the same reason as notebook_id.
                goal_id TEXT,
                -- The first of source_ids, kept for clients that read one source.
                source_id TEXT,
                -- JSON array of source ids, in the order they were added.
                source_ids TEXT NOT NULL DEFAULT '[]',
                -- What kind of hour the block is: work, read, review.
                purpose TEXT NOT NULL DEFAULT 'work',
                -- The calendar event the block mirrors, and its page, when a
                -- connected calendar drew it. No FK: the calendar is outside.
                calendar_event_id TEXT,
                calendar_event_url TEXT,
                -- Where the hour is, as the calendar says it: the event's
                -- conference link or else its room. The import's, not the
                -- learner's; notes are the learner's.
                location TEXT,
                status TEXT NOT NULL DEFAULT 'planned',
                revision INTEGER NOT NULL DEFAULT 1,
                superseded_in_revision INTEGER,
                deleted_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_time_blocks_plan ON time_blocks(day_plan_id, start_minute)")

        // The Planner's log: what the app saw the learner do, a span per sitting
        // on one thing (a source open in the Reader, a chat, a Doc), drawn beside
        // the plan and riding in the day's DayPlan record. target_id carries no
        // FK: the log still reads after the paper or chat is gone.
        try exec("""
            CREATE TABLE IF NOT EXISTS day_activities (
                id TEXT PRIMARY KEY,
                day_plan_id TEXT NOT NULL REFERENCES day_plans(id) ON DELETE CASCADE,
                start_minute INTEGER NOT NULL,
                end_minute INTEGER NOT NULL,
                kind TEXT NOT NULL,
                target_id TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_day_activities_plan ON day_activities(day_plan_id, start_minute)")

        // A timed learning bout: the clock the learner set, what came out of
        // it, and the break the write-up earned. Rides in the day's DayPlan
        // record beside its blocks and its log. block_id carries no FK — a
        // redraw supersedes the block's row and the bout must still read —
        // and neither does notebook_id, for the reason day_plans gives.
        try exec("""
            CREATE TABLE IF NOT EXISTS learning_bouts (
                id TEXT PRIMARY KEY,
                day_plan_id TEXT NOT NULL REFERENCES day_plans(id) ON DELETE CASCADE,
                block_id TEXT,
                title TEXT NOT NULL DEFAULT '',
                notebook_id TEXT,
                -- JSON array of source ids, copied from the block at the start.
                source_ids TEXT NOT NULL DEFAULT '[]',
                planned_minutes INTEGER NOT NULL,
                started_at REAL NOT NULL,
                -- The learner stopped learning. The timer running out does not
                -- set this: the clock never ends a bout.
                ended_at REAL,
                learned TEXT,
                unclear TEXT,
                -- The write-up was saved. This is when the break is earned.
                written_at REAL,
                break_minutes INTEGER NOT NULL DEFAULT 0,
                break_started_at REAL,
                break_ended_at REAL,
                abandoned_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_learning_bouts_plan ON learning_bouts(day_plan_id, started_at)")

        // Papers read off a video's slides at ingest, held as candidates until the
        // learner decides. source_id (the video) and imported_source_id (the paper
        // created on import) deliberately carry no FK, mirroring scheduled_sources:
        // CloudKit can deliver a candidate before either source row exists.
        try exec("""
            CREATE TABLE IF NOT EXISTS video_cited_papers (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                title TEXT NOT NULL,
                authors TEXT,
                year TEXT,
                journal TEXT,
                doi TEXT,
                url TEXT,
                slide_time_seconds REAL,
                slide_image_path TEXT,
                status TEXT NOT NULL,
                imported_source_id TEXT,
                kind TEXT NOT NULL DEFAULT 'paper',
                context TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_video_cited_papers_source ON video_cited_papers(source_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_video_cited_papers_status ON video_cited_papers(status)")

        // Journals (schema 99): publisher feeds this Mac follows, the articles
        // they announced, and the matching call's verdicts. All four tables are
        // device-local — the feed list and its HTTP validators describe this
        // machine's polling, and a match becomes synced library data only when
        // the learner accepts it (docs/journals-design.md). Pure DDL on empty
        // tables; cost cannot grow with the library.
        try exec("""
            CREATE TABLE IF NOT EXISTS journal_feeds (
                id TEXT PRIMARY KEY,
                feed_url TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                site_url TEXT,
                added_at REAL NOT NULL,
                last_checked_at REAL,
                last_succeeded_at REAL,
                last_error TEXT,
                etag TEXT,
                last_modified TEXT,
                item_count INTEGER NOT NULL DEFAULT 0
            )
        """)
        // The article URL is the identity: one row however many followed feeds
        // announce it, judged once. feed_id is the feed that announced it first.
        try exec("""
            CREATE TABLE IF NOT EXISTS journal_feed_items (
                item_url TEXT PRIMARY KEY,
                feed_id TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                authors TEXT,
                doi TEXT,
                journal TEXT,
                published_at REAL,
                first_seen_at REAL NOT NULL,
                judged_at REAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_journal_feed_items_feed ON journal_feed_items(feed_id, first_seen_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_journal_feed_items_judged ON journal_feed_items(judged_at)")
        // notebook_id carries no foreign key, like scheduled_tasks: a Notebook
        // deleted on another Mac still has its rows here, and they are simply
        // never shown. state is pending / accepted / dismissed; a dismissal is
        // the tombstone that keeps the same article from being offered to the
        // same Notebook twice.
        try exec("""
            CREATE TABLE IF NOT EXISTS journal_article_matches (
                item_url TEXT NOT NULL,
                notebook_id TEXT NOT NULL,
                reason TEXT,
                matched_at REAL NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                decided_at REAL,
                source_id TEXT,
                PRIMARY KEY (item_url, notebook_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_journal_article_matches_notebook ON journal_article_matches(notebook_id, state)")
        // Notebooks the learner has switched journal suggestions off for. An
        // exclusion list rather than an opt-in list so a Notebook created
        // tomorrow is watched without another trip to Settings.
        try exec("""
            CREATE TABLE IF NOT EXISTS journal_watch_excluded_notebooks (
                notebook_id TEXT PRIMARY KEY,
                excluded_at REAL NOT NULL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS courses (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                course_code TEXT,
                institution TEXT,
                instructors TEXT,
                playlist_url TEXT,
                is_hidden INTEGER NOT NULL DEFAULT 0,
                pending_playlist_import INTEGER NOT NULL DEFAULT 0,
                -- The team whose library this course is a copy in (schema 145).
                -- NULL is the learner's own library.
                team_id TEXT,
                -- The notebook the course lives in (schema 150).
                -- No foreign key: CloudKit may deliver the course first.
                -- NULL is in no notebook.
                home_notebook_id TEXT,
                -- The schema-v2 logical id (154) and what every v2 join reads
                wire_id TEXT,
                wire_key TEXT GENERATED ALWAYS AS (COALESCE(wire_id, id)) VIRTUAL,
                created_at REAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_courses_team ON courses(team_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_courses_home_notebook ON courses(home_notebook_id)")
        try exec("""
            CREATE TABLE IF NOT EXISTS video_playlists (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                playlist_url TEXT NOT NULL,
                last_refreshed_at REAL,
                is_hidden INTEGER NOT NULL DEFAULT 0,
                -- YouTube plugin: which playlists auto-refresh in the background
                -- and how they were followed: "liked", "foreverlm", or "channel"
                -- (a channel's uploads playlist); "playlist" rows are legacy follows
                -- kept as-is.
                auto_import INTEGER NOT NULL DEFAULT 0,
                connector_kind TEXT
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS course_lectures (
                id TEXT PRIMARY KEY,
                course_id TEXT NOT NULL,
                lecture_number INTEGER NOT NULL,
                title TEXT,
                created_at REAL NOT NULL,
                order_key TEXT,
                UNIQUE(course_id, lecture_number)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_course_lectures_course ON course_lectures(course_id)")

        try exec("""
            CREATE TABLE IF NOT EXISTS source_units (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                locator TEXT NOT NULL,
                title TEXT,
                UNIQUE(source_id, kind, locator)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_source_units_source ON source_units(source_id)")

        try exec("""
            CREATE TABLE IF NOT EXISTS course_lecture_items (
                id TEXT PRIMARY KEY,
                lecture_id TEXT NOT NULL REFERENCES course_lectures(id) ON DELETE CASCADE,
                source_id TEXT REFERENCES sources(id) ON DELETE CASCADE,
                source_unit_id TEXT REFERENCES source_units(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                label TEXT,
                sort_index INTEGER NOT NULL,
                created_at REAL NOT NULL,
                order_key TEXT,
                span_json TEXT,
                span_slot INTEGER,
                CHECK (source_id IS NOT NULL OR source_unit_id IS NOT NULL),
                UNIQUE(lecture_id, source_id, source_unit_id)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_course_lecture_items_lecture ON course_lecture_items(lecture_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_course_lecture_items_source ON course_lecture_items(source_id)")
        // An item may name a source unit instead of the source. Visibility asks
        // the question the other way round ("is this source in any course?"), so
        // that lookup needs an index of its own — without it SQLite builds a
        // transient one over the whole item table every time it is asked.
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_course_lecture_items_source_unit
            ON course_lecture_items(source_unit_id)
        """)
        // A course's quizzes (schema 138): course structure written ahead of
        // time, placed after a lecture. No foreign key to `courses`, like
        // `course_lectures`: a course's rows arrive before or after its
        // metadata in sync, and `deleteCourseGroup` removes them with it.
        try exec("""
            CREATE TABLE IF NOT EXISTS course_quizzes (
                id TEXT PRIMARY KEY,
                course_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                lecture_ids_json TEXT NOT NULL DEFAULT '[]',
                after_lecture_id TEXT,
                questions_json TEXT NOT NULL DEFAULT '[]',
                author TEXT NOT NULL DEFAULT 'foreverlm',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                symbol TEXT,
                artwork BLOB,
                revision INTEGER NOT NULL DEFAULT 1
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_course_quizzes_course ON course_quizzes(course_id)")


        try exec("""
            CREATE TABLE IF NOT EXISTS books (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                subtitle TEXT,
                author TEXT,
                edition TEXT,
                cover_path TEXT,
                kind TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS sync_changes (
                entity_type TEXT NOT NULL,
                logical_key TEXT NOT NULL,
                record_name TEXT NOT NULL,
                operation TEXT NOT NULL,
                changed_at REAL NOT NULL,
                tutor_only INTEGER NOT NULL DEFAULT 0,
                -- Where the record lives (schema 96): the private Knowledge
                -- zone, or a team zone in either database. See CloudKitZoneHome.
                zone_scope TEXT NOT NULL DEFAULT 'private',
                zone_name TEXT NOT NULL DEFAULT 'Knowledge',
                zone_owner_record_name TEXT,
                PRIMARY KEY (entity_type, logical_key)
            )
        """)

        // Local-only staging for versioned CloudKit repairs. The schema
        // transaction enqueues IDs set-wise; bounded post-launch batches derive
        // record names and build payloads/assets after the library is visible.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_sync_repair_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL
            )
        """)

        // Schema 98 renamed the CloudKit record type behind review sessions, so
        // every session goes up again under the new type. The migration stages
        // the ids set-wise; bounded post-launch batches hash the new record
        // names and enqueue ordinary sync changes.
        try exec("""
            CREATE TABLE IF NOT EXISTS review_session_sync_repair_queue (
                session_id TEXT PRIMARY KEY REFERENCES review_sessions(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL
            )
        """)

        // Same staging contract for stored text that still carries HTML
        // character references: migration enqueues IDs set-wise, and bounded
        // post-launch batches read, decode, and republish the content.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_text_reference_repair_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL
            )
        """)

        // Version 79 stages historical Zoom recordings set-wise; bounded
        // post-launch batches perform the relationship and sync writes after
        // the existing library is already visible.
        try exec("""
            CREATE TABLE IF NOT EXISTS zoom_meeting_adoption_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL
            )
        """)

        // Version 144 stages every paper with a DOI for one check of its title
        // against the title the DOI is registered under (a PDF's text can lose
        // a glyph; the catalog keeps it). Local-only: each Mac checks its own
        // library, and a restored title travels as an ordinary Source change.
        // `RegisteredPaperTitleCheckService` asks Crossref and DataCite off-main
        // in bounded batches after launch; a row leaves when answered.
        try exec("""
            CREATE TABLE IF NOT EXISTS paper_registered_title_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_paper_registered_title_order
            ON paper_registered_title_queue(attempt_count, enqueued_at)
        """)

        // Version 148 stages every personal YouTube video for one check of its
        // stored transcript against its captions, fetched again (a video keeps
        // no raw captions). Local-only: each Mac checks its own library, and a
        // rewritten transcript travels as an ordinary Source change.
        // `YouTubeTranscriptCheckService` fetches off-main in bounded batches
        // after launch; a row leaves when answered.
        try exec("""
            CREATE TABLE IF NOT EXISTS youtube_transcript_check_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_youtube_transcript_check_order
            ON youtube_transcript_check_queue(attempt_count, enqueued_at)
        """)

        // Version 166 stages every source of the learner's own library for one
        // check of its stored text for the soft hyphens older builds kept
        // (U+00AD, and a literal `&shy;` the decoder did not know). Local-only:
        // each Mac repairs its own copy, and the repaired text travels as an
        // ordinary Source change. `drainStoredSoftHyphenRepairBatch` reads it
        // after launch in bounded batches; a row leaves when answered.
        try exec("""
            CREATE TABLE IF NOT EXISTS source_text_soft_hyphen_repair_queue (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                enqueued_at REAL NOT NULL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS sync_metadata (
                entity_type TEXT NOT NULL,
                logical_key TEXT NOT NULL,
                record_name TEXT NOT NULL,
                system_fields BLOB,
                user_modification_at REAL NOT NULL,
                is_deleted INTEGER NOT NULL DEFAULT 0,
                zone_scope TEXT NOT NULL DEFAULT 'private',
                zone_name TEXT NOT NULL DEFAULT 'Knowledge',
                zone_owner_record_name TEXT,
                PRIMARY KEY (entity_type, logical_key),
                UNIQUE (record_name)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_sync_metadata_zone ON sync_metadata(zone_scope, zone_name, zone_owner_record_name)")

        // Permanent create-once/immutable record conflicts are quarantined
        // here instead of remaining in `sync_changes`. Keeping the server
        // payload and change tag makes the failure inspectable and recoverable,
        // while removing the active save prevents an unbounded CKSyncEngine
        // serverRecordChanged retry loop.
        try exec("""
            CREATE TABLE IF NOT EXISTS sync_conflicts (
                entity_type TEXT NOT NULL,
                logical_key TEXT NOT NULL,
                record_name TEXT NOT NULL,
                reason TEXT NOT NULL,
                local_modification_at REAL NOT NULL,
                server_modification_at REAL NOT NULL,
                detected_at REAL NOT NULL,
                server_payload BLOB,
                server_system_fields BLOB,
                zone_scope TEXT NOT NULL DEFAULT 'private',
                zone_name TEXT NOT NULL DEFAULT 'Knowledge',
                zone_owner_record_name TEXT,
                PRIMARY KEY (entity_type, logical_key)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_sync_conflicts_detected ON sync_conflicts(detected_at DESC)")

        // What each asset field last *successfully* uploaded, so an unchanged
        // asset is not rebuilt and re-sent every time its record is saved for an
        // unrelated reason. `digest` is the committed value; `pending_digest` is
        // staged while a save is in flight and only promoted when CloudKit
        // acknowledges the record. A crash between the two leaves a stale
        // pending value, which the next makeRecord for that record overwrites
        // before its own save can promote it.
        try exec("""
            CREATE TABLE IF NOT EXISTS sync_asset_digests (
                record_name TEXT NOT NULL,
                field TEXT NOT NULL,
                digest TEXT,
                pending_digest TEXT,
                staged_attempts INTEGER NOT NULL DEFAULT 0,
                first_staged_at REAL,
                last_staged_at REAL,
                PRIMARY KEY (record_name, field)
            )
        """)

        // One CKSyncEngine per database scope (schema 96): the learner's
        // private database, and the shared database that carries the teams
        // they were invited to. Each engine serializes its own state.
        try exec("""
            CREATE TABLE IF NOT EXISTS sync_engine_states (
                scope TEXT PRIMARY KEY,
                state_serialization BLOB
            )
        """)

        // Teams (schema 96). A row is the local projection of one team zone:
        // its CloudKit address, this account's role in it, and the share that
        // carries the roster. Content rows point at it through `team_id`.
        try exec("""
            CREATE TABLE IF NOT EXISTS teams (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('owner', 'member')),
                permission TEXT NOT NULL CHECK (permission IN ('readOnly', 'readWrite')),
                zone_scope TEXT NOT NULL,
                zone_name TEXT NOT NULL,
                zone_owner_record_name TEXT,
                share_record_name TEXT,
                share_url TEXT,
                created_at REAL NOT NULL,
                joined_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                family_plan_code TEXT
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS team_members (
                team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
                user_record_name TEXT NOT NULL,
                display_name TEXT NOT NULL,
                email TEXT,
                role TEXT NOT NULL,
                permission TEXT NOT NULL,
                acceptance_status TEXT NOT NULL,
                is_current_user INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL,
                PRIMARY KEY (team_id, user_record_name)
            )
        """)
        // Notebook tasks (schema 96). Every Notebook can carry tasks; a team
        // Notebook's tasks sync in the team zone and can name an assignee by
        // CloudKit user record name. notebook_id has no foreign key for the
        // same reason learning_goal_items.source_id has none: CloudKit may
        // deliver a task before its Notebook.
        try exec("""
            CREATE TABLE IF NOT EXISTS notebook_tasks (
                id TEXT PRIMARY KEY,
                notebook_id TEXT NOT NULL,
                team_id TEXT,
                title TEXT NOT NULL,
                notes TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'todo',
                assignee_record_name TEXT,
                assignee_display_name TEXT,
                due_at REAL,
                source_id TEXT,
                artifact_id TEXT,
                sort_order REAL NOT NULL DEFAULT 0,
                created_by_record_name TEXT,
                created_by_display_name TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL,
                order_key TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_notebook_tasks_notebook ON notebook_tasks(notebook_id, status, sort_order)")
        try exec("CREATE INDEX IF NOT EXISTS idx_notebook_tasks_team ON notebook_tasks(team_id)")

        // A member's request that a source cited on a team Doc be shared into
        // the team (docs/teams-design.md, decision 14). Synced in the team
        // zone; the URL is the card's address as written, matched against a
        // holder's library the way the card matches. artifact_id has no
        // foreign key because CloudKit may deliver the request before its Doc.
        try exec("""
            CREATE TABLE IF NOT EXISTS share_requests (
                id TEXT PRIMARY KEY,
                team_id TEXT NOT NULL,
                url TEXT NOT NULL,
                title TEXT,
                artifact_id TEXT,
                requested_by_record_name TEXT,
                requested_by_display_name TEXT,
                status TEXT NOT NULL DEFAULT 'open',
                resolved_by_record_name TEXT,
                resolved_by_display_name TEXT,
                fulfilled_source_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                resolved_at REAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_share_requests_team ON share_requests(team_id, status)")
        try exec("CREATE INDEX IF NOT EXISTS idx_share_requests_url ON share_requests(url)")

        // --- Per-type source tables ---

        try exec("""
            CREATE TABLE IF NOT EXISTS articles (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT,
                author TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS papers (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT,
                author TEXT,
                doi TEXT,
                published_doi TEXT,
                journal TEXT,
                published_year TEXT,
                is_paywalled INTEGER NOT NULL DEFAULT 0,
                paper_ingestion_method TEXT,
                paywall_suspicion TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS podcasts (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT,
                show_name TEXT,
                web_page_url TEXT,
                raw_ttml TEXT,
                -- Retired by schema 167 (podcast_transcript_audits): neither read nor written
                detruncated_ttml_sha256 TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS book_sources (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT,
                page_start INTEGER,
                page_count INTEGER
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS course_sources (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS meeting_groups (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                drive_folder_url TEXT,
                local_folder_path TEXT,
                recurrence_rule TEXT,
                timezone TEXT,
                is_hidden INTEGER NOT NULL DEFAULT 0,
                merged_into_group_id TEXT,
                schedule_json TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS meeting_sources (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT,
                occurred_at REAL,
                transcript_status TEXT,
                presenter TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS meeting_artifacts (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                group_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                url TEXT,
                local_file_path TEXT,
                mime_type TEXT,
                modified_at REAL,
                sort_index INTEGER NOT NULL DEFAULT 0
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_meeting_artifacts_group ON meeting_artifacts(group_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_meeting_artifacts_source ON meeting_artifacts(source_id)")

        // What a meeting session's transcript asked someone to do. source_id
        // carries no FK: the item is part of the series' record and must
        // read after the session is gone, and CloudKit may deliver the group
        // before the session. done_at is monotonic (a done item stays done),
        // which is what lets two Macs' rows union safely.
        try exec("""
            CREATE TABLE IF NOT EXISTS meeting_action_items (
                id TEXT PRIMARY KEY,
                group_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                text TEXT NOT NULL,
                owner TEXT,
                due_hint TEXT,
                done_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_meeting_action_items_group ON meeting_action_items(group_id, created_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_meeting_action_items_source ON meeting_action_items(source_id, position)")

        try exec("""
            CREATE TABLE IF NOT EXISTS videos (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT,
                platform TEXT,
                -- Both dates come from the Liked-feed sync (playlistItems
                -- `snippet.publishedAt` and `contentDetails.videoPublishedAt`). They
                -- stay NULL for videos that never came through that feed —
                -- Safari-discovered rows, manual adds — and for liked rows until the
                -- next feed refresh.
                liked_at REAL,
                video_published_at REAL,
                -- When this video's transcript was last compared against a fresh
                -- caption fetch, to settle whether the retired 50,000-character
                -- import cap had truncated it. A video has no stored raw
                -- transcript, so unlike a podcast episode the only authority on
                -- its true length is the network — and the answer has to be
                -- remembered, or every open would fetch again.
                legacy_cap_verified_at REAL
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS x_posts (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                local_file_path TEXT,
                normalized_url TEXT,
                title TEXT,
                domain TEXT NOT NULL DEFAULT '',
                discovery_origin TEXT,
                word_count INTEGER,
                artwork_url TEXT,
                author_handle TEXT,
                post_text TEXT,
                author TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS group_members (
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                group_id TEXT NOT NULL,
                sort_index INTEGER,
                lecture_group_id TEXT,
                PRIMARY KEY (source_id, group_id)
            )
        """)

        // Recreate the view to pick up schema changes (e.g. removed repos table)
        try exec("DROP VIEW IF EXISTS source_projection")
        try exec(Self.sourceProjectionViewSQL(sourceColumnNames: try tableColumnNames("sources"), readingStates: syncGeneration == .two))

        // Indexes for common queries
        try exec("CREATE INDEX IF NOT EXISTS idx_sources_state ON sources(state)")
        try exec("CREATE INDEX IF NOT EXISTS idx_sources_source_type ON sources(source_type)")
        try exec("CREATE INDEX IF NOT EXISTS idx_group_members_group_id ON group_members(group_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_articles_normalized_url ON articles(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_normalized_url ON papers(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_doi ON papers(doi)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_published_doi ON papers(published_doi)")
        // Legacy rows may contain uppercase DOI characters. New writes normalize,
        // while these indexed NOCASE lookups preserve portable identity for old rows.
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_doi_nocase ON papers(doi COLLATE NOCASE)")
        try exec("CREATE INDEX IF NOT EXISTS idx_papers_published_doi_nocase ON papers(published_doi COLLATE NOCASE)")
        try exec("CREATE INDEX IF NOT EXISTS idx_podcasts_normalized_url ON podcasts(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_book_sources_normalized_url ON book_sources(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_course_sources_normalized_url ON course_sources(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_meeting_sources_normalized_url ON meeting_sources(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_videos_normalized_url ON videos(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_x_posts_normalized_url ON x_posts(normalized_url)")
        try exec("CREATE INDEX IF NOT EXISTS idx_review_exchanges_session ON review_exchanges(session_id)")
        // Served the question calibration's read of every rated turn, newest
        // first, until that pass was retired on 2026-09-27. Kept rather than
        // dropped: removing it would be a schema change for nothing, and being
        // partial, it costs an unrated library nothing.
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_review_exchanges_rated
            ON review_exchanges(rated_at DESC) WHERE rating IS NOT NULL
        """)

        // The schema-v2 replica, outbox and activation tables (schema 154),
        // created empty; only a store's generation-2 activation fills them.
        // With the wire_key indexes they wait, as all of 154 does, on a store
        // held below it.
        if laysDownSchema154 {
            try createReplicaTables()
            try createWireKeyIndexes()
            // Schema 155's Source and Collection tables, empty (WP7).
            try createSourceSyncTables()
            // Schema 156's notebook tables, empty (WP8). A migrating store
            // gets the back-pointer view after its steps (the < 156 step).
            try createNotebookSyncTables()
            // Schema 157's course table, empty (WP9).
            try createCourseSyncTables()
            if !isMigration {
                try createNotebookChildrenView()
            }
            // Schema 159's Artifact tables, empty (WP11).
            try createArtifactSyncTables()
            // Schema 160's reading state, empty (WP12).
            try createReadingSyncTables()
            // Schema 161's memory tables, empty (WP13).
            try createMemorySyncTables()
            // Schema 162's jobs table, empty (WP14).
            try createTasksSyncTables()
            // Schema 163's Device and import-blocked tables, empty (WP12b).
            try createPersonalStateSyncTables()
        }

        if isMigration {
            if currentVersion < 8 {
                reactivatedCourseSourceCount = try reactivateArchivedCourseLectureSources()
            }
            if currentVersion < 9 {
                republishedVideoProgressCount = try republishVideoWatchProgressForSync()
            }
            if currentVersion < 10 {
                migratedPaperIngestionCount = try migratePaperIngestionGate()
            }
            if currentVersion < 13 {
                restoredCourseMaterialCount = try restoreMisclassifiedCourseMaterials()
            }
            if currentVersion < 14 {
                migratedModelPreferenceCount = try migratePersistedModelPreferences(
                    startupPreferenceSnapshot
                )
            }
            if currentVersion < 16 {
                republishedDismissedArchiveCount = try republishDismissedArchivedSourcesForSync()
            }
            if currentVersion < 18 {
                queuedCanonicalCleanupCount = try enqueueHistoricalCanonicalContentCleanup(
                    reason: "Source clean-up was introduced (schema 18)",
                    affectedSources: .unknown(because: "every source predates the clean-up")
                )
            }
            if currentVersion < 19 {
                // Re-fetch the authoritative ledger once so managed rows that
                // predate this column are updated with their server-recorded
                // platform. The import is idempotent by server_ledger_id.
                try exec("UPDATE managed_ai_usage_sync_state SET last_ledger_id = 0 WHERE singleton = 1")
            }
            if currentVersion < 23 {
                queuedCanonicalCleanupCount = try enqueueHistoricalCanonicalContentCleanup(
                    reason: "Source clean-up v6 (bounded hunks)",
                    affectedSources: .unknown(because: "the contract change reaches every cleaned source")
                )
            }
            if currentVersion < 24 {
                let repair = try repairArchivedSourceSyncState()
                republishedArchivedSourceCount = repair.republishedSources
                removedArchivedGoalLinkCount = repair.removedGoalLinks
            }
            if currentVersion < 26 {
                queuedCanonicalCleanupCount = try enqueueHistoricalCanonicalContentCleanup(
                    reason: "Source clean-up v8 (bibliography removal)",
                    affectedSources: .unknown(because: "any source may carry a bibliography")
                )
            }
            if currentVersion < 32 {
                try resetCanonicalContentCleanupAttempts()
            }
            if currentVersion < 34 {
                queuedPaperMetadataRepublishCount = try enqueueAttestedPaperSyncRepair()
            }
            if currentVersion < 35 {
                queuedCanonicalCleanupCount = try holdingBulkRequeue(
                    into: .canonicalCleanup,
                    reason: "Paper clean-up before Muse Spark review guides (schema 35)",
                    affectedSources: .unknown(because: "every stale paper is restaged")
                ) { try enqueueHistoricalPaperCanonicalContentCleanup() }
                queuedReviewGuideCount = try enqueueMuseSparkPaperReviewGuides()
            }
            if currentVersion < 37 {
                queuedTextlessSourceReingestionCount = try enqueueTextlessReadySourceReingestion()
            }
            if currentVersion < 38 {
                attributedRealtimeUsageCount = try backfillRealtimeUsagePlatformAttribution()
            }
            if currentVersion < 40 {
                // Version 37 demoted every textless `ready` source, but paywalled
                // papers came back: `clearPaywalledStatus` promoted on metadata
                // attestation alone, which a paper can satisfy while holding no
                // body text. Those call sites now require durable text, so this
                // sweep is the one-time cleanup rather than a recurring patch.
                queuedTextlessSourceReingestionCount = try enqueueTextlessReadySourceReingestion()
            }
            if currentVersion < 41 {
                queuedPaperFigureIndexCount = try enqueueHistoricalPaperFigureIndex()
            }
            if currentVersion < 42 {
                cancelledReviewGuideCount = try cancelPendingSourceReviewGuidePreparation()
            }
            if currentVersion < 43 {
                queuedListenableContentCount = try holdingBulkRequeue(
                    into: .listenPreparation,
                    reason: "Listen preparation was introduced (schema 43)",
                    affectedSources: .unknown(because: "every article and paper lacked a Listen derivative")
                ) { try enqueueHistoricalListenableContentPreparation() }
            }
            if currentVersion < 44 {
                retiredIneligibleListenableContentCount = try retireIneligibleListenableContentPreparation()
            }
            if currentVersion < 45 {
                requeuedPaperListenableContentCount = try holdingBulkRequeue(
                    into: .listenPreparation,
                    reason: "Listen preparation learned sidebar ordering (schema 45)",
                    affectedSources: .unknown(because: "any paper may carry a sidebar")
                ) { try requeuePaperListenableContentForSidebarOrdering() }
            }
            if currentVersion < 55 {
                // Re-clean from the preserved raw extraction. The bounded
                // background queue performs all parsing and AI work after
                // launch; migration only stages indexed source IDs. Versions
                // 46–55 iterated this contract before release, so one final
                // idempotent enqueue covers every predecessor without issuing
                // the same set-based statement repeatedly in one transaction.
                queuedCanonicalCleanupCount = try holdingBulkRequeue(
                    into: .canonicalCleanup,
                    reason: "Paper clean-up from the preserved extraction (schema 55)",
                    affectedSources: .unknown(because: "versions 46-55 reached every paper")
                ) { try enqueueHistoricalPaperCanonicalContentCleanup() }
            }
            if currentVersion < 56 {
                // A canonical cleanup can legitimately preserve every source
                // block. In that case the source hash stays unchanged, but an
                // older narration contract is still stale. Stage those already
                // cleaned papers once so queue completion means every paper has
                // a current narration derivative.
                requeuedStalePaperListenableContentCount = try holdingBulkRequeue(
                    into: .listenPreparation,
                    reason: "Listen preparation contract update (schema 56)",
                    affectedSources: .unknown(because: "every stale derivative is out of contract")
                ) { try enqueueStaleCleanedPaperListenableContentPreparation() }
            }
            if currentVersion < 65 {
                // Listen preparation used to require `state = 'ready'`, so a
                // paper that failed the metadata gate was left with canonical
                // text and no narration — iOS offered Listen and could only
                // report that the source was "still preparing". Stage those
                // sources once so the existing backlog heals.
                queuedUnattestedListenableContentCount = try holdingBulkRequeue(
                    into: .listenPreparation,
                    reason: "Listen preparation for papers without metadata (schema 65)",
                    affectedSources: .unknown(because: "the staged sources are the affected ones")
                ) { try enqueueUnattestedListenableContentPreparation() }
            }
            if currentVersion < 68 {
                queuedTextReferenceRepairCount =
                    try enqueueStoredHTMLCharacterReferenceRepair()
            }
            if currentVersion < 70 {
                queuedSourcePDFAssetRepublishCount =
                    try enqueueRecordedSourcePDFAssetRepublish()
            }
            if currentVersion < 73 {
                // Removing a course used to leave its own PDFs and notes in the
                // library as active rows no list could show: the Courses tab
                // lists courses, so course-typed material reaches a list only
                // through one. Hide the backlog those deletions left behind —
                // 104 sources from twelve long-deleted courses on the library
                // that surfaced this — and keep the same statement true from
                // now on inside `deleteCourseGroup`.
                hiddenCourselessCourseSourceCount = try hideCourseSourcesWithoutCourse().count
            }
            if currentVersion < 74 {
                queuedArticleChromeRefilterCount = try enqueueArchivedArticleChromeRefilter()
            }
            if currentVersion < 75 {
                // Figures stopped being copied out of PDFs. Both halves of that
                // are set-based DDL/staging here; the file sweep and the content
                // rewrite are library-proportional and run after launch.
                try dropPaperFigureImagePathColumn()
                queuedPaperFigureMarkdownRepairCount =
                    try enqueueLegacyPaperFigureMarkdownRepair()
                try execBind("""
                    INSERT INTO paper_figure_image_sweep_state (singleton, enqueued_at)
                    VALUES (1, ?)
                    ON CONFLICT(singleton) DO NOTHING
                """) { stmt in
                    sqlite3_bind_double(stmt, 1, Date().timeIntervalSinceReferenceDate)
                }
            }
            if currentVersion < 77 {
                // Stage IDs only. Transcript text remains readable and all
                // model calls run later through the bounded storage/AI actors.
                queuedPodcastTranscriptCleanupCount = try holdingBulkRequeue(
                    into: .podcastTranscriptCleanup,
                    reason: "Podcast ad clean-up was introduced (schema 77)",
                    affectedSources: .unknown(because: "every transcript predates the ad clean-up")
                ) { try enqueueHistoricalPodcastTranscriptCleanup() }
            }
            if currentVersion < 79 {
                // Zoom stopped being a tab and became a meeting provider, so its
                // recording IDs are staged set-wise. Relationship and sync
                // writes drain later in bounded batches, after first paint.
                queuedZoomRecordingCount = try enqueueZoomMeetingAdoption()
            }
            if currentVersion < 80 {
                // Folder images were briefly writable before every path mirrored
                // them into SQLite. Adopt only values with no durable row or
                // CloudKit history; an existing synced choice or tombstone wins
                // over a possibly stale local defaults value.
                migratedMeetingFolderImageCount = try migrateMeetingFolderImagePreferences(
                    startupPreferenceSnapshot
                )
            }
            if currentVersion < 83 {
                // Repair the digests already orphaned by the two exit paths that
                // used to leave them: a quarantined save and a save discarded
                // for a missing local row both left the queue while their
                // staged rows stayed pending, and nothing afterwards could
                // commit or clear them. A record with no queue entry cannot be
                // mid-flight at migration time, which is what makes this safe
                // to do set-wise here rather than record by record later.
                repairedOrphanedAssetStagingCount = try repairOrphanedAssetStaging()
            }
            // Schema 85 queued every podcast with stored TTML for a completeness
            // audit here. Schema 167's step, below, queues every episode its
            // audit can measure, which includes all of those, so a store older
            // than 85 is queued once, by it.
            if currentVersion < 88 {
                // The chat-history summary cache is new and regenerable, so an
                // older store carries nothing into it. Probing the shape catches
                // a same-named table of the wrong shape before the version
                // stamp commits, so the transaction rolls back whole.
                try query("""
                    SELECT session_id, digest, through_exchange_id, through_field, updated_at
                    FROM review_session_history_digests
                    LIMIT 0
                """) { _ in }
            }
            if currentVersion < 89 {
                // Ideas are extracted on demand, so an older store carries
                // nothing into the table; the probe only proves its shape, and
                // the ALTERs above have already added the grading columns.
                try query("""
                    SELECT \(Self.sourceIdeaColumns)
                    FROM source_ideas
                    LIMIT 0
                """) { _ in }
            }
            if currentVersion < 91 {
                // Review time starts accruing from this build, so an older
                // store carries nothing into the table; the probe proves the
                // shape so a same-named table of another shape rolls back.
                try query("""
                    SELECT \(Self.memoryReviewActivityColumns)
                    FROM memory_review_activity
                    LIMIT 0
                """) { _ in }
            }
            if currentVersion < 92 {
                retiredSlackSourceCount = try retireSlackSources()
            }
            if currentVersion < 93 {
                // Ratings start accruing from this build, so an older store
                // carries nothing into the columns; the probe proves the four
                // ALTERs above landed so a same-named column of another shape
                // rolls the migration back. DDL only, no row is read.
                try query("""
                    SELECT rating, rating_reason, rating_field, rated_at
                    FROM review_exchanges
                    LIMIT 0
                """) { _ in }
            }
            if currentVersion < 96 {
                // Teams. The one CKSyncEngine state row becomes the private
                // scope's row in the keyed table; a bounded set-based copy, no
                // application row is read. The probes prove the new tables and
                // the zone columns landed so a same-named table of another
                // shape rolls the whole migration back.
                var hasSingletonEngineState = false
                try query("""
                    SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sync_engine_state' LIMIT 1
                """) { _ in
                    hasSingletonEngineState = true
                }
                if hasSingletonEngineState {
                    try exec("""
                        INSERT OR REPLACE INTO sync_engine_states (scope, state_serialization)
                        SELECT 'private', state_serialization FROM sync_engine_state WHERE id = 1
                    """)
                    try exec("DROP TABLE IF EXISTS sync_engine_state")
                }
                try query("""
                    SELECT id, name, role, permission, zone_scope, zone_name, zone_owner_record_name,
                           share_record_name, share_url, created_at, joined_at, updated_at
                    FROM teams
                    LIMIT 0
                """) { _ in }
                try query("""
                    SELECT team_id, user_record_name, display_name, email, role, permission,
                           acceptance_status, is_current_user, updated_at
                    FROM team_members
                    LIMIT 0
                """) { _ in }
                try query("""
                    SELECT id, notebook_id, team_id, title, notes, status, assignee_record_name,
                           assignee_display_name, due_at, source_id, artifact_id, sort_order,
                           created_by_record_name, created_by_display_name, created_at, updated_at, completed_at
                    FROM notebook_tasks
                    LIMIT 0
                """) { _ in }
                try query("""
                    SELECT zone_scope, zone_name, zone_owner_record_name FROM sync_metadata LIMIT 0
                """) { _ in }
                try query("""
                    SELECT zone_scope, zone_name, zone_owner_record_name FROM sync_changes LIMIT 0
                """) { _ in }
                try query("""
                    SELECT zone_scope, zone_name, zone_owner_record_name FROM sync_conflicts LIMIT 0
                """) { _ in }
                try query("SELECT team_id FROM sources LIMIT 0") { _ in }
                try query("SELECT team_id FROM learning_goals LIMIT 0") { _ in }
                try query("SELECT team_id FROM global_artifacts LIMIT 0") { _ in }
                try query("SELECT team_id FROM review_sessions LIMIT 0") { _ in }
            }
            if currentVersion < 98 {
                // The review tables were renamed above. Two set-based fixes
                // follow, neither reading an application row one by one:
                // usage-ledger task names take the tasks' new raw values, and
                // the sync bookkeeping for the renamed CloudKit record type is
                // dropped so every session is re-uploaded as `ReviewSession`
                // by the post-launch drain. The old `FeynmanSession` records
                // stay in CloudKit unread; no build looks for them any more.
                try exec("""
                    UPDATE ai_usage_events
                    SET task = CASE task
                        WHEN 'feynman_quiz' THEN 'chat'
                        WHEN 'mobile_feynman_review' THEN 'mobile_review'
                    END
                    WHERE task IN ('feynman_quiz', 'mobile_feynman_review')
                """)
                try exec("DELETE FROM sync_changes WHERE entity_type = 'feynmanSession'")
                try exec("DELETE FROM sync_conflicts WHERE entity_type = 'feynmanSession'")
                try exec("""
                    DELETE FROM sync_asset_digests
                    WHERE record_name IN (SELECT record_name FROM sync_metadata WHERE entity_type = 'feynmanSession')
                """)
                try exec("DELETE FROM sync_metadata WHERE entity_type = 'feynmanSession'")
                try exec("""
                    INSERT OR IGNORE INTO review_session_sync_repair_queue (session_id, enqueued_at)
                    SELECT id, \(Date().timeIntervalSinceReferenceDate) FROM review_sessions
                """)
                // Probes: the renamed tables answer under their new names and
                // the old names are gone, or the whole migration rolls back.
                try query("SELECT id, topic, source_ids FROM review_sessions LIMIT 0") { _ in }
                try query("SELECT id, session_id FROM review_exchanges LIMIT 0") { _ in }
                try query("SELECT session_id, source_id FROM review_session_sources LIMIT 0") { _ in }
                try query("SELECT session_id FROM review_session_history_digests LIMIT 0") { _ in }
                try query("SELECT session_id, enqueued_at FROM review_session_sync_repair_queue LIMIT 0") { _ in }
                var staleTables = 0
                try query("""
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name IN (
                        'feynman_sessions', 'feynman_exchanges',
                        'feynman_session_sources', 'feynman_session_history_digests'
                    )
                """) { stmt in staleTables = Int(sqlite3_column_int(stmt, 0)) }
                guard staleTables == 0 else {
                    throw KnowledgeStoreError.invalidData(
                        "Schema 98 left \(staleTables) review table(s) under the retired name."
                    )
                }
            }
            if currentVersion < 97 {
                // A podcast episode filed under its web page held the page —
                // show notes, topic lists — as its content and reported ready,
                // so chat and search answered about the episode from its
                // description. 374 such rows on the library that surfaced this,
                // every one an older build's import of a private subscriber
                // feed. The text goes; the rows queue for the transcript
                // pipeline, which resolves them to the public episode Apple
                // transcribes. Set-wise over one indexed predicate; no network.
                demotedPodcastPageTextCount = try demotePodcastEpisodesHoldingPageText()
            }
            if currentVersion < 102 {
                // No Notebook had a repository before this build, so an older
                // store carries nothing into the column; the probe proves the
                // ALTER above landed so a same-named column of another shape
                // rolls the migration back. DDL only, no row is read.
                try query("SELECT repository FROM learning_goals LIMIT 0") { _ in }
            }
            if currentVersion < 104 {
                // A chat's loaded set is written only as chats are used, so an
                // older store carries nothing into the column; the probe proves
                // the ALTER above landed. DDL only, no row is read.
                try query("SELECT loaded_source_ids FROM review_sessions LIMIT 0") { _ in }
            }
            if currentVersion < 105 {
                // Two new tables on an older store, created empty above. The
                // probes select every column the planner reads, so a
                // same-named table of another shape rolls the migration back.
                // DDL only; no application row is read.
                try query("SELECT id, plan_date, revision, notes, shutdown_at, created_at, updated_at FROM day_plans LIMIT 0") { _ in }
                try query("""
                    SELECT id, day_plan_id, start_minute, end_minute, title, notes, notebook_id, status,
                           revision, superseded_in_revision, deleted_at, created_at, updated_at
                    FROM time_blocks LIMIT 0
                """) { _ in }
            }
            if currentVersion < 106 {
                // Nothing was archived before this build, so an older store
                // carries nothing into the column; the probe proves the ALTER
                // above landed, and a same-named column of another shape rolls
                // the migration back. DDL only, no row is read.
                try query("SELECT archived_at FROM global_artifacts LIMIT 0") { _ in }
            }
            if currentVersion < 107 {
                // No block carried a source before this build, so an older
                // store carries nothing into the column; the probe proves the
                // ALTER (or the CREATE TABLE above) landed. The log table is
                // new and empty; its probe selects every column the Planner
                // reads so a same-named table of another shape rolls the
                // migration back. DDL only; no application row is read.
                try query("SELECT source_id FROM time_blocks LIMIT 0") { _ in }
                try query("""
                    SELECT id, day_plan_id, start_minute, end_minute, kind, target_id, title, created_at, updated_at
                    FROM day_activities LIMIT 0
                """) { _ in }
            }
            if currentVersion < 108 {
                // The probe proves the ALTER (or the CREATE TABLE above)
                // landed. Then the one source a block carried becomes the
                // first of its sources: one set-based UPDATE over time_blocks,
                // a table of hand-drawn rows whose size follows the learner's
                // days, not the library. Rows already carrying a list — a
                // record that synced in from a newer client before this
                // launch — are left alone.
                try query("SELECT source_ids FROM time_blocks LIMIT 0") { _ in }
                try exec("""
                    UPDATE time_blocks
                    SET source_ids = json_array(source_id)
                    WHERE source_id IS NOT NULL AND source_id <> '' AND source_ids = '[]'
                """)
            }
            if currentVersion < 109 {
                // No block came from a calendar before this build, so an older
                // store carries nothing into the columns; the probe proves the
                // ALTERs (or the CREATE TABLE above) landed, and a same-named
                // column of another shape rolls the migration back. DDL only;
                // no application row is read.
                try query("SELECT calendar_event_id, calendar_event_url FROM time_blocks LIMIT 0") { _ in }
            }
            if currentVersion < 110 {
                // The probe proves the ALTER (or the CREATE TABLE above)
                // landed. NULL is the truth about every existing row — no
                // browser run has spoken yet — so nothing is written. DDL
                // only; no row is read.
                try query("SELECT paywall_suspicion FROM papers LIMIT 0") { _ in }
            }
            // Versions 111 and 112 added global_artifacts.hidden_at and
            // review_sessions.hidden_at and probed them here. Version 114
            // retired both columns for the two tables it creates, so a store
            // arriving from before 111 no longer gains them and the probes
            // went with them; a store from 111 to 113 keeps its columns and
            // hands their rows over below.
            if currentVersion < 113 {
                // No series had a fixed time before this build, so an older
                // store carries nothing into the column; the probe proves the
                // ALTER (or the CREATE TABLE above) landed. The action-item
                // table is new and empty; its probe selects every column the
                // Planner reads so a same-named table of another shape rolls
                // the migration back. DDL only; no application row is read.
                try query("SELECT schedule_json FROM meeting_groups LIMIT 0") { _ in }
                try query("""
                    SELECT id, group_id, source_id, position, text, owner, due_hint, done_at, created_at, updated_at
                    FROM meeting_action_items LIMIT 0
                """) { _ in }
            }
            if currentVersion < 114 {
                // Both tables are new; the probes prove the CREATE TABLEs above
                // landed, and a same-named table of another shape rolls the
                // migration back. Then the hides the retired per-Mac columns
                // recorded become rows here, each queued for CloudKit so the
                // other Macs learn of them — bounded by what a person hid by
                // hand, tens of rows, never the library.
                try query("SELECT artifact_id, hidden_at FROM hidden_artifacts LIMIT 0") { _ in }
                try query("SELECT session_id, hidden_at FROM hidden_review_sessions LIMIT 0") { _ in }
                adoptedHiddenItemCount = try adoptRetiredHiddenColumns()
            }
            if currentVersion < 115 {
                // The probe selects every column the candidate reader uses, so
                // it proves both ALTERs (or the CREATE TABLE above) landed and a
                // same-named table of another shape — which the additive step
                // would happily have given the two new columns — rolls the
                // migration back. DDL only; no row is read.
                try query("""
                    SELECT id, source_id, title, authors, year, journal, doi, url,
                           slide_time_seconds, slide_image_path, status, imported_source_id,
                           created_at, updated_at, kind, context
                    FROM video_cited_papers LIMIT 0
                """) { _ in }
            }
            if currentVersion < 116 {
                // Four reader layout choices and the navigation rail's hidden
                // rows and folds started following the account on 2026-09-14.
                // They had only ever been written to UserDefaults, so without
                // this the learner's existing choices would sit local until the
                // next time they happened to change one — and a rebuild into a
                // fresh preferences container would lose them outright, which is
                // what the v14 and v80 adoptions above exist to prevent.
                adoptedDisplayPreferenceCount = try adoptNewlySyncedDisplayPreferences(
                    startupPreferenceSnapshot
                )
            }
            if currentVersion < 117 {
                // No record was an animation and none named its sources before
                // this build, so an older store carries nothing into the column
                // or the table; the probes prove the ALTER and the CREATE TABLE
                // above landed, and a same-named grounding table of another
                // shape rolls the migration back. DDL only; no row is read.
                try query("SELECT kind FROM global_artifacts LIMIT 0") { _ in }
                try query("SELECT artifact_id, source_id, linked_at FROM global_artifact_source_links LIMIT 0") { _ in }
            }
            if currentVersion < 118 {
                // Every call an older store recorded went through the proxy,
                // so the default 0 is the truth about all of them and nothing
                // is read or rewritten here; the probe only proves the ALTER
                // above landed before the version stamp commits.
                try query("SELECT own_key FROM ai_usage_events LIMIT 0") { _ in }
            }
            if currentVersion < 119 {
                // No store had a bout before this build, so the table lands
                // empty and nothing is read or rewritten; the probe only
                // proves the CREATE TABLE above landed before the version
                // stamp commits, and a same-named table of another shape
                // rolls the migration back.
                try query("""
                    SELECT id, day_plan_id, block_id, title, notebook_id, source_ids, planned_minutes,
                           started_at, ended_at, learned, unclear, written_at,
                           break_minutes, break_started_at, break_ended_at, abandoned_at,
                           created_at, updated_at
                    FROM learning_bouts LIMIT 0
                """) { _ in }
            }
            if currentVersion < 120 {
                // Until this build, "no parent" was the whole definition of a
                // Notebook, so every parentless companion record in an older
                // store is one — whatever end_at the app happened to stamp on
                // it (`createNotebookContext` wrote today + 30 days, which no
                // Notebook surface ever read). From here the deadline is what
                // tells a Goal from a Notebook, so those records have to say
                // open-ended out loud or the learner's Notebooks would reappear
                // as overdue Goals. One set-based UPDATE; nested Goals, which
                // carry a real deadline and a parent, are untouched.
                //
                // The promoted rows are queued for sync as well: CloudKit still
                // holds their dated end_at, and a Mac that later syncs from an
                // empty store would otherwise read every old Notebook back as a
                // Goal due last month. The rows are the learner's Notebooks — a
                // handful, bounded by what they set up, never by the library —
                // so naming each is bounded work, not a scan.
                //
                // Only rows from before Goals shipped, though. A Mac still on
                // an older build keeps syncing while another moves on, and a
                // Goal set on the newer one — parentless, companion, dated —
                // lands in the old store looking exactly like a Notebook. On
                // 2026-09-19 a second Mac's first launch of build 115 promoted
                // four Goals set that morning, pushed the promotion, and the
                // Mac that set them read them back as Notebooks with no
                // deadline left to recover. `created_at` tells the two apart:
                // no build wrote a dated parentless Goal before `goalsShippedAt`,
                // so a row created since is read by the new rule wherever it
                // came from, and only the older rows are the Notebooks this
                // step exists for.
                let sentinel = LearningGoalRecord.openEndedEndAt.timeIntervalSinceReferenceDate
                let goalsShippedAt = Self.goalsShippedAt.timeIntervalSinceReferenceDate
                let promotedWhere = """
                     WHERE kind = '\(LearningGoalRecord.companionKind)'
                       AND (parent_notebook_id IS NULL OR TRIM(parent_notebook_id) = '')
                       AND end_at < \(sentinel)
                       AND created_at < \(goalsShippedAt)
                """
                var promoted: [String] = []
                try query("SELECT id FROM learning_goals" + promotedWhere) { stmt in
                    if let id = string(stmt, 0) { promoted.append(id) }
                }
                let promotedAt = Date()
                try exec("""
                    UPDATE learning_goals
                       SET end_at = \(sentinel),
                           updated_at = \(promotedAt.timeIntervalSinceReferenceDate)
                """ + promotedWhere)
                for id in promoted {
                    try upsertSyncSave(entity: .learningGoal, logicalKey: id, at: promotedAt)
                }
                // The probe proves the ALTER above landed before the stamp
                // commits; no block named a Goal before, so nothing is read.
                try query("SELECT goal_id FROM time_blocks LIMIT 0") { _ in }
            }
            if currentVersion < 121 {
                // No Goal named an artifact before this build, so an older
                // store carries nothing into the column; the probe proves the
                // ALTER above landed. DDL only, no row is read.
                try query("SELECT artifact_id FROM learning_goals LIMIT 0") { _ in }
            }
            if currentVersion < 122 {
                // No paper had a walkthrough before this build, so the table
                // lands empty and nothing is read or rewritten; the probe
                // proves the CREATE TABLE above landed before the stamp, and
                // a same-named table of another shape rolls the migration back.
                try query("""
                    SELECT source_id, source_sha256, walkthrough_json, walkthrough_version, generated_at
                    FROM source_walkthroughs LIMIT 0
                """) { _ in }
            }
            if currentVersion < 123 {
                // Every block an older store holds is work — nothing about a
                // block said what kind of hour it was — which is the column's
                // default, so nothing is backfilled and nothing is read. The
                // probe proves the ALTER above landed before the stamp.
                try query("SELECT purpose FROM time_blocks LIMIT 0") { _ in }
            }
            if currentVersion < 124 {
                // No animation had a walkthrough before this build, so the
                // table lands empty and nothing is read or rewritten; the
                // probe proves the CREATE TABLE above landed before the stamp,
                // and a same-named table of another shape rolls the
                // migration back.
                try query("""
                    SELECT artifact_id, artifact_sha256, walkthrough_json, walkthrough_version, generated_at
                    FROM artifact_walkthroughs LIMIT 0
                """) { _ in }
            }
            if currentVersion < 125 {
                // No Goal was placed by hand before this build, so an older
                // store carries nothing into the column and every row reads
                // by deadline as it did; the probe proves the ALTER above
                // landed before the stamp. DDL only, no row is read.
                try query("SELECT sort_order FROM learning_goals LIMIT 0") { _ in }
            }
            if currentVersion < 126 {
                // No Idea existed before this build, so both tables land empty
                // and nothing is read or rewritten; the probes prove the two
                // CREATE TABLEs above landed before the stamp, and a same-named
                // table of another shape rolls the migration back.
                try query("SELECT id, title, notes, status, created_at, updated_at FROM ideas LIMIT 0") { _ in }
                try query("SELECT idea_id, kind, target_id, added_at FROM idea_links LIMIT 0") { _ in }
            }
            if currentVersion < 127 {
                // No day had been closed before this build, so both tables
                // land empty and nothing is read or rewritten; the probes
                // prove the two CREATE TABLEs above landed before the stamp,
                // and a same-named table of another shape rolls the
                // migration back.
                try query("SELECT id, watermark, last_run_at FROM memory_day_close_state LIMIT 0") { _ in }
                try query("SELECT session_id, through_sequence, consolidated_at, source_count FROM chat_consolidations LIMIT 0") { _ in }
            }
            if currentVersion < 128 {
                // The probe proves the ALTER (or the CREATE TABLE above)
                // landed. Then the one bounded write: a block a Google or
                // Apple calendar drew had its notes written by that import —
                // the event's conference link or room — and by nothing else,
                // so they move to the column that is theirs and the notes
                // fall free for the learner. A meeting-series occurrence
                // (`meeting:`) never had import-written notes, and a
                // hand-drawn block has no event; both are left alone. Rows
                // already carrying a location — synced in from a newer
                // client — keep it. Tens of rows per day, no source read.
                try query("SELECT location FROM time_blocks LIMIT 0") { _ in }
                try exec("""
                    UPDATE time_blocks
                    SET location = notes, notes = NULL
                    WHERE calendar_event_id IS NOT NULL
                      AND (calendar_event_id LIKE 'google:%' OR calendar_event_id LIKE 'apple:%')
                      AND notes IS NOT NULL AND notes <> ''
                      AND location IS NULL
                """)
            }
            if currentVersion < 131 {
                // Lessons folded into walkthroughs (2026-09-23). Only a store
                // that reached 130 has the table; its rows — a Dev build's
                // day of lessons at most — become their sources' walkthroughs,
                // the lesson artifacts are archived, and the table goes.
                try adoptLessonsAsWalkthroughs()
            }
            if currentVersion < 132 {
                // Cleaner v19 (2026-09-23): a paper is cleaned from its full
                // PDF, never from a copy an older build cut at 50,000
                // characters, and a deletion-only second read restores
                // anything the plan took that is not noise. Sections printed
                // after the references, such as STAR★Methods, stay. Only ids
                // are staged; the post-launch drain does the extraction and
                // the model calls.
                queuedCanonicalCleanupCount = try enqueueHistoricalCanonicalContentCleanup(
                    reason: "Source clean-up v19 (papers cleaned from their full PDF)",
                    affectedSources: .unknown(
                        because: "v19 shipped before a bump had to name its sources; the store cannot tell which papers held a cut extraction"
                    )
                )
            }
            if currentVersion < 133 {
                // A walk's own progress record (2026-09-23): an empty table,
                // proved before the stamp; nothing is backfilled.
                try query("SELECT subject_id, progress_json, updated_at FROM walkthrough_progress LIMIT 0") { _ in }
            }
            if currentVersion < 134 {
                // Text that SQLite truncated at a U+0000 (2026-09-23): stage
                // every preparation id for the integrity audit. Ids only; the
                // drain does the hashing.
                queuedContentIntegrityAuditCount = try enqueueCanonicalContentIntegrityAudit()
            }
            if currentVersion < 135 {
                // Spend control for background AI (2026-09-24): the two
                // bulk-hold tables, created above, proved before the stamp.
                try query("SELECT id, queue, reason, created_at, status, decided_at FROM background_ai_bulk_jobs LIMIT 0") { _ in }
                try query("SELECT job_id, source_id, affected, held_at FROM background_ai_bulk_job_sources LIMIT 0") { _ in }
            }
            if currentVersion < 136 {
                // The learner's chat skills (2026-09-24): the table, created
                // above, proved before the stamp. Nothing is backfilled.
                try query("SELECT id, name, description, instructions, created_at, updated_at FROM skills LIMIT 0") { _ in }
            }
            if currentVersion < 137 {
                // Family plans (2026-09-25): the column, added above, proved
                // before the stamp. Nothing is backfilled.
                try query("SELECT family_plan_code FROM teams LIMIT 0") { _ in }
            }
            if currentVersion < 138 {
                // Course quizzes (2026-09-26): the table, created above,
                // proved before the stamp. Nothing is backfilled.
                try query("SELECT id, course_id, kind, title, lecture_ids_json, after_lecture_id, questions_json, author, created_at, updated_at FROM course_quizzes LIMIT 0") { _ in }
            }
            if currentVersion < 139 {
                // A mark's linked chat (2026-09-26): the column, added above,
                // proved before the stamp. Nothing is backfilled.
                try query("SELECT chat_session_id FROM source_highlights LIMIT 0") { _ in }
            }
            if currentVersion < 140 {
                // A mark's cited papers (2026-09-26): the column, added above,
                // proved before the stamp. Nothing is backfilled.
                try query("SELECT references_json FROM source_highlights LIMIT 0") { _ in }
            }
            if currentVersion < 141 {
                // A mark's since-publication update (2026-09-26): the columns,
                // added above, proved before the stamp. Nothing is backfilled.
                try query("SELECT publication_update, publication_update_at FROM source_highlights LIMIT 0") { _ in }
            }
            if currentVersion < 142 {
                // A course quiz's symbol and picture (2026-09-26): the
                // columns, added above, proved before the stamp. Nothing is
                // backfilled.
                try query("SELECT symbol, artwork FROM course_quizzes LIMIT 0") { _ in }
            }
            if currentVersion < 143 {
                // Titles are plain text (2026-09-27): the stored titles a
                // catalog wrote with inline markup take the fold new ones get.
                // Only rows whose title holds a `<` are read.
                foldedTitleMarkupCount = try foldStoredSourceTitleMarkup()
            }
            if currentVersion < 144 {
                // An author is a name (2026-09-27): the stored ones that are
                // markup or a web address are cleared. Only author cells that
                // could fail the rule are read.
                clearedImplausibleAuthorCount = try clearStoredImplausibleSourceAuthors()
                // A paper's title against its DOI's registered one: the queue,
                // created above, proved before the stamp, then every paper
                // with a DOI staged for the post-launch check. Ids only.
                try query("SELECT source_id, enqueued_at, attempt_count, last_error FROM paper_registered_title_queue LIMIT 0") { _ in }
                queuedRegisteredTitleCheckCount = try enqueueRegisteredPaperTitleChecks()
            }
            if currentVersion < 145 {
                // A course shared with a team (2026-09-27): the column,
                // added above, proved before the stamp. Nothing is backfilled.
                try query("SELECT team_id FROM courses LIMIT 0") { _ in }
            }
            if currentVersion < 146 {
                // A scheduled task's failed run tried again (2026-09-27): the
                // columns, added above, proved before the stamp. Nothing is
                // backfilled; the default is every old receipt's truth.
                try query("SELECT attempt, retry_at FROM scheduled_task_runs LIMIT 0") { _ in }
            }
            if currentVersion < 147 {
                // No Direction existed before this build, so the table lands
                // empty and nothing is read or rewritten; the probe proves the
                // CREATE TABLE above landed before the stamp, and a same-named
                // table of another shape rolls the migration back.
                try query("""
                    SELECT id, home_kind, home_id, title, rationale, angle, evidence_json,
                           objection, next_step, status, verdict_reason, chat_session_id,
                           created_at, updated_at, decided_at
                    FROM research_directions LIMIT 0
                """) { _ in }
            }
            if currentVersion < 148 {
                // A formatted YouTube transcript against its captions: the
                // queue, created above, proved before the stamp, then every
                // personal YouTube video staged for the post-launch check.
                // Ids only.
                try query("SELECT source_id, enqueued_at, attempt_count, last_error FROM youtube_transcript_check_queue LIMIT 0") { _ in }
                queuedYouTubeTranscriptCheckCount = try enqueueYouTubeTranscriptChecks()
            }
            if currentVersion < 149 {
                // A chat's effort and speed (2026-09-28): the columns, added
                // above, proved before the stamp. Nothing is backfilled; NULL
                // is every existing chat's truth.
                try query("SELECT model_effort, model_speed FROM review_sessions LIMIT 0") { _ in }
            }
            if currentVersion < 150 {
                // A course's notebook (2026-10-01): the column and its index,
                // added above, proved before the stamp. Nothing is backfilled;
                // homing a course is the learner's act.
                try query("SELECT home_notebook_id FROM courses LIMIT 0") { _ in }
            }
            if currentVersion < 152 {
                // A team notebook's approval (2026-10-02): the team Notebooks
                // whose pending or rejected items never reached the team are
                // staged for one republish. Set-based, metadata only.
                stagedTeamApprovalRepublishCount = try stageTeamNotebookApprovalRepublish()
            }
            if currentVersion < 153 {
                // What still points at a merged-away or split-away notebook
                // (2026-10-02): released set-based, the records republished.
                // Bounded by the dangling rows; no DDL.
                releasedDeletedNotebookLinks = try releaseLinksToDeletedNotebooks()
            }
            if currentVersion < 154, laysDownSchema154 {
                // The schema-v2 local store (2026-10-03): the ck_* tables are
                // created above, empty, and the wire columns were added with
                // the rest. The per-member tables lose their foreign keys to
                // content, row for row; then every new shape is proved before
                // the stamp. Nothing is filled and no trigger is created.
                rebuiltPerMemberRows = try rebuildPerMemberTablesWithoutContentForeignKeys()
                try probeSchema154()
            }
            if currentVersion < 155, laysDownSchema154 {
                // The Source and Collection records' tables (2026-10-03), created
                // above, empty; proved before the stamp. Nothing is filled.
                try probeSchema155()
            }
            if currentVersion < 156, laysDownSchema154 {
                // The notebook records' tables (2026-10-04), created above,
                // empty, and the back-pointer view, made here after 154's
                // rebuild of a table it reads; proved before the stamp.
                // Nothing is filled.
                try createNotebookChildrenView()
                try probeSchema156()
            }
            if currentVersion < 157, laysDownSchema154 {
                // The course records' columns and table (2026-10-04), added
                // above, empty; the back-pointer view made again without the
                // course home 2026-10-03 retired; proved before the stamp.
                // Nothing is filled.
                try exec("DROP VIEW IF EXISTS ck_notebook_children")
                try createNotebookChildrenView()
                try probeSchema157()
            }
            if currentVersion < 158, laysDownSchema154 {
                // The Chat and Exchange records' columns (2026-10-04), added
                // with the rest, NULL; proved before the stamp. Nothing is
                // filled.
                try probeSchema158()
            }
            if currentVersion < 159, laysDownSchema154 {
                // The Artifact records' tables and the body pointer (2026-10-04),
                // created above, empty; proved before the stamp. Nothing is
                // filled.
                try probeSchema159()
            }
            if currentVersion < Self.readingSchemaVersion, laysDownSchema154 {
                // The member's reading state (2026-10-04), created above,
                // empty; proved before the stamp. Nothing is filled.
                try probeReadingSchema()
            }
            if currentVersion < Self.memorySchemaVersion, laysDownSchema154 {
                // The memory records' tables (2026-10-04), created above,
                // empty; proved before the stamp. Nothing is filled.
                try probeMemorySchema()
            }
            if currentVersion < Self.tasksSchemaVersion, laysDownSchema154 {
                // The Task, Job and Automation records' table and columns
                // (2026-10-04), added above, empty; proved before the stamp.
                // Nothing is filled.
                try probeTasksSchema()
            }
            if currentVersion < Self.personalStateSchemaVersion, laysDownSchema154 {
                // The Device record's and the import-blocked shows' tables
                // (2026-10-04), created above, empty; proved before the
                // stamp. Nothing is filled.
                try probePersonalStateSchema()
            }
            if currentVersion < 166, laysDownSchema154 {
                // Soft hyphens left in stored text (2026-10-06): the queue,
                // created above, proved before the stamp, then every source of
                // the learner's own library staged for the post-launch repair.
                // Ids only; no text is read.
                try query("SELECT source_id, enqueued_at FROM source_text_soft_hyphen_repair_queue LIMIT 0") { _ in }
                queuedSoftHyphenRepairCount = try enqueueStoredSoftHyphenRepair()
            }
            if currentVersion < 167, laysDownSchema154 {
                // Podcast transcripts still cut at the retired cap
                // (2026-10-06): the audit's table and the queue's retry time,
                // created and added above, proved before the stamp; then every
                // episode the new test can measure is queued for it, whatever
                // schema 85's marker said. Ids only; no transcript or TTML is
                // read. Like every step from 154 on, it waits with 154 on a
                // store held below it: such a store stays stamped 153, and
                // queueing on each of its launches would start every pending
                // episode's attempts, and its wait for Apple, over again.
                try query("""
                    SELECT source_id, ttml_sha256, outcome, audited_at
                    FROM podcast_transcript_audits LIMIT 0
                """) { _ in }
                try query("""
                    SELECT source_id, enqueued_at, attempt_count, last_error, retry_after
                    FROM podcast_transcript_detruncation_queue LIMIT 0
                """) { _ in }
                queuedPodcastDetruncationCount = try enqueuePodcastTranscriptCompletenessAudit()
            }
            if currentVersion < Self.sourceFTSRowsSchemaVersion {
                // Where each full-text row is (2026-10-06): the map, created
                // above, empty and proved before the stamp, and one row
                // staging the record of the rows already written, which
                // happens after launch. No full-text row is read. Not held
                // with 154: this build's full-text writes read the map.
                try enqueueSourceFTSRowBackfill()
                try probeSourceFTSRowTables()
            }
            if currentVersion < Self.bookFilesSchemaVersion {
                // A PDF book is one file (2026-10-12): the chapters' page
                // columns, added above, and the merge queue, created above,
                // proved before the stamp; then every book with a chapter that
                // is a PDF file queued for the merge after launch. Ids only;
                // no file is read.
                try probeBookFileSchema()
                queuedSplitBookMergeCount = try enqueueSplitBookMerge()
            }
            if currentVersion < Self.epubBookFilesSchemaVersion {
                // An EPUB book is one file (2026-10-12): every book still
                // unpacked joins the queue above, to be packed after launch.
                // Ids only; no file is read.
                let before = try scalarInteger("SELECT COUNT(*) FROM book_file_merge_queue") ?? 0
                queuedUnpackedEPUBBookCount = try enqueueUnpackedEPUBBooks() - Int(before)
            }
            // Preparing the projection catches an older, structurally incompatible
            // table before the version stamp commits. The transaction then rolls
            // back completely instead of leaving a half-migrated store.
            try query("SELECT * FROM source_projection LIMIT 0") { _ in }
        } else {
            // WAL is persistent database configuration, so set it once for a new
            // database rather than issuing journal-mode writes on every launch.
            try exec("PRAGMA journal_mode = WAL")
        }

        // The version is the last write in the migration transaction. A failure
        // anywhere above leaves the old version and schema intact.
        try exec("PRAGMA user_version = \(stampedVersion)")
        if isMigration {
            try exec("COMMIT")
            migrationNeedsRollback = false
            logger.notice(
                "Migrated knowledge database schema from \(currentVersion) to \(stampedVersion)"
            )
            if reactivatedCourseSourceCount > 0 {
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if republishedVideoProgressCount > 0 {
                logger.notice(
                    "Queued \(republishedVideoProgressCount) video watch-progress source(s) for CloudKit republish"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if queuedPaperFigureMarkdownRepairCount > 0 {
                logger.notice(
                    "Queued \(queuedPaperFigureMarkdownRepairCount) source(s) to strip stale figure image links"
                )
            }
            if migratedPaperIngestionCount > 0 {
                logger.notice(
                    "Migrated and queued \(migratedPaperIngestionCount) paper ingestion attestation(s) for CloudKit republish"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if hiddenCourselessCourseSourceCount > 0 {
                logger.notice(
                    "Hid \(hiddenCourselessCourseSourceCount) course source(s) attached to no course and queued them for CloudKit republish"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if adoptedHiddenItemCount > 0 {
                logger.notice(
                    "Moved \(adoptedHiddenItemCount) hidden doc(s) and chat(s) into the synced hidden tables and queued them for CloudKit"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if queuedPodcastTranscriptCleanupCount > 0 {
                logger.notice(
                    "Queued \(queuedPodcastTranscriptCleanupCount) visible podcast transcript(s) for ad cleanup"
                )
            }
            if queuedZoomRecordingCount > 0 {
                logger.notice(
                    "Queued \(queuedZoomRecordingCount) Zoom recording(s) for meeting adoption"
                )
            }
            if restoredCourseMaterialCount > 0 {
                logger.notice(
                    "Restored and queued \(restoredCourseMaterialCount) course material source(s) for CloudKit republish"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if migratedModelPreferenceCount > 0 {
                logger.notice(
                    "Persisted and queued \(migratedModelPreferenceCount) model setting(s) for CloudKit republish"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if queuedPodcastDetruncationCount > 0 {
                logger.notice(
                    "Queued \(queuedPodcastDetruncationCount) podcast transcript(s) for the completeness audit against their episode's TTML"
                )
            }
            if demotedPodcastPageTextCount > 0 {
                logger.notice(
                    "Queued \(demotedPodcastPageTextCount) podcast episode(s) whose stored text was an episode page rather than a transcript"
                )
            }
            if migratedMeetingFolderImageCount > 0 {
                logger.notice(
                    "Persisted and queued \(migratedMeetingFolderImageCount) meeting folder image(s) for CloudKit republish"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if republishedDismissedArchiveCount > 0 {
                logger.notice(
                    "Queued \(republishedDismissedArchiveCount) dismissal-archived source(s) for CloudKit republish"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if adoptedDisplayPreferenceCount > 0 {
                logger.info(
                    "Adopted \(adoptedDisplayPreferenceCount) display preference(s) into the synced store"
                )
            }
            if queuedCanonicalCleanupCount > 0 {
                logger.notice(
                    "Queued \(queuedCanonicalCleanupCount) historical paper/article source(s) for canonical content cleanup"
                )
            }
            if queuedContentIntegrityAuditCount > 0 {
                logger.notice(
                    "Queued \(queuedContentIntegrityAuditCount) paper/article preparation(s) for the stored-text integrity audit"
                )
            }
            if queuedArticleChromeRefilterCount > 0 {
                logger.notice(
                    "Queued \(queuedArticleChromeRefilterCount) archived article(s) to refilter site chrome from their reader documents"
                )
            }
            if queuedReviewGuideCount > 0 {
                logger.notice(
                    "Queued \(queuedReviewGuideCount) source(s) for review-guide preparation"
                )
            }
            if cancelledReviewGuideCount > 0 {
                logger.notice(
                    "Cancelled \(cancelledReviewGuideCount) queued review-guide preparation(s); guides are now prepared when a review starts"
                )
            }
            if queuedPaperMetadataRepublishCount > 0 {
                logger.notice(
                    "Staged \(queuedPaperMetadataRepublishCount) attested paper source(s) for deferred CloudKit metadata repair"
                )
            }
            if foldedTitleMarkupCount > 0 {
                logger.notice(
                    "Folded the inline markup out of \(foldedTitleMarkupCount) source title(s) and staged them for deferred CloudKit republish"
                )
            }
            if clearedImplausibleAuthorCount > 0 {
                logger.notice(
                    "Cleared \(clearedImplausibleAuthorCount) stored author(s) that were markup or a web address, not a name, and staged them for deferred CloudKit republish"
                )
            }
            if queuedRegisteredTitleCheckCount > 0 {
                logger.notice(
                    "Queued \(queuedRegisteredTitleCheckCount) paper(s) with a DOI to check their titles against the registered ones"
                )
            }
            if queuedYouTubeTranscriptCheckCount > 0 {
                logger.notice(
                    "Queued \(queuedYouTubeTranscriptCheckCount) YouTube video(s) to check their stored transcripts against their captions"
                )
            }
            if queuedSoftHyphenRepairCount > 0 {
                logger.notice(
                    "Queued \(queuedSoftHyphenRepairCount) source(s) to check their stored text for soft hyphens"
                )
            }
            if queuedSplitBookMergeCount > 0 {
                logger.notice(
                    "Queued \(queuedSplitBookMergeCount) PDF book(s) to put back into one file"
                )
            }
            if queuedUnpackedEPUBBookCount > 0 {
                logger.notice(
                    "Queued \(queuedUnpackedEPUBBookCount) EPUB book(s) to pack back into one file"
                )
            }
            if stagedTeamApprovalRepublishCount > 0 {
                logger.notice(
                    "Staged \(stagedTeamApprovalRepublishCount) team Notebook(s) for CloudKit republish so their pending and rejected sources reach the team"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if queuedSourcePDFAssetRepublishCount > 0 {
                logger.notice(
                    "Staged \(queuedSourcePDFAssetRepublishCount) recorded PDF source(s) for deferred CloudKit asset repair"
                )
            }
            if queuedTextlessSourceReingestionCount > 0 {
                logger.notice(
                    "Requeued \(queuedTextlessSourceReingestionCount) textless ready source(s) for ingestion and deferred CloudKit repair"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if attributedRealtimeUsageCount > 0 {
                logger.notice(
                    "Named the originating device on \(attributedRealtimeUsageCount) realtime-voice usage row(s)"
                )
            }
            if retiredSlackSourceCount > 0 {
                logger.notice(
                    "Retired \(retiredSlackSourceCount) saved Slack thread(s); Slack is read live through the plugin"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if queuedPaperFigureIndexCount > 0 {
                logger.notice(
                    "Queued \(queuedPaperFigureIndexCount) paper PDF(s) for deferred figure indexing"
                )
            }
            if queuedListenableContentCount > 0 {
                logger.notice(
                    "Queued \(queuedListenableContentCount) paper/article source(s) for listenable-content preparation"
                )
            }
            if retiredIneligibleListenableContentCount > 0 {
                logger.notice(
                    "Retired \(retiredIneligibleListenableContentCount) non-paper/article listenable-content job(s)"
                )
            }
            if requeuedPaperListenableContentCount > 0 {
                logger.notice(
                    "Requeued \(requeuedPaperListenableContentCount) paper listenable-content derivative(s) for sidebar ordering"
                )
            }
            if requeuedStalePaperListenableContentCount > 0 {
                logger.notice(
                    "Requeued \(requeuedStalePaperListenableContentCount) cleaned paper narration derivative(s) with stale contracts"
                )
            }
            if queuedUnattestedListenableContentCount > 0 {
                logger.notice(
                    "Queued \(queuedUnattestedListenableContentCount) source(s) whose narration was withheld by a failed ingestion gate"
                )
            }
            if queuedTextReferenceRepairCount > 0 {
                logger.notice(
                    "Staged \(queuedTextReferenceRepairCount) source(s) whose stored text still holds HTML character references"
                )
            }
            if repairedOrphanedAssetStagingCount > 0 {
                logger.notice(
                    "Cleared \(repairedOrphanedAssetStagingCount) orphaned CloudKit asset staging row(s)"
                )
            }
            if !rebuiltPerMemberRows.isEmpty {
                logger.notice(
                    "Rebuilt \(rebuiltPerMemberRows.count) per-member table(s) without foreign keys to content, keeping all \(rebuiltPerMemberRows.values.reduce(0, +)) row(s)"
                )
            }
            if releasedDeletedNotebookLinks.republished > 0 {
                logger.notice(
                    "Released \(releasedDeletedNotebookLinks.republished) record(s) still linked to \(releasedDeletedNotebookLinks.deletedNotebooks) deleted notebook(s) and queued them for CloudKit"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            if republishedArchivedSourceCount > 0 || removedArchivedGoalLinkCount > 0 {
                logger.notice(
                    "Repaired archived-source sync state: queued \(republishedArchivedSourceCount) source(s), removed \(removedArchivedGoalLinkCount) stale Notebook link(s)"
                )
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
        }
    }

    /// Version 43 stages the second source derivative without reading or hashing
    /// library content in the migration transaction. Paper/article rows still
    /// awaiting canonical cleanup are deliberately skipped; that cleanup commit
    /// enqueues them against the final canonical text.
    private func enqueueHistoricalListenableContentPreparation() throws -> Int {
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO source_listenable_content_queue
                (source_id, target_version, source_sha256, enqueued_at, attempt_count, last_error)
            SELECT s.id, ?, NULL, ?, 0, NULL
            FROM sources s
            JOIN source_content sc ON sc.source_id = s.id
            WHERE s.state = 'ready'
              AND s.status = 'active'
              AND s.source_type IN ('article', 'paper')
              AND TRIM(sc.content) != ''
              AND NOT EXISTS (
                  SELECT 1 FROM canonical_content_cleanup_queue cq WHERE cq.source_id = s.id
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM source_listenable_content lc
                  WHERE lc.source_id = s.id
                    AND lc.generator_version >= ?
              )
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                enqueued_at = excluded.enqueued_at
        """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(SourceListenableContentMetadata.currentVersion))
            sqlite3_bind_double(stmt, 2, enqueuedAt)
            sqlite3_bind_int(stmt, 3, Int32(SourceListenableContentMetadata.currentVersion))
        }
        var count = 0
        try query("SELECT COUNT(*) FROM source_listenable_content_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Version 44 narrows generated listen-ready derivatives to the two source
    /// types whose extracted layout routinely needs narration preparation.
    /// Completed derivatives are harmless and remain available; only local,
    /// pending work is retired. The set-based delete scans the bounded queue once
    /// and resolves each source through the sources primary-key index.
    /// Version 92 retires Slack as a source type. A saved thread was a snapshot
    /// taken by hand, and a chat that found one believed it had checked Slack;
    /// the channel itself is read live through `read_slack_channel`, so nothing
    /// in the library should answer to "Slack" any more.
    ///
    /// Each saved thread goes through the same row-level delete a learner's own
    /// removal takes, so its embeddings, highlights, Schedule placements and
    /// CloudKit tombstones are handled exactly as they would be for any other
    /// source and the deletion reaches every device. The loop is bounded by the
    /// number of Slack sources, which only ever arrived one at a time through
    /// one assistant tool — a handful in the largest real library — never by
    /// the size of the library. The per-type table follows once it is empty.
    private func retireSlackSources() throws -> Int {
        var slackSourceIDs: [String] = []
        try query("SELECT id FROM sources WHERE source_type = 'slack'") { stmt in
            if let id = self.string(stmt, 0) { slackSourceIDs.append(id) }
        }
        for sourceID in slackSourceIDs {
            try deleteSourceRows(sourceID)
        }
        try exec("DROP INDEX IF EXISTS idx_slack_messages_normalized_url")
        try exec("DROP TABLE IF EXISTS slack_messages")
        return slackSourceIDs.count
    }

    private func retireIneligibleListenableContentPreparation() throws -> Int {
        try exec("""
            DELETE FROM source_listenable_content_queue
            WHERE NOT EXISTS (
                SELECT 1
                FROM sources s
                WHERE s.id = source_listenable_content_queue.source_id
                  AND s.source_type IN ('article', 'paper')
            )
        """)
        return Int(sqlite3_changes(db))
    }

    /// Version 45 regenerates paper-only speech derivatives after the narration
    /// contract gained validated sidebar relocation. Existing derivatives stay
    /// readable until their queued replacement commits, so launch never hides
    /// sources or blocks on content-sized AI work.
    private func requeuePaperListenableContentForSidebarOrdering() throws -> Int {
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO source_listenable_content_queue
                (source_id, target_version, source_sha256, enqueued_at, attempt_count, last_error)
            SELECT s.id, ?, NULL, ?, 0, NULL
            FROM sources s
            JOIN source_content sc ON sc.source_id = s.id
            WHERE s.state = 'ready'
              AND s.status = 'active'
              AND s.source_type = 'paper'
              AND NOT EXISTS (
                  SELECT 1 FROM canonical_content_cleanup_queue cq WHERE cq.source_id = s.id
              )
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                source_sha256 = NULL,
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL
        """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(SourceListenableContentMetadata.currentVersion))
            sqlite3_bind_double(stmt, 2, enqueuedAt)
        }
        return Int(sqlite3_changes(db))
    }

    /// Version 56 closes the case where cleanup v18 preserved the canonical
    /// bytes exactly. Hash-bound invalidation correctly kept the existing
    /// derivative, but a stale narration contract is still unsuitable for the
    /// current iOS reader. This is a bounded, set-based queue repair: no source
    /// body is read or hashed during migration, and papers still awaiting
    /// canonical cleanup remain gated behind that first stage.
    private func enqueueStaleCleanedPaperListenableContentPreparation() throws -> Int {
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO source_listenable_content_queue
                (source_id, target_version, source_sha256, enqueued_at, attempt_count, last_error)
            SELECT s.id, ?, pp.clean_sha256, ?, 0, NULL
            FROM sources s
            JOIN source_content sc ON sc.source_id = s.id
            JOIN paper_content_preparations pp ON pp.source_id = s.id
            LEFT JOIN source_listenable_content l ON l.source_id = s.id
            WHERE s.state = 'ready'
              AND s.status = 'active'
              AND s.source_type = 'paper'
              AND TRIM(sc.content) != ''
              AND pp.cleaner_version >= ?
              AND pp.clean_sha256 IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM canonical_content_cleanup_queue cq WHERE cq.source_id = s.id
              )
              AND (
                    l.source_id IS NULL
                 OR l.source_sha256 != pp.clean_sha256
                 OR l.generator_version != ?
                 OR COALESCE(l.preparation_signature, '') NOT LIKE ?
              )
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                source_sha256 = excluded.source_sha256,
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL
        """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(SourceListenableContentMetadata.currentVersion))
            sqlite3_bind_double(stmt, 2, enqueuedAt)
            sqlite3_bind_int(stmt, 3, Int32(PaperContentPreparationMetadata.currentVersion))
            sqlite3_bind_int(stmt, 4, Int32(SourceListenableContentMetadata.currentVersion))
            bind(stmt, 5, "\(PaperNarrationFilter.preparationContractPrefix)%")
        }
        return Int(sqlite3_changes(db))
    }

    /// Version 65 stages the sources the old `state = 'ready'` narration gate
    /// stranded. A paper that failed the metadata gate — an unsigned editorial,
    /// a paywalled record the learner attached a PDF to — still has canonical
    /// text, but its narration was never queued, so iOS listed it, offered
    /// Listen, and could only answer that the source was still preparing.
    ///
    /// Set-based and bounded like its predecessors: no source body is read or
    /// hashed here, and anything still awaiting canonical cleanup stays gated
    /// behind that first stage, which enqueues narration when it commits.
    private func enqueueUnattestedListenableContentPreparation() throws -> Int {
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO source_listenable_content_queue
                (source_id, target_version, source_sha256, enqueued_at, attempt_count, last_error)
            SELECT s.id, ?, NULL, ?, 0, NULL
            FROM sources s
            JOIN source_content sc ON sc.source_id = s.id
            WHERE s.state = 'error'
              AND s.status = 'active'
              AND s.source_type IN ('article', 'paper')
              AND TRIM(sc.content) != ''
              AND NOT EXISTS (
                  SELECT 1 FROM canonical_content_cleanup_queue cq WHERE cq.source_id = s.id
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM source_listenable_content lc
                  WHERE lc.source_id = s.id
                    AND lc.generator_version >= ?
              )
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                enqueued_at = excluded.enqueued_at
        """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(SourceListenableContentMetadata.currentVersion))
            sqlite3_bind_double(stmt, 2, enqueuedAt)
            sqlite3_bind_int(stmt, 3, Int32(SourceListenableContentMetadata.currentVersion))
        }
        return Int(sqlite3_changes(db))
    }

    /// Version 37 restores the core source contract: a `.ready` source has
    /// durable readable text. Version 10 grandfathered historical papers from
    /// metadata alone, leaving records that appeared in CarPlay but had no
    /// `sourceContentAsset` to load. Version 36 first repaired those records,
    /// but an older client could still sync a stale `ready` state into a store
    /// after that one-time migration had committed. Repeating the repair at 37
    /// closes that upgrade window; current CloudKit imports enforce the same
    /// invariant continuously.
    ///
    /// The migration only performs indexed, set-based metadata changes. Actual
    /// PDF/page retrieval, parsing, cleanup, AI calls, and CloudKit publication
    /// happen after launch through the existing event-driven ingestion and
    /// bounded `source_sync_repair_queue` drains.
    /// Names the device behind realtime-voice rows the proxy metered before the
    /// app sent device attribution on the control plane.
    ///
    /// Realtime voice bills through `/v1/realtime/usage` and `/v1/realtime/settle`,
    /// which never carried `X-ForeverLM-Platform`, so their authoritative server
    /// rows arrived with no platform while the client row beside them named the
    /// device correctly. A phone's voice sessions were therefore recorded and
    /// billed but absent from the usage pane's iOS filter. Re-fetching the server
    /// ledger cannot repair these — D1 stored the null — so the platform is
    /// adopted from the client row for the same call: same provider, within two
    /// seconds. Rows with no such neighbour keep their null and stay honestly
    /// unattributed.
    private func backfillRealtimeUsagePlatformAttribution() throws -> Int {
        var count = 0
        try query("""
            SELECT COUNT(*)
            FROM ai_usage_events AS server
            WHERE server.server_ledger_id IS NOT NULL
              AND server.client_platform IS NULL
              AND server.task = 'realtime_voice'
              AND EXISTS (
                  SELECT 1
                  FROM ai_usage_events AS client
                  WHERE client.server_ledger_id IS NULL
                    AND client.client_platform IS NOT NULL
                    AND client.operation = 'realtime_voice'
                    AND LOWER(client.provider) = LOWER(server.provider)
                    AND ABS(client.created_at - server.created_at) <= 2.0
              )
        """) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        guard count > 0 else { return 0 }

        try exec("""
            UPDATE ai_usage_events AS server
            SET client_platform = (
                SELECT client.client_platform
                FROM ai_usage_events AS client
                WHERE client.server_ledger_id IS NULL
                  AND client.client_platform IS NOT NULL
                  AND client.operation = 'realtime_voice'
                  AND LOWER(client.provider) = LOWER(server.provider)
                  AND ABS(client.created_at - server.created_at) <= 2.0
                ORDER BY ABS(client.created_at - server.created_at)
                LIMIT 1
            )
            WHERE server.server_ledger_id IS NOT NULL
              AND server.client_platform IS NULL
              AND server.task = 'realtime_voice'
              AND EXISTS (
                  SELECT 1
                  FROM ai_usage_events AS client
                  WHERE client.server_ledger_id IS NULL
                    AND client.client_platform IS NOT NULL
                    AND client.operation = 'realtime_voice'
                    AND LOWER(client.provider) = LOWER(server.provider)
                    AND ABS(client.created_at - server.created_at) <= 2.0
              )
        """)
        return count
    }

    /// Version 68 stages the sources whose stored text still carries HTML
    /// character references — `&ldquo;`, `&#233;`, and the `&amp;` that survived
    /// a single decoding pass over YouTube's doubly escaped timed text.
    ///
    /// The repair has to happen in the data. Reader text is escaped on its way
    /// into the WebView rather than parsed as HTML — deliberately, so a source
    /// can never inject markup — so a stored reference is shown verbatim on
    /// every platform, and decoding at render time would instead mangle an
    /// article that legitimately writes `&nbsp;` out in prose.
    ///
    /// Migration only stages IDs, set-wise. Reading, decoding, and republishing
    /// content is proportional to the library, so it happens in bounded
    /// post-launch batches once the source list is already usable.
    /// Retire `paper_figures.image_path`.
    ///
    /// Pure DDL against one small table: no row is read, rewritten, or counted,
    /// so the cost does not move with the library. The column is dropped rather
    /// than left holding empty strings because a `NOT NULL` column nothing writes
    /// is a standing invitation to start writing it again.
    private func dropPaperFigureImagePathColumn() throws {
        var tableExists = false
        try query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'paper_figures' LIMIT 1"
        ) { _ in
            tableExists = true
        }
        guard tableExists,
              try tableColumnNames("paper_figures").contains("image_path") else { return }
        try exec("ALTER TABLE paper_figures DROP COLUMN image_path")
    }

    /// Stage every source whose canonical text still carries the old
    /// `![caption](file:///…)` figure block.
    ///
    /// The scan is one indexed-free pass over `source_content` doing nothing but
    /// matching two literals — the same shape as the character-reference repair
    /// above, and for the same reason: staging ids is cheap and set-based, while
    /// reading and rewriting the text is proportional to the library and belongs
    /// in bounded post-launch batches once the source list is already usable.
    private func enqueueLegacyPaperFigureMarkdownRepair() throws -> Int {
        try execBind("""
            INSERT INTO paper_figure_markdown_repair_queue (source_id, enqueued_at)
            SELECT sc.source_id, ?
            FROM source_content sc
            WHERE sc.content GLOB '*## Figures*'
              AND sc.content GLOB '*](file://*'
            ON CONFLICT(source_id) DO NOTHING
        """) { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSinceReferenceDate)
        }
        var count = 0
        try query("SELECT COUNT(*) FROM paper_figure_markdown_repair_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    private func enqueueStoredHTMLCharacterReferenceRepair() throws -> Int {
        let now = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO source_text_reference_repair_queue (source_id, enqueued_at)
            SELECT sc.source_id, ?
            FROM source_content sc
            WHERE sc.content GLOB '*&[A-Za-z][A-Za-z]*;*'
               OR sc.content GLOB '*&#[0-9]*;*'
               OR sc.content GLOB '*&#[xX][0-9A-Fa-f]*;*'
            ON CONFLICT(source_id) DO NOTHING
        """) { stmt in
            sqlite3_bind_double(stmt, 1, now)
        }
        var count = 0
        try query("SELECT COUNT(*) FROM source_text_reference_repair_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Demote every `ready` source this device holds no text for, so the local
    /// readability contract is not violated, and let ordinary re-ingestion refill
    /// it after launch.
    ///
    /// Deliberately local. "This device has no text" and "the library has no text"
    /// are indistinguishable here — a fetch that did not carry the content asset
    /// looks exactly like a record published without one — so pushing the demotion
    /// made a second Mac's cold start demote healthy `ready` sources on every other
    /// device and re-run paid cleanup there. Re-ingestion that succeeds publishes
    /// real content through the normal save path, which repairs a genuinely
    /// textless server record without betting the whole library on a guess.
    private func enqueueTextlessReadySourceReingestion() throws -> Int {
        var count = 0
        try query("""
            SELECT COUNT(*)
            FROM sources s
            WHERE s.state = 'ready'
              AND s.status = 'active'
              AND NOT EXISTS (
                  SELECT 1
                  FROM source_content sc
                  WHERE sc.source_id = s.id
                    AND TRIM(sc.content) != ''
              )
        """) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        guard count > 0 else { return 0 }

        try exec("""
            UPDATE sources
            SET state = 'queued', error_message = NULL
            WHERE state = 'ready'
              AND status = 'active'
              AND NOT EXISTS (
                  SELECT 1
                  FROM source_content sc
                  WHERE sc.source_id = sources.id
                    AND TRIM(sc.content) != ''
              )
        """)
        return count
    }

    /// Version 35 restages every stale ready paper for cleanup without reading or
    /// hashing its content in the migration transaction. This closes any legacy
    /// gap before Muse Spark is allowed to see the paper. The tiny date-derived
    /// offset keeps every row in one migration-time batch while letting the
    /// background worker repair recently ingested papers first.
    private func enqueueHistoricalPaperCanonicalContentCleanup() throws -> Int {
        let targetVersion = PaperContentPreparationMetadata.currentVersion
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO canonical_content_cleanup_queue
                (source_id, target_version, enqueued_at, attempt_count, last_error, source_sha256)
            SELECT s.id, ?, ? - (s.date_added * 0.000000001), 0, NULL, NULL
            FROM sources s
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN paper_content_preparations pp ON pp.source_id = s.id
            WHERE s.source_type = 'paper'
              AND s.state = 'ready'
              AND s.status = 'active'
              AND sc.content != ''
              AND COALESCE(pp.cleaner_version, 0) < ?
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL
        """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(targetVersion))
            sqlite3_bind_double(stmt, 2, enqueuedAt)
            sqlite3_bind_int(stmt, 3, Int32(targetVersion))
        }
        var count = 0
        try query("SELECT COUNT(*) FROM canonical_content_cleanup_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Version 114: the hides the retired per-Mac columns recorded become rows
    /// in `hidden_artifacts` and `hidden_review_sessions`, each queued as a
    /// save so every Mac signed into the account learns of them. A store from
    /// before 111 has no such column and nothing to hand over. Bounded by the
    /// number of docs and chats a person hid by hand, never by the library.
    func adoptRetiredHiddenColumns() throws -> Int {
        var adopted = 0
        if try tableColumnNames("global_artifacts").contains("hidden_at") {
            var rows: [(id: String, hiddenAt: Date)] = []
            try query("SELECT id, hidden_at FROM global_artifacts WHERE hidden_at IS NOT NULL") { stmt in
                guard let id = self.string(stmt, 0) else { return }
                rows.append((id, Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))))
            }
            for row in rows {
                try execBind("INSERT INTO hidden_artifacts (artifact_id, hidden_at) VALUES (?, ?) ON CONFLICT(artifact_id) DO UPDATE SET hidden_at = excluded.hidden_at") { stmt in
                    bind(stmt, 1, row.id)
                    sqlite3_bind_double(stmt, 2, row.hiddenAt.timeIntervalSinceReferenceDate)
                }
                try upsertSyncSave(entity: .hiddenArtifact, logicalKey: row.id, at: row.hiddenAt)
                adopted += 1
            }
        }
        if try tableColumnNames("review_sessions").contains("hidden_at") {
            var rows: [(id: String, hiddenAt: Date)] = []
            try query("SELECT id, hidden_at FROM review_sessions WHERE hidden_at IS NOT NULL") { stmt in
                guard let id = self.string(stmt, 0) else { return }
                rows.append((id, Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))))
            }
            for row in rows {
                try execBind("INSERT INTO hidden_review_sessions (session_id, hidden_at) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET hidden_at = excluded.hidden_at") { stmt in
                    bind(stmt, 1, row.id)
                    sqlite3_bind_double(stmt, 2, row.hiddenAt.timeIntervalSinceReferenceDate)
                }
                try upsertSyncSave(entity: .hiddenReviewSession, logicalKey: row.id, at: row.hiddenAt)
                adopted += 1
            }
        }
        return adopted
    }

    /// Version 74 stages every archived web article whose reader document was
    /// written before `ArticleChromeFilter` existed. Those `article.html` files
    /// still carry the publisher's navigation, share bars, comment forms, and
    /// footer, because the archive is written once at fetch time and the only
    /// semantic cleanup the pipeline had ran downstream, over the text.
    ///
    /// Set-based and metadata-only: no file is opened, no content hashed, and
    /// nothing proportional to a source's length happens here. The bounded
    /// drain refetches each page after launch.
    private func enqueueArchivedArticleChromeRefilter() throws -> Int {
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO article_chrome_refilter_queue
                (source_id, enqueued_at, attempt_count, last_error)
            SELECT s.id, ? - (s.date_added * 0.000000001), 0, NULL
            FROM sources s
            JOIN articles a ON a.source_id = s.id
            WHERE s.status = 'active'
              AND a.local_file_path LIKE '%article.html'
              AND (a.url LIKE 'http://%' OR a.url LIKE 'https://%')
            ON CONFLICT(source_id) DO NOTHING
        """) { stmt in
            sqlite3_bind_double(stmt, 1, enqueuedAt)
        }
        var count = 0
        try query("SELECT COUNT(*) FROM article_chrome_refilter_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Version 77 stages visible, ready podcast transcripts for the first
    /// deletion-only sponsor/ad pass. Visibility is resolved with the same
    /// persisted relationships as `source_projection`; hidden shows and
    /// episodes incur no model cost, while an explicit visible override wins.
    ///
    /// This migration reads only indexed metadata and content presence. It does
    /// not load, hash, tokenize, or rewrite transcript text.
    private func enqueueHistoricalPodcastTranscriptCleanup() throws -> Int {
        let targetVersion = PodcastTranscriptCleanupMetadata.currentVersion
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO podcast_transcript_cleanup_queue
                (source_id, target_version, source_sha256, enqueued_at, attempt_count, last_error)
            SELECT s.id, ?, NULL, ? - (s.date_added * 0.000000001), 0, NULL
            FROM sources s
            JOIN podcasts p ON p.source_id = s.id
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN podcast_transcript_preparations prep ON prep.source_id = s.id
            WHERE s.source_type = 'podcast'
              AND s.state = 'ready'
              AND s.status = 'active'
              AND TRIM(sc.content) != ''
              AND COALESCE(prep.cleaner_version, 0) < ?
              AND NOT EXISTS (
                  SELECT 1 FROM hidden_sources hs WHERE hs.source_id = s.id
              )
              AND NOT EXISTS (
                  SELECT 1 FROM hidden_podcast_episodes hpe WHERE hpe.source_id = s.id
              )
              AND (
                    EXISTS (
                        SELECT 1 FROM visible_podcast_episode_overrides vpeo
                        WHERE vpeo.source_id = s.id
                    )
                 OR NOT EXISTS (
                        SELECT 1 FROM hidden_podcast_shows hps
                        WHERE hps.show_name = p.domain
                           OR hps.show_name = p.show_name
                    )
              )
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                source_sha256 = NULL,
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL
        """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(targetVersion))
            sqlite3_bind_double(stmt, 2, enqueuedAt)
            sqlite3_bind_int(stmt, 3, Int32(targetVersion))
        }
        var count = 0
        try query("SELECT COUNT(*) FROM podcast_transcript_cleanup_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Version 167 queues every podcast episode the completeness audit can
    /// measure for one audit by `PodcastTranscriptCompleteness`.
    ///
    /// The retired 50,000-character import cap wrote cut transcripts into
    /// `source_content`. Chat, search, the full-text index and embeddings read
    /// that column, so an episode was answered from the part that survived.
    /// Schema 85 queued the episodes with stored TTML and passed any holding
    /// 85% of its TTML text, which every episode of 50,000 to 58,800
    /// characters did; its marker then exempted them. On 2026-10-06 a real
    /// library still held 67 capped episodes: 44 with stored TTML (all 44 had
    /// passed), 23 without.
    ///
    /// Queued: every active podcast with text and stored TTML, and every
    /// public Apple episode without stored TTML whose text did not come from
    /// YouTube, for one fetch of Apple's TTML. The old marker is not read; an
    /// episode the new audit already recorded (a hydration since a store was
    /// held below 154) is not queued again; a row schema 85 left in the queue
    /// starts its attempts again. Ids only: `octet_length` and the presence of
    /// a `source_content` row are answered without reading a TTML or a
    /// transcript. Returns the episodes queued.
    private func enqueuePodcastTranscriptCompletenessAudit() throws -> Int {
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO podcast_transcript_detruncation_queue
                (source_id, enqueued_at, attempt_count, last_error, retry_after)
            SELECT s.id, ? - (s.date_added * 0.000000001), 0, NULL, NULL
            FROM sources s
            JOIN podcasts p ON p.source_id = s.id
            WHERE s.source_type = 'podcast'
              AND s.status = 'active'
              AND EXISTS (SELECT 1 FROM source_content sc WHERE sc.source_id = s.id)
              AND NOT EXISTS (SELECT 1 FROM podcast_transcript_audits a WHERE a.source_id = s.id)
              AND \(Self.podcastTranscriptAuditableSQL)
            ON CONFLICT(source_id) DO UPDATE SET
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL,
                retry_after = NULL
        """) { stmt in
            sqlite3_bind_double(stmt, 1, enqueuedAt)
        }
        return Int(sqlite3_changes(db))
    }

    /// One-time paper-only Muse Spark rollout. The sentinel is deliberate: the
    /// background candidate computes and validates the cleaned content hash after
    /// launch, keeping content-proportional work out of the schema transaction.
    /// Pending work for other source types is removed; their existing guides stay
    /// readable until a later explicit rollout.
    private func enqueueMuseSparkPaperReviewGuides() throws -> Int {
        // This is a full versioned replacement of the pending backlog. Generated
        // guides stay intact, but stale, inactive, and non-paper queue rows must
        // not make the bounded worker report work that it can never consume.
        try exec("DELETE FROM source_review_guide_queue")
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO source_review_guide_queue
                (source_id, source_sha256, enqueued_at, attempt_count, last_error)
            SELECT s.id, '', ?, 0, NULL
            FROM sources s
            JOIN source_content sc ON sc.source_id = s.id
            WHERE s.source_type = 'paper'
              AND s.state = 'ready'
              AND s.status = 'active'
              AND sc.content != ''
            ON CONFLICT(source_id) DO UPDATE SET
                source_sha256 = excluded.source_sha256,
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL
        """) { stmt in
            sqlite3_bind_double(stmt, 1, enqueuedAt)
        }
        var count = 0
        try query("SELECT COUNT(*) FROM source_review_guide_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Version 42 retires the version-35 whole-library backlog along with the
    /// background worker that consumed it. Review guides are now prepared when a
    /// review actually starts, so a pending row schedules nothing: it only
    /// carries a stale attempt count that the next review request would rebuild
    /// anyway. Generated guides are untouched and stay readable.
    private func cancelPendingSourceReviewGuidePreparation() throws -> Int {
        try exec("DELETE FROM source_review_guide_queue")
        return Int(sqlite3_changes(db))
    }

    /// Version 24 repairs two halves of the same ordering bug. Older archives
    /// could commit locally without leaving a pending Source save, so CloudKit
    /// kept advertising an active row whose content had already been removed.
    /// A later Learning Goal payload could also restore that archived source to
    /// a Notebook because the relationship arrived after the Source record.
    ///
    /// Archived state is authoritative: republish every archived Source and
    /// remove its Notebook/Goal memberships in the same migration transaction.
    /// The source and every affected Learning Goal are queued with the repaired
    /// values before the version stamp commits, so another device converges
    /// regardless of record delivery order.
    func repairArchivedSourceSyncState() throws -> (republishedSources: Int, removedGoalLinks: Int) {
        var sourceIDs: [String] = []
        try query("SELECT id FROM sources WHERE status = 'archived' ORDER BY id") { stmt in
            if let sourceID = string(stmt, 0) {
                sourceIDs.append(sourceID)
            }
        }

        var goalIDs: [String] = []
        try query("""
            SELECT DISTINCT gi.goal_id
            FROM learning_goal_items gi
            JOIN sources s ON s.id = gi.source_id
            WHERE s.status = 'archived'
            ORDER BY gi.goal_id
        """) { stmt in
            if let goalID = string(stmt, 0) {
                goalIDs.append(goalID)
            }
        }

        var removedGoalLinks = 0
        try query("""
            SELECT COUNT(*)
            FROM learning_goal_items gi
            JOIN sources s ON s.id = gi.source_id
            WHERE s.status = 'archived'
        """) { stmt in
            removedGoalLinks = Int(sqlite3_column_int64(stmt, 0))
        }
        try exec("""
            DELETE FROM learning_goal_items
            WHERE source_id IN (
                SELECT id FROM sources WHERE status = 'archived'
            )
        """)

        let now = Date()
        for sourceID in sourceIDs {
            try upsertSyncSave(entity: .source, logicalKey: sourceID, at: now)
        }
        for goalID in goalIDs {
            try touchLearningGoal(goalID, at: now)
            try upsertSyncSave(entity: .learningGoal, logicalKey: goalID, at: now)
        }
        return (sourceIDs.count, removedGoalLinks)
    }

    /// Schema 153 releases what still points at a notebook that is gone.
    /// Merging Notebooks removed each merged one by a raw DELETE, and a split
    /// with `keep_parent` false removed its emptied parent the same way, so
    /// whatever the ordinary delete would have cleared kept the dead id:
    /// chats, nested Goals, Docs, Ideas' links and the rest
    /// (`moveNotebookContentsInTransaction` now moves them first).
    ///
    /// "Gone" is a `learningGoal` tombstone in `sync_metadata` with no row
    /// behind it — the mark every local delete and every applied remote
    /// delete leaves. An id with no row and no tombstone is left alone: it
    /// may be a Notebook CloudKit has not delivered yet, and clearing a chat's
    /// link to it would republish the loss to every device.
    ///
    /// Each link is cleared the way the ordinary delete clears it, set-based:
    /// a chat, a course, a scheduled task, a Memory item and a Planner block
    /// or bout lose the id; a nested Goal stands alone instead of being
    /// deleted with its Notebook; a Doc loses its home and its link; another
    /// Notebook loses its related-Notebook link; a Schedule placement loses
    /// the tag; an Idea loses the link. Nothing a learner wrote is deleted. A
    /// Direction keeps its home (it has no other, and is shown nowhere), as
    /// does every task, a team's or not (`notebook_tasks.notebook_id` is NOT
    /// NULL); a read-only team's records
    /// are not this member's to republish and are left as they are.
    ///
    /// Every changed record is queued for CloudKit before the version stamp
    /// commits. The work is bounded by the dangling rows, not the library:
    /// one indexed probe for tombstones answers a library with none.
    func releaseLinksToDeletedNotebooks() throws -> (deletedNotebooks: Int, republished: Int) {
        let deleted = """
            SELECT m.logical_key FROM sync_metadata m
            WHERE m.entity_type = '\(CloudKitSyncEntity.learningGoal.rawValue)'
              AND m.is_deleted = 1
              AND NOT EXISTS (SELECT 1 FROM learning_goals g WHERE g.id = m.logical_key)
        """
        var deletedCount = 0
        try query("SELECT COUNT(*) FROM (\(deleted))") { stmt in
            deletedCount = Int(sqlite3_column_int64(stmt, 0))
        }
        guard deletedCount > 0 else { return (0, 0) }

        func writable(_ teamColumn: String) -> String {
            "(\(teamColumn) IS NULL OR \(teamColumn) NOT IN (SELECT id FROM teams WHERE permission = '\(TeamPermission.readOnly.rawValue)'))"
        }
        let notebookLinkKinds = "('\(IdeaLinkKind.notebook.rawValue)', '\(IdeaLinkKind.goal.rawValue)')"
        let now = Date()
        var toStage: [(entity: CloudKitSyncEntity, key: String)] = []
        func collect(_ entity: CloudKitSyncEntity, _ sql: String) throws {
            try query(sql) { stmt in
                if let id = self.string(stmt, 0) { toStage.append((entity, id)) }
            }
        }
        func write(_ sql: String) throws {
            try execBind(sql) { stmt in
                sqlite3_bind_double(stmt, 1, now.timeIntervalSinceReferenceDate)
            }
        }

        // Chats, kept in the ordinary Chats list (`clearReviewSessionGoals`).
        let chats = "goal_id IN (\(deleted)) AND \(writable("team_id"))"
        try collect(.reviewSession, "SELECT id FROM review_sessions WHERE \(chats) ORDER BY id")
        try exec("UPDATE review_sessions SET goal_id = NULL WHERE \(chats)")

        // Nested Goals stand alone; the ordinary delete would have deleted them.
        let nested = "parent_notebook_id IN (\(deleted)) AND \(writable("team_id"))"
        try collect(.learningGoal, "SELECT id FROM learning_goals WHERE \(nested) ORDER BY id")
        try write("UPDATE learning_goals SET parent_notebook_id = NULL, updated_at = ?1 WHERE \(nested)")

        // Docs lose the home and the link (`removeNotebookFromArtifacts`).
        let docs = """
            \(writable("team_id")) AND (home_notebook_id IN (\(deleted))
                OR id IN (SELECT artifact_id FROM global_artifact_notebook_links WHERE notebook_id IN (\(deleted))))
        """
        try collect(.artifact, "SELECT id FROM global_artifacts WHERE \(docs) ORDER BY id")
        try write("""
            UPDATE global_artifacts
            SET home_notebook_id = CASE WHEN home_notebook_id IN (\(deleted)) THEN NULL ELSE home_notebook_id END,
                updated_at = ?1
            WHERE \(docs)
        """)
        try exec("""
            DELETE FROM global_artifact_notebook_links
            WHERE notebook_id IN (\(deleted))
              AND artifact_id IN (SELECT id FROM global_artifacts WHERE \(writable("team_id")))
        """)

        // A Notebook that drew context from the gone one stops
        // (`removeIncomingRelatedNotebookLinks`); the link rides its record.
        let referrers = """
            \(writable("team_id")) AND id IN (
                SELECT notebook_id FROM notebook_related_notebook_links WHERE related_notebook_id IN (\(deleted)))
        """
        try collect(.learningGoal, "SELECT id FROM learning_goals WHERE \(referrers) ORDER BY id")
        try write("UPDATE learning_goals SET updated_at = ?1 WHERE \(referrers)")
        try exec("""
            DELETE FROM notebook_related_notebook_links
            WHERE related_notebook_id IN (\(deleted))
              AND notebook_id IN (SELECT id FROM learning_goals WHERE \(writable("team_id")))
        """)

        // Scheduled tasks file their runs in Chats (`detachScheduledTasksFromNotebook`).
        let tasks = "notebook_id IN (\(deleted))"
        try collect(.scheduledTask, "SELECT id FROM scheduled_tasks WHERE \(tasks) ORDER BY id")
        try write("UPDATE scheduled_tasks SET notebook_id = NULL, updated_at = ?1 WHERE \(tasks)")

        // A Schedule placement loses the tag and keeps its source.
        let tagged = "SELECT scheduled_source_id FROM scheduled_source_goals WHERE goal_id IN (\(deleted))"
        try collect(.scheduledSource, "SELECT DISTINCT scheduled_source_id FROM scheduled_source_goals WHERE goal_id IN (\(deleted)) ORDER BY 1")
        try write("UPDATE scheduled_sources SET updated_at = ?1 WHERE id IN (\(tagged))")
        try exec("DELETE FROM scheduled_source_goals WHERE goal_id IN (\(deleted))")

        // Memory items keep their targets and lose the Goal.
        let memory = "goal_id IN (\(deleted))"
        try collect(.memoryItem, "SELECT id FROM memory_items WHERE \(memory) ORDER BY id")
        try write("UPDATE memory_items SET goal_id = NULL, updated_at = ?1 WHERE \(memory)")

        // An Idea loses the link; the link rides inside the Idea's record.
        let ideaLinks = "kind IN \(notebookLinkKinds) AND target_id IN (\(deleted))"
        try collect(.idea, "SELECT DISTINCT idea_id FROM idea_links WHERE \(ideaLinks) ORDER BY 1")
        try write("UPDATE ideas SET updated_at = MAX(updated_at, ?1) WHERE id IN (SELECT idea_id FROM idea_links WHERE \(ideaLinks))")
        try exec("DELETE FROM idea_links WHERE \(ideaLinks)")

        // Planner blocks and bouts ride in their day's plan record.
        let days = """
            SELECT day_plan_id FROM time_blocks WHERE notebook_id IN (\(deleted)) OR goal_id IN (\(deleted))
            UNION
            SELECT day_plan_id FROM learning_bouts WHERE notebook_id IN (\(deleted))
        """
        try collect(.dayPlan, "SELECT day_plan_id FROM (\(days)) ORDER BY 1")
        try write("UPDATE day_plans SET updated_at = ?1 WHERE id IN (\(days))")
        try write("""
            UPDATE time_blocks
            SET notebook_id = CASE WHEN notebook_id IN (\(deleted)) THEN NULL ELSE notebook_id END,
                goal_id = CASE WHEN goal_id IN (\(deleted)) THEN NULL ELSE goal_id END,
                updated_at = ?1
            WHERE notebook_id IN (\(deleted)) OR goal_id IN (\(deleted))
        """)
        try write("UPDATE learning_bouts SET notebook_id = NULL, updated_at = ?1 WHERE notebook_id IN (\(deleted))")

        var seen = Set<String>()
        var republished = 0
        for record in toStage where seen.insert("\(record.entity.rawValue)\u{1F}\(record.key)").inserted {
            // A record whose zone is a read-only team's cannot be queued
            // (`upsertSyncSave` refuses it), and a migration must not fail on
            // one; the team-column filters above already left such rows alone.
            let home = try loadSyncMetadata(entity: record.entity, logicalKey: record.key)?.home
                ?? resolveRecordHome(entity: record.entity, logicalKey: record.key)
            if home.isTeamZone, try teamPermission(forHome: home) == .readOnly { continue }
            try upsertSyncSave(entity: record.entity, logicalKey: record.key, at: now)
            republished += 1
        }
        return (deletedCount, republished)
    }

    /// Clears the attempt budget for everything still queued. Version 32 removed
    /// the character-ratio cleanup heuristic so chrome-dominated pages (paywall
    /// teasers, CAPTCHA walls, link indexes) are judged by the configured model
    /// rather than a fixed retention percentage. Sources that exhausted their
    /// attempts under the old rule
    /// would otherwise stay retired forever despite now being cleanable, and the
    /// cleaner contract itself is unchanged, so this is deliberately cheaper
    /// than bumping the cleaner version and re-cleaning the whole library. The
    /// drain computes and persists the input hash when it actually attempts an
    /// item; startup never loads or hashes the source bodies.
    @discardableResult
    func resetCanonicalContentCleanupAttempts() throws -> Int {
        try exec("""
            UPDATE canonical_content_cleanup_queue
            SET attempt_count = 0,
                last_error = NULL,
                source_sha256 = NULL
            WHERE attempt_count > 0
        """)
        var count = 0
        try query("SELECT COUNT(*) FROM canonical_content_cleanup_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Version 34 heals Source records that were processed on another Mac before
    /// the payload-version/attestation merge contract existed. Migration only
    /// stages IDs; post-launch batches create `sync_metadata`/`sync_changes` and
    /// build CloudKit payloads after the source list is already usable.
    func enqueueAttestedPaperSyncRepair() throws -> Int {
        let now = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO source_sync_repair_queue (source_id, enqueued_at)
            SELECT p.source_id, ?
            FROM papers p
            JOIN sources s ON s.id = p.source_id
            WHERE p.paper_ingestion_method IS NOT NULL
            ON CONFLICT(source_id) DO NOTHING
        """) { stmt in
            sqlite3_bind_double(stmt, 1, now)
        }
        var count = 0
        try query("SELECT COUNT(*) FROM source_sync_repair_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Schema 143: the stored titles a catalog wrote with inline markup take the
    /// fold every title now gets on its way in, `H<sub>2</sub>O<sub>2</sub>`
    /// becoming `H₂O₂`. Only subtype rows whose title holds a `<` are read —
    /// one scan of each title column — and only those the fold changes are
    /// written, so `Zara <> Alan` stays as it is. Each changed source is
    /// staged for the deferred CloudKit republish, which the phone reads its
    /// titles from, and loses its full-text state so the indexer rewrites the
    /// row that indexed the tags as words. The tables are named as they stand
    /// at 143, not read from a live list that later schemas may change.
    func foldStoredSourceTitleMarkup() throws -> Int {
        let subtypeTables = [
            "articles", "papers", "podcasts", "videos", "book_sources",
            "course_sources", "meeting_sources", "x_posts",
        ]
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        var folded = 0
        for table in subtypeTables {
            var changes: [(sourceID: String, title: String)] = []
            try query("""
                SELECT t.source_id, t.title
                FROM \(table) t
                JOIN sources s ON s.id = t.source_id
                WHERE instr(t.title, '<') > 0
            """) { stmt in
                guard let sourceID = self.string(stmt, 0), let title = self.string(stmt, 1) else { return }
                let plain = title.decodingTitleMarkup()
                if plain != title { changes.append((sourceID, plain)) }
            }
            for change in changes {
                try execBind("UPDATE \(table) SET title = ? WHERE source_id = ?") { stmt in
                    bind(stmt, 1, change.title)
                    bind(stmt, 2, change.sourceID)
                }
                try execBind("""
                    INSERT INTO source_sync_repair_queue (source_id, enqueued_at)
                    VALUES (?, ?)
                    ON CONFLICT(source_id) DO NOTHING
                """) { stmt in
                    bind(stmt, 1, change.sourceID)
                    sqlite3_bind_double(stmt, 2, enqueuedAt)
                }
                try execBind("DELETE FROM source_fts_state WHERE source_id = ?") { stmt in
                    bind(stmt, 1, change.sourceID)
                }
            }
            folded += changes.count
        }
        return folded
    }

    /// Schema 144: a stored author that is some other field misread as one —
    /// markup, a web address, a "name" longer than any name (`SourceAuthor`)
    /// — is cleared. Only cells that could fail the rule are read, one scan of
    /// each author column for a `<`, a `=`, a `://`, a `www.` or more than
    /// `SourceAuthor.maximumNameLength` characters, and the Swift rule decides
    /// which of those go. Each cleared source is staged for the deferred
    /// CloudKit republish, which the phone and the other Mac read authors
    /// from, and loses its full-text state, because the author is indexed.
    /// No byline is invented in its place: nothing stored holds the real one.
    /// The columns are named as they stand at 144.
    func clearStoredImplausibleSourceAuthors() throws -> Int {
        let authorColumns = [
            ("articles", "author"), ("papers", "author"),
            ("x_posts", "author"), ("meeting_sources", "presenter"),
        ]
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        var cleared = 0
        for (table, column) in authorColumns {
            var sourceIDs: [String] = []
            try query("""
                SELECT t.source_id, t.\(column)
                FROM \(table) t
                JOIN sources s ON s.id = t.source_id
                WHERE instr(t.\(column), '<') > 0
                   OR instr(t.\(column), '=') > 0
                   OR instr(t.\(column), '://') > 0
                   OR instr(lower(t.\(column)), 'www.') > 0
                   OR length(t.\(column)) > \(SourceAuthor.maximumNameLength)
            """) { stmt in
                guard let sourceID = self.string(stmt, 0), let author = self.string(stmt, 1) else { return }
                if !SourceAuthor.isPlausible(author) { sourceIDs.append(sourceID) }
            }
            for sourceID in sourceIDs {
                try execBind("UPDATE \(table) SET \(column) = NULL WHERE source_id = ?") { stmt in
                    bind(stmt, 1, sourceID)
                }
                try execBind("""
                    INSERT INTO source_sync_repair_queue (source_id, enqueued_at)
                    VALUES (?, ?)
                    ON CONFLICT(source_id) DO NOTHING
                """) { stmt in
                    bind(stmt, 1, sourceID)
                    sqlite3_bind_double(stmt, 2, enqueuedAt)
                }
                try execBind("DELETE FROM source_fts_state WHERE source_id = ?") { stmt in
                    bind(stmt, 1, sourceID)
                }
            }
            cleared += sourceIDs.count
        }
        return cleared
    }

    /// Schema 144: every paper with a DOI and a title is staged once for the
    /// post-launch check against the title its DOI is registered under
    /// (`RegisteredPaperTitleCheckService`). One set-based INSERT over
    /// `papers`, ids only; the migration asks no catalog.
    func enqueueRegisteredPaperTitleChecks() throws -> Int {
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO paper_registered_title_queue (source_id, enqueued_at)
            SELECT p.source_id, ?
            FROM papers p
            JOIN sources s ON s.id = p.source_id
            WHERE TRIM(COALESCE(p.doi, '')) <> ''
              AND TRIM(COALESCE(p.title, '')) <> ''
            ON CONFLICT(source_id) DO NOTHING
        """) { stmt in
            sqlite3_bind_double(stmt, 1, enqueuedAt)
        }
        return try registeredPaperTitleQueueCount()
    }

    /// Schema 148: every personal YouTube video is staged once for the
    /// post-launch check of its stored transcript against its captions
    /// (`YouTubeTranscriptCheckService`). One set-based INSERT over `videos`,
    /// ids only: the migration reads no transcript and fetches no captions,
    /// and the check itself passes over a video with no text. A team's copy
    /// is left to the library it is shared from.
    func enqueueYouTubeTranscriptChecks() throws -> Int {
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO youtube_transcript_check_queue (source_id, enqueued_at)
            SELECT v.source_id, ?
            FROM videos v
            JOIN sources s ON s.id = v.source_id
            WHERE s.team_id IS NULL
              AND (v.url LIKE '%youtube.com/%' OR v.url LIKE '%youtu.be/%')
            ON CONFLICT(source_id) DO NOTHING
        """) { stmt in
            sqlite3_bind_double(stmt, 1, enqueuedAt)
        }
        return try youTubeTranscriptCheckQueueCount()
    }

    /// The team Notebooks schema 152 republishes: held in a team this account
    /// may edit, tracked by sync in that team's zone (a row the bootstrap pass
    /// has not met yet goes up whole anyway), not deleted or quarantined, with
    /// at least one pending or rejected item.
    /// Builds before 152 published every one of those items without its
    /// approval (`LearningGoalRecord.strippingMemberProgress`), so the team
    /// read each as an approved source. A team Notebook whose items all read
    /// as approved here is not named: the team's record already says that,
    /// and sending this Mac's view of it could only overwrite a teammate's
    /// verdict that never reached this Mac.
    static let teamApprovalRepublishSelection = """
        SELECT m.logical_key
        FROM sync_metadata m
        JOIN learning_goals g ON g.id = m.logical_key
        JOIN teams t ON t.id = g.team_id
        WHERE m.entity_type = 'learningGoal'
          AND m.is_deleted = 0
          AND m.zone_scope = t.zone_scope
          AND m.zone_name = t.zone_name
          AND t.permission = 'readWrite'
          AND EXISTS (
              SELECT 1 FROM learning_goal_items i
              WHERE i.goal_id = g.id AND i.review_state IN ('pending', 'rejected')
          )
          AND NOT EXISTS (
              SELECT 1 FROM sync_conflicts c
              WHERE c.entity_type = m.entity_type AND c.logical_key = m.logical_key
          )
    """

    /// Schema 152: stage each team Notebook in `teamApprovalRepublishSelection`
    /// for one CloudKit save, the way `upsertSyncSave` would — the record's
    /// modification date moves to now and a save is queued in the record's
    /// own zone — but as two set-based statements, so the cost is the team's
    /// Notebooks, never the library. A save already waiting takes the new
    /// change date, as `upsertSyncSave` gives it, and stops being tutor-only:
    /// a tutor-only change lets the server's record win the editorial merge,
    /// and the server's is the one missing approval. Being editorial, the save
    /// also wins over a teammate's change this Mac has not fetched yet, last
    /// writer wins like any offline edit (backend-storage-sync.md, Teams).
    /// The payload is built at send time from the rows as they stand, so the
    /// migration reads no item and writes no application row.
    func stageTeamNotebookApprovalRepublish() throws -> Int {
        let now = Date().timeIntervalSinceReferenceDate
        try execBind("""
            UPDATE sync_metadata
            SET user_modification_at = ?
            WHERE entity_type = 'learningGoal'
              AND logical_key IN (\(Self.teamApprovalRepublishSelection))
        """) { stmt in
            sqlite3_bind_double(stmt, 1, now)
        }
        let staged = Int(sqlite3_changes(db))
        guard staged > 0 else { return 0 }
        try execBind("""
            INSERT INTO sync_changes (
                entity_type, logical_key, record_name, operation, changed_at, tutor_only,
                zone_scope, zone_name, zone_owner_record_name
            )
            SELECT m.entity_type, m.logical_key, m.record_name, 'save', ?, 0,
                   m.zone_scope, m.zone_name, m.zone_owner_record_name
            FROM sync_metadata m
            WHERE m.entity_type = 'learningGoal'
              AND m.logical_key IN (\(Self.teamApprovalRepublishSelection))
            ON CONFLICT(entity_type, logical_key) DO UPDATE SET
                changed_at = excluded.changed_at,
                tutor_only = 0
            WHERE sync_changes.operation = 'save'
        """) { stmt in
            sqlite3_bind_double(stmt, 1, now)
        }
        return staged
    }

    /// Version 70 asks every Mac that records an original PDF to publish it once
    /// more. Older builds treated `sourcePDFAsset` as an optional iPhone feed and
    /// did not guarantee that a receiving Mac consumed it; worse, a Mac missing
    /// the bytes could clear the server field during an unrelated source save.
    ///
    /// Migration only stages indexed source IDs. It never stats or reads a file;
    /// the existing bounded post-launch drain builds records off-main. A Mac that
    /// has the PDF uploads it, while the mapper now leaves the server field
    /// untouched on a Mac that only has the portable path.
    func enqueueRecordedSourcePDFAssetRepublish() throws -> Int {
        let now = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO source_sync_repair_queue (source_id, enqueued_at)
            SELECT id, ?
            FROM source_projection
            WHERE source_type IN ('paper', 'book', 'course')
              AND (
                    lower(COALESCE(local_file_path, '')) LIKE '%.pdf'
                 OR lower(COALESCE(url, '')) LIKE '%.pdf'
              )
            ON CONFLICT(source_id) DO NOTHING
        """) { stmt in
            sqlite3_bind_double(stmt, 1, now)
        }
        var count = 0
        try query("SELECT COUNT(*) FROM source_sync_repair_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Schema 134: every paper and article preparation is audited once for
    /// stored text shorter than its hash (`auditCanonicalContentIntegrity`).
    /// Set-based, ids only; the primary-key scans of the two preparation
    /// tables are the whole cost.
    func enqueueCanonicalContentIntegrityAudit() throws -> Int {
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT OR IGNORE INTO canonical_content_integrity_audit_queue (source_id, enqueued_at)
            SELECT source_id, ? FROM paper_content_preparations
            UNION
            SELECT source_id, ? FROM article_content_preparations
        """) { stmt in
            sqlite3_bind_double(stmt, 1, enqueuedAt)
            sqlite3_bind_double(stmt, 2, enqueuedAt)
        }
        return try canonicalContentIntegrityAuditQueueCount()
    }

    /// Version 21 introduced the durable model-backed cleanup queue; version 23
    /// requeued stale sources for the bounded-hunk v6 contract, and version 25
    /// requeued them for the physical-line v7 contract, and version 26 requeues
    /// them for heading-independent bibliography removal in v8. None performs
    /// inference inside the schema transaction. The background cleanup actor
    /// drains this durable queue off-main after the library has loaded.
    ///
    /// **A cleaner version bump must say which sources it affects.** Every
    /// source below the current cleaner version is re-queued, because each is
    /// out of contract, but re-cleaning is paid work: cleaner v19 (schema 132)
    /// re-queued about 1,380 sources to fix about 280 and cost the learner
    /// $27.50 in an afternoon. So the re-queue is held for the learner
    /// (`holdingBulkRequeue`, over `learnerDecisionThreshold` sources), and
    /// `affectedSources` is what lets them choose "only the affected ones":
    /// pass `.matching(sql:)` with a condition over `s` (sources), `pp`
    /// (paper_content_preparations) and `ap` (article_content_preparations)
    /// that is true exactly for the sources the change alters — for example
    /// papers whose stored raw text is shorter than their PDF's, or articles
    /// from the hosts a new rule targets. `.unknown(because:)` is for a change
    /// that truly reaches every source, and says why. Migrations that already
    /// shipped keep their original selection; only the hold is new.
    func enqueueHistoricalCanonicalContentCleanup(
        reason: String,
        affectedSources: BulkRequeueAffectedSources
    ) throws -> Int {
        try holdingBulkRequeue(
            into: .canonicalCleanup,
            reason: reason,
            affectedSources: affectedSources
        ) {
            try stageHistoricalCanonicalContentCleanup()
        }
    }

    private func stageHistoricalCanonicalContentCleanup() throws -> Int {
        let targetVersion = PaperContentPreparationMetadata.currentVersion
        let enqueuedAt = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT INTO canonical_content_cleanup_queue
                (source_id, target_version, enqueued_at, attempt_count, last_error)
            SELECT s.id, ?, ?, 0, NULL
            FROM sources s
            JOIN source_content sc ON sc.source_id = s.id
            LEFT JOIN paper_content_preparations pp ON pp.source_id = s.id
            LEFT JOIN article_content_preparations ap ON ap.source_id = s.id
            WHERE s.state = 'ready'
              AND s.status = 'active'
              AND TRIM(sc.content) != ''
              AND (
                    (s.source_type = 'paper' AND COALESCE(pp.cleaner_version, 0) < ?)
                 OR (s.source_type IN ('article', 'manual', 'unclassified')
                     AND COALESCE(ap.cleaner_version, 0) < ?)
              )
            ON CONFLICT(source_id) DO UPDATE SET
                target_version = MAX(target_version, excluded.target_version),
                enqueued_at = excluded.enqueued_at,
                attempt_count = 0,
                last_error = NULL
        """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(targetVersion))
            sqlite3_bind_double(stmt, 2, enqueuedAt)
            sqlite3_bind_int(stmt, 3, Int32(targetVersion))
            sqlite3_bind_int(stmt, 4, Int32(targetVersion))
        }
        var count = 0
        try query("SELECT COUNT(*) FROM canonical_content_cleanup_queue") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// One-time v14 promotion of model choices that predate the SQLite preference
    /// mirror. Those choices already live in UserDefaults, but without this
    /// migration a rebuild that changes the preferences container loses them
    /// before `hydrateFromStore()` has anything durable to restore.
    ///
    /// This runs inside the schema migration's `BEGIN IMMEDIATE`; each row and its
    /// sync bookkeeping commit together, and a current database never runs it.
    @discardableResult
    func migratePersistedModelPreferences(_ preferences: [String: Any]) throws -> Int {
        var migratedCount = 0
        for key in preferences.keys.sorted() {
            guard SyncedPreferenceKeys.isPersistedModelConfiguration(key),
                  let value = preferences[key],
                  let xml = PreferenceStore.encodePlist(value)
            else { continue }
            try writePreference(key: key, valuePlistXML: xml)
            migratedCount += 1
        }
        return migratedCount
    }

    /// One-time v116 adoption of the preferences that became synced on
    /// 2026-09-14 — the video reader's layout mode and pane fractions, and the
    /// navigation rail's hidden rows and folds.
    ///
    /// Same contract as the v80 adoption below: a key is taken only when it has
    /// no durable row and no CloudKit history, so an existing synced choice or a
    /// tombstone from the other Mac always wins over this Mac's local value.
    /// Each adopted row goes through `writePreference` inside the outer
    /// migration transaction, committing the value and its sync outbox entry
    /// together. The input is the bounded defaults dictionary.
    @discardableResult
    func adoptNewlySyncedDisplayPreferences(_ preferences: [String: Any]) throws -> Int {
        let keys = [
            "reader.youtubeTranscriptBesideVideo",
            "reader.youtubeVideoPaneFraction",
            "reader.youtubeVideoPaneWidthFraction",
            "reader.meetingVideoPaneFraction",
            StudioRailHiddenItems.storageKey,
            "studio.navigation.chatsExpanded.v1",
            "studio.navigation.hiddenChatsExpanded.v1",
            "studio.navigation.expandedProjectIDs.v1",
        ]
        var adopted = 0
        for key in keys.sorted() {
            guard let value = preferences[key],
                  try loadPreferenceForSync(key) == nil
            else { continue }

            var hasSyncHistory = false
            try queryBind("""
                SELECT 1
                FROM sync_metadata
                WHERE entity_type = 'preference' AND logical_key = ?
                LIMIT 1
            """, bind: { statement in
                bind(statement, 1, key)
            }) { _ in
                hasSyncHistory = true
            }
            guard !hasSyncHistory, let xml = PreferenceStore.encodePlist(value) else { continue }

            try writePreference(key: key, valuePlistXML: xml)
            adopted += 1
        }
        return adopted
    }

    /// One-time v80 adoption of meeting-folder images that reached
    /// `UserDefaults` but not the SQLite preference mirror.
    ///
    /// A rebuild or second app/device hydrates only `user_preferences`, so an
    /// orphaned local value disappears despite still existing on the original
    /// Mac. Existing durable rows and CloudKit tombstones remain authoritative.
    /// Each adopted row goes through `writePreference` inside the outer migration
    /// transaction, committing its value and sync outbox entry atomically. The
    /// input is the bounded defaults dictionary, never the source library.
    @discardableResult
    func migrateMeetingFolderImagePreferences(_ preferences: [String: Any]) throws -> Int {
        let prefix = MeetingMetadata.folderImagePreferenceKeyPrefix
        var migratedCount = 0

        for key in preferences.keys.sorted() where key.hasPrefix(prefix) {
            guard let value = preferences[key] as? String,
                  !value.isEmpty,
                  try loadPreferenceForSync(key) == nil
            else { continue }

            var hasSyncHistory = false
            try queryBind("""
                SELECT 1
                FROM sync_metadata
                WHERE entity_type = 'preference' AND logical_key = ?
                LIMIT 1
            """, bind: { statement in
                bind(statement, 1, key)
            }) { _ in
                hasSyncHistory = true
            }
            guard !hasSyncHistory,
                  let xml = PreferenceStore.encodePlist(value)
            else { continue }

            try writePreference(key: key, valuePlistXML: xml)
            migratedCount += 1
        }
        return migratedCount
    }

    /// Version 8 repairs a legacy state where course lecture sources were archived
    /// while their course relationships remained. A course outline is an active
    /// collection, so every source it references must also be active. Each source
    /// update and its CloudKit bookkeeping share the outer migration transaction.
    func reactivateArchivedCourseLectureSources() throws -> Int {
        var sourceIDs: [String] = []
        try query("""
            SELECT DISTINCT s.id
            FROM sources s
            JOIN course_lecture_items cli ON cli.source_id = s.id
            WHERE s.status = 'archived'
            ORDER BY s.id
        """) { stmt in
            if let sourceID = string(stmt, 0) {
                sourceIDs.append(sourceID)
            }
        }
        guard !sourceIDs.isEmpty else { return 0 }

        let now = Date()
        for sourceID in sourceIDs {
            try execBind("""
                UPDATE sources
                SET status = 'active',
                    archived_at = NULL,
                    state = CASE
                        WHEN COALESCE(error_message, '') = ''
                         AND NOT EXISTS (
                                SELECT 1 FROM source_content sc
                                WHERE sc.source_id = sources.id
                                  AND COALESCE(LENGTH(sc.content), 0) > 0
                             )
                        THEN ?
                        ELSE state
                    END
                WHERE id = ? AND status = 'archived'
            """) { stmt in
                bind(stmt, 1, StudioArticleState.queued.rawValue)
                bind(stmt, 2, sourceID)
            }
            guard sqlite3_changes(db) > 0 else { continue }
            try upsertSyncSave(entity: .source, logicalKey: sourceID, at: now)
        }

        logger.notice("Reactivated \(sourceIDs.count) archived course lecture source(s)")
        return sourceIDs.count
    }

    /// Version 9 republishes existing video/recording locators once. Older
    /// builds synced the locator inside a whole-source payload, where a newer
    /// metadata or content save from another Mac could replace it with an empty
    /// value. Re-enqueueing surviving progress seeds CloudKit with the repaired
    /// merge semantics without running a repair on every launch.
    func republishVideoWatchProgressForSync() throws -> Int {
        var sourceIDs: [String] = []
        try query("""
            SELECT id, reading_position_locator
            FROM sources
            WHERE reading_position_locator IS NOT NULL
            ORDER BY id
        """) { stmt in
            guard let sourceID = string(stmt, 0),
                  VideoWatchProgress(encoded: string(stmt, 1)) != nil else {
                return
            }
            sourceIDs.append(sourceID)
        }
        guard !sourceIDs.isEmpty else { return 0 }

        let now = Date()
        for sourceID in sourceIDs {
            try upsertSyncSave(entity: .source, logicalKey: sourceID, at: now)
        }
        return sourceIDs.count
    }

    /// Republish sources that a dismissal archived while sync tracking was
    /// suppressed.
    ///
    /// `archiveSourcesMatchingDismissedURL` runs inside `withoutSyncTracking`
    /// on both inbound paths — a DismissedSource record arriving, and a Source
    /// record arriving whose URL is already dismissed here — so until the fix at
    /// that call site, `archiveSource`'s own `markRecordChanged` was a no-op and
    /// the archive never reached CloudKit. The server kept serving those sources
    /// as active with their text already wiped locally, so other devices listed
    /// sources they could not open, and every full zone pass re-sent and
    /// re-archived them without ever converging.
    ///
    /// New archives publish themselves now; these are the ones already stranded.
    /// Republishing an archived source that happens to be correct on the server
    /// costs one upload and changes nothing.
    func republishDismissedArchivedSourcesForSync() throws -> Int {
        var sourceIDs: [String] = []
        try query("""
            SELECT DISTINCT sp.id
            FROM source_projection sp
            JOIN dismissed_sources d
              ON d.url = sp.url
              OR d.url = sp.normalized_url
              OR d.url = sp.local_file_path
              OR d.url = sp.podcast_web_page_url
            WHERE sp.status = 'archived'
            ORDER BY sp.id
        """) { stmt in
            if let sourceID = string(stmt, 0) {
                sourceIDs.append(sourceID)
            }
        }
        guard !sourceIDs.isEmpty else { return 0 }

        let now = Date()
        for sourceID in sourceIDs {
            try upsertSyncSave(entity: .source, logicalKey: sourceID, at: now)
        }
        return sourceIDs.count
    }

    /// Version 10 makes a successful Paper Metadata LLM call a durable
    /// prerequisite for `.ready`. Papers from older builds cannot prove which
    /// ingestion path created them, so complete ready records are explicitly
    /// grandfathered as `legacy`; incomplete ready records are demoted and will
    /// be retried through the normal event-driven metadata queue. Every changed
    /// source is republished so both the attestation and state survive CloudKit.
    func migratePaperIngestionGate() throws -> Int {
        var sourceIDs: [String] = []
        try query("""
            SELECT s.id
            FROM sources s
            JOIN papers p ON p.source_id = s.id
            WHERE s.state = 'ready'
            ORDER BY s.id
        """) { stmt in
            if let sourceID = string(stmt, 0) {
                sourceIDs.append(sourceID)
            }
        }
        guard !sourceIDs.isEmpty else { return 0 }

        try exec("""
            UPDATE papers
            SET paper_ingestion_method = 'legacy'
            WHERE source_id IN (
                SELECT s.id
                FROM sources s
                JOIN papers p ON p.source_id = s.id
                WHERE s.state = 'ready'
                  AND TRIM(COALESCE(p.author, '')) != ''
                  AND p.author != 'Unknown authors'
                  AND TRIM(COALESCE(p.journal, '')) != ''
                  AND p.journal != 'Unknown venue'
                  AND TRIM(COALESCE(p.published_year, '')) != ''
                  AND p.published_year != 'Unknown year'
            )
        """)
        try exec("""
            UPDATE sources
            SET state = 'error',
                error_message = 'Paper ingestion incomplete: AI metadata extraction is required.'
            WHERE state = 'ready'
              AND id IN (
                  SELECT p.source_id
                  FROM papers p
                  WHERE p.paper_ingestion_method IS NULL
              )
        """)

        let now = Date()
        for sourceID in sourceIDs {
            try upsertSyncSave(entity: .source, logicalKey: sourceID, at: now)
        }
        return sourceIDs.count
    }

    /// Version 13 repairs course-owned PDF materials that the legacy direct-PDF
    /// fetch path rewrote from `.course` to `.paper`. `group_members` is the
    /// durable primary-home relationship: real papers attached to a lecture use
    /// `course_lecture_items` and remain papers. The source identity, URL, file,
    /// content, and course relationship are preserved; only the subtype storage
    /// and paper-only error state change.
    func restoreMisclassifiedCourseMaterials() throws -> Int {
        var sourceIDs: [String] = []
        try query("""
            SELECT DISTINCT s.id
            FROM sources s
            JOIN papers p ON p.source_id = s.id
            JOIN group_members gm ON gm.source_id = s.id
            JOIN courses c ON c.id = gm.group_id
            WHERE s.source_type = 'paper'
            ORDER BY s.id
        """) { stmt in
            if let sourceID = string(stmt, 0) {
                sourceIDs.append(sourceID)
            }
        }
        guard !sourceIDs.isEmpty else { return 0 }

        let now = Date()
        for sourceID in sourceIDs {
            try execBind("""
                INSERT INTO course_sources (
                    source_id, url, local_file_path, normalized_url, title,
                    domain, discovery_origin, word_count, artwork_url
                )
                SELECT
                    source_id, url, local_file_path, normalized_url, title,
                    domain, discovery_origin, word_count, artwork_url
                FROM papers
                WHERE source_id = ?
                ON CONFLICT(source_id) DO UPDATE SET
                    url = excluded.url,
                    local_file_path = excluded.local_file_path,
                    normalized_url = excluded.normalized_url,
                    title = excluded.title,
                    domain = excluded.domain,
                    discovery_origin = excluded.discovery_origin,
                    word_count = excluded.word_count,
                    artwork_url = excluded.artwork_url
            """) { stmt in
                bind(stmt, 1, sourceID)
            }
            try execBind("""
                UPDATE sources
                SET source_type = ?,
                    state = CASE
                        WHEN EXISTS (
                            SELECT 1 FROM papers p
                            WHERE p.source_id = sources.id
                              AND TRIM(COALESCE(p.local_file_path, '')) != ''
                        )
                        OR EXISTS (
                            SELECT 1 FROM source_content sc
                            WHERE sc.source_id = sources.id
                              AND TRIM(COALESCE(sc.content, '')) != ''
                        )
                        THEN ?
                        ELSE ?
                    END,
                    error_message = NULL
                WHERE id = ?
            """) { stmt in
                bind(stmt, 1, StudioSourceType.course.rawValue)
                bind(stmt, 2, StudioArticleState.ready.rawValue)
                bind(stmt, 3, StudioArticleState.queued.rawValue)
                bind(stmt, 4, sourceID)
            }
            try execBind("DELETE FROM papers WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            try upsertSyncSave(entity: .source, logicalKey: sourceID, at: now)
        }
        return sourceIDs.count
    }

    /// Additive changes supported by the current migration. Missing tables are
    /// installed by the shared `CREATE TABLE IF NOT EXISTS` statements above.
    /// Identity, primary-key, and relationship columns are intentionally absent
    /// from this list: those cannot be guessed or backfilled safely. A store held
    /// below 154 (`createSchema(stoppingBeforeSchema154:)`) gets none of 154's.
    func addMissingColumnsForCurrentSchema(includingSchema154: Bool) throws {
        var columns: [(table: String, name: String, definition: String)] = [
            ("sources", "state", "TEXT NOT NULL DEFAULT 'queued'"),
            ("sources", "error_message", "TEXT"),
            ("sources", "source_type", "TEXT NOT NULL DEFAULT 'article'"),
            ("sources", "existing_card_count", "INTEGER NOT NULL DEFAULT 0"),
            ("sources", "status", "TEXT NOT NULL DEFAULT 'active'"),
            ("sources", "archived_at", "TEXT"),
            ("sources", "public_url", "TEXT"),
            ("sources", "is_consumed", "INTEGER"),
            ("sources", "reading_position_page", "INTEGER"),
            ("sources", "reading_position_locator", "TEXT"),
            ("sources", "connector_label", "TEXT"),
            ("sources", "read_at", "REAL"),
            ("articles", "author", "TEXT"),
            ("papers", "published_doi", "TEXT"),
            ("papers", "paper_ingestion_method", "TEXT"),
            // Schema 110. NULL until the AI browser suspects a paywall it
            // cannot prove; every existing row is honestly unspoken-for.
            ("papers", "paywall_suspicion", "TEXT"),
            ("podcasts", "raw_ttml", "TEXT"),
            ("books", "subtitle", "TEXT"),
            ("books", "edition", "TEXT"),
            ("books", "kind", "TEXT"),
            ("courses", "is_hidden", "INTEGER NOT NULL DEFAULT 0"),
            ("courses", "pending_playlist_import", "INTEGER NOT NULL DEFAULT 0"),
            ("group_members", "lecture_group_id", "TEXT"),
            ("review_sessions", "source_ids", "TEXT NOT NULL DEFAULT '[]'"),
            ("review_sessions", "exchange_count", "INTEGER NOT NULL DEFAULT 0"),
            ("review_sessions", "model_provider", "TEXT"),
            ("review_sessions", "model_id", "TEXT"),
            ("review_sessions", "goal_id", "TEXT"),
            ("learning_goals", "kind", "TEXT"),
            ("learning_goals", "description", "TEXT"),
            ("learning_goals", "topic", "TEXT"),
            ("learning_goals", "discovery_enabled", "INTEGER"),
            ("learning_goals", "daily_target", "INTEGER"),
            ("learning_goals", "last_quiz_date", "TEXT"),
            ("learning_goals", "last_discovery_at", "REAL"),
            ("learning_goals", "notes", "TEXT"),
            ("learning_goals", "parent_notebook_id", "TEXT"),
            ("learning_goals", "research_questions", "TEXT"),
            ("learning_goals", "summary", "TEXT"),
            // Schema 102: the GitHub repository a Notebook is about. NULL on
            // every existing row is the truth — no Notebook had one before.
            ("learning_goals", "repository", "TEXT"),
            // Schema 121: the artifact a Goal is for. NULL on every existing
            // row is the truth — no Goal named one before.
            ("learning_goals", "artifact_id", "TEXT"),
            // Schema 125: where the learner put a Goal in the Goals tab. NULL
            // on every existing row is the truth — no Goal was placed before.
            ("learning_goals", "sort_order", "INTEGER"),
            // Schema 107: the source a Planner block is for. NULL on every
            // existing row is the truth — no block had one before.
            ("time_blocks", "source_id", "TEXT"),
            // Schema 108: every source a Planner block is for. '[]' on every
            // existing row until the < 108 step folds source_id into it.
            ("time_blocks", "source_ids", "TEXT NOT NULL DEFAULT '[]'"),
            // Schema 109: the calendar event a Planner block mirrors, and its
            // page. NULL on every existing row is the truth — no block came
            // from a calendar before.
            ("time_blocks", "calendar_event_id", "TEXT"),
            ("time_blocks", "calendar_event_url", "TEXT"),
            // Schema 120: the Goal a Planner block serves. NULL on every
            // existing row is the truth — no block named a Goal before.
            ("time_blocks", "goal_id", "TEXT"),
            // Schema 123: what kind of hour a Planner block is. 'work' on
            // every existing row is the truth — nothing about a block said
            // otherwise before.
            ("time_blocks", "purpose", "TEXT NOT NULL DEFAULT 'work'"),
            // Schema 128: where a Planner block is, as its calendar event
            // says. NULL on every existing row until the < 128 step moves a
            // calendar block's import-written notes into it.
            ("time_blocks", "location", "TEXT"),
            ("learning_goal_items", "origin", "TEXT"),
            ("learning_goal_items", "review_state", "TEXT"),
            ("learning_goal_items", "relevance", "REAL"),
            ("learning_goal_items", "last_quizzed_at", "REAL"),
            ("learning_goal_items", "quiz_count", "INTEGER"),
            ("learning_goal_items", "last_score", "REAL"),
            ("learning_goal_items", "sequence", "REAL"),
            ("scheduled_sources", "source_url", "TEXT"),
            ("scheduled_sources", "source_normalized_url", "TEXT"),
            ("scheduled_sources", "source_doi", "TEXT"),
            ("scheduled_sources", "source_published_doi", "TEXT"),
            // Some production databases were stamped v63 by an intermediate
            // build that installed source_activity_days without this companion
            // placement flag. The v64 bump deliberately re-enters this
            // versioned additive migration instead of repairing current stores
            // on every launch.
            ("scheduled_sources", "is_automatic", "INTEGER NOT NULL DEFAULT 0"),
            ("memory_attempts", "parent_curriculum_fingerprint", "TEXT"),
            ("sync_changes", "tutor_only", "INTEGER NOT NULL DEFAULT 0"),
            // Schema 118: 1 when the learner's own key paid and the call
            // never reached the proxy. 0 on every existing row — until this
            // build every billable call went through the proxy.
            ("ai_usage_events", "own_key", "INTEGER NOT NULL DEFAULT 0"),
            ("ai_usage_events", "task", "TEXT"),
            ("ai_usage_events", "session_id", "TEXT"),
            ("ai_usage_events", "activity_id", "TEXT"),
            ("ai_usage_events", "subject_id", "TEXT"),
            ("ai_usage_events", "subject_type", "TEXT"),
            ("ai_usage_events", "subject_title", "TEXT"),
            ("ai_usage_events", "character_count", "INTEGER"),
            ("ai_usage_events", "duration_seconds", "REAL"),
            ("ai_usage_events", "estimated_cost", "REAL"),
            ("ai_usage_events", "server_ledger_id", "INTEGER"),
            ("ai_usage_events", "server_request_id", "TEXT"),
            ("ai_usage_events", "client_platform", "TEXT"),
            // Schema 95: how long the call took as the client saw it. Nothing
            // recorded latency before, so "dictation is slow" (2026-09-07)
            // could only be argued from the code. NULL on every older row and
            // on paths that do not time themselves; it means unmeasured.
            ("ai_usage_events", "latency_ms", "INTEGER"),
            ("meeting_sources", "presenter", "TEXT"),
            ("meeting_groups", "merged_into_group_id", "TEXT"),
            ("meeting_groups", "schedule_json", "TEXT"),
            // Schema 115: what kind of source a candidate is, and what the
            // article that linked it says about it. Every row written before
            // was a paper with nothing to say beyond its bibliographic fields,
            // so the default and NULL are the truth and nothing is backfilled.
            ("video_cited_papers", "kind", "TEXT NOT NULL DEFAULT 'paper'"),
            ("video_cited_papers", "context", "TEXT"),
            ("videos", "liked_at", "REAL"),
            ("videos", "video_published_at", "REAL"),
            ("video_playlists", "auto_import", "INTEGER NOT NULL DEFAULT 0"),
            ("video_playlists", "connector_kind", "TEXT"),
            ("canonical_content_cleanup_queue", "source_sha256", "TEXT"),
            ("source_highlights", "anchor_prefix", "TEXT"),
            ("source_highlights", "anchor_suffix", "TEXT"),
            ("source_highlights", "anchor_offset", "INTEGER"),
            // Schema 139: the chat a mark's note came from. NULL on every
            // existing row is the truth — no mark linked a chat before.
            ("source_highlights", "chat_session_id", "TEXT"),
            // Schema 140: the papers a mark's note cites. NULL on every
            // existing row is the truth.
            ("source_highlights", "references_json", "TEXT"),
            // Schema 141: a mark's since-publication update and when it was
            // written. NULL on every existing row is the truth.
            ("source_highlights", "publication_update", "TEXT"),
            ("source_highlights", "publication_update_at", "REAL"),
            // Schema 142: a course quiz's SF Symbol and drawn picture. NULL on
            // every existing row is the truth — no quiz had either before.
            ("course_quizzes", "symbol", "TEXT"),
            ("course_quizzes", "artwork", "BLOB"),
            // How far into the source the learner actually got that day, as a
            // 0...1 fraction. `kinds` records that an interaction happened;
            // opening a reader for two seconds and reading the whole article
            // were previously indistinguishable, so consumption could only ever
            // be a completion flag. Defaulting to 0 keeps every pre-v66 row
            // honest: unknown depth, not zero depth (`hasMeasuredDepth`).
            ("source_activity_days", "max_fraction", "REAL NOT NULL DEFAULT 0"),
            // Schema 94: time actually spent with the source that day, from the
            // reader heartbeat and playback. 0 on older rows means unmeasured;
            // readers fall back to the day's activity span
            // (`SourceActivityDay.engagedTime`).
            ("source_activity_days", "engaged_seconds", "REAL NOT NULL DEFAULT 0"),
            ("global_artifacts", "is_draft", "INTEGER NOT NULL DEFAULT 0"),
            // Schema 90: the Google Docs edit URL of a linked doc. NULL is the
            // truth about every existing row — a doc whose body is its own
            // Markdown — so nothing is backfilled and the column costs one
            // ALTER TABLE, whatever the library's size.
            ("global_artifacts", "linked_url", "TEXT"),
            // Schema 106: when a doc or site was archived. NULL on every
            // existing row is the truth — nothing was archived before — so the
            // column costs one ALTER TABLE, whatever the library's size.
            ("global_artifacts", "archived_at", "REAL"),
            // Schema 117: what the record is when its link would misname it
            // ('animation'). NULL on every existing row is the truth — no
            // record was an animation before — so the column costs one ALTER
            // TABLE, whatever the library's size.
            ("global_artifacts", "kind", "TEXT"),
            // The reader-selection context a message was sent with: the quoted
            // passage, its section, and the doc it came from. Held only in
            // memory before v84, so reopening a chat started from a doc handed
            // the model the learner's question with the passage stripped out of
            // it, and the follow-up was answered blind. Older rows stay NULL —
            // unknown context, which is the truth about them.
            ("review_exchanges", "context_content", "TEXT"),
            // A staged digest says only "not acknowledged yet", which cannot
            // tell a batch in the air from one abandoned days ago. Counting the
            // staging passes and dating the first one separates them. Existing
            // rows take the defaults rather than a guessed history: attempt
            // zero with no dates reads as unknown, and the next save stamps the
            // truth.
            ("sync_asset_digests", "staged_attempts", "INTEGER NOT NULL DEFAULT 0"),
            ("sync_asset_digests", "first_staged_at", "REAL"),
            ("sync_asset_digests", "last_staged_at", "REAL"),
            // Schema 85's completeness marker, retired by schema 167: the test
            // that earned it passed transcripts the cap had cut, and
            // `podcast_transcript_audits` holds the audit's findings now. The
            // column stays for the stores that have it, neither read nor
            // written.
            ("podcasts", "detruncated_ttml_sha256", "TEXT"),
            // Schema 167: when a failed audit attempt may be tried again. NULL
            // on every existing row is the truth — nothing waits.
            ("podcast_transcript_detruncation_queue", "retry_after", "REAL"),
            // NULL means "never compared against a fresh caption fetch", which is
            // the right reading for every existing row: nothing has ever checked a
            // video transcript against the video it came from.
            ("videos", "legacy_cap_verified_at", "REAL"),
            // The display name of whoever wrote an X post. `StudioArticle.author`
            // carried it in memory, and the author backfill looked it up and
            // "saved" it on every plugin sync, but the x_posts upsert had no
            // column to put it in and the projection never read one — so every
            // reload forgot the names and the next sync named the same posts
            // again (2026-09-02). NULL means "not looked up yet", which is the
            // truth about every existing row.
            ("x_posts", "author", "TEXT"),
            // Memory review, schema 89. Every column is nullable and NULL reads
            // as "not set": a source with no chosen depth takes the default, a
            // chat with no kind is read from its id prefix, an exchange with no
            // coverage was never graded against ideas, and a memory item with
            // no idea was made before ideas existed.
            ("sources", "review_depth", "TEXT"),
            // Teams, schema 96. NULL is the truth about every existing row:
            // everything a library holds today is the learner's own. The sync
            // bookkeeping defaults name the one zone every existing record has
            // always lived in.
            ("sources", "team_id", "TEXT"),
            ("learning_goals", "team_id", "TEXT"),
            ("global_artifacts", "team_id", "TEXT"),
            ("review_sessions", "team_id", "TEXT"),
            ("sync_metadata", "zone_scope", "TEXT NOT NULL DEFAULT 'private'"),
            ("sync_metadata", "zone_name", "TEXT NOT NULL DEFAULT 'Knowledge'"),
            ("sync_metadata", "zone_owner_record_name", "TEXT"),
            ("sync_changes", "zone_scope", "TEXT NOT NULL DEFAULT 'private'"),
            ("sync_changes", "zone_name", "TEXT NOT NULL DEFAULT 'Knowledge'"),
            ("sync_changes", "zone_owner_record_name", "TEXT"),
            ("sync_conflicts", "zone_scope", "TEXT NOT NULL DEFAULT 'private'"),
            ("sync_conflicts", "zone_name", "TEXT NOT NULL DEFAULT 'Knowledge'"),
            ("sync_conflicts", "zone_owner_record_name", "TEXT"),
            ("review_sessions", "kind", "TEXT"),
            ("review_sessions", "briefing", "TEXT"),
            ("review_sessions", "loaded_source_ids", "TEXT"),
            // Schema 149: the effort and speed a chat's last reply was asked
            // for. NULL on every existing row is the truth — no chat kept one.
            ("review_sessions", "model_effort", "TEXT"),
            ("review_sessions", "model_speed", "TEXT"),
            ("review_exchanges", "idea_coverage", "TEXT"),
            ("review_exchanges", "question_verdict", "TEXT"),
            ("review_exchanges", "operation", "TEXT"),
            ("review_exchanges", "steer", "TEXT"),
            ("memory_items", "idea_id", "TEXT"),
            // The learner's thumb on a tutor turn, schema 93. NULL rating is
            // unrated; rated_at is the unit's clock for sync (see the
            // ReviewSession upsert), so a taken-back thumb keeps its stamp.
            ("review_exchanges", "rating", "TEXT"),
            ("review_exchanges", "rating_reason", "TEXT"),
            ("review_exchanges", "rating_field", "TEXT"),
            ("review_exchanges", "rated_at", "REAL"),
            // Schema 129: which of the source's ideas the chats folded into
            // this document actually engaged. An empty list on every existing
            // row is the truth — no close before this one recorded it — and it
            // reads as "nothing known", which leaves the review asking about
            // the whole source exactly as it did yesterday. The next day close
            // writes the real set.
            ("source_understanding", "discussed_idea_ids", "TEXT NOT NULL DEFAULT '[]'"),
            // Schema 137: the family plan code the team's owner handed it.
            // NULL on every existing row is the truth — no team was a family
            // before.
            ("teams", "family_plan_code", "TEXT"),
            // Schema 145: the team whose library a course is a copy in. NULL
            // on every existing row is the truth — no course was a team's
            // before.
            ("courses", "team_id", "TEXT"),
            // Schema 146: which try a scheduled run's receipt describes, and
            // when the next is due. 1 and NULL are every existing receipt's
            // truth — no run was tried again before.
            ("scheduled_task_runs", "attempt", "INTEGER NOT NULL DEFAULT 1"),
            ("scheduled_task_runs", "retry_at", "REAL"),
            // Schema 150: the notebook a course lives in. NULL on every
            // existing row is the truth — no course had a home before.
            ("courses", "home_notebook_id", "TEXT"),
            // Schema 169: a book chapter's pages in its book's one file. NULL
            // on every existing row is the truth — every chapter was a file of
            // its own. Not held with 154: this build's book writes name them.
            ("book_sources", "page_start", "INTEGER"),
            ("book_sources", "page_count", "INTEGER"),
        ]
        if includingSchema154 {
            columns += [
                // Schema 154: the schema-v2 logical id, NULL on every row until
                // the generation-2 activation fills it, and the virtual column
                // every v2 join reads, which is the row's own id meanwhile. An
                // ALTER of a virtual column rewrites no row. wire_id comes first
                // because wire_key is computed from it. On learning_goals the
                // v2 kind and redirects come first, in CREATE TABLE's order,
                // all NULL until the activation derives them.
                ("sources", "wire_id", "TEXT"),
                ("sources", "wire_key", Self.wireKeyDefinition),
                ("learning_goals", "entity_kind", "TEXT"),
                ("learning_goals", "merged_into", "TEXT"),
                ("learning_goals", "fold_kind", "TEXT"),
                ("learning_goals", "moving_to", "TEXT"),
                ("learning_goals", "moved_to", "TEXT"),
                ("learning_goals", "wire_id", "TEXT"),
                ("learning_goals", "wire_key", Self.wireKeyDefinition),
                ("review_sessions", "wire_id", "TEXT"),
                ("review_sessions", "wire_key", Self.wireKeyDefinition),
                ("global_artifacts", "wire_id", "TEXT"),
                ("global_artifacts", "wire_key", Self.wireKeyDefinition),
                ("courses", "wire_id", "TEXT"),
                ("courses", "wire_key", Self.wireKeyDefinition),
                // Schema 156: an Entry's fractional key, NULL until the
                // generation-2 activation derives it from sequence and
                // added_at (WP8).
                ("learning_goal_items", "order_key", "TEXT"),
                // Schema 157: what the Course, Lesson, lesson Entry and Quiz
                // records need (WP9), NULL until the generation-2 activation
                // derives them: a course's created date, a lesson's and an
                // item's fractional keys, an item's span and the n of its
                // Entry's `#n`. A quiz's revision is 1 on every existing row,
                // which is the truth: no quiz has a second revision before
                // generation 2 counts them.
                ("courses", "created_at", "REAL"),
                ("course_lectures", "order_key", "TEXT"),
                ("course_lecture_items", "order_key", "TEXT"),
                ("course_lecture_items", "span_json", "TEXT"),
                ("course_lecture_items", "span_slot", "INTEGER"),
                ("course_quizzes", "revision", "INTEGER NOT NULL DEFAULT 1"),
            ] + Self.chatSyncColumns + [
                // Schema 159: a Doc body's FileRef, NULL until the
                // generation-2 activation or the body publisher writes it
                // (WP11).
                ("global_artifacts", "body_ref", "TEXT"),
                // Schema 162: what the Task and Automation records need
                // (WP14), NULL until the generation-2 activation derives
                // them: a task's board key, the Mac that runs an automation,
                // a run's slot in its ring.
                ("notebook_tasks", "order_key", "TEXT"),
                ("scheduled_tasks", "runner_device_id", "TEXT"),
                ("scheduled_task_runs", "ring_slot", "TEXT"),
            ]
        }

        for column in columns {
            var tableExists = false
            try query(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(column.table)' LIMIT 1"
            ) { _ in
                tableExists = true
            }
            guard tableExists else { continue }

            // table_xinfo, which lists generated columns too: table_info
            // leaves wire_key out and would add it a second time.
            let existingColumns = try tableColumnNamesIncludingGenerated(column.table)
            guard !existingColumns.contains(column.name) else { continue }
            try exec(
                "ALTER TABLE \(column.table) ADD COLUMN \(column.name) \(column.definition)"
            )
        }
    }

    /// Heals `source_projection` when its stored definition drifts from this
    /// build's. A changed view definition otherwise only ever runs for
    /// brand-new databases, so a build that reshaped the view and then read a
    /// new column turned every source query into "no such column" against an
    /// existing store — the whole library rendered as empty while the data sat
    /// intact (2026-07-23). The view owns no rows, so it is safe to re-derive at
    /// launch. Replacement is transactional because the app can hold multiple
    /// connections to the same database; readers must continue seeing the old
    /// projection until the new one commits. The common path — stored definition
    /// already matches — stays read-only.
    func reconcileSourceProjectionView() throws {
        let expected = Self.sourceProjectionViewSQL(sourceColumnNames: try tableColumnNames("sources"), readingStates: syncGeneration == .two)

        func storedDefinition() throws -> String? {
            var stored: String?
            try query("SELECT sql FROM sqlite_master WHERE type = 'view' AND name = 'source_projection'") { stmt in
                stored = self.string(stmt, 0)
            }
            return stored
        }

        func definitionMatchesExpected(_ stored: String?) -> Bool {
            guard let stored else { return false }
            // SQLite omits whitespace before CREATE when persisting sqlite_master,
            // while Swift multiline strings retain their source indentation.
            // Interior whitespace remains exact so real definition drift is still
            // detected without turning every healthy launch into a schema write.
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !definitionMatchesExpected(try storedDefinition()) else { return }

        try exec("BEGIN IMMEDIATE")
        var needsRollback = true
        defer {
            if needsRollback {
                try? exec("ROLLBACK")
            }
        }

        // Another connection may have completed the same repair while this one
        // waited for the write lock. Recheck under the lock to avoid needless DDL.
        if !definitionMatchesExpected(try storedDefinition()) {
            try exec("DROP VIEW IF EXISTS source_projection")
            #if DEBUG
            afterSourceProjectionDropForTesting?()
            #endif
            try exec(expected)
        }

        try exec("COMMIT")
        needsRollback = false
    }

    /// The exact `source_projection` definition this build expects. Fresh
    /// database creation, migrations, and the launch-time drift check must all
    /// derive the view from this one string, or the drift comparison stops
    /// meaning anything. The defensive NULL projections also let older supported
    /// source tables reach the additive-column migration safely.
    ///
    /// The view promises exactly one row per source, and every caller depends on
    /// it — several key rows by `id` into a dictionary, which traps the process
    /// on a duplicate. `group_members` is keyed `(source_id, group_id)`, so a
    /// source filed into two groups otherwise fans the join out into two rows
    /// and crashed semantic source search mid-answer (2026-08-31). Pinning the
    /// join to `MIN(group_id)` restores one row per source and preserves what
    /// first-row-wins callers already saw, because the `(source_id, group_id)`
    /// primary key made SQLite emit the lowest `group_id` first anyway.
    ///
    /// With `readingStates` (a generation-2 store, schema v2 §3.5.18, §4.3) the
    /// reading columns come from the member's `reading_states` row on the
    /// source's wire id, never from `sources`, and a hidden or visible mark
    /// counts whether it names the row's own id or its wire id, so a team copy
    /// and the personal copy read one state. Generation 1's view is unchanged.
    static func sourceProjectionViewSQL(sourceColumnNames: Set<String>, readingStates: Bool = false) -> String {
        let sourcePublicURLProjection = sourceColumnNames.contains("public_url")
            ? "s.public_url"
            : "NULL AS public_url"
        let sourceReadingPositionPageProjection = sourceColumnNames.contains("reading_position_page")
            ? "s.reading_position_page"
            : "NULL AS reading_position_page"
        let sourceReadingPositionLocatorProjection = sourceColumnNames.contains("reading_position_locator")
            ? "s.reading_position_locator"
            : "NULL AS reading_position_locator"
        let sourceReadAtProjection = sourceColumnNames.contains("read_at")
            ? "s.read_at"
            : "NULL AS read_at"
        let sourcePluginLabelProjection = sourceColumnNames.contains("connector_label")
            ? "s.connector_label"
            : "NULL AS connector_label"
        let sourceTeamIDProjection = sourceColumnNames.contains("team_id")
            ? "s.team_id"
            : "NULL AS team_id"
        // Generation 2: the member's reading state on the wire id, and marks on either id.
        let readingColumns = (readingStates
            ? [
                "rs.position AS reading_position_page",
                ReadingLocatorCodec.macLocatorSQL("rs.locator_json") + " AS reading_position_locator",
                "rs.read_at AS read_at",
            ]
            : [sourceReadingPositionPageProjection, sourceReadingPositionLocatorProjection, sourceReadAtProjection]
        ).joined(separator: ",\n        ")
        func marked(_ table: String) -> String {
            "EXISTS (SELECT 1 FROM \(table) mark WHERE mark.source_id IN (s.id, s.wire_key))"
        }
        let hiddenSource = readingStates ? marked("hidden_sources") : "hs.source_id IS NOT NULL"
        let hiddenEpisode = readingStates ? marked("hidden_podcast_episodes") : "hpe.source_id IS NOT NULL"
        let episodeNotOverridden = readingStates ? "NOT " + marked("visible_podcast_episode_overrides") : "vpeo.source_id IS NULL"
        let videoNotOverridden = readingStates ? "NOT " + marked("visible_youtube_video_overrides") : "vyvo.source_id IS NULL"
        let videoOverrideJoin = readingStates ? "" : "\n    LEFT JOIN visible_youtube_video_overrides vyvo ON vyvo.source_id = s.id"
        let markJoins = (readingStates
            ? ["LEFT JOIN reading_states rs ON rs.wire_id = s.wire_key"]
            : [
                "LEFT JOIN hidden_sources hs ON hs.source_id = s.id",
                "LEFT JOIN hidden_podcast_episodes hpe ON hpe.source_id = s.id",
                "LEFT JOIN visible_podcast_episode_overrides vpeo ON vpeo.source_id = s.id",
            ]
        ).map { "\n    " + $0 }.joined()

        return """
            CREATE VIEW source_projection AS
            SELECT
                s.id,
                s.date_added,
                s.state,
                s.error_message,
                s.source_type,
                s.existing_card_count,
                s.status,
                s.archived_at,
                \(sourcePublicURLProjection),
                \(readingColumns),
                CASE
                    WHEN \(hiddenSource) THEN 1
                    WHEN \(hiddenEpisode) THEN 1
                    WHEN \(episodeNotOverridden) AND EXISTS (
                        SELECT 1
                        FROM hidden_podcast_shows hps
                        WHERE hps.show_name = pod.domain
                           OR hps.show_name = pod.show_name
                    ) THEN 1
                    WHEN \(videoNotOverridden) AND EXISTS (
                        SELECT 1
                        FROM hidden_youtube_channels hyc
                        WHERE hyc.channel_name = v.domain
                    ) THEN 1
                    ELSE 0
                END AS is_hidden,
                CASE
                    WHEN \(episodeNotOverridden) AND EXISTS (
                        SELECT 1
                        FROM hidden_podcast_shows hps
                        WHERE hps.show_name = pod.domain
                           OR hps.show_name = pod.show_name
                    ) THEN 1
                    WHEN \(videoNotOverridden) AND EXISTS (
                        SELECT 1
                        FROM hidden_youtube_channels hyc
                        WHERE hyc.channel_name = v.domain
                    ) THEN 1
                    ELSE 0
                END AS is_collection_hidden,
                COALESCE(a.url, p.url, pod.url, bs.url, cs.url, ms.url, v.url, xp.url) AS url,
                COALESCE(a.local_file_path, p.local_file_path, pod.local_file_path, bs.local_file_path, cs.local_file_path, ms.local_file_path, v.local_file_path, xp.local_file_path) AS local_file_path,
                COALESCE(a.normalized_url, p.normalized_url, pod.normalized_url, bs.normalized_url, cs.normalized_url, ms.normalized_url, v.normalized_url, xp.normalized_url) AS normalized_url,
                COALESCE(
                    a.title,
                    p.title,
                    pod.title,
                    bs.title,
                    cs.title,
                    ms.title,
                    v.title,
                    CASE
                        WHEN xp.title IS NOT NULL AND xp.title != '' THEN xp.title
                        WHEN xp.post_text IS NOT NULL AND xp.post_text != '' THEN substr(replace(replace(xp.post_text, char(10), ' '), char(13), ' '), 1, 80)
                        ELSE xp.url
                    END
                ) AS title,
                COALESCE(a.domain, p.domain, pod.domain, bs.domain, cs.domain, ms.domain, v.domain, xp.domain, '') AS domain,
                COALESCE(a.discovery_origin, p.discovery_origin, pod.discovery_origin, bs.discovery_origin, cs.discovery_origin, ms.discovery_origin, v.discovery_origin, xp.discovery_origin) AS discovery_origin,
                COALESCE(a.word_count, p.word_count, pod.word_count, bs.word_count, cs.word_count, ms.word_count, v.word_count, xp.word_count) AS word_count,
                COALESCE(a.artwork_url, p.artwork_url, pod.artwork_url, bs.artwork_url, cs.artwork_url, ms.artwork_url, v.artwork_url, xp.artwork_url) AS artwork_url,
                COALESCE(a.author, p.author, ms.presenter, xp.author) AS author,
                p.journal,
                p.published_year,
                p.is_paywalled,
                p.doi,
                p.published_doi,
                p.paper_ingestion_method,
                p.paywall_suspicion,
                pod.web_page_url AS podcast_web_page_url,
                v.liked_at,
                v.video_published_at,
                gm.group_id AS parent_group,
                COALESCE(book_meta.title, course_meta.title, video_playlist_meta.title, meeting_meta.title) AS parent_group_title,
                gm.sort_index AS group_sort_index,
                gm.lecture_group_id,
                bs.page_start AS book_page_start,
                bs.page_count AS book_page_count,
                \(sourcePluginLabelProjection),
                \(sourceTeamIDProjection)
            FROM sources s
            LEFT JOIN articles a ON a.source_id = s.id
            LEFT JOIN papers p ON p.source_id = s.id
            LEFT JOIN podcasts pod ON pod.source_id = s.id
            LEFT JOIN book_sources bs ON bs.source_id = s.id
            LEFT JOIN course_sources cs ON cs.source_id = s.id
            LEFT JOIN meeting_sources ms ON ms.source_id = s.id
            LEFT JOIN videos v ON v.source_id = s.id
            LEFT JOIN x_posts xp ON xp.source_id = s.id
            LEFT JOIN group_members gm
                ON gm.source_id = s.id
               AND gm.group_id = (
                   SELECT MIN(g2.group_id) FROM group_members g2 WHERE g2.source_id = s.id
               )\(videoOverrideJoin)
            LEFT JOIN books book_meta ON book_meta.id = gm.group_id
            LEFT JOIN courses course_meta ON course_meta.id = gm.group_id
            LEFT JOIN video_playlists video_playlist_meta ON video_playlist_meta.id = gm.group_id
            LEFT JOIN meeting_groups meeting_meta ON meeting_meta.id = gm.group_id\(markJoins)
        """
    }
}

extension KnowledgeStore {
    /// Schema 98: `feynman_*` becomes `review_*`. `ALTER TABLE … RENAME` keeps
    /// every row and index and rewrites the foreign keys that point at the
    /// table, so this is DDL only whatever the library size. The indexes that
    /// carried the old name are dropped so the installer's `CREATE INDEX IF
    /// NOT EXISTS` under the new names does not leave a duplicate pair; the
    /// one index whose name never carried the method name (`idx_fss_source`)
    /// follows its table untouched.
    ///
    /// A store that already has a table under the new name beside the old one
    /// is not something any build wrote, so it is refused and the migration
    /// rolls back rather than guessing which of the two holds the learner's
    /// reviews.
    func renameReviewTablesForSchema98() throws {
        let renames = [
            ("feynman_sessions", "review_sessions"),
            ("feynman_exchanges", "review_exchanges"),
            ("feynman_session_sources", "review_session_sources"),
            ("feynman_session_history_digests", "review_session_history_digests"),
        ]
        var existing = Set<String>()
        try query("SELECT name FROM sqlite_master WHERE type = 'table'") { stmt in
            if let name = self.string(stmt, 0) { existing.insert(name) }
        }
        for (old, new) in renames {
            guard existing.contains(old) else { continue }
            guard !existing.contains(new) else {
                throw KnowledgeStoreError.invalidData(
                    "Cannot rename \(old): a table named \(new) already exists."
                )
            }
            try exec("ALTER TABLE \(old) RENAME TO \(new)")
        }
        for index in ["idx_feynman_exchanges_rated", "idx_feynman_exchanges_session", "idx_feynman_sessions_team"] {
            try exec("DROP INDEX IF EXISTS \(index)")
        }
    }
}

// MARK: - Schema 131: lessons become walkthroughs

extension KnowledgeStore {
    /// The lesson record as schema 130 wrote it, read only here: the shape
    /// `PaperLesson` had before the feature was folded into walkthroughs.
    fileprivate struct LegacyLesson: Decodable {
        struct Question: Decodable {
            var answer: String?
            var keyPoints: [String]?
            var targetPanel: String?
            private enum CodingKeys: String, CodingKey {
                case answer
                case keyPoints = "key_points"
                case targetPanel = "target_panel"
            }
        }
        struct Moment: Decodable {
            var id: String
            var kind: String?
            var text: String
            var anchor: PaperWalkthroughAnchor?
            var more: [PaperWalkthroughMore]?
            var question: Question?
            var sourceMention: String?
            private enum CodingKeys: String, CodingKey {
                case id, kind, text, anchor, more, question
                case sourceMention = "source_mention"
            }
        }
        struct Chapter: Decodable {
            var id: String
            var title: String
            var claim: String?
            var moments: [Moment]
        }
        var sourceID: String
        var sourceSHA256: String
        var title: String
        var chapters: [Chapter]
        var generatedAt: Date
        var author: PaperWalkthrough.Author?
        private enum CodingKeys: String, CodingKey {
            case sourceID = "source_id"
            case sourceSHA256 = "source_sha256"
            case title, chapters
            case generatedAt = "generated_at"
            case author
        }

        /// The lesson as the walkthrough it becomes: a chapter per chapter, a
        /// step per moment — one beat, the moment's words — a question step
        /// for each of the four question kinds, the chips and the authors'
        /// sentence carried over.
        var walkthrough: PaperWalkthrough? {
            var steps: [PaperWalkthroughStep] = []
            var chapters: [PaperWalkthroughChapter] = []
            for (chapterIndex, chapter) in self.chapters.enumerated() {
                var ids: [String] = []
                for (momentIndex, moment) in chapter.moments.enumerated() {
                    let text = moment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let id = moment.id.isEmpty ? "ch-\(chapterIndex + 1)-m\(momentIndex + 1)" : moment.id
                    var quiz: PaperWalkthroughQuiz?
                    var kind: PaperWalkthroughStep.Kind = moment.anchor?.figureLabel == nil ? .explain : .figure
                    let quizKind: PaperWalkthroughQuiz.Kind?
                    switch moment.kind ?? "context" {
                    case "think_first": quizKind = .thinkFirst
                    case "predict": quizKind = .predict
                    case "find": quizKind = .find
                    case "explain": quizKind = .recall
                    default: quizKind = nil
                    }
                    if let quizKind, let answer = moment.question?.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
                        quiz = PaperWalkthroughQuiz(
                            question: text,
                            answer: answer,
                            keyPoints: moment.question?.keyPoints ?? [],
                            kind: quizKind,
                            targetPanel: quizKind == .find ? moment.question?.targetPanel : nil
                        )
                        kind = .quiz
                    }
                    steps.append(PaperWalkthroughStep(
                        id: id,
                        kind: kind,
                        title: chapter.title.isEmpty ? "Chapter \(chapterIndex + 1)" : chapter.title,
                        body: text,
                        anchor: moment.anchor,
                        quiz: quiz,
                        sourceMention: moment.sourceMention,
                        beats: quiz == nil ? [PaperWalkthroughBeat(text: text)] : nil,
                        more: moment.more ?? []
                    ))
                    ids.append(id)
                }
                guard !ids.isEmpty else { continue }
                chapters.append(PaperWalkthroughChapter(
                    id: chapter.id.isEmpty ? "ch-\(chapters.count + 1)" : chapter.id,
                    title: chapter.title,
                    claim: chapter.claim ?? "",
                    stepIDs: ids
                ))
            }
            guard !steps.isEmpty else { return nil }
            return PaperWalkthrough(
                sourceID: sourceID,
                sourceSHA256: sourceSHA256,
                title: title,
                steps: steps,
                chapters: chapters,
                generatedAt: generatedAt,
                author: author ?? .app
            )
        }
    }

    /// Schema 131: every `artifact_lessons` row becomes its source's
    /// walkthrough (kept where the source has none or the lesson is newer),
    /// its artifact is archived and queued for sync, and the table is
    /// dropped. Runs inside the migration transaction; a store that never
    /// had the table does nothing.
    fileprivate func adoptLessonsAsWalkthroughs() throws {
        var hasTable = false
        try query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'artifact_lessons' LIMIT 1") { _ in hasTable = true }
        guard hasTable else { return }

        struct Row { let artifactID: String; let json: String; let generatedAt: Double }
        var rows: [Row] = []
        try query("SELECT artifact_id, lesson_json, generated_at FROM artifact_lessons ORDER BY generated_at ASC LIMIT 500") { stmt in
            guard let artifactID = self.string(stmt, 0), let json = self.string(stmt, 1) else { return }
            rows.append(Row(artifactID: artifactID, json: json, generatedAt: sqlite3_column_double(stmt, 2)))
        }
        let now = Date()
        for row in rows {
            if let lesson = try? PaperWalkthroughCoding.decoder().decode(LegacyLesson.self, from: Data(row.json.utf8)),
               let walkthrough = lesson.walkthrough,
               let json = try? PaperWalkthroughCoding.json(walkthrough) {
                var sourceExists = false
                try queryBind("SELECT 1 FROM sources WHERE id = ? LIMIT 1", bind: { stmt in
                    self.bind(stmt, 1, walkthrough.sourceID)
                }) { _ in sourceExists = true }
                if sourceExists {
                    try execBind("""
                        INSERT INTO source_walkthroughs
                            (source_id, source_sha256, walkthrough_json, walkthrough_version, generated_at)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(source_id) DO UPDATE SET
                            source_sha256 = excluded.source_sha256,
                            walkthrough_json = excluded.walkthrough_json,
                            walkthrough_version = excluded.walkthrough_version,
                            generated_at = excluded.generated_at
                        WHERE excluded.generated_at > source_walkthroughs.generated_at
                    """) { stmt in
                        bind(stmt, 1, walkthrough.sourceID)
                        bind(stmt, 2, walkthrough.sourceSHA256)
                        bind(stmt, 3, json)
                        sqlite3_bind_int(stmt, 4, Int32(walkthrough.version))
                        sqlite3_bind_double(stmt, 5, walkthrough.generatedAt.timeIntervalSinceReferenceDate)
                    }
                    try markRecordChanged(entity: .source, logicalKey: walkthrough.sourceID, at: now)
                }
            }
            // The lesson artifact leaves the gallery as an archived record —
            // an ordinary synced state — never as a deletion that would need
            // a tombstone to stay gone.
            try execBind("UPDATE global_artifacts SET archived_at = ?, updated_at = ? WHERE id = ? AND archived_at IS NULL") { stmt in
                bind(stmt, 1, now.timeIntervalSinceReferenceDate)
                bind(stmt, 2, now.timeIntervalSinceReferenceDate)
                bind(stmt, 3, row.artifactID)
            }
            try markRecordChanged(entity: .artifact, logicalKey: row.artifactID, at: now)
        }
        try exec("DROP INDEX IF EXISTS idx_artifact_lessons_source")
        try exec("DROP TABLE IF EXISTS artifact_lessons")
    }
}

// MARK: - Schema 164: a notebook is no longer called a project

extension KnowledgeStore {
    /// The tables schema 164 renames, as `(old, new)`.
    static let projectStorageTableRenames: [(old: String, new: String)] = [
        ("project_files", "notebook_files"),
        ("project_tasks", "notebook_tasks"),
        ("project_course_links", "notebook_course_links"),
        ("project_related_project_links", "notebook_related_notebook_links"),
        ("global_artifact_project_links", "global_artifact_notebook_links"),
        ("journal_watch_excluded_projects", "journal_watch_excluded_notebooks"),
    ]

    /// The columns schema 164 renames, as `(table after the table renames, old, new)`.
    static let projectStorageColumnRenames: [(table: String, old: String, new: String)] = [
        ("learning_goals", "parent_project_id", "parent_notebook_id"),
        ("courses", "home_project_id", "home_notebook_id"),
        ("global_artifacts", "home_project_id", "home_notebook_id"),
        ("global_artifact_notebook_links", "project_id", "notebook_id"),
        ("notebook_related_notebook_links", "project_id", "notebook_id"),
        ("notebook_related_notebook_links", "related_project_id", "related_notebook_id"),
        ("notebook_tasks", "project_id", "notebook_id"),
        ("notebook_files", "project_id", "notebook_id"),
        ("scheduled_tasks", "project_id", "notebook_id"),
        ("journal_article_matches", "project_id", "notebook_id"),
        ("journal_watch_excluded_notebooks", "project_id", "notebook_id"),
        ("time_blocks", "project_id", "notebook_id"),
        ("learning_bouts", "project_id", "notebook_id"),
    ]

    /// Schema 164 (2026-10-04, the product owner: "they shouldn't be called projects
    /// internally anymore"): the tables and columns that said project say
    /// notebook. In place and idempotent, so a store held below 154 and opened
    /// again, or one whose tables were already laid down under the new names,
    /// is left as it is. ALTER TABLE RENAME keeps rows, indexes, foreign keys
    /// and the triggers on the tables. An index that carries the old word in its
    /// name is dropped and made again, under its new name, by the installer that
    /// runs next (`dropsRetiredIndexes`; a store held at 153, which runs no
    /// installer, keeps them until the launch that lays down 154). The
    /// back-pointer view names the tables in its rows, so it is made again; the
    /// generation-2 outbox, which names them in its rows too, follows. A table
    /// named like a rename's target rolls the whole migration back, as schema
    /// 98's does. Catalog writes and a few UPDATEs on small tables, none of them per row.
    func renameProjectStorageForSchema164(dropsRetiredIndexes: Bool = true) throws {
        var existing = Set<String>()
        var views = Set<String>()
        try query("SELECT type, name FROM sqlite_master WHERE type IN ('table', 'view')") { stmt in
            guard let type = self.string(stmt, 0), let name = self.string(stmt, 1) else { return }
            if type == "view" { views.insert(name) } else { existing.insert(name) }
        }
        // The view's rows carry table names as text, which no rename rewrites.
        let remakesChildrenView = views.contains("ck_notebook_children")
        if remakesChildrenView {
            try exec("DROP VIEW ck_notebook_children")
        }
        for (old, new) in Self.projectStorageTableRenames {
            guard existing.contains(old) else { continue }
            guard !existing.contains(new) else {
                throw KnowledgeStoreError.invalidData(
                    "Cannot rename \(old): a table named \(new) already exists."
                )
            }
            try exec("ALTER TABLE \(old) RENAME TO \(new)")
            existing.remove(old)
            existing.insert(new)
        }
        for (table, old, new) in Self.projectStorageColumnRenames where existing.contains(table) {
            let columns = try tableColumnNames(table)
            guard columns.contains(old), !columns.contains(new) else { continue }
            try exec("ALTER TABLE \(table) RENAME COLUMN \(old) TO \(new)")
        }
        if dropsRetiredIndexes {
            var staleIndexes: [String] = []
            try query("""
                SELECT name FROM sqlite_master
                WHERE type = 'index'
                  AND name LIKE 'idx\\_%project%' ESCAPE '\\'
                  AND name NOT LIKE '%projection%'
                  AND name NOT LIKE '%unprojected%'
            """) { stmt in
                if let name = self.string(stmt, 0) { staleIndexes.append(name) }
            }
            for index in staleIndexes {
                try exec("DROP INDEX IF EXISTS \(index)")
            }
        }
        if remakesChildrenView {
            try createNotebookChildrenView()
        }
        // The generation-2 outbox keys its rows by table and column name (schema 154).
        for outbox in ["ck_outbox", "ck_outbox_fields"] where existing.contains(outbox) {
            for (old, new) in Self.projectStorageTableRenames {
                try execute("UPDATE \(outbox) SET source_table = ? WHERE source_table = ?", [.text(new), .text(old)])
            }
        }
        if existing.contains("ck_outbox_fields") {
            for (table, old, new) in Self.projectStorageColumnRenames {
                try execute(
                    "UPDATE ck_outbox_fields SET \"column\" = ? WHERE source_table = ? AND \"column\" = ?",
                    [.text(new), .text(table), .text(old)]
                )
            }
        }
        // Stored kind values: the same rows, the same meaning.
        if existing.contains("idea_links") {
            try exec("UPDATE idea_links SET kind = 'notebook' WHERE kind = 'project'")
        }
        if existing.contains("research_directions") {
            try exec("UPDATE research_directions SET home_kind = 'notebook' WHERE home_kind = 'project'")
        }
        // The usage ledger keeps the subject type each row was written with: it is a record of
        // what happened, and rewriting it would scan the whole ledger (0.65 s on 62,110 rows).
    }

    /// Whether the store still holds a table or column under the name schema
    /// 164 retires: one catalog read.
    func holdsRetiredProjectStorageNames() throws -> Bool {
        let tables = Self.projectStorageTableRenames.map { "'\($0.old)'" }.joined(separator: ", ")
        var holds = false
        try query("""
            SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name IN (\(tables)))
                OR EXISTS(SELECT 1 FROM pragma_table_info('learning_goals') WHERE name = 'parent_project_id')
        """) { stmt in
            holds = sqlite3_column_int(stmt, 0) != 0
        }
        return holds
    }
}
