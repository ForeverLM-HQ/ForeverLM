import Testing
import Foundation
@testable import ForeverLM

// MARK: - YouTube playlist page parsing

/// YouTube serves playlist pages in two markups: the legacy shape
/// (`playlistVideoRenderer` entries inside a `playlistVideoListRenderer`, paged
/// by `continuationItemRenderer`) and the lockup shape rolled out in 2026
/// (`lockupViewModel` entries directly in the item section, paged by
/// `continuationItemViewModel`). The parser must read both; when the lockup
/// migration landed upstream, every course playlist import failed with
/// "No videos found in playlist".
@Suite("YouTube Playlist Parsing")
struct YouTubePlaylistParsingTests {

    private func json(_ string: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(string.utf8))
        return try #require(object as? [String: Any])
    }

    private func playlistPage(sectionContents: String) throws -> [String: Any] {
        try json("""
        {"contents": {"twoColumnBrowseResultsRenderer": {"tabs": [{"tabRenderer": {"content":
          {"sectionListRenderer": {"contents": [{"itemSectionRenderer": {"contents": \(sectionContents)}}]}}
        }}]}}}
        """)
    }

    private static let videoLockup = """
    {"lockupViewModel": {
      "contentId": "rmVRLeJRkl4",
      "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
      "metadata": {"lockupMetadataViewModel": {
        "title": {"content": "Lecture 1 - Intro & Word Vectors"},
        "metadata": {"contentMetadataViewModel": {"metadataRows": [
          {"metadataParts": [
            {"text": {"content": "Stanford Online", "commandRuns": [{"onTap": {"innertubeCommand": {"browseEndpoint": {"browseId": "UCabc"}}}}]}},
            {"text": {"content": "801K views"}},
            {"text": {"content": "4 years ago"}}
          ]}
        ]}}
      }},
      "rendererContext": {"commandContext": {"onTap": {"innertubeCommand": {
        "watchEndpoint": {"videoId": "rmVRLeJRkl4", "index": 0}
      }}}}
    }}
    """

    private static let lockupPager = """
    {"continuationItemViewModel": {"continuationCommand": {"innertubeCommand": {
      "continuationCommand": {"token": "LOCKUP_TOKEN", "request": "CONTINUATION_REQUEST_TYPE_BROWSE"}
    }}}}
    """

    @Test("Lockup playlist page yields items with 1-based indexes and the pager token")
    func parsesLockupPage() throws {
        let secondLockup = Self.videoLockup
            .replacingOccurrences(of: "rmVRLeJRkl4", with: "gqaHkPEZAew")
            .replacingOccurrences(of: "\"index\": 0", with: "\"index\": 1")
        let page = try playlistPage(sectionContents: "[\(Self.videoLockup), \(secondLockup), \(Self.lockupPager)]")

        let (items, continuation) = YouTubePlaylistService.parsePlaylistPageItems(from: page)

        #expect(items.count == 2)
        #expect(items.first?.videoId == "rmVRLeJRkl4")
        #expect(items.first?.title == "Lecture 1 - Intro & Word Vectors")
        // watchEndpoint.index is 0-based; the parser exposes the 1-based
        // position the legacy markup displayed.
        #expect(items.map(\.playlistIndex) == [1, 2])
        #expect(items.first?.channelTitle == "Stanford Online")
        #expect(continuation == "LOCKUP_TOKEN")
    }

    @Test("Lockup without a watch endpoint index still imports, with no index")
    func parsesLockupWithoutIndex() throws {
        let bare = """
        {"lockupViewModel": {
          "contentId": "abc123def45",
          "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
          "metadata": {"lockupMetadataViewModel": {"title": {"content": "Untracked"}}}
        }}
        """
        let page = try playlistPage(sectionContents: "[\(bare)]")

        let (items, _) = YouTubePlaylistService.parsePlaylistPageItems(from: page)

        #expect(items.count == 1)
        #expect(items.first?.playlistIndex == nil)
        // Plain view-count/age rows are absent here; no byline means no channel.
        #expect(items.first?.channelTitle == nil)
    }

    @Test("Non-video lockups (mixes, playlists in rails) are skipped")
    func skipsNonVideoLockups() throws {
        let playlistLockup = """
        {"lockupViewModel": {
          "contentId": "PL12345",
          "contentType": "LOCKUP_CONTENT_TYPE_PLAYLIST",
          "metadata": {"lockupMetadataViewModel": {"title": {"content": "A rail playlist"}}}
        }}
        """
        let page = try playlistPage(sectionContents: "[\(playlistLockup), \(Self.videoLockup)]")

        let (items, _) = YouTubePlaylistService.parsePlaylistPageItems(from: page)

        #expect(items.map(\.videoId) == ["rmVRLeJRkl4"])
    }

    @Test("Legacy playlist page markup still parses")
    func parsesLegacyPage() throws {
        let wrapped = """
        [{"playlistVideoListRenderer": {"contents": [
          {"playlistVideoRenderer": {
            "videoId": "abc123def45",
            "title": {"runs": [{"text": "Old Style Lecture"}]},
            "index": {"simpleText": "1"},
            "shortBylineText": {"runs": [{"text": "Old Channel"}]}
          }},
          {"continuationItemRenderer": {"continuationEndpoint": {"continuationCommand": {"token": "LEGACY_TOKEN"}}}}
        ]}}]
        """
        let page = try playlistPage(sectionContents: wrapped)

        let (items, continuation) = YouTubePlaylistService.parsePlaylistPageItems(from: page)

        #expect(items.count == 1)
        #expect(items.first?.videoId == "abc123def45")
        #expect(items.first?.title == "Old Style Lecture")
        #expect(items.first?.playlistIndex == 1)
        #expect(items.first?.channelTitle == "Old Channel")
        #expect(continuation == "LEGACY_TOKEN")
    }

    @Test("Continuation responses parse in both markups")
    func parsesContinuationResponses() throws {
        let lockupResponse = try json("""
        {"onResponseReceivedActions": [{"appendContinuationItemsAction": {"continuationItems": [
          \(Self.videoLockup.replacingOccurrences(of: "\"index\": 0", with: "\"index\": 100")),
          \(Self.lockupPager)
        ]}}]}
        """)
        let (lockupItems, lockupNext) = YouTubePlaylistService.parseContinuationItems(from: lockupResponse)
        #expect(lockupItems.count == 1)
        #expect(lockupItems.first?.playlistIndex == 101)
        #expect(lockupNext == "LOCKUP_TOKEN")

        let legacyResponse = try json("""
        {"onResponseReceivedActions": [{"appendContinuationItemsAction": {"continuationItems": [
          {"playlistVideoRenderer": {"videoId": "abc123def45", "title": {"runs": [{"text": "Old"}]}, "index": {"simpleText": "101"}}},
          {"continuationItemRenderer": {"continuationEndpoint": {"continuationCommand": {"token": "LEGACY_NEXT"}}}}
        ]}}]}
        """)
        let (legacyItems, legacyNext) = YouTubePlaylistService.parseContinuationItems(from: legacyResponse)
        #expect(legacyItems.count == 1)
        #expect(legacyItems.first?.playlistIndex == 101)
        #expect(legacyNext == "LEGACY_NEXT")
    }

    @Test("A page with no recognizable entries yields nothing")
    func emptyPageYieldsNothing() throws {
        let page = try playlistPage(sectionContents: "[{\"someFutureRenderer\": {}}]")

        let (items, continuation) = YouTubePlaylistService.parsePlaylistPageItems(from: page)

        #expect(items.isEmpty)
        #expect(continuation == nil)
    }
}

// MARK: - Course metadata extraction parsing

/// After a playlist import creates a course, the `courseMetadata` AI task
/// infers title/code/institution/instructors from the playlist's own text.
/// These cover the response parser, which must treat blank and "null"-ish
/// strings as absent rather than writing junk into course metadata.
@Suite("Course Metadata Extraction Parsing")
struct CourseMetadataExtractionParsingTests {

    @Test("Parses a full metadata object with prose around it")
    func parsesFullObject() {
        let response = """
        Here is the metadata you asked for:
        {"title": "Machine Learning", "course_code": "CS229", "institution": "Stanford", "instructors": "Andrew Ng"}
        """
        let parsed = AIService.parseCourseMetadataExtraction(response)
        #expect(parsed?.title == "Machine Learning")
        #expect(parsed?.courseCode == "CS229")
        #expect(parsed?.institution == "Stanford")
        #expect(parsed?.instructors == "Andrew Ng")
    }

    @Test("Null, blank, and placeholder fields come back nil")
    func absentFields() {
        let parsed = AIService.parseCourseMetadataExtraction(
            #"{"title": "NLP with Deep Learning", "course_code": null, "institution": "  ", "instructors": "Unknown"}"#
        )
        #expect(parsed?.title == "NLP with Deep Learning")
        #expect(parsed?.courseCode == nil)
        #expect(parsed?.institution == nil)
        #expect(parsed?.instructors == nil)
    }

    @Test("A response without a JSON object parses to nil")
    func noJSONIsNil() {
        #expect(AIService.parseCourseMetadataExtraction("I could not determine the metadata.") == nil)
        #expect(AIService.parseCourseMetadataExtraction("}{") == nil)
    }

    @Test("Overlong values are capped, whitespace trimmed")
    func trimsAndCaps() {
        let long = String(repeating: "x", count: 400)
        let parsed = AIService.parseCourseMetadataExtraction(
            "{\"title\": \"  Linear Algebra \", \"course_code\": \"\(long)\"}"
        )
        #expect(parsed?.title == "Linear Algebra")
        #expect(parsed?.courseCode?.count == 120)
        #expect(parsed?.institution == nil)
    }
}

// MARK: - The course row while its lectures arrive

/// A course's sidebar row spins where its item count will be while the
/// playlist is being imported (product owner, 2026-09-11: "when this is importing;
/// it should show a spinning wheel on here"), and while it is a shell Web
/// Studio authored whose playlist this Mac has yet to expand.
@Suite("Course import spinner")
struct CourseImportSpinnerTests {
    @Test("A course spins while its import is in flight or its web shell is unexpanded, and not otherwise")
    func courseIsImporting() {
        #expect(StudioViewModel.courseIsImporting("mit-7.05", importing: ["mit-7.05"], pendingWebImport: false))
        #expect(StudioViewModel.courseIsImporting("mit-7.05", importing: [], pendingWebImport: true))
        #expect(!StudioViewModel.courseIsImporting("mit-7.05", importing: ["another"], pendingWebImport: false))
        #expect(!StudioViewModel.courseIsImporting("mit-7.05", importing: [], pendingWebImport: false))
    }
}
