#if os(macOS)
import AppKit
import SwiftUI

/// The in-app folder chooser that follows the one Google sign-in.
///
/// Google's own Picker chooses a folder in the browser, but the token it hands
/// back cannot read what is inside that folder, so connecting through it meant
/// a second consent screen for the permission that can. Choosing here instead,
/// through the read-only access the learner just granted, makes one sign-in
/// enough. It is a sheet on the frontmost ForeverLM window, because the learner
/// arrives from the browser with no particular window in front.
@MainActor
enum GoogleDriveFolderPicker {
    /// The folder the learner chose, or nil when they cancelled.
    static func choose(account: GoogleDriveAccount) async -> GoogleDriveFile? {
        await withCheckedContinuation { continuation in
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 460, height: 420)

            var finished = false
            let finish: (GoogleDriveFile?) -> Void = { folder in
                guard !finished else { return }
                finished = true
                if let parent = panel.sheetParent {
                    parent.endSheet(panel)
                } else {
                    panel.close()
                }
                continuation.resume(returning: folder)
            }
            panel.contentViewController = NSHostingController(
                rootView: GoogleDriveFolderPickerView(account: account, finish: finish)
            )

            NSApp.activate(ignoringOtherApps: true)
            let parent = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
            if let parent {
                parent.beginSheet(panel) { _ in finish(nil) }
            } else {
                panel.center()
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }
}

private struct GoogleDriveFolderPickerView: View {
    let account: GoogleDriveAccount
    let finish: (GoogleDriveFile?) -> Void

    private enum Place: String, CaseIterable, Identifiable {
        case myDrive, sharedWithMe, sharedDrives
        var id: String { rawValue }
        var title: String {
            switch self {
            case .myDrive: return "My Drive"
            case .sharedWithMe: return "Shared with me"
            case .sharedDrives: return "Shared drives"
            }
        }
        var location: GoogleDriveService.FolderLocation {
            switch self {
            case .myDrive: return .myDrive
            case .sharedWithMe: return .sharedWithMe
            case .sharedDrives: return .sharedDrives
            }
        }
    }

    private enum Phase {
        case loading
        case loaded([GoogleDriveFile])
        case failed(String)
    }

    /// What the list is showing, so one `.task(id:)` reloads on any change.
    private struct LoadKey: Hashable {
        let location: GoogleDriveService.FolderLocation
        let search: String
        let attempt: Int
    }

    @State private var place: Place = .myDrive
    /// Folders opened below the place, outermost first.
    @State private var trail: [GoogleDriveFile] = []
    /// Names the trail's start when it began in a search rather than a place.
    @State private var trailStart: String?
    @State private var query = ""
    @State private var phase: Phase = .loading
    @State private var attempt = 0

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !searchText.isEmpty }

    private var location: GoogleDriveService.FolderLocation {
        trail.last.map { .folder($0.resourceID) } ?? place.location
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 420)
        .task(id: LoadKey(location: location, search: searchText, attempt: attempt)) {
            await load()
        }
        .accessibilityIdentifier("googleDrive.folderPicker")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose your meeting folder")
                    .font(.headline)
                Text("Signed in as \(account.displayLabel). ForeverLM imports the recordings and transcripts in the folder you choose, and nothing else.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                finish(nil)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash(inset: -4))
            .help("Cancel")
            .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Where", selection: $place) {
                ForEach(Place.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: place) { _, _ in
                trail = []
                trailStart = nil
                query = ""
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search all folders by name", text: $query)
                    .textFieldStyle(.plain)
                if isSearching {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: Capsule())

            if !trail.isEmpty, !isSearching {
                breadcrumb
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button {
                trail.removeLast()
                if trail.isEmpty { trailStart = nil }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.hoverWash(inset: -4))
            .help("Up one folder")
            .accessibilityLabel("Up one folder")
            Text(([trailStart ?? place.title] + trail.map(\.name)).joined(separator: " › "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack { ProgressView().controlSize(.small) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Button("Try Again") { attempt += 1 }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let folders):
            if folders.isEmpty {
                Text(isSearching ? "No folder matches “\(searchText)”." : "No folders here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(folders, id: \.id) { folder in
                    row(folder)
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(_ folder: GoogleDriveFile) -> some View {
        HStack(spacing: 8) {
            Button {
                open(folder)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: place == .sharedDrives && trail.isEmpty && !isSearching
                          ? "externaldrive" : "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(folder.name)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Choose") { finish(folder) }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { finish(nil) }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let current = trail.last, !isSearching {
                Button("Use “\(current.name)”") { finish(current) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Opening a folder from a search result or from the shared drives list
    /// resets the trail to that folder, so Up leaves the search rather than
    /// walking a path that was never browsed.
    private func open(_ folder: GoogleDriveFile) {
        if isSearching {
            query = ""
            trailStart = "Search"
            trail = [folder]
        } else {
            trail.append(folder)
        }
    }

    private func load() async {
        phase = .loading
        do {
            if isSearching {
                // Typing: wait for a pause so each keystroke is not a request.
                try await Task.sleep(for: .milliseconds(300))
                phase = .loaded(try await GoogleDriveService.shared.searchFolders(
                    matching: searchText,
                    accountID: account.id
                ))
            } else {
                phase = .loaded(try await GoogleDriveService.shared.listFolders(
                    in: location,
                    accountID: account.id
                ))
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}
#endif
