import AppKit
import SwiftUI

/// What ForeverLM sells (product owner, 2026-10-10; docs/pricing-pro-design.md
/// → How it is sold): the Early user deal, $19 paid once, and nothing beside
/// it. There is no monthly plan ("I personally don't like monthly
/// subscriptions!!"), so nothing here shows a monthly price or compares the
/// deal with one. The price is the proxy's (`AppAccess.prices`), never this
/// build's, and the deal is offered only while `plans_on_sale` lists it. Mac
/// only: the iPhone and iPad app never shows a price or a way to buy.
struct EarlyUserDealOffer: View {
    @Environment(ManagedAIAccountModel.self) private var account

    static let title = "Early user deal"
    static let terms = "paid once, no subscription"
    /// What Billing says if the account server ever says MCP is free (state `free`).
    static let freeTitle = "MCP is free"
    /// What the welcome screen says if the account server sells nothing.
    static let freeWelcomeLine = "ForeverLM is free, MCP included."
    /// The line every surface says what AI costs with.
    static let ownKeyLine = "AI runs on your own OpenRouter key, at OpenRouter's cost. ForeverLM adds nothing."

    /// "Get the Early User Deal: $19", or without the price while the proxy
    /// has not said it.
    static func buyTitle(onceCents: Int?) -> String {
        onceCents.map { "Get the Early User Deal: \(ManagedAI.dollars($0))" } ?? "Get the Early User Deal"
    }

    /// "7 days free, then $19 once. No subscription." The count of free days
    /// is the proxy's (`AppAccess.freeDaysTotal`), like the price; a part the
    /// proxy has not said is left unnamed rather than guessed.
    static func headline(onceCents: Int?, freeDays: Int?) -> String {
        let start = freeDays.map { "\($0) days free" } ?? "Free to start"
        let price = onceCents.map { "\(ManagedAI.dollars($0)) once" } ?? "pay once"
        return "\(start), then \(price). No subscription."
    }

    /// What the welcome screen says once: the whole app's price and free days.
    /// "7 day free trial, then one-time $19. No monthly subscription!"
    /// (product owner, 2026-11-21).
    static func welcomeLine(onceCents: Int?, freeDays: Int?) -> String {
        let start = freeDays.map { "\($0) day free trial" } ?? "Free to start"
        let price = onceCents.map { "one-time \(ManagedAI.dollars($0))" } ?? "pay once"
        return "\(start), then \(price). No monthly subscription!"
    }

    /// The welcome line for an account's access: the price and the count of
    /// free days, which are the account server's (7 days free, then $19
    /// once, since 2026-11-11). Before the access is known the line names
    /// neither; "free, MCP included" only when the server says MCP is free or
    /// sells nothing.
    static func welcomeLine(access: ManagedAI.AppAccess?) -> String {
        guard let access else { return welcomeLine(onceCents: nil, freeDays: nil) }
        guard access.state != .free, access.plansOnSale.contains(.once) else { return freeWelcomeLine }
        return welcomeLine(onceCents: access.prices.onceCents, freeDays: access.freeDaysTotal)
    }

    private var prices: ManagedAI.AppAccess.Prices { account.planPrices }
    private var onSale: [ManagedAI.AppPlan] { account.appAccess?.plansOnSale ?? ManagedAI.AppAccess.paidAppPlans }

    var body: some View {
        if onSale.contains(.once) {
            deal
        }
    }

    private var deal: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.title)
                    .font(.subheadline.weight(.semibold))
                RecommendedBadge()
                Spacer(minLength: 12)
                if let once = prices.onceCents {
                    Text(ManagedAI.dollars(once))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
            }
            Text(Self.terms)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                if account.planCheckoutInFlight == .once {
                    ProgressView().controlSize(.small)
                } else {
                    Button(Self.buyTitle(onceCents: prices.onceCents)) {
                        Task { await account.choosePlan(.once) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.planCheckoutInFlight != nil || !account.isSignedIn)
                    .accessibilityIdentifier("billing.plan.once")
                }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("billing.plan.deal")
    }
}

/// Settings → Billing: paying for ForeverLM, in one card. In the free days, or
/// locked, the card is the offer. A buyer sees "Paid once". A comped account
/// sees "Included with your account". The key, limits and activity are AI
/// Usage.
struct AppPlanSettingsSection: View {
    @Environment(ManagedAIAccountModel.self) private var account

    var body: some View {
        Group {
            if let access = account.appAccess {
                planContent(access)
            } else {
                SettingsSection(title: "Plan") {
                    BillingCard {
                        if account.refreshInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            BillingRow(title: "Couldn't load your plan", detail: "Check your connection") {
                                Button("Retry") { Task { await account.refresh() } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
        // Checkout and the Stripe page finish in the browser; coming back is
        // when to look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await account.refresh(minimumInterval: 2, silently: true) }
        }
    }

    @ViewBuilder
    private func planContent(_ access: ManagedAI.AppAccess) -> some View {
        switch access.state {
        case .free:
            SettingsSection(title: "MCP", description: EarlyUserDealOffer.freeTitle) {
                Text(EarlyUserDealOffer.ownKeyLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("billing.mcpFree")
            }
        case .freeDays, .locked:
            SettingsSection(title: "ForeverLM", description: offerSummary(access)) {
                VStack(alignment: .leading, spacing: 10) {
                    EarlyUserDealOffer()
                    Text(EarlyUserDealOffer.ownKeyLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .paidOnce, .comped:
            SettingsSection(title: "Plan") {
                planCard(access)
            }
        }
    }

    @ViewBuilder
    private func planCard(_ access: ManagedAI.AppAccess) -> some View {
        BillingCard {
            BillingRow(title: planTitle(access), detail: planDetail(access)) { EmptyView() }
                // A group of its own, so the identifier stays on the row
                // rather than stamping both texts.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("billing.subscription.status")
        }
    }

    /// Above the offer: how many of the free days are left, or that they are
    /// over.
    private func offerSummary(_ access: ManagedAI.AppAccess) -> String {
        if let status = account.freeDaysStatus { return status }
        if account.isAppLocked { return AppLockWall.title }
        return EarlyUserDealOffer.headline(onceCents: access.prices.onceCents, freeDays: access.freeDaysTotal)
    }

    private func planTitle(_ access: ManagedAI.AppAccess) -> String {
        access.state == .paidOnce ? "Paid once" : "Plan"
    }

    private func planDetail(_ access: ManagedAI.AppAccess) -> String {
        switch access.state {
        case .paidOnce: return "ForeverLM is yours to use. No subscription"
        case .comped: return "Included with your account"
        case .free, .freeDays, .locked: return ""
        }
    }
}

/// The free days' two notices (docs/pricing-pro-design.md → The free days):
/// one two days before the end and one on the last day, each shown once, each
/// offering the deal, so the free days never end as a surprise. They count
/// from the end, so they fall two days before it and on its last day. They ride the
/// Studio status banner (`StudioViewModel.showToast`). Keyed by the free
/// days' end, so new free days (the cutover's) show them again.
@MainActor
enum FreeDaysNotices {
    enum Notice: String {
        case twoDaysLeft
        case lastDay
    }

    /// Which notice is due with `daysLeft` free days left after today. The
    /// two-days notice still shows with one day left if the app was not
    /// opened the day before.
    static func due(daysLeft: Int) -> Notice? {
        switch daysLeft {
        case ...0: return .lastDay
        case 1...2: return .twoDaysLeft
        default: return nil
        }
    }

    /// "2 days free left. Keep everything you've built with the Early user
    /// deal, $19 paid once, no subscription."
    static func message(daysLeft: Int, onceCents: Int?) -> String {
        let deal = onceCents.map { "the Early user deal, \(ManagedAI.dollars($0)) paid once" } ?? "the Early user deal, paid once"
        return "\(ManagedAI.AppAccess.freeDaysStatus(daysLeft: daysLeft)). Keep everything you've built with \(deal), no subscription."
    }

    private static func shownKey(_ notice: Notice, freeUntil: Date) -> DeviceKey<Bool> {
        Prefs.Families.freeDaysNotice.key("\(notice.rawValue).\(Int(freeUntil.timeIntervalSince1970))")
    }

    /// Shows the notice that is due, once. Device-local: a notice seen on
    /// one Mac is not owed to another.
    static func showIfDue(account: ManagedAIAccountModel, vm: StudioViewModel) {
        guard let daysLeft = account.freeDaysLeft,
              let freeUntil = account.appAccess?.freeUntil,
              let notice = due(daysLeft: daysLeft) else { return }
        let key = shownKey(notice, freeUntil: freeUntil)
        guard !Preferences.value(key) else { return }
        Preferences.set(true, for: key)
        let onceCents = account.planPrices.onceCents
        vm.showToast(
            message(daysLeft: daysLeft, onceCents: onceCents),
            action: StudioToastAction(title: EarlyUserDealOffer.buyTitle(onceCents: onceCents)) { _ in
                await account.choosePlan(.once)
            }
        )
    }
}

/// The dense account card Billing and AI Usage share: rows of title, detail
/// and controls, parted by full-width dividers.
struct BillingCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // The stack is load-bearing, as in `SettingsCard`: modifiers on a
        // multi-view `content` would otherwise paint a card per row.
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

/// Quiet title/detail/control rows, like the dense account rows in ChatGPT
/// and Codex.
struct BillingRow<Controls: View>: View {
    let title: String
    let detail: String
    /// A row that needs the learner's eye: the detail turns orange.
    let isWarning: Bool
    let controls: Controls

    init(title: String, detail: String, isWarning: Bool = false, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.detail = detail
        self.isWarning = isWarning
        self.controls = controls()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) { controls }
        }
    }
}

struct BillingRowDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, -16)
            .padding(.vertical, 14)
    }
}
