import Foundation
import Testing
@testable import ForeverLM

/// The Atlas (docs/atlas-design.md): reading the model's skeleton and
/// deepening, keeping only what points at something, the passages the app
/// writes, the fisheye's neighbourhood, the Canvas lens it lays out, what
/// Learn drafts from, and its row in `atlases`.
@Suite("Atlas")
struct AtlasTests {

    // MARK: Fixtures

    private static func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func entry(
        _ id: String,
        _ name: String,
        parent: String?,
        kind: String = "concept",
        relations: [[String: Any]] = [],
        evidence: [Any] = [],
        terms: [[String: Any]] = [],
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "id": id,
            "name": name,
            "kind": kind,
            "gist": "\(name) in a few words",
            "line": "\(name) is one sentence long.",
            "parent": parent ?? NSNull(),
            "relations": relations,
            "evidence": evidence,
            "terms": terms,
            "status": "established",
            "open_questions": [],
        ]
        for (key, value) in extra { entry[key] = value }
        return entry
    }

    /// Mitophagy, laid out the way the model is asked to: a root, three
    /// subtopics and their concepts, relations and evidence.
    private static var mitophagyEntries: [[String: Any]] {
        [
            entry("c1", "Mitophagy", parent: nil, kind: "field", extra: ["paragraph": "Cells clear damaged mitochondria."]),
            entry("c2", "Damage sensing", parent: "c1", kind: "topic"),
            entry("c3", "PINK1 accumulation", parent: "c2", kind: "mechanism",
                  relations: [["to": "c4", "kind": "causes", "label": "recruits"], ["to": "c8", "kind": "prerequisite"]],
                  evidence: [["passage": "p1", "stance": "supports"], ["passage": "p2", "stance": "defines"]],
                  terms: [["term": "PINK1", "definition": "A kinase that builds up on depolarised mitochondria."]]),
            entry("c4", "Parkin recruitment", parent: "c2", kind: "mechanism",
                  relations: [["to": "c5", "kind": "causes"]],
                  evidence: [["passage": "p3"]]),
            entry("c5", "Ubiquitin chains", parent: "c1", kind: "concept",
                  relations: [["to": "c3", "kind": "part_of"]]),
            entry("c6", "Measuring mitophagy", parent: "c1", kind: "topic"),
            entry("c7", "mt-Keima imaging", parent: "c6", kind: "method",
                  relations: [["to": "c3", "kind": "measures", "label": "reads out"]],
                  evidence: ["p4"]),
            entry("c8", "Membrane potential", parent: "c1", kind: "concept",
                  evidence: [["passage": "p2", "stance": "context"]]),
        ]
    }

    private static let passageIDs: Set<String> = ["p1", "p2", "p3", "p4"]

    private static let passages: [AtlasPassage] = [
        AtlasPassage(id: "p1", sourceID: "s-pink1", title: "PINK1 stabilization", year: "2010", text: "PINK1 is selectively stabilized on impaired mitochondria."),
        AtlasPassage(id: "p2", sourceID: "s-potential", title: "Membrane potential", year: nil, text: "Loss of membrane potential blocks PINK1 import."),
        AtlasPassage(id: "p3", sourceID: "s-parkin", title: "Parkin recruitment", year: "2008", text: "Parkin is recruited to dysfunctional mitochondria."),
        AtlasPassage(id: "p4", sourceID: "s-keima", title: "mt-Keima", year: "2016", text: "mt-Keima reports delivery of mitochondria to lysosomes."),
    ]

    private static func mitophagyAtlas() throws -> Atlas {
        let parsed = try AtlasResponse.skeleton(from: json(["topic": "Mitophagy", "concepts": mitophagyEntries]), passageIDs: passageIDs)
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return Atlas(
            id: "atlas:test",
            topic: "Mitophagy",
            scope: AtlasScope(itemRefs: ["source:s-pink1", "idea:i1"], notebookID: "nb1"),
            rootID: parsed.rootID,
            concepts: parsed.concepts,
            passages: passages,
            createdAt: at,
            updatedAt: at,
            model: "test-model"
        )
    }

    // MARK: Parsing and validation

    @Test("A skeleton reads into concepts in reading order, with its topic and root")
    func skeletonReads() throws {
        let fenced = "Here it is:\n```json\n" + Self.json(["topic": "Mitophagy", "concepts": Self.mitophagyEntries]) + "\n```"
        let parsed = try AtlasResponse.skeleton(from: fenced, passageIDs: Self.passageIDs)
        #expect(parsed.topic == "Mitophagy")
        #expect(parsed.rootID == "c1")
        // Depth first from the root: each branch before the next subtopic.
        #expect(parsed.concepts.map(\.id) == ["c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8"])
        let pink1 = try #require(parsed.concepts.first { $0.id == "c3" })
        #expect(pink1.kind == .mechanism)
        #expect(pink1.relations.map(\.kind) == [.causes, .prerequisite])
        #expect(pink1.evidence.map(\.stance) == [.supports, .defines])
        #expect(pink1.terms.first?.term == "PINK1")
        // A bare passage id is evidence too.
        #expect(parsed.concepts.first { $0.id == "c7" }?.evidence.map(\.passageID) == ["p4"])
        #expect(parsed.concepts.first { $0.id == "c1" }?.paragraph == "Cells clear damaged mitochondria.")
    }

    @Test("Relations, evidence and parents that point at nothing are dropped")
    func danglingIDsAreDropped() throws {
        var entries = Self.mitophagyEntries
        entries[2]["relations"] = [["to": "c99", "kind": "causes"], ["to": "c3", "kind": "related"], ["to": "c4", "kind": "causes"], ["to": "c4", "kind": "causes"]]
        entries[2]["evidence"] = [["passage": "p1"], ["passage": "p99"], ["passage": "p1", "stance": "context"]]
        entries[4]["parent"] = "c77"
        let parsed = try AtlasResponse.skeleton(from: Self.json(["concepts": entries]), passageIDs: Self.passageIDs)
        let pink1 = try #require(parsed.concepts.first { $0.id == "c3" })
        // Unknown target, a relation to itself and a repeat go.
        #expect(pink1.relations.map(\.to) == ["c4"])
        // An id the app never gave goes; a passage cited twice counts once.
        #expect(pink1.evidence.map(\.passageID) == ["p1"])
        // A parent that names nothing hangs the concept under the root.
        #expect(parsed.concepts.first { $0.id == "c5" }?.parentID == "c1")
    }

    @Test("Missing and repeated ids get fresh ones that collide with nothing")
    func uniqueIDs() throws {
        var entries = Self.mitophagyEntries
        entries[5]["id"] = "c2"
        entries[6]["id"] = ""
        let parsed = try AtlasResponse.skeleton(from: Self.json(["concepts": entries]), passageIDs: Self.passageIDs)
        let ids = parsed.concepts.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == entries.count)
        // The first to claim an id keeps it; the repeat and the blank get the
        // next ids no concept names.
        #expect(parsed.concepts.first { $0.name == "Damage sensing" }?.id == "c2")
        #expect(parsed.concepts.first { $0.name == "Measuring mitophagy" }?.id == "c6")
        #expect(parsed.concepts.first { $0.name == "mt-Keima imaging" }?.id == "c7")
    }

    @Test("Exactly one root: the first without a parent, the others under it")
    func oneRoot() throws {
        var entries = Self.mitophagyEntries
        entries[5]["parent"] = NSNull()
        let parsed = try AtlasResponse.skeleton(from: Self.json(["concepts": entries]), passageIDs: Self.passageIDs)
        #expect(parsed.rootID == "c1")
        #expect(parsed.concepts.filter { $0.parentID == nil }.map(\.id) == ["c1"])
        #expect(parsed.concepts.first { $0.id == "c6" }?.parentID == "c1")

        // No concept without a parent: the first becomes the root.
        var cyclic = Self.mitophagyEntries
        cyclic[0]["parent"] = "c2"
        let rooted = try AtlasResponse.skeleton(from: Self.json(["concepts": cyclic]), passageIDs: Self.passageIDs)
        #expect(rooted.rootID == "c1")
        #expect(rooted.concepts.first?.parentID == nil)
    }

    @Test("A parent chain that loops is cut so every concept reaches the root")
    func cyclesAreCut() throws {
        var entries = Self.mitophagyEntries
        entries[1]["parent"] = "c3"   // c2 under c3, while c3 is under c2
        let parsed = try AtlasResponse.skeleton(from: Self.json(["concepts": entries]), passageIDs: Self.passageIDs)
        let atlas = Atlas(topic: "Mitophagy", scope: AtlasScope(), rootID: parsed.rootID, concepts: parsed.concepts, passages: [], createdAt: Date(), updatedAt: Date())
        for concept in atlas.concepts where concept.id != atlas.rootID {
            #expect(atlas.ancestors(of: concept.id).first?.id == atlas.rootID, "\(concept.id) reaches the root")
        }
        #expect(atlas.outline().count == atlas.concepts.count)
    }

    @Test("At most 24 concepts are kept, parents before children; fewer than five is no Atlas")
    func conceptCaps() throws {
        var entries: [[String: Any]] = [Self.entry("c1", "Root", parent: nil, kind: "field")]
        for index in 2...30 {
            entries.append(Self.entry("c\(index)", "Concept \(index)", parent: index <= 6 ? "c1" : "c\((index % 5) + 2)"))
        }
        let parsed = try AtlasResponse.skeleton(from: Self.json(["concepts": entries]), passageIDs: [])
        #expect(parsed.concepts.count == AtlasLimits.maximumConcepts)
        let kept = Set(parsed.concepts.map(\.id))
        for concept in parsed.concepts {
            if let parent = concept.parentID { #expect(kept.contains(parent)) }
        }

        let few = Array(Self.mitophagyEntries.prefix(4))
        #expect(throws: AtlasResponseError.tooFewConcepts(4)) {
            try AtlasResponse.skeleton(from: Self.json(["concepts": few]), passageIDs: Self.passageIDs)
        }
        #expect(throws: AtlasResponseError.unreadable) {
            try AtlasResponse.skeleton(from: "I could not do that.", passageIDs: [])
        }
    }

    @Test("Text is capped: a gist at eight words, terms at three in the skeleton")
    func textCaps() throws {
        var entries = Self.mitophagyEntries
        entries[2]["gist"] = "one two three four five six seven eight nine ten eleven"
        entries[2]["name"] = String(repeating: "Long name ", count: 20)
        entries[2]["terms"] = (1...6).map { ["term": "Term \($0)", "definition": "Definition \($0)."] }
        entries[2]["open_questions"] = ["Why?", "How?", "When?", "Where?"]
        let parsed = try AtlasResponse.skeleton(from: Self.json(["concepts": entries]), passageIDs: Self.passageIDs)
        let concept = try #require(parsed.concepts.first { $0.id == "c3" })
        #expect(concept.gist.split(separator: " ").count <= AtlasLimits.gistWords)
        #expect(concept.gist.hasSuffix("…"))
        #expect(concept.name.count <= AtlasLimits.nameCharacters)
        #expect(concept.terms.count == AtlasLimits.skeletonTerms)
        #expect(concept.openQuestions.count == AtlasLimits.skeletonOpenQuestions)
        // A concept with no gist takes the start of its line.
        var noGist = Self.mitophagyEntries
        noGist[3]["gist"] = ""
        let fallback = try AtlasResponse.skeleton(from: Self.json(["concepts": noGist]), passageIDs: Self.passageIDs)
        #expect(fallback.concepts.first { $0.id == "c4" }?.gist.isEmpty == false)
    }

    @Test("Unknown kinds, statuses and stances read as the plainest one rather than failing")
    func lenientEnums() throws {
        var entries = Self.mitophagyEntries
        entries[2]["kind"] = "pathway"
        entries[2]["status"] = "contested"
        entries[2]["relations"] = [["to": "c4", "kind": "Part Of"]]
        let parsed = try AtlasResponse.skeleton(from: Self.json(["concepts": entries]), passageIDs: Self.passageIDs)
        let concept = try #require(parsed.concepts.first { $0.id == "c3" })
        #expect(concept.kind == .concept)
        #expect(concept.status == .debated)
        #expect(concept.relations.first?.kind == .partOf)
    }

    // MARK: Passages are the app's

    @Test("A passage's text is the app's; a quote the model writes is never kept")
    func passagesAreTheApps() throws {
        var entries = Self.mitophagyEntries
        entries[2]["evidence"] = [["passage": "p1", "quote": "PINK1 is a made-up quote the model wrote"]]
        entries[2]["quote"] = "Another quote"
        let parsed = try AtlasResponse.skeleton(from: Self.json(["concepts": entries]), passageIDs: Self.passageIDs)
        let atlas = Atlas(topic: "Mitophagy", scope: AtlasScope(), rootID: parsed.rootID, concepts: parsed.concepts, passages: Self.passages, createdAt: Date(), updatedAt: Date())
        let shown = atlas.evidencePassages(of: "c3")
        #expect(shown.map(\.passage.text) == [Self.passages[0].text])
        let encoded = try Atlas.encoded(atlas)
        #expect(!encoded.contains("made-up quote"))
        #expect(!encoded.contains("Another quote"))
    }

    @Test("A quote reads whole where the PDF broke a word at a line's end, and keeps a writer's own hanging hyphen")
    func quotesJoinLineBreakHyphens() {
        let broken = AtlasPassage(id: "p1", sourceID: "s", title: "T", year: nil, text: "making under- standing their bioenergetics an increasingly impor- tant focus")
        #expect(broken.readableText == "making understanding their bioenergetics an increasingly important focus")
        #expect(broken.text.contains("under- standing"))
        #expect(AtlasPassage.joiningLineBreakHyphens("pre- and post-synaptic terminals") == "pre- and post-synaptic terminals")
        #expect(AtlasPassage.joiningLineBreakHyphens("Ca2+ overload - a trigger") == "Ca2+ overload - a trigger")
        #expect(AtlasPassage.joiningLineBreakHyphens("PKMDR- FLIM can report") == "PKMDR- FLIM can report")
    }

    @Test("Retrieval takes the ranked chunks, else the ones holding the query's words, else the opening")
    func retrievalPicksChunks() throws {
        let filler = (1...400).map { "word\($0)" }.joined(separator: " ")
        let content = "Opening sentence of the paper. " + filler + " Mitophagy needs PINK1 and Parkin to work together. " + filler
        let chunks = SourceEmbeddingText.textChunks(from: content)
        let mitophagyChunk = try #require(chunks.firstIndex { $0.contains("Mitophagy needs PINK1") })

        let ranked = AtlasRetrieval.passages(
            from: [.init(sourceID: "s1", title: "Paper", year: "2020", content: content, rankedChunks: [3])],
            queryTerms: ["mitophagy"],
            perSource: 1
        )
        #expect(ranked.count == 1)
        #expect(chunks[3].contains(ranked[0].text.prefix(40)))

        let lexical = AtlasRetrieval.passages(
            from: [.init(sourceID: "s1", title: "Paper", year: nil, content: content, rankedChunks: [])],
            queryTerms: ["mitophagy", "parkin"],
            perSource: 1
        )
        #expect(lexical.first?.text.contains("Mitophagy needs PINK1") == true)
        #expect(chunks[mitophagyChunk].contains(lexical[0].text.suffix(30)))

        let opening = AtlasRetrieval.passages(
            from: [.init(sourceID: "s1", title: "Paper", year: nil, content: content, rankedChunks: [])],
            queryTerms: ["absent"],
            perSource: 1,
            firstNumber: 7
        )
        #expect(opening.first?.id == "p7")
        #expect(opening.first?.text.hasPrefix("Opening sentence") == true)
    }

    @Test("An excerpt is the chunk's own words: begun at a sentence, ended at one, never longer than asked")
    func excerptsAreVerbatim() {
        let chunk = "of the cell. PINK1 accumulates on the outer membrane when import fails. It then phosphorylates ubiquitin and Parkin, which spreads the signal across the surface. The result is engulfment."
        let excerpt = AtlasRetrieval.excerpt(chunk, characters: 100)
        #expect(excerpt == "PINK1 accumulates on the outer membrane when import fails.")
        #expect(excerpt.count <= 100)
        #expect(chunk.contains(excerpt))
        #expect(excerpt.hasSuffix("."))
        #expect(AtlasRetrieval.year("Published 2019, revised 2021") == "2019")
        #expect(AtlasRetrieval.year("Unknown year") == nil)
    }

    // MARK: Deepening

    @Test("A deepening merges: paragraph and steps written, new terms only, cited passages join the pool")
    func deepenMerges() throws {
        let atlas = try Self.mitophagyAtlas()
        let fresh = [
            AtlasPassage(id: "", sourceID: "s-new", title: "New paper", year: "2021", text: "PINK1 phosphorylates ubiquitin at Ser65."),
            AtlasPassage(id: "", sourceID: "s-pink1", title: "PINK1 stabilization", year: "2010", text: Self.passages[0].text),
            AtlasPassage(id: "", sourceID: "s-other", title: "Uncited", year: nil, text: "Not cited by the deepening."),
        ]
        let offered = atlas.numbering(fresh)
        // The passage the pool already holds is not offered twice.
        #expect(offered.map(\.id) == ["p5", "p6"])
        let reply = Self.json([
            "paragraph": "PINK1 is imported and cleaved in healthy mitochondria.",
            "steps": ["1. Import fails.", "Step 2: PINK1 builds up.", "PINK1 recruits Parkin."],
            "terms": [["term": "PINK1", "definition": "Already listed."], ["term": "TOM complex", "definition": "The outer-membrane import gate."]],
            "evidence": [["passage": "p5", "stance": "supports"], ["passage": "p1"], ["passage": "p42"]],
            "open_questions": ["How fast does PINK1 accumulate in neurons?"],
        ])
        let deepening = try AtlasResponse.deepening(
            from: reply,
            passageIDs: Set(offered.map(\.id) + ["p1", "p2"]),
            existingTerms: atlas.concept("c3")!.terms
        )
        #expect(deepening.steps == ["Import fails.", "PINK1 builds up.", "PINK1 recruits Parkin."])
        #expect(deepening.terms.map(\.term) == ["TOM complex"])
        #expect(deepening.evidence.map(\.passageID) == ["p5", "p1"])

        let merged = atlas.merging(deepening, into: "c3", offered: offered, at: Date(timeIntervalSinceReferenceDate: 900_000_000))
        let concept = try #require(merged.concept("c3"))
        #expect(concept.deepened)
        #expect(concept.paragraph == "PINK1 is imported and cleaved in healthy mitochondria.")
        #expect(concept.steps?.count == 3)
        #expect(concept.terms.map(\.term) == ["PINK1", "TOM complex"])
        #expect(concept.evidence.map(\.passageID) == ["p1", "p2", "p5"])
        // Only the cited new passage joins the pool, with the app's text.
        #expect(merged.passages.map(\.id) == ["p1", "p2", "p3", "p4", "p5"])
        #expect(merged.passage("p5")?.text == "PINK1 phosphorylates ubiquitin at Ser65.")
        #expect(merged.updatedAt == Date(timeIntervalSinceReferenceDate: 900_000_000))
        #expect(concept.openQuestions == ["How fast does PINK1 accumulate in neurons?"])
        // A concept at the paragraph level now needs nothing more.
        #expect(!concept.needsDeepening(at: .paragraph))
        #expect(atlas.concept("c4")!.needsDeepening(at: .steps))
        #expect(!atlas.concept("c1")!.needsDeepening(at: .paragraph), "the root's paragraph came with the skeleton")
        #expect(!atlas.concept("c4")!.needsDeepening(at: .line))

        #expect(throws: AtlasResponseError.emptyDeepening) {
            try AtlasResponse.deepening(from: "{\"terms\": []}", passageIDs: [], existingTerms: [])
        }
    }

    @Test("A deepening written from an older copy lands on the newest without undoing another")
    func adoptingKeepsOtherDeepenings() throws {
        let atlas = try Self.mitophagyAtlas()
        let newPassage = AtlasPassage(id: "p5", sourceID: "s-a", title: "A", year: nil, text: "Text A.")
        let deepenedC3 = atlas.merging(
            AtlasDeepening(paragraph: "C3 deep.", steps: ["One.", "Two.", "Three."], terms: [], evidence: [.init(passageID: "p5", stance: .supports)], openQuestions: []),
            into: "c3", offered: [newPassage], at: Date()
        )
        // Meanwhile c4 was deepened with another passage numbered p5.
        let otherPassage = AtlasPassage(id: "p5", sourceID: "s-b", title: "B", year: nil, text: "Text B.")
        let deepenedC4 = atlas.merging(
            AtlasDeepening(paragraph: "C4 deep.", steps: [], terms: [], evidence: [.init(passageID: "p5", stance: .supports)], openQuestions: []),
            into: "c4", offered: [otherPassage], at: Date()
        )
        let both = deepenedC4.adopting("c3", from: deepenedC3, at: Date())
        #expect(both.concept("c4")?.paragraph == "C4 deep.")
        #expect(both.concept("c3")?.paragraph == "C3 deep.")
        let c3Passages = both.evidencePassages(of: "c3").map(\.passage.text)
        let c4Passages = both.evidencePassages(of: "c4").map(\.passage.text)
        #expect(c3Passages.contains("Text A."))
        #expect(c4Passages.contains("Text B."))
        #expect(Set(both.passages.map(\.id)).count == both.passages.count, "no two passages share an id")
    }

    // MARK: The fisheye

    @Test("The neighbourhood: broader above, narrower below, know first, and related both ways")
    func neighbourhood() throws {
        let atlas = try Self.mitophagyAtlas()
        let around = atlas.neighbourhood(of: "c3")
        #expect(around.broader.map(\.id) == ["c1", "c2"])
        #expect(around.narrower.isEmpty)
        #expect(around.knowFirst.map(\.id) == ["c8"])
        let related = Dictionary(uniqueKeysWithValues: around.related.map { ($0.concept.id, $0) })
        // Outgoing with its label, incoming with the kind's phrase for that way.
        #expect(related["c4"]?.phrase == "recruits")
        #expect(related["c4"]?.isOutgoing == true)
        #expect(related["c5"]?.phrase == "has part")
        #expect(related["c7"]?.phrase == "measured by")
        #expect(related["c7"]?.isOutgoing == false)

        let root = atlas.neighbourhood(of: "c1")
        #expect(root.broader.isEmpty)
        #expect(root.narrower.map(\.id) == ["c2", "c5", "c6", "c8"])

        let membrane = atlas.neighbourhood(of: "c8")
        #expect(membrane.related.first { $0.concept.id == "c3" }?.phrase == "needed for")
        #expect(atlas.branch(of: "c2").map(\.id) == ["c2", "c3", "c4"])
        #expect(atlas.outline().map(\.depth) == [0, 1, 2, 2, 1, 1, 2, 1])
    }

    @Test("Back and forward walk the focus history, and a new focus clears forward")
    @MainActor
    func focusHistory() throws {
        let model = AtlasModel()
        model.show(try Self.mitophagyAtlas())
        #expect(model.focusID == "c1")
        model.focus("c2")
        model.focus("c3")
        model.goBack()
        #expect(model.focusID == "c2")
        model.goForward()
        #expect(model.focusID == "c3")
        model.goBack()
        model.focus("c7")
        #expect(!model.canGoForward)
        #expect(model.backStack == ["c1", "c2"])
        model.climb()
        #expect(model.level == .gist)
        model.descend()
        model.descend()
        model.descend()
        model.descend()
        #expect(model.level == .steps)
    }

    // MARK: Lay Out on Canvas

    @Test("The Atlas becomes a concepts lens: sources at most three, causal and part-of arrows, empty concepts left off")
    func lensRequest() throws {
        let atlas = try Self.mitophagyAtlas()
        let request = try #require(atlas.canvasLensRequest())
        #expect(request.layout == .concepts)
        #expect(request.title == "Mitophagy")
        let labels = request.concepts.map(\.label)
        // c1, c2 and c6 cite nothing and join no arrow: they are not drawn.
        #expect(labels == ["PINK1 accumulation", "Parkin recruitment", "Ubiquitin chains", "mt-Keima imaging", "Membrane potential"])
        let pink1 = try #require(request.concepts.first { $0.label == "PINK1 accumulation" })
        #expect(pink1.items.map(\.description) == ["source:s-pink1", "source:s-potential"])
        #expect(pink1.note == "PINK1 accumulation is one sentence long.")
        let links = request.conceptLinks.map { "\($0.from)→\($0.to):\($0.label)" }
        #expect(links.contains("PINK1 accumulation→Parkin recruitment:recruits"))
        #expect(links.contains("Membrane potential→PINK1 accumulation:needed for"), "what comes first points at what needs it")
        #expect(links.contains("Ubiquitin chains→PINK1 accumulation:part of"))
        #expect(links.contains("mt-Keima imaging→PINK1 accumulation:reads out"))

        let branch = try #require(atlas.canvasLensRequest(branch: "c2"))
        #expect(branch.title == "Mitophagy: Damage sensing")
        #expect(branch.concepts.map(\.label) == ["PINK1 accumulation", "Parkin recruitment"])

        // No concept with a source: nothing to lay out.
        var bare = atlas
        for index in bare.concepts.indices { bare.concepts[index].evidence = [] }
        #expect(bare.canvasLensRequest() == nil)
    }

    @Test("Concepts of one name stay apart in the lens")
    func lensNamesAreUnique() throws {
        var atlas = try Self.mitophagyAtlas()
        atlas.concepts[3].name = "PINK1 accumulation"
        let request = try #require(atlas.canvasLensRequest())
        let labels = request.concepts.map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(labels.contains("PINK1 accumulation (2)"))
    }

    // MARK: Learn and memory

    @Test("Learn drafts from the concept and its terms, anchored to its sources; nothing without evidence")
    func learnAnchors() throws {
        let atlas = try Self.mitophagyAtlas()
        let anchors = atlas.learnAnchors(for: "c3")
        #expect(anchors.map(\.kind) == [.concept, .term])
        #expect(anchors[0].text == "PINK1 accumulation: PINK1 accumulation is one sentence long.")
        #expect(anchors[0].sourceIDs == ["s-pink1", "s-potential"])
        #expect(anchors[0].passages.map(\.text) == [Self.passages[0].text, Self.passages[1].text])
        #expect(anchors[1].text.hasPrefix("PINK1: "))
        // A subtopic that cites nothing itself is grounded by its branch.
        #expect(atlas.learnAnchors(for: "c2").first?.sourceIDs == ["s-pink1", "s-parkin", "s-potential"])
        // Nothing in its branch is in the library: no card.
        #expect(atlas.learnAnchors(for: "c5").isEmpty)
    }

    @Test("A concept is grounded by its own passages, else by its branch's, the strongest first")
    func grounding() throws {
        let atlas = try Self.mitophagyAtlas()
        #expect(atlas.citesItself("c3"))
        #expect(atlas.groundingPassages(of: "c3").map(\.passage.id) == ["p1", "p2"])
        #expect(!atlas.citesItself("c2"))
        // c3's p1 (supports) and p2 (defines), c4's p3 (supports): supports first.
        #expect(atlas.groundingPassages(of: "c2").map(\.passage.id) == ["p1", "p3", "p2"])
        #expect(atlas.groundingSourceIDs(of: "c6") == ["s-keima"])
        #expect(atlas.groundingPassages(of: "c5").isEmpty)
        #expect(Set(atlas.groundingSourceIDs(of: "c1")) == Set(atlas.evidenceSourceIDs))
    }

    @Test("A concept's memory sums its sources' marks: fading over due over solid")
    func memoryStanding() {
        let marks: [String: KnowledgeMapMemoryMark] = [
            "a": .init(cards: 4, due: 0, fading: 0, solid: 4, lastReviewedAt: nil, dusty: false),
            "b": .init(cards: 2, due: 2, fading: 0, solid: 0, lastReviewedAt: nil, dusty: false),
            "c": .init(cards: 1, due: 0, fading: 1, solid: 0, lastReviewedAt: nil, dusty: true),
        ]
        #expect(AtlasMemoryStanding.of(sourceIDs: ["a"], marks: marks).tone == .solid)
        let due = AtlasMemoryStanding.of(sourceIDs: ["a", "b", "b"], marks: marks)
        #expect(due.tone == .due)
        #expect(due.line == "6 cards · 2 due")
        #expect(AtlasMemoryStanding.of(sourceIDs: ["a", "b", "c"], marks: marks).tone == .fading)
        let none = AtlasMemoryStanding.of(sourceIDs: ["x"], marks: marks)
        #expect(none.tone == .none)
        #expect(none.line == "No cards yet")
    }

    // MARK: The row

    @Test("An Atlas round-trips through its row in atlases, scope and all")
    func storeRoundTrip() throws {
        let store = try KnowledgeStore(inMemory: true)
        let atlas = try Self.mitophagyAtlas()
        try store.saveAtlasRow(try atlas.row())
        let row = try #require(try store.atlasRow(id: atlas.id))
        #expect(row.topic == "Mitophagy")
        #expect(row.notebookID == "nb1")
        let read = try Atlas(row: row)
        #expect(read == atlas)
        let listing = AtlasListing(row: row)
        #expect(listing.scope == atlas.scope)
        #expect(listing.answers(topic: "mitophagy ", scope: AtlasScope(itemRefs: ["idea:i1", "source:s-pink1"], notebookID: "nb1")))
        #expect(listing.answers(topic: nil, scope: atlas.scope), "the same cards with no topic named mean this Atlas")
        #expect(!listing.answers(topic: "Autophagy", scope: atlas.scope))
        #expect(!listing.answers(topic: "Mitophagy", scope: AtlasScope()))
        #expect(!AtlasListing(row: try Atlas(topic: "X", scope: AtlasScope(), rootID: "c1", concepts: atlas.concepts, passages: [], createdAt: Date(), updatedAt: Date()).row()).answers(topic: nil, scope: AtlasScope()),
                "a request naming nothing over the whole library means no stored Atlas")
    }

    @Test("A payload from a later version with words this build does not know still reads")
    func forwardCompatibleDecoding() throws {
        let payload = """
        {"id":"atlas:x","topic":"T","scope":{"itemRefs":["source:b","source:a"]},"rootID":"c1",
         "concepts":[{"id":"c1","name":"Root","kind":"subfield","status":"contested","relations":[{"to":"c2","kind":"inhibits"}],"evidence":[{"passageID":"p1","stance":"refutes"}],"newField":1},
                     {"id":"c2","name":"Leaf"}],
         "passages":[{"id":"p1","sourceID":"a","title":"A","text":"Words."}],
         "createdAt":1,"updatedAt":2,"version":2}
        """
        let atlas = try JSONDecoder().decode(Atlas.self, from: Data(payload.utf8))
        #expect(atlas.scope.itemRefs == ["source:a", "source:b"])
        #expect(atlas.concepts[0].kind == .concept)
        #expect(atlas.concepts[0].status == .debated)
        #expect(atlas.concepts[0].relations.first?.kind == .related)
        #expect(atlas.concepts[0].evidence.first?.stance == .supports)
        #expect(atlas.concepts[1].terms.isEmpty)
        #expect(atlas.concepts[1].deepened == false)
    }
}
