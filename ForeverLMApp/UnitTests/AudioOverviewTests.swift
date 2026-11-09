import Foundation
import Testing
@testable import ForeverLM

/// What the writer and the condensing pass were handed.
private final class AudioOverviewCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWrites: [(system: String, user: String)] = []
    private var storedParts: [AudioOverviewCondensePart] = []

    var writes: [(system: String, user: String)] {
        lock.lock(); defer { lock.unlock() }
        return storedWrites
    }

    var parts: [AudioOverviewCondensePart] {
        lock.lock(); defer { lock.unlock() }
        return storedParts
    }

    func recordWrite(system: String, user: String) {
        lock.lock(); defer { lock.unlock() }
        storedWrites.append((system, user))
    }

    func recordPart(_ part: AudioOverviewCondensePart) {
        lock.lock(); defer { lock.unlock() }
        storedParts.append(part)
    }
}

/// Answers with canned text, so the storage side and the planner can be
/// pinned without a provider.
private struct CannedAudioOverviewBackend: AudioOverviewModelBackend {
    var draft = AudioOverviewDraft(title: "What the notebook says", script: "  First paragraph.\n\nSecond paragraph.  ")
    var recorder: AudioOverviewCallRecorder? = nil
    /// What each condensing call answers; nil for a short canned account.
    var account: (@Sendable (AudioOverviewCondensePart) -> String)? = nil

    func condense(_ part: AudioOverviewCondensePart, route: AudioOverviewRoute) async throws -> String {
        recorder?.recordPart(part)
        return account?(part) ?? "Condensed account of \(part.sourceTitle), part \(part.index)."
    }

    func write(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        route: AudioOverviewRoute
    ) async throws -> AudioOverviewDraft {
        recorder?.recordWrite(system: system, user: user)
        return draft
    }
}

/// A writer whose answer has no script.
private struct FailingAudioOverviewBackend: AudioOverviewModelBackend {
    func condense(_ part: AudioOverviewCondensePart, route: AudioOverviewRoute) async throws -> String { "Condensed." }

    func write(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        route: AudioOverviewRoute
    ) async throws -> AudioOverviewDraft {
        throw AudioOverviewGenerationError.emptyScript
    }
}

/// The script sources whose audio files a delete removed.
private final class RemovedAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var ids: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func record(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(id)
    }
}

/// A provider that answers after the run was cancelled.
private struct LateAudioOverviewBackend: AudioOverviewModelBackend {
    func condense(_ part: AudioOverviewCondensePart, route: AudioOverviewRoute) async throws -> String { "Condensed." }

    func write(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        route: AudioOverviewRoute
    ) async throws -> AudioOverviewDraft {
        while !Task.isCancelled { await Task.yield() }
        return AudioOverviewDraft(title: "Late", script: "Arrived anyway.")
    }
}

private func makeTemporaryStorage() -> (StorageService, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioOverviewTests_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (StorageService(storeRoot: root), root)
}

@discardableResult
private func seedSource(
    _ storage: StorageService,
    url: String,
    title: String,
    type: StudioSourceType = .article,
    content: String?
) async throws -> StudioArticle {
    var article = StudioArticle(url: url, title: title, sourceType: type, discoveryOrigin: .manual)
    if let content {
        article.content = content
        article.wordCount = content.split(separator: " ").count
        article.state = .ready
    }
    try await storage.saveSource(article)
    return article
}

private func makeNotebook(_ storage: StorageService, title: String, sourceIDs: [String]) async throws -> LearningGoalRecord {
    try await storage.createCompanionGoal(
        title: title,
        topic: title,
        startAt: Date(),
        endAt: LearningGoalRecord.openEndedEndAt,
        dailyTarget: 3,
        discoveryEnabled: false,
        seedSourceIDs: sourceIDs
    )
}

/// A route with the window and price the test names; the model is unknown to
/// every catalog, so the run's own window check has nothing to trim against.
private func testRoute(
    writerBudget: Int? = nil,
    condenserBudget: Int? = nil,
    input: Double? = 1,
    output: Double? = 2
) -> AudioOverviewRoute {
    AudioOverviewRoute(
        provider: .openRouter,
        model: "test/audio-overview-writer",
        writerInputBudget: writerBudget,
        condenserInputBudget: condenserBudget,
        inputUSDPerMillion: input,
        outputUSDPerMillion: output
    )
}

/// The route a catalogued model really publishes: OpenRouter's GPT-4o, whose
/// window the context-budget tables pin, so the run's own refuse-rather-than-
/// cut check has a window to hold the turn to.
private func cataloguedRoute() throws -> AudioOverviewRoute {
    let model = "openai/gpt-4o"
    let writerBudget: Int = try #require(AIService.inputCharacterBudget(
        provider: .openRouter, model: model, requestedMaxTokens: AIService.audioOverviewWriterMaxTokens
    ))
    let condenserBudget: Int = try #require(AIService.inputCharacterBudget(
        provider: .openRouter, model: model, requestedMaxTokens: AudioOverviewCondensePart.largestMaxTokens
    ))
    return AudioOverviewRoute(
        provider: .openRouter,
        model: model,
        writerInputBudget: writerBudget,
        condenserInputBudget: condenserBudget,
        inputUSDPerMillion: 1,
        outputUSDPerMillion: 2
    )
}

/// A team this account joined and may write to. Joined, not owned: under generation 2
/// sharing a notebook into a space this account owns moves it (D21) and copies nothing,
/// and these tests are about what a copy carries.
private func makeTeam(_ store: KnowledgeStore, id: String = "team-audio") throws -> TeamRecord {
    let now = Date()
    let team = TeamRecord(
        id: id,
        name: "Nexus",
        role: .member,
        permission: .readWrite,
        zoneScope: .shared,
        zoneName: TeamRecord.zoneName(forTeamID: id),
        zoneOwnerRecordName: "_owner-record",
        shareRecordName: nil,
        shareURL: nil,
        createdAt: now,
        joinedAt: now,
        updatedAt: now
    )
    try store.saveTeam(team)
    return team
}

private func candidate(id: String, title: String, text: String, ideas: String? = nil) -> AudioOverviewNotebook.Candidate {
    var source = StudioArticle(url: "https://example.org/\(id)", title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
    source.state = .ready
    return AudioOverviewNotebook.Candidate(source: source, text: text, ideas: ideas)
}

@Suite("Audio Overview")
struct AudioOverviewTests {

    // MARK: - The carrier

    @Test("An overview's carrier URL names its Artifact and fixes the carrier's id, on both apps")
    func carrierGrammar() {
        let url = AudioOverviewScript.url(artifactID: "abc-123")
        #expect(url == "foreverlm://audio-overview/abc-123")
        #expect(AudioOverviewScript.isCarrierURL(url))
        #expect(AudioOverviewScript.isCarrierURL("  \(url)\n"))
        #expect(AudioOverviewScript.artifactID(fromCarrierURL: url) == "abc-123")
        #expect(!AudioOverviewScript.isCarrierURL("foreverlm://audio-overview/"))
        #expect(!AudioOverviewScript.isCarrierURL("foreverlm://audio-overview/a/b"))
        #expect(!AudioOverviewScript.isCarrierURL(ExplainerScript.url(explaining: "abc-123")))
        #expect(AudioOverviewScript.urlPrefix == TextToSpeechPreparationPolicy.audioOverviewURLPrefix)
        #expect(AudioOverviewScript.domain == ExplainerScript.domain)

        // `MobileCloudMutationServiceTests.testAudioOverviewIDMatchesTheMac`
        // pins the phone's id to this same literal: SHA-256 of
        // "source:v1:audio-overview/abc-123". Change one, change both.
        #expect(GeneratedAudioOverview.carrierSourceID(artifactID: "abc-123") == SourceIdentity.stableID(for: url))
        #expect(
            GeneratedAudioOverview.carrierSourceID(artifactID: "abc-123")
                == "src_fdae6341ed2b4c48f243fa5adf047366b1207d743dd2710ca92ccaf060bb8546"
        )
        #expect(URLNormalizer.normalize(url) == "audio-overview/abc-123")

        let carrier = GeneratedAudioOverview.carrierSource(artifactID: "abc-123", title: "T", script: "  One two.\n\nThree.  ")
        #expect(carrier.id == GeneratedAudioOverview.carrierSourceID(artifactID: "abc-123"))
        #expect(carrier.sourceType == .article)
        #expect(carrier.state == .ready)
        #expect(carrier.content == "One two.\n\nThree.")
        #expect(carrier.wordCount == 3)
        #expect(carrier.domain == AudioOverviewScript.domain)
        #expect(GeneratedAudioOverview.artifactID(ofCarrier: carrier) == "abc-123")
    }

    @Test("A carrier is a spoken script: never prepared, explained, walked, or under the Articles switch")
    func carrierIsASpokenScript() {
        let url = AudioOverviewScript.url(artifactID: "x")
        let explainer = ExplainerScript.url(explaining: "x")
        #expect(TextToSpeechPreparationPolicy.isSpokenScript(url: url))
        #expect(TextToSpeechPreparationPolicy.isSpokenScript(url: explainer))
        #expect(TextToSpeechPreparationPolicy.isAudioOverviewScript(url: url))
        #expect(!TextToSpeechPreparationPolicy.isAudioOverviewScript(url: explainer))
        #expect(!TextToSpeechPreparationPolicy.isSpokenScript(url: "https://example.org/audio-overview/x"))
        #expect(!TextToSpeechPreparationPolicy.usesAIPreparation(sourceType: "article", url: url))
        #expect(ExplainerScript.isSpokenScriptURL(url))
        #expect(!ExplainerScript.isExplainable(sourceType: "article", url: url))
        #expect(SourceAudioAutomation.kind(forSourceType: "article", url: url) == SourceAudioAutomation.explainerKind)
        #expect(SourceAudioAutomation.kind(forSourceType: "article", url: "https://example.org/a") == "article")

        let carrier = GeneratedAudioOverview.carrierSource(artifactID: "x", title: "T", script: "Script.")
        #expect(!GeneratedExplainer.canExplain(carrier))
        #expect(PaperWalkthroughSubject.of(carrier) == nil)
    }

    @MainActor
    @Test("No tab lists a carrier as a row of its own")
    func carrierIsInNoTab() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AudioOverviewTests_vm_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let vm = StudioViewModel(storageService: StorageService(storeRoot: tmp))
        var article = StudioArticle(url: "https://example.org/a", title: "A", sourceType: .article, discoveryOrigin: .manual)
        article.state = .ready
        let carrier = GeneratedAudioOverview.carrierSource(artifactID: "overview-1", title: "Overview", script: "Script.")
        vm.articles = [article, carrier]

        for tab in StudioSidebarTab.allCases {
            #expect(!vm.sourceBelongsToTab(carrier, tab: tab), "\(tab)")
        }
        #expect(vm.sidebarTab(listing: carrier) == nil)
        vm.sidebarTab = .articles
        #expect(vm.matchesCurrentTab(article))
        #expect(!vm.matchesCurrentTab(carrier))
        #expect(vm.activeTabArticles.map(\.id) == [article.id])
    }

    // MARK: - Formats and lengths

    @Test("Each format runs to its words and minutes; a brief has one length")
    func formatsAndLengths() {
        #expect(AudioOverviewFormat.allCases.map(\.rawValue) == ["deep_dive", "brief", "critique"])
        #expect(AudioOverviewLength.allCases.map(\.rawValue) == ["shorter", "default", "longer"])
        #expect(AudioOverviewFormat.default == .deepDive)
        #expect(AudioOverviewLength.default == .standard)

        #expect(AudioOverviewFormat.deepDive.wordRange(.shorter) == 900...1_200)
        #expect(AudioOverviewFormat.deepDive.wordRange(.standard) == 1_600...2_000)
        #expect(AudioOverviewFormat.deepDive.wordRange(.longer) == 2_600...3_100)
        #expect(AudioOverviewFormat.critique.wordRange(.shorter) == 700...900)
        #expect(AudioOverviewFormat.critique.wordRange(.standard) == 1_100...1_400)
        #expect(AudioOverviewFormat.critique.wordRange(.longer) == 1_800...2_200)
        for length in AudioOverviewLength.allCases {
            #expect(AudioOverviewFormat.brief.wordRange(length) == 280...340)
        }
        #expect(AudioOverviewLength.allCases.map { AudioOverviewFormat.deepDive.minutes($0) } == [7, 12, 19])
        #expect(AudioOverviewLength.allCases.map { AudioOverviewFormat.critique.minutes($0) } == [5, 8, 13])
        #expect(AudioOverviewFormat.brief.minutes(.longer) == 2)

        let brief = AudioOverviewOptions(format: .brief, length: .longer, focus: "  ")
        #expect(!brief.format.takesLength)
        #expect(brief.effectiveLength == nil)
        #expect(brief.wordRange == 280...340)
        #expect(brief.trimmedFocus == nil)
        let deep = AudioOverviewOptions(format: .deepDive, length: .longer, focus: " complex I ")
        #expect(deep.effectiveLength == .longer)
        #expect(deep.trimmedFocus == "complex I")
    }

    // MARK: - The record

    @Test("The recipe rides the body, and a body reads as an overview even when an older build dropped the kind")
    func recipeBody() throws {
        let settings = AudioOverviewSettings(
            format: .critique,
            length: .shorter,
            focus: "the methods",
            audioSourceID: GeneratedAudioOverview.carrierSourceID(artifactID: "o-1"),
            sources: [
                AudioOverviewSourceReading(sourceID: "a", title: "Paper A", readAs: .whole),
                AudioOverviewSourceReading(sourceID: "b", title: "Book B", readAs: .ideas),
                AudioOverviewSourceReading(sourceID: "c", title: "Talk C", readAs: .condensed),
            ],
            model: "test/model",
            madeAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let body = try AudioOverviewScript.markdown(settings: settings)
        #expect(body.hasPrefix(AudioOverviewScript.markerPrefix))
        #expect(AudioOverviewScript.isOverviewMarkdown(body))
        #expect(AudioOverviewScript.settings(fromMarkdown: body) == settings)
        #expect(body.contains("Read from their stored ideas: Book B."))
        #expect(body.contains("Read condensed: Talk C."))
        #expect(settings.headline == "Critique · 3 sources · about 5 min")
        #expect(settings.recipe == "Made from 3 sources · the methods · 1 read from their ideas · 1 condensed")
        #expect(settings.notReadWhole.map(\.sourceID) == ["b", "c"])

        let kindless = ArtifactRecord(id: "o-1", title: "T", homeNotebookID: "p", linkedNotebookIDs: ["p"], createdAt: Date(), updatedAt: Date())
        #expect(AudioOverviewScript.isOverview(kindless, markdown: body))
        #expect(!AudioOverviewScript.isOverview(kindless, markdown: "# A doc\n\nText."))
        #expect(!AudioOverviewScript.isOverview(kindless, markdown: nil))
        var linked = kindless
        linked.linkedURL = "https://docs.google.com/document/d/x/edit"
        #expect(!AudioOverviewScript.isOverview(linked, markdown: body))
        var kinded = kindless
        kinded.kind = .audioOverview
        #expect(kinded.isAudioOverview)
        #expect(AudioOverviewScript.isOverview(kinded, markdown: nil))
        #expect(kinded.section == .docs)
        #expect(kinded.kindLabel == "Audio overview")

        // The kind travels in the payload by its word, and an older build's
        // record with no kind still decodes.
        let data = try JSONEncoder().encode(kinded)
        let decoded = try JSONDecoder().decode(ArtifactRecord.self, from: data)
        #expect(decoded.kind == .audioOverview)
        #expect(String(decoding: data, as: UTF8.self).contains("\"audio_overview\""))
        #expect(ArtifactKind.audioOverview.label == AudioOverviewScript.kindLabel)
        #expect(ArtifactKind.audioOverview.symbolName == "waveform")
    }

    @Test("The writer's turn leads with the focus and says how each source was read")
    func writerTurn() {
        let turn = AudioOverviewWriterTurn.userMessage(
            notebookTitle: "Mitochondria",
            instructions: "For a physiologist.",
            options: AudioOverviewOptions(format: .deepDive, length: .standard, focus: "complex I"),
            sources: [
                AudioOverviewTurnSource(title: "Paper A", kind: "research paper", author: "Lane N", venue: "Cell", year: "2024", readAs: .whole, text: "Whole text."),
                AudioOverviewTurnSource(title: "Book B", kind: "book chapter", readAs: .ideas, text: "- An idea."),
                AudioOverviewTurnSource(title: "Talk C", kind: "video transcript", readAs: .condensed, text: "An account."),
            ]
        )
        let lines = turn.components(separatedBy: "\n")
        #expect(lines.first == "Focus: complex I")
        #expect(turn.contains("Notebook: Mitochondria"))
        #expect(turn.contains("Notebook instructions: For a physiologist."))
        #expect(turn.contains("Target length: 1600 to 2000 words, about 12 minutes spoken."))
        #expect(turn.contains(AudioOverviewWriterTurn.readingNote))
        #expect(turn.contains("Published: Cell, 2024"))
        #expect(turn.contains("Read: whole\nFull text:\nWhole text."))
        #expect(turn.contains("Read: from its ideas\nIts ideas:\n- An idea."))
        #expect(turn.contains("Read: condensed\nCondensed account:\nAn account."))
        #expect(turn.contains("=== Source 3 of 3 ==="))

        let noFocus = AudioOverviewWriterTurn.userMessage(
            notebookTitle: "N", instructions: nil, options: AudioOverviewOptions(format: .brief), sources: []
        )
        #expect(noFocus.hasPrefix("Notebook: N"))
        #expect(noFocus.contains("Target length: 280 to 340 words, about 2 minutes spoken."))
    }

    // MARK: - Fitting the window

    @Test("Everything is read whole when the window takes it, or when no window is published")
    func wholeWhenItFits() throws {
        let lengths = [
            AudioOverviewBudget.Length(id: "a", whole: 50_000, ideas: 2_000),
            AudioOverviewBudget.Length(id: "b", whole: 40_000, ideas: nil),
        ]
        let unpublished = try AudioOverviewBudget.choose(sources: lengths, fixedCharacters: 1_000, budget: nil, model: "m")
        #expect(unpublished.values.allSatisfy { $0.readAs == .whole })
        let roomy = try AudioOverviewBudget.choose(sources: lengths, fixedCharacters: 1_000, budget: 91_000, model: "m")
        #expect(roomy.values.allSatisfy { $0.readAs == .whole })
    }

    @Test("The largest sources give way first: ideas when stored, condensed otherwise, with the room left shared")
    func largestFirst() throws {
        let lengths = [
            AudioOverviewBudget.Length(id: "a", whole: 50_000, ideas: 2_000),
            AudioOverviewBudget.Length(id: "b", whole: 40_000, ideas: nil),
            AudioOverviewBudget.Length(id: "c", whole: 1_000, ideas: nil),
        ]
        let choices = try AudioOverviewBudget.choose(sources: lengths, fixedCharacters: 1_000, budget: 20_000, model: "m")
        #expect(choices["a"] == AudioOverviewBudget.Choice(readAs: .ideas, targetCharacters: nil))
        // The room left — 20,000 less 1,000 fixed, 2,000 of ideas and 1,000
        // whole — is asked for at 80%, so the account lands inside the window.
        #expect(choices["b"] == AudioOverviewBudget.Choice(readAs: .condensed, targetCharacters: 12_800))
        #expect(choices["c"] == AudioOverviewBudget.Choice(readAs: .whole, targetCharacters: nil))
    }

    @Test("Nothing is cut: a turn that cannot fit even condensed is refused")
    func refusesRatherThanCuts() {
        let lengths = [AudioOverviewBudget.Length(id: "a", whole: 30_000, ideas: nil)]
        #expect(throws: AudioOverviewGenerationError.doesNotFit(model: "m", sourceCount: 1)) {
            _ = try AudioOverviewBudget.choose(sources: lengths, fixedCharacters: 10_000, budget: 5_000, model: "m")
        }
    }

    @Test("The condensing pass reads every character of a source once, in order")
    func condensingCoversTheWholeText() throws {
        let paragraph = String(repeating: "Mitochondria make most of the cell's energy. ", count: 40)
        let text = (1...60).map { "Section \($0). \(paragraph)" }.joined(separator: "\n\n")
        let pieces = AudioOverviewGeneratorService.splitConsecutively(text, into: 4)
        #expect(pieces.count == 4)
        #expect(pieces.joined() == text)
        #expect(pieces.allSatisfy { !$0.isEmpty })

        let long = candidate(id: "long", title: "Long", text: text)
        let parts = try AudioOverviewGeneratorService.condensingParts(
            of: long,
            targetCharacters: 12_000,
            route: testRoute(writerBudget: 50_000, condenserBudget: 30_000)
        )
        #expect(parts.count > 1)
        #expect(parts.map(\.text).joined() == text)
        #expect(parts.map(\.index) == Array(1...parts.count))
        #expect(parts.allSatisfy { $0.count == parts.count && $0.sourceID == "long" })
        #expect(parts.allSatisfy { $0.userMessage.contains("Part \($0.index) of \(parts.count)") })
    }

    @Test("The writing is priced honestly: unpriced reads unknown, a free route free")
    func writingCost() throws {
        let notebook = AudioOverviewNotebook(
            notebookID: "p", title: "N", instructions: nil,
            candidates: [candidate(id: "a", title: "A", text: String(repeating: "word ", count: 2_000))],
            skipped: []
        )
        let request = AudioOverviewRequest(notebookID: "p", options: AudioOverviewOptions())
        let unpriced = try AudioOverviewGeneratorService.plan(notebook, request: request, route: testRoute(input: nil, output: nil), system: "S")
        #expect(unpriced.writingCost.label == "price unknown")
        #expect(unpriced.writingCost.expectedUSD == nil)
        let free = try AudioOverviewGeneratorService.plan(notebook, request: request, route: testRoute(input: 0, output: 0), system: "S")
        #expect(free.writingCost.label == "free")
        let priced = try AudioOverviewGeneratorService.plan(notebook, request: request, route: testRoute(input: 1, output: 2), system: "S")
        let expected = try #require(priced.writingCost.expectedUSD)
        let maximum = try #require(priced.writingCost.maximumUSD)
        #expect(expected > 0 && maximum >= expected)
        #expect(priced.writingCost.label.hasPrefix("about $"))
        #expect(priced.writingCost.requestCount == 1)
        #expect(priced.expectedScriptCharacters == 2_000 * 6)
        #expect(priced.sourcesSummary == "1 source")

        let empty = AudioOverviewNotebook(notebookID: "p", title: "Empty", instructions: nil, candidates: [], skipped: [])
        #expect(throws: AudioOverviewGenerationError.noSources("Empty")) {
            _ = try AudioOverviewGeneratorService.plan(empty, request: request, route: testRoute(), system: "S")
        }
    }

    // MARK: - Pipeline

    @Test("An overview is saved as an Artifact homed on the notebook, with its script on the carrier")
    func writesAndSaves() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "Paper A", content: "The whole text of A.")
        let b = try await seedSource(storage, url: "https://journal.example/b", title: "Article B", content: "The whole text of B.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id, b.id])

        let recorder = AudioOverviewCallRecorder()
        let service = AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend(recorder: recorder))
        let loaded = try await service.load(notebookID: notebook.id)
        #expect(Set(loaded.candidates.map(\.source.id)) == [a.id, b.id])
        let plan = try AudioOverviewGeneratorService.plan(
            loaded,
            request: AudioOverviewRequest(notebookID: notebook.id, options: AudioOverviewOptions(focus: "energy")),
            route: testRoute()
        )
        let result = try await service.run(plan, artifactID: "overview-1")

        #expect(result.artifact.id == "overview-1")
        #expect(result.artifact.kind == .audioOverview)
        #expect(result.artifact.homeNotebookID == notebook.id)
        #expect(result.artifact.linkedNotebookIDs == [notebook.id])
        #expect(Set(result.artifact.sourceIDs) == Set([a.id, b.id]))
        #expect(result.artifact.title == "What the notebook says")
        #expect(result.carrier.id == GeneratedAudioOverview.carrierSourceID(artifactID: "overview-1"))
        #expect(result.settings.audioSourceID == result.carrier.id)
        #expect(result.settings.sources.map(\.readAs) == [.whole, .whole])
        #expect(result.settings.focus == "energy")

        // The writer was handed every source whole, and nothing was condensed.
        #expect(recorder.parts.isEmpty)
        let user = try #require(recorder.writes.first?.user)
        #expect(user.contains("The whole text of A."))
        #expect(user.contains("The whole text of B."))
        #expect(user.hasPrefix("Focus: energy"))

        let carrier = try #require(try await storage.loadSourceWithoutContent(result.carrier.id))
        #expect(carrier.url == AudioOverviewScript.url(artifactID: "overview-1"))
        let script = await storage.loadSourceContent(result.carrier.id)
        #expect(script == "First paragraph.\n\nSecond paragraph.")
        let body = try await storage.artifactMarkdown("overview-1")
        #expect(AudioOverviewScript.settings(fromMarkdown: body.markdown) == result.settings)
        // The carrier is not one of the notebook's sources.
        let pool = try await storage.notebookContextSourceIDs(notebookID: notebook.id)
        #expect(!pool.contains(result.carrier.id))
    }

    @Test("A source too long for the window is read from a condensed account of its whole text, and the turn says so")
    func condensesWhatDoesNotFit() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let longText = (1...400).map { "Paragraph \($0) of the long chapter about the respiratory chain." }.joined(separator: "\n\n")
        let long = try await seedSource(storage, url: "https://books.example/long", title: "Long Chapter", content: longText)
        let short = try await seedSource(storage, url: "https://journal.example/short", title: "Short", content: "A short text.")
        let notebook = try await makeNotebook(storage, title: "Respiration", sourceIDs: [long.id, short.id])

        let recorder = AudioOverviewCallRecorder()
        let service = AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend(recorder: recorder))
        let loaded = try await service.load(notebookID: notebook.id)
        let plan = try AudioOverviewGeneratorService.plan(
            loaded,
            request: AudioOverviewRequest(notebookID: notebook.id, options: AudioOverviewOptions()),
            route: testRoute(writerBudget: 20_000),
            system: "System."
        )
        #expect(plan.sources.map(\.readAs) == [.condensed, .whole])
        #expect(plan.condensingCallCount >= 1)
        #expect(plan.sourcesSummary == "2 sources · 1 condensed")
        let result = try await service.run(plan, artifactID: "overview-2")

        // The parts are condensed side by side; in their own order they are
        // the whole text, nothing left out.
        #expect(recorder.parts.sorted { $0.index < $1.index }.map(\.text).joined() == longText)
        let user = try #require(recorder.writes.first?.user)
        #expect(user.contains("Read: condensed"))
        #expect(user.contains("Condensed account of Long Chapter, part 1."))
        #expect(!user.contains("Paragraph 400 of the long chapter"))
        #expect(user.contains("A short text."))
        #expect(result.settings.sources.map(\.readAs) == [.condensed, .whole])
        #expect(result.settings.summaryLine.contains("Read condensed: Long Chapter."))
    }

    @Test("Deleting the overview deletes its carrier, and deleting the carrier deletes the overview")
    func deleteCascadesBothWays() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A.")
        let notebook = try await makeNotebook(storage, title: "N", sourceIDs: [a.id])
        let service = AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend())
        let loaded = try await service.load(notebookID: notebook.id)
        let request = AudioOverviewRequest(notebookID: notebook.id, options: AudioOverviewOptions(format: .brief))
        let plan = try AudioOverviewGeneratorService.plan(loaded, request: request, route: testRoute())

        let first = try await service.run(plan, artifactID: "overview-a")
        try await storage.deleteArtifact(first.artifact.id)
        #expect(try await storage.loadSourceWithoutContent(first.carrier.id) == nil)
        #expect(try await storage.loadArtifacts().contains { $0.id == first.artifact.id } == false)

        let second = try await service.run(plan, artifactID: "overview-b")
        try await storage.deleteSource(second.carrier.id)
        #expect(try await storage.loadArtifacts().contains { $0.id == second.artifact.id } == false)
        #expect(try await storage.loadSourceWithoutContent(a.id) != nil)
    }

    @Test("A cancelled run saves nothing, even when the writer answers after the cancel")
    func cancelledRunSavesNothing() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A.")
        let notebook = try await makeNotebook(storage, title: "N", sourceIDs: [a.id])
        let service = AudioOverviewGeneratorService(storage: storage, backend: LateAudioOverviewBackend())
        let loaded = try await service.load(notebookID: notebook.id)
        let plan = try AudioOverviewGeneratorService.plan(
            loaded, request: AudioOverviewRequest(notebookID: notebook.id, options: AudioOverviewOptions()), route: testRoute()
        )
        let run = Task { try await service.run(plan, artifactID: "overview-late") }
        await Task.yield()
        run.cancel()
        let outcome = await run.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(try await storage.loadSourceWithoutContent(GeneratedAudioOverview.carrierSourceID(artifactID: "overview-late")) == nil)
        #expect(try await storage.loadArtifacts().isEmpty)
    }

    @Test("Spoken scripts and sources without text are set aside with the reason; sources outside the notebook are refused")
    func loadSetsAsideAndRefuses() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A.")
        let textless = try await seedSource(storage, url: "https://journal.example/none", title: "None", content: nil)
        var explainer = StudioArticle(url: ExplainerScript.url(explaining: a.id), title: "Explainer: A", sourceType: .article, discoveryOrigin: .manual)
        explainer.content = "A spoken script."
        explainer.state = .ready
        try await storage.saveSource(explainer)
        let outside = try await seedSource(storage, url: "https://journal.example/out", title: "Out", content: "Elsewhere.")
        let notebook = try await makeNotebook(storage, title: "N", sourceIDs: [a.id, textless.id, explainer.id])

        let service = AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend())
        let loaded = try await service.load(notebookID: notebook.id)
        #expect(loaded.candidates.map(\.source.id) == [a.id])
        #expect(Set(loaded.skipped.map(\.sourceID)) == Set([textless.id, explainer.id]))
        #expect(loaded.selectedCount == 3)

        await #expect(throws: AudioOverviewGenerationError.sourceNotInNotebook([outside.id])) {
            _ = try await service.load(notebookID: notebook.id, sourceIDs: [a.id, outside.id])
        }
        await #expect(throws: AudioOverviewGenerationError.notebookNotFound("missing")) {
            _ = try await service.load(notebookID: "missing")
        }
    }

    @Test("A context notebook's sources reach the notebook's chats once put in, never its writers: not unasked, and not by name")
    func writersLeaveContextNotebooksOut() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A.")
        let lent = try await seedSource(storage, url: "https://journal.example/lent", title: "Lent", content: "Text of the context notebook's source.")
        let notebook = try await makeNotebook(storage, title: "N", sourceIDs: [a.id])
        let related = try await makeNotebook(storage, title: "R", sourceIDs: [lent.id])
        try await storage.setRelatedNotebooks(notebookID: notebook.id, relatedNotebookIDs: [related.id])
        #expect(try await storage.notebookContextSourceIDs(notebookID: notebook.id) == [a.id, lent.id], "a box can stand for either")
        let linked = try #require(try await storage.loadLearningGoal(notebook.id))
        let contextNotebooks = NotebookChatSelection.contextNotebooks(of: linked) { $0 == related.id ? [lent.id] : nil }

        try await NotebookStateStore.$override.withValue(NotebookStateStore.Box()) { () async throws -> Void in
            #expect(NotebookChatContext.chatSourceIDs(
                own: linked.approvedSourceIDs,
                linked: contextNotebooks,
                selection: NotebookChatSelection.selection(notebookID: notebook.id)
            ) == [a.id], "linked alone, its chats read only its own")
            NotebookChatSelection.writeContextNotebooks([related.id], notebookID: notebook.id)
            #expect(NotebookChatContext.chatSourceIDs(
                own: linked.approvedSourceIDs,
                linked: contextNotebooks,
                selection: NotebookChatSelection.selection(notebookID: notebook.id)
            ) == [a.id, lent.id], "put in, its chats read both")

            #expect(try await AudioOverviewGeneratorService.notebookSourceIDs(notebookID: notebook.id, storage: storage) == [a.id])
            let service = AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend())
            #expect(try await service.load(notebookID: notebook.id).candidates.map(\.source.id) == [a.id])
            await #expect(throws: AudioOverviewGenerationError.sourceNotInNotebook([lent.id])) {
                _ = try await service.load(notebookID: notebook.id, sourceIDs: [lent.id])
            }
        }
    }

    // MARK: - The window, read from a catalogued model

    @Test("On a catalogued window a turn that fits is sent as built")
    func cataloguedWindowSendsAFittingTurn() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "Paper A", content: "The whole text of A.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id])
        let recorder = AudioOverviewCallRecorder()
        let service = AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend(recorder: recorder))
        let plan = try AudioOverviewGeneratorService.plan(
            try await service.load(notebookID: notebook.id),
            request: AudioOverviewRequest(notebookID: notebook.id, options: AudioOverviewOptions()),
            route: try cataloguedRoute()
        )
        #expect(plan.sources.map(\.readAs) == [.whole])
        _ = try await service.run(plan, artifactID: "overview-fits")
        #expect(recorder.writes.count == 1)
        #expect(recorder.writes.first?.user.contains("The whole text of A.") == true)
    }

    @Test("On a catalogued window a condensed account that comes back too long is refused, never cut, and nothing is written or saved")
    func cataloguedWindowRefusesAnOverflowingTurn() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let route = try cataloguedRoute()
        let budget = try #require(route.writerInputBudget)
        let line = "A paragraph about the respiratory chain and its proton pumps.\n"
        let longText = String(repeating: line, count: budget / line.count + 2_000)
        let long = try await seedSource(storage, url: "https://books.example/long", title: "Long Chapter", content: longText)
        let short = try await seedSource(storage, url: "https://journal.example/short", title: "Short", content: "A short text.")
        let notebook = try await makeNotebook(storage, title: "Respiration", sourceIDs: [long.id, short.id])

        // Every part answers with its whole share of the window and more, so
        // the accounts together overflow the writer's request.
        let recorder = AudioOverviewCallRecorder()
        let backend = CannedAudioOverviewBackend(recorder: recorder) { part in
            String(repeating: "x", count: budget / part.count + 1_000)
        }
        let service = AudioOverviewGeneratorService(storage: storage, backend: backend)
        let plan = try AudioOverviewGeneratorService.plan(
            try await service.load(notebookID: notebook.id),
            request: AudioOverviewRequest(notebookID: notebook.id, options: AudioOverviewOptions()),
            route: route
        )
        #expect(plan.sources.map(\.readAs) == [.condensed, .whole])
        await #expect(throws: AudioOverviewGenerationError.condensedTooLong(model: route.modelLabel)) {
            _ = try await service.run(plan, artifactID: "overview-overflows")
        }
        #expect(!recorder.parts.isEmpty)
        #expect(recorder.writes.isEmpty)
        #expect(try await storage.loadArtifacts().isEmpty)
        #expect(try await storage.loadSourceWithoutContent(GeneratedAudioOverview.carrierSourceID(artifactID: "overview-overflows")) == nil)
    }

    @Test("A window with no room for one condensing request is refused, with no invented floor")
    func windowTooSmallToCondense() {
        let route = AudioOverviewRoute(
            provider: .openRouter,
            model: "test/tiny",
            writerInputBudget: 1_000,
            condenserInputBudget: 500,
            inputUSDPerMillion: 1,
            outputUSDPerMillion: 2
        )
        #expect(throws: AudioOverviewGenerationError.windowTooSmall(model: "test/tiny")) {
            _ = try AudioOverviewGeneratorService.condensingParts(
                of: candidate(id: "a", title: "A", text: String(repeating: "word ", count: 2_000)),
                targetCharacters: 2_400,
                route: route
            )
        }
    }

    // MARK: - Stored ideas

    @Test("Stored ideas stand in only for the whole text they were taken from: as stored, a trailing newline included, and never past what extraction reads")
    func ideasThroughLoad() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        // Stored with a trailing newline, which extraction hashes as is.
        let shortText = "The whole text of A, about complex I.\n"
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "Paper A", content: shortText)
        // Longer than extraction read before 2026-09-30: its ideas may leave the tail out.
        let line = "A sentence about the respiratory chain.\n"
        let longText = String(repeating: line, count: SourceIdeaDrafting.legacyReadCharacters / line.count + 100)
        #expect(longText.count > SourceIdeaDrafting.legacyReadCharacters)
        let b = try await seedSource(storage, url: "https://books.example/b", title: "Book B", content: longText)
        for (source, text) in [(a, shortText), (b, longText)] {
            let hash = SourceIdeaDrafting.contentHash(text)
            try await storage.replaceSourceIdeas(sourceID: source.id, contentHash: hash, ideas: [
                SourceIdea(
                    id: SourceIdea.id(sourceID: source.id, contentHash: hash, index: 0),
                    sourceID: source.id,
                    statement: "Complex I pumps protons.",
                    recallNote: "Four per NADH.",
                    contentHash: hash,
                    sortIndex: 0
                ),
            ])
        }
        let notebook = try await makeNotebook(storage, title: "N", sourceIDs: [a.id, b.id])

        let loaded = try await AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend())
            .load(notebookID: notebook.id)
        let byID = Dictionary(uniqueKeysWithValues: loaded.candidates.map { ($0.source.id, $0) })
        let first = try #require(byID[a.id])
        #expect(first.ideas?.contains("Complex I pumps protons.") == true)
        #expect(first.ideas?.contains("A good recall holds: Four per NADH.") == true)
        // The writer reads the text trimmed; the hash was of the text as stored.
        #expect(first.text == "The whole text of A, about complex I.")
        let second = try #require(byID[b.id])
        #expect(second.ideas == nil)
        #expect(second.text.count > SourceIdeaDrafting.legacyReadCharacters - 1)
    }

    // MARK: - Sync, teams, clean-up, Memory

    @Test("An inbound delete of either half takes the other and publishes its tombstone, for the client that never knew")
    func inboundDeleteCascades() throws {
        let store = try KnowledgeStore(inMemory: true)
        func makeOverview(_ id: String) throws -> String {
            let carrier = GeneratedAudioOverview.carrierSource(artifactID: id, title: "Overview \(id)", script: "Script.")
            try store.saveSource(carrier)
            try store.saveArtifactRecord(ArtifactRecord(
                id: id, title: "Overview \(id)", homeNotebookID: nil, linkedNotebookIDs: [],
                kind: .audioOverview, createdAt: Date(), updatedAt: Date()
            ))
            return carrier.id
        }

        // The Artifact deleted on another Mac: the carrier goes too, and its
        // tombstone is sent for a deleting client that never sent it.
        let firstCarrier = try makeOverview("overview-inbound-1")
        try store.clearAllPendingSyncChanges()
        try store.withoutSyncTracking { try store.deleteArtifactRecord("overview-inbound-1") }
        #expect(try store.loadSourceWithoutContent(firstCarrier) == nil)
        let afterArtifact = try store.pendingSyncChanges()
        #expect(afterArtifact.contains { $0.entity == .source && $0.logicalKey == firstCarrier && $0.operation == .delete })
        #expect(!afterArtifact.contains { $0.entity == .artifact })

        // The carrier deleted elsewhere: the Artifact goes, tombstone included.
        let secondCarrier = try makeOverview("overview-inbound-2")
        try store.clearAllPendingSyncChanges()
        try store.withoutSyncTracking { try store.deleteSource(secondCarrier) }
        #expect(try store.loadArtifact("overview-inbound-2") == nil)
        let afterCarrier = try store.pendingSyncChanges()
        #expect(afterCarrier.contains { $0.entity == .artifact && $0.logicalKey == "overview-inbound-2" && $0.operation == .delete })
        #expect(!afterCarrier.contains { $0.entity == .source })
    }

    @Test("An overview stays out of a team: sharing its notebook copies its Docs and not it, and sharing it alone is refused, kind or no kind")
    func teamsLeaveOverviewsOut() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A.")
        let notebook = try await makeNotebook(storage, title: "N", sourceIDs: [a.id])
        let service = AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend())
        let plan = try AudioOverviewGeneratorService.plan(
            try await service.load(notebookID: notebook.id),
            request: AudioOverviewRequest(notebookID: notebook.id, options: AudioOverviewOptions(format: .brief)),
            route: testRoute()
        )
        let overview = try await service.run(plan, artifactID: "overview-team")
        let doc = try await storage.createArtifact(
            title: "Notes", homeNotebookID: notebook.id, linkedNotebookIDs: [notebook.id], markdown: "# Notes\n\nText."
        )
        let store = try await storage.notebookFilesKnowledgeStore()
        let team = try makeTeam(store)

        _ = try await storage.shareNotebook(notebook.id, withTeam: team.id, includeSources: false, includeDocs: true, includeChats: false)
        let docCopy = TeamContentIdentity.artifactCopyID(teamID: team.id, original: doc.artifact)
        let overviewCopy = TeamContentIdentity.artifactCopyID(teamID: team.id, original: overview.artifact)
        #expect(try store.loadArtifact(docCopy) != nil)
        #expect(try store.loadArtifact(overviewCopy) == nil)

        await #expect(throws: KnowledgeStoreError.self) {
            _ = try await storage.shareArtifact(overview.artifact.id, withTeam: team.id)
        }
        // A record an older build saved back without its kind is still one,
        // by the script source its id names.
        var kindless = overview.artifact
        kindless.kind = nil
        try store.saveArtifactRecord(kindless)
        #expect(try store.isAudioOverview(kindless))
        #expect(try !store.isAudioOverview(doc.artifact))
        await #expect(throws: KnowledgeStoreError.self) {
            _ = try await storage.shareArtifact(overview.artifact.id, withTeam: team.id)
        }
        #expect(try store.loadArtifact(overviewCopy) == nil)
    }

    @Test("A spoken script is never queued for the paid clean-up pass, and one queued before is pruned")
    func spokenScriptsSkipCleanup() throws {
        let store = try KnowledgeStore(inMemory: true)
        func queued() throws -> Set<String> {
            var ids = Set<String>()
            try store.queryBind("SELECT source_id FROM canonical_content_cleanup_queue", bind: { _ in }) { stmt in
                if let id = store.string(stmt, 0) { ids.insert(id) }
            }
            return ids
        }
        var article = StudioArticle(url: "https://example.org/clean", title: "Article", sourceType: .article, discoveryOrigin: .manual)
        article.content = "A body worth cleaning."
        article.state = .ready
        try store.saveSource(article)
        let carrier = GeneratedAudioOverview.carrierSource(artifactID: "overview-clean", title: "Overview", script: "The script.")
        try store.saveSource(carrier)
        #expect(try queued().contains(article.id))
        #expect(try !queued().contains(carrier.id))

        // An explainer a build before this rule queued.
        var explainer = StudioArticle(url: ExplainerScript.url(explaining: article.id), title: "Explainer", sourceType: .article, discoveryOrigin: .manual)
        explainer.content = "An explainer's script."
        explainer.state = .ready
        try store.saveSource(explainer)
        #expect(try !queued().contains(explainer.id))
        try store.execForTesting("""
            INSERT OR REPLACE INTO canonical_content_cleanup_queue
                (source_id, target_version, enqueued_at, attempt_count, last_error, source_sha256)
            VALUES ('\(explainer.id)', \(PaperContentPreparationMetadata.currentVersion), 0, 0, NULL, NULL)
        """)
        #expect(try !store.canonicalContentCleanupCandidates(limit: 50).contains { $0.sourceID == explainer.id })
        #expect(try store.pruneIneligibleCanonicalContentCleanupQueue() >= 1)
        #expect(try !queued().contains(explainer.id))
        #expect(try queued().contains(article.id))
    }

    @Test("Hearing an overview is not a source to review: its script never joins Memory's candidates or extracts ideas")
    func overviewScriptIsNoReviewCandidate() async throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var article = StudioArticle(url: "https://example.com/heard", title: "Heard")
        article.content = String(repeating: "Body worth reviewing. ", count: 20)
        try store.saveSource(article)
        let carrier = GeneratedAudioOverview.carrierSource(
            artifactID: "overview-heard",
            title: "Overview",
            script: String(repeating: "A spoken retelling. ", count: 20)
        )
        try store.saveSource(carrier)
        for id in [article.id, carrier.id] {
            _ = try store.recordScheduledSourceActivity(
                sourceID: id, on: now.addingTimeInterval(-86_400), kind: .listening, fraction: 0.9, engagedSeconds: 600
            )
        }
        #expect(try store.cohortCandidates(now: now).map(\.sourceID) == [article.id])

        // Reading or hearing it to the end warms extraction, which refuses.
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = GeneratedAudioOverview.carrierSource(artifactID: "overview-heard-2", title: "Overview", script: "A retelling.")
        try await storage.saveSource(saved)
        let extraction = SourceIdeaExtractionService(storage: storage, aiService: AIService())
        await #expect(throws: SourceIdeaExtractionError.self) {
            _ = try await extraction.prepare(sourceID: saved.id)
        }
    }

    // MARK: - The narration's price

    @Test("Make's agreement covers a script that costs no more with the voice it was quoted for, and nothing else")
    func narrationApproval() throws {
        let notebook = AudioOverviewNotebook(
            notebookID: "p", title: "N", instructions: nil,
            candidates: [candidate(id: "a", title: "A", text: "Text.")],
            skipped: []
        )
        let plan = try AudioOverviewGeneratorService.plan(
            notebook, request: AudioOverviewRequest(notebookID: "p", options: AudioOverviewOptions()), route: testRoute(), system: "S"
        )
        func quote(_ usd: Double?) -> AudioOverviewQuote {
            AudioOverviewQuote(
                plan: plan,
                audio: ArticleSpeechCostEstimate(characters: plan.expectedScriptCharacters, usd: usd),
                speechProvider: "openrouter",
                speechModel: "test/tts",
                voice: "Kore",
                voiceLabel: "Test TTS · Kore",
                audioStartsAutomatically: false,
                speechConfigurationError: nil
            )
        }
        let quoted = quote(0.40)
        #expect(quoted.approvesNarration(costing: 0.31, provider: "openrouter", model: "test/tts"))
        #expect(quoted.approvesNarration(costing: 0.40, provider: "openrouter", model: "test/tts"))
        #expect(!quoted.approvesNarration(costing: 0.41, provider: "openrouter", model: "test/tts"))
        #expect(!quoted.approvesNarration(costing: nil, provider: "openrouter", model: "test/tts"))
        #expect(!quoted.approvesNarration(costing: 0.10, provider: "openrouter", model: "other/tts"))
        #expect(!quote(nil).approvesNarration(costing: 0.10, provider: "openrouter", model: "test/tts"))
        #expect(quote(0).approvesNarration(costing: 0, provider: "openrouter", model: "test/tts"))
    }

    // MARK: - The task

    @Test("Audio Overview Writing is a learner-started Settings task with the writer's prompt")
    func task() {
        let task = AITask.audioOverviewWriting
        #expect(task.rawValue == "audio_overview_writing")
        #expect(task.defaultPrompt == Prompts.audioOverviewWriter)
        #expect(task.sourceType == nil)
        #expect(!task.isBackgroundWork)
        #expect(!AITask.backgroundWorkTaskIDs.contains(task.rawValue))
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "audio_overview_writing")?.displayName == "Audio Overview Writing")
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "audio_overview_writing")?.showInAdvancedSettings == true)
        #expect(AIUsageTaskLabel.text(for: "audio_overview_writing") == "Write Audio Overview")
        #expect(Prompts.audioOverviewWriter.contains(Prompts.textbookExplanation))
    }
}

// MARK: - generate_audio_overview

private func makeMCPStore() -> (MCPDataStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioOverviewMCPTests_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path), root)
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

/// The narration's price, handed in so the developer's own voice never
/// decides the outcome.
private func paidAudioQuote(_ usd: Double) -> @Sendable (AudioOverviewPlan) async -> AudioOverviewQuote {
    { plan in
        AudioOverviewQuote(
            plan: plan,
            audio: ArticleSpeechCostEstimate(characters: plan.expectedScriptCharacters, usd: usd),
            speechProvider: "OpenRouter",
            speechModel: "test/tts",
            voice: "Kore",
            voiceLabel: "Test TTS · Kore",
            audioStartsAutomatically: false,
            speechConfigurationError: nil
        )
    }
}

/// A selection automation may never spend on, so the Explainers switch on
/// the test host cannot stand in for the confirmation.
private let neverAutomatic = AutomaticAudioSelection(provider: .groq, model: "test/tts", voice: "Kore", allowsPaidVoices: false)

@Suite("Audio Overview over MCP")
struct AudioOverviewMCPTests {
    @Test("generate_audio_overview is registered as paid, self-gated, Notebook-scoped work with a popup")
    func registration() throws {
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "generate_audio_overview" })
        let required = try #require(tool.inputSchema["required"] as? [String])
        #expect(required == ["notebook_id"])
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        #expect((properties["format"] as? [String: Any])?["enum"] as? [String] == ["deep_dive", "brief", "critique"])
        #expect((properties["length"] as? [String: Any])?["enum"] as? [String] == ["shorter", "default", "longer"])
        #expect(properties["approved_spend_usd"] != nil)
        #expect(tool.description.contains("cancel_ai_work"))
        #expect(MCPToolRegistry.paidWorkToolNames.contains("generate_audio_overview"))
        #expect(MCPToolRegistry.selfGatedToolNames.contains("generate_audio_overview"))
        #expect(MCPToolActivityTitle.shownToolNames.contains("generate_audio_overview"))
        let title = try #require(MCPToolActivityTitle.forTool("generate_audio_overview", arguments: [:]))
        #expect(title.subject == .notebook)
        #expect(title.text(subjectName: "Mitochondria") == "Writing an audio overview of Mitochondria")
        #expect(MCPRunningWork.about(["notebook_id": "p-1", "focus": "x"]) == "notebook_id p-1")
    }

    @Test("generate_audio_overview refuses what it cannot make, and prices a paid voice before spending anything")
    func refusals() async throws {
        let (store, root) = makeMCPStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = store.notebookFileStorage
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A, enough to talk about.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id])
        let route = testRoute()

        await #expect(throws: MCPError.self) {
            _ = try await store.generateAudioOverview(arguments: [:], backend: CannedAudioOverviewBackend(), route: route)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.generateAudioOverview(
                arguments: ["notebook_id": notebook.id, "format": "debate"],
                backend: CannedAudioOverviewBackend(), route: route
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.generateAudioOverview(
                arguments: ["notebook_id": "missing"], backend: CannedAudioOverviewBackend(), route: route
            )
        }

        // A paid voice and no confirm_cost: the estimate, and nothing written.
        let quoted = try object(try await store.generateAudioOverview(
            arguments: ["notebook_id": notebook.id, "format": "brief"],
            backend: CannedAudioOverviewBackend(),
            route: route,
            audioQuote: paidAudioQuote(0.40),
            automaticAudioSelection: neverAutomatic
        ))
        #expect(quoted["status"] as? String == "awaiting_confirmation")
        #expect(quoted["work_id"] == nil)
        let estimate = try #require(quoted["estimate"] as? [String: Any])
        #expect((estimate["audio"] as? [String: Any])?["estimated_cost_usd"] as? Double == 0.40)
        #expect(estimate["writing"] is [String: Any])
        #expect((quoted["sources"] as? [[String: Any]])?.first?["read_as"] as? String == "whole")
        #expect(try await storage.loadArtifacts().isEmpty)

        // Agreed, but above the approved ceiling: still nothing started.
        let tooLow = try object(try await store.generateAudioOverview(
            arguments: ["notebook_id": notebook.id, "confirm_cost": true, "approved_spend_usd": 0.01],
            backend: CannedAudioOverviewBackend(),
            route: route,
            audioQuote: paidAudioQuote(0.40),
            automaticAudioSelection: neverAutomatic
        ))
        #expect(tooLow["status"] as? String == "approval_too_low")
        #expect(try await storage.loadArtifacts().isEmpty)
    }

    @Test("generate_audio_overview starts background work and saves the overview with its carrier")
    func startsInTheBackground() async throws {
        let (store, root) = makeMCPStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = store.notebookFileStorage
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A, enough to talk about.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id])

        let started = try object(try await store.generateAudioOverview(
            arguments: ["notebook_id": notebook.id, "format": "critique", "length": "shorter", "generate_audio": false],
            backend: CannedAudioOverviewBackend(),
            route: testRoute(),
            audioQuote: paidAudioQuote(0.40),
            automaticAudioSelection: neverAutomatic
        ))
        #expect(started["status"] as? String == "started")
        let workID = try #require(started["work_id"] as? String)
        let overviewID = try #require(started["overview_id"] as? String)
        #expect(started["audio_source_id"] as? String == GeneratedAudioOverview.carrierSourceID(artifactID: overviewID))
        #expect(started["format"] as? String == "critique")
        #expect(started["length"] as? String == "shorter")
        // No audio was asked for, so its price is not part of the answer.
        #expect((started["estimate"] as? [String: Any])?["audio"] == nil)

        // The work is listed until it ends.
        for _ in 0..<400 where MCPRunningWork.shared.snapshot.contains(where: { $0.id == workID }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!MCPRunningWork.shared.snapshot.contains { $0.id == workID })
        let saved = try #require(try await storage.loadArtifacts().first { $0.id == overviewID })
        #expect(saved.kind == .audioOverview)
        #expect(saved.homeNotebookID == notebook.id)
        #expect(try await storage.loadSourceWithoutContent(GeneratedAudioOverview.carrierSourceID(artifactID: overviewID)) != nil)

        // read_doc returns the recipe, and list_docs names the carrier.
        let read = try object(try await store.readArtifact(artifactID: overviewID))
        #expect((read["audio_overview"] as? [String: Any])?["format"] as? String == "critique")
        #expect(read["audio_source_id"] as? String == GeneratedAudioOverview.carrierSourceID(artifactID: overviewID))
        #expect((read["doc"] as? [String: Any])?["kind"] as? String == "audio_overview")
    }

    @Test("delete_doc deletes an overview with its script and audio, and delete_source on its script takes the overview the same way")
    func deleteToolsTakeTheAudio() async throws {
        let (store, root) = makeMCPStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = store.notebookFileStorage
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A, enough to talk about.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id])
        let service = AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend())
        let plan = try AudioOverviewGeneratorService.plan(
            try await service.load(notebookID: notebook.id),
            request: AudioOverviewRequest(notebookID: notebook.id, options: AudioOverviewOptions(format: .brief)),
            route: testRoute()
        )
        let first = try await service.run(plan, artifactID: "overview-delete-1")
        let second = try await service.run(plan, artifactID: "overview-delete-2")
        let removed = RemovedAudioRecorder()

        let answer = try object(try await store.deleteArtifact(artifactID: first.artifact.id) { removed.record($0) })
        #expect(answer["status"] as? String == "deleted")
        #expect((answer["doc"] as? [String: Any])?["kind"] as? String == "audio_overview")
        #expect(removed.ids == [first.carrier.id])
        #expect(try await storage.loadSourceWithoutContent(first.carrier.id) == nil)
        #expect(try await storage.loadArtifacts().contains { $0.id == first.artifact.id } == false)

        let message = try await store.deleteSourceWithItsAudio(second.carrier.id) { removed.record($0) }
        #expect(message.contains("audio overview"))
        #expect(removed.ids == [first.carrier.id, second.carrier.id])
        #expect(try await storage.loadArtifacts().contains { $0.id == second.artifact.id } == false)

        // Any other source is deleted as before, with no audio step.
        let plain = try await store.deleteSourceWithItsAudio(a.id) { removed.record($0) }
        #expect(plain.hasPrefix("Deleted source"))
        #expect(removed.ids.count == 2)
    }

    @Test("The Docs write tools refuse an overview, kind or no kind, and list_docs names it either way")
    func docsToolsRefuseAnOverview() async throws {
        let (store, root) = makeMCPStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = store.notebookFileStorage
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A, enough to talk about.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id])
        let service = AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend())
        let plan = try AudioOverviewGeneratorService.plan(
            try await service.load(notebookID: notebook.id),
            request: AudioOverviewRequest(notebookID: notebook.id, options: AudioOverviewOptions(format: .brief)),
            route: testRoute()
        )
        let overview = try await service.run(plan, artifactID: "overview-docs")
        let id = overview.artifact.id
        let read = try object(try await store.readArtifact(artifactID: id))
        let revision = try #require(read["revision"] as? String)

        await #expect(throws: MCPError.self) {
            _ = try await store.writeArtifact(artifactID: id, markdown: "# A Doc now", expectedRevision: revision)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.editArtifact(
                artifactID: id,
                edits: [MCPDataStore.ArtifactEdit(find: "Brief", replace: "Long", replaceAll: false)],
                append: nil,
                expectedRevision: revision
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.publishArtifact(artifactID: id, readers: nil)
        }

        // An older build saved it back without the kind: still refused, and
        // still listed as an overview.
        let knowledge = try await storage.notebookFilesKnowledgeStore()
        var kindless = overview.artifact
        kindless.kind = nil
        try knowledge.saveArtifactRecord(kindless)
        await #expect(throws: MCPError.self) {
            _ = try await store.writeArtifact(artifactID: id, markdown: "# A Doc now", expectedRevision: revision)
        }
        let listed = try object(try await store.listArtifacts(notebookID: nil))
        let entry = try #require((listed["docs"] as? [[String: Any]])?.first { $0["id"] as? String == id })
        #expect(entry["kind"] as? String == "audio_overview")
        #expect(entry["audio_source_id"] as? String == overview.carrier.id)
    }

    @Test("A run that ends without a script tells get_source_audio_status why; an audio refusal reads as one")
    func failedRunIsReported() async throws {
        let (store, root) = makeMCPStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = store.notebookFileStorage
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A, enough to talk about.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id])
        let plan = try AudioOverviewGeneratorService.plan(
            try await AudioOverviewGeneratorService(storage: storage, backend: CannedAudioOverviewBackend()).load(notebookID: notebook.id),
            request: AudioOverviewRequest(notebookID: notebook.id, options: AudioOverviewOptions()),
            route: testRoute()
        )
        let overviewID = "overview-fails-\(UUID().uuidString.lowercased())"
        let result = await AudioOverviewGenerationCoordinator.shared.write(
            plan,
            artifactID: overviewID,
            storage: storage,
            backend: FailingAudioOverviewBackend()
        )
        guard case .failure = result else {
            Issue.record("the run should have failed")
            return
        }
        let carrierID = GeneratedAudioOverview.carrierSourceID(artifactID: overviewID)
        let status = try object(try await store.getSourceAudioStatus(sourceIDs: [carrierID]))
        let entry = try #require((status["sources"] as? [[String: Any]])?.first)
        #expect(entry["found"] as? Bool == false)
        #expect(entry["overview_id"] as? String == overviewID)
        #expect(entry["writing_failed"] as? String == AudioOverviewGenerationError.emptyScript.localizedDescription)

        #expect(MCPDataStore.audioOverviewAudioRefusal(#"{"status":"started"}"#) == nil)
        #expect(MCPDataStore.audioOverviewAudioRefusal(#"{"status":"nothing_to_generate"}"#) == nil)
        let tooLow = MCPDataStore.audioOverviewAudioRefusal(#"{"status":"approval_too_low","message":"Nothing was started."}"#)
        #expect(tooLow?.contains("longer than the estimate") == true)
    }

    @Test("generate_audio_overview writes nothing a voice that cannot narrate would be asked to read")
    func refusesWithoutAVoice() async throws {
        let (store, root) = makeMCPStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = store.notebookFileStorage
        let a = try await seedSource(storage, url: "https://journal.example/a", title: "A", content: "Text of A, enough to talk about.")
        let notebook = try await makeNotebook(storage, title: "Mitochondria", sourceIDs: [a.id])
        let brokenVoice: @Sendable (AudioOverviewPlan) async -> AudioOverviewQuote = { plan in
            AudioOverviewQuote(
                plan: plan,
                audio: ArticleSpeechCostEstimate(characters: plan.expectedScriptCharacters, usd: nil),
                speechProvider: "apple",
                speechModel: "test/tts",
                voice: "Kore",
                voiceLabel: "Test TTS · Kore",
                audioStartsAutomatically: false,
                speechConfigurationError: "The selected text-to-speech provider is no longer available."
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.generateAudioOverview(
                arguments: ["notebook_id": notebook.id, "confirm_cost": true],
                backend: CannedAudioOverviewBackend(),
                route: testRoute(),
                audioQuote: brokenVoice,
                automaticAudioSelection: neverAutomatic
            )
        }
        #expect(try await storage.loadArtifacts().isEmpty)
    }
}
