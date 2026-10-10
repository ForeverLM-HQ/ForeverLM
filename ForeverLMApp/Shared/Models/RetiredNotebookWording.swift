import Foundation

/// A notebook was called a project until 2026-10-04 (schema 164). A record an older
/// build saved in iCloud still names its notebook fields with the old word
/// (`parentProjectID`, `homeProjectID`, `linkedProjectIDs`, `projectID`) until something
/// saves it again, so every device reads a payload through `currentPayload` before decoding
/// it, and a library synced before the rename keeps its notebooks, their Goals and what is
/// filed in them. The Mac (`CloudKitRecordMapper`) and the iPhone (`MobileCloudRecordPayload`)
/// share this; the web's `parseCloudKitPayload` does the same.
///
/// Only keys change, never values, and only keys shaped like identifiers that carry the word as
/// a notebook (never `projection`, `projected` or Linear's projects), so a title, a note or a
/// dictionary keyed by ids reads as it was saved. A payload with no retired key is returned
/// byte for byte.
enum RetiredNotebookWording {
    private static let marker = Data("roject".utf8)

    /// The key this build uses for `key`, or nil when `key` is not a retired one.
    static func currentKey(_ key: String) -> String? {
        guard key.contains("roject"), isIdentifier(key) else { return nil }
        let lowered = key.lowercased()
        for kept in ["projection", "projected", "projector", "unproject", "linear"] where lowered.contains(kept) {
            return nil
        }
        let renamed = key
            .replacingOccurrences(of: "Projects", with: "Notebooks")
            .replacingOccurrences(of: "projects", with: "notebooks")
            .replacingOccurrences(of: "Project", with: "Notebook")
            .replacingOccurrences(of: "project", with: "notebook")
        return renamed == key ? nil : renamed
    }

    /// `data` with every retired key renamed; `data` itself when it holds none or is not JSON.
    static func currentPayload(_ data: Data) -> Data {
        guard data.range(of: marker) != nil,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return data
        }
        var changed = false
        let current = renamingKeys(in: object, changed: &changed)
        guard changed,
              let rewritten = try? JSONSerialization.data(withJSONObject: current, options: [.fragmentsAllowed]) else {
            return data
        }
        return rewritten
    }

    private static func renamingKeys(in object: Any, changed: inout Bool) -> Any {
        if let dictionary = object as? [String: Any] {
            var result: [String: Any] = [:]
            result.reserveCapacity(dictionary.count)
            // A key already under its current name wins over a retired twin.
            for (key, value) in dictionary where currentKey(key) == nil {
                result[key] = renamingKeys(in: value, changed: &changed)
            }
            for (key, value) in dictionary {
                guard let renamed = currentKey(key) else { continue }
                changed = true
                if result[renamed] == nil {
                    result[renamed] = renamingKeys(in: value, changed: &changed)
                }
            }
            return result
        }
        if let array = object as? [Any] {
            return array.map { renamingKeys(in: $0, changed: &changed) }
        }
        return object
    }

    private static func isIdentifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }
}
