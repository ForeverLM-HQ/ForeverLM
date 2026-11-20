import Foundation
import OSLog
#if canImport(AppKit)
import AppKit
import Security
#endif
import AuthenticationServices

/// UI-facing state for the managed AI rail ("ForeverLM AI"): sign-in, the paid
/// app's access (the free days, payment, the lock),
/// the own OpenRouter key, any leftover balance, and billing history. `@MainActor @Observable`, with in-flight
/// flags and no `throws` out of its methods; failures land in `errorMessage` as a
/// full user-facing sentence.
///
/// Deliberately holds no fallback behavior: if a managed call fails, the server's
/// own message is shown and nothing silently switches rails.
@MainActor
@Observable
final class ManagedAIAccountModel {

    private(set) var balance: ManagedAI.Balance? {
        didSet {
            // Every balance fetch carries the plan too, and every sign-out
            // clears both, so the plan follows whatever the balance just did.
            appAccess = ManagedAI.appAccess
            // Screen record mode is admin only, and this is the one place the
            // proxy's answer arrives. A nil balance (a transient failure, a
            // locally lapsed session) leaves the last answer standing, so a
            // network blip mid-take does not drop the scope; sign-out and a
            // rejected session clear it below.
            if let balance { ScreenRecordMode.recordAdminStatus(balance.isAdmin) }
            // A refusal because the account was closed is the one action error
            // the balance can disprove. Once it reads the account open again the
            // sentence is stale: a metering failure that closes an account for a
            // while would leave Settings saying "disabled" after it reopens.
            if errorIsAccountDisabled, balance?.disabled == false { errorMessage = nil }
        }
    }

    /// The paid app's access: the free days, paid once, monthly (bought
    /// before the lock), comped, family or locked. Nil until a worker that reports plans has answered.
    /// See `ManagedAI.AppAccess`.
    private(set) var appAccess: ManagedAI.AppAccess? = ManagedAI.appAccess {
        didSet {
            guard appAccess != oldValue else { return }
            scheduleFreeDaysTick()
        }
    }
    /// The plan whose checkout is being opened, so only its button spins.
    private(set) var planCheckoutInFlight: ManagedAI.AppPlan?
    /// Reads the account again every few seconds after checkout opens, while
    /// the app is locked, so the pay screen opens the app by itself once
    /// Stripe's webhook lands (product owner, 2026-10-13: no "I've Paid").
    @ObservationIgnored private var paymentWatch: Task<Void, Never>?

    /// Moves when the free days cross a day, or end, while the app is open,
    /// so the account menu's count and the lock are read again.
    private(set) var freeDaysClock = 0
    @ObservationIgnored private var freeDaysTick: Task<Void, Never>?

    /// Whether the learner's own router key may pay for requests: for any
    /// account that is not locked (`ManagedAI.ownKeyAllowed`).
    var ownKeyAllowed: Bool { !isAppLocked }
    /// What the app costs, as the proxy last reported it.
    var planPrices: ManagedAI.AppAccess.Prices { appAccess?.prices ?? .unknown }

    /// Whether the app is locked: the free days are over and nothing is paid
    /// (`ManagedAI.isAppLocked`). The Mac then shows only `AppLockWall`.
    var isAppLocked: Bool {
        _ = freeDaysClock
        return appAccess?.isLocked(at: ManagedAI.serverNow) ?? false
    }

    /// Whole free days left after today, while the free days run. Nil
    /// otherwise.
    var freeDaysLeft: Int? {
        _ = freeDaysClock
        return appAccess?.freeDaysLeft(at: ManagedAI.serverNow)
    }

    /// The account menu's quiet line: "29 days free left".
    var freeDaysStatus: String? {
        freeDaysLeft.map(ManagedAI.AppAccess.freeDaysStatus(daysLeft:))
    }
    /// Whether AI work has nothing to run on: no own key stored (ForeverLM pays
    /// for no AI). Ambient UI shows it as the "add your key" prompt.
    var creditsAreEmpty: Bool { !isLoadingStoredSession && ownKey == nil }

    /// The learner's own router key, mirrored for the Billing pane. Loaded with
    /// the stored session, off the main actor, and kept current by the two
    /// writers below.
    private(set) var ownKey: ManagedAI.OwnKey?

    /// Whether the proxy recognises this account as an operator that may add
    /// balance without paying. Absent until a balance load succeeds, so the
    /// control appears only once the server has actually said so.
    var isAdmin: Bool { balance?.isAdmin == true }
    /// Starts closed until the stored credential snapshot has been read off-main.
    /// Keychain reads can synchronously contact `securityd`; doing them from a
    /// main-actor property initializer produced launch-time responsiveness warnings.
    private(set) var isSignedIn = false

    /// Whether an Apple account is attached to this Mac — what the launch gate in
    /// `ContentView` asks. Tolerates a lapsed session for `ManagedAI.accountGracePeriod`,
    /// unlike `isSignedIn`, which asks the stricter "will the proxy accept this token?".
    /// See `ManagedAI.hasAccountAccess` for why the two differ.
    private(set) var hasAccountAccess = false
    private(set) var isLoadingStoredSession = true
    var signInInFlight = false
    var refreshInFlight = false
    var errorMessage: String? {
        didSet { errorIsAccountDisabled = false }
    }
    /// Whether `errorMessage` is the proxy's `account_disabled` refusal, which
    /// the next balance read clears once the account is open again. Set only by
    /// `show(_:)`; any other write to `errorMessage` resets it.
    @ObservationIgnored private var errorIsAccountDisabled = false
    /// A balance load failure is owned separately from sign-in and billing
    /// actions. A later successful refresh can clear this without erasing a
    /// checkout, portal, or account error the learner still needs to see.
    private(set) var balanceErrorMessage: String?
    @ObservationIgnored private var lastBalanceRefreshAt: Date?
    @ObservationIgnored private var balanceRequest: Task<ManagedAI.Balance, Error>?
    @ObservationIgnored private var lastValidationAt: Date?
    @ObservationIgnored private var validationRunning = false

    /// True while a session that is *locally* past its expiry is being checked with the proxy.
    ///
    /// The app stays walled for the duration. `hasAccountAccess` would open it on the strength
    /// of the grace window alone, which means opening on a session that may already have been
    /// revoked — the user would get a second of Studio and then be thrown back to the wall.
    /// Holding the wall until the answer arrives makes the lapsed case honest: either the proxy
    /// confirms the session and the app opens, or it doesn't and the user signs in.
    ///
    /// Only ever set for a lapsed session. A locally-valid one opens immediately and revalidates
    /// in the background, so the common launch is not gated on the network.
    private(set) var isValidatingLapsedSession = false


    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ManagedAI")

    /// Shows the proxy's refusal, noting whether it is the closed-account one.
    private func show(_ error: ManagedAI.ServiceError) {
        errorMessage = error.message
        errorIsAccountDisabled = error.isAccountDisabled
    }

    // MARK: - Sign in

    /// Hydrates the launch gate without performing Keychain I/O on the main actor.
    /// The vault is cached by `KeychainService`, so this also primes later UI reads.
    func loadStoredSession() async {
        guard isLoadingStoredSession else { return }
        let snapshot = await Task.detached(priority: .userInitiated) {
            (
                isSignedIn: ManagedAI.isSignedIn,
                hasAccountAccess: ManagedAI.hasAccountAccess,
                ownKey: ManagedAI.ownKey
            )
        }.value
        isSignedIn = snapshot.isSignedIn
        hasAccountAccess = snapshot.hasAccountAccess
        ownKey = snapshot.ownKey
        isLoadingStoredSession = false
        // The access cached from the last launch may hold free days that
        // run out while this one is open.
        scheduleFreeDaysTick()
    }

    // MARK: - Your own router key

    /// Stores the learner's own OpenRouter key, or removes it
    /// when `key` is empty. The Keychain write happens off the main actor; the
    /// balance's emptiness is then re-read, because with a key an empty balance
    /// no longer gates chat, and the balance is refreshed so the pane's detail
    /// line says who pays.
    ///
    /// A new key is checked with its router first and stored only if the
    /// router accepts it; otherwise `errorMessage` says why and nothing
    /// changes. Returns whether the key (or its removal) was stored.
    @discardableResult
    func setOwnKey(_ key: String, router: ManagedAI.OwnKeyRouter) async -> Bool {
        errorMessage = nil
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            do {
                if case .rejected(let reason) = try await ManagedAI.checkOwnKey(trimmed, router: router) {
                    errorMessage = reason
                    return false
                }
            } catch {
                errorMessage = "Couldn't check the key with \(router.label): \(error.localizedDescription)"
                return false
            }
        }
        let stored = await Task.detached(priority: .userInitiated) {
            ManagedAI.setOwnKey(key, router: router)
            return ManagedAI.ownKey
        }.value
        ownKey = stored
        await refresh(silently: true)
        return true
    }

    func removeOwnKey() async {
        guard let router = ownKey?.router else { return }
        await setOwnKey("", router: router)
    }

    /// Re-reads the key after something other than this model wrote it — the
    /// `set_own_router_key` MCP tool, or a key synced in from another device.
    func reloadOwnKey() async {
        let stored = await Task.detached(priority: .userInitiated) { ManagedAI.ownKey }.value
        guard stored != ownKey else { return }
        ownKey = stored
        await refresh(minimumInterval: 2, silently: true)
    }

    /// Signs in with Apple and exchanges the identity token for a session.
    func signIn() async {
        guard !signInInFlight else { return }
        errorMessage = nil

        if let message = AppleSignInSupport.preflightMessage {
            errorMessage = message
            return
        }

        let identityToken: String
        do {
            identityToken = try await AppleIdentityToken.request()
        } catch is CancellationError {
            return
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return
        } catch {
            errorMessage = AppleSignInSupport.userMessage(for: error)
            return
        }
        await exchange(identityToken: identityToken)
    }

    /// Signing out drops the account entirely, which re-walls the app: Sign in with Apple is
    /// required to use ForeverLM, so there is no "signed out but still working" state.
    /// Completes a sign-in started by a native `SignInWithAppleButton`, which already ran the
    /// authorization and hands back the credential — no second sheet.
    ///
    /// `signIn()` presents its own sheet for surfaces that only have a plain button (the
    /// Settings card); the account wall uses Apple's own button, so it lands here instead.
    func completeSignIn(_ result: Result<ASAuthorization, Error>) {
        if let message = AppleSignInSupport.preflightMessage {
            errorMessage = message
            return
        }

        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let token = String(data: data, encoding: .utf8) else {
                errorMessage = AppleIdentityToken.Failure.noToken.errorDescription
                return
            }
            // Persist the Apple `sub`. MCP tunnel provisioning derives its user_id as
            // SHA256(appleUserID) and the relay bills by matching that against
            // managed_ai_accounts.apple_sub_hash — so if this isn't stored, every MCP
            // tool call resolves to no account and fails as unbillable. This is the
            // primary sign-in path, so it is the one that has to write it.
            KeychainService.appleUserID = credential.user
            Task { await exchange(identityToken: token) }
        case .failure(let error):
            errorMessage = AppleSignInSupport.userMessage(for: error)
        }
    }

    /// Exchanges an Apple identity token for a session. Shared by both sign-in entry points.
    private func exchange(identityToken: String) async {
        guard !signInInFlight else { return }
        signInInFlight = true
        defer { signInInFlight = false }
        errorMessage = nil

        do {
            try await ManagedAI.signIn(identityToken: identityToken)
            if let subject = AppleIdentityToken.subject(from: identityToken) {
                // The proxy has now verified the token. Persisting the subject only
                // after that check keeps MCP identity tied to an authenticated Apple user.
                KeychainService.appleUserID = subject
            }
            isSignedIn = true
            hasAccountAccess = true
            // The proxy just minted this token, so it needs no revalidation for a while.
            lastValidationAt = Date()
            await refresh()
        } catch let error as ManagedAI.ServiceError {
            show(error)
        } catch {
            logger.warning("Managed AI sign-in failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't reach ForeverLM AI. Check your connection and try again."
        }
    }

    func signOut() {
        ManagedAI.clearSession()
        // The Apple `sub` is this Mac's billing identity: MCP tunnel
        // provisioning hashes it into `tunnels.user_id`, and the relay bills
        // whoever it matches. Left behind, a signed-out Mac keeps provisioning
        // as the person who just left, so it goes with the session.
        KeychainService.appleUserID = nil
        isSignedIn = false
        hasAccountAccess = false
        balance = nil
        ScreenRecordMode.clearAdminStatus()
        lastBalanceRefreshAt = nil
        lastValidationAt = nil
        errorMessage = nil
        balanceErrorMessage = nil
    }

    // MARK: - Gate validation

    /// Asks the proxy whether the stored session is real, and re-walls the app if it says no.
    ///
    /// The launch gate is otherwise a pure Keychain read: `ManagedAI.hasAccountAccess` answers
    /// from a token's presence and its *locally recorded* expiry, and nothing ever asked the
    /// server. So a token that was revoked server-side, or one stored without an expiry (which
    /// `hasAccountAccess` treats as valid forever), kept this Mac unlocked indefinitely — the
    /// app opened straight into Studio for someone who was, as far as the proxy is concerned,
    /// not signed in at all.
    ///
    /// `refresh()` cannot do this job: it early-returns unless `ManagedAI.isSignedIn`, and an
    /// aged-out token is exactly the case that needs checking. This one runs whenever a token
    /// exists, expired or not.
    ///
    /// Only a definitive rejection re-walls. A network failure deliberately leaves the gate
    /// alone — that is what `ManagedAI.accountGracePeriod` exists for, and an offline Mac must
    /// not read as signed out.
    func validateStoredSession(minimumInterval: TimeInterval = 0) async {
        let session = await Task.detached(priority: .userInitiated) {
            (
                exists: ManagedAI.sessionToken != nil,
                isSignedIn: ManagedAI.isSignedIn,
                hasAccountAccess: ManagedAI.hasAccountAccess,
                needsRenewal: ManagedAI.sessionNeedsRenewal
            )
        }.value
        guard session.exists else {
            // No token at all — the gate already says so, and there is nothing to ask about.
            hasAccountAccess = session.hasAccountAccess
            isSignedIn = false
            return
        }
        if let lastValidationAt, Date().timeIntervalSince(lastValidationAt) < minimumInterval {
            return
        }
        guard !validationRunning else { return }
        validationRunning = true
        // A lapsed session holds the wall while we ask; a live one revalidates invisibly.
        let sessionIsLapsed = !session.isSignedIn
        isValidatingLapsedSession = sessionIsLapsed
        defer {
            validationRunning = false
            isValidatingLapsedSession = false
        }

        do {
            // The cheapest authenticated endpoint; its answer doubles as a fresh balance.
            balance = try await requestBalance()
            isSignedIn = true
            hasAccountAccess = true
            lastValidationAt = Date()
            lastBalanceRefreshAt = Date()
            balanceErrorMessage = nil
        } catch let error as ManagedAI.ServiceError where error.isInvalidSession {
            // The transport already dropped the token; mirror that in the gate so the wall
            // comes back on this launch rather than at some later Settings visit.
            isSignedIn = false
            hasAccountAccess = false
            balance = nil
            ScreenRecordMode.clearAdminStatus()
            lastBalanceRefreshAt = nil
            lastValidationAt = Date()
            return
        } catch {
            // Offline, or the proxy is unhappy for some other reason. Say nothing and keep
            // the current gate state; this runs unprompted at launch, so it has no business
            // putting an error in front of someone who just opened the app.
            logger.warning("Managed AI session validation failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // The session just proved live; slide it forward if it is into its second half,
        // so a Mac that is opened at all never reaches the day-30 wall. Slack is the
        // surface that shows this first: its connection lives on the gateway and is
        // reached only with this session, so a lapsed session read as Slack disconnecting.
        guard session.needsRenewal else { return }
        do {
            try await ManagedAI.renewSession()
        } catch let error as ManagedAI.ServiceError where error.isInvalidSession {
            // Rejected between the balance read and now — revoked, or the account is
            // gone. The transport dropped the token; re-wall as a rejected read would.
            isSignedIn = false
            hasAccountAccess = false
            balance = nil
            ScreenRecordMode.clearAdminStatus()
            lastBalanceRefreshAt = nil
        } catch {
            // The current session is still good; the next launch or activation asks again.
            logger.warning("Managed AI session renewal failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Balance

    func refresh(minimumInterval: TimeInterval = 0, silently: Bool = false) async {
        // A Keychain read can wait on securityd: never on the main actor.
        let signedIn = await Task.detached(priority: .userInitiated) { ManagedAI.isSignedIn }.value
        guard signedIn else {
            isSignedIn = false
            balance = nil
            balanceErrorMessage = nil
            return
        }
        if let lastBalanceRefreshAt, Date().timeIntervalSince(lastBalanceRefreshAt) < minimumInterval {
            return
        }
        if !silently { refreshInFlight = true }
        defer {
            if !silently { refreshInFlight = false }
        }
        if !silently { balanceErrorMessage = nil }

        do {
            balance = try await requestBalance()
            isSignedIn = true
            lastBalanceRefreshAt = Date()
            // Clear even after a silent activation refresh. This is the recovery
            // event for a prior visible failure, and keeping the red error beside
            // fresh balance data makes a successful screen still look broken.
            balanceErrorMessage = nil
        } catch let error as ManagedAI.ServiceError {
            // An invalid session clears itself in the transport; reflect that in
            // the UI rather than showing a stale balance behind an error.
            //
            // This also ends the grace window, and deliberately so: the server *rejected*
            // the token, which is different from it merely having aged out locally. The
            // guard above handles the latter and leaves `hasAccountAccess` alone so an
            // offline Mac keeps working.
            if error.isInvalidSession {
                isSignedIn = false
                hasAccountAccess = false
                balance = nil
                ScreenRecordMode.clearAdminStatus()
                balanceErrorMessage = nil
                if !silently { show(error) }
            } else if !silently {
                balanceErrorMessage = error.message
            }
        } catch {
            logger.warning("Managed AI balance failed: \(error.localizedDescription, privacy: .public)")
            if !silently {
                balanceErrorMessage = "Couldn't load your ForeverLM billing details. Check your connection and try again."
            }
        }
    }

    /// Launch validation and the Billing pane can appear on the same activation.
    /// They must await one shared read instead of racing duplicate D1 snapshots;
    /// importantly, a visible caller still observes and reports the shared error.
    private func requestBalance() async throws -> ManagedAI.Balance {
        if let balanceRequest {
            return try await balanceRequest.value
        }

        let request = Task.detached(priority: .userInitiated) {
            try await ManagedAI.balance()
        }
        balanceRequest = request
        defer { balanceRequest = nil }
        return try await request.value
    }

    // MARK: - Own key and plan

    private(set) var openRouterConnectInFlight = false

    /// "Connect OpenRouter": signs in at OpenRouter in the browser and stores
    /// the key it hands back exactly as a pasted key is stored (checked first).
    @discardableResult
    func connectOpenRouter() async -> Bool {
        guard !openRouterConnectInFlight else { return false }
        openRouterConnectInFlight = true
        defer { openRouterConnectInFlight = false }
        errorMessage = nil
        do {
            let key = try await OpenRouterConnect.connect()
            return await setOwnKey(key, router: .openRouter)
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Opens Stripe Checkout in the browser: the Early user deal (`.once`),
    /// the one plan the paid app sells. It takes effect when Stripe's webhook
    /// lands; the app becoming active again, or the payment watch, picks it up.
    func choosePlan(_ plan: ManagedAI.AppPlan) async {
        guard planCheckoutInFlight == nil else { return }
        planCheckoutInFlight = plan
        defer { planCheckoutInFlight = nil }
        errorMessage = nil

        do {
            let url = try await ManagedAI.planCheckoutURL(plan)
            open(url)
            watchForPayment()
        } catch let error as ManagedAI.ServiceError {
            show(error)
        } catch {
            logger.warning("Plan checkout failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't start checkout. Check your connection and try again."
        }
    }

    /// While the app is locked, reads the account every five seconds for ten
    /// minutes after checkout opens, and stops as soon as it is unlocked.
    private func watchForPayment() {
        paymentWatch?.cancel()
        guard isAppLocked else { return }
        let deadline = Date().addingTimeInterval(600)
        paymentWatch = Task { [weak self] in
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.isAppLocked else { return }
                await self.refresh(minimumInterval: 2, silently: true)
            }
        }
    }

    /// Re-reads the lock and the account menu's count when the free days
    /// next cross a day on the proxy's clock, and once more when they end,
    /// so a Mac left open locks on time and a refresh confirms it.
    private func scheduleFreeDaysTick() {
        freeDaysTick?.cancel()
        freeDaysTick = nil
        guard let access = appAccess, access.state == .freeDays,
              let freeUntil = access.freeUntil else { return }
        let remaining = freeUntil.timeIntervalSince(ManagedAI.serverNow)
        guard remaining > 0 else { return }
        let toNextDay = remaining.truncatingRemainder(dividingBy: MemoryTutorScheduler.secondsPerDay)
        let delay = (toNextDay > 0 ? toNextDay : MemoryTutorScheduler.secondsPerDay) + 1
        let endsTheFreeDays = delay >= remaining
        freeDaysTick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.freeDaysClock += 1
            if endsTheFreeDays {
                await self.refresh(silently: true)
            }
            self.scheduleFreeDaysTick()
        }
    }

    private func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

/// Requests a fresh Sign in with Apple identity token.
///
/// The existing license flows obtain their token inside `SignInWithAppleButton`
/// completion handlers and never persist it (identity tokens are short-lived), so
/// the managed rail needs its own way to ask for one on demand. This wraps
/// `ASAuthorizationController` in an async call.
enum AppleIdentityToken {

    enum Failure: LocalizedError {
        case noToken
        case invalidCallback

        var errorDescription: String? {
            switch self {
            case .noToken: return "Apple sign-in didn't return an identity token. Please try again."
            case .invalidCallback: return "Apple sign-in returned an invalid response. Please try again."
            }
        }
    }

    /// Presents the system Sign in with Apple sheet and returns the identity token
    /// as a JWT string. Throws `ASAuthorizationError.canceled` if the user backs out.
    @MainActor
    static func request() async throws -> String {
        #if os(macOS)
        if !AppleSignInSupport.hasRequiredEntitlement,
           AppleSignInSupport.supportsWebAuthentication {
            return try await WebRequest.request()
        }
        #endif

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = Delegate()

        return try await withCheckedThrowingContinuation { continuation in
            // The controller holds its delegate weakly, so the delegate must stay
            // alive until it resumes; it keeps itself alive via this reference and
            // releases it when done.
            delegate.continuation = continuation
            delegate.retain = delegate
            controller.delegate = delegate
            controller.presentationContextProvider = delegate
            controller.performRequests()
        }
    }

    static func subject(from token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["sub"] as? String
    }

    #if os(macOS)
    /// Hands a `foreverlm://apple-sign-in` link that reached the app through
    /// its URL handler to the web sign-in waiting on it. True when the link was
    /// a sign-in callback, whether or not a request was still waiting.
    @MainActor
    static func handleWebCallback(_ url: URL) -> Bool {
        WebRequest.handleOpenedCallback(url)
    }

    /// Sign in with Apple for Developer ID builds. Apple does not allow the
    /// native entitlement in a Developer ID provisioning profile, so the app
    /// opens the registered web Services ID and receives the token through the
    /// existing `foreverlm` callback scheme.
    @MainActor
    private final class WebRequest: NSObject, ASWebAuthenticationPresentationContextProviding {
        private var session: ASWebAuthenticationSession?
        private var continuation: CheckedContinuation<String, Error>?
        private var retain: WebRequest?
        private let state: String
        private var startURL: URL?
        /// Set once the request has moved from the sign-in sheet to an
        /// ordinary browser tab, so a second bad result fails instead of
        /// opening another tab.
        private var waitsInBrowser = false

        /// The request whose sign-in continues in an ordinary browser tab and
        /// is waiting for the app's URL handler to deliver its callback.
        private static var awaitingOpenedCallback: WebRequest?

        private init(state: String) {
            self.state = state
        }

        static func handleOpenedCallback(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == ForeverLMRuntimeIdentity.urlScheme,
                  url.host?.lowercased() == "apple-sign-in" else { return false }
            guard let request = awaitingOpenedCallback else {
                logger.error("Web sign-in callback arrived with no sign-in waiting for it")
                return true
            }
            request.complete(callbackURL: url, error: nil)
            return true
        }

        static func request() async throws -> String {
            // A new click replaces a sign-in still waiting in a browser tab
            // the learner gave up on.
            awaitingOpenedCallback?.finish(.failure(CancellationError()))

            let state = randomToken()
            guard var components = URLComponents(string: "https://foreverlm.com/account/billing/") else {
                throw Failure.invalidCallback
            }
            components.queryItems = [
                URLQueryItem(name: "native_sign_in", value: "1"),
                URLQueryItem(name: "state", value: state),
            ]
            guard let url = components.url else { throw Failure.invalidCallback }

            let request = WebRequest(state: state)
            return try await withCheckedThrowingContinuation { continuation in
                request.continuation = continuation
                request.retain = request
                request.start(url: url)
            }
        }

        private static func randomToken() -> String {
            var bytes = [UInt8](repeating: 0, count: 24)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            }
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        private func start(url: URL) {
            startURL = url
            let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callbackURL, error in
                self?.complete(callbackURL: callbackURL, error: error)
            }
            let session = WebAuthenticationSessionSupport.make(
                url: url,
                callbackScheme: ForeverLMRuntimeIdentity.urlScheme,
                completionHandler: completion
            )
            session.presentationContextProvider = self
            // A shared browser session carries Safari's cookies, so the sheet
            // finds the Apple Account already signed in to appleid.apple.com and
            // completes as that person without asking. Signing out here and
            // signing back in then returns the same account no matter which
            // Apple ID is typed, because nothing the app clears can reach
            // Apple's own web session. An ephemeral jar is the only lever: it
            // costs a returning learner a password and a two-factor prompt, and
            // it is what makes switching accounts on one Mac possible at all.
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                Self.logger.error("Web sign-in session refused to start")
                finish(.failure(Failure.invalidCallback))
            }
        }

        /// Each rejection below says which check failed, so a failed first
        /// sign-in on a fresh Mac can be diagnosed; the token itself is never logged.
        private static let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
            category: "AppleSignIn"
        )

        private func complete(callbackURL: URL?, error: Error?) {
            if let webError = error as? ASWebAuthenticationSessionError,
               webError.code == .canceledLogin {
                finish(.failure(CancellationError()))
                return
            }
            if let error {
                finish(.failure(error))
                return
            }
            guard let callbackURL else {
                Self.logger.error("Web sign-in finished with neither a callback nor an error")
                continueInBrowserOrFail()
                return
            }
            guard callbackURL.scheme?.lowercased() == ForeverLMRuntimeIdentity.urlScheme,
                  callbackURL.host?.lowercased() == "apple-sign-in",
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
                Self.logger.error(
                    "Web sign-in callback had an unexpected shape: scheme=\(callbackURL.scheme ?? "nil", privacy: .public) host=\(callbackURL.host ?? "nil", privacy: .public) path=\(callbackURL.path, privacy: .public)"
                )
                continueInBrowserOrFail()
                return
            }
            guard components.queryItems?.first(where: { $0.name == "state" })?.value == state else {
                Self.logger.error("Web sign-in callback carried a different state than this request")
                finish(.failure(Failure.invalidCallback))
                return
            }

            let callbackError = components.queryItems?.first(where: { $0.name == "error" })?.value
            if callbackError == "user_cancelled_authorize" {
                finish(.failure(CancellationError()))
                return
            }
            guard let token = components.queryItems?.first(where: { $0.name == "identity_token" })?.value,
                  !token.isEmpty else {
                Self.logger.error(
                    "Web sign-in callback had no identity token: error=\(callbackError ?? "nil", privacy: .public)"
                )
                finish(.failure(Failure.invalidCallback))
                return
            }

            finish(.success(token))
        }

        /// Safari in a new macOS 27.0 account ends every sign-in sheet on its
        /// first navigation: it reports the sheet
        /// finished about 0.1 s in, with the start page as the "callback",
        /// before foreverlm.com is even fetched. Its own Google sign-in fails
        /// the same way there, so no URL or option the app picks for the sheet
        /// can help. The sign-in itself does not need the sheet: the server
        /// already ends it by redirecting to `foreverlm://apple-sign-in`, which
        /// an ordinary browser tab hands to the app's URL handler. That tab
        /// shares the browser's Apple session, so it gives up the sheet's
        /// private cookie jar only on the Macs where the sheet cannot work.
        private func continueInBrowserOrFail() {
            guard !waitsInBrowser, let startURL else {
                finish(.failure(Failure.invalidCallback))
                return
            }
            waitsInBrowser = true
            session?.cancel()
            session = nil

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // ForeverLM can itself be the default browser; its Browser pane
            // cannot show Apple's sign-in, so the tab goes to Safari instead.
            let defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: startURL)
            let browser = defaultBrowser.flatMap { url in
                url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL ? nil : url
            } ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            guard let browser else {
                Self.logger.error("Web sign-in found no browser to continue in")
                finish(.failure(Failure.invalidCallback))
                return
            }

            Self.logger.notice("Web sign-in sheet ended early; continuing in a browser tab")
            Self.awaitingOpenedCallback = self
            NSWorkspace.shared.open([startURL], withApplicationAt: browser, configuration: configuration) { _, error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    Self.logger.error("Web sign-in could not open a browser tab: \(error.localizedDescription, privacy: .public)")
                    self?.finish(.failure(error))
                }
            }
        }

        private func finish(_ result: Result<String, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            if Self.awaitingOpenedCallback === self {
                Self.awaitingOpenedCallback = nil
            }
            session?.cancel()
            session = nil
            retain = nil
            continuation.resume(with: result)
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }
    #endif

    private final class Delegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        var continuation: CheckedContinuation<String, Error>?
        var retain: Delegate?

        private func finish(_ result: Result<String, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            retain = nil
            continuation.resume(with: result)
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let token = String(data: data, encoding: .utf8) else {
                finish(.failure(Failure.noToken))
                return
            }
            // Same reason as completeSignIn: MCP billing identity derives from this.
            KeychainService.appleUserID = credential.user
            finish(.success(token))
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            finish(.failure(error))
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            #if canImport(AppKit)
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            return ASPresentationAnchor()
            #endif
        }
    }
}
