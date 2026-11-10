import Foundation

/// Local, regenerable metadata for a file in a Notebook workspace.
///
/// The file's relative path is the synced state. This record is a fast SQLite
/// projection that each device can rebuild by scanning the Notebook folder.
struct NotebookFileRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let notebookID: String
    let relativePath: String
    let name: String
    let contentType: String?
    let sizeBytes: Int64
    let modifiedAt: Date
    let createdAt: Date

    var pathExtension: String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }

    var isMarkdownDocument: Bool {
        NotebookMarkdownFilePath.isMarkdownExtension(pathExtension)
    }

    /// User-owned path within the Notebook workspace.
    var notebookRelativePath: String {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2 else { return name }
        return components.dropFirst(2).map(String.init).joined(separator: "/")
    }

    var notebookDirectoryPath: String? {
        let components = notebookRelativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return nil }
        return components.dropLast().map(String.init).joined(separator: "/")
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// A complete, revision-bound Markdown file from a Notebook workspace.
///
/// The SHA-256 revision is the optimistic-concurrency token used by both the
/// in-app editor and MCP. An edit can never silently overwrite a newer Finder,
/// iCloud, or second-device revision.
struct NotebookMarkdownFileSnapshot: Equatable, Sendable {
    let record: NotebookFileRecord
    let markdown: String
    let revision: String
}

enum NotebookMarkdownFileError: LocalizedError, Equatable {
    case invalidPath(String)
    case unsupportedExtension
    case tooLarge(maxBytes: Int)
    case unavailable(String)
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let reason):
            return "Invalid Markdown file path: \(reason)"
        case .unsupportedExtension:
            return "Notebook artifacts must use a .md or .markdown extension."
        case .tooLarge(let maxBytes):
            return "Markdown files larger than \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)) cannot be edited in ForeverLM."
        case .unavailable(let path):
            return "Notebook file “\(path)” is unavailable on this device."
        case .conflict(let path):
            return "Notebook file “\(path)” changed since it was opened. Reload it before saving so the newer revision is not overwritten."
        }
    }
}

/// Deterministic path validation for user-owned Notebook artifacts. Paths are
/// identity, so they never pass through an LLM or title-cleanup heuristic.
enum NotebookMarkdownFilePath {
    static let supportedExtensions: Set<String> = ["md", "markdown"]

    static func isMarkdownExtension(_ pathExtension: String) -> Bool {
        supportedExtensions.contains(pathExtension.lowercased())
    }

    static func validatedRelativePath(_ rawPath: String) throws -> String {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw NotebookMarkdownFileError.invalidPath("a filename is required.")
        }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else {
            throw NotebookMarkdownFileError.invalidPath("use a path inside the Notebook, not an absolute path.")
        }
        guard !path.contains("\\"), !path.contains("\0") else {
            throw NotebookMarkdownFileError.invalidPath("the path contains an unsupported character.")
        }
        guard path.count <= 512 else {
            throw NotebookMarkdownFileError.invalidPath("the path is too long.")
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count <= 32,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 255 }) else {
            throw NotebookMarkdownFileError.invalidPath("empty, dot, and parent-directory components are not allowed.")
        }
        guard let filename = components.last,
              isMarkdownExtension(URL(fileURLWithPath: filename).pathExtension) else {
            throw NotebookMarkdownFileError.unsupportedExtension
        }
        return components.joined(separator: "/")
    }
}
