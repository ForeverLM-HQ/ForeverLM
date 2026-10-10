import Foundation

/// A picture the assistant drew, named so the chat line that shows it carries
/// no file path.
///
/// `foreverlm://image/generated/<id>` sits beside `SourceImageReference`'s
/// `foreverlm://image/<sourceID>/page/<n>` on purpose: the transcript renderer
/// already treats every `foreverlm://image/…` URL as a picture to resolve
/// through the host, so a drawn picture rides the same figure chrome, Copy
/// button and drag-out as a figure from a paper. The two grammars cannot
/// collide — a source reference has three path segments, this has two, and
/// `generated` is reserved as the first one.
///
/// The id is the only identity. Each client keeps the bytes it drew in its own
/// store and resolves the id from there; another device that never drew the
/// picture says so in place, the same way it does for a source it does not hold.
/// The pictures a course's quizzes or a source's walk show are the exception:
/// they ride that record (`CourseQuizPicturePackage`,
/// `WalkthroughPicturePackage`) into every other Mac's store under the same id.
struct GeneratedImageReference: Hashable, Sendable {
    static let segment = "generated"

    let id: String

    /// Nil for an id that could not name a file safely.
    init?(id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidID(trimmed) else { return nil }
        self.id = trimmed
    }

    /// Parses `foreverlm://image/generated/<id>`; anything else is nil.
    init?(urlString: String) {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == SourceImageReference.scheme,
              components.host?.lowercased() == SourceImageReference.host else { return nil }
        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard segments.count == 2, segments[0].lowercased() == Self.segment else { return nil }
        self.init(id: segments[1])
    }

    var urlString: String {
        "\(SourceImageReference.scheme)://\(SourceImageReference.host)/\(Self.segment)/\(id)"
    }

    /// The line the assistant pastes into its answer, alt text kept to one
    /// bracket-free line exactly as `SourceImageReference.markdown` does.
    func markdown(alt: String) -> String {
        let cleaned = alt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "![\(cleaned.isEmpty ? "Generated image" : cleaned)](\(urlString))"
    }

    /// A fresh id for a picture about to be stored.
    static func newID() -> String {
        UUID().uuidString.lowercased()
    }

    /// Lowercase hex and dashes only, 8–64 characters: a UUID, and nothing that
    /// could walk a directory or hide a second path segment.
    static func isValidID(_ id: String) -> Bool {
        guard (8...64).contains(id.count) else { return false }
        return id.allSatisfy { $0.isNumber || ("a"..."f").contains($0) || $0 == "-" }
    }
}
