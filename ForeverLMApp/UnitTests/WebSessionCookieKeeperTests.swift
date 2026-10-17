import Foundation
import Testing
import WebKit
@testable import ForeverLM

@Suite("Web session cookie keeper")
@MainActor
struct WebSessionCookieKeeperTests {
    // A cookie store does not keep its data store alive, so each test holds
    // the `WKWebsiteDataStore` until it has read the cookies back.
    private func cookie(_ name: String, _ value: String, domain: String = ".example-journal.org", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WebSessionCookieKeeperTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("SessionCookies.plist")
    }

    @Test("A saved cookie reads back with its name, value, domain and secure flag")
    func roundTrip() throws {
        let decoded = WebSessionCookieKeeper.decode(try WebSessionCookieKeeper.encode([cookie("idp_session", "abc123")]))
        #expect(decoded.count == 1)
        #expect(decoded.first?.name == "idp_session")
        #expect(decoded.first?.value == "abc123")
        #expect(decoded.first?.domain == ".example-journal.org")
        #expect(decoded.first?.isSecure == true)
        #expect(decoded.first?.isSessionOnly == true)
    }

    @Test("Only session cookies are kept; one with an expiry is WebKit's to keep")
    func savesSessionCookiesOnly() async throws {
        let file = scratchFile()
        let jarData = WKWebsiteDataStore.nonPersistent()
        let jar = jarData.httpCookieStore
        await jar.setCookie(cookie("idp_session", "signed-in"))
        await jar.setCookie(cookie("idp_marker", "seen", expires: Date().addingTimeInterval(86_400)))

        await WebSessionCookieKeeper(cookieStore: jar, fileURL: file).save()

        let saved = WebSessionCookieKeeper.decode(try Data(contentsOf: file))
        #expect(saved.map(\.name) == ["idp_session"])
        withExtendedLifetime(jarData) {}
    }

    @Test("Restoring puts a quit's session cookies back, but never over a fresher one")
    func restoreKeepsFresherCookies() async throws {
        let file = scratchFile()
        let beforeData = WKWebsiteDataStore.nonPersistent()
        let before = beforeData.httpCookieStore
        await before.setCookie(cookie("idp_session", "old-session"))
        await before.setCookie(cookie("idp_session_http", "old-http"))
        await WebSessionCookieKeeper(cookieStore: before, fileURL: file).save()

        let afterData = WKWebsiteDataStore.nonPersistent()
        let after = afterData.httpCookieStore
        await after.setCookie(cookie("idp_session", "new-session"))
        await WebSessionCookieKeeper(cookieStore: after, fileURL: file).restore()

        let values = Dictionary(uniqueKeysWithValues: await after.allCookies().map { ($0.name, $0.value) })
        #expect(values["idp_session"] == "new-session")
        #expect(values["idp_session_http"] == "old-http")
        withExtendedLifetime((beforeData, afterData)) {}
    }
}
