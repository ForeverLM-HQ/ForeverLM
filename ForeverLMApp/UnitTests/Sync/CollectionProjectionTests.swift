import Foundation
import Testing
@testable import ForeverLM

/// The Collection record's projection and a playlist's member Entries (docs/cloudkit-schema-design.md
/// §3.5.5, §3.5.8, §5.7, WP7): books, meeting series, followed and unfollowed playlists, shows and
/// channels round-trip; a member applied before its Source waits for it; a local source delete leaves
/// the member's Entry live on the server and brings the member back on re-import.
@Suite("Collection projection")
struct CollectionProjectionTests {
    private typealias Fixture = SourceSyncFixture

    private static let playlist = "playlist_youtube.com/playlist?list=UU8kGsMa0LygSX9nkBcBH1Sg"
    private static let videoURL = "https://www.youtube.com/watch?v=abcdefghijk"
    private static var videoID: String { SourceIdentity.stableID(for: videoURL) }
    private static var entryID: String { PlaylistEntryProjection.entryID(playlistID: playlist, sourceID: videoID) }

    private static func encoded(_ store: KnowledgeStore, _ id: String) throws -> [String: SyncJSON] {
        let rows = try #require(try CollectionProjection.loadRows(id: id, connection: store))
        return CollectionProjection.encodeRows(rows)
    }

    private static func video() throws -> ReplicaRecord {
        try Fixture.record(.source, videoID, [
            "type": "video", "title": "A member", "url": .string(videoURL), "status": "active",
            "ingest": .object(["ord": .array([0, 4]), "state": "ready"]), "addedAt": SyncJSON(Int64(1_759_000_000_000)),
            "meta": .object(["channelName": "Alon Lab"]),
        ])
    }

    private static func entry(state: String = "active", orderKey: String? = SourceOrderKeys.key(forIndex: 3)) throws -> ReplicaRecord {
        var fields: [String: SyncJSON] = [
            "containerKind": "playlist", "containerID": .string(playlist), "itemKind": "source", "itemID": .string(videoID),
            "state": .string(state), "origin": "import", "addedAt": SyncJSON(Int64(1_759_000_000_000)),
        ]
        if let orderKey { fields["orderKey"] = .string(orderKey) }
        return try Fixture.record(.entry, entryID, fields)
    }

    @Test("A show or channel first met after the activation gets its Collection when its first episode is saved")
    func newShowGetsItsCollection() throws {
        let (root, store) = try Fixture.makeStore("collection-new-show")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        var episode = StudioArticle(url: "https://podcasts.example.org/huberman/1", title: "Episode 1", sourceType: .podcast)
        episode.domain = "Huberman Lab"
        try store.saveSource(episode)
        let show = SyncIdentity.collectionID(kind: "podcastShow", externalKey: "Huberman Lab")
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM source_collections WHERE id = '\(show)' AND kind = 'podcastShow'") == 1)
        #expect(try Fixture.pending(store)["Collection:\(show)"] != nil, "the record goes out beside the Source that names it")

        var video = StudioArticle(url: Self.videoURL, title: "A member", sourceType: .video)
        video.domain = "Alon Lab"
        try store.saveSource(video)
        let channel = SyncIdentity.collectionID(kind: "youtubeChannel", externalKey: "Alon Lab")
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM source_collections WHERE id = '\(channel)'") == 1)
        // A second episode adds nothing and moves nothing.
        var second = StudioArticle(url: "https://podcasts.example.org/huberman/2", title: "Episode 2", sourceType: .podcast)
        second.domain = "Huberman Lab"
        try Fixture.sendAll(store)
        try store.saveSource(second)
        #expect(try Fixture.pending(store)["Collection:\(show)"] == nil)
    }

    @Test("A book, a meeting series, a followed playlist and a show each round-trip through their own table")
    func roundTrips() throws {
        let (root, store) = try Fixture.makeStore("collection-round-trip")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try store.saveVideoPlaylistGroup(id: "playlist_youtube.com/playlist?list=LL", metadata: VideoPlaylistMetadata(
            title: "Liked videos", playlistURL: "https://www.youtube.com/playlist?list=LL"
        ))
        try Fixture.sendAll(store)
        let show = SyncIdentity.collectionID(kind: "podcastShow", externalKey: "Huberman Lab")
        let records: [(id: String, fields: [String: SyncJSON], table: String)] = [
            ("BFD0CD37-6840-4D47-9CEB-3EC7A1E36747", [
                "kind": "book", "externalKey": "BFD0CD37-6840-4D47-9CEB-3EC7A1E36747", "title": "Cell Biology by the Numbers",
                "subtitle": "A guide", "author": "Ron Milo",
            ], "books"),
            ("Aging Biology Study Group", [
                "kind": "meetingSeries", "externalKey": "Aging Biology Study Group", "title": "Aging Biology Study Group",
                "schedule": .object(["rrule": "FREQ=WEEKLY;BYDAY=SU", "timezone": "America/New_York",
                                     "driveFolderURL": "https://drive.google.com/x", "planned": .array(["2026-10-04"])]),
            ], "meeting_groups"),
            ("playlist_youtube.com/playlist?list=LL", [
                "kind": "playlist", "externalKey": "https://www.youtube.com/playlist?list=LL", "title": "Liked",
                "feed": .object(["playlistID": "LL"]),
            ], "video_playlists"),
            (show, [
                "kind": "podcastShow", "externalKey": "Huberman Lab", "title": "Huberman Lab", "status": "active",
                "feed": .object(["feedURL": "https://feeds.example.org/huberman"]), "addedAt": SyncJSON(Int64(1_759_000_000_000)),
            ], "source_collections"),
        ]
        for record in records {
            try Fixture.apply(store, [try Fixture.record(.collection, record.id, record.fields)])
            #expect(try Fixture.count(store, "SELECT COUNT(*) FROM \(record.table) WHERE id = ?", [.text(record.id)]) == 1, "\(record.table)")
            let encoded = try Self.encoded(store, record.id)
            for (field, value) in record.fields {
                #expect(encoded[field] == value, "\(record.table).\(field)")
            }
        }
        // Following and hiding are this member's own: a playlist's record leaves them as they were.
        #expect(try Fixture.text(store, "SELECT title FROM video_playlists WHERE id = 'playlist_youtube.com/playlist?list=LL'") == "Liked")
        #expect(try Fixture.pending(store).isEmpty, "applied records send nothing back")
    }

    @Test("A playlist nobody here follows is kept with the shows and channels, not followed")
    func unfollowedPlaylist() throws {
        let (root, store) = try Fixture.makeStore("collection-unfollowed")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Fixture.apply(store, [try Fixture.record(.collection, Self.playlist, [
            "kind": "playlist", "externalKey": "youtube.com/playlist?list=UU8kGsMa0LygSX9nkBcBH1Sg", "title": .string(Self.playlist),
        ])])
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM video_playlists") == 0)
        #expect(try Fixture.text(store, "SELECT kind FROM source_collections WHERE id = ?", [.text(Self.playlist)]) == "playlist")
    }

    @Test("A playlist Entry applied before its Source waits, and is projected when the source arrives")
    func entryBeforeItsSource() throws {
        let (root, store) = try Fixture.makeStore("collection-entry-first")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Fixture.apply(store, [try Self.entry()])
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM group_members") == 0)
        #expect(try Fixture.text(store, "SELECT waiting_on_type || ':' || waiting_on_id FROM ck_unprojected") == "Source:\(Self.videoID)")

        try Fixture.apply(store, [try Self.video()])
        #expect(try Fixture.text(store, "SELECT group_id || '|' || sort_index FROM group_members WHERE source_id = ?", [.text(Self.videoID)]) == "\(Self.playlist)|3")
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0)
        #expect(try Fixture.pending(store).isEmpty)
    }

    @Test("A local source delete keeps its playlist Entry live on the server, and re-import brings the member back")
    func localDeleteThenReimport() throws {
        let (root, store) = try Fixture.makeStore("collection-delete-reimport")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Fixture.apply(store, [try Self.video(), try Self.entry()])
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM group_members WHERE group_id = ?", [.text(Self.playlist)]) == 1)

        try store.execForTesting("DELETE FROM sources WHERE id = '\(Self.videoID)'")
        let pending = try Fixture.pending(store)
        guard case .delete? = pending["Source:\(Self.videoID)"]?.action else {
            Issue.record("the deleted source's record is deleted")
            return
        }
        #expect(pending["Entry:\(Self.entryID)"] == nil, "the Entry is not written: it hides while its source is gone")
        #expect(try Fixture.text(store, "SELECT waiting_on_type || ':' || waiting_on_id FROM ck_unprojected") == "Source:\(Self.videoID)")

        // The same video imported again mints the same id.
        try store.saveSource(StudioArticle(url: Self.videoURL, title: "A member", sourceType: .video))
        try store.drainReadyProjections(Fixture.registry)
        #expect(try Fixture.text(store, "SELECT group_id || '|' || sort_index FROM group_members WHERE source_id = ?", [.text(Self.videoID)]) == "\(Self.playlist)|3")
        // The member is live as it was: at most a later date added, which the minimum keeps out.
        let member = try Fixture.pending(store)["Entry:\(Self.entryID)"]
        #expect(member.map { Set($0.stamps.keys.map(\.field)).isSubset(of: ["addedAt"]) } ?? true, "the member is not removed or moved")
    }

    @Test("A member removed from a playlist while its source stays is a removed Entry")
    func removedMember() throws {
        let (root, store) = try Fixture.makeStore("collection-removed")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Fixture.apply(store, [try Self.video(), try Self.entry()])
        try store.execForTesting("DELETE FROM group_members WHERE source_id = '\(Self.videoID)' AND group_id = '\(Self.playlist)'")
        let change = try Fixture.pending(store)["Entry:\(Self.entryID)"]
        #expect(Fixture.savedFields(change)?["state"] == "removed")
        #expect(change?.stamps.keys.map(\.field) == ["state"], "only the state moves")
    }

    @Test("A member added here is an Entry in the playlist, ordered by its index")
    func addedMember() throws {
        let (root, store) = try Fixture.makeStore("collection-added")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        var member = StudioArticle(url: Self.videoURL, title: "A member", sourceType: .video, parentGroup: Self.playlist)
        member.courseSortIndex = 5
        try store.saveSource(member)
        let fields = try #require(Fixture.savedFields(try Fixture.pending(store)["Entry:\(Self.entryID)"]))
        #expect(fields["containerKind"] == "playlist" && fields["containerID"] == .string(Self.playlist))
        #expect(fields["itemID"] == .string(Self.videoID) && fields["state"] == "active")
        #expect(fields["orderKey"] == SourceOrderKeys.key(forIndex: 5).map(SyncJSON.string))
        // A course's or a book's membership is no Entry.
        try store.execForTesting("INSERT INTO group_members (source_id, group_id) VALUES ('\(Self.videoID)', 'course-1')")
        #expect(try Fixture.pending(store).keys.filter { $0.hasPrefix("Entry:") } == ["Entry:\(Self.entryID)"])
    }

    @Test("Saving a playlist or a meeting group dates only what changed: an upsert, not a replace")
    func upsertsDateOnlyWhatChanged() throws {
        let (root, store) = try Fixture.makeStore("collection-upsert")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        let id = "playlist_youtube.com/playlist?list=LL"
        try store.saveVideoPlaylistGroup(id: id, metadata: VideoPlaylistMetadata(title: "Liked videos", playlistURL: "https://www.youtube.com/playlist?list=LL"))
        try Fixture.sendAll(store)
        var metadata = VideoPlaylistMetadata(title: "Liked videos", playlistURL: "https://www.youtube.com/playlist?list=LL")
        metadata.autoImport = true
        try store.saveVideoPlaylistGroup(id: id, metadata: metadata)
        // Following is the member's Mark, not a field of the Collection record, and nothing else changed.
        #expect(try Fixture.pending(store).keys.filter { $0.hasPrefix("Collection:") }.isEmpty, "following is not on the record")
        metadata.title = "Liked"
        try store.saveVideoPlaylistGroup(id: id, metadata: metadata)
        let changed = try Fixture.pending(store).filter { $0.key.hasPrefix("Collection:") }.values
        #expect(changed.count == 1 && changed.first?.stamps.keys.map(\.field) == ["title"], "only the title is dated")
    }

    // MARK: A book's cover (`files.cover`)

    private static let bookID = "BFD0CD37-6840-4D47-9CEB-3EC7A1E36747"

    private static func cover(_ body: Data) -> FileRef {
        FileRef(owner: bookID, role: BookCovers.role, hash: SyncIdentity.sha256Hex(body), size: Int64(body.count),
                mime: BookCovers.mime, encoding: "identity", storedParts: [body])
    }

    private static func book(cover: FileRef?) throws -> ReplicaRecord {
        var fields: [String: SyncJSON] = ["kind": "book", "externalKey": .string(bookID), "title": "The Vital Question", "author": "Nick Lane"]
        if let cover { fields["files"] = .object([BookCovers.role: cover.value]) }
        return try Fixture.record(.collection, bookID, fields)
    }

    @Test("A book's cover another Mac put up is fetched into the book's row, and a cover file of this Mac's own is never replaced")
    func bookCoverArrives() async throws {
        let (root, store) = try Fixture.makeStore("collection-book-cover")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("book-covers-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: folder)
        }
        try Fixture.prepareReplica(store)
        let body = Data("the cover's bytes".utf8)
        try Fixture.apply(store, [try Self.book(cover: Self.cover(body))])
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ? AND target = ?",
                                  [.text(BookCovers.queueKind), .text(Self.bookID)]) == 1, "a book with no cover file here wants the cover")

        let reader = SatelliteReader(store: .direct(store)) { _ in body }
        let taken = await KnowledgeStore.$installedSourceFileRootOverride.withValue(folder) { await reader.drain() }
        #expect(taken == 1)
        let installed = BookCovers.installedPath(hash: SyncIdentity.sha256Hex(body))
        #expect(try Fixture.text(store, "SELECT cover_path FROM books WHERE id = ?", [.text(Self.bookID)]) == installed)
        #expect(try Data(contentsOf: folder.appendingPathComponent(installed)) == body)
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ?", [.text(BookCovers.queueKind)]) == 0)
        #expect(try Fixture.pending(store)["Collection:\(Self.bookID)"] == nil, "a fetched cover is never sent back")

        // A Mac that holds its own cover file for the book keeps it, whatever cover the record names.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let own = folder.appendingPathComponent("own-cover.jpg")
        try Data("this Mac's own cover".utf8).write(to: own)
        try store.execute("UPDATE books SET cover_path = ? WHERE id = ?", [.text(own.path), .text(Self.bookID)])
        try Fixture.apply(store, [try Self.book(cover: Self.cover(Data("another cover".utf8)))])
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ?", [.text(BookCovers.queueKind)]) == 0)
        #expect(try Fixture.text(store, "SELECT cover_path FROM books WHERE id = ?", [.text(Self.bookID)]) == own.path)
    }

    @Test("The publisher takes a book whose cover is set here and whose record names none, and leaves a book with a cover or no record")
    func bookCoverToPublish() throws {
        let (root, store) = try Fixture.makeStore("collection-book-cover-publish")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Fixture.apply(store, [try Self.book(cover: nil)])
        try store.execute("UPDATE books SET cover_path = 'Books/TheVitalQuestion/cover.jpg' WHERE id = ?", [.text(Self.bookID)])
        // A book the replica holds no record of yet waits for it: the pointer goes onto a held version.
        try store.execute("INSERT INTO books (id, title, cover_path) VALUES ('B2', 'Unsent', 'Books/Unsent/cover.jpg')")
        #expect(try BookCovers.unpublished(connection: store).map(\.bookID) == [Self.bookID])

        try Fixture.apply(store, [try Self.book(cover: Self.cover(Data("the cover's bytes".utf8)))])
        #expect(try BookCovers.unpublished(connection: store).isEmpty, "a record that names a cover is left as it is")
    }
}
