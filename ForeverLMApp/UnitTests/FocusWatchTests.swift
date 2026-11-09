import Foundation
import Testing
@testable import ForeverLM

/// Nudge Me Back on Track's rules (`FocusWatch.swift`): when a drift nudges,
/// what goes on the day's log, which goal stands, and how a thing in front is
/// named. The watcher and the judge need a Mac's screen and Apple
/// Intelligence; these are the pure parts they lean on.
@Suite("Nudge me back on track")
struct FocusWatchTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let feed = FocusScene(appName: "Brave Browser", bundleID: "com.brave.Browser", windowTitle: "Home / X", url: URL(string: "https://x.com/home"))
    private let videos = FocusScene(appName: "Brave Browser", bundleID: "com.brave.Browser", windowTitle: "YouTube", url: URL(string: "https://www.youtube.com/"))
    private let paper = FocusScene(appName: "Preview", bundleID: "com.apple.Preview", windowTitle: "esm3.pdf")

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test("A drift nudges once, two minutes in, and is logged as it goes and when it ends")
    func nudgesOnceAndLogs() {
        var tracker = FocusDriftTracker()
        #expect(tracker.observe(onTrack: false, scene: feed, at: at(0)).isEmpty)
        #expect(tracker.observe(onTrack: false, scene: feed, at: at(30)).isEmpty)
        // A minute in: long enough to log.
        #expect(tracker.observe(onTrack: false, scene: feed, at: at(60)) == [.log(feed, from: at(0), to: at(60))])
        // Two minutes: the nudge, with the log widened.
        #expect(tracker.observe(onTrack: false, scene: feed, at: at(120)) == [.log(feed, from: at(0), to: at(120)), .nudge(feed)])
        // Never twice in one drift; the log widens at most once a minute.
        #expect(tracker.observe(onTrack: false, scene: feed, at: at(150)).isEmpty)
        #expect(tracker.observe(onTrack: false, scene: feed, at: at(185)) == [.log(feed, from: at(0), to: at(185))])
        // Back on track closes it.
        #expect(tracker.observe(onTrack: true, scene: paper, at: at(200)) == [.log(feed, from: at(0), to: at(200))])
        #expect(!tracker.isDrifting)
        // The next drift nudges again.
        _ = tracker.observe(onTrack: false, scene: feed, at: at(300))
        #expect(tracker.observe(onTrack: false, scene: feed, at: at(420)).contains(.nudge(feed)))
    }

    @Test("A glance under a minute is neither nudged nor logged")
    func glanceStaysOff() {
        var tracker = FocusDriftTracker()
        #expect(tracker.observe(onTrack: false, scene: feed, at: at(0)).isEmpty)
        #expect(tracker.observe(onTrack: false, scene: feed, at: at(40)).isEmpty)
        #expect(tracker.observe(onTrack: true, scene: paper, at: at(50)).isEmpty)
        #expect(tracker.close(at: at(500)).isEmpty)
    }

    @Test("Each site a drift wandered through is logged, the first one too")
    func everyStretchLogged() {
        var tracker = FocusDriftTracker()
        _ = tracker.observe(onTrack: false, scene: feed, at: at(0))
        // Forty seconds on X, then YouTube: not yet a minute, nothing logged.
        #expect(tracker.observe(onTrack: false, scene: videos, at: at(40)).isEmpty)
        // At a minute both go on.
        #expect(tracker.observe(onTrack: false, scene: videos, at: at(70)) == [
            .log(feed, from: at(0), to: at(40)),
            .log(videos, from: at(40), to: at(70)),
        ])
        // The nudge names what is in front when it comes.
        #expect(tracker.observe(onTrack: false, scene: videos, at: at(125)).contains(.nudge(videos)))
    }

    @Test("Going idle ends a drift as it stood")
    func idleCloses() {
        var tracker = FocusDriftTracker()
        _ = tracker.observe(onTrack: false, scene: feed, at: at(0))
        _ = tracker.observe(onTrack: false, scene: videos, at: at(30))
        #expect(tracker.close(at: at(90)) == [.log(feed, from: at(0), to: at(30)), .log(videos, from: at(30), to: at(90))])
        #expect(!tracker.isDrifting)
    }

    @Test("A thing in front is named by its site, else its app, and judged without its query")
    func sceneNames() {
        #expect(feed.targetID == "x.com" && feed.displayName == "x.com")
        #expect(videos.host == "youtube.com" && videos.pageText == "youtube.com")
        #expect(paper.targetID == "com.apple.Preview" && paper.displayName == "Preview")
        let search = FocusScene(appName: "Safari", bundleID: "com.apple.Safari", url: URL(string: "https://www.google.com/search?q=private+words"))
        #expect(search.pageText == "google.com/search")
        #expect(FocusScene(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "  ").windowTitle == nil)
        #expect(feed.verdictKey != videos.verdictKey)
        #expect(FrontWindowReader.addressURL(from: "x.com/home")?.host == "x.com")
        #expect(FrontWindowReader.addressURL(from: "what is esm3") == nil)
    }

    @Test("The bout on the clock is the goal, else a block of the learner's own, never a meeting")
    func goals() {
        let now = at(0)
        let bout = LearningBout(dayPlanID: "2026-11-08", title: "Read the ESM3 paper", startedAt: at(-600))
        let boutGoal = FocusGoal.current(bout: bout, boutSourceTitles: ["ESM3"], event: nil, now: now)
        #expect(boutGoal?.title == "Read the ESM3 paper" && boutGoal?.context == ["ESM3"])

        var block = AppleCalendarEvent(
            calendarID: "c", eventIdentifier: "e", occurrenceDate: nil, title: "Write the thesis intro",
            start: at(-1800), end: at(1800), isAllDay: false, isDeclined: false, isFree: false,
            isCancelled: false, isBirthday: false, location: nil, url: nil
        )
        #expect(FocusGoal.current(bout: nil, event: block, now: now)?.title == "Write the thesis intro")
        // The bout wins over the block it runs in.
        #expect(FocusGoal.current(bout: bout, event: block, now: now)?.title == "Read the ESM3 paper")
        block.hasOtherPeople = true
        #expect(FocusGoal.current(bout: nil, event: block, now: now) == nil)
        // A stopped bout is no goal.
        var stopped = bout
        stopped.endedAt = at(-60)
        #expect(FocusGoal.current(bout: stopped, event: nil, now: now) == nil)
    }

    @Test("Time off track is on the log but not learning, and opens nothing")
    func offTrackKind() {
        let span = DayActivity(dayPlanID: "2026-11-08", startMinute: 600, endMinute: 612, kind: .offTrack, targetID: "x.com", title: "x.com")
        #expect(span.link == nil)
        #expect(!DayActivityKind.offTrack.isLearning)
        #expect(DayActivityKind.allCases.filter(\.isLearning).count == DayActivityKind.allCases.count - 1)
        let reading = DayActivity(dayPlanID: "2026-11-08", startMinute: 590, endMinute: 640, kind: .reading, targetID: "src-1", title: "ESM3")
        let groups = DayPlanDetail.activityGroups([reading, span])
        #expect(groups.map(\.kind) == [.reading, .offTrack])
        #expect(groups.last?.title == "x.com")
    }
}
