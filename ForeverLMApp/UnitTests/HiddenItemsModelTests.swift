import Foundation
import Testing
@testable import ForeverLM

@Suite("Hidden items footer")
struct HiddenItemsModelTests {
    @Test("The footer counts groups and lone items in the tab's own nouns")
    func footerTitleReadsInTheTabsNouns() {
        #expect(HiddenItemsModel.footerTitle(groupCount: 3, groupNoun: "show", itemCount: 0, itemNoun: "episode") == "3 hidden shows")
        #expect(HiddenItemsModel.footerTitle(groupCount: 1, groupNoun: "show", itemCount: 2, itemNoun: "episode") == "1 hidden show, 2 episodes")
        #expect(HiddenItemsModel.footerTitle(groupCount: 0, groupNoun: "show", itemCount: 1, itemNoun: "episode") == "1 hidden episode")
        #expect(HiddenItemsModel.footerTitle(groupCount: 0, groupNoun: nil, itemCount: 4, itemNoun: "paper") == "4 hidden papers")
        #expect(HiddenItemsModel.footerTitle(groupCount: 2, groupNoun: "channel or playlist", itemCount: 0, itemNoun: "video") == "2 hidden channels or playlists")
        // Nothing hidden: the caller drops the row.
        #expect(HiddenItemsModel.footerTitle(groupCount: 0, groupNoun: "show", itemCount: 0, itemNoun: "episode").isEmpty)
    }

    @Test("A search counts hidden shows by their own title or any hidden episode's")
    func matchCountFollowsThePagesFilter() {
        let drive = HiddenItemsModel.GroupEntry(
            id: "drive",
            title: "The Peter Attia Drive",
            hiddenEpisodes: [
                .init(id: "e1", title: "#402 ‒ NMR blood analysis", unhide: {}, remove: nil),
                .init(id: "e2", title: "#403 ‒ Peptides", unhide: {}, remove: nil),
            ],
            unhide: {},
            remove: nil
        )
        let rogan = HiddenItemsModel.GroupEntry(id: "rogan", title: "The Joe Rogan Experience", hiddenEpisodes: [], unhide: {}, remove: nil)
        let lone = HiddenItemsModel.ItemEntry(id: "x", title: "Attia on peptides, a stray episode", unhide: {}, remove: nil)
        let model = HiddenItemsModel(groupsTitle: "Shows", itemsTitle: "Episodes", groups: [drive, rogan], items: [lone])

        #expect(model.searchableCount == 5)
        #expect(model.matchCount(for: "") == 5)
        #expect(model.matchCount(for: "attia") == 2)
        #expect(model.matchCount(for: "peptides") == 2)
        #expect(model.matchCount(for: "nmr") == 1)
        #expect(model.matchCount(for: "rogan") == 1)
        #expect(model.matchCount(for: "huberman") == 0)
    }

    @Test("A show the search reached only through an episode opens to just the matching episodes")
    func episodeMatchesOpenTheShowToTheMatches() {
        let drive = HiddenItemsModel.GroupEntry(
            id: "drive",
            title: "The Peter Attia Drive",
            hiddenEpisodes: [
                .init(id: "e1", title: "#402 ‒ NMR blood analysis", unhide: {}, remove: nil),
                .init(id: "e2", title: "#403 ‒ Peptides", unhide: {}, remove: nil),
            ],
            unhide: {},
            remove: nil
        )
        let model = HiddenItemsModel(groupsTitle: "Shows", itemsTitle: "Episodes", groups: [drive], items: [])

        // The search found an episode, not the show: the row opens on the match alone.
        #expect(model.matchesOnlyThroughEpisodes(drive, query: "nmr"))
        #expect(model.episodes(of: drive, matching: "nmr").map(\.id) == ["e1"])
        #expect(model.episodes(of: drive, matching: " NMR ").map(\.id) == ["e1"])

        // The show itself matches: it stays closed and lists every hidden episode when opened.
        #expect(!model.matchesOnlyThroughEpisodes(drive, query: "attia"))
        #expect(model.episodes(of: drive, matching: "attia").map(\.id) == ["e1", "e2"])

        // No search, or a search nothing under the show matches: nothing is filtered.
        #expect(!model.matchesOnlyThroughEpisodes(drive, query: ""))
        #expect(model.episodes(of: drive, matching: "").map(\.id) == ["e1", "e2"])
        #expect(!model.matchesOnlyThroughEpisodes(drive, query: "huberman"))
        #expect(model.episodes(of: drive, matching: "huberman").map(\.id) == ["e1", "e2"])
    }

    @Test("Every tab names what it hides")
    func footerNounsCoverEveryTab() {
        for tab in StudioSidebarTab.allCases {
            let nouns = HiddenItemsModel.footerNouns(for: tab)
            #expect(!nouns.item.isEmpty, "\(tab)")
        }
        #expect(HiddenItemsModel.footerNouns(for: .podcasts).group == "show")
        #expect(HiddenItemsModel.footerNouns(for: .papers).group == nil)
    }
}
