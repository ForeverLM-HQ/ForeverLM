// ArtifactCanvas: the Docs list, the home and the selection bookkeeping.

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension ArtifactCanvas {
    var artifactList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .zoomedSystemFont(size: 10, weight: .medium)
                    .foregroundStyle(.tertiary)
                TextField("Search \(section.pluralNoun)", text: $searchText)
                    .textFieldStyle(.plain)
                    .zoomedSystemFont(size: 11)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.hoverWash(in: Circle(), inset: -3))
                    .help("Clear search")
                }
                if section == .animations {
                    animateSourceButton
                }
                // The list's collapse control lives on the list, at its inner
                // edge beside the search field, the way a side panel is
                // closed from inside itself rather than from the pane title.
                StudioChromeIconButton(
                    systemImage: "sidebar.leading",
                    label: "Hide \(section.pluralNoun) list"
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isArtifactListVisible = false
                    }
                }
                .padding(.trailing, -6)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(visibleArtifacts) { artifact in
                        Button {
                            select(artifact)
                            // In a pane that only holds one column, choosing a
                            // doc is the gesture that asks for the page.
                            if !listFitsBesideDocument {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    isArtifactListVisible = false
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    // A linked page is named as one in two
                                    // places — the glyph here and the caption
                                    // below — so it never blends in with a doc
                                    // the writer can edit in place.
                                    artifactKindIcon(for: artifact, height: 11)
                                    Text(artifact.title)
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                    teamMembershipBadge(for: artifact)
                                    if artifact.isDraft || vm.teamDocDraftID(for: artifact.id) != nil {
                                        Text("Draft")
                                            .zoomedSystemFont(size: 8, weight: .semibold)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.primary.opacity(0.07),
                                                in: Capsule()
                                            )
                                            .accessibilityLabel("Draft document")
                                    }
                                    if artifact.isArchived {
                                        Text("Archived")
                                            .zoomedSystemFont(size: 8, weight: .semibold)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.primary.opacity(0.07),
                                                in: Capsule()
                                            )
                                            .accessibilityLabel("Archived")
                                    }
                                    if artifact.isHidden {
                                        Text("Hidden")
                                            .zoomedSystemFont(size: 8, weight: .semibold)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.primary.opacity(0.07),
                                                in: Capsule()
                                            )
                                            .accessibilityLabel("Hidden")
                                    }
                                    if publishedStatuses[artifact.id] != nil {
                                        Text("Published")
                                            .zoomedSystemFont(size: 8, weight: .semibold)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.primary.opacity(0.07),
                                                in: Capsule()
                                            )
                                            .accessibilityLabel("Published document")
                                    }
                                }
                                Text(docListDetail(for: artifact))
                                    .lineLimit(1)
                                    .zoomedSystemFont(size: 9)
                                    .foregroundStyle(.tertiary)
                            }
                            .zoomedSystemFont(size: 11)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                selectedArtifactID == artifact.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
                        .contextMenu {
                            docActions(for: artifact)
                        }
                        // The row drags the doc as well as the pane: dropped on
                        // the center edge it opens Docs beside showing this doc,
                        // dropped on a chat it joins that chat's context, dropped
                        // on the open doc's page it is written there as a link.
                        // The row must not select itself as the drag begins:
                        // the editor is keyed on the selection, so that swapped
                        // the open doc for the dragged one under the pointer and
                        // the drop landed on itself, which writes nothing. The
                        // edge split reveals the dragged doc when it lands.
                        .onDrag {
                            StudioDragVisibility.shared.begin(centerTab: section.centerTab, artifactID: artifact.id)
                            return studioArtifactDragProvider(for: artifact)
                        }
                    }

                    if visibleArtifacts.isEmpty {
                        ContentUnavailableView("No matching \(section.pluralNoun)", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    }
                }
                .padding(7)
                // The space under the rows takes the whole height, so a
                // right-click anywhere in the list that is not a row offers
                // the same two ways in that the header buttons do. A row's own
                // context menu still wins over it.
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .contextMenu {
                    addDocMenuItems
                }
            }
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    // MARK: - Docs home

    /// A doc's actions, shared by its row in the list and its card on the
    /// home so the two never drift apart.
    @ViewBuilder
    func docActions(for artifact: ArtifactRecord) -> some View {
        // An animation with a walkthrough is walked through in the chat
        // beside it, one step a turn, the page following each step
        // (walkthrough-design.md, "Animations are walked through").
        if artifact.isAnimation, vm.artifactIDsWithWalkthroughs.contains(artifact.id) {
            Button("Walk Through", systemImage: "figure.walk") {
                selectedArtifactID = artifact.id
                vm.requestWalkthroughPlayback(forAnimation: artifact.id)
            }
            .accessibilityIdentifier("animations.walkThrough")
            Divider()
        }
        if !artifact.namesItself {
            Button("Rename…", systemImage: "pencil") {
                artifactRenameDraft = artifact.title
                artifactToRename = artifact
            }
        }
        // The name as the row shows it, for pasting into a chat or a message
        // (product owner, 2026-09-10: "give me a right click copy name of a site").
        Button("Copy Name", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(artifact.title, forType: .string)
            vm.showToast("Name copied")
        }
        // Draft is a state of something written here; a site is not written
        // here, so it is neither a draft nor production, and a mnemonic
        // reading is written by its writer.
        if section == .docs, !artifact.isMnemonicReading {
            Button(
                artifact.isDraft ? "Mark as Production" : "Mark as Draft",
                systemImage: artifact.isDraft ? "checkmark.seal" : "pencil.line"
            ) {
                Task {
                    await vm.updateArtifact(
                        artifactID: artifact.id,
                        isDraft: !artifact.isDraft
                    )
                }
            }
        }
        // Put away, not thrown away: the record keeps its body, its page and
        // its Notebook links and only leaves the list (product owner, 2026-09-10:
        // "allow me to archive sites"). For a page or a site the put-away
        // place is the Space's Trash since 2026-10-06, so Move to Trash below
        // is the one way there and Restore the way back; an animation keeps
        // Archive, having no Trash to be found in.
        if artifact.isArchived {
            Button("Restore \(section.noun.capitalized)", systemImage: "arrow.uturn.backward") {
                Task { await vm.restoreArtifactFromTrash(artifact.id) }
            }
        } else if section == .animations {
            Button("Archive \(section.noun.capitalized)", systemImage: "archivebox") {
                closeIfOpen(artifact)
                Task { await vm.updateArtifact(artifactID: artifact.id, isArchived: true) }
            }
        }
        // Hide is the learner's view, where Archive is the record's state
        // (product owner, 2026-09-11: "allow me to hide docs also; and sites as
        // well"). Nothing about the record moves — not its date, its team
        // copies or its page; the hide syncs as a record of its own, so every
        // Mac of the learner's hides it and no teammate does. The Hidden
        // filter is the one place it is listed again, with Show on the same
        // menu.
        if artifact.isHidden {
            Button("Show \(section.noun.capitalized)", systemImage: "eye") {
                Task { await vm.setArtifactHidden(artifactID: artifact.id, isHidden: false) }
            }
        } else {
            Button("Hide \(section.noun.capitalized)", systemImage: "eye.slash") {
                closeIfOpen(artifact)
                Task { await vm.setArtifactHidden(artifactID: artifact.id, isHidden: true) }
            }
        }
        ArtifactNotebooksMenu(artifact: artifact)
        KnowledgeMapAddToCanvasMenu(refs: ["doc:\(artifact.id)"])
        KnowledgeMapOnCanvasesSection(ref: "doc:\(artifact.id)", windowState: windowState)
        ShareWithTeamMenu { teamID in
            Task { await vm.shareArtifact(artifact.id, withTeam: teamID) }
        }
        AssignToMemberMenu { member in
            Task { await vm.assign(artifactID: artifact.id, to: member) }
        }
        Divider()
        // A site kept in the library has no web address to open.
        if LinkedPage.localSiteID(fromURLString: artifact.linkedURL) == nil {
            if let linkedURL = artifact.linkedURL, let url = URL(string: linkedURL) {
                Button("Open in Browser", systemImage: "safari") {
                    NSWorkspace.shared.open(url)
                }
            } else if !artifact.isMnemonicReading {
                Button("Convert to Google Doc…", systemImage: LinkedGoogleDoc.symbolName) {
                    artifactToConvert = artifact
                }
            }
        }
        Button("Add to Chat", systemImage: "message") {
            Task { await vm.attachDocToChat(artifact.id) }
        }
        Button("Open Beside", systemImage: "rectangle.split.2x1") {
            selectedArtifactID = artifact.id
            vm.placeCenterTabAtEdge(section.centerTab, leading: false)
        }
        // Where a click on the row goes: a team's record listed in My
        // Library opens through its team's library (`select(_:)`).
        OpenStudioDestinationInOtherWindowMenu(
            destination: vm.activeTeamID == nil && artifact.teamID != nil
                ? .teamArtifact(artifact.id)
                : .doc(artifact.id),
            currentWindowState: windowState,
            openNewWindow: { openWindow(id: "studio") }
        )
        Divider()
        if artifact.isArchived, section != .animations {
            Button("Delete Forever…", systemImage: "trash", role: .destructive) {
                artifactToDelete = artifact
            }
        } else {
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                trash(artifact)
            }
        }
    }

    func commitArtifactRename() {
        guard let artifact = artifactToRename else { return }
        let title = artifactRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        artifactToRename = nil
        guard title != artifact.title else { return }
        Task { await vm.updateArtifact(artifactID: artifact.id, title: title) }
    }

    /// Putting the open record away — archiving or hiding it — closes it onto
    /// the index, since the list beside it no longer shows it.
    func closeIfOpen(_ artifact: ArtifactRecord) {
        guard selectedArtifactID == artifact.id else { return }
        if notebookID == nil {
            selectedArtifactID = nil
            isShowingIndex = true
        } else {
            // A Notebook's canvas has no index: the next doc in the list takes
            // the pane, or the placeholder does.
            selectedArtifactID = visibleArtifacts.first { $0.id != artifact.id }?.id
        }
    }

    /// The home's entries: the search, then the filter, in the side list's
    /// order — newest created first, so an edit moves a card no more than it
    /// moves a row.
    private var homeArtifacts: [ArtifactRecord] {
        let filtered: [ArtifactRecord]
        switch homeFilter {
        case .all: filtered = visibleArtifacts
        case .published: filtered = visibleArtifacts.filter { publishedStatuses[$0.id] != nil }
        // ForeverLM's own: a site made here (`save_site`).
        case .foreverlmPages: filtered = visibleArtifacts.filter { $0.linkedKind == .foreverlmSite }
        case .drafts: filtered = visibleArtifacts.filter { $0.isDraft || vm.teamDocDraftID(for: $0.id) != nil }
        case .claudeArtifacts: filtered = visibleArtifacts.filter { $0.linkedKind == .claudeArtifact }
        case .codexSites: filtered = visibleArtifacts.filter { $0.linkedKind == .codexSite }
        // `visibleArtifacts` is already the archived, or the hidden, set under
        // these filters.
        case .archived, .hidden: filtered = visibleArtifacts
        }
        return filtered
    }

    /// The Docs home: what the rail's Docs row lands on. A gallery in the shape
    /// Claude's Artifacts and Codex's Sites pages take (product owner, 2026-09-08):
    /// the surface's name and one line on what it is for; the filters, the
    /// search and the one prominent way to make a new doc on a row; the docs
    /// as cards, newest first; and, with nothing written yet, an illustration,
    /// a question and the same button. The side list a doc opens with is
    /// unchanged — this is the place with no doc open.
    var artifactHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                homeControls

                if homeArtifacts.isEmpty {
                    homeEmptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 56)
                        .padding(.bottom, 32)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(homeArtifacts) { artifact in
                            homeCard(for: artifact)
                        }
                    }
                    .padding(.top, 18)
                }
            }
            // The Space's column (`spacePlaceColumn`), less the margin the
            // workspace already draws around this home.
            .padding(.horizontal, SpacePlaceMetrics.horizontalPadding - StudioDesign.Metrics.pageMargin)
            .padding(.top, SpacePlaceMetrics.topPadding - 14)
            .padding(.bottom, SpacePlaceMetrics.bottomPadding - 12)
            .frame(maxWidth: SpacePlaceMetrics.maxWidth - 2 * StudioDesign.Metrics.pageMargin, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title) home")
    }

    /// The Space's head (`SpacePlaceHeader`): the name, the search and the one
    /// prominent way in, then the filters as the Space's scope pills.
    /// Teammates' requests for sources this library holds are answered in the
    /// strip's bell, the one inbox (2026-10-13), not here.
    private var homeControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            SpacePlaceHeader(searchText: $searchText, searchIdentifier: "artifacts.home.search") {
                SpacePlaceTitle(title: notebookID.flatMap { vm.notebook(id: $0)?.title } ?? section.title)
            } actions: {
                homeNewDocButton
            }
            homeFilterChips
        }
    }

    /// The chips keep their words whole: a pane narrower than the row scrolls
    /// it sideways rather than breaking "Published" into syllables stacked
    /// five lines tall, which is what a squeezed HStack of Texts did in a
    /// three-pane window once Hidden made the row five and six chips long.
    private var homeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(ArtifactHomeFilter.cases(for: section, notebookScoped: notebookID != nil)) { filter in
                    SpaceScopePill(title: filter.title, isSelected: homeFilter == filter) {
                        homeFilter = filter
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The one prominent way in, as the Space's dark pill: New Page on the
    /// Pages home, Link a Site… on the Sites home, where nothing is written
    /// and every entry is a link, and the animation chat on Animations.
    @ViewBuilder
    private var homeNewDocButton: some View {
        switch section {
        case .docs:
            SpaceDarkPillButton(
                title: "New Page",
                systemImage: nil,
                image: nil,
                shortcut: KeyboardShortcut("n", modifiers: [.command, .shift])
            ) {
                beginCreation()
            }
            .help("Start a new page")
        case .sites:
            SpaceDarkPillButton(title: section.linkActionTitle, systemImage: nil, image: nil) {
                isLinkingPage = true
            }
            .help("Link a Codex site or a Claude artifact from its address")
        case .animations:
            // An animation is made in a chat, not linked: the button opens
            // one with the request typed, and the learner names the source.
            SpaceDarkPillButton(title: section.linkActionTitle, systemImage: nil, image: nil) {
                vm.requestAnimationChat()
            }
            .help("Ask the chat for an animation of how something in a source works")
        }
    }

    /// One doc on the home: its title, where it lives or where it is
    /// published, what it is (Draft, Published, a Google Doc, a team's copy)
    /// and when it last changed. The same drag, actions and destination as
    /// its row in the list.
    private func homeCard(for artifact: ArtifactRecord) -> some View {
        let published = publishedStatuses[artifact.id]
        let teams = vm.activeTeamID == nil ? (sharingTeamsByArtifactID[artifact.id] ?? []) : []
        return Button {
            if vm.activeTeamID == nil, artifact.teamID != nil {
                Task { await vm.openTeamArtifact(artifact.id) }
                return
            }
            selectedArtifactID = artifact.id
            if !listFitsBesideDocument {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isArtifactListVisible = false
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    artifactKindIcon(for: artifact, height: 13)
                    Text(artifact.title)
                        .zoomedSystemFont(size: 15, weight: .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(published.map { "foreverlm.com/share/\($0.slug)" } ?? notebookLabel(for: artifact))
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if artifact.isDraft || vm.teamDocDraftID(for: artifact.id) != nil {
                        homeBadge("Draft")
                    }
                    if artifact.isArchived {
                        homeBadge("Archived", systemImage: "archivebox")
                    }
                    if artifact.isHidden {
                        homeBadge("Hidden", systemImage: "eye.slash")
                    }
                    if published != nil {
                        homeBadge(published?.isProtected == true ? "Published · shared" : "Published")
                    }
                    ForEach(teams) { team in
                        homeBadge(team.name, systemImage: "person.2")
                    }
                    Spacer(minLength: 0)
                    Text("\(section == .docs ? "Edited" : "Updated") \(artifact.updatedAt.formatted(.dateTime.month(.abbreviated).day()))")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.top, 12)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0))
        .accessibilityLabel(artifact.title)
        .contextMenu {
            docActions(for: artifact)
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: section.centerTab, artifactID: artifact.id)
            return studioArtifactDragProvider(for: artifact)
        }
    }

    private func homeBadge(_ title: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .zoomedSystemFont(size: 8, weight: .semibold)
            }
            Text(title)
                .zoomedSystemFont(size: 9, weight: .semibold)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    /// Nothing to show: either the library has no docs yet, which gets the
    /// illustration and the question, or the search and filter left none,
    /// which says so quietly. The blank slate asks about the whole library,
    /// not the filter: an empty Archived or Hidden filter over a full library
    /// says "Nothing archived" / "Nothing hidden", never "What will you write?".
    @ViewBuilder
    private var homeEmptyState: some View {
        let libraryIsEmpty = !artifacts.contains {
            !TeamContentIdentity.isDraftArtifactID($0.id) && !DailyNote.isDailyNoteID($0.id)
        }
        if libraryIsEmpty && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch section {
            case .docs:
                VStack(spacing: 14) {
                    homeIllustration
                    Text("What will you write?")
                        .zoomedSystemFont(size: 15, weight: .semibold)
                    Text("A page starts out empty. Cite the sources you are reading as you go, ask the AI to draft or revise a passage, publish it on foreverlm.com, or share it with a team that edits it with you.")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    HStack(spacing: 10) {
                        SpaceDarkPillButton(title: "New Page", systemImage: nil, image: nil) { beginCreation() }
                        Button(section.linkActionTitle) { isLinkingPage = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            case .sites:
                VStack(spacing: 14) {
                    sitesIllustration
                    Text("Bring your pages here")
                        .zoomedSystemFont(size: 15, weight: .semibold)
                    Text("A page you publish from Pages appears here as it reads on foreverlm.com. A Codex site or a Claude artifact opens here as itself, with a read-only text copy that chat and review can read; paste its link to start, and the site or artifact itself stays where it is.")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    SpaceDarkPillButton(title: section.linkActionTitle, systemImage: nil, image: nil) { isLinkingPage = true }
                        .padding(.top, 2)
                }
            case .animations:
                VStack(spacing: 14) {
                    Image(systemName: ArtifactKind.animation.symbolName)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .accessibilityHidden(true)
                    Text("See how it works")
                        .zoomedSystemFont(size: 15, weight: .semibold)
                    Text("Ask a chat about a paper to animate its mechanism — the steps of a pathway, where each happens, with and without the intervention — and it draws one that plays here, linked to the paper. Claude and Codex can save one too, through the ForeverLM plugin.")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    SpaceDarkPillButton(title: section.linkActionTitle, systemImage: nil, image: nil) {
                        vm.requestAnimationChat()
                    }
                    .padding(.top, 2)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: searchText.isEmpty ? homeFilter.emptySymbol : "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(searchText.isEmpty ? homeFilter.emptyTitle : "No matching \(section.pluralNoun)")
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Line art in the same monochrome as the doc's: a browser window with a
    /// title bar and a page inside, and a link ring at its corner.
    private var sitesIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(lineWidth: 1.5)
                .frame(width: 68, height: 52)
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 3) {
                            Circle().frame(width: 3.5, height: 3.5)
                            Circle().frame(width: 3.5, height: 3.5)
                            Circle().frame(width: 3.5, height: 3.5)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Rectangle().frame(height: 1.5)
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().frame(width: 30, height: 1.5)
                            Capsule().frame(width: 22, height: 1.5)
                            Capsule().frame(width: 26, height: 1.5)
                        }
                        .padding(9)
                    }
                }
                .offset(x: -8, y: 0)
            Image(systemName: "link")
                .font(.system(size: 22, weight: .light))
                .padding(7)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(lineWidth: 1.5))
                .offset(x: 30, y: 22)
        }
        .frame(width: 104, height: 104)
        .foregroundStyle(Color.primary.opacity(0.7))
        .accessibilityHidden(true)
    }

    /// Line art in the doc's own monochrome: a page, a circle and a pencil.
    /// Accent colour stays reserved for content.
    private var homeIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(lineWidth: 1.5)
                .frame(width: 44, height: 56)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().frame(width: 22, height: 1.5)
                        Capsule().frame(width: 16, height: 1.5)
                        Capsule().frame(width: 20, height: 1.5)
                    }
                    .padding(9)
                }
                .offset(x: -16, y: 6)
            Circle()
                .strokeBorder(lineWidth: 1.5)
                .frame(width: 40, height: 40)
                .offset(x: 18, y: 16)
            Image(systemName: "pencil")
                .font(.system(size: 30, weight: .light))
                .rotationEffect(.degrees(-10))
                .offset(x: 20, y: -18)
        }
        .frame(width: 104, height: 104)
        .foregroundStyle(Color.primary.opacity(0.7))
        .accessibilityHidden(true)
    }

    /// The glyph before a linked record's title: the product's mark for a
    /// linked page, the animation glyph for an animation — which is kept as
    /// a ForeverLM site and would otherwise carry the site's mark — and
    /// nothing for a Markdown doc.
    @ViewBuilder
    func artifactKindIcon(for artifact: ArtifactRecord, height: CGFloat) -> some View {
        if artifact.isAnimation {
            Image(systemName: ArtifactKind.animation.symbolName)
                .font(.system(size: height, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel(ArtifactKind.animation.label)
        } else if let kind = artifact.linkedKind {
            LinkedPageIcon(kind: kind, height: height)
        }
    }

    private func notebookLabel(for artifact: ArtifactRecord) -> String {
        // What kind of thing the row is outranks where it is filed: a linked
        // page says which where another row says its Notebook, and an
        // animation says so rather than naming the site it is hosted as.
        if artifact.isLinked { return artifact.kindLabel ?? "Linked page" }
        if notebookID != nil { return "Edited" }
        let names = artifact.linkedNotebookIDs.compactMap { vm.notebook(id: $0)?.title }
        if names.isEmpty { return "Unfiled" }
        return names.joined(separator: ", ")
    }

    private func docListDetail(for artifact: ArtifactRecord) -> String {
        if let status = publishedStatuses[artifact.id] {
            return "foreverlm.com/share/\(status.slug)"
        }
        return notebookLabel(for: artifact)
    }

    func publishedStatusBinding(for artifactID: String) -> Binding<PublishedDocStatus?> {
        Binding(
            get: { vm.publishedDocStatuses[artifactID] },
            set: { status in vm.publishedDocStatuses[artifactID] = status }
        )
    }

    func beginCreation(inPageSpace pageSpaceID: String? = nil) {
        Task {
            do {
                let snapshot = try await vm.createArtifact(
                    title: ArtifactPlaceholderTitle.current,
                    homeNotebookID: notebookID,
                    linkedNotebookIDs: notebookID.map { [$0] } ?? [],
                    pageSpaceID: pageSpaceID
                )
                searchText = ""
                selectedArtifactID = snapshot.artifact.id
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }

    /// A canvas with no valid selection comes back to the doc this window
    /// last showed, if it lists it, before falling back to the first doc. The
    /// selection is view state and a pane rebuild — a layout change, a tab
    /// swap, the saved layout being applied at launch — makes a fresh canvas;
    /// without this the doc that was open would give way to whichever is first.
    /// Opens the record a card asked for before this canvas could list it.
    /// Clicking an Animation's card on the Artifacts home (an animation is a
    /// row of its notebook's Studio since 2026-10-06) made this canvas and
    /// asked for the record in one motion, but the canvas's list was still
    /// loading when `task` looked, so the request was never answered and the
    /// pane said "Select an animation" (seen filming, 2026-09-24). The list
    /// arriving is heard here as well (`reconcileSelection`).
    func answerRevealRequestIfListed() {
        guard let request = vm.artifactRevealRequest,
              request.windowID == windowState.id,
              request.section == section,
              answers(paneOf: request.groupID),
              artifacts.contains(where: { $0.id == request.artifactID }) else { return }
        vm.artifactRevealRequest = nil
        searchText = ""
        isShowingIndex = false
        selectedArtifactID = request.artifactID
        pendingBlockReveal = request.block.map { ArtifactBlockRevealRequest(artifactID: request.artifactID, reveal: $0) }
    }

    /// A doc this window asked this canvas for that it has not opened yet.
    var isAwaitingRevealedArtifact: Bool {
        guard let request = vm.artifactRevealRequest else { return false }
        return request.windowID == windowState.id && request.section == section
            && answers(paneOf: request.groupID)
    }

    /// The canvas's first answer, given before its first frame rather than
    /// after `task`'s reload. A doc clicked in the sidebar or on the Artifacts
    /// home makes this canvas and asks for the doc in one motion, and the
    /// library is almost always loaded already; waiting on the reload — the
    /// shared-doc CloudKit round trip included — left the pane saying "Select
    /// a doc" in the meantime (product owner, 2026-09-29).
    func answerRequestsBeforeLoad() {
        answerRevealRequestIfListed()
        openPendingArtifactIfNeeded()
        showIndexIfRequested()
        // A doc asked for but not listed yet is still coming; opening the
        // remembered one meanwhile would flash a doc nobody chose. `task`
        // answers once the reload lands.
        guard !isAwaitingRevealedArtifact, windowState.pendingArtifactID == nil else { return }
        reconcileSelection()
        if selectedArtifactID != nil || isShowingIndex { hasSettledSelection = true }
    }

    func reconcileSelection() {
        answerRevealRequestIfListed()
        if let selectedArtifactID, artifacts.contains(where: { $0.id == selectedArtifactID }) { return }
        // The open record changed section under the pane — published from
        // Docs, unpublished or unlinked from Sites — and is still in the
        // library: follow it to its new pane rather than swapping in whatever
        // is first here. Only the global canvases: a Notebook's Docs lists its
        // published docs too.
        if let selectedArtifactID, notebookID == nil,
           vm.artifacts.contains(where: { $0.id == selectedArtifactID }) {
            vm.revealArtifact(selectedArtifactID)
            self.selectedArtifactID = nil
            return
        }
        // The index has no open doc by design; it is not a selection to repair.
        if isShowingIndex {
            selectedArtifactID = nil
            return
        }
        if let remembered = windowState.openArtifactID,
           artifacts.contains(where: { $0.id == remembered }) {
            selectedArtifactID = remembered
            return
        }
        // Whatever is first on the list as shown — never an archived or a
        // hidden record the list is keeping out of sight, nor a daily note,
        // which is reached by its day, nor a record this canvas does not list.
        selectedArtifactID = visibleArtifacts.first?.id
            ?? artifacts.first { !$0.isArchived && !$0.isHidden && !DailyNote.isDailyNoteID($0.id) && listsHere($0) }?.id
    }

    /// Answers the rail's Docs or Sites row with the index. Only the global
    /// canvas of the row's section does: a Notebook's own Docs list is a
    /// different place, and the row always opens the global one
    /// (`openNotepadInReader` clears the scope). And only the canvas in the
    /// window the row was clicked in: a doc open in another window stays.
    func showIndexIfRequested() {
        guard notebookID == nil,
              let request = vm.artifactIndexRequest,
              request.windowID == windowState.id,
              request.section == section,
              answers(paneOf: request.groupID) else { return }
        vm.artifactIndexRequest = nil
        searchText = ""
        // The Space shows the section's own place: Pages, or Sites.
        let place: SpaceDestination = section == .sites ? .sites : .pages
        if windowState.spaceDestinationKey != place.key { windowState.spaceDestinationKey = place.key }
        isShowingIndex = true
        selectedArtifactID = nil
    }

    /// Selects the doc a resume left waiting, if this canvas lists it. A
    /// Notebook-scoped canvas that does not leaves the request standing for
    /// the global one, which does.
    func openPendingArtifactIfNeeded() {
        guard let artifactID = windowState.pendingArtifactID,
              artifacts.contains(where: { $0.id == artifactID }) else { return }
        windowState.pendingArtifactID = nil
        searchText = ""
        selectedArtifactID = artifactID
    }
}
