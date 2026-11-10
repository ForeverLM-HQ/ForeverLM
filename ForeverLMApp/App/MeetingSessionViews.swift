// Meeting session chevron, artifact rows, folder icon and provider badges.
import SwiftUI
import AppKit

/// Indents a session's artifacts under it and hangs a hairline rail down the
/// left, so the files read as parts of the meeting above rather than siblings.
/// The chevron that shows or hides a meeting session's files. The session row
/// draws it itself (see `meetingSessionRow`), like a series' own chevron
/// (`lazyGroupHeader`).
struct MeetingSessionChevron: View {
    static let width: CGFloat = 16

    let isExpanded: Bool
    let title: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .zoomedSystemFont(size: 10, weight: .semibold)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: Self.width, height: Self.width)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 4, inset: 0, opacity: 0.10))
        .help(isExpanded ? "Hide this meeting's files" : "Show this meeting's files")
        .accessibilityLabel(isExpanded ? "Hide the files of \(title)" : "Show the files of \(title)")
    }
}

struct MeetingArtifactStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(spacing: 1) {
            content
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
        }
        .padding(.leading, 8)
    }
}

/// A single file belonging to a meeting session.
///
/// The row opens the session in ForeverLM's own reader, at this file's part of
/// it — the transcript Google wrote is already ingested, so a click that left
/// for Google Docs was giving up search, highlights, review, listening, the
/// papers a meeting mentioned, and the slides in its recording, all to show text
/// ForeverLM already had. Drive stays one click away in the hover button beside
/// the row, which is also where a file whose text never made it into the session
/// lands, so a click is never swallowed.
struct MeetingArtifactRow: View {
    let artifact: MeetingArtifact

    @Environment(StudioViewModel.self) private var vm
    @State private var isHovering = false
    @State private var isOpening = false

    /// Where this file exists outside ForeverLM, if anywhere.
    private enum ExternalCopy {
        case webPage(URL)
        case fileOnDisk(URL)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: artifact.kind.iconName)
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(artifact.kind.label)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .disabled(!canOpen)
        .overlay(alignment: .trailing) {
            // Drawn over the row rather than inside it, so appearing on hover
            // never reflows the label beside it.
            if isHovering, let external = externalCopy {
                Button {
                    open(external)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .zoomedSystemFont(size: 9)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.hoverWash(inset: -3))
                .help(externalHelp(for: external))
            }
        }
        .onHover { isHovering = $0 }
        .help(artifact.title)
        .contextMenu {
            if canOpen {
                Button(action: open) {
                    Label("Open in ForeverLM", systemImage: "book")
                }
                OtherWindowSourceMenuItem(sourceID: artifact.sourceId)
            }
            if let external = externalCopy {
                Button {
                    open(external)
                } label: {
                    Label(externalHelp(for: external), systemImage: "arrow.up.forward.square")
                }
            }
        }
    }

    /// The kinds ForeverLM shows in place stay live even with no external copy at
    /// all: an on-device transcript has neither a Drive URL nor a file on disk,
    /// and must not render as a permanently disabled row under the recording it
    /// was made from.
    private var canOpen: Bool {
        switch artifact.kind {
        case .transcript, .notes, .chat, .recording:
            return true
        case .attachment:
            return externalCopy != nil
        }
    }

    private var externalCopy: ExternalCopy? {
        if let url = artifact.url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty,
           let resolved = URL(string: url) {
            return .webPage(resolved)
        }
        if let path = artifact.localFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return .fileOnDisk(URL(fileURLWithPath: path))
        }
        return nil
    }

    private func externalHelp(for external: ExternalCopy) -> String {
        switch external {
        case .webPage(let url):
            return url.host?.contains("google.com") == true
                ? "Open in Google Drive"
                : "Open in browser"
        case .fileOnDisk:
            return "Reveal in Finder"
        }
    }

    private func open() {
        guard !isOpening else { return }
        isOpening = true
        Task {
            let openedInReader = await vm.openMeetingArtifactInReader(artifact)
            isOpening = false
            guard !openedInReader else { return }
            // This file's text never reached the session document — a Doc the
            // plugin could not export, a deck attached to the invite — so the
            // external copy is the only place it exists.
            if let external = externalCopy {
                open(external)
            } else {
                vm.showToast("ForeverLM has no copy of this \(artifact.kind.label.lowercased()) to open.")
            }
        }
    }

    private func open(_ external: ExternalCopy) {
        switch external {
        case .webPage(let url):
            WebLinkOpening.open(url)
        case .fileOnDisk(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// A meeting folder's sidebar tile: the image chosen for that folder, or the
/// shared meetings icon when none is.
///
/// The chosen image is drawn `.fill`, so a logo that is not
/// square crops to the tile instead of floating in a half-empty one. A failed
/// or still-loading fetch shows the default icon rather than a gap — the header
/// is chrome, and an empty square there reads as a broken folder.
struct MeetingFolderIcon: View {
    let imageURL: String?

    var body: some View {
        Group {
            if let imageURL, let url = URL(string: imageURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        defaultIcon
                    }
                }
            } else {
                defaultIcon
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var defaultIcon: some View {
        Image("MeetingsIcon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
    }
}

/// The provider marks for one meeting series.
///
/// Meetings is a single tab over several providers, so a row has to say which
/// one it came from. A series that draws on more than one shows more than one
/// mark — the split Google Drive and Read AI tabs listed that series twice
/// instead, once under each, which is the duplication this replaces.
struct MeetingProviderBadges: View {
    let providers: [MeetingProvider]
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(providers) { provider in
                MeetingProviderMark(provider: provider, size: size)
                    .help("Synced with \(provider.displayName)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard !providers.isEmpty else { return "" }
        return "From " + ListFormatter.localizedString(
            byJoining: providers.map(\.displayName)
        )
    }
}

/// One provider's brand mark, falling back to an SF Symbol for providers with
/// no logo of their own — a folder on this Mac is not a brand.
struct MeetingProviderMark: View {
    let provider: MeetingProvider
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let asset = provider.iconAsset {
                Image(asset)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            } else {
                Image(systemName: provider.icon)
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(provider.color)
            }
        }
        .frame(width: size, height: size)
        .help(provider.displayName)
    }
}
