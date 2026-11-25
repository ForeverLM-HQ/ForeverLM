import Foundation
import OSLog
import CryptoKit

#if os(macOS) || os(iOS)
/// Launches the native MCP server + WebSocket relay on macOS and iOS.
///
/// Fully self-contained — no binaries, no Python, no Homebrew, no cloudflared.
/// A WebSocket connection to the ForeverLM Cloudflare Worker relay provides the
/// public URL (e.g., https://{hash}.foreverlm.com).
///
/// First launch: provisions a stable tunnel URL via the provisioner worker.
/// Subsequent launches: reuses cached credentials from Keychain.
///
/// Main-actor isolated on purpose. `startHostedTunnel` is kicked off from
/// several places at launch — the scene's `.task`, the scene-phase change to
/// `.active`, and one `.task` per open window — and they all arrive within the
/// same few milliseconds. Without isolation those calls ran on the cooperative
/// pool at once: each passed the `state != .starting` guard before any had
/// written `.starting`, then wrote `state` (an enum with a String payload)
/// concurrently. A torn read of that payload inside the Observation
/// `shouldNotifyObservers` equality check was a SIGSEGV at launch. On the main
/// actor the guard and the write are one uninterrupted step, so the later
/// callers see the start in flight (`isStartInFlight`) and return.
@Observable
@MainActor
final class MCPServerLauncher {
    static let shared = MCPServerLauncher()

    enum LaunchState: Equatable {
        case idle
        case starting
        case settingUp(String)
        case running
        case failed(String)
        /// Another ForeverLM signed in to this Apple ID took the tunnel, and
        /// this one stepped aside until it leaves. Assistants still reach the
        /// library, through that instance. It is its own state rather than
        /// `.settingUp(reason)` because Settings would show that as "Connecting..."
        /// with a spinner for as long as the other Mac stayed up.
        case servedElsewhere
    }

    private(set) var state: LaunchState = .idle

    var isInProgress: Bool {
        switch state {
        case .starting, .settingUp: return true
        default: return false
        }
    }

    /// The stable public tunnel URL for this user.
    private(set) var tunnelURL: String?

    /// The full MCP endpoint URL for display in the UI.
    var mcpURL: String? {
        guard let tunnelURL else { return nil }
        return "\(tunnelURL)/mcp"
    }

    private let relay = MCPRelayClient()
    private let logger = Logger(subsystem: "ForeverLM", category: "MCPLauncher")
    private var lastProvisionError: String?
    private var loopbackServer: MCPHTTPServer?

    /// True from the first line of `startHostedTunnel` to its return, so the
    /// launch-time callers that arrive together see one start and return. It
    /// also tells a start's own `.settingUp` apart from the relay's: outside a
    /// start, `.settingUp` means the relay is getting the tunnel back by itself.
    private var isStartInFlight = false

    /// Provisioner endpoints, tried in order. Distinct hosts only — a repeated
    /// entry costs a second identical round trip on every failure and hides the
    /// fact that there is one fewer fallback than it looks like.
    ///
    /// One address, in the brand zone. The Worker's workers.dev host is not a
    /// fallback: it sits on a personal account subdomain, and a zone-level DNS
    /// failure takes the site and the other services down with it anyway.
    /// `mcp.<brand>` is not one either: it resolves to the MCP offline page,
    /// which answers Cloudflare 1042 (a Worker cannot subrequest another
    /// Worker on its own zone). A fallback that cannot succeed is not a
    /// fallback; it just delays the one that can.
    private static let provisionerURLs = [
        "https://provision.\(MCPBrandDomains.current)",
    ]

    // MARK: - Public API

    func autoStart() async {
        guard MCPRuntimePreferences.assistantIntegrationsEnabled else {
            await stop()
            return
        }
        // The tunnel is keyed by Apple ID, so a development build launched
        // beside the installed app would take the same address over the moment
        // it connected, and the installed app never noticed it had lost it.
        // A development build's automatic start now leaves a live tunnel alone;
        // pressing Connect still takes it deliberately.
        await startHostedTunnel(yieldingToLiveInstance: ForeverLMRuntimeIdentity.isDevelopment)
    }

    func start() async {
        await startHostedTunnel()
    }

    /// `takingOver` is the learner choosing this Mac while another ForeverLM
    /// serves the tunnel (Use This Mac in Settings). The relay hands the address
    /// here and the other instance steps aside in turn, so the two do not fight.
    func startHostedTunnel(yieldingToLiveInstance: Bool = false, takingOver: Bool = false) async {
        // The one entitlement gate on the tunnel: it does not connect while the
        // app is locked (product owner, 2026-10-10: the free days over and
        // nothing paid; `ManagedAI.isAppLocked`). The app scene stops a running
        // tunnel when the lock comes on and starts it again when it lifts. A
        // tool call that reaches this Mac anyway is refused by
        // `MCPProtocolHandler.appLockRefusal`, and the hosted gateway refuses
        // its own on the account server's word.
        guard !ManagedAI.isAppLocked else { return }
        guard !isStartInFlight, state != .running else { return }
        isStartInFlight = true
        defer { isStartInFlight = false }

        // The relay reconnecting after a drop, or waiting for another instance
        // to leave the tunnel, is left to finish: a fresh connect would only
        // restart it, and taking the tunnel back on app activation is the fight
        // stepping aside ended. A relay that has stopped trying gets one, which
        // is what app activation and Connect are for.
        let relayMayBeRecovering: Bool
        switch state {
        case .settingUp: relayMayBeRecovering = true
        case .servedElsewhere: relayMayBeRecovering = !takingOver
        case .idle, .starting, .running, .failed: relayMayBeRecovering = false
        }
        if relayMayBeRecovering {
            guard await !relay.isRecoveringOnItsOwn() else { return }
            logger.warning("The MCP relay stopped reconnecting on its own; starting a fresh connection")
        }
        state = .starting
        lastProvisionError = nil

        await relay.setOnConnectionRestored { [weak self] connectedURL in
            Task { @MainActor in
                self?.finishSuccessfulConnection(
                    connectedURL: connectedURL,
                    requestedURL: connectedURL
                )
            }
        }

        // A live socket dropped and the relay is reconnecting on its own. The
        // launcher has to hear it: startHostedTunnel returns early while
        // .running, so a launcher that kept reporting .running would ignore app
        // activation and Connect, and only switching assistant integrations
        // off and on would bring the tunnel back.
        // The relay also calls this when the instance it stepped aside for has
        // left and it starts taking the tunnel back.
        await relay.setOnConnectionLost { [weak self] reason in
            Task { @MainActor in
                guard let self, self.state == .running || self.state == .servedElsewhere else { return }
                // Handlers each hop to the main actor on a task of their own, so
                // a quick reconnect's onConnectionRestored can run before this.
                // Ask the relay rather than trust the order.
                guard await !self.relay.isConnected,
                      self.state == .running || self.state == .servedElsewhere else { return }
                self.logger.warning("MCP relay connection lost (\(reason, privacy: .public)); the relay is reconnecting")
                self.state = .settingUp("Reconnecting...")
            }
        }

        // Authentication rejection is the only terminal reconnect condition.
        // Transient failures remain inside the relay's bounded-backoff loop.
        await relay.setOnPermanentDisconnect { [weak self] reason in
            Task { @MainActor in
                guard let self else { return }
                self.state = .failed(reason)
                self.tunnelURL = nil

                // Recover a revoked credential without waiting for a Settings
                // interaction. startHostedTunnel validates the rejection before
                // replacing anything persisted in Keychain.
                guard MCPRuntimePreferences.assistantIntegrationsEnabled else { return }
                await self.startHostedTunnel()
            }
        }

        // Retries continue in the relay; this only stops the UI from presenting a
        // dead hostname as an in-progress connection. onConnectionRestored puts
        // the state back to .running if a later attempt succeeds.
        await relay.setOnSustainedFailure { [weak self] detail in
            Task { @MainActor in
                guard let self else { return }
                guard case .settingUp = self.state else { return }
                self.state = .failed("The MCP relay is not reachable. Still retrying. \(detail)")
            }
        }

        // Step 1: Ensure OAuth credentials exist
        configureOAuthEnvironment()

        // Stepping aside is not a failure: the relay's socket for this tunnel
        // is now someone else's, and the client reconnects on its own once
        // that instance leaves, which comes back through onConnectionRestored.
        // The relay logs the reason itself, with the tunnel's address.
        await relay.setOnConnectionYielded { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.state = .servedElsewhere
            }
        }

        // Step 2: Get or provision tunnel credentials
        state = .settingUp("Connecting...")
        var token = KeychainService.load(.mcpTunnelToken)
        var url = KeychainService.load(.mcpTunnelURL)

        // A URL on a retired brand domain is stale by construction, not merely
        // unreachable: the relay's routes and the tunnel's DNS record moved to
        // the current domain together, so the cached host resolves nowhere. The
        // relay reports that as a transport failure, which is retried forever,
        // so a stale host has to be recognised here — before connecting — or the
        // app never leaves "Connecting...". The provisioner is keyed on this
        // user's Apple identity and returns the same tunnel at its current
        // hostname, so this costs one request and no identity churn.
        var cachedURLIsStale = url.map { !MCPBrandDomains.isOnCurrentDomain($0) } ?? false
        if cachedURLIsStale, let url {
            logger.notice("Cached MCP URL \(url) is on a retired brand domain; re-provisioning")
        }
        // A tunnel provisioned under another identity rule is another build's:
        // a Dev build that cached the installed app's tunnel before Dev builds
        // had identities of their own would otherwise keep taking it over. A
        // cache with no recorded identity predates the record and is treated
        // the same way; the provisioner is idempotent per identity, so the
        // installed app gets its own tunnel back and the marker is written once.
        if !cachedURLIsStale, url != nil, let seed = provisioningIdentitySeed(),
           KeychainService.load(.mcpTunnelIdentity) != Self.identityHash(seed: seed) {
            logger.notice("Cached MCP tunnel was provisioned under another identity, or before identities were recorded; re-provisioning")
            cachedURLIsStale = true
        }
        let hasCachedTunnelCredentials = token != nil && url != nil && !cachedURLIsStale

        if token == nil || url == nil || cachedURLIsStale {
            state = .settingUp("Setting up your MCP URL...")
            let provisioned = await provisionTunnel()
            if provisioned {
                token = KeychainService.load(.mcpTunnelToken)
                url = KeychainService.load(.mcpTunnelURL)
            }
        }

        guard let token, let url else {
            let detail = lastProvisionError ?? "Could not provision MCP tunnel credentials."
            state = .failed("Could not set up MCP. \(detail)")
            return
        }

        // Step 3: Connect to relay via WebSocket
        if yieldingToLiveInstance, await relay.isTunnelServedByAnotherInstance(tunnelURL: url) {
            logger.notice("Another ForeverLM is serving \(url, privacy: .public); this development build is leaving it alone")
            state = .failed("Another ForeverLM is already serving \(url). Quit it, or press Connect to take the address over for this development build.")
            return
        }
        await MCPGatewayAuthorizationVerifier.shared.configure(tunnelToken: token)
        state = .settingUp("Connecting to relay...")
        if let connectedURL = await relay.connect(tunnelURL: url, tunnelToken: token) {
            finishSuccessfulConnection(connectedURL: connectedURL, requestedURL: url)
            return
        }

        let firstError = await relay.connectionErrorMessage() ?? "The relay did not accept the WebSocket connection."
        let firstFailureKind = await relay.connectionFailureKind() ?? .transient

        // A timeout, DNS failure, 5xx response, or other transient outage says
        // nothing about credential validity. Keep the credentials and reconnect
        // automatically with capped exponential backoff.
        guard firstFailureKind == .authenticationRejected else {
            logger.warning("Relay connection is temporarily unavailable; preserving credentials and retrying: \(firstError)")
            state = .settingUp("Reconnecting...")
            await relay.startAutomaticReconnect()
            return
        }

        guard hasCachedTunnelCredentials else {
            state = .failed(firstError)
            return
        }

        logger.warning("Relay explicitly rejected cached credentials; attempting reprovision: \(firstError)")
        state = .settingUp("Refreshing MCP URL...")

        // Never delete the last-known-good pair before its replacement exists.
        // provisionTunnel writes the replacement only after a complete successful
        // response, so a refused session or a provisioner outage is recoverable.
        guard await provisionTunnel(),
              let refreshedToken = KeychainService.load(.mcpTunnelToken),
              let refreshedURL = KeychainService.load(.mcpTunnelURL) else {
            let provisionDetail = lastProvisionError ?? "Provisioning did not return tunnel credentials."
            state = .failed("Relay credential refresh failed; the previous credentials were preserved. \(provisionDetail) \(firstError)")
            return
        }

        state = .settingUp("Connecting to relay...")
        await MCPGatewayAuthorizationVerifier.shared.configure(tunnelToken: refreshedToken)
        guard let connectedURL = await relay.connect(tunnelURL: refreshedURL, tunnelToken: refreshedToken) else {
            let secondError = await relay.connectionErrorMessage() ?? "The relay did not accept the WebSocket connection."
            let secondFailureKind = await relay.connectionFailureKind() ?? .transient
            if secondFailureKind == .transient {
                logger.warning("Relay unavailable after credential refresh; retrying automatically: \(secondError)")
                state = .settingUp("Reconnecting...")
                await relay.startAutomaticReconnect()
            } else {
                state = .failed("Relay rejected newly provisioned credentials. \(secondError)")
            }
            return
        }

        finishSuccessfulConnection(connectedURL: connectedURL, requestedURL: refreshedURL)
    }

    func stop() async {
        await relay.disconnect()
        await MCPGatewayAuthorizationVerifier.shared.clear()
        loopbackServer?.stop()
        loopbackServer = nil
        tunnelURL = nil
        state = .idle
    }

    // MARK: - Tunnel Provisioning

    /// The Apple `sub`, and nothing else.
    ///
    /// This seed becomes `tunnels.user_id = SHA256(seed)`, which the relay matches against
    /// `managed_ai_accounts.apple_sub_hash` to decide who to bill. There is no
    /// fallback that derives a `local-mcp-<clientID>` seed when the Apple ID is
    /// missing: it would provision a tunnel whose user_id can never match any account, so
    /// every tool call would fail as unbillable while the connection looked healthy.
    ///
    /// A wrong identity is worse than no identity: refuse to provision instead. The app
    /// only starts MCP once the account wall has cleared (`hasAccountAccess`), so a
    /// missing value here means the sign-in path failed to persist it, which is a bug to
    /// surface, not to route around.
    private func provisioningIdentitySeed() -> String? {
        guard let appleUserID = KeychainService.load(.appleUserID),
              !appleUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Self.identitySeed(appleUserID: appleUserID, isDevelopment: ForeverLMRuntimeIdentity.isDevelopment)
    }

    /// The suffix a development build appends to its Apple user id before
    /// hashing, so it provisions and holds a tunnel of its own instead of the
    /// installed app's. The gateway appends the same to the Apple `sub` when
    /// it issues a grant for its `/dev/mcp` resource (`DEV_IDENTITY_SUFFIX` in
    /// workers/mcp-gateway/src/config.ts), and the AI proxy when it answers the
    /// `development_apple_sub_hash` the tunnel provisioner accepts
    /// (`MCP_DEVELOPMENT_IDENTITY_SUFFIX`); the three must agree.
    static let developmentIdentitySuffix = "#dev"

    /// What is hashed into the tunnel's `user_id`: the Apple user id as is for
    /// the installed app, and with `developmentIdentitySuffix` for a Dev build.
    nonisolated static func identitySeed(appleUserID: String, isDevelopment: Bool) -> String {
        isDevelopment ? appleUserID + developmentIdentitySuffix : appleUserID
    }

    /// The hash a seed provisions under — the `user_id` the tunnels table keys on.
    nonisolated static func identityHash(seed: String) -> String {
        SHA256.hash(data: Data(seed.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func provisioningFailureMessage(statusCode: Int, data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String,
           !error.isEmpty {
            return "Provisioning returned HTTP \(statusCode): \(error)"
        }
        if let body = String(data: data, encoding: .utf8),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Provisioning returned HTTP \(statusCode): \(body)"
        }
        return "Provisioning returned HTTP \(statusCode)."
    }

    /// The request that asks for this identity's tunnel. Its bearer is the
    /// learner's own managed session, the one Sign in with Apple minted: the
    /// provisioner has the proxy verify it and accepts only the installed-app or
    /// development identity that session belongs to, so no request can reach
    /// another learner's tunnel. (A secret baked into the binary would be
    /// extractable by anyone holding the app.)
    nonisolated static func provisioningRequest(baseURL: String, userIDHash: String, sessionToken: String) -> URLRequest? {
        guard let url = URL(string: "\(baseURL)/provision") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["user_id": userIDHash])
        return request
    }

    /// A refusal the provisioner makes on the request itself (no session, a
    /// session it would not accept, an identity that is not the session's, a
    /// spent budget, a malformed body). Every endpoint is the same Worker, so a
    /// second address would only repeat it. Only the provisioner's own JSON,
    /// which carries a `code`, counts: a 403 from Cloudflare's edge is not the
    /// provisioner speaking, so a later address in the list may still answer.
    nonisolated static func isProvisioningVerdict(statusCode: Int, data: Data) -> Bool {
        guard [400, 401, 403, 429].contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String else { return false }
        return !code.isEmpty
    }

    @discardableResult
    private func configureOAuthEnvironment() -> (clientID: String, clientSecret: String) {
        let creds = KeychainService.ensureMCPOAuthCredentials()
        setenv("OAUTH_CLIENT_ID", creds.clientID, 1)
        setenv("OAUTH_CLIENT_SECRET", creds.clientSecret, 1)
        return creds
    }

    private func finishSuccessfulConnection(connectedURL: String, requestedURL: String) {
        tunnelURL = connectedURL
        setenv("OAUTH_ISSUER_URL", connectedURL, 1)
        if connectedURL != requestedURL {
            KeychainService.save(connectedURL, for: .mcpTunnelURL)
            logger.info("Updated cached MCP URL to working relay host \(connectedURL)")
        }
        startLoopbackListener()
        state = .running
        logger.info("MCP server ready at \(connectedURL)")
    }

    /// Loopback listener (bound to 127.0.0.1, local connections only) exposing
    /// ONLY `GET /mcp-url`, the personal URL this app serves now
    /// (`personalURLResponse`). It carries no OAuth route: every authorization
    /// is approved by the learner in the app (match code) or with the pairing
    /// code. Everything else stays relay-only so the local port opens no data
    /// surface. If the port is taken, Settings still shows the URL, so a bind
    /// failure is logged and otherwise ignored.
    private func startLoopbackListener() {
        guard loopbackServer == nil else { return }
        let server = MCPHTTPServer()
        server.route("*", Self.personalURLPath) { [weak self] request in
            let tunnelURL = await self?.tunnelURL
            return Self.personalURLResponse(to: request, tunnelURL: tunnelURL, port: MCPHTTPServer.loopbackPort)
        }
        do {
            try server.start(port: MCPHTTPServer.loopbackPort)
            loopbackServer = server
        } catch {
            logger.warning("Loopback listener failed to start: \(error.localizedDescription)")
        }
    }

    /// Where a program on this Mac asks for the personal URL:
    /// `GET http://127.0.0.1:<ForeverLMRuntimeIdentity.mcpLoopbackPort>/mcp-url`.
    nonisolated static let personalURLPath = "/mcp-url"

    /// The loopback answer to `GET /mcp-url`: `{"url": <tunnel URL>}` and
    /// nothing else, with no token and nothing from the library.
    ///
    /// The personal URL follows the Apple identity. A change of developer team
    /// gives the same learner a new Sign in with Apple `sub` and so a new
    /// tunnel, and the old address answers 503 "app not running" forever. A
    /// plugin whose saved URL answers that asks here, and follows the move
    /// without anyone copying the new URL out of Settings. The
    /// listener opens only once the relay has accepted this app's tunnel, so
    /// the URL it names is one the relay has served to this app.
    ///
    /// Only a local program gets an answer. The URL is not a credential, but it
    /// is a stable identifier that no web page should read. A browser marks
    /// every request a page makes with `Origin` or `Sec-Fetch-Site`, and a page
    /// that rebinds its own hostname to 127.0.0.1 still sends that hostname as
    /// `Host`. A request with either mark, or naming any host but loopback, is
    /// refused.
    nonisolated static func personalURLResponse(to request: HTTPRequest, tunnelURL: String?, port: UInt16) -> HTTPResponse {
        guard request.path == personalURLPath else {
            return .json(["error": "Not found"], status: 404)
        }
        guard request.method == "GET" else {
            return .json(["error": "method_not_allowed"], status: 405)
        }
        guard isLocalProgramRequest(headers: request.headers, port: port) else {
            return .json(["error": "forbidden"], status: 403)
        }
        guard let tunnelURL, !tunnelURL.isEmpty else {
            return .json(["error": "not_connected"], status: 503)
        }
        return .json(["url": tunnelURL])
    }

    /// True for a request a program sent to this listener by its loopback
    /// address, and false for anything a browser sent on a page's behalf.
    /// `Sec-Fetch-Site: none` is the learner typing the address themselves.
    /// The listener binds 127.0.0.1 only, so those are the only names a
    /// program can have used to reach it.
    nonisolated static func isLocalProgramRequest(headers: [String: String], port: UInt16) -> Bool {
        if headers["origin"] != nil { return false }
        if let site = headers["sec-fetch-site"], site.lowercased() != "none" { return false }
        guard let host = headers["host"]?.lowercased() else { return false }
        return ["127.0.0.1", "localhost"].contains { host == $0 || host == "\($0):\(port)" }
    }

    private func provisionTunnel() async -> Bool {
        guard let identitySeed = provisioningIdentitySeed() else {
            lastProvisionError = "MCP can't start: your Apple account isn't linked on this Mac. "
                + "Sign out and sign in with Apple again from the account menu."
            logger.error("No Apple User ID in Keychain — refusing to provision an unbillable tunnel")
            return false
        }

        let userIdHash = Self.identityHash(seed: identitySeed)

        guard let sessionToken = ManagedAI.requestSessionToken else {
            lastProvisionError = "MCP can't start: this Mac isn't signed in to ForeverLM. "
                + "Sign in with Apple from the account menu."
            logger.error("No managed session in Keychain — nothing to authorize tunnel provisioning with")
            return false
        }

        var attemptErrors: [String] = []

        for baseURL in Self.provisionerURLs {
            guard let request = Self.provisioningRequest(baseURL: baseURL, userIDHash: userIdHash, sessionToken: sessionToken) else {
                attemptErrors.append("\(baseURL): invalid URL")
                continue
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    let detail = "Provisioning endpoint returned an invalid response."
                    logger.warning("Provisioning failed via \(baseURL): \(detail)")
                    attemptErrors.append("\(baseURL): \(detail)")
                    continue
                }

                guard (200...201).contains(http.statusCode) else {
                    let detail = provisioningFailureMessage(statusCode: http.statusCode, data: data)
                    logger.warning("Provisioning failed via \(baseURL): \(detail)")
                    if Self.isProvisioningVerdict(statusCode: http.statusCode, data: data) {
                        lastProvisionError = detail
                        return false
                    }
                    attemptErrors.append("\(baseURL): \(detail)")
                    continue
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tunnelToken = json["tunnel_token"] as? String,
                      let tunnelUrl = json["tunnel_url"] as? String,
                      let oauthClientId = json["oauth_client_id"] as? String,
                      let oauthClientSecret = json["oauth_client_secret"] as? String else {
                    let detail = "Provisioning response is missing required tunnel fields."
                    logger.warning("Provisioning failed via \(baseURL): \(detail)")
                    attemptErrors.append("\(baseURL): \(detail)")
                    continue
                }

                KeychainService.save(tunnelToken, for: .mcpTunnelToken)
                KeychainService.save(tunnelUrl, for: .mcpTunnelURL)
                KeychainService.save(userIdHash, for: .mcpTunnelIdentity)
                KeychainService.save(oauthClientId, for: .mcpOAuthClientID)
                KeychainService.save(oauthClientSecret, for: .mcpOAuthClientSecret)

                lastProvisionError = nil
                logger.info("Provisioned via \(baseURL): \(tunnelUrl)")
                return true
            } catch {
                let detail = error.localizedDescription
                logger.warning("Provisioning request failed via \(baseURL): \(detail)")
                attemptErrors.append("\(baseURL): \(detail)")
            }
        }

        let details = attemptErrors.isEmpty ? "No provisioner endpoints were available." : attemptErrors.joined(separator: " | ")
        lastProvisionError = "Provisioning failed across all endpoints. \(details)"
        return false
    }
}
#endif
