// Drop handling for the notebook source pool: sources, PDFs as papers, and the pool drop delegate.
import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum NotebookSourceDropHandler {
    /// A drop on a Notebook: sources join its pool, and a course group links
    /// the course so future lectures follow.
    @MainActor
    static func handle(providers: [NSItemProvider], vm: StudioViewModel, notebookID: String? = nil) -> Bool {
        resolve(
            providers: providers,
            vm: vm,
            linkCourse: { courseID, sourceIDs in
                await vm.linkCourseToNotebookContext(courseID: courseID, sourceIDs: sourceIDs, notebookID: notebookID)
            },
            add: { sourceIDs in
                await vm.addSourcesToNotebookContext(sourceIDs, notebookID: notebookID)
            }
        )
    }

    /// A drop on a Goal's row: the same payloads, put on the Goal's pool. A
    /// course group is its sources today and nothing more — a Goal is
    /// timebound, so it does not subscribe to lectures that are not out yet.
    @MainActor
    static func handle(providers: [NSItemProvider], vm: StudioViewModel, goalID: String) -> Bool {
        resolve(
            providers: providers,
            vm: vm,
            linkCourse: { _, sourceIDs in
                await vm.addSourcesToGoal(goalID: goalID, sourceIDs: sourceIDs)
            },
            add: { sourceIDs in
                await vm.addSourcesToGoal(goalID: goalID, sourceIDs: sourceIDs)
            }
        )
    }

    /// A drop on an Idea's row: the same payloads, linked to the Idea as the
    /// research it draws on. A course group is its sources today, like a Goal.
    @MainActor
    static func handle(providers: [NSItemProvider], vm: StudioViewModel, ideaID: String) -> Bool {
        resolve(
            providers: providers,
            vm: vm,
            linkCourse: { _, sourceIDs in
                await vm.linkIdea(ideaID: ideaID, kind: .source, targetIDs: sourceIDs)
            },
            add: { sourceIDs in
                await vm.linkIdea(ideaID: ideaID, kind: .source, targetIDs: sourceIDs)
            }
        )
    }

    /// Reads every source payload an in-app drag can carry — a group, a
    /// Schedule item, a multi-selection of rows, a bare source id — and hands
    /// the resolved ids to `add`, or a course group to `linkCourse`. Returns
    /// whether any provider was one of ours; the loads finish asynchronously.
    @MainActor
    private static func resolve(
        providers: [NSItemProvider],
        vm: StudioViewModel,
        linkCourse: @escaping @MainActor (_ courseID: String, _ sourceIDs: [String]) async -> Void,
        add: @escaping @MainActor (_ sourceIDs: [String]) async -> Void
    ) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.studioGroup.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioGroup.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioGroupTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        let sourceIDs = transfer.sourceIDs.flatMap { $0.isEmpty ? nil : $0 }
                            ?? vm.sourceIDsForGroupInOrder(transfer.groupName)
                        if vm.allCourseGroupNames.contains(transfer.groupName) {
                            await linkCourse(transfer.groupName, sourceIDs)
                        } else {
                            await add(sourceIDs)
                        }
                    }
                }
                handled = true
                continue
            }

            // A source row registers both representations on one provider. The
            // article transfer is the one that can carry a multi-selection, so
            // it is read first; the bare id is only for providers that have
            // nothing else.
            if provider.hasItemConformingToTypeIdentifier(UTType.studioArticle.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioArticle.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioArticleTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        // The payload is the snapshot of what the learner picked
                        // up; the live selection may have moved on by the drop.
                        await add(transfer.draggedSourceIDs)
                    }
                }
                handled = true
                continue
            }

            guard provider.hasItemConformingToTypeIdentifier(UTType.studioSourceID.identifier) else { continue }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.studioSourceID.identifier) { data, _ in
                guard let data,
                      let sourceID = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sourceID.isEmpty else { return }
                Task { @MainActor in
                    await add([sourceID])
                }
            }
            handled = true
        }
        return handled
    }
}

// MARK: - PDFs dropped as papers

/// Reading the PDFs a drop carries, for the two places a PDF dropped from
/// Finder or a browser becomes a paper: the Sources list's Papers tab and a
/// notebook's Sources column. Each hands what it reads to the library's one
/// PDF import (`StudioViewModel.importPDF(from:)`); this only gets the files.
enum PaperFileDrop {
    /// What a PDF drop carries: a file, or a PDF's bytes.
    static let types: [UTType] = [.fileURL, .pdf]

    /// The file URL a provider's `.fileURL` item loaded as. Finder hands over
    /// its bookmark data, other apps an `NSURL`, a path or a URL string.
    static func fileURL(fromLoadedItem item: Any?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let value = item as? String {
            let parsed = URL(string: value)
            return parsed?.isFileURL == true ? parsed : URL(fileURLWithPath: value)
        }
        return item as? URL
    }

    /// Whether `url` names a PDF on disk, by its extension, as the Papers
    /// tab has always judged a dropped file.
    static func isPDFFile(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.isFileURL && url.pathExtension.lowercased() == "pdf"
    }

    /// Loads each PDF the drop carries and hands it to `deliver` on the main
    /// actor: a file as it is, a PDF's bytes staged into a temporary file
    /// first (`PaperDropStager`, whose file `deliver` cleans up after the
    /// import). A file that is no PDF, or a load that fails, goes to `fail`
    /// with the name the provider suggested and why. True when the drop
    /// carried anything to try.
    static func load(
        _ providers: [NSItemProvider],
        deliver: @escaping @MainActor (URL, String, PaperDropStager.StagedFile?) -> Void,
        fail: @escaping @MainActor (String?, String) -> Void
    ) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    let suggestedName = provider.suggestedName
                    if let error {
                        let message = error.localizedDescription
                        Task { @MainActor in fail(suggestedName, message) }
                        return
                    }
                    let url = fileURL(fromLoadedItem: item)
                    guard let url, isPDFFile(url) else {
                        Task { @MainActor in fail(suggestedName, "Finder did not provide a readable PDF file URL.") }
                        return
                    }
                    Task { @MainActor in deliver(url, url.lastPathComponent, nil) }
                }
                continue
            }

            guard provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) else { continue }
            handled = true
            provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, error in
                let suggestedName = provider.suggestedName
                if let error {
                    let message = error.localizedDescription
                    Task { @MainActor in fail(suggestedName, message) }
                    return
                }
                guard let data, !data.isEmpty else {
                    Task { @MainActor in fail(suggestedName, "The dropped PDF contained no readable data.") }
                    return
                }
                Task { @MainActor in
                    do {
                        let staged = try await PaperDropStager.stage(data: data, suggestedName: suggestedName)
                        deliver(staged.url, staged.displayName, staged)
                    } catch {
                        fail(suggestedName, error.localizedDescription)
                    }
                }
            }
        }
        return handled
    }
}

/// What a drop on a notebook's Sources column is.
enum NotebookSourcesDrop: Equatable {
    /// The app's own rows — sources, a book, a course — which join the
    /// notebook as they are.
    case sources
    /// PDFs from Finder or a browser, imported as papers and then filed in
    /// the notebook.
    case pdfs
    case none

    /// A drag of the app's own rows is a source drop even when it carries a
    /// PDF file too: a paper's row offers its file to Finder, and must not be
    /// imported a second time. Only files alone import as papers, and only
    /// where the notebook takes new sources.
    static func kind(carriesSources: Bool, carriesFiles: Bool, acceptsPDFs: Bool) -> NotebookSourcesDrop {
        if carriesSources { return .sources }
        if carriesFiles, acceptsPDFs { return .pdfs }
        return .none
    }
}

/// The drop on a Notebook's pool: the app's rows always, and in a notebook's
/// Sources column PDFs from Finder or a browser too, each lighting its own
/// overlay.
struct NotebookPoolDropDelegate: DropDelegate {
    let acceptsPDFs: Bool
    /// Whether the in-app drag under way could add anything here; drawn, but
    /// never what decides a drop (`NotebookSourcePoolView`'s note).
    let canAcceptSourceDrag: Bool
    @Binding var isTargeted: Bool
    @Binding var isPDFTargeted: Bool
    let dropSources: ([NSItemProvider]) -> Bool
    let dropPDFs: ([NSItemProvider]) -> Bool

    private func kind(_ info: DropInfo) -> NotebookSourcesDrop {
        NotebookSourcesDrop.kind(
            carriesSources: info.hasItemsConforming(to: mcpSourceContextDropTypes),
            carriesFiles: info.hasItemsConforming(to: PaperFileDrop.types),
            acceptsPDFs: acceptsPDFs
        )
    }

    func validateDrop(info: DropInfo) -> Bool {
        kind(info) != .none
    }

    func dropEntered(info: DropInfo) {
        switch kind(info) {
        case .sources: isTargeted = canAcceptSourceDrag
        case .pdfs: isPDFTargeted = true
        case .none: break
        }
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        isPDFTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            isTargeted = false
            isPDFTargeted = false
        }
        switch kind(info) {
        case .sources: return dropSources(info.itemProviders(for: mcpSourceContextDropTypes))
        case .pdfs: return dropPDFs(info.itemProviders(for: PaperFileDrop.types))
        case .none: return false
        }
    }
}
