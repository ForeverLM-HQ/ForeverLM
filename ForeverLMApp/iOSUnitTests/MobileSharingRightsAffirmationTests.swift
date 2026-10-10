import Foundation
import XCTest
@testable import ForeverLM

/// The learner's rights affirmation on the phone. The phone keeps no model of
/// its own: the Mac's `SharingRightsAffirmation`, compiled into it, gives the
/// synced row `sharing.rightsAffirmation`, the value written, the version
/// rule and the words Before you share says, and the phone only reads and
/// writes the row through its own Preference rows (`MobilePreferencePlist`).
/// The Mac's SharingRightsAffirmationTests and the web's
/// library-sharing.test.ts pin the same, and run the same row vectors.
final class MobileSharingRightsAffirmationTests: XCTestCase {
    func testThePhoneSaysTheContractsWords() {
        XCTAssertEqual(SharingRightsAffirmation.preferenceKey, "sharing.rightsAffirmation")
        XCTAssertEqual(SharingRightsAffirmation.currentVersion, 1)
        XCTAssertEqual(SharingRightsAffirmation.title, "Before you share")
        XCTAssertEqual(
            SharingRightsAffirmation.statement,
            "Sharing a notebook gives the people you invite copies of its sources. Share only sources you have the right to share, in line with copyright and each source's terms."
        )
        XCTAssertEqual(SharingRightsAffirmation.checkboxLabel, "I have the rights to share these sources")
        XCTAssertEqual(SharingRightsAffirmation.shareButtonTitle, "Share")
        XCTAssertEqual(SharingRightsAffirmation.cancelButtonTitle, "Cancel")
    }

    func testAskedOnceNotAgainAndAgainWhenTheVersionRises() throws {
        // No row: asked.
        XCTAssertTrue(SharingRightsAffirmation.needsAsking(rowValue: nil))
        // Ticked and Share pressed: the value every client writes, in UTC, to the second.
        let pressed = Date(timeIntervalSince1970: 1_791_030_896.789)
        let value = SharingRightsAffirmation(affirmedAt: pressed).rowValue
        XCTAssertEqual(value, #"{"version":1,"affirmedAt":"2026-10-03T12:34:56Z"}"#)
        let stored = try XCTUnwrap(SharingRightsAffirmation(rowValue: value))
        XCTAssertEqual(stored.version, 1)
        XCTAssertEqual(stored.affirmedAt, Date(timeIntervalSince1970: 1_791_030_896))
        // Not asked again while the version is current.
        XCTAssertFalse(SharingRightsAffirmation.needsAsking(rowValue: value))
        // A newer statement asks again; a row a newer client wrote does not.
        XCTAssertTrue(SharingRightsAffirmation.needsAsking(rowValue: value, currentVersion: 2))
        XCTAssertFalse(SharingRightsAffirmation.needsAsking(rowValue: #"{"version":2,"affirmedAt":"2026-10-03T12:34:56Z"}"#))
        // Key order is the writer's business; a fraction of a second and an
        // offset read as they do on the Mac and the web.
        XCTAssertFalse(SharingRightsAffirmation.needsAsking(rowValue: #"{"affirmedAt":"2026-10-03T12:34:56Z","version":1}"#))
        XCTAssertFalse(SharingRightsAffirmation.needsAsking(rowValue: #"{"version":1,"affirmedAt":"2026-10-03T12:34:56.789Z"}"#))
        XCTAssertFalse(SharingRightsAffirmation.needsAsking(rowValue: #"{"version":1,"affirmedAt":"2026-10-03T14:34:56+02:00"}"#))
    }

    func testARowThisPhoneCannotReadAsks() {
        for malformed in [
            "",
            "yes",
            "{",
            "[]",
            "null",
            #"{"version":0,"affirmedAt":"2026-10-03T12:34:56Z"}"#,
            #"{"version":"1","affirmedAt":"2026-10-03T12:34:56Z"}"#,
            #"{"version":1.5,"affirmedAt":"2026-10-03T12:34:56Z"}"#,
            #"{"version":true,"affirmedAt":"2026-10-03T12:34:56Z"}"#,
            #"{"version":1}"#,
            #"{"version":1,"affirmedAt":"yesterday"}"#,
            #"{"version":1,"affirmedAt":"2026-10-03"}"#,
            #"{"version":1,"affirmedAt":"2026-13-45T99:99:99Z"}"#,
            #"{"version":1,"affirmedAt":"2026-10-03T14:34:56+0200"}"#,
            #"{"version":1,"affirmedAt":"2026-10-03T12:34:56z"}"#,
        ] {
            XCTAssertTrue(SharingRightsAffirmation.needsAsking(rowValue: malformed), malformed)
        }
    }

    func testTheRowTravelsAsThePreferencePlistEveryClientWrites() throws {
        let value = SharingRightsAffirmation(affirmedAt: Date(timeIntervalSince1970: 1_791_000_000)).rowValue
        let xml = try XCTUnwrap(MobilePreferencePlist.encode(value))
        XCTAssertEqual(MobilePreferencePlist.decode(xml) as? String, value)
        XCTAssertFalse(SharingRightsAffirmation.needsAsking(rowValue: MobilePreferencePlist.decode(xml)))
        // The web's encoder escapes the quotes; the phone reads its row the same.
        let web = #"<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>v</key><string>{&quot;version&quot;:1,&quot;affirmedAt&quot;:&quot;2026-10-03T08:00:00Z&quot;}</string></dict></plist>"#
        let fromWeb = MobilePreferencePlist.decode(web) as? String
        XCTAssertEqual(fromWeb, #"{"version":1,"affirmedAt":"2026-10-03T08:00:00Z"}"#)
        XCTAssertFalse(SharingRightsAffirmation.needsAsking(rowValue: fromWeb))
    }
}
