import Foundation
import Testing
@testable import ForeverLM

@Suite("Source Narration")
struct SourceNarrationTests {
    private func progress(_ done: Int, of total: Int) -> ArticleSpeechChunkProgress {
        ArticleSpeechChunkProgress(completedChunks: done, totalChunks: total)
    }

    // MARK: State

    @Test func noNarrationAndNothingRunningIsNotMade() {
        let state = SourceNarrationState(hasNarration: false, isMaking: false, progress: nil)
        #expect(state == .notMade)
        #expect(state.statusLine == nil)
        #expect(state.fraction == nil)
    }

    @Test func aRunInFlightIsBeingMadeWithItsShare() {
        let state = SourceNarrationState(hasNarration: false, isMaking: true, progress: progress(4, of: 8))
        #expect(state == .making(percent: 50))
        #expect(state.isMaking)
        #expect(state.fraction == 0.5)
        #expect(state.statusLine == "Making narration, this takes a while · 50%")
    }

    @Test func aRunWithNothingLandedYetShowsNoNumber() {
        for progress in [nil, progress(0, of: 8)] {
            let state = SourceNarrationState(hasNarration: false, isMaking: true, progress: progress)
            #expect(state == .making(percent: nil))
            #expect(state.fraction == nil)
            #expect(state.statusLine == "Making narration, this takes a while")
        }
    }

    @Test func aNarrationThatExistsIsReadyWhateverElseIsRunning() {
        #expect(SourceNarrationState(hasNarration: true, isMaking: false, progress: nil) == .ready)
        #expect(SourceNarrationState(hasNarration: true, isMaking: true, progress: progress(3, of: 8)) == .ready)
        #expect(SourceNarrationState.ready.statusLine == nil)
    }

    // MARK: What Listen does

    @Test func listenPlaysAtOnceAndWaitsOnlyForARunAlreadyMakingIt() {
        #expect(SourceNarrationState.notMade.listenAction() == .play)
        #expect(SourceNarrationState.making(percent: 40).listenAction() == .wait)
        #expect(SourceNarrationState.ready.listenAction() == .play)
    }

    // MARK: Requests

    @Test func aNarrationListenMadePlaysWhenItLands() {
        var requests = SourceNarrationRequests()
        requests.begin("a")
        #expect(requests.contains("a"))
        let plays = requests.end("a", outcome: .ready)
        #expect(plays)
        #expect(!requests.contains("a"))
    }

    @Test func aRunThatEndsWithoutAudioPlaysNothing() {
        var requests = SourceNarrationRequests()
        requests.begin("a")
        let afterFailure = requests.end("a", outcome: .failed("The voice refused it."))
        #expect(!afterFailure)
        requests.begin("a")
        let afterCancel = requests.end("a", outcome: .cancelled)
        #expect(!afterCancel)
        #expect(!requests.contains("a"))
    }

    @Test func aRunNobodyAskedListenForEndsQuietly() {
        // The source's Generate Audio, an assistant's queue or automatic audio.
        var requests = SourceNarrationRequests()
        requests.begin("a")
        let plays = requests.end("b", outcome: .ready)
        #expect(!plays)
        #expect(requests.contains("a"))
    }

    @Test func stoppingDropsTheRequestSoNothingPlaysLater() {
        var requests = SourceNarrationRequests()
        requests.begin("a")
        requests.cancel("a")
        let plays = requests.end("a", outcome: .ready)
        #expect(!plays)
    }

    @Test func aFinishedNarrationNeverPlaysOverAnotherSource() {
        #expect(SourceNarration.startsPlayingWhenMade(otherSourceIsActive: false))
        #expect(!SourceNarration.startsPlayingWhenMade(otherSourceIsActive: true))
    }

    // MARK: Artifacts

    @Test func aSourcesNarrationIsListedButASpokenScriptsIsNot() {
        #expect(SourceNarration.isListedAsArtifact(sourceURL: "https://example.com/paper"))
        #expect(SourceNarration.isListedAsArtifact(sourceURL: "https://www.biorxiv.org/content/10.1101/1"))
        #expect(!SourceNarration.isListedAsArtifact(sourceURL: "foreverlm://explainer/abc"))
        #expect(!SourceNarration.isListedAsArtifact(sourceURL: "foreverlm://audio-overview/abc"))
    }

    @Test func theCardNamesTheSourceItReads() {
        #expect(SourceNarration.caption(forSourceTitled: "Mitochondria") == "Narration of Mitochondria")
    }
}
