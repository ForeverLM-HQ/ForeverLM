import Foundation
import Testing
@testable import ForeverLM

/// The Space on the phone, against the Mac's own rules (docs/docs-design.md, "The Space"): which records
/// are pages, which place lists which, the pins, spaces and subpages read from the Mac's rows, daily
/// notes, and the Recents the phone keeps in the Mac's shape.
@MainActor
@Suite("The Space on the phone")
struct MobileSpaceModelsTests {
    // MARK: - Fixtures

    private static func page(_ id: String, title: String? = nil, kind: String = "doc", created: TimeInterval = 0, edited: TimeInterval? = nil,
                             teamID: String? = nil, trashed: Bool = false, hidden: Bool = false, linkedURL: String? = nil) -> MobileSpacePage {
        MobileSpacePage(
            id: id, title: title ?? id, kind: kind, notebookID: nil, teamID: teamID, isDraft: false, isTrashed: trashed, isHidden: hidden,
            createdAt: Date(timeIntervalSince1970: created), editedAt: Date(timeIntervalSince1970: edited ?? created), bodyRevision: nil,
            linkedURL: linkedURL, isDailyNote: teamID == nil && DailyNote.isDailyNoteID(id),
            isEditableMarkdown: teamID == nil && linkedURL == nil && kind != MobileSpaceListing.readingKind
        )
    }

    private static let googleDoc = "https://docs.google.com/document/d/abc/edit"
    private static let claudeArtifact = "https://claude.ai/code/artifact/0123abcd-4567-89ef-0123-456789abcdef"

    // MARK: - Which records are pages

    @Test("Every record the Mac's Space lists is a page here; a Notes Doc, a file, a picture, an animation, an overview, a deck and a member's draft are not")
    func spaceRecords() {
        for kind in ["doc", "linkedDoc", "site", "report", "explainer", "lesson", "skill", "mnemonic_reading", "kindNoBuildKnows"] {
            #expect(MobileSpaceListing.isSpaceRecord(id: "a1", kind: kind), "\(kind)")
        }
        for kind in ["notes", "file", "picture", "animation", "audioOverview", "audio_overview", "flashcards"] {
            #expect(!MobileSpaceListing.isSpaceRecord(id: "a1", kind: kind), "\(kind)")
        }
        for id in ["draft:a1", "draft_a1", "notes:nb1", "file:nb1:abc", "picture:img1", MemoryCard.draftDeckID(sourceID: "src1"), ""] {
            #expect(!MobileSpaceListing.isSpaceRecord(id: id, kind: "doc"), "\(id)")
        }
    }

    @Test("A page is a page, a Google Doc, a site or a reading as SpaceCatalog sorts the Mac's records")
    func spaceKinds() {
        #expect(Self.page("p").spaceKind == .page)
        #expect(Self.page("g", kind: "linkedDoc", linkedURL: Self.googleDoc).spaceKind == .googleDoc)
        #expect(Self.page("s", kind: "linkedDoc", linkedURL: Self.claudeArtifact).spaceKind == .site)
        #expect(Self.page("l", kind: "site", linkedURL: "foreverlm-site://site-1/").spaceKind == .site)
        #expect(Self.page("u", kind: "linkedDoc", linkedURL: "https://example.org/page").spaceKind == .page, "a link no build knows is a page")
        #expect(Self.page("r", kind: MobileSpaceListing.readingKind).spaceKind == .reading)
        // The Mac sorts the same records the same way.
        let now = Date()
        for (url, kind) in [(Self.googleDoc, MobileSpacePage.Kind.googleDoc), (Self.claudeArtifact, .site)] {
            let record = ArtifactRecord(id: "x", title: "x", homeNotebookID: nil, linkedNotebookIDs: [], linkedURL: url, createdAt: now, updatedAt: now)
            #expect((record.linkedKind == .googleDoc) == (kind == .googleDoc))
            #expect((record.section == .sites) == (kind == .site))
        }
    }

    @Test("A new page is titled as the Mac's, and a title is trimmed and cut")
    func titles() {
        #expect(MobileSpaceListing.untitledTitle == ArtifactPlaceholderTitle.current)
        #expect(MobileSpaceListing.cleanedTitle("  Cells \n") == "Cells")
        #expect(MobileSpaceListing.cleanedTitle(" \n ") == nil)
        #expect(MobileSpaceListing.cleanedTitle(String(repeating: "a", count: 600))?.count == MobileSpaceListing.titleCharacterLimit)
    }

    // MARK: - Places

    @Test("Each place lists what the Mac's lists: Trash only what is in it, a space only its pages, a row naming a deleted space read past")
    func placesList() {
        let organization = MobileSpaceOrganization(rows: [
            "pageSpace.psp-1": "🧪 Lab", "page.space.p": "psp-1", "page.space.g": "psp-gone",
        ])
        let page = Self.page("p")
        let google = Self.page("g", kind: "linkedDoc", linkedURL: Self.googleDoc)
        let site = Self.page("s", kind: "linkedDoc", linkedURL: Self.claudeArtifact)
        let reading = Self.page("r", kind: MobileSpaceListing.readingKind)
        let team = Self.page("t", teamID: "s1")
        let trashed = Self.page("x", trashed: true)
        let all = [page, google, site, reading, team, trashed]
        func ids(_ place: MobileSpacePlace) -> Set<String> {
            Set(all.filter { MobileSpaceListing.lists(place, $0, organization: organization) }.map(\.id))
        }
        #expect(ids(.all) == ["p", "g", "s", "r", "t"])
        #expect(ids(.pages) == ["p", "r", "t"])
        #expect(ids(.sites) == ["s"])
        #expect(ids(.drive) == ["g"])
        #expect(ids(.team("s1")) == ["t"])
        #expect(ids(.space("psp-1")) == ["p"])
        #expect(ids(.space("psp-gone")).isEmpty, "a row naming a deleted space is read past")
        #expect(ids(.trash) == ["x"])
    }

    @Test("A hidden page is listed in Trash alone, a daily note only to a search, and a search matches the title")
    func filters() {
        let hidden = Self.page("h", hidden: true)
        #expect(!MobileSpaceListing.passesFilters(hidden, in: .all, query: ""))
        #expect(MobileSpaceListing.passesFilters(hidden, in: .trash, query: ""))
        let daily = Self.page("daily-2026-10-07", title: "October 7th, 2026")
        #expect(daily.isDailyNote)
        #expect(!MobileSpaceListing.passesFilters(daily, in: .pages, query: " "))
        #expect(MobileSpaceListing.passesFilters(daily, in: .pages, query: "october"))
        // The Mac's own rule says the same, and a day with writing is listed on both.
        #expect(NotesGraphDocListing.isListed(id: daily.id, title: daily.title, createdAt: daily.createdAt,
                                              updatedAt: daily.editedAt, searchQuery: "") == false)
        let written = Self.page("daily-2026-10-07", title: "Shifting from virtual cells to mitochondria")
        #expect(MobileSpaceListing.passesFilters(written, in: .pages, query: ""))
        let page = Self.page("p", title: "Membrane Potential")
        #expect(MobileSpaceListing.passesFilters(page, in: .all, query: "membrane"))
        #expect(!MobileSpaceListing.passesFilters(page, in: .all, query: "mitochondria"))
    }

    @Test("Date created is the default order, then activity and name; a tie goes by id")
    func sorting() {
        let a = Self.page("a", title: "Beta", created: 1, edited: 30)
        let b = Self.page("b", title: "alpha", created: 3, edited: 10)
        let c = Self.page("c", title: "Gamma", created: 3, edited: 20)
        #expect(MobileSpaceListing.sorted([a, b, c], by: .created).map(\.id) == ["b", "c", "a"])
        #expect(MobileSpaceListing.sorted([a, b, c], by: .activity).map(\.id) == ["a", "c", "b"])
        #expect(MobileSpaceListing.sorted([a, b, c], by: .name).map(\.id) == ["b", "a", "c"])
        #expect(MobileSpaceSort.allCases.map(\.rawValue) == SpaceSort.allCases.map(\.rawValue), "the Mac's orders")
        let organization = MobileSpaceOrganization()
        #expect(MobileSpaceListing.pages(in: .all, from: [a, b, c, Self.page("t", trashed: true)], organization: organization).map(\.id) == ["b", "c", "a"])
        #expect(MobileSpaceListing.date(of: a, in: .trash, sort: .created) == a.editedAt, "Trash shows when it went there")
        #expect(MobileSpaceListing.date(of: a, in: .all, sort: .created) == a.createdAt)
    }

    @Test("Plan lists the learner's quarter and week plans, out of Trash, as the Mac's Plan place opens them")
    func planPlace() {
        let organization = MobileSpaceOrganization()
        let quarter = Self.page("plan-2026-q4", title: "Q4 2026")
        let week = Self.page("plan-2026-w45", title: "Week of November 2nd, 2026")
        let teamCopy = Self.page("plan-2026-q3", teamID: "s1")
        let trashed = Self.page("plan-2026-q2", trashed: true)
        let other = Self.page("plan-day")
        let all = [quarter, week, teamCopy, trashed, other]
        #expect(quarter.isPlan && week.isPlan)
        #expect(!teamCopy.isPlan, "a plan is My Library's")
        #expect(!other.isPlan)
        let listed = Set(all.filter { MobileSpaceListing.lists(.plan, $0, organization: organization) }.map(\.id))
        #expect(listed == ["plan-2026-q4", "plan-2026-w45"])
        #expect(!MobileSpaceListing.canNest(quarter), "a plan is reached by its period, never nested")
        #expect(MobileSpacePlace.places.contains(.plan))
        #expect(!MobileSpaceListing.nests(.plan, query: "", organization: organization))
    }

    @Test("A place's key round-trips and is the key the Mac's window keeps for the same place")
    func placeKeys() {
        let places: [MobileSpacePlace] = MobileSpacePlace.places + [.trash, .team("team-1"), .space("psp-1")]
        for place in places {
            #expect(MobileSpacePlace(key: place.key) == place)
        }
        for place in places {
            #expect(SpaceDestination(key: place.key).key == place.key)
        }
        #expect(MobileSpacePlace(key: "images") == .all, "the pictures are the Mac's")
        #expect(MobileSpacePlace(key: "space:") == .all)
    }

    @Test("A page open from a space keeps the space lit; else it is listed by what it is")
    func listingPlace() {
        let organization = MobileSpaceOrganization(rows: ["pageSpace.psp-1": "Lab", "page.space.p": "psp-1"])
        let page = Self.page("p")
        #expect(MobileSpacePlace.listing(page, within: .space("psp-1"), organization: organization) == .space("psp-1"))
        #expect(MobileSpacePlace.listing(page, organization: organization) == .pages)
        #expect(MobileSpacePlace.listing(Self.page("g", kind: "linkedDoc", linkedURL: Self.googleDoc), organization: organization) == .drive)
        #expect(MobileSpacePlace.listing(Self.page("x", trashed: true), within: .space("psp-1"), organization: organization) == .trash)
    }

    // MARK: - The grouping

    @Test("The grouping reads the Mac's rows as the Mac does: spaces by name, pins and parents by page")
    func organizationFromRows() {
        let rows: [String: Any] = [
            "pageSpace.psp-b": "🧪 Lab", "pageSpace.psp-a": "Archive", "pageSpace.psp-empty": "  ",
            "page.space.p1": "psp-b", "page.pinned.p1": "1700000000", "page.pinned.p2": NSNumber(value: 1_800_000_000),
            "page.pinned.bad": "soon", "page.parent.p2": "p1", "page.parent.self": "self", "chat.model": "x",
        ]
        let organization = MobileSpaceOrganization(rows: rows)
        #expect(organization.spaces == PageSpaces(rows: rows).ordered)
        #expect(organization.spaces.map(\.id) == ["psp-a", "psp-b"])
        #expect(organization.spaceID(ofPage: "p1") == "psp-b")
        #expect(organization.pinnedAtByPage == ["p1": 1_700_000_000, "p2": 1_800_000_000])
        #expect(organization.parentByPage == ["p2": "p1"])
        #expect(organization.pageSpaces == PageSpaces(rows: rows))
        #expect(organization.pins == PagePins(rows: rows))
        #expect(organization.parents == PageParents(rows: rows))
        #expect(Set(MobileSpaceOrganization.preferenceKeyPrefixes) == [
            PageSpaces.namePreferenceKeyPrefix, PageSpaces.membershipPreferenceKeyPrefix, PageSpaces.trashPreferenceKeyPrefix,
            PagePins.preferenceKeyPrefix, PageParents.preferenceKeyPrefix,
        ])
        let renamed = organization.settingName("Lab", for: "psp-b").settingSpace(nil, for: "p1").settingPin(nil, for: "p1").settingParent(nil, for: "p2")
        #expect(renamed.space("psp-b")?.name == "Lab")
        #expect(renamed.spaceIDByPage["p1"] == nil && !renamed.isPinned("p1") && renamed.parentByPage.isEmpty)
    }

    @Test("Pinned lists the learner's own pages, the newest pin first, never a team's, a trashed or a hidden one")
    func pinned() {
        let organization = MobileSpaceOrganization(rows: [
            "page.pinned.a": "10", "page.pinned.b": "30", "page.pinned.c": "20", "page.pinned.team": "40", "page.pinned.gone": "50",
            "page.pinned.trashed": "60", "page.pinned.hidden": "70",
        ])
        let pages = [Self.page("a"), Self.page("b"), Self.page("c"), Self.page("team", teamID: "s1"), Self.page("trashed", trashed: true),
                     Self.page("hidden", hidden: true)]
        #expect(MobileSpaceListing.pinned(pages, organization: organization).map(\.id) == ["b", "c", "a"])
        #expect(!MobileSpaceListing.canPin(Self.page("team", teamID: "s1")))
        #expect(PagePins.rowValue(at: Date(timeIntervalSince1970: 1_700_000_000.9)) == "1700000000", "the Mac's row value")
    }

    @Test("Only the learner's own Markdown pages nest; a daily note, a linked page, a reading and a team's page do not")
    func nesting() {
        #expect(MobileSpaceListing.canNest(Self.page("p")))
        #expect(!MobileSpaceListing.canNest(Self.page("daily-2026-10-07")))
        #expect(!MobileSpaceListing.canNest(Self.page("g", kind: "linkedDoc", linkedURL: Self.googleDoc)))
        #expect(!MobileSpaceListing.canNest(Self.page("r", kind: MobileSpaceListing.readingKind)))
        #expect(!MobileSpaceListing.canNest(Self.page("t", teamID: "s1")))
        #expect(MobileSpaceListing.canFileInSpace(Self.page("g", kind: "linkedDoc", linkedURL: Self.googleDoc)), "a Google Doc files in a space")
        #expect(!MobileSpaceListing.canFileInSpace(Self.page("t", teamID: "s1")))
    }

    @Test("Subpages read as the Mac's tree: children in order, the trail from the top, a gone or trashed parent leaves its child on top, a cycle cut")
    func subpages() {
        let pages = [Self.page("a", created: 5), Self.page("b", created: 4), Self.page("c", created: 3), Self.page("d", created: 2),
                     Self.page("x", created: 1, trashed: true), Self.page("y", created: 0)]
        let organization = MobileSpaceOrganization(rows: [
            "page.parent.b": "a", "page.parent.c": "b", "page.parent.d": "a", "page.parent.y": "x",
        ])
        #expect(MobileSpaceListing.children(of: "a", in: pages, organization: organization).map(\.id) == ["b", "d"])
        #expect(MobileSpaceListing.parent(of: "c", in: pages, organization: organization)?.id == "b")
        #expect(MobileSpaceListing.ancestors(of: "c", in: pages, organization: organization).map(\.id) == ["a", "b"])
        #expect(MobileSpaceListing.parent(of: "y", in: pages, organization: organization) == nil, "a trashed parent leaves it on top")
        #expect(MobileSpaceListing.parentCandidates(for: "b", in: pages, organization: organization).map(\.id) == ["a", "d", "y"],
                "never itself, a page under it, or one in Trash")
        let cycle = MobileSpaceOrganization(rows: ["page.parent.a": "b", "page.parent.b": "a"])
        let tree = MobileSpaceListing.tree(pages, organization: cycle)
        #expect(tree.parentID(ofPage: "a") == nil, "cut at the smallest id, as on every device")
        #expect(tree.parentID(ofPage: "b") == "a")
    }

    @Test("A list nests subpages under an open parent at their depth, flat when searched or in a place that does not nest")
    func entries() {
        let pages = [Self.page("a", created: 5), Self.page("b", created: 4), Self.page("c", created: 3), Self.page("g", kind: "linkedDoc",
                     created: 2, linkedURL: Self.googleDoc)]
        let organization = MobileSpaceOrganization(rows: ["page.parent.b": "a", "page.parent.c": "b"])
        #expect(MobileSpaceListing.nests(.pages, query: "", organization: organization))
        #expect(!MobileSpaceListing.nests(.pages, query: "x", organization: organization))
        #expect(!MobileSpaceListing.nests(.trash, query: "", organization: organization))
        #expect(!MobileSpaceListing.nests(.all, query: "", organization: MobileSpaceOrganization()))
        let closed = MobileSpaceListing.entries(pages, nests: true, organization: organization, expanded: [])
        #expect(closed.map(\.id) == ["a", "g"])
        #expect(closed.first?.hasChildren == true && closed.first?.isExpanded == false)
        let open = MobileSpaceListing.entries(pages, nests: true, organization: organization, expanded: ["a", "b"])
        #expect(open.map(\.id) == ["a", "b", "c", "g"])
        #expect(open.map(\.level) == [0, 1, 2, 0])
        #expect(MobileSpaceListing.entries(pages, nests: false, organization: organization, expanded: ["a"]).map(\.id) == ["a", "b", "c", "g"])
    }

    @Test("Daily notes list newest day first, out of Trash, by the Mac's ids")
    func dailyNotes() {
        let pages = [Self.page("daily-2026-10-05"), Self.page("daily-2026-10-07"), Self.page("daily-2026-10-06", trashed: true), Self.page("p"),
                     Self.page("daily-2026-02-30")]
        #expect(MobileSpaceListing.dailyNotes(pages).map(\.id) == ["daily-2026-10-07", "daily-2026-10-05"])
        #expect(DailyNote.title(forDayKey: "2026-10-07") == "October 7th, 2026")
    }

    // MARK: - Recents

    @Test("Recents keep the latest opening first, once, within the Mac's capacity, in the shape the Mac's Recents read")
    func recents() throws {
        let suite = "MobileSpaceModelsTests.recents.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = MobileSpaceRecents(defaults: defaults)
        recents.note("a", at: Date(timeIntervalSince1970: 1))
        recents.note("b", at: Date(timeIntervalSince1970: 2))
        recents.note("a", at: Date(timeIntervalSince1970: 3))
        #expect(recents.items.map(\.id) == ["a", "b"])
        #expect(MobileSpaceRecents(defaults: defaults).items == recents.items, "read back across launches")
        defaults.set(defaults.array(forKey: MobileSpaceRecents.preferenceKey), forKey: SpaceRecents.preferenceKey)
        #expect(SpaceRecents.load(from: defaults).map(\.id) == ["a", "b"], "the Mac's shape")
        #expect(MobileSpaceRecents.capacity == SpaceRecents.capacity)

        let shown = recents.shown(among: [Self.page("a", trashed: true), Self.page("b")])
        #expect(shown.map(\.id) == ["b"], "a trashed or gone page is not offered")
        recents.forget("a")
        #expect(recents.items.map(\.id) == ["b"])
        for index in 0..<(MobileSpaceRecents.capacity + 5) { recents.note("r\(index)") }
        #expect(recents.items.count == MobileSpaceRecents.capacity)
        #expect(recents.items.first?.id == "r\(MobileSpaceRecents.capacity + 4)")

        defaults.set("not a list", forKey: MobileSpaceRecents.preferenceKey)
        #expect(MobileSpaceRecents(defaults: defaults).items.isEmpty)
        defaults.set([["k": "image", "id": "i", "t": 1.0], ["k": "artifact", "id": "p", "t": 2.0]], forKey: MobileSpaceRecents.preferenceKey)
        #expect(MobileSpaceRecents(defaults: defaults).items.map(\.id) == ["p"], "a Mac's picture is not a page")
    }
}
