import Foundation
import SwiftUI
import WebKit

/// Where a walkthrough step's saved animation (`WalkthroughAnimationReference`)
/// is shown from on the phone.
///
/// A saved animation is an Artifact whose address is either the library's
/// own `foreverlm-site://<id>/` — its files travel inside the record's
/// CloudKit body package (under generation 2, its `body` satellite), which
/// the phone fetches and unpacks here, then
/// serves from Caches through `MobileLocalSiteSchemeHandler` — or, for a
/// record not yet brought home, its hosted page at sites.foreverlm.com, which
/// is loaded with the account's session as the Mac loads it. Either way the
/// page gets the kit's walk parameters (`?embed=1&step=N&c=…`), so it shows
/// its stage alone at the step and holds the last frame.
actor MobileAnimationSiteStore {
    static let shared = MobileAnimationSiteStore()

    enum Page: Equatable {
        case local(URL)
        case hosted(URLRequest)
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
        // The Artifact as the phone holds it, its package the `body` satellite, fetched by name
        // (docs/cloudkit-schema-design.md §3.5.15).
        guard let satellites = await MobileSatellites.current(),
              let body = try await satellites.artifactBody(reference.animationID) else { throw PageError.noAddress }
        let localID = body.linkedURL.flatMap(URL.init(string:)).flatMap(LocalSiteServing.siteID(from:))
        if localID != nil || (body.linkedURL == nil && body.package != nil) {
            try unpackIfNeeded(artifactID: reference.animationID, revision: body.bodyRevision, package: body.package)
            let address = URL(string: "\(LocalSiteServing.scheme)://\(reference.animationID.lowercased())/")!
            return .local(reference.pageURL(animationURL: address))
        }
        guard let linked = body.linkedURL, let url = URL(string: linked), url.scheme?.lowercased() == "https" else {
            throw PageError.noAddress
        }
        var request = URLRequest(url: reference.pageURL(animationURL: url))
        // The sites host reads the account from the managed session, as the
        // Mac's LinkedDocWebView does; no other host gets it.
        if url.host?.lowercased() == "sites.foreverlm.com", let token = ManagedAI.requestSessionToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return .hosted(request)
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

    static func install(on configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(shared, forURLScheme: LocalSiteServing.scheme)
    }

    private let queue = DispatchQueue(label: "com.foreverlm.mobile-local-site", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var stoppedTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        let key = ObjectIdentifier(urlSchemeTask)
        queue.async { [weak self] in
            let answer = LocalSiteServing.answer(
                for: request,
                missingPage: "This animation has no such page on this phone yet."
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = true
        MobileLocalSiteSchemeHandler.install(on: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
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
        case .hosted(let request):
            coordinator.home = request.url
            webView.load(request)
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
