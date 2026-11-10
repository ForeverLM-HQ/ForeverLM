// Source fetching errors and the PDF fetch refusal.
import Foundation
import PDFKit

// MARK: - Errors

/// A PDF request the host answered with something other than the file, and
/// what it answered.
///
/// What `downloadPDF` throws when the publisher refuses the file, so a tool
/// relays what the publisher said (PubMed Central's "Supplemental document is
/// embargoed", HTTP 403) and not a bare "Failed to fetch source content". The
/// pipeline's decisions — paywall evidence, whether the reader's session is
/// worth a try — read `classification`; only the sentence says what happened.
struct PDFFetchRefusal: LocalizedError, Equatable {
    /// What the pipeline treats the answer as.
    let classification: SourceError
    let host: String
    /// The HTTP status of the answer; nil for an answer from the reader's session.
    let status: Int?
    let message: String

    var errorDescription: String? { message }

    /// A non-2xx answer. 403 classifies as `accessDenied`, the rest as `httpError`.
    static func httpStatus(
        _ status: Int,
        host: String,
        body: Data,
        contentType: String?,
        retryAfter: String?
    ) -> PDFFetchRefusal {
        let said = bodySummary(body, contentType: contentType).map { ": \($0)" } ?? ""
        let message: String
        switch status {
        case 429:
            let wait = retryAfter.map { ", asks to retry after \($0)" } ?? ""
            message = "\(host) is rate-limiting ForeverLM's requests (HTTP 429\(wait))\(said)"
        case 503 where retryAfter != nil:
            message = "\(host) is unavailable (HTTP 503, asks to retry after \(retryAfter ?? ""))\(said)"
        default:
            message = "\(host) refused the PDF (HTTP \(status))\(said)"
        }
        return PDFFetchRefusal(
            classification: status == 403 ? .accessDenied : .httpError(status),
            host: host,
            status: status,
            message: message
        )
    }

    /// A 2xx answer that is a page, not the file.
    static func page(host: String, body: Data, contentType: String?) -> PDFFetchRefusal {
        let title = bodySummary(body, contentType: contentType).map { " (“\($0)”)" } ?? ""
        return PDFFetchRefusal(
            classification: .fetchFailed,
            host: host,
            status: 200,
            message: "\(host) answered with a web page\(title), not the PDF"
        )
    }

    /// PMC's proof-of-work page, unsolved or shown again after its answer.
    static func unansweredProofOfWork(host: String, afterAnswer: Bool) -> PDFFetchRefusal {
        PDFFetchRefusal(
            classification: .fetchFailed,
            host: host,
            status: 200,
            message: afterAnswer
                ? "\(host) showed its “Preparing to download ...” check again after ForeverLM answered it, not the PDF"
                : "\(host) answered with its “Preparing to download ...” check, which ForeverLM could not answer, not the PDF"
        )
    }

    /// The reader's hidden web view ended somewhere other than the file.
    static func readerSession(host: String, pageTitle: String?, timedOut: Bool) -> PDFFetchRefusal {
        let title = pageTitle.flatMap { $0.isEmpty ? nil : " (“\($0)”)" } ?? ""
        return PDFFetchRefusal(
            classification: .fetchFailed,
            host: host,
            status: nil,
            message: timedOut
                ? "\(host) did not hand the reader's session the PDF before it timed out"
                : "\(host) showed the reader's session a page\(title), not the PDF"
        )
    }

    /// What a refusal body says, short enough for a sentence: a page's
    /// `<title>`, or the first line of a plain-text body. Nil for anything
    /// else (binary, empty, a page without a title).
    static func bodySummary(_ body: Data, contentType: String?) -> String? {
        guard !body.isEmpty, !body.contains(0),
              let text = String(data: body.prefix(64 * 1024), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isMarkup = trimmed.hasPrefix("<") || (contentType?.lowercased().contains("html") == true && trimmed.contains("<"))
        let summary: String
        if isMarkup {
            guard let range = trimmed.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else {
                return nil
            }
            summary = String(trimmed[range])
                .replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
                .decodingHTMLCharacterReferences()
        } else {
            summary = trimmed.components(separatedBy: .newlines).first ?? trimmed
        }
        let collapsed = summary
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }
}

extension SourceError {
    /// The `SourceError` a download failure amounts to for the paper
    /// pipeline's decisions, looking through a `PDFFetchRefusal`.
    static func classifying(_ error: Error) -> SourceError? {
        if let sourceError = error as? SourceError { return sourceError }
        if let refusal = error as? PDFFetchRefusal { return refusal.classification }
        return nil
    }
}

enum SourceError: LocalizedError, Equatable {
    case invalidURL
    case fetchFailed
    case accessDenied
    case httpError(Int)
    case decodingFailed
    case fileNotFound
    case localFileNotSupported
    case pdfReadFailed
    case paperMetadataExtractionFailed
    case paperIngestionFailed(String)
    case aiCreditsRequired
    case insufficientContent
    case unsupportedBookFormat
    case bookChapterBoundaryMismatch(String)
    case kindleConversionToolMissing
    case kindleConversionFailed(String)
    case googleDocsUnavailable(SourceService.GoogleDocsResource.Kind)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid source URL"
        case .fetchFailed: return "Failed to fetch source content"
        case .accessDenied: return "Access denied (paywall or bot protection)"
        case .insufficientContent: return "No archive.ph snapshot found or content too short"
        case .httpError(404): return "Article not found (404) — the URL may be incorrect or the article may have been retracted"
        case .httpError(let code): return "HTTP error \(code)"
        case .decodingFailed: return "Failed to decode source content"
        case .fileNotFound: return "Source file not found"
        case .localFileNotSupported: return "Local file access not available on this platform"
        case .pdfReadFailed: return "Failed to read PDF content"
        case .paperMetadataExtractionFailed:
            return "Paper ingestion failed because AI metadata extraction returned none of author, venue, and year"
        case .paperIngestionFailed(let message):
            return message
        case .aiCreditsRequired:
            return "Saved to your library, but reading it in is on hold: add your OpenRouter key in AI Usage (the sidebar's OpenRouter button) to finish ingesting it. You can open and read it now."
        case .unsupportedBookFormat: return "Unsupported book format"
        case .bookChapterBoundaryMismatch(let message): return message
        case .kindleConversionToolMissing: return "Install Calibre to import Kindle files: brew install --cask calibre"
        case .kindleConversionFailed(let message): return message
        case .googleDocsUnavailable(let kind):
            return "Could not export this \(kind.label) as text. Set its sharing to “Anyone with the link” — ForeverLM can only read link-accessible Google files."
        }
    }
}
