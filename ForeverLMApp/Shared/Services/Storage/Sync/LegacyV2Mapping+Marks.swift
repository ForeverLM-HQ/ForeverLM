import Foundation

// MARK: - The member's Marks (docs/cloudkit-schema-design.md §10, §3.5.19)

extension LegacyV2Mapping {
    /// A Mark an old record gives. `on` makes it (no owner: whichever old record gives it first creates
    /// it); off is `clears`, which turns an existing Mark off and makes none, since a state that was never
    /// on is no change to a Mark that was never made. `at` is Cocoa seconds, as `MarkRows` holds it.
    static func mark(_ key: MarkKey, on: Bool, value: SyncJSON? = nil, at: Date?) -> LegacyV2Record {
        let rows = MarkRows(key: key, on: on, value: on ? value : nil, at: at?.timeIntervalSinceReferenceDate)
        return LegacyV2Record(type: .mark, id: key.id, fields: MarkProjection.encodeRows(rows), giving: on ? .creates : .clears)
    }

    /// The Marks a Hidden*, DismissedSource, SourceIdea or VideoCitedPaper record gives, from the same
    /// rows the activation notebooks (`MarkProjection.load`). A hide, a dismissal and a block are on while
    /// their old record exists; no old-world deletion turns one off (§13.6: no old-world change removes a Mark).
    static func mapMarkRecord(_ payload: LegacyPayload, record: LegacyRecord, context: LegacyMappingContext) throws -> [LegacyV2Record] {
        switch payload {
        case .hiddenSource(let hidden):
            return [mark(MarkKey.source("hidden", try context.sourceWireID(hidden.sourceID)), on: true, at: hidden.hiddenAt)]
        case .hiddenPodcastShow(let hidden):
            return [mark(MarkKey.hiddenShow(hidden.showName), on: true, value: ["name": .string(hidden.showName)], at: hidden.hiddenAt)]
        case .hiddenYouTubeChannel(let hidden):
            return [mark(MarkKey.hiddenChannel(hidden.channelName), on: true, value: ["name": .string(hidden.channelName)], at: hidden.hiddenAt)]
        case .hiddenArtifact(let hidden):
            return [mark(MarkKey(kind: "hidden", target: "art:" + hidden.artifactID), on: true, at: hidden.hiddenAt)]
        case .hiddenReviewSession(let hidden):
            return [mark(MarkKey(kind: "hidden", target: "cht:" + hidden.sessionID), on: true, at: hidden.hiddenAt)]
        case .dismissedSource(let dismissed):
            var value: [String: SyncJSON] = ["url": .string(dismissed.url)]
            if let title = dismissed.title { value["title"] = .string(title) }
            return [mark(MarkKey.dismissed(url: dismissed.url), on: true, value: .object(value), at: dismissed.dismissedAt)]
        case .sourceIdea(let payload):
            // The ideas themselves are the source's `ideas` satellite, which the asset pass gives (§13.6).
            let key = MarkKey.source("wantIdea", try context.sourceWireID(payload.idea.sourceID), sub: payload.idea.id)
            return [mark(key, on: payload.idea.wanted, at: payload.idea.wanted ? payload.idea.updatedAt : record.modifiedAt)]
        case .videoCitedPaper(let payload):
            let paper = payload.paper
            let key = MarkKey.source("citedDecision", try context.sourceWireID(paper.sourceID), sub: paper.id)
            guard let decided = CitedDecision(localStatus: paper.status.rawValue) else {
                // Pending and unresolved are no decision: a decided candidate put back is cleared.
                return [mark(key, on: false, at: record.modifiedAt)]
            }
            var value: [String: SyncJSON] = ["status": .string(decided.rawValue)]
            if let imported = paper.importedSourceID { value["importedSourceID"] = .string(imported) }
            return [mark(key, on: true, value: .object(value), at: paper.updatedAt)]
        default:
            return []
        }
    }

    /// The `following` Mark of an auto-importing playlist (`video_playlists.auto_import`).
    static func followingMark(_ payload: CloudKitVideoPlaylistPayload, record: LegacyRecord) -> LegacyV2Record {
        let key = MarkKey(kind: "following", target: "col:" + payload.id)
        return mark(key, on: payload.metadata.autoImport, value: ["autoImport": .bool(true)], at: payload.metadata.autoImport ? nil : record.modifiedAt)
    }

    /// The Marks a Source record gives: a YouTube like (`videos.liked_at`), its discovery origin, and a
    /// visible override of a podcast episode or a YouTube video. A like or an origin on a team copy makes
    /// none, since the personal copy's row holds the member's (§3.5.19); a key the payload omits gives nothing.
    static func sourceMarks(_ payload: CloudKitSourcePayload, wireID: String, record: LegacyRecord) -> [LegacyV2Record] {
        let article = payload.article
        var marks: [LegacyV2Record] = []
        if record.teamID == nil {
            if let liked = article.likedAt {
                marks.append(mark(
                    MarkKey.source("liked", wireID), on: true,
                    value: ["at": SyncJSON(SyncTime.milliseconds(cocoaSeconds: liked.timeIntervalSinceReferenceDate))], at: liked
                ))
            }
            if let origin = article.discoveryOrigin?.rawValue, !origin.isEmpty {
                marks.append(mark(
                    MarkKey.source("provenance", wireID), on: true,
                    value: ["origin": .string(origin), "at": SyncJSON(SyncTime.milliseconds(cocoaSeconds: article.dateAdded.timeIntervalSinceReferenceDate))],
                    at: article.dateAdded
                ))
            }
        }
        // The override flags are explicit for a podcast episode and a YouTube video: false deletes the row.
        let overridable = article.sourceType == .podcast ? payload.visiblePodcastEpisodeOverride
            : (article.sourceType == .video && article.isYouTubeURL ? payload.visibleYouTubeVideoOverride : nil)
        if let visible = overridable {
            marks.append(mark(MarkKey.source("visibleOverride", wireID), on: visible, at: record.modifiedAt))
        }
        return marks
    }

    /// The Marks a chat's ratings give: one `rated` Mark per exchange the learner thumbed (a payload that
    /// carries no rating says nothing, so it never blanks one the other device made).
    static func ratingMarks(_ exchanges: [CloudKitReviewExchangePayload]) -> [LegacyV2Record] {
        exchanges.sorted { $0.sequenceNumber < $1.sequenceNumber }.compactMap { exchange in
            guard let rating = exchange.rating else { return nil }
            var value: [String: SyncJSON] = ["rating": .string(rating), "field": .string(exchange.ratingField ?? "evaluation")]
            if let reason = exchange.ratingReason { value["reason"] = .string(reason) }
            return mark(MarkKey(kind: "rated", target: "exc:" + exchange.id), on: true, value: .object(value), at: exchange.ratedAt)
        }
    }

    /// `podcasts.blockedShows` (Mark `importBlocked`): exactly the shows the row lists, each blocked at
    /// the row's time, and every show this Mac holds blocked that it no longer lists turned off, as
    /// `deriveBlockedPodcastShows` does.
    static func blockedShowMarks(names: [String], updatedAt: Date, context: LegacyMappingContext) throws -> [LegacyV2Record] {
        let wanted = Dictionary(names.map { (SourceDiscovery.podcastShowKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        var marks: [LegacyV2Record] = []
        for (key, name) in wanted.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            marks.append(mark(MarkKey.blockedShow(name), on: true, value: ["name": .string(name)], at: updatedAt))
        }
        for held in try context.heldBlockedShows() where wanted[SourceDiscovery.podcastShowKey(held)] == nil {
            marks.append(mark(MarkKey.blockedShow(held), on: false, at: updatedAt))
        }
        return marks
    }
}
