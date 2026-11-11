import Foundation

// MARK: - The rights affirmation before sharing

/// The learner's word, given once, that they may share the sources they share
/// (docs/teams-design.md, decision 22). The product owner, 2026-10-03: "maybe the first
/// time make someone click an affirmation that they have the rights to share
/// those sources with someone else and that they are aware of the copyright
/// laws etc". It is asked before the first thing that copies sources to other
/// people — a notebook's Share… (its first Invite People… or Copy Invitation
/// Link), Share with Team ▸, MCP's `share_notebook` and `share_with_team` —
/// and not again while the stored version is current.
///
/// One synced, per-learner preference row, `sharing.rightsAffirmation`,
/// holding the JSON string `{"version":1,"affirmedAt":"2026-10-03T12:00:00Z"}`
/// (UTC, whole seconds), so it is asked once across the Mac, the iPhone and the
/// web. No row, a row that does not decode, or a row whose version is lower
/// than `currentVersion` means ask; raising `currentVersion` with the statement
/// asks every learner again. Opening or reading anything never writes the row:
/// only the learner ticking the box and pressing Share does, or an assistant
/// passing `rights_affirmed_by_learner: true` after asking the learner in
/// `assistantQuestion`'s words.
///
/// Foundation-only: the Mac, the iPhone and the macOS unit tests compile this
/// one file, and the web keeps the same key, value, reading and words
/// (`library-sharing.js`; its test reads them from here, and both run
/// docs-site/website/test/sharing-rights-affirmation-vectors.json).
struct SharingRightsAffirmation: Equatable, Sendable {
    static let preferenceKey = Prefs.Account.sharingRightsAffirmation.name
    /// The statement's version. Raise it when the words below change in
    /// meaning, and every learner is asked again.
    static let currentVersion = 1

    // The words, the same on every client.
    static let title = "Before you share"
    static let statement = "Sharing a notebook gives the people you invite copies of its sources. Share only sources you have the right to share, in line with copyright and each source's terms."
    static let checkboxLabel = "I have the rights to share these sources"
    static let shareButtonTitle = "Share"
    static let cancelButtonTitle = "Cancel"

    /// What an assistant asks the learner before it may pass
    /// `rights_affirmed_by_learner: true`.
    static let assistantQuestion = "Do you have the rights to share these sources with the people you invite, in line with copyright and each source's terms?"
    /// What an MCP sharing tool answers while the learner has not affirmed.
    static let assistantRefusal = "Before sharing, ask the learner: \"\(assistantQuestion)\" Pass rights_affirmed_by_learner: true only if they say yes."

    let version: Int
    /// When the learner affirmed, to the second.
    let affirmedAt: Date

    init(version: Int = Self.currentVersion, affirmedAt: Date) {
        self.version = version
        self.affirmedAt = Date(timeIntervalSince1970: affirmedAt.timeIntervalSince1970.rounded(.down))
    }

    /// The row's value, as an affirmation made now writes it.
    var rowValue: String {
        "{\"version\":\(version),\"affirmedAt\":\"\(Self.timestampFormatter().string(from: affirmedAt))\"}"
    }

    /// A stored row's value read back: the JSON string with an integer
    /// `version` and an ISO 8601 `affirmedAt` with its zone, `Z` as every
    /// client writes it or `+02:00`, to the second or with a fraction of a
    /// second. Nil for anything else, a zone without its colon, a lowercase
    /// z or a space included: the formatter alone would take those, and the
    /// web would not.
    init?(rowValue: Any?) {
        guard let text = rowValue as? String,
              let row = try? JSONDecoder().decode(Row.self, from: Data(text.utf8)),
              row.affirmedAt.wholeMatch(of: #/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})/#) != nil,
              let affirmedAt = Self.date(from: row.affirmedAt) else { return nil }
        self.init(version: row.version, affirmedAt: affirmedAt)
    }

    /// Whether this affirmation answers the question a client of
    /// `currentVersion` asks. A later version's answer covers an older client.
    func isCurrent(for currentVersion: Int = Self.currentVersion) -> Bool {
        version >= currentVersion
    }

    /// Whether a learner whose row holds `rowValue` must be asked before
    /// sharing: no row, a row that does not decode, or an older version.
    static func needsAsking(rowValue: Any?, currentVersion: Int = Self.currentVersion) -> Bool {
        guard let affirmation = SharingRightsAffirmation(rowValue: rowValue) else { return true }
        return !affirmation.isCurrent(for: currentVersion)
    }

    private struct Row: Decodable {
        let version: Int
        let affirmedAt: String
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func date(from text: String) -> Date? {
        if let date = timestampFormatter().date(from: text) { return date }
        let fractional = timestampFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
