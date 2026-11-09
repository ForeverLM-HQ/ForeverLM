import Foundation

/// Reads a Sparkle appcast for one answer: the newest build this Mac could
/// install. Pure, and independent of Sparkle, so it can be tested on its own
/// and asked while Sparkle is holding a session.
///
/// Why the app reads its own feed at all: Sparkle consults the appcast only
/// when it has nothing to resume. Once it holds a downloaded archive, or an
/// installer is already waiting for the app to quit, every later check —
/// scheduled, on activation, and the pill's click alike — resumes that build
/// without asking the feed again. A release published in between stays
/// invisible until the resumed one is installed, and the freshly installed
/// build then announces the next one at once. `AppUpdateUserDriver` asks this
/// reader whether a resumed build is still the latest before letting anyone
/// install it.
///
/// Only what decides "newest for this Mac" is read: the build
/// (`sparkle:version`), the OS bounds, the channel and the platform.
/// Signatures, deltas, rollout phases and release notes stay Sparkle's; nothing
/// here installs anything.
enum AppcastFeed {
    struct Item: Equatable {
        /// `sparkle:version`, the build number Sparkle compares.
        var version: String
        /// `sparkle:shortVersionString`, the marketing version.
        var displayVersion: String?
        var minimumSystemVersion: String?
        var maximumSystemVersion: String?
        /// `sparkle:channel`; absent is the default channel every updater sees.
        /// Any other value is offered only to a Mac signed up for it
        /// (`BetaReleases`).
        var channel: String?
        /// `sparkle:os` on the enclosure; absent means macOS.
        var os: String?
    }

    /// Every `<item>` in the feed, in document order. Malformed XML yields what
    /// parsed before the error; a feed that is not RSS yields nothing.
    static func items(in data: Data) -> [Item] {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// The newest build the feed offers a Mac running `systemVersion`, or nil
    /// when the feed has none it could install.
    ///
    /// Mirrors the filters Sparkle applies before choosing: macOS items only,
    /// the default channel plus `allowedChannels` (what
    /// `allowedChannels(for:)` tells Sparkle), and OS bounds that admit this
    /// system. A build Sparkle would not offer must not count as "newer", or
    /// the pill would discard a build it can install for one it cannot.
    static func newestInstallableVersion(in data: Data, systemVersion: String, allowedChannels: Set<String>) -> String? {
        items(in: data)
            .filter { isInstallable($0, systemVersion: systemVersion, allowedChannels: allowedChannels) }
            .map(\.version)
            .max { compare($0, $1) == .orderedAscending }
    }

    /// Whether the feed publishes `build` as a beta: true when every item
    /// naming that build sits in a channel of its own (`sparkle:channel`,
    /// `beta`), false when one sits in the default channel (a promoted beta
    /// keeps its build number and loses its channel), and nil when the feed
    /// does not list the build at all (a Dev build, or one aged out of it).
    static func isBeta(build: String, in data: Data) -> Bool? {
        let listed = items(in: data).filter { $0.version == build }
        guard !listed.isEmpty else { return nil }
        return listed.allSatisfy { !($0.channel ?? "").isEmpty }
    }

    static func isInstallable(_ item: Item, systemVersion: String, allowedChannels: Set<String>) -> Bool {
        if let os = item.os, os.lowercased() != "macos" { return false }
        if let channel = item.channel, !channel.isEmpty, !allowedChannels.contains(channel) { return false }
        if let minimum = item.minimumSystemVersion, compare(systemVersion, minimum) == .orderedAscending {
            return false
        }
        if let maximum = item.maximumSystemVersion, compare(systemVersion, maximum) == .orderedDescending {
            return false
        }
        return true
    }

    /// The running system as a dotted version, the shape appcast bounds use.
    static var currentSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedDescending
    }

    /// Dotted-version comparison: components compared numerically where both
    /// are numbers, as text otherwise, and a missing trailing component reads
    /// as zero, so "1.0" equals "1.0.0". The feed's builds are plain integers
    /// (78, 79, 80), for which this agrees with Sparkle's own comparator.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(of: lhs)
        let right = components(of: rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : .number(0)
            let r = index < right.count ? right[index] : .number(0)
            switch (l, r) {
            case let (.number(a), .number(b)):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            case let (.text(a), .text(b)):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            case (.number, .text):
                // "1.0" outranks "1.0b": a bare number is the release, text a pre-release.
                return .orderedDescending
            case (.text, .number):
                return .orderedAscending
            }
        }
        return .orderedSame
    }

    private enum Component: Equatable {
        case number(Int)
        case text(String)
    }

    private static func components(of version: String) -> [Component] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "." || $0 == "-" })
            .map { piece in
                if let number = Int(piece) { return .number(number) }
                return .text(String(piece))
            }
    }

    // MARK: - Parsing

    private final class FeedDelegate: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var current: Item?
        private var text = ""
        /// `sparkle:version` on the enclosure is the older spelling; the element wins when both appear.
        private var sawVersionElement = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            switch elementName {
            case "item":
                current = Item(version: "")
                sawVersionElement = false
            case "enclosure":
                guard current != nil else { return }
                if !sawVersionElement, let version = attributes["sparkle:version"] {
                    current?.version = version
                }
                if current?.displayVersion == nil, let display = attributes["sparkle:shortVersionString"] {
                    current?.displayVersion = display
                }
                if let os = attributes["sparkle:os"] {
                    current?.os = os
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            guard current != nil else { return }
            switch elementName {
            case "item":
                if let item = current, !item.version.isEmpty {
                    items.append(item)
                }
                current = nil
            case "sparkle:version":
                current?.version = value
                sawVersionElement = true
            case "sparkle:shortVersionString":
                current?.displayVersion = value
            case "sparkle:minimumSystemVersion":
                current?.minimumSystemVersion = value
            case "sparkle:maximumSystemVersion":
                current?.maximumSystemVersion = value
            case "sparkle:channel":
                current?.channel = value
            default:
                break
            }
        }
    }
}
