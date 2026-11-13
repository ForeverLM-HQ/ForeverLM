import AuthenticationServices
import SwiftUI

// Sign in with Apple, mirroring the Mac's identity-token exchange against the
// proxy. The proxy needs only Apple's stable app-specific subject, so the phone
// requests no personal scopes such as name or email.
//
// The native button is deliberately the iOS path. The other Mac entry point
// (`AppleIdentityToken.request()`) drives an ASAuthorizationController directly
// and needs a presentation anchor, and its `presentationAnchor(for:)` returns an
// empty `ASPresentationAnchor` on anything but AppKit. `SignInWithAppleButton`
// needs no anchor at all.
struct MobileSignInGate: View {
    var onSignedIn: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var isExchanging = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = []
            } onCompletion: { result in
                complete(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 44)
            .disabled(isExchanging || !AppleSignInSupport.hasRequiredEntitlement)

            if isExchanging {
                ProgressView()
                    .controlSize(.small)
            }

            if let errorMessage = errorMessage ?? AppleSignInSupport.preflightMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor
    private func complete(_ result: Result<ASAuthorization, Error>) {
        if let message = AppleSignInSupport.preflightMessage {
            errorMessage = message
            return
        }

        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let token = String(data: data, encoding: .utf8) else {
                errorMessage = "Apple didn't return an identity token. Try again."
                return
            }
            exchange(identityToken: token)
        case .failure(let error):
            errorMessage = AppleSignInSupport.userMessage(for: error)
        }
    }

    @MainActor
    private func exchange(identityToken: String) {
        guard !isExchanging else { return }
        isExchanging = true
        errorMessage = nil

        Task {
            defer { isExchanging = false }
            do {
                // `signIn` is nonisolated async, so the keychain writes and the
                // network round trip leave the main actor on their own.
                _ = try await ManagedAI.signIn(identityToken: identityToken)
                onSignedIn()
            } catch let error as ManagedAI.ServiceError {
                // The proxy's message is already user-facing and is the authoritative
                // failure on the single managed-AI rail.
                errorMessage = error.message
            } catch {
                errorMessage = "Couldn’t reach ForeverLM. Check your connection and try again."
            }
        }
    }
}

/// Launch-gate state for the phone: Sign in with Apple is required before the app
/// shows anything else, the same rule the Mac enforces with `AppleAccountWall`.
///
/// Mirrors the gate slice of `ManagedAIAccountModel`, with one phone-specific
/// difference: the Mac reads the Keychain synchronously in its init, and on the
/// phone that read must never happen on the main actor (see
/// `MobileAudioReviewViewModel.init`). So `hasAccountAccess` starts nil — an
/// icon-and-spinner beat — until the first off-main read answers.
@MainActor
@Observable
final class MobileAccountGateModel {
    /// nil until the first Keychain read answers; then `ManagedAI.hasAccountAccess`,
    /// refined by proxy validation.
    private(set) var hasAccountAccess: Bool?

    /// True while a locally-lapsed session is being checked with the proxy. The
    /// wall holds with a quiet "checking" line for the duration, so a returning
    /// user whose session turns out fine never sees a sign-in button flash, and
    /// the app never opens on a grace window that is covering a revoked token.
    private(set) var isValidatingLapsedSession = false

    @ObservationIgnored private var lastValidationAt: Date?
    @ObservationIgnored private var validationRunning = false

    var showsWall: Bool { hasAccountAccess != true || isValidatingLapsedSession }
    var isResolving: Bool { hasAccountAccess == nil }

    /// Answers the gate locally, then asks the proxy whether the stored session is
    /// still real. Only a definitive `invalid_session` re-walls; a network failure
    /// leaves the local answer standing — that is what `ManagedAI.accountGracePeriod`
    /// exists for, and an offline phone must not read as signed out.
    func validateStoredSession(minimumInterval: TimeInterval = 0) async {
        let local = await Task.detached(priority: .userInitiated) {
            (access: ManagedAI.hasAccountAccess,
             live: ManagedAI.isSignedIn,
             hasToken: ManagedAI.sessionToken != nil,
             needsRenewal: ManagedAI.sessionNeedsRenewal)
        }.value
        hasAccountAccess = local.access

        // No token at all — the gate already says so, and there is nothing to ask about.
        guard local.hasToken else { return }
        if let lastValidationAt, Date().timeIntervalSince(lastValidationAt) < minimumInterval {
            return
        }
        guard !validationRunning else { return }
        validationRunning = true
        isValidatingLapsedSession = !local.live
        defer {
            validationRunning = false
            isValidatingLapsedSession = false
        }

        do {
            // The cheapest authenticated endpoint; the home screen loads the
            // balance it actually displays separately.
            _ = try await ManagedAI.balance()
            hasAccountAccess = true
            lastValidationAt = Date()
        } catch let error as ManagedAI.ServiceError where error.isInvalidSession {
            // The transport already dropped the token; mirror that here so the
            // wall comes back on this launch rather than at the next voice start.
            hasAccountAccess = false
            lastValidationAt = Date()
            return
        } catch {
            // Offline, or the proxy is unhappy for some other reason. This runs
            // unprompted at launch, so it has no business surfacing an error.
            return
        }

        // The session just proved live; slide it forward once it is into its
        // second half, so a phone that is opened at all never hits the day-30
        // wall. Same schedule as the Mac's `ManagedAIAccountModel`.
        guard local.needsRenewal else { return }
        do {
            try await ManagedAI.renewSession()
        } catch let error as ManagedAI.ServiceError where error.isInvalidSession {
            hasAccountAccess = false
        } catch {
            // The current session is still good; the next launch asks again.
        }
    }

    /// A wall sign-in just completed — `ManagedAI.signIn` stored the session.
    func didSignIn() {
        hasAccountAccess = true
        lastValidationAt = Date()
    }

    /// Account deletion clears the proxy session before this is called. Publish
    /// the gate change immediately so the app cannot remain open on stale state.
    func didDeleteAccount() {
        hasAccountAccess = false
        lastValidationAt = Date()
    }

    /// Settings › Account › Sign Out: the session leaves this phone and the
    /// wall comes back; the account, its usage and the iCloud library stay, and
    /// Sign in with Apple returns to the same account. Voice ends first, since
    /// it runs on the session.
    func signOut() async {
        await MobileRealtimeVoice.controller.end()
        await Task.detached(priority: .userInitiated) { ManagedAI.clearSession() }.value
        hasAccountAccess = false
        lastValidationAt = Date()
    }
}

/// Full-screen account wall shown before anything else, like the Mac's
/// `AppleAccountWall`: no "not now", no escape hatch. `MobileAccountGateModel`
/// softens only the renewal case, so an established user offline on the day
/// their token lapses is never locked out.
struct MobileAccountWall: View {
    let isResolving: Bool
    let isCheckingSession: Bool
    var onSignedIn: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.xLarge) {
            // The brand mark itself: `ForeverLMMark` is the shipped artwork.
            //
            // Drifting, not still: the colour wanders inside the loops while the
            // shape holds. It is ambient rather than a progress signal — the
            // wall is the one screen a user sits and looks at, and the mark is
            // the only thing on it. Reduce Motion stops it.
            ForeverLMMark(width: 176, motion: .drifting)
                .accessibilityHidden(true)

            if isResolving {
                // First Keychain read still in flight (a frame or two). Neither
                // flash a sign-in button at a signed-in user nor the app at a
                // signed-out one.
                ProgressView()
            } else {
                Text("Sign in to ForeverLM")
                    .font(.title.bold())
                    .accessibilityIdentifier("account.wall.title")

                if isCheckingSession {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking your account…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 44)
                } else {
                    MobileSignInGate(onSignedIn: onSignedIn)
                        .frame(maxWidth: 320)

                    // Said before anything else: the phone alone has no
                    // library. A Mac adds the sources and prepares their
                    // text (product owner, 2026-11-13: "Please just say that
                    // it needs the Mac").
                    Text("ForeverLM on the iPhone works with ForeverLM on your Mac. The Mac adds your sources; you read, listen, talk and review them here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("account.wall.needsMac")
                }
            }
        }
        .padding(MobileDesign.Spacing.xxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            // Same soft wash as the Mac wall, so the screen reads as designed
            // rather than a stranded dialog.
            LinearGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)
            .blur(radius: 40)
            .ignoresSafeArea()
        }
    }
}

/// Inline sign-in card for surfaces that discover mid-flow that there is no
/// session — the reading chat, mainly.
struct MobileSignInPrompt: View {
    var onSignedIn: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 32))
                .foregroundStyle(.tint)

            Text("Signing in with Apple is how ForeverLM pays for and meters the AI you use.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            MobileSignInGate(onSignedIn: onSignedIn)
                .frame(maxWidth: 320)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}
