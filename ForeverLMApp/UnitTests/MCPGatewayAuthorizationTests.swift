import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

@Suite("MCP universal gateway authorization")
struct MCPGatewayAuthorizationTests {
    private let token = "tunnel-test-secret"
    private let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)

    @Test("A valid signed request receives ChatGPT full access")
    func validSignature() async {
        let verifier = MCPGatewayAuthorizationVerifier()
        await verifier.configure(tunnelToken: token)
        let now = Date(timeIntervalSince1970: 1_776_182_400)
        let timestamp = String(Int(now.timeIntervalSince1970))
        let nonce = "abcdefghijklmnopqrstuv"
        let request = signedRequest(timestamp: timestamp, nonce: nonce)

        let access = await verifier.validate(request, now: now)
        #expect(access == MCPAccessContext(clientID: "chatgpt-directory", scope: .full, connectorLabel: "ChatGPT"))
    }

    @Test("Signature matches the gateway test vector")
    func signatureTestVector() {
        #expect(MCPGatewayAuthorizationVerifier.signature(
            tunnelToken: token,
            method: "POST",
            path: "/mcp",
            timestamp: "1776182400",
            nonce: "abcdefghijklmnopqrstuv",
            body: body
        ) == "TDuaMJxEakFAk-oFQSoB_3L7nu-_Kvq4o4ye7tDRwso")
    }

    @Test("A signed request cannot be replayed")
    func replayIsRejected() async {
        let verifier = MCPGatewayAuthorizationVerifier()
        await verifier.configure(tunnelToken: token)
        let now = Date(timeIntervalSince1970: 1_776_182_400)
        let request = signedRequest(timestamp: String(Int(now.timeIntervalSince1970)), nonce: "abcdefghijklmnopqrstuv")

        #expect(await verifier.validate(request, now: now) != nil)
        #expect(await verifier.validate(request, now: now) == nil)
    }

    @Test("Body tampering and stale timestamps are rejected")
    func tamperingIsRejected() async {
        let verifier = MCPGatewayAuthorizationVerifier()
        await verifier.configure(tunnelToken: token)
        let now = Date(timeIntervalSince1970: 1_776_182_400)
        let timestamp = String(Int(now.timeIntervalSince1970))
        var request = signedRequest(timestamp: timestamp, nonce: "abcdefghijklmnopqrstuv")
        request = HTTPRequest(
            method: request.method,
            path: request.path,
            queryString: request.queryString,
            headers: request.headers,
            body: Data("tampered".utf8)
        )
        #expect(await verifier.validate(request, now: now) == nil)

        let stale = signedRequest(timestamp: String(Int(now.timeIntervalSince1970 - 91)), nonce: "zyxwvutsrqponmlkjihgfe")
        #expect(await verifier.validate(stale, now: now) == nil)
    }

    @Test("The gateway's name for the calling app reaches the access context, decoded, and never gates it")
    func assistantNameFromGatewayHeader() async {
        let verifier = MCPGatewayAuthorizationVerifier()
        await verifier.configure(tunnelToken: token)
        let now = Date(timeIntervalSince1970: 1_776_182_400)
        let signed = signedRequest(timestamp: String(Int(now.timeIntervalSince1970)), nonce: "abcdefghijklmnopqrstuv")
        var headers = signed.headers
        headers["x-foreverlm-gateway-client"] = "Claude%20Code%20(foreverlm)"
        let named = HTTPRequest(method: signed.method, path: signed.path, queryString: "", headers: headers, body: signed.body)

        let access = await verifier.validate(named, now: now)
        #expect(access?.assistantName == "Claude Code (foreverlm)")
        #expect(access?.clientID == "chatgpt-directory")

        #expect(MCPGatewayAuthorizationVerifier.assistantName(fromHeader: nil) == nil)
        #expect(MCPGatewayAuthorizationVerifier.assistantName(fromHeader: "%20") == nil)
        #expect(MCPGatewayAuthorizationVerifier.assistantName(fromHeader: "Cod%0Aex") == "Cod ex")
        #expect(MCPGatewayAuthorizationVerifier.assistantName(fromHeader: "Gr%C3%B6k") == "Grök")
    }

    private func signedRequest(timestamp: String, nonce: String) -> HTTPRequest {
        let signature = MCPGatewayAuthorizationVerifier.signature(
            tunnelToken: token,
            method: "POST",
            path: "/mcp",
            timestamp: timestamp,
            nonce: nonce,
            body: body
        )
        return HTTPRequest(
            method: "POST",
            path: "/mcp",
            queryString: "",
            headers: [
                "x-foreverlm-gateway-timestamp": timestamp,
                "x-foreverlm-gateway-nonce": nonce,
                "x-foreverlm-gateway-signature": signature,
            ],
            body: body
        )
    }
}

#endif
