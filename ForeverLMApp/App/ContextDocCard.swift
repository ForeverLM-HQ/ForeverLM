// The document and source cards shown for chat context.
import SwiftUI
import AppKit

/// An attached Doc in the "In context" list.
///
/// Deliberately plainer than a source row: a Doc has no cover art, no reader to
/// open it in from here, and nothing to say about itself beyond its name.
struct ContextDocCard: View {
    let doc: ChatDocAttachment
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(doc.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            // Built only under the pointer, the hidden glyph holding its
            // place: a button at opacity 0 is still a live control, and while
            // an assistive app reads the screen SwiftUI walks every control
            // in the window for each one an update builds (2026-10-03).
            if isHovering {
                Button(action: onRemove) {
                    ContextCardRemoveGlyph()
                }
                .buttonStyle(.hoverWash(in: Circle()))
                .help("Remove \(doc.title) from chat context")
            } else {
                ContextCardRemoveGlyph()
                    .hidden()
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page in context: \(doc.title)")
        // The × for VoiceOver, which has no pointer to bring it out; while
        // the × is built, the combined element carries its press already.
        .accessibilityActions {
            if !isHovering {
                Button("Remove from Chat Context", action: onRemove)
            }
        }
    }
}

/// The × on an "In context" card, and, hidden, what holds its place while
/// the button is not built.
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

/// One source in the composer's "In context" popover. Its own view so each row can
/// own a hover state: the row highlights and the remove button fades in only under
/// the pointer, which keeps a list of sources from reading as a wall of ✕ buttons.
struct ContextSourceCard: View {
    let source: StudioArticle
    let metadataVisibility: MetadataVisibilitySettings
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            ArticleRow(article: source, metadataVisibility: metadataVisibility)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opensInOtherWindow(source)
        .help("Open \(source.title) in the reader")
        // The × for VoiceOver, which has no pointer to bring it out.
        .accessibilityAction(named: Text("Remove from Chat Context"), onRemove)
        .padding(.leading, 8)
        // Room for the remove button so its fade-in never reflows the row.
        .padding(.trailing, 26)
        .padding(.vertical, 5)
        // This wash spans the row including the space the remove button fades into,
        // so it is the one that stays; `ArticleRow` drops its narrower one.
        .ownsRowHoverWash()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .overlay(alignment: .topTrailing) {
            // Built only under the pointer: a button at opacity 0 is still a
            // live control, and while an assistive app reads the screen
            // SwiftUI walks every control in the window for each one an
            // update builds (2026-10-03). The padding above holds its room.
            if isHovering {
                Button(action: onRemove) {
                    ContextCardRemoveGlyph()
                }
                .buttonStyle(.hoverWash(in: Circle(), inset: 0))
                .help("Remove \(source.title) from chat context")
                .padding(.top, 7)
                .padding(.trailing, 5)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
