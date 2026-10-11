import CoreGraphics
import Foundation

// MARK: - Opening a card from the Canvas, beside it (docs/knowledge-map-design.md, "Circling and the inspector")
//
// A double-click opens a card as it always did (`openKnowledgeMapItem`: a
// source in the Reader, a Doc where Docs open, an Idea in Ideas). Heptabase's
// ⌥-click, Return on a selected card and the inspector's Open Beside open it
// *beside* the Canvas instead, so the plane stays where it is: a source in
// the Reader, a Doc in its pane, an Idea in its editor, a clip or page in the
// Reader at the spot, a chat as a chat, and another canvas as the canvas
// open. ⌘-click shows the card as a floating popup (`showKnowledgeMapPopup`).

extension StudioViewModel {
    // MARK: The popup

    /// ⌘-click: floats the card's faces beside `rect`, where the page drew it
    /// (in the pane's points). One at a time: it replaces the one showing. A
    /// card the Canvas does not hold has no popup.
    func showKnowledgeMapPopup(_ ref: String, near rect: CGRect) {
        guard knowledgeMap.nodesByRef[ref] != nil else { return }
        knowledgeMap.popup = KnowledgeMapPopup(ref: ref, rect: rect, windowID: activeWindowState.id)
    }

    func dismissKnowledgeMapPopup() {
        if knowledgeMap.popup != nil { knowledgeMap.popup = nil }
    }

    // MARK: Open beside

    /// ⌥-click, Return on a selected card, the popup's and the inspector's
    /// Open Beside: the card opens beside the Canvas in `windowState`, which
    /// keeps what it shows. It closes the popup that offered it. A paper shown
    /// as its page opens at that page.
    func openKnowledgeMapItemBeside(_ ref: String, in windowState: StudioWindowState) async {
        dismissKnowledgeMapPopup()
        if let id = Self.knowledgeMapID(of: ref, prefix: "canvas:") {
            // Another canvas is the canvas open; there is no "beside" for one.
            openCanvas(id, in: windowState)
            return
        }
        if let id = Self.knowledgeMapID(of: ref, prefix: "chat:") {
            inWindow(windowState) {
                openCenterTabBeside(.chat)
                requestResumeReviewSession(id)
            }
            return
        }
        guard let item = KnowledgeMap.ItemRef(ref) else { return }
        if item.kind == .source {
            guard await openSourceBesideChat(canonicalSourceID(item.id), beside: .knowledgeMap, in: windowState) else {
                showToast("That source is not in the library")
                return
            }
            // A paper shown as its page opens at that page.
            requestReaderPassage(nil, page: knowledgeMap.layout.placements[ref]?.page, for: canonicalSourceID(item.id))
        } else if item.kind == .doc {
            revealArtifact(item.id, in: windowState, beside: .knowledgeMap)
        } else if item.kind == .idea {
            // The Ideas pane beside the Canvas, with this Idea's editor up
            // (`IdeasPane` answers the request).
            if !ideas.contains(where: { $0.id == item.id }) { await loadIdeas() }
            guard ideas.contains(where: { $0.id == item.id }) else {
                showToast("That idea is no longer in your library")
                return
            }
            revealCenterTab(.ideas, beside: .knowledgeMap, in: windowState)
            ideaRevealRequest = IdeaRevealRequest(ideaID: item.id, windowID: windowState.id)
        } else {
            // A clip or a page opens its paper beside the Canvas at the spot,
            // as a double-click does; any other kind opens as it always did.
            await openKnowledgeMapItem(ref, in: windowState)
        }
    }

    /// The id after `prefix` in a card's ref, for the kinds `KnowledgeMap.ItemRef`
    /// may not name (`canvas:<canvasID>`, `chat:<reviewSessionID>`).
    nonisolated static func knowledgeMapID(of ref: String, prefix: String) -> String? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let id = String(trimmed.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// Whether a card has a Reader to open in: a source, and what is cut from
    /// one (a passage, a figure, a page). The inspector's Open in ▸ lists the
    /// Reader for it.
    func knowledgeMapCardHasReader(_ ref: String) -> Bool {
        guard let item = KnowledgeMap.ItemRef(ref) else { return false }
        return item.kind == .source
    }
}
