import AppKit
import SwiftUI

/// The page menu's **Version History…** (docs/docs-design.md, "Version
/// history"): the page's versions on this Mac, newest first under the current
/// one, and the chosen version's text beside them, read only. **Restore This
/// Version** makes it the page through the ordinary save, which keeps the
/// body it replaces as a version of its own; **Copy** takes its Markdown.
/// Esc or × closes it.
struct PageVersionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let pageTitle: String
    /// The text the page shows now, typing included.
    let currentMarkdown: String
    let loadVersions: () async -> [PageVersion]
    let loadMarkdown: (PageVersion) async throws -> String
    /// Nil when the page is not this learner's to write, a team's page: its
    /// versions are read and copied, never restored here.
    let restore: ((PageVersion) async throws -> Void)?

    enum Selection: Hashable {
        case current
        case version(String)
    }

    @State private var versions: [PageVersion] = []
    @State private var hasLoaded = false
    @State private var selection: Selection? = .current
    @State private var bodies: [String: String] = [:]
    @State private var loadError: String?
    @State private var isRestoring = false
    @State private var restoreError: String?
    @State private var copiedSelection: Selection?

    private var selectedVersion: PageVersion? {
        guard case .version(let id)? = selection else { return nil }
        return versions.first { $0.id == id }
    }

    private var selectedMarkdown: String? {
        switch selection {
        case .version(let id)?: return bodies[id]
        default: return currentMarkdown
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                versionList
                    .frame(width: 250)
                Divider()
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 460, idealHeight: 620)
        .task {
            versions = await loadVersions()
            hasLoaded = true
        }
        .task(id: selection) {
            loadError = nil
            restoreError = nil
            guard let version = selectedVersion, bodies[version.id] == nil else { return }
            do {
                bodies[version.id] = try await loadMarkdown(version)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Version History")
                .zoomedSystemFont(size: 14, weight: .semibold)
            Text(pageTitle)
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("page.versionHistory.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var versionList: some View {
        List(selection: $selection) {
            row(title: "Current version", detail: nil)
                .tag(Selection.current)
            ForEach(versions) { version in
                row(title: PageVersionLabel.when(version.savedAt), detail: version.reason.summary)
                    .tag(Selection.version(version.id))
            }
            if hasLoaded, versions.isEmpty {
                Text("No earlier versions on this Mac yet")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        // A click picks the row; the window's selectable text would take it.
        .textSelection(.disabled)
        .accessibilityIdentifier("page.versionHistory.list")
    }

    private func row(title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .zoomedSystemFont(size: 12.5, weight: .medium)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let restoreError {
                    Text(restoreError)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    copySelection()
                } label: {
                    Label(copiedSelection == selection ? "Copied" : "Copy", systemImage: copiedSelection == selection ? "checkmark" : "doc.on.doc")
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .disabled(selectedMarkdown == nil)
                .help("Copy this version's text")
                .accessibilityIdentifier("page.versionHistory.copy")
                if let version = selectedVersion, restore != nil {
                    Button {
                        restoreVersion(version)
                    } label: {
                        HStack(spacing: 6) {
                            if isRestoring {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Restore This Version")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRestoring || bodies[version.id] == nil)
                    .help("Make this version the page; what the page says now is kept in this list")
                    .accessibilityIdentifier("page.versionHistory.restore")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            if let markdown = selectedMarkdown {
                PageVersionPreview(markdown: markdown)
                    .id(selection)
            } else if let loadError {
                Text(loadError)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func copySelection() {
        guard let markdown = selectedMarkdown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copiedSelection = selection
    }

    private func restoreVersion(_ version: PageVersion) {
        guard let restore, !isRestoring else { return }
        isRestoring = true
        restoreError = nil
        Task {
            do {
                try await restore(version)
                isRestoring = false
                dismiss()
            } catch {
                isRestoring = false
                restoreError = error.localizedDescription
            }
        }
    }
}

/// A version's Markdown drawn as reading text: headings, lists, quotes, code
/// and tables as such, and the inline marks within a line. Read only and
/// selectable; a light rendering, since the page's own editor is a web view
/// that holds one page at a time.
struct PageVersionPreview: View {
    private let blocks: [PageVersionPreviewBlock]

    init(markdown: String) {
        blocks = PageVersionPreviewBlock.blocks(from: markdown)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    blockView(block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .textSelection(.enabled)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func blockView(_ block: PageVersionPreviewBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(Self.inline(block.text))
                .zoomedSystemFont(size: level == 1 ? 20 : level == 2 ? 17 : level == 3 ? 15 : 13.5, weight: .semibold)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph:
            Text(Self.inline(block.text))
                .zoomedSystemFont(size: 13.5)
                .lineSpacing(3)
        case .listItem(let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .zoomedSystemFont(size: 13.5)
                    .foregroundStyle(.secondary)
                Text(Self.inline(block.text))
                    .zoomedSystemFont(size: 13.5)
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .quote:
            Text(Self.inline(block.text))
                .zoomedSystemFont(size: 13.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 2)
                }
        case .code:
            Text(block.text)
                .zoomedSystemFont(size: 12, design: .monospaced)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .rule:
            Divider()
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// One block of a version's Markdown, for `PageVersionPreview`.
struct PageVersionPreviewBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading(Int)
        case paragraph
        case listItem(depth: Int, marker: String)
        case quote
        /// A fenced block, or a table's lines, drawn as written.
        case code
        case rule
    }

    let id: Int
    let kind: Kind
    let text: String

    static func blocks(from markdown: String) -> [PageVersionPreviewBlock] {
        var blocks: [PageVersionPreviewBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [String] = []
        var code: [String]?

        func append(_ kind: Kind, _ text: String) {
            blocks.append(PageVersionPreviewBlock(id: blocks.count, kind: kind, text: text))
        }
        func flush() {
            if !paragraph.isEmpty { append(.paragraph, paragraph.joined(separator: "\n")) }
            if !quote.isEmpty { append(.quote, quote.joined(separator: "\n")) }
            if !table.isEmpty { append(.code, table.joined(separator: "\n")) }
            paragraph = []
            quote = []
            table = []
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if trimmed.hasPrefix("```") {
                    append(.code, open.joined(separator: "\n"))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let heading = headingLevel(trimmed) {
                flush()
                append(.heading(heading.level), heading.text)
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                append(.rule, "")
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !table.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                table.append(trimmed)
                continue
            }
            if let item = listItem(line) {
                flush()
                append(.listItem(depth: item.depth, marker: item.marker), item.text)
                continue
            }
            if !quote.isEmpty || !table.isEmpty { flush() }
            paragraph.append(trimmed)
        }
        if let open = code { append(.code, open.joined(separator: "\n")) }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (depth: Int, marker: String, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(indent.count)
        let depth = width / 2
        for bullet in ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            let marker = bullet.contains("[ ]") ? "☐" : bullet.contains("[") ? "☑" : "•"
            return (depth, marker, String(rest.dropFirst(bullet.count)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return (depth, "\(digits).", String(after.dropFirst(2)))
            }
        }
        return nil
    }
}
