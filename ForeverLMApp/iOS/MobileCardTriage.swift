import Foundation

// Going through cards on the phone (docs/memory-design.md, "Cards to check on the iPhone"): what To
// Check's Keep, Edit and Skip write, and what a kept card's menu writes — Edit Card, Start Over, Always
// Ask in Its Own Words, Retire, and the card review's This Asks Something Else. The Mac's writers
// (`MemoryCardTriageWriter`, `MemoryCardEditWriter`, `recordMemoryCardAskedSomethingElse`) decide the
// same things over its store; here every write is a patch on the card's `Card` record
// through the phone's writer (`MobileCardRecords`), so nothing reaches a deck row.

/// Writes what the learner decided in To Check, one card at a time, in the order decided. A decision
/// the phone cannot carry out — a quote its source no longer prints, a source whose text is not on the
/// phone — is reported and leaves its card to check.
enum MobileCardTriageWriter {
    struct Outcome {
        var result = MemoryCardTriageResult()
        /// The Memory items Keep made or found, for the screens to hold at once.
        var kept: [MemoryItem] = []
    }

    static func apply(
        _ decisions: [MemoryCardTriageDecision],
        writer: MobileRecordWriter,
        sourceText: (String) async -> String?,
        at now: Date = Date()
    ) async -> Outcome {
        var outcome = Outcome()
        var texts: [String: String?] = [:]
        func fail(_ card: MemoryCardToCheck, _ reason: String) {
            outcome.result.failed.append(MemoryCardTriageResult.Failure(cardID: card.cardID, reason: reason))
        }
        var seen = Set<String>()
        for decision in decisions where seen.insert(decision.card.cardID).inserted {
            let card = decision.card
            switch decision.action {
            case .keep, .keepEdited:
                let face: MemoryCard?
                if case .keepEdited(let edit) = decision.action {
                    face = MemoryCardTriage.editedFace(card, edit)
                } else {
                    face = card.face
                }
                guard let face else {
                    fail(card, MobileCardRecords.Refusal.noFace.localizedDescription)
                    continue
                }
                if texts[card.sourceID] == nil { texts[card.sourceID] = await sourceText(card.sourceID) }
                // The other sources the card is kept on: its own, or the ones the learner chose in Edit.
                var alsoFrom = card.alsoFrom
                if case .keepEdited(let edit) = decision.action, let chosen = edit.alsoFrom { alsoFrom = chosen }
                var linkTexts: [String: String] = [:]
                for link in alsoFrom {
                    if texts[link.sourceID] == nil { texts[link.sourceID] = await sourceText(link.sourceID) }
                    if let text = texts[link.sourceID] ?? nil { linkTexts[link.sourceID] = text }
                }
                do {
                    let item = try MobileCardRecords.keptItem(
                        card, face: face, sourceText: texts[card.sourceID] ?? nil, alsoFrom: alsoFrom, linkTexts: linkTexts, at: now
                    )
                    let kept = try await writer.transaction { try $0.keepDraftCard(item) }
                    let held: MemoryItem
                    switch kept {
                    case .kept: held = item
                    case .keptElsewhere(let other): held = other
                    }
                    outcome.result.kept.append(MemoryCardTriageResult.Kept(cardID: card.cardID, memoryItemID: held.id))
                    outcome.kept.append(held)
                } catch {
                    fail(card, error.localizedDescription)
                }
            case .skip:
                do {
                    try await writer.transaction { try $0.skipDraftCard(card.cardID) }
                    outcome.result.skipped.append(card.cardID)
                } catch {
                    fail(card, error.localizedDescription)
                }
            }
        }
        return outcome
    }
}

/// What a change to a kept card writes, the Mac's `MemoryCardEditWriter` on the phone's records:
///
/// - a new front alone rewords the card (its `front` variant); its item and schedule are untouched,
///   and the front it was kept with takes the rewording back;
/// - a new back or why starts it over: the old card retired with its answers, and a revision under a
///   new card id kept on the same passages, which its sources must still print, first asked the day
///   after.
enum MobileCardEditWriter {
    /// A change the learner asked for that the phone did not make.
    enum Refusal: LocalizedError, Equatable {
        case unchanged

        var errorDescription: String? {
            switch self {
            case .unchanged: return "Nothing about the card changed."
            }
        }
    }

    /// Whether `edit` changes the card's answer (its back, why or pictures), which starts it over.
    static func startsOver(_ card: MemoryCardListing, _ edit: MemoryCardEdit) -> Bool {
        let face = card.face
        return edit.back != face.back || edit.why != face.why
            || edit.frontImages != face.frontImages || edit.backImages != face.backImages
    }

    /// The front a reword writes: nil when the learner went back to the front the card was kept with.
    /// Throws when the front is empty or is the wording the card is asked in already.
    static func rewording(_ card: MemoryCardListing, front: String, wording: String) throws -> String? {
        let front = front.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, front != wording else { throw Refusal.unchanged }
        return front == card.face.front ? nil : front
    }

    /// The revision's face: the edit's words or, with none, the card as it is asked now, under a new
    /// card id.
    static func revisedFace(_ card: MemoryCardListing, edit: MemoryCardEdit?, wording: String, newID: String) -> MemoryCard {
        let face = card.face
        return MemoryCard(
            cardID: newID,
            front: edit?.front ?? wording,
            back: edit?.back ?? face.back,
            why: edit?.why ?? face.why,
            origin: face.origin,
            deckID: face.deckID,
            frontImages: edit?.frontImages ?? face.frontImages,
            backImages: edit?.backImages ?? face.backImages
        )
    }

    /// "This asks something else" once a sitting and wording (the Mac's
    /// `KnowledgeStore.askedSomethingElseAttemptID`).
    static func askedSomethingElseAttemptID(sessionKey: String, memoryItemID: String, prompt: String) -> String {
        let fields = [sessionKey, memoryItemID, prompt].joined(separator: "\u{1F}")
        return "memory-asked-else-v1-" + fields.sha256Hex
    }
}
