import WebKit

/// ForeverLM shows YouTube one video at a time, and nothing YouTube recommends
/// around it. The product owner (2026-09-28): "i want to make sure you don't allow the user
/// to go down a youtube rabbit hole from within this app. the algorithmic
/// recommendations should be blocked".
///
/// Every web view in the app — a Browser tab, a source's live page, a Doc or
/// Site, a book — asks this before one of its pages leaves for a YouTube
/// address (`WebPagePolicy.action`). A video plays in the Reader's player,
/// which shows that video and nothing else of YouTube (`YouTubeWatchPageView`);
/// any other page of YouTube's own — the home feed, a channel, search, Shorts,
/// a playlist, subscriptions — does not open inside ForeverLM at all. YouTube
/// players embedded in other sites stay, stripped of their suggestions by
/// `YouTubeDistractionFilter`'s embed rule.
enum YouTubeContainment {
    enum Decision: Equatable {
        /// Not a page of YouTube's own: the web view's usual rules apply.
        case notYouTube
        /// A YouTube video, at the watch address the Reader's player plays it at.
        case video(URL)
        /// A page of YouTube's own that is not a video.
        case refused
    }

    static let refusalMessage = "ForeverLM opens YouTube one video at a time, not its feed, channels or search."

    static func decision(for urlString: String) -> Decision {
        guard let url = URL(string: urlString) else { return .notYouTube }
        return decision(for: url)
    }

    static func decision(for url: URL) -> Decision {
        guard let host = url.host?.lowercased(), youTubeHosts.contains(host) else { return .notYouTube }
        if let watchURL = YouTubeURLMetadata.watchURL(for: url.absoluteString) { return .video(watchURL) }
        // Passing through, not a page: the end of a Google sign-in, and
        // YouTube's hop to a link's destination off YouTube.
        if passThroughPaths.contains(url.path.lowercased()) { return .notYouTube }
        return .refused
    }

    /// The hosts that serve YouTube's own pages. Google's sign-in and YouTube's
    /// consent page (`consent.youtube.com`) are not among them.
    private static let youTubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtu.be",
        "youtube-nocookie.com", "www.youtube-nocookie.com"
    ]

    private static let passThroughPaths: Set<String> = ["/signin", "/redirect"]
}

/// Strips YouTube's watch-page chrome so the reader shows the player and nothing else.
///
/// The reader loads the real watch page rather than the `/embed/` iframe: uploaders can
/// disable embedding per video, and `rel=0` has only restricted related videos to the same
/// channel since 2018, so the embed is both less reliable and no less distracting. Loading
/// the watch page means the masthead, recommendations, comments, and end screens come along
/// with it.
///
/// A `WKContentRuleList` removes them before first paint and keeps applying across YouTube's
/// SPA navigation, neither of which an injected stylesheet does cleanly. Layout reflow —
/// collapsing the now-empty columns so the player fills the pane — is not expressible as
/// `css-display-none` and lives in `YouTubeWatchPageView.watchPageChromeStyleScript`.
///
/// The same list has a second rule for YouTube players other sites embed — an article's, a
/// Doc's, any page in a Browser tab: inside an embed's frame the player's suggestion layers
/// are hidden too, so its pause and end screens offer no video to click on to. Every web view
/// that can show other sites attaches the list (`attach(to:)`).
enum YouTubeDistractionFilter {
    /// Bump this suffix whenever the selectors or rules change. `WKContentRuleListStore`
    /// caches compiled lists on disk by identifier and would otherwise keep returning the old one.
    private static let identifier = "foreverlm-youtube-distraction-v5"

    /// Everything the watch page hides; also the stylesheet the player falls back on when the
    /// rule list cannot compile (`YouTubeWatchPageView.watchPageChromeStyleScript`).
    static var hiddenSelectors: [String] { watchPageChromeSelectors + playerSuggestionSelectors }

    private static let watchPageChromeSelectors = [
        // Page chrome around the player.
        "#masthead-container",
        "ytd-masthead",
        "#secondary",
        "#below",
        "#comments",
        "#chat",
        "ytd-live-chat-frame",
        // Shelves and ad slots YouTube injects into the primary column.
        "ytd-merch-shelf-renderer",
        "#donation-shelf",
        "#ticket-shelf",
        "#player-ads",
        "ytd-companion-slot-renderer",
        ".ytp-ad-overlay-container",
        // YouTube's browse surfaces — the home feed, channels, subscriptions,
        // search results — and the guide beside them. The reader never shows one
        // (`YouTubeWatchPageView.watchPageStayOnVideoScript` turns the page back to
        // its video), and these keep the feed from painting in the moment before.
        "ytd-browse",
        "ytd-search",
        "ytd-mini-guide-renderer",
        "tp-yt-app-drawer#guide"
    ]

    /// The player's own suggestions and the controls that leave the video: hidden on the
    /// watch page, and in every YouTube player another site embeds.
    private static let playerSuggestionSelectors = [
        // In-player suggestions: cards during playback, the grids at the end, and the
        // "More videos" panel that covers the frame every time you pause to think.
        // The end-of-video wall exists in two generations: the classic
        // .html5-endscreen videowall (hiding the layer covers its tiles and
        // pagination arrows) and the modern .ytp-fullscreen-grid of
        // .ytp-modern-videowall-still tiles, which is a separate #movie_player
        // child that .ytp-endscreen-content never covered.
        ".ytp-ce-element",
        ".html5-endscreen",
        ".ytp-endscreen-content",
        ".ytp-fullscreen-grid",
        ".ytp-modern-videowall-still",
        ".ytp-upnext",
        ".ytp-pause-overlay",
        ".ytp-suggested-action",
        ".ytp-autonav-endscreen-upnext-container",
        ".ytp-autonav-endscreen-countdown-overlay",
        ".ytp-cards-button",
        ".ytp-cards-teaser",
        // Player controls that leave the video: the miniplayer button shrinks it
        // into a corner over the home feed, and next/previous play another one.
        // `YouTubeWatchPageView.watchPageStayOnVideoScript` also refuses their
        // keys and the navigations themselves; these only take the buttons away.
        ".ytp-miniplayer-button",
        ".ytp-next-button",
        ".ytp-prev-button",
        // The autoplay switch: `watchPageChromeStyleScript` turns it off, and
        // left in view it is one click from YouTube choosing what plays next.
        ".ytp-autonav-toggle",
        // An embed's own offers of more: "More videos", and the related-video
        // wall its end screen opens on.
        ".ytp-more-videos-view",
        ".ytp-videowall-still"
    ]

    private static var cached: WKContentRuleList?
    private static var pending: [(WKContentRuleList?) -> Void] = []
    private static var isResolving = false

    /// Resolves the compiled rule list, compiling it on first use and reusing the store's
    /// on-disk copy afterwards.
    ///
    /// The completion is always called exactly once, on the main queue, and is called with
    /// `nil` when compilation fails — callers must still load the page in that case. A
    /// distracting player beats a blank one, and a silent no-video failure would look
    /// exactly like a broken source.
    @MainActor
    static func resolve(completion: @escaping (WKContentRuleList?) -> Void) {
        if let cached {
            completion(cached)
            return
        }

        pending.append(completion)
        guard !isResolving else { return }
        isResolving = true

        guard let store = WKContentRuleListStore.default(), let json = encodedRules() else {
            finish(with: nil)
            return
        }

        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            if let list {
                finish(with: list)
                return
            }
            // Not compiled yet (first launch, or the identifier was bumped). The compile
            // itself runs off the main thread inside WebKit.
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { compiled, error in
                if let error {
                    print("[YouTubeDistractionFilter] rule compilation failed, loading unfiltered: \(error)")
                }
                finish(with: compiled)
            }
        }
    }

    /// Gives a web view that can show other sites the embed rule, so a YouTube player a page
    /// embeds shows no suggestions. Attached as soon as the list resolves — at once after its
    /// first use in a session — so at worst the first page of a launch goes unfiltered.
    @MainActor
    static func attach(to userContentController: WKUserContentController) {
        resolve { list in
            if let list { userContentController.add(list) }
        }
    }

    private static func finish(with list: WKContentRuleList?) {
        DispatchQueue.main.async {
            cached = list
            isResolving = false
            let waiters = pending
            pending = []
            for waiter in waiters {
                waiter(list)
            }
        }
    }

    private static func encodedRules() -> String? {
        let rules: [[String: Any]] = [
            // The watch page, in the Reader's player.
            [
                "trigger": [
                    "url-filter": ".*",
                    "if-domain": ["*youtube.com"]
                ],
                "action": [
                    "type": "css-display-none",
                    "selector": hiddenSelectors.joined(separator: ", ")
                ]
            ],
            // A player another site embeds, matched by its frame's own address.
            // WebKit's rule patterns have no alternation, hence the optional group.
            [
                "trigger": [
                    "url-filter": "^https?://([a-z0-9-]+\\.)?youtube(-nocookie)?\\.com/embed/"
                ],
                "action": [
                    "type": "css-display-none",
                    "selector": playerSuggestionSelectors.joined(separator: ", ")
                ]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
