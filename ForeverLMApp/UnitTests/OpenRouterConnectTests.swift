import Foundation
import Testing
@testable import ForeverLM

@Suite("Connect OpenRouter")
struct OpenRouterConnectTests {
    @Test("The PKCE challenge is the RFC 7636 S256 of the verifier")
    func challengeMatchesRFCExample() {
        // RFC 7636 Appendix B.
        #expect(OpenRouterConnect.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = OpenRouterConnect.makeCodeVerifier()
        #expect(verifier.count >= 43)
        #expect(!verifier.contains("=") && !verifier.contains("+") && !verifier.contains("/"))
    }

    @Test("The sign-in address carries the localhost callback and the S256 challenge")
    func authorizationURL() throws {
        let url = try #require(OpenRouterConnect.authorizationURL(callbackURL: "http://localhost:5123/openrouter", codeChallenge: "abc"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host == "openrouter.ai")
        #expect(items.first { $0.name == "callback_url" }?.value == "http://localhost:5123/openrouter")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(items.first { $0.name == "code_challenge" }?.value == "abc")
    }
}
