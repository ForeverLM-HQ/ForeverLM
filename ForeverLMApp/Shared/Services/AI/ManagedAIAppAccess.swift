import Foundation

/// ForeverLM is free, MCP included (product owner, 2026-11-08: "get rid of
/// any kind of payment for now", "make the mcp free"): the proxy answers the
/// state `free` (`State.free`), sells nothing and counts no free days. What
/// follows is the paid model it replaced, which the code still decodes for
/// payments made before and for when payment is rethought.
///
/// From 2026-10-16 MCP was the paid part (product owner,
/// 2026-10-16: "make the MCP paywalled; for the rest people should be able to
/// use the app for free using openrouter"). Everything in the app, sync and
/// AI included, runs without paying, on the learner's own OpenRouter key,
/// billed by OpenRouter at cost; a free model costs $0. What is sold is the
/// assistant connection (MCP: Claude, ChatGPT and every other client that
/// reaches the library): 7 days free from the first sign-in, with no card and
/// no click, then $19 paid once (the Early user deal). Nothing is sold by the
/// month. The free days end and nothing else changes: the tunnel stops and
/// assistants' tool calls are refused, nothing is deleted, and paying brings
/// the connection back. The count of free days and the price come from the
/// proxy (`freeDaysTotal`, `prices`); no message here names a count of its
/// own.
///
/// The proxy decides all of it: it returns the account's access with every
/// session and balance fetch (`access`, and its `unlocked` / `state` /
/// `free_until` at the top level too); docs/managed-ai-billing.md → App
/// plans. On the wire `unlocked` has meant "MCP may run" since 2026-10-16;
/// the name is older than the decision and is kept so a stored access still
/// decodes.
///
/// The iPhone and iPad app has no MCP connection, so it never shows a price,
/// a way to buy or where to buy (App Review 3.1.3(f)).
extension ManagedAI {
    /// What can be bought. The raw value is the plan id
    /// `POST /v1/plan/checkout` takes; whether it is on sale is
    /// `AppAccess.plansOnSale`.
    enum AppPlan: String, CaseIterable, Identifiable, Sendable {
        /// The Early user deal: $19, paid once, no subscription. The one plan
        /// the paid app sells (product owner, 2026-10-10: "I personally don't
        /// like monthly subscriptions!!").
        case once
        var id: String { rawValue }

        /// The proxy's plan id, older ones included: `forever` and `pro` were
        /// paid once too. Monthly, Believer and Yearly are subscriptions no
        /// longer sold, so they read as nil here; `AppAccess.planName` still
        /// names one bought before.
        init?(serverValue: String) {
            switch serverValue {
            case "once", "forever", "pro": self = .once
            default: return nil
            }
        }
    }

    /// A tool call refused while MCP is locked, on the hosted gateway and on
    /// this Mac's direct path alike. It names no price and no place to buy.
    static let mcpLockedMessage = "ForeverLM's MCP connection is not unlocked on this account. Open ForeverLM on your Mac to unlock it."

    struct AppAccess: Codable, Equatable, Sendable {
        /// The proxy's six states, which are the state of MCP's entitlement:
        /// the app itself runs in every one of them. They arrive as the response's top-level
        /// `state` and as `access.app_state`; `access.state` keeps its older
        /// values for shipped builds (a paid-once account still says
        /// `forever` there), and this build does not read it. Server values
        /// are mapped onto these (`init(serverValue:)`), and a state this
        /// build does not know reads as the free days: a missing or strange
        /// answer never locks.
        enum State: String, Codable, Sendable {
            /// MCP is free for every account (2026-11-08): nothing to pay,
            /// no free days counting down, nothing locks.
            case free
            case freeDays = "free_days"
            case paidOnce = "paid_once"
            case monthly
            case comped
            /// A child in a family team whose parent's plan is live
            /// (docs/managed-ai-billing.md → Family plans).
            case family
            /// The free days are over and nothing is paid: MCP is off, and
            /// nothing else is.
            case locked

            init(serverValue: String?) {
                switch serverValue {
                case "free": self = .free
                case "free_days": self = .freeDays
                case "paid_once", "forever", "pro": self = .paidOnce
                case "monthly", "subscribed": self = .monthly
                case "comped": self = .comped
                case "family": self = .family
                case "locked": self = .locked
                default: self = .freeDays
                }
            }
        }

        /// Today's prices, from the proxy. A subscription keeps the price it
        /// started at, which is `AppAccess.priceCents`. Nil when the proxy did
        /// not say: the app never makes a price up.
        struct Prices: Codable, Equatable, Sendable {
            let onceCents: Int?
            /// Monthly's price from before the lock, which the proxy still
            /// reports. Nothing offers it; it is what a subscription from
            /// before reads as until Stripe says its own.
            let monthlyCents: Int?

            enum CodingKeys: String, CodingKey {
                case onceCents = "once_cents"
                case monthlyCents = "monthly_cents"
                /// The paid-once price under its name from before 2026-10-10.
                case proCents = "pro_cents"
            }

            init(onceCents: Int?, monthlyCents: Int?) {
                self.onceCents = onceCents
                self.monthlyCents = monthlyCents
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                onceCents = try container.decodeIfPresent(Int.self, forKey: .onceCents)
                    ?? container.decodeIfPresent(Int.self, forKey: .proCents)
                monthlyCents = try container.decodeIfPresent(Int.self, forKey: .monthlyCents)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(onceCents, forKey: .onceCents)
                try container.encodeIfPresent(monthlyCents, forKey: .monthlyCents)
            }

            static let unknown = Prices(onceCents: nil, monthlyCents: nil)
        }

        /// What the paid app sells when the proxy does not list it: the Early
        /// user deal alone, which is what the proxy lists too.
        static let paidAppPlans: [AppPlan] = [.once]

        let state: State
        /// The proxy's plan id as sent, so a retired plan (Believer, Yearly)
        /// still reads as what it is (`planName`).
        let plan: String?
        let founding: Bool
        let renewsAt: Date?
        /// What a subscription charges each period: the price it started at.
        let priceCents: Int?
        let cancelAtPeriodEnd: Bool
        let paymentFailed: Bool
        /// A subscription in its free trial: Monthly's 30 days, from before
        /// the lock (`renewsAt` is its first charge).
        let trialing: Bool
        let prices: Prices
        /// What may be bought now: the plans this build sells that the proxy
        /// lists, so never a subscription, whatever else it lists. Missing
        /// means the Early user deal alone (`paidAppPlans`).
        let plansOnSale: [AppPlan]
        /// When the free days end. Nil when there are none.
        let freeUntil: Date?
        /// How many free days an account gets (`free_days_total`), for "7 days
        /// free, then $19 once". Nil from a proxy older than the field.
        let freeDaysTotal: Int?
        /// The proxy's `unlocked` as sent. Nil is "not said", as in an access
        /// cached before the field.
        let unlockedField: Bool?

        /// The proxy also sends `app_lock` (always true now) and
        /// `own_key_allowed` (always `unlocked`) for builds that still read
        /// them; this one reads neither, and an access cached with them, or
        /// with the `plan_access` block of the plans sold before the lock,
        /// still decodes.
        enum CodingKeys: String, CodingKey {
            case plan, founding, prices, trialing, unlocked
            /// The paid app's state inside `access`.
            case appState = "app_state"
            case renewsAt = "renews_at"
            case priceCents = "price_cents"
            case cancelAtPeriodEnd = "cancel_at_period_end"
            case paymentFailed = "payment_failed"
            case plansOnSale = "plans_on_sale"
            case freeUntil = "free_until"
            case freeDaysTotal = "free_days_total"
        }

        /// MCP's entitlement. Not said reads as unlocked: a missing answer
        /// never locks.
        var unlocked: Bool { unlockedField ?? true }

        /// Whether the account has paid in some form: paid once, a
        /// subscription, a comp or a family plan.
        var isPaid: Bool {
            switch state {
            case .paidOnce, .monthly, .comped, .family: return true
            case .free, .freeDays, .locked: return false
            }
        }

        /// A subscription's name, the retired ones included.
        var planName: String {
            switch plan {
            case "believer": return "Believer"
            case "yearly": return "Yearly"
            case "once", "forever", "pro": return "Paid once"
            default: return "Monthly"
            }
        }

        /// Whether the subscription renews yearly: Believer and Yearly did.
        var renewsYearly: Bool { plan == "believer" || plan == "yearly" }

        /// What the subscription charges each period, from what it started at
        /// or, before Stripe has said, today's monthly price.
        var subscriptionPriceCents: Int? {
            guard state == .monthly else { return nil }
            if let priceCents { return priceCents }
            return renewsYearly ? nil : prices.monthlyCents
        }

        /// Whether MCP is locked at `serverNow`, a moment on the proxy's
        /// clock (`ManagedAI.serverNow`). A paid account is never locked
        /// here, whatever the time, so being offline cannot lock it; the free
        /// days run out at `freeUntil` even offline.
        func isMCPLocked(at serverNow: Date) -> Bool {
            if !unlocked || state == .locked { return true }
            if state == .freeDays, let freeUntil, serverNow >= freeUntil { return true }
            return false
        }

        /// Whole free days left after today: 6 on the first of 7, 0 on the
        /// last. Nil outside running free days.
        func freeDaysLeft(at serverNow: Date) -> Int? {
            guard state == .freeDays, unlocked, let freeUntil else { return nil }
            let remaining = freeUntil.timeIntervalSince(serverNow)
            guard remaining > 0 else { return nil }
            return max(0, Int((remaining / 86_400).rounded(.up)) - 1)
        }

        /// The account menu's quiet line: "MCP free: 6 days left", "MCP free:
        /// 1 day left", "MCP free: last day".
        static func freeDaysStatus(daysLeft: Int) -> String {
            switch daysLeft {
            case ...0: return "MCP free: last day"
            case 1: return "MCP free: 1 day left"
            default: return "MCP free: \(daysLeft) days left"
            }
        }

        init(
            state: State,
            plan: String? = nil,
            founding: Bool = false,
            renewsAt: Date? = nil,
            priceCents: Int? = nil,
            cancelAtPeriodEnd: Bool = false,
            paymentFailed: Bool = false,
            trialing: Bool = false,
            prices: Prices = .unknown,
            plansOnSale: [AppPlan] = AppAccess.paidAppPlans,
            freeUntil: Date? = nil,
            freeDaysTotal: Int? = nil,
            unlocked: Bool? = nil
        ) {
            self.state = state
            self.plan = plan
            self.founding = founding
            self.renewsAt = renewsAt
            self.priceCents = state == .monthly ? priceCents : nil
            self.cancelAtPeriodEnd = cancelAtPeriodEnd
            self.paymentFailed = paymentFailed
            self.trialing = state == .monthly && trialing
            self.prices = prices
            self.plansOnSale = plansOnSale
            self.freeUntil = freeUntil
            self.freeDaysTotal = freeDaysTotal
            self.unlockedField = unlocked
        }

        /// The lock fields a response carries at its top level, beside the
        /// access block. The block's own answer wins; these fill what it left
        /// out.
        struct TopLevelFields: Decodable, Sendable {
            /// The paid app's state, the same as `access.app_state`.
            var state: String? = nil
            let unlocked: Bool?
            let freeUntil: String?

            enum CodingKeys: String, CodingKey {
                case state
                case unlocked
                case freeUntil = "free_until"
            }
        }

        /// This access with what the response said at its top level filled
        /// in where the block itself was silent. The top-level `state` is the
        /// paid app's, so it wins over the block's own `app_state`.
        func filling(_ top: TopLevelFields?) -> AppAccess {
            guard let top else { return self }
            return AppAccess(
                state: top.state.map { State(serverValue: $0) } ?? state, plan: plan, founding: founding, renewsAt: renewsAt,
                priceCents: priceCents, cancelAtPeriodEnd: cancelAtPeriodEnd,
                paymentFailed: paymentFailed, trialing: trialing, prices: prices,
                plansOnSale: plansOnSale,
                freeUntil: freeUntil ?? Self.date(top.freeUntil),
                freeDaysTotal: freeDaysTotal,
                unlocked: unlockedField ?? top.unlocked
            )
        }

        /// Lenient on purpose: a state this build does not know reads as the
        /// free days, a missing `unlocked` as unlocked, and a plan on sale
        /// this build does not know is left out, rather than failing the
        /// whole session.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Only the plans this build sells, once each, whatever else the
            // proxy lists: never a subscription. A proxy that lists none
            // sells the Early user deal alone.
            let onSale = try container.decodeIfPresent([String].self, forKey: .plansOnSale)
            let plans = onSale.map { onSale in
                let listed = Set(onSale.compactMap(AppPlan.init(serverValue:)))
                return AppPlan.allCases.filter(listed.contains)
            } ?? Self.paidAppPlans
            let appState = try container.decodeIfPresent(String.self, forKey: .appState)
            self.init(
                state: State(serverValue: appState),
                plan: try container.decodeIfPresent(String.self, forKey: .plan),
                founding: try container.decodeIfPresent(Bool.self, forKey: .founding) ?? false,
                renewsAt: Self.date(try container.decodeIfPresent(String.self, forKey: .renewsAt)),
                priceCents: try container.decodeIfPresent(Int.self, forKey: .priceCents),
                cancelAtPeriodEnd: try container.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd) ?? false,
                paymentFailed: try container.decodeIfPresent(Bool.self, forKey: .paymentFailed) ?? false,
                trialing: try container.decodeIfPresent(Bool.self, forKey: .trialing) ?? false,
                prices: try container.decodeIfPresent(Prices.self, forKey: .prices) ?? .unknown,
                plansOnSale: plans,
                freeUntil: Self.date(try container.decodeIfPresent(String.self, forKey: .freeUntil)),
                freeDaysTotal: try container.decodeIfPresent(Int.self, forKey: .freeDaysTotal),
                unlocked: try container.decodeIfPresent(Bool.self, forKey: .unlocked)
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state.rawValue, forKey: .appState)
            try container.encodeIfPresent(plan, forKey: .plan)
            try container.encode(founding, forKey: .founding)
            try container.encodeIfPresent(renewsAt.map(Self.string), forKey: .renewsAt)
            try container.encodeIfPresent(priceCents, forKey: .priceCents)
            try container.encode(cancelAtPeriodEnd, forKey: .cancelAtPeriodEnd)
            try container.encode(paymentFailed, forKey: .paymentFailed)
            try container.encode(trialing, forKey: .trialing)
            try container.encode(prices, forKey: .prices)
            try container.encode(plansOnSale.map(\.rawValue), forKey: .plansOnSale)
            try container.encodeIfPresent(freeUntil.map(Self.string), forKey: .freeUntil)
            try container.encodeIfPresent(freeDaysTotal, forKey: .freeDaysTotal)
            try container.encodeIfPresent(unlockedField, forKey: .unlocked)
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

    /// A price as the app writes it: "$19", "$6.70". Prices are set in US
    /// dollars, so they read the same everywhere.
    static func dollars(_ cents: Int) -> String {
        let value = Double(cents) / 100
        return value.formatted(
            .currency(code: "USD")
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(cents % 100 == 0 ? 0 : 2))
        )
    }

    private static let appAccessKey = "managedAI.appAccess"

    /// The last access the proxy reported, kept per device so an offline
    /// launch still knows it: a paid account never locks for being offline.
    /// Nil until a worker that reports plans has answered.
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

    /// Records the access a session or balance response carried, with the
    /// lock fields it sent at its top level filled in. An older worker sends
    /// no access, and that keeps the last answer instead of clearing it.
    static func storeAppAccess(_ access: AppAccess?, topLevel: AppAccess.TopLevelFields? = nil) {
        guard let access else { return }
        let merged = access.filling(topLevel)
        guard merged != appAccess else { return }
        appAccess = merged
    }

    // MARK: - The proxy's clock

    private static let serverClockOffsetKey = "managedAI.serverClockOffset"

    /// The proxy's clock minus this device's, as last read from a response's
    /// `Date` header. The free days end on the proxy's clock, so setting this
    /// device's clock back does not extend them.
    static var serverClockOffset: TimeInterval {
        UserDefaults.standard.double(forKey: serverClockOffsetKey)
    }

    /// Now, on the proxy's clock as last read.
    static var serverNow: Date { Date().addingTimeInterval(serverClockOffset) }

    /// Notes the proxy's clock from a response's `Date` header. The header is
    /// whole seconds, so a difference of a few seconds is noise and is not
    /// written.
    static func recordServerDate(_ header: String?, receivedAt: Date = Date()) {
        guard let header, let serverDate = httpDate(header) else { return }
        let offset = serverDate.timeIntervalSince(receivedAt)
        guard abs(offset - serverClockOffset) > 5 else { return }
        UserDefaults.standard.set(offset, forKey: serverClockOffsetKey)
    }

    static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }

    // MARK: - What the lock holds back

    /// Whether MCP is locked: the account has neither paid nor free days
    /// left. Answers from the cached access, never the network, so anything
    /// about to start work can ask cheaply. While locked, the MCP connection
    /// (`MCPServerLauncher.startHostedTunnel`) stops and a tool call that
    /// still arrives is refused (`MCPProtocolHandler.mcpLockRefusal`). It is
    /// the only thing the lock holds back: the app, sync and AI keep running.
    /// Nothing is deleted.
    static var isMCPLocked: Bool {
        appAccess?.isMCPLocked(at: serverNow) ?? false
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
    /// paid period's end) and is not charged again.
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

    /// Cancels the subscription at the end of what is paid for (before its
    /// first charge, nothing is ever charged), telling the proxy why when the
    /// learner said. Both answers are optional.
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

    /// Stripe Checkout for a plan, opened in the browser: `.once` is a
    /// one-time payment, the one plan sold (a retired plan's checkout answers
    /// `plan_retired`). Checkout takes promotion codes itself, so a
    /// friends-and-family code needs nothing here.
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
