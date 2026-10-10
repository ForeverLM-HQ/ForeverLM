import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share extension's principal class (`NSExtensionPrincipalClass`): hosts
/// the share sheet (`MobileShareSheetView`) and ends the request when it is
/// done. Add queues what was shared in the app group's inbox
/// (`MobileShareInbox`), filed into the notebook chosen; the app captures it
/// the next time it is active (`MobileAudioReviewViewModel.importPendingSharedSources`).
final class MobileShareViewController: UIViewController {
    private var model: MobileShareSheetModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = MobileShareSheetModel(inputItems: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        model.onFinish = { [weak self] outcome in
            switch outcome {
            case .added:
                self?.extensionContext?.completeRequest(returningItems: nil)
            case .cancelled:
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }
        self.model = model

        let host = UIHostingController(rootView: MobileShareSheetView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

/// The share sheet's state: what was shared, read from the extension's items
/// (no fetch), the notebooks the app last listed with the one last shared
/// into chosen, and Add. Opening it writes nothing; Add writes the queued
/// items and the choice the next share opens on.
@MainActor
final class MobileShareSheetModel: ObservableObject {
    enum Outcome {
        case added
        case cancelled
    }

    /// One thing shared, as the sheet shows it and Add queues it.
    struct Item: Identifiable {
        enum Content {
            case link(URL)
            /// A PDF, copied into the app group only when Add queues it.
            case file(NSItemProvider, typeIdentifier: String)
        }

        let id = UUID()
        let content: Content
        /// The title the sending app gave it; nil when it gave none.
        let title: String?
        /// The site a link is from, or the kind of file.
        let detail: String?

        /// The row's first line: the title, else the address or the kind.
        var headline: String {
            if let title { return title }
            switch content {
            case .link(let url): return Self.shortAddress(url)
            case .file: return detail ?? "PDF"
            }
        }

        /// The row's second line, when the first does not already say it.
        var subheadline: String? {
            title == nil ? nil : detail
        }

        private static func shortAddress(_ url: URL) -> String {
            let site = MobileSharePreview.site(of: url) ?? ""
            let path = url.path == "/" ? "" : url.path
            return site + path
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var notebooks: [MobileShareNotebook] = []
    @Published private(set) var isReading = true
    @Published private(set) var isAdding = false
    @Published var notebookID: String?
    @Published var errorMessage: String?
    var onFinish: ((Outcome) -> Void)?

    private let inputItems: [NSExtensionItem]
    /// Items already queued, so Add after a failure does not queue them twice.
    private var queuedItemIDs: Set<UUID> = []

    init(inputItems: [NSExtensionItem]) {
        self.inputItems = inputItems
    }

    var canAdd: Bool {
        !isReading && !isAdding && !items.isEmpty
    }

    func read() async {
        guard isReading else { return }
        async let listed = Self.readNotebooks()
        let resolved = await Self.resolve(inputItems)
        let (notebooks, preselected) = await listed
        self.notebooks = notebooks
        notebookID = preselected
        items = resolved
        isReading = false
    }

    func cancel() {
        onFinish?(.cancelled)
    }

    func add() {
        guard canAdd else { return }
        isAdding = true
        let notebookID = notebooks.contains { $0.id == self.notebookID } ? self.notebookID : nil
        Task {
            do {
                for item in items where !queuedItemIDs.contains(item.id) {
                    try await Self.queue(item, notebookID: notebookID)
                    queuedItemIDs.insert(item.id)
                }
                await Task.detached(priority: .userInitiated) {
                    MobileShareNotebookStore.shared?.rememberLastUsed(notebookID)
                }.value
                onFinish?(.added)
            } catch {
                isAdding = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Reading what was shared

    /// The notebooks the app last listed and the choice the sheet opens on,
    /// read off the main actor.
    private nonisolated static func readNotebooks() async -> ([MobileShareNotebook], String?) {
        await Task.detached(priority: .userInitiated) {
            guard let store = MobileShareNotebookStore.shared else { return ([], nil) }
            let notebooks = store.notebooks
            return (notebooks, MobileShareNotebookList.preselected(lastUsed: store.lastUsedNotebookID, in: notebooks))
        }.value
    }

    /// Each shared web address once, and the PDFs of an item that names no web
    /// address: a page shared from a browser often carries its document too,
    /// which would otherwise arrive as a second source.
    private static func resolve(_ inputItems: [NSExtensionItem]) async -> [Item] {
        var items: [Item] = []
        var addresses = Set<String>()
        for inputItem in inputItems {
            let providers = inputItem.attachments ?? []
            let given = MobileSharePreview.title(
                itemTitle: inputItem.attributedTitle?.string,
                contentText: inputItem.attributedContentText?.string
            )
            var links: [Item] = []
            for provider in providers {
                guard let url = await webAddress(from: provider),
                      addresses.insert(url.absoluteString).inserted else { continue }
                links.append(Item(
                    content: .link(url),
                    title: given ?? MobileSharePreview.title(itemTitle: provider.suggestedName, contentText: nil),
                    detail: MobileSharePreview.site(of: url)
                ))
            }
            if !links.isEmpty {
                items.append(contentsOf: links)
                continue
            }
            for provider in providers {
                guard let type = pdfType(of: provider) else { continue }
                items.append(Item(
                    content: .file(provider, typeIdentifier: type),
                    title: MobileSharePreview.title(itemTitle: provider.suggestedName, contentText: nil) ?? given,
                    detail: UTType(type)?.localizedDescription
                ))
            }
        }
        return items
    }

    private static func webAddress(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await loadURL(from: provider),
           MobileSharePreview.isWebAddress(url) {
            return url
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await loadText(from: provider) {
            return MobileSharePreview.webAddress(in: text)
        }
        return nil
    }

    /// The phone imports PDFs only (`MobileCloudMutationService.captureFile`).
    private static func pdfType(of provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .pdf) == true }
    }

    private static func loadURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { value, error in
                if let error { continuation.resume(throwing: error); return }
                if let url = value as? URL { continuation.resume(returning: url); return }
                if let url = value as? NSURL { continuation.resume(returning: url as URL); return }
                if let text = value as? String { continuation.resume(returning: URL(string: text)); return }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func loadText(from provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { value, error in
                if let error { continuation.resume(throwing: error); return }
                if let text = value as? String { continuation.resume(returning: text); return }
                if let text = value as? NSAttributedString { continuation.resume(returning: text.string); return }
                if let data = value as? Data { continuation.resume(returning: String(data: data, encoding: .utf8)); return }
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Queueing

    private static func queue(_ item: Item, notebookID: String?) async throws {
        switch item.content {
        case .link(let url):
            try await MobileShareInbox.shared.enqueueURL(url, title: item.title, notebookID: notebookID)
        case .file(let provider, let typeIdentifier):
            let path = try await stashFile(from: provider, typeIdentifier: typeIdentifier)
            try await MobileShareInbox.shared.enqueueStashedFile(path: path, title: item.title, notebookID: notebookID)
        }
    }

    /// Copies the file while the provider's temporary URL is still valid.
    private static func stashFile(from provider: NSItemProvider, typeIdentifier: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, error in
                if let error { continuation.resume(throwing: error); return }
                guard let temporaryURL else {
                    continuation.resume(throwing: MobileShareExtensionError.unsupportedAttachment)
                    return
                }
                do {
                    continuation.resume(returning: try MobileShareInbox.stashFile(from: temporaryURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum MobileShareExtensionError: LocalizedError {
    case unsupportedAttachment

    var errorDescription: String? {
        switch self {
        case .unsupportedAttachment: return "ForeverLM could not read this shared item."
        }
    }
}
