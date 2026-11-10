import Foundation
import SwiftUI
import WebKit

/// Where a walkthrough step's saved animation (`WalkthroughAnimationReference`)
/// is shown from on the phone.
///
/// A saved animation is an Artifact whose address is the library's own
/// `foreverlm-site://<id>/`: its files travel inside the record's CloudKit
/// body package (its `body` satellite), which the phone
/// fetches and unpacks here, then serves from Caches through
/// `MobileLocalSiteSchemeHandler`. The page gets the kit's walk parameters
/// (`?embed=1&step=N&c=…`), so it shows its stage alone at the step and holds
/// the last frame.
actor MobileAnimationSiteStore {
    static let shared = MobileAnimationSiteStore()

    enum Page: Equatable {
        case local(URL)
    }

    enum PageError: LocalizedError {
        case noAddress
        case noFiles

        var errorDescription: String? {
            switch self {
            case .noAddress: return "This animation has no page to show yet."
            case .noFiles: return "This animation's files have not reached iCloud yet."
            }
        }
    }

    /// Unpacked sites, one folder a record. Caches, since every byte of it
    /// can be fetched again from the record.
    nonisolated static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnimationSites", isDirectory: true)
    }

    nonisolated static func siteDirectory(artifactID: String) -> URL {
        root.appendingPathComponent(artifactID.lowercased(), isDirectory: true)
    }

    private static let revisionFile = ".revision"

    /// The page for a step's reference: the record fetched, its files
    /// unpacked when this phone does not hold its current revision.
    func page(for reference: WalkthroughAnimationReference) async throws -> Page {
        let address = try await siteAddress(animationID: reference.animationID)
        return .local(reference.pageURL(animationURL: address))
    }

    /// The animation's own page, its player and controls, with no walk
    /// parameters: what a Memory card plays.
    func page(forAnimationID animationID: String) async throws -> Page {
        .local(try await siteAddress(animationID: animationID))
    }

    /// The animation's address, once its record is fetched and its files
    /// unpacked here when this phone does not hold its current revision.
    private func siteAddress(animationID: String) async throws -> URL {
        // The Artifact as the phone holds it, its package the `body` satellite, fetched by name
        // (docs/cloudkit-schema-design.md §3.5.15).
        guard let satellites = await MobileSatellites.current(),
              let body = try await satellites.artifactBody(animationID) else { throw PageError.noAddress }
        let localID = body.linkedURL.flatMap(URL.init(string:)).flatMap(LocalSiteServing.siteID(from:))
        if localID != nil || (body.linkedURL == nil && body.package != nil) {
            try unpackIfNeeded(artifactID: animationID, revision: body.bodyRevision, package: body.package)
            return URL(string: "\(LocalSiteServing.scheme)://\(animationID.lowercased())/")!
        }
        throw PageError.noAddress
    }

    private func unpackIfNeeded(artifactID: String, revision: String?, package: Data?) throws {
        let directory = Self.siteDirectory(artifactID: artifactID)
        let marker = directory.appendingPathComponent(Self.revisionFile)
        if let revision,
           let held = try? String(contentsOf: marker, encoding: .utf8),
           held == revision {
            return
        }
        guard let package else {
            // No package in the record: keep whatever this phone unpacked
            // before, if anything.
            if FileManager.default.fileExists(atPath: directory.path) { return }
            throw PageError.noFiles
        }
        let decoded = try ArtifactBodyPackage.decode(package, expectedRevision: revision)
        guard let files = decoded.siteFiles, !files.isEmpty else { throw PageError.noFiles }
        let fileManager = FileManager.default
        let staging = Self.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in files {
                guard let path = SiteFilePath.normalize(file.path) else { continue }
                let target = staging.appendingPathComponent(path)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: target, options: .atomic)
            }
            try Data(decoded.revision.utf8).write(to: staging.appendingPathComponent(Self.revisionFile), options: .atomic)
            if fileManager.fileExists(atPath: directory.path) {
                _ = try fileManager.replaceItemAt(directory, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: directory)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}

/// Serves `foreverlm-site://<id>/…` from the sites the phone unpacked, with
/// the Mac's rule and sandbox policy (`LocalSiteServing`). Files are read off
/// the main thread.
final class MobileLocalSiteSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = MobileLocalSiteSchemeHandler()
    /// Serves an animation on a Memory card under
    /// `LocalSiteServing.cardContentSecurityPolicy`, which refuses the network.
    static let cardPlayer = MobileLocalSiteSchemeHandler(contentSecurityPolicy: LocalSiteServing.cardContentSecurityPolicy)

    static func install(on configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(shared, forURLScheme: LocalSiteServing.scheme)
    }

    static func installCardPlayer(on configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(cardPlayer, forURLScheme: LocalSiteServing.scheme)
    }

    private let policy: String

    override convenience init() {
        self.init(contentSecurityPolicy: LocalSiteServing.contentSecurityPolicy)
    }

    private init(contentSecurityPolicy: String) {
        policy = contentSecurityPolicy
        super.init()
    }

    private let queue = DispatchQueue(label: "com.foreverlm.mobile-local-site", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var stoppedTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        let key = ObjectIdentifier(urlSchemeTask)
        let policy = policy
        queue.async { [weak self] in
            let answer = LocalSiteServing.answer(
                for: request,
                missingPage: "This animation has no such page on this phone yet.",
                contentSecurityPolicy: policy
            ) { MobileAnimationSiteStore.siteDirectory(artifactID: $0) }
            DispatchQueue.main.async {
                guard let self, !self.consumeStopped(key) else { return }
                urlSchemeTask.didReceive(answer.response)
                urlSchemeTask.didReceive(answer.body)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    private func consumeStopped(_ key: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedTasks.remove(key) != nil
    }
}

/// A step's saved animation in its card: fetched, then shown at the step
/// the reference pins. A failure says why instead of drawing nothing.
struct MobileWalkthroughReferencedAnimation: View {
    let reference: WalkthroughAnimationReference

    private enum LoadState {
        case loading
        case loaded(MobileAnimationSiteStore.Page)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let page):
                MobileAnimationPageWebView(page: page)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .textSelection(.disabled)
            }
        }
        .task(id: reference) {
            state = .loading
            do {
                state = .loaded(try await MobileAnimationSiteStore.shared.page(for: reference))
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// The animation's page in a store of its own. Navigation stays on the
/// animation — its own scheme and host — and links out, forms to elsewhere
/// and popups go nowhere, as on the Mac.
private struct MobileAnimationPageWebView: UIViewRepresentable {
    let page: MobileAnimationSiteStore.Page
    /// A Memory card's player: the card player's policy (no network), and the
    /// page scrolls inside its frame, where a walk's stage does not.
    var isCardPlayer = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = true
        if isCardPlayer {
            MobileLocalSiteSchemeHandler.installCardPlayer(on: configuration)
        } else {
            MobileLocalSiteSchemeHandler.install(on: configuration)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = isCardPlayer
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        load(into: webView, coordinator: context.coordinator)
    }

    private func load(into webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.loaded != page else { return }
        coordinator.loaded = page
        switch page {
        case .local(let url):
            coordinator.home = url
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded: MobileAnimationSiteStore.Page?
        var home: URL?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, let home else {
                decisionHandler(.cancel)
                return
            }
            let sameSite = url.scheme?.lowercased() == home.scheme?.lowercased()
                && url.host?.lowercased() == home.host?.lowercased()
            decisionHandler(sameSite || url.absoluteString == "about:blank" ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}

/// A Memory card's animation on the phone: the animation's record fetched when
/// the face is on screen (a card holds no web view for a face nobody is
/// looking at), then played from its own page in the card player's web view,
/// with the page's controls. A failure says why instead of drawing nothing.
struct MobileCardAnimationView: View {
    let image: MemoryCardImage

    private enum LoadState {
        case loading
        case loaded(MobileAnimationSiteStore.Page)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 90)
            case .loaded(let page):
                MobileAnimationPageWebView(page: page, isCardPlayer: true)
                    .frame(height: 340)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .textSelection(.disabled)
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(image.alt)
        .accessibilityIdentifier("memory.cards.animation")
        .task(id: image.target) {
            guard let animationID = image.animationID else {
                state = .failed("This animation's address is not one this phone can play.")
                return
            }
            state = .loading
            do {
                state = .loaded(try await MobileAnimationSiteStore.shared.page(forAnimationID: animationID))
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
