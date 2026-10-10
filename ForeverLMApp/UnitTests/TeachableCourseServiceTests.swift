import AVFoundation
import CommonCrypto
import Foundation
import Testing
@testable import ForeverLM

private final class TeachableFixtureAnchor {}

private func fixture(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(Bundle(for: TeachableFixtureAnchor.self).url(forResource: name, withExtension: ext))
    return try Data(contentsOf: url)
}

/// A Teachable lecture page read into its outline, attachments and video, and
/// the Hotmart player's stream found. The page fixture is the structure of a
/// real UMDF Mito U lecture (2026-09-26), with scripts and personal ids removed.
@Suite("Teachable course service")
struct TeachableCourseServiceTests {
    private static let lectureURL = URL(string: "https://umdf-mitou.teachable.com/courses/umdf-mitochondrial-medicine-2024-course11132/lectures/63595968")!

    @Test("A lecture page yields its title, course, outline, speakers and Hotmart video")
    func parsesLecturePage() throws {
        let html = try #require(String(data: try fixture("teachable-lecture-hotmart", "html"), encoding: .utf8))
        let page = try TeachableCourseService.parseLecturePage(html: html, url: Self.lectureURL)

        #expect(page.title == "Multidisciplinary Management and Acute Care")
        #expect(page.lectureID == "63595968")
        #expect(page.courseID == "2893890")
        #expect(page.courseTitle == "Masterclass 2025 - Multidisciplinary Management and Acute Care")

        #expect(page.sections.count == 1)
        let section = try #require(page.sections.first)
        #expect(section.title == "UMDF Mitochondrial Medicine 2025 - Masterclass on Primary Mito Myopathy (PMM) with Focus on TK2d")
        #expect(section.lectures.map(\.id) == ["63595968", "63609336"])
        // The outline prints the running time after a video's name; the title drops it.
        #expect(section.lectures.map(\.title) == ["Multidisciplinary Management and Acute Care", "Reguired Information for CME"])
        #expect(section.lectures[1].url.absoluteString == "https://umdf-mitou.teachable.com/courses/umdf-mitochondrial-medicine-2024-course11132/lectures/63609336")

        #expect(page.hotmartVideos == [.init(attachmentID: "118649048", userID: "1000001")])
        #expect(page.wistiaVideoIDs.isEmpty)
        #expect(page.hasVideo)
        let speakers = try #require(page.textAttachments.first)
        #expect(speakers.contains("Amy Goldstein, MD Children's Hospital of Philadelphia, Philadelphia, PA"))
        #expect(speakers.split(separator: "\n").count == 4, "paragraphs and list items stay separate lines")
    }

    @Test("A page with no lecture heading is not a lecture (a sign-in or sales page)")
    func signInPageIsNotALecture() {
        #expect(throws: TeachableCourseService.TeachableError.notALecturePage) {
            _ = try TeachableCourseService.parseLecturePage(
                html: "<html><body><form action=\"/sign_in\">Log in</form></body></html>",
                url: Self.lectureURL
            )
        }
    }

    @Test("Lecture addresses are recognised on teachable.com and on a school's own domain")
    func recognisesLectureURLs() {
        #expect(TeachableCourseService.isLectureURL("https://umdf-mitou.teachable.com/courses/x/lectures/63595968"))
        #expect(TeachableCourseService.isLectureURL("https://learn.example.com/courses/abc/lectures/12"))
        #expect(!TeachableCourseService.isLectureURL("https://umdf-mitou.teachable.com/courses"))
        #expect(!TeachableCourseService.isLectureURL("https://example.com/courses/abc"))
        #expect(!TeachableCourseService.isLectureURL("https://www.youtube.com/watch?v=abc"))
        let noisy = URL(string: "https://umdf-mitou.teachable.com/courses/x/lectures/63595968/?autoplay=1#t")!
        #expect(TeachableCourseService.canonicalLectureURL(noisy).absoluteString == "https://umdf-mitou.teachable.com/courses/x/lectures/63595968")
    }

    @Test("Teachable's sign-in addresses are recognised")
    func recognisesSignIn() {
        #expect(TeachableCourseService.isSignInAddress(URL(string: "https://sso.teachable.com/secure/123/identity/login")!))
        #expect(TeachableCourseService.isSignInAddress(URL(string: "https://umdf-mitou.teachable.com/sign_in")!))
        #expect(!TeachableCourseService.isSignInAddress(Self.lectureURL))
    }

    @Test("The school's grant and the player page lead to the smallest HLS playlist")
    func resolvesHotmartStream() throws {
        let grant = try TeachableCourseService.hotmartGrant(fromJSON: Data(
            #"{"duration":2638,"video_id":"TESTVIDEO01","signature":"sig","teachable_application_key":"tok","status":"READY","flags":[]}"#.utf8
        ))
        #expect(grant == .init(videoID: "TESTVIDEO01", signature: "sig", token: "tok"))
        #expect(throws: TeachableCourseService.TeachableError.self) {
            _ = try TeachableCourseService.hotmartGrant(fromJSON: Data(#"{"status":"PROCESSING"}"#.utf8))
        }

        let player = try #require(String(data: try fixture("hotmart-player-embed", "html"), encoding: .utf8))
        let playlist = try #require(TeachableCourseService.hotmartPlaylistURL(fromPlayerHTML: player))
        #expect(playlist.path == "/video/TESTVIDEO01/hls/master-pkg-t-240.m3u8")
        #expect(playlist.query?.contains("hdnts=") == true, "the signed token stays on the address")
    }

    @Test("The transcript is headed by the lecture's own text")
    func transcriptDocument() throws {
        let html = try #require(String(data: try fixture("teachable-lecture-hotmart", "html"), encoding: .utf8))
        let page = try TeachableCourseService.parseLecturePage(html: html, url: Self.lectureURL)
        let document = TeachableCourseService.transcriptDocument(page: page, spoken: "Good morning.")
        #expect(document.hasPrefix("Multidisciplinary Management and Acute Care\n"))
        #expect(document.hasSuffix("\n\n---\n\nGood morning."))
    }
}

/// HLS playlists read, segments decrypted and transport streams reduced to
/// their audio, the way a course player's stream is downloaded for a
/// transcript. End-to-end runs against ffmpeg-made streams (AES-128 TS with
/// explicit and sequence IVs, fMP4, an audio-only rendition) were checked on
/// 2026-09-26 with a harness; these pin the parts.
@Suite("HLS audio downloader")
struct HLSAudioDownloaderTests {
    private static let base = URL(string: "https://cdn.example/video/abc/hls/master.m3u8?hdnts=t")!

    @Test("A master picks its lowest-bandwidth audio-carrying variant")
    func masterPicksSmallestVariant() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aacl-75",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="1"
        #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="mp4a.40.2,avc1.640029",RESOLUTION=960x540,AUDIO="audio-aacl-75"
        v540.m3u8?hdntl=a
        #EXT-X-STREAM-INF:BANDWIDTH=148000,CODECS="mp4a.40.2,avc1.640029",RESOLUTION=426x240,AUDIO="audio-aacl-75",CLOSED-CAPTIONS=NONE
        v240.m3u8?hdntl=b
        """
        guard case .master(let master) = try HLSAudioDownloader.parse(text, baseURL: Self.base) else {
            Issue.record("expected a master playlist")
            return
        }
        #expect(master.variants.count == 2)
        #expect(master.audioRenditions.isEmpty, "an AUDIO group without a URI is muxed into the variants")
        #expect(master.audioPlaylistURL()?.absoluteString == "https://cdn.example/video/abc/hls/v240.m3u8?hdntl=b")
    }

    @Test("An audio-only rendition is preferred over any variant")
    func audioRenditionPreferred() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=500000,CODECS="avc1.640029,mp4a.40.2",AUDIO="aud"
        video.m3u8
        """
        guard case .master(let master) = try HLSAudioDownloader.parse(text, baseURL: Self.base) else {
            Issue.record("expected a master playlist")
            return
        }
        #expect(master.audioPlaylistURL()?.absoluteString == "https://cdn.example/video/abc/hls/audio/index.m3u8")
    }

    @Test("A media playlist carries its sequence numbers and AES-128 key")
    func mediaPlaylistKeys() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example/k.key?hdntl=z"
        #EXTINF:6, no desc
        s-1.ts?hdntl=z
        #EXTINF:6, no desc
        s-2.ts?hdntl=z
        #EXT-X-ENDLIST
        """
        guard case .media(let media) = try HLSAudioDownloader.parse(text, baseURL: Self.base) else {
            Issue.record("expected a media playlist")
            return
        }
        #expect(media.segments.map(\.sequenceNumber) == [1, 2])
        #expect(media.segments.first?.uri.absoluteString == "https://cdn.example/video/abc/hls/s-1.ts?hdntl=z")
        #expect(media.segments.first?.key == .aes128(uri: URL(string: "https://keys.example/k.key?hdntl=z")!, iv: nil))
        #expect(media.initializationSection == nil)
    }

    @Test("SAMPLE-AES is refused as DRM, byte ranges as unsupported")
    func refusesProtectedAndByteRange() {
        #expect(throws: HLSAudioDownloader.HLSError.unsupportedEncryption("SAMPLE-AES")) {
            _ = try HLSAudioDownloader.parse("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://x\"\n#EXTINF:6,\na.ts", baseURL: Self.base)
        }
        #expect(throws: HLSAudioDownloader.HLSError.byteRangeSegmentsUnsupported) {
            _ = try HLSAudioDownloader.parse("#EXTM3U\n#EXTINF:6,\n#EXT-X-BYTERANGE:1000@0\na.ts", baseURL: Self.base)
        }
        #expect(throws: HLSAudioDownloader.HLSError.notAPlaylist) {
            _ = try HLSAudioDownloader.parse("<HTML><HEAD>Access Denied", baseURL: Self.base)
        }
    }

    @Test("Attribute lists keep commas inside quotes")
    func attributeLists() {
        let attrs = HLSAudioDownloader.attributes(#"METHOD=AES-128,URI="https://a.b/k?x=1,y=2",IV=0x0000000000000000000000000000000A"#)
        #expect(attrs["METHOD"] == "AES-128")
        #expect(attrs["URI"] == "https://a.b/k?x=1,y=2")
        #expect(attrs["IV"] == "0x0000000000000000000000000000000A")
    }

    @Test("A segment without an IV uses its sequence number, big-endian")
    func sequenceIV() {
        let iv = HLSAudioDownloader.sequenceIV(258)
        #expect(iv.count == 16)
        #expect(Array(iv) == Array(repeating: 0, count: 14) + [0x01, 0x02])
    }

    @Test("An AES-128 segment decrypts to the transport stream, and the stream to ADTS audio AVFoundation reads")
    func decryptsAndDemuxes() async throws {
        let clear = try fixture("hls-audio-segment", "ts")
        let key = Data((0..<16).map { UInt8($0 * 7 & 0xFF) })
        let iv = HLSAudioDownloader.sequenceIV(5)
        let encrypted = try Self.encrypt(clear, key: key, iv: iv)
        #expect(encrypted != clear)
        let decrypted = try HLSAudioDownloader.decryptAES128(encrypted, key: key, iv: iv)
        #expect(decrypted == clear)

        var writer = AudioStreamWriter()
        // Two halves, cut mid-packet, as network chunks can arrive.
        let cut = decrypted.count / 2 + 37
        try writer.append(decrypted.prefix(cut))
        try writer.append(decrypted.suffix(from: cut))
        let (audio, fileExtension) = try writer.finish()
        #expect(fileExtension == "aac")
        let head = [UInt8](audio.prefix(2))
        #expect(head.count == 2 && head[0] == 0xFF && head[1] & 0xF0 == 0xF0, "ADTS sync word")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hls-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("audio.aac")
        try audio.write(to: file)
        let duration = try await AVURLAsset(url: file).load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 2) < 0.2)
    }

    private static func encrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw HLSAudioDownloader.HLSError.emptyStream }
        output.removeSubrange(moved..<output.count)
        return output
    }
}
