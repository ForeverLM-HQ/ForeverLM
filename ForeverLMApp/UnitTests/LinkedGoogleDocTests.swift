import Foundation
import Testing
@testable import ForeverLM

@Suite("Linked Google Docs")
struct LinkedGoogleDocTests {
    @Test("Every form of a Google Docs link normalizes to one canonical edit URL")
    func canonicalEditURL() throws {
        let canonical = "https://docs.google.com/document/d/1AbC-dEf_9/edit"
        for pasted in [
            "https://docs.google.com/document/d/1AbC-dEf_9/edit",
            "https://docs.google.com/document/d/1AbC-dEf_9/edit?usp=sharing",
            "https://docs.google.com/document/d/1AbC-dEf_9/edit#heading=h.abc",
            "https://docs.google.com/document/d/1AbC-dEf_9/preview",
            "https://docs.google.com/document/d/1AbC-dEf_9/view",
            "https://docs.google.com/document/d/1AbC-dEf_9",
            "https://docs.google.com/document/u/0/d/1AbC-dEf_9/edit",
            "https://docs.google.com/document/d/1AbC-dEf_9/mobilebasic",
            "docs.google.com/document/d/1AbC-dEf_9/edit",
            "  https://docs.google.com/document/d/1AbC-dEf_9/edit \n",
        ] {
            #expect(try LinkedGoogleDoc.canonicalEditURL(from: pasted).absoluteString == canonical, "\(pasted)")
        }
        #expect(LinkedGoogleDoc.documentID(from: canonical) == "1AbC-dEf_9")
        #expect(
            LinkedGoogleDoc.exportURL(documentID: "1AbC-dEf_9").absoluteString
                == "https://docs.google.com/document/d/1AbC-dEf_9/export?format=txt"
        )
    }

    @Test("Anything that is not a Google Doc is refused with the reason")
    func refusesNonDocuments() {
        #expect(throws: LinkedGoogleDocError.empty) {
            _ = try LinkedGoogleDoc.canonicalEditURL(from: "   ")
        }
        #expect(throws: LinkedGoogleDocError.notGoogleDocs("drive.google.com")) {
            _ = try LinkedGoogleDoc.canonicalEditURL(from: "https://drive.google.com/file/d/1AbC/view")
        }
        #expect(throws: LinkedGoogleDocError.notGoogleDocs("example.com")) {
            _ = try LinkedGoogleDoc.canonicalEditURL(from: "https://example.com/document/d/1AbC/edit")
        }
        #expect(throws: LinkedGoogleDocError.wrongKind("Google Sheet")) {
            _ = try LinkedGoogleDoc.canonicalEditURL(from: "https://docs.google.com/spreadsheets/d/1AbC/edit#gid=0")
        }
        #expect(throws: LinkedGoogleDocError.wrongKind("Google Slides deck")) {
            _ = try LinkedGoogleDoc.canonicalEditURL(from: "https://docs.google.com/presentation/d/1AbC/edit")
        }
        #expect(throws: LinkedGoogleDocError.noDocumentID) {
            _ = try LinkedGoogleDoc.canonicalEditURL(from: "https://docs.google.com/document/")
        }
        // A published snapshot is not an exportable document id.
        #expect(throws: LinkedGoogleDocError.noDocumentID) {
            _ = try LinkedGoogleDoc.canonicalEditURL(from: "https://docs.google.com/document/d/e/2PACX-abc/pub")
        }
        #expect(LinkedGoogleDoc.documentID(from: "https://docs.google.com/spreadsheets/d/1AbC/edit") == nil)
        for error in [LinkedGoogleDocError.empty, .notAURL, .notGoogleDocs("x"), .noDocumentID, .wrongKind("y")] {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test("The doc's name comes off Google's page title; sign-in pages never do")
    func titleFromPageTitle() {
        #expect(LinkedGoogleDoc.title(fromPageTitle: "Q3 planning notes - Google Docs") == "Q3 planning notes")
        #expect(LinkedGoogleDoc.title(fromPageTitle: "  Notes – Google Docs ") == "Notes")
        #expect(LinkedGoogleDoc.title(fromPageTitle: "Google Docs") == nil)
        #expect(LinkedGoogleDoc.title(fromPageTitle: "Google Accounts") == nil)
        #expect(LinkedGoogleDoc.title(fromPageTitle: "") == nil)
        #expect(LinkedGoogleDoc.isSignInURL(URL(string: "https://accounts.google.com/v3/signin/identifier?x=1")))
        #expect(!LinkedGoogleDoc.isSignInURL(URL(string: "https://docs.google.com/document/d/1/edit")))
        #expect(!LinkedGoogleDoc.isSignInURL(nil))
        #expect(
            LinkedGoogleDoc.pageTitle(inHTML: "<html><head><meta charset=\"utf-8\"><TITLE>Plan &amp; budget - Google Docs</TITLE></head>")
                == "Plan & budget - Google Docs"
        )
        #expect(LinkedGoogleDoc.pageTitle(inHTML: "<html><body>no title</body></html>") == nil)
    }

    @Test("Only the browser cookies a request would carry are attached to the export")
    func cookieScoping() throws {
        let exportURL = LinkedGoogleDoc.exportURL(documentID: "1AbC")
        func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: "v", .domain: domain, .path: path,
            ]
            if secure { properties[.secure] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)!
        }
        let applicable = LinkedGoogleDoc.cookies([
            cookie("SID", domain: ".google.com"),
            cookie("docs", domain: "docs.google.com"),
            cookie("other", domain: ".example.com"),
            cookie("accounts", domain: "accounts.google.com"),
            cookie("deep", domain: ".google.com", path: "/drive"),
            cookie("stale", domain: ".google.com", expires: Date(timeIntervalSinceNow: -60)),
        ], applicableTo: exportURL)
        #expect(applicable.map(\.name).sorted() == ["SID", "docs"])
    }
}
