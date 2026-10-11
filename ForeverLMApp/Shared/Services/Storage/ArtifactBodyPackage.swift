import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Deterministic wire package for one Article body and the media referenced by
/// that Markdown. JSON is used only for the package manifest in transit; local
/// persistent metadata remains in SQLite and the canonical content is ordinary
/// files under `Artifacts/<id>`.
///
/// Format 2 adds a site's files (`siteFiles`): a ForeverLM site or animation
/// kept in the library travels between devices here, beside its text copy.
/// A body with no site is still
/// written as format 1, byte for byte, so a Doc's revision never changes.
struct ArtifactBodyPackage: Sendable, Equatable {
    static let formatVersion = 1
    static let siteFormatVersion = 2
    static let maxPackageBytes = 48 * 1_024 * 1_024
    static let maxMarkdownBytes = 5 * 1_024 * 1_024
    private static let magic = Data("FYNART01".utf8)

    struct Encoded: Sendable, Equatable {
        let data: Data
        let revision: String
        let byteCount: Int
    }

    struct Decoded: Sendable, Equatable {
        let markdown: String
        let attachments: [Attachment]
        let revision: String
        /// The site's files, in path order; nil for a body with no site.
        var siteFiles: [SiteFile]? = nil
    }

    struct Attachment: Sendable, Equatable {
        let token: String
        let mimeType: String
        let data: Data
    }

    private struct Manifest: Codable {
        let version: Int
        let markdownByteCount: Int
        let attachments: [ManifestAttachment]
        var siteFiles: [ManifestSiteFile]? = nil
    }

    private struct ManifestSiteFile: Codable {
        let path: String
        let byteCount: Int
        let sha256: String
    }

    private struct ManifestAttachment: Codable {
        let token: String
        let mimeType: String
        let byteCount: Int
        let sha256: String
    }

    static func encode(markdown: String, attachmentDirectory: URL?, siteFiles: [SiteFile]? = nil) throws -> Encoded {
        let markdownData = Data(markdown.utf8)
        guard markdownData.count <= maxMarkdownBytes else {
            throw ArtifactBodyPackageError.markdownTooLarge(maxBytes: maxMarkdownBytes)
        }

        var attachments: [(manifest: ManifestAttachment, data: Data)] = []
        for token in try referencedAttachmentTokens(markdown) {
            guard let attachmentDirectory else {
                throw ArtifactBodyPackageError.missingAttachment(token)
            }
            let url = attachmentDirectory.appendingPathComponent(token, isDirectory: false)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else {
                throw ArtifactBodyPackageError.missingAttachment(token)
            }
            attachments.append((
                ManifestAttachment(
                    token: token,
                    mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                        ?? "application/octet-stream",
                    byteCount: data.count,
                    sha256: sha256(data)
                ),
                data
            ))
        }

        let sortedSiteFiles = siteFiles?.sorted { $0.path < $1.path }
        for file in sortedSiteFiles ?? [] where SiteFilePath.normalize(file.path) != file.path {
            throw ArtifactBodyPackageError.invalidSiteFile(file.path)
        }
        let manifest = Manifest(
            version: sortedSiteFiles == nil ? formatVersion : siteFormatVersion,
            markdownByteCount: markdownData.count,
            attachments: attachments.map(\.manifest),
            siteFiles: sortedSiteFiles?.map {
                ManifestSiteFile(path: $0.path, byteCount: $0.data.count, sha256: sha256($0.data))
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        guard manifestData.count <= Int(UInt32.max) else {
            throw ArtifactBodyPackageError.invalidPackage
        }

        var data = Data()
        data.reserveCapacity(
            magic.count + 4 + manifestData.count + markdownData.count
                + attachments.reduce(0) { $0 + $1.data.count }
                + (sortedSiteFiles ?? []).reduce(0) { $0 + $1.data.count }
        )
        data.append(magic)
        var manifestLength = UInt32(manifestData.count).bigEndian
        withUnsafeBytes(of: &manifestLength) { data.append(contentsOf: $0) }
        data.append(manifestData)
        data.append(markdownData)
        for attachment in attachments { data.append(attachment.data) }
        for file in sortedSiteFiles ?? [] { data.append(file.data) }
        guard data.count <= maxPackageBytes else {
            throw ArtifactBodyPackageError.packageTooLarge(maxBytes: maxPackageBytes)
        }
        return Encoded(data: data, revision: sha256(data), byteCount: data.count)
    }

    static func decode(_ data: Data, expectedRevision: String? = nil) throws -> Decoded {
        guard data.count >= magic.count + 4,
              data.prefix(magic.count) == magic else {
            throw ArtifactBodyPackageError.invalidPackage
        }
        let revision = sha256(data)
        if let expectedRevision,
           !expectedRevision.isEmpty,
           revision.caseInsensitiveCompare(expectedRevision) != .orderedSame {
            throw ArtifactBodyPackageError.revisionMismatch
        }

        let lengthOffset = magic.count
        let manifestLength = data[lengthOffset..<(lengthOffset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        let manifestStart = lengthOffset + 4
        let manifestEnd = manifestStart + Int(manifestLength)
        guard manifestEnd <= data.count else {
            throw ArtifactBodyPackageError.invalidPackage
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: data[manifestStart..<manifestEnd]
        )
        guard manifest.version == formatVersion || manifest.version == siteFormatVersion,
              manifest.markdownByteCount >= 0 else {
            throw ArtifactBodyPackageError.unsupportedVersion(manifest.version)
        }

        var cursor = manifestEnd
        let markdownEnd = cursor + manifest.markdownByteCount
        guard markdownEnd <= data.count else {
            throw ArtifactBodyPackageError.invalidPackage
        }
        let markdown = String(decoding: data[cursor..<markdownEnd], as: UTF8.self)
        cursor = markdownEnd
        var attachments: [Attachment] = []
        for descriptor in manifest.attachments {
            guard validAttachmentToken(descriptor.token),
                  descriptor.byteCount > 0,
                  cursor + descriptor.byteCount <= data.count else {
                throw ArtifactBodyPackageError.invalidPackage
            }
            let bytes = Data(data[cursor..<(cursor + descriptor.byteCount)])
            guard sha256(bytes).caseInsensitiveCompare(descriptor.sha256) == .orderedSame else {
                throw ArtifactBodyPackageError.attachmentIntegrity(descriptor.token)
            }
            attachments.append(Attachment(
                token: descriptor.token,
                mimeType: descriptor.mimeType,
                data: bytes
            ))
            cursor += descriptor.byteCount
        }
        var siteFiles: [SiteFile]? = nil
        if manifest.version == siteFormatVersion {
            var files: [SiteFile] = []
            var seen = Set<String>()
            for descriptor in manifest.siteFiles ?? [] {
                guard SiteFilePath.normalize(descriptor.path) == descriptor.path,
                      seen.insert(descriptor.path.lowercased()).inserted,
                      descriptor.byteCount >= 0,
                      cursor + descriptor.byteCount <= data.count else {
                    throw ArtifactBodyPackageError.invalidSiteFile(descriptor.path)
                }
                let bytes = Data(data[cursor..<(cursor + descriptor.byteCount)])
                guard sha256(bytes).caseInsensitiveCompare(descriptor.sha256) == .orderedSame else {
                    throw ArtifactBodyPackageError.attachmentIntegrity(descriptor.path)
                }
                files.append(SiteFile(path: descriptor.path, data: bytes))
                cursor += descriptor.byteCount
            }
            siteFiles = files
        }
        guard cursor == data.count else {
            throw ArtifactBodyPackageError.invalidPackage
        }
        return Decoded(markdown: markdown, attachments: attachments, revision: revision, siteFiles: siteFiles)
    }

    static func referencedAttachmentTokens(_ markdown: String) throws -> [String] {
        let pattern = #"foreverlm://attachment/([^\s\)\]\"']+)"#
        let expression = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        var ordered: [String] = []
        var seen = Set<String>()
        for match in expression.matches(in: markdown, range: fullRange) {
            guard let range = Range(match.range(at: 1), in: markdown) else { continue }
            let encoded = String(markdown[range])
            let token = encoded.removingPercentEncoding ?? encoded
            guard validAttachmentToken(token) else {
                throw ArtifactBodyPackageError.invalidAttachment(token)
            }
            if seen.insert(token).inserted { ordered.append(token) }
        }
        return ordered
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validAttachmentToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 180,
              token != ".", token != "..",
              !token.contains("/"), !token.contains("\\") else { return false }
        return token.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }
}

enum ArtifactBodyPackageError: LocalizedError, Equatable {
    case invalidPackage
    case unsupportedVersion(Int)
    case revisionMismatch
    case invalidAttachment(String)
    case missingAttachment(String)
    case attachmentIntegrity(String)
    case markdownTooLarge(maxBytes: Int)
    case packageTooLarge(maxBytes: Int)
    case invalidSiteFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            return "The synced Article body package is invalid."
        case .unsupportedVersion(let version):
            return "This Article uses unsupported body format version \(version)."
        case .revisionMismatch:
            return "The synced Article body does not match its declared revision."
        case .invalidAttachment(let token):
            return "The Article contains an invalid attachment reference: \(token)"
        case .missingAttachment(let token):
            return "The Article attachment \(token) is unavailable."
        case .attachmentIntegrity(let token):
            return "The Article attachment \(token) failed its integrity check."
        case .markdownTooLarge(let maxBytes):
            return "The Article text exceeds the \(maxBytes)-byte limit."
        case .packageTooLarge(let maxBytes):
            return "The page and its pictures and files exceed the \(maxBytes)-byte sync limit."
        case .invalidSiteFile(let path):
            return "The site file \(path) is not a path a site can hold."
        }
    }
}
