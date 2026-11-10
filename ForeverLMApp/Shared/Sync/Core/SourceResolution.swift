/// `resolveSource()` (§4.2): a duplicate's loser keeps `mergedInto` for ever as a redirect to its
/// winner, and everything that names the loser and never changes (a highlight, a card's deck and
/// anchors, a sitting's answers, a reply's citations) is read through this walk, so it shows on the
/// winner. Every client runs this one walk (JS `schema/js/resolve.js`); vectors
/// `schema/vectors/resolve.json`.
enum SourceResolution {
    /// Follows `mergedInto` within one zone up to 8 times, stopping at a source the client does not
    /// hold or one already visited; an unknown start is returned as it is. `mergedInto` is nil for a
    /// source the client does not hold, `.some(nil)` for one with no redirect.
    static func resolve(_ start: String, mergedInto: (String) -> String??) -> String {
        var current = start
        var visited: Set<String> = [start]
        for _ in 0..<SyncSchema.Limits.redirectMaxHops {
            guard case .some(.some(let next)) = mergedInto(current), !next.isEmpty,
                  mergedInto(next) != nil, visited.insert(next).inserted
            else { break }
            current = next
        }
        return current
    }
}
