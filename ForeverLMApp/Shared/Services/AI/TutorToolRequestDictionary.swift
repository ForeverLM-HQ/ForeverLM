import Foundation

extension TutorToolDefinition {
    /// The tool as the JSON object a chat request's tool list carries, encoded
    /// from the portable tutor contract itself, so the Mac's in-app chat
    /// (`AIToolSpec(portable:)`) and the phone's memory review grader declare
    /// a tool from one definition.
    var requestDictionary: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            preconditionFailure("The shared review tutor contract must encode as a JSON object.")
        }
        return dictionary
    }
}
