import Foundation
import os
import WebKit

/// Keeps the Library jar's session cookies from one launch to the next, so a
/// publisher sign-in made in the reader survives quitting the app.
///
/// Springer Nature signs a learner in with `idp_session` and `idp_session_http`
/// on `.nature.com`, both session cookies: no expiry, "until the browser
/// closes". A browser that reopens its tabs keeps them (Brave holds them for
/// days), but WebKit drops every session cookie when the app quits, so each
/// launch of ForeverLM found the reader signed out of Nature and its papers
/// paywalled again (2026-10-17). Only the week-long `idp_marker` was left,
/// which says a sign-in happened, not who.
///
/// So the keeper copies the session cookies of `WKWebsiteDataStore.default()`
/// — the Library profile, the jar the readers and the paper pipeline share —
/// to a file of this Mac's own whenever they change, and puts them back at
/// launch: what a browser that restores its session does. A cookie the jar
/// already holds at launch is fresher than the copy and is left alone. The
/// other browser profiles are not kept; they are the learner's own jars.
@MainActor
final class WebSessionCookieKeeper: NSObject, WKHTTPCookieStoreObserver {
    static let shared = WebSessionCookieKeeper(
        cookieStore: WKWebsiteDataStore.default().httpCookieStore,
        fileURL: ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent("SessionCookies.plist", isDirectory: false)
    )

    private static let logger = Logger(subsystem: "com.foreverlm", category: "WebSessionCookies")

    /// Cookie changes come in bursts (a page sets a dozen at once), so a save
    /// waits for the burst to settle.
    private static let saveDelay: Duration = .seconds(1)

    private let cookieStore: WKHTTPCookieStore
    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?
    private var started = false

    init(cookieStore: WKHTTPCookieStore, fileURL: URL) {
        self.cookieStore = cookieStore
        self.fileURL = fileURL
    }

    /// Put the last launch's session cookies back, then follow the jar.
    func start() async {
        guard !started else { return }
        started = true
        await restore()
        cookieStore.add(self)
    }

    func restore() async {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let saved = Self.decode(data)
        guard !saved.isEmpty else { return }
        let held = Set(await cookieStore.allCookies().map(Self.identity))
        var restored = 0
        for cookie in saved where !held.contains(Self.identity(cookie)) {
            await cookieStore.setCookie(cookie)
            restored += 1
        }
        Self.logger.info("Restored \(restored, privacy: .public) session cookies")
    }

    func save() async {
        let session = await cookieStore.allCookies().filter(\.isSessionOnly)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Self.encode(session).write(to: fileURL, options: [.atomic])
            // Sign-in tokens: readable by this user only, as WebKit's own cookie file is.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Self.logger.error("Could not save session cookies: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.scheduleSave() }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    // MARK: File format

    /// A cookie is one per name, domain and path; a second with the same three replaces the first.
    nonisolated static func identity(_ cookie: HTTPCookie) -> String {
        "\(cookie.name)\t\(cookie.domain.lowercased())\t\(cookie.path)"
    }

    /// A property list of each cookie's `properties`, which `HTTPCookie(properties:)` reads back.
    nonisolated static func encode(_ cookies: [HTTPCookie]) throws -> Data {
        let list: [[String: Any]] = cookies.compactMap { cookie in
            guard let properties = cookie.properties else { return nil }
            var entry: [String: Any] = [:]
            for (key, value) in properties where PropertyListSerialization.propertyList(value, isValidFor: .binary) {
                entry[key.rawValue] = value
            }
            return entry
        }
        return try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    }

    nonisolated static func decode(_ data: Data) -> [HTTPCookie] {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            let properties = Dictionary(uniqueKeysWithValues: entry.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            return HTTPCookie(properties: properties)
        }
    }
}
