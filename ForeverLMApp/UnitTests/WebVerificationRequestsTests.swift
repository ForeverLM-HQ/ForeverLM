import Foundation
import Testing
@testable import ForeverLM

/// The registry that replaced self-opening download windows. Papers now download
/// headless, so these are the semantics that decide whether the user ever hears
/// about a blocked download — and whether a stale offer can outlive it.
@MainActor
struct WebVerificationRequestsTests {
    private func makeRegistry() -> WebVerificationRequests {
        // The banner reads `.shared`, but every test here drives its own instance
        // so a leftover request cannot leak between cases.
        WebVerificationRequests()
    }

    @Test("a parked request neither opens nor skips until the user picks")
    func parkingIsInert() {
        let registry = makeRegistry()
        var opened = 0
        var skipped = 0
        registry.request(message: "check", detail: "Paper", open: { opened += 1 }, skip: { skipped += 1 })

        #expect(registry.pending.count == 1)
        #expect(registry.latest?.detail == "Paper")
        #expect(opened == 0)
        #expect(skipped == 0)
    }

    @Test("opening runs the window builder once and clears the banner")
    func openRunsBuilderOnce() {
        let registry = makeRegistry()
        var opened = 0
        let id = registry.request(message: "check", detail: nil, open: { opened += 1 }, skip: {})

        registry.open(id)
        registry.open(id)

        #expect(opened == 1)
        #expect(registry.pending.isEmpty)
    }

    @Test("skipping abandons the download behind the request")
    func skipRunsSkipHandler() {
        let registry = makeRegistry()
        var skipped = 0
        let id = registry.request(message: "check", detail: nil, open: {}, skip: { skipped += 1 })

        registry.skip(id)

        #expect(skipped == 1)
        #expect(registry.pending.isEmpty)
    }

    @Test("withdrawing removes the offer without touching the work behind it")
    func withdrawIsSilent() {
        let registry = makeRegistry()
        var opened = 0
        var skipped = 0
        let id = registry.request(message: "check", detail: nil, open: { opened += 1 }, skip: { skipped += 1 })

        // The challenge cleared itself, or the download failed anyway.
        registry.withdraw(id)

        #expect(registry.pending.isEmpty)
        #expect(opened == 0)
        #expect(skipped == 0)
        // A withdrawn request is inert, not merely hidden.
        registry.open(id)
        registry.skip(id)
        #expect(opened == 0)
        #expect(skipped == 0)
    }

    @Test("the newest request is the one the banner offers")
    func latestWins() {
        let registry = makeRegistry()
        registry.request(message: "first", detail: nil, open: {}, skip: {})
        let second = registry.request(message: "second", detail: nil, open: {}, skip: {})

        #expect(registry.latest?.id == second)
        #expect(registry.pending.count == 2)

        // Clearing the newest falls back to the one still waiting.
        registry.withdraw(second)
        #expect(registry.latest?.message == "first")
    }

    @Test("a held registry keeps requests waiting but offers no banner until the hold ends")
    func holdKeepsBannerOff() async {
        let registry = makeRegistry()
        registry.request(message: "check", detail: "Paper", open: {}, skip: {})

        registry.holdBanners(for: .milliseconds(50))
        #expect(registry.pending.count == 1)
        #expect(registry.latest == nil)

        try? await Task.sleep(for: .milliseconds(300))
        #expect(registry.latest?.detail == "Paper")
    }
}
