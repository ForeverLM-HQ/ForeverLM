import AppKit
import SwiftUI

/// The plans on sale (docs/managed-ai-billing.md → App plans), as the proxy
/// lists them. A plan is what lets the learner's own OpenRouter key run every
/// model. Since 2026-10-06: Believer first while the early-adopter offer is
/// open, recommended, at $19 a year that never goes up, and its free week
/// starts here with one click and no card; then Monthly at $4, which starts
/// with 30 free days when the account has never had a trial (2026-09-27:
/// "make it a 30 day free trial"; the product owner, 2026-09-26: "but people should
/// actually sign up"): the card is taken at Checkout, and the line under the
/// picker says how to get out before the trial ends.
struct AppPlanPicker: View {
    @Environment(ManagedAIAccountModel.self) private var account

    private var prices: ManagedAI.AppAccess.Prices { account.planPrices }
    private var access: ManagedAI.AppAccess? { account.appAccess }
    private var plans: [ManagedAI.AppPlan] { access?.plansOnSale ?? ManagedAI.AppAccess.plansSoldBeforeBeliever }

    /// The free days a plan starts with, if the account has never had a
    /// trial: Believer's week needs no card, Monthly's 30 days take one.
    private func trialDays(_ plan: ManagedAI.AppPlan) -> Int? {
        guard let access, access.trialAvailable else { return nil }
        switch plan {
        case .believer: return access.believerOffer?.trialDays
        case .monthly, .yearly: return access.trialDays
        case .forever: return nil
        }
    }

    /// Whether a plan here starts a trial that takes a card at checkout.
    private var cardTrialOffered: Bool {
        plans.contains { $0 != .believer && trialDays($0) != nil }
    }

    static func dollars(_ cents: Int) -> String {
        let value = Double(cents) / 100
        // Prices are set in US dollars, so they read the same everywhere.
        return value.formatted(
            .currency(code: "USD")
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(cents % 100 == 0 ? 0 : 2))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(plans) { plan in
                option(plan)
            }
            if cardTrialOffered {
                Text("Monthly's free days start at checkout, where you add a card. Cancel before they end, here or at foreverlm.com/account/billing, and you pay nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("billing.plan.trialNote")
            }
        }
    }

    private func option(_ plan: ManagedAI.AppPlan) -> some View {
        let isRecommended = plan == access?.recommendedPlan
        return Button {
            Task {
                if plan == .believer, access?.believerTrialAvailable == true {
                    await account.startBelieverTrial()
                } else {
                    await account.choosePlan(plan)
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title(plan))
                            .font(.subheadline.weight(.semibold))
                        if isRecommended { RecommendedBadge() }
                    }
                    Text(detail(plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 12)
                if account.planCheckoutInFlight == plan {
                    ProgressView().controlSize(.small)
                } else {
                    Text(price(plan))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isRecommended ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.055)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 10, inset: 0))
        .disabled(account.planCheckoutInFlight != nil)
    }

    private func title(_ plan: ManagedAI.AppPlan) -> String {
        switch plan {
        case .believer: return "Believer"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .forever: return "Lifetime"
        }
    }

    private func price(_ plan: ManagedAI.AppPlan) -> String {
        switch plan {
        case .believer: return "\(Self.dollars(prices.believerCents))/yr"
        case .monthly: return "\(Self.dollars(prices.monthlyCents))/mo"
        case .yearly: return "\(Self.dollars(prices.yearlyCents))/yr"
        case .forever: return Self.dollars(prices.foreverCents)
        }
    }

    private func detail(_ plan: ManagedAI.AppPlan) -> String {
        let trial = trialDays(plan).map { "First \($0) days free, then " } ?? ""
        switch plan {
        case .believer:
            let price = Self.dollars(prices.believerCents)
            return trialDays(.believer).map {
                "\($0) days free, no card needed. Then \(price) a year, a price that never goes up."
            } ?? "\(price) a year, a price that never goes up. For early believers."
        case .monthly: return trial.isEmpty ? "Cancel anytime." : "\(trial)\(Self.dollars(prices.monthlyCents)) a month. Cancel anytime."
        case .yearly: return trial.isEmpty ? "Two months free." : "\(trial)\(Self.dollars(prices.yearlyCents)) a year. Two months free."
        case .forever: return "Pay once, keep it for good."
        }
    }
}

/// Settings → Billing: the ForeverLM plan and nothing else. The product owner
/// (2026-09-28): "there should be a place where people can cancel their
/// subscription or manage their subscription … separate from all the AI
/// usage". The key, Free mode, limits and activity are Settings › AI Usage.
/// Without a plan the pane is the picker. With one it is a single card: which
/// plan and what happens next, then paying, switching and cancelling, one row
/// each, so cancelling is never a search.
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
        if access.state == .free {
            SettingsSection(title: "Choose a plan", description: freeSummary(access)) {
                AppPlanPicker()
            }
        } else {
            SettingsSection(title: "Plan") {
                BillingCard {
                    if access.state == .subscribed, access.paymentFailed {
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

                    // The free week has nothing at Stripe to cancel: it ends by
                    // itself. Keeping Believer is its $19 checkout.
                    if access.state == .believerTrial {
                        BillingRowDivider()
                        BillingRow(
                            title: "Keep Believer",
                            detail: "\(AppPlanPicker.dollars(access.prices.believerCents)) a year, a price that never goes up"
                        ) {
                            if account.planCheckoutInFlight == .believer {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Keep Believer") { Task { await account.choosePlan(.believer) } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(account.planCheckoutInFlight != nil)
                                    .accessibilityIdentifier("billing.plan.keepBeliever")
                            }
                        }
                    }

                    if access.state == .subscribed {
                        BillingRowDivider()
                        cancelRow(access)
                    }
                }
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

    private func freeSummary(_ access: ManagedAI.AppAccess) -> String {
        "A plan lets your own OpenRouter key run ForeverLM's AI features, every model included."
    }

    private func planTitle(_ access: ManagedAI.AppAccess) -> String {
        switch access.state {
        case .free: return "No plan"
        case .subscribed:
            switch access.appPlan {
            case .believer: return "Believer plan"
            case .yearly: return "Yearly plan"
            case .monthly: return "Monthly plan"
            case .forever, nil: return "Plan"
            }
        case .believerTrial: return "Believer plan"
        case .forever: return "Lifetime plan"
        case .comped: return "Plan"
        case .family: return "Family plan"
        }
    }

    private func planDetail(_ access: ManagedAI.AppAccess) -> String {
        switch access.state {
        case .free:
            return "Choose a plan to run AI features on your key"
        case .believerTrial:
            let keep = "Keep it for \(AppPlanPicker.dollars(access.prices.believerCents)) a year, a price that never goes up."
            guard let endsAt = access.trialEndsAt else { return "Free week. \(keep)" }
            return "Free until \(endsAt.formatted(date: .abbreviated, time: .omitted)), no card needed. \(keep)"
        case .subscribed:
            guard let renewsAt = access.renewsAt else {
                return access.trialing ? "Free trial" : "Renews automatically"
            }
            let date = renewsAt.formatted(date: .abbreviated, time: .omitted)
            if access.trialing {
                if access.cancelAtPeriodEnd { return "Free until \(date), then over. Nothing will be charged." }
                return price(access).map { "Free until \(date), then \($0)" } ?? "Free until \(date)"
            }
            if access.cancelAtPeriodEnd { return "Ends \(date) and won't renew" }
            return access.isBeliever ? "Renews \(date). Your price never goes up." : "Renews \(date)"
        case .forever:
            return access.founding
                ? "You were here before plans existed, so it's yours for good"
                : "Paid once, never renews"
        case .comped:
            return "Included with your account"
        case .family:
            return "Covered by your family's plan"
        }
    }

    /// What the plan costs, beside its name: what the subscription charges,
    /// which is the price it started at. A lifetime plan was paid once.
    private func price(_ access: ManagedAI.AppAccess) -> String? {
        guard let cents = access.subscriptionPriceCents else { return nil }
        switch access.appPlan {
        case .believer, .yearly: return "\(AppPlanPicker.dollars(cents))/yr"
        case .monthly: return "\(AppPlanPicker.dollars(cents))/mo"
        case .forever, nil: return nil
        }
    }

    /// Whether there is a Stripe customer to open: the proxy refuses the page
    /// (`no_purchases`) for an account that has never paid, which a founding
    /// lifetime, a comped or a family account has not.
    private func paysThroughStripe(_ access: ManagedAI.AppAccess) -> Bool {
        switch access.state {
        case .subscribed: return true
        case .forever: return !access.founding
        case .free, .comped, .family, .believerTrial: return false
        }
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
    let controls: Controls

    init(title: String, detail: String, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.detail = detail
        self.controls = controls()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
/// to the end of what is paid for, or of the free trial, which is then never
/// charged.
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
        return access.isBeliever ? "\(stays) Its \(AppPlanPicker.dollars(access.subscriptionPriceCents ?? access.prices.believerCents)) believer price ends with it." : stays
    }
}
