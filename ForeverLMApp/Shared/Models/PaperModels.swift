// Paper ingestion models and StudioArticle paper-metadata members, moved out of Models.swift.

import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Durable proof that a paper passed the metadata gate required for ingestion.
/// `predatesGate` (stored as `"legacy"`) marks papers that predate the gate and
/// already have complete metadata. New papers can become ready only after a
/// successful Paper Metadata LLM call writes `llm`.
enum PaperIngestionMethod: String, Codable {
    case predatesGate = "legacy"
    case llm
    /// The learner supplied the required metadata by hand. Some scholarly
    /// documents simply do not print all of it — a repository thesis often has
    /// no journal and no year anywhere in its front matter — so a human
    /// attestation has to be able to complete ingestion the model could not.
    case manual
    /// Another of the learner's devices finished this paper's ingestion and its Source
    /// record arrived `ready` (generation 2: `Source.ingest`, written only after that
    /// device passed the metadata gate). This Mac took its word and neither calls the
    /// Paper Metadata model nor queues the paper for it. Written only by
    /// `SourceProjection` and `InboundSourceFiles`.
    case synced
}

/// A user-actionable paper problem shown in the "Papers that need attention"
/// list. Deferred cleanup and Listen preparation are intentionally absent: they
/// are background maintenance, not evidence that an intact paper is broken.
enum PaperAttentionReason: String, Equatable {
    case pdfNeeded = "PDF needed"
    case metadataIncomplete = "Metadata incomplete"
}

/// The concrete user action that resolves a persisted paper-ingestion failure.
/// These cases classify only code-owned error messages emitted by the paper
/// pipeline; human-authored source text never participates in this decision.
enum PaperIngestionRecoveryAction: Equatable {
    case configureAI
    case addBalance
    case attachPDF
    /// The extractor ran and simply could not find a field the document never
    /// prints. Retrying it produces the same answer; the learner filling the
    /// field in is the fix.
    case editDetails
    case retry

    var title: String {
        switch self {
        case .configureAI: return "Configure AI"
        case .addBalance: return "Add Key"
        case .attachPDF: return "Choose PDF"
        case .editDetails: return "Edit Details"
        case .retry: return "Retry"
        }
    }
}

/// A compare-and-swap patch for the fields owned by deterministic paper metadata
/// backfill. Network lookups can overlap PDF attachment and AI metadata
/// extraction, so applying a captured whole `StudioArticle` after an `await`
/// would revert unrelated, newer fields such as URL and `localFilePath`.
struct PaperMetadataBackfillPatch: Sendable {
    let sourceID: String

    private let originalTitle: String
    private let title: String
    private let originalAuthor: String?
    private let author: String?
    private let originalJournal: String?
    private let journal: String?
    private let originalPublishedYear: String?
    private let publishedYear: String?
    private let originalDOI: String?
    private let doi: String?
    private let originalPublishedDOI: String?
    private let publishedDOI: String?

    init(original: StudioArticle, candidate: StudioArticle) {
        sourceID = original.id
        originalTitle = original.title
        title = candidate.title
        originalAuthor = original.author
        author = candidate.author
        originalJournal = original.journal
        journal = candidate.journal
        originalPublishedYear = original.publishedYear
        publishedYear = candidate.publishedYear
        originalDOI = original.doi
        doi = candidate.doi
        originalPublishedDOI = original.publishedDOI
        publishedDOI = candidate.publishedDOI
    }

    /// Apply only fields that still equal the values observed before the network
    /// work began. A concurrent AI result wins field-by-field, while unrelated
    /// source state is never touched.
    @discardableResult
    func apply(to article: inout StudioArticle) -> Bool {
        guard article.id == sourceID, article.sourceType == .paper else { return false }

        var changed = false
        if title != originalTitle, article.title == originalTitle {
            article.title = title
            changed = true
        }
        if author != originalAuthor, article.author == originalAuthor {
            article.author = author
            changed = true
        }
        if journal != originalJournal, article.journal == originalJournal {
            article.journal = journal
            changed = true
        }
        if publishedYear != originalPublishedYear,
           article.publishedYear == originalPublishedYear {
            article.publishedYear = publishedYear
            changed = true
        }
        if doi != originalDOI, article.doi == originalDOI {
            article.doi = doi
            changed = true
        }
        if publishedDOI != originalPublishedDOI, article.publishedDOI == originalPublishedDOI {
            article.publishedDOI = publishedDOI
            changed = true
        }
        return changed
    }
}

struct PaperContentPreparationMetadata: Codable, Equatable, Sendable {
    /// Version 1 is the deterministic migration cleanup. Version 2 returned a
    /// rewritten paper. Version 3 applies a validated paper block-deletion plan.
    /// Version 4 extends that same non-rewriting contract to web articles.
    /// Version 5 feeds the complete raw extraction to the model and applies a
    /// validated deletion-only diff with both block and exact-text hunks.
    /// Version 6 uses smaller stable blocks, bounds inline hunks, disables
    /// reasoning, and validates every uncached diff before persistence. Version
    /// 7 makes extracted physical lines the deletion unit so metadata and prose
    /// can never disappear together in one coarse block. Version 8 makes
    /// bibliography recognition independent of seeing its heading in the same
    /// request chunk. Version 9 adds validated forward relocation of substantive
    /// boxes that physical PDF order placed inside a main-text paragraph.
    /// Version 10 adds a focused Box-heading pass so long consecutive boxes do
    /// not hide the grammatical continuation from a broad cleanup request.
    /// Version 11 normalizes the merged broad/focused plan against the complete
    /// document before reconstruction. Version 12 prefers the complete wider
    /// Box range when broad and focused plans share the same starting heading.
    /// Version 13 uses semantic start/resume/paragraph boundaries and expands
    /// complete Box intervals deterministically in the app. Versions 14–17
    /// tightened the focused boundary contract and structural Box-heading
    /// recognition against live extracted papers. Version 18 keeps the exact
    /// Box move when deletion removes noise inside its range and fails closed
    /// if an interrupted paragraph's required move disappears during final
    /// normalization. Version 19 cleans a paper's complete PDF extraction
    /// rather than a stored copy an older build capped at 50,000 characters,
    /// keeps back-matter statements and every section printed after the
    /// references (STAR★Methods, Methods), and restores any whole-block
    /// deletion that a second, deletions-only model read calls source content.
    static let deterministicVersion = 1
    static let currentVersion = 19

    let cleanerVersion: Int
    let rawSHA256: String
    let cleanSHA256: String?
    let preparedAt: Date?
}

extension StudioArticle {
    var paperAuthorNeedsEnrichment: Bool {
        guard sourceType == .paper else { return false }
        guard let value = normalizedAuthor else { return true }
        return value == Self.unknownPaperAuthor
    }

    var paperJournalNeedsEnrichment: Bool {
        guard sourceType == .paper else { return false }
        guard let value = normalizedJournal else { return true }
        return value == Self.unknownPaperJournal
    }

    var paperYearNeedsEnrichment: Bool {
        guard sourceType == .paper else { return false }
        guard let value = normalizedPublishedYear else { return true }
        return value == Self.unknownPaperYear
    }

    /// What the metadata stage actually requires: the extractor came back with
    /// at least one bibliographic field. Requiring all three failed the
    /// documents that simply do not have them — a lab preprint with no venue,
    /// an unsigned editorial, a thesis whose front matter prints no year — and
    /// left readable papers sitting in the attention list behind an error no
    /// retry could clear. A missing field is a blank to fill in later, not a
    /// failed ingestion; an all-blank result still is one, and the extractor
    /// itself already rejects a wholly empty model response.
    var hasAttestablePaperMetadata: Bool {
        guard sourceType == .paper else { return true }
        return !paperAuthorNeedsEnrichment
            || !paperJournalNeedsEnrichment
            || !paperYearNeedsEnrichment
    }

    /// True only after the current Source Content Cleanup contract produced
    /// canonical text. Non-empty content alone is insufficient because older
    /// payloads may contain raw extraction text that is not listen-ready.
    var hasCompletedPaperContentCleanup: Bool {
        guard sourceType == .paper else { return true }
        return paperContentSHA256?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    /// A paper whose text is final: metadata attested and the current
    /// clean-up committed. Listen, Explain and text-to-speech gate on this. The
    /// Listen derivative is prepared when the learner presses Listen, or at
    /// once for the kinds automatic audio covers (2026-09-24), so its absence
    /// is not a failed ingestion.
    var isPaperReadyForListenPreparation: Bool {
        guard sourceType == .paper else { return true }
        return state == .ready
            && hasPaperIngestionAttestation
            && hasCompletedPaperContentCleanup
    }

    /// Ingestion is over: metadata is attested, and the text is either clean
    /// or handed to the durable cleanup queue, which moves the row from
    /// `.queued` to `.ready` when the clean text lands (3813fb3). Callers that
    /// ask "did this paper finish?" use this, not
    /// `isPaperReadyForListenPreparation`: a queued cleanup is not a stall, and
    /// recording it as one set the row to `.error`, which the queue's drain
    /// never picks up, so the cleanup could never run.
    var hasFinishedPaperIngestion: Bool {
        guard sourceType == .paper else { return true }
        if isPaperReadyForListenPreparation { return true }
        return state == .queued
            && errorMessage == nil
            && hasPaperIngestionAttestation
    }

    /// Metadata, canonical cleanup, and the durable Listen derivative are all
    /// ready. Since Listen became lazy (2026-09-24) nothing gates a control on
    /// this: a paper without a derivative yet is still fully readable and
    /// listenable, and `isPaperReadyForListenPreparation` is the gate.
    var hasSuccessfulPaperIngestion: Bool {
        guard sourceType == .paper else { return true }
        return isPaperReadyForListenPreparation && paperListenableContentReady
    }

    /// Whether Listen narration applies to this source at all. Preparation
    /// follows the source's canonical text, not its bibliography or its current
    /// lifecycle state: an unsigned editorial fails the metadata gate and still
    /// has a full document to narrate, and a paper cycling back through `queued`
    /// for a metadata retry has not lost the text it was queued against.
    /// Archiving it, or changing it into a type that carries real audio, is what
    /// retires the work.
    var supportsListenableContentPreparation: Bool {
        (sourceType == .article || sourceType == .paper) && status == .active
    }

    /// Gives user-actionable, non-terminal paper states a concise UI explanation.
    /// Versioned cleanup and Listen backfills can cover the entire historical
    /// library after an update; those stay silent and never make healthy papers
    /// appear broken while the durable queues drain in the background.
    /// The caller supplies cached PDF availability so this stays safe in SwiftUI
    /// render paths and never stats an iCloud-backed file on the main actor.
    func paperAttentionReason(hasUsablePDF: Bool) -> PaperAttentionReason? {
        guard sourceType == .paper,
              !hasPaywallMarker,
              state != .error,
              state != .fetching else { return nil }
        guard hasUsablePDF else { return .pdfNeeded }
        guard hasPaperIngestionAttestation else { return .metadataIncomplete }
        return nil
    }

    var hasPaperIngestionAttestation: Bool {
        sourceType == .paper
            && hasAttestablePaperMetadata
            && paperIngestionMethod != nil
    }

    var requiresPaperMetadataAI: Bool {
        sourceType == .paper && paperIngestionMethod == nil
    }

    /// Call only after the Paper Metadata task returned successfully and its
    /// result has been applied. Requiring one resolved bibliographic field here
    /// prevents a technically successful but empty model response from attesting
    /// this stage, without failing a document that prints no venue or no year.
    @discardableResult
    mutating func completePaperMetadataExtractionAfterLLM() -> Bool {
        guard attestPaperMetadataExtractionAfterLLM() else { return false }
        state = .ready
        return true
    }

    /// Content cleanup is downstream from metadata extraction. Preserve the
    /// metadata attestation so Retry resumes cleanup instead of charging for a
    /// second metadata call and so the UI reports the stage that actually failed.
    mutating func failPaperContentCleanup(_ message: String) {
        guard sourceType == .paper else { return }
        state = .error
        errorMessage = message
    }

    /// Names the fields the extractor actually left missing. "did not return
    /// author, venue, and year" reads as a total failure even when only the
    /// year was absent, and it hides how small the manual fix is.
    var missingRequiredPaperMetadataFields: [String] {
        guard sourceType == .paper else { return [] }
        var missing: [String] = []
        if paperAuthorNeedsEnrichment { missing.append("author") }
        if paperJournalNeedsEnrichment { missing.append("venue") }
        if paperYearNeedsEnrichment { missing.append("year") }
        return missing
    }

    /// Recognizes an incomplete-extraction failure.
    static let paperMetadataIncompleteMarker = "Paper Metadata AI could not find the"

    static func paperMetadataIncompleteMessage(missing: [String]) -> String {
        let fields = missing.isEmpty ? ["author", "venue", "year"] : missing
        let list: String
        switch fields.count {
        case 1: list = fields[0]
        case 2: list = "\(fields[0]) and \(fields[1])"
        default: list = "\(fields.dropLast().joined(separator: ", ")), and \(fields[fields.count - 1])"
        }
        let noun = fields.count == 1 ? "it" : "them"
        return "Paper ingestion failed: \(paperMetadataIncompleteMarker) \(list). "
            + "Edit the details to fill \(noun) in."
    }

    /// Recognizes a persisted incomplete-metadata failure.
    var isPaperMetadataIncompleteFailure: Bool {
        guard sourceType == .paper, state == .error, let errorMessage else { return false }
        return errorMessage.contains(Self.paperMetadataIncompleteMarker)
    }

    /// A paper an earlier build failed because the extractor left one of the
    /// bibliographic fields blank. That persisted failure is itself the record
    /// that the Paper Metadata call ran and its result was applied, so the stage
    /// is already attested under the current gate; re-running the model would
    /// spend tokens to be told the same "?" again. Rows without canonical text
    /// still have real work left and are deliberately excluded — they go back
    /// through extraction, which owns Source Content Cleanup.
    var canAttestPaperIngestionAfterBlankMetadataFailure: Bool {
        sourceType == .paper
            && paperIngestionMethod == nil
            && isPaperMetadataIncompleteFailure
            && hasAttestablePaperMetadata
            && hasCompletedPaperContentCleanup
    }

    /// Source Content Cleanup is a named, code-owned pipeline step, so this
    /// prefix recognizes its failures without guessing at human-authored text.
    static let paperContentCleanupFailurePrefix = "Paper cleanup couldn't finish."

    static func paperContentCleanupFailureMessage(_ detail: String) -> String {
        "\(paperContentCleanupFailurePrefix) This step removes headers, footers, references, and other noise so the paper sounds natural when you listen and later AI work uses fewer tokens. Error: \(detail)"
    }

    var isPaperContentCleanupFailure: Bool {
        guard sourceType == .paper, let errorMessage else { return false }
        return errorMessage.hasPrefix(Self.paperContentCleanupFailurePrefix)
    }

    /// Whether this source stopped mid-ingestion only because the ForeverLM AI
    /// account had nothing to pay with. Its extraction is already staged and
    /// nothing about it failed, so adding a key makes the remaining work
    /// possible again — the row is
    /// paused, not broken, and is the app's to resume rather than the learner's
    /// to retry.
    var isPausedByEmptyAIBalance: Bool {
        state == .error
            && PaperContentPreparationService.isEmptyBalanceFailure(errorMessage)
    }

    var paperContentCleanupFailureDetail: String? {
        guard isPaperContentCleanupFailure, let errorMessage else { return nil }
        if let range = errorMessage.range(of: "Error: ") {
            return String(errorMessage[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// The complete persisted cause, minus the redundant badge prefix. This is
    /// intentionally suitable for inline display instead of being hidden only
    /// in tooltip/accessibility text.
    var paperIngestionFailureDetail: String? {
        guard sourceType == .paper,
              state == .error,
              !hasPaywallMarker,
              !isPaperContentCleanupFailure else { return nil }
        let trimmed = (errorMessage ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No failure details were recorded." }
        let visibleMessage: String
        if let debugLogRange = trimmed.range(of: "\n\n--- Debug Log ---") {
            visibleMessage = String(trimmed[..<debugLogRange.lowerBound])
        } else {
            visibleMessage = trimmed
        }
        let prefix = "Paper ingestion failed:"
        guard visibleMessage.hasPrefix(prefix) else { return visibleMessage }
        let detail = visibleMessage.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "No failure details were recorded." : detail
    }

    /// Resolve a code-owned failure into a useful next step. PDF availability
    /// is supplied from the cached projection so SwiftUI never stats an iCloud
    /// file while rendering the row.
    func paperIngestionRecoveryAction(hasUsablePDF: Bool) -> PaperIngestionRecoveryAction? {
        guard sourceType == .paper,
              state == .error,
              !hasPaywallMarker else { return nil }
        let message = errorMessage ?? ""
        if message.localizedCaseInsensitiveContains("is not configured") {
            return .configureAI
        }
        // The two configuration blockers that name themselves instead of
        // saying "not configured". Both are fixed in the same place the
        // Configure AI button opens, and neither is a retry.
        if message.contains(KeychainService.invalidModelRouteMessage)
            || message.contains(KeychainService.backgroundAIConsentMessage) {
            return .configureAI
        }
        // Every "add your OpenRouter key" wording: today's, and those from
        // while the key also needed a plan ("… and choose a plan", until
        // 2026-10-10), still stored on older rows. "AI balance is empty" and
        // "top up" are the wordings from before the prepaid balance was
        // retired.
        if message.localizedCaseInsensitiveContains("add your OpenRouter key")
            || (message.localizedCaseInsensitiveContains("your OpenRouter key")
                && message.localizedCaseInsensitiveContains("choose a plan"))
            || message.localizedCaseInsensitiveContains("AI balance is empty")
            || message.localizedCaseInsensitiveContains("top up") {
            return .addBalance
        }
        if !hasUsablePDF
            || message.localizedCaseInsensitiveContains("no readable PDF")
            || message.localizedCaseInsensitiveContains("no readable paper text") {
            return .attachPDF
        }
        // Some documents print none of the three fields, and another extraction
        // pass returns the same answer, so send the learner to the fields instead
        // of to a button that cannot succeed.
        if isPaperMetadataIncompleteFailure {
            return .editDetails
        }
        return .retry
    }

    mutating func installPreparedPaperContent(
        raw: String,
        clean: String,
        metadata: PaperContentPreparationMetadata,
        wordCount preparedWordCount: Int? = nil
    ) {
        guard sourceType == .paper else { return }
        rawPaperContentForPersistence = raw
        paperContentPreparationForPersistence = metadata
        paperContentSHA256 = metadata.cleanerVersion
            >= PaperContentPreparationMetadata.currentVersion
            && metadata.cleanSHA256 != nil
            ? metadata.rawSHA256
            : nil
        paperListenableContentReady = false
        content = clean
        wordCount = preparedWordCount
            ?? clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Install the canonical derivative for an article while carrying the
    /// original extraction to the storage actor for one atomic save. The
    /// transient raw value is intentionally excluded from Codable just like
    /// the paper equivalent above.
    mutating func installPreparedArticleContent(
        raw: String,
        clean: String,
        metadata: PaperContentPreparationMetadata,
        wordCount preparedWordCount: Int? = nil
    ) {
        guard sourceType == .article || sourceType == .manual || sourceType == .unclassified else { return }
        rawArticleContentForPersistence = raw
        articleContentPreparationForPersistence = metadata
        content = clean
        wordCount = preparedWordCount
            ?? clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    mutating func stageArticleContentCleanup(raw: String, rawSHA256: String? = nil) {
        guard sourceType == .article || sourceType == .manual || sourceType == .unclassified else { return }
        rawArticleContentForPersistence = raw
        articleContentPreparationForPersistence = PaperContentPreparationMetadata(
            cleanerVersion: 0,
            rawSHA256: rawSHA256 ?? PaperContentPreparationService.sha256(raw),
            cleanSHA256: nil,
            preparedAt: nil
        )
        content = nil
    }

    mutating func stagePaperContentCleanup(raw: String, rawSHA256: String? = nil) {
        guard sourceType == .paper else { return }
        rawPaperContentForPersistence = raw
        paperContentPreparationForPersistence = PaperContentPreparationMetadata(
            cleanerVersion: 0,
            rawSHA256: rawSHA256 ?? PaperContentPreparationService.sha256(raw),
            cleanSHA256: nil,
            preparedAt: nil
        )
        content = nil
    }

    /// The storage handoff may hold several megabytes. Library rows hydrate
    /// text lazily, so never retain it in published SwiftUI model state after
    /// the atomic save has consumed it.
    mutating func discardPersistedPaperContentFromMemory() {
        guard sourceType == .paper else { return }
        rawPaperContentForPersistence = nil
        paperContentPreparationForPersistence = nil
        content = nil
    }

    mutating func discardPersistedArticleContentHandoff() {
        rawArticleContentForPersistence = nil
        articleContentPreparationForPersistence = nil
    }

    var paperMetadataCompletenessScore: Int {
        guard sourceType == .paper else { return 0 }
        var score = 0
        if !paperAuthorNeedsEnrichment { score += 1 }
        if !paperJournalNeedsEnrichment { score += 1 }
        if !paperYearNeedsEnrichment { score += 1 }
        return score
    }

    var paperMetadataDisplayParts: [String] {
        guard sourceType == .paper else { return [] }
        let journalDisplay: String = {
            if let j = normalizedJournal, j != Self.unknownPaperJournal { return j }
            let lower = url.lowercased()
            if lower.contains("biorxiv.org") { return "bioRxiv" }
            if lower.contains("medrxiv.org") { return "medRxiv" }
            if lower.contains("arxiv.org") { return "arXiv" }
            if lower.contains("nature.com") {
                // Extract specific Nature sub-journal from the title suffix
                // e.g. "Some paper title | Nature Methods" → "Nature Methods"
                if let pipeRange = title.range(of: " | Nature", options: .backwards),
                   title[pipeRange.upperBound...].allSatisfy({ $0.isLetter || $0.isWhitespace }) {
                    return String(title[title.index(pipeRange.lowerBound, offsetBy: 3)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                return "Nature"
            }
            if lower.contains("cell.com") { return "Cell" }
            if lower.contains("science.org") { return "Science" }
            if lower.contains("pnas.org") { return "PNAS" }
            if lower.contains("plos.org") { return "PLOS" }
            if lower.contains("elifesciences.org") { return "eLife" }
            if lower.contains("pubs.acs.org") { return "ACS" }
            if lower.contains("frontiersin.org") { return "Frontiers" }
            // Detect bioRxiv from DOI-based local filenames
            let filename = (url as NSString).lastPathComponent.lowercased()
            if filename.hasPrefix("10.1101_") || filename.hasPrefix("10.64898_") || filename.hasPrefix("biorxiv") { return "bioRxiv" }
            if filename.hasPrefix("medrxiv") { return "medRxiv" }
            return Self.unknownPaperJournal
        }()
        return [
            shortAuthorDisplay ?? Self.unknownPaperAuthor,
            journalDisplay,
            normalizedPublishedYear ?? Self.unknownPaperYear,
        ]
    }

    /// Whether this source has been marked as paywalled: the `is_paywalled` flag or the `paywall` marker in `error_message`.
    var hasPaywallMarker: Bool {
        isPaywalled || statusFlag == .paywall
    }

    /// Whether this paper is behind a paywall and needs a user-attached PDF.
    var isPaywalledPaper: Bool {
        sourceType == .paper && hasPaywallMarker
    }

    /// The AI browser's reason for thinking this paper is paywalled, while the
    /// paper still sits in "Papers that need attention" wanting a PDF. Nil once
    /// a PDF is attached or the paper is marked paywalled, so the row's Mark as
    /// Paywalled button never outlives the question it answers. Takes cached PDF
    /// availability like `paperAttentionReason`, for the same render-path reason.
    func suggestedPaywallReason(hasUsablePDF: Bool) -> String? {
        guard paperAttentionReason(hasUsablePDF: hasUsablePDF) == .pdfNeeded,
              let reason = paywallSuspicion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        return reason
    }
}
