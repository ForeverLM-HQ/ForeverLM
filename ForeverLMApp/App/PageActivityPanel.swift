import AppKit
import SwiftUI

/// The page's **Page activity** panel, beside the page as Codex draws it
/// (`codex.space.page.activity.*`; docs/docs-design.md, "Version history"):
/// the page's versions on this Mac, newest first under the current one, each
/// with when it stopped being the page and what replaced it. Choosing a
/// version shows it over the page (`PageVersionOverlay`), with **Restore This
/// Version** and **Copy**; the page itself stays open and readable beside the
/// panel, as Codex's history does, where the old sheet covered it. The clock
/// on the page's top line and **Page Activity** in the page menu open it; ×
/// closes it.
struct PageActivityPanel: View {
    let loadVersions: () async -> [PageVersion]
    /// Bumped by the host after a save or a restore, so a new version shows.
    let reloadToken: String
    /// The version shown over the page; nil shows the page as it is now.
    @Binding var previewedVersion: PageVersion?
    let onClose: () -> Void

    @State private var versions: [PageVersion] = []
    @State private var hasLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Page activity")
                    .zoomedSystemFont(size: 13, weight: .semibold)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.hoverWash)
                .help("Close page activity")
                .accessibilityLabel("Close page activity")
                .accessibilityIdentifier("page.versionHistory.close")
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text("VERSIONS")
                        .zoomedSystemFont(size: 9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    row(title: "Current version", detail: nil, isSelected: previewedVersion == nil) {
                        previewedVersion = nil
                    }
                    ForEach(versions) { version in
                        row(
                            title: PageVersionLabel.when(version.savedAt),
                            detail: version.reason.summary,
                            isSelected: previewedVersion?.id == version.id
                        ) {
                            previewedVersion = version
                        }
                    }
                    if hasLoaded, versions.isEmpty {
                        Text("No earlier versions on this Mac yet")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    Text("Versions are kept on this Mac: when an assistant or a restore changes the page, every ten minutes of writing, and when the page loses more than half its text at once.")
                        .zoomedSystemFont(size: 10)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                }
                .padding(8)
            }
            .accessibilityIdentifier("page.versionHistory.list")
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: reloadToken) {
            versions = await loadVersions()
            hasLoaded = true
            if let shown = previewedVersion, !versions.contains(shown) { previewedVersion = nil }
        }
    }

    private func row(title: String, detail: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .zoomedSystemFont(size: 10.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.primary.opacity(0.07) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A version chosen in Page activity, shown over the page: a line naming it
/// with **Copy**, **Restore This Version** (when the page is the learner's to
/// write) and **Back to Current**, and its text drawn as reading text. The
/// editor stays alive underneath, so going back loses neither the caret nor
/// the undo history. Esc goes back.
struct PageVersionOverlay: View {
    let version: PageVersion
    let loadMarkdown: (PageVersion) async throws -> String
    /// Nil when the page is not this learner's to write, a team's page: its
    /// versions are read and copied, never restored here.
    let restore: ((PageVersion) async throws -> Void)?
    let onDone: () -> Void

    @State private var markdown: String?
    @State private var loadError: String?
    @State private var isRestoring = false
    @State private var restoreError: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(PageVersionLabel.when(version.savedAt))
                        .zoomedSystemFont(size: 12.5, weight: .semibold)
                    Text(restoreError ?? version.reason.summary)
                        .zoomedSystemFont(size: 10.5)
                        .foregroundStyle(restoreError == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    guard let markdown else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .disabled(markdown == nil)
                .help("Copy this version's text")
                .accessibilityIdentifier("page.versionHistory.copy")
                Button("Back to Current", action: onDone)
                    .buttonStyle(.hoverWash)
                    .keyboardShortcut(.cancelAction)
                    .help("Show the page as it is now")
                if restore != nil {
                    Button {
                        restoreVersion()
                    } label: {
                        HStack(spacing: 6) {
                            if isRestoring { ProgressView().controlSize(.small) }
                            Text("Restore This Version")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRestoring || markdown == nil)
                    .help("Make this version the page; what the page says now is kept in Page activity")
                    .accessibilityIdentifier("page.versionHistory.restore")
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let markdown {
                PageVersionPreview(markdown: markdown)
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
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: version.id) {
            markdown = nil
            loadError = nil
            restoreError = nil
            copied = false
            do {
                markdown = try await loadMarkdown(version)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func restoreVersion() {
        guard let restore, !isRestoring else { return }
        isRestoring = true
        restoreError = nil
        Task {
            do {
                try await restore(version)
                isRestoring = false
                onDone()
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
