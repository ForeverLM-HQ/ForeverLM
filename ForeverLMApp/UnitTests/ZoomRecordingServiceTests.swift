import Testing
import Foundation
@testable import ForeverLM

@Suite("Zoom Recording Service")
struct ZoomRecordingServiceTests {

    // MARK: - URL detection

    @Suite("URL Detection")
    struct URLDetectionTests {

        @Test("Play and share recording links are detected")
        func recordingLinks() {
            #expect(ZoomRecordingService.isZoomRecordingURL(
                "https://us02web.zoom.us/rec/play/ExAmPlEpLaY_tokenAAAAbbbbCCC.-dddEEEEffffGGGG?accessLevel=meeting"
            ))
            #expect(ZoomRecordingService.isZoomRecordingURL(
                "https://us02web.zoom.us/rec/share/ExAmPlEsHaRe-token0aaaaBBBBccccDD.eeeeFFFFggggHHHH?referrer=luma"
            ))
            #expect(ZoomRecordingService.isZoomRecordingURL(
                "https://zoom.us/rec/play/abc123"
            ))
        }

        @Test("Non-recording Zoom URLs and other hosts are rejected")
        func nonRecordingLinks() {
            #expect(!ZoomRecordingService.isZoomRecordingURL("https://us02web.zoom.us/j/123456789"))
            #expect(!ZoomRecordingService.isZoomRecordingURL("https://zoom.us/pricing"))
            #expect(!ZoomRecordingService.isZoomRecordingURL("https://www.youtube.com/watch?v=abc"))
            // Host must actually be zoom.us — a lookalike domain or a zoom URL
            // stuffed into another site's query string must not match.
            #expect(!ZoomRecordingService.isZoomRecordingURL("https://notzoom.us/rec/play/abc"))
            #expect(!ZoomRecordingService.isZoomRecordingURL("https://evil.example/rec/play/?u=zoom.us"))
        }
    }

    // MARK: - window.__data__ parsing

    @Suite("Page Data Parsing")
    struct PageDataParsingTests {

        // Shape captured from a real us02web.zoom.us/rec/play page (June 2026):
        // JavaScript object literal, unquoted keys, mixed quote styles.
        static let playPageHTML = """
        <script>
        window.__data__ = {
        logo: {
        img:  "" ,
        link: 'https://us02web.zoom.us/',
        alt:  "Zoom Logo"
        },
        meetingId: '',
        fileId: 'ExAmPlEfIlEiD0aaaaBBBBccccDDDD-ee_FFFFggggHHHHiiiiJJ.KKKKllllMMMM',
        isLogin: false,
        siteName: 'Zoom',
        accessLevel: ''
        };
        </script>
        """

        @Test("File id is extracted from a play page")
        func fileIDFromPlayPage() {
            let data = ZoomRecordingService.parseWindowData(Self.playPageHTML)
            #expect(data["fileId"] == "ExAmPlEfIlEiD0aaaaBBBBccccDDDD-ee_FFFFggggHHHHiiiiJJ.KKKKllllMMMM")
            #expect(data["meetingId"] == "")
            #expect(data["siteName"] == "Zoom")
        }

        @Test("Meeting id is extracted from a share page")
        func meetingIDFromSharePage() {
            let html = "window.__data__ = { meetingId: 'ExAmPlEmEeTiNgId0000.aaaaBBB_ccccDDDD', fileId: '', isFromShare: true }"
            let data = ZoomRecordingService.parseWindowData(html)
            #expect(data["meetingId"] == "ExAmPlEmEeTiNgId0000.aaaaBBB_ccccDDDD")
        }

        @Test("Escaped characters in values are unescaped")
        func escapedValues() {
            let html = #"window.__data__ = { topic: 'Robin\'s Meeting', path: "a\/b" }"#
            let data = ZoomRecordingService.parseWindowData(html)
            #expect(data["topic"] == "Robin's Meeting")
            #expect(data["path"] == "a/b")
        }

        @Test("Pages without the data blob yield an empty dictionary")
        func missingBlob() {
            #expect(ZoomRecordingService.parseWindowData("<html><body>Passcode Required</body></html>").isEmpty)
        }
    }

    // MARK: - VTT conversion

    @Suite("VTT Conversion")
    struct VTTConversionTests {

        @Test("Zoom transcript VTT becomes timestamped speaker lines")
        func transcriptVTT() {
            let vtt = """
            WEBVTT

            1
            00:00:03.600 --> 00:00:06.240
            Jane Doe: Welcome everyone, let's get started.

            2
            00:00:06.500 --> 00:00:09.100
            John Smith: Thanks Jane.
            Great to be here.

            3
            01:02:03.000 --> 01:02:05.000
            Jane Doe: Wrapping up now.
            """
            let text = ZoomRecordingService.plainTextFromVTT(vtt)
            let lines = text.split(separator: "\n").map(String.init)
            #expect(lines == [
                "[0:03] Jane Doe: Welcome everyone, let's get started.",
                "[0:06] John Smith: Thanks Jane. Great to be here.",
                "[1:02:03] Jane Doe: Wrapping up now.",
            ])
        }

        @Test("Consecutive duplicate cues are collapsed and tags stripped")
        func duplicateAndTaggedCues() {
            let vtt = """
            WEBVTT

            00:00:01.000 --> 00:00:02.000
            <v Jane>Same line</v>

            00:00:02.000 --> 00:00:03.000
            Same line
            """
            let text = ZoomRecordingService.plainTextFromVTT(vtt)
            #expect(text == "[0:01] Same line")
        }

        @Test("Timestamps without hours are handled")
        func shortTimestamps() {
            #expect(ZoomRecordingService.displayStamp(fromVTTTime: "01:02.500") == "1:02")
            #expect(ZoomRecordingService.displayStamp(fromVTTTime: "00:00:59.999") == "0:59")
            #expect(ZoomRecordingService.displayStamp(fromVTTTime: "02:03:04.000") == "2:03:04")
        }

        @Test("Empty or headers-only VTT produces empty text")
        func emptyVTT() {
            #expect(ZoomRecordingService.plainTextFromVTT("WEBVTT\n\nNOTE nothing here").isEmpty)
        }
    }

    // MARK: - API payload decoding

    @Suite("Play Info Decoding")
    struct PlayInfoDecodingTests {

        @Test("Passcode gate response is recognized")
        func needPasswordResponse() throws {
            // Captured verbatim from /nws/recording/1.0/play/share-info (June 2026).
            let json = """
            {"status":true,"errorCode":0,"errorMessage":null,"result":{"accessLevel":"","action":"viewdetailpage","sharelevel":"meeting","useWhichPasswd":"meeting","requestFrom":"pwdCheck","clusterId":"us02","fileId":null,"redirectUrl":"/rec/component-page","componentName":"need-password","meetingId":"p9Ab7lpgVb0-UVRg4KGRoXDgNBTUEiu6.MJqActToTqRkrPA-","needRedirect":true}}
            """
            let envelope = try JSONDecoder().decode(
                ZoomRecordingService.PlayEnvelope.self, from: Data(json.utf8)
            )
            let result = try #require(envelope.result)
            #expect(envelope.status)
            #expect(result.needsPasscode)
            #expect(result.useWhichPasswd == "meeting")
            #expect(result.meetingId == "p9Ab7lpgVb0-UVRg4KGRoXDgNBTUEiu6.MJqActToTqRkrPA-")
            #expect(result.action == "viewdetailpage")
        }

        @Test("Recording info exposes topic, media, and transcript URLs")
        func recordingInfoResponse() throws {
            let json = """
            {"status":true,"errorCode":0,"errorMessage":null,"result":{"componentName":"rec-play","topic":"Weekly Sync","viewMp4Url":"https://ssrweb.zoom.us/rec/download/view.mp4?x=1","transcriptUrl":"/rec/play/vtt?type=transcript&fid=abc","meet":{"topic":"Weekly Sync"}}}
            """
            let envelope = try JSONDecoder().decode(
                ZoomRecordingService.PlayEnvelope.self, from: Data(json.utf8)
            )
            let result = try #require(envelope.result)
            let base = try #require(URL(string: "https://us02web.zoom.us"))
            #expect(!result.needsPasscode)
            #expect(result.displayTopic == "Weekly Sync")
            #expect(result.transcriptFileURL(relativeTo: base)?.absoluteString == "https://us02web.zoom.us/rec/play/vtt?type=transcript&fid=abc")
            // The recording's own MP4 is decoded for the not-ready summary and
            // nothing else; there is no route that downloads it.
            #expect(result.viewMp4Url == "https://ssrweb.zoom.us/rec/download/view.mp4?x=1")
        }

        @Test("Closed captions are used when no transcript exists")
        func ccFallback() throws {
            let json = """
            {"status":true,"result":{"componentName":"rec-play","ccUrl":"/rec/play/vtt?type=cc&fid=abc"}}
            """
            let envelope = try JSONDecoder().decode(
                ZoomRecordingService.PlayEnvelope.self, from: Data(json.utf8)
            )
            let result = try #require(envelope.result)
            let base = try #require(URL(string: "https://us02web.zoom.us"))
            #expect(result.transcriptFileURL(relativeTo: base)?.absoluteString == "https://us02web.zoom.us/rec/play/vtt?type=cc&fid=abc")
        }
    }

    // MARK: - Waiting for Zoom's transcript

    @Suite("Transcript readiness")
    struct TranscriptReadinessTests {

        @Test("The play-info fields Zoom populated are listed, and the asset-bearing ones summarised")
        func populatedFields() {
            let json = """
            {"status":true,"result":{"componentName":"rec-play","fileId":"abc","topic":"Standup","viewMp4Url":"/rec/play/x.mp4","transcriptUrl":"","ccUrl":null,"meet":{"topic":"Standup"},"totalClips":1}}
            """
            let names = ZoomRecordingService.populatedFieldNames(inPlayInfo: Data(json.utf8))
            #expect(names == ["componentName", "fileId", "meet", "topic", "totalClips", "viewMp4Url"])
            #expect(ZoomRecordingService.assetSummary(fieldNames: names) == "viewMp4Url")
            #expect(ZoomRecordingService.assetSummary(fieldNames: ["ccUrl", "topic", "transcriptUrl", "viewMp4Url"]) == "ccUrl, transcriptUrl, viewMp4Url")
            #expect(ZoomRecordingService.populatedFieldNames(inPlayInfo: Data("not json".utf8)).isEmpty)
        }

        @Test("Not-ready, empty and transient answers are worth asking again; a passcode or a gone recording is not")
        func retryWorth() {
            #expect(ZoomRecordingService.ZoomRecordingError.transcriptNotReady(assets: "viewMp4Url").isWorthRetrying)
            #expect(ZoomRecordingService.ZoomRecordingError.emptyTranscript.isWorthRetrying)
            #expect(ZoomRecordingService.ZoomRecordingError.apiError("HTTP 502").isWorthRetrying)
            #expect(!ZoomRecordingService.ZoomRecordingError.passcodeRequired.isWorthRetrying)
            // Zoom's answer for the three standups deleted by 2026-09-12.
            let gone = ZoomRecordingService.rejection(code: 3301, message: "This recording does not exist.")
            #expect(!gone.isWorthRetrying)
            #expect(gone.localizedDescription == "Zoom no longer has this recording: This recording does not exist.")
            #expect(ZoomRecordingService.rejection(code: 500, message: nil).isWorthRetrying)
            #expect(ZoomRecordingService.ZoomRecordingError.transcriptNotReady(assets: "viewMp4Url").localizedDescription
                == "Zoom has not published this recording's transcript yet (Zoom offered: viewMp4Url).")
        }

        @Test("An automatic fetch asks Zoom until it gives up after two days; the learner's own ask is never given up on")
        func waitDecision() {
            typealias Wait = StudioViewModel.ZoomTranscriptWait
            let added = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(Wait.decision(request: .automatic, addedAt: added, now: added.addingTimeInterval(60)) == .askZoom)
            // Three hours used to be the moment the recording was downloaded
            // and transcribed. Nothing happens there now.
            #expect(Wait.decision(request: .automatic, addedAt: added, now: added.addingTimeInterval(3 * 3600)) == .askZoom)
            #expect(Wait.decision(request: .automatic, addedAt: added, now: added.addingTimeInterval(48 * 3600 - 1)) == .askZoom)
            #expect(Wait.decision(request: .automatic, addedAt: added, now: added.addingTimeInterval(48 * 3600)) == .giveUp)
            #expect(Wait.decision(request: .userInitiated, addedAt: added, now: added.addingTimeInterval(60)) == .askZoom)
            #expect(Wait.decision(request: .userInitiated, addedAt: added, now: added.addingTimeInterval(72 * 3600)) == .askZoom)
        }

        @Test("The check asks again about queued sessions and the pre-wait 'produced no text' errors, not about passcodes, text, or two-day-old rows")
        func waitingRows() {
            typealias Wait = StudioViewModel.ZoomTranscriptWait
            let added = Date(timeIntervalSince1970: 1_800_000_000)
            let soon = added.addingTimeInterval(600)
            #expect(Wait.isWaiting(state: .queued, errorMessage: Wait.waitingMessage(checkedAt: soon, detail: nil), hasContent: false, addedAt: added, now: soon))
            #expect(Wait.isWaiting(state: .error, errorMessage: "Zoom transcript unavailable: Transcription produced no text.", hasContent: false, addedAt: added, now: soon))
            #expect(Wait.isWaiting(state: .error, errorMessage: "Waiting for Zoom's transcript · checked 10:42", hasContent: false, addedAt: added, now: soon))
            #expect(!Wait.isWaiting(state: .error, errorMessage: "This Zoom recording requires a passcode.", hasContent: false, addedAt: added, now: soon))
            #expect(!Wait.isWaiting(state: .ready, errorMessage: nil, hasContent: true, addedAt: added, now: soon))
            #expect(!Wait.isWaiting(state: .fetching, errorMessage: nil, hasContent: false, addedAt: added, now: soon))
            #expect(!Wait.isWaiting(state: .queued, errorMessage: nil, hasContent: false, addedAt: added, now: added.addingTimeInterval(49 * 3600)))
            #expect(Wait.waitingMessage(checkedAt: soon, detail: "Zoom offered viewMp4Url").hasPrefix("Waiting for Zoom's transcript · checked "))
            #expect(Wait.waitingMessage(checkedAt: soon, detail: "Zoom offered viewMp4Url").hasSuffix(" · Zoom offered viewMp4Url"))
        }
    }

    // MARK: - Form encoding

    @Test("Passcode form encoding escapes reserved characters")
    func formEncoding() {
        let encoded = ZoomRecordingService.formEncode([
            ("id", "abc.def-123"),
            ("passwd", "p@ss code&more"),
            ("action", "viewdetailpage"),
            ("recaptcha", ""),
        ])
        #expect(encoded == "id=abc.def-123&passwd=p%40ss%20code%26more&action=viewdetailpage&recaptcha=")
    }
}
