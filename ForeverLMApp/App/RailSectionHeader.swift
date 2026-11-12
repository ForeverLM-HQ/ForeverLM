// The rail section headers and placeholder rows.
import SwiftUI
import AppKit

struct RailSectionHeader: View {
    let title: String
    var action: (() -> Void)?
    /// `nil` means the section is not foldable; otherwise the label and a
    /// chevron toggle it, the way a notebook row folds its chats.
    var isExpanded: Bool?
    var toggleExpanded: (() -> Void)?

    @State private var hovering = false

    init(
        title: String,
        isExpanded: Bool? = nil,
        toggleExpanded: (() -> Void)? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.toggleExpanded = toggleExpanded
        self.action = action
    }

    private var plusGlyph: some View {
        Image(systemName: "plus")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    var body: some View {
        HStack(spacing: 8) {
            if let isExpanded, let toggleExpanded {
                Button(action: toggleExpanded) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            // The chevron is a hint, not chrome: it shows on
                            // hover or while the section is folded, so an open
                            // section keeps the quiet label it always had.
                            .opacity(hovering || !isExpanded ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Hides this section's chats" : "Shows this section's chats")
                .accessibilityIdentifier("studio.navigation.section.\(title.lowercased()).toggle")
            } else {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            // Built only while the pointer is over the header, a hidden glyph
            // holding its place so the header keeps its height:
            // a + at rest beside New chat read as a second New chat. The
            // header's menu offers it without a pointer.
            if let action {
                if hovering {
                    Button(action: action) {
                        plusGlyph
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                    .help("New library chat, in no notebook")
                    .accessibilityLabel("New library chat")
                } else {
                    plusGlyph
                        .hidden()
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.top, 10)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The whole header is the hover target, its empty middle included,
        // so the + stays while the pointer travels to it.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Section header that doubles as a destination: it titles the run of rows
/// beneath it but still opens its browse-all view on click. Same type treatment
/// as `RailSectionHeader`, with a hover wash hugging the text so it
/// reads as clickable without turning back into a full row. Open Beside is
/// on its menu, and it drags to the
/// center's edge.
struct RailSectionHeaderButton: View {
    let title: String
    var identifier: String? = nil
    var isSelected = false
    let action: () -> Void
    @State private var hovering = false

    private var textStyle: HierarchicalShapeStyle {
        if isSelected { return .primary }
        return hovering ? .secondary : .tertiary
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: action) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(textStyle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier ?? "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // 5pt outer leading + 5pt wash inset keeps the text at the same 10pt
        // leading as the plain headers; 10pt top + 3pt wash inset lands the
        // text on the same 13pt/3pt vertical rhythm.
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .padding(.top, 10)
    }
}

struct RailPlaceholderRow: View {
    let text: String
    var indent: CGFloat = 8

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.leading, 8 + indent)
            .padding(.vertical, StudioDesign.Spacing.xSmall)
            .frame(minHeight: 28, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The "Hidden" marker that heads the hidden chats and folds them away. It
/// sits on the chat rows' left edge, with its glyph in the rows' icon column,
/// so it reads as a line of the list rather than a control that belongs to
/// the section header.
struct RailShowMoreRow: View {
    let title: String
    let accessibilityHint: String
    let systemImage: String
    var indent: CGFloat = 8
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .padding(.leading, 8 + indent)
            .padding(.trailing, 6)
            .padding(.vertical, StudioDesign.Spacing.xSmall)
            .frame(minHeight: StudioDesign.Metrics.navigationRowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .onHover { hovering = $0 }
        .accessibilityHint(accessibilityHint)
    }
}
