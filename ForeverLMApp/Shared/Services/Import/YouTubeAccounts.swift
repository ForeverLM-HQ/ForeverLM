import Foundation

/// What a connected YouTube account brings into the library.
///
/// Which YouTube state belongs to an account and which to the learner:
/// - **Account:** the tokens and the OAuth client that issued them (Keychain
///   items per account id), and what this account imports: its source (Liked
///   videos or its playlist named ForeverLM), the liked-import policy and its
///   cutoff. Disconnecting an account deletes all of it, and connecting the
///   same channel again starts from nothing chosen.
/// - **Learner:** the automatic-import switch, whether new liked-video
///   transcripts are formatted, followed channels and hidden channels. A
///   followed channel is a public follow, so it does not depend on which
///   account is connected; the calls that need a token anyway borrow the first
///   connected account's (`YouTubeService.publicRequestAccountID`).
struct YouTubeImportChoices: Codable, Equatable, Hashable, Sendable {
    /// nil until the learner picks one.
    var source: YouTubeImportSource?
    /// The playlist named ForeverLM that `source == .foreverLMPlaylist` reads,
    /// remembered so switching away can release its group.
    var foreverLMPlaylistID: String?
    /// `.undecided` until the learner says whether existing likes come in;
    /// nothing is imported from Liked videos before that.
    var likedPolicy: YouTubeLikedImportPolicy
    /// With `.futureOnly`, likes from before this moment are not imported.
    var likedCutoff: Date?

    /// A connection nobody has configured yet.
    static let unchosen = YouTubeImportChoices(
        source: nil,
        foreverLMPlaylistID: nil,
        likedPolicy: .undecided,
        likedCutoff: nil
    )
}

struct YouTubeAccount: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// The account's YouTube channel id (`UC…`). `channels.list?mine=true` is
    /// the cheapest identity inside `youtube.readonly`: Google's userinfo
    /// needs `openid` or `email`, which this connection never asks for, and a
    /// channel id survives a rename.
    let id: String
    /// The channel's title, the only name the readonly scope gives (no email).
    var title: String
    var choices: YouTubeImportChoices

    init(id: String, title: String, choices: YouTubeImportChoices = .unchosen) {
        self.id = id
        self.title = title
        self.choices = choices
    }
}

/// The accounts as stored: a JSON array in one synced Keychain item, in the
/// order they were connected (that order is what "the first connected" means).
enum YouTubeAccountList {
    static func decode(_ value: String?) -> [YouTubeAccount] {
        guard let value, let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([YouTubeAccount].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return decoded.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    static func encode(_ accounts: [YouTubeAccount]) -> String? {
        guard let data = try? JSONEncoder().encode(accounts) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Connecting a channel that is already listed keeps its place and its
    /// choices and refreshes its title; a new one goes last.
    static func connecting(
        id: String,
        title: String,
        choicesIfNew: YouTubeImportChoices = .unchosen,
        into accounts: [YouTubeAccount]
    ) -> [YouTubeAccount] {
        var accounts = accounts
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].title = title
        } else {
            accounts.append(YouTubeAccount(id: id, title: title, choices: choicesIfNew))
        }
        return accounts
    }

    static func removing(id: String, from accounts: [YouTubeAccount]) -> [YouTubeAccount] {
        accounts.filter { $0.id != id }
    }

    static func setting(
        _ choices: YouTubeImportChoices,
        forAccount id: String,
        in accounts: [YouTubeAccount]
    ) -> [YouTubeAccount] {
        accounts.map { account in
            guard account.id == id else { return account }
            var updated = account
            updated.choices = choices
            return updated
        }
    }
}

/// The accounts and which of them hold no grant any more, read once.
struct YouTubeAccountSnapshot: Equatable, Sendable {
    var accounts: [YouTubeAccount]
    /// Listed accounts whose credentials are gone: Google revoked the grant.
    /// They stay listed so reconnecting the same channel restores its choices.
    var disconnectedIDs: Set<String>
}
