import Foundation
import OSLog

#if os(macOS) || os(iOS)

/// The domains this app's hosted MCP tunnels have lived on.
///
/// A tunnel URL is not a stable identifier: it is `{subdomain}.{brand domain}`,
/// and the brand domain is a property of the *current* build, not of the tunnel.
/// When the product was renamed, the relay's Worker routes and every tunnel's DNS
/// record moved to the new zone in one step, so a URL cached under the old domain
/// stopped resolving entirely. That failure is indistinguishable from an outage at
/// the transport layer, so a client that keeps a retired URL retries a hostname
/// that will never answer and reports nothing but "connecting" forever.
///
/// This is the one place that knows the difference. `retired` exists only so a
/// stale cached URL can be recognised and replaced; nothing may address a retired
/// domain as a current identifier or dual-read from it indefinitely.
enum MCPBrandDomains {
    /// The brand domain this build's relay and provisioner serve.
    static let current = "foreverlm.com"

    /// Brand domains that have hosted tunnels in shipped builds and no longer do.
    static let retired = ["feynmanlm.com"]

    /// Current first — a candidate list is tried in order.
    static let all = [current] + retired

    /// Whether `tunnelURL`'s host still belongs to the domain this build serves.
    ///
    /// A cached tunnel URL that fails this is stale by construction and must be
    /// re-provisioned rather than retried: the provisioner is what knows the
    /// user's current hostname and what publishes its DNS.
    static func isOnCurrentDomain(_ tunnelURL: String) -> Bool {
        guard let host = URL(string: tunnelURL)?.host else { return false }
        return host == current || host.hasSuffix(".\(current)")
    }
}

/// Relay responses the app finished but could not send, because the socket was
/// down at that moment.
///
/// A relayed request is answered whether or not the socket that carried it is
/// still open: the tool has run — on 2026-09-19 an `add_goal_sources` write landed
/// in the store while the Mac, starved by a compiler build, lost its socket — and
/// dropping the answer left the caller to time out and be told the tool did not
/// exist. The relay keeps a request pending for `REQUEST_BUDGET_MS` (60 s) after
/// the socket closes, so an answer that arrives on the reconnected socket inside
/// that window still reaches the caller. Held responses are therefore bounded the
/// same way: anything older than the relay's budget cannot be matched and is
/// dropped, and the queue keeps at most `capacity` entries so a long outage never
/// grows it without limit.
struct MCPRelayHeldResponses: Sendable {
    struct Entry: Equatable, Sendable {
        let requestID: String
        let text: String
        let heldAt: Date
    }

    /// Mirrors `REQUEST_BUDGET_MS` in `workers/mcp-relay`: past this the relay has
    /// already answered the caller, and a late response would be dropped there.
    static let retention: TimeInterval = 60
    static let capacity = 64

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Keep `entry`, evicting anything already past retention and, if the queue is
    /// still full, the oldest entry.
    mutating func hold(_ entry: Entry) {
        entries.removeAll { entry.heldAt.timeIntervalSince($0.heldAt) > Self.retention }
        if entries.count >= Self.capacity {
            entries.removeFirst(entries.count - Self.capacity + 1)
        }
        entries.append(entry)
    }

    mutating func hold(requestID: String, text: String, now: Date = Date()) {
        hold(Entry(requestID: requestID, text: text, heldAt: now))
    }

    /// Remove and return every entry still inside the relay's budget, oldest first.
    /// Entries past it are discarded: the relay has already answered that caller.
    mutating func drain(now: Date = Date()) -> [Entry] {
        let due = entries.filter { now.timeIntervalSince($0.heldAt) <= Self.retention }
        entries.removeAll()
        return due
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

/// Connects to the MCP WebSocket relay worker.
/// Replaces cloudflared — no binary download needed, works in sandbox and on iOS.
///
/// The relay worker sits at `*.foreverlm.com`. This client:
/// 1. Opens a WebSocket to `wss://{subdomain}.foreverlm.com/ws?token={token}`
/// 2. Receives HTTP requests forwarded by the relay (from Claude.ai/ChatGPT)
/// 3. Processes them via the in-process MCP server
/// 4. Sends responses back over WebSocket
actor MCPRelayClient {
    enum ConnectionFailureKind: Equatable, Sendable {
        case authenticationRejected
        case transient
    }

    private let logger = Logger(subsystem: "ForeverLM", category: "MCPRelay")
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private(set) var isConnected = false
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var tunnelURL: String?
    private var tunnelToken: String?
    private var lastConnectionError: String?
    private var lastConnectionFailureKind: ConnectionFailureKind?

    /// Requests the relay has handed to the app but not yet answered. The
    /// client may cancel its HTTP request (ChatGPT's Stop button does this)
    /// while the Mac is still indexing or waiting on a model, so the relay
    /// sends a matching cancellation frame and this task must be stopped too.
    private var inFlightRequests: [String: Task<Void, Never>] = [:]

    /// Nonces of liveness probes that arrived back through *this* socket. See
    /// `verifyTunnelOwnership`.
    private var seenProbeNonces: Set<String> = []
    /// Set while this client has stepped aside for another ForeverLM serving the
    /// same tunnel; cleared when it reconnects.
    private var yieldedToAnotherInstance = false
    private var yieldMonitorTask: Task<Void, Never>?

    /// Answers finished while the socket was down; sent once it is back. See
    /// `MCPRelayHeldResponses`.
    private var heldResponses = MCPRelayHeldResponses()

    /// Called when this client finds another ForeverLM serving its tunnel and
    /// steps aside rather than fighting for it. It reconnects on its own once
    /// that instance goes away, reported through onConnectionRestored.
    private var onConnectionYielded: (@Sendable (String) -> Void)?

    /// Called when a background reconnect succeeds so the launcher can republish
    /// its running state without requiring a Settings interaction.
    private var onConnectionRestored: (@Sendable (String) -> Void)?

    /// Called only when the relay explicitly rejects the saved credential. A
    /// transient network or relay outage keeps retrying automatically.
    private var onPermanentDisconnect: (@Sendable (String) -> Void)?

    /// Called once per reconnect loop when retries have failed long enough that
    /// calling this an outage is no longer honest. Retrying continues; this
    /// exists so the UI can stop claiming to be connecting and show what failed.
    private var onSustainedFailure: (@Sendable (String) -> Void)?

    /// Called when a connected socket drops for a reason other than another
    /// instance taking the tunnel over, or when the instance this client stepped
    /// aside for has left, as the relay starts reconnecting on its own. Without
    /// it the launcher kept reporting `.running` through the whole
    /// outage, and a launcher that believes it is running ignores both app
    /// activation and Connect. Reconnecting succeeds through onConnectionRestored.
    private var onConnectionLost: (@Sendable (String) -> Void)?

    /// When the reconnect loop last moved: an attempt began, or one ended and
    /// its backoff began. See `isRecoveringOnItsOwn`.
    private var reconnectLoopMovedAt: ContinuousClock.Instant?

    private let heartbeatInterval: Duration
    private let pingTimeout: Duration

    /// The defaults are what the app runs with; tests shorten them.
    init(heartbeatInterval: Duration = .seconds(30), pingTimeout: Duration = .seconds(10)) {
        self.heartbeatInterval = heartbeatInterval
        self.pingTimeout = pingTimeout
    }

    func setOnConnectionRestored(_ handler: (@Sendable (String) -> Void)?) {
        onConnectionRestored = handler
    }

    func setOnConnectionLost(_ handler: (@Sendable (String) -> Void)?) {
        onConnectionLost = handler
    }

    func setOnPermanentDisconnect(_ handler: (@Sendable (String) -> Void)?) {
        onPermanentDisconnect = handler
    }

    func setOnSustainedFailure(_ handler: (@Sendable (String) -> Void)?) {
        onSustainedFailure = handler
    }

    func setOnConnectionYielded(_ handler: (@Sendable (String) -> Void)?) {
        onConnectionYielded = handler
    }

    /// Connect to the relay. Returns the working public MCP URL on success.
    func connect(tunnelURL: String, tunnelToken: String) async -> String? {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        yieldMonitorTask?.cancel()
        yieldMonitorTask = nil
        yieldedToAnotherInstance = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false

        self.tunnelURL = tunnelURL
        self.tunnelToken = tunnelToken

        return await doConnect()
    }

    func connectionErrorMessage() -> String? {
        lastConnectionError
    }

    func connectionFailureKind() -> ConnectionFailureKind? {
        lastConnectionFailureKind
    }

    /// Continue recovering from a transient initial connection failure. The
    /// disconnect receive path uses this same event-driven backoff loop.
    func startAutomaticReconnect() {
        scheduleReconnect()
    }

    func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        yieldMonitorTask?.cancel()
        yieldMonitorTask = nil
        yieldedToAnotherInstance = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        lastConnectionFailureKind = nil
        // A deliberate stop: nothing will reconnect to carry these, and the relay
        // rejects the requests behind them as soon as it sees the close.
        heldResponses.removeAll()
        logger.info("Disconnected from relay")
    }

    private func doConnect() async -> String? {
        guard let tunnelURL, let tunnelToken else { return nil }

        let candidates = relayURLCandidates(from: tunnelURL)
        var attemptErrors: [String] = []
        var responseStatusCodes: [Int?] = []

        for candidateURL in candidates {
            let wsURL = candidateURL
                .replacingOccurrences(of: "https://", with: "wss://")
                .appending("/ws?token=\(tunnelToken)")

            guard let url = URL(string: wsURL) else {
                attemptErrors.append("invalid URL \(wsURL)")
                responseStatusCodes.append(nil)
                continue
            }

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: url)
            urlSession = session
            webSocket = task
            task.resume()

            let pingError: Error?
            do {
                try await Self.ping(task, within: pingTimeout)
                pingError = nil
            } catch {
                pingError = error
            }

            // A newer connect or a disconnect replaced this attempt while it
            // waited for its pong. The shared socket and error state are that
            // one's now, so this attempt closes its own socket and leaves them
            // alone: clearing them here would strand the live connection with
            // no socket to answer on.
            guard webSocket === task else {
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                return nil
            }

            if let pingError {
                let statusCode = (task.response as? HTTPURLResponse)?.statusCode
                responseStatusCodes.append(statusCode)
                let statusDetail = statusCode.map { "HTTP \($0), " } ?? ""
                attemptErrors.append("\(candidateURL): \(statusDetail)\(pingError.localizedDescription)")
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                webSocket = nil
                urlSession = nil
                continue
            }

            self.tunnelURL = candidateURL
            isConnected = true
            lastConnectionError = nil
            lastConnectionFailureKind = nil
            logger.info("Connected to relay at \(candidateURL)")

            startReceiving(from: task)
            startReconnectMonitor()
            Task { await self.flushHeldResponses() }

            return candidateURL
        }

        let message = "Relay handshake failed: \(attemptErrors.joined(separator: " | "))"
        lastConnectionError = message
        lastConnectionFailureKind = Self.failureKind(forHTTPStatusCodes: responseStatusCodes)
        logger.error("\(message)")
        isConnected = false
        return nil
    }

    /// Re-provisioning is destructive to cached connectivity, so only an
    /// explicit authentication rejection is evidence that the credential is
    /// stale. Missing responses, timeouts, 5xx errors, and mixed results are all
    /// transient and must retain the last-known-good credential.
    nonisolated static func failureKind(forHTTPStatusCodes statusCodes: [Int?]) -> ConnectionFailureKind {
        let observed = statusCodes.compactMap { $0 }
        guard !observed.isEmpty,
              observed.count == statusCodes.count,
              observed.allSatisfy({ $0 == 401 || $0 == 403 }) else {
            return .transient
        }
        return .authenticationRejected
    }

    // MARK: - Message Handling

    private func startReceiving(from socket: URLSessionWebSocketTask) {
        Task { [weak self] in
            while let self {
                do {
                    let message = try await socket.receive()
                    await self.handleMessage(message)
                } catch {
                    await self.handleDisconnect(error, socket: socket)
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let d):
            data = d
        @unknown default:
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = json["id"] as? String else {
            logger.warning("Invalid relay message: missing id")
            return
        }

        if json["type"] as? String == "cancel" {
            inFlightRequests.removeValue(forKey: requestID)?.cancel()
            logger.info("Cancelled relayed request \(requestID, privacy: .public)")
            return
        }

        let method = json["method"] as? String ?? "GET"
        let path = json["path"] as? String ?? "/"
        if let nonce = Self.probeNonce(fromPath: path) {
            // A probe whose answer never came back would otherwise leave its
            // nonce behind; the set is tiny, so clearing it is fine.
            if seenProbeNonces.count > 64 { seenProbeNonces.removeAll() }
            seenProbeNonces.insert(nonce)
        }
        let headersDict = json["headers"] as? [String: String] ?? [:]
        let bodyStr = json["body"] as? String ?? ""
        let bodyData = Data(bodyStr.utf8)
        let queryString: String
        if let qIndex = path.firstIndex(of: "?") {
            queryString = String(path[path.index(after: qIndex)...])
        } else {
            queryString = ""
        }
        let cleanPath = path.contains("?") ? String(path[..<path.firstIndex(of: "?")!]) : path

        #if os(macOS)
        let request = HTTPRequest(
            method: method,
            path: cleanPath,
            queryString: queryString,
            headers: headersDict,
            body: bodyData
        )

        // Process the request through our in-process MCP server. Someone is
        // waiting on the far end of every relayed request, so it runs at
        // user-initiated priority: the storage actor's queue is ordered by
        // priority, and a plain Task here would queue a `list_docs` behind
        // whatever maintenance the app happens to be running.
        let task = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let response = await self.processRequest(request)
            guard !Task.isCancelled else { return }
            await self.sendResponse(requestID: requestID, response: response)
            await self.finishRequest(requestID)
        }
        inFlightRequests[requestID] = task
        #else
        logger.warning("MCP relay message received on iOS — relay processing not supported on this platform (path: \(cleanPath))")
        #endif
    }

    private func finishRequest(_ requestID: String) {
        inFlightRequests.removeValue(forKey: requestID)
    }

    #if os(macOS)
    private func processRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // Route hosted relay traffic through the app's MCP handlers.

        // Health check
        if request.path == "/health" {
            return .text("ok")
        }

        // OAuth / discovery
        if request.path.hasPrefix("/.well-known") || request.path.hasPrefix("/oauth") {
            let oauthProvider = await MCPOAuthProvider.sharedProvider()
            if let oauthResponse = await oauthProvider.handleRequest(request) {
                return oauthResponse
            }
        }

        // CORS preflight
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 200, statusText: "OK", headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization, Mcp-Session-Id",
            ], body: Data())
        }

        // MCP protocol
        if request.path == "/mcp" && request.method == "POST" {
            switch await authorizeMCPRequest(request) {
            case .unauthorized(let response):
                return response
            case .authorized(let access):
                return await MCPProtocolHandler.shared.handleRequest(request, access: access)
            }
        }

        return .json(["error": "Not found"], status: 404)
    }

    private func sendResponse(requestID: String, response: HTTPResponse) async {
        let responseJSON: [String: Any] = [
            "id": requestID,
            "status": response.status,
            "headers": response.headers,
            "body": String(data: response.body, encoding: .utf8) ?? "",
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: responseJSON),
              let text = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize response for request \(requestID)")
            return
        }

        // The tool has run by now; the socket may not have survived it. An answer
        // the socket cannot carry is held for the reconnect rather than dropped,
        // because the relay keeps its request pending across the gap — see
        // `MCPRelayHeldResponses`.
        guard let webSocket else {
            heldResponses.hold(requestID: requestID, text: text)
            logger.warning("Holding response for request \(requestID, privacy: .public): the relay socket is down")
            return
        }
        do {
            try await webSocket.send(.string(text))
        } catch {
            heldResponses.hold(requestID: requestID, text: text)
            logger.warning("Holding response for request \(requestID, privacy: .public): send failed (\(error.localizedDescription))")
        }
    }

    /// Send every response held while the socket was down, oldest first, over the
    /// socket that is up now. A send failure puts the rest back for the next
    /// reconnect; their age still bounds them.
    private func flushHeldResponses() async {
        let due = heldResponses.drain()
        guard !due.isEmpty else { return }
        guard let socket = webSocket else {
            due.forEach { heldResponses.hold($0) }
            return
        }
        for (position, entry) in due.enumerated() {
            do {
                try await socket.send(.string(entry.text))
                logger.info("Delivered held response for request \(entry.requestID, privacy: .public) after reconnect")
            } catch {
                logger.warning("Held response for request \(entry.requestID, privacy: .public) still unsendable: \(error.localizedDescription)")
                due[position...].forEach { heldResponses.hold($0) }
                return
            }
        }
    }
    #endif // os(macOS)

    // MARK: - Reconnection

    private func handleDisconnect(_ error: Error, socket: URLSessionWebSocketTask) {
        // A superseded receive loop can finish after a newer socket connects.
        // Ignore that stale callback instead of tearing down the live relay.
        guard webSocket === socket else { return }
        let replaced = Self.wasReplaced(closeCode: socket.closeCode, closeReason: socket.closeReason)
        isConnected = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        // Public: the persisted log said only "<private>" on 2026-09-29, and a
        // URLError's description carries no URL or token.
        logger.warning("WebSocket disconnected: \(error.localizedDescription, privacy: .public)")
        if replaced, let tunnelURL {
            // Reconnecting here is what made two instances knock each other
            // off once a second: each reconnect replaced the other's socket,
            // which reconnected in turn. The one that was replaced waits.
            stepAside(reason: "Another ForeverLM signed in to this Apple ID took over \(tunnelURL). This one reconnects when it stops.")
        } else {
            scheduleReconnect()
            onConnectionLost?(error.localizedDescription)
        }
    }

    /// The relay closes the socket it is replacing with this exact reason, so
    /// the closed side can tell a takeover from an outage.
    nonisolated static func wasReplaced(closeCode: URLSessionWebSocketTask.CloseCode, closeReason: Data?) -> Bool {
        guard closeCode == .normalClosure, let closeReason else { return false }
        return String(decoding: closeReason, as: UTF8.self).localizedCaseInsensitiveContains("replaced by new connection")
    }

    // MARK: - Liveness
    //
    // The relay keeps one socket per tunnel and closes the older one when a new
    // one connects — another Mac signed in to the same Apple ID, or a development
    // build running beside the installed app — and a socket the relay has let
    // go of can stay open on this side indefinitely: the receive loop never
    // fails, and a ping with no pong used to wait forever, so the app kept
    // reporting "running" while every request to its URL got the offline page.
    // The monitor therefore puts every ping on a deadline and, every other
    // tick, sends a request through the public tunnel URL that has to come back
    // through this very socket.

    private func startReconnectMonitor() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { break }
                guard await self.pingOrReconnect() else { break }
                tick += 1
                if tick.isMultiple(of: 2) {
                    guard await self.verifyTunnelOwnership() else { break }
                }
            }
        }
    }

    /// False once the socket has been torn down, so the monitor stops.
    private func pingOrReconnect() async -> Bool {
        guard let ws = webSocket else { return false }
        do {
            try await Self.ping(ws, within: pingTimeout)
            return true
        } catch {
            handleDisconnect(error, socket: ws)
            return false
        }
    }

    // MARK: - Ping deadline
    //
    // `URLSessionWebSocketTask.sendPing` ignores task cancellation, and on a
    // half-open socket (after a network or VPN route change) its pong handler
    // never runs. Both pings here used to race a sleeping child in a task group,
    // and that deadline could not fire: a group returns only once every child
    // has finished, and the ping child never did. On 2026-09-29 the installed
    // app's reconnect sat on one such ping from 14:05 until integrations were
    // switched off and on at 17:26, logging nothing after "WebSocket
    // disconnected" while its tunnel served the relay's offline page.
    //
    // So the pong, the deadline and cancellation of the waiting task each try to
    // resume one continuation, and the first one to get there wins. A deadline
    // that wins also cancels the socket, which makes URLSession call the pong
    // handler with an error and let go of it.

    /// Pings `socket` and waits at most `limit` for the pong. A socket that
    /// misses the deadline is cancelled.
    nonisolated private static func ping(_ socket: URLSessionWebSocketTask, within limit: Duration) async throws {
        try await awaitPong(
            within: limit,
            sendPing: { socket.sendPing(pongReceiveHandler: $0) },
            onDeadline: { socket.cancel(with: .goingAway, reason: nil) }
        )
    }

    /// Waits for the pong to one ping, and ends at `limit` whether or not the
    /// socket ever answers.
    ///
    /// `sendPing` hands the pong handler to the socket; a handler that runs
    /// again, or after the wait has ended, does nothing. `onDeadline` runs only
    /// when the deadline is what ended the wait. Cancelling the waiting task
    /// ends the wait with `CancellationError`.
    nonisolated static func awaitPong(
        within limit: Duration,
        sendPing: (@escaping @Sendable (Error?) -> Void) -> Void,
        onDeadline: @escaping @Sendable () -> Void
    ) async throws {
        let wait = PongWait()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard wait.begin(continuation) else { return }
                wait.arm(Task {
                    do { try await Task.sleep(for: limit) } catch { return }
                    if wait.end(URLError(.timedOut)) { onDeadline() }
                })
                sendPing { error in wait.end(error) }
            }
        } onCancel: {
            wait.end(CancellationError())
        }
    }

    /// The continuation one pong wait resumes, exactly once, by whichever of the
    /// pong, the deadline or cancellation reaches it first. A failing socket can
    /// call the pong handler more than once, and resuming a continuation twice
    /// is a runtime trap.
    private final class PongWait: Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<Void, Error>?
            var outcome: Result<Void, Error>?
            var deadline: Task<Void, Never>?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        /// Keeps `continuation` for whichever ending comes first. False when the
        /// wait already ended (cancellation can arrive before the continuation
        /// exists); the continuation has then been resumed with that ending.
        func begin(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
            let earlyOutcome = state.withLock { state -> Result<Void, Error>? in
                guard let outcome = state.outcome else {
                    state.continuation = continuation
                    return nil
                }
                return outcome
            }
            guard let earlyOutcome else { return true }
            continuation.resume(with: earlyOutcome)
            return false
        }

        /// Keeps the deadline timer so the wait can stop it when it ends first.
        func arm(_ deadline: Task<Void, Never>) {
            let ended = state.withLock { state -> Bool in
                guard state.outcome == nil else { return true }
                state.deadline = deadline
                return false
            }
            if ended { deadline.cancel() }
        }

        /// Ends the wait with `error`, or with success when it is nil. True only
        /// for the call that ended it.
        @discardableResult
        func end(_ error: Error?) -> Bool {
            let outcome: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
            let ending = state.withLock { state -> (CheckedContinuation<Void, Error>?, Task<Void, Never>?)? in
                guard state.outcome == nil else { return nil }
                state.outcome = outcome
                defer { state.continuation = nil; state.deadline = nil }
                return (state.continuation, state.deadline)
            }
            guard let (continuation, deadline) = ending else { return false }
            deadline?.cancel()
            continuation?.resume(with: outcome)
            return true
        }
    }

    enum TunnelProbeVerdict: Equatable, Sendable {
        /// The probe came back through this socket: the tunnel is ours.
        case held
        /// The relay answered from a live socket that is not this one.
        case heldByAnotherInstance
        /// The relay has no app connected, or could not forward: whatever this
        /// side still holds is dead.
        case unreachable
        /// The probe failed before it said anything about the tunnel.
        case inconclusive
    }

    /// What the relay's answer to a liveness probe means. `statusCode` is nil
    /// when no HTTP answer arrived at all.
    nonisolated static func probeVerdict(statusCode: Int?, sawNonce: Bool) -> TunnelProbeVerdict {
        guard let statusCode else { return .inconclusive }
        if sawNonce { return .held }
        switch statusCode {
        case 200..<300: return .heldByAnotherInstance
        case 502, 503, 504: return .unreachable
        default: return .inconclusive
        }
    }

    /// The nonce a forwarded request carries when it is one of our probes.
    nonisolated static func probeNonce(fromPath path: String) -> String? {
        guard let components = URLComponents(string: path), components.path == "/health" else { return nil }
        return components.queryItems?.first(where: { $0.name == "probe" })?.value
    }

    /// Sends one request through the public tunnel URL and checks that it
    /// arrived here. False once this client has stepped aside or torn its socket
    /// down, so the monitor stops.
    private func verifyTunnelOwnership() async -> Bool {
        guard let tunnelURL, let ws = webSocket else { return false }
        let verdict = await probeTunnel(tunnelURL, nonce: UUID().uuidString)
        guard webSocket === ws else { return false }
        switch verdict {
        case .held, .inconclusive:
            return true
        case .unreachable:
            logger.warning("Relay reports this tunnel offline while its socket looked alive; reconnecting")
            handleDisconnect(URLError(.networkConnectionLost), socket: ws)
            return false
        case .heldByAnotherInstance:
            stepAside(reason: "Another ForeverLM signed in to this Apple ID is serving \(tunnelURL). This one reconnects when it stops.")
            return false
        }
    }

    private func probeTunnel(_ tunnelURL: String, nonce: String) async -> TunnelProbeVerdict {
        guard let url = URL(string: "\(tunnelURL)/health?probe=\(nonce)") else { return .inconclusive }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        var statusCode: Int?
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            statusCode = (response as? HTTPURLResponse)?.statusCode
        } catch {
            statusCode = nil
        }
        // The relay forwards the request over the socket before it answers the
        // HTTP call, so by now handleMessage has recorded the nonce if it came here.
        let sawNonce = seenProbeNonces.remove(nonce) != nil
        return Self.probeVerdict(statusCode: statusCode, sawNonce: sawNonce)
    }

    /// Whether some other ForeverLM is live on this tunnel right now. Asked before
    /// a development build connects, so it does not take the installed app's
    /// address away from it.
    func isTunnelServedByAnotherInstance(tunnelURL: String) async -> Bool {
        guard webSocket == nil else { return false }
        return await probeTunnel(tunnelURL, nonce: UUID().uuidString) == .heldByAnotherInstance
    }

    /// Give the tunnel up to the instance that has it, and wait for it to leave.
    /// Reconnecting straight away would only take the tunnel back for thirty
    /// seconds and hand the other side the same discovery.
    private func stepAside(reason: String) {
        logger.notice("\(reason, privacy: .public)")
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        yieldedToAnotherInstance = true
        onConnectionYielded?(reason)
        yieldMonitorTask?.cancel()
        let interval = heartbeatInterval
        yieldMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { break }
                if await self.reconnectIfTunnelFreed() { break }
            }
        }
    }

    /// True once the other instance has gone and a reconnect has been scheduled.
    private func reconnectIfTunnelFreed() async -> Bool {
        guard yieldedToAnotherInstance, let tunnelURL else { return true }
        guard await probeTunnel(tunnelURL, nonce: UUID().uuidString) == .unreachable else { return false }
        logger.info("The other ForeverLM left the tunnel; reconnecting")
        yieldMonitorTask = nil
        yieldedToAnotherInstance = false
        scheduleReconnect()
        // The launcher stops saying another instance serves the tunnel, and a
        // reconnect that keeps failing can be reported as the outage it is.
        onConnectionLost?("The other ForeverLM left the tunnel")
        return true
    }

    /// Attempts after which a transient failure stops being reported as one.
    /// With 2s doubling to a 60s cap this is about two minutes of retrying —
    /// past any redeploy or blip, and short enough that a user watching the
    /// status is told what is wrong instead of watching "connecting" forever.
    private static let sustainedFailureAttempts = 6

    /// How long a live reconnect loop can go without moving. Its longest backoff
    /// is 60 s, and an attempt is bounded by the ping deadline on each candidate
    /// host, so three minutes leaves room for a Mac starved by a compiler build.
    private static let reconnectStallLimit: Duration = .seconds(180)

    /// Whether the relay is getting its tunnel back by itself right now, so a
    /// fresh connect would only interrupt it: a reconnect loop that is still
    /// making attempts, or a wait for another instance to leave the tunnel. A
    /// loop that has stopped moving does not count. One sat on a single ping for
    /// three hours on 2026-09-29.
    func isRecoveringOnItsOwn() -> Bool {
        if yieldedToAnotherInstance, yieldMonitorTask != nil { return true }
        guard reconnectTask != nil, let reconnectLoopMovedAt else { return false }
        return ContinuousClock.now - reconnectLoopMovedAt < Self.reconnectStallLimit
    }

    private func markReconnectLoopMoved() {
        reconnectLoopMovedAt = .now
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectLoopMovedAt = .now
        reconnectTask = Task { [weak self] in
            var delay: UInt64 = 2
            var attempt = 1
            var reportedSustainedFailure = false
            while !Task.isCancelled {
                guard !Task.isCancelled, let self else { break }
                self.logger.info("Reconnecting (attempt \(attempt))...")
                await self.markReconnectLoopMoved()
                if let reconnectedURL = await self.doConnect() {
                    self.logger.info("Reconnected successfully at \(reconnectedURL)")
                    await self.handleReconnect(reconnectedURL)
                    return
                }
                // connect() or disconnect() cancelled this loop during the
                // attempt, and has already cleared or replaced reconnectTask.
                guard !Task.isCancelled else { return }
                await self.markReconnectLoopMoved()

                if await self.connectionFailureKind() == .authenticationRejected {
                    self.logger.error("Relay rejected the saved tunnel credential")
                    await self.handlePermanentDisconnect(
                        reason: "Relay rejected the saved MCP credentials. Reconnecting will refresh them."
                    )
                    return
                }

                // Keep retrying either way — the connection may still come back —
                // but report the failure once so the status stops reading as
                // progress. A hostname that resolves nowhere fails exactly like a
                // brief outage here, and silently retrying it is what made the
                // rename's broken tunnel URLs undiagnosable.
                if attempt >= Self.sustainedFailureAttempts, !reportedSustainedFailure {
                    reportedSustainedFailure = true
                    let detail = await self.connectionErrorMessage()
                        ?? "The relay did not accept the WebSocket connection."
                    self.logger.error("Relay still unreachable after \(attempt) attempts: \(detail)")
                    await self.reportSustainedFailure(detail: detail)
                }

                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 60) // Exponential backoff, max 60s
                attempt += 1
            }
            await self?.clearReconnectTask()
        }
    }

    private func reportSustainedFailure(detail: String) {
        onSustainedFailure?(detail)
    }

    private func handleReconnect(_ connectedURL: String) {
        reconnectTask = nil
        yieldedToAnotherInstance = false
        onConnectionRestored?(connectedURL)
    }

    private func handlePermanentDisconnect(reason: String) {
        reconnectTask = nil
        onPermanentDisconnect?(reason)
    }

    private func clearReconnectTask() {
        reconnectTask = nil
    }

    nonisolated func relayURLCandidates(from tunnelURL: String) -> [String] {
        guard let url = URL(string: tunnelURL), let host = url.host else {
            return [tunnelURL]
        }

        var pendingHosts = [host]
        var seenHosts = Set<String>()
        var candidates: [String] = []
        while let candidateHost = pendingHosts.first {
            pendingHosts.removeFirst()
            guard seenHosts.insert(candidateHost).inserted else { continue }
            candidates.append(tunnelURL.replacingOccurrences(of: host, with: candidateHost))
            pendingHosts.append(contentsOf: [
                Self.currentBrandHost(for: candidateHost),
                Self.legacyHost(for: candidateHost),
                Self.modernHost(for: candidateHost),
            ].compactMap { $0 })
        }

        return candidates
    }

    /// The same tunnel subdomain on the brand domain this build serves.
    ///
    /// A tunnel URL cached before the product rename still names a retired brand
    /// domain, and that hostname's DNS and Worker route moved wholesale — it now
    /// resolves nowhere. Because that reads as a transport failure rather than a
    /// rejected credential, a client without this mapping retries the dead host
    /// forever and never reports anything but "connecting".
    nonisolated static func currentBrandHost(for host: String) -> String? {
        for retiredDomain in MCPBrandDomains.retired {
            let suffix = ".\(retiredDomain)"
            guard host.hasSuffix(suffix) else { continue }
            return String(host.dropLast(retiredDomain.count)) + MCPBrandDomains.current
        }
        return nil
    }

    nonisolated static func legacyHost(for host: String) -> String? {
        for brandDomain in MCPBrandDomains.all {
            let suffix = ".\(brandDomain)"
            guard host.hasSuffix(suffix), !host.hasSuffix(".mcp\(suffix)") else { continue }
            let prefix = String(host.dropLast(suffix.count))
            guard !prefix.isEmpty, !prefix.contains(".") else { continue }
            return "\(prefix).mcp.\(brandDomain)"
        }
        return nil
    }

    nonisolated static func modernHost(for host: String) -> String? {
        for brandDomain in MCPBrandDomains.all {
            let suffix = ".mcp.\(brandDomain)"
            guard host.hasSuffix(suffix) else { continue }
            let prefix = String(host.dropLast(suffix.count))
            guard !prefix.isEmpty, !prefix.contains(".") else { continue }
            return "\(prefix).\(brandDomain)"
        }
        return nil
    }
}

#endif
