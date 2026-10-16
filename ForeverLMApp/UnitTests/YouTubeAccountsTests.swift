import Foundation
import Testing
@testable import ForeverLM

/// The pure parts of a YouTube plugin that holds several accounts: the stored
/// list, what an older single connection becomes, which account an assistant's
/// call means, and what each account's own import choices do to the shared
/// Liked mirror. Keychain, network and views are not touched.
@Suite("YouTube accounts")
struct YouTubeAccountsTests {

    private func account(
        _ id: String,
        _ title: String,
        source: YouTubeImportSource? = nil,
        policy: YouTubeLikedImportPolicy = .undecided,
        cutoff: Date? = nil,
        playlistID: String? = nil
    ) -> YouTubeAccount {
        YouTubeAccount(
            id: id,
            title: title,
            choices: YouTubeImportChoices(
                source: source,
                foreverLMPlaylistID: playlistID,
                likedPolicy: policy,
                likedCutoff: cutoff
            )
        )
    }

    private func item(_ videoID: String, likedAt: Date? = nil) -> YouTubePlaylistItem {
        YouTubePlaylistItem(videoId: videoID, title: "Video \(videoID)", likedAt: likedAt)
    }

    // MARK: - The stored list

    @Test("the list survives encoding with each account's choices")
    func listRoundTrips() throws {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let accounts = [
            account("UCzara", "Zara Holt Lab", source: .likedVideos, policy: .futureOnly, cutoff: cutoff),
            account("UCbench", "Bench Notes", source: .foreverLMPlaylist, playlistID: "PLbench"),
            account("UCnone", "Nothing Yet"),
        ]
        let decoded = YouTubeAccountList.decode(try #require(YouTubeAccountList.encode(accounts)))
        #expect(decoded == accounts)
    }

    @Test("a missing, broken or repeating list reads as the accounts it can")
    func decodeIsTolerant() throws {
        #expect(YouTubeAccountList.decode(nil).isEmpty)
        #expect(YouTubeAccountList.decode("not json").isEmpty)
        let repeated = try #require(YouTubeAccountList.encode([
            account("UCzara", "Zara Holt Lab"),
            account("", "No id"),
            account("UCzara", "Zara again"),
        ]))
        #expect(YouTubeAccountList.decode(repeated).map(\.title) == ["Zara Holt Lab"])
    }

    @Test("connecting a listed channel keeps its place and choices, a new one goes last")
    func connectingKeepsOrderAndChoices() {
        let listed = [
            account("UCone", "One", source: .likedVideos, policy: .importExisting),
            account("UCtwo", "Two"),
        ]
        let reconnected = YouTubeAccountList.connecting(id: "UCone", title: "One, renamed", into: listed)
        #expect(reconnected.map(\.id) == ["UCone", "UCtwo"])
        #expect(reconnected[0].title == "One, renamed")
        #expect(reconnected[0].choices.source == .likedVideos)
        #expect(reconnected[0].choices.likedPolicy == .importExisting)

        let added = YouTubeAccountList.connecting(id: "UCthree", title: "Three", into: listed)
        #expect(added.map(\.id) == ["UCone", "UCtwo", "UCthree"])
        #expect(added[2].choices == .unchosen)
    }

    @Test("disconnecting one account leaves the others as they were")
    func removingOneAccount() {
        let listed = [account("UCone", "One", source: .likedVideos, policy: .futureOnly), account("UCtwo", "Two")]
        let remaining = YouTubeAccountList.removing(id: "UCtwo", from: listed)
        #expect(remaining == [listed[0]])
    }

    @Test("an account's choices are stored for that account only")
    func settingChoicesIsPerAccount() {
        let listed = [account("UCone", "One"), account("UCtwo", "Two")]
        var chosen = YouTubeImportChoices.unchosen
        chosen.source = .foreverLMPlaylist
        chosen.foreverLMPlaylistID = "PLtwo"
        let updated = YouTubeAccountList.setting(chosen, forAccount: "UCtwo", in: listed)
        #expect(updated[0].choices == .unchosen)
        #expect(updated[1].choices == chosen)
        #expect(YouTubeAccountList.setting(chosen, forAccount: "UCmissing", in: listed) == listed)
    }

    // MARK: - Adopting the single connection

    @Test("the old connection becomes the first account with what it imported")
    func adoptionCarriesChoices() {
        let choices = YouTubeImportChoices(
            source: .likedVideos,
            foreverLMPlaylistID: nil,
            likedPolicy: .futureOnly,
            likedCutoff: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let adopted = YouTubeAccountList.connecting(id: "UCzara", title: "Zara Holt Lab", choicesIfNew: choices, into: [])
        #expect(adopted.count == 1)
        #expect(adopted[0].choices == choices)
    }

    @Test("adopting on a second Mac never overwrites an account the first Mac already listed")
    func adoptionKeepsAnExistingAccount() {
        let listed = [account("UCzara", "Zara Holt Lab", source: .foreverLMPlaylist, playlistID: "PLzara")]
        let again = YouTubeAccountList.connecting(
            id: "UCzara",
            title: "Zara Holt Lab",
            choicesIfNew: YouTubeImportChoices(source: .likedVideos, foreverLMPlaylistID: nil, likedPolicy: .importExisting, likedCutoff: nil),
            into: listed
        )
        #expect(again == listed)
    }

    @Test("the old preferences and followed groups are read into the first account's choices")
    func legacyChoicesFromPreferencesAndGroups() {
        let likedGroupID = StudioViewModel.youtubePlaylistGroupID(for: YouTubeService.likedVideosPlaylistURL)
        let likedOnly = [likedGroupID: VideoPlaylistMetadata(
            title: "Liked videos",
            playlistURL: YouTubeService.likedVideosPlaylistURL,
            autoImport: true,
            connectorKind: YouTubeImportSource.likedVideos.connectorKind
        )]
        // Liked videos mirrored before the policy existed: existing and future likes.
        let unset = StudioViewModel.legacyYouTubeChoices(groups: likedOnly, policyRaw: nil, cutoff: 0)
        #expect(unset.source == .likedVideos)
        #expect(unset.likedPolicy == .importExisting)
        #expect(unset.likedCutoff == nil)

        let chosen = StudioViewModel.legacyYouTubeChoices(groups: likedOnly, policyRaw: "futureOnly", cutoff: 1_700_000_000)
        #expect(chosen.likedPolicy == .futureOnly)
        #expect(chosen.likedCutoff == Date(timeIntervalSince1970: 1_700_000_000))

        let playlist = ["playlist_x": VideoPlaylistMetadata(
            title: "ForeverLM",
            playlistURL: YouTubeService.playlistURL(forID: "PLzara"),
            autoImport: true,
            connectorKind: YouTubeImportSource.foreverLMPlaylist.connectorKind
        )]
        let named = StudioViewModel.legacyYouTubeChoices(groups: playlist, policyRaw: nil, cutoff: 0)
        #expect(named.source == .foreverLMPlaylist)
        #expect(named.foreverLMPlaylistID == "PLzara")
        #expect(named.likedPolicy == .undecided)

        let nothing = StudioViewModel.legacyYouTubeChoices(groups: [:], policyRaw: nil, cutoff: 0)
        #expect(nothing == .unchosen)
    }

    // MARK: - Which account a call means

    @Test("an unnamed call means the only connected account")
    func selectionOfTheOnlyAccount() throws {
        let only = [account("UCzara", "Zara Holt Lab")]
        let picked = try MCPDataStore.pluginPick(only, requested: nil, id: \.id, label: \.title, what: "YouTube account", argument: "account")
        #expect(picked.id == "UCzara")
    }

    @Test("an unnamed call with several accounts names them and asks for one")
    func selectionWithSeveralAccountsNamesThem() {
        let several = [account("UCzara", "Zara Holt Lab"), account("UCbench", "Bench Notes")]
        do {
            _ = try MCPDataStore.pluginPick(several, requested: nil, id: \.id, label: \.title, what: "YouTube account", argument: "account")
            Issue.record("Two accounts and no name should not pick one.")
        } catch let error as MCPError {
            let message = error.localizedDescription
            #expect(message.contains("pass account"))
            #expect(message.contains("Zara Holt Lab"))
            #expect(message.contains("Bench Notes"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("a call names an account by channel title or id, ignoring case")
    func selectionByTitleOrID() throws {
        let several = [account("UCzara", "Zara Holt Lab"), account("UCbench", "Bench Notes")]
        let byTitle = try MCPDataStore.pluginPick(several, requested: "bench notes", id: \.id, label: \.title, what: "YouTube account", argument: "account")
        #expect(byTitle.id == "UCbench")
        let byID = try MCPDataStore.pluginPick(several, requested: "UCzara", id: \.id, label: \.title, what: "YouTube account", argument: "account")
        #expect(byID.title == "Zara Holt Lab")
        #expect(throws: MCPError.self) {
            _ = try MCPDataStore.pluginPick(several, requested: "Acme Lab", id: \.id, label: \.title, what: "YouTube account", argument: "account")
        }
    }

    // MARK: - What each account imports

    @Test("each account's own policy filters its own likes, and a video two accounts like comes in once")
    func perAccountPolicyShapesTheMirror() {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let everything = account("UCone", "One", source: .likedVideos, policy: .importExisting)
        let fromNow = account("UCtwo", "Two", source: .likedVideos, policy: .futureOnly, cutoff: cutoff)
        let plan = StudioViewModel.likedMirrorPlan(
            [
                .init(account: everything, feed: ([item("shared"), item("old", likedAt: Date(timeIntervalSince1970: 10))], true)),
                .init(account: fromNow, feed: ([
                    item("shared", likedAt: Date(timeIntervalSince1970: 2_000)),
                    item("older", likedAt: Date(timeIntervalSince1970: 10)),
                    item("fresh", likedAt: Date(timeIntervalSince1970: 3_000)),
                ], true)),
            ],
            accountCount: 2,
            existingURLKeys: []
        )
        #expect(plan.importItems.map(\.videoId) == ["shared", "old", "fresh"])
        #expect(plan.fetchedCount == 5)
        #expect(plan.fetchedAny)
    }

    @Test("videos the library already holds come through a future-only account")
    func futureOnlyKeepsKnownVideos() {
        let fromNow = account("UCone", "One", source: .likedVideos, policy: .futureOnly, cutoff: Date(timeIntervalSince1970: 1_000))
        let known = item("known", likedAt: Date(timeIntervalSince1970: 10))
        let plan = StudioViewModel.likedMirrorPlan(
            [.init(account: fromNow, feed: ([known], true))],
            accountCount: 1,
            existingURLKeys: [StudioViewModel.sourceURLIdentityKey(known.url)]
        )
        #expect(plan.importItems.map(\.videoId) == ["known"])
    }

    @Test("unliked videos are archived only for one account whose whole feed was read")
    func archivingNeedsOneCompleteAccount() {
        let one = account("UCone", "One", source: .likedVideos, policy: .importExisting)
        let two = account("UCtwo", "Two", source: .likedVideos, policy: .importExisting)
        let liked = item("liked")

        let sole = StudioViewModel.likedMirrorPlan([.init(account: one, feed: ([liked], true))], accountCount: 1, existingURLKeys: [])
        #expect(sole.stillLikedURLKeys == [StudioViewModel.sourceURLIdentityKey(liked.url)])

        // A feed cut short proves nothing about what is missing from it.
        let truncated = StudioViewModel.likedMirrorPlan([.init(account: one, feed: ([liked], false))], accountCount: 1, existingURLKeys: [])
        #expect(truncated.stillLikedURLKeys == nil)

        // Liked rows carry no account: with a second account listed, absence
        // from one feed says nothing about the other's rows.
        let shared = StudioViewModel.likedMirrorPlan(
            [.init(account: one, feed: ([liked], true)), .init(account: two, feed: ([liked], true))],
            accountCount: 2,
            existingURLKeys: []
        )
        #expect(shared.stillLikedURLKeys == nil)
        let listedButNotFetched = StudioViewModel.likedMirrorPlan([.init(account: one, feed: ([liked], true))], accountCount: 2, existingURLKeys: [])
        #expect(listedButNotFetched.stillLikedURLKeys == nil)
    }

    @Test("a failing account does not stop the others and blocks archiving")
    func aFailedAccountLeavesTheRestImporting() {
        let one = account("UCone", "One", source: .likedVideos, policy: .importExisting)
        let two = account("UCtwo", "Two", source: .likedVideos, policy: .importExisting)
        let plan = StudioViewModel.likedMirrorPlan(
            [.init(account: one, feed: nil), .init(account: two, feed: ([item("fine")], true))],
            accountCount: 2,
            existingURLKeys: []
        )
        #expect(plan.importItems.map(\.videoId) == ["fine"])
        #expect(plan.stillLikedURLKeys == nil)

        let allFailed = StudioViewModel.likedMirrorPlan([.init(account: one, feed: nil)], accountCount: 1, existingURLKeys: [])
        #expect(!allFailed.fetchedAny)
        #expect(allFailed.stillLikedURLKeys == nil)
    }

    @Test("accounts mark one shared Liked group and one playlist group each")
    func sourceGroupsFollowTheAccounts() {
        let likedGroupID = StudioViewModel.youtubePlaylistGroupID(for: YouTubeService.likedVideosPlaylistURL)
        let kinds = StudioViewModel.youtubeSourceGroupKinds(accounts: [
            account("UCone", "One", source: .likedVideos),
            account("UCtwo", "Two", source: .likedVideos),
            account("UCthree", "Three", source: .foreverLMPlaylist, playlistID: "PLthree"),
            account("UCfour", "Four", source: .foreverLMPlaylist, playlistID: "PLfour"),
            account("UCfive", "Five"),
        ])
        #expect(kinds.count == 3)
        #expect(kinds[likedGroupID] == YouTubeImportSource.likedVideos.connectorKind)
        #expect(kinds[StudioViewModel.youtubePlaylistGroupID(for: YouTubeService.playlistURL(forID: "PLthree"))]
            == YouTubeImportSource.foreverLMPlaylist.connectorKind)
        #expect(kinds[StudioViewModel.youtubePlaylistGroupID(for: YouTubeService.playlistURL(forID: "PLfour"))]
            == YouTubeImportSource.foreverLMPlaylist.connectorKind)

        // With no account reading Liked videos, its group is no longer marked.
        let released = StudioViewModel.youtubeSourceGroupKinds(accounts: [account("UCone", "One", source: .foreverLMPlaylist, playlistID: "PLone")])
        #expect(released[likedGroupID] == nil)
    }

    // MARK: - The Plugins list

    @Test("the plugins list names each source once however many accounts read it")
    func chipSummary() {
        #expect(PluginScopeCopy.youtube(sources: ["Liked videos", "Liked videos"], followedChannels: 0) == "Imports your Liked videos.")
        #expect(PluginScopeCopy.youtube(sources: ["Liked videos", "ForeverLM playlist"], followedChannels: 0)
            == "Imports your Liked videos and ForeverLM playlist.")
        #expect(PluginScopeCopy.youtube(sources: [], followedChannels: 2) == "Follows 2 channels.")
    }
}
