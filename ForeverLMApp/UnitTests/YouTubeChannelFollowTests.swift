import Foundation
import Testing
@testable import ForeverLM

@Suite("YouTube channel follow")
struct YouTubeChannelFollowTests {
    @Test("A channel can be pasted as a handle, an id, or any of YouTube's channel addresses")
    func channelReferencesParse() {
        typealias Ref = YouTubeService.ChannelReference
        #expect(YouTubeService.channelReference(from: "@PeterAttiaMD") == Ref.handle("PeterAttiaMD"))
        #expect(YouTubeService.channelReference(from: " https://www.youtube.com/@PeterAttiaMD ") == Ref.handle("PeterAttiaMD"))
        #expect(YouTubeService.channelReference(from: "youtube.com/@PeterAttiaMD/videos") == Ref.handle("PeterAttiaMD"))
        #expect(YouTubeService.channelReference(from: "https://m.youtube.com/@PeterAttiaMD") == Ref.handle("PeterAttiaMD"))
        #expect(YouTubeService.channelReference(from: "https://www.youtube.com/channel/UC8kGsMa0LygSX9nkBcBH1Sg") == Ref.id("UC8kGsMa0LygSX9nkBcBH1Sg"))
        #expect(YouTubeService.channelReference(from: "UC8kGsMa0LygSX9nkBcBH1Sg") == Ref.id("UC8kGsMa0LygSX9nkBcBH1Sg"))
        #expect(YouTubeService.channelReference(from: "https://www.youtube.com/c/PeterAttiaMD") == Ref.username("PeterAttiaMD"))
        #expect(YouTubeService.channelReference(from: "https://www.youtube.com/user/peterattiamd") == Ref.username("peterattiamd"))
    }

    @Test("A video, a playlist, another site, or nothing is not a channel")
    func nonChannelInputsAreRefused() {
        #expect(YouTubeService.channelReference(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(YouTubeService.channelReference(from: "https://www.youtube.com/playlist?list=PL123") == nil)
        #expect(YouTubeService.channelReference(from: "https://vimeo.com/@someone") == nil)
        #expect(YouTubeService.channelReference(from: "@") == nil)
        #expect(YouTubeService.channelReference(from: "   ") == nil)
        #expect(YouTubeService.channelReference(from: "https://www.youtube.com/channel/notanid") == nil)
    }

    @Test("A channel's uploads playlist is its id with UC swapped for UU")
    func uploadsPlaylistDerivesFromTheChannelID() {
        #expect(YouTubeService.uploadsPlaylistID(forChannelID: "UC8kGsMa0LygSX9nkBcBH1Sg") == "UU8kGsMa0LygSX9nkBcBH1Sg")
        let channel = YouTubeService.Channel(id: "UC8kGsMa0LygSX9nkBcBH1Sg", title: "Peter Attia MD", uploadsPlaylistID: "UU8kGsMa0LygSX9nkBcBH1Sg")
        #expect(channel.uploadsPlaylistURL == "https://www.youtube.com/playlist?list=UU8kGsMa0LygSX9nkBcBH1Sg")
        #expect(YouTubeService.playlistID(fromPlaylistURL: channel.uploadsPlaylistURL) == "UU8kGsMa0LygSX9nkBcBH1Sg")
        #expect(YouTubeService.playlistID(fromPlaylistURL: "https://www.youtube.com/@PeterAttiaMD") == nil)
    }
}
