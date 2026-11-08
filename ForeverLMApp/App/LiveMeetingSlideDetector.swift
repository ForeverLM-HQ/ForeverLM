import Foundation

/// Decides when the window being watched shows a new slide.
///
/// Each frame arrives as a small grey fingerprint (one byte per cell, the
/// frame shrunk to `width` x `height`). A frame is a new slide when it differs
/// from the last kept slide over a large share of its cells and has held still
/// for `stableFrames` frames, so a transition, a build animation or a scroll is
/// never kept half-way. Faces in a call's small tiles move all the time but
/// cover few cells, which the share threshold rides over.
///
/// The detector is pure: it keeps only fingerprints and counts, and makes no
/// model call. (product owner, 2026-11-08: the chat looks at a slide only when
/// the learner asks about it.)
struct LiveMeetingSlideDetector: Sendable {
    static let width = 32
    static let height = 18

    /// How far apart two cells' grey values must be (0...255) to count as changed.
    var cellThreshold: Int = 24
    /// The share of cells that must change against the last kept slide.
    var newSlideShare: Double = 0.2
    /// The share of cells that may still change between consecutive frames of a
    /// frame that has settled: room for the faces in a call's tiles, which
    /// never hold still.
    var settledShare: Double = 0.08
    /// How many settled frames in a row a new slide needs before it is kept.
    var stableFrames: Int = 2

    private(set) var lastKept: [UInt8]?
    private var previous: [UInt8]?
    private var settledCount = 0

    init() {}

    /// Feeds one frame's fingerprint; true when this frame should be kept as a
    /// new slide. The first settled frame is always kept.
    mutating func consider(_ fingerprint: [UInt8]) -> Bool {
        guard fingerprint.count == Self.width * Self.height else { return false }
        defer { previous = fingerprint }

        if let previous, Self.changedShare(previous, fingerprint, cellThreshold: cellThreshold) <= settledShare {
            settledCount += 1
        } else {
            settledCount = 1
        }
        guard settledCount >= stableFrames else { return false }

        if let lastKept,
           Self.changedShare(lastKept, fingerprint, cellThreshold: cellThreshold) < newSlideShare {
            return false
        }
        lastKept = fingerprint
        return true
    }

    /// The share of cells whose grey values differ by more than `cellThreshold`.
    static func changedShare(_ a: [UInt8], _ b: [UInt8], cellThreshold: Int) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > cellThreshold {
            changed += 1
        }
        return Double(changed) / Double(a.count)
    }
}
