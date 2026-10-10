import CryptoKit
import Foundation

#if os(macOS)

/// Verifies requests that arrived through the directory's universal MCP gateway.
///
/// The gateway has already completed OAuth with the owner. It proves that fact to
/// this Mac by signing the exact request with the per-install tunnel token. The
/// token never crosses the public MCP connection and stays in Keychain/D1, while
/// a timestamp and one-time nonce prevent a captured signed request from being
/// replayed against the app.
actor MCPGatewayAuthorizationVerifier {
    static let shared = MCPGatewayAuthorizationVerifier()

    private static let timestampHeader = "x-foreverlm-gateway-timestamp"
    private static let nonceHeader = "x-foreverlm-gateway-nonce"
    private static let signatureHeader = "x-foreverlm-gateway-signature"
    /// The AI app the gateway says made the call, percent-encoded. Outside the
    /// signature on purpose: it only names the app in the popup a long call
    /// shows (`MCPAccessContext.assistantName`), and the gateway never copies
    /// a client's own copy of it.
    private static let clientHeader = "x-foreverlm-gateway-client"
    private static let maximumClockSkew: TimeInterval = 90
    private static let maximumRememberedNonces = 512

    private var tunnelToken: String?
    private var consumedNonces: [String: Date] = [:]

    func configure(tunnelToken: String) {
        guard self.tunnelToken != tunnelToken else { return }
        self.tunnelToken = tunnelToken
        consumedNonces.removeAll(keepingCapacity: true)
    }

    func clear() {
        tunnelToken = nil
        consumedNonces.removeAll(keepingCapacity: false)
    }

    func validate(_ request: HTTPRequest, now: Date = Date()) -> MCPAccessContext? {
        guard let tunnelToken,
              let timestamp = request.headers[Self.timestampHeader],
              let timestampSeconds = TimeInterval(timestamp),
              abs(now.timeIntervalSince1970 - timestampSeconds) <= Self.maximumClockSkew,
              let nonce = request.headers[Self.nonceHeader],
              nonce.range(of: #"^[A-Za-z0-9_-]{20,64}$"#, options: .regularExpression) != nil,
              consumedNonces[nonce] == nil,
              let providedSignature = request.headers[Self.signatureHeader] else {
            return nil
        }

        let expectedSignature = Self.signature(
            tunnelToken: tunnelToken,
            method: request.method,
            path: request.path,
            timestamp: timestamp,
            nonce: nonce,
            body: request.body
        )
        guard constantTimeEquals(providedSignature, expectedSignature) else { return nil }

        consumedNonces[nonce] = now.addingTimeInterval(Self.maximumClockSkew)
        consumedNonces = consumedNonces.filter { $0.value > now }
        if consumedNonces.count > Self.maximumRememberedNonces {
            let overflow = consumedNonces.count - Self.maximumRememberedNonces
            for (key, _) in consumedNonces.sorted(by: { $0.value < $1.value }).prefix(overflow) {
                consumedNonces.removeValue(forKey: key)
            }
        }

        return MCPAccessContext(
            clientID: "chatgpt-directory",
            scope: .full,
            connectorLabel: "ChatGPT",
            assistantName: Self.assistantName(fromHeader: request.headers[Self.clientHeader])
        )
    }

    nonisolated static func assistantName(fromHeader value: String?) -> String? {
        guard let decoded = value?.removingPercentEncoding else { return nil }
        let name = MCPOAuthProvider.sanitizedPluginLabel(decoded)
        // The sanitizer's stand-in for an empty name is no name here.
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
    }

    nonisolated static func signature(
        tunnelToken: String,
        method: String,
        path: String,
        timestamp: String,
        nonce: String,
        body: Data
    ) -> String {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = ["v1", method.uppercased(), path, timestamp, nonce, bodyHash]
            .joined(separator: "\n")
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: SymmetricKey(data: Data(tunnelToken.utf8))
        )
        return Data(authentication).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#endif
