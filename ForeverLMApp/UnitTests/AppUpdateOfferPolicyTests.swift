import Testing
@testable import ForeverLM

/// The pill releases Sparkle's session for the updates it shows, and a resumed
/// update is checked against the feed before anyone can install it, so the
/// build that gets installed is always the newest the feed had at that moment.
@Suite("App Update Offer Policy")
struct AppUpdateOfferPolicyTests {

    @Test("A scheduled update belongs to the pill while the rail is visible")
    func scheduledUpdateGoesToThePill() {
        #expect(AppUpdateOfferPolicy.pillOwnsOffer(
            userInitiated: false,
            isInformationOnly: false,
            railVisible: true
        ))
    }

    @Test("A user-initiated check is answered by Sparkle's dialog, which the user is waiting for")
    func userInitiatedCheckStaysWithSparkle() {
        #expect(!AppUpdateOfferPolicy.pillOwnsOffer(
            userInitiated: true,
            isInformationOnly: false,
            railVisible: true
        ))
    }

    @Test("An information-only update has no installer for the pill to run")
    func informationOnlyUpdateStaysWithSparkle() {
        #expect(!AppUpdateOfferPolicy.pillOwnsOffer(
            userInitiated: false,
            isInformationOnly: true,
            railVisible: true
        ))
    }

    @Test("With the rail hidden the pill has no surface, so Sparkle's dialog is shown")
    func hiddenRailFallsBackToSparkle() {
        #expect(!AppUpdateOfferPolicy.pillOwnsOffer(
            userInitiated: false,
            isInformationOnly: false,
            railVisible: false
        ))
    }

    @Test("Only a resumed download or staged install is checked against the feed; a fresh check just read it")
    func freshnessCheckOnlyForResumedOffers() {
        #expect(!AppUpdateOfferPolicy.needsFreshnessCheck(stage: .notDownloaded, isInformationOnly: false))
        #expect(AppUpdateOfferPolicy.needsFreshnessCheck(stage: .downloaded, isInformationOnly: false))
        #expect(AppUpdateOfferPolicy.needsFreshnessCheck(stage: .installing, isInformationOnly: false))
        #expect(!AppUpdateOfferPolicy.needsFreshnessCheck(stage: .downloaded, isInformationOnly: true))
    }

    @Test("A resumed build is stale only when the feed carries a newer one")
    func staleWhenFeedHasNewer() {
        #expect(AppUpdateOfferPolicy.resumedOfferIsStale(resumedVersion: "80", newestPublished: "81"))
        #expect(!AppUpdateOfferPolicy.resumedOfferIsStale(resumedVersion: "80", newestPublished: "80"))
        #expect(!AppUpdateOfferPolicy.resumedOfferIsStale(resumedVersion: "80", newestPublished: "79"))
    }

    @Test("An unreadable feed is not evidence, so the resumed build is shown as before")
    func unreadableFeedKeepsResumedBuild() {
        #expect(!AppUpdateOfferPolicy.resumedOfferIsStale(resumedVersion: "80", newestPublished: nil))
    }

    @Test("The same build is discarded at most twice, so a slow-to-exit installer cannot become a loop")
    func discardCeiling() {
        #expect(AppUpdateOfferPolicy.maximumDiscardsPerBuild == 2)
    }
}
