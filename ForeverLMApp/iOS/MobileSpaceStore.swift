import Foundation
import Observation
import OSLog

// MARK: - The Space on the phone

/// The Space on the iPhone and iPad (docs/docs-design.md, "The Space"; the product owner, 2026-10-07: "yes build
/// the space on iphone too", "docs etc all has to work there too"): every page the learner holds, their
/// own spaces of pages, pins and subpages, read from the phone's replica and written through its
/// generation-2 writer as the Mac and the web write them. The screens draw from `pages` and
/// `organization` with `MobileSpaceListing`'s rules; this store reads and writes, nothing more.
///
/// Generation 2 only (§13.6): before this install has switched to the replica the Space is unavailable
/// (`isAvailable` false, every act `.unavailable`), and nothing reaches the old container.
///
/// The store reads the library again when the replica changes (`.mobileReplicaDidChange`, coalesced),
/// and publishes each of its own writes as soon as it is made, read back from the replica, so a list
/// never waits for a sync round. A read that started before one of its writes is dropped, never
/// published over it: the write's own change notice reads again.
///
/// A page's text is saved only over the revision the editor opened (`saveBody(_:of:expectedRevision:)`):
/// sync keeps the server's body when two devices wrote one, so a save over a body that moved meanwhile
/// is refused as `.conflict` with the text the page holds now, never written over it.
@MainActor
@Observable
final class MobileSpaceStore {
    /// What the store reads and writes with: the session's writer, and its satellites for page bodies.
    struct Backend: Sendable {
        let writer: MobileRecordWriter
        let satellites: MobileSatellites
    }

    /// The backend now; nil while the Space is unavailable (no session yet).
    typealias Connect = @Sendable () async -> Backend?

    static let shared = MobileSpaceStore()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileSpaceStore")

    /// Every page the Space lists, those in Trash and those hidden included, the newest made first.
    private(set) var pages: [MobileSpacePage] = []
    /// The learner's spaces of pages, pins and subpages.
    private(set) var organization = MobileSpaceOrganization()
    /// The teams the phone holds, listed under Spaces after the learner's own.
    private(set) var teams: [MobileSpaceTeam] = []
    /// False until the phone's session runs.
    private(set) var isAvailable = false
    private(set) var isLoading = false

    @ObservationIgnored private let connect: Connect
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let recents: MobileSpaceRecents?
    /// How many of its own writes the store has published: a read that started before one is dropped.
    @ObservationIgnored private var published = 0
    @ObservationIgnored private var loads = 0
    @ObservationIgnored private var reloads: MobileReloadCoalescer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// The running session's writer and satellites.
    nonisolated static let sessionBackend: Connect = {
        guard let session = await MobileSyncSession.startIfEnabled() else { return nil }
        return Backend(writer: session.writer, satellites: session.satellites)
    }

    /// `observesReplica` reads the library again whenever the replica changes; `recents` forgets a page
    /// deleted for good (the shared Recents when nil).
    init(connect: @escaping Connect = MobileSpaceStore.sessionBackend, now: @escaping @Sendable () -> Date = { Date() },
         recents: MobileSpaceRecents? = nil, observesReplica: Bool = true) {
        self.connect = connect
        self.now = now
        self.recents = recents
        guard observesReplica else { return }
        reloads = MobileReloadCoalescer { [weak self] in await self?.refresh() }
        observer = NotificationCenter.default.addObserver(forName: .mobileReplicaDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloads?.changed() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Reading

    /// Reads the pages and the grouping again from the replica. A failed read leaves what was read last.
    func refresh() async {
        guard let backend = await connect() else {
            isAvailable = false
            if !pages.isEmpty { pages = [] }
            if organization != MobileSpaceOrganization() { organization = MobileSpaceOrganization() }
            if !teams.isEmpty { teams = [] }
            return
        }
        isAvailable = true
        let started = published
        loads += 1
        isLoading = true
        defer {
            loads -= 1
            isLoading = loads > 0
        }
        do {
            let snapshot = try await backend.writer.replica.read { try MobileSpaceReadModel.snapshot(in: $0) }
            // A write published since this read began: its change notice reads again.
            guard started == published else { return }
            if snapshot.pages != pages { pages = snapshot.pages }
            if snapshot.organization != organization { organization = snapshot.organization }
            if snapshot.teams != teams { teams = snapshot.teams }
        } catch {
            Self.logger.error("The Space could not be read: \(String(describing: error), privacy: .public)")
        }
    }

    /// A page's Markdown, its revision (the hash a save names as `expectedRevision`) and its pictures, a
    /// `data:` URL per attachment token as the editor draws them. Its body is fetched the first time and
    /// kept on disk by hash after that. `.notArrived` while a Mac has not uploaded it yet.
    func body(of pageID: String) async throws -> (markdown: String, revision: String?, pictures: [String: String]) {
        try await act { backend in
            guard let held = try await backend.writer.read({ try $0.heldPage(pageID) }) else { throw MobileSpaceError.notFound }
            guard let file = held.envelope.fields["body"].flatMap(FileRef.init(json:)) else {
                if held.envelope.fields["linkedURL"]?.stringValue?.isEmpty == false {
                    throw MobileSpaceError.refused("No text copy of this page has reached iCloud yet.")
                }
                throw MobileSpaceError.notArrived
            }
            let decoded = try await Self.decodedBody(file, ownerZoneKey: held.zoneKey, satellites: backend.satellites)
            let pictures = Dictionary(decoded.attachments.map { ($0.token, "data:\($0.mimeType);base64,\($0.data.base64EncodedString())") },
                                      uniquingKeysWith: { first, _ in first })
            return (decoded.markdown, file.hash, pictures)
        }
    }

    // MARK: Writing a page

    /// Saves a page's Markdown over the revision the editor opened (`expectedRevision`, nil for a page
    /// that had no body) and returns the new revision; the same text writes nothing and returns the
    /// revision held. Throws `.conflict` with the page's text now when its revision moved, on this phone
    /// or by sync, before anything is written. The pictures the Markdown still names and a site's files
    /// stay in the page.
    @discardableResult
    func saveBody(_ markdown: String, of pageID: String, expectedRevision: String?) async throws -> String? {
        try await act { backend in
            let writer = backend.writer
            let (held, page) = try await writer.read { write -> ((zoneKey: String, envelope: SyncEnvelope)?, MobileSpacePage?) in
                let held = try write.heldPage(pageID)
                let page = try MobileSpaceReadModel.pages(in: write.replica, ids: [pageID]).first
                return (held, page)
            }
            guard let held else { throw MobileSpaceError.notFound }
            guard let page, page.isEditableMarkdown else { throw MobileSpaceError.refused("This page can’t be edited on this iPhone.") }
            let current = held.envelope.fields["body"].flatMap(FileRef.init(json:))
            guard current?.hash == expectedRevision else {
                throw try await Self.conflict(current, ownerZoneKey: held.zoneKey, satellites: backend.satellites)
            }
            var carried: ArtifactBodyPackage.Decoded?
            if let current { carried = try await Self.decodedBody(current, ownerZoneKey: held.zoneKey, satellites: backend.satellites) }
            let encoded: ArtifactBodyPackage.Encoded
            do {
                encoded = try MobileSpaceBody.encode(markdown, carrying: carried)
            } catch let error as ArtifactBodyPackageError {
                throw MobileSpaceError.refused(error.localizedDescription)
            }
            if encoded.revision == current?.hash { return current?.hash }
            let file = try await writer.uploadPageBody(encoded.data, pageID: pageID, keeping: current)
            backend.satellites.hold(encoded.data, as: file)
            let saved: MobileSpacePage?
            do {
                saved = try await writer.transaction { write -> MobileSpacePage? in
                    try write.writePageBody(pageID, body: file, markdown: markdown, expectedRevision: expectedRevision)
                    return try MobileSpaceReadModel.pages(in: write.replica, ids: [pageID]).first
                }
            } catch is MobileSpaceBodyMoved {
                // Moved by sync while the new body uploaded.
                let moved = try await writer.read { try $0.heldPage(pageID)?.envelope.fields["body"].flatMap(FileRef.init(json:)) }
                throw try await Self.conflict(moved, ownerZoneKey: held.zoneKey, satellites: backend.satellites)
            }
            if let saved { publish(saved) }
            return file.hash
        }
    }

    /// A new page of the learner's own, its Markdown its body (a placeholder title when `title` is
    /// empty, as the Mac's New page): in `spaceID`, or under `parentID` and in that page's space, as the
    /// Mac's New Subpage files one. `id` is the id the editor gave a page it linked before it existed (a
    /// `/` Page row, `MobilePageCreationRequest`); a page the phone already holds under it is returned as
    /// it is, so a request made twice makes one page.
    func createPage(title: String, markdown: String, spaceID: String?, parentID: String?, id: String? = nil) async throws -> MobileSpacePage {
        let clean = MobileSpaceListing.cleanedTitle(title) ?? MobileSpaceListing.untitledTitle
        if let parentID {
            guard let parent = pages.first(where: { $0.id == parentID }), !parent.isTrashed, MobileSpaceListing.canNest(parent) else {
                throw MobileSpaceError.refused("A page can go only under one of your own pages.")
            }
        }
        let named = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let named, !MobileSpaceListing.isSpaceRecord(id: named, kind: "doc") || DailyNote.isDailyNoteID(named) {
            throw MobileSpaceError.refused("“\(named)” can’t name a page.")
        }
        let space = spaceID ?? parentID.flatMap { organization.spaceID(ofPage: $0) }
        return try await act { backend in
            let writer = backend.writer
            if let named {
                let held = try await writer.read { write -> (isHeld: Bool, page: MobileSpacePage?) in
                    guard try write.heldPage(named) != nil else { return (false, nil) }
                    return (true, try MobileSpaceReadModel.pages(in: write.replica, ids: [named]).first)
                }
                if held.isHeld {
                    guard let page = held.page else { throw MobileSpaceError.refused("“\(named)” can’t name a page.") }
                    publish(page)
                    return page
                }
            }
            let id = named ?? writer.newID()
            let encoded = try Self.encoded(markdown)
            let file = try await writer.uploadPageBody(encoded.data, pageID: id, keeping: nil)
            backend.satellites.hold(encoded.data, as: file)
            let made = try await writer.transaction { write -> (MobileSpacePage?, MobileSpaceOrganization) in
                let rows = try write.pageOrganization()
                if let spaceID, rows.space(spaceID) == nil { throw MobileSpaceError.notFound }
                try write.createPage(id, title: clean, body: file, markdown: markdown)
                if let space, rows.space(space) != nil { try write.writePageRow(PageSpaces.membershipKey(pageID: id), space) }
                if let parentID { try write.writePageRow(PageParents.key(pageID: id), parentID) }
                let page = try MobileSpaceReadModel.pages(in: write.replica, ids: [id]).first
                let organization = try write.pageOrganization()
                return (page, organization)
            }
            guard let page = made.0 else { throw MobileSpaceError.notFound }
            publish(page)
            publish(made.1)
            return page
        }
    }

    /// The daily note of a day (`DailyNote`, `YYYY-MM-DD`), made in My Library with the day's title and
    /// an empty body when the phone holds none. Its id is its day, so the same day made here and on a
    /// Mac is one record. An existing note is returned as it is, in Trash or not.
    func ensureDailyNote(dayKey: String) async throws -> MobileSpacePage {
        guard let title = DailyNote.title(forDayKey: dayKey) else {
            throw MobileSpaceError.refused("“\(dayKey)” is not a day; a day is written YYYY-MM-DD.")
        }
        let id = DailyNote.id(forDayKey: dayKey)
        return try await act { backend in
            let writer = backend.writer
            let existing = try await writer.read { write -> MobileSpacePage? in
                guard try write.heldPage(id) != nil else { return nil }
                return try MobileSpaceReadModel.pages(in: write.replica, ids: [id]).first
            }
            if let existing {
                publish(existing)
                return existing
            }
            let encoded = try Self.encoded("")
            let file = try await writer.uploadPageBody(encoded.data, pageID: id, keeping: nil)
            backend.satellites.hold(encoded.data, as: file)
            let page = try await writer.transaction { write -> MobileSpacePage? in
                // Made meanwhile, by sync bringing the same day from a Mac: that one stands.
                if try write.heldPage(id) == nil { try write.createPage(id, title: title, body: file, markdown: "") }
                return try MobileSpaceReadModel.pages(in: write.replica, ids: [id]).first
            }
            guard let page else { throw MobileSpaceError.notFound }
            publish(page)
            return page
        }
    }

    func rename(_ pageID: String, to title: String) async throws {
        guard let clean = MobileSpaceListing.cleanedTitle(title) else { throw MobileSpaceError.invalidName }
        try await writePage(pageID) { try $0.renamePage(pageID, to: clean) }
    }

    /// Move to Trash: the page is kept whole and listed in Trash, where it can be restored.
    func moveToTrash(_ pageID: String) async throws {
        try await writePage(pageID) { try $0.setPageTrashed(pageID, true) }
    }

    func restore(_ pageID: String) async throws {
        try await writePage(pageID) { try $0.setPageTrashed(pageID, false) }
    }

    /// Deletes a page for good, with its comments. It leaves its space, and the pages under it come out
    /// to the top (`forgetPageSpaces`, `forgetPageParents`).
    func deleteForever(_ pageID: String) async throws {
        try await act { backend in
            let organization = try await backend.writer.transaction { write -> MobileSpaceOrganization in
                try write.deletePage(pageID)
                let rows = try write.pageOrganization()
                if rows.spaceIDByPage[pageID] != nil { try write.writePageRow(PageSpaces.membershipKey(pageID: pageID), nil) }
                for row in rows.parents.rowsAfterForgetting([pageID]) {
                    try write.writePageRow(PageParents.key(pageID: row.pageID), nil)
                }
                return try write.pageOrganization()
            }
            published += 1
            pages.removeAll { $0.id == pageID }
            publish(organization)
            (recents ?? MobileSpaceRecents.shared).forget(pageID)
        }
    }

    // MARK: Organizing

    /// **Pin** and **Unpin**: only the learner's own pages pin; pinning again keeps the first moment.
    func setPinned(_ pageID: String, _ pinned: Bool) async throws {
        if pinned {
            guard let page = pages.first(where: { $0.id == pageID }) else { throw MobileSpaceError.notFound }
            guard MobileSpaceListing.canPin(page) else { throw MobileSpaceError.refused("Only your own pages can be pinned.") }
        }
        let value = PagePins.rowValue(at: now())
        try await writeRows { write, rows in
            guard rows.isPinned(pageID) != pinned else { return }
            try write.writePageRow(PagePins.key(pageID: pageID), pinned ? value : nil)
        }
    }

    /// **Move to Space ▸**: the page goes to the space, or out of every space (nil). A space deleted
    /// on another device since is `.notFound` and takes nothing.
    func move(_ pageID: String, toSpace spaceID: String?) async throws {
        guard let page = pages.first(where: { $0.id == pageID }) else { throw MobileSpaceError.notFound }
        guard MobileSpaceListing.canFileInSpace(page) else { throw MobileSpaceError.refused("Only your own pages go in a space.") }
        try await writeRows { write, rows in
            if let spaceID, rows.space(spaceID) == nil { throw MobileSpaceError.notFound }
            for row in rows.pageSpaces.membershipRowsAfterMoving([pageID], to: spaceID) {
                try write.writePageRow(PageSpaces.membershipKey(pageID: row.pageID), row.spaceID)
            }
        }
    }

    /// **Move to Page…** and **Remove from Parent** (nil): only the learner's own Markdown pages nest,
    /// under another of their own out of Trash, and never under themselves or a page under them.
    func setParent(of pageID: String, to parentID: String?) async throws {
        let snapshot = pages
        guard let page = snapshot.first(where: { $0.id == pageID }) else { throw MobileSpaceError.notFound }
        guard MobileSpaceListing.canNest(page) else { throw MobileSpaceError.refused("Only your own pages can be nested.") }
        let ordered = MobileSpaceListing.nestable(snapshot).map(\.id)
        try await writeRows { write, rows in
            guard rows.parents.tree(among: ordered).canSetParent(parentID, for: pageID) else {
                throw MobileSpaceError.refused("A page can’t go under itself or under a page inside it.")
            }
            for row in rows.parents.rowsAfterSettingParent(parentID, for: pageID, among: ordered) {
                try write.writePageRow(PageParents.key(pageID: row.pageID), row.parentID)
            }
        }
    }

    /// Makes a space of pages named `name` and returns its id.
    func createSpace(named name: String) async throws -> String {
        guard let cleaned = PageSpaces.cleanedName(name) else { throw MobileSpaceError.invalidName }
        let id = PageSpaces.newSpaceID()
        try await writeRows { write, _ in try write.writePageRow(PageSpaces.nameKey(spaceID: id), cleaned) }
        return id
    }

    /// Renames a space. One deleted on another device since is `.notFound` and leaves the phone, never
    /// brought back by a new name.
    func renameSpace(_ spaceID: String, to name: String) async throws {
        guard let cleaned = PageSpaces.cleanedName(name) else { throw MobileSpaceError.invalidName }
        try await writeRows { write, rows in
            guard rows.space(spaceID) != nil else { throw MobileSpaceError.notFound }
            try write.writePageRow(PageSpaces.nameKey(spaceID: spaceID), cleaned)
        }
    }

    /// Deletes a space: its name row, and every page row that names it. The pages stay, in All.
    func deleteSpace(_ spaceID: String) async throws {
        try await writeRows { write, rows in
            for row in rows.pageSpaces.membershipRowsAfterDeleting(spaceID) {
                try write.writePageRow(PageSpaces.membershipKey(pageID: row.pageID), nil)
            }
            try write.writePageRow(PageSpaces.nameKey(spaceID: spaceID), nil)
        }
    }

    // MARK: Helpers

    /// Runs an act with the backend, or refuses it while the Space is unavailable; the writer's
    /// refusals come back in the Space's words.
    private func act<T>(_ body: (Backend) async throws -> T) async throws -> T {
        guard let backend = await connect() else {
            isAvailable = false
            throw MobileSpaceError.unavailable
        }
        isAvailable = true
        do {
            return try await body(backend)
        } catch let error as MobileRecordWriterError {
            throw Self.spaceError(error)
        }
    }

    /// One page's record written, then published as the replica reads it back; a page the Space no
    /// longer lists (a reading restored into its notebook) leaves the list.
    private func writePage(_ pageID: String, _ change: @escaping (inout MobileWrite) throws -> Void) async throws {
        try await act { backend in
            let page = try await backend.writer.transaction { write -> MobileSpacePage? in
                try change(&write)
                return try MobileSpaceReadModel.pages(in: write.replica, ids: [pageID]).first
            }
            if let page {
                publish(page)
            } else {
                published += 1
                pages.removeAll { $0.id == pageID }
            }
        }
    }

    /// Rows of the grouping written over the rows as the phone holds them now (another device's since
    /// the last read included), then published as written. A space found gone is published gone.
    private func writeRows(_ change: @escaping (inout MobileWrite, MobileSpaceOrganization) throws -> Void) async throws {
        try await act { backend in
            do {
                let organization = try await backend.writer.transaction { write -> MobileSpaceOrganization in
                    try change(&write, try write.pageOrganization())
                    return try write.pageOrganization()
                }
                publish(organization)
            } catch MobileSpaceError.notFound {
                let organization = try await backend.writer.read { try $0.pageOrganization() }
                publish(organization)
                throw MobileSpaceError.notFound
            }
        }
    }

    private func publish(_ page: MobileSpacePage) {
        published += 1
        if let index = pages.firstIndex(where: { $0.id == page.id }) {
            pages[index] = page
        } else {
            pages = MobileSpaceListing.sorted(pages + [page], by: .created)
        }
    }

    private func publish(_ next: MobileSpaceOrganization) {
        published += 1
        if next != organization { organization = next }
    }

    /// A new page's package; a picture the Markdown names that no page holds is refused.
    private static func encoded(_ markdown: String) throws -> ArtifactBodyPackage.Encoded {
        do {
            return try MobileSpaceBody.encode(markdown, carrying: nil)
        } catch let error as ArtifactBodyPackageError {
            throw MobileSpaceError.refused(error.localizedDescription)
        }
    }

    private static func decodedBody(_ file: FileRef, ownerZoneKey: String, satellites: MobileSatellites) async throws -> ArtifactBodyPackage.Decoded {
        guard let satellite = try await satellites.satellite(file, ownerZoneKey: ownerZoneKey) else { throw MobileSpaceError.unavailable }
        return try MobileSpaceBody.decode(try await satellites.data(satellite), file: file)
    }

    /// The conflict a save meets: the page's text and revision as they are now.
    private static func conflict(_ current: FileRef?, ownerZoneKey: String, satellites: MobileSatellites) async throws -> MobileSpaceError {
        guard let current else { return .conflict(currentMarkdown: "", currentRevision: nil) }
        let decoded = try await decodedBody(current, ownerZoneKey: ownerZoneKey, satellites: satellites)
        return .conflict(currentMarkdown: decoded.markdown, currentRevision: current.hash)
    }

    static func spaceError(_ error: MobileRecordWriterError) -> Error {
        switch error {
        case .zoneNotHeld: return MobileSpaceError.unavailable
        case .emptyTitle: return MobileSpaceError.invalidName
        case .refused(let reason): return MobileSpaceError.refused(reason)
        default: return error
        }
    }
}
