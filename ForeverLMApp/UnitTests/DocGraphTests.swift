import Foundation
import Testing
@testable import ForeverLM

// MARK: - Pure suite

/// The notes graph's reading of a Doc (docs/notes-graph-design.md): which
/// blocks a Doc has, what each is called and points at, and the two edits and
/// the resolution the graph makes. Pure: no store.
@Suite("Notes graph: reading Docs as blocks")
struct DocGraphParserTests {
    /// A research note the way Docs stores one: headings, nested bullets,
    /// an ordered list, a quote, tasks, code with grammar-looking text inside,
    /// an escaped title link and a tag the serializer escaped at a line start.
    static let research = ##"""
    # Mitochondrial quality control

    Mitophagy clears damaged mitochondria. ^mito00001

    ## PINK1 and Parkin

    - PINK1 builds up on depolarised mitochondria ^pink10001
      - It recruits [[Parkin]] from the cytosol
        - Parkin ubiquitinates outer membrane proteins #mechanism
      - See [the review](https://doi.org/10.1000/review-1) and [Mitophagy](foreverlm://doc/doc-mito)
    - Loss of membrane potential is the trigger
    1. First step
    2. Second step

    > Quoted finding about #[[Membrane potential]] ^quote0001
    >
    > A second quoted paragraph

    - [ ] Read the Narendra paper
    - [x] Summarize ((pink10001))

    ```swift
    let x = "[[Not a link]] #nottag ((abcdefghi))"
    ```

        indented code [[Nope]] ((zzzzzzzzz))

    Inline `[[code]]` stays, and \[\[Escaped title\]\] counts.

    \#linestart tag and *emphasis* with **strong** text
    """##

    private func blocks(_ markdown: String, docID: String = "doc") -> [DocGraphParsedBlock] {
        DocGraphParser.parse(markdown, docID: docID).blocks
    }

    @Test("Headings, paragraphs, nested bullets, ordered items, quotes and tasks are blocks, keyed by where they stand")
    func researchNoteBlocks() {
        let parse = DocGraphParser.parse(Self.research, docID: "research")
        let blocks = parse.blocks
        #expect(blocks.map(\.block.key) == [
            "0", "1", "2", "3.0", "3.0.0", "3.0.0.0", "3.0.1", "3.1", "4.0", "4.1", "5", "5~1", "6.0", "6.1", "9", "10",
        ])
        #expect(blocks.map(\.block.kind) == [
            .heading, .paragraph, .heading, .listItem, .listItem, .listItem, .listItem, .listItem, .listItem, .listItem,
            .quote, .quote, .listItem, .listItem, .paragraph, .paragraph,
        ])
        #expect(blocks.allSatisfy { $0.block.docID == "research" })
        #expect(blocks[0].headingLevel == 1)
        #expect(blocks[2].headingLevel == 2)
        #expect(blocks[0].block.line == 0)
        #expect(blocks[3].block.line == 6)
        #expect(parse.verbatimLines == IndexSet([21, 22, 23, 25]), "the fence and the indented code are not read")
    }

    @Test("A block's own text drops its marker, list marker and hashes; its id, plain text and links are read")
    func ownTextAndIDs() {
        let blocks = blocks(Self.research)
        #expect(blocks[1].block.blockID == "mito00001")
        #expect(blocks[1].block.markdown == "Mitophagy clears damaged mitochondria.")
        #expect(blocks[3].block.blockID == "pink10001")
        #expect(blocks[3].block.markdown == "PINK1 builds up on depolarised mitochondria")
        #expect(blocks[4].block.blockID == nil)
        #expect(blocks[6].block.markdown == "See [the review](https://doi.org/10.1000/review-1) and [Mitophagy](foreverlm://doc/doc-mito)")
        #expect(blocks[6].block.plainText == "See the review and Mitophagy")
        #expect(blocks[6].links.webReferences == ["https://doi.org/10.1000/review-1"])
        #expect(blocks[6].links.docIDs == ["doc-mito"])
        #expect(blocks[10].block.blockID == "quote0001")
        #expect(blocks[10].block.markdown == "Quoted finding about #[[Membrane potential]]")
        // A task keeps its box in its Markdown, not in its text.
        #expect(blocks[12].block.markdown == "[ ] Read the Narendra paper")
        #expect(blocks[12].block.plainText == "Read the Narendra paper")
        #expect(blocks[13].block.markdown == "[x] Summarize ((pink10001))")
        #expect(blocks[13].block.plainText == "Summarize ((pink10001))")
        #expect(blocks[13].links.blockReferences == ["pink10001"])
        // Escapes and emphasis are not text; code is, and the grammar stays as written.
        #expect(blocks[14].block.plainText == "Inline [[code]] stays, and [[Escaped title]] counts.")
        #expect(blocks[15].block.plainText == "#linestart tag and emphasis with strong text")
    }

    @Test("Breadcrumbs read outermost first: the section's heading, then the bullets above")
    func breadcrumbs() {
        let blocks = blocks(Self.research)
        #expect(blocks[0].block.breadcrumbs == [])
        #expect(blocks[1].block.breadcrumbs == ["Mitochondrial quality control"])
        #expect(blocks[2].block.breadcrumbs == ["Mitochondrial quality control"], "a heading sits under the heading of a higher level")
        #expect(blocks[3].block.breadcrumbs == ["PINK1 and Parkin"])
        #expect(blocks[4].block.breadcrumbs == ["PINK1 and Parkin", "PINK1 builds up on depolarised mitochondria"])
        #expect(blocks[5].block.breadcrumbs == [
            "PINK1 and Parkin", "PINK1 builds up on depolarised mitochondria", "It recruits [[Parkin]] from the cytosol",
        ])
        #expect(blocks[10].block.breadcrumbs == ["PINK1 and Parkin"])
    }

    @Test("A bullet's children are the Markdown nested under it, unindented")
    func childrenMarkdown() {
        let blocks = blocks(Self.research)
        #expect(blocks[3].block.childrenMarkdown == """
        - It recruits [[Parkin]] from the cytosol
          - Parkin ubiquitinates outer membrane proteins #mechanism
        - See [the review](https://doi.org/10.1000/review-1) and [Mitophagy](foreverlm://doc/doc-mito)
        """)
        #expect(blocks[4].block.childrenMarkdown == "- Parkin ubiquitinates outer membrane proteins #mechanism")
        #expect(blocks[5].block.childrenMarkdown == "")
        #expect(blocks[1].block.childrenMarkdown == "")
    }

    @Test("Title links, tags and escaped forms name pages; nothing in code does")
    func titlesAndTags() {
        let blocks = blocks(Self.research)
        #expect(blocks[4].links.titles == ["parkin"])
        #expect(blocks[5].links.titles == ["mechanism"])
        #expect(blocks[10].links.titles == ["membrane potential"])
        #expect(blocks[14].links.titles == ["escaped title"], "`[[code]]` is code")
        #expect(blocks[15].links.titles == ["linestart"], "a tag the serializer escaped at the start of a line")
        let everything = blocks.flatMap { $0.links.titles + $0.links.blockReferences }
        #expect(!everything.contains("not a link"))
        #expect(!everything.contains("nottag"))
        #expect(!everything.contains("nope"))
        #expect(!everything.contains("abcdefghi"))
        #expect(!everything.contains("zzzzzzzzz"))
    }

    @Test("Bullets nest by indentation: three-space nesting, a second paragraph, a lazy line, an empty item, `1)` lists")
    func nestingRules() {
        let markdown = """
        * Drug discovery
           * What perturbations
           * What model ^model0001
        * Mitonuclear mismatch
          continued on a second line

          A second paragraph in the item ^secpara01
        *
          * Under an empty item
        1) Alpha
        2) Beta
        - First item
        lazy line belongs to it
        """
        let blocks = blocks(markdown)
        #expect(blocks.map(\.block.key) == ["0.0", "0.0.0", "0.0.1", "0.1", "0.1~1", "0.2", "0.2.0", "1.0", "1.1", "2.0"])
        #expect(blocks[1].block.breadcrumbs == ["Drug discovery"])
        #expect(blocks[2].block.blockID == "model0001")
        #expect(blocks[3].block.markdown == "Mitonuclear mismatch\ncontinued on a second line")
        #expect(blocks[3].block.plainText == "Mitonuclear mismatch continued on a second line")
        #expect(blocks[3].block.childrenMarkdown == "A second paragraph in the item ^secpara01")
        #expect(blocks[4].block.kind == .paragraph)
        #expect(blocks[4].block.blockID == "secpara01")
        #expect(blocks[4].block.breadcrumbs == ["Mitonuclear mismatch continued on a second line"])
        #expect(blocks[5].block.markdown == "")
        #expect(blocks[5].block.childrenMarkdown == "* Under an empty item")
        #expect(blocks[6].block.breadcrumbs == [], "an empty bullet is no breadcrumb")
        #expect(blocks[7].block.plainText == "Alpha")
        #expect(blocks[9].block.markdown == "First item\nlazy line belongs to it")
    }

    @Test("Setext headings, lazy quotes and display math read as CommonMark reads them; front matter, tables, HTML, rules and pictures are not blocks")
    func whatIsNotABlock() {
        let markdown = """
        ---
        title: Notes
        ---

        Setext title
        ============

        > quoted start
        lazy quoted

        | Page | Note |
        | --- | --- |
        | [[In a table]] | x |

        <div>
        [[In HTML]]
        </div>

        $$
        x^{abcdefghi} [[In math]]
        $$

        ![A figure](foreverlm://attachment/figure.png)

        ---

        Under it all [[Page]]
        """
        let blocks = blocks(markdown)
        #expect(blocks.map(\.block.plainText) == ["Setext title", "quoted start lazy quoted", "Under it all [[Page]]"])
        #expect(blocks[0].block.kind == .heading)
        #expect(blocks[0].headingLevel == 1)
        #expect(blocks[1].block.kind == .quote)
        #expect(blocks[1].block.breadcrumbs == ["Setext title"])
        #expect(blocks.flatMap(\.links.titles) == ["page"])
    }

    @Test("Plain text drops emphasis and escapes but keeps what only looks like them")
    func plainTextMarks() {
        #expect(DocGraphText.plainText("**Bold** and *em* and __strong__ and _em_ and ~~gone~~") == "Bold and em and strong and em and gone")
        #expect(DocGraphText.plainText("snake_case_name stays, 2 * 3 stays, ~5 mins stays") == "snake_case_name stays, 2 * 3 stays, ~5 mins stays")
        #expect(DocGraphText.plainText(#"Escaped \*stars\* and a \\ backslash"#) == #"Escaped *stars* and a \ backslash"#)
        #expect(DocGraphText.plainText("Tom &amp; Jerry&#39;s <b>bold</b> <https://example.com>") == "Tom & Jerry's bold https://example.com")
        #expect(DocGraphText.plainText("A picture ![alt](x.png) and `co*de*` here") == "A picture and co*de* here")
        #expect(DocGraphText.plainText("**[Linked](https://example.com)** words") == "Linked words")
        #expect(DocGraphText.plainText("Crème   brûlée\u{00A0}text") == "Crème brûlée text")
    }

    @Test("Absurd nesting is read without running out of stack")
    func deepNesting() {
        let quotes = String(repeating: ">", count: 5_000) + " deep ((abcdefghi))"
        _ = DocGraphParser.parse(quotes, docID: "d")
        _ = DocGraphResolver.resolve(quotes) { _ in nil }
        let bullets = (0..<300).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n")
        let blocks = DocGraphParser.parse(bullets, docID: "d").blocks
        #expect(blocks.count >= 40)
        #expect(blocks.first?.block.key == "0.0")
        #expect(blocks[2].block.key == "0.0.0.0")
    }

    @Test("A heading's closing hashes and a CRLF line end are not its text")
    func headingsAndLineEnds() {
        let blocks = blocks("## Results ## ^resul7001\r\nBody line\r\n")
        #expect(blocks.first?.block.markdown == "Results")
        #expect(blocks.first?.block.blockID == "resul7001")
        #expect(blocks.last?.block.markdown == "Body line")
    }

    @Test("An embed alone in a paragraph is an embed; written in a sentence it reads as a reference")
    func embeds() {
        let blocks = blocks("{{embed: ((claim0001))}}\n\n- {{[[embed]]: ((claim0002))}}\n\nSee {{embed: ((claim0003))}} here.")
        #expect(blocks.map(\.isEmbedOnly) == [true, true, false])
        #expect(blocks[0].links.embeds == ["claim0001"])
        #expect(blocks[1].links.embeds == ["claim0002"])
        #expect(blocks[2].links.embeds == [])
        #expect(blocks[2].links.blockReferences == ["claim0003"])
    }

    @Test("Days are read from titles that name them")
    func dayTitles() {
        let blocks = blocks("Due [[October 6th, 2026]] and #[[Oct 7, 2026]], not [[Mitophagy 2026]].")
        #expect(Set(blocks[0].links.dayKeys) == ["2026-10-06", "2026-10-07"])
    }

    @Test("A title is found as whole words, any case and accents, outside links, code, addresses and the grammar")
    func wordMatching() {
        let matcher = DocGraphWordMatcher("Mitophagy")
        #expect(matcher.occurrences(in: "We study Mitophagy.").map(\.lowerBound) == [9])
        #expect(matcher.occurrences(in: "MITOPHAGY rules").count == 1)
        #expect(matcher.occurrences(in: "premitophagy and mitophagyish").isEmpty)
        #expect(matcher.occurrences(in: "[Mitophagy review](https://example.com)").isEmpty)
        #expect(matcher.occurrences(in: "Code `mitophagy` only").isEmpty)
        #expect(matcher.occurrences(in: "Linked [[Mitophagy]] and #mitophagy and #[[Mitophagy]]").isEmpty)
        #expect(matcher.occurrences(in: "https://en.wikipedia.org/wiki/Mitophagy").isEmpty)
        #expect(matcher.occurrences(in: "**Mitophagy** is bold").count == 1)
        let accented = DocGraphWordMatcher("Crème brûlée")
        #expect(accented.occurrences(in: "A creme\nbrulee recipe").count == 1, "accents fold and any whitespace parts the words")
    }

    // MARK: Edits

    @Test("Giving a block an id appends the marker to its last line, keeps an id it has, and finds a moved block by its text")
    func assigningBlockIDs() throws {
        let markdown = "- Alpha\n- Beta\n  continues\n- Gamma ^gamma0001\n"
        let edit = try #require(DocGraphEditing.assigningBlockID("beta00001", key: "0.1", expectedPlainText: "Beta continues", keyIsCurrent: true, in: markdown))
        #expect(edit.changed)
        #expect(edit.markdown == "- Alpha\n- Beta\n  continues ^beta00001\n- Gamma ^gamma0001\n")
        #expect(DocGraphParser.parse(edit.markdown, docID: "d").block(withID: "beta00001")?.block.plainText == "Beta continues")

        let kept = try #require(DocGraphEditing.assigningBlockID("other0001", key: "0.2", expectedPlainText: "Gamma", keyIsCurrent: true, in: markdown))
        #expect(!kept.changed)
        #expect(kept.blockID == "gamma0001")
        #expect(kept.markdown == markdown)

        // The Doc changed: a line went in above, so the key names another block.
        let moved = "- New first\n" + markdown
        let refound = try #require(DocGraphEditing.assigningBlockID("beta00001", key: "0.1", expectedPlainText: "Beta continues", keyIsCurrent: false, in: moved))
        #expect(refound.markdown == "- New first\n- Alpha\n- Beta\n  continues ^beta00001\n- Gamma ^gamma0001\n")

        #expect(DocGraphEditing.assigningBlockID("beta00001", key: "0.1", expectedPlainText: "Beta continues", keyIsCurrent: false, in: "- Alpha\n- Gone") == nil)
        #expect(DocGraphEditing.assigningBlockID("NOT-AN-ID", key: "0.1", expectedPlainText: "Beta continues", keyIsCurrent: true, in: markdown) == nil)

        let heading = try #require(DocGraphEditing.assigningBlockID("head00001", key: "0", expectedPlainText: "Results", keyIsCurrent: true, in: "## Results ##\n\nText"))
        #expect(heading.markdown == "## Results ## ^head00001\n\nText")
        let setext = try #require(DocGraphEditing.assigningBlockID("sete00001", key: "0", expectedPlainText: "Title", keyIsCurrent: true, in: "Title\n=====\n"))
        #expect(setext.markdown == "Title ^sete00001\n=====\n")
    }

    // MARK: Resolving

    private func lookup(_ markdown: String) -> (String) -> DocGraphParsedBlock? {
        let parse = DocGraphParser.parse(markdown, docID: "library")
        return { id in parse.block(withID: id) }
    }

    @Test("Resolving reads references as their text, embeds as the block and its children, and drops markers")
    func resolving() {
        let library = lookup("""
        - Claim one with [[Parkin]] ^claim0001
          - Evidence A
          - Evidence B ^evide0002
        - [ ] Task to do ^task00001

        ## Results ^resul0001

        Refers back to ((claim0001)) ^loops0001
        """)
        let markdown = #"""
        # Draft ^draft0001

        As ((claim0001)), see #mechanism and #[[Membrane potential]] in \[\[Escaped page\]\].

        {{embed: ((claim0001))}}

        - {{embed: ((evide0002))}}

        {{embed: ((resul0001))}}

        Missing ((zzzzzzzzz)) stays; a task reads ((task00001)); a reference inside one reads too: ((loops0001)).

        Code `((claim0001)) [[Not]]` and [a link](https://example.com/#anchor) stay.

        ```
        ((claim0001)) ^keep00001
        ```
        """#
        let resolved = DocGraphResolver.resolve(markdown, lookup: library)
        #expect(resolved == #"""
        # Draft

        As Claim one with Parkin, see mechanism and Membrane potential in Escaped page.

        - Claim one with Parkin
          - Evidence A
          - Evidence B

        - Evidence B

        ## Results

        Missing ((zzzzzzzzz)) stays; a task reads Task to do; a reference inside one reads too: Refers back to Claim one with Parkin.

        Code `((claim0001)) [[Not]]` and [a link](https://example.com/#anchor) stay.

        ```
        ((claim0001)) ^keep00001
        ```
        """#)
        #expect(DocGraphResolver.resolve("Nothing to resolve here.\n", lookup: library) == "Nothing to resolve here.\n")
    }

    @Test("Resolving line for line keeps every line where it was: an embed reads as its block's text on its own line")
    func resolvingKeepingLines() {
        let library = lookup("- Claim one ^claim0001\n  - Evidence A\n  - Evidence B")
        let markdown = "# Draft ^draft0001\n\n{{embed: ((claim0001))}}\n\n- {{embed: ((claim0001))}}\n\nAfter ((claim0001)) and #tag."
        let resolved = DocGraphResolver.resolve(markdown, keepingLines: true, lookup: library)
        #expect(resolved == "# Draft\n\nClaim one\n\n- Claim one\n\nAfter Claim one and tag.")
        #expect(resolved.components(separatedBy: "\n").count == markdown.components(separatedBy: "\n").count)
    }

    @Test("A block that embeds itself, or references itself, resolves without end")
    func resolvingCycles() {
        let library = lookup("- Self ((selfx0001)) ^selfx0001\n  - Child {{embed: ((selfx0001))}}")
        let resolved = DocGraphResolver.resolve("{{embed: ((selfx0001))}}", lookup: library)
        #expect(resolved.hasPrefix("- Self ((selfx0001))"))
        #expect(resolved.count < 500)
    }
}

// MARK: - Storage suite

/// The notes graph over a real store: what points at a Doc, an Idea, a source
/// or a block; Unlinked References; block search; title targets; daily notes;
/// the two writes into another Doc; and resolution for readers outside the app.
@Suite("Notes graph: the library's answers")
struct DocGraphStorageTests {
    private func makeStorage() -> (StorageService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocGraphTests_\(UUID().uuidString)", isDirectory: true)
        return (StorageService(storeRoot: root), root)
    }

    @discardableResult
    private func doc(_ storage: StorageService, _ title: String, _ markdown: String) async throws -> ArtifactMarkdownSnapshot {
        try await storage.createArtifact(title: title, homeNotebookID: nil, linkedNotebookIDs: [], markdown: markdown)
    }

    private func rewrite(_ storage: StorageService, _ id: String, _ markdown: String) async throws -> ArtifactMarkdownSnapshot {
        let current = try await storage.artifactMarkdown(id)
        return try await storage.writeArtifactMarkdown(artifactID: id, markdown: markdown, expectedRevision: current.revision)
    }

    private func team(_ storage: StorageService, _ id: String) async throws -> TeamRecord {
        let now = Date()
        let team = TeamRecord(
            id: id, name: "Nexus", role: .owner, permission: .readWrite, zoneScope: .privateScope,
            zoneName: TeamRecord.zoneName(forTeamID: id), zoneOwnerRecordName: nil, shareRecordName: nil,
            shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        )
        let store = try await storage.notebookFilesKnowledgeStore()
        try store.saveTeam(team)
        return team
    }

    @Test("A Doc's Linked References: blocks linking it by id, title link and tag, and Ideas linking it, newest first; not its own, an archived Doc's or another library's")
    func linkedReferencesToADoc() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let parkin = try await doc(storage, "Parkin", "Parkin is an E3 ligase; this page names [[Parkin]] itself.").artifact
        let byID = try await doc(storage, "Mechanisms", "- PINK1 recruits [Parkin](foreverlm://doc/\(parkin.id))\n  - Nested detail").artifact
        let byTitle = try await doc(storage, "Reading notes", "## Today\n\n- Read about [[parkin]] again\n- Unrelated bullet").artifact
        let byTag = try await doc(storage, "Tags", "Quality control #Parkin\n\nAnd #[[PARKIN]] once more").artifact
        let archived = try await doc(storage, "Old notes", "Mentions [[Parkin]] too.").artifact
        _ = try await storage.updateArtifact(artifactID: archived.id, title: nil, homeNotebookID: nil, linkedNotebookIDs: nil, isArchived: true)
        try await doc(storage, "Other", "Nothing about it.")
        let idea = try await storage.createIdea(title: "Parkin as a drug target", links: [IdeaLink(kind: .artifact, targetID: parkin.id)])

        let groups = try await storage.docGraphLinkedReferences(to: .doc(parkin.id), teamID: nil)
        #expect(groups.map(\.id) == [idea.id, byTag.id, byTitle.id, byID.id])
        #expect(groups.map(\.kind) == [.idea, .doc, .doc, .doc])
        #expect(groups[0].title == "Parkin as a drug target")
        #expect(groups[0].blocks.isEmpty)
        #expect(groups[1].blocks.map(\.plainText) == ["Quality control #Parkin", "And #[[PARKIN]] once more"])
        #expect(groups[2].blocks.map(\.plainText) == ["Read about [[parkin]] again"])
        #expect(groups[2].blocks.first?.breadcrumbs == ["Today"])
        #expect(groups[3].blocks.first?.key == "0.0")
        #expect(groups[3].blocks.first?.childrenMarkdown == "- Nested detail")
        #expect(groups[3].blocks.first?.docID == byID.id)
    }

    @Test("A daily note is pointed at by any title for its day, a daily note's group says so, and an old day sorts by its day")
    func dailyNoteReferences() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try await storage.ensureDailyNote(dayKey: "2020-01-01")
        let plan = try await doc(storage, "Plan", "- Due [[January 1st, 2020]]\n- Also #[[Jan 1, 2020]]\n- Not [[January 2nd, 2020]]").artifact
        let toDay = try await storage.docGraphLinkedReferences(to: .doc(day.id), teamID: nil)
        #expect(toDay.map(\.id) == [plan.id])
        #expect(toDay.first?.blocks.map(\.key) == ["0.0", "0.1"])

        let parkin = try await doc(storage, "Parkin", "A page.").artifact
        let earlier = try await doc(storage, "Earlier", "About [[Parkin]].").artifact
        // Written in after `Earlier`, but the note is 2020's: it sorts by its day.
        _ = try await rewrite(storage, day.id, "- Talked about [[Parkin]] ^talk00001")
        let toParkin = try await storage.docGraphLinkedReferences(to: .doc(parkin.id), teamID: nil)
        #expect(toParkin.map(\.id) == [earlier.id, day.id])
        #expect(toParkin.map(\.kind) == [.doc, .dailyNote])
        #expect(toParkin.last?.title == "January 1st, 2020")
    }

    @Test("An Idea's and a source's Linked References: id links, grounding and book tokens, cited addresses, and Ideas linked to the source; code holds none")
    func ideaAndSourceReferences() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        func source(_ id: String, url: String, title: String, parentGroup: String? = nil) async throws {
            var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
            article.domain = URL(string: url)?.host ?? ""
            article.content = "Enough readable text for \(title) to count as a source."
            article.wordCount = 10
            article.state = .ready
            article.parentGroup = parentGroup
            try await storage.saveSource(article)
        }
        try await source("paper", url: "https://doi.org/10.1000/paper-1", title: "The paper")
        try await source("chapter", url: "https://example.com/book/ch3", title: "Chapter three", parentGroup: "book-group")

        let idea = try await storage.createIdea(title: "Depolarised cells")
        let ideaDoc = try await doc(storage, "Idea doc", "See [Depolarised cells](foreverlm://idea/\(idea.id)) here.\n\nAnd unrelated.").artifact
        let toIdea = try await storage.docGraphLinkedReferences(to: .idea(idea.id), teamID: nil)
        #expect(toIdea.map(\.id) == [ideaDoc.id])
        #expect(toIdea.first?.blocks.count == 1)

        let grounded = try await doc(storage, "Grounded", "A passage [standing on](foreverlm://grounding/paper) the paper.").artifact
        let cited = try await doc(storage, "Cited", "- [The paper](https://doi.org/10.1000/paper-1) cited\n- [Not held](https://doi.org/10.1000/elsewhere)").artifact
        let book = try await doc(storage, "Book", "[Notes](foreverlm://grounding/book:book-group) on the book.").artifact
        try await doc(storage, "Code", "`foreverlm://source/paper` in code is not a link.")
        let paperIdea = try await storage.createIdea(title: "The paper's claim", links: [IdeaLink(kind: .source, targetID: "paper")])

        let toPaper = try await storage.docGraphLinkedReferences(to: .source("paper"), teamID: nil)
        #expect(toPaper.map(\.id) == [paperIdea.id, cited.id, grounded.id])
        #expect(toPaper[1].blocks.map(\.plainText) == ["The paper cited"])
        let toChapter = try await storage.docGraphLinkedReferences(to: .source("chapter"), teamID: nil)
        #expect(toChapter.map(\.id) == [book.id])
        await #expect(throws: KnowledgeStoreError.self) {
            _ = try await storage.docGraphLinkedReferences(to: .source("missing"), teamID: nil)
        }
    }

    @Test("A block's references and embeds are listed and counted, never itself, and its id is looked up across the library")
    func blockReferencesAndCounts() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await doc(storage, "Claims", "- Claim one ^claim0001\n  - Evidence\n- Claim two ^claim0002\n- Uses ((claim0001)) here").artifact
        let citing = try await doc(storage, "Citing", "As ((claim0001)) says.\n\n{{embed: ((claim0001))}}\n\nAnd ((claim0002)) twice ((claim0002)).").artifact
        try await doc(storage, "Copied", "- A copy that kept the marker ^claim0001")

        let groups = try await storage.docGraphLinkedReferences(to: .block("claim0001"), teamID: nil)
        #expect(Set(groups.map(\.id)) == [citing.id, source.id])
        #expect(groups.first { $0.id == citing.id }?.blocks.map(\.key) == ["0", "1"])
        #expect(groups.first { $0.id == source.id }?.blocks.map(\.plainText) == ["Uses ((claim0001)) here"])

        let counts = try await storage.docGraphReferenceCounts(inDoc: source.id)
        #expect(counts == ["claim0001": 3, "claim0002": 1])

        let found = try await storage.docGraphBlocks(["claim0001", "claim0002", "zzzzzzzzz"], teamID: nil)
        #expect(Set(found.keys) == ["claim0001", "claim0002"])
        #expect(found["claim0001"]?.docID == source.id, "the Doc made first holds a copied id")
        #expect(found["claim0001"]?.markdown == "Claim one")
        #expect(found["claim0001"]?.childrenMarkdown == "- Evidence")
    }

    @Test("Unlinked References: whole words in other Docs, one per block, not where linked, coded or inside a link")
    func unlinkedMentions() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try await doc(storage, "Mitophagy", "Mitophagy is the subject of this page.").artifact
        let holder = try await doc(storage, "Neurons", "We study mitophagy in neurons; MITOPHAGY again.\n\n- Mitophagy in a bullet").artifact
        try await doc(storage, "Linked", "Already [[Mitophagy]] linked, and mitophagy written too.")
        try await doc(storage, "Inside", "A [Mitophagy review](https://example.com) and `mitophagy` in code.")
        try await doc(storage, "Prefix", "Premitophagy is not it.")

        let mentions = try await storage.docGraphUnlinkedMentions(ofDoc: target.id)
        #expect(mentions.map(\.docID) == [holder.id, holder.id])
        #expect(mentions.map(\.block.key) == ["0", "1.0"])
        #expect(mentions[0].docTitle == "Neurons")
        #expect(mentions[0].start == 9)
        #expect(mentions[0].end == 18)

        let short = try await doc(storage, "Ox", "Ox ox ox.").artifact
        #expect(try await storage.docGraphUnlinkedMentions(ofDoc: short.id).isEmpty)
    }

    @Test("Block search: every word must appear; the whole phrase first, then word starts, then the rest, newest Doc first within each")
    func blockSearch() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let older = try await doc(storage, "Older", "Membrane potential collapse precedes mitophagy.")
        try await doc(storage, "Middle", "The potential of membranes matters.")
        try await doc(storage, "Newer", "Transmembrane potentials vary.")
        try await doc(storage, "Newest", "Membrane potential, again.")
        try await doc(storage, "Unrelated", "Nothing here.")

        let hits = try await storage.docGraphSearchBlocks("membrane potential", teamID: nil, limit: 12)
        #expect(hits.map(\.docTitle) == ["Newest", "Older", "Middle", "Newer"])
        let first = try #require(hits.first { $0.docTitle == "Older" })
        #expect(first.revision == older.revision)
        #expect(first.docID == older.artifact.id)
        #expect(try await storage.docGraphSearchBlocks("membrane potential", teamID: nil, limit: 2).count == 2)
        #expect(try await storage.docGraphSearchBlocks("", teamID: nil, limit: 2).map(\.docTitle) == ["Unrelated", "Newest"])
        #expect(try await storage.docGraphSearchBlocks("zzz qqq", teamID: nil, limit: 12).isEmpty)
    }

    @Test("The Space's page search: a page whose text holds every word, in any block, any case and accent; archived pages are not found")
    func pageTextSearch() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let both = try await doc(storage, "Notes", "Membrane potential collapses.\n\nThen mitophagy follows.")
        let accent = try await doc(storage, "Café", "The MITOPHAGY of a café cell.")
        try await doc(storage, "Other", "Membrane only.")
        #expect(try await storage.docGraphSearchPageIDs("mitophagy membrane", teamID: nil) == [both.artifact.id],
                "every word, each in any block")
        #expect(try await storage.docGraphSearchPageIDs("Mitophagy", teamID: nil) == [both.artifact.id, accent.artifact.id])
        #expect(try await storage.docGraphSearchPageIDs("cafe", teamID: nil) == [accent.artifact.id], "accents are folded")
        #expect(try await storage.docGraphSearchPageIDs("   ", teamID: nil).isEmpty)
        #expect(try await storage.docGraphSearchPageIDs("zzz", teamID: nil).isEmpty)
        _ = try await storage.updateArtifact(artifactID: accent.artifact.id, title: nil, homeNotebookID: nil, linkedNotebookIDs: nil, isArchived: true)
        #expect(try await storage.docGraphSearchPageIDs("mitophagy", teamID: nil) == [both.artifact.id], "a page in Trash is not found")
    }

    @Test("Title targets: the newest Doc of a title, a daily note by its day; archived Docs and other libraries are not named")
    func titleTargetsAndLibraries() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        try await doc(storage, "Parkin", "Older page.")
        let newer = try await doc(storage, "parkin", "Newer page.").artifact
        let day = try await storage.ensureDailyNote(dayKey: "2026-10-06")
        let archived = try await doc(storage, "Archived page", "Gone.").artifact
        _ = try await storage.updateArtifact(artifactID: archived.id, title: nil, homeNotebookID: nil, linkedNotebookIDs: nil, isArchived: true)
        let nexus = try await team(storage, "team-graph")
        let teamParkin = try await storage.createArtifact(title: "Parkin", homeNotebookID: nil, linkedNotebookIDs: [], markdown: "The team's page.", teamID: nexus.id).artifact
        let teamNotes = try await storage.createArtifact(title: "Team notes", homeNotebookID: nil, linkedNotebookIDs: [], markdown: "- [[Parkin]] in the team ^teamb0001", teamID: nexus.id).artifact

        let mine = try await storage.docGraphTitleTargets(teamID: nil)
        #expect(mine["parkin"] == newer.id)
        #expect(mine["october 6th, 2026"] == day.id)
        #expect(mine["archived page"] == nil)
        #expect(mine["team notes"] == nil)
        let theirs = try await storage.docGraphTitleTargets(teamID: nexus.id)
        #expect(theirs == ["parkin": teamParkin.id, "team notes": teamNotes.id])

        // A library answers for itself: My Library's Parkin is not pointed at
        // from the team, the team's is, and a team has no Ideas.
        #expect(try await storage.docGraphLinkedReferences(to: .doc(newer.id), teamID: nil).isEmpty)
        #expect(try await storage.docGraphLinkedReferences(to: .doc(teamParkin.id), teamID: nexus.id).map(\.id) == [teamNotes.id])
        #expect(try await storage.docGraphBlocks(["teamb0001"], teamID: nil).isEmpty)
        #expect(try await storage.docGraphBlocks(["teamb0001"], teamID: nexus.id)["teamb0001"]?.docID == teamNotes.id)
        #expect(try await storage.docGraphResolvedMarkdown("See ((teamb0001)).", teamID: nil) == "See ((teamb0001)).")
        #expect(try await storage.docGraphResolvedMarkdown("See ((teamb0001)).", teamID: nexus.id) == "See Parkin in the team.")

        #expect(try await storage.docGraphTeamID(forDoc: newer.id) == nil)
    }

    @Test("Giving another Doc's block an id saves it, keeps an id it has, finds a moved block by its text, and refuses a block that is gone")
    func assigningBlockIDs() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = try await doc(storage, "List", "- Alpha\n- Beta").artifact
        let hit = try #require(try await storage.docGraphSearchBlocks("beta", teamID: nil, limit: 5).first)
        let id = try await storage.docGraphAssignBlockID(docID: list.id, key: hit.block.key, revision: hit.revision, expectedPlainText: hit.block.plainText, proposedID: "beta00001")
        #expect(id == "beta00001")
        #expect(try await storage.artifactMarkdown(list.id).markdown == "- Alpha\n- Beta ^beta00001")
        #expect(try await storage.docGraphBlocks(["beta00001"], teamID: nil)["beta00001"]?.plainText == "Beta")

        let again = try #require(try await storage.docGraphSearchBlocks("beta", teamID: nil, limit: 5).first)
        let kept = try await storage.docGraphAssignBlockID(docID: list.id, key: again.block.key, revision: again.revision, expectedPlainText: again.block.plainText, proposedID: "other0001")
        #expect(kept == "beta00001")
        #expect(try await storage.artifactMarkdown(list.id).markdown == "- Alpha\n- Beta ^beta00001")

        let moving = try await doc(storage, "Moving", "- One\n- Two").artifact
        let two = try #require(try await storage.docGraphSearchBlocks("two", teamID: nil, limit: 5).first)
        _ = try await rewrite(storage, moving.id, "- Zero\n- One\n- Two")
        let moved = try await storage.docGraphAssignBlockID(docID: moving.id, key: two.block.key, revision: two.revision, expectedPlainText: two.block.plainText, proposedID: "twoxx0001")
        #expect(moved == "twoxx0001")
        #expect(try await storage.artifactMarkdown(moving.id).markdown == "- Zero\n- One\n- Two ^twoxx0001")

        let vanishing = try await doc(storage, "Vanishing", "- Keep\n- Lose").artifact
        let lose = try #require(try await storage.docGraphSearchBlocks("lose", teamID: nil, limit: 5).first)
        _ = try await rewrite(storage, vanishing.id, "- Keep")
        await #expect(throws: DocGraphError.blockMoved("Vanishing")) {
            _ = try await storage.docGraphAssignBlockID(docID: vanishing.id, key: lose.block.key, revision: lose.revision, expectedPlainText: lose.block.plainText, proposedID: "losex0001")
        }
        #expect(try await storage.artifactMarkdown(vanishing.id).markdown == "- Keep")

        let animation = try await storage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://anim/")!, title: "The animation",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )
        await #expect(throws: DocGraphError.notMarkdown("The animation")) {
            _ = try await storage.docGraphAssignBlockID(docID: animation.id, key: "0", revision: "", expectedPlainText: "x", proposedID: "anima0001")
        }
    }

    @Test("A day's note is made once, empty, in My Library, titled with its day; daily notes list newest day first")
    func dailyNotes() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await storage.ensureDailyNote(dayKey: "2026-10-06")
        let second = try await storage.ensureDailyNote(dayKey: "2026-10-06")
        #expect(first.id == "daily-2026-10-06")
        #expect(second.id == first.id)
        #expect(second.createdAt == first.createdAt)
        #expect(first.title == "October 6th, 2026")
        #expect(first.teamID == nil)
        #expect(first.homeNotebookID == nil)
        #expect(try await storage.artifactMarkdown(first.id).markdown == "")
        #expect(try await storage.loadArtifacts().filter { $0.id == first.id }.count == 1)
        await #expect(throws: KnowledgeStoreError.self) {
            _ = try await storage.ensureDailyNote(dayKey: "2026-02-30")
        }

        _ = try await storage.ensureDailyNote(dayKey: "2026-10-01")
        _ = try await storage.ensureDailyNote(dayKey: "2026-10-03")
        _ = try await storage.ensureDailyNote(dayKey: "2026-10-02")
        try await doc(storage, "Not a day", "Text.")
        #expect(try await storage.dailyNotes(before: nil, limit: 10).map(\.id) == ["daily-2026-10-06", "daily-2026-10-03", "daily-2026-10-02", "daily-2026-10-01"])
        #expect(try await storage.dailyNotes(before: "2026-10-03", limit: 10).map(\.id) == ["daily-2026-10-02", "daily-2026-10-01"])
        #expect(try await storage.dailyNotes(before: nil, limit: 1).map(\.id) == ["daily-2026-10-06"])
        _ = try await storage.updateArtifact(artifactID: "daily-2026-10-02", title: nil, homeNotebookID: nil, linkedNotebookIDs: nil, isArchived: true)
        #expect(try await storage.dailyNotes(before: "2026-10-06", limit: 10).map(\.id) == ["daily-2026-10-03", "daily-2026-10-01"])
    }

    @Test("Resolved Markdown reads the library's blocks and the text's own, and leaves an unknown reference as written")
    func resolvedMarkdown() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        try await doc(storage, "Claims", "- Claim one with [[Parkin]] ^claim0001\n  - Evidence ^evide0001")
        let markdown = "As ((claim0001)) says.\n\n{{embed: ((claim0001))}}\n\nOwn ((ownbl0001)).\n\nLocal block ^ownbl0001\n\nMissing ((zzzzzzzzz)), #tag and #[[Two words]]."
        let resolved = try await storage.docGraphResolvedMarkdown(markdown, teamID: nil)
        #expect(resolved == "As Claim one with Parkin says.\n\n- Claim one with Parkin\n  - Evidence\n\nOwn Local block.\n\nLocal block\n\nMissing ((zzzzzzzzz)), tag and Two words.")
        #expect(try await storage.docGraphResolvedMarkdown("Plain text.", teamID: nil) == "Plain text.")
    }

    @Test("A question over the library reads a Doc's body once per revision")
    func parsesOncePerRevision() async throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let cached = try await doc(storage, "Cached", "- First thought ^first0001").artifact
        #expect(try await storage.docGraphBlocks(["first0001"], teamID: nil)["first0001"]?.plainText == "First thought")

        // Changed on disk behind the store's back: the record's date did not
        // move, so the remembered parse answers.
        let file = try await storage.artifactFileURL(cached.id)
        try Data("- Changed on disk ^first0001".utf8).write(to: file, options: .atomic)
        #expect(try await storage.docGraphBlocks(["first0001"], teamID: nil)["first0001"]?.plainText == "First thought")

        // A save moves the date, and the Doc is read again.
        _ = try await rewrite(storage, cached.id, "- Rewritten ^first0001")
        #expect(try await storage.docGraphBlocks(["first0001"], teamID: nil)["first0001"]?.plainText == "Rewritten")
    }
}
