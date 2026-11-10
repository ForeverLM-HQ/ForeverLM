// Rows, cards and pictures the Space browse view draws, and the styles that go with them.
#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Row

enum SpaceListMetrics {
    /// What a row's disclosure chevron takes before its tile, and what each
    /// level of subpage indents by.
    static let disclosureColumnWidth: CGFloat = 20
    static let indentPerLevel: CGFloat = 18
}

/// A page's chevron in the list: whether its subpages show, and the press that
/// shows or hides them.
struct SpaceRowDisclosure {
    let isExpanded: Bool
    let toggle: () -> Void
}

/// One list row: the tile, the name (with a shared mark), the notebook, the
/// date, and the ⋯ that shows under the pointer — or Trash's Restore. A page
/// with subpages leads with a chevron, and a subpage is indented under it.
struct SpaceListRow<Tile: View, Menu: View>: View {
    let item: SpaceItem
    /// Chosen for the selection bar: the row takes the selected fill and its
    /// tile a check.
    var isSelected = false
    @ViewBuilder let tile: () -> Tile
    let showsLocation: Bool
    let locationWidth: CGFloat
    let dateWidth: CGFloat
    let dateText: String
    /// Trash's Restore, shown beside the ⋯ under the pointer.
    let restore: (() -> Void)?
    /// How many pages this one is under, as the list draws it.
    var level = 0
    /// Keeps a column for the chevron, so every tile lines up.
    var reservesDisclosure = false
    var disclosure: SpaceRowDisclosure? = nil
    let open: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                if reservesDisclosure || level > 0 {
                    Color.clear.frame(width: CGFloat(level) * SpaceListMetrics.indentPerLevel, height: 1)
                    if let disclosure {
                        Button(action: disclosure.toggle) {
                            Image(systemName: "chevron.right")
                                .zoomedSystemFont(size: 9.5, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(disclosure.isExpanded ? 90 : 0))
                                .frame(width: SpaceListMetrics.disclosureColumnWidth, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(disclosure.isExpanded ? "Hide subpages" : "Show subpages")
                        .accessibilityLabel(disclosure.isExpanded ? "Hide subpages of \(item.title)" : "Show subpages of \(item.title)")
                        .accessibilityIdentifier("space.item.\(item.id).disclosure")
                    } else {
                        Color.clear.frame(width: SpaceListMetrics.disclosureColumnWidth, height: 1)
                    }
                }
                rowButton
            }
            trailingControls
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? StudioDesign.selectionFill(isSelected: true, isHovered: isHovering) : Color.primary.opacity(isHovering ? 0.04 : 0))
        )
        // The row paints its own hover fill; the inner Button takes `.plain`.
        .ownsRowHoverWash()
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("space.item.\(item.id)")
    }

    private var rowButton: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                tile()
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected { SpaceSelectedCheck().offset(x: 4, y: 4) }
                    }
                HStack(spacing: 6) {
                    Text(item.title)
                        .zoomedSystemFont(size: 13.5)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if item.isShared {
                        Image(systemName: "person.2")
                            .zoomedSystemFont(size: 10, weight: .medium)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Shared")
                    }
                    if item.isPublished {
                        Image(systemName: "globe")
                            .zoomedSystemFont(size: 10, weight: .medium)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Published")
                    }
                    if item.artifact?.isDraft == true {
                        Text("Draft")
                            .zoomedSystemFont(size: 9.5, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsLocation {
                    Text(item.location ?? "—")
                        .zoomedSystemFont(size: 12.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: locationWidth, alignment: .leading)
                }
                Text(dateText)
                    .zoomedSystemFont(size: 12.5)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: dateWidth, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textSelection(.disabled)
    }

    private var trailingControls: some View {
        ZStack {
            if let restore, isHovering {
                Button("Restore", action: restore)
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .fixedSize()
                    .offset(x: -64)
            }
            SwiftUI.Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .fixedSize()
            .opacity(isHovering ? 1 : 0)
            .help("More")
            .accessibilityLabel("Actions for \(item.title)")
        }
        .frame(width: 26)
    }
}

// MARK: - Card

/// A grid card: the item's picture — a site's page, a page's opening lines,
/// the picture itself — then its name and its date.
struct SpaceGridCard<Menu: View>: View {
    let item: SpaceItem
    var isSelected = false
    let previews: ArtifactPreviewStore
    let loadExcerpt: @Sendable (String) async throws -> String
    let dateText: String
    let open: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var isHovering = false

    private static var radius: CGFloat { 12 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                SpaceItemPicture(item: item, previews: previews, loadExcerpt: loadExcerpt)
                    .aspectRatio(item.kind == .image ? 1 : 16 / 10, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(
                            isSelected ? Color.primary.opacity(0.55) : Color.primary.opacity(isHovering ? 0.18 : 0.09),
                            lineWidth: isSelected ? 2 : 1
                        )
                    }
                    .overlay(alignment: .topLeading) {
                        if isSelected { SpaceSelectedCheck().padding(8) }
                    }
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .zoomedSystemFont(size: 13, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(dateText)
                        .zoomedSystemFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .textSelection(.disabled)
                Spacer(minLength: 0)
                SwiftUI.Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .fixedSize()
                .opacity(isHovering ? 1 : 0)
                .accessibilityLabel("Actions for \(item.title)")
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .help(item.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("space.item.\(item.id)")
    }
}

/// The check a chosen row's tile or card wears: a filled circle with a tick,
/// in the list's one colour.
private struct SpaceSelectedCheck: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color(nsColor: .textBackgroundColor), Color.primary)
            .zoomedSystemFont(size: 14, weight: .semibold)
            .background(Circle().fill(Color(nsColor: .textBackgroundColor)).padding(1))
            .accessibilityHidden(true)
    }
}

/// The top of a grid card: a picture's thumbnail, a site's photograph, or a
/// page drawn as a sheet with its opening lines, on the kind's colour.
private struct SpaceItemPicture: View {
    @Environment(StudioViewModel.self) private var vm
    let item: SpaceItem
    let previews: ArtifactPreviewStore
    let loadExcerpt: @Sendable (String) async throws -> String

    private var tint: Color { SpaceKindStyle.tint(item.kind) }
    private var previewKey: String { ArtifactPreviewStore.cacheKey(id: item.id, updatedAt: item.updatedAt) }

    var body: some View {
        Color.clear
            .background(tint.opacity(0.08))
            .overlay {
                if let listing = item.image?.latest {
                    SpaceImageThumbnail(path: listing.path, cacheKey: SpaceImageThumbnail.cacheKey(listing), previews: previews)
                } else if let goal = item.notebook {
                    NotebookIconView(notebookID: goal.id, size: 56, cornerRadius: 14, plate: NotebookTint.color(for: goal.id)) {
                        Text(NotebookTitle(goal.title).displayIcon)
                            .font(.system(size: 28))
                    }
                } else if let courseID = item.courseID {
                    CourseCoverImage(artworkURL: vm.courseArtworkURL(courseID))
                } else if item.kind == .page || item.kind == .reading {
                    pageSheet
                } else if let image = previews.image(for: previewKey) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if let linkedKind = item.artifact?.linkedKind {
                    LinkedPageIcon(kind: linkedKind, height: 30)
                        .opacity(0.8)
                } else {
                    Image(systemName: SpaceKindStyle.symbol(item.kind))
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(tint.opacity(0.6))
                }
            }
            .clipped()
            .task(id: previewKey) {
                guard item.image == nil, let artifact = item.artifact else { return }
                if item.kind == .page || item.kind == .reading {
                    let id = artifact.id
                    let loader = loadExcerpt
                    previews.requestExcerpt(for: previewKey, title: item.title) { try await loader(id) }
                } else if let request = ArtifactsHomePane.previewRequest(
                    // An animation's page is photographed as a site's is.
                    kind: item.kind == .site || item.kind == .animation ? .site : .doc,
                    linkedURL: artifact.linkedURL,
                    linkedKind: artifact.linkedKind
                ) {
                    previews.request(request, for: previewKey)
                }
            }
            .onDisappear { previews.withdraw(previewKey) }
            .accessibilityHidden(true)
    }

    /// A page as a sheet of paper: its title in the page's type, its opening
    /// lines, fading out under the card's edge.
    private var pageSheet: some View {
        GeometryReader { proxy in
            let inset = proxy.size.width * 0.12
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let excerpt = previews.excerpts[previewKey], !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: 6.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(1.5)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<6, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary.opacity(0.07))
                                .frame(width: proxy.size.width * (index == 5 ? 0.45 : 0.76), height: 3)
                        }
                    }
                    .padding(.top, 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, inset)
            .padding(.top, inset * 0.9)
            .frame(width: proxy.size.width - inset * 0.9, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
            .offset(x: inset * 0.45, y: inset * 0.7)
            .mask(
                LinearGradient(
                    stops: [.init(color: .black, location: 0.7), .init(color: .black.opacity(0), location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .clipped()
    }
}

/// A picture's thumbnail, made once off the main actor and kept in the
/// preview store's disk cache.
struct SpaceImageThumbnail: View {
    let path: String
    let cacheKey: String
    let previews: ArtifactPreviewStore

    static func cacheKey(_ listing: GeneratedImageStore.Listing) -> String {
        "space-image:v1:\(listing.id)"
    }

    var body: some View {
        Group {
            if let image = previews.image(for: cacheKey) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.primary.opacity(0.05)
            }
        }
        .task(id: cacheKey) { previews.request(.file(path: path), for: cacheKey) }
    }
}

/// Each kind's colour and glyph: blue for a page and pink for a picture, as
/// ChatGPT's list draws them, and ForeverLM's own for the rest.
enum SpaceKindStyle {
    static func tint(_ kind: SpaceItem.Kind) -> Color {
        switch kind {
        case .page: return Color(red: 0.03, green: 0.54, blue: 0.93)
        case .googleDoc: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .site: return .teal
        case .animation: return .pink
        case .reading: return .purple
        case .canvas: return .orange
        case .goalList: return .green
        case .ideaList: return Color(red: 0.86, green: 0.62, blue: 0.0)
        case .image: return Color(red: 0.81, green: 0.25, blue: 0.58)
        case .notebook: return .indigo
        case .course: return .cyan
        case .chat, .space: return .gray
        }
    }

    static func symbol(_ kind: SpaceItem.Kind) -> String {
        switch kind {
        case .page: return "doc.text.fill"
        case .googleDoc: return "doc.richtext"
        case .site: return "globe"
        case .animation: return ArtifactKind.animation.symbolName
        case .reading: return "text.book.closed.fill"
        case .canvas: return "rectangle.3.group.fill"
        case .goalList: return "target"
        case .ideaList: return "lightbulb.fill"
        case .image: return "photo"
        case .notebook: return NotebookGlyph.systemImage
        case .course: return "graduationcap.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .space: return "square.stack.fill"
        }
    }
}

/// What Trash says about how long it keeps things. Codex's Trash deletes after
/// 30 days; ForeverLM's Trash is the archive, so nothing leaves it on its own.
enum SpaceTrashWording {
    static let retention = "Items stay in Trash until you empty it."
}

/// ChatGPT's short dates: "now", "8m", "8h", "2d", then the day.
enum SpaceDateText {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < MemoryTutorScheduler.secondsPerDay { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * MemoryTutorScheduler.secondsPerDay { return "\(Int(seconds / MemoryTutorScheduler.secondsPerDay))d" }
        let calendar = Calendar.current
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
#endif
