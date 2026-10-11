import CoreGraphics
import Foundation

/// The floating card ⌘-click opens over a card on the Canvas: its faces, an
/// Idea's note to edit in place, and Open Beside / Open (`KnowledgeMapPopupLayer`,
/// docs/knowledge-map-design.md, "Circling and the inspector"). One shows at a
/// time; Esc, a click elsewhere on the plane (the selection moving off the
/// card, the camera moving) or the pane closing takes it away. Nothing about
/// it is stored.
struct KnowledgeMapPopup: Equatable, Identifiable {
    /// The card it shows (`source:<id>`, `idea:<id>`…).
    let ref: String
    /// Where the page drew the card when it was pressed, in the Canvas pane's
    /// points from its top left (the plane fills the pane).
    let rect: CGRect
    /// The Studio window it was asked for in: only that window's pane draws it.
    var windowID: UUID?

    var id: String { ref }
}

/// Where the add box opens (`KnowledgeMapAddBox`, docs/knowledge-map-design.md,
/// "Adding to the canvas"): the right-click's **Add Here…**, **/** on the plane
/// and the **+** after the tools. With a point, the box opens there and a card
/// is set down there; without one it opens under the tools and a card goes
/// beside the selection, else the middle of the view. Never stored.
struct KnowledgeMapAddBoxRequest: Equatable, Hashable {
    /// The point in the Canvas pane's points from its top left (the plane
    /// fills the pane), where the learner asked; nil for the + button.
    var view: CGPoint?
    /// The same point in world units, where a new Idea is written.
    var worldX: Double?
    var worldY: Double?
    /// The Studio window it was asked for in: only that window's pane draws it.
    var windowID: UUID?
}
