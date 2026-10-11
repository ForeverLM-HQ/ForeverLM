import SwiftUI
import AppKit
import AuthenticationServices

/// The account wall: ForeverLM requires Sign in with Apple before it can be used.
///
/// One Apple account is the app's identity everywhere — it is what managed AI meters usage
/// against and what MCP per-tool-call billing attributes calls to. Establishing it once at
/// launch keeps the rest of the app free of sign-in prompts.
///
/// There is deliberately no bypass — no "not now", no escape hatch. That is a real cost: a
/// Mac signed out of iCloud, or offline on first launch, cannot get past this screen.
/// `ManagedAI.hasAccountAccess` softens only the *renewal* case, so an established user is
/// never locked out of their own knowledge base by a lapsed token.
struct AppleAccountWall: View {
    /// Set while a lapsed session is being checked with the proxy. Shows a quiet progress
    /// line instead of the sign-in button, so a returning user whose session turns out to be
    /// fine doesn't see a sign-in prompt flash up and vanish.
    var isCheckingSession = false

    @Environment(ManagedAIAccountModel.self) private var account
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                // The mark either way, at one size, so the switch between the two
                // states changes only what the colour is doing and never makes
                // the logo jump or resize.
                //
                // While the session is being checked the mark carries the wait,
                // so the one thing on screen that is already the app's identity
                // is also the thing that shows it is working. Otherwise its
                // colour drifts — ambient, and the wall is a screen people sit
                // and look at.
                //
                // This used to be `AppIconImage.shared`, which is the mark on the
                // icon's opaque white tile. On the wall's own soft gradient that
                // read as a white card pasted onto the screen; the transparent
                // artwork sits on the wash instead of punching a hole in it.
                if isCheckingSession {
                    ForeverLMLoadingIndicator(width: 116)
                        .frame(height: 76)
                } else {
                    ForeverLMMark(width: 116, motion: .drifting)
                        .frame(height: 76)
                }

                // The title and Apple's button say everything the wall needs to;
                // the product owner cut the explanatory sentence under it as too wordy.
                Text("Sign in to \(ForeverLMRuntimeIdentity.displayName)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
            }

            VStack(spacing: 10) {
                if isCheckingSession {
                    // No spinner beside the label: the mark above is already the
                    // progress, and two indicators for one wait read as two waits.
                    Text("Checking your account…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(height: 44)
                } else {
                    ZStack {
                        Group {
                            if AppleSignInSupport.hasRequiredEntitlement {
                                SignInWithAppleButton(.continue) { request in
                                    request.requestedScopes = [.email]
                                } onCompletion: { result in
                                    account.completeSignIn(result)
                                }
                                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                            } else {
                                Button {
                                    Task { await account.signIn() }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text("")
                                            .font(.system(size: 21, weight: .medium))
                                        Text("Continue with Apple")
                                            .font(.system(size: 15, weight: .medium))
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(colorScheme == .dark ? .black : .white)
                                .background(colorScheme == .dark ? Color.white : Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                        }
                        .frame(height: 44)
                        .disabled(account.signInInFlight || !AppleSignInSupport.canSignIn)
                        .opacity(account.signInInFlight || !AppleSignInSupport.canSignIn ? 0.35 : 1)

                        if account.signInInFlight {
                            ProgressView().controlSize(.small)
                        }
                    }

                    // An ad-hoc Dev copy cannot be fixed from inside, but the signed
                    // one build_dev.sh installed usually exists a click away. Opening it
                    // here beats reading the path out of the message and typing it.
                    if let signedBuild = AppleSignInSupport.handoffDevelopmentBuildURL {
                        Button("Open the signed Dev build") {
                            openSignedDevelopmentBuild(at: signedBuild)
                        }
                        .controlSize(.large)
                    }

                    if let message = account.errorMessage ?? AppleSignInSupport.preflightMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.red.opacity(0.10))
                            )
                    }
                }
            }
        }
        .padding(36)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.12), radius: 24, y: 10)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            // A soft wash behind the card so the wall reads as a designed screen rather
            // than a dialog stranded on a blank window.
            LinearGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)
            .blur(radius: 40)
        }
    }

    /// Launches the installed signed copy and quits this one once it is up, so the
    /// two do not sit side by side arguing over the same knowledge.db.
    private func openSignedDevelopmentBuild(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// The pay screen (product owner, 2026-10-10; docs/pricing-pro-design.md → Day 8:
/// locked): once the free days are over and nothing is paid, it is the
/// only thing the Mac shows, after the sign-in wall and ahead of everything
/// else. The Early user deal, $19 once and nothing beside it, I've Paid to
/// ask the proxy again, Sign Out, and where the library lives, so "your
/// files, no lock-in" stays true. Nothing is deleted; paying restores the app
/// exactly as it was. While it is up, background AI, sync and the MCP
/// connection are stopped (`ManagedAI.isAppLocked`).
///
/// The price is the proxy's (`AppAccess.prices`), and the deal is offered
/// while it is on sale. The same quiet card on a soft wash as
/// `AppleAccountWall`.
struct AppLockWall: View {
    static let title = "Your free days are over"
    static let message = "Keep everything you've built: pay once and ForeverLM is yours to use."
    static let libraryLine = "Your library stays in your iCloud Drive (ForeverLM folder), as plain files you own."

    @Environment(ManagedAIAccountModel.self) private var account
    @Environment(\.colorScheme) private var colorScheme

    private var prices: ManagedAI.AppAccess.Prices { account.planPrices }
    private var onSale: [ManagedAI.AppPlan] { account.appAccess?.plansOnSale ?? ManagedAI.AppAccess.paidAppPlans }
    private var busy: Bool { account.planCheckoutInFlight != nil || account.paymentCheckInFlight }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                ForeverLMMark(width: 96, motion: .still)
                    .frame(height: 62)
                Text(Self.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(Self.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                if onSale.contains(.once) {
                    Button {
                        Task { await account.choosePlan(.once) }
                    } label: {
                        ZStack {
                            Text(EarlyUserDealOffer.buyTitle(onceCents: prices.onceCents))
                                .font(.headline)
                                .opacity(account.planCheckoutInFlight == .once ? 0 : 1)
                            if account.planCheckoutInFlight == .once {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                    .accessibilityIdentifier("appLock.buyOnce")
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task { await account.checkPayment() }
                } label: {
                    HStack(spacing: 6) {
                        if account.paymentCheckInFlight {
                            ProgressView().controlSize(.mini)
                        }
                        Text("I've Paid")
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("appLock.paid")

                Button("Sign Out") { account.signOut() }
                    .disabled(busy)
                    .accessibilityIdentifier("appLock.signOut")
            }
            .controlSize(.large)

            if account.paymentNotSeenYet {
                Text("Your payment hasn't reached ForeverLM yet. It can take a minute after checkout; try again shortly.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = account.errorMessage ?? account.balanceErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Label(Self.libraryLine, systemImage: "folder")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("appLock.library")
        }
        .padding(36)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.12), radius: 24, y: 10)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)
            .blur(radius: 40)
        }
        // Checkout finishes in the browser; coming back is when to look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await account.refresh(minimumInterval: 2, silently: true) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appLock.wall")
    }
}
