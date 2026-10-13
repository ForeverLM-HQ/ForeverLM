import Foundation
import Testing
@testable import ForeverLM

/// Sources brought into a running chat between two messages: the mark that
/// rides beside the next message, the line the transcript draws from it, and
/// what the model is told.
@Suite("Chat context additions")
struct ChatContextAdditionsTests {

    private let articles = [
        ChatContextAdditions.Source(id: "a1", title: "Mitochondrial phenotyping", type: "article"),
        ChatContextAdditions.Source(id: "a2", title: "OxPhos defects are hypermetabolic", type: "article"),
        ChatContextAdditions.Source(id: "a3", title: "Energy expenditure in MELAS", type: "article"),
    ]

    // MARK: - The mark

    @Test("The mark round-trips, on one line, over the reference material it sits above")
    func markRoundTrips() {
        let stored = ChatContextAdditions.contextContent(
            added: articles,
            referenceContext: "> a quoted passage\n\nSource: Picard 2022"
        )
        let firstLine = stored!.components(separatedBy: "\n").first!
        #expect(firstLine.hasPrefix("<flm_context_sources>{"))
        #expect(firstLine.hasSuffix("}</flm_context_sources>"))

        let parsed = ChatContextAdditions.parse(contextContent: stored)
        #expect(parsed.added == articles)
        #expect(parsed.remainder == "> a quoted passage\n\nSource: Picard 2022")
    }

    @Test("A title with a newline or a quote survives the trip")
    func awkwardTitlesSurvive() {
        let awkward = [ChatContextAdditions.Source(id: "x", title: "Line one\nline \"two\" / three", type: "paper")]
        let stored = ChatContextAdditions.contextContent(added: awkward, referenceContext: nil)!
        #expect(stored.components(separatedBy: "\n").count == 1)
        #expect(ChatContextAdditions.parse(contextContent: stored).added == awkward)
    }

    @Test("Nothing added hands the reference material back unchanged")
    func nothingAdded() {
        #expect(ChatContextAdditions.contextContent(added: [], referenceContext: "passage") == "passage")
        #expect(ChatContextAdditions.contextContent(added: [], referenceContext: "  ") == nil)
        #expect(ChatContextAdditions.marker(added: []) == nil)
        #expect(ChatContextAdditions.parse(contextContent: nil) == .init(added: [], remainder: nil))
        #expect(ChatContextAdditions.parse(contextContent: "> passage") == .init(added: [], remainder: "> passage"))
    }

    @Test("A mark that cannot be read passes through whole rather than eating the line")
    func unreadableMarkPassesThrough() {
        let broken = "<flm_context_sources>not json</flm_context_sources>\n> passage"
        #expect(ChatContextAdditions.parse(contextContent: broken) == .init(added: [], remainder: broken))
    }

    @Test("The same source twice is one addition")
    func duplicatesFold() {
        let twice = [articles[0], articles[0], articles[1]]
        #expect(ChatContextAdditions.parse(contextContent: ChatContextAdditions.marker(added: twice)).added == [articles[0], articles[1]])
        #expect(ChatContextAdditions.summary(added: twice) == "Added 2 articles to context")
    }

    @Test("The plugin and side-question marks read the same under the additions mark")
    func stacksUnderTheOtherMarks() {
        let sideQuestion = ChatSideQuestion.contextContent(openQuestion: "What is ROS?", referenceContext: "> passage")
        let plugin = ChatPluginRequest.contextContent(for: .slack, referenceContext: sideQuestion)
        let stored = ChatContextAdditions.contextContent(added: articles, referenceContext: plugin)!

        let additions = ChatContextAdditions.parse(contextContent: stored)
        #expect(additions.added == articles)
        #expect(additions.remainder == plugin)

        // Each parser skips the line above it, so a reader that never heard
        // of additions sees the context it always saw.
        let pluginParsed = ChatPluginRequest.parse(contextContent: stored)
        #expect(pluginParsed.plugin == .slack)
        #expect(pluginParsed.remainder == sideQuestion)
        let aside = ChatSideQuestion.parse(contextContent: pluginParsed.remainder)
        #expect(aside.isSideQuestion)
        #expect(aside.openQuestion == "What is ROS?")
        #expect(aside.referenceContext == "> passage")
        #expect(ChatSideQuestion.parse(contextContent: stored).isSideQuestion == false,
                "the plugin mark still sits between them; only the additions line is skipped")
        #expect(ChatSideQuestion.parse(contextContent: ChatContextAdditions.contextContent(added: articles, referenceContext: sideQuestion)).isSideQuestion)
    }

    // MARK: - What was on screen

    private let articleOnScreen = ChatContextAdditions.OnScreen(
        id: "src-ask-not",
        title: "Ask not what AI can do for longevity. Ask what the longevity field can do for AI.",
        kind: "article"
    )

    @Test("A mark of additions alone keeps its bytes: no onScreen key is written")
    func additionsOnlyKeepTheirBytes() {
        let mark = ChatContextAdditions.marker(added: [articles[0]])!
        #expect(mark == #"<flm_context_sources>{"added":[{"id":"a1","title":"Mitochondrial phenotyping","type":"article"}]}</flm_context_sources>"#)
    }

    @Test("Sources on screen ride the same mark, beside additions or alone, and draw no additions row")
    func onScreenRoundTrips() {
        let alone = ChatContextAdditions.contextContent("> a passage", onScreen: [articleOnScreen])!
        let parsedAlone = ChatContextAdditions.parse(contextContent: alone)
        #expect(parsedAlone.added.isEmpty)
        #expect(parsedAlone.onScreen == [articleOnScreen])
        #expect(parsedAlone.remainder == "> a passage")
        // `added` is written even when empty, so a build that knows only
        // additions still decodes the mark and takes it off the line.
        #expect(alone.hasPrefix(#"<flm_context_sources>{"added":[],"onScreen":["#))

        let withAdditions = ChatContextAdditions.contextContent(
            ChatContextAdditions.contextContent(added: articles, referenceContext: "> a passage"),
            onScreen: [articleOnScreen, articleOnScreen]
        )
        let parsed = ChatContextAdditions.parse(contextContent: withAdditions)
        #expect(parsed.added == articles)
        #expect(parsed.onScreen == [articleOnScreen])
        #expect(parsed.remainder == "> a passage")

        #expect(ChatContextAdditions.contextContent("> a passage", onScreen: []) == "> a passage")
        #expect(ChatContextAdditions.contextContent(nil, onScreen: []) == nil)
    }

    @Test("A passage sent with the on-screen mark above it is still the message's passage")
    func passageSurvivesTheOnScreenMark() {
        let passage = "Selected passage:\n> we need to start deliberately generating data\n\nSource ID: src-ask-not"
        let stored = ChatContextAdditions.contextContent(passage, onScreen: [articleOnScreen])
        #expect(ChatPassageOrigin.parse(contextContent: stored)?.sourceID == "src-ask-not")
        #expect(ChatPassageOrigin.parse(contextContent: stored) == ChatPassageOrigin.parse(contextContent: passage))
        #expect(ChatSideQuestion.parse(contextContent: stored).isSideQuestion == false)
    }

    @Test("The tutor is told what was on screen, by title and source_id, and that attached is not open")
    @MainActor
    func tutorIsToldWhatWasOnScreen() {
        let contents = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (
                visible: "do you see the article i have open?",
                context: ChatContextAdditions.contextContent(nil, onScreen: [articleOnScreen])
            ),
        ]).joined(separator: "\n")

        #expect(contents.contains("do you see the article i have open?"))
        #expect(contents.contains("<on_screen_when_sent>"))
        #expect(contents.contains("article “Ask not what AI can do for longevity."))
        #expect(contents.contains("(source_id: src-ask-not)"))
        #expect(contents.contains("not what they are looking at"))
        #expect(!contents.contains("flm_context_sources"))
        #expect(!contents.contains("<context_sources_added>"))
        #expect(!contents.contains("<reader_selection_context>"))
    }

    @Test("A message sent beside a Reader carries the window's on-screen sources; a chat with no window carries nothing")
    @MainActor
    func managerWritesTheWindowIntoTheMessage() {
        let panes = ChatOpenPanes(windows: [
            .init(isChatsWindow: true, panes: [
                .init(onScreen: .init(name: "Chat", contents: [.chat(title: "New chat", isThisChat: true)])),
                .init(onScreen: .init(name: "Reader", contents: [.source(
                    id: articleOnScreen.id, title: articleOnScreen.title, kind: "article", position: nil
                )])),
            ]),
        ])
        let stored = ReviewSessionManager.onScreenContextForTesting(openPanes: panes, referenceContext: nil)
        #expect(ChatContextAdditions.parse(contextContent: stored).onScreen == [articleOnScreen])
        #expect(ReviewSessionManager.onScreenContextForTesting(openPanes: nil, referenceContext: "> p") == "> p")
    }

    @Test("A source left out with its chip's × rides no message; one still open beside it does")
    @MainActor
    func leftOutSourceRidesNoMessage() {
        let paper = ChatContextAdditions.OnScreen(id: "src-paper", title: "An archaeal origin of eukaryotes", kind: "paper")
        let panes = ChatOpenPanes(windows: [
            .init(
                isChatsWindow: true,
                panes: [.init(onScreen: .init(name: "Reader", contents: [.source(
                    id: articleOnScreen.id, title: articleOnScreen.title, kind: "article", position: nil
                )]))],
                alsoOnScreen: [.source(id: paper.id, title: paper.title, kind: "paper", position: nil)]
            ),
        ])
        let stored = ReviewSessionManager.onScreenContextForTesting(
            openPanes: panes, referenceContext: "> p", leftOut: [articleOnScreen.id]
        )
        #expect(ChatContextAdditions.parse(contextContent: stored).onScreen == [paper])
        #expect(ChatContextAdditions.parse(contextContent: stored).remainder == "> p")
        // Everything left out: the message carries what it carried anyway, and no mark.
        #expect(ReviewSessionManager.onScreenContextForTesting(
            openPanes: panes, referenceContext: "> p", leftOut: [articleOnScreen.id, paper.id]
        ) == "> p")
    }

    // MARK: - What the transcript says

    @Test("The line names the sources' own kind when they share one, and sources when they do not")
    func summaryWording() {
        #expect(ChatContextAdditions.summary(added: articles) == "Added 3 articles to context")
        #expect(ChatContextAdditions.summary(added: [articles[0]]) == "Added 1 article to context")
        #expect(ChatContextAdditions.summary(added: [
            .init(id: "p", title: "A paper", type: "paper"),
            .init(id: "q", title: "Another", type: "paper"),
        ]) == "Added 2 papers to context")
        #expect(ChatContextAdditions.summary(added: [
            .init(id: "p", title: "A paper", type: "paper"),
            .init(id: "c", title: "A podcast", type: "podcast"),
        ]) == "Added 2 sources to context")
        #expect(ChatContextAdditions.summary(added: [.init(id: "x", title: "A post", type: "xPost")]) == "Added 1 X post to context")
        // The web-page storage states read as articles, the way the sidebar files them.
        #expect(ChatContextAdditions.summary(added: [
            .init(id: "m", title: "A link", type: "manual"),
            .init(id: "u", title: "A page", type: "unclassified"),
        ]) == "Added 2 articles to context")
        #expect(ChatContextAdditions.summary(added: [.init(id: "z", title: "New kind", type: "hologram")]) == "Added 1 source to context")
        #expect(ChatContextAdditions.summary(added: []) == "")
    }

    // MARK: - What the model is told

    @Test("The tutor is told which sources arrived, by name, outside the reference wrapper; the mark itself never reaches it")
    @MainActor
    func tutorIsToldWhatArrived() {
        let contents = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (
                visible: "please explain the takeaways from these articles",
                context: ChatContextAdditions.contextContent(added: articles, referenceContext: "> a quoted passage\n\nSource: Picard 2022")
            ),
        ]).joined(separator: "\n")

        #expect(contents.contains("please explain the takeaways from these articles"))
        #expect(contents.contains("<context_sources_added>"))
        #expect(contents.contains("3 articles"))
        #expect(contents.contains("“OxPhos defects are hypermetabolic”"))
        #expect(!contents.contains("flm_context_sources"))
        // The passage keeps its wrapper; the framing stands outside it.
        #expect(contents.contains("<reader_selection_context>"))
        #expect(contents.contains("Source: Picard 2022"))
        let wrapperEnd = contents.range(of: "</reader_selection_context>")!.upperBound
        let framingStart = contents.range(of: "<context_sources_added>")!.lowerBound
        #expect(framingStart >= wrapperEnd)
    }

    // MARK: - The manager

    @Test("Sources dropped into a running chat wait as pending additions and leave with the next message")
    @MainActor
    func droppedSourcesRideWithTheNextMessage() async {
        var first = StudioArticle(url: "https://example.com/first", title: "First article", sourceType: .article, id: "first")
        first.content = "first article body"
        var second = StudioArticle(url: "https://example.com/second", title: "Second article", sourceType: .article, id: "second")
        second.content = "second article body"

        let result = await ReviewSessionManager.contextAdditionsForTesting(
            existingMessages: [
                .init(role: .user, content: "name the primary mitochondrial diseases"),
                .init(role: .assistant, content: "MELAS, MERRF, LHON…"),
            ],
            droppedArticles: [first, second],
            referenceContext: "> a passage"
        )
        #expect(result.pending.map(\.id) == ["first", "second"])
        #expect(result.pending.map(\.title) == ["First article", "Second article"])
        #expect(result.pending.map(\.type) == ["article", "article"])

        let parsed = ChatContextAdditions.parse(contextContent: result.nextContext)
        #expect(parsed.added == result.pending)
        #expect(parsed.remainder == "> a passage")
    }

    @Test("Sources staged before the first message are the chat's opening context, not an addition")
    @MainActor
    func stagingBeforeTheFirstMessageIsNotAnAddition() async {
        var staged = StudioArticle(url: "https://example.com/staged", title: "Staged", sourceType: .paper, id: "staged")
        staged.content = "staged body"

        let result = await ReviewSessionManager.contextAdditionsForTesting(existingMessages: [], droppedArticles: [staged])
        #expect(result.pending.isEmpty)
        #expect(result.nextContext == nil)
    }
}

/// A question asked beside a video: the moment its player stood at rides the
/// on-screen mark, the send fills in what was said and the frame, and the
/// tutor is told all three (docs/chat-design.md, "A question beside a video
/// is asked at its moment").
@Suite("Chat video moments")
struct ChatVideoMomentTests {
    private let video = ChatContextAdditions.OnScreen(
        id: "src-talk",
        title: "Finbow's Mitochondrial Cristae",
        kind: "video",
        moment: .init(at: 1611, playing: false)
    )

    @Test("A moment rides the on-screen mark; an entry without one keeps the bytes it always had")
    func momentRoundTripsAndOldMarksKeepTheirBytes() throws {
        let plain = ChatContextAdditions.OnScreen(id: "a1", title: "An article", kind: "article")
        #expect(ChatContextAdditions.marker(added: [], onScreen: [plain])
            == #"<flm_context_sources>{"added":[],"onScreen":[{"id":"a1","kind":"article","title":"An article"}]}</flm_context_sources>"#)

        let mark = try #require(ChatContextAdditions.marker(added: [], onScreen: [video]))
        #expect(mark.contains(#""moment":{"at":1611,"playing":false}"#))
        #expect(!mark.contains("said"))
        #expect(!mark.contains("\n"))
        #expect(ChatContextAdditions.parse(contextContent: mark).onScreen == [video])
    }

    @Test("The send fills in a video's moment and leaves the rest of the mark as it was")
    func completingAMomentTouchesOnlyThatVideo() throws {
        let article = ChatContextAdditions.OnScreen(id: "a1", title: "An article", kind: "article")
        let added = ChatContextAdditions.Source(id: "p1", title: "A paper", type: "paper")
        let stamped = ChatContextAdditions.contextContent(added: [added], onScreen: [article, video], referenceContext: "> a passage")
        var completed = try #require(video.moment)
        completed.said = "[26:20] These are solenoidal current loops."
        completed.frame = true

        let stored = ChatContextAdditions.contextContent(stamped, completingMoments: ["src-talk": completed])
        let parsed = ChatContextAdditions.parse(contextContent: stored)
        #expect(parsed.added == [added])
        #expect(parsed.remainder == "> a passage")
        #expect(parsed.onScreen.first == article)
        #expect(parsed.onScreen.last?.moment == completed)

        #expect(ChatContextAdditions.contextContent(stamped, completingMoments: [:]) == stamped)
        #expect(ChatContextAdditions.contextContent(stamped, completingMoments: ["elsewhere": completed]) == stamped)
        #expect(ChatContextAdditions.contextContent(nil, completingMoments: ["src-talk": completed]) == nil)
    }

    @Test("The tutor hears where the video stood, what was said around it, and gets the frame as a picture line")
    @MainActor
    func tutorIsToldTheMoment() throws {
        var completed = try #require(video.moment)
        completed.said = "[25:56] for the vibrational problem here.\n[26:20] These are solenoidal current loops."
        completed.frame = true
        var asked = video
        asked.moment = completed
        let contents = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (visible: "what does he mean by this?", context: ChatContextAdditions.contextContent(nil, onScreen: [asked])),
        ]).joined(separator: "\n")

        #expect(contents.contains("video “Finbow's Mitochondrial Cristae” (source_id: src-talk), paused at 26:51"))
        #expect(contents.contains("<video_moment>"))
        #expect(contents.contains("The learner asked this at 26:51"))
        #expect(contents.contains("with the video paused there"))
        #expect(contents.contains("[26:20] These are solenoidal current loops."))
        #expect(contents.contains("![Finbow's Mitochondrial Cristae at 26:51](foreverlm://image/src-talk/at/1611)"))
        #expect(contents.contains("foreverlm://source/src-talk?t=1611"))
        #expect(!contents.contains("flm_context_sources"))
    }

    @Test("A moment with no frame tells the tutor how to look; one the send did not fill in is only a time")
    @MainActor
    func momentWithoutFrameAndStampOnly() throws {
        var noFrame = try #require(video.moment)
        noFrame.said = "[26:20] These are solenoidal current loops."
        noFrame.frame = false
        var asked = video
        asked.moment = noFrame
        let withoutFrame = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (visible: "and this?", context: ChatContextAdditions.contextContent(nil, onScreen: [asked])),
        ]).joined(separator: "\n")
        #expect(withoutFrame.contains("No picture of the screen at 26:51 could be taken"))
        #expect(withoutFrame.contains("call show_source_image with source_id src-talk and at 1611"))
        #expect(!withoutFrame.contains("foreverlm://image/src-talk/at/1611"))

        let stampOnly = ReviewSessionManager.providerContentsForTesting(learnerTurns: [
            (visible: "about the paper", context: ChatContextAdditions.contextContent(nil, onScreen: [video])),
        ]).joined(separator: "\n")
        #expect(stampOnly.contains("paused at 26:51"))
        #expect(!stampOnly.contains("<video_moment>"))
    }

    @Test("The transcript around a moment holds the segment under way and those near it, earliest dropped first")
    func transcriptExcerpt() throws {
        let segments: [(seconds: Double, text: String)] = [
            (0, "Welcome."),
            (1400, "Long before the moment."),
            (1530, "Now the  rotors."),
            (1580, "These are solenoidal\ncurrent loops."),
            (1600, "What's interesting is"),
            (1625, "the faces couple."),
            (1700, "Much later."),
        ]
        let excerpt = try #require(ChatContextAdditions.transcriptExcerpt(segments, around: 1611))
        #expect(excerpt == """
        [25:30] Now the rotors.
        [26:20] These are solenoidal current loops.
        [26:40] What's interesting is
        [27:05] the faces couple.
        """)

        // A long paragraph under way at the moment belongs to it however early it began.
        let paragraph = try #require(ChatContextAdditions.transcriptExcerpt(
            [(1000, "A paragraph that runs for minutes."), (1900, "Next.")],
            around: 1611
        ))
        #expect(paragraph == "[16:40] A paragraph that runs for minutes.")

        // Past the last segment's two minutes there is nothing to quote.
        #expect(ChatContextAdditions.transcriptExcerpt([(0, "Hello.")], around: 5000) == nil)

        // Over the limit, the lines nearest the moment stay.
        let many = (0..<40).map { (seconds: Double(1530 + $0 * 2), text: "word word word word word \($0)") }
        let capped = try #require(ChatContextAdditions.transcriptExcerpt(many, around: 1611, characterLimit: 200))
        #expect(capped.count <= 201)
        #expect(capped.hasSuffix("word 39"))
        #expect(!capped.contains("word 0\n"))
    }

    @Test("The playhead reads as a phrase and a clock")
    func playheadWording() {
        #expect(ChatContextAdditions.clock(1611) == "26:51")
        #expect(ChatContextAdditions.clock(3723) == "1:02:03")
        #expect(ChatContextAdditions.playheadPhrase(.init(at: 65, playing: true)) == "playing at 1:05")
        #expect(ChatContextAdditions.playheadPhrase(.init(at: 65)) == "at 1:05")
        #expect(ChatOpenPanes.VideoPlayhead(seconds: 1611.9, isPlaying: false).positionLabel == "paused at 26:51")
    }
}
