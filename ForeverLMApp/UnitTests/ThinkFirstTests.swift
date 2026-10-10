import Foundation
import Testing
@testable import ForeverLM

/// Think first (docs/fences-and-think-first-design.md, "Think first"): the
/// levels and where they apply, the takes kept in understanding documents,
/// the guess beside a chat question, a report's take, and the learner's
/// candidate in a direction search.
@Suite("Think first levels")
struct ThinkFirstLevelTests {

    private func scratchDefaults() -> UserDefaults {
        let name = "ThinkFirstTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Off asks nothing, Summaries and Studio asks all but the chat, Also Chat asks everywhere")
    func levelsAsk() {
        for moment in ThinkFirstMoment.allCases {
            #expect(!ThinkFirstLevel.off.asks(moment))
            #expect(ThinkFirstLevel.alsoChat.asks(moment))
            #expect(ThinkFirstLevel.summariesAndStudio.asks(moment) == (moment != .chat))
        }
    }

    @Test("Absent is Off, a notebook's own level wins over the library's, and an unknown word reads as Off")
    func levelResolution() {
        let defaults = scratchDefaults()
        #expect(ThinkFirst.libraryLevel(defaults: defaults) == .off)
        #expect(ThinkFirst.level(notebookID: "nb", defaults: defaults) == .off)

        defaults.set(ThinkFirstLevel.summariesAndStudio.rawValue, forKey: ThinkFirst.levelKey)
        #expect(ThinkFirst.level(notebookID: "nb", defaults: defaults) == .summariesAndStudio)
        #expect(ThinkFirst.level(notebookID: nil, defaults: defaults) == .summariesAndStudio)

        defaults.set(ThinkFirstLevel.alsoChat.rawValue, forKey: ThinkFirst.notebookKey("nb"))
        #expect(ThinkFirst.notebookLevel("nb", defaults: defaults) == .alsoChat)
        #expect(ThinkFirst.level(notebookID: "nb", defaults: defaults) == .alsoChat)
        #expect(ThinkFirst.level(notebookID: "other", defaults: defaults) == .summariesAndStudio)
        #expect(ThinkFirst.asks(.chat, notebookID: "nb", defaults: defaults))
        #expect(!ThinkFirst.asks(.chat, notebookID: "other", defaults: defaults))

        defaults.set(ThinkFirstLevel.off.rawValue, forKey: ThinkFirst.notebookKey("quiet"))
        #expect(!ThinkFirst.asks(.report, notebookID: "quiet", defaults: defaults))

        defaults.set("everywhereSoon", forKey: ThinkFirst.levelKey)
        #expect(ThinkFirst.libraryLevel(defaults: defaults) == .off)
    }

    @Test("The keys are the catalog's, and the notebook's is per notebook")
    func keys() {
        #expect(ThinkFirst.levelKey == "thinkFirst.level")
        #expect(ThinkFirst.notebookKey("abc") == "notebook.thinkFirst.abc")
        #expect(ThinkFirstLevel.allCases.map(\.rawValue) == ["off", "summariesAndStudio", "alsoChat"])
    }

    @Test("A take with no words is a skip")
    func emptyTakeIsSkip() {
        #expect(ThinkFirst.take("  \n ") == nil)
        #expect(ThinkFirst.take("  It is about ROS. ") == "It is about ROS.")
    }

    @Test("The tally counts answers and skips per moment, and says when a moment is mostly skipped")
    func tally() {
        let defaults = scratchDefaults()
        ThinkFirstTally.record(.report, answered: true, defaults: defaults)
        ThinkFirstTally.record(.report, answered: false, defaults: defaults)
        ThinkFirstTally.record(.chat, answered: false, defaults: defaults)
        let counts = ThinkFirstTally.counts(defaults: defaults)
        #expect(counts[.report] == ThinkFirstTally.Count(answered: 1, skipped: 1))
        #expect(counts[.chat] == ThinkFirstTally.Count(answered: 0, skipped: 1))
        #expect(counts[.sourceSummary] == ThinkFirstTally.Count())

        #expect(!ThinkFirstTally.Count(answered: 0, skipped: 9).isMostlySkipped)
        #expect(ThinkFirstTally.Count(answered: 1, skipped: 9).isMostlySkipped)
        #expect(!ThinkFirstTally.Count(answered: 2, skipped: 8).isMostlySkipped)
    }

    @Test("A source is asked about once on this Mac, and the oldest fall off past the limit")
    func askedSources() {
        let defaults = scratchDefaults()
        #expect(!ThinkFirstAskedSources.contains("a", defaults: defaults))
        ThinkFirstAskedSources.insert("a", defaults: defaults)
        ThinkFirstAskedSources.insert("a", defaults: defaults)
        #expect(ThinkFirstAskedSources.contains("a", defaults: defaults))
        #expect(defaults.stringArray(forKey: ThinkFirstAskedSources.preferenceKey) == ["a"])

        for index in 0..<ThinkFirstAskedSources.limit {
            ThinkFirstAskedSources.insert("s\(index)", defaults: defaults)
        }
        #expect(!ThinkFirstAskedSources.contains("a", defaults: defaults))
        #expect(defaults.stringArray(forKey: ThinkFirstAskedSources.preferenceKey)?.count == ThinkFirstAskedSources.limit)
    }

    @Test("The level and a notebook's level sync with the account; the tally and the asked sources stay on this Mac")
    func syncing() {
        #expect(SyncedPreferenceKeys.isSynced(ThinkFirst.levelKey))
        #expect(SyncedPreferenceKeys.isSynced(ThinkFirst.notebookKey("nb-1")))
        #expect(!SyncedPreferenceKeys.isSynced(ThinkFirstTally.countsKey))
        #expect(!SyncedPreferenceKeys.isSynced(ThinkFirstAskedSources.preferenceKey))
    }
}

@Suite("Think first takes")
struct ThinkFirstTakeTests {

    private static let day: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 6
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    @Test("A take's section is a dated heading, the question in italics and the words as written")
    func section() {
        let section = ThinkFirstTake.section(question: "What do you expect this to say?", take: " That *ROS* signal.\n", on: Self.day)
        #expect(section == "## Before the summary (2026-10-06)\n\n*What do you expect this to say?*\n\nThat *ROS* signal.")
    }

    @Test("Every take reads back with its day, question and words, up to the next heading")
    func readsBack() {
        let markdown = """
        # Aging Hallmarks

        They can explain autophagy.

        ## Before the summary (2026-10-01)

        *What do you expect this to say?*

        That aging is one process.
        Maybe two.

        ## Open threads

        Mitophagy.

        ## Before the summary (2026-10-06)

        *What's the gist, in a line?*

        Twelve hallmarks, loosely linked.
        """
        let takes = ThinkFirstTake.takes(in: markdown)
        #expect(takes.count == 2)
        #expect(takes[0].day == "2026-10-01")
        #expect(takes[0].question == "What do you expect this to say?")
        #expect(takes[0].text == "That aging is one process.\nMaybe two.")
        #expect(!takes[0].section.contains("Open threads"))
        #expect(takes[1].question == "What's the gist, in a line?")
        #expect(takes[1].text == "Twelve hallmarks, loosely linked.")
    }

    @Test("A rewrite keeps every take: one it dropped goes back at the end, one it kept is not doubled")
    func rewritesKeepTakes() {
        let take = ThinkFirstTake.section(question: "What do you expect this to say?", take: "Mitochondria decide.", on: Self.day)
        let previous = "# Paper\n\nOld note.\n\n" + take + "\n"

        let dropped = ThinkFirstTake.keepingTakes(of: previous, in: "# Paper\n\nNew note.")
        #expect(dropped == "# Paper\n\nNew note.\n\n" + take + "\n")

        let kept = "# Paper\n\n" + take + "\n\nNew note."
        #expect(ThinkFirstTake.keepingTakes(of: previous, in: kept) == kept)
        #expect(ThinkFirstTake.keepingTakes(of: nil, in: "# Paper") == "# Paper")
    }
}

@Suite("Think first takes in understanding documents", .serialized)
struct ThinkFirstUnderstandingStorageTests {

    private func withTemporaryRoot<T>(_ body: (URL) throws -> T) rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkFirstUnderstanding_\(UUID().uuidString)")
        KnowledgeStore.understandingRootOverride = root.path
        defer {
            KnowledgeStore.understandingRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        return try body(root)
    }

    private func makeSource(_ store: KnowledgeStore, title: String) throws -> StudioArticle {
        let url = "https://example.com/\(UUID().uuidString)"
        var article = StudioArticle(url: url, title: title)
        article.normalizedURL = URLNormalizer.normalize(url)
        article.content = String(repeating: "Body worth reviewing. ", count: 20)
        try store.saveSource(article)
        return article
    }

    @Test("A source with no document gets the blank header and the take, which reads as the learner's own words")
    func newDocument() throws {
        try withTemporaryRoot { root in
            let store = try KnowledgeStore(inMemory: true)
            let article = try makeSource(store, title: "Aging Hallmarks")
            let written = try store.appendThinkFirstTake(
                sourceID: article.id,
                title: article.title,
                question: "What do you expect this to say?",
                take: "That aging is one process."
            )
            #expect(written.markdown.hasPrefix(UnderstandingDocumentTemplate.blank(title: "Aging Hallmarks")))
            #expect(written.thinkFirstTakes.map(\.text) == ["That aging is one process."])
            #expect(written.hasLearnerEdits)

            let loaded = try #require(try store.loadUnderstandingDocument(sourceID: article.id))
            #expect(loaded.thinkFirstTakes.map(\.text) == ["That aging is one process."])
            #expect(loaded.bodySHA256 == UnderstandingDocument.digest(UnderstandingDocumentTemplate.blank(title: "Aging Hallmarks")))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(loaded.relativePath).path))
        }
    }

    @Test("A take goes at the end of an existing document and leaves what the model wrote, and its digest, alone")
    func existingDocument() throws {
        try withTemporaryRoot { _ in
            let store = try KnowledgeStore(inMemory: true)
            let article = try makeSource(store, title: "Mitophagy")
            let model = try store.saveUnderstandingDocument(
                sourceID: article.id,
                title: article.title,
                markdown: "# Mitophagy\n\nThey can explain PINK1.",
                derivedThroughSessionID: "s1",
                openThreadCount: 1
            )
            let written = try store.appendThinkFirstTake(
                sourceID: article.id,
                title: article.title,
                question: "What's the gist, in a line?",
                take: "Damaged mitochondria get tagged and eaten."
            )
            #expect(written.markdown.hasPrefix("# Mitophagy\n\nThey can explain PINK1.\n\n## Before the summary ("))
            #expect(written.bodySHA256 == model.bodySHA256)
            #expect(written.derivedThroughSessionID == "s1")
            #expect(written.openThreadCount == 1)
            #expect(written.relativePath == model.relativePath)
        }
    }

    @Test("A rewrite that leaves a take out gets it back; one that keeps it is written as given")
    func rewritesKeepTakes() throws {
        try withTemporaryRoot { _ in
            let store = try KnowledgeStore(inMemory: true)
            let article = try makeSource(store, title: "Complex I")
            let withTake = try store.appendThinkFirstTake(
                sourceID: article.id,
                title: article.title,
                question: "What do you expect this to say?",
                take: "Complex I leaks electrons."
            )
            let section = try #require(withTake.thinkFirstTakes.first?.section)

            let rewritten = try store.saveUnderstandingDocument(
                sourceID: article.id,
                title: article.title,
                markdown: "# Complex I\n\nThey explained reverse electron transport.",
                derivedThroughSessionID: "s2"
            )
            #expect(rewritten.markdown.hasSuffix(section + "\n"))
            #expect(rewritten.thinkFirstTakes.map(\.text) == ["Complex I leaks electrons."])
            #expect(!rewritten.hasLearnerEdits)

            let kept = "# Complex I\n\n" + section + "\n\nThey explained it twice."
            let again = try store.saveUnderstandingDocument(
                sourceID: article.id,
                title: article.title,
                markdown: kept,
                derivedThroughSessionID: "s3"
            )
            #expect(again.markdown == kept)
        }
    }
}

@Suite("Think first: a guess before a chat question")
struct ChatGuessTests {

    @Test("The mark is one line of JSON, so a guess on several lines stays one line")
    func marker() {
        let mark = ChatGuess.marker(guess: " It's \"ATP\"\nor maybe NADH/FAD ")
        #expect(mark == #"<flm_guess>{"guess":"It's \"ATP\"\nor maybe NADH/FAD"}</flm_guess>"#)
        #expect(ChatGuess.marker(guess: "  ") == nil)
    }

    @Test("A guessed question reads back through the side-question layer, its passage still found under it")
    func readsBackUnderTheMarks() {
        let reference = ReaderSelectionExplanationRequest(sourceID: "src-9", selectedText: "quoted words")
            .contextualContent(fallbackTitle: "Title")
        let stored = ChatGuess.contextContent(guess: "Electrons leak at complex I.", referenceContext: reference)
        let withMarks = ChatContextAdditions.contextContent(
            added: [ChatContextAdditions.Source(id: "a1", title: "Added", type: "article")],
            referenceContext: ChatPluginRequest.contextContent(for: .slack, referenceContext: stored)
        )

        #expect(ChatGuess.guess(contextContent: withMarks) == "Electrons leak at complex I.")
        let plugin = ChatPluginRequest.parse(contextContent: withMarks)
        let parsed = ChatSideQuestion.parse(contextContent: plugin.remainder)
        #expect(!parsed.isSideQuestion)
        #expect(parsed.guess == "Electrons leak at complex I.")
        #expect(parsed.referenceContext == reference.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(ChatPassageOrigin.parse(contextContent: withMarks)?.sourceID == "src-9")
    }

    @Test("A guess alone stores only its mark; a message with none reads as before")
    func noReference() {
        let stored = ChatGuess.contextContent(guess: "Twelve.", referenceContext: nil)
        #expect(stored == #"<flm_guess>{"guess":"Twelve."}</flm_guess>"#)
        #expect(ChatSideQuestion.parse(contextContent: stored).referenceContext == nil)
        #expect(ChatGuess.guess(contextContent: "Selected passage:\n> words") == nil)
        #expect(ChatSideQuestion.parse(contextContent: "Selected passage:\n> words").guess == nil)
        #expect(ChatGuess.contextContent(guess: " ", referenceContext: "ref") == "ref")
    }

    @Test("A side question is never read as a guess")
    func sideQuestionsStayAsides() {
        let aside = ChatSideQuestion.contextContent(openQuestion: "Why?", referenceContext: nil)
        let parsed = ChatSideQuestion.parse(contextContent: aside)
        #expect(parsed.isSideQuestion)
        #expect(parsed.guess == nil)
    }

    @Test("The model hears the guess in the learner's words and is told to compare, never to grade")
    func framing() {
        let framing = ChatGuess.framing(guess: "It is complex I.")
        #expect(framing.contains("\u{201C}It is complex I.\u{201D}"))
        #expect(framing.contains("begins \"Your guess:\""))
        #expect(framing.contains("Do not grade, score or praise it."))
    }

    @Test("Only a message that ends in a question mark is asked for a guess")
    func questions() {
        #expect(ChatGuess.isQuestion("Why does complex I leak? "))
        #expect(!ChatGuess.isQuestion("Summarize this paper."))
        #expect(!ChatGuess.isQuestion("Is it? No, tell me."))
    }
}

@Suite("Think first: a report's take")
struct ReportTakeTests {

    @Test("The take opens the report under Your take, escaped to read as written")
    func section() {
        let section = ReportTake.section("# Not a heading\nThe *key* is [S1]\n\n- not a bullet\n1. not a list\n2026 was the year")
        #expect(section == "## Your take\n\n\\# Not a heading\nThe \\*key\\* is \\[S1\\]\n\n\\- not a bullet\n1\\. not a list\n2026 was the year")
        #expect(ReportTake.section(" \n ") == nil)
    }

    @Test("A report with a take starts with it; one without is left as it was")
    func prefixed() {
        #expect(ReportTake.prefixed("# Body\n", take: "Mine.") == "## Your take\n\nMine.\n\n# Body\n")
        #expect(ReportTake.prefixed("# Body\n", take: nil) == "# Body\n")
    }

    @Test("The writer's turn carries the take and the section it owes, only when there is one")
    func writerTurn() {
        let withTake = ReportWriterTurn.userMessage(
            notebookTitle: "Mito",
            instructions: nil,
            options: ReportOptions(format: .briefing, focus: "aging", take: " ROS is a signal. "),
            subjectDocument: nil,
            sources: []
        )
        #expect(withTake.contains(ReportTake.writerInstruction("ROS is a signal.")))
        #expect(withTake.contains("\"Where this differs from your take\""))
        let without = ReportWriterTurn.userMessage(
            notebookTitle: "Mito",
            instructions: nil,
            options: ReportOptions(format: .briefing, focus: "aging"),
            subjectDocument: nil,
            sources: []
        )
        #expect(!without.contains("their own take"))
        #expect(ReportOptions(take: "  ").trimmedTake == nil)
    }

    @Test("generate_report takes the learner's take")
    func mcpArgument() throws {
        let options = try MCPDataStore.reportOptions(["format": "briefing", "take": "  It is about energy. "])
        #expect(options.trimmedTake == "It is about energy.")
        #expect(try MCPDataStore.reportOptions([:]).trimmedTake == nil)
    }
}

@Suite("Think first: what the learner would try")
struct DirectionTakeTests {

    @Test("The search request names the learner's candidate only when there is one")
    func request() {
        let plain = Prompts.directionSearchRequest(homeKind: .notebook, homeID: "nb-1")
        #expect(plain == "Direction search request for the notebook with home_id nb-1. Call find_directions with that home_id before anything else, then follow the steps it returns.")
        let withCandidate = Prompts.directionSearchRequest(homeKind: .notebook, homeID: "nb-1", learnerCandidate: " Try urolithin A. ")
        #expect(withCandidate.hasPrefix(plain))
        #expect(withCandidate.contains("\u{201C}Try urolithin A.\u{201D}"))
        #expect(withCandidate.contains("steps 4 and 5"))
        #expect(Prompts.directionSearchRequest(homeKind: .idea, homeID: "i", learnerCandidate: "  ") == Prompts.directionSearchRequest(homeKind: .idea, homeID: "i"))
    }

    @Test("A launch carries the candidate into the chat's model-only line")
    func launch() {
        var launch = DirectionSearchLaunch(homeKind: .goal, homeID: "g", homeTitle: "Treat MELAS", notebookID: nil)
        #expect(launch.learnerCandidate == nil)
        launch.learnerCandidate = "Taurine."
        let request = ReaderSelectionExplanationRequest(directionSearch: launch, sourceIDs: [])
        #expect(request.contextualContent().contains("\u{201C}Taurine.\u{201D}"))
        #expect(launch.message == "Find directions for “Treat MELAS”")
    }
}
