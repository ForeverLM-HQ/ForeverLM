import Foundation

/// ForeverLM is a paid app (product owner, 2026-10-10 and 2026-10-11, and again
/// 2026-11-12: "basically just payment to keep using the app after 30 days and
/// just one time"; docs/pricing-pro-design.md): 7 days free from the first
/// sign-in, with no card and no click, then $19 paid once (the Early user
/// deal). Nothing is sold by the month ("No ongoing subscription or anything
/// like that"). Paying gets the whole app; there are no tiers. Day 8 without
/// payment locks the Mac app and the web library (the iPhone and iPad apps stay
/// open and show no price), and nothing is deleted: paying restores everything.
/// The count of free days and the price come from the proxy (`freeDaysTotal`,
/// `prices`); no message here names a count of its own. AI is never part of
/// the price. It always runs on the learner's own OpenRouter key, billed by
/// OpenRouter at cost, and a free model costs $0.
///
/// The proxy decides all of it: it returns the account's access with every
/// session and balance fetch (`access`, and the lock fields at the top level
/// too); docs/managed-ai-billing.md → App plans. The learner's own key runs for
/// any unlocked account (`ManagedAI.ownKeyAllowed`).
///
/// The iPhone and iPad app never shows a price, a way to buy or where to buy
/// (App Review 3.1.3(f)); see `MobileAppLockView`.
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
        /// paid once too. Anything else is not sold, so it reads as nil.
        init?(serverValue: String) {
            switch serverValue {
            case "once", "forever", "pro": self = .once
            default: return nil
            }
        }
    }

    /// What the app says when it is locked and must not say more: the
    /// iPhone's lock text, background work held back, the direct MCP path.
    static let appLockedMessage = "Your free days of ForeverLM are over."

    /// A tool call refused on a locked account, on the hosted gateway and on
    /// this Mac's direct path alike. It names no price and no place to buy.
    static let appLockedMCPMessage = "Your free days of ForeverLM are over. Open ForeverLM on your Mac to continue."

    struct AppAccess: Codable, Equatable, Sendable {
        /// The proxy's six states. They arrive as the response's top-level
        /// `state` and as `access.app_state`; `access.state` keeps its older
        /// values for shipped builds (a paid-once account still says
        /// `forever` there), and this build does not read it. Server values
        /// are mapped onto these (`init(serverValue:)`), and a state this
        /// build does not know reads as the free days: a missing or strange
        /// answer never locks.
        enum State: String, Codable, Sendable {
            /// MCP is free for every account: nothing to pay,
            /// no free days counting down, nothing locks.
            case free
            case freeDays = "free_days"
            case paidOnce = "paid_once"
            case comped
            case locked

            init(serverValue: String?) {
                switch serverValue {
                case "free": self = .free
                case "free_days": self = .freeDays
                case "paid_once", "forever", "pro": self = .paidOnce
                // The one subscription that ever existed was cancelled; a
                // paid account of any older kind is simply paid.
                case "monthly", "subscribed": self = .paidOnce
                case "comped": self = .comped
                case "locked": self = .locked
                default: self = .freeDays
                }
            }
        }

        /// Today's price, from the proxy. Nil when the proxy did not say: the
        /// app never makes a price up.
        struct Prices: Codable, Equatable, Sendable {
            let onceCents: Int?

            enum CodingKeys: String, CodingKey {
                case onceCents = "once_cents"
                /// The paid-once price under its earlier name.
                case proCents = "pro_cents"
            }

            init(onceCents: Int?) {
                self.onceCents = onceCents
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                onceCents = try container.decodeIfPresent(Int.self, forKey: .onceCents)
                    ?? container.decodeIfPresent(Int.self, forKey: .proCents)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(onceCents, forKey: .onceCents)
            }

            static let unknown = Prices(onceCents: nil)
        }

        /// What the paid app sells when the proxy does not list it: the Early
        /// user deal alone, which is what the proxy lists too.
        static let paidAppPlans: [AppPlan] = [.once]

        let state: State
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
            case prices, unlocked
            /// The paid app's state inside `access`.
            case appState = "app_state"
            case plansOnSale = "plans_on_sale"
            case freeUntil = "free_until"
            case freeDaysTotal = "free_days_total"
        }

        /// The account's one entitlement. Not said reads as unlocked: a
        /// missing answer never locks.
        var unlocked: Bool { unlockedField ?? true }

        /// Whether the account has paid: paid once, or a comp.
        var isPaid: Bool {
            switch state {
            case .paidOnce, .comped: return true
            case .free, .freeDays, .locked: return false
            }
        }

        /// Whether the app is locked at `serverNow`, a moment on the proxy's
        /// clock (`ManagedAI.serverNow`). A paid account is never locked
        /// here, whatever the time, so being offline cannot lock it; the free
        /// days run out at `freeUntil` even offline.
        func isLocked(at serverNow: Date) -> Bool {
            if !unlocked || state == .locked { return true }
            #if os(macOS) && FOREVERLM_FIRST_RUN
            // The First Run app's day-31 switch: a comped account (the tester's
            // own) reads as an ordinary one whose free days are over.
            if state == .comped, FirstRunTrialSkip.isOn { return true }
            #endif
            if state == .freeDays, let freeUntil, serverNow >= freeUntil { return true }
            return false
        }

        /// Whole free days left after today: 6 on the first of 7, 0 on the
        /// last. Nil outside running free days.
        func freeDaysLeft(at serverNow: Date) -> Int? {
            guard state == .freeDays, unlocked, let freeUntil else { return nil }
            let remaining = freeUntil.timeIntervalSince(serverNow)
            guard remaining > 0 else { return nil }
            return max(0, Int((remaining / MemoryTutorScheduler.secondsPerDay).rounded(.up)) - 1)
        }

        /// The account menu's quiet line: "6 days free left", "1 day free
        /// left", "Last free day".
        static func freeDaysStatus(daysLeft: Int) -> String {
            switch daysLeft {
            case ...0: return "Last free day"
            case 1: return "1 day free left"
            default: return "\(daysLeft) days free left"
            }
        }

        /// The iPhone's status row: "Free, 6 days left", and on the last day
        /// "Free, last day".
        static func phoneFreeDaysStatus(daysLeft: Int) -> String {
            switch daysLeft {
            case ...0: return "Free, last day"
            case 1: return "Free, 1 day left"
            default: return "Free, \(daysLeft) days left"
            }
        }

        init(
            state: State,
            prices: Prices = .unknown,
            plansOnSale: [AppPlan] = AppAccess.paidAppPlans,
            freeUntil: Date? = nil,
            freeDaysTotal: Int? = nil,
            unlocked: Bool? = nil
        ) {
            self.state = state
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
                state: top.state.map { State(serverValue: $0) } ?? state, prices: prices,
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

    /// A price as the app writes it: "$19". Prices are set in US
    /// dollars, so they read the same everywhere.
    static func dollars(_ cents: Int) -> String {
        let value = Double(cents) / 100
        return value.formatted(
            .currency(code: "USD")
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(cents % 100 == 0 ? 0 : 2))
        )
    }

    /// The last access the proxy reported, kept per device so an offline
    /// launch still knows it: a paid account never locks for being offline.
    /// Nil until a worker that reports plans has answered.
    static var appAccess: AppAccess? {
        get {
            guard let data = Preferences.value(Prefs.Models.managedAppAccess) else { return nil }
            return try? JSONDecoder().decode(AppAccess.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                Preferences.set(data, for: Prefs.Models.managedAppAccess)
            } else {
                Preferences.reset(Prefs.Models.managedAppAccess)
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

    /// The proxy's clock minus this device's, as last read from a response's
    /// `Date` header. The free days end on the proxy's clock, so setting this
    /// device's clock back does not extend them.
    static var serverClockOffset: TimeInterval {
        Preferences.value(Prefs.Models.managedServerClockOffset) ?? 0
    }

    /// Now, on the proxy's clock as last read.
    static var serverNow: Date {
        #if os(macOS) && FOREVERLM_FIRST_RUN
        // The First Run app's own switch for seeing day 31 (`FirstRunTrialSkip`).
        return Date().addingTimeInterval(serverClockOffset + FirstRunTrialSkip.offset)
        #else
        return Date().addingTimeInterval(serverClockOffset)
        #endif
    }

    /// Notes the proxy's clock from a response's `Date` header. The header is
    /// whole seconds, so a difference of a few seconds is noise and is not
    /// written.
    static func recordServerDate(_ header: String?, receivedAt: Date = Date()) {
        guard let header, let serverDate = httpDate(header) else { return }
        let offset = serverDate.timeIntervalSince(receivedAt)
        guard abs(offset - serverClockOffset) > 5 else { return }
        Preferences.set(offset, for: Prefs.Models.managedServerClockOffset)
    }

    static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }

    // MARK: - What the lock holds back

    /// Whether the app is locked: the account has neither paid nor free days
    /// left. Answers from the cached access,
    /// never the network, so anything about to start work can ask cheaply.
    /// While locked, the Mac shows only its pay screen, the iPhone its lock,
    /// and background AI (`KeychainService.resolveConfig`), sync
    /// (`MacSyncSession.round`) and the MCP connection
    /// (`MCPServerLauncher.startHostedTunnel`) stop. Nothing is deleted.
    static var isAppLocked: Bool {
        appAccess?.isLocked(at: serverNow) ?? false
    }

    /// Whether the learner's own router key may pay for requests: for any
    /// account that is not locked, its free days or paid. Nil access is the
    /// proxy not having answered yet, which is not locked, and the proxy
    /// still has the last word (`app_locked`).
    static var ownKeyAllowed: Bool { !isAppLocked }

    /// Stripe Checkout for a plan, opened in the browser: `.once` is a
    /// one-time payment, the one plan sold (a retired plan's checkout answers
    /// `plan_retired`). Checkout takes promotion codes itself.
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
