import Foundation

extension String {
    /// The text made safe for HTML element content or a double-quoted attribute:
    /// `&`, `<`, `>` and `"` become entities. `&` goes first so the entities
    /// written for the others are not escaped again.
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
