import Foundation
import os

private let logger = Logger(subsystem: "com.foreverlm", category: "RegisteredPaperTitle")

/// A title the check gave back to a paper.
struct RestoredPaperTitle: Sendable, Equatable {
    let sourceID: String
    let title: String
}

struct RegisteredPaperTitleCheckResult: Sendable {
    let restored: [RestoredPaperTitle]
    let checkedCount: Int
    let remainingCount: Int
}

/// Checks each staged paper's title against the title its DOI is registered
/// under, and gives back the characters its PDF's text lost.
///
/// Schema 144 staged every paper with a DOI in `paper_registered_title_queue`;
/// a paper ingested since checks itself while its metadata is read
/// (`applyExtractedPaperMetadata`). This asks Crossref and then DataCite — free,
/// keyless, no model — a few DOIs at a time, and restores a title only where
/// the stored one is the registered one with non-ASCII characters lost
/// (`RegisteredPaperTitle`), so a DOI that names some other work changes
/// nothing. An answered row leaves the queue. A row no agency could answer
/// counts an attempt and is asked again on a later drain; a batch in which no
/// agency answered at all ends the drain — the Mac is offline or rate-limited —
/// until the next trigger, the same event-driven ones canonical cleanup runs on.
actor RegisteredPaperTitleCheckService {
    /// DOIs asked at once. Crossref's polite pool allows far more; a
    /// once-per-library backfill has no reason to hurry.
    static let batchSize = 4

    typealias Lookup = @Sendable (String) async -> PaperService.RegisteredTitle

    private let storage: StorageService
    private let lookup: Lookup
    private var isDraining = false

    init(
        storage: StorageService,
        lookup: @escaping Lookup = { doi in await PaperService.registeredTitle(forDOI: doi) }
    ) {
        self.storage = storage
        self.lookup = lookup
    }

    private enum Outcome: Sendable {
        case restored(RestoredPaperTitle)
        case answered
        case unanswered
    }

    func drain() async -> RegisteredPaperTitleCheckResult {
        guard !isDraining else {
            return await result(restored: [], checked: 0)
        }
        isDraining = true
        defer { isDraining = false }

        do {
            try await storage.dropRegisteredPaperTitleChecksWithoutPapers()
        } catch {
            logger.error("Could not tidy the registered-title queue: \(error.localizedDescription, privacy: .public)")
        }

        var restored: [RestoredPaperTitle] = []
        var checked = 0
        while !Task.isCancelled {
            let candidates: [RegisteredPaperTitleCandidate]
            do {
                candidates = try await storage.registeredPaperTitleCandidates(limit: Self.batchSize)
            } catch {
                logger.error("Could not read the registered-title queue: \(error.localizedDescription, privacy: .public)")
                break
            }
            if candidates.isEmpty { break }

            let outcomes = await withTaskGroup(of: Outcome.self) { group in
                for candidate in candidates {
                    group.addTask { await self.check(candidate) }
                }
                var outcomes: [Outcome] = []
                for await outcome in group {
                    outcomes.append(outcome)
                }
                return outcomes
            }

            var answered = 0
            for outcome in outcomes {
                switch outcome {
                case .restored(let title):
                    restored.append(title)
                    answered += 1
                case .answered:
                    answered += 1
                case .unanswered:
                    break
                }
            }
            checked += answered
            // No agency answered anything: offline or rate-limited. Stop here
            // rather than spend every row's attempts at network speed.
            if answered == 0 { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await result(restored: restored, checked: checked)
    }

    private func check(_ candidate: RegisteredPaperTitleCandidate) async -> Outcome {
        let doi = candidate.doi.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = candidate.title
        guard !doi.isEmpty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // The DOI or the title went away since the row was staged.
            do {
                try await storage.completeRegisteredPaperTitleCheck(sourceID: candidate.sourceID)
            } catch {
                logger.error("Could not complete the registered-title check: \(error.localizedDescription, privacy: .public)")
            }
            return .answered
        }
        let answer = await lookup(doi)
        // An interrupted drain is not an unanswered DOI: leave the row as it
        // is, so the next drain asks again without counting an attempt.
        if Task.isCancelled { return .unanswered }
        switch answer {
        case .title(let registered):
            do {
                if let restoredTitle = RegisteredPaperTitle.restoringLostCharacters(in: title, registered: registered) {
                    let changed = try await storage.restoreRegisteredPaperTitle(
                        sourceID: candidate.sourceID,
                        checkedTitle: title,
                        registeredTitle: restoredTitle
                    )
                    if changed {
                        logger.notice(
                            "Restored the registered title of \(candidate.sourceID, privacy: .public): \(restoredTitle, privacy: .public)"
                        )
                        return .restored(RestoredPaperTitle(sourceID: candidate.sourceID, title: restoredTitle))
                    }
                    return .answered
                }
                try await storage.completeRegisteredPaperTitleCheck(sourceID: candidate.sourceID)
                return .answered
            } catch {
                logger.error(
                    "Could not record the registered-title check for \(candidate.sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return .unanswered
            }
        case .unregistered:
            do {
                try await storage.completeRegisteredPaperTitleCheck(sourceID: candidate.sourceID)
            } catch {
                logger.error("Could not complete the registered-title check: \(error.localizedDescription, privacy: .public)")
            }
            return .answered
        case .unavailable(let message):
            do {
                try await storage.recordRegisteredPaperTitleCheckFailure(
                    sourceID: candidate.sourceID,
                    message: message
                )
            } catch {
                logger.error("Could not record the registered-title check failure: \(error.localizedDescription, privacy: .public)")
            }
            return .unanswered
        }
    }

    private func result(restored: [RestoredPaperTitle], checked: Int) async -> RegisteredPaperTitleCheckResult {
        let remaining = (try? await storage.registeredPaperTitleQueueCount()) ?? 0
        if checked > 0 {
            logger.info(
                "Checked \(checked) paper title(s) against their registered titles, restored \(restored.count); \(remaining) remaining"
            )
        }
        return RegisteredPaperTitleCheckResult(
            restored: restored,
            checkedCount: checked,
            remainingCount: remaining
        )
    }
}
