// The rows of the chat's "In context" list.
import SwiftUI
import AppKit

/// Every row of the "In context" list has one shape, whatever it holds: a
/// 36×48 leading tile, a title, a faint line under it saying what it is, and
/// an × that comes out under the pointer at the top trailing corner (product
/// owner, 2026-11-25, of a Page drawn as a small chip above a list of
/// covered papers: "any thing that can be put in the context should be in a
/// similar form and shape"). A source draws its own `ArticleRow` in the
/// label; anything else draws `ContextItemLabel`. Never give one kind its own
/// row shape here; the rule is "One list, one row shape" in
/// docs/ui-design.md.
struct ContextRow<Label: View>: View {
    let help: String
    let removeHelp: String
    /// Nil for a row with nothing to open from here.
    let open: (() -> Void)?
    let remove: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    var body: some View {
        content
            // The × for VoiceOver, which has no pointer to bring it out.
            .accessibilityAction(named: Text("Remove from Chat Context"), remove)
            .padding(.leading, 8)
            // Room for the remove button so its fade-in never reflows the row.
            .padding(.trailing, 26)
            .padding(.vertical, 5)
            // This wash spans the row including the space the remove button
            // fades into, so it is the one that stays; `ArticleRow` drops its
            // narrower one.
            .ownsRowHoverWash()
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            )
            .overlay(alignment: .topTrailing) {
                // Built only under the pointer: a button at opacity 0 is still
                // a live control, and while an assistive app reads the screen
                // SwiftUI walks every control in the window for each one an
                // update builds. The padding above holds its room.
                if isHovering {
                    Button(action: remove) {
                        ContextCardRemoveGlyph()
                    }
                    .buttonStyle(.hoverWash(in: Circle(), inset: 0))
                    .help(removeHelp)
                    .padding(.top, 7)
                    .padding(.trailing, 5)
                }
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var content: some View {
        if let open {
            Button(action: open) {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        } else {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help(help)
        }
    }
}

/// What a row of the "In context" list shows for anything that is not a
/// library source: the kind's glyph on a tile the size of a source's cover,
/// the title as a source row sets it, and the kind under it where a source
/// puts its byline.
struct ContextItemLabel: View {
    let symbol: String
    let title: String
    let kind: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 36, height: 48)
                .overlay {
                    Image(systemName: symbol)
                        .zoomedSystemFont(size: 18)
                        .foregroundStyle(.secondary)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(kind)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            // A row's words are its label, not text to copy; the window's text
            // selection would otherwise take the click.
            .textSelection(.disabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An attached Doc in the "In context" list.
struct ContextDocCard: View {
    let doc: ChatDocAttachment
    let onRemove: () -> Void

    var body: some View {
        ContextRow(
            help: doc.title,
            removeHelp: "Remove \(doc.title) from chat context",
            open: nil,
            remove: onRemove
        ) {
            ContextItemLabel(
                symbol: doc.linkedURL == nil ? "doc.text" : "safari",
                title: doc.title,
                kind: doc.linkedURL == nil ? "Page" : "Site"
            )
            .accessibilityLabel("Page in context: \(doc.title)")
        }
    }
}

/// The × on an "In context" row.
private struct ContextCardRemoveGlyph: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(Color.primary.opacity(0.08), in: Circle())
            .contentShape(Circle())
    }
}

/// One source in the composer's "In context" popover.
struct ContextSourceCard: View {
    let source: StudioArticle
    let metadataVisibility: MetadataVisibilitySettings
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ContextRow(
            help: "Open \(source.title) in the reader",
            removeHelp: "Remove \(source.title) from chat context",
            open: onOpen,
            remove: onRemove
        ) {
            // Every row here reads at full strength: what is in the context is
            // the point, and a read source's grey title made the list look
            // like two kinds of row.
            ArticleRow(
                article: source,
                metadataVisibility: metadataVisibility,
                alwaysShowsBookContext: true,
                dimsReadTitle: false
            )
        }
        .opensInOtherWindow(source)
    }
}
