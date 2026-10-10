import Foundation

/// A line-level three-way merge for a Doc body.
///
/// Two members of a team may edit the same Doc at once. Each Mac keeps, beside
/// the body, the body it last knew the server to hold (`base`). When a server
/// body (`theirs`) arrives while this Mac holds a newer body of its own
/// (`mine`), the two sets of changes are combined here: changes to different
/// lines merge on their own, and the same or adjacent lines changed on both
/// sides are a conflict the writer settles. A conflict never produces marked-up
/// text; the caller keeps one whole version and holds the other.
///
/// Lines are the unit because Markdown prose is line-shaped — a paragraph is a
/// line, and paragraphs are separated by blank lines — so two writers working
/// in different paragraphs never collide, while two edits to one paragraph do.
enum ArtifactThreeWayMerge {
    enum Outcome: Equatable, Sendable {
        case merged(String)
        case conflict
    }

    /// The line-diff table is quadratic in the changed region. Past this many
    /// cells a merge is not attempted and the change is treated as a conflict;
    /// a real Doc's edits are local, so the common prefix and suffix trimming
    /// keeps the region small even for a long report.
    static let maxDiffCells = 4_000_000

    static func merge(base: String, mine: String, theirs: String) -> Outcome {
        if mine == theirs { return .merged(mine) }
        if base == mine { return .merged(theirs) }
        if base == theirs { return .merged(mine) }

        let baseLines = lines(base)
        guard let mineHunks = hunks(from: baseLines, to: lines(mine)),
              let theirHunks = hunks(from: baseLines, to: lines(theirs)) else {
            return .conflict
        }

        var out: [Substring] = []
        var cursor = 0
        func take(_ hunk: Hunk) {
            out.append(contentsOf: baseLines[cursor..<hunk.baseStart])
            out.append(contentsOf: hunk.replacement)
            cursor = hunk.baseEnd
        }
        var i = 0
        var j = 0
        while i < mineHunks.count || j < theirHunks.count {
            if i < mineHunks.count, j < theirHunks.count {
                let a = mineHunks[i]
                let b = theirHunks[j]
                if a.touches(b) {
                    // The same change made on both sides is one change.
                    guard a == b else { return .conflict }
                    take(a)
                    i += 1
                    j += 1
                } else if a.baseStart <= b.baseStart {
                    take(a)
                    i += 1
                } else {
                    take(b)
                    j += 1
                }
            } else if i < mineHunks.count {
                take(mineHunks[i])
                i += 1
            } else {
                take(theirHunks[j])
                j += 1
            }
        }
        out.append(contentsOf: baseLines[cursor...])
        return .merged(out.joined(separator: "\n"))
    }

    // MARK: - Line diff

    /// One region of the base replaced by other lines. An insertion has an
    /// empty base range at the line it goes before.
    struct Hunk: Equatable {
        var baseStart: Int
        var baseEnd: Int
        var replacement: [Substring]

        var isInsertion: Bool { baseStart == baseEnd }

        /// Whether two hunks change the same place. Overlapping ranges do;
        /// so do ranges that merely meet, and an insertion at the edge of a
        /// change — both writers were working on the same passage, and only
        /// they can say what it should read.
        func touches(_ other: Hunk) -> Bool {
            baseStart <= other.baseEnd && other.baseStart <= baseEnd
        }
    }

    static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The changes that turn `base` into `target`, as sorted, non-touching
    /// hunks. nil when the changed region is too large to diff.
    static func hunks(from base: [Substring], to target: [Substring]) -> [Hunk]? {
        var prefix = 0
        while prefix < base.count, prefix < target.count, base[prefix] == target[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < base.count - prefix, suffix < target.count - prefix,
              base[base.count - 1 - suffix] == target[target.count - 1 - suffix] {
            suffix += 1
        }
        let baseMid = Array(base[prefix..<(base.count - suffix)])
        let targetMid = Array(target[prefix..<(target.count - suffix)])
        if baseMid.isEmpty && targetMid.isEmpty { return [] }
        if baseMid.isEmpty {
            return [Hunk(baseStart: prefix, baseEnd: prefix, replacement: targetMid)]
        }
        if targetMid.isEmpty {
            return [Hunk(baseStart: prefix, baseEnd: prefix + baseMid.count, replacement: [])]
        }
        guard baseMid.count * targetMid.count <= maxDiffCells else { return nil }

        // Compare interned line ids rather than strings while filling the table.
        var ids: [Substring: Int32] = [:]
        func intern(_ line: Substring) -> Int32 {
            if let id = ids[line] { return id }
            let id = Int32(ids.count)
            ids[line] = id
            return id
        }
        let a = baseMid.map(intern)
        let b = targetMid.map(intern)
        let n = a.count
        let m = b.count
        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in 1...n {
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    table[i * width + j] = table[(i - 1) * width + (j - 1)] + 1
                } else {
                    table[i * width + j] = max(table[(i - 1) * width + j], table[i * width + (j - 1)])
                }
            }
        }

        enum Op { case equal, deleteBase, insertTarget(Int) }
        var ops: [Op] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                ops.append(.equal)
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || table[i * width + (j - 1)] >= table[(i - 1) * width + j] {
                ops.append(.insertTarget(j - 1))
                j -= 1
            } else {
                ops.append(.deleteBase)
                i -= 1
            }
        }
        ops.reverse()

        var hunks: [Hunk] = []
        var open: Hunk?
        var baseIndex = prefix
        for op in ops {
            switch op {
            case .equal:
                if let hunk = open {
                    hunks.append(hunk)
                    open = nil
                }
                baseIndex += 1
            case .deleteBase:
                if open == nil {
                    open = Hunk(baseStart: baseIndex, baseEnd: baseIndex, replacement: [])
                }
                baseIndex += 1
                open?.baseEnd = baseIndex
            case .insertTarget(let t):
                if open == nil {
                    open = Hunk(baseStart: baseIndex, baseEnd: baseIndex, replacement: [])
                }
                open?.replacement.append(targetMid[t])
            }
        }
        if let hunk = open { hunks.append(hunk) }
        return hunks
    }
}
