import Foundation

/// A mark the learner flagged to follow up (`SourceHighlight.followUpAt`,
/// whatever its color) with the library source it is on. `sourceID` is the source's id on this device, which a team copy's marks
/// (kept on the source's wire id) are mapped to.
struct FollowUpMark: Identifiable, Equatable, Sendable {
    let highlight: SourceHighlight
    let sourceID: String

    var id: String { highlight.id }

    static func == (lhs: FollowUpMark, rhs: FollowUpMark) -> Bool {
        lhs.highlight.id == rhs.highlight.id
            && lhs.highlight.updatedAt == rhs.highlight.updatedAt
            && lhs.sourceID == rhs.sourceID
    }
}

/// The Follow up list: every mark in the library the learner set aside to
/// come back to, newest first, so "what did I mean to follow up on?" has one
/// answer across every source instead of one source's notes at a time
/// (product owner, 2026-11-07: "some ideas we need to follow up on later").
///
/// View-free and Foundation-only, so the rule is tested without a window.
enum FollowUpList {
    /// The open marks on sources the learner has not put away, newest first.
    /// A bare slide mark (a slide set down on the canvas and never written on)
    /// is no annotation of the learner's; a mark on a source that is hidden or
    /// archived is put away with it. A tie keeps a fixed order (the id) so two
    /// marks made in one import do not swap between redraws.
    static func open(_ marks: [FollowUpMark], isPutAway: (String) -> Bool) -> [FollowUpMark] {
        marks
            .filter { $0.highlight.isFlaggedForFollowUp && !$0.highlight.isBareSlideMark && !isPutAway($0.sourceID) }
            .sorted { lhs, rhs in
                if lhs.highlight.createdAt != rhs.highlight.createdAt {
                    return lhs.highlight.createdAt > rhs.highlight.createdAt
                }
                return lhs.highlight.id < rhs.highlight.id
            }
    }

    /// `marks` with `highlight` brought up to date: a flagged mark is added or
    /// replaced, any other leaves the list. This is how the list follows a
    /// flag set or taken off in the Reader without a new query.
    static func applying(_ highlight: SourceHighlight, to marks: [FollowUpMark]) -> [FollowUpMark] {
        var result = marks.filter { $0.id != highlight.id }
        if highlight.isFlaggedForFollowUp {
            result.append(FollowUpMark(highlight: highlight, sourceID: highlight.sourceID))
        }
        return result
    }

    /// `marks` without the mark `highlightID`.
    static func removing(_ highlightID: String, from marks: [FollowUpMark]) -> [FollowUpMark] {
        marks.filter { $0.id != highlightID }
    }
}
