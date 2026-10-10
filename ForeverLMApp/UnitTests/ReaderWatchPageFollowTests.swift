import Foundation
import Testing
@testable import ForeverLM

/// A course's lectures are one YouTube playlist, and the player hands itself on
/// to the next one when a lecture ends. The reader used to stay bound to the
/// lecture it opened — its title, transcript, notes and watch progress all went
/// on describing a video that had stopped playing — so it now asks, once per
/// reported address, whether the page is still on the source's own video.
@Suite("Reader watch page follow")
struct ReaderWatchPageFollowTests {
    private let lecture3 = "https://www.youtube.com/watch?v=aaaaaaaaaaa"
    private let lecture4 = "https://www.youtube.com/watch?v=bbbbbbbbbbb"

    @Test("A watch link names its video whatever the playlist hangs off it")
    func playlistParametersDoNotChangeTheVideo() {
        let inPlaylist = "https://www.youtube.com/watch?v=aaaaaaaaaaa&list=PLcourse&index=3&t=91s"
        #expect(YouTubeWatchPageIdentity.namesSameVideo(inPlaylist, lecture3))
        #expect(YouTubeWatchPageIdentity.namesSameVideo("https://youtu.be/aaaaaaaaaaa", lecture3))
        #expect(!YouTubeWatchPageIdentity.namesSameVideo(lecture4, lecture3))
    }

    @Test("The reader stays put while the page is still on its own video")
    func staysOnTheOpenedVideo() {
        #expect(YouTubeWatchPageIdentity.videoNavigatedAwayFrom(
            sourceURL: lecture3,
            livePageURL: URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa&list=PLcourse&index=3")
        ) == nil)
        // Nothing has been reported yet: the page has not moved anywhere.
        #expect(YouTubeWatchPageIdentity.videoNavigatedAwayFrom(
            sourceURL: lecture3,
            livePageURL: nil
        ) == nil)
    }

    @Test("The next lecture the playlist plays is reported as the video moved to")
    func reportsTheVideoThePlayerMovedTo() throws {
        let movedTo = try #require(YouTubeWatchPageIdentity.videoNavigatedAwayFrom(
            sourceURL: lecture3,
            livePageURL: URL(string: "https://www.youtube.com/watch?v=bbbbbbbbbbb&list=PLcourse&index=4")
        ))
        // The address is handed back whole: the library lookup normalizes it,
        // and Open in Safari wants the link the page is actually on.
        #expect(movedTo.absoluteString == "https://www.youtube.com/watch?v=bbbbbbbbbbb&list=PLcourse&index=4")
        #expect(YouTubeWatchPageIdentity.namesSameVideo(movedTo.absoluteString, lecture4))
    }

    /// The reader shows one video, never YouTube's feed. The page can still be
    /// on its way back from one — the miniplayer takes it to the home feed —
    /// and in that moment the reader must go on describing the video, not
    /// offer Add to Sources for youtube.com.
    @Test("YouTube's own pages without a video are told apart from video pages and other sites")
    func youtubePagesWithoutVideo() throws {
        for page in [
            "https://www.youtube.com/",
            "https://youtube.com/feed/subscriptions",
            "https://www.youtube.com/@BlenderOfficial",
            "https://www.youtube.com/results?search_query=mitochondria",
            "https://m.youtube.com/"
        ] {
            #expect(YouTubeWatchPageIdentity.isYouTubePageWithoutVideo(try #require(URL(string: page))), "\(page)")
        }
        for page in [
            lecture3,
            "https://www.youtube.com/watch?v=aaaaaaaaaaa&list=PLcourse&index=3",
            "https://m.youtube.com/watch?v=aaaaaaaaaaa",
            "https://www.youtube.com/shorts/aaaaaaaaaaa",
            "https://www.youtube.com/live/aaaaaaaaaaa",
            "https://youtu.be/aaaaaaaaaaa",
            // Sign-in and consent happen on other hosts and are real pages the
            // reader reports as usual.
            "https://accounts.google.com/ServiceLogin?service=youtube",
            "https://consent.youtube.com/m?continue=https://www.youtube.com/watch?v=aaaaaaaaaaa"
        ] {
            #expect(!YouTubeWatchPageIdentity.isYouTubePageWithoutVideo(try #require(URL(string: page))), "\(page)")
        }
    }

    /// No rabbit hole (product owner, 2026-09-28): the page plays its own video or a
    /// video the learner saved, never the one YouTube picks next.
    @Test("The page may show its own video or a saved one, never one YouTube chose")
    func onlyTheSourceOrSavedVideos() throws {
        let source = try #require(URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa&list=RDaaaaaaaaaaa"))
        let savedLecture = "bbbbbbbbbbb"
        let isSaved: (URL) -> Bool = { YouTubeWatchPageIdentity.namesSameVideo($0.absoluteString, "https://youtu.be/\(savedLecture)") }

        // Its own video, whatever the Mix or a timestamp hangs off the address.
        #expect(YouTubeWatchPageIdentity.mayShow(
            try #require(URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa&t=120s")),
            sourceURL: source, isSavedVideo: isSaved
        ))
        // The next lecture of a course the learner saved.
        #expect(YouTubeWatchPageIdentity.mayShow(
            try #require(URL(string: "https://www.youtube.com/watch?v=bbbbbbbbbbb&list=PLcourse&index=4")),
            sourceURL: source, isSavedVideo: isSaved
        ))
        // The Mix's next entry, which nobody saved.
        #expect(!YouTubeWatchPageIdentity.mayShow(
            try #require(URL(string: "https://www.youtube.com/watch?v=ccccccccccc&list=RDaaaaaaaaaaa&index=2")),
            sourceURL: source, isSavedVideo: isSaved
        ))
    }
}
