#if os(macOS) && FOREVERLM_FIRST_RUN
import Foundation
import Security

/// The half of `scripts/reset_first_run_app.sh` that only the app can do.
///
/// The script removes the First Run app's library, settings, caches and
/// privacy permissions, but its sign-in and keys sit in the data-protection
/// keychain under an access group only this signed app can open, so no
/// command-line tool can delete them. Left alone, a "fresh" launch would come
/// back already signed in and skip the very screens it exists to show. The
/// script leaves `markerURL` behind; the next launch sees it, deletes every
/// keychain item under this app's own service, and removes the marker.
///
/// It must run before anything reads the keychain or opens the library, which
/// is why `ForeverLMApp` calls it from its first stored property.
enum FirstRunFreshStart {
    /// Keep in step with `MARKER` in `scripts/reset_first_run_app.sh`.
    static var markerURL: URL {
        ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent(".fresh-start-requested", isDirectory: false)
    }

    static func prepareIfRequested() {
        let fileManager = FileManager.default
        guard ForeverLMRuntimeIdentity.isFirstRun,
              fileManager.fileExists(atPath: markerURL.path) else { return }
        deleteKeychainItems()
        try? fileManager.removeItem(at: markerURL)
    }

    /// Every generic password under this app's service, in whichever keychain
    /// and access group it landed, synced or not. The service is the First Run
    /// app's alone, so nothing the Dev or installed app keeps can match.
    private static func deleteKeychainItems() {
        let service = ForeverLMRuntimeIdentity.keychainService
        let queries: [[String: Any]] = [
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecUseDataProtectionKeychain as String: true,
            ],
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ],
        ]
        for query in queries {
            // The file-based keychain deletes one match per call.
            var remaining = 256
            while remaining > 0, SecItemDelete(query as CFDictionary) == errSecSuccess {
                remaining -= 1
            }
        }
    }
}
#endif
