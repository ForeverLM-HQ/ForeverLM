import OSLog
import SwiftUI

// The three surfaces of Save Offline: the action (reader menu and row context
// menu), the row badge that says a source is already saved, and the Offline
// screen in Settings where saved sources are reviewed and removed.

/// Shared so the reader menu and a browser row's context menu can never drift
/// into showing different states for the same source. Deliberately always one
/// `Button`: a menu is not a general view container, and branching its content
/// is how custom menu rows end up rendered flat or inert.
struct MobileOfflineSaveButton: View {
    let source: MobileCloudSource

    @ObservedObject private var offline = MobileOfflineLibrary.shared

    var body: some View {
        Button(title, systemImage: icon) {
            guard let action else { return }
            Task { await action() }
        }
        .disabled(action == nil)
        .accessibilityIdentifier(identifier)
    }

    private var title: String {
        switch offline.state(for: source.id) {
        case .saved: return "Remove Download"
        case .saving: return "Saving…"
        case .notSaved, .failed: return "Save Offline"
        }
    }

    private var icon: String {
        switch offline.state(for: source.id) {
        case .saved: return "arrow.down.circle.fill"
        case .saving, .notSaved, .failed: return "arrow.down.circle"
        }
    }

    private var identifier: String {
        switch offline.state(for: source.id) {
        case .saved: return "source.removeDownload"
        case .saving: return "source.savingOffline"
        case .notSaved, .failed: return "source.saveOffline"
        }
    }

    private var action: (@MainActor () async -> Void)? {
        switch offline.state(for: source.id) {
        case .saved:
            return { await offline.remove(sourceID: source.id) }
        case .saving:
            return nil
        case .notSaved, .failed:
            return { await offline.save(source) }
        }
    }
}

/// The row marker for a saved source. Sized to sit beside the audio indicators
/// without changing row height.
struct MobileOfflineRowBadge: View {
    let isSaving: Bool

    var body: some View {
        Image(systemName: isSaving ? "arrow.down.circle" : "arrow.down.circle.fill")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityLabel(isSaving ? "Saving offline" : "Saved offline")
    }
}

/// Settings → Offline. What is on this phone, how much it costs in storage, and
/// the only place to take it off again in bulk. Once the phone has switched to
/// the new iCloud store, also which spaces it downloads whole and whether it
/// searches the text of every source.
struct MobileOfflineDownloadsView: View {
    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @ObservedObject private var offline = MobileOfflineLibrary.shared
    @StateObject private var choices = MobileOfflineChoicesModel()
    @State private var confirmsRemoveAll = false

    var body: some View {
        List {
            if rows.isEmpty {
                ContentUnavailableView("Nothing Saved", systemImage: "arrow.down.circle")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(rows) { row in
                        MobileOfflineDownloadRow(row: row)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Remove", role: .destructive) {
                                    Task { await offline.remove(sourceID: row.id) }
                                }
                            }
                    }
                } footer: {
                    if let total = offline.formattedTotalBytes {
                        Text(total)
                    }
                }

                Section {
                    Button("Remove All Downloads", role: .destructive) {
                        confirmsRemoveAll = true
                    }
                    .accessibilityIdentifier("offline.removeAll")
                }
            }

            if choices.isAvailable {
                if !choices.spaces.isEmpty {
                    Section {
                        ForEach(choices.spaces) { space in
                            Toggle(isOn: Binding(
                                get: { space.isDownloaded },
                                set: { choices.setDownloaded($0, space: space.id) }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(space.name)
                                    if let line = space.sizeLine {
                                        Text(line)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                            .accessibilityIdentifier("offline.space.downloadAll")
                        }
                    } header: {
                        Text("Download All Files")
                    } footer: {
                        Text("Keeps every file of a shared space on this iPhone, to read without a connection. What a space holds shows either way.")
                    }
                }

                Section {
                    Toggle("Search the text of every source", isOn: Binding(
                        get: { choices.searchesWholeLibrary },
                        set: { choices.setSearchesWholeLibrary($0) }
                    ))
                    .accessibilityIdentifier("offline.search.wholeLibrary")
                } header: {
                    Text("Search")
                } footer: {
                    Text("This iPhone searches the titles and summaries of all your sources, and the text of the ones in your notebooks, read in the last 30 days or saved offline. Turn this on to download the text of every source and search it too.")
                }
            }
        }
        .navigationTitle("Offline")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove all downloads?",
            isPresented: $confirmsRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                Task { await offline.removeAll() }
            }
        } message: {
            Text("The sources stay in your library and download again when you open them.")
        }
        .task { await offline.refreshUsage() }
        .task { await choices.load() }
    }

    private var rows: [MobileOfflineDownloadRow.Model] {
        let sourcesByID = Dictionary(vm.allSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return offline.savedSourceIDs
            .map { sourceID in
                let source = sourcesByID[sourceID]
                return MobileOfflineDownloadRow.Model(
                    id: sourceID,
                    // A pin can outlive its catalog row (archived on the Mac, or a
                    // delta that has not landed yet). Showing the id keeps those
                    // bytes visible and removable instead of stranded.
                    title: source?.title ?? sourceID,
                    sourceType: source?.sourceType,
                    subtitle: source?.citationSubtitle,
                    bytes: offline.bytesBySourceID[sourceID] ?? 0
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

private struct MobileOfflineDownloadRow: View {
    struct Model: Identifiable {
        let id: String
        let title: String
        let sourceType: String?
        let subtitle: String?
        let bytes: Int64
    }

    let row: Model

    var body: some View {
        HStack(spacing: 12) {
            if let sourceType = row.sourceType {
                MobileSourceIconTile(sourceType: sourceType, size: CGSize(width: 32, height: 32))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .lineLimit(2)
                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(MobileOfflineByteFormat.string(row.bytes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Settings → Offline's choices (docs/cloudkit-schema-design.md §2.3, §8a): the
/// spaces it downloads whole ("Download all files", bytes only, never what a
/// space shows), each with what it would take, and the whole-library text
/// search. Both are this device's own, never synced.
@MainActor
final class MobileOfflineChoicesModel: ObservableObject {
    struct SpaceRow: Identifiable, Equatable {
        /// The space's zone key.
        let id: String
        let name: String
        var isDownloaded: Bool
        /// What downloading it whole takes, and what it keeps already; nil until measured.
        var total: Int64?
        var kept: Int64 = 0

        var sizeLine: String? {
            guard let total else { return nil }
            guard isDownloaded, kept < total else { return MobileOfflineByteFormat.string(total) }
            return "\(MobileOfflineByteFormat.string(kept)) of \(MobileOfflineByteFormat.string(total))"
        }
    }

    @Published private(set) var isAvailable = false
    @Published private(set) var spaces: [SpaceRow] = []
    @Published private(set) var searchesWholeLibrary = false

    private let downloads: MobileSpaceDownloads
    private let textChoice: MobileTextIndexChoice

    init(downloads: MobileSpaceDownloads = MobileSpaceDownloads(), textChoice: MobileTextIndexChoice = MobileTextIndexChoice()) {
        self.downloads = downloads
        self.textChoice = textChoice
    }

    /// A space as the toggle names it: its root's name, else what kind of space it is.
    static func name(of space: MobileProjection.Space) -> String {
        if let name = space.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        switch space.kind {
        case "family": return "Family"
        case "notebook": return "Shared notebook"
        case "doc": return "Shared Page"
        default: return "Team"
        }
    }

    func load() async {
        guard let session = await MobileSyncSession.startIfEnabled() else { return }
        isAvailable = true
        searchesWholeLibrary = textChoice.wholeLibrary
        var held: [MobileProjection.Space] = []
        do {
            held = try await session.projection.spaces()
        } catch {
            Logger(subsystem: "com.foreverlm.mobile", category: "OfflineChoices")
                .error("Reading the spaces held on this phone failed: \(error.localizedDescription, privacy: .public)")
        }
        spaces = held.map { SpaceRow(id: $0.zoneKey, name: Self.name(of: $0), isDownloaded: downloads.contains($0.zoneKey)) }
        for space in held {
            await measure(space.zoneKey, satellites: session.satellites)
        }
    }

    /// Turning a space on downloads it now, a bounded batch at a time while the choice stands, rather
    /// than 25 files a sync round; later rounds keep it whole.
    func setDownloaded(_ downloaded: Bool, space zoneKey: String) {
        downloads.set(zoneKey, downloaded: downloaded)
        update(zoneKey) { $0.isDownloaded = downloaded }
        let downloads = self.downloads
        Task {
            guard let satellites = await MobileSatellites.current() else { return }
            if downloaded {
                while downloads.contains(zoneKey), await satellites.downloadSpaces([zoneKey]) > 0 {
                    await measure(zoneKey, satellites: satellites)
                }
            } else {
                await satellites.stopDownloading(space: zoneKey)
            }
            await measure(zoneKey, satellites: satellites)
        }
    }

    /// Turning it on indexes the library's text now, 40 sources a pass while the choice stands, rather
    /// than 40 a sync round; turning it off drops what left the text set at once.
    func setSearchesWholeLibrary(_ on: Bool) {
        textChoice.wholeLibrary = on
        searchesWholeLibrary = on
        guard let session = MobileSyncSession.current else { return }
        let pinned = MobileOfflinePins.saved()
        let textChoice = self.textChoice
        Task.detached(priority: .utility) {
            guard on else {
                await session.textIndexer.refresh(pinned: pinned, wholeLibrary: false)
                return
            }
            while textChoice.wholeLibrary, await session.textIndexer.refresh(pinned: pinned, wholeLibrary: true) > 0 {}
        }
    }

    private func measure(_ zoneKey: String, satellites: MobileSatellites) async {
        guard let size = try? await satellites.spaceSize(zoneKey: zoneKey) else { return }
        update(zoneKey) {
            $0.total = size.total
            $0.kept = size.kept
        }
    }

    private func update(_ zoneKey: String, _ change: (inout SpaceRow) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == zoneKey }) else { return }
        change(&spaces[index])
    }
}
