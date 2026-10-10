import Foundation
import UniformTypeIdentifiers

/// Serving a site kept in the library at `foreverlm-site://<artifact-id>/…`:
/// which file an address names, and the response a web view gets for it,
/// under the sandbox policy every such page is served with. The Mac's
/// `LocalSiteSchemeHandler` serves from the record's folder in its content
/// root; the phone's `MobileLocalSiteSchemeHandler` from the files it unpacked
/// from the Artifact's CloudKit body, to show a walkthrough's animation by
/// reference. One rule for both, so a page behaves the same on each.
enum LocalSiteServing {
    /// `LinkedPage.localSiteScheme`.
    static let scheme = "foreverlm-site"

    static let contentSecurityPolicy = "sandbox allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-modals allow-downloads allow-pointer-lock"

    /// The record a local site address names, lowercased as WebKit hands a
    /// host back; nil for any other address.
    static func siteID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              let host = url.host?.lowercased(), !host.isEmpty,
              !host.contains(".."),
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else {
            return nil
        }
        return host
    }

    /// The file a request names inside the record's site folder, or nil when
    /// the address is not one of the record's files.
    static func fileURL(for url: URL, siteDirectory: (String) -> URL) -> URL? {
        guard let artifactID = siteID(from: url) else { return nil }
        let site = siteDirectory(artifactID)
        let rawPath = url.path.removingPercentEncoding ?? url.path
        var relative = rawPath.split(separator: "/").joined(separator: "/")
        if relative.isEmpty || rawPath.hasSuffix("/") {
            relative = relative.isEmpty ? SiteFilePath.entryFile : relative + "/" + SiteFilePath.entryFile
        }
        guard let path = SiteFilePath.normalize(relative) else { return nil }
        var file = site.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            file = file.appendingPathComponent(SiteFilePath.entryFile)
        }
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    static func answer(
        for request: URLRequest,
        missingPage: String,
        siteDirectory: (String) -> URL
    ) -> (response: URLResponse, body: Data) {
        let url = request.url ?? URL(string: "\(scheme)://missing/")!
        var headers = [
            "Content-Security-Policy": contentSecurityPolicy,
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
            "X-Content-Type-Options": "nosniff",
        ]
        guard let file = fileURL(for: url, siteDirectory: siteDirectory),
              let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
            let body = Data("<!doctype html><title>There is no page here</title><p>\(missingPage)</p>".utf8)
            headers["Content-Type"] = "text/html; charset=utf-8"
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, body)
        }
        var type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if type.hasPrefix("text/") || type == "application/javascript" || type == "application/json" || type == "image/svg+xml" {
            type += "; charset=utf-8"
        }
        headers["Content-Type"] = type
        headers["Accept-Ranges"] = "bytes"
        if let range = request.value(forHTTPHeaderField: "Range"), let bounds = byteRange(range, length: data.count) {
            headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(data.count)"
            headers["Content-Length"] = String(bounds.count)
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, data.subdata(in: bounds))
        }
        headers["Content-Length"] = String(data.count)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (response, data)
    }

    /// `bytes=a-b`, `bytes=a-` or `bytes=-n` as a half-open range inside the
    /// file; nil for anything else, which is answered whole.
    static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        guard length > 0, header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(parts[0]), start < length else { return nil }
        let end = parts[1].isEmpty ? length - 1 : min(Int(parts[1]) ?? (length - 1), length - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
}
