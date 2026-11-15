import Foundation

extension Notification.Name {
    /// An AI request had no key to run on (`ManagedAI.creditsAreEmpty`). The
    /// app shell presents the blocking "add your OpenRouter key" prompt; feature
    /// views keep their own error state so the failed operation still has local
    /// context.
    static let managedAICreditsEmpty = Notification.Name("managedAICreditsEmpty")

    /// The learner stored an own key after having none. This is the moment work
    /// that was refused for want of a key becomes possible, so it is what
    /// resumes it — a key the app never acts on leaves the learner pressing the
    /// button again on a source that can already be paid for.
    static let managedAICreditsRestored = Notification.Name("managedAICreditsRestored")
    /// The learner stored, replaced, or removed their own router key.
    static let managedAIOwnKeyDidChange = Notification.Name("managedAIOwnKeyDidChange")
    /// A session was stored or cleared: the learner signed in or out. A "sign in"
    /// error shown before it no longer describes this Mac, so whoever shows one
    /// clears it here.
    static let managedAISessionDidChange = Notification.Name("managedAISessionDidChange")
}

/// ForeverLM's account service (`workers/ai-proxy`, ai.foreverlm.com): Sign in
/// with Apple, the paid app's plan (the free days, payment, the lock), Stripe
/// checkout, and the Doc and Site publishing bearer. ForeverLM pays for no AI
/// (product owner, 2026-11-15): every AI request runs on the learner's own
/// OpenRouter key (and, for voice, their own OpenAI key) and leaves the device
/// for those providers directly, never through ForeverLM's server. The session
/// token is the only ForeverLM credential, minted from Sign in with Apple.
enum ManagedAI {

    /// The account service. Every account call goes here; no AI request does.
    static let baseURL = URL(string: "https://ai.foreverlm.com")!
    /// What the learner has spent, per model and day, in OpenRouter's own monitor.
    /// ForeverLM keeps no spend figures of its own (product owner, 2026-10-15:
    /// "we shouldn't maintain our own spend stuff").
    static let openRouterActivityURL = URL(string: "https://openrouter.ai/activity")!

    // MARK: - Session

    #if DEBUG
    /// Lets the opt-in live integration suite authenticate in a clean test
    /// runner without copying a token into source, a scheme, or the Keychain.
    /// Production builds cannot read this override. A signed-in local app
    /// needs no token for a live suite: its opt-in flag
    /// (`liveSuiteReadsKeychainSession`) lets the hosted test bundle read the
    /// app's existing Keychain session.
    private static var environmentSessionToken: String? {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["FOREVERLM_MANAGED_SESSION_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// Pins `isSignedIn` for a unit test. Nil leaves the unit-test default,
    /// which is signed out; a test that needs a session sets `true`.
    /// Production builds cannot set this.
    nonisolated(unsafe) static var signedInOverrideForTesting: Bool?

    /// Whether this test process opted into one of the billable live suites,
    /// which run on the developer's real session: `ManagedModelSmokeTests`
    /// (`FOREVERLM_MODEL_SMOKE_TESTS=1`), `LiveAPIIntegrationTests`
    /// (`FOREVERLM_LIVE_API_TESTS=1`) and the live slide-citation test in
    /// `SlideCitationServiceTests` (`FOREVERLM_LIVE_AI_TESTS=1`). Every other
    /// unit test runs signed out.
    private static let liveSuiteReadsKeychainSession: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return ["FOREVERLM_MODEL_SMOKE_TESTS", "FOREVERLM_LIVE_API_TESTS", "FOREVERLM_LIVE_AI_TESTS"]
            .contains { environment[$0] == "1" }
    }()
    #endif

    /// Session token minted by `POST /v1/session` from an Apple identity token.
    /// Its presence is what makes managed mode active on this Mac.
    static var sessionToken: String? {
        get {
            #if DEBUG
            if let environmentSessionToken { return environmentSessionToken }
            #endif
            guard let token = KeychainService.managedAISessionToken?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
            return token
        }
        set {
            KeychainService.managedAISessionToken = newValue
            NotificationCenter.default.post(name: .managedAISessionDidChange, object: nil)
        }
    }

    /// Unix seconds at which the stored session expires. The proxy mints 30-day
    /// tokens and `renewSession()` slides a live one forward before it lapses;
    /// the proxy still decides on every request, so this is a hint for the
    /// renewal schedule and the launch gate rather than an authority.
    static var sessionExpiry: Date? {
        get {
            guard let raw = KeychainService.managedAISessionExpiry, let seconds = TimeInterval(raw) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        set { KeychainService.managedAISessionExpiry = newValue.map { String(Int($0.timeIntervalSince1970)) } }
    }

    /// True once a usable session exists on this Mac.
    ///
    /// An expired token counts as signed out: identity tokens are short-lived and
    /// never stored, so a session cannot be refreshed without the user completing
    /// the Apple sheet again. Knowing that up front is better than routing a
    /// request that is certain to 401.
    ///
    /// Deliberately does not consider balance — an empty balance is the server's
    /// "add your key" refusal, not a reason to silently fall back to another rail.
    static var isSignedIn: Bool {
        #if DEBUG
        if let signedInOverrideForTesting { return signedInOverrideForTesting }
        // A supplied live-test token is authoritative for the test process; a
        // stale expiry belonging to some unrelated Keychain session must not
        // make `resolveConfig` reject it before the proxy gets to validate it.
        if environmentSessionToken != nil { return true }
        // A unit test starts signed out, whatever the Dev app hosting it last
        // did. Reading the developer's Keychain session here made every test
        // that reached `KeychainService.resolveConfig` send real, billed AI
        // requests while the Dev app was signed in, and pass or fail on the
        // model's answer: `RenderedReaderPageAdoptionTests
        // .paperFullTextBecomesContent` fails on every signed-in run if
        // a real Paper Metadata call finds no author. Only the opt-in live
        // suites read the real session.
        if hostsUnitTests, !liveSuiteReadsKeychainSession { return false }
        #endif
        guard sessionToken != nil else { return false }
        if let expiry = sessionExpiry, expiry <= Date() { return false }
        return true
    }

    /// The session a request to a ForeverLM service carries: `rewrite` puts it
    /// on a proxied AI call, and the Doc and Site publishing services, the
    /// plugin gateways and the sites host read it as their bearer.
    ///
    /// Under unit tests, `isSignedIn` being false keeps `resolveConfig` from
    /// building a config, but a test can still hand `AIService` a config it
    /// built itself and send it without a mock transport, and every `list_docs`
    /// test asked the publishing service for this account's pages. The
    /// developer's Keychain session must not ride along on those requests, or
    /// the proxy bills their account and the publishing service answers with
    /// their real pages; without one, each caller takes its signed-out path.
    /// The live suites and a supplied test token keep their credential.
    ///
    /// `sessionToken` itself stays the stored session: the launch gate
    /// (`hasAccountAccess`), renewal and sign-out read and write that.
    static var requestSessionToken: String? {
        #if DEBUG
        if environmentSessionToken == nil, hostsUnitTests, !liveSuiteReadsKeychainSession { return nil }
        #endif
        return sessionToken
    }

    static func clearSession() {
        sessionToken = nil
        sessionExpiry = nil
        // The plan belongs to the Apple ID; the next sign-in reports its own.
        appAccess = nil
    }

    // MARK: - Your own router key

    /// The router a learner's own key belongs to. A request the key pays for
    /// goes to the router on this key instead of ForeverLM's, the router bills
    /// the learner's own account, and the ForeverLM balance is charged nothing.
    /// OpenRouter is the only router; the enum stays so a second router is one
    /// case away.
    enum OwnKeyRouter: String, CaseIterable, Sendable, Identifiable {
        case openRouter = "openrouter"

        var id: String { rawValue }

        var label: String { "OpenRouter" }

        /// What this key actually pays for, mid-sentence. The product owner (2026-09-22):
        /// "users should be able to bring their own key for everything that is
        /// openrouter enabled; but for other things they should have to pay",
        /// so an OpenRouter key takes chat, reviews and background tasks and
        /// every voice, transcription model, image model and video model
        /// OpenRouter serves — the first-party ones included — and `rewrite`
        /// sends those requests to OpenRouter on the key.
        var billedScope: String { "text, voices, speech-to-text, images and video" }

        /// `billedScope` at the start of a sentence.
        var billedScopeCapitalized: String {
            billedScope.prefix(1).uppercased() + billedScope.dropFirst()
        }

        /// The provider host whose requests this key pays for. `rewrite` keys
        /// off the request's own host, so a key is attached only to requests
        /// bound for its router.
        var host: String { "openrouter.ai" }

        /// Whether a request this key pays for goes straight to the router
        /// instead of through the metered proxy. OpenRouter does: the app
        /// already speaks its API directly, and the proxy adds nothing to a
        /// call it neither bills nor credentials.
        var sendsDirect: Bool { true }

        /// The transport ordinary text takes while this key is set.
        var routingMode: AITextRoutingMode { .openRouter }

        /// The link under the key field.
        var keysLinkTitle: String { "Get an OpenRouter key" }

        /// Where the learner gets one.
        var keysURL: URL { URL(string: "https://openrouter.ai/keys")! }

        /// What OpenRouter is, said wherever the learner sets up the key.
        var aboutNote: String {
            "\(label) is one account for AI models from many providers. You choose which models ForeverLM uses, and from which providers."
        }

        /// The product owner (2026-09-27): the learner answers for the terms of the
        /// models they pick, and training on inputs is the term to say out
        /// loud, since free models' hosts mostly do it. It reads as plain
        /// secondary text beside the other notes, not as a warning: "no need
        /// to make this a warning".
        var trainingNote: String {
            "You are responsible for understanding the terms of the models you choose. Some providers train on what you send them and others do not. Free models usually do, and some paid models do too."
        }

        var creditsLinkTitle: String { "Add credits at \(label)" }

        var keyPrivacySummary: String { "Saved in your Keychain, sent only to \(label)" }

        var creditsURL: URL { URL(string: "https://openrouter.ai/settings/credits")! }

        /// Where the key lives and where it goes, shown wherever a key is
        /// entered. The product owner (2026-09-25): it has to be clear the key is not
        /// stored on ForeverLM's servers. True because `rewrite` sends it only
        /// to `host` and the proxy gets `ownKeyHeldHeader` instead.
        var keyPrivacyNote: String {
            "Your key is saved only in your Keychain, which iCloud Keychain syncs end-to-end encrypted to your other devices, and it is sent only to \(label). ForeverLM's servers never receive or store it."
        }

        var keychainKey: KeychainService.Key { .ownOpenRouterKey }
    }

    /// The learner's own router key, as stored: one router, one key. The key
    /// lives in the iCloud Keychain so the learner's Macs and iPhone share it;
    /// it never reaches `UserDefaults`, a log, or a synced preference row.
    struct OwnKey: Sendable, Equatable {
        let router: OwnKeyRouter
        let key: String

        /// What Settings shows instead of the key.
        var suffix: String { String(key.suffix(4)) }
    }

    /// The proxy's own-key header. It is never set: the
    /// key goes to its router and nowhere else.
    static let ownKeyHeader = "X-ForeverLM-Own-Key"

    /// What the proxy gets instead when a key is stored but may not run (a
    /// locked account): only that the learner holds one, so it can answer
    /// `app_locked` by name. Never the key.
    static let ownKeyHeldHeader = "X-ForeverLM-Own-Key-Held"

    /// Provider credential headers a caller may have set. Cleared on both
    /// rails before the rail's own credential goes on: the app may have set an
    /// empty `x-api-key`/`Bearer ` sentinel, and `Authorization` is the very
    /// header the session — or, direct, the learner's key — occupies.
    private static let providerCredentialHeaders = [
        "x-api-key",
        "x-goog-api-key",
        "xi-api-key",
        "Authorization",
        "Proxy-Authorization",
        "cf-aig-authorization"
    ]

    /// Every header `rewrite` stamps for the proxy's benefit. Cleared on the
    /// direct rail: there is no proxy there to read them, and what the learner
    /// is studying is not the provider's business.
    private static let proxyAttributionHeaders = [
        "X-ForeverLM-Task",
        "X-ForeverLM-Source-Title",
        "X-ForeverLM-Subject-ID",
        "X-ForeverLM-Subject-Type",
        "X-ForeverLM-Activity-ID",
        "X-ForeverLM-Platform",
        "X-ForeverLM-Build",
        "X-ForeverLM-Response-Cache",
        ownKeyHeader,
        ownKeyHeldHeader
    ]

    /// Renames a transport failure that never reached a provider.
    ///
    /// Every managed request carries ForeverLM's host, not the provider's, so a
    /// DNS block, a dropped connection or a Worker that is down surfaces as
    /// "OpenRouter timed out" for a request OpenRouter never saw — which sends
    /// the reader to check the provider's status page, or the app's own
    /// routing, for a condition that is neither. Returns the error unchanged
    /// when it is anything else, including the same failure against a real
    /// provider on the direct rail, where blaming the provider is correct.
    static func namingUnreachableService(_ error: Error) -> Error {
        if let blocked = blockedRequestError(error) {
            surfaceIfNeeded(blocked)
            return blocked
        }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .secureConnectionFailed,
             .resourceUnavailable:
            break
        default:
            return error
        }
        // `failingURL` is absent on some URLErrors; the string form is the
        // documented fallback and carries the same URL.
        let failingHost = urlError.failingURL?.host?.lowercased()
            ?? (urlError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
                .flatMap { URL(string: $0)?.host?.lowercased() }
        guard let failingHost, failingHost == baseURL.host?.lowercased() else { return error }
        let message = "ForeverLM's AI service (\(failingHost)) could not be reached, so the request never got to the AI provider. \(urlError.localizedDescription)"
        #if os(macOS)
        return AIError.serviceUnreachable(message)
        #else
        // `AIError` lives in AIService.swift, which the phone does not compile;
        // the phone gets the same words as its own error.
        return ManagedAIUnreachableError(message: message)
        #endif
    }

    /// Whether a request bound for `host` leaves on the learner's own router
    /// key, straight to that router, instead of through the metered proxy.
    ///
    /// The single statement of the rule: `rewrite` routes by it, and the
    /// OpenRouter body builder asks it whether to request the billed cost that
    /// the proxy would otherwise have resolved on the app's behalf.
    /// The key leaves direct only while the account is unlocked
    /// (`ManagedAI.ownKeyAllowed`). Otherwise the request
    /// goes through the proxy, which answers `app_locked` instead of quietly
    /// spending balance.
    /// OpenRouter's app attribution (openrouter.ai/docs/app-attribution):
    /// `HTTP-Referer` is what puts ForeverLM on its rankings and model pages,
    /// the title names it there, and the categories file it in the app
    /// marketplace. The proxy stamps the same three on the managed rail
    /// (`providerUpstreamHeaders` in workers/ai-proxy), so only a request the
    /// learner's own key sends direct needs them here.
    static let openRouterAttributionHeaders: [(field: String, value: String)] = [
        ("HTTP-Referer", "https://foreverlm.com"),
        ("X-OpenRouter-Title", "ForeverLM"),
        ("X-OpenRouter-Categories", "personal-agent,general-chat")
    ]

    static func applyOpenRouterAttribution(_ request: inout URLRequest) {
        for header in openRouterAttributionHeaders {
            request.setValue(header.value, forHTTPHeaderField: header.field)
        }
    }

    static func sendsOwnKeyDirect(toHost host: String?) -> Bool {
        var allowed = ownKeyAllowed
        #if DEBUG
        if let override = ownKeyAllowedOverrideForTesting { allowed = override }
        #endif
        guard allowed, let host = host?.lowercased(), let own = ownKey else { return false }
        return own.router.sendsDirect && own.router.host == host
    }

    #if DEBUG
    private static let hostsUnitTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }()

    /// Pins the own key for a unit test. The hosted test bundle otherwise reads
    /// the developer's own Keychain, so a routing test's outcome would follow
    /// whatever key the Dev app last stored. `.some(nil)` pins "no key".
    nonisolated(unsafe) static var ownKeyOverrideForTesting: OwnKey??

    /// Pins whether the account lets the key run, for the same reason: the
    /// stored access otherwise follows whatever account the Dev app last
    /// signed in.
    nonisolated(unsafe) static var ownKeyAllowedOverrideForTesting: Bool?
    #endif

    private static let ownKeyLock = AppLock()
    /// `nil` until the Keychain has been read once this launch; then the
    /// answer, which every write below keeps current. Routing resolves the
    /// transport synchronously at dispatch, so this must not cost a Keychain
    /// round trip per request.
    nonisolated(unsafe) private static var ownKeyCache: OwnKey??

    /// The learner's own router key, or nil when the balance pays.
    static var ownKey: OwnKey? {
        #if DEBUG
        if let override = ownKeyOverrideForTesting { return override }
        #endif
        return ownKeyLock.withLock {
            if let cached = ownKeyCache { return cached }
            #if DEBUG
            // A unit test starts with no key, whatever the Dev app last stored
            // in the developer's Keychain; one that needs a key sets it.
            if hostsUnitTests {
                ownKeyCache = .some(nil)
                return nil
            }
            #endif
            let loaded = readOwnKeyFromKeychain()
            ownKeyCache = .some(loaded)
            return loaded
        }
    }

    /// The router the learner's text goes through while their key is set.
    static var ownKeyRouter: OwnKeyRouter? { ownKey?.router }

    static var hasOwnKey: Bool { ownKey != nil }

    /// What the router said about a key before it was stored.
    enum OwnKeyCheck: Equatable, Sendable {
        case accepted
        case rejected(String)
    }

    struct OwnKeyCheckError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Asks the router whether it accepts `key`, so a mistyped key is caught
    /// when it is saved instead of on the first chat. OpenRouter's key-info
    /// endpoint answers 200 for a live key and 401 for one it does not know;
    /// the request goes straight to OpenRouter, as every call on that key
    /// does. Throws when the router cannot be asked at all — the caller then
    /// says so rather than storing a key nobody has vouched for.
    static func checkOwnKey(
        _ key: String,
        router: OwnKeyRouter,
        session: URLSession = .shared
    ) async throws -> OwnKeyCheck {
        var request = URLRequest(url: OpenRouterAPI.key)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let result = ownKeyCheckResult(statusCode: status, router: router) else {
            throw OwnKeyCheckError(message: "\(router.label) answered \(status) when asked about the key. Try again in a moment.")
        }
        return result
    }

    /// The status-code half of `checkOwnKey`, separate so it can be tested.
    /// Nil for an answer that says nothing about the key (a 5xx, a 429).
    static func ownKeyCheckResult(statusCode: Int, router: OwnKeyRouter) -> OwnKeyCheck? {
        switch statusCode {
        case 200..<300:
            return .accepted
        case 401, 403:
            return .rejected("\(router.label) didn't accept this key. Check that you copied all of it.")
        default:
            return nil
        }
    }

    /// OpenRouter's own count of the day's free-model (`:free`) requests, for
    /// the account the key belongs to: every app on that account counts, not
    /// only ForeverLM. The cap is 50 a day until the account has bought $10 of
    /// credits and 1,000 after, and the count starts again at UTC midnight.
    struct FreeModelDailyRequests: Equatable, Sendable {
        let used: Int
        let limit: Int
        let remaining: Int

        /// When the count starts again: the first UTC midnight after `now`.
        static func resetDate(after now: Date = Date()) -> Date {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let today = utc.startOfDay(for: now)
            return utc.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(MemoryTutorScheduler.secondsPerDay)
        }

        /// Every free-model request of the day is used.
        var isSpent: Bool { remaining <= 0 }

        /// "962 of 1,000 left · resets at 17:00", the reset in the learner's
        /// own time. Spent, it says so in a sentence (product owner,
        /// 2026-10-17: "it should say when we run out of openrouter free
        /// calls clearly").
        func summary(now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
            let number = IntegerFormatStyle<Int>.number.locale(locale)
            let reset = Self.resetDate(after: now)
                .formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
            if isSpent {
                return "All \(limit.formatted(number)) free-model requests are used. Free models won't answer until \(reset)."
            }
            return "\(remaining.formatted(number)) of \(limit.formatted(number)) left · resets at \(reset)"
        }
    }

    /// Asks OpenRouter's key-info endpoint, a read that spends nothing, how
    /// many free-model requests the key's account has left today. Nil
    /// without an OpenRouter key; throws when OpenRouter cannot say.
    static func freeModelDailyRequests(session: URLSession = .shared) async throws -> FreeModelDailyRequests? {
        guard let own = ownKey, own.router == .openRouter else { return nil }
        var request = URLRequest(url: OpenRouterAPI.key)
        request.setValue("Bearer \(own.key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let counts = freeModelDailyRequests(fromKeyInfo: data) else {
            throw OwnKeyCheckError(message: "\(own.router.label) answered \(status) when asked about free-model requests.")
        }
        return counts
    }

    /// The parsing half of `freeModelDailyRequests`, separate so it can be
    /// tested: `data.free_model_daily_requests` of the key-info answer.
    static func freeModelDailyRequests(fromKeyInfo body: Data) -> FreeModelDailyRequests? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let info = json["data"] as? [String: Any],
              let counts = info["free_model_daily_requests"] as? [String: Any],
              let used = counts["used"] as? Int,
              let limit = counts["limit"] as? Int,
              let remaining = counts["remaining"] as? Int else { return nil }
        return FreeModelDailyRequests(used: used, limit: limit, remaining: remaining)
    }

    /// Stores, replaces, or (with nil or an empty string) removes the learner's
    /// key. One key at a time, so the router the text takes is never ambiguous.
    ///
    /// Setting a key also clears the durable "balance is empty" flag: the flag
    /// gates chat before a request is sent, and with a key the balance is no
    /// longer what pays for chat. Removing a key leaves the flag to the next
    /// balance fetch, which is the authority on the balance itself.
    static func setOwnKey(_ rawKey: String?, router: OwnKeyRouter) {
        let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stored: OwnKey? = key.isEmpty ? nil : OwnKey(router: router, key: key)
        let hadNoKey = !hasOwnKey
        ownKeyLock.withLock {
            for candidate in OwnKeyRouter.allCases {
                if let stored, candidate == stored.router {
                    KeychainService.save(stored.key, for: candidate.keychainKey)
                } else {
                    KeychainService.delete(candidate.keychainKey)
                }
            }
            ownKeyCache = .some(stored)
        }
        NotificationCenter.default.post(name: .managedAIOwnKeyDidChange, object: nil)
        if stored != nil, hadNoKey {
            Task { @MainActor in
                NotificationCenter.default.post(name: .managedAICreditsRestored, object: nil)
            }
        }
    }

    /// Drops the in-memory copy so the next read asks the Keychain again — for
    /// a key that arrived from another device over iCloud Keychain.
    static func reloadOwnKey() {
        ownKeyLock.withLock { ownKeyCache = nil }
    }

    private static func readOwnKeyFromKeychain() -> OwnKey? {
        // In router order, so two stored keys (unreachable through Settings,
        // possible from two devices racing) resolve the same way everywhere.
        for router in OwnKeyRouter.allCases {
            if let key = KeychainService.load(router.keychainKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return OwnKey(router: router, key: key)
            }
        }
        return nil
    }

    // MARK: - Session renewal

    /// How far ahead of expiry a live session is renewed: half its 30-day life.
    ///
    /// The session is the only credential this Mac holds, and everything that
    /// reads as "connected" in Plugins hangs off it — Slack most visibly, since
    /// the workspace token lives on the gateway and the Mac reaches it only with
    /// this session. Without renewal a Mac that was signed in on day 1 found a
    /// dead session at its first launch after day 30, and Slack read as
    /// disconnected until the Apple sheet was completed again. Renewing at the
    /// halfway mark means any Mac opened at least once a fortnight never lapses,
    /// and a fortnight of slack absorbs a holiday without an extra round trip on
    /// every launch.
    static let sessionRenewalLead: TimeInterval = 15 * MemoryTutorScheduler.secondsPerDay

    /// Pure: whether a session expiring at `expiry` should be renewed at `now`.
    ///
    /// An unknown expiry — a token stored by a build that did not record one —
    /// renews so the schedule has a date to work from. A lapsed session does not:
    /// the proxy refuses to renew an expired token, and the Apple sheet is the
    /// only way back, so asking would only add a failed request to the launch.
    static func sessionNeedsRenewal(expiry: Date?, now: Date = Date()) -> Bool {
        guard let expiry else { return true }
        guard expiry > now else { return false }
        return expiry.timeIntervalSince(now) <= sessionRenewalLead
    }

    /// Whether the stored session is due for renewal. False when there is no
    /// session to renew.
    static var sessionNeedsRenewal: Bool {
        guard sessionToken != nil else { return false }
        return sessionNeedsRenewal(expiry: sessionExpiry)
    }

    /// Exchanges the live session for a fresh 30-day one and stores it.
    ///
    /// The proxy answers `invalid_session` for a token it no longer accepts or
    /// an account that no longer exists; `send` clears the stored session on that
    /// code before this throws, so a caller sees the same state a rejected
    /// balance read would leave. Any other failure — offline, a proxy incident —
    /// leaves the current session in place: it is still valid, and the next
    /// launch or activation asks again.
    static func renewSession() async throws {
        struct Response: Decodable {
            let sessionToken: String
            let expiresAt: TimeInterval

            enum CodingKeys: String, CodingKey {
                case sessionToken = "session_token"
                case expiresAt = "expires_at"
            }
        }
        struct EmptyBody: Encodable {}

        let response: Response = try await post("/v1/session/renew", body: EmptyBody(), authenticated: true)
        sessionToken = response.sessionToken
        sessionExpiry = Date(timeIntervalSince1970: response.expiresAt)
    }

    /// How long past a session's expiry this Mac still counts as having an account, for
    /// **gating the app only** — a lapsed session keeps the knowledge base reachable for two
    /// weeks even though the proxy already rejects the expired token.
    static let accountGracePeriod: TimeInterval = 14 * MemoryTutorScheduler.secondsPerDay

    /// Whether this Mac has an Apple account attached — the launch gate's question.
    ///
    /// Distinct from `isSignedIn`, and deliberately more forgiving. `isSignedIn` asks "will
    /// the proxy accept this token?", so an expired token is a no. This asks "has this person
    /// established who they are?", and a lapsed session still answers yes for two weeks.
    /// Sign in with Apple is required to launch and there is no key-entry bypass, so without
    /// the grace window a user who is offline (or in the air) on the day their 30-day token
    /// lapses cannot open their own knowledge base — a network blip would read as a lockout.
    ///
    /// This is not a security boundary and must never be used as one: the proxy still rejects
    /// the expired token, so managed AI calls fail with the server's own message while the
    /// rest of the app keeps working. Renewal needs the Apple sheet, which needs network.
    static var hasAccountAccess: Bool {
        guard sessionToken != nil else { return false }
        guard let expiry = sessionExpiry else { return true }
        return Date() < expiry.addingTimeInterval(accountGracePeriod)
    }

    // MARK: - Routing

    /// Readies a provider-native request to leave on the learner's own key.
    ///
    /// Keys off the request's own **host**, not a caller-supplied provider label:
    /// several call sites pass a hardcoded (and occasionally wrong) provider
    /// string, so trusting the label would misroute them. A request bound for
    /// the key's own router gets the key; every other request is pointed
    /// nowhere (`noKeyURL`), since ForeverLM pays for no AI, which makes routing
    /// failures explicit and keeps stale keys from older builds from escaping.
    static func rewrite(_ request: inout URLRequest) {
        let originalURL = request.url
        let host = originalURL?.host?.lowercased()

        // A call the learner's own key pays for goes straight to that router.
        // The proxy collects nothing on it, enforces no cap on it and lends it
        // no credential; standing in its path only makes ForeverLM an outage
        // surface for inference it is not selling, and carries the learner's
        // prompts through a server with no stake in them. The spend is still
        // recorded: `AIUsageTracker` stamps the task, the subject and the cost
        // OpenRouter itself reports into the local ledger the usage pane reads.
        // What it gives up is D1's roll-up of these calls across the learner's
        // devices — usage rows are deliberately not pushed to CloudKit
        // (`saveAIUsageEvent`), so a direct-rail row stays on the device that
        // made the call.
        //
        // Narrow on purpose: an own key *and* a request already bound for that
        // key's own router. Every other host still ends at the proxy, so the
        // invariant holds for everything ForeverLM pays for.
        if sendsOwnKeyDirect(toHost: host), let own = ownKey {
            for header in providerCredentialHeaders {
                request.setValue(nil, forHTTPHeaderField: header)
            }
            for header in proxyAttributionHeaders {
                request.setValue(nil, forHTTPHeaderField: header)
            }
            request.setValue("Bearer \(own.key)", forHTTPHeaderField: "Authorization")
            if host == "openrouter.ai" { applyOpenRouterAttribution(&request) }
            return
        }

        // Everything else has nowhere to go. ForeverLM pays for no AI, so a
        // request with no own key (or whose key may not run, a locked app) is
        // pointed at a URL no session can load, and `namingUnreachableService`
        // turns the resulting failure into the sentence that says what to do.
        // It must never be left pointing at a provider unauthenticated, and an
        // unknown host's URL, query included, is never kept: a lab's own API
        // can carry its key as `?key=`.
        request.url = host == "openrouter.ai" && ownKey != nil && !ownKeyAllowed ? appLockedURL : noKeyURL
        for header in providerCredentialHeaders {
            request.setValue(nil, forHTTPHeaderField: header)
        }
        request.setValue(nil, forHTTPHeaderField: "Authorization")
    }

    /// Where a request with no route is pointed (`rewrite`). The scheme is one
    /// URLSession cannot load, so nothing leaves the device.
    static let noKeyURL = URL(string: "foreverlm-blocked://no-own-key")!
    static let appLockedURL = URL(string: "foreverlm-blocked://app-locked")!

    /// The sentence for a request `rewrite` had no route for, or nil when the
    /// error is anything else.
    static func blockedRequestError(_ error: Error) -> ServiceError? {
        guard let urlError = error as? URLError, urlError.code == .unsupportedURL else { return nil }
        let url = urlError.failingURL
            ?? (urlError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0) }
        guard url?.scheme == noKeyURL.scheme else { return nil }
        if url?.host == appLockedURL.host {
            return ServiceError(
                code: "app_locked",
                message: "ForeverLM is locked until it is paid for. Everything you have set up stays as it is."
            )
        }
        return ServiceError(
            code: "no_own_key",
            message: "AI runs on your own OpenRouter key. Add it in Settings, then try again."
        )
    }

    /// Operational attribution only; billing identity still comes from the
    /// authenticated Apple session. Activity identity is mandatory for every
    /// billable request, including call paths that have no source subject.
    private static func applyUsageAttribution(
        _ request: inout URLRequest,
        activityID: String
    ) {
        if let task = AIUsageAttribution.task?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !task.isEmpty {
            request.setValue(String(task.prefix(80)), forHTTPHeaderField: "X-ForeverLM-Task")
        }
        func setEncodedAttribution(_ value: String?, maximumLength: Int, header: String) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return }
            let bounded = String(value.prefix(maximumLength))
            var headerSafeCharacters = CharacterSet.alphanumerics
            headerSafeCharacters.insert(charactersIn: "-._~")
            if let encoded = bounded.addingPercentEncoding(withAllowedCharacters: headerSafeCharacters) {
                request.setValue(encoded, forHTTPHeaderField: header)
            }
        }
        // Percent encoding keeps arbitrary Unicode display titles and opaque
        // deterministic IDs valid in headers. Prompt/source content is never
        // sent in these operational fields.
        setEncodedAttribution(
            AIUsageAttribution.sourceTitle,
            maximumLength: 240,
            header: "X-ForeverLM-Source-Title"
        )
        setEncodedAttribution(
            AIUsageAttribution.subjectID,
            maximumLength: 240,
            header: "X-ForeverLM-Subject-ID"
        )
        setEncodedAttribution(
            AIUsageAttribution.subjectType,
            maximumLength: 80,
            header: "X-ForeverLM-Subject-Type"
        )
        setEncodedAttribution(
            activityID,
            maximumLength: 120,
            header: "X-ForeverLM-Activity-ID"
        )
    }

    /// Device family this build runs on. The client recorders stamp the same
    /// value into `AIUsageEvent.clientPlatform`, so a call's client row and its
    /// authoritative server row always name the same device.
    static var clientPlatform: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "Apple"
        #endif
    }

    /// Stamps device attribution on any request the proxy may meter.
    ///
    /// This belongs on the control plane as well as the proxied provider path.
    /// Realtime voice bills through the control plane,
    /// never through `rewrite`, so applying this only in `rewrite` would leave every
    /// voice session's ledger row with no platform.
    private static func applyDeviceAttribution(_ request: inout URLRequest) {
        request.setValue(clientPlatform, forHTTPHeaderField: "X-ForeverLM-Platform")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let buildLabel = [version, build].compactMap { $0 }.joined(separator: " (")
            + (version != nil && build != nil ? ")" : "")
        if !buildLabel.isEmpty {
            request.setValue(String(buildLabel.prefix(80)), forHTTPHeaderField: "X-ForeverLM-Build")
        }
    }

    // MARK: - Account API

    /// What `/v1/balance` still says that the app uses. ForeverLM pays for no
    /// AI, so there is no balance, comp, spending limit or usage ledger any
    /// more (product owner, 2026-11-15); the response also carries the plan,
    /// which `fetchBalance` stores.
    struct Balance: Sendable {
        /// An operator closed the account (a Stripe dispute, say).
        let disabled: Bool
        /// An operator account: the only thing it unlocks is screen record mode.
        let isAdmin: Bool
    }

    struct ServiceError: LocalizedError, Sendable {
        let code: String
        let message: String
        var errorDescription: String? { message }

        var isInvalidSession: Bool { code == "invalid_session" }
        /// The proxy closed the account (an operator, a Stripe dispute, or
        /// three metering failures in a row). The balance's `disabled` is the
        /// same flag, so a later balance read can say it no longer holds.
        var isAccountDisabled: Bool { code == "account_disabled" }
        /// The proxy's catch-all for a thrown failure (a D1 outage, Apple's
        /// JWKS unreachable, an upstream fetch that threw). It says nothing
        /// about the request, so it is as retryable as an `http_5xx`. The proxy
        /// answers `internal`; `internal_error` is the older spelling.
        var isInternalProxyFailure: Bool { code == "internal" || code == "internal_error" }
    }

    /// Exchanges an Apple identity token for a session token, creating the account
    /// on first sign-in, and stores the plan the server reports with it.
    static func signIn(identityToken: String) async throws {
        struct Response: Decodable {
            let sessionToken: String
            let expiresAt: TimeInterval
            /// The app plan. Optional so a build newer than the worker still signs in.
            let access: AppAccess?
            /// The paid app's fields the proxy also sends beside `access`:
            /// `state` here is the new state (`access.state` keeps the old one).
            let state: String?
            let unlocked: Bool?
            let freeUntil: String?

            enum CodingKeys: String, CodingKey {
                case sessionToken = "session_token"
                case expiresAt = "expires_at"
                case access
                case state
                case unlocked
                case freeUntil = "free_until"
            }
        }

        let body = ["identity_token": identityToken]
        let response: Response = try await post("/v1/session", body: body, authenticated: false)
        sessionToken = response.sessionToken
        sessionExpiry = Date(timeIntervalSince1970: response.expiresAt)
        storeAppAccess(
            response.access,
            topLevel: .init(
                state: response.state,
                unlocked: response.unlocked,
                freeUntil: response.freeUntil
            )
        )
    }

    /// Loads the read-only account snapshot with a short bounded retry. Opening
    /// Billing commonly races a network handoff as the app becomes active; a
    /// single lost connection must not strand the screen until the next app
    /// activation. Authentication and schema failures still fail immediately.
    static func balance() async throws -> Balance {
        let retryDelaysNanoseconds: [UInt64] = [250_000_000, 750_000_000]
        var retryIndex = 0

        while true {
            do {
                return try await fetchBalance()
            } catch {
                guard retryIndex < retryDelaysNanoseconds.count,
                      isRetryableBalanceError(error) else {
                    throw error
                }
                let delay = retryDelaysNanoseconds[retryIndex]
                retryIndex += 1
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    /// Kept internal so focused tests can prove that auth/schema failures are
    /// never hidden by retry while temporary transport/proxy failures recover.
    static func isRetryableBalanceError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled,
                 .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed,
                 .secureConnectionFailed,
                 .cannotLoadFromNetwork:
                return true
            default:
                return false
            }
        }

        guard let serviceError = error as? ServiceError else { return false }
        if serviceError.isInternalProxyFailure
            || serviceError.code == "service_unavailable"
            || serviceError.code == "temporarily_unavailable"
            || serviceError.code == "database_unavailable" {
            return true
        }
        guard serviceError.code.hasPrefix("http_"),
              let status = Int(serviceError.code.dropFirst("http_".count)) else {
            return false
        }
        return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
    }

    private static func fetchBalance() async throws -> Balance {
        struct Response: Decodable {
            let disabled: Bool?
            let admin: Bool?
            let access: AppAccess?
            /// The paid app's fields the proxy also sends beside `access`:
            /// `state` here is the new state (`access.state` keeps the old one).
            let state: String?
            let unlocked: Bool?
            let freeUntil: String?

            enum CodingKeys: String, CodingKey {
                case disabled
                case admin
                case access
                case state
                case unlocked
                case freeUntil = "free_until"
            }
        }

        let response: Response = try await get(
            "/v1/balance",
            headers: ["X-ForeverLM-Day-Start": dayStartHeaderValue()]
        )
        storeAppAccess(
            response.access,
            topLevel: .init(
                state: response.state,
                unlocked: response.unlocked,
                freeUntil: response.freeUntil
            )
        )
        return Balance(disabled: response.disabled ?? false, isAdmin: response.admin ?? false)
    }

    /// Permanently removes the managed-AI account, including its balance,
    /// usage history, and saved billing profile. The private iCloud knowledge
    /// library is owned by the user's Apple account and is not sent here.
    static func deleteAccount(identityToken: String, authorizationCode: String) async throws {
        struct Response: Decodable {
            let deleted: Bool
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/account"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "identity_token": identityToken,
            "authorization_code": authorizationCode,
        ])
        try authenticate(&request)
        let response: Response = try await send(request)
        guard response.deleted else {
            throw ServiceError(code: "bad_response", message: "ForeverLM AI did not confirm account deletion.")
        }
        clearSession()
    }

    /// Stripe billing-portal URL: the user's plan, invoices, and receipts,
    /// under their own Stripe login.
    static func billingPortalURL() async throws -> URL {
        struct Response: Decodable {
            let portalURL: String
            enum CodingKeys: String, CodingKey { case portalURL = "portal_url" }
        }
        let response: Response = try await post("/v1/credits/portal", body: [String: String](), authenticated: true)
        guard let url = URL(string: response.portalURL) else {
            throw ServiceError(code: "bad_response", message: "Billing history returned an address the app couldn't open.")
        }
        return url
    }

    // MARK: - Transport

    private static func get<T: Decodable>(_ path: String, headers: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        try authenticate(&request)
        applyDeviceAttribution(&request)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try await send(request)
    }

    /// The learner's own day, named for the proxy by the instant local
    /// midnight fell (ISO-8601, UTC). The comp's "used today" is summed from
    /// there, so it turns over at the learner's midnight rather than UTC's,
    /// which is 5 pm in California.
    static func dayStartHeaderValue(now: Date = Date(), calendar: Calendar = .current) -> String {
        ISO8601DateFormatter().string(from: calendar.startOfDay(for: now))
    }

    /// A request to one of the proxy's own routes — not a provider URL rewritten
    /// through `rewrite`, but an endpoint the proxy serves itself, such as the
    /// video job route. Carries the session, the usage attribution the
    /// task-locals hold (task, subject, activity), and the device build, so the
    /// charge lands in the ledger the way every other billable request's does.
    static func billableProxyRequest(path: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        try authenticate(&request)
        applyUsageAttribution(
            &request,
            activityID: AIUsageAttribution.resolvedActivityID(
                AIUsageAttribution.activityID,
                sessionID: AIUsageAttribution.sessionID,
                fallback: UUID().uuidString
            )
        )
        applyDeviceAttribution(&request)
        return request
    }

    /// Internal rather than private so ManagedAIAppAccess.swift can start plan checkout.
    static func post<T: Decodable>(
        _ path: String,
        body: some Encodable,
        authenticated: Bool,
        usageActivityID: String? = nil
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        if authenticated { try authenticate(&request) }
        if let usageActivityID {
            applyUsageAttribution(
                &request,
                activityID: AIUsageAttribution.resolvedActivityID(
                    usageActivityID,
                    sessionID: nil,
                    fallback: UUID().uuidString
                )
            )
        }
        applyDeviceAttribution(&request)
        return try await send(request)
    }

    private static func authenticate(_ request: inout URLRequest) throws {
        guard let token = sessionToken else {
            throw ServiceError(code: "invalid_session", message: "Sign in with Apple to use ForeverLM AI.")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// The proxy's error envelope: `{error:{code,message}}`.
    private struct ErrorBody: Decodable {
        struct Payload: Decodable {
            let code: String
            let message: String
        }
        let error: Payload
    }

    /// Decodes the proxy's stable error envelope without interpreting its
    /// human-facing message. Provider requests use this too because every one
    /// is rewritten through the managed proxy before it leaves the app.
    static func serviceError(from data: Data) -> ServiceError? {
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else {
            return nil
        }
        return ServiceError(code: body.error.code, message: body.error.message)
    }

    /// An account the proxy says is locked: the plan it carries is what puts
    /// the pay screen up, so it is read again.
    static func surfaceIfNeeded(_ error: ServiceError) {
        if error.code == "no_own_key" {
            Task { @MainActor in
                NotificationCenter.default.post(name: .managedAICreditsEmpty, object: nil)
            }
            return
        }
        guard error.code == "app_locked" else { return }
        refreshAccess()
    }

    /// Whether AI work has nothing to run on: ForeverLM pays for none, so with
    /// no own key every AI request is refused (`rewrite`), and work that needs
    /// one waits until a key is stored.
    static var creditsAreEmpty: Bool { !hasOwnKey }

    /// Re-reads the plan after the proxy said the account is locked.
    ///
    /// Coalesced, because a refused batch fails many requests at once and they
    /// would otherwise each fetch the account.
    static func refreshAccess() {
        guard isSignedIn else { return }
        let alreadyRunning = accessRefreshLock.withLock {
            let running = accessRefreshInFlight
            if !running { accessRefreshInFlight = true }
            return running
        }
        guard !alreadyRunning else { return }
        Task.detached(priority: .utility) {
            defer {
                accessRefreshLock.withLock { accessRefreshInFlight = false }
            }
            // A failure here is not worth surfacing: the request that triggered
            // it already reported the refusal.
            _ = try? await balance()
        }
    }

    private static let accessRefreshLock = AppLock()
    nonisolated(unsafe) private static var accessRefreshInFlight = false

    private static func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // The free days end on the proxy's clock, not this device's.
        recordServerDate(http.value(forHTTPHeaderField: "Date"))

        guard (200...299).contains(http.statusCode) else {
            // The proxy always answers with {error:{code,message}}; surface both
            // rather than a generic status so the user sees what actually failed.
            if let error = serviceError(from: data) {
                if error.isInvalidSession { clearSession() }
                surfaceIfNeeded(error)
                throw error
            }
            throw ServiceError(
                code: "http_\(http.statusCode)",
                message: "ForeverLM AI returned an unexpected error (\(http.statusCode))."
            )
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// The phone's form of "ForeverLM's AI service could not be reached": the
/// Mac raises `AIError.serviceUnreachable`, whose file the iOS target does
/// not compile.
struct ManagedAIUnreachableError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension URLSession {
    /// `data(for:)` with a failure that never reached a provider renamed after
    /// what was actually unreachable. Every AI request path uses this rather
    /// than `data(for:)`, so the honest wording is the default and cannot be
    /// forgotten at a call site.
    func foreverLMData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await data(for: request)
        } catch {
            throw ManagedAI.namingUnreachableService(error)
        }
    }

    /// `bytes(for:)` under the same rule, for the streaming chat path.
    func foreverLMBytes(
        for request: URLRequest,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await bytes(for: request, delegate: delegate)
        } catch {
            throw ManagedAI.namingUnreachableService(error)
        }
    }
}
