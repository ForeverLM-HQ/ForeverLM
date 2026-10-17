import Foundation
import Testing
@testable import ForeverLM

/// The paid app (product owner, 2026-10-10 and 2026-10-11;
/// docs/pricing-pro-design.md): 7 days free, then the Early user deal, $19 paid
/// once, with no monthly plan, and a locked app on day 8 without payment. The
/// proxy has run it since 2026-10-11 and decides it all; these pin how the app
/// reads its answer.
@Suite("App plans")
struct AppPlanTests {
    private func decode(_ json: String) throws -> ManagedAI.AppAccess {
        try JSONDecoder().decode(ManagedAI.AppAccess.self, from: Data(json.utf8))
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!

    @Test("The proxy's access block decodes, the old fields shipped builds read included, and round-trips")
    func decodesWorkerAccess() throws {
        // The whole block as the proxy sends it: the paid app's fields, and
        // beside them the ones older builds still read.
        let access = try decode("""
        {"state":"free","app_state":"free_days","plan":null,"founding":false,"unlocked":true,"app_lock":true,
         "free_until":"2026-10-23T09:00:00.000Z","free_days_total":7,"own_key_allowed":true,
         "renews_at":null,"cancel_at_period_end":false,"price_cents":null,"payment_failed":false,
         "trialing":false,"trial_available":false,"trial_days":30,"trial_ends_at":null,"believer_offer":null,
         "plans_on_sale":["once"],
         "prices":{"once_cents":1900,"monthly_cents":400}}
        """)
        #expect(access.state == .freeDays)
        #expect(access.unlocked)
        #expect(access.freeUntil == ISO8601DateFormatter().date(from: "2026-10-23T09:00:00Z"))
        #expect(access.freeDaysTotal == 7)
        #expect(access.plansOnSale == [.once])
        #expect(access.prices.onceCents == 1900)
        #expect(access.prices.monthlyCents == 400, "Monthly's price from before the lock, which the proxy still reports")
        #expect(!access.isPaid)
        #expect(!access.isMCPLocked(at: now))
        let roundTrip = try JSONDecoder().decode(ManagedAI.AppAccess.self, from: JSONEncoder().encode(access))
        #expect(roundTrip == access)
        // The cache keeps only what this build reads.
        let cached = try JSONSerialization.jsonObject(with: JSONEncoder().encode(access)) as? [String: Any]
        #expect(cached?["app_lock"] == nil)
        #expect(cached?["own_key_allowed"] == nil)
        #expect(cached?["plan_access"] == nil)
    }

    @Test("The paid app's state is access.app_state; access.state keeps its old values and is read only without it")
    func states() throws {
        for (raw, state) in [
            ("free_days", ManagedAI.AppAccess.State.freeDays), ("paid_once", .paidOnce), ("monthly", .monthly),
            ("comped", .comped), ("family", .family), ("locked", .locked),
        ] {
            #expect(try decode(#"{"state":"free","app_state":"\#(raw)"}"#).state == state, "\(raw)")
        }
        // Shipped builds read access.state, so a paid-once account still says
        // forever there; app_state is what counts.
        #expect(try decode(#"{"state":"forever","app_state":"paid_once"}"#).state == .paidOnce)
        #expect(try decode(#"{"state":"free","app_state":"locked"}"#).state == .locked)
        // An access cached before app_state existed carries only the old state.
        for (raw, state) in [
            ("forever", ManagedAI.AppAccess.State.paidOnce), ("pro", .paidOnce), ("subscribed", .monthly),
            ("free", .freeDays), ("believer_trial", .freeDays), ("comped", .comped), ("family", .family),
        ] {
            #expect(try decode(#"{"state":"\#(raw)"}"#).state == state, "\(raw)")
        }
        // The response's top-level state is the paid app's too, and wins over
        // an access block that carried only the old one.
        let old = try decode(#"{"state":"free"}"#)
        #expect(old.filling(.init(state: "locked", unlocked: false, freeUntil: nil)).state == .locked)
        #expect(old.filling(.init(unlocked: nil, freeUntil: nil)).state == .freeDays)
        // A state this build does not know reads as the free days and never
        // locks; free_week, the first build's name for them, is one such.
        for raw in ["paused", "free_week"] {
            let unknown = try decode(#"{"app_state":"\#(raw)","unlocked":true}"#)
            #expect(unknown.state == .freeDays, "\(raw)")
            #expect(!unknown.isMCPLocked(at: now), "\(raw)")
        }
        #expect(ManagedAI.AppAccess.State(serverValue: nil) == .freeDays)
    }

    @Test("The one plan sold is once; older paid-once ids read as it, and no subscription is ever on sale")
    func plans() throws {
        #expect(ManagedAI.AppPlan.allCases.map(\.rawValue) == ["once"])
        #expect(ManagedAI.AppPlan(serverValue: "once") == .once)
        #expect(ManagedAI.AppPlan(serverValue: "forever") == .once)
        #expect(ManagedAI.AppPlan(serverValue: "pro") == .once)
        for retired in ["monthly", "believer", "yearly"] {
            #expect(ManagedAI.AppPlan(serverValue: retired) == nil, "\(retired)")
        }

        // Whatever else a proxy lists, only the deal is on sale, once.
        let stale = try decode(#"{"app_state":"locked","unlocked":false,"plans_on_sale":["believer","monthly","once","pro"]}"#)
        #expect(stale.plansOnSale == [.once], "never a subscription, no repeats")
        // A list without the deal sells nothing.
        #expect(try decode(#"{"app_state":"free_days","plans_on_sale":["believer","monthly"]}"#).plansOnSale.isEmpty)
        // Not said: the Early user deal alone.
        #expect(try decode(#"{"app_state":"free_days"}"#).plansOnSale == [.once])
        #expect(ManagedAI.AppAccess(state: .freeDays).plansOnSale == [.once])

        let paidOnce = try decode(#"{"app_state":"paid_once","plan":"forever","founding":true}"#)
        #expect(paidOnce.isPaid)
        #expect(paidOnce.planName == "Paid once")
        #expect(paidOnce.subscriptionPriceCents == nil)
    }

    @Test("Older keys still decode, and app_lock and own_key_allowed decide nothing: the lock is unlocked and the state")
    func tolerantDecoding() throws {
        // An access this Mac cached before the cleanup: the pre-lock plans'
        // block, the lock off, and the key said held back.
        let cached = try decode("""
        {"app_state":"free_days","unlocked":true,"app_lock":false,"own_key_allowed":false,
         "free_until":"2026-10-23T09:00:00.000Z","plans_on_sale":["once"],
         "plan_access":{"state":"free","trial_available":true,"trial_days":30,"own_key_allowed":false,
          "plans_on_sale":["believer","monthly"],"believer_offer":{"trial_days":7},
          "prices":{"monthly_cents":400,"yearly_cents":6700,"forever_cents":12500,"believer_cents":1900}}}
        """)
        #expect(cached.state == .freeDays)
        #expect(!cached.isMCPLocked(at: now), "an unlocked account in its free days runs, whatever own_key_allowed said")
        #expect(cached.freeDaysLeft(at: now) == 2)

        // app_lock false no longer keeps a lapsed or locked account open.
        let lapsed = try decode(#"{"app_state":"free_days","unlocked":true,"app_lock":false,"free_until":"2026-10-01T00:00:00Z"}"#)
        #expect(lapsed.isMCPLocked(at: now))
        #expect(lapsed.freeDaysLeft(at: now) == nil)
        #expect(try decode(#"{"app_state":"locked","unlocked":false,"app_lock":false}"#).isMCPLocked(at: now))

        // A missing unlocked never locks, and nothing missing fails the decode.
        let bare = try decode(#"{}"#)
        #expect(bare.unlocked)
        #expect(bare.state == .freeDays)
        #expect(!bare.isMCPLocked(at: now))
        #expect(bare.freeDaysLeft(at: now) == nil, "no free days to count without free_until")
        #expect(bare.prices == .unknown)
    }

    @Test("The proxy's unlocked decides, and the free days run out on the proxy's clock even offline")
    func lock() throws {
        let locked = try decode(#"{"app_state":"locked","unlocked":false}"#)
        #expect(locked.isMCPLocked(at: now))
        #expect(!locked.isPaid)
        // unlocked false locks whatever the state says.
        #expect(try decode(#"{"app_state":"free_days","unlocked":false}"#).isMCPLocked(at: now))

        let freeDays = try decode(#"{"app_state":"free_days","unlocked":true,"free_until":"2026-10-21T12:00:00Z"}"#)
        #expect(!freeDays.isMCPLocked(at: now))
        #expect(freeDays.isMCPLocked(at: now.addingTimeInterval(86_400)), "the cached free days end at free_until without asking")

        // A paid account never locks for the time passing, so being offline
        // cannot lock it.
        for json in [
            #"{"app_state":"paid_once","unlocked":true,"free_until":"2026-10-01T00:00:00Z"}"#,
            #"{"app_state":"monthly","plan":"monthly","unlocked":true,"free_until":"2026-10-01T00:00:00Z"}"#,
            #"{"app_state":"comped","unlocked":true}"#,
            #"{"app_state":"family","unlocked":true}"#,
        ] {
            let paid = try decode(json)
            #expect(paid.isPaid)
            #expect(!paid.isMCPLocked(at: now.addingTimeInterval(365 * 86_400)), "\(json)")
            #expect(paid.freeDaysLeft(at: now) == nil, "\(json)")
        }
    }

    @Test("The 7 free days count whole days left after today: 6 on the first day, the last day last")
    func freeDaysCountdown() throws {
        let freeUntil = now.addingTimeInterval(7 * 86_400)
        let freeDays = ManagedAI.AppAccess(state: .freeDays, freeUntil: freeUntil, freeDaysTotal: 7, unlocked: true)
        #expect(freeDays.freeDaysLeft(at: now) == 6, "day 1")
        #expect(freeDays.freeDaysLeft(at: now.addingTimeInterval(4 * 86_400 + 1)) == 2, "day 5, two days before the end")
        #expect(freeDays.freeDaysLeft(at: now.addingTimeInterval(5 * 86_400 + 1)) == 1, "day 6")
        #expect(freeDays.freeDaysLeft(at: now.addingTimeInterval(6 * 86_400 + 1)) == 0, "day 7, the last")
        #expect(freeDays.freeDaysLeft(at: freeUntil) == nil)
        #expect(!freeDays.isMCPLocked(at: freeUntil.addingTimeInterval(-1)))
        #expect(freeDays.isMCPLocked(at: freeUntil), "day 8 locks")

        #expect(ManagedAI.AppAccess.freeDaysStatus(daysLeft: 6) == "MCP free: 6 days left")
        #expect(ManagedAI.AppAccess.freeDaysStatus(daysLeft: 2) == "MCP free: 2 days left")
        #expect(ManagedAI.AppAccess.freeDaysStatus(daysLeft: 1) == "MCP free: 1 day left")
        #expect(ManagedAI.AppAccess.freeDaysStatus(daysLeft: 0) == "MCP free: last day")
    }

    @Test("Two days before the end and the last day each bring one notice offering the deal")
    @MainActor
    func freeDaysNotices() {
        #expect(FreeDaysNotices.due(daysLeft: 29) == nil, "free days longer than a week still notice only at the end")
        #expect(FreeDaysNotices.due(daysLeft: 6) == nil, "day 1 of 7")
        #expect(FreeDaysNotices.due(daysLeft: 3) == nil, "day 4 of 7")
        #expect(FreeDaysNotices.due(daysLeft: 2) == .twoDaysLeft)
        #expect(FreeDaysNotices.due(daysLeft: 1) == .twoDaysLeft, "missed the day before, shown the next")
        #expect(FreeDaysNotices.due(daysLeft: 0) == .lastDay)
        #expect(FreeDaysNotices.message(daysLeft: 2, onceCents: 1900)
            == "MCP free: 2 days left. Keep your assistants connected with the Early user deal, $19 paid once, no subscription.")
        #expect(FreeDaysNotices.message(daysLeft: 0, onceCents: 1900).hasPrefix("MCP free: last day."))
        #expect(FreeDaysNotices.message(daysLeft: 2, onceCents: nil)
            == "MCP free: 2 days left. Keep your assistants connected with the Early user deal, paid once, no subscription.")
    }

    @Test("The top-level lock fields fill what the access block left out, and never override it")
    func topLevelFields() throws {
        let silent = try decode(#"{"app_state":"free_days"}"#)
        let filled = silent.filling(.init(unlocked: false, freeUntil: "2026-10-23T09:00:00Z"))
        #expect(!filled.unlocked)
        #expect(filled.isMCPLocked(at: now))
        #expect(filled.freeUntil == ISO8601DateFormatter().date(from: "2026-10-23T09:00:00Z"))
        let said = try decode(#"{"app_state":"free_days","unlocked":true,"free_until":"2026-10-25T09:00:00Z"}"#)
        let kept = said.filling(.init(unlocked: false, freeUntil: "2026-10-23T09:00:00Z"))
        #expect(kept.unlocked)
        #expect(kept.freeUntil == ISO8601DateFormatter().date(from: "2026-10-25T09:00:00Z"))
        #expect(silent.filling(nil) == silent)
        // The response's own top-level keys, app_lock among them, decode.
        let top = try JSONDecoder().decode(
            ManagedAI.AppAccess.TopLevelFields.self,
            from: Data(#"{"state":"locked","unlocked":false,"free_until":null,"app_lock":true}"#.utf8)
        )
        #expect(top.state == "locked")
        #expect(top.unlocked == false)
        #expect(silent.filling(top).isMCPLocked(at: now))
    }

    @Test("Prices come from the proxy, the paid-once price under its older name too, and are never made up")
    func prices() throws {
        #expect(try decode(#"{"prices":{"pro_cents":1900,"monthly_cents":400}}"#).prices.onceCents == 1900)
        let unsaid = try decode(#"{"app_state":"free_days"}"#)
        #expect(unsaid.prices == .unknown)
        #expect(ManagedAI.dollars(400) == "$4")
        #expect(ManagedAI.dollars(670) == "$6.70")
        #expect(ManagedAI.dollars(1_900) == "$19")
    }

    @Test("The offer and the lock say the contract's words, with the proxy's prices")
    @MainActor
    func wording() {
        #expect(EarlyUserDealOffer.title == "Early user deal")
        #expect(EarlyUserDealOffer.terms == "Unlocks MCP. Paid once, no subscription")
        #expect(EarlyUserDealOffer.buyTitle(onceCents: 1900) == "Get the Early User Deal: $19")
        #expect(EarlyUserDealOffer.buyTitle(onceCents: nil) == "Get the Early User Deal")
        #expect(EarlyUserDealOffer.headline(onceCents: 1900, freeDays: 7) == "MCP: 7 days free, then $19 once. No subscription.")
        #expect(EarlyUserDealOffer.headline(onceCents: nil, freeDays: 7) == "MCP: 7 days free, then pay once. No subscription.")
        #expect(EarlyUserDealOffer.headline(onceCents: 1900, freeDays: nil) == "MCP: Free to start, then $19 once. No subscription.",
                "a proxy that has not said the count gets no count of the build's own")
        #expect(EarlyUserDealOffer.welcomeLine(onceCents: 1900, freeDays: 7)
            == "The app is free. MCP: 7 days free, then $19 once. No subscription.")
        #expect(EarlyUserDealOffer.ownKeyLine == "The app is free. AI runs on your own OpenRouter key, at OpenRouter's cost. ForeverLM adds nothing.")
        #expect(EarlyUserDealOffer.lockedTitle == "MCP is locked")
        #expect(ManagedAI.mcpLockedMessage == "ForeverLM's MCP connection is not unlocked on this account. Open ForeverLM on your Mac to unlock it.")
        for text in [
            EarlyUserDealOffer.headline(onceCents: 1900, freeDays: 7), EarlyUserDealOffer.buyTitle(onceCents: 1900),
            EarlyUserDealOffer.welcomeLine(onceCents: 1900, freeDays: 7), EarlyUserDealOffer.lockedTitle,
            FreeDaysNotices.message(daysLeft: 2, onceCents: 1900), ManagedAI.mcpLockedMessage,
        ] {
            #expect(!text.contains("—"))
            #expect(!text.localizedCaseInsensitiveContains("lifetime"))
            #expect(!text.localizedCaseInsensitiveContains("for life"))
            #expect(!text.contains("Pro"))
            #expect(!text.localizedCaseInsensitiveContains("month"), "nothing compares the deal with a monthly price: \(text)")
            #expect(!text.localizedCaseInsensitiveContains("week"), "\(text)")
        }
    }

    @Test("The key runs for any unlocked account, so no message ties it to a plan")
    @MainActor
    func keyNeedsNoPlan() {
        let messages = [
            AICreditEntitlement.purchaseRequiredMessage,
            KeychainService.emptyBalanceMessage,
            EarlyUserDealOffer.ownKeyLine,
            ReviewSessionManager.chatConfigFailureMessageForTesting(isSignedIn: true, provider: .openRouter),
        ]
        for text in messages {
            #expect(!text.isEmpty)
            #expect(!text.localizedCaseInsensitiveContains("plan"), "\(text)")
        }
        // A refusal is still recognised as one the account, not the model,
        // made: today's wording, and those stored chats hold from while the
        // key needed a plan.
        #expect(AICreditEntitlement.isBlockedByBudget(AICreditEntitlement.purchaseRequiredMessage))
        for stored in AICreditEntitlement.planEraPurchaseRequiredMessages {
            #expect(AICreditEntitlement.isBlockedByBudget("Error: \(stored)"))
        }
        #expect(!AICreditEntitlement.isBlockedByBudget("The model timed out."))
    }

    @Test("A subscriber from before the lock is paid, keeps its price, and is offered the switch to the deal")
    func subscriberFromBeforeTheLock() throws {
        let subscriber = try decode("""
        {"state":"subscribed","app_state":"monthly","plan":"monthly","app_lock":true,"unlocked":true,
         "own_key_allowed":true,"price_cents":400,"renews_at":"2026-11-05T09:00:00Z","plans_on_sale":["once"],
         "prices":{"once_cents":1900,"monthly_cents":400}}
        """)
        #expect(subscriber.state == .monthly)
        #expect(subscriber.isPaid)
        #expect(!subscriber.isMCPLocked(at: now.addingTimeInterval(365 * 86_400)))
        #expect(subscriber.planName == "Monthly")
        #expect(!subscriber.renewsYearly)
        #expect(subscriber.subscriptionPriceCents == 400)
        #expect(subscriber.renewsAt == ISO8601DateFormatter().date(from: "2026-11-05T09:00:00Z"))
        #expect(subscriber.plansOnSale == [.once], "Switch to Paid Once is the deal, and nothing else")
        // Before Stripe has said its price, Monthly reads as the proxy's
        // monthly price, never one of the build's own.
        let unpriced = try decode(#"{"app_state":"monthly","plan":"monthly","prices":{"monthly_cents":400}}"#)
        #expect(unpriced.subscriptionPriceCents == 400)
        #expect(try decode(#"{"app_state":"monthly","plan":"monthly"}"#).subscriptionPriceCents == nil)
        // A yearly subscription keeps its own name and price, and has no
        // monthly price to fall back on.
        let believer = try decode(#"{"app_state":"monthly","plan":"believer","price_cents":1900}"#)
        #expect(believer.planName == "Believer")
        #expect(believer.renewsYearly)
        #expect(believer.subscriptionPriceCents == 1900, "a subscription keeps the price it started at")
        let yearly = try decode(#"{"app_state":"monthly","plan":"yearly","prices":{"monthly_cents":400}}"#)
        #expect(yearly.planName == "Yearly")
        #expect(yearly.subscriptionPriceCents == nil)
        // Cancelled, it is still paid until the period ends.
        let ending = try decode(#"{"app_state":"monthly","plan":"monthly","unlocked":true,"cancel_at_period_end":true}"#)
        #expect(ending.cancelAtPeriodEnd)
        #expect(ending.isPaid)
    }

    @Test("A monthly plan in its free trial (bought before the lock) reads as trialing; nothing else does")
    func trialing() throws {
        let access = try decode("""
        {"app_state":"monthly","plan":"monthly","trialing":true,
         "renews_at":"2026-10-03T09:00:00Z","cancel_at_period_end":false,"own_key_allowed":true}
        """)
        #expect(access.trialing)
        #expect(access.renewsAt == ISO8601DateFormatter().date(from: "2026-10-03T09:00:00Z"))
        #expect(!ManagedAI.AppAccess(state: .freeDays, trialing: true).trialing)
        #expect(ManagedAI.AppAccess(state: .monthly, plan: "monthly", priceCents: 400).subscriptionPriceCents == 400)
        #expect(ManagedAI.AppAccess(state: .paidOnce, priceCents: 1900).priceCents == nil)
    }

    @Test("The proxy's clock comes from a response's Date header")
    func serverClock() {
        let date = ManagedAI.httpDate("Tue, 20 Oct 2026 12:00:00 GMT")
        #expect(date == now)
        #expect(ManagedAI.httpDate("not a date") == nil)
    }

    @Test("A tool call reaching this Mac directly is refused while MCP is locked, and only then")
    func directPathGate() {
        var direct = MCPAccessContext.internalFullAccess
        #expect(MCPProtocolHandler.mcpLockRefusal(for: direct, locked: true) == nil, "in-app chat is never gated here")
        direct.arrivedWithoutGateway = true
        #expect(MCPProtocolHandler.mcpLockRefusal(for: direct, locked: true) == ManagedAI.mcpLockedMessage)
        #expect(MCPProtocolHandler.mcpLockRefusal(for: direct, locked: false) == nil)
    }

    @Test("Cancellation reasons are Stripe's feedback values, and the answer carries the end date")
    func cancellation() throws {
        #expect(ManagedAI.PlanCancellationReason.allCases.map(\.rawValue) == [
            "too_expensive", "unused", "missing_features", "low_quality", "too_complex", "switched_service", "other",
        ])
        let ended = try JSONDecoder().decode(ManagedAI.PlanCancellation.self, from: Data(#"{"cancel_at_period_end":true,"ends_at":"2026-10-03T09:00:00.000Z"}"#.utf8))
        #expect(ended.endsAt == ISO8601DateFormatter().date(from: "2026-10-03T09:00:00Z"))
        let unknown = try JSONDecoder().decode(ManagedAI.PlanCancellation.self, from: Data(#"{"cancel_at_period_end":true,"ends_at":null}"#.utf8))
        #expect(unknown.endsAt == nil)
    }
}
