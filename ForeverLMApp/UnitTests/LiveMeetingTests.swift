import Foundation
import Testing
@testable import ForeverLM

/// A meeting recorded live on the Mac: when a frame is a new slide, which
/// microphone lines are the call's echo, how the session's text reads (the
/// library's meeting transcript shape and a recording's slide block), what a
/// chat holding the session is told each turn, and where the pane opens.
@Suite("Live meetings")
struct LiveMeetingTests {

    // MARK: Slides

    /// Feeds frames to one detector; a class, since `#expect` cannot mutate.
    private final class Feeder {
        var detector = LiveMeetingSlideDetector()
        func callAsFunction(_ fingerprint: [UInt8]) -> Bool { detector.consider(fingerprint) }
    }

    private static func frame(_ value: UInt8) -> [UInt8] {
        [UInt8](repeating: value, count: LiveMeetingSlideDetector.width * LiveMeetingSlideDetector.height)
    }

    /// The frame with its first `cells` cells set to `value`: a small change,
    /// like a face moving in a tile.
    private static func frame(_ base: UInt8, changing cells: Int, to value: UInt8) -> [UInt8] {
        var pixels = frame(base)
        for index in 0..<cells { pixels[index] = value }
        return pixels
    }

    @Test("the first frame that holds still is kept, and holding still keeps nothing more")
    func firstSettledFrameIsKept() {
        let feed = Feeder()
        #expect(!feed(Self.frame(40)))
        #expect(feed(Self.frame(40)))
        #expect(!feed(Self.frame(40)))
        #expect(!feed(Self.frame(40)))
    }

    @Test("a new slide is kept once it settles, never mid-transition")
    func newSlideAfterItSettles() {
        let feed = Feeder()
        _ = feed(Self.frame(40))
        #expect(feed(Self.frame(40)))
        // A fade: every frame differs from the last.
        #expect(!feed(Self.frame(120)))
        #expect(!feed(Self.frame(200)))
        // Settled on the new slide.
        #expect(feed(Self.frame(200)))
        #expect(!feed(Self.frame(200)))
    }

    @Test("a face moving in a small tile is not a new slide")
    func smallChangesAreNotSlides() {
        let feed = Feeder()
        _ = feed(Self.frame(40))
        #expect(feed(Self.frame(40)))
        let tile = LiveMeetingSlideDetector.width * LiveMeetingSlideDetector.height / 20
        for _ in 0..<4 {
            #expect(!feed(Self.frame(40, changing: tile, to: 220)))
            #expect(!feed(Self.frame(40, changing: tile, to: 10)))
        }
    }

    @Test("a new slide is kept while a face keeps moving in its tile")
    func newSlideBesideAMovingFace() {
        let feed = Feeder()
        let tile = LiveMeetingSlideDetector.width * LiveMeetingSlideDetector.height / 20
        _ = feed(Self.frame(40, changing: tile, to: 220))
        #expect(feed(Self.frame(40, changing: tile, to: 10)))
        #expect(!feed(Self.frame(200, changing: tile, to: 220)))
        #expect(feed(Self.frame(200, changing: tile, to: 10)))
    }

    @Test("a fingerprint of the wrong size is ignored")
    func wrongSizeIsIgnored() {
        let feed = Feeder()
        #expect(!feed([1, 2, 3]))
        #expect(!feed([1, 2, 3]))
    }

    // MARK: Echo

    private static func line(_ voice: LiveMeetingVoice, _ start: TimeInterval, _ text: String) -> LiveMeetingLine {
        LiveMeetingLine(voice: voice, start: start, end: start + 3, text: text)
    }

    @Test("the call heard again through the microphone is echo")
    func echoIsDropped() {
        let them = [Self.line(.them, 10, "The mitochondrial genome encodes thirteen proteins.")]
        #expect(LiveMeetingTranscriptRules.isEcho(
            Self.line(.me, 11, "the mitochondrial genome encodes thirteen proteins"), recentThem: them
        ))
    }

    @Test("the learner's own words are kept, short replies included")
    func ownWordsAreKept() {
        let them = [Self.line(.them, 10, "The mitochondrial genome encodes thirteen proteins.")]
        #expect(!LiveMeetingTranscriptRules.isEcho(
            Self.line(.me, 14, "Which of those are in complex one?"), recentThem: them
        ))
        #expect(!LiveMeetingTranscriptRules.isEcho(Self.line(.me, 14, "Yes, okay."), recentThem: them))
        // Their line long gone: the same words are the learner's.
        #expect(!LiveMeetingTranscriptRules.isEcho(
            Self.line(.me, 60, "the mitochondrial genome encodes thirteen proteins"), recentThem: them
        ))
    }

    @Test("a short reply is echo only when it repeats theirs exactly")
    func shortEcho() {
        let them = [Self.line(.them, 10, "Sounds good.")]
        #expect(LiveMeetingTranscriptRules.isEcho(Self.line(.me, 11, "sounds good"), recentThem: them))
        #expect(!LiveMeetingTranscriptRules.isEcho(Self.line(.me, 11, "good"), recentThem: them))
    }

    // MARK: The session's text

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-11-08 17:00:00 UTC.
    private static let start = Date(timeIntervalSince1970: 1_794_157_200)

    @Test("the transcript reads as every meeting transcript does, at wall-clock times")
    func transcriptShape() {
        let text = LiveMeetingTranscriptRules.transcriptText([
            Self.line(.them, 65, "Welcome, everyone."),
            Self.line(.me, 3_725, "Thanks, Zara."),
        ], startedAt: Self.start, calendar: Self.utc)
        #expect(text == "[17:01:05] Them: Welcome, everyone.\n[18:02:05] Me: Thanks, Zara.")
        // The speaker labels read as the Zoom captions' do.
        #expect(StudioViewModel.zoomCaptionSpeakers(text) == ["Them", "Me"])
    }

    @Test("the session's slides are a recording's slide block, which the Reader parses")
    func sessionContentCarriesSlides() {
        let slides = [
            LiveMeetingSlide(number: 1, shownAt: 30, imageURL: URL(fileURLWithPath: "/tmp/live/slide_001_000030s.jpg"), text: "Aims"),
            LiveMeetingSlide(number: 2, shownAt: 300, imageURL: URL(fileURLWithPath: "/tmp/live/slide_002_000300s.jpg"), text: ""),
        ]
        let content = LiveMeetingSessionText.sessionContent(
            sessionTitle: "Acme Lab journal club - 2026/11/08 17:00",
            lines: [Self.line(.them, 65, "Welcome, everyone.")],
            slides: slides,
            startedAt: Self.start,
            calendar: Self.utc
        )
        #expect(content.hasPrefix("# Acme Lab journal club - 2026/11/08 17:00\n\n## Transcript\n\n[17:01:05] Them: Welcome, everyone."))
        let parsed = YouTubeSlideContentParser.parse(content)
        #expect(parsed.slides.map(\.index) == [1, 2])
        #expect(parsed.slides.first?.windows == [SlideTimeWindow(start: 30, end: 300)])
        #expect(parsed.slides.last?.windows == [SlideTimeWindow(start: 300, end: nil)])
        #expect(MeetingContent.contains(section: .transcript, in: content))
    }

    @Test("a meeting with nothing kept yet is its title and an empty transcript")
    func emptySessionContent() {
        let content = LiveMeetingSessionText.sessionContent(
            sessionTitle: "Standup - 2026/11/08 17:00", lines: [], slides: [], startedAt: Self.start, calendar: Self.utc
        )
        #expect(content == "# Standup - 2026/11/08 17:00\n\n## Transcript\n\n")
    }

    // MARK: What a chat reads

    @Test("a chat is told the meeting is live, what was said, the slides, and how to show one")
    func chatBlockWhileLive() {
        let block = LiveMeetingSessionText.chatBlock(
            title: "Acme Lab journal club",
            sourceID: "src_live",
            startedAt: Self.start,
            endedAt: nil,
            now: Self.start.addingTimeInterval(12 * 60 + 5),
            lines: [Self.line(.them, 65, "Welcome, everyone.")],
            slides: [LiveMeetingSlide(number: 1, shownAt: 30, imageURL: URL(fileURLWithPath: "/tmp/a.jpg"), text: "Aims\nMethods")],
            hearing: [.me: "so the question is"],
            calendar: Self.utc
        )
        #expect(block.contains("is being recorded live on this Mac: it began at 17:00:00 and is 12 minutes in now"))
        #expect(block.contains("[17:00:30] Slide 1 came on screen: Aims / Methods\n[17:01:05] Them: Welcome, everyone.\n(still speaking) Me: so the question is"))
        #expect(block.contains("call show_source_image with source_id src_live and its slide number"))
        #expect(block.contains("replaces it"))
    }

    @Test("after Stop the chat is told the recording is whole, and half-heard words are gone")
    func chatBlockAfterStop() {
        let block = LiveMeetingSessionText.chatBlock(
            title: "Standup",
            sourceID: "src_live",
            startedAt: Self.start,
            endedAt: Self.start.addingTimeInterval(30 * 60),
            now: Self.start.addingTimeInterval(40 * 60),
            lines: [],
            slides: [],
            hearing: [.them: "never finished"],
            calendar: Self.utc
        )
        #expect(block.contains("was recorded live on this Mac from 17:00:00 to 17:30:00; this is all of it"))
        #expect(block.contains("(Nothing has been said yet.)"))
        #expect(!block.contains("never finished"))
        #expect(!block.contains("show_source_image"))
    }

    @MainActor
    @Test("a chat holding no live session gets nothing")
    func noBlockWithoutTheSession() {
        let saved = LiveMeetingChatContext.provider
        defer { LiveMeetingChatContext.provider = saved }
        LiveMeetingChatContext.provider = { ids in ids.contains("src_live") ? "LIVE" : nil }
        #expect(LiveMeetingChatContext.turnContext(forSourceIDs: ["src_other"]) == "")
        #expect(LiveMeetingChatContext.turnContext(forSourceIDs: []) == "")
        #expect(LiveMeetingChatContext.turnContext(forSourceIDs: ["src_other", "src_live"]) == "\n\nLIVE")
    }

    // MARK: Where the pane opens

    @Test("the pane opens beside a lone pane, as a tab at two, and comes forward when open")
    func paneOpens() {
        let one = StudioCenterTabGroups(groups: [.init(tabs: [.chat, .reader], activeTab: .chat)])
        let opened = StudioViewModel.layoutShowingLiveMeeting(one, focusedGroupID: nil)
        #expect(opened.groups.map(\.activeTab) == [.chat, .liveMeeting])

        let two = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.reader], activeTab: .reader),
        ])
        let asTab = StudioViewModel.layoutShowingLiveMeeting(two, focusedGroupID: two.groups[1].id)
        #expect(asTab.groups.count == 2)
        #expect(asTab.groups[1].activeTab == .liveMeeting)
        #expect(asTab.groups[1].openTabs == [.reader, .liveMeeting])

        var behind = asTab
        behind.groups[1].activeTab = .reader
        let forward = StudioViewModel.layoutShowingLiveMeeting(behind, focusedGroupID: nil)
        #expect(forward.groups[1].activeTab == .liveMeeting)
        #expect(forward.groups.count == 2)
    }

    @Test("the pane is never stored with the layout")
    func paneIsTransient() {
        let one = StudioCenterTabGroups(groups: [.init(tabs: [.chat, .reader], activeTab: .chat)])
        let opened = StudioViewModel.layoutShowingLiveMeeting(one, focusedGroupID: nil)
        #expect(!opened.persistedRepresentation.joined().contains("liveMeeting"))
    }
}
