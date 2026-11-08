import AppKit
import SwiftUI

/// What ForeverLM sells (product owner, 2026-10-10; docs/pricing-pro-design.md
/// → How it is sold): the Early user deal, $19 paid once, which unlocks MCP,
/// and nothing beside it. The app and its AI are free (product owner,
/// 2026-10-16: "make the MCP paywalled; for the rest people should be able to
/// use the app for free using openrouter"). There is no monthly plan ("I personally don't like monthly
/// subscriptions!!"), so nothing here shows a monthly price or compares the
/// deal with one. The price is the proxy's (`AppAccess.prices`), never this
/// build's, and the deal is offered only while `plans_on_sale` lists it. Mac
/// only: the iPhone and iPad app never shows a price or a way to buy.
struct EarlyUserDealOffer: View {
    @Environment(ManagedAIAccountModel.self) private var account

    static let title = "Early user deal"
    static let terms = "Unlocks MCP. Paid once, no subscription"
    /// What Billing's section says once the free days are over and nothing is
    /// paid.
    static let lockedTitle = "MCP is locked"
    /// What Billing says while nothing is sold (2026-11-08: MCP is free).
    static let freeTitle = "MCP is free"
    /// What the welcome screen says while nothing is sold.
    static let freeWelcomeLine = "ForeverLM is free, MCP included."
    /// The line every surface says what AI costs with.
    static let ownKeyLine = "The app is free. AI runs on your OpenRouter API key, at OpenRouter's cost. ForeverLM adds nothing."

    /// "Get the Early User Deal: $19", or without the price while the proxy
    /// has not said it.
    static func buyTitle(onceCents: Int?) -> String {
        onceCents.map { "Get the Early User Deal: \(ManagedAI.dollars($0))" } ?? "Get the Early User Deal"
    }

    /// "MCP: 7 days free, then $19 once. No subscription." The count of free
    /// days is the proxy's (`AppAccess.freeDaysTotal`), like the price; a part
    /// the proxy has not said is left unnamed rather than guessed.
    static func headline(onceCents: Int?, freeDays: Int?) -> String {
        let start = freeDays.map { "\($0) days free" } ?? "Free to start"
        let price = onceCents.map { "\(ManagedAI.dollars($0)) once" } ?? "pay once"
        return "MCP: \(start), then \(price). No subscription."
    }

    /// What the welcome screen says once: the app is free, and what is not.
    static func welcomeLine(onceCents: Int?, freeDays: Int?) -> String {
        "The app is free. \(headline(onceCents: onceCents, freeDays: freeDays))"
    }

    /// The welcome line for an account's access: the price only while the
    /// account server sells the deal, and "free, MCP included" otherwise,
    /// before the access is known too, since nothing is sold now.
    static func welcomeLine(access: ManagedAI.AppAccess?) -> String {
        guard let access, access.state != .free, access.plansOnSale.contains(.once) else { return freeWelcomeLine }
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

/// Settings → Billing: paying for ForeverLM, in one card. The product owner
/// (2026-09-28): "there should be a place where people can cancel their
/// subscription or manage their subscription … separate from all the AI
/// usage". The key, limits and activity are AI Usage.
///
/// While MCP is free (2026-11-08) the section says so and offers nothing.
/// In MCP's free days, or locked, the card is the offer. A buyer sees "Paid
/// once". A subscriber from before the lock (nothing sells a subscription
/// now) sees the plan, Switch to Paid Once, and paying and cancelling, one
/// row each, so cancelling is never a search. A comped account sees
/// "Included with your account".
struct AppPlanSettingsSection: View {
    @Environment(ManagedAIAccountModel.self) private var account
    @State private var isCancelling = false

    var body: some View {
        Group {
            if let access = account.appAccess {
                planContent(access)
                    .sheet(isPresented: $isCancelling) {
                        CancelPlanSheet(access: access)
                    }
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
            SettingsSection(title: "MCP", description: offerSummary(access)) {
                VStack(alignment: .leading, spacing: 10) {
                    EarlyUserDealOffer()
                    Text(EarlyUserDealOffer.ownKeyLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .paidOnce, .monthly, .comped, .family:
            SettingsSection(title: "Plan") {
                planCard(access)
            }
        }
    }

    @ViewBuilder
    private func planCard(_ access: ManagedAI.AppAccess) -> some View {
        BillingCard {
            if access.state == .monthly, access.paymentFailed {
                HStack(spacing: 20) {
                    Label("Your last payment didn't go through. Update your card to keep your plan.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Update Card") { Task { await account.openBillingHistory() } }
                        .buttonStyle(.borderedProminent)
                }
                BillingRowDivider()
            }

            BillingRow(title: planTitle(access), detail: planDetail(access)) {
                if let price = price(access) {
                    Text(price)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            // A group of its own, so the identifier stays on the row
            // rather than stamping both texts.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("billing.subscription.status")

            if paysThroughStripe(access) {
                BillingRowDivider()
                BillingRow(
                    title: "Payment method and invoices",
                    detail: "Change your card or download receipts, in Stripe"
                ) {
                    Button("Open") { Task { await account.openBillingHistory() } }
                        .buttonStyle(.bordered)
                }
            }

            // A subscriber who pays once has the subscription cancelled by the
            // proxy when the payment lands.
            if access.state == .monthly, access.plansOnSale.contains(.once) {
                BillingRowDivider()
                BillingRow(title: "Switch to Paid Once", detail: switchDetail(access)) {
                    if account.planCheckoutInFlight == .once {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Switch to Paid Once") { Task { await account.choosePlan(.once) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(account.planCheckoutInFlight != nil)
                            .accessibilityIdentifier("billing.plan.switchToOnce")
                    }
                }
            }

            if access.state == .monthly {
                BillingRowDivider()
                cancelRow(access)
            }
        }
    }

    @ViewBuilder
    private func cancelRow(_ access: ManagedAI.AppAccess) -> some View {
        let date = access.renewsAt?.formatted(date: .abbreviated, time: .omitted)
        if access.cancelAtPeriodEnd {
            BillingRow(
                title: "Keep your plan",
                detail: access.trialing
                    ? (date.map { "Its first payment is then on \($0)" } ?? "It carries on after the free trial")
                    : (date.map { "It renews on \($0) as before" } ?? "It renews as before")
            ) {
                Button("Keep My Plan") { Task { await account.resumePlan() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.planChangeInFlight)
                    .accessibilityIdentifier("billing.plan.resume")
            }
        } else {
            BillingRow(
                title: "Cancel plan",
                detail: access.trialing
                    ? (date.map { "Cancel before \($0) and nothing is charged" } ?? "Nothing is charged during the free trial")
                    : (date.map { "You keep it until \($0)" } ?? "You keep it until the end of what you've paid for")
            ) {
                Button("Cancel Plan…", role: .destructive) { isCancelling = true }
                    .buttonStyle(.bordered)
                    .disabled(account.planChangeInFlight)
                    .accessibilityIdentifier("billing.plan.cancel")
            }
        }
    }

    /// Above the offer: how many of the free days are left, or that MCP is
    /// locked.
    private func offerSummary(_ access: ManagedAI.AppAccess) -> String {
        if let status = account.freeDaysStatus { return status }
        if account.isMCPLocked { return EarlyUserDealOffer.lockedTitle }
        return EarlyUserDealOffer.headline(onceCents: access.prices.onceCents, freeDays: access.freeDaysTotal)
    }

    private func switchDetail(_ access: ManagedAI.AppAccess) -> String {
        let price = access.prices.onceCents.map { "\(ManagedAI.dollars($0)) once, no subscription" } ?? "Paid once, no subscription"
        return "\(price). Your subscription stops when you pay"
    }

    private func planTitle(_ access: ManagedAI.AppAccess) -> String {
        switch access.state {
        case .paidOnce: return "Paid once"
        case .monthly: return "\(access.planName) plan"
        case .comped: return "Plan"
        case .family: return "Family plan"
        case .free, .freeDays, .locked: return "Plan"
        }
    }

    private func planDetail(_ access: ManagedAI.AppAccess) -> String {
        switch access.state {
        case .paidOnce:
            return access.founding
                ? "Granted to early users. No subscription"
                : "MCP is unlocked. No subscription"
        case .monthly:
            guard let renewsAt = access.renewsAt else {
                return access.trialing ? "Free trial" : "Renews automatically"
            }
            let date = renewsAt.formatted(date: .abbreviated, time: .omitted)
            if access.trialing {
                if access.cancelAtPeriodEnd { return "Free until \(date), then over. Nothing will be charged." }
                return price(access).map { "Free until \(date), then \($0)" } ?? "Free until \(date)"
            }
            if access.cancelAtPeriodEnd { return "Ends \(date) and won't renew" }
            return access.plan == "believer" ? "Renews \(date). Your price never goes up." : "Renews \(date)"
        case .comped:
            return "Included with your account"
        case .family:
            return "Covered by your family's plan"
        case .free, .freeDays, .locked:
            return ""
        }
    }

    /// What the subscription charges, beside its name: the price it started
    /// at. Paid once has nothing more to charge.
    private func price(_ access: ManagedAI.AppAccess) -> String? {
        guard let cents = access.subscriptionPriceCents else { return nil }
        return "\(ManagedAI.dollars(cents))/\(access.renewsYearly ? "yr" : "mo")"
    }

    /// Whether there is a Stripe customer to open: the proxy refuses the page
    /// (`no_purchases`) for an account that has never paid, which a founding
    /// grant, a comped or a family account has not.
    private func paysThroughStripe(_ access: ManagedAI.AppAccess) -> Bool {
        switch access.state {
        case .monthly: return true
        case .paidOnce: return !access.founding
        case .free, .freeDays, .locked, .comped, .family: return false
        }
    }
}

/// The free days' two notices (docs/pricing-pro-design.md → The free days):
/// one two days before the end and one on the last day, each shown once, each
/// offering the deal, so MCP never locks as a surprise. They count
/// from the end, so they fall on days 5 and 7 of the 7. They ride the
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

    /// "MCP free: 2 days left. Keep your assistants connected with the Early
    /// user deal, $19 paid once, no subscription."
    static func message(daysLeft: Int, onceCents: Int?) -> String {
        let deal = onceCents.map { "the Early user deal, \(ManagedAI.dollars($0)) paid once" } ?? "the Early user deal, paid once"
        return "\(ManagedAI.AppAccess.freeDaysStatus(daysLeft: daysLeft)). Keep your assistants connected with \(deal), no subscription."
    }

    private static func shownKey(_ notice: Notice, freeUntil: Date) -> String {
        "freeDaysNotice.\(notice.rawValue).\(Int(freeUntil.timeIntervalSince1970))"
    }

    /// Shows the notice that is due, once. Device-local: a notice seen on
    /// one Mac is not owed to another.
    static func showIfDue(account: ManagedAIAccountModel, vm: StudioViewModel) {
        guard let daysLeft = account.freeDaysLeft,
              let freeUntil = account.appAccess?.freeUntil,
              let notice = due(daysLeft: daysLeft) else { return }
        let key = shownKey(notice, freeUntil: freeUntil)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
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

/// Cancelling asks why, and both answers are optional (product owner, 2026-09-26:
/// "if they cancel, they should be able to let us know why"). The plan runs
/// to the end of what is paid for; a subscription still in its free trial is
/// never charged.
struct CancelPlanSheet: View {
    let access: ManagedAI.AppAccess

    @Environment(ManagedAIAccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ManagedAI.PlanCancellationReason?
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cancel your plan")
                .font(.title2.weight(.semibold))
            Text(lede)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Would you tell us why? Both questions are optional.")
                .font(.subheadline.weight(.medium))
                .padding(.top, 4)
            Picker("Reason", selection: $reason) {
                ForEach(ManagedAI.PlanCancellationReason.allCases) { reason in
                    Text(reason.title).tag(Optional(reason))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityIdentifier("billing.plan.cancelReason")

            VStack(alignment: .leading, spacing: 6) {
                Text("Anything you'd like us to know?")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $comment)
                    .font(.body)
                    .frame(minHeight: 64, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if comment.isEmpty {
                            Text("What would have made you stay?")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("billing.plan.cancelComment")
            }

            HStack {
                if account.planChangeInFlight {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Keep My Plan") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Cancel Plan", role: .destructive) {
                    Task {
                        if await account.cancelPlan(reason: reason, comment: comment) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("billing.plan.cancelConfirm")
            }
            .disabled(account.planChangeInFlight)

            if let message = account.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var lede: String {
        let until = access.renewsAt?.formatted(date: .abbreviated, time: .omitted)
        if access.trialing {
            return until.map { "Your free trial still runs until \($0), and nothing will be charged." }
                ?? "Nothing will be charged."
        }
        let stays = until.map { "Your plan stays until \($0), the end of the period you have paid for." }
            ?? "Your plan stays until the end of the period you have paid for."
        // The believer price is for those who keep it; it may not be on offer
        // again.
        guard access.plan == "believer", let cents = access.subscriptionPriceCents else { return stays }
        return "\(stays) Its \(ManagedAI.dollars(cents)) believer price ends with it."
    }
}
