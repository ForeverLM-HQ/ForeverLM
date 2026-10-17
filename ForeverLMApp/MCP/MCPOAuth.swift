import Foundation
import CryptoKit
import OSLog
import Security

#if os(macOS)

/// OAuth 2.1 + PKCE provider for MCP server.
/// Supports dynamic client registration, authorization code flow, and token refresh.
/// Tokens persist to disk so clients don't need to re-auth after app restart.
actor MCPOAuthProvider {
    /// The initializer restores OAuth credentials and performs a one-time legacy
    /// file import. Keep that Keychain/file work off the caller's executor: the
    /// first access normally comes from a main-actor SwiftUI `.task` at launch.
    private static let sharedTask = Task.detached(priority: .userInitiated) {
        MCPOAuthProvider()
    }

    static func sharedProvider() async -> MCPOAuthProvider {
        await sharedTask.value
    }

    private let logger = Logger(subsystem: "ForeverLM", category: "MCPOAuth")

    // Stores — loaded from durable storage on the detached initializer, saved on mutation
    private var authCodes: [String: AuthCode] = [:]
    private var accessTokens: [String: TokenInfo] = [:]
    private var refreshTokens: [String: RefreshInfo] = [:]
    private var dynamicClients: [String: DynamicClient] = [:]

    private init() {
        let loaded = Self.loadPersistedTokens()
        accessTokens = loaded.accessTokens
        refreshTokens = loaded.refreshTokens
        dynamicClients = loaded.legacyDynamicClients.merging(Self.loadDynamicClientsFromKeychain()) { _, keychainClient in
            keychainClient
        }
        // Re-persist so a legacy oauth_tokens.json import lands in the Keychain.
        Self.persistTokens(accessTokens: accessTokens, refreshTokens: refreshTokens, dynamicClients: dynamicClients)
    }

    private let allowedRedirectHosts: Set<String> = [
        "claude.ai",
        "claude.com",
        "chatgpt.com",
        "platform.openai.com",
        "gemini.google.com",
        "platform.edisonscientific.com",
        "localhost",
        "127.0.0.1",
        "::1",
    ]

    struct AuthCode {
        let codeChallenge: String
        let redirectURI: String
        let clientID: String
        let expires: Date
        let scope: String
        let resource: String?
    }

    struct TokenInfo {
        let clientID: String
        let expires: Date
        /// Canonical granted scope raw value. Tokens persisted before scopes
        /// existed load as `mcp:tools` (full), matching what they were granted.
        let scope: String
    }

    struct RefreshInfo {
        let clientID: String
        let scope: String
        let resource: String?
    }

    struct DynamicClient {
        let clientSecret: String?
        let redirectURIs: [String]
        let tokenEndpointAuthMethod: String
        /// RFC 7591 `client_name` supplied at registration. This is what a
        /// plugin's sources are labeled with, so it is kept verbatim here
        /// and sanitized only where displayed or stamped.
        let clientName: String?
        /// RFC 7591 `logo_uri`, https-only (validated at registration).
        /// Rendered ONLY in the app's Plugins list — never on the
        /// consent surfaces, where a look-alike logo could dress a malicious
        /// authorization request up as a trusted product.
        let logoURI: String?
        /// Plugin-reported operational health. These fields live beside the
        /// OAuth grant in Keychain: they contain no source data or credentials,
        /// and let Settings distinguish "authorized" from "actually syncing".
        let lastSeenAt: Date?
        let lastSuccessfulSyncAt: Date?
        let reportedState: UserPluginHealthState?
        let statusDetail: String?
    }

    enum UserPluginHealthState: String, Codable, Sendable {
        case healthy
        case syncing
        case needsReconnect = "needs_reconnect"
        case error
    }

    // MARK: - Issuer URL

    private var configuredIssuerURL: String? {
        let rawValue = ProcessInfo.processInfo.environment["OAUTH_ISSUER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawValue, !rawValue.isEmpty else { return nil }
        return rawValue
    }

    private var preRegisteredClientID: String? {
        let val = KeychainService.load(.mcpOAuthClientID)
        return (val?.isEmpty == false) ? val : nil
    }

    private var preRegisteredClientSecret: String? {
        let val = KeychainService.load(.mcpOAuthClientSecret)
        return (val?.isEmpty == false) ? val : nil
    }

    // MARK: - Route Handler

    /// Handle all OAuth and discovery endpoints. Returns nil if not an OAuth path.
    func handleRequest(_ request: HTTPRequest) async -> HTTPResponse? {
        switch request.path {
        case "/.well-known/oauth-protected-resource":
            return handleProtectedResource(request)
        case "/.well-known/oauth-authorization-server", "/.well-known/openid-configuration":
            return handleAuthorizationServer(request)
        case "/oauth/authorize":
            return handleAuthorize(request)
        case "/oauth/approve":
            return handleApproveAuthorize(request)
        case "/oauth/pending":
            return handlePendingStatus(request)
        case "/oauth/token":
            return await handleToken(request)
        case "/oauth/register":
            return handleRegister(request)
        // /oauth/local-approve is intentionally absent: it must stay
        // unreachable through the relay and is registered only on the
        // loopback listener (see MCPServerLauncher).
        default:
            return nil
        }
    }

    /// Validate an access token (called by auth middleware). Returns what the
    /// token authorizes — owning client, granted scope, and the plugin label
    /// used for provenance stamping — or nil for an unknown/expired token.
    func validateAccessToken(_ token: String) -> MCPAccessContext? {
        cleanExpired()
        guard let info = accessTokens[token], info.expires > Date() else { return nil }
        return MCPAccessContext(
            clientID: info.clientID,
            scope: MCPAuthScope.effective(fromRequested: info.scope),
            connectorLabel: connectorLabel(forClientID: info.clientID),
            assistantName: dynamicClients[info.clientID]?.clientName.map(Self.sanitizedPluginLabel)
        )
    }

    /// The display label stamped onto sources a plugin-scoped client adds.
    /// Derived from the client's registered `client_name`; a client that never
    /// registered a name falls back to its client id, which the owner saw at
    /// consent time. Never derived from tool arguments, so it can't be spoofed.
    private func connectorLabel(forClientID clientID: String) -> String {
        Self.sanitizedPluginLabel(dynamicClients[clientID]?.clientName ?? clientID)
    }

    /// Plugin labels land in the synced `sources.connector_label` column and
    /// in UI text, so control characters become spaces (a newline mid-name must
    /// not merge two words), whitespace is collapsed, and length is bounded.
    /// Empty input falls back to "Plugin".
    static func sanitizedPluginLabel(_ raw: String) -> String {
        let space = Unicode.Scalar(32 as UInt8)
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            scalars.append((scalar.value < 0x20 || scalar.value == 0x7F) ? space : scalar)
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let bounded = String(collapsed.prefix(64)).trimmingCharacters(in: .whitespaces)
        return bounded.isEmpty ? "Plugin" : bounded
    }

    // MARK: - Discovery Endpoints

    private func handleProtectedResource(_ request: HTTPRequest) -> HTTPResponse {
        let issuerURL = issuerURL(for: request)
        return .json([
            "resource": issuerURL,
            "authorization_servers": [issuerURL],
            "bearer_methods_supported": ["header"],
            "scopes_supported": MCPAuthScope.advertised,
        ])
    }

    private func handleAuthorizationServer(_ request: HTTPRequest) -> HTTPResponse {
        let issuerURL = issuerURL(for: request)
        return .json([
            "issuer": issuerURL,
            "authorization_endpoint": "\(issuerURL)/oauth/authorize",
            "token_endpoint": "\(issuerURL)/oauth/token",
            "registration_endpoint": "\(issuerURL)/oauth/register",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "token_endpoint_auth_methods_supported": ["client_secret_post", "client_secret_basic", "none"],
            "code_challenge_methods_supported": ["S256"],
            "scopes_supported": MCPAuthScope.advertised,
        ])
    }

    // MARK: - Authorization
    //
    // OWNER-CONSENT GATE.
    // /oauth/authorize is reachable by anyone who can hit the public relay URL, so
    // without an owner check any caller could complete the flow and mint a working
    // access token for this user's entire knowledge base. Standard MCP clients
    // (Claude.ai / ChatGPT) drive the OAuth flow from discovery metadata and cannot
    // inject a custom query param, so consent is collected interactively:
    // /oauth/authorize records a pending authorization and renders a waiting page
    // in the user's browser, the app (same process) shows a native Approve/Deny
    // prompt with a match code, and the page polls /oauth/pending until the owner
    // resolves it. Both surfaces show the same two-digit match code so the owner
    // can't be raced into approving an attacker's concurrent request.
    //
    // Fallbacks that must stay: a valid pairing code as an `approval` query param
    // completes the flow directly (tests/advanced setups), and the waiting page
    // embeds a pairing-code form POSTing to /oauth/approve for owners who aren't
    // at the Mac (e.g. connecting from a phone while the app runs at home). The
    // pairing-recovery deep link MUST keep displaying
    // `MCPOAuthProvider.ownerPairingCode` for that path. Do not remove this gate.

    /// A browser-initiated authorization waiting for the owner to resolve it in the app.
    private struct PendingAuthorization {
        let params: [String: String]
        let clientName: String
        let matchCode: String
        let coalesceKey: String
        let expires: Date
        /// Scope the request would be granted on approval, so both consent
        /// surfaces can describe ingest-only requests accurately.
        let grantedScope: MCPAuthScope
        var resolution: Resolution?

        enum Resolution { case approved, denied }
    }

    private var pendingAuthorizations: [String: PendingAuthorization] = [:]
    private static let pendingAuthorizationTTL: TimeInterval = 300
    private static let maxPendingAuthorizations = 4

    private func handleAuthorize(_ request: HTTPRequest) -> HTTPResponse {
        let params = request.queryParams

        // Shortcut: a valid pairing code already supplied as a query param skips approval.
        if let approval = Self.suppliedApproval(in: params),
           constantTimeEquals(approval, Self.ownerPairingCode) {
            return completeAuthorization(params: params)
        }

        // Fully validate before prompting so the owner is never asked to approve
        // a request that would fail after their click anyway.
        if let error = validateAuthorizationParams(params) {
            return error
        }

        sweepExpiredPendingAuthorizations()

        // A reload of the consent URL re-sends identical params; reuse the pending
        // request instead of stacking a second prompt in the app.
        let coalesceKey = Self.coalesceKey(for: params)
        if let existing = pendingAuthorizations.first(where: {
            $0.value.coalesceKey == coalesceKey && $0.value.resolution == nil
        }) {
            return waitingPageResponse(requestID: existing.key, pending: existing.value)
        }

        // Anyone who knows the relay URL can hit this endpoint, so cap how many
        // prompts can be queued against the app at once.
        guard pendingAuthorizations.count < Self.maxPendingAuthorizations else {
            logger.warning("Rejected /oauth/authorize: too many pending authorizations")
            return .json(["error": "temporarily_unavailable", "error_description": "Too many pending authorization requests. Try again in a few minutes."], status: 429)
        }

        let requestID = generateToken()
        let pending = PendingAuthorization(
            params: params,
            clientName: Self.clientDisplayName(clientID: params["client_id"], redirectURI: params["redirect_uri"]),
            matchCode: String(format: "%02d", Int.random(in: 0...99)),
            coalesceKey: coalesceKey,
            expires: Date().addingTimeInterval(Self.pendingAuthorizationTTL),
            grantedScope: MCPAuthScope.effective(fromRequested: params["scope"]),
            resolution: nil
        )
        pendingAuthorizations[requestID] = pending
        logger.info("Created pending authorization for \(pending.clientName); waiting for in-app approval")
        notifyPendingAuthorizationsChanged()
        return waitingPageResponse(requestID: requestID, pending: pending)
    }

    private static func coalesceKey(for params: [String: String]) -> String {
        ["client_id", "redirect_uri", "code_challenge", "state", "scope"]
            .map { params[$0] ?? "" }
            .joined(separator: "|")
    }

    /// Browser polling endpoint for the waiting page. The request ID is an
    /// unguessable token known only to the browser that initiated the flow, so
    /// returning the code-bearing redirect URL here does not widen access.
    private func handlePendingStatus(_ request: HTTPRequest) -> HTTPResponse {
        sweepExpiredPendingAuthorizations()
        guard let requestID = request.queryParams["request"],
              let pending = pendingAuthorizations[requestID] else {
            return .json(["status": "expired"])
        }

        switch pending.resolution {
        case nil:
            return .json(["status": "pending"])
        case .approved:
            pendingAuthorizations.removeValue(forKey: requestID)
            guard let redirectURL = issueAuthorizationRedirect(params: pending.params) else {
                return .json(["status": "expired"])
            }
            logger.info("Delivered approved authorization to \(pending.clientName)")
            return .json(["status": "approved", "redirect_url": redirectURL])
        case .denied:
            pendingAuthorizations.removeValue(forKey: requestID)
            var payload: [String: Any] = ["status": "denied"]
            if let redirectURL = deniedRedirectURL(params: pending.params) {
                payload["redirect_url"] = redirectURL
            }
            return .json(payload)
        }
    }

    // MARK: In-app approval surface

    /// Pending requests for the app's approval prompt, oldest first.
    func pendingAuthorizationSummaries() -> [MCPPendingAuthorizationSummary] {
        sweepExpiredPendingAuthorizations()
        return pendingAuthorizations
            .filter { $0.value.resolution == nil }
            .map {
                MCPPendingAuthorizationSummary(
                    id: $0.key,
                    clientName: $0.value.clientName,
                    matchCode: $0.value.matchCode,
                    expires: $0.value.expires,
                    ingestOnly: $0.value.grantedScope == .ingest
                )
            }
            .sorted { $0.expires < $1.expires }
    }

    /// Resolve a pending request from the app's approval prompt. The browser
    /// waiting page picks the resolution up on its next poll.
    func resolveAuthorization(id: String, approved: Bool) {
        sweepExpiredPendingAuthorizations()
        guard var pending = pendingAuthorizations[id], pending.resolution == nil else { return }
        pending.resolution = approved ? .approved : .denied
        pendingAuthorizations[id] = pending
        logger.info("Owner \(approved ? "approved" : "denied", privacy: .public) authorization for \(pending.clientName)")
        notifyPendingAuthorizationsChanged()
    }

    private func sweepExpiredPendingAuthorizations() {
        let now = Date()
        let expired = pendingAuthorizations.filter { $0.value.expires <= now }
        guard !expired.isEmpty else { return }
        for key in expired.keys {
            pendingAuthorizations.removeValue(forKey: key)
        }
        if expired.contains(where: { $0.value.resolution == nil }) {
            notifyPendingAuthorizationsChanged()
        }
    }

    private func notifyPendingAuthorizationsChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .mcpPendingAuthorizationsChanged, object: nil)
        }
    }

    // MARK: Same-machine zero-click approval
    //
    // Served ONLY by the loopback listener (`MCPServerLauncher` registers this
    // route there); the relay dispatch in `handleRequest` has no case for this
    // path, so it is unreachable from the public tunnel URL. The waiting page —
    // served from the tunnel origin — fires a fetch at 127.0.0.1: reaching this
    // endpoint proves the browser sits on the same Mac as the app, which is
    // stronger owner evidence than a typed pairing code. Two things keep a
    // malicious website from driving this: browsers attach an unforgeable
    // Origin header to cross-origin fetches and only this install's own tunnel
    // origin is accepted, and the waiting page forbids framing
    // (frame-ancestors 'none') so it can't be embedded invisibly. Request IDs
    // are unguessable and known only to the initiating browser tab.
    //
    // Chrome gates public-site → loopback fetches behind Private Network
    // Access, which sends a CORS preflight first — hence the OPTIONS branch
    // with Access-Control-Allow-Private-Network. Safari blocks the fetch as
    // mixed content; there the in-app prompt simply remains the flow.

    func handleLocalApprove(_ request: HTTPRequest) -> HTTPResponse {
        guard MCPRuntimePreferences.zeroClickOAuthApprovalEnabled else {
            return .json(["error": "disabled"], status: 403)
        }
        guard let origin = firstHeaderValue(named: "origin", in: request.headers),
              isTrustedLocalApproveOrigin(origin) else {
            logger.warning("Rejected /oauth/local-approve: missing or untrusted Origin header")
            return .json(["error": "forbidden"], status: 403)
        }

        let corsHeaders = [
            "Access-Control-Allow-Origin": origin,
            "Vary": "Origin",
        ]

        if request.method == "OPTIONS" {
            var headers = corsHeaders
            headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
            headers["Access-Control-Allow-Headers"] = "content-type"
            headers["Access-Control-Allow-Private-Network"] = "true"
            headers["Access-Control-Max-Age"] = "600"
            return HTTPResponse(status: 204, statusText: "No Content", headers: headers, body: Data())
        }
        guard request.method == "POST" else {
            return .json(["error": "method_not_allowed"], status: 405)
        }

        sweepExpiredPendingAuthorizations()
        let params = parseTokenParams(request)
        guard let requestID = params["request"],
              let pending = pendingAuthorizations[requestID],
              pending.resolution == nil else {
            return .json(["error": "unknown_request"], status: 404)
        }

        logger.notice("Auto-approving authorization for \(pending.clientName): browser proved same-machine via loopback")
        resolveAuthorization(id: requestID, approved: true)
        return HTTPResponse(status: 204, statusText: "No Content", headers: corsHeaders, body: Data())
    }

    /// Only the page this install itself serves may drive same-machine
    /// approval: the tunnel/issuer origin, or loopback during local testing.
    private func isTrustedLocalApproveOrigin(_ origin: String) -> Bool {
        guard let originURL = URL(string: origin),
              let originHost = originURL.host?.lowercased() else {
            return false
        }
        if let issuer = ProcessInfo.processInfo.environment["OAUTH_ISSUER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let issuerURL = URL(string: issuer),
           let issuerHost = issuerURL.host?.lowercased(),
           originHost == issuerHost,
           originURL.scheme?.lowercased() == issuerURL.scheme?.lowercased() {
            return true
        }
        return ["localhost", "127.0.0.1", "::1"].contains(originHost)
    }

    /// Handle the owner-consent form POST. Validates the entered pairing code and,
    /// on success, issues the auth code + redirect. On a wrong code, re-renders the
    /// consent page with an error so no token is issued without owner approval.
    private func handleApproveAuthorize(_ request: HTTPRequest) -> HTTPResponse {
        let params = parseTokenParams(request)
        guard let approval = Self.suppliedApproval(in: params), !approval.isEmpty,
              constantTimeEquals(approval, Self.ownerPairingCode) else {
            logger.warning("Rejected /oauth/approve: missing or invalid owner pairing code")
            return consentPageResponse(
                params: params,
                error: "That pairing code was not correct. Open ForeverLM Settings to find the current code, then try again."
            )
        }
        return completeAuthorization(params: params)
    }

    /// Shared final step for the query-param shortcut and the pairing-code POST:
    /// fully validate the request and issue the auth code as a 302 redirect.
    private func completeAuthorization(params: [String: String]) -> HTTPResponse {
        if let error = validateAuthorizationParams(params) {
            return error
        }
        guard let redirectURL = issueAuthorizationRedirect(params: params) else {
            return .json(["error": "invalid_request"], status: 400)
        }
        return .redirect(redirectURL)
    }

    /// Full request validation shared by the direct flow and the pending-approval
    /// flow. Returns an error response, or nil when the request may proceed.
    private func validateAuthorizationParams(_ params: [String: String]) -> HTTPResponse? {
        guard params["response_type"] == "code" else {
            return .json(["error": "unsupported_response_type"], status: 400)
        }
        guard let clientID = params["client_id"] else {
            return .json(["error": "invalid_request", "error_description": "client_id required"], status: 400)
        }
        guard let redirectURI = params["redirect_uri"] else {
            return .json(["error": "invalid_request", "error_description": "redirect_uri required"], status: 400)
        }
        guard params["code_challenge"] != nil,
              params["code_challenge_method"] == "S256" else {
            return .json(["error": "invalid_request", "error_description": "PKCE S256 required"], status: 400)
        }

        // Validate client (recovery of loopback clients only happens behind the
        // owner-consent gate, so an unknown dyn_ client can't be auto-registered
        // by an unauthenticated caller).
        guard validateClient(clientID)
                || recoverDynamicLoopbackClient(clientID: clientID, redirectURI: redirectURI, requestedScope: params["scope"]) else {
            return Self.unknownClientResponse(clientID: clientID, status: 400)
        }

        guard isRedirectAllowed(redirectURI, clientID: clientID) else {
            return .json(["error": "invalid_request", "error_description": "redirect_uri not allowed"], status: 400)
        }

        // `state` is echoed back to the client verbatim, so reject control
        // characters that could smuggle headers into the redirect (response-splitting).
        if let state = params["state"], containsControlCharacters(state) {
            return .json(["error": "invalid_request", "error_description": "state contains control characters"], status: 400)
        }

        // Unknown scopes fail loudly rather than being silently dropped or
        // granted: a plugin asking for a scope this server never defined
        // should hear that, not receive a token whose reach it misjudges.
        if let scope = params["scope"], !scope.isEmpty, !MCPAuthScope.allTokensKnown(inRequested: scope) {
            return .json([
                "error": "invalid_scope",
                "error_description": "Supported scopes: mcp:tools (full access) and mcp:ingest (add sources only).",
            ], status: 400)
        }
        return nil
    }

    /// Mint an auth code and build the client redirect URL. Callers must have
    /// passed `params` through `validateAuthorizationParams` first.
    private func issueAuthorizationRedirect(params: [String: String]) -> String? {
        guard let clientID = params["client_id"],
              let redirectURI = params["redirect_uri"],
              let codeChallenge = params["code_challenge"] else {
            return nil
        }

        let code = generateToken()
        // Canonicalize at issuance so every stored grant carries exactly one
        // known scope value; the token response echoes what was granted.
        let scope = MCPAuthScope.effective(fromRequested: params["scope"]).rawValue
        authCodes[code] = AuthCode(
            codeChallenge: codeChallenge,
            redirectURI: redirectURI,
            clientID: clientID,
            expires: Date().addingTimeInterval(60),
            scope: scope,
            resource: params["resource"]
        )

        // Percent-encode both values so a crafted `state` can't inject extra
        // query params into the redirect.
        var redirectURL = redirectURI
        redirectURL += redirectURI.contains("?") ? "&" : "?"
        redirectURL += "code=\(Self.percentEncodedQueryValue(code))"
        if let state = params["state"] {
            redirectURL += "&state=\(Self.percentEncodedQueryValue(state))"
        }

        logger.info("Issued auth code for client \(clientID)")
        return redirectURL
    }

    /// The OAuth error redirect for a denied request, so the client shows a
    /// failure instead of waiting forever. Only built from validated params.
    private func deniedRedirectURL(params: [String: String]) -> String? {
        guard let redirectURI = params["redirect_uri"] else { return nil }
        var redirectURL = redirectURI
        redirectURL += redirectURI.contains("?") ? "&" : "?"
        redirectURL += "error=access_denied"
        if let state = params["state"] {
            redirectURL += "&state=\(Self.percentEncodedQueryValue(state))"
        }
        return redirectURL
    }

    /// The pairing code from any of the accepted param names, trimmed.
    private static func suppliedApproval(in params: [String: String]) -> String? {
        (params["approval"] ?? params["pairing_code"] ?? params["approval_code"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The original authorize params as hidden form fields (all HTML-escaped) so a
    /// pairing-code POST to /oauth/approve can complete the flow.
    private static func hiddenFormFields(for params: [String: String]) -> String {
        ["response_type", "client_id", "redirect_uri", "code_challenge",
         "code_challenge_method", "scope", "state", "resource"]
            .compactMap { name in
                guard let value = params[name] else { return nil }
                return "      <input type=\"hidden\" name=\"\(htmlEscape(name))\" value=\"\(htmlEscape(value))\">\n"
            }
            .joined()
    }

    /// Render the pairing-code consent page. This is the fallback surface — the
    /// primary flow is the in-app approval prompt driven by `waitingPageResponse` —
    /// reached when a pairing-code POST to /oauth/approve fails.
    private func consentPageResponse(params: [String: String], error: String?) -> HTTPResponse {
        let hiddenFields = Self.hiddenFormFields(for: params)
        let clientLabel = Self.htmlEscape(Self.clientDisplayName(
            clientID: params["client_id"],
            redirectURI: params["redirect_uri"]
        ))
        let redirectLabel = Self.htmlEscape(params["redirect_uri"] ?? "")
        let errorBlock = error.map { "      <p class=\"error\">\(Self.htmlEscape($0))</p>\n" } ?? ""
        let lede = Self.scopeLede(
            escapedClientLabel: clientLabel,
            scope: MCPAuthScope.effective(fromRequested: params["scope"])
        )

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Connect to ForeverLM</title>
          <style>
        \(Self.consentPageStyles)
          </style>
        </head>
        <body>
          <div class="card">
            <img class="logo" src="https://foreverlm.com/assets/app-icon.png?v=square" alt="ForeverLM">
            <h1>Connect to ForeverLM</h1>
            <p class="lede">\(lede)</p>
            <hr>
        \(errorBlock)  <form method="post" action="/oauth/approve">
        \(hiddenFields)      <label for="approval">Pairing code</label>
              <input id="approval" type="text" name="approval" autocomplete="off" autofocus spellcheck="false" autocapitalize="off" placeholder="Paste your pairing code" inputmode="latin">
              <button type="submit">Approve</button>
          </form>
            <p class="settings-link"><a href="foreverlm://settings/mcp/pairing">Find your code in ForeverLM</a></p>
          </div>
          <p class="hint">If you did not initiate this, close this page — no access is granted without the code.</p>
          <p class="detail">Redirects to: \(redirectLabel)</p>
        </body>
        </html>
        """

        return HTTPResponse(
            status: 200,
            statusText: "OK",
            headers: Self.consentPageHeaders,
            body: Data(html.utf8)
        )
    }

    /// The consent-page line describing what approval grants. Ingest-only
    /// requests state exactly what the client can and cannot do, so the owner
    /// never approves a plugin believing it is read-only — or approves a
    /// full-access assistant believing it is just a plugin. The label must
    /// already be HTML-escaped by the caller.
    private static func scopeLede(escapedClientLabel: String, scope: MCPAuthScope) -> String {
        switch scope {
        case .full:
            return "<span class=\"client\">\(escapedClientLabel)</span> is requesting access to your ForeverLM knowledge base."
        case .ingest:
            return "<span class=\"client\">\(escapedClientLabel)</span> is requesting <strong>ingest-only</strong> access: it can add new sources to your library, but cannot read your knowledge base, modify or delete other sources, or use any other tools."
        }
    }

    /// Consent surfaces must never render inside a frame: an invisibly embedded
    /// waiting page could otherwise drive same-machine auto-approval from a
    /// malicious site (see handleLocalApprove).
    private static let consentPageHeaders = [
        "Content-Type": "text/html; charset=utf-8",
        "Content-Security-Policy": "frame-ancestors 'none'",
        "X-Frame-Options": "DENY",
    ]

    /// Render the primary consent surface: a waiting page that shows the match
    /// code, polls /oauth/pending, and completes once the owner approves in the
    /// app. Embeds a collapsed pairing-code form for owners not at the Mac.
    private func waitingPageResponse(requestID: String, pending: PendingAuthorization) -> HTTPResponse {
        let params = pending.params
        let hiddenFields = Self.hiddenFormFields(for: params)
        let clientLabel = Self.htmlEscape(pending.clientName)
        let redirectLabel = Self.htmlEscape(params["redirect_uri"] ?? "")
        let matchCode = Self.htmlEscape(pending.matchCode)
        let lede = Self.scopeLede(escapedClientLabel: clientLabel, scope: pending.grantedScope)

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Connect to ForeverLM</title>
          <style>
        \(Self.consentPageStyles)
          </style>
        </head>
        <body>
          <div class="card">
            <img class="logo" src="https://foreverlm.com/assets/app-icon.png?v=square" alt="ForeverLM">
            <h1>Connect to ForeverLM</h1>
            <p class="lede">\(lede)</p>
            <hr>
            <div id="live">
              <div class="match-code">\(matchCode)</div>
              <p class="match-caption">ForeverLM on your Mac shows this same code.</p>
              <p class="status"><span class="spinner"></span>Waiting for you to approve in ForeverLM&hellip;</p>
              <p class="settings-link"><a href="foreverlm://mcp/approve">Open ForeverLM</a></p>
            </div>
            <div id="done" hidden>
              <div class="state-icon">&#10003;</div>
              <p class="state-title">Approved</p>
              <p class="state-caption">Taking you back to \(clientLabel)&hellip;</p>
            </div>
            <div id="denied" hidden>
              <div class="state-icon state-icon-denied">&#10005;</div>
              <p class="state-title">Request denied</p>
              <p class="state-caption">No access was granted. You can close this tab.</p>
            </div>
            <div id="expired" hidden>
              <p class="state-title">This request expired</p>
              <p class="state-caption">Go back to \(clientLabel) and try connecting again, or reload this page.</p>
              <button type="button" onclick="location.reload()">Try again</button>
            </div>
            <details class="fallback">
              <summary>Not at your Mac? Use the pairing code instead</summary>
              <form method="post" action="/oauth/approve">
        \(hiddenFields)      <input type="text" name="approval" autocomplete="off" spellcheck="false" autocapitalize="off" placeholder="Paste your pairing code" inputmode="latin">
                <button type="submit">Approve</button>
              </form>
            </details>
          </div>
          <p class="hint">If you did not initiate this, close this page — no access is granted unless you approve in the app.</p>
          <p class="detail">Redirects to: \(redirectLabel)</p>
          <script>
            (function () {
              var pollURL = "/oauth/pending?request=\(requestID)";
              var resolved = false;
              var attempts = 0;
              function show(id) {
                ["live", "done", "denied", "expired"].forEach(function (name) {
                  document.getElementById(name).hidden = (name !== id);
                });
              }
              function poll() {
                attempts += 1;
                fetch(pollURL, { cache: "no-store" })
                  .then(function (r) { return r.json(); })
                  .then(function (d) {
                    if (d.status === "approved") {
                      resolved = true;
                      show("done");
                      location.replace(d.redirect_url);
                    } else if (d.status === "denied") {
                      resolved = true;
                      show("denied");
                      if (d.redirect_url) {
                        setTimeout(function () { location.replace(d.redirect_url); }, 1500);
                      }
                    } else if (d.status === "expired") {
                      resolved = true;
                      show("expired");
                    } else {
                      // Poll quickly at first so same-machine auto-approval
                      // feels instant, then settle into a slower cadence.
                      setTimeout(poll, attempts < 6 ? 500 : 1500);
                    }
                  })
                  .catch(function () { setTimeout(poll, 3000); });
              }
              poll();
              // Zero-click: prove this browser is on the same Mac as the app by
              // reaching its loopback listener. Chrome preflights this under
              // Private Network Access; Safari blocks it as mixed content and
              // falls back to the in-app prompt. The response is intentionally
              // opaque — polling picks up the approval.
              try {
                fetch("http://127.0.0.1:\(MCPHTTPServer.loopbackPort)/oauth/local-approve", {
                  method: "POST",
                  mode: "no-cors",
                  headers: { "Content-Type": "application/x-www-form-urlencoded" },
                  body: "request=\(requestID)"
                }).catch(function () {});
              } catch (e) {}
              // Bring the desktop app forward so the approval prompt is visible,
              // unless same-machine approval already landed.
              setTimeout(function () {
                if (!resolved) { location.href = "foreverlm://mcp/approve"; }
              }, 1600);
            })();
          </script>
        </body>
        </html>
        """

        return HTTPResponse(
            status: 200,
            statusText: "OK",
            headers: Self.consentPageHeaders,
            body: Data(html.utf8)
        )
    }

    /// Shared stylesheet for the consent and waiting pages.
    private static let consentPageStyles = """
            :root { color-scheme: light dark; }
            * { box-sizing: border-box; }
            body {
              font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
              background: #f4f3ee;
              color: #1a1915;
              margin: 0;
              min-height: 100vh;
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              padding: 1.5rem;
              line-height: 1.5;
            }
            .card {
              background: #fff;
              border-radius: 1.5rem;
              box-shadow: 0 1px 3px rgba(0,0,0,0.06), 0 12px 40px rgba(0,0,0,0.08);
              max-width: 26rem;
              width: 100%;
              padding: 2.75rem 2.5rem 2.25rem;
              text-align: center;
            }
            .logo {
              width: 4.75rem;
              height: 4.75rem;
              border-radius: 1.1rem;
              display: block;
              margin: 0 auto 1.5rem;
              box-shadow: 0 1px 4px rgba(0,0,0,0.15);
            }
            h1 {
              font-family: "Iowan Old Style", "Palatino", Georgia, "Times New Roman", serif;
              font-size: 1.75rem;
              font-weight: 600;
              margin: 0 0 0.6rem;
              letter-spacing: -0.01em;
            }
            .lede { color: #55534c; font-size: 0.95rem; margin: 0; }
            .client { font-weight: 600; color: #1a1915; }
            hr { border: 0; border-top: 1px solid #e8e6df; margin: 1.6rem 0; }
            label {
              display: block;
              font-size: 0.85rem;
              font-weight: 500;
              color: #55534c;
              text-align: left;
              margin-bottom: 0.5rem;
            }
            input[type=text] {
              width: 100%;
              padding: 0.9rem 1rem;
              font-size: 1.3rem;
              font-family: ui-monospace, "SF Mono", Menlo, monospace;
              text-align: center;
              letter-spacing: 0.12em;
              border: 1.5px solid #d9d7ce;
              border-radius: 0.85rem;
              background: #fbfaf7;
              color: inherit;
              margin-bottom: 1rem;
              outline: none;
            }
            input[type=text]:focus { border-color: #1a1915; background: #fff; }
            input[type=text]::placeholder {
              font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
              font-size: 1rem;
              letter-spacing: normal;
              color: #b0ada2;
            }
            button {
              width: 100%;
              padding: 0.95rem;
              font-size: 1rem;
              font-weight: 600;
              font-family: inherit;
              border: 0;
              border-radius: 0.85rem;
              background: #1a1915;
              color: #fff;
              cursor: pointer;
            }
            button:hover { background: #35332c; }
            .settings-link { margin: 1.1rem 0 0; font-size: 0.85rem; }
            .settings-link a { color: #55534c; }
            .error {
              color: #b3261e;
              font-size: 0.9rem;
              font-weight: 500;
              background: #fdeceb;
              border-radius: 0.6rem;
              padding: 0.7rem 0.9rem;
              margin: 0 0 1.25rem;
              text-align: left;
            }
            .hint { color: #8a877d; font-size: 0.8rem; max-width: 24rem; text-align: center; margin: 1.5rem 0 0; }
            .detail { color: #b0ada2; font-size: 0.72rem; word-break: break-all; margin: 0.4rem 0 0; }
            .match-code {
              font-family: ui-monospace, "SF Mono", Menlo, monospace;
              font-size: 3rem;
              font-weight: 700;
              letter-spacing: 0.18em;
              margin: 0.4rem 0 0.2rem;
            }
            .match-caption { color: #8a877d; font-size: 0.82rem; margin: 0 0 1.4rem; }
            .status {
              color: #55534c;
              font-size: 0.95rem;
              display: flex;
              align-items: center;
              justify-content: center;
              gap: 0.6rem;
              margin: 0 0 0.2rem;
            }
            .spinner {
              width: 1rem;
              height: 1rem;
              flex: none;
              border: 2px solid #d9d7ce;
              border-top-color: #55534c;
              border-radius: 50%;
              animation: spin 0.9s linear infinite;
            }
            @keyframes spin { to { transform: rotate(360deg); } }
            .state-icon { font-size: 2.2rem; line-height: 1; color: #2e7d32; margin-top: 0.5rem; }
            .state-icon-denied { color: #b3261e; }
            .state-title { font-size: 1.1rem; font-weight: 600; margin: 0.5rem 0 0.3rem; }
            .state-caption { color: #55534c; font-size: 0.9rem; margin: 0 0 1rem; }
            .fallback { margin-top: 1.6rem; }
            .fallback summary { color: #8a877d; font-size: 0.82rem; cursor: pointer; }
            .fallback form { margin-top: 0.9rem; }
            .fallback input[type=text] { font-size: 1rem; letter-spacing: 0.06em; padding: 0.7rem 0.9rem; }
            @media (prefers-color-scheme: dark) {
              body { background: #262624; color: #ecebe6; }
              .card { background: #30302e; box-shadow: 0 1px 3px rgba(0,0,0,0.4), 0 12px 40px rgba(0,0,0,0.35); }
              .lede, label, .settings-link a { color: #b6b3aa; }
              .client { color: #ecebe6; }
              hr { border-top-color: #45443f; }
              input[type=text] { background: #262624; border-color: #55534c; }
              input[type=text]:focus { border-color: #ecebe6; background: #262624; }
              button { background: #ecebe6; color: #1a1915; }
              button:hover { background: #d9d7ce; }
              .error { color: #f2b8b5; background: #4a2b28; }
              .hint { color: #8a877d; }
              .detail { color: #6b6960; }
              .status, .state-caption { color: #b6b3aa; }
              .spinner { border-color: #55534c; border-top-color: #ecebe6; }
              .state-icon { color: #7bc47f; }
              .state-icon-denied { color: #f2b8b5; }
            }
        """

    /// OAuth client IDs are machine identifiers, so translate trusted callback hosts
    /// into the product names people expect to see on a consent screen.
    static func clientDisplayName(clientID: String?, redirectURI: String?) -> String {
        let host = redirectURI.flatMap { URL(string: $0)?.host?.lowercased() }

        switch host {
        case "claude.ai", "claude.com":
            return "Claude"
        case "chatgpt.com", "platform.openai.com":
            return "ChatGPT"
        case "gemini.google.com":
            return "Gemini"
        case "platform.edisonscientific.com":
            return "Edison"
        case "localhost", "127.0.0.1", "::1":
            return "Local MCP client"
        default:
            if let clientID, !clientID.hasPrefix("dyn_") {
                return clientID
            }
            return "An AI assistant"
        }
    }

    /// Escape a value for safe interpolation into HTML text or a double-quoted attribute.
    private static func htmlEscape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Token Exchange

    private func handleToken(_ request: HTTPRequest) async -> HTTPResponse {
        // Parse form body or JSON
        let params = parseTokenParams(request)

        guard let grantType = params["grant_type"] else {
            return .json(["error": "invalid_request"], status: 400)
        }

        switch grantType {
        case "authorization_code":
            return handleAuthCodeGrant(params, request: request)
        case "refresh_token":
            return handleRefreshGrant(params, request: request)
        default:
            return .json(["error": "unsupported_grant_type"], status: 400)
        }
    }

    private func handleAuthCodeGrant(_ params: [String: String], request: HTTPRequest) -> HTTPResponse {
        guard let code = params["code"],
              let codeVerifier = params["code_verifier"] else {
            return .json(["error": "invalid_request"], status: 400)
        }

        guard let authCode = authCodes[code] else {
            return .json(["error": "invalid_grant", "error_description": "Invalid or expired code"], status: 400)
        }

        // Single-use
        authCodes.removeValue(forKey: code)

        // Check expiry
        guard authCode.expires > Date() else {
            return .json(["error": "invalid_grant", "error_description": "Code expired"], status: 400)
        }

        // Authenticate the client per its registered token_endpoint_auth_method,
        // and require it to be the client the code was issued to.
        guard let clientID = authenticateTokenRequest(params, request: request),
              clientID == authCode.clientID else {
            return .json(["error": "invalid_client"], status: 401)
        }

        // Verify PKCE
        guard verifySHA256Challenge(verifier: codeVerifier, challenge: authCode.codeChallenge) else {
            return .json(["error": "invalid_grant", "error_description": "PKCE verification failed"], status: 400)
        }

        // Issue tokens
        let accessToken = generateToken()
        let refreshToken = generateToken()
        let expiresIn = 7 * 24 * 3600 // 7 days

        accessTokens[accessToken] = TokenInfo(
            clientID: clientID,
            expires: Date().addingTimeInterval(TimeInterval(expiresIn)),
            scope: authCode.scope
        )
        refreshTokens[refreshToken] = RefreshInfo(
            clientID: clientID,
            scope: authCode.scope,
            resource: authCode.resource
        )

        logger.info("Issued access token for client \(clientID)")
        saveTokens()

        return .json([
            "access_token": accessToken,
            "token_type": "Bearer",
            "expires_in": expiresIn,
            "refresh_token": refreshToken,
            "scope": authCode.scope,
        ])
    }

    private func handleRefreshGrant(_ params: [String: String], request: HTTPRequest) -> HTTPResponse {
        guard let oldRefresh = params["refresh_token"] else {
            return .json(["error": "invalid_request"], status: 400)
        }
        // A client this store does not know is RFC 6749's invalid_client, not
        // invalid_grant, whatever token it brings. That is how a plugin learns,
        // before it opens a browser, that its registration is gone and it must
        // register again rather than reuse the id (see mayRecoverDynamicClient).
        if let presentedID = params["client_id"] ?? extractBasicAuthCredentials(request)?.clientID,
           !validateClient(presentedID) {
            return Self.unknownClientResponse(clientID: presentedID, status: 401)
        }
        guard let refreshInfo = refreshTokens[oldRefresh] else {
            return .json(["error": "invalid_grant"], status: 400)
        }

        // Authenticate the client per its registered token_endpoint_auth_method and
        // require it to be the token's owner — BEFORE consuming the refresh token,
        // so an unauthenticated caller can't burn a victim's token.
        guard let clientID = authenticateTokenRequest(params, request: request),
              clientID == refreshInfo.clientID else {
            return .json(["error": "invalid_client"], status: 401)
        }

        // Rotate refresh token
        refreshTokens.removeValue(forKey: oldRefresh)

        let accessToken = generateToken()
        let newRefreshToken = generateToken()
        let expiresIn = 7 * 24 * 3600

        // Scope is copied from the stored grant, never from request params, so a
        // refresh can neither escalate nor sidestep what the owner approved.
        accessTokens[accessToken] = TokenInfo(
            clientID: refreshInfo.clientID,
            expires: Date().addingTimeInterval(TimeInterval(expiresIn)),
            scope: refreshInfo.scope
        )
        refreshTokens[newRefreshToken] = RefreshInfo(
            clientID: refreshInfo.clientID,
            scope: refreshInfo.scope,
            resource: refreshInfo.resource
        )
        saveTokens()

        return .json([
            "access_token": accessToken,
            "token_type": "Bearer",
            "expires_in": expiresIn,
            "refresh_token": newRefreshToken,
            "scope": refreshInfo.scope,
        ])
    }

    // MARK: - Dynamic Client Registration

    private func handleRegister(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.bodyJSON else {
            return .json(["error": "invalid_request"], status: 400)
        }

        let redirectURIs = body["redirect_uris"] as? [String] ?? []
        let authMethod = body["token_endpoint_auth_method"] as? String ?? "client_secret_post"
        let clientName = (body["client_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A supplied-but-invalid logo fails loudly rather than being silently
        // dropped — the plugin author should learn at registration, not by
        // seeing a blank icon later.
        let rawLogoURI = (body["logo_uri"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let logoURI = Self.validatedLogoURI(rawLogoURI)
        if let rawLogoURI, !rawLogoURI.isEmpty, logoURI == nil {
            return .json([
                "error": "invalid_client_metadata",
                "error_description": "logo_uri must be an https URL (at most 2048 characters).",
            ], status: 400)
        }

        let clientID = "dyn_\(generateToken(length: 16))"
        let clientSecret: String? = (authMethod == "none") ? nil : generateToken()

        dynamicClients[clientID] = DynamicClient(
            clientSecret: clientSecret,
            redirectURIs: redirectURIs,
            tokenEndpointAuthMethod: authMethod,
            clientName: (clientName?.isEmpty == false) ? clientName : nil,
            logoURI: logoURI,
            lastSeenAt: nil,
            lastSuccessfulSyncAt: nil,
            reportedState: nil,
            statusDetail: nil
        )
        logger.info("Registered dynamic client \(clientID)")
        saveTokens()

        var response: [String: Any] = [
            "client_id": clientID,
            "redirect_uris": redirectURIs,
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": authMethod,
        ]
        if let secret = clientSecret {
            response["client_secret"] = secret
        }
        if let clientName, !clientName.isEmpty {
            response["client_name"] = clientName
        }
        if let logoURI {
            response["logo_uri"] = logoURI
        }

        return .json(response, status: 201)
    }

    // MARK: - Helpers

    /// Identity-only check used by /oauth/authorize (client secrets are never sent
    /// on the authorization request; they are enforced at the token endpoint).
    private func validateClient(_ clientID: String) -> Bool {
        clientID == preRegisteredClientID || dynamicClients[clientID] != nil
    }

    /// Authenticate a token-endpoint request per the client's registered
    /// `token_endpoint_auth_method`. Confidential clients (client_secret_post /
    /// client_secret_basic) MUST present their secret — compared constant-time —
    /// while public clients ("none") rely on PKCE. Returns the authenticated
    /// client_id, or nil when authentication fails.
    private func authenticateTokenRequest(_ params: [String: String], request: HTTPRequest) -> String? {
        let basic = extractBasicAuthCredentials(request)
        guard let clientID = params["client_id"] ?? basic?.clientID else { return nil }
        let suppliedSecret = params["client_secret"] ?? basic?.clientSecret

        // Pre-registered (provisioner-issued) client: confidential, secret required.
        if clientID == preRegisteredClientID {
            guard let expected = preRegisteredClientSecret else { return clientID }
            guard let suppliedSecret, constantTimeEquals(suppliedSecret, expected) else { return nil }
            return clientID
        }

        guard let dyn = dynamicClients[clientID] else { return nil }
        if dyn.tokenEndpointAuthMethod == "none" { return clientID }
        guard let expected = dyn.clientSecret,
              let suppliedSecret,
              constantTimeEquals(suppliedSecret, expected) else { return nil }
        return clientID
    }

    private func recoverDynamicLoopbackClient(clientID: String, redirectURI: String, requestedScope: String?) -> Bool {
        guard dynamicClients[clientID] == nil,
              Self.mayRecoverDynamicClient(clientID: clientID, redirectURI: redirectURI, requestedScope: requestedScope) else {
            return false
        }

        dynamicClients[clientID] = DynamicClient(
            clientSecret: nil,
            redirectURIs: [redirectURI],
            tokenEndpointAuthMethod: "none",
            clientName: nil,
            logoURI: nil,
            lastSeenAt: nil,
            lastSuccessfulSyncAt: nil,
            reportedState: nil,
            statusDetail: nil
        )
        logger.warning("Recovered stale dynamic OAuth client \(clientID) for loopback redirect")
        saveTokens()
        return true
    }

    /// Whether an authorization request may recreate the unknown `dyn_` client
    /// it names. A local assistant (Claude Code, Codex) whose registration this
    /// store lost, to a reinstall or a Keychain reset, keeps working without
    /// registering again, still behind the owner's approval.
    ///
    /// A plugin asking for `mcp:ingest` is refused instead. It is known by the
    /// `client_name` it registered: that name labels every source it adds
    /// (`sources.connector_label`) and its row in Plugins, and an
    /// authorization request does not carry it. Recreated, the client would
    /// have no name, so its sources would file under the raw `dyn_…` id and the
    /// list would show the id. Refused with `invalid_client`, the plugin
    /// registers again under its name.
    static func mayRecoverDynamicClient(clientID: String, redirectURI: String, requestedScope: String?) -> Bool {
        clientID.hasPrefix("dyn_")
            && isLoopbackRedirect(redirectURI)
            && MCPAuthScope.effective(fromRequested: requestedScope) != .ingest
    }

    /// RFC 6749 `invalid_client` for a client id this store does not know. A
    /// `dyn_` id is one it issued once and has since forgotten, so the answer
    /// says what to do about it.
    static func unknownClientResponse(clientID: String, status: Int) -> HTTPResponse {
        guard clientID.hasPrefix("dyn_") else {
            return .json(["error": "invalid_client"], status: status)
        }
        return .json([
            "error": "invalid_client",
            "error_description": "ForeverLM does not know this client_id. It forgets registrations when it is reinstalled or moves to another Apple account. Register again at /oauth/register with the same client_name, then authorize with the client_id that returns.",
        ], status: status)
    }

    private func isRedirectAllowed(_ uri: String, clientID: String) -> Bool {
        if let url = URL(string: uri), let host = url.host,
           allowedRedirectHosts.contains(host) { return true }
        if let dyn = dynamicClients[clientID], dyn.redirectURIs.contains(uri) { return true }
        return false
    }

    private static func isLoopbackRedirect(_ uri: String) -> Bool {
        guard let url = URL(string: uri),
              url.scheme == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func verifySHA256Challenge(verifier: String, challenge: String) -> Bool {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        let encoded = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded == challenge
    }

    private func parseTokenParams(_ request: HTTPRequest) -> [String: String] {
        // Try form-encoded body first
        if let bodyStr = String(data: request.body, encoding: .utf8),
           request.headers["content-type"]?.contains("form") == true {
            var result: [String: String] = [:]
            for pair in bodyStr.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    result[decodeFormURLComponent(String(parts[0]))] =
                        decodeFormURLComponent(String(parts[1]))
                }
            }
            return result
        }
        // Try JSON body
        if let json = request.bodyJSON as? [String: String] {
            return json
        }
        return [:]
    }

    /// Decode client_secret_basic credentials. Per RFC 6749 §2.3.1 the id and
    /// secret are form-urlencoded before base64, so both halves are percent-decoded.
    private func extractBasicAuthCredentials(_ request: HTTPRequest) -> (clientID: String, clientSecret: String?)? {
        guard let auth = request.headers["authorization"],
              auth.hasPrefix("Basic "),
              let data = Data(base64Encoded: String(auth.dropFirst(6))),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        let parts = decoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let rawID = parts.first, !rawID.isEmpty else { return nil }
        let clientID = decodeFormURLComponent(rawID)
        let secret = parts.count > 1 ? decodeFormURLComponent(parts[1]) : nil
        return (clientID, secret)
    }

    private func generateToken(length: Int = 32) -> String {
        Self.secureRandomHex(byteCount: length)
    }

    /// CSPRNG-backed hex string. Fails loudly rather than ever returning a zeroed
    /// (and therefore predictable) token: a silent fallback here would let an
    /// attacker guess auth codes / access tokens.
    static func secureRandomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed (OSStatus \(status)); refusing to issue a predictable OAuth secret")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Percent-encode a value for safe inclusion in a redirect query string. Only
    /// unreserved characters (RFC 3986) survive; everything else — including
    /// CR/LF/`&`/`=` — is escaped.
    static func percentEncodedQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    // MARK: - Owner Pairing Code
    //
    // A stable per-install secret the device owner presents to approve an OAuth
    // authorization (see the owner-consent gate in handleAuthorize). Generated once
    // and stored in the Keychain so it survives restarts. Not owned by the shared
    // KeychainService key enum (which lives outside the MCP module), so it is read
    // and written here directly via the Security framework.
    private static let pairingKeychainService = ForeverLMRuntimeIdentity.keychainService
    private static let pairingKeychainAccount = "mcp_oauth_pairing_code"

    /// The owner pairing code, generated on first read. The Settings UI must surface
    /// this value so the owner can paste it into a client's authorize URL.
    static var ownerPairingCode: String {
        if let existing = loadPairingCodeFromKeychain(), !existing.isEmpty {
            return existing
        }
        // 8 random bytes → 16 hex chars: short enough to copy, wide enough not to guess.
        let generated = secureRandomHex(byteCount: 8)
        savePairingCodeToKeychain(generated)
        return generated
    }

    private static func pairingKeychainBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pairingKeychainService,
            kSecAttrAccount as String: pairingKeychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func loadPairingCodeFromKeychain() -> String? {
        var query = pairingKeychainBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func savePairingCodeToKeychain(_ value: String) {
        let base = pairingKeychainBaseQuery()
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private func issuerURL(for request: HTTPRequest) -> String {
        if let configuredIssuerURL {
            return configuredIssuerURL
        }
        if let derivedIssuerURL = deriveIssuerURL(from: request) {
            return derivedIssuerURL
        }
        return "http://localhost:\(ForeverLMRuntimeIdentity.mcpLoopbackPort)"
    }

    private func deriveIssuerURL(from request: HTTPRequest) -> String? {
        if let forwardedValue = firstHeaderValue(named: "forwarded", in: request.headers),
           let forwardedIssuerURL = parseForwardedIssuerURL(forwardedValue) {
            return forwardedIssuerURL
        }

        let forwardedHost = firstHeaderValue(named: "x-forwarded-host", in: request.headers)
        let host = forwardedHost ?? firstHeaderValue(named: "host", in: request.headers)
        guard let host else { return nil }

        let scheme = firstHeaderValue(named: "x-forwarded-proto", in: request.headers) ?? defaultScheme(for: host)
        return "\(scheme)://\(host)"
    }

    private func parseForwardedIssuerURL(_ value: String) -> String? {
        let firstEntry = value.split(separator: ",", maxSplits: 1).first.map(String.init) ?? value
        let pairs = firstEntry.split(separator: ";")

        var proto: String?
        var host: String?

        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            if key == "proto", !normalizedValue.isEmpty {
                proto = normalizedValue
            } else if key == "host", !normalizedValue.isEmpty {
                host = normalizedValue
            }
        }

        guard let host else { return nil }
        return "\((proto ?? defaultScheme(for: host)))://\(host)"
    }

    private func firstHeaderValue(named headerName: String, in headers: [String: String]) -> String? {
        guard let rawValue = headers[headerName] else { return nil }
        let firstValue = rawValue.split(separator: ",", maxSplits: 1).first.map(String.init) ?? rawValue
        let trimmedValue = firstValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        return trimmedValue
    }

    private func defaultScheme(for host: String) -> String {
        let hostWithoutPort = host.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() ?? host.lowercased()
        switch hostWithoutPort {
        case "localhost", "127.0.0.1", "::1":
            return "http"
        default:
            return "https"
        }
    }

    private func cleanExpired() {
        let now = Date()
        authCodes = authCodes.filter { $0.value.expires > now }
        accessTokens = accessTokens.filter { $0.value.expires > now }
    }

    // MARK: - Token Persistence
    //
    // Access and refresh tokens are bearer secrets — anyone holding one can read
    // the entire knowledge base — so they persist to the Keychain, never to a
    // plaintext file. Earlier builds wrote them to oauth_tokens.json in
    // Application Support; that file is imported once on first load and deleted.

    private struct PersistedTokens: Codable {
        var accessTokens: [String: PersistedAccessToken]
        var refreshTokens: [String: PersistedRefreshToken]
        // Present only in the legacy oauth_tokens.json shape; dynamic clients now
        // persist solely in their own Keychain item.
        var dynamicClients: [String: PersistedDynamicClient]?

        struct PersistedAccessToken: Codable {
            let clientID: String
            let expires: Date
            // Absent in tokens persisted before scopes existed; those were all
            // granted full access, so they decode as such.
            let scope: String?
        }
        struct PersistedRefreshToken: Codable {
            let clientID: String
            let scope: String
            let resource: String?
        }
        struct PersistedDynamicClient: Codable {
            let clientSecret: String?
            let redirectURIs: [String]
            let tokenEndpointAuthMethod: String
            // Absent for clients registered before names were captured.
            let clientName: String?
            // Absent for clients registered before logos were captured.
            let logoURI: String?
            let lastSeenAt: Date?
            let lastSuccessfulSyncAt: Date?
            let reportedState: UserPluginHealthState?
            let statusDetail: String?
        }
    }

    private static var legacyTokenFilePath: URL {
        ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent(".appdata/oauth_tokens.json")
    }

    private func saveTokens() {
        Self.persistTokens(accessTokens: accessTokens, refreshTokens: refreshTokens, dynamicClients: dynamicClients)
    }

    /// Nonisolated persistence core so `init` can persist a legacy import before
    /// actor isolation is established.
    private static func persistTokens(
        accessTokens: [String: TokenInfo],
        refreshTokens: [String: RefreshInfo],
        dynamicClients: [String: DynamicClient]
    ) {
        saveDynamicClientsToKeychain(dynamicClients)
        let persisted = PersistedTokens(
            accessTokens: accessTokens.mapValues { .init(clientID: $0.clientID, expires: $0.expires, scope: $0.scope) },
            refreshTokens: refreshTokens.mapValues { .init(clientID: $0.clientID, scope: $0.scope, resource: $0.resource) },
            dynamicClients: nil
        )
        do {
            let data = try JSONEncoder().encode(persisted)
            KeychainService.save(String(decoding: data, as: UTF8.self), for: .mcpOAuthTokens)
        } catch {
            Logger(subsystem: "ForeverLM", category: "MCPOAuth").warning("Failed to save OAuth tokens: \(error)")
        }
    }

    private static func loadPersistedTokens() -> (accessTokens: [String: TokenInfo], refreshTokens: [String: RefreshInfo], legacyDynamicClients: [String: DynamicClient]) {
        if let raw = KeychainService.load(.mcpOAuthTokens),
           let data = raw.data(using: .utf8),
           let persisted = try? JSONDecoder().decode(PersistedTokens.self, from: data) {
            return liveTokens(from: persisted)
        }

        // One-time import of the legacy plaintext token file, which is deleted so
        // bearer secrets never linger on disk. (The caller re-persists to Keychain.)
        let legacyURL = legacyTokenFilePath
        guard let data = try? Data(contentsOf: legacyURL),
              let persisted = try? JSONDecoder().decode(PersistedTokens.self, from: data) else {
            return ([:], [:], [:])
        }
        try? FileManager.default.removeItem(at: legacyURL)
        return liveTokens(from: persisted)
    }

    private static func liveTokens(from persisted: PersistedTokens) -> (accessTokens: [String: TokenInfo], refreshTokens: [String: RefreshInfo], legacyDynamicClients: [String: DynamicClient]) {
        let now = Date()
        let access = persisted.accessTokens
            .filter { $0.value.expires > now }
            .mapValues { TokenInfo(clientID: $0.clientID, expires: $0.expires, scope: $0.scope ?? MCPAuthScope.full.rawValue) }
        let refresh = persisted.refreshTokens
            .mapValues { RefreshInfo(clientID: $0.clientID, scope: $0.scope, resource: $0.resource) }
        let clients = (persisted.dynamicClients ?? [:])
            .mapValues {
                DynamicClient(
                    clientSecret: $0.clientSecret,
                    redirectURIs: $0.redirectURIs,
                    tokenEndpointAuthMethod: $0.tokenEndpointAuthMethod,
                    clientName: $0.clientName,
                    logoURI: $0.logoURI,
                    lastSeenAt: $0.lastSeenAt,
                    lastSuccessfulSyncAt: $0.lastSuccessfulSyncAt,
                    reportedState: $0.reportedState,
                    statusDetail: $0.statusDetail
                )
            }

        return (access, refresh, clients)
    }

    private static func saveDynamicClientsToKeychain(_ dynamicClients: [String: DynamicClient]) {
        let persisted = dynamicClients.mapValues {
            PersistedTokens.PersistedDynamicClient(
                clientSecret: $0.clientSecret,
                redirectURIs: $0.redirectURIs,
                tokenEndpointAuthMethod: $0.tokenEndpointAuthMethod,
                clientName: $0.clientName,
                logoURI: $0.logoURI,
                lastSeenAt: $0.lastSeenAt,
                lastSuccessfulSyncAt: $0.lastSuccessfulSyncAt,
                reportedState: $0.reportedState,
                statusDetail: $0.statusDetail
            )
        }

        guard !persisted.isEmpty else {
            KeychainService.delete(.mcpOAuthDynamicClients)
            return
        }

        guard let data = try? JSONEncoder().encode(persisted),
              let value = String(data: data, encoding: .utf8) else {
            return
        }
        KeychainService.save(value, for: .mcpOAuthDynamicClients)
    }

    private static func loadDynamicClientsFromKeychain() -> [String: DynamicClient] {
        guard let rawValue = KeychainService.load(.mcpOAuthDynamicClients),
              let data = rawValue.data(using: .utf8),
              let persisted = try? JSONDecoder().decode([String: PersistedTokens.PersistedDynamicClient].self, from: data) else {
            return [:]
        }

        return persisted.mapValues {
            DynamicClient(
                clientSecret: $0.clientSecret,
                redirectURIs: $0.redirectURIs,
                tokenEndpointAuthMethod: $0.tokenEndpointAuthMethod,
                clientName: $0.clientName,
                logoURI: $0.logoURI,
                lastSeenAt: $0.lastSeenAt,
                lastSuccessfulSyncAt: $0.lastSuccessfulSyncAt,
                reportedState: $0.reportedState,
                statusDetail: $0.statusDetail
            )
        }
    }

    // MARK: - User-Plugin Management (Settings)

    /// One user-built plugin as the Settings pane shows it: a dynamic OAuth
    /// client holding an ingest-scoped grant.
    struct UserPluginSummary: Identifiable, Sendable, Equatable {
        let id: String
        /// Sanitized label — exactly what this plugin's sources carry in
        /// `connector_label`, so counts and bulk-removal key off it directly.
        let name: String
        /// https-only registration logo, rendered in the Plugins place (never consent).
        let logoURI: String?
        let lastSeenAt: Date?
        let lastSuccessfulSyncAt: Date?
        let reportedState: UserPluginHealthState?
        let statusDetail: String?

        /// A plugin that once opted into health reporting must keep checking
        /// in. Twenty-six hours tolerates a missed hourly run without allowing a
        /// dead launchd job to look healthy indefinitely.
        var needsAttention: Bool {
            if reportedState == .needsReconnect || reportedState == .error { return true }
            guard let lastSeenAt else { return false }
            return Date().timeIntervalSince(lastSeenAt) > 26 * 60 * 60
        }

        /// Why the plugin needs attention, as the predicate of a sentence
        /// whose subject is the plugin ("Read AI Meetings needs to sign in
        /// again — …"), carrying the detail the plugin reported when it gave
        /// one. That detail is what names the command that fixes it, and
        /// nothing in ForeverLM can run that on the plugin's behalf — which
        /// is why this never says "reconnect" as if a button here could.
        /// nil while the plugin is healthy.
        var attentionSummary: String? {
            guard needsAttention else { return nil }
            let detail = statusDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch reportedState {
            case .needsReconnect:
                return detail.isEmpty
                    ? "needs to sign in again — run its login to get the latest"
                    : "needs to sign in again — \(detail)"
            case .error:
                return detail.isEmpty
                    ? "failed on its last run"
                    : "failed on its last run — \(detail)"
            default:
                let since = lastSeenAt.map { $0.formatted(.relative(presentation: .named)) } ?? "a while ago"
                return "last checked in \(since) — its schedule may have stopped"
            }
        }
    }

    /// Every client that currently holds an ingest-scoped access or refresh
    /// token, for the Plugins place: its Your Plugins rows and Build Your Own.
    func userPluginSummaries() -> [UserPluginSummary] {
        cleanExpired()
        var clientIDs = Set<String>()
        for info in accessTokens.values where MCPAuthScope.effective(fromRequested: info.scope) == .ingest {
            clientIDs.insert(info.clientID)
        }
        for info in refreshTokens.values where MCPAuthScope.effective(fromRequested: info.scope) == .ingest {
            clientIDs.insert(info.clientID)
        }
        return clientIDs
            .map { clientID in
                UserPluginSummary(
                    id: clientID,
                    name: connectorLabel(forClientID: clientID),
                    logoURI: dynamicClients[clientID]?.logoURI,
                    lastSeenAt: dynamicClients[clientID]?.lastSeenAt,
                    lastSuccessfulSyncAt: dynamicClients[clientID]?.lastSuccessfulSyncAt,
                    reportedState: dynamicClients[clientID]?.reportedState,
                    statusDetail: dynamicClients[clientID]?.statusDetail
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Called only by an authenticated ingest plugin. The plugin owns the
    /// truth about its upstream token and scheduler, while ForeverLM owns the
    /// grant and presentation of that truth.
    func reportPluginStatus(
        clientID: String,
        state: UserPluginHealthState,
        detail: String?
    ) -> Bool {
        guard let client = dynamicClients[clientID] else { return false }
        let now = Date()
        let cleanDetail = detail.map(Self.sanitizedPluginStatusDetail)
        dynamicClients[clientID] = DynamicClient(
            clientSecret: client.clientSecret,
            redirectURIs: client.redirectURIs,
            tokenEndpointAuthMethod: client.tokenEndpointAuthMethod,
            clientName: client.clientName,
            logoURI: client.logoURI,
            lastSeenAt: now,
            lastSuccessfulSyncAt: state == .healthy ? now : client.lastSuccessfulSyncAt,
            reportedState: state,
            statusDetail: cleanDetail
        )
        if let provider = MeetingProvider.forPluginLabel(connectorLabel(forClientID: clientID)) {
            PreferenceStore.set(state.rawValue, forKey: "connectorHealth.\(provider.rawValue).state")
            PreferenceStore.set(now.timeIntervalSince1970, forKey: "connectorHealth.\(provider.rawValue).lastSeenAt")
            if state == .healthy {
                PreferenceStore.set(now.timeIntervalSince1970, forKey: "connectorHealth.\(provider.rawValue).lastSuccessfulSyncAt")
            }
            // Generation 2: the health is this Mac's Device record's, not a synced preference.
            ConnectorHealthSync.mirror()
        }
        saveTokens()
        NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
        return true
    }

    static func sanitizedPluginStatusDetail(_ raw: String) -> String {
        let collapsed = raw
            .unicodeScalars
            .map { ($0.value < 0x20 || $0.value == 0x7F) ? " " : String($0) }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(240))
    }

    /// Owner-side revocation of one plugin: forgets the client registration
    /// and every token it holds, effective immediately. Deliberately app-only —
    /// MCP has no tool for this, so a compromised full-scope client can never
    /// silence other plugins (documented parity exception in
    /// docs/user-plugins.md). Sources the plugin added are untouched;
    /// remove those separately (remove_connector_sources or the Settings button).
    func revokeClient(_ clientID: String) {
        if let provider = dynamicClients[clientID]
            .map({ Self.sanitizedPluginLabel($0.clientName ?? clientID) })
            .flatMap(MeetingProvider.forPluginLabel) {
            PreferenceStore.set(UserPluginHealthState.needsReconnect.rawValue, forKey: "connectorHealth.\(provider.rawValue).state")
            PreferenceStore.set(Date().timeIntervalSince1970, forKey: "connectorHealth.\(provider.rawValue).lastSeenAt")
            ConnectorHealthSync.mirror()
        }
        accessTokens = accessTokens.filter { $0.value.clientID != clientID }
        refreshTokens = refreshTokens.filter { $0.value.clientID != clientID }
        dynamicClients.removeValue(forKey: clientID)
        saveTokens()
        logger.notice("Revoked user plugin client \(clientID)")
    }

    /// Accept only an https URL with a host, bounded in length. The logo is
    /// rendered solely in the app's Settings list; consent surfaces keep the
    /// generic icon so a malicious registration can't impersonate a trusted
    /// product at approval time.
    static func validatedLogoURI(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= 2048,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// True if the string contains any C0/C1 control character (CR, LF, NUL, etc.).
/// Used to reject header-injection attempts in redirect parameters.
func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}

/// Coarse authorization scopes a client can be granted at consent time.
///
/// `full` (`mcp:tools`) is the historical default every assistant client gets.
/// `ingest` (`mcp:ingest`) is the plugin scope for user-built plugins:
/// the client may add sources, update the sources it added, and read server
/// status — nothing else. Enforcement lives in `MCPToolRegistry`
/// (`ingestAllowedTools`); this type only names and parses the grants.
enum MCPAuthScope: String, Codable, Sendable, Equatable {
    case full = "mcp:tools"
    case ingest = "mcp:ingest"

    static let advertised: [String] = [MCPAuthScope.full.rawValue, MCPAuthScope.ingest.rawValue]

    /// Effective granted scope for a requested `scope` parameter. Absence — or
    /// any request that includes `mcp:tools` — grants full access, matching the
    /// historical behavior of clients that never send a scope. Only an explicit,
    /// exclusive `mcp:ingest` narrows the grant, so a scope can restrict but
    /// never escalate by omission.
    static func effective(fromRequested scope: String?) -> MCPAuthScope {
        guard let scope, !scope.isEmpty else { return .full }
        let tokens = Set(scope.split(separator: " ").map(String.init))
        if tokens.contains(MCPAuthScope.ingest.rawValue), !tokens.contains(MCPAuthScope.full.rawValue) {
            return .ingest
        }
        return .full
    }

    /// True when every space-separated token names a scope this server knows.
    /// Unknown scopes are rejected at /oauth/authorize rather than silently
    /// granted or dropped.
    static func allTokensKnown(inRequested scope: String) -> Bool {
        scope.split(separator: " ").allSatisfy { advertised.contains(String($0)) }
    }
}

/// What a validated access token authorizes: the owning OAuth client, the scope
/// granted at consent, and the sanitized label provenance stamping uses for
/// sources an ingest-scoped client adds.
struct MCPAccessContext: Sendable, Equatable {
    let clientID: String
    let scope: MCPAuthScope
    let connectorLabel: String
    /// The AI app the learner sees named while a call it made runs on
    /// ForeverLM's models (`MCPToolActivityCenter`): the name it registered
    /// under, or the one the hosted gateway passes on. Display only — nothing
    /// authorizes on it — and nil when the caller never gave one.
    var assistantName: String? = nil
    /// True for a request that reached this Mac on its own OAuth bearer
    /// (a Build Your Own plugin, Read AI, any client given the tunnel's
    /// address), not through the hosted gateway. Only these are checked
    /// against the MCP lock here (`MCPProtocolHandler.mcpLockRefusal`); the
    /// gateway checks its own, and in-app callers (`internalFullAccess`)
    /// never are.
    var arrivedWithoutGateway = false

    /// The context in-app callers (Chat, ⌘K assistant bar) run under: the app
    /// process is the owner, so it is never scope-restricted. Remote MCP paths
    /// must never fall back to this — they always derive their context from
    /// the request's bearer token in `authorizeMCPRequest`.
    static let internalFullAccess = MCPAccessContext(clientID: "in-app", scope: .full, connectorLabel: "ForeverLM")
}

/// A pending OAuth authorization for the app's approval prompt.
struct MCPPendingAuthorizationSummary: Identifiable, Sendable, Equatable {
    let id: String
    let clientName: String
    let matchCode: String
    let expires: Date
    /// True when the request asks for the ingest-only scope, so the prompt can
    /// say "can only add sources" instead of implying full access.
    let ingestOnly: Bool
}

extension Notification.Name {
    /// Posted on the main actor whenever the set of MCP authorizations awaiting
    /// in-app approval changes. Observers should re-query
    /// `MCPOAuthProvider.sharedProvider().pendingAuthorizationSummaries()`.
    static let mcpPendingAuthorizationsChanged = Notification.Name("mcpPendingAuthorizationsChanged")
}

#endif
