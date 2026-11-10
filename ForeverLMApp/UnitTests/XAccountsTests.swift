import Testing
import Foundation
@testable import ForeverLM

@Suite("X Accounts")
struct XAccountsTests {
    private let robin = XAccount(id: "1001", username: "robin")
    private let zara = XAccount(id: "1002", username: "zara_holt")

    @Test("The account list round-trips and drops duplicates and empty ids")
    func accountListRoundTrips() throws {
        let encoded = try #require(XAccountBook.encode([robin, zara, XAccount(id: "1001", username: "again"), XAccount(id: "", username: "ghost")]))
        #expect(XAccountBook.decode(encoded) == [robin, zara])
        #expect(XAccountBook.decode(nil).isEmpty)
        #expect(XAccountBook.decode("not json").isEmpty)
        // An account adopted before its handle was read has none, and keeps none.
        let unnamed = XAccount(id: "1003", username: nil)
        #expect(XAccountBook.decode(XAccountBook.encode([unnamed])) == [unnamed])
        #expect(unnamed.displayLabel == "X account 1003")
        #expect(robin.displayLabel == "@robin")
    }

    @Test("Signing in again as a connected X user refreshes it in place")
    func mergingRefreshesTheSameUser() {
        let renamed = XAccount(id: "1001", username: "robin_ward")
        #expect(XAccountBook.merging(renamed, into: [robin, zara]) == [renamed, zara])
        #expect(XAccountBook.merging(XAccount(id: "1003", username: "kai"), into: [robin, zara]).map(\.id) == ["1001", "1002", "1003"])
        // A sign-in that did not read the handle keeps the one already known.
        #expect(XAccountBook.merging(XAccount(id: "1001", username: nil), into: [robin]) == [robin])
        #expect(XAccountBook.removing(id: "1001", from: [robin, zara]) == [zara])
    }

    @Test("Credentials round-trip as one value, expiry included")
    func credentialsRoundTrip() throws {
        let expiry = Date(timeIntervalSince1970: 1_788_000_000)
        let credentials = XAccountCredentials(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            tokenExpiry: expiry,
            grantedScopes: "tweet.read tweet.write",
            clientID: "client-1"
        )
        let decoded = try #require(XAccountCredentials.decode(credentials.encoded()))
        #expect(decoded == credentials)
        #expect(XAccountCredentials.decode(nil) == nil)
        #expect(XAccountCredentials.decode("{\"accessToken\":\"\"}") == nil)
    }

    @Test("Each account has its own bookmark cursors")
    func cursorKeysArePerAccount() {
        #expect(XAccountBook.newestIDKey(accountID: "1001") == "x_bookmarks_newest_id.1001")
        #expect(XAccountBook.lastSyncKey(accountID: "1001") == "x_bookmarks_last_sync.1001")
        #expect(XAccountBook.newestIDKey(accountID: "1001") != XAccountBook.newestIDKey(accountID: "1002"))
        // They stay under the prefix that keeps them off iCloud's preference sync.
        #expect(XAccountBook.newestIDKey(accountID: "1001").hasPrefix("x_bookmarks_"))
        #expect(XAccountBook.lastSyncKey(accountID: "1001").hasPrefix("x_bookmarks_"))
    }

    @Test("A saved post cuts an account's first sync short only when it is the only account")
    func savedPostsStopOnlyWhenTheyCanBeTrusted() {
        let saved: Set<String> = ["a", "b"]
        // The watermark makes the saved posts a safe extra stop.
        #expect(XAccountBook.stopPostIDs(savedPostIDs: saved, newestSeenTweetID: "w", connectedAccountCount: 2) == saved)
        // One account, no watermark yet: the library's posts are its own.
        #expect(XAccountBook.stopPostIDs(savedPostIDs: saved, newestSeenTweetID: nil, connectedAccountCount: 1) == saved)
        // A new account among others: the library's posts may be another account's.
        #expect(XAccountBook.stopPostIDs(savedPostIDs: saved, newestSeenTweetID: nil, connectedAccountCount: 2).isEmpty)
    }

    @Test("A post goes out as the one connected account, or as the one named")
    func postingAccountSelection() throws {
        #expect(try XAccountBook.postingAccount(among: [robin], requested: nil) == robin)
        #expect(try XAccountBook.postingAccount(among: [robin], requested: "  ") == robin)
        #expect(try XAccountBook.postingAccount(among: [robin, zara], requested: "@Zara_Holt") == zara)
        #expect(try XAccountBook.postingAccount(among: [robin, zara], requested: "1001") == robin)
        #expect(try XAccountBook.postingAccount(among: [robin, zara], requested: "robin") == robin)
    }

    @Test("With several accounts and none named, posting refuses and names them")
    func postingRequiresANameWhenSeveral() {
        #expect(throws: XBookmarkError.accountRequired(connected: ["@robin", "@zara_holt"])) {
            try XAccountBook.postingAccount(among: [robin, zara], requested: nil)
        }
        #expect(throws: XBookmarkError.accountNotConnected("@kai", connected: ["@robin", "@zara_holt"])) {
            try XAccountBook.postingAccount(among: [robin, zara], requested: "@kai")
        }
        #expect(throws: XBookmarkError.notSignedIn) {
            try XAccountBook.postingAccount(among: [], requested: nil)
        }
        let message = XBookmarkError.accountRequired(connected: ["@robin", "@zara_holt"]).errorDescription
        #expect(message?.contains("@robin") == true && message?.contains("@zara_holt") == true)
    }
}
