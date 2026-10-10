import Foundation

// MARK: - Sources and collections (docs/cloudkit-schema-design.md §10, the `Source`, `Book`, `VideoPlaylist` and `MeetingGroup` rows)

extension LegacyV2Mapping {
    /// The Source fields an old Source record never gives: its file and machine-output satellites come
    /// through the asset pass (§13.6 "Assets"), as the activation queues them (`queueSourceFiles`).
    static let sourceFieldsNotGiven: Set<String> = ["files", "derived"]

    /// An old Source: its own record, its playlist Entry while its group id names a playlist (R6-2), its
    /// show's or channel's Collection (no owner, R6-m3), and its playlist's Collection when no
    /// `VideoPlaylist` record gives one (create only, R7-m5). A course's or a stray group id gives nothing.
    static func mapSource(_ payload: CloudKitSourcePayload, record: LegacyRecord, context: LegacyMappingContext, into mapping: inout LegacyMapping) throws {
        let article = payload.article
        let wireID = try context.wireID(.source, oldID: article.id, teamID: record.teamID)
        let group = sourceGroup(article)
        var groupNames: [String] = []
        if let group, article.sourceType == .video {
            groupNames.append(group)
            if let title = try context.videoPlaylistTitle(group) { groupNames.append(title) }
        }
        let membership: SourceCollectionMembership? = try group.flatMap { group in
            try context.collectionKind(groupID: group).map {
                SourceCollectionMembership(groupID: group, sortIndex: article.courseSortIndex.map(Int64.init), kind: $0)
            }
        }
        let rows = sourceRows(payload, membership: membership, groupNames: groupNames)
        var fields = SourceProjection.encodeRows(rows)
        for field in sourceFieldsNotGiven { fields.removeValue(forKey: field) }
        // `meta.attachments` is the meeting series' to give (§10, "Who owns what"); work keys only add (§4.2).
        fields["meta"] = fields["meta"].flatMap { meta in
            var elements = meta.objectValue ?? [:]
            elements.removeValue(forKey: "attachments")
            return elements.isEmpty ? nil : .object(elements)
        }
        mapping.records.append(LegacyV2Record(type: .source, id: wireID, fields: fields, giving: .owns))
        // The member's state this record feeds: its reading state, a like, a discovery origin and an override.
        if let state = sourceReadingState(payload, wireID: wireID, record: record) { mapping.records.append(state) }
        mapping.records += sourceMarks(payload, wireID: wireID, record: record)

        if let collectionID = SourceProjection.derivedCollectionID(rows), let name = sourceCollectionName(rows) {
            let kind = article.sourceType == .podcast ? "podcastShow" : "youtubeChannel"
            let collection = CollectionRows.derived(
                kind: kind, externalKey: name, title: name, subtitle: nil, author: nil, feed: nil, status: "active",
                addedAt: article.dateAdded.timeIntervalSinceReferenceDate
            )
            mapping.records.append(LegacyV2Record(type: .collection, id: collectionID, fields: CollectionProjection.encodeRows(collection), giving: .creates))
        }

        if let group, group.hasPrefix(PlaylistEntryProjection.playlistPrefix) {
            let entry = PlaylistEntryProjection.Rows(
                playlistID: group, sourceID: wireID, sortIndex: article.courseSortIndex.map(Int64.init),
                addedAt: article.dateAdded.timeIntervalSinceReferenceDate
            )
            mapping.records.append(LegacyV2Record(
                type: .entry, id: PlaylistEntryProjection.entryID(playlistID: group, sourceID: wireID),
                fields: PlaylistEntryProjection.encodeRows(entry), giving: .owns
            ))
            if try !context.holdsVideoPlaylist(group) {
                let collection = CollectionRows.derived(
                    kind: "playlist", externalKey: String(group.dropFirst(PlaylistEntryProjection.playlistPrefix.count)), title: group,
                    subtitle: nil, author: nil, feed: nil, status: "active", addedAt: article.dateAdded.timeIntervalSinceReferenceDate
                )
                mapping.records.append(LegacyV2Record(type: .collection, id: group, fields: CollectionProjection.encodeRows(collection), giving: .createsOnly))
            }
        }
    }

    /// The group a source is in, as `persistSourceRows` keeps it: a book's own id names it only for a
    /// book (the whole-book convention), every other type's self-group is dropped.
    static func sourceGroup(_ article: StudioArticle) -> String? {
        guard let group = article.parentGroup, !group.isEmpty else { return nil }
        return article.sourceType == .book || group != article.id ? group : nil
    }

    /// The show's or channel's name its Collection is keyed by (`deriveSourceCollections`).
    static func sourceCollectionName(_ rows: SourceRows) -> String? {
        switch rows.sourceType {
        case "podcast": return SourceProjection.venue(rows)
        case "video": return SourceCollections.channelName(domain: rows.text("domain"), url: rows.text("url"), groupNames: rows.groupNames)
        default: return nil
        }
    }

    /// The row values `persistSourceRows` writes for an old Source, as `SourceProjection.loadRows`
    /// reads them back: the `sources` row, its per-type table, its book or meeting series membership and
    /// the work keys the activation derives from its address and DOIs (`deriveSourceWorkKeys`).
    static func sourceRows(_ payload: CloudKitSourcePayload, membership: SourceCollectionMembership?, groupNames: [String]) -> SourceRows {
        let article = payload.article
        let localType = article.sourceType.rawValue
        let table = SourceLocalTables.subtypeTable(forLocalType: localType)
        let url = StorageService.relativeSourcePath(article.url)
        let normalized = URLNormalizer.normalize(article.url)
        let author = SourceAuthor.storable(article.sourceType == .paper ? StudioArticle.canonicalPaperAuthor(article.author) : article.author)
        let title = article.sourceType == .xPost ? article.title : KnowledgeStore.persistedTitle(for: article)
        let doi = article.doi?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let published = [payload.sourceIdentity?.publishedDOI, article.publishedDOI]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty }

        var subtype: [String: SQLiteValue] = [
            "url": .text(url), "title": .text(title), "domain": .text(article.domain),
            "word_count": .integer(article.wordCount.map(Int64.init)), "normalized_url": .text(normalized),
            "local_file_path": .text(article.localFilePath.map(StorageService.relativeSourcePath)),
        ]
        switch table {
        case "articles", "x_posts":
            subtype["author"] = .text(author)
            if table == "x_posts" { subtype["author_handle"] = .null }
        case "papers":
            subtype["author"] = .text(author)
            subtype["doi"] = .text(doi)
            subtype["published_doi"] = .text(published)
            subtype["journal"] = .text(article.journal)
            subtype["published_year"] = .text(article.publishedYear)
            subtype["is_paywalled"] = .integer(article.isPaywalled ? 1 : 0)
        case "podcasts":
            subtype["show_name"] = .text(article.domain)
        case "meeting_sources":
            subtype["occurred_at"] = .real(article.dateAdded.timeIntervalSinceReferenceDate)
            subtype["presenter"] = .text(author)
        case "videos":
            subtype["video_published_at"] = .real(article.videoPublishedAt?.timeIntervalSinceReferenceDate)
        default:
            break
        }
        var rows = SourceRows(
            sourceID: article.id, dateAdded: article.dateAdded.timeIntervalSinceReferenceDate, state: article.state.rawValue,
            errorMessage: article.errorMessage, sourceType: localType, status: article.status.rawValue, subtypeTable: table,
            subtype: subtype, membership: membership
        )
        rows.workKeys = SourceWorkKeys.keys(url: url, normalizedURL: normalized, doi: doi).sorted()
        rows.groupNames = groupNames
        return rows
    }

    // MARK: Collections

    /// An old Book: its Collection (`saveBookRecord`).
    static func book(_ payload: CloudKitBookPayload) -> LegacyV2Record {
        let rows = CollectionRows.book(id: payload.id, title: payload.title, subtitle: payload.subtitle, author: SourceAuthor.storable(payload.author))
        return LegacyV2Record(type: .collection, id: payload.id, fields: CollectionProjection.encodeRows(rows), giving: .owns)
    }

    /// An old VideoPlaylist: its Collection only. Its members' Entries are their Sources' (R6-2).
    static func videoPlaylist(_ payload: CloudKitVideoPlaylistPayload) -> LegacyV2Record {
        let rows = CollectionRows.playlist(title: payload.metadata.title, url: payload.metadata.playlistURL)
        return LegacyV2Record(type: .collection, id: payload.id, fields: CollectionProjection.encodeRows(rows), giving: .owns)
    }

    /// An old MeetingGroup: its Collection (`saveMeetingGroup`), its action items' Tasks, and, fed, each
    /// session Source's `meta.attachments` from the series' files and links (`saveMeetingArtifactsRecord`).
    /// The series is always silent on its Tasks: generation 1 unions a record's items with the ones a Mac
    /// holds, and an older client's payload omits the key (R6-m4), so an item left out removes nothing.
    static func mapMeetingGroup(_ payload: CloudKitMeetingGroupPayload, record: LegacyRecord, context: LegacyMappingContext, into mapping: inout LegacyMapping) throws {
        let metadata = payload.metadata
        let schedule = metadata.schedule?.jsonString.flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue
        let rows = CollectionRows.meetingSeries(
            id: payload.id, title: metadata.title ?? payload.id, driveFolderURL: metadata.driveFolderURL,
            recurrenceRule: metadata.recurrenceRule, timezone: metadata.timezone, mergedInto: metadata.mergedIntoGroupID, schedule: schedule
        )
        mapping.records.append(LegacyV2Record(type: .collection, id: payload.id, fields: CollectionProjection.encodeRows(rows), giving: .owns))

        var bySource: [String: [String: SyncJSON]] = [:]
        for artifact in payload.artifacts where !artifact.sourceId.isEmpty {
            var object: [String: SyncJSON] = ["kind": .string(artifact.kind.rawValue), "title": .string(artifact.title)]
            if let url = artifact.url { object["url"] = .string(url) }
            if let mime = artifact.mimeType { object["mime"] = .string(mime) }
            object["order"] = SyncJSON(Int64(artifact.sortIndex))
            bySource[artifact.sourceId, default: [:]][artifact.id] = .object(object)
        }
        for (sourceID, attachments) in bySource.sorted(by: { $0.key < $1.key }) {
            mapping.records.append(LegacyV2Record(
                type: .source, id: try context.wireID(.source, oldID: sourceID, teamID: record.teamID),
                fields: ["meta": .object(["attachments": .object(attachments)])], giving: .feeds
            ))
        }
        mapping.records += actionItemTasks(payload.actionItems ?? [], groupID: payload.id)
        mapping.silentChildren.insert(LegacyChildScope(type: .task))
    }
}
