import Foundation
import OSLog

/// Giving meeting rows a picture.
///
/// `MeetingIconService` decides where a picture comes from; this decides which
/// sessions get one and when. The split matters because the two halves have
/// different rules: the service is free to try the cheap sources for anything,
/// while the decision to spend belongs to an explicit act by the learner or to
/// a setting they turned on.
extension StudioViewModel {

    /// Sessions whose icon does not yet match what the learner asked for. This
    /// is what the Settings button counts, so it counts what a learner would
    /// count: rows that still look wrong, including archived ones they may yet
    /// restore.
    ///
    /// Under Always Draw that includes meetings already showing a clipped
    /// frame. Those frames are the reason someone chooses Always Draw, so a
    /// count that called them finished would leave the setting looking inert.
    var meetingsMissingIconCount: Int {
        let source = MacImageGenerationSettings.effectiveSource
        return articles.count {
            $0.sourceType == .meeting && !Self.hasSatisfactoryIcon($0, source: source)
        }
    }

    /// Reads the stored path, the preference, and whether the picture is on this
    /// disk — nothing on the view model, so it stays off the main actor like
    /// `iconRunSummary` below.
    ///
    /// `iconIsOnDisk` is a seam for tests, which have no business writing into
    /// the learner's content root to express "this path has bytes behind it".
    nonisolated static func hasSatisfactoryIcon(
        _ article: StudioArticle,
        source: ImageGenerationCatalog.Source,
        iconIsOnDisk: (String) -> Bool = { MeetingIconService.hasStoredIconFile(forArtworkURL: $0) }
    ) -> Bool {
        guard let artwork = article.artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !artwork.isEmpty else { return false }
        // Artwork this app did not write — a podcast cover, a YouTube still —
        // is not ours to second-guess.
        guard MeetingIconService.localArtworkPath(for: artwork) != nil else { return true }
        // A path is not a picture. This read the stored string and stopped, so a
        // Mac that had been sent an icon's path but not its bytes counted itself
        // finished: the row drew the fallback glyph, the Settings count said
        // zero, and no button on this Mac would ever fix it. The icon asset
        // carries the bytes now, and this is what makes a Mac still waiting for
        // them ask rather than sit satisfied.
        guard iconIsOnDisk(artwork) else { return false }
        guard source.drawsEverything else { return true }
        return MeetingIconService.isDrawnIconPath(artwork)
    }

    /// The recording artifact for a session, which both free icon sources need.
    private func meetingRecording(for sourceID: String) -> MeetingArtifact? {
        meetingArtifactsBySourceId[sourceID]?.first { $0.kind == .recording }
    }

    private func iconRequest(
        for article: StudioArticle,
        allowsGeneration: Bool,
        source: ImageGenerationCatalog.Source
    ) -> MeetingIconService.Request {
        let recording = meetingRecording(for: article.id)
        return MeetingIconService.Request(
            sourceID: article.id,
            title: article.title,
            presenter: article.author,
            groupTitle: article.parentGroup.map { meetingDisplayName($0) },
            recordingURLOrID: recording?.url ?? recording?.localFilePath,
            recordingMIMEType: recording?.mimeType,
            recordingModifiedAt: recording?.modifiedAt,
            localRecordingPath: recording?.localFilePath,
            allowsGeneration: allowsGeneration,
            source: source
        )
    }

    /// Resolve icons for the named sessions, at most a few at a time.
    ///
    /// Bounded because each one is a Drive round trip or a paid generation, and
    /// eighty of either at once is how a plugin starts refusing requests.
    /// The result counts what each source produced, which is what lets the
    /// caller say how many icons were *drawn* rather than merely how many rows
    /// changed.
    @discardableResult
    func resolveMeetingIcons(
        sourceIDs: [String],
        allowsGeneration: Bool
    ) async -> [MeetingIconService.Origin: Int] {
        let source = MacImageGenerationSettings.effectiveSource
        let requests = sourceIDs.compactMap { id -> MeetingIconService.Request? in
            guard let article = articlesById[id],
                  article.sourceType == .meeting,
                  !Self.hasSatisfactoryIcon(article, source: source) else { return nil }
            return iconRequest(for: article, allowsGeneration: allowsGeneration, source: source)
        }
        guard !requests.isEmpty else { return [:] }

        var counts: [MeetingIconService.Origin: Int] = [:]
        var index = 0
        let window = 3

        await withTaskGroup(of: (String, MeetingIconService.Outcome?).self) { group in
            func addNext() {
                guard index < requests.count else { return }
                let request = requests[index]
                index += 1
                group.addTask {
                    let outcome = await MeetingIconService.shared.icon(for: request)
                    return (request.sourceID, outcome)
                }
            }
            for _ in 0..<min(window, requests.count) { addNext() }

            while let (sourceID, outcome) = await group.next() {
                addNext()
                guard let outcome else { continue }
                counts[outcome.origin, default: 0] += 1
                await applyIcon(outcome, to: sourceID)
            }
        }
        return counts
    }

    private func applyIcon(_ outcome: MeetingIconService.Outcome, to sourceID: String) async {
        guard let index = articles.firstIndex(where: { $0.id == sourceID }) else { return }
        var article = articles[index]
        // A path that already matches is not proof there is nothing to save.
        // On a Mac that was sent an icon's path but never its bytes, a fresh
        // capture writes the file at exactly the path already on record — and
        // returning here left that record unchanged, so the icon this Mac had
        // just made stayed on this Mac. Only a run that wrote nothing new is a
        // no-op.
        guard article.artworkURL != outcome.relativePath || outcome.wroteFile else { return }
        article.artworkURL = outcome.relativePath
        if await persistSource(article, context: "Save meeting icon"),
           let current = articles.firstIndex(where: { $0.id == sourceID }) {
            articles[current] = article
        }
    }

    /// The free pass, run after an import brings in new sessions. Never draws:
    /// an import is not a purchase, unless the learner said it was in Settings.
    func backfillIconsForImportedMeetings(sourceIDs: [String]) async {
        guard !sourceIDs.isEmpty else { return }
        let allowsGeneration = MacImageGenerationSettings.isEnabled
            && MacImageGenerationSettings.generatesForNewMeetings
        await resolveMeetingIcons(sourceIDs: sourceIDs, allowsGeneration: allowsGeneration)
    }

    /// The Settings button: every session without a picture, free sources first
    /// and the model only for what they could not cover.
    func generateMissingMeetingIcons() async {
        let source = MacImageGenerationSettings.effectiveSource
        let pending = articles
            .filter { $0.sourceType == .meeting && !Self.hasSatisfactoryIcon($0, source: source) }
            .map(\.id)
        guard !pending.isEmpty else { return }

        let counts = await resolveMeetingIcons(
            sourceIDs: pending,
            allowsGeneration: MacImageGenerationSettings.isEnabled
        )
        showToast(Self.iconRunSummary(counts: counts, attempted: pending.count))
    }

    /// Says which of the three sources did the work, because "37 icons" hides
    /// the only number with a price attached.
    nonisolated static func iconRunSummary(
        counts: [MeetingIconService.Origin: Int],
        attempted: Int
    ) -> String {
        let found = (counts[.driveThumbnail] ?? 0) + (counts[.recordingFrame] ?? 0)
        let drawn = counts[.generated] ?? 0
        if found == 0 && drawn == 0 {
            return "No icons could be added to \(attempted) meeting\(attempted == 1 ? "" : "s")."
        }
        var parts: [String] = []
        if found > 0 { parts.append("\(found) from recordings") }
        if drawn > 0 { parts.append("\(drawn) drawn") }
        let total = found + drawn
        return "Added \(total) meeting icon\(total == 1 ? "" : "s") — \(parts.joined(separator: ", "))."
    }
}
