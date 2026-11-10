import CryptoKit
import Foundation

/// The phone's writes to the library: each change goes to the replica through `MobileRecordWriter`,
/// which sends it. The phone holds no other copy of the library.
actor MobileCloudMutationService {
    static let shared = MobileCloudMutationService()

    private let recordWriter: @Sendable () async -> MobileRecordWriter?

    init(writer: @escaping @Sendable () async -> MobileRecordWriter? = { await MobileRecordWriter.current() }) {
        recordWriter = writer
    }

    private func requiredWriter() async throws -> MobileRecordWriter {
        try await MobileRecordWriter.required(from: recordWriter)
    }

    // MARK: - Notebooks

    /// A notebook has no deadline: since the Mac's schema 120 that is what
    /// tells it from a Goal, so `endAt` is the open-ended sentinel the Mac and
    /// the web store. Until 2026-10-02 this wrote today + 30 days, and every
    /// notebook made on the phone read as a Goal due in a month everywhere
    /// else.
    func createNotebook(title: String, instructions: String?, summary: String? = nil) async throws -> String {
        let writer = try await requiredWriter()
        do {
            return try await writer.createNotebook(title: title, instructions: instructions, summary: summary)
        } catch MobileRecordWriterError.emptyTitle {
            throw MobileCloudMutationError.emptyNotebookTitle
        }
    }

    func updateNotebook(
        id: String,
        title: String? = nil,
        instructions: String? = nil,
        replaceInstructions: Bool = false,
        summary: String? = nil,
        replaceSummary: Bool = false,
        status: String? = nil
    ) async throws {
        let writer = try await requiredWriter()
        try await writer.transaction {
            try $0.updateNotebook(id, title: title, instructions: instructions, replaceInstructions: replaceInstructions,
                                  summary: summary, replaceSummary: replaceSummary, status: status)
        }
    }

    /// Add a Notebook to Context: links `contextNotebookID` to the notebook
    /// `id` after the notebooks it already links to, in the order the record
    /// holds them now, so a link made on another device meanwhile stays; one
    /// already linked stays where it is. Whether the notebook's chats read
    /// it is the member's own row, never the record (`NotebookChatContext`).
    func linkContextNotebook(_ contextNotebookID: String, toNotebookID id: String) async throws {
        guard !contextNotebookID.isEmpty, contextNotebookID != id else {
            throw MobileCloudMutationError.invalidNotebook
        }
        let writer = try await requiredWriter()
        try await writer.transaction { try $0.setRelatedNotebook(contextNotebookID, of: id, linked: true) }
    }

    /// Take Out of Context: unlinks `contextNotebookID` from the notebook
    /// `id`; its other links keep their order.
    func unlinkContextNotebook(_ contextNotebookID: String, fromNotebookID id: String) async throws {
        let writer = try await requiredWriter()
        try await writer.transaction { try $0.setRelatedNotebook(contextNotebookID, of: id, linked: false) }
    }

    func addSources(_ sources: [MobileCloudSource], toNotebookID notebookID: String) async throws {
        guard !sources.isEmpty else { return }
        let writer = try await requiredWriter()
        let ids = sources.map(\.id)
        try await writer.transaction { _ = try $0.fileSources(ids, into: notebookID) }
    }

    func removeSources(_ sourceIDs: Set<String>, fromNotebookID notebookID: String) async throws {
        guard !sourceIDs.isEmpty else { return }
        let writer = try await requiredWriter()
        try await writer.transaction { try $0.removeSources(sourceIDs, from: notebookID) }
    }

    func deleteNotebook(id: String, deleteLinkedChats: Bool) async throws {
        let writer = try await requiredWriter()
        try await writer.transaction { try $0.deleteNotebook(id, deleteLinkedChats: deleteLinkedChats) }
    }

    // MARK: - Schedule

    func schedule(
        source: MobileCloudSource,
        on date: Date,
        notebookID: String?,
        existing: MobileCloudScheduledSource?,
        order: Int
    ) async throws {
        let writer = try await requiredWriter()
        // One Placement per source (`pl:<sourceID>`), tagged with the notebook it serves (§3.5.21).
        try await writer.transaction { try $0.schedule(source.id, on: date, order: order, goalID: notebookID) }
    }

    /// Completion is always a fact someone produced: a saved review
    /// record, or the learner checking the item off on today's plan card.
    /// Nothing the app merely observes — an open, a play — ever calls this.
    func completeScheduledSource(sourceID: String) async throws {
        let writer = try await requiredWriter()
        try await writer.transaction { try $0.completePlacement(sourceID, at: Date()) }
    }

    /// Create today's pending calendar placement when source activity starts,
    /// and carry how deep into the source the learner has reached.
    /// Existing explicit plans remain, while automatic-only placements follow
    /// the learner's current activity day.
    ///
    /// `fraction` is the learner's furthest point as a 0...1 share of the whole
    /// source, or nil when the surface cannot measure one. It merges with MAX,
    /// so it is safe to send repeatedly and it never walks backwards.
    func recordSourceActivity(
        source: MobileCloudSource,
        existingPlacement: MobileCloudScheduledSource?,
        startedAt: Date,
        order: Int,
        kind: SourceActivityKind,
        fraction: Double? = nil,
        engagedSeconds: Double = 0
    ) async throws -> MobileCloudScheduledSource {
        // The time goes on this device's ActivityLog of the day (§3.5.24), once the source has 30 s of
        // engaged use: opening alone writes nothing (P9). Logged activity puts the source on the Schedule:
        // an automatic Placement on the day, or one that follows it.
        let writer = try await requiredWriter()
        let logged = try await MobileActivityLogRecorder.shared.record(sourceID: source.id, kind: kind, at: startedAt, fraction: fraction,
                                                                       engagedSeconds: engagedSeconds, completed: false, writer: writer)
        guard logged else { return existingPlacement ?? Self.unsavedPlacement(source: source, at: startedAt, completedAt: nil) }
        return try await writer.transaction { write in
            try write.placeAutomatically(source.id, at: startedAt, order: order)
            return try write.scheduledSource(source.id)
        } ?? Self.unsavedPlacement(source: source, at: startedAt, completedAt: nil)
    }

    /// Records the same durable consumption fact the Mac writes when a learner
    /// reaches the end of a source in the reader. Finishing text-to-speech playback
    /// uses this path too: `readAt` feeds the retention queue, while the completed
    /// Schedule placement makes day-based requests such as "review yesterday's
    /// listening" resolvable through MCP.
    ///
    /// A source that was already planned keeps that planned day; an unplanned
    /// source is placed on the completion day already checked off, matching
    /// `StudioViewModel.recordReadOnTodaysSchedule` on macOS.
    func recordSourceConsumption(
        source: MobileCloudSource,
        existingPlacement: MobileCloudScheduledSource?,
        completedAt: Date,
        order: Int,
        kind: SourceActivityKind
    ) async throws -> MobileCloudScheduledSource {
        let writer = try await requiredWriter()
        // The member's ReadingState marks it read (and listened to), the first time standing, and the
        // device's ActivityLog records the completion; its Placement on the day (automatic when it had
        // none) is done, and the source completed (§3.5.21, §10).
        try await writer.transaction { try $0.markRead(source.id, at: completedAt, consumed: kind == .listening) }
        try await MobileActivityLogRecorder.shared.record(sourceID: source.id, kind: kind, at: completedAt, fraction: 1,
                                                          engagedSeconds: 0, completed: true, writer: writer)
        return try await writer.transaction { write in
            try write.consumePlacement(source.id, at: completedAt, order: order)
            return try write.scheduledSource(source.id)
        } ?? Self.unsavedPlacement(source: source, at: completedAt, completedAt: completedAt)
    }

    // MARK: - Source capture and deletion

    /// A link the learner captured, as a Source (or a Job a Mac runs when the
    /// phone cannot make the Source itself).
    func captureSource(url: URL, title: String?, sourceType: String) async throws -> String {
        try await captureSource(url: url, title: title, sourceType: sourceType, target: nil)
    }

    /// A capture filed into `target` (D47): the Job's target before the first complete `Catalog` pass and
    /// the Entry after it.
    func captureSource(url: URL, title: String?, sourceType: String, target: MobileCaptureTarget?) async throws -> String {
        let writer = try await requiredWriter()
        guard let id = try await writer.transaction({ try $0.captureURL(url, title: title, sourceType: sourceType, target: target) }) else {
            throw MobileRecordWriterError.queuedForMac
        }
        return id
    }

    /// A PDF the learner picked or scanned, as a Source whose `pdf` satellite the writer uploads.
    func captureFile(url: URL, title: String?) async throws -> String {
        try await captureFile(url: url, title: title, capture: "pdf", target: nil)
    }

    /// A PDF filed into `target` (D47); `capture` is how it was made (`pdf`, `scan`, `photos`, `share`).
    func captureFile(url: URL, title: String?, capture: String, target: MobileCaptureTarget?) async throws -> String {
        let writer = try await requiredWriter()
        guard url.isFileURL else { throw MobileCloudMutationError.unsupportedCaptureURL }
        return try await writer.captureFile(at: url, title: title, capture: capture, target: target)
    }

    func deleteSource(
        _ source: MobileCloudSource,
        notebooks: [MobileCloudNotebook],
        scheduledSources: [MobileCloudScheduledSource],
        highlights: [SourceHighlight]
    ) async throws {
        let writer = try await requiredWriter()
        // The Source and its explainer go; per-member state, highlights included, stays (§5.4, D18).
        let explainerID = Self.explainerSourceID(explaining: source.id)
        try await writer.transaction { try $0.deleteSource(source.id, explainerID: explainerID == source.id ? nil : explainerID) }
    }

    // MARK: - Explainers

    /// The id the explainer of a source has, on every device: the Mac derives
    /// it from the same `foreverlm://explainer/<sourceID>` URL with the same
    /// normalizer and hash (`GeneratedExplainer.sourceID(explaining:)`), which
    /// `MobileCloudMutationServiceTests` pins against a literal.
    nonisolated static func explainerSourceID(explaining explainedSourceID: String) -> String {
        Self.sourceID(forNormalizedURL: MobileURLNormalizer.normalize(ExplainerScript.url(explaining: explainedSourceID)))
    }

    /// The id of the source a notebook's audio overview keeps its script and
    /// audio on, from the overview's Artifact id: the Mac derives it from the
    /// same `foreverlm://audio-overview/<artifactID>` URL with the same
    /// normalizer and hash (`GeneratedAudioOverview.carrierSourceID`), which
    /// `MobileCloudMutationServiceTests` pins against a literal.
    nonisolated static func audioOverviewSourceID(artifactID: String) -> String {
        Self.sourceID(forNormalizedURL: MobileURLNormalizer.normalize(
            TextToSpeechPreparationPolicy.audioOverviewURLPrefix + artifactID
        ))
    }

    /// Saves the spoken explainer of one source as the article-typed Source the
    /// Mac writes for it (explainer-design.md): the same URL grammar and the
    /// same id, so the Mac's Explain button opens this one and a rewrite from
    /// either device replaces it rather than adding a row. It is a Source in the
    /// learner's `Catalog`, its script the `files.text` satellite. Returns the
    /// explainer's id.
    func saveExplainer(explaining source: MobileCloudSource, script: String) async throws -> String {
        let writer = try await requiredWriter()
        return try await writer.saveExplainer(MobileExplainerOrigin(source), script: script)
    }

    func saveSourceHighlight(_ highlight: SourceHighlight, source: MobileCloudSource) async throws {
        let writer = try await requiredWriter()
        // The member's Highlight record in Library, on the source's canonical id (§3.5.17).
        try await writer.transaction { try $0.saveHighlight(highlight) }
    }

    func deleteSourceHighlight(id: String) async throws {
        let writer = try await requiredWriter()
        try await writer.transaction { try $0.deleteHighlight(id) }
    }

    func archiveSource(
        _ source: MobileCloudSource,
        notebooks: [MobileCloudNotebook],
        scheduledSources: [MobileCloudScheduledSource]
    ) async throws {
        guard let url = source.url, !url.isEmpty else {
            throw MobileCloudMutationError.missingSourceURL
        }
        let writer = try await requiredWriter()
        try await writer.transaction { try $0.archiveSource(source.id) }
    }

    /// Publishes a walkthrough the phone wrote as the source's `walkthrough`
    /// satellite (`MobileRecordWriter.saveWalkthrough`). The Mac keeps it only
    /// while it matches the source's canonical text, as it does for a
    /// walkthrough another Mac wrote; a later one from any device replaces it.
    func savePaperWalkthrough(_ walkthrough: PaperWalkthrough) async throws {
        let writer = try await requiredWriter()
        try await writer.saveWalkthrough(walkthrough)
    }

    /// The placement a screen keeps for a source until its Placement is written.
    private static func unsavedPlacement(source: MobileCloudSource, at date: Date, completedAt: Date?) -> MobileCloudScheduledSource {
        MobileCloudScheduledSource(id: SyncIdentity.placementID(sourceID: source.id), sourceID: source.id, sourceIdentity: nil,
                                   plannedAt: Calendar.current.startOfDay(for: date), completedAt: completedAt, goalIDs: [],
                                   updatedAt: date, isAutomatic: true)
    }

    private static func sourceID(forNormalizedURL value: String) -> String {
        let digest = SHA256.hash(data: Data("source:v1:\(value)".utf8))
        return "src_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func cleanTitle(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(90))
    }

    static func cleanInstructions(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(4_000))
    }

    /// The Notebook card's one-line description, stored the way the Mac stores it:
    /// the shared Portable rule (`NotebookSummary.normalized`), so the two clients
    /// never disagree about collapsed whitespace or the length cap.
    static func cleanSummary(_ value: String?) -> String? {
        NotebookSummary.normalized(value)
    }

    /// The label of a page ForeverLM links rather than imports, or nil for an
    /// ordinary address. The product owner (2026-09-09): "codex sites should always
    /// obviously be ingested as a 'site' not as an article". The Mac's rule is
    /// `LinkedPage.kind(of:)` (Shared/Models/LinkedPage.swift), which this
    /// target does not compile, so the three hosts are repeated here — a Codex
    /// site at `<site>.<workspace>.chatgpt.site` (the bare domain and one label
    /// under it are OpenAI's), a Claude artifact and a Google Doc.
    static func linkedPageKindLabel(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host == "docs.google.com" {
            return parts.count >= 3 && parts[0] == "document" && parts[1] == "d" ? "Google Doc" : nil
        }
        if host == "claude.ai" || host == "www.claude.ai" {
            guard parts.count >= 3 else { return nil }
            let family = (parts[0].lowercased(), parts[1].lowercased())
            return family == ("code", "artifact") || family == ("public", "artifacts") ? "Claude Artifact" : nil
        }
        if host.hasSuffix(".chatgpt.site") {
            let labels = host.split(separator: ".")
            return labels.count >= 4 && labels.allSatisfy { !$0.isEmpty } ? "Codex Site" : nil
        }
        return nil
    }
}

enum MobileCloudMutationError: LocalizedError {
    case conflict
    case emptyNotebookTitle
    case fileCopyFailed(String)
    case invalidPayload
    case invalidArtifact
    case invalidNotebook
    case invalidSchedulePlacement
    case missingRecord
    case missingSourceURL
    case unsupportedCaptureURL
    case unsupportedCaptureFile
    /// A page ForeverLM links rather than imports, by its kind's label.
    case linkedPage(String)
    case emptyExplainerScript

    var errorDescription: String? {
        switch self {
        case .conflict: return "The item changed on another device. Refresh and try again."
        case .emptyExplainerScript: return "The writer returned no script."
        case .emptyNotebookTitle: return "Enter a Notebook name."
        case .fileCopyFailed(let message): return "The file could not be copied into ForeverLM: \(message)"
        case .invalidPayload: return "The synced record has an unsupported format. Update ForeverLM on your devices and try again."
        case .invalidArtifact: return "A linked Artifact is no longer available."
        case .invalidNotebook: return "This Notebook is no longer available."
        case .invalidSchedulePlacement: return "This Schedule item is no longer available."
        case .missingRecord: return "The item was removed on another device."
        case .missingSourceURL: return "This source cannot be archived because its synced URL is missing."
        case .linkedPage(let label):
            let section = label == "Google Doc" ? "Pages" : "Sites"
            return "That is a \(label). ForeverLM links it in \(section) instead of importing it as an article; link it from the Mac app's \(section)."
        case .unsupportedCaptureURL: return "Enter an http or https URL."
        case .unsupportedCaptureFile: return "Choose a PDF to import on iPhone."
        }
    }
}
