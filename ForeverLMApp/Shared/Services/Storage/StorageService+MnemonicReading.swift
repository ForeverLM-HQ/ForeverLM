import Foundation
import OSLog

// MARK: - Mnemonic readings in storage
//
// docs/memory-design.md, "Mnemonic reading". A reading is an Artifact of kind
// `.mnemonicReading`, its body the questions (`MnemonicReading`): homed on the
// notebook it was made in, grounded on its sources in reading order. A
// source's questions are saved into it as they are written, each quote
// checked against the source's text; answering one of them writes the
// learner's Memory (`KnowledgeStore+MnemonicReading`).

/// What `saveMnemonicReadingSection` did with one source's questions.
struct MnemonicReadingSectionSaved: Equatable, Sendable {
    let readingID: String
    /// The questions added, as the reading holds them.
    var added: [MnemonicQuestion] = []
    /// Questions the reading already held under the same id.
    var alreadyWritten = 0
    /// Questions whose quote the source's text does not print: not saved.
    var ungrounded: [MnemonicQuestion] = []
    /// Questions the body would not give back whole: not saved.
    var unreadable: [MnemonicQuestion] = []
    /// Whether this save made the reading.
    var created = false
}

extension StorageService {
    private static let readingLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "MnemonicReading"
    )

    // MARK: Answers

    /// A grade the learner gave a reading's question, kept or answered by
    /// Memory's rules (`KnowledgeStore.recordMnemonicReadingAnswer`).
    func recordMnemonicReadingAnswer(
        _ question: MnemonicQuestion,
        remembered: Bool,
        sittingKey: String,
        at now: Date = Date()
    ) throws -> MnemonicReadingAnswer {
        let answer = try notebookFilesKnowledgeStore().recordMnemonicReadingAnswer(
            question,
            remembered: remembered,
            sittingKey: sittingKey,
            at: now
        )
        if answer.outcome.wroteAttempt {
            scheduleSoonCloudKitSyncForMnemonicReadings()
        }
        return answer
    }

    /// Where each of a reading's questions stands in the learner's Memory,
    /// by question id (`KnowledgeStore.mnemonicReadingMemory`). Reads only.
    func mnemonicReadingMemory(for questions: [MnemonicQuestion]) throws -> [String: MnemonicQuestionMemory] {
        try notebookFilesKnowledgeStore().mnemonicReadingMemory(for: questions)
    }

    // MARK: The reading

    /// A reading and its questions, read from its body. Throws for a record
    /// that is not a reading — by its kind, or by its body's marker when an
    /// older build saved it back without the kind — and for a body still
    /// downloading from iCloud.
    func mnemonicReading(_ readingID: String) throws -> (artifact: ArtifactRecord, reading: MnemonicReading) {
        let snapshot = try artifactMarkdown(readingID)
        guard snapshot.artifact.isMnemonicReading(markdown: snapshot.markdown) else {
            throw KnowledgeStoreError.invalidData("‘\(snapshot.artifact.title)’ is not a mnemonic reading.")
        }
        return (snapshot.artifact, MnemonicReading.parse(snapshot.markdown, fallbackTitle: snapshot.artifact.title))
    }

    /// The readings grounded on any of `sourceIDs`, oldest first: what the
    /// Reader's PDF draws its questions from. One pass over the records, so a
    /// book's many chapters ask once.
    func mnemonicReadings(groundedOn sourceIDs: [String]) throws -> [ArtifactRecord] {
        let wanted = Set(sourceIDs)
        return try notebookFilesKnowledgeStore().loadArtifacts()
            .filter {
                $0.kind == .mnemonicReading
                    && !TeamContentIdentity.isDraftArtifactID($0.id)
                    && !wanted.isDisjoint(with: $0.sourceIDs)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Writes one source's questions into the reading `readingID`: each
    /// question's quote is checked against the source's text
    /// (`MemoryGroundingText`, the matcher its Memory item will be grounded
    /// with) and one the text does not print is returned in `ungrounded` and
    /// never saved; the rest join the source's section, which is marked
    /// written (`MnemonicReading.writing`). A reading that does not exist yet
    /// is made from `skeleton` — every source's section pending but this one —
    /// as an Artifact of kind `.mnemonicReading` homed on its notebook and
    /// grounded on its sources; without a skeleton a missing reading throws
    /// (it was deleted while being written). A team's copies of the
    /// learner's reading follow it (`refreshMnemonicReadingTeamCopies`).
    /// Throws for a source with no text, and a body still downloading.
    @discardableResult
    func saveMnemonicReadingSection(
        readingID: String,
        sourceID: String,
        sourceTitle: String,
        questions: [MnemonicQuestion],
        creatingWith skeleton: MnemonicReadingSkeleton?
    ) throws -> MnemonicReadingSectionSaved {
        let store = try notebookFilesKnowledgeStore()
        guard let content = try store.loadSourceContent(sourceID),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData("Source \(sourceID) has no text yet, so no question can follow a passage of it.")
        }
        let grounding = MemoryGroundingText(content)
        var result = MnemonicReadingSectionSaved(readingID: readingID)
        var grounded: [MnemonicQuestion] = []
        for question in questions {
            // Every question stands on the section's source, under the id its
            // content mints there.
            let own = question.sourceID == sourceID ? question : MnemonicQuestion.mint(
                sourceID: sourceID,
                quote: question.quote,
                question: question.question,
                answer: question.answer,
                why: question.why
            )
            if grounding.contains(own.quote) {
                grounded.append(own)
            } else {
                result.ungrounded.append(own)
            }
        }

        if let existing = try store.loadArtifact(readingID) {
            let snapshot = try artifactMarkdown(readingID)
            guard existing.isMnemonicReading(markdown: snapshot.markdown) else {
                throw KnowledgeStoreError.invalidData("‘\(existing.title)’ is not a mnemonic reading.")
            }
            let reading = MnemonicReading.parse(snapshot.markdown, fallbackTitle: existing.title)
            let written = reading.writing(grounded, in: sourceID, title: sourceTitle)
            result.added = written.added
            result.alreadyWritten = written.alreadyWritten.count
            result.unreadable = written.unreadable
            if written.reading != reading {
                _ = try writeArtifactMarkdown(
                    artifactID: readingID,
                    markdown: written.reading.markdown,
                    expectedRevision: snapshot.revision
                )
                if !existing.sourceIDs.contains(sourceID), existing.teamID == nil {
                    var record = try store.loadArtifact(readingID) ?? existing
                    record.sourceIDs.append(sourceID)
                    try store.saveArtifactRecord(record)
                }
            }
        } else {
            guard let skeleton else { throw MnemonicReadingError.readingGone(readingID) }
            let reading = MnemonicReading(title: skeleton.title, sections: skeleton.sections.map {
                MnemonicReading.Section(sourceID: $0.sourceID, title: MnemonicReading.singleLine($0.title))
            })
            let written = reading.writing(grounded, in: sourceID, title: sourceTitle)
            result.added = written.added
            result.alreadyWritten = written.alreadyWritten.count
            result.unreadable = written.unreadable
            _ = try createArtifact(
                title: skeleton.title,
                homeNotebookID: skeleton.notebookID,
                linkedNotebookIDs: skeleton.notebookID.map { [$0] } ?? [],
                markdown: written.reading.markdown,
                artifactID: readingID,
                sourceIDs: written.reading.sections.map(\.sourceID),
                kind: .mnemonicReading
            )
            result.created = true
        }
        refreshMnemonicReadingTeamCopies(readingID, store: store)
        scheduleSoonCloudKitSyncForMnemonicReadings()
        return result
    }

    /// A reading of the learner's own that a team holds a copy of (made when
    /// its notebook was shared with the team) is rewritten here each time a
    /// source's questions land, since a reading's copy is never edited in the
    /// team — nobody's answers are in it, only the questions. Never throws: the learner's own write has happened.
    private func refreshMnemonicReadingTeamCopies(_ readingID: String, store: KnowledgeStore) {
        do {
            guard let reading = try store.loadArtifact(readingID), reading.teamID == nil else { return }
            let teams = try store.teamsHoldingArtifact(readingID).filter(\.canEdit)
            for team in teams {
                _ = try shareArtifact(readingID, withTeam: team.id, scheduleSync: false)
            }
            guard !teams.isEmpty else { return }
            scheduleImmediateCloudKitSyncForTeams()
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        } catch {
            Self.readingLogger.error("A team copy of reading \(readingID, privacy: .public) did not follow it: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Books

    /// A book's chapters in reading order, by its id or its title as
    /// `list_sources` shows it (case aside): its id, title and chapter ids.
    /// Nil when no book answers to it.
    func bookChapters(named book: String) throws -> (bookID: String, title: String, sourceIDs: [String])? {
        try notebookFilesKnowledgeStore().bookChapters(named: book)
    }
}

extension KnowledgeStore {
    /// A reading's body as a team's copy holds it: each source's section
    /// names the team's copy of the source (`teamSourceCopyID`), which the
    /// copy's grounding carries into the team, so a member reads the reading
    /// over the team's sources. The questions keep their ids, so a member who
    /// also holds the learner's own copy answers one card.
    func mnemonicReadingTeamCopyBody(_ markdown: String, fallbackTitle: String, teamID: String) throws -> String {
        var reading = MnemonicReading.parse(markdown, fallbackTitle: fallbackTitle)
        reading.sections = try reading.sections.map { section in
            guard let source = try loadSourceWithoutContent(section.sourceID), source.teamID != teamID else { return section }
            let copyID = try teamSourceCopyID(teamID: teamID, url: source.url)
            return MnemonicReading.Section(
                sourceID: copyID,
                title: section.title,
                isWritten: section.isWritten,
                questions: section.questions.map { question in
                    var copied = question
                    copied.sourceID = copyID
                    return copied
                }
            )
        }
        return reading.markdown
    }

    /// A book's active chapters in reading order (`group_sort_index`, then
    /// title), by the book's id or its title, case aside.
    func bookChapters(named rawBook: String) throws -> (bookID: String, title: String, sourceIDs: [String])? {
        let book = rawBook.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !book.isEmpty else { return nil }
        var rows: [(id: String, group: String, groupTitle: String, index: Int?, title: String)] = []
        try queryBind("""
            SELECT id, parent_group, COALESCE(parent_group_title, parent_group), group_sort_index, title
            FROM source_projection
            WHERE source_type = 'book' AND status = 'active'
              AND parent_group IS NOT NULL AND parent_group <> ''
              AND (parent_group = ? OR COALESCE(parent_group_title, parent_group) = ? COLLATE NOCASE)
        """, bind: { statement in
            self.bind(statement, 1, book)
            self.bind(statement, 2, book)
        }) { statement in
            guard let id = self.string(statement, 0), let group = self.string(statement, 1) else { return }
            rows.append((
                id,
                group,
                self.string(statement, 2) ?? group,
                self.optionalInt(statement, 3),
                self.string(statement, 4) ?? ""
            ))
        }
        // A book is one group: the one its id names, else the first its title names.
        guard let group = rows.first(where: { $0.group == book })?.group ?? rows.first?.group else { return nil }
        let chapters = rows.filter { $0.group == group }.sorted { lhs, rhs in
            switch (lhs.index, rhs.index) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
        return (group, chapters.first?.groupTitle ?? group, chapters.map(\.id))
    }
}
