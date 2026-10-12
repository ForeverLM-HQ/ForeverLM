import Foundation

// MARK: - The notes graph's storage side (docs/notes-graph-design.md)
//
// What the editor, the Docs pane, Ideas, the Reader and MCP ask of the notes
// graph. Derived from the Docs' stored Markdown, never indexed in SQLite: each
// Doc's parse (`DocGraphParser`) is remembered by its `updatedAt`
// (`DocGraphParseCache`), as `artifactsLinked(toSource:)` remembers its
// citations, so a question rereads only the Docs that changed. Everything
// here runs on the storage actor, off the main actor.
//
// A library answers for itself: a Doc in My Library sees My Library's Docs, a
// team Doc its team's (`teamID`), because a link cannot be followed into a
// library the reader does not have. The pages of the graph are the library's
// Markdown Docs (`kind` nil, not linked pages), hidden ones included; team
// drafts (`TeamContentIdentity`) and archived Docs are not pages, and neither
// is a body that says it is a mnemonic reading or an audio overview. Ideas
// are My Library's, so only My Library's graph lists them.

/// One page of the graph: a Doc, the revision it was read at, its blocks.
struct DocGraphPage: Sendable {
    let artifact: ArtifactRecord
    let revision: String
    let parse: DocGraphParse
}

extension StorageService {

    /// Every page whose blocks point at `target`, newest edit first, daily
    /// notes among them by their day: blocks linking the Doc (by id, by title
    /// link or tag), the Idea or the source, or referencing or embedding the
    /// block. For a Doc or a source, the Ideas linked to it come too, as
    /// `.idea` groups with no blocks. The target's own blocks are not listed.
    ///
    /// A Doc is pointed at by its id, by its title (`[[Title]]`, `#tag`,
    /// `#[[Two words]]`, compared normalized), and a daily note in My Library
    /// by any title that names its day. A source is pointed at by a
    /// `foreverlm://source` or `foreverlm://grounding` address naming it or
    /// its book (`book:<id>`, as `artifactsLinked(toSource:)` reads them), and
    /// by a web address the library resolves to it. A member's draft of a
    /// team Doc answers for the team Doc it drafts. Archived Ideas are left
    /// out, as archived Docs are. A daily note's group sorts by the earlier of
    /// its last edit and the end of its day, so a late edit to an old day does
    /// not lift it above the days after it.
    func docGraphLinkedReferences(to target: DocGraphTarget, teamID: String?) throws -> [DocGraphReferenceGroup] {
        let store = try notebookFilesKnowledgeStore()
        let artifacts = try store.loadArtifacts()
        let pages = docGraphPages(from: artifacts, teamID: teamID)
        var groups: [DocGraphReferenceGroup]
        switch target {
        case .doc(let requestedID):
            let doc = Self.docGraphDraftedDoc(requestedID, among: artifacts)
                ?? artifacts.first { $0.id == requestedID }
            let docID = doc?.id ?? requestedID
            let ids: Set<String> = [docID, requestedID]
            let title = doc.map { DocGraphSyntax.normalizedTitle($0.title) } ?? ""
            let dayKey = teamID == nil ? DailyNote.dayKey(ofID: docID) : nil
            groups = Self.docGraphGroups(pages, skippingDocs: ids) { block in
                block.links.docIDs.contains(where: ids.contains)
                    || (!title.isEmpty && block.links.titles.contains(title))
                    || (dayKey.map(block.links.dayKeys.contains) ?? false)
            }
            if teamID == nil {
                groups += try Self.docGraphIdeaGroups(store.loadIdeas(linkedTo: .artifact, targetID: docID))
            }
        case .idea(let ideaID):
            groups = Self.docGraphGroups(pages) { $0.links.ideaIDs.contains(ideaID) }
        case .source(let sourceID):
            guard let source = try store.loadSourceWithoutContent(sourceID) else {
                throw KnowledgeStoreError.invalidData("Source \(sourceID) does not exist.")
            }
            var tokens: Set<String> = [sourceID]
            if let book = source.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines), !book.isEmpty {
                tokens.insert(book)
                tokens.insert("book:\(book)")
            }
            let resolved = docGraphWebSources(for: pages, teamID: teamID, store: store)
            groups = Self.docGraphGroups(pages) { block in
                !tokens.isDisjoint(with: block.links.sourceTokens)
                    || block.links.webReferences.contains { resolved[$0] == sourceID }
            }
            if teamID == nil {
                groups += try Self.docGraphIdeaGroups(store.loadIdeas(linkedTo: .source, targetID: sourceID))
            }
        case .block(let blockID):
            groups = Self.docGraphGroups(pages, skippingBlock: blockID) { block in
                block.links.blockReferences.contains(blockID) || block.links.embeds.contains(blockID)
            }
        }
        return groups.sorted(by: Self.docGraphGroupOrder)
    }

    /// Where another Doc of the same library writes this Doc's title without
    /// linking it, whole words and case-insensitively, newest edit first. A
    /// title shorter than three characters has none.
    ///
    /// One mention per block, its first: a block that already links the Doc
    /// (by id, title or day) is a linked reference instead, and words inside
    /// links, title links, tags, block references, code and web addresses do
    /// not count. Accents and width are folded as titles are. At most
    /// `docGraphMentionLimit` are listed, for a title common enough to be
    /// everywhere.
    func docGraphUnlinkedMentions(ofDoc docID: String) throws -> [DocGraphMention] {
        let store = try notebookFilesKnowledgeStore()
        let artifacts = try store.loadArtifacts()
        guard let requested = artifacts.first(where: { $0.id == docID }) else {
            throw ArtifactError.unavailable(docID)
        }
        let doc = Self.docGraphDraftedDoc(docID, among: artifacts) ?? requested
        let title = doc.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 3 else { return [] }
        let matcher = DocGraphWordMatcher(title)
        let phrase = matcher.phrase
        guard !phrase.isEmpty else { return [] }
        let normalizedTitle = DocGraphSyntax.normalizedTitle(title)
        let dayKey = doc.teamID == nil ? DailyNote.dayKey(ofID: doc.id) : nil
        let skipped: Set<String> = [doc.id, docID]
        var mentions: [DocGraphMention] = []
        for page in docGraphPages(from: artifacts, teamID: doc.teamID) where !skipped.contains(page.artifact.id) {
            for block in page.parse.blocks where DocGraphText.contains(block.searchText, phrase) {
                if block.links.docIDs.contains(where: skipped.contains)
                    || block.links.titles.contains(normalizedTitle)
                    || (dayKey.map(block.links.dayKeys.contains) ?? false) {
                    continue
                }
                guard let range = matcher.occurrences(in: block.block.markdown).first else { continue }
                mentions.append(DocGraphMention(
                    docID: page.artifact.id,
                    docTitle: page.artifact.title,
                    revision: page.revision,
                    block: block.block,
                    start: range.lowerBound,
                    end: range.upperBound
                ))
                if mentions.count >= Self.docGraphMentionLimit { return mentions }
            }
        }
        return mentions
    }

    /// The most unlinked mentions a page lists.
    static let docGraphMentionLimit = 500

    /// The blocks these ids name, wherever they are in the library, for
    /// drawing `((id))` and embeds; an id no Doc holds is left out. When two
    /// blocks carry the same id (a block copied with its marker), the one in
    /// the Doc made first is the block.
    func docGraphBlocks(_ blockIDs: [String], teamID: String?) throws -> [String: DocGraphBlock] {
        let wanted = Set(blockIDs)
        guard !wanted.isEmpty else { return [:] }
        let index = try docGraphBlockIndex(teamID: teamID, only: wanted)
        return index.mapValues(\.block)
    }

    /// The blocks whose text holds every word of `query`, for `((`: the best
    /// matches first, the Doc being written in included, at most `limit`.
    ///
    /// Words are compared folded (case, accents, width) anywhere in a block's
    /// plain text. Blocks holding the whole query as written, from the start
    /// of a word, come first, then blocks where every word begins a word,
    /// then the rest; within each, the most recently edited Doc first, then
    /// the Doc's own order. An empty query lists the most recently edited
    /// Docs' blocks in order. Empty blocks and embed paragraphs are not
    /// offered.
    func docGraphSearchBlocks(_ query: String, teamID: String?, limit: Int) throws -> [DocGraphBlockHit] {
        let limit = max(1, min(limit, 200))
        let store = try notebookFilesKnowledgeStore()
        let pages = docGraphPages(from: try store.loadArtifacts(), teamID: teamID)
        let words = DocGraphText.foldedWords(query)
        func hit(_ page: DocGraphPage, _ block: DocGraphParsedBlock) -> DocGraphBlockHit {
            DocGraphBlockHit(docID: page.artifact.id, docTitle: page.artifact.title, revision: page.revision, block: block.block)
        }
        if words.isEmpty {
            var hits: [DocGraphBlockHit] = []
            for page in pages {
                for block in page.parse.blocks where !block.searchText.isEmpty && !block.isEmbedOnly {
                    hits.append(hit(page, block))
                    if hits.count == limit { return hits }
                }
            }
            return hits
        }
        let phrase = words.joined(separator: " ")
        var ranked: [(rank: Int, page: Int, block: Int, hit: DocGraphBlockHit)] = []
        for (pageIndex, page) in pages.enumerated() {
            for (blockIndex, block) in page.parse.blocks.enumerated() where !block.isEmbedOnly {
                let text = block.searchText
                guard words.allSatisfy({ DocGraphText.contains(text, $0) }) else { continue }
                let rank: Int
                if DocGraphText.startsWord(phrase, in: text) {
                    rank = 0
                } else if words.allSatisfy({ DocGraphText.startsWord($0, in: text) }) {
                    rank = 1
                } else {
                    rank = 2
                }
                ranked.append((rank, pageIndex, blockIndex, hit(page, block)))
            }
        }
        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.page != rhs.page { return lhs.page < rhs.page }
            return lhs.block < rhs.block
        }
        return ranked.prefix(limit).map(\.hit)
    }

    /// How many times each block of this Doc that has an id is referenced or
    /// embedded elsewhere in the library, for the count beside a block.
    ///
    /// Counted in blocks, as the popover lists them: a block that references
    /// the same block twice counts once. References from this Doc's other
    /// blocks count; a block never counts itself. Blocks nothing references
    /// are left out.
    func docGraphReferenceCounts(inDoc docID: String) throws -> [String: Int] {
        let store = try notebookFilesKnowledgeStore()
        let artifacts = try store.loadArtifacts()
        guard let record = artifacts.first(where: { $0.id == docID }) else {
            throw ArtifactError.unavailable(docID)
        }
        let teamID = Self.docGraphDraftedDoc(docID, among: artifacts)?.teamID ?? record.teamID
        // A draft is no page of the graph, so its own blocks are read here.
        let own: DocGraphParse
        if let page = docGraphPage(record) {
            own = page.parse
        } else {
            own = DocGraphParser.parse(try artifactMarkdown(of: record).markdown, docID: docID)
        }
        let ids = Set(own.blocks.compactMap(\.block.blockID))
        guard !ids.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        for page in docGraphPages(from: artifacts, teamID: teamID) {
            for block in page.parse.blocks {
                let referenced = Set(block.links.blockReferences).union(block.links.embeds).intersection(ids)
                for id in referenced where block.block.blockID != id {
                    counts[id, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// The library's pages by normalized title (`DocGraphSyntax.normalizedTitle`):
    /// what `[[Title]]`, `#tag` and `#[[Two words]]` name. A daily note answers
    /// to its title as well.
    ///
    /// When two pages share a title, the most recently edited one is named.
    /// A daily note answers to its day written out ("October 6th, 2026") even
    /// when it was renamed. Reads no Doc's body.
    func docGraphTitleTargets(teamID: String?) throws -> [String: String] {
        let store = try notebookFilesKnowledgeStore()
        let records = try store.loadArtifacts()
            .filter { Self.isDocGraphPage($0) && $0.teamID == teamID }
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt < $1.updatedAt : $0.id < $1.id }
        var targets: [String: String] = [:]
        for record in records {
            let title = DocGraphSyntax.normalizedTitle(record.title)
            if !title.isEmpty { targets[title] = record.id }
            if teamID == nil, let dayKey = DailyNote.dayKey(ofID: record.id),
               let dayTitle = DailyNote.title(forDayKey: dayKey) {
                targets[DocGraphSyntax.normalizedTitle(dayTitle)] = record.id
            }
        }
        return targets
    }

    /// Gives the block at `key` in another Doc the id `proposedID` (the one
    /// the referencing editor has already written) and saves that Doc, so
    /// `((proposedID))` resolves. A block that already has an id keeps it and
    /// that id is returned. `revision` and `expectedPlainText` say which block
    /// was meant: when the Doc changed since, the block is found again by its
    /// text, and refused (`blockMoved`) when it cannot be.
    func docGraphAssignBlockID(docID: String, key: String, revision: String, expectedPlainText: String, proposedID: String) async throws -> String {
        guard DocGraphSyntax.isBlockID(proposedID) else {
            throw KnowledgeStoreError.invalidData("“\(proposedID)” is not a block id: a block id is nine lowercase letters and digits.")
        }
        for attempt in 0..<2 {
            let snapshot = try artifactMarkdown(docID)
            guard snapshot.artifact.kind == nil, !snapshot.artifact.isLinked else {
                throw DocGraphError.notMarkdown(snapshot.artifact.title)
            }
            let keyIsCurrent = snapshot.revision.caseInsensitiveCompare(revision) == .orderedSame
            guard let edit = DocGraphEditing.assigningBlockID(
                proposedID,
                key: key,
                expectedPlainText: expectedPlainText,
                keyIsCurrent: keyIsCurrent,
                in: snapshot.markdown
            ) else {
                throw DocGraphError.blockMoved(snapshot.artifact.title)
            }
            guard edit.changed else { return edit.blockID }
            do {
                let saved = try await writeArtifactMarkdownAndSync(
                    artifactID: docID,
                    markdown: edit.markdown,
                    expectedRevision: snapshot.revision
                )
                docGraphRemember(saved)
                return edit.blockID
            } catch let error as ArtifactError {
                // Written by someone else between the read and the save: read
                // it again once and find the block in what it says now.
                guard case .conflict = error, attempt == 0 else { throw error }
            }
        }
        throw DocGraphError.blockMoved(try artifactMarkdown(docID).artifact.title)
    }

    /// Turns an unlinked mention into a link to `targetDocID`
    /// (`[the mention's own words](foreverlm://doc/<id>)`) in the Doc that
    /// holds it, and saves it; refused (`mentionMoved`) when that Doc changed
    /// and the mention cannot be found again.
    func docGraphLinkMention(_ mention: DocGraphMention, toDoc targetDocID: String) async throws {
        for attempt in 0..<2 {
            let snapshot = try artifactMarkdown(mention.docID)
            guard snapshot.artifact.kind == nil, !snapshot.artifact.isLinked else {
                throw DocGraphError.notMarkdown(snapshot.artifact.title)
            }
            let keyIsCurrent = snapshot.revision.caseInsensitiveCompare(mention.revision) == .orderedSame
            guard let markdown = DocGraphEditing.linkingMention(
                mention,
                toDoc: targetDocID,
                keyIsCurrent: keyIsCurrent,
                in: snapshot.markdown
            ) else {
                throw DocGraphError.mentionMoved(snapshot.artifact.title)
            }
            do {
                let saved = try await writeArtifactMarkdownAndSync(
                    artifactID: mention.docID,
                    markdown: markdown,
                    expectedRevision: snapshot.revision
                )
                docGraphRemember(saved)
                return
            } catch let error as ArtifactError {
                guard case .conflict = error, attempt == 0 else { throw error }
            }
        }
        throw DocGraphError.mentionMoved(try artifactMarkdown(mention.docID).artifact.title)
    }

    /// The daily note for a day (`DailyNote.dayKey`), made in My Library with
    /// its day's title and an empty body when it does not exist yet. Making
    /// it twice, here or on another Mac, makes one record.
    ///
    /// An existing note is returned as it is, archived or not; making one
    /// that another writer (sync bringing the same day from another Mac) made
    /// in between returns that one.
    func ensureDailyNote(dayKey: String) async throws -> ArtifactRecord {
        guard let title = DailyNote.title(forDayKey: dayKey) else {
            throw KnowledgeStoreError.invalidData("“\(dayKey)” is not a day; a day is written YYYY-MM-DD.")
        }
        let noteID = DailyNote.id(forDayKey: dayKey)
        let store = try notebookFilesKnowledgeStore()
        if let existing = try store.loadArtifact(noteID) { return existing }
        do {
            return try createArtifact(
                title: title,
                homeNotebookID: nil,
                linkedNotebookIDs: [],
                markdown: "",
                teamID: nil,
                artifactID: noteID
            ).artifact
        } catch {
            if let existing = try store.loadArtifact(noteID) { return existing }
            throw error
        }
    }

    /// The working log (`WorkingLog`), a background record that no list shows
    /// (`WorkingMemoryRecords`), made with its seed body when it does not
    /// exist yet. Making it twice, here or on another Mac, makes one record.
    func ensureWorkingLog() async throws -> ArtifactRecord {
        let store = try notebookFilesKnowledgeStore()
        if let existing = try store.loadArtifact(WorkingLog.id) { return existing }
        do {
            return try createArtifact(
                title: WorkingLog.title,
                homeNotebookID: nil,
                linkedNotebookIDs: [],
                markdown: WorkingLog.seedMarkdown,
                teamID: nil,
                artifactID: WorkingLog.id
            ).artifact
        } catch {
            if let existing = try store.loadArtifact(WorkingLog.id) { return existing }
            throw error
        }
    }

    /// What a chat's prompt carries of the working log: its excerpt, nil
    /// while there is no log or nothing has been written in it. Reading never
    /// makes the record; the day close does when it first writes.
    func workingLogPromptExcerpt() async throws -> String? {
        guard let record = try notebookFilesKnowledgeStore().loadArtifact(WorkingLog.id) else { return nil }
        return WorkingLog.promptExcerpt(fromMarkdown: try artifactMarkdown(of: record).markdown)
    }

    /// Forgets the working log: its body goes back to the seed, so no chat is
    /// handed the old summary and the next day close starts afresh. Settings'
    /// Forget All runs it beside forgetting the notes. A newer body (written
    /// on another Mac) is read again, three times.
    func resetWorkingLog() async throws {
        guard try notebookFilesKnowledgeStore().loadArtifact(WorkingLog.id) != nil else { return }
        for attempt in 0..<3 {
            let current = try artifactMarkdown(WorkingLog.id)
            guard current.markdown != WorkingLog.seedMarkdown else { return }
            do {
                _ = try await writeArtifactMarkdownAndSync(
                    artifactID: WorkingLog.id,
                    markdown: WorkingLog.seedMarkdown,
                    expectedRevision: current.revision,
                    versionReason: .assistantEdit
                )
                return
            } catch ArtifactError.conflict where attempt < 2 {
                continue
            }
        }
    }

    /// The daily notes that exist, newest day first: those before `dayKey`
    /// (all when nil), at most `limit`. Archived ones are left out.
    func dailyNotes(before dayKey: String?, limit: Int) throws -> [ArtifactRecord] {
        guard limit > 0 else { return [] }
        let store = try notebookFilesKnowledgeStore()
        var notes: [(day: String, record: ArtifactRecord)] = []
        for record in try store.loadArtifacts() where record.teamID == nil && Self.isDocGraphPage(record) {
            guard let day = DailyNote.dayKey(ofID: record.id) else { continue }
            if let dayKey, day >= dayKey { continue }
            notes.append((day, record))
        }
        return notes.sorted { $0.day > $1.day }.prefix(limit).map(\.record)
    }

    /// A Doc's Markdown as a reader outside the app should get it: `((id))`
    /// replaced by the block's text, an embed by the block and its children,
    /// ` ^id` markers removed, title links and tags read as their words.
    /// Publishing and `read_doc` with `resolve_references` use it.
    ///
    /// Blocks are looked up in `teamID`'s library and in the text itself (a
    /// reference to a block of this Doc resolves before it is saved).
    /// `DocGraphResolver` has the rules; a body with no `((` is never read
    /// against the library.
    func docGraphResolvedMarkdown(_ markdown: String, teamID: String?) throws -> String {
        let index = try docGraphResolutionIndex(markdown, teamID: teamID)
        return DocGraphResolver.resolve(markdown) { index[$0] }
    }

    /// `docGraphResolvedMarkdown`, line for line: an embed reads as its
    /// block's own text on the embed's line, without what is nested under it,
    /// so every other line keeps its number. The Docs pane's Page view draws
    /// this, because its Edit mode names a block by its lines in the draft.
    func docGraphResolvedMarkdownKeepingLines(_ markdown: String, teamID: String?) throws -> String {
        let index = try docGraphResolutionIndex(markdown, teamID: teamID)
        return DocGraphResolver.resolve(markdown, keepingLines: true) { index[$0] }
    }

    /// The blocks a body's references can name: the library's, and the
    /// body's own, which win (a reference to a block of this Doc resolves
    /// before it is saved). Empty for a body with no `((`.
    private func docGraphResolutionIndex(_ markdown: String, teamID: String?) throws -> [String: DocGraphParsedBlock] {
        guard DocGraphText.contains(markdown, "((") else { return [:] }
        var index = try docGraphBlockIndex(teamID: teamID, only: nil)
        for block in DocGraphParser.parse(markdown, docID: "").blocks {
            if let id = block.block.blockID { index[id] = block }
        }
        return index
    }

    /// The library whose graph a Doc's references are read in: its own, or
    /// for a member's draft of a team Doc, the team's.
    func docGraphTeamID(forDoc docID: String) throws -> String? {
        let artifacts = try notebookFilesKnowledgeStore().loadArtifacts()
        if let drafted = Self.docGraphDraftedDoc(docID, among: artifacts) { return drafted.teamID }
        guard let record = artifacts.first(where: { $0.id == docID }) else {
            throw ArtifactError.unavailable(docID)
        }
        return record.teamID
    }

    // MARK: - Pages and their parses

    /// Whether a record is a page of the graph (see the top of this file);
    /// the body's own word on what it is comes in when it is read.
    nonisolated static func isDocGraphPage(_ artifact: ArtifactRecord) -> Bool {
        artifact.kind == nil && !artifact.isLinked && !artifact.isArchived
            && !TeamContentIdentity.isDraftArtifactID(artifact.id)
    }

    /// The library's pages from one listing of the records, in the listing's
    /// order (newest edit first), each parsed once per `updatedAt`.
    func docGraphPages(from artifacts: [ArtifactRecord], teamID: String?) -> [DocGraphPage] {
        var pages: [DocGraphPage] = []
        var present = Set<String>()
        for artifact in artifacts {
            present.insert(artifact.id)
            guard Self.isDocGraphPage(artifact), artifact.teamID == teamID,
                  let page = docGraphPage(artifact) else { continue }
            pages.append(page)
        }
        DocGraphParseCache.shared.keepOnly(present, scope: docGraphCacheScope)
        return pages
    }

    /// A page's parse: remembered, or read and remembered. A body that cannot
    /// be read now (still downloading) is no page this time and is read again
    /// next time.
    private func docGraphPage(_ artifact: ArtifactRecord) -> DocGraphPage? {
        if let entry = DocGraphParseCache.shared.entry(scope: docGraphCacheScope, artifactID: artifact.id, updatedAt: artifact.updatedAt) {
            return entry.isPage ? DocGraphPage(artifact: artifact, revision: entry.revision, parse: entry.parse) : nil
        }
        guard let snapshot = try? artifactMarkdown(of: artifact) else { return nil }
        return docGraphRemember(snapshot)
    }

    /// Parses a body and remembers it by the record's `updatedAt`; a save the
    /// graph made itself is remembered as it is written.
    @discardableResult
    private func docGraphRemember(_ snapshot: ArtifactMarkdownSnapshot) -> DocGraphPage? {
        let isPage = !MnemonicReading.isReadingMarkdown(snapshot.markdown)
            && !AudioOverviewScript.isOverviewMarkdown(snapshot.markdown)
        let parse = isPage ? DocGraphParser.parse(snapshot.markdown, docID: snapshot.artifact.id) : .empty
        DocGraphParseCache.shared.store(
            DocGraphParseCache.Entry(updatedAt: snapshot.artifact.updatedAt, revision: snapshot.revision, isPage: isPage, parse: parse),
            scope: docGraphCacheScope,
            artifactID: snapshot.artifact.id
        )
        return isPage ? DocGraphPage(artifact: snapshot.artifact, revision: snapshot.revision, parse: parse) : nil
    }

    /// The cache is the process's; each store keeps its own part of it.
    private var docGraphCacheScope: String { libraryRootURL.standardizedFileURL.path }

    /// Every block with an id in a library (or only `wanted` ones). When two
    /// carry one id, the block in the Doc made first wins, then the first in
    /// its Doc.
    private func docGraphBlockIndex(teamID: String?, only wanted: Set<String>?) throws -> [String: DocGraphParsedBlock] {
        let store = try notebookFilesKnowledgeStore()
        let pages = docGraphPages(from: try store.loadArtifacts(), teamID: teamID)
            .sorted { $0.artifact.createdAt != $1.artifact.createdAt ? $0.artifact.createdAt < $1.artifact.createdAt : $0.artifact.id < $1.artifact.id }
        var index: [String: DocGraphParsedBlock] = [:]
        for page in pages {
            for block in page.parse.blocks {
                guard let id = block.block.blockID, index[id] == nil else { continue }
                if let wanted, !wanted.contains(id) { continue }
                index[id] = block
            }
        }
        return index
    }

    /// The source each web address in the pages resolves to, in their
    /// library, by `librarySourceIDs(forReferenceURLs:teamID:)`. Remembered
    /// until the library's sources change (`docGraphSourceStamp`), so opening
    /// a source's references twice resolves each address once.
    private func docGraphWebSources(for pages: [DocGraphPage], teamID: String?, store: KnowledgeStore) -> [String: String] {
        let addresses = Set(pages.flatMap { $0.parse.blocks.flatMap(\.links.webReferences) })
        guard !addresses.isEmpty else { return [:] }
        let scope = docGraphCacheScope + "\u{0}" + (teamID ?? "")
        guard let stamp = try? store.docGraphSourceStamp(teamID: teamID) else {
            return librarySourceIDs(forReferenceURLs: Array(addresses), teamID: teamID)
        }
        var known = DocGraphParseCache.shared.resolvedAddresses(scope: scope, stamp: stamp)
        let unknown = addresses.filter { known[$0] == nil }
        if !unknown.isEmpty {
            let found = librarySourceIDs(forReferenceURLs: Array(unknown), teamID: teamID)
            for address in unknown { known[address] = found[address] ?? "" }
            DocGraphParseCache.shared.storeResolvedAddresses(known, scope: scope, stamp: stamp)
        }
        return known.filter { !$0.value.isEmpty && addresses.contains($0.key) }
    }

    // MARK: - Answers

    /// The team Doc a member's draft drafts, or nil when `docID` is no draft.
    nonisolated static func docGraphDraftedDoc(_ docID: String, among artifacts: [ArtifactRecord]) -> ArtifactRecord? {
        guard TeamContentIdentity.isDraftArtifactID(docID) else { return nil }
        return artifacts.first { artifact in
            guard let teamID = artifact.teamID else { return false }
            return TeamContentIdentity.draftArtifactID(teamID: teamID, teamArtifactID: artifact.id) == docID
        }
    }

    nonisolated static func docGraphGroups(
        _ pages: [DocGraphPage],
        skippingDocs skipped: Set<String> = [],
        skippingBlock skippedBlock: String? = nil,
        where points: (DocGraphParsedBlock) -> Bool
    ) -> [DocGraphReferenceGroup] {
        pages.compactMap { page in
            guard !skipped.contains(page.artifact.id) else { return nil }
            let blocks = page.parse.blocks
                .filter { block in
                    if let skippedBlock, block.block.blockID == skippedBlock { return false }
                    return points(block)
                }
                .map(\.block)
            guard !blocks.isEmpty else { return nil }
            return DocGraphReferenceGroup(
                kind: DailyNote.isDailyNoteID(page.artifact.id) && page.artifact.teamID == nil ? .dailyNote : .doc,
                id: page.artifact.id,
                title: page.artifact.title,
                updatedAt: page.artifact.updatedAt,
                blocks: blocks
            )
        }
    }

    nonisolated static func docGraphIdeaGroups(_ ideas: [IdeaRecord]) -> [DocGraphReferenceGroup] {
        ideas.filter { !$0.isArchived }.map { idea in
            DocGraphReferenceGroup(kind: .idea, id: idea.id, title: idea.title, updatedAt: idea.updatedAt, blocks: [])
        }
    }

    /// Newest first; a daily note at the earlier of its last edit and the end
    /// of its day.
    nonisolated static func docGraphGroupOrder(_ lhs: DocGraphReferenceGroup, _ rhs: DocGraphReferenceGroup) -> Bool {
        let left = docGraphSortDate(lhs)
        let right = docGraphSortDate(rhs)
        if left != right { return left > right }
        if lhs.title != rhs.title { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
        return lhs.id < rhs.id
    }

    private nonisolated static func docGraphSortDate(_ group: DocGraphReferenceGroup) -> Date {
        guard group.kind == .dailyNote,
              let dayKey = DailyNote.dayKey(ofID: group.id),
              let start = DailyNote.date(forDayKey: dayKey),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return group.updatedAt }
        return min(group.updatedAt, end)
    }
}

extension KnowledgeStore {
    /// A value that changes when the sources a web address can resolve to
    /// change in a library: one added, archived, restored or deleted, or a
    /// paper's DOI learned. The graph's resolved addresses live as long as it.
    func docGraphSourceStamp(teamID: String?) throws -> String {
        var stamp = ""
        try queryBind("""
            SELECT (SELECT COUNT(*) FROM sources WHERE team_id IS ?1)
                || ':' || (SELECT COUNT(*) FROM sources WHERE team_id IS ?1 AND status = 'active')
                || ':' || (SELECT COALESCE(MAX(date_added), 0) FROM sources WHERE team_id IS ?1)
                || ':' || (SELECT COUNT(doi) + COUNT(published_doi) FROM papers)
            """, bind: { statement in
                self.bind(statement, 1, teamID)
            }) { statement in
            stamp = self.string(statement, 0) ?? ""
        }
        return stamp
    }
}

/// Each Markdown Doc's parse, remembered by the Doc's `updatedAt` so a
/// question over the library never rereads a Doc that has not changed, and
/// the sources the library's web addresses resolve to. In memory only: the
/// answer is derivable from the Docs at any time, and a database index would
/// be a second copy of the truth to keep right. Entries are kept per store
/// (`scope`), so two stores in one process — tests — never share answers.
final class DocGraphParseCache: @unchecked Sendable {
    struct Entry: Sendable {
        let updatedAt: Date
        let revision: String
        /// False for a body that says it is not a Doc (a mnemonic reading, an
        /// audio overview saved without its kind).
        let isPage: Bool
        let parse: DocGraphParse
    }

    static let shared = DocGraphParseCache()
    private let lock = NSLock()
    private var entries: [String: [String: Entry]] = [:]
    private var addresses: [String: (stamp: String, sources: [String: String])] = [:]

    func entry(scope: String, artifactID: String, updatedAt: Date) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[scope]?[artifactID], entry.updatedAt == updatedAt else { return nil }
        return entry
    }

    func store(_ entry: Entry, scope: String, artifactID: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[scope, default: [:]][artifactID] = entry
    }

    /// Forgets the Docs a store no longer has.
    func keepOnly(_ artifactIDs: Set<String>, scope: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = entries[scope], current.keys.contains(where: { !artifactIDs.contains($0) }) else { return }
        entries[scope] = current.filter { artifactIDs.contains($0.key) }
    }

    /// The addresses resolved under `stamp`, address → source id ("" for
    /// none); nothing when the stamp moved on.
    func resolvedAddresses(scope: String, stamp: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard let known = addresses[scope], known.stamp == stamp else { return [:] }
        return known.sources
    }

    func storeResolvedAddresses(_ sources: [String: String], scope: String, stamp: String) {
        lock.lock()
        defer { lock.unlock() }
        addresses[scope] = (stamp, sources)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        addresses.removeAll()
    }
}
