import Foundation

// MARK: - A notebook's outputs
//
// What the Studio column lists under its tiles (docs/notebooks-design.md,
// "Studio"): the things filed in the notebook — Docs, Sites, animations and
// audio overviews homed on it or linked to it, and the courses it follows —
// and the things derived from its sources, their walkthroughs, spoken
// explainers and narrations, the Make Cards runs on its sources and the
// standalone pictures homed in it. Newest first, by when each was made. Since
// 2026-10-06 the one-off kinds — pictures, animations, audio overviews,
// films, walkthroughs, narrations — are listed here alone: the Notebooks
// home's Docs tab keeps only Docs, Sites and Ideas. Pure, so membership and
// order are tested without a view or a store; the view model feeds it what it
// has loaded (`StudioViewModel+NotebookOutputs.swift`).
//
// Membership is a handful of small named functions on purpose: the shared
// notebook-membership predicate (docs/notebooks-design.md, "Homing") takes
// their place once it lands, and every list here follows it.

/// One row of a notebook's outputs.
struct NotebookOutput: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case doc
        case site
        case animation
        case audioOverview
        case course
        case walkthrough
        case explainer
        case videoOverview
        /// A mnemonic reading: the sources' text with questions in it.
        case mnemonicReading
        /// One Make Cards run on the notebook's sources: the cards it
        /// drafted, which wait in To Check.
        case cards
        /// A standalone picture homed in the notebook
        /// (`GeneratedImageStore.ImageGroup.notebookID`).
        case picture
        /// A source's narration: the source read aloud, made once and
        /// shared by every notebook holding the source (`SourceNarration`).
        case narration
    }

    let kind: Kind
    /// What opening it names: the record's id for a Doc, Site, animation or
    /// audio overview (a run's reserved id while it is written); the
    /// course's id; the walked source's id; the explainer's own source id;
    /// the video's own source id; a Make Cards run's time
    /// (`NotebookOutputs.CardRun.id`); a picture's image id; the narrated
    /// source's id.
    let targetID: String
    let title: String
    /// The sources it was made from, in order: a record's grounding, a
    /// course's sources, the one source a walkthrough or an explainer is of.
    /// Empty when the record names none.
    let sourceIDs: [String]
    /// When it was made: a record's creation, a walk's writing, an
    /// explainer's arrival, a run's start, a course's newest source. Nil when
    /// nothing says, for a course whose sources this library does not hold.
    let date: Date?
    /// The words it was made to, when the record keeps them; nil today for
    /// every kind. A report keeps its whole recipe in its body ("Made from 6
    /// sources · Briefing · …"), and its row's menu reads that line instead
    /// (`StudioViewModel.reportRecipe(_:)`).
    var instruction: String? = nil
    /// An audio overview still being written: listed first, opened by
    /// nothing until it is saved.
    var isPending: Bool = false
    /// A linked record's kind (a Site's product), for its glyph.
    var linkedKind: LinkedPageKind? = nil
    /// The team whose record this is; nil for the learner's own.
    var teamID: String? = nil
    /// How many cards a Make Cards run drafted; nil for every other kind.
    var cardCount: Int? = nil

    var id: String { "\(kind.rawValue):\(targetID)" }

    /// The glyph the row leads with: each kind's mark where the app already
    /// has one (the Docs tab's chips, the Courses rail row, the explainer's
    /// lightbulb, the Reader's Listen).
    var symbolName: String {
        switch kind {
        case .doc: return "note.text"
        case .site: return linkedKind?.symbolName ?? "globe"
        case .animation: return ArtifactKind.animation.symbolName
        case .audioOverview: return ArtifactKind.audioOverview.symbolName
        case .course: return "graduationcap"
        case .walkthrough: return "figure.walk"
        case .explainer: return "lightbulb.fill"
        case .videoOverview: return "play.rectangle.fill"
        case .mnemonicReading: return ArtifactKind.mnemonicReadingSymbolName
        case .cards: return MemoryReviewSession.sidebarIcon
        case .picture: return "photo"
        case .narration: return "speaker.wave.2"
        }
    }

    /// The kind in a word, for VoiceOver and the row's help.
    var kindLabel: String {
        switch kind {
        case .doc: return "Page"
        case .site: return linkedKind?.label ?? "Site"
        case .animation: return ArtifactKind.animation.label
        case .audioOverview: return ArtifactKind.audioOverview.label
        case .course: return "Course"
        case .walkthrough: return "Walkthrough"
        case .explainer: return "Explainer"
        case .videoOverview: return "Video overview"
        case .mnemonicReading: return MnemonicReading.kindLabel
        case .cards: return "Cards"
        case .picture: return "Picture"
        case .narration: return "Narration"
        }
    }
}

enum NotebookOutputs {
    /// An audio overview being written for a notebook
    /// (`AudioOverviewGenerationCoordinator.Run`, as the view model hands it over).
    struct Run: Equatable, Sendable {
        let id: String
        let notebookID: String?
        let title: String
        let startedAt: Date
    }

    /// A course in this library, with its sources in study order.
    struct Course: Equatable, Sendable {
        let id: String
        let title: String
        let sourceIDs: [String]
        /// When its newest source arrived; nil when the library holds none.
        let date: Date?
    }

    /// A source's walkthrough: the walk's own title, or its source's.
    struct Walkthrough: Equatable, Sendable {
        let sourceID: String
        let title: String
        let date: Date
    }

    /// A video the notebook holds as one of its sources and plays in the
    /// Reader — a video overview brought in from Gemini Notebook, or an
    /// explainer film made here (`GeneratedExplainerVideo`).
    struct VideoOverview: Equatable, Sendable {
        let sourceID: String
        let title: String
        let date: Date
    }

    /// One Make Cards run on the notebook's sources, read back from their
    /// draft decks (`cardRuns`): the cards a request drafted, which every
    /// card of one run carries as one drafting time.
    struct CardRun: Equatable, Sendable {
        /// When the run drafted, to the second: every card of a run is
        /// stamped with its start (`CardDraftingService.run`).
        let draftedAt: Date
        let cardCount: Int
        /// The notebook's sources it drafted, in the order first met.
        let sourceIDs: [String]

        /// The run's output id: its drafting time in whole seconds.
        var id: String { String(Int64(draftedAt.timeIntervalSince1970.rounded(.down))) }
    }

    /// A standalone picture homed in a notebook.
    struct Picture: Equatable, Sendable {
        let imageID: String
        /// The notebook it lives in (`ImageGroup.notebookID`).
        let notebookID: String?
        let title: String
        /// Its latest version's.
        let date: Date
    }

    /// A source's narration, made: the source's own title, since the
    /// narration is the source read aloud, and when it was made.
    struct Narration: Equatable, Sendable {
        let sourceID: String
        let title: String
        let date: Date
    }

    /// The Make Cards runs on `memberSourceIDs`, newest first: the cards the
    /// learner asked for (`Flashcard.isRequested` — Make Cards, or an
    /// assistant's `draft_cards`), drafted by ForeverLM rather than written
    /// by an assistant, grouped by their one drafting time. A run is the
    /// notebook's through the sources it drafted, the derived rule a
    /// walkthrough follows: Make Cards from the Reader on a source the
    /// notebook holds shows here too, and only the cards on its members are
    /// counted. Background drafting's cards are not runs: they are the
    /// Cards row's "to check".
    static func cardRuns(_ decks: [MemoryCardDraftDeck], memberSourceIDs: Set<String>) -> [CardRun] {
        var cardsByTime: [Date: Int] = [:]
        var sourcesByTime: [Date: [String]] = [:]
        for deck in decks.sorted(by: { $0.sourceID < $1.sourceID }) where memberSourceIDs.contains(deck.sourceID) {
            for card in deck.deck.cards where card.isRequested && (card.origin == nil || card.origin == .drafted) {
                guard let draftedAt = card.draftedAt else { continue }
                cardsByTime[draftedAt, default: 0] += 1
                if !(sourcesByTime[draftedAt]?.contains(deck.sourceID) ?? false) {
                    sourcesByTime[draftedAt, default: []].append(deck.sourceID)
                }
            }
        }
        return cardsByTime
            .map { CardRun(draftedAt: $0.key, cardCount: $0.value, sourceIDs: sourcesByTime[$0.key] ?? []) }
            .sorted { $0.draftedAt > $1.draftedAt }
    }

    /// "12 drafted from 3 sources": a run's second line before its age,
    /// under its title, Cards.
    static func cardRunLine(cardCount: Int, sourceCount: Int) -> String {
        let cards = "\(cardCount) drafted"
        guard let sources = sourcesLabel(count: sourceCount) else { return cards }
        return "\(cards) from \(sources)"
    }

    /// A spoken explainer: its own source, and the source it explains.
    struct Explainer: Equatable, Sendable {
        let id: String
        let explainedSourceID: String
        let title: String
        let date: Date
    }

    // MARK: Membership

    /// Whether a record is filed in the notebook: homed on it, or linked to
    /// it — the filed rule every surface shares (`NotebookMembership`).
    /// Making a record with a home also links it there
    /// (`StorageService.createArtifact`); the home counts on its own as well,
    /// so a record whose links an older build trimmed is not lost.
    static func isFiled(_ record: ArtifactRecord, in notebookID: String) -> Bool {
        NotebookMembership.isFiled(in: notebookID, notebookIDs: NotebookMembership.filingNotebookIDs(of: record))
    }

    /// Whether a record is listed at all: not archived, not hidden, and not
    /// a team member's private draft of a team Doc, which opens through Edit
    /// on the team's copy (the web's `notebookOutputs` keeps the same rule).
    static func isListed(_ record: ArtifactRecord) -> Bool {
        !record.isArchived && !record.isHidden && !TeamContentIdentity.isDraftArtifactID(record.id)
    }

    /// Whether an audio overview being written is the notebook's.
    static func isRun(_ run: Run, for notebookID: String) -> Bool {
        run.notebookID == notebookID
    }

    /// Whether the notebook follows a course (`notebook_course_links`): the
    /// only tie between a course and a notebook
    /// (`NotebookMembership.filingNotebookIDs(followedBy:)`).
    static func isCourseFiled(_ courseID: String, linkedCourseIDs: Set<String>) -> Bool {
        linkedCourseIDs.contains(courseID)
    }

    /// Whether something derived from one source — its walkthrough, its
    /// explainer, its narration — shows in the notebook: the source is one of its members,
    /// named as the library names it. It shows in every notebook holding the
    /// source (the derived rule, `NotebookMembership`).
    static func isDerived(fromSource sourceID: String, memberSourceIDs: Set<String>) -> Bool {
        NotebookMembership.isDerived(sourceID: sourceID, from: memberSourceIDs)
    }

    // MARK: Building

    /// Everything the notebook made or its sources gave rise to, newest
    /// first (`ordered`), each once. `audioOverviewIDs` names the records
    /// that are audio overviews though their kind does not say so (saved
    /// back by an older build; `StudioViewModel.isAudioOverview`).
    static func outputs(
        in notebookID: String,
        memberSourceIDs: Set<String>,
        records: [ArtifactRecord],
        audioOverviewIDs: Set<String> = [],
        runs: [Run] = [],
        courses: [Course] = [],
        linkedCourseIDs: Set<String> = [],
        walkthroughs: [Walkthrough] = [],
        explainers: [Explainer] = [],
        videoOverviews: [VideoOverview] = [],
        cardRuns: [CardRun] = [],
        pictures: [Picture] = [],
        narrations: [Narration] = []
    ) -> [NotebookOutput] {
        var outputs: [NotebookOutput] = []
        for run in runs where isRun(run, for: notebookID) {
            outputs.append(NotebookOutput(
                kind: .audioOverview,
                targetID: run.id,
                title: run.title,
                sourceIDs: [],
                date: run.startedAt,
                isPending: true
            ))
        }
        for record in records where isListed(record) && isFiled(record, in: notebookID) {
            outputs.append(NotebookOutput(
                kind: kind(of: record, isAudioOverview: audioOverviewIDs.contains(record.id)),
                targetID: record.id,
                title: record.title,
                sourceIDs: record.sourceIDs,
                date: record.createdAt,
                linkedKind: record.linkedKind,
                teamID: record.teamID
            ))
        }
        for course in courses where isCourseFiled(course.id, linkedCourseIDs: linkedCourseIDs) {
            outputs.append(NotebookOutput(
                kind: .course,
                targetID: course.id,
                title: course.title,
                sourceIDs: course.sourceIDs,
                date: course.date
            ))
        }
        for walk in walkthroughs where isDerived(fromSource: walk.sourceID, memberSourceIDs: memberSourceIDs) {
            outputs.append(NotebookOutput(
                kind: .walkthrough,
                targetID: walk.sourceID,
                title: walk.title,
                sourceIDs: [walk.sourceID],
                date: walk.date
            ))
        }
        for explainer in explainers
        where isDerived(fromSource: explainer.explainedSourceID, memberSourceIDs: memberSourceIDs) {
            outputs.append(NotebookOutput(
                kind: .explainer,
                targetID: explainer.id,
                title: explainer.title,
                sourceIDs: [explainer.explainedSourceID],
                date: explainer.date
            ))
        }
        for narration in narrations
        where isDerived(fromSource: narration.sourceID, memberSourceIDs: memberSourceIDs) {
            outputs.append(NotebookOutput(
                kind: .narration,
                targetID: narration.sourceID,
                title: narration.title,
                sourceIDs: [narration.sourceID],
                date: narration.date
            ))
        }
        // A video is one of the notebook's own sources, so only a member's
        // shows here: a video in the library that the notebook does not hold
        // is not its output.
        for video in videoOverviews where memberSourceIDs.contains(video.sourceID) {
            outputs.append(NotebookOutput(
                kind: .videoOverview,
                targetID: video.sourceID,
                title: video.title,
                sourceIDs: [],
                date: video.date
            ))
        }
        for run in cardRuns {
            let sources = run.sourceIDs.filter(memberSourceIDs.contains)
            guard !sources.isEmpty else { continue }
            outputs.append(NotebookOutput(
                kind: .cards,
                targetID: run.id,
                title: "Cards",
                sourceIDs: sources,
                date: run.draftedAt,
                cardCount: run.cardCount
            ))
        }
        // A picture is filed by its own notebook, never by its sources: an
        // image lives in one notebook (`GeneratedImageStore.setNotebook`).
        for picture in pictures where picture.notebookID == notebookID {
            outputs.append(NotebookOutput(
                kind: .picture,
                targetID: picture.imageID,
                title: picture.title,
                sourceIDs: [],
                date: picture.date
            ))
        }
        // A run whose record has just been saved is listed once, as saved.
        let savedIDs = Set(outputs.filter { !$0.isPending }.map(\.id))
        var seen = Set<String>()
        let unique = outputs.filter { output in
            guard !(output.isPending && savedIDs.contains(output.id)) else { return false }
            return seen.insert(output.id).inserted
        }
        return ordered(unique)
    }

    /// The record's kind among the outputs: an audio overview by its kind or
    /// the library's word for it, else by the section its link puts it in.
    static func kind(of record: ArtifactRecord, isAudioOverview: Bool) -> NotebookOutput.Kind {
        if isAudioOverview || record.kind == .audioOverview { return .audioOverview }
        if record.kind == .mnemonicReading { return .mnemonicReading }
        switch record.section {
        case .docs: return .doc
        case .sites: return .site
        case .animations: return .animation
        }
    }

    /// Newest first: runs being written lead, then by when each was made —
    /// made, not edited, so a Doc being written in the slot beside the
    /// column does not jump to the top on every save (the Docs list's rule,
    /// the product owner, 2026-09-29). Undated last; ties by title, then id, so the
    /// order never shuffles between redraws.
    static func ordered(_ outputs: [NotebookOutput]) -> [NotebookOutput] {
        outputs.sorted { lhs, rhs in
            if lhs.isPending != rhs.isPending { return lhs.isPending }
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            let byTitle = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    // MARK: Words

    /// "1 source", "3 sources"; nil for none, and the row then says only when.
    static func sourcesLabel(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 source" : "\(count) sources"
    }

    /// An output row's second line before its date, as Gemini Notebook
    /// writes it: "Doc · 4 sources", "Briefing · 6 sources", "Course".
    static func subtitle(kind: String, sourceCount: Int) -> String {
        [kind, sourcesLabel(count: sourceCount)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The recipe on an output's menu: "Made from 3 sources · <instruction>",
    /// either half alone, or nil with neither.
    static func recipe(sourceCount: Int, instruction: String?) -> String? {
        let words = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let made = sourceCount > 0 ? "Made from \(sourcesLabel(count: sourceCount) ?? "")" : nil
        switch (made, words.isEmpty) {
        case let (made?, false): return "\(made) · \(words)"
        case let (made?, true): return made
        case (nil, false): return words
        case (nil, true): return nil
        }
    }
}

/// Which of a notebook's outputs are new on this Mac — made after the Studio
/// first listed outputs here, and not opened since — for the unread dot
/// Gemini Notebook puts on an output nobody has looked at. A per-Mac
/// preference, never a record: opening an output writes nothing synced and
/// moves no date (AGENTS "Opening is a read").
struct NotebookOutputSeenState: Equatable {
    /// When this Mac started keeping track: anything made before reads as
    /// seen, so the first launch with the dot marks nothing.
    var since: Date
    /// The outputs opened since, newest last, kept to `limit`.
    var seenIDs: [String] = []

    /// Far past any learner's opens; an id evicted past it would read new
    /// again, so the cap is a backstop, not a working size.
    static let limit = 2_000

    func isNew(_ output: NotebookOutput) -> Bool {
        guard !output.isPending, let date = output.date, date > since else { return false }
        return !seenIDs.contains(output.id)
    }

    mutating func markSeen(_ outputID: String) {
        guard !seenIDs.contains(outputID) else { return }
        seenIDs.append(outputID)
        if seenIDs.count > Self.limit { seenIDs.removeFirst(seenIDs.count - Self.limit) }
    }
}
