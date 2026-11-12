import Foundation
import Network
import os
import Testing
@testable import ForeverLM

#if os(macOS)

/// A tunnel URL cached before the product rename names a retired brand domain,
/// and that hostname's DNS record and Worker route moved to the current domain
/// together — it now resolves nowhere. Because a hostname that does not resolve
/// fails exactly like a brief relay outage, a client that cannot recognise the
/// retired domain retries it under bounded backoff forever and reports nothing
/// but "Connecting...". These cover the two places that recognise it.
@Suite("MCP relay brand hosts")
struct MCPRelayHostTests {
    private let relay = MCPRelayClient()

    @Test("A retired brand host maps to the same subdomain on the current domain")
    func retiredHostMigrates() {
        #expect(MCPRelayClient.currentBrandHost(for: "3c9a1e7b5d20.feynmanlm.com") == "3c9a1e7b5d20.foreverlm.com")
        #expect(MCPRelayClient.currentBrandHost(for: "3c9a1e7b5d20.mcp.feynmanlm.com") == "3c9a1e7b5d20.mcp.foreverlm.com")
    }

    @Test("A current brand host is already canonical")
    func currentHostIsUnchanged() {
        #expect(MCPRelayClient.currentBrandHost(for: "3c9a1e7b5d20.foreverlm.com") == nil)
    }

    @Test("Connecting to a retired URL tries the current brand host")
    func candidatesIncludeCurrentBrandHost() {
        let candidates = relay.relayURLCandidates(from: "https://3c9a1e7b5d20.feynmanlm.com")
        #expect(candidates.first == "https://3c9a1e7b5d20.feynmanlm.com")
        #expect(candidates.contains("https://3c9a1e7b5d20.foreverlm.com"))
    }

    @Test("Candidates are distinct so no attempt is spent twice")
    func candidatesAreDistinct() {
        let candidates = relay.relayURLCandidates(from: "https://3c9a1e7b5d20.foreverlm.com")
        #expect(candidates.count == Set(candidates).count)
        #expect(candidates.contains("https://3c9a1e7b5d20.foreverlm.com"))
    }

    @Test("A retired-domain URL is recognised as stale, not merely unreachable")
    func staleURLIsDetected() {
        #expect(MCPBrandDomains.isOnCurrentDomain("https://3c9a1e7b5d20.foreverlm.com"))
        #expect(MCPBrandDomains.isOnCurrentDomain("https://3c9a1e7b5d20.mcp.foreverlm.com"))
        #expect(!MCPBrandDomains.isOnCurrentDomain("https://3c9a1e7b5d20.feynmanlm.com"))
        #expect(!MCPBrandDomains.isOnCurrentDomain("not a url"))
    }
}

/// The relay keeps one socket per tunnel and closes the older one when a new one
/// connects, and a socket it has let go of can stay open on this side with no
/// error ever arriving. So the client periodically sends a request through its
/// own public URL and reads the relay's answer together with whether the
/// request came back through its socket. These pin down what each answer means.
@Suite("MCP relay tunnel probe")
struct MCPRelayTunnelProbeTests {
    @Test("A probe that came back through this socket means the tunnel is held")
    func heldWhenTheNonceCameBack() {
        #expect(MCPRelayClient.probeVerdict(statusCode: 200, sawNonce: true) == .held)
    }

    @Test("A success that never arrived here means another instance holds the tunnel")
    func anotherInstanceWhenTheNonceDidNot() {
        #expect(MCPRelayClient.probeVerdict(statusCode: 200, sawNonce: false) == .heldByAnotherInstance)
        #expect(MCPRelayClient.probeVerdict(statusCode: 204, sawNonce: false) == .heldByAnotherInstance)
    }

    @Test("The relay's offline answers mean this side's socket is dead")
    func unreachableOnOfflinePage() {
        for status in [502, 503, 504] {
            #expect(MCPRelayClient.probeVerdict(statusCode: status, sawNonce: false) == .unreachable)
        }
    }

    @Test("A probe that failed or met an unexpected status proves nothing")
    func inconclusiveOtherwise() {
        #expect(MCPRelayClient.probeVerdict(statusCode: nil, sawNonce: false) == .inconclusive)
        #expect(MCPRelayClient.probeVerdict(statusCode: 429, sawNonce: false) == .inconclusive)
        #expect(MCPRelayClient.probeVerdict(statusCode: 500, sawNonce: false) == .inconclusive)
    }

    @Test("The relay's replacement close is told apart from any other close")
    func replacementCloseIsRecognised() {
        let reason = Data("Replaced by new connection".utf8)
        #expect(MCPRelayClient.wasReplaced(closeCode: .normalClosure, closeReason: reason))
        #expect(!MCPRelayClient.wasReplaced(closeCode: .goingAway, closeReason: reason))
        #expect(!MCPRelayClient.wasReplaced(closeCode: .normalClosure, closeReason: Data("bye".utf8)))
        #expect(!MCPRelayClient.wasReplaced(closeCode: .normalClosure, closeReason: nil))
        #expect(!MCPRelayClient.wasReplaced(closeCode: .invalid, closeReason: nil))
    }

    @Test("Only a health request carries a probe nonce")
    func nonceOnlyOnHealth() {
        #expect(MCPRelayClient.probeNonce(fromPath: "/health?probe=abc-123") == "abc-123")
        #expect(MCPRelayClient.probeNonce(fromPath: "/health") == nil)
        #expect(MCPRelayClient.probeNonce(fromPath: "/health?other=1") == nil)
        #expect(MCPRelayClient.probeNonce(fromPath: "/mcp?probe=abc") == nil)
        #expect(MCPRelayClient.probeNonce(fromPath: "not a path ?? probe=abc") == nil)
    }
}

/// A development build provisions and holds a tunnel of its own. It used to
/// hash the same Apple user id as the installed app and so claim the same
/// tunnel row, taking the address over on every launch; the suffix here is
/// what the gateway appends too when it issues a grant for `/dev/mcp`.
@Suite("MCP tunnel identity")
struct MCPTunnelIdentityTests {
    @Test("The installed app hashes the Apple user id as is; a Dev build appends its suffix")
    func seeds() {
        #expect(MCPServerLauncher.identitySeed(appleUserID: "001234.abc", isDevelopment: false) == "001234.abc")
        #expect(MCPServerLauncher.identitySeed(appleUserID: "001234.abc", isDevelopment: true) == "001234.abc#dev")
        #expect(MCPServerLauncher.developmentIdentitySuffix == "#dev")
    }

    @Test("The hash is SHA-256 hex of the seed, so the two identities never collide")
    func hashes() {
        // sha256("abc") — a fixed vector, so a change of algorithm or encoding shows.
        #expect(MCPServerLauncher.identityHash(seed: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let installed = MCPServerLauncher.identityHash(seed: MCPServerLauncher.identitySeed(appleUserID: "001234.abc", isDevelopment: false))
        let development = MCPServerLauncher.identityHash(seed: MCPServerLauncher.identitySeed(appleUserID: "001234.abc", isDevelopment: true))
        #expect(installed != development)
        #expect(installed.count == 64 && development.count == 64)
    }
}

/// The provisioner authorizes the learner's own managed session, not a secret
/// shared by every copy of the app, and answers a refusal as JSON with a code.
@Suite("MCP tunnel provisioning request")
struct MCPTunnelProvisioningRequestTests {
    @Test("The bearer is the managed session and the body names only the identity")
    func request() throws {
        let identity = MCPServerLauncher.identityHash(seed: "001234.abc")
        let request = try #require(MCPServerLauncher.provisioningRequest(
            baseURL: "https://provision.foreverlm.com",
            userIDHash: identity,
            sessionToken: "v1.c2Vzc2lvbg.1790000000.mac"
        ))
        #expect(request.url?.absoluteString == "https://provision.foreverlm.com/provision")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer v1.c2Vzc2lvbg.1790000000.mac")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["user_id": identity])
    }

    @Test("Only the provisioner's own refusal stops the fallback address")
    func verdicts() {
        let refusal = Data(#"{"error":"ForeverLM did not accept this Mac's sign-in.","code":"invalid_session"}"#.utf8)
        #expect(MCPServerLauncher.isProvisioningVerdict(statusCode: 401, data: refusal))
        #expect(MCPServerLauncher.isProvisioningVerdict(statusCode: 403, data: Data(#"{"error":"x","code":"identity_mismatch"}"#.utf8)))
        #expect(MCPServerLauncher.isProvisioningVerdict(statusCode: 429, data: Data(#"{"error":"x","code":"rate_limited"}"#.utf8)))
        // Cloudflare's edge, not the provisioner: a later address may still answer.
        #expect(!MCPServerLauncher.isProvisioningVerdict(statusCode: 403, data: Data("<html>Access denied</html>".utf8)))
        // An outage is not a verdict, even in the provisioner's own words.
        #expect(!MCPServerLauncher.isProvisioningVerdict(statusCode: 503, data: Data(#"{"error":"x","code":"identity_unavailable"}"#.utf8)))
    }
}

/// `GET /mcp-url` on the loopback listener tells a plugin on this Mac which
/// personal URL the app serves now. On 2026-10-10 a new Apple identity meant a
/// new tunnel, and the old URL answered 503 "app not running" forever while the
/// Read AI plugin kept calling it. The route answers local programs only, and
/// says nothing but the URL.
@Suite("MCP loopback personal URL")
struct MCPLoopbackPersonalURLTests {
    private let port: UInt16 = 8522
    private let url = "https://be13a8b307673678.foreverlm.com"

    private func request(
        _ method: String = "GET",
        path: String = "/mcp-url",
        headers: [String: String] = ["host": "127.0.0.1:8522"]
    ) -> HTTPRequest {
        HTTPRequest(method: method, path: path, queryString: "", headers: headers, body: Data())
    }

    private func body(_ response: HTTPResponse) throws -> [String: String] {
        try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: String])
    }

    @Test("A local program gets the URL and nothing else")
    func localProgramGetsOnlyTheURL() throws {
        let response = MCPServerLauncher.personalURLResponse(to: request(), tunnelURL: url, port: port)
        #expect(response.status == 200)
        #expect(try body(response) == ["url": url])
    }

    @Test("Every loopback spelling of the address is local, and so is the learner typing it")
    func loopbackSpellingsAreLocal() {
        for headers in [
            ["host": "localhost:8522"],
            ["host": "127.0.0.1"],
            ["host": "LOCALHOST:8522"],
            ["host": "127.0.0.1:8522", "sec-fetch-site": "none"],
        ] {
            let response = MCPServerLauncher.personalURLResponse(to: request(headers: headers), tunnelURL: url, port: port)
            #expect(response.status == 200, "\(headers)")
        }
    }

    @Test("A web page cannot read it")
    func browserRequestsAreRefused() {
        for headers in [
            ["host": "127.0.0.1:8522", "origin": "https://example.com"],
            ["host": "127.0.0.1:8522", "sec-fetch-site": "cross-site"],
            ["host": "127.0.0.1:8522", "sec-fetch-site": "same-origin"],
            // DNS rebinding: the page's own hostname, resolved to 127.0.0.1.
            ["host": "example.com:8522"],
            ["host": "127.0.0.1:8523"],
            [:],
        ] {
            let response = MCPServerLauncher.personalURLResponse(to: request(headers: headers), tunnelURL: url, port: port)
            #expect(response.status == 403, "\(headers)")
            #expect(!String(decoding: response.body, as: UTF8.self).contains("foreverlm.com"))
        }
    }

    @Test("With no tunnel it says so rather than naming a URL")
    func noTunnelIsUnavailable() throws {
        for tunnelURL in [nil, ""] as [String?] {
            let response = MCPServerLauncher.personalURLResponse(to: request(), tunnelURL: tunnelURL, port: port)
            #expect(response.status == 503)
            #expect(try body(response) == ["error": "not_connected"])
        }
    }

    @Test("Only GET on the exact path answers")
    func onlyGetOnTheExactPath() {
        #expect(MCPServerLauncher.personalURLResponse(to: request("POST"), tunnelURL: url, port: port).status == 405)
        #expect(MCPServerLauncher.personalURLResponse(to: request(path: "/mcp-url/token"), tunnelURL: url, port: port).status == 404)
        #expect(MCPServerLauncher.personalURLPath == "/mcp-url")
    }
}

/// Nothing in the app listens on the network: the way in from outside is the
/// relay's outbound tunnel, and every local listener binds 127.0.0.1
/// (product owner, 2026-11-11: "make sure this is the case for our app", of
/// a closed-ports server rule). The Google, YouTube and OpenRouter sign-in
/// callbacks set only `acceptLocalOnly`, which reads like loopback and is not:
/// they bound every interface and answered on the Wi-Fi address.
@Suite("Local listeners bind loopback")
struct LoopbackListenerTests {
    @Test("The loopback parameters bind 127.0.0.1 and nothing wider")
    func loopbackParametersBindLoopback() {
        #expect(NWParameters.loopbackTCP().requiredLocalEndpoint == .hostPort(host: .ipv4(.loopback), port: .any))
        #expect(NWParameters.loopbackTCP(port: 8522).requiredLocalEndpoint == .hostPort(host: .ipv4(.loopback), port: 8522))
    }

    @Test("Every listener in the app is built on them")
    func everyListenerIsLoopback() throws {
        var listeners: [String] = []
        var unbound: [String] = []
        for directory in ["App", "Shared", "MCP", "iOS"] {
            let base = PreferenceRegistryTests.appDirectory.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                let lines = try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() where line.contains("NWListener(using:") {
                    let place = "\(file.lastPathComponent):\(index + 1)"
                    listeners.append(place)
                    if !line.contains(".loopbackTCP(") { unbound.append(place) }
                }
            }
        }
        #expect(listeners.count >= 3, "found \(listeners)")
        #expect(unbound.isEmpty, "Listeners not bound to loopback: \(unbound)")
    }
}

/// The tool has run by the time its answer cannot be sent, so the answer is held
/// for the reconnect rather than dropped — a write that landed on 2026-09-19 left
/// its caller timing out for want of this. The relay keeps the request pending for
/// its 60 s budget after the socket closes, and these pin the queue to that window.
@Suite("MCP relay held responses")
struct MCPRelayHeldResponseTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("A response held while the socket was down is delivered on the reconnect")
    func heldThenDrained() {
        var held = MCPRelayHeldResponses()
        held.hold(requestID: "req_1", text: "{\"id\":\"req_1\"}", now: t0)
        held.hold(requestID: "req_2", text: "{\"id\":\"req_2\"}", now: t0.addingTimeInterval(1))
        let due = held.drain(now: t0.addingTimeInterval(5))
        #expect(due.map(\.requestID) == ["req_1", "req_2"])
        #expect(held.isEmpty)
    }

    @Test("The window is the relay's request budget: an older answer has already been answered for")
    func retentionMatchesRelayBudget() {
        #expect(MCPRelayHeldResponses.retention == 60)
        var held = MCPRelayHeldResponses()
        held.hold(requestID: "stale", text: "{}", now: t0)
        held.hold(requestID: "fresh", text: "{}", now: t0.addingTimeInterval(30))
        let due = held.drain(now: t0.addingTimeInterval(61))
        #expect(due.map(\.requestID) == ["fresh"])
        #expect(held.isEmpty)
    }

    @Test("Holding a new answer evicts the ones the relay has already given up on")
    func holdEvictsExpired() {
        var held = MCPRelayHeldResponses()
        held.hold(requestID: "stale", text: "{}", now: t0)
        held.hold(requestID: "fresh", text: "{}", now: t0.addingTimeInterval(61))
        #expect(held.entries.map(\.requestID) == ["fresh"])
    }

    @Test("The queue is bounded, oldest out first")
    func capacityDropsOldest() {
        var held = MCPRelayHeldResponses()
        for index in 0..<(MCPRelayHeldResponses.capacity + 3) {
            held.hold(requestID: "req_\(index)", text: "{}", now: t0.addingTimeInterval(Double(index) * 0.1))
        }
        #expect(held.entries.count == MCPRelayHeldResponses.capacity)
        #expect(held.entries.first?.requestID == "req_3")
        #expect(held.entries.last?.requestID == "req_\(MCPRelayHeldResponses.capacity + 2)")
    }

    @Test("A send that fails again puts the entry back with its original age")
    func reholdKeepsAge() {
        var held = MCPRelayHeldResponses()
        held.hold(requestID: "req_1", text: "{}", now: t0)
        let due = held.drain(now: t0.addingTimeInterval(10))
        due.forEach { held.hold($0) }
        #expect(held.entries.first?.heldAt == t0)
        // Its age still bounds it: by the next reconnect the relay has answered.
        #expect(held.drain(now: t0.addingTimeInterval(70)).isEmpty)
    }
}

// MARK: - Ping deadline

/// `URLSessionWebSocketTask.sendPing` ignores task cancellation, and a socket
/// that stays open after a network or VPN route change never calls its pong
/// handler. Both of the relay's pings raced a timeout in a task group, and a
/// group cannot return before its ping child does, so the 10 s deadline waited
/// forever: on 2026-09-29 the installed app's reconnect sat on one ping for
/// over three hours while its tunnel served the offline page. These pin that
/// the deadline ends the wait whatever the socket does. Each waits through
/// `ending(within:)`, so on the old code a test fails instead of hanging.
@Suite("MCP relay ping deadline")
struct MCPRelayPingDeadlineTests {
    @Test("A pong that never comes ends the wait at the deadline, and the socket is cancelled")
    func pongThatNeverComes() async {
        let deadlines = Counter()
        let outcome = await ending(within: .seconds(5)) {
            // A half-open socket: the pong handler is taken and never called.
            try await MCPRelayClient.awaitPong(
                within: .milliseconds(100),
                sendPing: { _ in },
                onDeadline: { deadlines.increment() }
            )
        }
        #expect(outcome.urlErrorCode == .timedOut)
        #expect(deadlines.value == 1)
    }

    @Test("A pong ends the wait, and the deadline does nothing afterwards")
    func pongArrives() async throws {
        let deadlines = Counter()
        let outcome = await ending(within: .seconds(5)) {
            try await MCPRelayClient.awaitPong(
                within: .milliseconds(100),
                sendPing: { pong in DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { pong(nil) } },
                onDeadline: { deadlines.increment() }
            )
        }
        #expect(outcome.returned)
        try await Task.sleep(for: .milliseconds(300))
        #expect(deadlines.value == 0)
    }

    @Test("A ping the socket fails reports that failure, not a timeout")
    func pingFails() async {
        let deadlines = Counter()
        let outcome = await ending(within: .seconds(5)) {
            try await MCPRelayClient.awaitPong(
                within: .seconds(60),
                sendPing: { pong in DispatchQueue.global().async { pong(URLError(.networkConnectionLost)) } },
                onDeadline: { deadlines.increment() }
            )
        }
        #expect(outcome.urlErrorCode == .networkConnectionLost)
        #expect(deadlines.value == 0)
    }

    @Test("A pong handler called on cancel, late, or twice resumes nothing a second time")
    func lateAndRepeatedPongs() async {
        let handler = HeldPongHandler()
        let outcome = await ending(within: .seconds(5)) {
            try await MCPRelayClient.awaitPong(
                within: .milliseconds(100),
                sendPing: { handler.keep($0) },
                // What URLSession does when the deadline cancels the socket:
                // the handler finally runs, with NSURLErrorCancelled.
                onDeadline: { handler.call(URLError(.cancelled)) }
            )
        }
        #expect(outcome.urlErrorCode == .timedOut)
        // A second resume of the continuation would trap and take the run down.
        handler.call(nil)
        handler.call(URLError(.networkConnectionLost))
    }

    @Test("Cancelling the waiting task ends the wait, and the deadline stays quiet")
    func cancellationEndsTheWait() async throws {
        let deadlines = Counter()
        let wait = Task {
            try await MCPRelayClient.awaitPong(
                within: .seconds(60),
                sendPing: { _ in },
                onDeadline: { deadlines.increment() }
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        wait.cancel()
        let outcome = await ending(within: .seconds(5)) { try await wait.value }
        #expect(outcome.threwCancellation)
        #expect(deadlines.value == 0)
    }

    @Test("A task cancelled before it pings ends at once and sends no ping")
    func cancelledBeforeThePing() async {
        let pings = Counter()
        let outcome = await ending(within: .seconds(5)) {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MCPRelayClient.awaitPong(
                within: .seconds(60),
                sendPing: { _ in pings.increment() },
                onDeadline: {}
            )
        }
        #expect(outcome.threwCancellation)
        #expect(pings.value == 0)
    }
}

/// The same deadline through a real `URLSessionWebSocketTask`, against a
/// loopback WebSocket server that completes the handshake and then leaves pings
/// unanswered. URLSession's own 60 s request timeout covers only the handshake,
/// so without the relay's deadline nothing ever ends these waits.
@Suite("MCP relay against a socket that stops answering")
struct MCPRelayQuietSocketTests {
    @Test("Connecting gives up on a relay that accepts the socket but never answers the ping")
    func connectGivesUp() async throws {
        let server = try QuietWebSocketServer(answeringPings: false)
        let port = try await server.start()
        defer { server.stop() }
        let relay = MCPRelayClient(pingTimeout: .milliseconds(300))
        let connectedURL = OSAllocatedUnfairLock<String?>(initialState: nil)

        let outcome = await ending(within: .seconds(10)) {
            let url = await relay.connect(tunnelURL: "ws://127.0.0.1:\(port)", tunnelToken: "test")
            connectedURL.withLock { $0 = url }
        }

        #expect(outcome.returned)
        #expect(connectedURL.withLock { $0 } == nil)
        #expect(server.handshakes >= 1)
        #expect(await relay.connectionErrorMessage() != nil)
        // A missing pong says nothing about the credential.
        #expect(await relay.connectionFailureKind() == .transient)
        await relay.disconnect()
    }

    @Test("The heartbeat reports a socket that stops answering, and the relay gets the tunnel back")
    func heartbeatReportsTheLoss() async throws {
        let server = try QuietWebSocketServer(answeringPings: true)
        let port = try await server.start()
        defer { server.stop() }
        let relay = MCPRelayClient(heartbeatInterval: .milliseconds(200), pingTimeout: .milliseconds(300))
        let lost = Recorder()
        let restored = Recorder()
        await relay.setOnConnectionLost { lost.record($0) }
        await relay.setOnConnectionRestored { restored.record($0) }
        let tunnelURL = "ws://127.0.0.1:\(port)"
        #expect(await relay.connect(tunnelURL: tunnelURL, tunnelToken: "test") == tunnelURL)

        server.setAnswersPings(false)
        #expect(await eventually(within: .seconds(10)) { lost.values.count == 1 })
        #expect(await relay.isConnected == false)
        // The launcher leaves a loop that is really reconnecting alone.
        #expect(await relay.isRecoveringOnItsOwn())

        server.setAnswersPings(true)
        #expect(await eventually(within: .seconds(15)) { restored.values == [tunnelURL] })
        #expect(await relay.isConnected)
        #expect(await relay.isRecoveringOnItsOwn() == false)
        #expect(lost.values.count == 1)
        await relay.disconnect()
    }

    /// What pressing Connect does while the reconnect waits on a pong. Now that
    /// the deadline ends that wait, the superseded attempt comes back after the
    /// new connection has its socket, and it must not clear it: the relay would
    /// stay "connected" with no heartbeat and hold every answer it owed.
    @Test("A connect that replaces a reconnect still waiting on its pong keeps its own socket")
    func connectReplacingAPendingReconnect() async throws {
        let stale = try QuietWebSocketServer(answeringPings: true)
        let stalePort = try await stale.start()
        defer { stale.stop() }
        let fresh = try QuietWebSocketServer(answeringPings: true)
        let freshPort = try await fresh.start()
        defer { fresh.stop() }
        let relay = MCPRelayClient(heartbeatInterval: .milliseconds(200), pingTimeout: .seconds(1))
        let lost = Recorder()
        await relay.setOnConnectionLost { lost.record($0) }
        let staleURL = "ws://127.0.0.1:\(stalePort)"
        #expect(await relay.connect(tunnelURL: staleURL, tunnelToken: "test") == staleURL)

        // The socket goes quiet; the heartbeat reports it, and the reconnect's
        // first attempt completes its handshake and waits on a pong.
        stale.setAnswersPings(false)
        #expect(await eventually(within: .seconds(10)) { lost.values.count == 1 && stale.handshakes == 2 })

        let freshURL = "ws://127.0.0.1:\(freshPort)"
        #expect(await relay.connect(tunnelURL: freshURL, tunnelToken: "test") == freshURL)
        let pingsAtConnect = fresh.pings

        // The heartbeat pings the new socket, so the relay still holds it. (Two
        // ticks: the second also sends an ownership probe, which this server
        // never answers, and the monitor waits on it.)
        #expect(await eventually(within: .seconds(5)) { fresh.pings >= pingsAtConnect + 2 })
        #expect(await relay.isConnected)
        #expect(lost.values.count == 1)
        await relay.disconnect()
    }
}

// MARK: - Ping deadline test support

/// How a wait ended, or `.stillWaiting` if it had not by the time the test gave up.
private enum WaitOutcome: Sendable {
    case returned
    case threw(Error)
    case stillWaiting

    var returned: Bool {
        if case .returned = self { return true }
        return false
    }

    var urlErrorCode: URLError.Code? {
        guard case .threw(let error) = self else { return nil }
        return (error as? URLError)?.code
    }

    var threwCancellation: Bool {
        guard case .threw(let error) = self else { return false }
        return error is CancellationError
    }
}

/// Runs `operation` on a task of its own and reports how it ended, giving up
/// after `limit`. Deliberately not a task group or `async let`: either would
/// wait on the very hang these tests exist to catch, and hang the run with it.
private func ending(
    within limit: Duration,
    _ operation: @escaping @Sendable () async throws -> Void
) async -> WaitOutcome {
    let outcome = OSAllocatedUnfairLock<WaitOutcome?>(initialState: nil)
    let task = Task {
        do {
            try await operation()
            outcome.withLock { $0 = .returned }
        } catch {
            outcome.withLock { $0 = .threw(error) }
        }
    }
    let giveUp = ContinuousClock.now + limit
    while ContinuousClock.now < giveUp {
        if let ended = outcome.withLock({ $0 }) { return ended }
        try? await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    return .stillWaiting
}

/// Polls `condition` until it holds or `limit` passes.
private func eventually(within limit: Duration, _ condition: @Sendable () -> Bool) async -> Bool {
    let giveUp = ContinuousClock.now + limit
    while ContinuousClock.now < giveUp {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private final class Counter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

private final class Recorder: Sendable {
    private let recorded = OSAllocatedUnfairLock<[String]>(initialState: [])
    func record(_ value: String) { recorded.withLock { $0.append(value) } }
    var values: [String] { recorded.withLock { $0 } }
}

/// Keeps the pong handler a ping was given, so a test can call it when a real
/// socket would: late, on cancel, or more than once.
private final class HeldPongHandler: Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable (Error?) -> Void)?>(initialState: nil)
    func keep(_ pong: @escaping @Sendable (Error?) -> Void) { handler.withLock { $0 = pong } }
    func call(_ error: Error?) { handler.withLock { $0 }?(error) }
}

/// A WebSocket server on the loopback interface that completes every handshake
/// and answers pings only while told to: a socket that stays open and goes
/// quiet, as the relay's did after the route change. Loopback only, so the
/// application firewall never asks about it.
private final class QuietWebSocketServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "QuietWebSocketServer")
    private let listener: NWListener
    private let answersPings: OSAllocatedUnfairLock<Bool>
    private let handshakeCount = OSAllocatedUnfairLock(initialState: 0)
    private let pingCount = OSAllocatedUnfairLock(initialState: 0)
    /// Confined to `queue`.
    private var connections: [NWConnection] = []

    init(answeringPings: Bool) throws {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = false
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        answersPings = OSAllocatedUnfairLock(initialState: answeringPings)
    }

    /// Completed WebSocket handshakes so far.
    var handshakes: Int { handshakeCount.withLock { $0 } }

    /// Pings received so far, answered or not.
    var pings: Int { pingCount.withLock { $0 } }

    func setAnswersPings(_ answers: Bool) {
        answersPings.withLock { $0 = answers }
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable (Result<UInt16, Error>) -> Void = { result in
                let first = resumed.withLock { didResume in
                    defer { didResume = true }
                    return !didResume
                }
                if first { continuation.resume(with: result) }
            }
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        resumeOnce(.success(port))
                    } else {
                        resumeOnce(.failure(URLError(.cannotConnectToHost)))
                    }
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.async {
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [handshakeCount] state in
            if case .ready = state { handshakeCount.withLock { $0 += 1 } }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .ping {
                self.pingCount.withLock { $0 += 1 }
            }
            if metadata?.opcode == .ping, self.answersPings.withLock({ $0 }) {
                let pong = NWConnection.ContentContext(
                    identifier: "pong",
                    metadata: [NWProtocolWebSocket.Metadata(opcode: .pong)]
                )
                connection.send(content: content, contentContext: pong, isComplete: true, completion: .idempotent)
            }
            self.receive(on: connection)
        }
    }
}

#endif
