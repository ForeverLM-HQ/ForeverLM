import Foundation
import Network
import OSLog

#if os(macOS)

// MARK: - HTTP Types

struct HTTPRequest {
    let method: String
    let path: String
    let queryString: String
    let headers: [String: String]
    let body: Data

    var queryParams: [String: String] {
        guard !queryString.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = decodeFormURLComponent(String(parts[0]))
                let val = decodeFormURLComponent(String(parts[1]))
                result[key] = val
            }
        }
        return result
    }

    var bodyJSON: [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

/// Decode an `application/x-www-form-urlencoded` component. OAuth clients such
/// as ChatGPT encode spaces in multi-value scope parameters as `+`; Foundation's
/// `removingPercentEncoding` deliberately leaves those plus signs untouched.
/// Replace raw plus signs before percent-decoding so `%2B` remains a literal `+`.
func decodeFormURLComponent(_ rawValue: String) -> String {
    let plusDecoded = rawValue.replacingOccurrences(of: "+", with: " ")
    return plusDecoded.removingPercentEncoding ?? plusDecoded
}

struct HTTPResponse {
    let status: Int
    let statusText: String
    var headers: [String: String]
    let body: Data

    static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        // .fragmentsAllowed: a scalar top-level value would otherwise make
        // JSONSerialization throw an ObjC exception that `try?` cannot catch.
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        return HTTPResponse(
            status: status,
            statusText: statusText(for: status),
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            statusText: statusText(for: status),
            headers: ["Content-Type": "text/plain"],
            body: Data(text.utf8)
        )
    }

    static func redirect(_ url: String) -> HTTPResponse {
        HTTPResponse(
            status: 302,
            statusText: "Found",
            headers: ["Location": url],
            body: Data()
        )
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}

// MARK: - Route Handler

typealias RouteHandler = @Sendable (HTTPRequest) async -> HTTPResponse

// MARK: - Loopback listening

extension NWParameters {
    /// TCP for a listener only programs on this Mac can reach. It binds
    /// 127.0.0.1, so it opens no port on Wi-Fi or any other network, and the
    /// one way in from outside stays the relay's outbound tunnel. Every
    /// `NWListener` in the app is built on it (`LoopbackListenerTests`).
    ///
    /// `acceptLocalOnly` alone is not this: it admits every peer on the local
    /// link and leaves the port open on all interfaces, which is how the
    /// sign-in callback listeners answered on the Wi-Fi address until
    /// 2026-11-11. `.any` takes a free port, which the listener reports once
    /// it is ready.
    static func loopbackTCP(port: NWEndpoint.Port = .any) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        return parameters
    }
}

// MARK: - HTTP Server

final class MCPHTTPServer: @unchecked Sendable {
    /// Loopback port for personal-URL discovery
    /// (`MCPServerLauncher.startLoopbackListener`): local plugins ask it for
    /// `/mcp-url`.
    static let loopbackPort = ForeverLMRuntimeIdentity.mcpLoopbackPort

    private var listener: NWListener?
    private var routes: [(method: String, pathPrefix: String, handler: RouteHandler)] = []
    private let logger = Logger(subsystem: "ForeverLM", category: "MCPHTTPServer")
    private let queue = DispatchQueue(
        label: "\(ForeverLMRuntimeIdentity.keychainService).mcp-http",
        attributes: .concurrent
    )

    /// Hard ceilings so a malicious/broken client can't exhaust memory by never
    /// terminating the header block or by declaring an enormous Content-Length.
    private let maxHeaderBytes = 64 * 1024
    private let maxBodyBytes = 8 * 1024 * 1024 // 8 MB

    /// Register a route. Use "*" for method to match any method.
    func route(_ method: String, _ pathPrefix: String, handler: @escaping RouteHandler) {
        routes.append((method: method, pathPrefix: pathPrefix, handler: handler))
    }

    func start(port: UInt16 = ForeverLMRuntimeIdentity.mcpLoopbackPort) throws {
        let l = try NWListener(using: .loopbackTCP(port: NWEndpoint.Port(rawValue: port)!))
        l.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("HTTP server listening on 127.0.0.1:\(port)")
            case .failed(let error):
                self?.logger.error("Listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            if let error {
                self.logger.debug("Connection receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            guard let data, !data.isEmpty else {
                if isComplete { connection.cancel() }
                return
            }

            let accumulated = buffer + data
            let bytes = [UInt8](accumulated)

            // Look for end of headers (\r\n\r\n)
            guard let headerEndIndex = self.findHeaderEnd(bytes) else {
                // Cap unterminated header accumulation so a client that never sends
                // \r\n\r\n can't grow the buffer without bound.
                if accumulated.count > self.maxHeaderBytes {
                    self.send(connection, .text("Request Header Fields Too Large", status: 431))
                    connection.cancel()
                    return
                }
                // Need more data for headers
                self.receiveRequest(connection, buffer: accumulated)
                return
            }

            if headerEndIndex > self.maxHeaderBytes {
                self.send(connection, .text("Request Header Fields Too Large", status: 431))
                connection.cancel()
                return
            }

            let headerData = accumulated[..<headerEndIndex]
            let bodyStart = headerEndIndex + 4 // skip \r\n\r\n

            guard let headerStr = String(data: headerData, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let contentLength = self.parseContentLength(headerStr)
            if contentLength < 0 {
                self.send(connection, .text("Bad Request", status: 400))
                connection.cancel()
                return
            }
            // Reject an oversized declared body before buffering it (memory-exhaustion DoS).
            if contentLength > self.maxBodyBytes {
                self.send(connection, .text("Payload Too Large", status: 413))
                connection.cancel()
                return
            }
            let bodyAvailable = accumulated.count - bodyStart

            if bodyAvailable < contentLength {
                // Need more body data
                self.receiveRequest(connection, buffer: accumulated)
                return
            }

            // Full request received
            let bodyData = accumulated[bodyStart..<(bodyStart + contentLength)]

            guard let request = self.parseRequest(headerStr, body: Data(bodyData)) else {
                self.send(connection, .text("Bad Request", status: 400))
                return
            }

            // A client is waiting on every request, so it outranks the app's
            // maintenance on the storage actor's priority-ordered queue.
            Task(priority: .userInitiated) {
                let response = await self.dispatch(request)
                self.send(connection, response)
                // Support keep-alive: receive next request
                let remaining = accumulated[(bodyStart + contentLength)...]
                self.receiveRequest(connection, buffer: Data(remaining))
            }
        }
    }

    private func findHeaderEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == 0x0D && bytes[i+1] == 0x0A && bytes[i+2] == 0x0D && bytes[i+3] == 0x0A {
                return i
            }
        }
        return nil
    }

    private func parseContentLength(_ headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                // A present-but-unparseable Content-Length is a protocol error, not "0".
                return Int(value) ?? -1
            }
        }
        return 0
    }

    private func parseRequest(_ headerStr: String, body: Data) -> HTTPRequest? {
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let fullPath = String(parts[1])

        let (path, query): (String, String)
        if let qIndex = fullPath.firstIndex(of: "?") {
            path = String(fullPath[..<qIndex])
            query = String(fullPath[fullPath.index(after: qIndex)...])
        } else {
            path = fullPath
            query = ""
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return HTTPRequest(method: method, path: path, queryString: query, headers: headers, body: body)
    }

    private func dispatch(_ request: HTTPRequest) async -> HTTPResponse {
        // Find matching route (first match wins)
        for route in routes {
            if (route.method == "*" || route.method == request.method) &&
               request.path.hasPrefix(route.pathPrefix) {
                return await route.handler(request)
            }
        }
        return .json(["error": "Not found"], status: 404)
    }

    private func send(_ connection: NWConnection, _ response: HTTPResponse) {
        var header = "HTTP/1.1 \(response.status) \(response.statusText)\r\n"
        var allHeaders = response.headers
        allHeaders["Content-Length"] = "\(response.body.count)"
        allHeaders["Connection"] = "keep-alive"
        if allHeaders["Access-Control-Allow-Origin"] == nil {
            allHeaders["Access-Control-Allow-Origin"] = "*"
        }
        for (key, value) in allHeaders {
            // Strip control characters (CR/LF included) from both name and value so a
            // tainted header value can't inject extra headers or split the response.
            header += "\(sanitizedHeaderField(key)): \(sanitizedHeaderField(value))\r\n"
        }
        header += "\r\n"

        let responseData = Data(header.utf8) + response.body
        connection.send(content: responseData, completion: .contentProcessed { _ in })
    }

    /// Remove control characters (including CR and LF) from an outgoing header
    /// field name or value to prevent response-splitting / header-injection.
    private func sanitizedHeaderField(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        })
    }
}

// MARK: - Shared MCP Authorization

/// Constant-time string comparison so bearer-token checks don't leak length or
/// content via timing. Returns false immediately on length mismatch (length is
/// not itself secret for these fixed-format tokens).
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let lhs = Array(a.utf8)
    let rhs = Array(b.utf8)
    guard lhs.count == rhs.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<lhs.count {
        diff |= lhs[i] ^ rhs[i]
    }
    return diff == 0
}

/// The outcome of authorizing a `POST /mcp` request: the validated token's
/// access context (client identity + granted scope), or the 401 to send back.
enum MCPAuthorization {
    case authorized(MCPAccessContext)
    case unauthorized(HTTPResponse)
}

/// Authorize a `POST /mcp` request. Used by the hosted relay client so the
/// bearer-auth policy lives in exactly one place. On success the returned
/// context carries the granted scope; the protocol handler filters tool
/// visibility and dispatch with it, so every request re-derives its authority
/// from the token rather than from any session state.
///
/// Only per-install OAuth access tokens (minted through the owner-consent pairing
/// flow) are accepted. The build-time provisioning secret must never authorize
/// `/mcp`: it is identical in every distributed binary, so accepting it here would
/// let anyone who extracts it from one app copy read any user's knowledge base
/// through their hosted MCP URL.
///
/// No entitlement check happens here; the gate is the app lock (product owner,
/// 2026-10-10: the free days over and nothing paid). The hosted gateway
/// refuses `tools/call` for a locked account on the account server's word. A
/// call on this Mac's own bearer never passes the gateway, so it is marked
/// `arrivedWithoutGateway` and `MCPProtocolHandler.appLockRefusal` refuses it
/// the same way. While locked the tunnel itself does not run either
/// (`MCPServerLauncher.startHostedTunnel`).
func authorizeMCPRequest(_ request: HTTPRequest) async -> MCPAuthorization {
    // The public ChatGPT directory uses one universal OAuth endpoint. Its
    // gateway signs the exact request with this installation's tunnel token;
    // verify that proof before considering the per-install bearer-token path.
    if let access = await MCPGatewayAuthorizationVerifier.shared.validate(request) {
        return .authorized(access)
    }

    guard let auth = request.headers["authorization"],
          auth.lowercased().hasPrefix("bearer ") else {
        return .unauthorized(.json(["error": "Unauthorized"], status: 401))
    }
    let token = String(auth.dropFirst(7))

    let oauthProvider = await MCPOAuthProvider.sharedProvider()
    if var access = await oauthProvider.validateAccessToken(token) {
        access.arrivedWithoutGateway = true
        return .authorized(access)
    }

    return .unauthorized(.json(["error": "Unauthorized"], status: 401))
}

#endif
