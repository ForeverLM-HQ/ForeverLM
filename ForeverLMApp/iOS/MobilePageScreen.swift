import SwiftUI
import UIKit

// A page of the Space on the phone (docs/docs-design.md, "The Space", "Subpages", "Daily Notes"): its
// name, the quiet trail of the pages above it, and its text in the editor the Mac and the web run
// (`MobilePageEditorView`), saved through the store a second after the last edit, and at once when the
// page closes or the app leaves. A save is written only over the revision the text was opened at; one
// that meets another device's newer text asks which stands, in the Mac's words (Use theirs, Keep
// mine), and waits for the answer. Everything else is the page's ⋯, the same menu as its row.

/// One page, written in place when it is the learner's own Markdown page out of Trash, read otherwise:
/// a team's page, a reading, a linked Google Doc's text copy (with Open in Google Docs).
struct MobilePageScreen: View {
    let pageID: String

    @Environment(MobileSpaceStore.self) private var store
    @Environment(MobileSpaceRecents.self) private var recents
    @Environment(\.spaceNavigation) private var navigation
    @Environment(\.spaceNotebookTitles) private var notebookTitles
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: MobilePageModel
    @State private var actions = MobileSpaceActions()
    @State private var titleDraft = ""
    /// Rename… asked for the title while the page's first heading names it, so it is drawn.
    @State private var isEditingTitle = false
    @FocusState private var titleFocused: Bool

    /// How wide the page is drawn, which sets where the editor's text starts.
    @State private var pageWidth: CGFloat = 0

    /// Where the editor's text starts, so the trail and the title stand over it: its column is at most
    /// `MobilePageEditorView.pageMaxWidth` wide and centred, with a side margin of 6% of the width
    /// between 20 and 48 points (the editor's `--artifact-page-padding`).
    private var textInset: CGFloat {
        let column = min(pageWidth, MobilePageEditorView.pageMaxWidth)
        return max(0, (pageWidth - column) / 2) + min(max(pageWidth * 0.06, 20), 48)
    }

    init(pageID: String) {
        self.pageID = pageID
        _model = State(initialValue: MobilePageModel(pageID: pageID))
    }

    private var page: MobileSpacePage? {
        store.pages.first { $0.id == pageID }
    }

    var body: some View {
        MobileSpaceAvailability {
            if let page {
                pageView(page)
            } else {
                ContentUnavailableView {
                    Label("Page Not Here", systemImage: "doc.text")
                } description: {
                    Text(MobileSpaceError.notFound.localizedDescription)
                }
            }
        }
        .navigationTitle(page.map(MobileSpacePageTitle.display) ?? "Page")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The name is the page's own first line; the bar keeps it for Back and VoiceOver only.
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
            if let page {
                ToolbarItem(placement: .topBarTrailing) {
                    pageMenu(page)
                }
            }
        }
        .spaceActions(actions)
        .onAppear { recents.note(pageID) }
        .onDisappear { model.saveNow() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveNow() }
        }
        .accessibilityIdentifier("page.screen")
    }

    // MARK: The page

    private func pageView(_ page: MobileSpacePage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(page)
            notices(page)
            surface(page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .task(id: page.bodyRevision) {
            await model.open(with: store, revision: page.bodyRevision)
        }
        // The heading a page opens with is its name: the title takes its words once typing
        // pauses (and as the page opens), so the two never read as two names.
        .task(id: model.firstHeading) {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            adoptHeadingAsTitle(page)
        }
        .onChange(of: page.title, initial: true) { _, title in
            if !titleFocused { titleDraft = MobileSpacePageTitle.isPlaceholder(title) ? "" : title }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
    }

    /// "Parent › Page" over a subpage, then the title — not drawn while the page's first heading is its
    /// title (the page says the name already), as on the Mac; a daily note always names its day.
    @ViewBuilder
    private func header(_ page: MobileSpacePage) -> some View {
        let ancestors = MobileSpaceListing.ancestors(of: page.id, in: store.pages, organization: store.organization)
        let showsTitle = page.isDailyNote || page.isPlan || isEditingTitle || titleFocused
            || model.firstHeading?.lowercased() != page.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !ancestors.isEmpty || showsTitle {
            VStack(alignment: .leading, spacing: 2) {
                if !ancestors.isEmpty {
                    MobilePageTrail(ancestors: ancestors, title: MobileSpacePageTitle.display(page)) { id in
                        if let url = MobilePageEditorAddress.url(kind: "doc", id: id) { openURL(url) }
                    }
                }
                if showsTitle {
                    titleField(page)
                }
            }
            .padding(.horizontal, textInset)
            .padding(.top, MobileDesign.Spacing.small)
        }
    }

    @ViewBuilder
    private func titleField(_ page: MobileSpacePage) -> some View {
        if page.isOwn, !page.isTrashed {
            // Above the page's own headings, as the Mac's title sits above an H2.
            TextField(MobileSpaceListing.untitledTitle, text: $titleDraft)
                .font(.title.weight(.bold))
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit { titleFocused = false }
                .accessibilityLabel("Title")
                .accessibilityIdentifier("page.title")
        } else {
            Text(MobileSpacePageTitle.display(page))
                .font(.title.weight(.bold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// What is happening now and asks for something: a save that met another device's text, a page in
    /// Trash, a save that failed; and a linked page's way to its own app.
    @ViewBuilder
    private func notices(_ page: MobileSpacePage) -> some View {
        if model.conflict != nil {
            notice {
                Label("Changed elsewhere while you were editing", systemImage: "arrow.triangle.branch")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: MobileDesign.Spacing.small) {
                    Button("Use theirs") { model.useTheirs() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("page.conflict.useTheirs")
                    Button("Keep mine") { model.keepMine() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("page.conflict.keepMine")
                }
                .controlSize(.small)
            }
        } else if page.isTrashed {
            notice {
                HStack {
                    Label("In Trash", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    if page.isOwn {
                        Button("Restore") {
                            actions.run("Couldn’t Restore the Page") { try await store.restore(page.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        } else if let message = model.saveError {
            notice {
                Label("Not saved: \(message)", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                Button("Try Again") { model.saveNow() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        if let url = MobileSpacePageMenuItems.webAddress(page) {
            Link(destination: url) {
                Label(page.spaceKind == .googleDoc ? "Open in Google Docs" : "Open Site", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, textInset)
            .padding(.top, MobileDesign.Spacing.small)
        }
    }

    private func notice<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            content()
        }
        .padding(MobileDesign.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous))
        .padding(.horizontal, textInset)
        .padding(.top, MobileDesign.Spacing.small)
    }

    @ViewBuilder
    private func surface(_ page: MobileSpacePage) -> some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notArrived:
            ContentUnavailableView {
                Label("Not on This iPhone Yet", systemImage: "icloud.and.arrow.down")
            } description: {
                Text("This page’s text is still on its way from your Mac.")
            }
        case .failed(let message):
            // A linked page whose text copy has not come is waiting, not broken.
            ContentUnavailableView {
                Label(page.linkedURL == nil ? "Can’t Show This Page" : "Not on This iPhone Yet",
                      systemImage: page.linkedURL == nil ? "doc.text" : "icloud.and.arrow.down")
            } description: {
                Text(message)
            }
        case .ready:
            editor(page)
        }
    }

    private func editor(_ page: MobileSpacePage) -> some View {
        let model = self.model
        let editable = page.isEditableMarkdown && !page.isTrashed
        return MobilePageEditorView(
            pageID: page.id,
            markdown: model.text,
            textKey: model.textKey,
            isEditable: editable,
            linkTargets: linkTargets,
            attachmentDataURLs: model.pictures,
            onMarkdownChange: { value in model.edited(value) },
            onOpenURL: { url in follow(url) },
            onCreatePage: editable ? { request in await makeLinkedPage(request, from: page) } : nil,
            onError: { message in model.editorFailed(message) }
        )
        .id(page.id)
    }

    /// What `[[` and `@` offer: the learner's pages out of Trash, each with where it is filed (or
    /// Draft), then the notebooks.
    private var linkTargets: [MobilePageLinkTarget] {
        let organization = store.organization
        let pages = store.pages
            .filter { !$0.isTrashed && !$0.isHidden && $0.id != pageID }
            .map { page -> MobilePageLinkTarget in
                let detail: String
                if page.isDraft {
                    detail = "Draft"
                } else if let notebookID = page.notebookIDs.first, let name = notebookTitles[notebookID] {
                    detail = name
                } else if let space = organization.spaceID(ofPage: page.id).flatMap(organization.space) {
                    detail = NotebookTitle(space.name).text
                } else {
                    detail = ""
                }
                return MobilePageLinkTarget(id: page.id, title: MobileSpacePageTitle.display(page), kind: "doc", detail: detail)
            }
        let notebooks = notebookTitles
            .map { MobilePageLinkTarget(id: $0.key, title: $0.value, kind: "notebook", detail: "Notebook") }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return pages + notebooks
    }

    /// A link the page followed: a page, a notebook or a source where the app opens them (the shell's
    /// stack, or the split view's page column), the web in the browser. An Idea or a chat is the Mac's.
    private func follow(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            openURL(url)
        default:
            if MobileDeepLink.parse(url) != nil { openURL(url) }
        }
    }

    /// A page the `/` menu's Page row (or a `[[` new page) linked before it existed, made under the id
    /// the editor gave it: under this page when the editor asks for a subpage and this page can hold one.
    private func makeLinkedPage(_ request: MobilePageCreationRequest, from page: MobileSpacePage) async -> Bool {
        let parentID = request.isSubpage && MobileSpaceListing.canNest(page) ? page.id : nil
        do {
            _ = try await store.createPage(title: request.title, markdown: "", spaceID: nil, parentID: parentID, id: request.id)
            if let parentID { MobileSpaceExpansion.expand(parentID) }
            return true
        } catch {
            actions.failure = MobileSpaceActions.Failure(title: "Couldn’t Make the Page", message: error.localizedDescription)
            return false
        }
    }

    // MARK: The title

    private func beginRename() {
        isEditingTitle = true
        titleFocused = true
    }

    /// The name typed, once the field lets go of the caret. An empty name leaves an untitled page as
    /// it is and gives a daily note its day back.
    private func commitTitle() {
        isEditingTitle = false
        guard let page, page.isOwn, !page.isTrashed else { return }
        let typed = MobileSpaceListing.cleanedTitle(titleDraft)
        let title = typed ?? DailyNote.dayKey(ofID: page.id).flatMap { DailyNote.title(forDayKey: $0) }
        guard let title, title != page.title else {
            titleDraft = MobileSpacePageTitle.isPlaceholder(page.title) ? "" : page.title
            return
        }
        // A page named by its heading is renamed in the heading too, so the two stay one string.
        if page.isEditableMarkdown, !page.isDailyNote, !page.isPlan { model.retitle(to: title) }
        actions.run("Couldn’t Rename the Page") { try await store.rename(page.id, to: title) }
    }

    /// The page's own words for its name: its opening heading, when the stored title is another string.
    private func adoptHeadingAsTitle(_ page: MobileSpacePage) {
        guard page.isEditableMarkdown, page.isOwn, !page.isTrashed, !page.isDailyNote, !page.isPlan,
              !isEditingTitle, !titleFocused, model.phase == .ready,
              let adopted = MobilePageTitleRule.adoptedTitle(replacing: page.title, heading: model.firstHeading)
        else { return }
        actions.run("Couldn’t Rename the Page") { try await store.rename(page.id, to: adopted) }
    }

    // MARK: The ⋯

    private func pageMenu(_ page: MobileSpacePage) -> some View {
        Menu {
            MobileSpacePageMenuItems(page: page, onRename: beginRename)
            if let dayKey = DailyNote.dayKey(ofID: page.id) {
                Section {
                    if dayKey != DailyNote.dayKey(for: Date()) {
                        Button("Today", systemImage: "calendar") { openDay(DailyNote.dayKey(for: Date())) }
                    }
                    if let previous = MobilePageDays.dayKey(dayKey, offsetBy: -1) {
                        Button("Previous Day", systemImage: "chevron.left") { openDay(previous) }
                    }
                    if let next = MobilePageDays.dayKey(dayKey, offsetBy: 1) {
                        Button("Next Day", systemImage: "chevron.right") { openDay(next) }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Page options")
        .accessibilityIdentifier("page.menu")
    }

    /// Another day's note in this one's place, made when the phone holds none, as the Mac's ‹ and ›.
    private func openDay(_ dayKey: String) {
        actions.run("Couldn’t Open the Daily Note") {
            let note = try await store.ensureDailyNote(dayKey: dayKey)
            navigation.replacePage(pageID, note.id)
        }
    }
}

/// Stepping between daily notes: the day `days` from a day, in the learner's calendar.
enum MobilePageDays {
    static func dayKey(_ dayKey: String, offsetBy days: Int, calendar: Calendar = .current) -> String? {
        guard let date = DailyNote.date(forDayKey: dayKey, calendar: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return DailyNote.dayKey(for: moved, calendar: calendar)
    }
}

/// The quiet line over a subpage: "Parent › Page", each page above a link that opens it, the top left
/// off behind an ellipsis past `PageParents.displayDepthLimit`.
struct MobilePageTrail: View {
    let ancestors: [MobileSpacePage]
    let title: String
    let open: (String) -> Void

    var body: some View {
        let byID = Dictionary(ancestors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let trail = PageParents.trail(ancestors.map(\.id))
        HStack(spacing: 4) {
            if trail.isTruncated {
                Text("…")
                    .foregroundStyle(.tertiary)
                separator
            }
            ForEach(trail.ids, id: \.self) { id in
                if let ancestor = byID[id] {
                    Button {
                        open(id)
                    } label: {
                        Text(MobileSpacePageTitle.display(ancestor))
                            .lineLimit(1)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Opens the page")
                    .accessibilityIdentifier("page.trail.\(id)")
                    separator
                }
            }
            Text(title)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Parent pages")
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.quaternary)
            .accessibilityHidden(true)
    }
}

// MARK: - The text and its saves

/// A page's text on its screen: what the editor was handed (`text`, handed again whenever `textKey`
/// changes), the edits it reports, and the saves they make. A save names the revision the text was
/// opened or last saved at; one the store refuses as `.conflict` is held as `conflict` until the learner
/// answers, and no save is made meanwhile. The model outlives its screen until its last save is
/// written: the editor's final edit arrives as the page closes.
@MainActor
@Observable
final class MobilePageModel {
    enum Phase: Equatable {
        case loading
        case ready
        case notArrived
        case failed(String)
    }

    /// The other device's text a save met, and its revision.
    struct Conflict: Equatable {
        let markdown: String
        let revision: String?
    }

    let pageID: String
    private(set) var phase: Phase = .loading
    private(set) var text = ""
    private(set) var textKey = UUID().uuidString
    private(set) var pictures: [String: String] = [:]
    private(set) var conflict: Conflict?
    private(set) var saveError: String?
    /// The `# ` heading the text opens with, which names the page when it is its title.
    private(set) var firstHeading: String?

    @ObservationIgnored private var store: MobileSpaceStore?
    /// The revision `saved` is: what a save names as `expectedRevision`.
    @ObservationIgnored private var revision: String?
    @ObservationIgnored private var saved = ""
    /// The editor's newest text; nil until it reports an edit.
    @ObservationIgnored private var draft: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var isSaving = false
    @ObservationIgnored private var savesAgain = false

    /// How long after the last edit a save is made, as the Mac's 800 ms, rounded to a beat.
    static let autosaveDelay: Duration = .seconds(1)

    init(pageID: String) {
        self.pageID = pageID
    }

    private var hasUnsavedText: Bool {
        draft.map { $0 != saved } ?? false
    }

    /// Reads the page the first time, again once its text arrives, and again when another device's
    /// save moves its revision while nothing typed here waits to be saved; typing that does wait meets
    /// that save as a conflict when it is written.
    func open(with store: MobileSpaceStore, revision current: String?) async {
        self.store = store
        if phase == .ready {
            guard current != revision, !isSaving, !hasUnsavedText, conflict == nil else { return }
        }
        do {
            let body = try await store.body(of: pageID)
            guard !hasUnsavedText, conflict == nil else { return }
            take(body.markdown, revision: body.revision)
            pictures = body.pictures
            phase = .ready
        } catch MobileSpaceError.notArrived {
            if phase != .ready { phase = .notArrived }
        } catch {
            if phase != .ready { phase = .failed(error.localizedDescription) }
        }
    }

    /// An edit the editor reported: saved a beat after the last one, and at once while the app is
    /// leaving, which may not give it the beat.
    func edited(_ markdown: String) {
        guard phase == .ready else { return }
        draft = markdown
        let heading = MobilePageTitleRule.firstHeading(in: markdown)
        if heading != firstHeading { firstHeading = heading }
        schedule(after: UIApplication.shared.applicationState == .active ? Self.autosaveDelay : .zero)
    }

    /// A rename of a page named by its opening heading, written into the heading: the editor is handed
    /// the new text and it is saved at once, so the title and the heading are one string.
    func retitle(to title: String) {
        guard phase == .ready, let renamed = MobilePageTitleRule.retitling(draft ?? saved, to: title) else { return }
        text = renamed
        draft = renamed
        firstHeading = MobilePageTitleRule.firstHeading(in: renamed)
        textKey = UUID().uuidString
        schedule(after: .zero)
    }

    /// The page closing or the app leaving: what waits is saved now.
    func saveNow() {
        guard hasUnsavedText else { return }
        schedule(after: .zero)
    }

    /// **Use theirs**: the other device's text replaces this phone's, which is not saved.
    func useTheirs() {
        guard let conflict else { return }
        self.conflict = nil
        take(conflict.markdown, revision: conflict.revision)
    }

    /// **Keep mine**: this phone's text is saved over the other device's, named by its revision.
    func keepMine() {
        guard let conflict else { return }
        self.conflict = nil
        revision = conflict.revision
        saved = conflict.markdown
        schedule(after: .zero)
    }

    func editorFailed(_ message: String) {
        phase = .failed(message)
    }

    /// Hands the editor `markdown` as the page's text at `revision`.
    private func take(_ markdown: String, revision: String?) {
        text = markdown
        saved = markdown
        self.revision = revision
        draft = nil
        firstHeading = MobilePageTitleRule.firstHeading(in: markdown)
        textKey = UUID().uuidString
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        // The task holds the model, so a save the closing page asked for is still written.
        pending = Task { [self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await save()
        }
    }

    private func save() async {
        guard let store, phase == .ready, conflict == nil, let draft, draft != saved else { return }
        guard !isSaving else {
            savesAgain = true
            return
        }
        isSaving = true
        let assertion = MobileBackgroundSaveAssertion(name: "ForeverLM page save")
        do {
            let written = try await store.saveBody(draft, of: pageID, expectedRevision: revision)
            revision = written
            saved = draft
            saveError = nil
        } catch MobileSpaceError.conflict(let markdown, let current) {
            conflict = Conflict(markdown: markdown, revision: current)
        } catch {
            saveError = error.localizedDescription
        }
        assertion.end()
        isSaving = false
        if savesAgain || hasUnsavedText {
            savesAgain = false
            if conflict == nil, saveError == nil { schedule(after: .zero) }
        }
    }
}

/// Whether a page's body names it already: the `# ` heading it opens with (the Mac's
/// `ArtifactMarkdownTitle`), read no further than the first line with words on it.
enum MobilePageTitleRule {
    static func firstHeading(in markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.hasPrefix("# ") else { return nil }
            let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : String(title.prefix(500))
        }
        return nil
    }

    /// The title a page takes from its heading: the heading's words when they are not already the
    /// title, character for character (the Mac's `ArtifactMarkdownTitle.adoptedTitle`).
    static func adoptedTitle(replacing title: String, heading: String?) -> String? {
        guard let heading else { return nil }
        return heading == title.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : heading
    }

    /// The text with its opening heading's words replaced by `title`; nil when it has no opening
    /// heading, the title is empty or the heading already says it (the Mac's `retitling`).
    static func retitling(_ markdown: String, to title: String) -> String? {
        let words = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        var lines = markdown.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("# "), !trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Spacing aside, a heading that already says it is left alone (the Mac's `retitling`).
        guard trimmed.dropFirst(2).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") != words else { return nil }
        let renamed = "# \(words)"
        guard lines[index] != renamed else { return nil }
        lines[index] = renamed
        return lines.joined(separator: "\n")
    }
}
