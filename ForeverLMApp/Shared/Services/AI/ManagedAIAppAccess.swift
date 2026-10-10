import Foundation

/// The app's own plan (product owner, 2026-09-25). ForeverLM's AI features run on
/// the learner's own OpenRouter key, billed by OpenRouter at cost, and a plan
/// is what lets that key run every model. Since 2026-10-06 a plan is Monthly
/// at $4 a month (30 days free, signed up for with a card) or, while the
/// early-adopter offer is open, Believer at $19 a year: a price that never
/// goes up (the product owner: "these users can lock in this price forever"), after a
/// free week that needs no card. Yearly and Lifetime are no longer sold; the
/// accounts that have them keep them. Without a plan the proxy refuses the
/// key for every model, free ones and Free mode included (`plan_required`;
/// 2026-09-27). There is no prepaid balance to buy any more; an account's
/// leftover balance still pays for requests sent without a key until it runs
/// out. The proxy decides the plan and what is on sale, and returns both with
/// every session and balance fetch (`access`); docs/managed-ai-billing.md →
/// App plans.
extension ManagedAI {
    /// Every plan an account can have. The raw values are the plan ids
    /// `POST /v1/plan/checkout` takes; what is on sale is
    /// `AppAccess.plansOnSale`, in the order the picker shows it.
    enum AppPlan: String, CaseIterable, Identifiable, Sendable {
        case believer, monthly, yearly, forever
        var id: String { rawValue }
    }

    struct AppAccess: Codable, Equatable, Sendable {
        /// `family`: a child in a family team whose parent's plan is live
        /// covers them (docs/managed-ai-billing.md → Family plans).
        /// `believerTrial`: Believer's free week, which has nothing at Stripe
        /// yet; keeping Believer is its $19 checkout.
        enum State: String, Codable, Sendable {
            case free, subscribed, forever, comped, family
            case believerTrial = "believer_trial"
        }

        /// Today's prices. A subscription keeps the price it started at, which
        /// is `AppAccess.priceCents`.
        struct Prices: Codable, Equatable, Sendable {
            let monthlyCents: Int
            let yearlyCents: Int
            let foreverCents: Int
            let believerCents: Int

            enum CodingKeys: String, CodingKey {
                case monthlyCents = "monthly_cents"
                case yearlyCents = "yearly_cents"
                case foreverCents = "forever_cents"
                case believerCents = "believer_cents"
            }

            static let standard = Prices(monthlyCents: 400, yearlyCents: 6_700, foreverCents: 12_500, believerCents: 1_900)

            init(monthlyCents: Int, yearlyCents: Int, foreverCents: Int, believerCents: Int) {
                self.monthlyCents = monthlyCents
                self.yearlyCents = yearlyCents
                self.foreverCents = foreverCents
                self.believerCents = believerCents
            }

            /// A price the worker leaves out reads as the standard one, so a
            /// worker from before the yearly or believer plan still decodes.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                monthlyCents = try container.decodeIfPresent(Int.self, forKey: .monthlyCents) ?? Self.standard.monthlyCents
                yearlyCents = try container.decodeIfPresent(Int.self, forKey: .yearlyCents) ?? Self.standard.yearlyCents
                foreverCents = try container.decodeIfPresent(Int.self, forKey: .foreverCents) ?? Self.standard.foreverCents
                believerCents = try container.decodeIfPresent(Int.self, forKey: .believerCents) ?? Self.standard.believerCents
            }
        }

        /// Believer while it is on sale (product owner, 2026-10-06): $19 a year that
        /// never goes up, after a free week of `trialDays` that needs no card.
        struct BelieverOffer: Codable, Equatable, Sendable {
            let trialDays: Int

            enum CodingKeys: String, CodingKey {
                case trialDays = "trial_days"
            }
        }

        let state: State
        let plan: String?
        let founding: Bool
        let renewsAt: Date?
        /// When Believer's free week runs out. Nothing is charged then.
        let trialEndsAt: Date?
        /// What a subscription charges each period: the price it started at,
        /// so a believer's $19 stays $19 whatever today's price is.
        let priceCents: Int?
        let cancelAtPeriodEnd: Bool
        let paymentFailed: Bool
        /// In a free trial: Monthly's 30 days, whose first charge is
        /// `renewsAt`, or Believer's free week, which ends at `trialEndsAt`.
        let trialing: Bool
        /// A free account that has never had a trial: Monthly's checkout
        /// starts with `trialDays` free, and Believer's free week can start.
        let trialAvailable: Bool
        let trialDays: Int
        let ownKeyAllowed: Bool
        let prices: Prices
        /// What a free account may buy now, in the picker's order.
        let plansOnSale: [AppPlan]
        /// Nil once the offer closes, and from a worker from before it.
        let believerOffer: BelieverOffer?

        enum CodingKeys: String, CodingKey {
            case state, plan, founding, prices, trialing
            case believerOffer = "believer_offer"
            case plansOnSale = "plans_on_sale"
            case renewsAt = "renews_at"
            case trialEndsAt = "trial_ends_at"
            case priceCents = "price_cents"
            case cancelAtPeriodEnd = "cancel_at_period_end"
            case paymentFailed = "payment_failed"
            case trialAvailable = "trial_available"
            case trialDays = "trial_days"
            case ownKeyAllowed = "own_key_allowed"
        }

        static let standardTrialDays = 30
        /// What a worker from before 2026-10-06 sold.
        static let plansSoldBeforeBeliever: [AppPlan] = [.monthly, .yearly, .forever]

        /// The plan a subscribed account is on, or the believer in the free
        /// week. Nil for one this build does not know, and for states that
        /// carry no plan.
        var appPlan: AppPlan? { plan.flatMap(AppPlan.init(rawValue:)) }

        /// Believer, in its free week or kept.
        var isBeliever: Bool {
            appPlan == .believer && (state == .believerTrial || state == .subscribed)
        }

        /// Whether one click starts Believer's free week.
        var believerTrialAvailable: Bool { trialAvailable && believerOffer != nil }

        /// The plan the picker marks: Believer while it is on sale.
        var recommendedPlan: AppPlan? { plansOnSale.contains(.believer) ? .believer : nil }

        /// What the subscription charges each period, from what it started at
        /// or, before Stripe has said, today's price for its plan.
        var subscriptionPriceCents: Int? {
            guard state == .subscribed else { return nil }
            if let priceCents { return priceCents }
            switch appPlan {
            case .believer: return prices.believerCents
            case .monthly: return prices.monthlyCents
            case .yearly: return prices.yearlyCents
            case .forever, nil: return nil
            }
        }

        init(
            state: State,
            plan: String? = nil,
            founding: Bool = false,
            renewsAt: Date? = nil,
            trialEndsAt: Date? = nil,
            priceCents: Int? = nil,
            cancelAtPeriodEnd: Bool = false,
            paymentFailed: Bool = false,
            trialing: Bool = false,
            trialAvailable: Bool = false,
            trialDays: Int = AppAccess.standardTrialDays,
            ownKeyAllowed: Bool? = nil,
            prices: Prices = .standard,
            plansOnSale: [AppPlan] = AppAccess.plansSoldBeforeBeliever,
            believerOffer: BelieverOffer? = nil
        ) {
            self.state = state
            self.plan = plan
            self.founding = founding
            self.renewsAt = renewsAt
            self.trialEndsAt = state == .believerTrial ? trialEndsAt : nil
            self.priceCents = state == .subscribed ? priceCents : nil
            self.cancelAtPeriodEnd = cancelAtPeriodEnd
            self.paymentFailed = paymentFailed
            self.trialing = state == .believerTrial || (state == .subscribed && trialing)
            self.trialAvailable = state == .free && trialAvailable
            self.trialDays = trialDays > 0 ? trialDays : AppAccess.standardTrialDays
            self.ownKeyAllowed = ownKeyAllowed ?? (state != .free)
            self.prices = prices
            self.plansOnSale = plansOnSale
            self.believerOffer = believerOffer
        }

        /// Lenient on purpose: a state this build does not know reads as free,
        /// and what a plan gives falls back to what the state implies, rather
        /// than failing the whole session. A plan on sale this build does not
        /// know is left out of the picker.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawState = try container.decodeIfPresent(String.self, forKey: .state)
            let state = rawState.flatMap(State.init(rawValue:)) ?? .free
            let onSale = try container.decodeIfPresent([String].self, forKey: .plansOnSale)
            self.init(
                state: state,
                plan: try container.decodeIfPresent(String.self, forKey: .plan),
                founding: try container.decodeIfPresent(Bool.self, forKey: .founding) ?? false,
                renewsAt: Self.date(try container.decodeIfPresent(String.self, forKey: .renewsAt)),
                trialEndsAt: Self.date(try container.decodeIfPresent(String.self, forKey: .trialEndsAt)),
                priceCents: try container.decodeIfPresent(Int.self, forKey: .priceCents),
                cancelAtPeriodEnd: try container.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd) ?? false,
                paymentFailed: try container.decodeIfPresent(Bool.self, forKey: .paymentFailed) ?? false,
                trialing: try container.decodeIfPresent(Bool.self, forKey: .trialing) ?? false,
                // A worker from before the free week offers none.
                trialAvailable: try container.decodeIfPresent(Bool.self, forKey: .trialAvailable) ?? false,
                trialDays: try container.decodeIfPresent(Int.self, forKey: .trialDays) ?? AppAccess.standardTrialDays,
                ownKeyAllowed: try container.decodeIfPresent(Bool.self, forKey: .ownKeyAllowed),
                prices: try container.decodeIfPresent(Prices.self, forKey: .prices) ?? .standard,
                plansOnSale: onSale.map { $0.compactMap(AppPlan.init(rawValue:)) } ?? AppAccess.plansSoldBeforeBeliever,
                believerOffer: try container.decodeIfPresent(BelieverOffer.self, forKey: .believerOffer)
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state.rawValue, forKey: .state)
            try container.encodeIfPresent(plan, forKey: .plan)
            try container.encode(founding, forKey: .founding)
            try container.encodeIfPresent(renewsAt.map(Self.string), forKey: .renewsAt)
            try container.encodeIfPresent(trialEndsAt.map(Self.string), forKey: .trialEndsAt)
            try container.encodeIfPresent(priceCents, forKey: .priceCents)
            try container.encode(cancelAtPeriodEnd, forKey: .cancelAtPeriodEnd)
            try container.encode(paymentFailed, forKey: .paymentFailed)
            try container.encode(trialing, forKey: .trialing)
            try container.encode(trialAvailable, forKey: .trialAvailable)
            try container.encode(trialDays, forKey: .trialDays)
            try container.encode(ownKeyAllowed, forKey: .ownKeyAllowed)
            try container.encode(prices, forKey: .prices)
            try container.encode(plansOnSale.map(\.rawValue), forKey: .plansOnSale)
            try container.encodeIfPresent(believerOffer, forKey: .believerOffer)
        }

        static func date(_ string: String?) -> Date? {
            guard let string else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }

        private static func string(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }
    }

    private static let appAccessKey = "managedAI.appAccess"

    /// The last plan the proxy reported, kept per Mac so an offline launch
    /// still knows it. Nil until a worker that reports plans has answered.
    static var appAccess: AppAccess? {
        get {
            guard let data = UserDefaults.standard.data(forKey: appAccessKey) else { return nil }
            return try? JSONDecoder().decode(AppAccess.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: appAccessKey)
            } else {
                UserDefaults.standard.removeObject(forKey: appAccessKey)
            }
        }
    }

    /// Records the plan a session or balance response carried. An older worker
    /// sends none, and that keeps the last answer instead of clearing it.
    static func storeAppAccess(_ access: AppAccess?) {
        guard let access, access != appAccess else { return }
        appAccess = access
    }

    /// Whether the learner's own router key may pay for requests. Nil access
    /// means the proxy has not reported a plan yet (a worker from before
    /// plans): nothing was gated then, so nothing is gated here either, and the
    /// proxy still has the last word.
    static var ownKeyAllowed: Bool {
        appAccess?.ownKeyAllowed ?? true
    }

    /// Why a learner cancels (product owner, 2026-09-26: "if they cancel, they
    /// should be able to let us know why"). The raw values are Stripe's own
    /// cancellation feedback values, which `POST /v1/plan/cancel` takes.
    enum PlanCancellationReason: String, CaseIterable, Identifiable, Sendable {
        case tooExpensive = "too_expensive"
        case unused
        case missingFeatures = "missing_features"
        case lowQuality = "low_quality"
        case tooComplex = "too_complex"
        case switchedService = "switched_service"
        case other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tooExpensive: return "It costs too much"
            case .unused: return "I don't use it enough"
            case .missingFeatures: return "It's missing something I need"
            case .lowQuality: return "The answers weren't good enough"
            case .tooComplex: return "It's hard to use"
            case .switchedService: return "I'm switching to something else"
            case .other: return "Something else"
            }
        }
    }

    /// What `POST /v1/plan/cancel` answers: the plan runs to `endsAt` (the
    /// paid period's end, or the free week's) and is not charged again.
    struct PlanCancellation: Decodable, Equatable, Sendable {
        let endsAt: Date?
        enum CodingKeys: String, CodingKey { case endsAt = "ends_at" }
        init(endsAt: Date?) { self.endsAt = endsAt }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            endsAt = AppAccess.date(try container.decodeIfPresent(String.self, forKey: .endsAt))
        }
    }

    /// The comment is cut where the proxy cuts it.
    static let planCancellationCommentLimit = 2_000

    /// Cancels the plan at the end of what is paid for (or of the free week,
    /// which is then never charged), telling the proxy why when the learner
    /// said. Both answers are optional.
    static func cancelPlan(reason: PlanCancellationReason?, comment: String) async throws -> PlanCancellation {
        struct Body: Encodable {
            let reason: String?
            let comment: String
            let client: String
        }
        let trimmed = String(comment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(planCancellationCommentLimit))
        return try await post(
            "/v1/plan/cancel",
            body: Body(reason: reason?.rawValue, comment: trimmed, client: planCancellationClient),
            authenticated: true
        )
    }

    /// Takes a cancellation back before the period ends.
    static func resumePlan() async throws {
        struct Response: Decodable { let cancelAtPeriodEnd: Bool
            enum CodingKeys: String, CodingKey { case cancelAtPeriodEnd = "cancel_at_period_end" } }
        let _: Response = try await post("/v1/plan/resume", body: [String: String](), authenticated: true)
    }

    private static var planCancellationClient: String {
        #if os(iOS)
        return "ios"
        #else
        return "mac"
        #endif
    }

    /// Starts Believer's free week: no card, nothing at Stripe. The proxy
    /// answers when the week ends; the plan shows on the next refresh.
    static func startBelieverTrial() async throws -> Date? {
        struct Response: Decodable {
            let trialEndsAt: String?
            enum CodingKeys: String, CodingKey { case trialEndsAt = "trial_ends_at" }
        }
        let response: Response = try await post("/v1/plan/believer-trial", body: [String: String](), authenticated: true)
        return AppAccess.date(response.trialEndsAt)
    }

    /// Stripe Checkout for a plan, opened in the browser. Checkout takes
    /// promotion codes itself, so a friends-and-family code needs nothing here.
    static func planCheckoutURL(_ plan: AppPlan) async throws -> URL {
        struct Body: Encodable { let plan: String }
        struct Response: Decodable {
            let checkoutURL: String
            enum CodingKeys: String, CodingKey { case checkoutURL = "checkout_url" }
        }
        let response: Response = try await post(
            "/v1/plan/checkout",
            body: Body(plan: plan.rawValue),
            authenticated: true
        )
        guard let url = URL(string: response.checkoutURL) else {
            throw ServiceError(code: "bad_response", message: "Checkout returned an address the app couldn't open.")
        }
        return url
    }
}
