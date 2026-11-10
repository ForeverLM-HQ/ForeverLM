import Foundation
import Testing
@testable import ForeverLM

/// The Mark projection (docs/cloudkit-schema-design.md §3.5.19, §6.3, §5.7, WP12b): every kind from the
/// table generation 1 keeps it in, and back into it on another Mac; a hide at t0, a remote unhide at t1
/// and a local change at t2, where the unhide wins; a Mark applied before its source; and a source delete
/// that keeps the hidden and dismissed Marks and the like.
@Suite("Mark projection")
struct MarkProjectionTests {
    typealias F = NotebookSyncFixture

    static func addVideo(_ store: KnowledgeStore, _ id: String, channel: String = "Mito Lab", likedAt: Double? = nil, origin: String? = nil) throws {
        try store.execute("INSERT INTO sources (id, date_added, state, source_type, status) VALUES (?, 100, 'ready', 'video', 'active')", [.text(id)])
        try store.execute(
            "INSERT INTO videos (source_id, url, normalized_url, title, domain, liked_at, discovery_origin) VALUES (?, ?, ?, 'A talk', ?, ?, ?)",
            [.text(id), .text("https://youtube.com/watch?v=\(id)"), .text("youtube.com/watch?v=\(id)"), .text(channel), .real(likedAt), .text(origin)]
        )
    }

    static func addPodcast(_ store: KnowledgeStore, _ id: String) throws {
        try store.execute("INSERT INTO sources (id, date_added, state, source_type, status) VALUES (?, 100, 'ready', 'podcast', 'active')", [.text(id)])
        try store.execute(
            "INSERT INTO podcasts (source_id, url, normalized_url, title, domain) VALUES (?, ?, ?, 'An episode', 'EPIC RADIO')",
            [.text(id), .text("https://pod.example/\(id)"), .text("pod.example/\(id)")]
        )
    }

    static func mark(_ store: KnowledgeStore, _ key: MarkKey) throws -> [String: SyncJSON]? {
        F.savedFields(try F.pending(store)["Mark:\(key.id)"])
    }

    /// Every kind's rows, written as the app writes them.
    static func writeEveryKind(_ store: KnowledgeStore) throws {
        try F.addSource(store, "src-a")
        try addPodcast(store, "src-pod")
        try addVideo(store, "src-vid", likedAt: 700_000_000, origin: "youtubePlaylist")
        try store.writeSourceHidden("src-a", hidden: true, hiddenAt: Date(timeIntervalSinceReferenceDate: 1_000))
        try store.execute("INSERT INTO hidden_podcast_shows (show_name, hidden_at) VALUES ('EPIC RADIO', 1500)")
        try store.execute("INSERT INTO hidden_youtube_channels (channel_name, hidden_at) VALUES ('Mito Lab', 2000)")
        try store.execute("INSERT INTO hidden_artifacts (artifact_id, hidden_at) VALUES ('art-1', 3000)")
        try store.execute("INSERT INTO hidden_review_sessions (session_id, hidden_at) VALUES ('chat-1', 4000)")
        try store.execute("INSERT INTO dismissed_sources (url, title, dismissed_at) VALUES ('https://www.example.com/paper?utm_source=x', 'A paper', 5000)")
        try store.execute("INSERT INTO visible_podcast_episode_overrides (source_id, visible_at) VALUES ('src-pod', 6000)")
        try store.execute("INSERT INTO blocked_podcast_shows (show_name, blocked_at) VALUES ('Spam Show', 7000)")
        try store.execute("""
            INSERT INTO source_ideas (id, source_id, statement, recall_note, wanted, content_hash, created_at, updated_at)
            VALUES ('idea-1', 'src-a', 'Mitochondria divide', 'note', 1, 'h', 1, 8000)
        """)
        try store.execute("""
            INSERT INTO video_cited_papers (id, source_id, title, status, imported_source_id, created_at, updated_at)
            VALUES ('cand-1', 'src-vid', 'Cited', 'imported', 'src-a', 1, 9000)
        """)
        try store.execute("INSERT INTO video_playlists (id, title, playlist_url, auto_import) VALUES ('pl-uploads', 'Uploads', 'https://youtube.com/playlist?list=UU1', 1)")
    }

    @Test("Every kind encodes from its table, and another Mac writes each back into the same table")
    func everyKindRoundTrips() throws {
        let (root, store) = try F.makeStore("mk-kinds")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try Self.writeEveryKind(store)
        let pending = try F.pending(store)

        let hidden = try #require(F.savedFields(pending["Mark:mk:hidden:src:src-a"]))
        #expect(hidden["kind"] == .string("hidden") && hidden["target"] == .string("src:src-a") && hidden["on"] == .bool(true))
        #expect(hidden["at"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 1_000)))
        let show = try #require(F.savedFields(pending["Mark:\(MarkKey.hiddenShow("EPIC RADIO").id)"]))
        #expect(show["value"] == .object(["name": .string("EPIC RADIO")]))
        #expect(F.savedFields(pending["Mark:\(MarkKey.hiddenChannel("Mito Lab").id)"])?["on"] == .bool(true))
        #expect(F.savedFields(pending["Mark:mk:hidden:art:art-1"])?["on"] == .bool(true))
        #expect(F.savedFields(pending["Mark:mk:hidden:cht:chat-1"])?["on"] == .bool(true))
        let dismissed = try #require(F.savedFields(pending["Mark:\(MarkKey.dismissed(url: "https://www.example.com/paper?utm_source=x").id)"]))
        #expect(dismissed["target"]?.stringValue?.hasPrefix("wk:url:") == true)
        #expect(dismissed["value"] == .object(["url": .string("https://www.example.com/paper?utm_source=x"), "title": .string("A paper")]))
        #expect(F.savedFields(pending["Mark:mk:visibleOverride:src:src-pod"])?["on"] == .bool(true))
        #expect(F.savedFields(pending["Mark:\(MarkKey.blockedShow("Spam Show").id)"])?["value"] == .object(["name": .string("Spam Show")]))
        #expect(F.savedFields(pending["Mark:mk:wantIdea:src:src-a#idea-1"])?["on"] == .bool(true))
        #expect(F.savedFields(pending["Mark:mk:citedDecision:src:src-vid#cand-1"])?["value"]
                == .object(["status": .string("imported"), "importedSourceID": .string("src-a")]))
        #expect(F.savedFields(pending["Mark:mk:liked:src:src-vid"])?["value"]
                == .object(["at": SyncJSON(SyncTime.milliseconds(cocoaSeconds: 700_000_000))]))
        #expect(F.savedFields(pending["Mark:mk:following:col:pl-uploads"])?["value"] == .object(["autoImport": .bool(true)]))
        #expect(F.savedFields(pending["Mark:mk:provenance:src:src-vid"])?["value"]?.objectValue?["origin"] == .string("youtubePlaylist"))
        #expect(pending["Mark:mk:liked:src:src-pod"] == nil && pending["Mark:mk:provenance:src:src-a"] == nil, "no like or origin, no Mark")

        // Another Mac holds the content and none of the member's state; every Mark lands in its table.
        let (otherRoot, other) = try F.makeStore("mk-kinds-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try F.prepareReplica(other)
        try F.addSource(other, "src-a")
        try Self.addPodcast(other, "src-pod")
        try Self.addVideo(other, "src-vid")
        try other.execute("""
            INSERT INTO source_ideas (id, source_id, statement, recall_note, wanted, content_hash, created_at, updated_at)
            VALUES ('idea-1', 'src-a', 'Mitochondria divide', 'note', 0, 'h', 1, 1)
        """)
        try other.execute("INSERT INTO video_cited_papers (id, source_id, title, status, created_at, updated_at) VALUES ('cand-1', 'src-vid', 'Cited', 'pending', 1, 1)")
        try other.execute("INSERT INTO video_playlists (id, title, playlist_url, auto_import) VALUES ('pl-uploads', 'Uploads', 'https://youtube.com/playlist?list=UU1', 0)")
        try F.sendAll(other)
        let marks = try pending.filter { $0.key.hasPrefix("Mark:") }.map { try OutboxTestProjections.serverRecord(for: $0.value) }
        try F.apply(other, marks)
        #expect(try F.count(other, "SELECT COUNT(*) FROM hidden_sources WHERE source_id = 'src-a' AND hidden_at = 1000") == 1)
        #expect(try F.count(other, "SELECT COUNT(*) FROM hidden_podcast_shows WHERE show_name = 'EPIC RADIO'") == 1)
        #expect(try F.count(other, "SELECT COUNT(*) FROM hidden_youtube_channels WHERE channel_name = 'Mito Lab'") == 1)
        #expect(try F.count(other, "SELECT COUNT(*) FROM hidden_artifacts WHERE artifact_id = 'art-1'") == 1)
        #expect(try F.count(other, "SELECT COUNT(*) FROM hidden_review_sessions WHERE session_id = 'chat-1'") == 1)
        #expect(try F.text(other, "SELECT title FROM dismissed_sources WHERE url = 'https://www.example.com/paper?utm_source=x'") == "A paper")
        #expect(try F.count(other, "SELECT COUNT(*) FROM visible_podcast_episode_overrides WHERE source_id = 'src-pod'") == 1)
        #expect(try F.count(other, "SELECT COUNT(*) FROM blocked_podcast_shows WHERE show_name = 'Spam Show'") == 1)
        #expect(try F.count(other, "SELECT wanted FROM source_ideas WHERE id = 'idea-1'") == 1)
        #expect(try F.text(other, "SELECT status || ':' || imported_source_id FROM video_cited_papers WHERE id = 'cand-1'") == "imported:src-a")
        #expect(try F.count(other, "SELECT COUNT(*) FROM videos WHERE source_id = 'src-vid' AND liked_at = 700000000") == 1)
        #expect(try F.count(other, "SELECT auto_import FROM video_playlists WHERE id = 'pl-uploads'") == 1)
        #expect(try F.text(other, "SELECT discovery_origin FROM videos WHERE source_id = 'src-vid'") == "youtubePlaylist")
        #expect(try F.pending(other).keys.filter { $0.hasPrefix("Mark:") }.isEmpty, "an apply sends nothing back")
    }

    @Test("A hidden collection that is neither a show nor a channel lands in neither table")
    func hiddenOtherCollectionLandsNowhere() throws {
        let (root, store) = try F.makeStore("mk-hidden-playlist")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        let at = SyncJSON(Int64(1_759_000_000_000))
        try F.apply(store, [
            try F.record(.mark, "mk:hidden:col:pl-uploads", ["kind": .string("hidden"), "target": .string("col:pl-uploads"), "on": .bool(true),
                                                             "value": .object(["name": .string("Uploads")]), "at": at]),
            try F.record(.mark, MarkKey.hiddenChannel("Mito Lab").id, ["kind": .string("hidden"), "target": .string(MarkKey.hiddenChannel("Mito Lab").target),
                                                                       "on": .bool(true), "value": .object(["name": .string("Mito Lab")]), "at": at]),
        ])
        #expect(try F.count(store, "SELECT COUNT(*) FROM hidden_youtube_channels WHERE channel_name = 'Uploads'") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM hidden_podcast_shows WHERE show_name = 'Uploads'") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM hidden_youtube_channels WHERE channel_name = 'Mito Lab'") == 1)
    }

    @Test("An unhide, an un-want, an unfollow and a cleared rating send on = false, and the Mark is never deleted")
    func offIsAFlipNeverADelete() throws {
        let (root, store) = try F.makeStore("mk-off")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try Self.writeEveryKind(store)
        try F.sendAll(store)
        try store.writeSourceHidden("src-a", hidden: false)
        try store.execute("UPDATE source_ideas SET wanted = 0 WHERE id = 'idea-1'")
        try store.execute("UPDATE video_playlists SET auto_import = 0 WHERE id = 'pl-uploads'")
        try store.execute("DELETE FROM dismissed_sources")
        let pending = try F.pending(store)
        for id in ["mk:hidden:src:src-a", "mk:wantIdea:src:src-a#idea-1", "mk:following:col:pl-uploads",
                   MarkKey.dismissed(url: "https://www.example.com/paper?utm_source=x").id] {
            guard case .save(let envelope)? = pending["Mark:\(id)"]?.action else { Issue.record("\(id) is not saved"); continue }
            #expect(envelope.fields["on"] == .bool(false), "\(id)")
        }
        #expect(!pending.values.contains { $0.recordType == .mark && $0.action == .delete })
    }

    @Test("A hide at t0, a remote unhide at t1, a local change at t2: the unhide wins and the change lands")
    func hideLosesToLaterUnhide() throws {
        let (root, store) = try F.makeStore("mk-t0t1t2")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-a")
        try store.writeSourceHidden("src-a", hidden: true)
        try F.sendAll(store)
        try store.writeSourceHidden("src-a", hidden: false)
        try F.sendAll(store)
        // Later than the unhide's acknowledgement: offline, hidden again at t0 and its time edited at t2.
        let t0 = Date().timeIntervalSinceReferenceDate + 100, t2 = t0 + 20
        try store.writeSourceHidden("src-a", hidden: true, hiddenAt: Date(timeIntervalSinceReferenceDate: t0))
        try store.execute("UPDATE ck_outbox_fields SET dirty_at = ? WHERE source_table = 'hidden_sources'", [.real(t0)])
        try store.execute("UPDATE hidden_sources SET hidden_at = ? WHERE source_id = 'src-a'", [.real(t2)])
        try store.execute("UPDATE ck_outbox_fields SET dirty_at = ? WHERE source_table = 'hidden_sources' AND column = 'hidden_at'", [.real(t2)])

        let change = try #require(try F.pending(store)["Mark:mk:hidden:src:src-a"])
        guard case .save(let local) = change.action else { Issue.record("expected a save"); return }
        let onStamp = try #require(change.stamps[StampedPath("on")])
        let atStamp = try #require(change.stamps[StampedPath("at")])
        #expect(onStamp.milliseconds == SyncTime.milliseconds(cocoaSeconds: t0), "the hide keeps its own time")
        #expect(atStamp.milliseconds == SyncTime.milliseconds(cocoaSeconds: t2))

        // Another device unhid it at t1, between the two.
        let t1 = SyncTime.milliseconds(cocoaSeconds: t0 + 10)
        let held = try #require(try F.held(store, .mark, "mk:hidden:src:src-a"))
        var server = held
        server.fields["on"] = .bool(false)
        server.stamps["on"] = .value(SyncStamp(policy: .lastWriter, milliseconds: t1, counter: 0, deviceID: "otheraaa"))
        let merged = FieldMerge.merge(server: server, local: local, base: held, mintedAgainst: change.mintedAgainst).merged
        #expect(merged.fields["on"] == .bool(false), "the remote unhide wins over the earlier hide")
        #expect(merged.fields["at"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: t2)), "the later change still lands")
    }

    @Test("A Mark applied before its source waits for it; a hide needs none")
    func markBeforeItsSource() throws {
        let (root, store) = try F.makeStore("mk-order")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        let at = SyncJSON(Int64(1_759_000_000_000))
        try F.apply(store, [
            try F.record(.mark, "mk:hidden:src:src-late", ["kind": .string("hidden"), "target": .string("src:src-late"), "on": .bool(true), "at": at]),
            try F.record(.mark, "mk:visibleOverride:src:src-late", ["kind": .string("visibleOverride"), "target": .string("src:src-late"), "on": .bool(true), "at": at]),
            try F.record(.mark, "mk:liked:src:vid-late", ["kind": .string("liked"), "target": .string("src:vid-late"), "on": .bool(true),
                                                           "value": .object(["at": at]), "at": at]),
        ])
        #expect(try F.count(store, "SELECT COUNT(*) FROM hidden_sources WHERE source_id = 'src-late'") == 1, "a hide is written at once")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected WHERE waiting_on_type = 'Source' AND waiting_on_id IN ('src-late', 'vid-late')") == 2)

        try Self.addPodcast(store, "src-late")
        try Self.addVideo(store, "vid-late")
        #expect(try store.drainReadyProjections() == 2)
        #expect(try F.count(store, "SELECT COUNT(*) FROM visible_podcast_episode_overrides WHERE source_id = 'src-late'") == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM videos WHERE source_id = 'vid-late' AND liked_at IS NOT NULL") == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0)
    }

    @Test("A source deleted here keeps its hidden and dismissed Marks and its like, rows and records")
    func sourceDeleteKeepsMarks() throws {
        let (root, store) = try F.makeStore("mk-source-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try Self.writeEveryKind(store)
        try F.sendAll(store)
        try store.deleteSourceRows("src-a")
        try store.deleteSourceRows("src-vid")
        let pending = try F.pending(store)
        #expect(pending["Mark:mk:hidden:src:src-a"] == nil && pending["Mark:mk:liked:src:src-vid"] == nil)
        #expect(pending["Mark:mk:provenance:src:src-vid"] == nil && pending["Mark:mk:citedDecision:src:src-vid#cand-1"] == nil)
        #expect(try F.count(store, "SELECT COUNT(*) FROM hidden_sources WHERE source_id = 'src-a'") == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM dismissed_sources") == 1)
        #expect(try F.held(store, .mark, "mk:liked:src:src-vid")?.fields["on"] == .bool(true), "the server's like stays as it was")
        // The like waits for its video, and a re-import brings it back.
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected WHERE waiting_on_type = 'Source' AND waiting_on_id = 'src-vid'") >= 1)
        try Self.addVideo(store, "src-vid")
        _ = try store.drainReadyProjections()
        #expect(try F.count(store, "SELECT COUNT(*) FROM videos WHERE source_id = 'src-vid' AND liked_at = 700000000") == 1)
    }

    @Test("The activation makes a hide waiting for its source a hide, and the import-blocked shows exactly generation 1's list")
    func activationDerivesHidesAndBlocks() throws {
        let (root, store) = try F.makeStore("mk-activation", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try store.execute("INSERT INTO pending_hidden_sources (source_id, hidden_at) VALUES ('src-late', 900)")
        try store.execute("INSERT INTO hidden_sources (source_id, hidden_at) VALUES ('src-old', 100)")
        let blocked = try #require(PreferenceStore.encodePlist(["EPIC RADIO", "Spam Show"]))
        try store.execute("INSERT INTO user_preferences (key, value, updated_at) VALUES ('podcasts.blockedShows', ?, 4000)", [.text(blocked)])
        try store.inDerivationTransaction { try $0.rekeyPersonalStateRows() }
        try store.inDerivationTransaction { try $0.deriveBlockedPodcastShows() }
        #expect(try F.text(store, "SELECT group_concat(source_id || ':' || hidden_at, ',') FROM (SELECT * FROM hidden_sources ORDER BY 1)") == "src-late:900.0,src-old:100.0")
        #expect(try F.count(store, "SELECT COUNT(*) FROM pending_hidden_sources") == 0)
        #expect(try store.blockedPodcastShowNames() == ["EPIC RADIO", "Spam Show"])
        #expect(try F.count(store, "SELECT COUNT(*) FROM blocked_podcast_shows WHERE blocked_at = 4000") == 2)

        // Generation 1 unblocks one show before the activation runs again: exactly the row's list.
        let one = try #require(PreferenceStore.encodePlist(["epic radio"]))
        try store.execute("UPDATE user_preferences SET value = ?, updated_at = 5000 WHERE key = 'podcasts.blockedShows'", [.text(one)])
        try store.inDerivationTransaction { try $0.deriveBlockedPodcastShows() }
        #expect(try store.blockedPodcastShowNames().map { $0.lowercased() } == ["epic radio"])
    }

    @Test("Blocking and unblocking a show under generation 2 turns its Mark on and off")
    func blockedShowsWriter() throws {
        let (root, store) = try F.makeStore("mk-blocked")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try store.setBlockedPodcastShows(["EPIC RADIO", "Spam Show"])
        #expect(F.savedFields(try F.pending(store)["Mark:\(MarkKey.blockedShow("Spam Show").id)"])?["on"] == .bool(true))
        try F.sendAll(store)
        try store.setBlockedPodcastShows([" epic radio"])
        let pending = try F.pending(store)
        #expect(Set(pending.keys) == ["Mark:\(MarkKey.blockedShow("Spam Show").id)"], "a show still blocked writes nothing")
        #expect(F.savedFields(pending["Mark:\(MarkKey.blockedShow("Spam Show").id)"])?["on"] == .bool(false))
    }

    @Test("A hide made on a team's copy is the member's hide of the work, and unhiding either copy undoes it")
    func teamCopyHidesFollowTheWireKey() throws {
        let (root, store) = try F.makeStore("mark-team-hide", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addSource(store, "src-p")
        try NotebookSyncFixture.addTeamCopy(store, "team-copy", of: "src-p")
        try store.setSourceHidden("team-copy", hidden: true)
        #expect(try F.text(store, "SELECT group_concat(source_id) FROM hidden_sources") == "src-p", "kept under the wire key, once")
        #expect(try F.text(store, "SELECT CAST(is_hidden AS TEXT) FROM source_projection WHERE id = 'team-copy'") == "1")
        #expect(try F.text(store, "SELECT CAST(is_hidden AS TEXT) FROM source_projection WHERE id = 'src-p'") == "1", "the personal copy shares it")
        try store.setSourceHidden("team-copy", hidden: false)
        #expect(try F.count(store, "SELECT COUNT(*) FROM hidden_sources") == 0, "unhiding the copy deletes the row that was written")

        // A hide the activation re-keyed, undone from the copy.
        try store.execute("INSERT INTO hidden_sources (source_id, hidden_at) VALUES ('src-p', 5)")
        try store.setSourceHidden("team-copy", hidden: false)
        #expect(try F.count(store, "SELECT COUNT(*) FROM hidden_sources") == 0)

        // A podcast episode's overrides are keyed the same way and found from either copy.
        try Self.addPodcast(store, "pod-p")
        try store.execute("""
            INSERT INTO sources (id, date_added, state, source_type, status, team_id, wire_id) VALUES ('pod-team', 1, 'ready', 'podcast', 'active', 'team-1', 'pod-p')
        """)
        try store.setPodcastEpisodeVisibleOverride("pod-team", visible: true)
        #expect(try F.text(store, "SELECT group_concat(source_id) FROM visible_podcast_episode_overrides") == "pod-p")
        #expect(try store.loadVisiblePodcastEpisodeOverrideIDs().contains("pod-team"), "the loader names the local copy")
        try store.setPodcastEpisodeVisibleOverride("pod-team", visible: false)
        #expect(try F.count(store, "SELECT COUNT(*) FROM visible_podcast_episode_overrides") == 0)
    }
}
