import Foundation

// MARK: - Written faces on the plane (WP-B1)
//
// docs/sensemaking-design.md, "Written faces". A source card drawn on the
// Canvas reads at three distances: far, a few words of what it is about; mid,
// its main finding in a sentence; near, its question, approach and finding.
// They are written by the Canvas Summaries model in the background
// (`StudioViewModel.refreshKnowledgeMapFaces`), kept in `source_faces` against
// the text they were written from, and drawn in place of a cut title. The
// learner's own words (an Idea's sentence) are never replaced.

/// The faces pass's bookkeeping for this session.
@MainActor
final class KnowledgeMapFacesState {
    /// A pass request's number: only the latest one after a burst of moves
    /// goes on, and a request while a pass runs makes it run once more.
    var request = 0
    var isRunning = false
    var runAgain = false
    /// The stored rows read or written this session, by source id.
    var rows: [String: SourceFacesRow] = [:]
    /// The sources whose stored row was looked for already.
    var looked: Set<String> = []
    /// Each source's fingerprint, with the cheap signature it was taken at: a
    /// source whose title, length or state is unchanged is not read again.
    var fingerprints: [String: (signature: String, fingerprint: String)] = [:]
    /// Fingerprints the model gave no faces for this session; not asked again
    /// until the text changes.
    var unanswered: Set<String> = []
    /// When a pass last failed: writing waits a while after one, so a broken
    /// model is not asked on every move.
    var failedAt: Date?

    static let retryAfterFailure: TimeInterval = 300
}

extension KnowledgeMapModel {
    /// The source cards the plane draws, by source id: the placed ones, then
    /// those hanging under a placed Idea as its evidence.
    var drawnSourceIDs: [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        func add(_ ref: String) {
            guard let item = KnowledgeMap.ItemRef(ref), item.kind == .source,
                  nodesByRef[ref] != nil, seen.insert(item.id).inserted else { return }
            ids.append(item.id)
        }
        for ref in layout.placements.keys.sorted() { add(ref) }
        let placedIdeas = Set(layout.placements.keys.filter { $0.hasPrefix("idea:") })
        if !placedIdeas.isEmpty {
            for link in content.links where link.kind == "idea" && placedIdeas.contains(link.a) { add(link.b) }
        }
        return ids
    }

    /// Takes stored or newly written faces, keyed by the card's ref.
    func storeFaces(_ rows: [SourceFacesRow]) {
        guard !rows.isEmpty else { return }
        for row in rows {
            facesState.rows[row.sourceID] = row
            faces[KnowledgeMap.ItemRef(kind: .source, id: row.sourceID).description] = KnowledgeMapFaces.Face(far: row.far, mid: row.mid, near: row.near)
        }
        facesRevision &+= 1
    }

    /// What the renderer's `setFaces` takes.
    struct FacesPayload: Encodable {
        var enabled: Bool
        var faces: [String: KnowledgeMapFaces.Face]
    }

    var facesPayload: FacesPayload {
        FacesPayload(enabled: showsWrittenFaces, faces: faces)
    }
}
