import Foundation

extension Notification.Name {
    /// A managed request reached the proxy but the account had nothing to pay
    /// with: no own key, and no leftover balance. The app shell presents the
    /// blocking "add your OpenRouter key" prompt; feature views keep their own
    /// error state so the failed operation still has local context.
    static let managedAICreditsEmpty = Notification.Name("managedAICreditsEmpty")

    /// The account can pay again after having been empty (a key was added, or
    /// an operator granted balance). This is the moment work that was refused
    /// for want of payment becomes possible, so it is what resumes it — a key
    /// the app never acts on leaves the learner pressing the button again on a
    /// source that can already be paid for.
    static let managedAICreditsRestored = Notification.Name("managedAICreditsRestored")
    /// The learner stored, replaced, or removed their own router key.
    static let managedAIOwnKeyDidChange = Notification.Name("managedAIOwnKeyDidChange")
    /// A session was stored or cleared: the learner signed in or out. A "sign in"
    /// error shown before it no longer describes this Mac, so whoever shows one
    /// clears it here.
    static let managedAISessionDidChange = Notification.Name("managedAISessionDidChange")
}

/// "ForeverLM AI" — the managed rail. Since 2026-09-25 AI features run on the
/// learner's own OpenRouter key, which runs for every signed-in account, paid
/// or not (only MCP is paid for; see `ManagedAI.AppAccess`); an account's
/// leftover prepaid balance, and operator grants and comps, still pay through
/// this proxy.
///
/// Requests go to the metered proxy (`workers/ai-proxy`, ai.foreverlm.com), which
/// authenticates the user's session, meters the response server-side, debits any
/// balance it pays from, and forwards to OpenRouter for text or the explicitly selected
/// first-party media route. No provider key exists in this app;
/// the session token is the only credential, and it is minted from Sign in with
/// Apple.
///
/// This proxy is the only managed credential boundary. The app once also supported routing through the user's
/// own Cloudflare AI Gateway on their own keys, with local provider keys as a
/// third path; both are gone. Only the proxy can attach upstream attribution and
/// hold the inference keys without shipping them in the app bundle. Neither managed
/// provider route is an automatic fallback for another.
/// Spec: docs/managed-ai-billing.md.
enum ManagedAI {

    /// The metered proxy. Every managed request and account call goes here.
    static let baseURL = URL(string: "https://ai.foreverlm.com")!
    /// Listen on OpenAI's voices, which the proxy speaks itself
    /// (`ArticleSpeechCatalog.openAIRealtimeModelID`). Not below /v1/proxy:
    /// no OpenAI API is passed through, and the learner's own OpenRouter key
    /// cannot reach it, so `rewrite` keeps it on the proxy either way.
    static let openAISpeechURL = URL(string: "https://ai.foreverlm.com/v1/openai/speech")!
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
        // model's answer: on 2026-09-24 `RenderedReaderPageAdoptionTests
        // .paperFullTextBecomesContent` failed on every signed-in run because
        // a real Paper Metadata call found no author. Only the opt-in live
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
        /// to `host`, straight to the router.
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

    /// Header builds before 2026-09-25 carried the key to the proxy in. This
    /// build never sets it: the key goes to its router and nowhere else.
    static let ownKeyHeader = "X-ForeverLM-Own-Key"

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
        ownKeyHeader
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
        // the phone gets the same words as its own error (the iOS build had
        // failed on this line since 2026-09-17).
        return ManagedAIUnreachableError(message: message)
        #endif
    }

    /// Whether a request bound for `host` leaves on the learner's own router
    /// key, straight to that router, instead of through the metered proxy.
    ///
    /// The single statement of the rule: `rewrite` routes by it, and the
    /// OpenRouter body builder asks it whether to request the billed cost that
    /// the proxy would otherwise have resolved on the app's behalf.
    /// The key leaves direct whenever one is stored for that router; paying
    /// for MCP never decides it.
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
        guard let host = host?.lowercased(), let own = ownKey else { return false }
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
    #endif

    private static let ownKeyLock = NSLock()
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
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
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
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
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
        if stored != nil, creditsAreEmpty {
            creditsAreEmpty = false
        }
        NotificationCenter.default.post(name: .managedAIOwnKeyDidChange, object: nil)
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

    /// Rewrites a provider-native request to the metered proxy.
    ///
    /// Keys off the request's own **host**, not a caller-supplied provider label:
    /// several call sites pass a hardcoded (and occasionally wrong) provider
    /// string, so trusting the label would misroute them.
    /// Missing sessions, malformed URLs, and unknown hosts still end at the
    /// proxy. Nothing ForeverLM pays for is ever left pointing at a provider,
    /// which makes routing failures explicit and prevents stale keys from older
    /// builds escaping. The learner's own router key is the one exception, and
    /// it is taken below on the same host test the key is attached by.
    static func rewrite(_ request: inout URLRequest) {
        let token = requestSessionToken
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

        // Path the proxy expects, provider-native below /v1/proxy/{provider}.
        // OpenRouter is the proxy's only upstream: text never travels a lab's
        // own API (see `AIService.openAICompatibleChatEndpoint`), and the
        // first-party media routes answer 410 since 2026-10-02.
        let path: String
        let queryItems: [URLQueryItem]
        switch host {
        case openAISpeechURL.host?.lowercased() where originalURL?.path == openAISpeechURL.path:
            // A route the proxy serves itself, kept as it is.
            path = openAISpeechURL.path
            queryItems = []
        case "openrouter.ai":
            path = "openrouter" + (originalURL?.path ?? "")
            // OpenRouter takes its key only as a header, so the query (a
            // generation lookup's `id`, for one) passes through whole.
            queryItems = originalURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        default:
            // Deliberately reaches a non-existent proxy endpoint and fails 404.
            // It must never preserve an unknown provider URL as a fallback,
            // its query included: a lab's own API can carry its key as `?key=`.
            path = "unsupported"
            queryItems = []
        }

        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.path = path.hasPrefix("/") ? path : "/v1/proxy/" + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        request.url = components.url ?? baseURL.appendingPathComponent("v1/rejected-route")

        // The session token is the only credential on this rail.
        for header in providerCredentialHeaders {
            request.setValue(nil, forHTTPHeaderField: header)
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // The learner's key never travels to ForeverLM: a request bound for
        // its router with the key stored went direct above.
        request.setValue(nil, forHTTPHeaderField: ownKeyHeader)

        applyUsageAttribution(
            &request,
            activityID: AIUsageAttribution.resolvedActivityID(
                AIUsageAttribution.activityID,
                sessionID: AIUsageAttribution.sessionID,
                fallback: UUID().uuidString
            )
        )
        if AIResponseCachePolicy.deterministic {
            request.setValue("deterministic", forHTTPHeaderField: "X-ForeverLM-Response-Cache")
        }
        applyDeviceAttribution(&request)
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
    /// Realtime voice (removed 2026-10-01) billed through the control plane,
    /// never through `rewrite`, and applying this only in `rewrite` left every
    /// voice session's ledger row with no platform (found 2026-08-07).
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

    /// Balance is USD on the wire and in the UI; the ledger stays micro-USD
    /// precise. Nothing adds balance except an operator grant: prepaid
    /// top-ups are not sold (`balance_retired`).
    static func creditBalanceText(microUSD: Int) -> String {
        max(0, Double(microUSD) / 1_000_000).formatted(
            .currency(code: "USD").precision(.fractionLength(2))
        )
    }

    struct Balance: Sendable {
        /// Remaining credit in micro-USD (1 USD = 1_000_000). Can go slightly
        /// negative: a request in flight may overshoot an almost-empty balance.
        let microUSD: Int
        let disabled: Bool
        /// Usage on this account is comped: the proxy skips the balance check and
        /// records the real cost without debiting it. The balance figure is then
        /// a historical number, not a spending limit.
        let billingExempt: Bool
        /// This account may grant itself balance. Server-decided; the app only
        /// decides whether to show the control.
        let isAdmin: Bool
        let recent: [LedgerEntry]
        let spendCap: SpendCap
        /// nil for an account that pays for itself. Present for a beta tester the
        /// operator comps, carrying the router their text models must use and the
        /// operator's monthly ceiling on the comp.
        let comp: Comp?

        var usd: Double { Double(microUSD) / 1_000_000 }
        var credits: Double { Double(microUSD) / 10_000 }

        /// Whether AI work has to stop. A comped account is never out of balance
        /// however far below zero its history sits, so every caller that gates
        /// work on this — onboarding, the rail banner, the paper pipeline — keeps
        /// working without asking about exemption itself.
        /// Whether the account cannot pay for AI. A learner's own router key
        /// pays for every model without the balance, so an empty balance
        /// beside a key gates nothing.
        var isEmpty: Bool { microUSD <= 0 && !billingExempt && !ManagedAI.hasOwnKey }
    }

    /// A comped beta account, as the server describes it.
    ///
    /// A comp is unlimited and carries no allowance, so the month's spend here is
    /// reporting rather than a budget: it is the only honest number to show when
    /// the balance beside it is history that a comp does not move.
    struct Comp: Sendable {
        /// Transport the account's text models must use, e.g. "openrouter".
        let textRouter: String?
        let spentThisMonthMicroUSD: Int
        /// Today's comped spend, over the learner's own day (the UTC day from a
        /// worker that predates the day-start header). nil from a worker that
        /// predates the figure.
        let spentTodayMicroUSD: Int?

        var routingMode: AITextRoutingMode? {
            textRouter.flatMap(AITextRoutingMode.init(serverToken:))
        }
        var spentThisMonthUSD: Double { Double(spentThisMonthMicroUSD) / 1_000_000 }
    }

    /// The user's optional monthly ceiling on managed-AI spend.
    ///
    /// Both figures are the complete underlying AI-cost debit, so the UI can
    /// show "x of y" without applying pricing again.
    struct SpendCap: Sendable {
        /// nil when no cap is set, which is the default.
        let monthlyLimitMicroUSD: Int?
        let spentThisMonthMicroUSD: Int
        /// When the month's total rolls back to zero (UTC month boundary).
        let resetsAt: String?
        /// Largest cap the server will store, for bounding the picker.
        let maximumUSD: Int

        var isSet: Bool { monthlyLimitMicroUSD != nil }
        var limitUSD: Double? { monthlyLimitMicroUSD.map { Double($0) / 1_000_000 } }
        var spentThisMonthUSD: Double { Double(spentThisMonthMicroUSD) / 1_000_000 }

        var isReached: Bool {
            guard let limit = monthlyLimitMicroUSD else { return false }
            return spentThisMonthMicroUSD >= limit
        }
    }

    struct LedgerEntry: Sendable, Identifiable {
        let id = UUID()
        /// "allowance" | "purchase" | "auto_topup" | "usage" | "refund" | "adjustment"
        let kind: String
        let microUSD: Int
        let model: String?
        /// Feature label supplied by the client and persisted by the managed
        /// proxy. Nil for calls from builds predating server attribution.
        let task: String?
        /// Article, paper, or book title supplied for source-bound background
        /// work. Nil for chat, non-source tasks, and older app builds.
        let sourceTitle: String?
        let requestID: String?
        let clientPlatform: String?
        let clientBuild: String?
        let createdAt: String

        var usd: Double { Double(microUSD) / 1_000_000 }
        var credits: Double { Double(microUSD) / 10_000 }
    }

    /// One authoritative usage debit from the proxy's D1 billing ledger.
    /// Unlike the client recorder, this row exists only after server metering
    /// completed and includes the actual margin-adjusted amount.
    struct UsageLedgerEvent: Codable, Sendable {
        let id: Int64
        let provider: String
        let model: String
        let task: String?
        let sourceTitle: String?
        let subjectID: String?
        let subjectType: String?
        let activityID: String?
        let requestID: String?
        let inputTokens: Int?
        let outputTokens: Int?
        let cachedInputTokens: Int?
        let cacheWrite5mTokens: Int?
        let cacheWrite1hTokens: Int?
        let reasoningTokens: Int?
        let webSearchCalls: Int?
        let billedMicrousd: Int
        let exactCost: Int
        /// The learner's own router key paid for this row (migration 0041);
        /// `billed_microusd` is then what their router charged them, not a debit.
        var ownKey: Int? = nil
        /// Who paid when it was neither the learner's balance nor their key:
        /// `foreverlm_openai_credits` for voice mode (migration 0051).
        var paidBy: String? = nil
        let clientPlatform: String?
        let clientBuild: String?
        let createdAtUnix: TimeInterval

        enum CodingKeys: String, CodingKey {
            case id, provider, model, task
            case sourceTitle = "source_title"
            case subjectID = "subject_id"
            case subjectType = "subject_type"
            case activityID = "activity_id"
            case requestID = "request_id"
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case cacheWrite5mTokens = "cache_write_5m_tokens"
            case cacheWrite1hTokens = "cache_write_1h_tokens"
            case reasoningTokens = "reasoning_tokens"
            case webSearchCalls = "web_search_calls"
            case billedMicrousd = "billed_microusd"
            case exactCost = "exact_cost"
            case ownKey = "own_key"
            case paidBy = "paid_by"
            case clientPlatform = "client_platform"
            case clientBuild = "client_build"
            case createdAtUnix = "created_at_unix"
        }
    }

    struct UsageLedgerPage: Decodable, Sendable {
        let events: [UsageLedgerEvent]
        let nextAfterID: Int64
        let hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case events
            case nextAfterID = "next_after_id"
            case hasMore = "has_more"
        }
    }

    /// An error the proxy reported, carrying its machine-readable code so callers
    /// can branch (notably `credits_empty` → the add-your-key prompt) while showing the
    /// server's own message verbatim. No fallback text is invented here.
    struct ServiceError: LocalizedError, Sendable {
        let code: String
        let message: String
        var errorDescription: String? { message }

        var isCreditsEmpty: Bool { code == "credits_empty" }
        var isInvalidSession: Bool { code == "invalid_session" }
        /// The proxy closed the account (an operator, a Stripe dispute, or
        /// three metering failures in a row). The balance's `disabled` is the
        /// same flag, so a later balance read can say it no longer holds.
        var isAccountDisabled: Bool { code == "account_disabled" }
        /// The proxy refused the transport this client named. It means the
        /// account-wide policy moved while this client was running, so the
        /// stored policy is stale rather than the request being wrong.
        var isStaleTextRouter: Bool { code == "text_router_required" }
        /// The proxy's catch-all for a thrown failure (a D1 outage, Apple's
        /// JWKS unreachable, an upstream fetch that threw). It says nothing
        /// about the request, so it is as retryable as an `http_5xx`. The proxy
        /// answers `internal`; `internal_error` is the older spelling.
        var isInternalProxyFailure: Bool { code == "internal" || code == "internal_error" }
    }

    /// The comp block both `/v1/session` and `/v1/balance` return. Optional
    /// throughout so a build newer than the deployed worker still decodes.
    struct CompRow: Decodable, Sendable {
        let active: Bool?
        let textRouter: String?
        let spentThisMonthMicrousd: Int?
        var spentTodayMicrousd: Int? = nil

        enum CodingKeys: String, CodingKey {
            case active
            case textRouter = "text_router"
            case spentThisMonthMicrousd = "spent_this_month_microusd"
            case spentTodayMicrousd = "spent_today_microusd"
        }

        var comp: Comp {
            Comp(
                textRouter: textRouter,
                spentThisMonthMicroUSD: spentThisMonthMicrousd ?? 0,
                spentTodayMicroUSD: spentTodayMicrousd
            )
        }
    }

    /// Exchanges an Apple identity token for a session token, creating the account
    /// on first sign-in. Returns the balance the server reports so the caller can
    /// show it immediately.
    static func signIn(identityToken: String) async throws -> Int {
        struct Response: Decodable {
            let sessionToken: String
            let expiresAt: TimeInterval
            let balanceMicrousd: Int
            /// Optional so a build newer than the deployed worker still signs in.
            let billingExempt: Bool?
            /// Account-wide transport policy. Optional for the same reason, and
            /// its absence means the shipped default rather than "no policy".
            let textRouter: String?
            let comp: CompRow?
            /// The app plan. Optional so a build newer than the worker still signs in.
            let access: AppAccess?
            /// The paid app's fields the proxy also sends beside `access`:
            /// `state` here is the new state (`access.state` keeps the old one).
            let state: String?
            let unlocked: Bool?
            let freeUntil: String?
            /// Which models the account may pick; absent is any.
            let modelAccess: AIModelAccess?

            enum CodingKeys: String, CodingKey {
                case sessionToken = "session_token"
                case expiresAt = "expires_at"
                case balanceMicrousd = "balance_microusd"
                case billingExempt = "billing_exempt"
                case textRouter = "text_router"
                case comp
                case access
                case state
                case unlocked
                case freeUntil = "free_until"
                case modelAccess = "model_access"
            }
        }

        let body = ["identity_token": identityToken]
        let response: Response = try await post("/v1/session", body: body, authenticated: false)
        sessionToken = response.sessionToken
        sessionExpiry = Date(timeIntervalSince1970: response.expiresAt)
        creditsAreEmpty = response.balanceMicrousd <= 0 && response.billingExempt != true && !hasOwnKey
        // Sign-in is the first moment the app can learn the account's transport
        // policy, so the launch's very first request already uses it.
        applyTextRouterPolicy(response.textRouter, comp: response.comp)
        storeAppAccess(
            response.access,
            topLevel: .init(
                state: response.state,
                unlocked: response.unlocked,
                freeUntil: response.freeUntil
            )
        )
        AIModelAccess.store(response.modelAccess)
        return response.balanceMicrousd
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
            let balanceMicrousd: Int
            let disabled: Bool
            /// Optional so a build newer than the deployed worker still decodes.
            let billingExempt: Bool?
            let admin: Bool?
            let recent: [Row]

            struct Row: Decodable {
                let kind: String
                let amountMicrousd: Int
                let model: String?
                let task: String?
                let sourceTitle: String?
                let requestID: String?
                let clientPlatform: String?
                let clientBuild: String?
                let createdAt: String

                enum CodingKeys: String, CodingKey {
                    case kind
                    case amountMicrousd = "amount_microusd"
                    case model
                    case task
                    case sourceTitle = "source_title"
                    case requestID = "request_id"
                    case clientPlatform = "client_platform"
                    case clientBuild = "client_build"
                    case createdAt = "created_at"
                }
            }

            /// Optional so a build newer than the deployed worker still decodes
            /// a balance instead of failing the whole account screen.
            struct SpendCapRow: Decodable {
                let monthlyLimitMicrousd: Int?
                let spentThisMonthMicrousd: Int
                let resetsAt: String?
                let maximumUSD: Int

                enum CodingKeys: String, CodingKey {
                    case monthlyLimitMicrousd = "monthly_limit_microusd"
                    case spentThisMonthMicrousd = "spent_this_month_microusd"
                    case resetsAt = "resets_at"
                    case maximumUSD = "maximum_usd"
                }
            }

            enum CodingKeys: String, CodingKey {
                case balanceMicrousd = "balance_microusd"
                case disabled
                case billingExempt = "billing_exempt"
                case admin
                case recent
                case spendCap = "spend_cap"
                case textRouter = "text_router"
                case comp
                case access
                case state
                case unlocked
                case freeUntil = "free_until"
                case modelAccess = "model_access"
            }

            let spendCap: SpendCapRow?
            let textRouter: String?
            let comp: CompRow?
            let access: AppAccess?
            /// The paid app's fields the proxy also sends beside `access`:
            /// `state` here is the new state (`access.state` keeps the old one).
            let state: String?
            let unlocked: Bool?
            let freeUntil: String?
            /// Which models the account may pick; absent is any.
            let modelAccess: AIModelAccess?
        }

        let response: Response = try await get(
            "/v1/balance",
            headers: ["X-ForeverLM-Day-Start": dayStartHeaderValue()]
        )
        let billingExempt = response.billingExempt ?? false
        creditsAreEmpty = response.balanceMicrousd <= 0 && !billingExempt && !hasOwnKey
        // The recurring chance to re-learn the policy: a router switched while
        // this client was already running reaches it here rather than waiting
        // for a new build.
        applyTextRouterPolicy(response.textRouter, comp: response.comp)
        storeAppAccess(
            response.access,
            topLevel: .init(
                state: response.state,
                unlocked: response.unlocked,
                freeUntil: response.freeUntil
            )
        )
        AIModelAccess.store(response.modelAccess)
        return Balance(
            microUSD: response.balanceMicrousd,
            disabled: response.disabled,
            billingExempt: billingExempt,
            isAdmin: response.admin ?? false,
            recent: response.recent.map {
                LedgerEntry(
                    kind: $0.kind,
                    microUSD: $0.amountMicrousd,
                    model: $0.model,
                    task: $0.task,
                    sourceTitle: $0.sourceTitle,
                    requestID: $0.requestID,
                    clientPlatform: $0.clientPlatform,
                    clientBuild: $0.clientBuild,
                    createdAt: $0.createdAt
                )
            },
            spendCap: SpendCap(
                monthlyLimitMicroUSD: response.spendCap?.monthlyLimitMicrousd,
                spentThisMonthMicroUSD: response.spendCap?.spentThisMonthMicrousd ?? 0,
                resetsAt: response.spendCap?.resetsAt,
                maximumUSD: response.spendCap?.maximumUSD ?? 10_000
            ),
            comp: response.comp?.active == true ? response.comp?.comp : nil
        )
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
        // A deleted account's transport policy would otherwise outlive it and
        // lock the next account signed in on this Mac to the old router.
        applyTextRouterPolicy(nil, comp: nil)
        clearSession()
    }

    static func usageEvents(after ledgerID: Int64, limit: Int = 1_000) async throws -> UsageLedgerPage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/usage/events"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "after_id", value: String(max(0, ledgerID))),
            URLQueryItem(name: "limit", value: String(min(max(1, limit), 1_000))),
        ]
        guard let url = components?.url else {
            throw ServiceError(code: "bad_request", message: "Could not construct the AI usage reconciliation request.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try authenticate(&request)
        return try await send(request)
    }

    /// Set the monthly spending cap, or pass nil to remove it.
    ///
    /// The amount is what the account is charged, margin included — the same
    /// number the balance and history show — so the cap means what the user
    /// reads it to mean. Returns the month's spend so far so a cap set below it
    /// can be reported as already reached without a second round trip.
    @discardableResult
    static func setSpendCap(monthlyLimitUSD: Double?) async throws -> SpendCap {
        struct Response: Decodable {
            let monthlyLimitMicrousd: Int?
            let spentThisMonthMicrousd: Int

            enum CodingKeys: String, CodingKey {
                case monthlyLimitMicrousd = "monthly_limit_microusd"
                case spentThisMonthMicrousd = "spent_this_month_microusd"
            }
        }
        // `encode` rather than the synthesized `encodeIfPresent`, so clearing
        // the cap sends an explicit `null` instead of dropping the key. The
        // server rejects a body with no `monthly_limit_usd` at all — it refuses
        // to guess whether a missing field meant "no cap" or a client bug — so
        // the synthesized conformance would make "Remove cap" fail with a 400.
        struct Body: Encodable {
            let monthlyLimitUSD: Double?
            enum CodingKeys: String, CodingKey { case monthlyLimitUSD = "monthly_limit_usd" }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(monthlyLimitUSD, forKey: .monthlyLimitUSD)
            }
        }
        let response: Response = try await post(
            "/v1/credits/spend-cap",
            body: Body(monthlyLimitUSD: monthlyLimitUSD),
            authenticated: true
        )
        return SpendCap(
            monthlyLimitMicroUSD: response.monthlyLimitMicrousd,
            spentThisMonthMicroUSD: response.spentThisMonthMicrousd,
            resetsAt: nil,
            maximumUSD: 10_000
        )
    }

    /// Result of an operator balance grant.
    struct Grant: Sendable {
        let balanceMicroUSD: Int
        /// True when the server recognised this attempt's key and added nothing,
        /// so a retry after a lost response reports honestly instead of twice.
        let alreadyGranted: Bool
    }

    /// Adds balance directly, with no payment and no Stripe object, for accounts
    /// the proxy recognises as operators. The server decides that; a non-operator
    /// account gets `not_admin` back however the button was reached.
    ///
    /// `idempotencyKey` must be stable across retries of the same intent: the
    /// ledger's unique index, not this client, is what stops a double grant.
    static func grantCredits(amountUSD: Int, idempotencyKey: String) async throws -> Grant {
        struct Body: Encodable {
            let amountUSD: Int
            let idempotencyKey: String

            enum CodingKeys: String, CodingKey {
                case amountUSD = "amount_usd"
                case idempotencyKey = "idempotency_key"
            }
        }
        struct Response: Decodable {
            let balanceMicrousd: Int
            let alreadyGranted: Bool?

            enum CodingKeys: String, CodingKey {
                case balanceMicrousd = "balance_microusd"
                case alreadyGranted = "already_granted"
            }
        }
        let response: Response = try await post(
            "/v1/credits/grant",
            body: Body(amountUSD: amountUSD, idempotencyKey: idempotencyKey),
            authenticated: true
        )
        // A grant is true the moment the server answers, so the local
        // exhausted flag can be cleared straight away.
        if response.balanceMicrousd > 0 { creditsAreEmpty = false }
        return Grant(
            balanceMicroUSD: response.balanceMicrousd,
            alreadyGranted: response.alreadyGranted ?? false
        )
    }

    // MARK: - Company spending caps

    /// What ForeverLM itself pays each model maker for, this UTC month and
    /// year, and the caps an operator set (product owner, 2026-11-07: "let me
    /// set that in settings, like per month caps for each provider. it can
    /// also be a per year cap"). Company-paid is voice on the company's OpenAI
    /// credits and every call on the proxy's own OpenRouter key; a learner's
    /// own key is neither counted nor capped. Operators only: anyone else gets
    /// `not_admin`, which the Settings section reads as "not shown".
    struct CompanySpendCaps: Decodable, Sendable {
        struct Period: Decodable, Sendable, Equatable {
            let capMicroUSD: Int?
            let spentMicroUSD: Int
            let reached: Bool
            let resetsAt: String

            enum CodingKeys: String, CodingKey {
                case capMicroUSD = "cap_microusd"
                case spentMicroUSD = "spent_microusd"
                case reached
                case resetsAt = "resets_at"
            }
        }

        struct Provider: Decodable, Sendable, Identifiable, Equatable {
            /// The maker as OpenRouter names it: "anthropic", "openai".
            let provider: String
            let label: String
            let month: Period
            let year: Period
            var id: String { provider }
        }

        let providers: [Provider]
    }

    enum CompanySpendCapPeriod: String, Sendable {
        case month
        case year
    }

    static func companySpendCaps() async throws -> CompanySpendCaps {
        try await get("/v1/admin/company-spend-caps")
    }

    /// Sets one cap, or removes it with nil, and returns the listing as it
    /// now stands.
    static func setCompanySpendCap(
        provider: String,
        period: CompanySpendCapPeriod,
        capUSD: Double?
    ) async throws -> CompanySpendCaps {
        // `encode` rather than `encodeIfPresent`: the server refuses a body
        // without `cap_usd`, so removing a cap must send an explicit null.
        struct Body: Encodable {
            let provider: String
            let period: String
            let capUSD: Double?
            enum CodingKeys: String, CodingKey {
                case provider, period
                case capUSD = "cap_usd"
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(provider, forKey: .provider)
                try container.encode(period, forKey: .period)
                try container.encode(capUSD, forKey: .capUSD)
            }
        }
        return try await post(
            "/v1/admin/company-spend-caps",
            body: Body(provider: provider, period: period.rawValue, capUSD: capUSD),
            authenticated: true
        )
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

    /// Publishes the one account failure that needs app-wide UI. Delivery is
    /// main-actor-bound because SwiftUI observes it at the app shell, while the
    /// network response is normally decoded on an AI or URLSession actor.
    static func surfaceIfNeeded(_ error: ServiceError) {
        // A stale policy: the balance fetch re-reads it.
        if error.isStaleTextRouter {
            refreshTextRouterPolicy()
            return
        }
        guard error.isCreditsEmpty else { return }
        // With the learner's own key every model is paid for, so a balance
        // refusal here is the proxy's own message about a stray request;
        // marking the account empty would make chat refuse to send, which
        // the key still pays for.
        guard !hasOwnKey else { return }
        creditsAreEmpty = true
        Task { @MainActor in
            NotificationCenter.default.post(name: .managedAICreditsEmpty, object: nil)
        }
    }

    /// Re-reads the account-wide transport policy after the proxy refused the
    /// transport this client named.
    ///
    /// Deliberately not a retry of the failed request: the AI call still fails
    /// loudly with the proxy's own message, and nothing here re-dispatches it
    /// onto a second provider. All this does is make the *next* request use the
    /// router the server now names, so recovery costs one visible failure rather
    /// than an app relaunch.
    ///
    /// Coalesced, because a refused batch fails many requests at once and they
    /// would otherwise each fetch the balance.
    static func refreshTextRouterPolicy() {
        guard isSignedIn else { return }
        let alreadyRunning = policyRefreshLock.withLock {
            let running = policyRefreshInFlight
            if !running { policyRefreshInFlight = true }
            return running
        }
        guard !alreadyRunning else { return }
        Task.detached(priority: .utility) {
            defer {
                policyRefreshLock.withLock { policyRefreshInFlight = false }
            }
            // A failure here is not worth surfacing: the request that triggered
            // it already reported the refusal, and the next balance fetch of the
            // launch picks the policy up anyway.
            _ = try? await balance()
        }
    }

    private static let policyRefreshLock = NSLock()
    nonisolated(unsafe) private static var policyRefreshInFlight = false

    /// Last known answer to "can this account pay for an AI call?", durable so
    /// code outside the UI can ask without a network round trip.
    ///
    /// Written by the two places that learn it for a fact: a balance fetch, and
    /// the proxy refusing a call for want of credit. Defaults to false — an app
    /// that has never asked must not behave as though the account were empty.
    static var creditsAreEmpty: Bool {
        get { Preferences.value(Prefs.Models.managedCreditsAreEmpty) ?? false }
        set {
            let wasEmpty = Preferences.value(Prefs.Models.managedCreditsAreEmpty) ?? false
            Preferences.set(newValue, for: Prefs.Models.managedCreditsAreEmpty)
            // Announce the edge, not the state: both writers (a balance fetch
            // and an operator grant) can report a healthy balance repeatedly,
            // and only the transition out of empty is a new fact for paused
            // work to act on.
            guard wasEmpty, !newValue else { return }
            Task { @MainActor in
                NotificationCenter.default.post(name: .managedAICreditsRestored, object: nil)
            }
        }
    }

    /// Records the account's transport policy from the two places that learn it:
    /// signing in and fetching the balance.
    ///
    /// The top-level field is the account-wide policy and outranks everything
    /// else. The comp block is still read as a fallback so a client talking to a
    /// worker that predates the account-wide field keeps working; a comp no
    /// longer means a *different* router, only that the same policy arrived by
    /// the older route.
    ///
    /// A response carrying neither clears the stored token, which resolves to
    /// the shipped default rather than to "no policy" — the app has no third
    /// state where text has no transport.
    static func applyTextRouterPolicy(_ accountWide: String?, comp row: CompRow?) {
        let compToken = row?.active == true ? row?.textRouter : nil
        requiredTextRouterToken = accountWide ?? compToken
    }

    /// The router this account's text models must use, as the server named it.
    /// Persisted because routing is resolved synchronously at the moment a
    /// request is dispatched, including before the first balance fetch of a
    /// launch: the proxy refuses a request that names a different transport, so
    /// the last policy this device was told is the only safe thing to open with.
    ///
    /// Never a synced preference: this is server policy for one account, not a
    /// choice to carry onto another device's launch.
    static var requiredTextRouterToken: String? {
        get { Preferences.value(Prefs.Models.managedRequiredTextRouter) }
        set {
            guard let newValue, !newValue.isEmpty else {
                Preferences.reset(Prefs.Models.managedRequiredTextRouter)
                return
            }
            Preferences.set(newValue, for: Prefs.Models.managedRequiredTextRouter)
        }
    }

    /// nil when this device has not been told a policy yet, or was told one it
    /// does not understand. Both resolve to the shipped default at the call
    /// site: a token from a newer server than this build must never silently
    /// become "route however you like".
    static var requiredTextRoutingMode: AITextRoutingMode? {
        guard let token = requiredTextRouterToken else { return nil }
        return AITextRoutingMode(serverToken: token)
    }

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

/// Which models the account may pick, as the proxy says on every session and
/// balance read (`model_access`): its makers' models and, when `freeModels`,
/// OpenRouter's free ones. A subsidized ("covered") account gets Anthropic and
/// OpenAI; everyone else gets nil, which is any model (product owner,
/// 2026-11-09: subsidized users "should not see all the models").
///
/// It binds only while ForeverLM pays, so it lapses while the learner's own
/// OpenRouter key is stored: that key pays for whatever it runs. The proxy
/// refuses any other model for the account; the pickers hide what it would
/// refuse, and `permittedSlug` moves a stored pick it would refuse onto one it
/// serves, so the account's work runs instead of failing.
struct AIModelAccess: Codable, Equatable, Sendable {
    let makers: [String]
    let freeModels: Bool

    enum CodingKeys: String, CodingKey {
        case makers
        case freeModels = "free_models"
    }

    /// What runs in place of a stored pick the account may not use: Anthropic's
    /// cheapest current model, which reads images and runs every background
    /// task, on the Anthropic credits the account is covered by.
    static let substituteSlug = "anthropic/claude-haiku-5.5"

    /// Whether an OpenRouter slug (`maker/model`) is one this access covers.
    func allows(slug: String) -> Bool {
        let id = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if freeModels, id == "openrouter/free" || id.hasSuffix(":free") { return true }
        guard let slash = id.firstIndex(of: "/") else { return false }
        return makers.contains { $0.lowercased() == id[..<slash] }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: AIModelAccess??

    /// The limit in force: nil while any model may be picked.
    static var current: AIModelAccess? {
        guard !ManagedAI.hasOwnKey else { return nil }
        return stored
    }

    /// Read outside the lock: UserDefaults is never touched under one.
    private static var stored: AIModelAccess? {
        if let cached = lock.withLock({ cache }) { return cached }
        let loaded = Preferences.value(Prefs.Models.managedModelAccess)
            .flatMap { try? JSONDecoder().decode(AIModelAccess.self, from: $0) }
        lock.withLock { if cache == nil { cache = .some(loaded) } }
        return loaded
    }

    /// Keeps what the proxy last said. A change rebuilds every picker.
    static func store(_ access: AIModelAccess?) {
        guard stored != access else { return }
        if let access, let data = try? JSONEncoder().encode(access) {
            Preferences.set(data, for: Prefs.Models.managedModelAccess)
        } else {
            Preferences.reset(Prefs.Models.managedModelAccess)
        }
        lock.withLock { cache = .some(access) }
        // `.aiProviderDidChange` by its name, which this file shares with
        // targets that do not compile KeychainService.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("aiProviderDidChange"), object: nil)
        }
    }

    /// Whether a picker may list this OpenRouter slug.
    static func allows(slug: String) -> Bool {
        current?.allows(slug: slug) ?? true
    }

    /// The slug to send: the one given, or `substitute` when the account may
    /// not use it.
    static func permittedSlug(_ slug: String, substitute: String = substituteSlug) -> String {
        current?.permitted(slug, substitute: substitute) ?? slug
    }

    /// `slug` when this access covers it, else `substitute`.
    func permitted(_ slug: String, substitute: String = AIModelAccess.substituteSlug) -> String {
        allows(slug: slug) ? slug : substitute
    }
}
