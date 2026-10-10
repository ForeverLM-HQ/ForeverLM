import Foundation
import Testing
@testable import ForeverLM

@Suite("App plans")
struct AppPlanTests {
    private func decode(_ json: String) throws -> ManagedAI.AppAccess {
        try JSONDecoder().decode(ManagedAI.AppAccess.self, from: Data(json.utf8))
    }

    @Test("The worker's access block decodes, dates, benefits and prices included")
    func decodesWorkerAccess() throws {
        let access = try decode("""
        {"state":"subscribed","plan":"yearly","founding":false,
         "renews_at":"2026-10-23T09:00:00.000Z",
         "cancel_at_period_end":false,"payment_failed":false,
         "own_key_allowed":true,"balance_margin_percent":0,
         "prices":{"monthly_cents":670,"yearly_cents":6700,"forever_cents":12500}}
        """)
        #expect(access.state == .subscribed)
        #expect(access.appPlan == .yearly)
        #expect(access.renewsAt == ISO8601DateFormatter().date(from: "2026-10-23T09:00:00Z"))
        #expect(access.ownKeyAllowed)
        #expect(access.prices.yearlyCents == 6700)
        #expect(access.prices.foreverCents == 12500)
        let roundTrip = try JSONDecoder().decode(ManagedAI.AppAccess.self, from: JSONEncoder().encode(access))
        #expect(roundTrip == access)
    }

    @Test("A free account has no own key, and a worker from before the free trial offers none")
    func freeAccount() throws {
        let access = try decode(#"{"state":"free","own_key_allowed":false}"#)
        #expect(access.state == .free)
        #expect(!access.ownKeyAllowed)
        #expect(access.appPlan == nil)
        #expect(!access.trialAvailable)
        #expect(!access.trialing)
        #expect(access.trialDays == ManagedAI.AppAccess.standardTrialDays)
    }

    @Test("A free account that never had its free trial is offered one")
    func trialOffered() throws {
        let access = try decode(#"{"state":"free","own_key_allowed":false,"trial_available":true,"trial_days":30}"#)
        #expect(access.trialAvailable)
        #expect(access.trialDays == 30)
        let spent = try decode(#"{"state":"free","trial_available":false,"trial_days":30}"#)
        #expect(!spent.trialAvailable)
        let roundTrip = try JSONDecoder().decode(ManagedAI.AppAccess.self, from: JSONEncoder().encode(access))
        #expect(roundTrip == access)
    }

    @Test("A subscription in its free trial reads as trialing, with the first charge as its renewal")
    func trialing() throws {
        let access = try decode("""
        {"state":"subscribed","plan":"monthly","trialing":true,"trial_available":false,"trial_days":7,
         "renews_at":"2026-10-03T09:00:00Z","cancel_at_period_end":false,"own_key_allowed":true}
        """)
        #expect(access.trialing)
        #expect(!access.trialAvailable)
        #expect(access.ownKeyAllowed)
        #expect(access.renewsAt == ISO8601DateFormatter().date(from: "2026-10-03T09:00:00Z"))
        // A trial belongs to a subscription, and an offer to a free account.
        let free = ManagedAI.AppAccess(state: .free, trialing: true, trialAvailable: true)
        #expect(!free.trialing)
        #expect(free.trialAvailable)
        let subscribed = ManagedAI.AppAccess(state: .subscribed, plan: "monthly", trialing: true, trialAvailable: true)
        #expect(subscribed.trialing)
        #expect(!subscribed.trialAvailable)
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

    @Test("A child covered by a parent's plan reads as family, with the own key allowed")
    func familyCoverage() throws {
        let access = try decode(#"{"state":"family","own_key_allowed":true,"family":{"team_id":"t1","covered":true}}"#)
        #expect(access.state == .family)
        #expect(access.ownKeyAllowed)
        #expect(access.appPlan == nil)
    }

    @Test("A worker from before the yearly plan still decodes its prices")
    func pricesWithoutYearly() throws {
        let access = try decode(#"{"state":"free","prices":{"monthly_cents":670,"forever_cents":12500}}"#)
        #expect(access.prices.monthlyCents == 670)
        #expect(access.prices.yearlyCents == ManagedAI.AppAccess.Prices.standard.yearlyCents)
        #expect(access.prices.foreverCents == 12500)
    }

    @Test("A state this build doesn't know reads as free, and benefits follow the state")
    func unknownStateIsFree() throws {
        let unknown = try decode(#"{"state":"paused"}"#)
        #expect(unknown.state == .free)
        #expect(!unknown.ownKeyAllowed)
        let lifetime = try decode(#"{"state":"forever"}"#)
        #expect(lifetime.ownKeyAllowed)
    }

    @Test("Monthly is $4 and Believer $19 a year; every plan an account can have still decodes")
    func prices() {
        #expect(ManagedAI.AppPlan.allCases.map(\.rawValue) == ["believer", "monthly", "yearly", "forever"])
        #expect(ManagedAI.AppAccess.Prices.standard.monthlyCents == 400)
        #expect(ManagedAI.AppAccess.Prices.standard.believerCents == 1_900)
        #expect(ManagedAI.AppAccess.Prices.standard.yearlyCents == 6_700)
        #expect(ManagedAI.AppAccess.Prices.standard.foreverCents == 12_500)
        #expect(AppPlanPicker.dollars(400) == "$4")
        #expect(AppPlanPicker.dollars(670) == "$6.70")
        #expect(AppPlanPicker.dollars(1_900) == "$19")
    }

    @Test("The picker lists what the proxy has on sale: Believer first and recommended while it is open")
    func plansOnSale() throws {
        let open = try decode("""
        {"state":"free","own_key_allowed":false,"trial_available":true,"trial_days":30,
         "prices":{"monthly_cents":400,"yearly_cents":6700,"forever_cents":12500,"believer_cents":1900},
         "plans_on_sale":["believer","monthly"],"believer_offer":{"trial_days":7}}
        """)
        #expect(open.plansOnSale == [.believer, .monthly])
        #expect(open.recommendedPlan == .believer)
        #expect(open.believerOffer == ManagedAI.AppAccess.BelieverOffer(trialDays: 7))
        #expect(open.believerTrialAvailable)
        #expect(open.prices.believerCents == 1900)
        let roundTrip = try JSONDecoder().decode(ManagedAI.AppAccess.self, from: JSONEncoder().encode(open))
        #expect(roundTrip == open)

        let closed = try decode(#"{"state":"free","trial_available":true,"plans_on_sale":["monthly","someday"],"believer_offer":null}"#)
        #expect(closed.plansOnSale == [.monthly], "a plan this build does not know is left out")
        #expect(closed.recommendedPlan == nil)
        #expect(!closed.believerTrialAvailable)

        let spent = try decode(#"{"state":"free","trial_available":false,"plans_on_sale":["believer","monthly"],"believer_offer":{"trial_days":7}}"#)
        #expect(!spent.believerTrialAvailable, "one trial per account")

        // A worker from before 2026-10-06 sold Monthly, Yearly and Lifetime.
        let older = try decode(#"{"state":"free","prices":{"monthly_cents":670,"yearly_cents":6700,"forever_cents":12500}}"#)
        #expect(older.plansOnSale == [.monthly, .yearly, .forever])
        #expect(older.believerOffer == nil)
    }

    @Test("Believer's free week is its own state, with the key running and nothing at Stripe")
    func believerFreeWeek() throws {
        let week = try decode("""
        {"state":"believer_trial","plan":"believer","trialing":true,"trial_ends_at":"2026-10-13T09:00:00Z",
         "renews_at":null,"price_cents":null,"own_key_allowed":true}
        """)
        #expect(week.state == .believerTrial)
        #expect(week.isBeliever)
        #expect(week.trialing)
        #expect(week.ownKeyAllowed)
        #expect(week.trialEndsAt == ISO8601DateFormatter().date(from: "2026-10-13T09:00:00Z"))
        #expect(week.subscriptionPriceCents == nil)
        let roundTrip = try JSONDecoder().decode(ManagedAI.AppAccess.self, from: JSONEncoder().encode(week))
        #expect(roundTrip == week)
    }

    @Test("A subscription shows the price it started at, so a believer's $19 stays $19")
    func lockedPrice() throws {
        let believer = try decode(#"{"state":"subscribed","plan":"believer","price_cents":1900,"renews_at":"2027-10-13T09:00:00Z","own_key_allowed":true,"prices":{"believer_cents":2500}}"#)
        #expect(believer.isBeliever)
        #expect(believer.subscriptionPriceCents == 1900, "today's price may change; theirs does not")
        let olderMonthly = try decode(#"{"state":"subscribed","plan":"monthly","price_cents":670,"own_key_allowed":true}"#)
        #expect(olderMonthly.subscriptionPriceCents == 670)
        let unsaid = try decode(#"{"state":"subscribed","plan":"monthly","own_key_allowed":true}"#)
        #expect(unsaid.subscriptionPriceCents == 400, "before Stripe has said, today's price")
        let lifetime = try decode(#"{"state":"forever","plan":"forever"}"#)
        #expect(lifetime.subscriptionPriceCents == nil)
        #expect(!lifetime.isBeliever)
    }
}
