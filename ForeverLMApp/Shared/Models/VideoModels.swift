// Video and YouTube models, moved out of Models.swift.

import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum YouTubeURLMetadata {
    static func isYouTubeURL(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return lower.contains("youtube.com/watch") || lower.contains("youtu.be/")
            || lower.contains("youtube.com/v/") || lower.contains("youtube.com/embed/")
            || lower.contains("youtube.com/shorts/")
    }

    /// The watch address of the YouTube video an address names — a watch link,
    /// youtu.be, Shorts, a livestream, an embed (youtube-nocookie.com's too) —
    /// or nil when it names none. ForeverLM shows YouTube one video at a time,
    /// in the Reader's player, and this is the address it plays it at
    /// (`YouTubeContainment`): the video and the moment a link pointed to, and
    /// no playlist or Mix for YouTube to carry on through.
    static func watchURL(for urlString: String) -> URL? {
        guard var components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased() else { return nil }
        // The privacy-enhanced embed is YouTube's player under another name.
        if host == "youtube-nocookie.com" || host == "www.youtube-nocookie.com" {
            components.host = "www.youtube.com"
        }
        guard let address = components.string,
              let videoID = ForeverLMCore.youtubeVideoID(from: address) else { return nil }
        var watch = URLComponents()
        watch.scheme = "https"
        watch.host = "www.youtube.com"
        watch.path = "/watch"
        watch.queryItems = [URLQueryItem(name: "v", value: videoID)]
        if let moment = components.queryItems?.first(where: { $0.name == "t" || $0.name == "start" })?.value,
           !moment.isEmpty {
            watch.queryItems?.append(URLQueryItem(name: "t", value: moment))
        }
        return watch.url
    }

    static func sanitizedVideoTitle(_ title: String) -> String? {
        let cleaned = decodeHTMLEntities(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "..."), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&rdquo;", "\""), ("&ldquo;", "\""),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let nsResult = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            for match in matches.reversed() {
                if let numRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[numRange]),
                   let scalar = Unicode.Scalar(codePoint),
                   let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }

        return result
    }
}

// MARK: - Video Playlists

struct VideoPlaylistMetadata: Codable, Equatable, Hashable, Sendable {
    var title: String
    var playlistURL: String
    var lastRefreshedAt: Date?
    var isHidden: Bool
    /// When true, the YouTube plugin re-checks this playlist in the background
    /// (shortly after launch, then every few hours) and imports any new videos.
    /// False for ordinary, manually-added playlists, which only refresh on demand.
    var autoImport: Bool
    /// How the followed item was added: "liked" for the Liked-videos feed,
    /// "foreverlm" for the owned playlist with that name, "channel" for a
    /// followed channel's uploads, or nil for an ordinary manually-added
    /// playlist group.
    var connectorKind: String?

    init(
        title: String,
        playlistURL: String,
        lastRefreshedAt: Date? = nil,
        isHidden: Bool = false,
        autoImport: Bool = false,
        connectorKind: String? = nil
    ) {
        self.title = title
        self.playlistURL = playlistURL
        self.lastRefreshedAt = lastRefreshedAt
        self.isHidden = isHidden
        self.autoImport = autoImport
        self.connectorKind = connectorKind
    }
}
