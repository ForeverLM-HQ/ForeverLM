import AuthenticationServices
import Foundation
import OSLog
#if os(macOS)
import Security
#endif

/// The one boundary between AuthenticationServices failures and user-facing copy.
///
/// Apple's localized descriptions include framework domains and numeric codes (for
/// example `AuthorizationError error 1000`). Those details belong in diagnostics,
/// never in the account wall. A missing entitlement is detected before a request is
/// made because an ad-hoc/unsigned development artifact can never complete Apple sign-in.
enum AppleSignInSupport {
    /// A Dev build shows the remedy rather than the shipping copy: the only person
    /// who ever reads it is the one who can rebuild the app, and "install a signed
    /// build" does not tell them that a Dev build is signable at all.
    #if FOREVERLM_DEVELOPMENT
    static let unavailableMessage = "This copy of DevLM is ad-hoc signed, so it carries no Sign in with Apple entitlement. ForeverLMApp/scripts/build_dev.sh builds a signed one and installs it at ~/Applications/DevLM.app; launch that copy."
    #else
    static let unavailableMessage = "This copy of ForeverLM can’t use Sign in with Apple. Install a signed build and try again."
    #endif
    static let genericFailureMessage = "Apple couldn’t complete sign-in. Check your Apple Account and internet connection, then try again."

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "AppleSignIn"
    )

    /// Cached once rather than querying the process entitlement from a SwiftUI body.
    static let hasRequiredEntitlement: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.applesignin" as CFString,
                  nil
              ) as? [String] else {
            return false
        }
        return value.contains("Default")
        #else
        // SecTask entitlement inspection is not public on iOS. Device and
        // simulator installs are already rejected when provisioning does not
        // match the target's Sign in with Apple entitlement.
        return true
        #endif
    }()

    /// A web Services ID flow still needs an identifiable, signed requesting
    /// app. Ad-hoc products can be produced by verification builds with code
    /// signing disabled; letting one start AuthenticationServices produces an
    /// empty browser sheet and can hand the callback to a different cached Dev
    /// bundle. A real Apple Development or Developer ID signature injects this
    /// entitlement even though it is not written in the source plist.
    static let hasSigningTeam: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.team-identifier" as CFString,
                  nil
              ) as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #else
        return true
        #endif
    }()

    static func webAuthenticationIsAvailable(
        isDirectDownload: Bool,
        hasSigningTeam: Bool
    ) -> Bool {
        isDirectDownload && hasSigningTeam
    }

    /// Developer ID provisioning does not support the native Sign in with Apple
    /// entitlement. Direct-download builds authenticate through the registered
    /// web Services ID instead, then hand the Apple identity token back to the app.
    static let supportsWebAuthentication: Bool = {
        #if os(macOS) && DIRECT_DOWNLOAD
        return webAuthenticationIsAvailable(
            isDirectDownload: true,
            hasSigningTeam: hasSigningTeam
        )
        #else
        return false
        #endif
    }()

    static var canSignIn: Bool {
        hasRequiredEntitlement || supportsWebAuthentication
    }

    /// Where `scripts/build_dev.sh` installs the signed Dev build (`DevLM.app`,
    /// or `FirstRunLM.app` for the FirstRun configuration). Test runs and
    /// verification builds keep producing ad-hoc "DevLM.app" bundles in one
    /// DerivedData directory or another, and LaunchServices is happy to open any of
    /// them; this is the one path that only ever holds a copy that can sign in.
    /// Mac only: iOS has no home directory to install into and no Dev build to
    /// hand off to, and `homeDirectoryForCurrentUser` does not compile there.
    #if os(macOS)
    static let installedDevelopmentBuildURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/\(ForeverLMRuntimeIdentity.bundleFileName).app", isDirectory: true)
    #else
    static let installedDevelopmentBuildURL = URL(fileURLWithPath: "/Applications/DevLM.app", isDirectory: true)
    #endif

    /// The signed Dev build to hand off to when this process cannot sign in, or nil
    /// when there is none — or when this process *is* the installed copy, in which
    /// case relaunching it would only bring the same wall back.
    static func installedDevelopmentBuild(
        at installed: URL = installedDevelopmentBuildURL,
        currentBundle: URL = Bundle.main.bundleURL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        guard exists(installed) else { return nil }
        let installedPath = installed.standardizedFileURL.resolvingSymlinksInPath().path
        let currentPath = currentBundle.standardizedFileURL.resolvingSymlinksInPath().path
        return installedPath == currentPath ? nil : installed
    }

    /// Non-nil only for a Dev build that cannot sign in while a signed copy is installed.
    static var handoffDevelopmentBuildURL: URL? {
        #if os(macOS) && FOREVERLM_DEVELOPMENT
        return canSignIn ? nil : installedDevelopmentBuild()
        #else
        return nil
        #endif
    }

    static var preflightMessage: String? {
        canSignIn ? nil : unavailableMessage
    }

    /// Returns nil only when the user cancelled. Every other framework failure is
    /// recorded with its domain/code and reduced to stable, human-readable copy.
    static func userMessage(for error: Error) -> String? {
        if let authorizationError = error as? ASAuthorizationError,
           authorizationError.code == .canceled {
            return nil
        }

        let nsError = error as NSError
        logger.error(
            "Apple authorization failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
        )
        return genericFailureMessage
    }
}

/// Constructs browser authentication sessions through AuthenticationServices' current
/// callback matcher while preserving support for the app's earliest OS versions.
///
/// The deprecated scheme-only handoff rendered its requesting-app label as “(null)” on
/// current macOS before Safari opened the authentication flow. Keeping construction here
/// prevents individual OAuth integrations from drifting back to that deprecated path.
enum WebAuthenticationSessionSupport {
    static func make(
        url: URL,
        callbackScheme: String,
        completionHandler: @escaping ASWebAuthenticationSession.CompletionHandler
    ) -> ASWebAuthenticationSession {
        if #available(macOS 14.4, iOS 17.4, *) {
            return ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme),
                completionHandler: completionHandler
            )
        }
        return ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme,
            completionHandler: completionHandler
        )
    }
}
