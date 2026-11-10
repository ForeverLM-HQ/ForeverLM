import Foundation

// MARK: - Sensemaking entry points (docs/sensemaking-design.md)
//
// The calls one shape makes into another: the Canvas inspector's Ask section
// opens an Atlas, starts a review in place and drafts cards.

extension StudioViewModel {

    // MARK: Ask the Canvas

    /// Asks the selected cards `tool`; the answer arrives as proposals drawn
    /// dotted on the Canvas.
    func canvasAsk(_ tool: CanvasAskTool, refs: [String]) {
        startCanvasAsk(tool, refs: refs)
    }

    // MARK: Atlas

    /// Opens an Atlas of `topic` over these cards or this notebook: the one
    /// already made for it, else a new one. A nil topic is read from the cards.
    func openAtlas(topic: String?, itemRefs: [String], notebookID: String?) {
        // Making one is AI work for a pane that would not open: nothing
        // starts where the Atlas does not show (`BetaFeatures`).
        guard BetaFeatures.showsCanvas else { return }
        presentAtlas(topic: topic, itemRefs: itemRefs, notebookID: notebookID)
    }

    // MARK: Memory on the Canvas

    /// Reviews the kept cards anchored to these Canvas cards, in place: the
    /// Canvas flies to each card in turn and asks there.
    func canvasReviewHere(refs: [String]) {
        startKnowledgeMapReview(refs: refs)
    }

    /// Drafts Memory cards from these Ideas, arrows and sources into To Check.
    func canvasMakeCards(refs: [String], edgeIDs: [String]) {
        startKnowledgeMapCards(refs: refs, edgeIDs: edgeIDs)
    }

    /// How the kept cards anchored to each of these sources stand today, by
    /// source id; a source with no kept card is left out. Read by the Canvas's
    /// Memory layer and by the Atlas's concepts.
    func memoryMarks(forSourceIDs sourceIDs: [String]) async -> [String: KnowledgeMapMemoryMark] {
        await canvasMemoryMarks(forSourceIDs: sourceIDs)
    }
}
