import Foundation
import Testing
@testable import ForeverLM

/// The app reads its own appcast to learn whether a build Sparkle resumed is
/// still the newest. These pin what "newest for this Mac" means against the
/// feed shape `generate_appcast` writes for releases.foreverlm.com.
@Suite("Appcast Feed")
struct AppcastFeedTests {

    /// Three real releases, newest first, as the live feed carried them on 2026-09-08.
    static let liveFeed = """
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
        <channel>
            <title>ForeverLM</title>
            <item>
                <title>0.31.0</title>
                <pubDate>Tue, 08 Sep 2026 16:04:09 -0700</pubDate>
                <sparkle:version>80</sparkle:version>
                <sparkle:shortVersionString>0.31.0</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                <enclosure url="https://releases.foreverlm.com/ForeverLM-0.31.0-build80-universal.dmg" length="38162781" type="application/octet-stream" sparkle:edSignature="G4C8"/>
            </item>
            <item>
                <title>0.30.0</title>
                <sparkle:version>79</sparkle:version>
                <sparkle:shortVersionString>0.30.0</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                <enclosure url="https://releases.foreverlm.com/ForeverLM-0.30.0-build79-universal.dmg" length="38165016" type="application/octet-stream" sparkle:edSignature="L5Rw"/>
            </item>
            <item>
                <title>0.29.0</title>
                <sparkle:version>78</sparkle:version>
                <sparkle:shortVersionString>0.29.0</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                <enclosure url="https://releases.foreverlm.com/ForeverLM-0.29.0-build78-universal.dmg" length="38113255" type="application/octet-stream" sparkle:edSignature="Alyq"/>
            </item>
        </channel>
    </rss>
    """

    static func feed(items: String) -> Data {
        Data("""
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel><title>ForeverLM</title>\(items)</channel>
        </rss>
        """.utf8)
    }

    @Test("Every item is read with its build, marketing version and OS floor")
    func readsLiveFeed() {
        let items = AppcastFeed.items(in: Data(Self.liveFeed.utf8))
        #expect(items.map(\.version) == ["80", "79", "78"])
        #expect(items.map(\.displayVersion) == ["0.31.0", "0.30.0", "0.29.0"])
        #expect(items.allSatisfy { $0.minimumSystemVersion == "14.0" })
        #expect(items.allSatisfy { $0.channel == nil && $0.os == nil })
    }

    @Test("The newest installable build is the highest build number, whatever the document order")
    func newestIsHighestBuild() {
        #expect(AppcastFeed.newestInstallableVersion(in: Data(Self.liveFeed.utf8), systemVersion: "27.0.0", allowedChannels: []) == "80")

        let reordered = Self.feed(items: """
            <item><sparkle:version>78</sparkle:version><enclosure url="a.dmg"/></item>
            <item><sparkle:version>81</sparkle:version><enclosure url="b.dmg"/></item>
            <item><sparkle:version>80</sparkle:version><enclosure url="c.dmg"/></item>
            """)
        #expect(AppcastFeed.newestInstallableVersion(in: reordered, systemVersion: "27.0.0", allowedChannels: []) == "81")
    }

    @Test("A build this Mac cannot run does not count as newer")
    func systemBoundsFilter() {
        let data = Self.feed(items: """
            <item><sparkle:version>82</sparkle:version><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion><enclosure url="a.dmg"/></item>
            <item><sparkle:version>81</sparkle:version><sparkle:maximumSystemVersion>15.9</sparkle:maximumSystemVersion><enclosure url="b.dmg"/></item>
            <item><sparkle:version>80</sparkle:version><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url="c.dmg"/></item>
            """)
        #expect(AppcastFeed.newestInstallableVersion(in: data, systemVersion: "27.0.0", allowedChannels: []) == "80")
        #expect(AppcastFeed.newestInstallableVersion(in: data, systemVersion: "15.5.0", allowedChannels: []) == "81")
        // Below every floor, the one item with no floor is what remains.
        #expect(AppcastFeed.newestInstallableVersion(in: data, systemVersion: "13.6.0", allowedChannels: []) == "81")

        let tooNew = Self.feed(items: """
            <item><sparkle:version>82</sparkle:version><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion><enclosure url="a.dmg"/></item>
            """)
        #expect(AppcastFeed.newestInstallableVersion(in: tooNew, systemVersion: "27.0.0", allowedChannels: []) == nil)
    }

    @Test("Channel and non-macOS items are left to Sparkle's own rules, which exclude them")
    func channelAndPlatformFilter() {
        let data = Self.feed(items: """
            <item><sparkle:version>90</sparkle:version><sparkle:channel>beta</sparkle:channel><enclosure url="a.dmg"/></item>
            <item><sparkle:version>85</sparkle:version><enclosure url="b.zip" sparkle:os="windows"/></item>
            <item><sparkle:version>80</sparkle:version><enclosure url="c.dmg" sparkle:os="macos"/></item>
            """)
        #expect(AppcastFeed.newestInstallableVersion(in: data, systemVersion: "27.0.0", allowedChannels: []) == "80")
    }

    @Test("A Mac signed up for beta releases sees the newest of the beta and default channels, and no other channel")
    func betaChannelForSignedUpMacs() {
        let betaAhead = Self.feed(items: """
            <item><sparkle:version>191</sparkle:version><sparkle:channel>nightly</sparkle:channel><enclosure url="n.dmg"/></item>
            <item><sparkle:version>190</sparkle:version><sparkle:channel>beta</sparkle:channel><enclosure url="b.dmg"/></item>
            <item><sparkle:version>188</sparkle:version><enclosure url="p.dmg"/></item>
            """)
        let signedUp = BetaReleases.allowedChannels(signedUp: true)
        #expect(signedUp == ["beta"])
        #expect(BetaReleases.allowedChannels(signedUp: false).isEmpty)
        #expect(AppcastFeed.newestInstallableVersion(in: betaAhead, systemVersion: "27.0.0", allowedChannels: signedUp) == "190")
        #expect(AppcastFeed.newestInstallableVersion(in: betaAhead, systemVersion: "27.0.0", allowedChannels: []) == "188")

        // A production release cut after the betas is newer than all of them,
        // and reaches signed-up Macs through the default channel.
        let productionAhead = Self.feed(items: """
            <item><sparkle:version>192</sparkle:version><enclosure url="p2.dmg"/></item>
            <item><sparkle:version>190</sparkle:version><sparkle:channel>beta</sparkle:channel><enclosure url="b.dmg"/></item>
            """)
        #expect(AppcastFeed.newestInstallableVersion(in: productionAhead, systemVersion: "27.0.0", allowedChannels: signedUp) == "192")
    }

    @Test("The older enclosure-attribute spelling of the build is read, and the element wins over it")
    func enclosureAttributeFallback() {
        let data = Self.feed(items: """
            <item><enclosure url="a.dmg" sparkle:version="77" sparkle:shortVersionString="0.28.0"/></item>
            <item><sparkle:version>80</sparkle:version><enclosure url="b.dmg" sparkle:version="12"/></item>
            """)
        let items = AppcastFeed.items(in: data)
        #expect(items.map(\.version) == ["77", "80"])
        #expect(items.first?.displayVersion == "0.28.0")
    }

    @Test("The feed is tried at SUFeedURL first, then at the fallback, each once")
    func feedAddressesInOrder() {
        let primary = "https://releases.foreverlm.com/appcast.xml"
        let fallback = "https://foreverlm.com/releases/appcast.xml"
        #expect(AppcastFeed.feedURLs(info: ["SUFeedURL": primary, AppcastFeed.fallbackFeedInfoKey: fallback]).map(\.absoluteString) == [primary, fallback])
        #expect(AppcastFeed.feedURLs(info: ["SUFeedURL": primary]).map(\.absoluteString) == [primary])
        #expect(AppcastFeed.feedURLs(info: ["SUFeedURL": primary, AppcastFeed.fallbackFeedInfoKey: primary]).count == 1)
        #expect(AppcastFeed.feedURLs(info: nil).isEmpty)
    }

    @Test("The app's own Info.plist names a fallback feed on another host")
    func bundledFallbackFeed() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Info.plist")
        let info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let urls = AppcastFeed.feedURLs(info: info)
        #expect(urls.count == 2)
        #expect(urls.first?.host != urls.last?.host)
    }

    @Test("Only a feed that could not be downloaded or parsed moves the check to the fallback")
    func unreadableFeedErrors() {
        #expect(AppcastFeed.isUnreadableFeed(NSError(domain: "SUSparkleErrorDomain", code: 1002)))
        #expect(AppcastFeed.isUnreadableFeed(NSError(domain: "SUSparkleErrorDomain", code: 1000)))
        // No update, a failed archive download, or a network error Sparkle did not wrap: not the feed's address.
        #expect(!AppcastFeed.isUnreadableFeed(NSError(domain: "SUSparkleErrorDomain", code: 1001)))
        #expect(!AppcastFeed.isUnreadableFeed(NSError(domain: "SUSparkleErrorDomain", code: 2001)))
        #expect(!AppcastFeed.isUnreadableFeed(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
    }

    @Test("A feed that is not RSS, or is empty, offers nothing rather than throwing")
    func unreadableFeeds() {
        #expect(AppcastFeed.newestInstallableVersion(in: Data(), systemVersion: "27.0.0", allowedChannels: []) == nil)
        #expect(AppcastFeed.newestInstallableVersion(in: Data("<html><body>503</body></html>".utf8), systemVersion: "27.0.0", allowedChannels: []) == nil)
        #expect(AppcastFeed.newestInstallableVersion(in: Data("not xml at all".utf8), systemVersion: "27.0.0", allowedChannels: []) == nil)
        // An item without a build is not an item.
        let versionless = Self.feed(items: "<item><title>0.31.0</title><enclosure url=\"a.dmg\"/></item>")
        #expect(AppcastFeed.items(in: versionless).isEmpty)
    }

    @Test("A download cut short still yields the items that were read")
    func truncatedFeedKeepsParsedItems() {
        let whole = Self.liveFeed
        let cut = String(whole.prefix(whole.range(of: "<title>0.29.0</title>")!.lowerBound.utf16Offset(in: whole)))
        let items = AppcastFeed.items(in: Data(cut.utf8))
        #expect(items.map(\.version) == ["80", "79"])
    }

    @Test("Version comparison is numeric per component, so build 100 outranks build 99")
    func versionComparison() {
        #expect(AppcastFeed.isVersion("80", newerThan: "79"))
        #expect(AppcastFeed.isVersion("100", newerThan: "99"))
        #expect(!AppcastFeed.isVersion("79", newerThan: "80"))
        #expect(!AppcastFeed.isVersion("80", newerThan: "80"))
        #expect(AppcastFeed.isVersion("0.31.0", newerThan: "0.30.0"))
        #expect(AppcastFeed.isVersion("2", newerThan: "1.9.9"))
        #expect(AppcastFeed.compare("1.0", "1.0.0") == .orderedSame)
        #expect(AppcastFeed.compare("27.0.0", "14.0") == .orderedDescending)
        #expect(AppcastFeed.compare("1.0", "1.0b") == .orderedDescending)
    }

    /// Another account on this Mac updated /Applications/ForeverLM.app while
    /// this copy kept running: the build on disk is the one to relaunch into,
    /// and nothing should be downloaded or installed.
    @Test func installedCopyNewerThanRunningBuildAsksForRelaunch() {
        let installed: [String: Any] = ["CFBundleVersion": "134", "CFBundleShortVersionString": "0.77.0"]
        #expect(InstalledAppCopy.newerBuild(installedInfo: installed, runningBuild: "133")
            == InstalledAppCopy.Build(build: "134", displayVersion: "0.77.0"))
        // Numeric, not lexical: build 100 is newer than build 99.
        #expect(InstalledAppCopy.newerBuild(installedInfo: ["CFBundleVersion": "100"], runningBuild: "99")?.build == "100")
    }

    @Test func installedCopySameOrOlderThanRunningBuildLeavesSparkleAlone() {
        #expect(InstalledAppCopy.newerBuild(installedInfo: ["CFBundleVersion": "134"], runningBuild: "134") == nil)
        #expect(InstalledAppCopy.newerBuild(installedInfo: ["CFBundleVersion": "133"], runningBuild: "134") == nil)
        #expect(InstalledAppCopy.newerBuild(installedInfo: nil, runningBuild: "134") == nil)
        #expect(InstalledAppCopy.newerBuild(installedInfo: ["CFBundleVersion": "134"], runningBuild: nil) == nil)
    }

    /// The installer is found by the app it carries, not by its volume name, and
    /// only a mounted image counts.
    @Test func installerImageIsTheMountedImageCarryingThisApp() {
        let info: [String: Any] = ["images": [
            ["image-path": "/Users/zara/Downloads/ForeverLM-1.dmg",
             "system-entities": [["dev-entry": "/dev/disk4"], ["mount-point": "/Volumes/ForeverLM Installer"]]],
            ["image-path": "/Users/zara/Downloads/Other.dmg",
             "system-entities": [["mount-point": "/Volumes/Other"]]],
            ["image-path": "/Users/zara/Downloads/Unmounted.dmg",
             "system-entities": [["dev-entry": "/dev/disk5"]]],
        ]]
        let found = InstallerImage.carryingThisApp(
            hdiutilInfo: info,
            appFileName: "ForeverLM.app",
            bundleIdentifier: "com.foreverlm",
            bundleIdentifierAt: { path in
                path == "/Volumes/ForeverLM Installer/ForeverLM.app" ? "com.foreverlm" : nil
            }
        )
        #expect(found == [InstallerImage.Mounted(
            imagePath: "/Users/zara/Downloads/ForeverLM-1.dmg",
            mountPoint: "/Volumes/ForeverLM Installer"
        )])
        #expect(InstallerImage.carryingThisApp(
            hdiutilInfo: nil, appFileName: "ForeverLM.app", bundleIdentifier: "com.foreverlm",
            bundleIdentifierAt: { _ in "com.foreverlm" }
        ).isEmpty)
    }

    @Test func installerIsOfferedOnlyToAnInstalledCopy() {
        #expect(InstallerImage.isInstalled(bundleURL: URL(fileURLWithPath: "/Applications/ForeverLM.app")))
        #expect(!InstallerImage.isInstalled(bundleURL: URL(fileURLWithPath: "/Volumes/ForeverLM Installer/ForeverLM.app")))
        #expect(!InstallerImage.isInstalled(bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/ForeverLM.app")))
    }

    @Test("A build is a beta while the feed lists it only in its own channel")
    func runningBuildIsBeta() {
        let feed = Self.feed(items: """
            <item><sparkle:version>191</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
            <item><sparkle:version>190</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
            <item><sparkle:version>190</sparkle:version></item>
            <item><sparkle:version>189</sparkle:version></item>
        """)
        #expect(AppcastFeed.isBeta(build: "191", in: feed) == true)
        #expect(AppcastFeed.isBeta(build: "190", in: feed) == false, "a promoted build is listed in the default channel too")
        #expect(AppcastFeed.isBeta(build: "189", in: feed) == false)
        #expect(AppcastFeed.isBeta(build: "185", in: feed) == nil, "a build the feed does not list says nothing")
    }

    @Test("The kept answer belongs to one build only")
    func runningBuildAnswerIsPerBuild() {
        let stored = RunningBuildChannel.storedValue(isBeta: true, build: "191")
        #expect(RunningBuildChannel.isBeta(stored: stored, build: "191"))
        #expect(!RunningBuildChannel.isBeta(stored: stored, build: "192"), "an update never shows the last build's answer")
        #expect(!RunningBuildChannel.isBeta(stored: RunningBuildChannel.storedValue(isBeta: false, build: "191"), build: "191"))
        #expect(!RunningBuildChannel.isBeta(stored: nil, build: "191"))
        #expect(!RunningBuildChannel.isBeta(stored: stored, build: ""))
    }
}
