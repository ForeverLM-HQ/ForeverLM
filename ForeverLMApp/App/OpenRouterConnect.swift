import AppKit
import CryptoKit
import Foundation

/// "Connect OpenRouter": OpenRouter's OAuth PKCE flow, so a learner gets a key
/// without finding and copying one (docs: openrouter.ai/docs/use-cases/oauth-pkce).
///
/// The browser signs in at openrouter.ai/auth and returns to a one-time
/// loopback listener on this Mac with `?code=`; the code and its verifier are
/// then exchanged at /api/v1/auth/keys for a key that bills the learner's own
/// OpenRouter account. OpenRouter documents localhost callbacks on any port,
/// which is why this uses the loopback listener the Google sign-ins already use
/// rather than a custom URL scheme.
enum OpenRouterConnect {
    struct ConnectError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let callbackPath = "/openrouter"

    static func authorizationURL(callbackURL: String, codeChallenge: String, keyLabel: String = "ForeverLM") -> URL? {
        var components = URLComponents(string: "https://openrouter.ai/auth")
        components?.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "key_label", value: keyLabel),
        ]
        return components?.url
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Runs the whole flow and returns the new key. The key is not stored here:
    /// the caller hands it to `ManagedAIAccountModel.setOwnKey`, which checks it
    /// with OpenRouter and keeps it in the Keychain like a pasted one — or, for
    /// a family member's key (`keyLabel` naming them), seals it to their device
    /// (docs/family-design.md).
    static func connect(keyLabel: String = "ForeverLM") async throws -> String {
        let verifier = makeCodeVerifier()
        let server = try GoogleOAuthCallbackServer(serviceName: "OpenRouter", callbackPath: callbackPath)
        try await server.start()
        let callbackURL = "http://localhost:\(server.port)\(callbackPath)"
        guard let authURL = authorizationURL(
            callbackURL: callbackURL,
            codeChallenge: codeChallenge(for: verifier),
            keyLabel: keyLabel
        ) else {
            server.stop()
            throw ConnectError(message: "Couldn't build the OpenRouter sign-in address.")
        }

        let callbackTask = Task { try await server.waitForCallback(timeout: 300) }
        defer {
            callbackTask.cancel()
            server.stop()
        }
        guard NSWorkspace.shared.open(authURL) else {
            throw ConnectError(message: "Couldn't open OpenRouter in your browser.")
        }

        let returned = try await callbackTask.value
        guard let code = URLComponents(url: returned, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            server.completeBrowserCallback(success: false, message: "OpenRouter didn't send a key. Return to ForeverLM and try again.")
            throw ConnectError(message: "OpenRouter didn't finish connecting. Try again, or paste a key instead.")
        }

        do {
            let key = try await exchange(code: code, verifier: verifier)
            server.completeBrowserCallback(success: true, message: "You can close this tab and return to ForeverLM.")
            return key
        } catch {
            server.completeBrowserCallback(success: false, message: "Return to ForeverLM and try again.")
            throw error
        }
    }

    private static func exchange(code: String, verifier: String) async throws -> String {
        struct Body: Encodable {
            let code: String
            let code_verifier: String
            let code_challenge_method: String
        }
        struct Response: Decodable { let key: String }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(code: code, code_verifier: verifier, code_challenge_method: "S256"))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let key = try? JSONDecoder().decode(Response.self, from: data).key, !key.isEmpty else {
            throw ConnectError(message: "OpenRouter didn't hand over a key. Try again, or paste a key instead.")
        }
        return key
    }
}
