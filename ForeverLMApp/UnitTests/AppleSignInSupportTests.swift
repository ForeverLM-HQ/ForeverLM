import AuthenticationServices
import Foundation
import Testing
@testable import ForeverLM

@Suite("Apple sign-in error presentation")
struct AppleSignInSupportTests {
    @Test("Web authentication requires a signed app")
    func webAuthenticationRejectsAdHocBuilds() {
        #expect(AppleSignInSupport.webAuthenticationIsAvailable(
            isDirectDownload: true,
            hasSigningTeam: true
        ))
        #expect(!AppleSignInSupport.webAuthenticationIsAvailable(
            isDirectDownload: true,
            hasSigningTeam: false
        ))
        #expect(!AppleSignInSupport.webAuthenticationIsAvailable(
            isDirectDownload: false,
            hasSigningTeam: true
        ))
    }

    @Test("Hand-off targets the installed signed build, never itself")
    func installedDevelopmentBuildResolution() {
        let installed = URL(fileURLWithPath: "/Users/me/Applications/DevLM.app", isDirectory: true)
        let derived = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData/X/Build/Products/Debug/DevLM.app", isDirectory: true)

        #expect(AppleSignInSupport.installedDevelopmentBuild(
            at: installed, currentBundle: derived, exists: { _ in true }
        ) == installed)
        #expect(AppleSignInSupport.installedDevelopmentBuild(
            at: installed, currentBundle: derived, exists: { _ in false }
        ) == nil)
        // The installed copy itself, reached through a trailing slash, is not a target.
        #expect(AppleSignInSupport.installedDevelopmentBuild(
            at: installed,
            currentBundle: URL(fileURLWithPath: "/Users/me/Applications/DevLM.app/"),
            exists: { _ in true }
        ) == nil)
    }

    @Test("Framework details never reach user-facing copy")
    func sanitizesUnknownFrameworkError() {
        let error = ASAuthorizationError(.unknown)

        let message = AppleSignInSupport.userMessage(for: error)

        #expect(message == AppleSignInSupport.genericFailureMessage)
        #expect(message?.contains("AuthenticationServices") == false)
        #expect(message?.contains("1000") == false)
    }

    @Test("Cancellation remains silent")
    func cancellationIsSilent() {
        #expect(AppleSignInSupport.userMessage(for: ASAuthorizationError(.canceled)) == nil)
    }

    @Test("Unrelated errors are also reduced to stable copy")
    func sanitizesUnexpectedError() {
        let error = NSError(
            domain: "Sensitive.Internal.Domain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Internal implementation detail"]
        )

        #expect(AppleSignInSupport.userMessage(for: error) == AppleSignInSupport.genericFailureMessage)
    }
}
