import Foundation

/// Turning a Markdown Doc into a Google Doc: the one Drive API call that
/// creates the document, and what comes back from it.
///
/// Google Drive converts an uploaded HTML file into a Google Doc when the
/// metadata asks for `application/vnd.google-apps.document`, so conversion is
/// a single `files.create` with a multipart body: a JSON part naming the doc
/// and its target type, and an HTML part holding the rendered Markdown. The
/// pieces that need no network are here as pure functions so they can be
/// pinned by tests; `GoogleDriveService.createGoogleDoc` supplies the token
/// and sends the request.
enum GoogleDocConversion {
    /// The Google Docs type Drive converts the upload into.
    static let googleDocMimeType = "application/vnd.google-apps.document"
    /// Drive's multipart upload endpoint for `files.create`.
    static let uploadURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!

    /// The `files.create` request for one document. `boundary` is a parameter
    /// so a test can pin the body byte for byte; callers take the default.
    static func createRequest(
        title: String,
        html: String,
        accessToken: String,
        boundary: String = defaultBoundary()
    ) throws -> URLRequest {
        var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id,name,webViewLink"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("ForeverLM", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        request.httpBody = try multipartBody(title: title, html: html, boundary: boundary)
        return request
    }

    /// The multipart/related body: the metadata part, then the media part,
    /// each introduced by the boundary and closed by the terminating one.
    static func multipartBody(title: String, html: String, boundary: String) throws -> Data {
        let metadata = try metadataJSON(title: title)
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadata)
        body.append("\r\n--\(boundary)\r\n")
        body.append("Content-Type: text/html; charset=UTF-8\r\n\r\n")
        body.append(Data(html.utf8))
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    /// The metadata part: the document's name and the type Drive converts it
    /// into. Encoded with sorted keys so the same title gives the same bytes.
    static func metadataJSON(title: String) throws -> Data {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = FileMetadata(
            name: trimmed.isEmpty ? LinkedGoogleDoc.placeholderTitle : trimmed,
            mimeType: googleDocMimeType
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(metadata)
    }

    /// The new document's id from Drive's `files.create` response.
    static func documentID(fromCreateResponse data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(CreateResponse.self, from: data) else {
            throw GoogleDocConversionError.invalidResponse
        }
        let id = response.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw GoogleDocConversionError.invalidResponse }
        return id
    }

    /// Google's own account of a failed request, when the body carries one;
    /// nil for a body that is not Drive's error shape.
    static func errorMessage(fromResponse data: Data) -> String? {
        guard let failure = try? JSONDecoder().decode(FailureResponse.self, from: data) else { return nil }
        let message = failure.error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    /// A boundary that cannot appear in the parts: Drive's own examples use a
    /// fixed token, but a random suffix rules out a document that happens to
    /// contain the marker.
    static func defaultBoundary() -> String {
        "foreverlm_doc_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private struct FileMetadata: Encodable {
        let name: String
        let mimeType: String
    }

    private struct CreateResponse: Decodable {
        let id: String
    }

    private struct FailureResponse: Decodable {
        struct Detail: Decodable {
            let message: String
        }
        let error: Detail
    }
}

/// Why a conversion did not happen, in the words the sheet shows.
enum GoogleDocConversionError: LocalizedError, Equatable {
    /// Sign-in was cancelled, timed out, or Google did not grant access to
    /// create files.
    case signInIncomplete(String)
    /// Drive answered the create with an error.
    case refused(status: Int, detail: String?)
    /// The request never reached Drive, or the answer never came back.
    case network(String)
    /// Drive said it created something but did not name the document.
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .signInIncomplete(let reason):
            return "Google sign-in did not finish, so nothing was converted. \(reason)"
        case .refused(let status, let detail):
            if let detail, !detail.isEmpty {
                return "Google Drive refused to create the document (HTTP \(status)): \(detail)"
            }
            return "Google Drive refused to create the document (HTTP \(status))."
        case .network(let reason):
            return "Could not reach Google Drive. \(reason)"
        case .invalidResponse:
            return "Google Drive did not say which document it created, so the page was left as it was."
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
