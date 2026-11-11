import Foundation

import AppKit

/// Preference for which browser to use when opening article URLs.
enum BrowserPreference: String, CaseIterable, Identifiable {
    case sourceOrigin
    case systemDefault
    case safari
    case chrome
    case brave
    case arc
    case opera

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sourceOrigin: return "Source Browser"
        case .systemDefault: return "System Default"
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .opera: return "Opera"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .sourceOrigin, .systemDefault: return nil
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .brave: return "com.brave.Browser"
        case .arc: return "company.thebrowser.Browser"
        case .opera: return "com.operasoftware.Opera"
        }
    }

    var iconName: String {
        switch self {
        case .sourceOrigin: return "arrow.triangle.branch"
        case .systemDefault: return "globe"
        case .safari: return "safari"
        case .chrome: return "globe"
        case .brave: return "shield.lefthalf.filled"
        case .arc: return "globe"
        case .opera: return "globe"
        }
    }
}

enum BrowserService {

    /// Read the current preference, which has no UI and is set with
    /// `defaults write com.foreverlm preferredBrowser <value>`.
    ///
    /// Goes through `DefaultsEscapeHatch` so the command works regardless of which
    /// preference domain it landed in — the sandboxed and non-sandboxed builds read
    /// different files, and `defaults` targets the sandboxed one.
    static var currentPreference: BrowserPreference {
        guard let raw = DefaultsEscapeHatch.string(forKey: Prefs.Discovery.preferredBrowser.name),
              let pref = BrowserPreference(rawValue: raw) else {
            return .sourceOrigin
        }
        return pref
    }

    /// Bundle IDs for known browsers, keyed by DiscoveryOrigin.
    static func bundleIdentifier(for origin: DiscoveryOrigin) -> String? {
        switch origin {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .brave: return "com.brave.Browser"
        default: return nil
        }
    }

    /// Open a URL using the user's preferred browser setting, with optional discovery origin.
    static func open(
        _ url: URL,
        discoveryOrigin: DiscoveryOrigin? = nil,
        preference: BrowserPreference = currentPreference
    ) {
        #if os(macOS)
        let targetBundleID: String? = {
            switch preference {
            case .sourceOrigin:
                if let origin = discoveryOrigin {
                    return bundleIdentifier(for: origin)
                }
                return nil
            case .systemDefault:
                return nil
            default:
                return preference.bundleIdentifier
            }
        }()

        if let bundleID = targetBundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

// MARK: - Source → Web Destination

extension BrowserService {
    /// Where "open this source in a browser" should land, plus whether that
    /// destination is the source itself or a search standing in for it.
    struct SourceWebDestination: Equatable {
        let url: URL
        /// True when no link to the source exists and this is a title search.
        let isSearch: Bool
    }

    /// Resolve the page to show when the learner asks to open a source in a
    /// browser. Returns nil for a source with no web presence at all.
    ///
    /// Papers get their own ladder because their stored URL is the least
    /// reliable of any source type. It is often the PDF rather than the page a
    /// human reads, and a paywalled publisher answers the PDF path with a 403
    /// while serving the landing page that carries sign-in and institutional
    /// access. Roughly a third of the papers here were added from a local PDF
    /// and carry no web URL at all, so the ladder continues through the DOI and
    /// ends at a title search: every paper has somewhere to go.
    static func sourceWebDestination(for article: StudioArticle) -> SourceWebDestination? {
        guard article.sourceType == .paper else {
            // Deliberately not `publicURL`: that field is a share/export
            // destination and falls back to an Amazon or Apple Podcasts *search*
            // for anything without a link of its own, which is not what a menu
            // item reading "Open in Browser" promises.
            let candidates = [article.url, article.podcastWebPageURL, article.normalizedURL]
            guard let url = candidates.compactMap(webURL).first else { return nil }
            return SourceWebDestination(url: url, isSearch: false)
        }

        if let stored = webURL(article.url) {
            // A direct PDF link is the wrong browser destination: sign-in and
            // institutional access live on the landing page, and a paywalled
            // host refuses the PDF path outright.
            if PaperService.isDirectPDFURL(stored.absoluteString) {
                if let abstract = PaperService.paperAbstractURL(from: stored.absoluteString),
                   let url = URL(string: abstract) {
                    return SourceWebDestination(url: url, isSearch: false)
                }
                if let doi = doiURL(for: article) {
                    return SourceWebDestination(url: doi, isSearch: false)
                }
            }
            return SourceWebDestination(url: stored, isSearch: false)
        }

        if let doi = doiURL(for: article) {
            return SourceWebDestination(url: doi, isSearch: false)
        }

        guard let search = scholarSearchURL(for: article.title) else { return nil }
        return SourceWebDestination(url: search, isSearch: true)
    }

    private static func webURL(_ value: String?) -> URL? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              clean.hasPrefix("http://") || clean.hasPrefix("https://") else {
            return nil
        }
        return URL(string: clean)
    }

    private static func doiURL(for article: StudioArticle) -> URL? {
        let raw = (article.doi ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("http") { return URL(string: raw) }
        // Older DOIs carry characters — angle brackets, semicolons — that the
        // strict URL parser rejects unencoded.
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://doi.org/\(encoded)")
    }

    private static func scholarSearchURL(for title: String) -> URL? {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://scholar.google.com/scholar")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}
