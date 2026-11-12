import SwiftUI

/// The Atlas (docs/atlas-design.md): a topic laid out as a small hierarchy of
/// concepts at levels of abstraction, grounded in the learner's library.
///
/// A place like the Canvas: a center tab with its ×, Open in Other Window
/// under its ⋯, and Open Beside wherever it is opened from. The header holds
/// the topic (with the Atlases made before), the view (Fisheye or Ladder),
/// the level (Gist · Line · Paragraph · Steps; ↑ and ↓ climb it), Lay Out on
/// Canvas, Ask in Chat and the ⋯. The Fisheye draws the focused concept
/// large with its neighbours around it; the Ladder draws the whole
/// hierarchy as an outline. ForeverLM's words about itself are drawn in its
/// ✦ voice; the passages are the library's own words, selectable.
struct AtlasPane: View {
    static let systemImage = "point.3.connected.trianglepath.dotted"

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @FocusState private var keysFocused: Bool
    @FocusState private var topicFieldFocused: Bool
    @Namespace private var namespace
    @State private var confirmsDelete = false

    private var model: AtlasModel { windowState.atlas }

    var body: some View {
        let model = model
        Group {
            if let atlas = model.current {
                VStack(spacing: 0) {
                    header(atlas)
                    if let building = model.building {
                        buildingBanner(building)
                    } else if let error = model.buildError {
                        errorBanner(error)
                    }
                    Divider()
                    content(atlas)
                }
            } else if let building = model.building {
                buildingCard(building)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .studioPaneNameHeader("Atlas")
        .studioCenterTabCloseChrome(for: .atlas)
        .task {
            await vm.refreshAtlasListings()
            await vm.refreshAtlasMemory(for: windowState.atlas)
        }
        .onChange(of: model.focusID) { vm.inWindow(windowState) { vm.deepenAtlasFocusIfNeeded() } }
        .onChange(of: model.level) { vm.inWindow(windowState) { vm.deepenAtlasFocusIfNeeded() } }
        .onChange(of: model.viewMode) { vm.inWindow(windowState) { vm.deepenAtlasFocusIfNeeded() } }
        .onChange(of: model.current?.id) { vm.inWindow(windowState) { vm.deepenAtlasFocusIfNeeded() } }
        .confirmationDialog(
            "Delete this Atlas?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Atlas", role: .destructive) {
                guard let id = model.current?.id else { return }
                Task {
                    do { try await vm.deleteAtlas(id: id) } catch {
                        vm.showToast("Could not delete the Atlas: \(error.localizedDescription)")
                    }
                }
            }
        } message: {
            Text("ForeverLM can lay the topic out again. Cards you made from it stay.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Atlas")
        .accessibilityIdentifier("atlas.pane")
    }

    // MARK: Header

    private func header(_ atlas: Atlas) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                historyButtons
                topicMenu(atlas)
                Spacer(minLength: 8)
                layOutMenu(atlas)
                Button {
                    if let id = model.focusID { vm.requestChatAboutAtlasConcept(id, in: windowState) }
                } label: {
                    Label("Ask in Chat", systemImage: "bubble.left.and.bubble.right")
                        .zoomedSystemFont(size: 12, weight: .medium)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                .help("A fresh chat beside the Atlas with this concept's sources attached")
                .accessibilityIdentifier("atlas.askInChat")
                moreMenu
            }
            HStack(spacing: 10) {
                Picker("View", selection: $model.viewMode) {
                    ForEach(AtlasViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Fisheye: the concept in focus with what surrounds it. Ladder: the whole Atlas as an outline.")
                .accessibilityIdentifier("atlas.viewMode")
                Picker("Level", selection: $model.level) {
                    ForEach(AtlasLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("How much of each concept to read (↑ and ↓)")
                .accessibilityIdentifier("atlas.level")
                Spacer(minLength: 8)
                Text("✦ \(atlas.concepts.count) concepts · \(atlas.groundedConceptCount) in your library")
                    .zoomedSystemFont(size: 11.5)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.disabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var historyButtons: some View {
        HStack(spacing: 0) {
            Button { withAnimation(Self.refocus) { model.goBack() } } label: {
                Image(systemName: "chevron.left")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!model.canGoBack)
            .help("Back to the concept before (⌘[)")
            .accessibilityLabel("Back")
            Button { withAnimation(Self.refocus) { model.goForward() } } label: {
                Image(systemName: "chevron.right")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!model.canGoForward)
            .help("Forward (⌘])")
            .accessibilityLabel("Forward")
        }
    }

    /// The topic, plain: the learner's words. Its menu holds the Atlases made
    /// before and a new one.
    private func topicMenu(_ atlas: Atlas) -> some View {
        Menu {
            Button("New Atlas…") {
                model.clear()
                topicFieldFocused = true
            }
            let others = model.listings.filter { $0.id != atlas.id }
            if !others.isEmpty {
                Divider()
                ForEach(others.prefix(20)) { listing in
                    Button(listing.topic) {
                        vm.task(in: windowState) { await vm.openStoredAtlas(id: listing.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(atlas.topic)
                    .zoomedSystemFont(size: 16, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(minWidth: 80, alignment: .leading)
        .hoverHighlight(cornerRadius: 6, inset: -4)
        .help("Your Atlases")
        .accessibilityIdentifier("atlas.topicMenu")
    }

    private func layOutMenu(_ atlas: Atlas) -> some View {
        let focus = model.focusedConcept
        let branch = focus.flatMap { $0.id == atlas.rootID || atlas.children(of: $0.id).isEmpty ? nil : $0 }
        return Menu {
            Button("The Whole Atlas") {
                vm.task(in: windowState) { await vm.layOutAtlasOnCanvas(branch: nil, in: windowState) }
            }
            Button(branch.map { "\($0.name) and What Is Under It" } ?? "This Branch") {
                guard let branch else { return }
                vm.task(in: windowState) { await vm.layOutAtlasOnCanvas(branch: branch.id, in: windowState) }
            }
            .disabled(branch == nil)
        } label: {
            HStack(spacing: 4) {
                Label("Lay Out on Canvas", systemImage: KnowledgeMap.symbolName)
                    .zoomedSystemFont(size: 12, weight: .medium)
                Image(systemName: "chevron.down")
                    .zoomedSystemFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .hoverHighlight(cornerRadius: 6, inset: -4)
        .help("Show the concepts and their sources as a lens on the Canvas, to keep there or not")
        .accessibilityIdentifier("atlas.layOut")
    }

    private var moreMenu: some View {
        Menu {
            Button("Rebuild", systemImage: "arrow.clockwise") { vm.inWindow(windowState) { vm.rebuildAtlas() } }
                .disabled(model.building != nil)
            OtherWindowMenuItem(.atlas)
            Divider()
            Button("Delete Atlas…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
        } label: {
            RowMoreActionsLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight()
        .help("Atlas actions")
        .accessibilityLabel("Atlas actions")
        .accessibilityIdentifier("atlas.more")
    }

    // MARK: Building, errors and the empty state

    private func buildingText(_ building: AtlasModel.Building) -> String {
        building.stage == .reading ? "Reading your library" : "Writing the concepts"
    }

    private func buildingBanner(_ building: AtlasModel.Building) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("✦ Laying out \(building.topic)… \(buildingText(building))")
                .zoomedSystemFont(size: 12)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.disabled)
            Spacer(minLength: 8)
            Button("Stop") { model.stopBuilding() }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                .accessibilityIdentifier("atlas.stop")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Text("Could not lay it out: \(error)")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.disabled)
            Spacer(minLength: 8)
            Button {
                model.buildError = nil
            } label: {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0, opacity: 0.10))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func buildingCard(_ building: AtlasModel.Building) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("✦ Laying out \(building.topic)…")
                    .zoomedSystemFont(size: 15)
                    .italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.disabled)
            }
            Text(buildingText(building))
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.tertiary)
                .textSelection(.disabled)
            Button("Stop") { model.stopBuilding() }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -6, opacity: 0.10))
                .accessibilityIdentifier("atlas.stop")
        }
        .padding(28)
        .frame(maxWidth: 520)
    }

    private var emptyState: some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What do you want to understand?")
                    .zoomedSystemFont(size: 20, weight: .semibold)
                    .textSelection(.disabled)
                HStack(spacing: 8) {
                    TextField("A field, a mechanism, a question", text: $model.draftTopic)
                        .textFieldStyle(.roundedBorder)
                        .zoomedSystemFont(size: 14)
                        .focused($topicFieldFocused)
                        .onSubmit(buildDraft)
                        .accessibilityIdentifier("atlas.topicField")
                    Button("Build", action: buildDraft)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.draftTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("atlas.build")
                }
                if let error = model.buildError {
                    Text("Could not lay it out: \(error)")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.disabled)
                }
                if !model.listings.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Atlases")
                            .zoomedSystemFont(size: 11, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                            .padding(.bottom, 4)
                        ForEach(model.listings.prefix(12)) { listing in
                            Button {
                                vm.task(in: windowState) { await vm.openStoredAtlas(id: listing.id) }
                            } label: {
                                HStack {
                                    Image(systemName: Self.systemImage)
                                        .foregroundStyle(.secondary)
                                    Text(listing.topic)
                                        .zoomedSystemFont(size: 13)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(listing.updatedAt, format: .dateTime.month(.abbreviated).day())
                                        .zoomedSystemFont(size: 11)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.08))
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { topicFieldFocused = true }
    }

    private func buildDraft() {
        let topic = model.draftTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }
        vm.inWindow(windowState) { vm.buildAtlas(topic: topic) }
    }

    // MARK: Content

    static let refocus = Animation.spring(response: 0.42, dampingFraction: 0.86)

    private func content(_ atlas: Atlas) -> some View {
        Group {
            switch model.viewMode {
            case .fisheye:
                AtlasFisheyeView(atlas: atlas, namespace: namespace, onFocus: refocus)
            case .ladder:
                AtlasLadderView(atlas: atlas, onFocus: refocus)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($keysFocused)
        .onKeyPress(.upArrow) {
            model.climb()
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.descend()
            return .handled
        }
        .onAppear { keysFocused = true }
        .simultaneousGesture(TapGesture().onEnded { keysFocused = true })
    }

    private func refocus(_ id: String) {
        keysFocused = true
        withAnimation(Self.refocus) { model.focus(id) }
    }
}

// MARK: - Shared pieces

/// A concept's memory as a dot: green when its cards hold, amber when some
/// are due, a muted red when some are fading, grey with none.
struct AtlasMemoryDot: View {
    let standing: AtlasMemoryStanding
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Self.color(standing.tone))
            .frame(width: size, height: size)
            .help(standing.line)
            .accessibilityLabel(standing.line)
    }

    static func color(_ tone: AtlasMemoryStanding.Tone) -> Color {
        switch tone {
        case .none: return Color.secondary.opacity(0.35)
        case .solid: return Color.green.opacity(0.85)
        case .due: return Color.orange.opacity(0.9)
        case .fading: return Color(red: 0.78, green: 0.33, blue: 0.30).opacity(0.85)
        }
    }
}

/// A small capsule: a concept's kind or status.
struct AtlasBadge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .zoomedSystemFont(size: 10.5, weight: .medium)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .textSelection(.disabled)
    }

    static func tint(_ status: AtlasConcept.Status) -> Color {
        switch status {
        case .established: return .green
        case .debated: return .orange
        case .speculative: return .purple
        }
    }
}

// MARK: - Fisheye

/// The focused concept large in the middle, at the chosen level, with its
/// terms, its evidence and its memory; broader concepts as a ladder above,
/// narrower ones as cards below, what to know first on the left and what it
/// relates to on the right. Clicking any of them focuses it.
struct AtlasFisheyeView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let atlas: Atlas
    let namespace: Namespace.ID
    let onFocus: (String) -> Void

    private var model: AtlasModel { windowState.atlas }

    var body: some View {
        let focusID = model.focusID ?? atlas.rootID
        let neighbourhood = atlas.neighbourhood(of: focusID)
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    breadcrumb(neighbourhood.broader)
                    if let focus = atlas.concept(focusID) {
                        if proxy.size.width >= 860 {
                            HStack(alignment: .top, spacing: 18) {
                                knowFirst(neighbourhood.knowFirst)
                                    .frame(width: 170, alignment: .leading)
                                AtlasFocusCard(atlas: atlas, concept: focus, namespace: namespace)
                                    .frame(maxWidth: 680)
                                related(neighbourhood.related)
                                    .frame(width: 210, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            knowFirst(neighbourhood.knowFirst)
                            AtlasFocusCard(atlas: atlas, concept: focus, namespace: namespace)
                            related(neighbourhood.related)
                        }
                        narrower(neighbourhood.narrower)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func breadcrumb(_ broader: [AtlasConcept]) -> some View {
        if !broader.isEmpty {
            ChipFlowLayout(spacing: 4) {
                ForEach(Array(broader.enumerated()), id: \.element.id) { index, concept in
                    HStack(spacing: 4) {
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .zoomedSystemFont(size: 9, weight: .semibold)
                                .foregroundStyle(.tertiary)
                        }
                        Button { onFocus(concept.id) } label: {
                            Text(concept.name)
                                .zoomedSystemFont(size: 12, weight: .medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .matchedGeometryEffect(id: concept.id, in: namespace)
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3, opacity: 0.10))
                        .help(concept.line)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Broader")
        }
    }

    @ViewBuilder
    private func knowFirst(_ concepts: [AtlasConcept]) -> some View {
        if !concepts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Know first")
                ChipFlowLayout(spacing: 6) {
                    ForEach(concepts) { concept in
                        Button { onFocus(concept.id) } label: {
                            HStack(spacing: 5) {
                                AtlasMemoryDot(standing: model.memory(of: concept.id), size: 6)
                                Text(concept.name)
                                    .zoomedSystemFont(size: 12)
                                    .lineLimit(2)
                                    .matchedGeometryEffect(id: concept.id, in: namespace)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().strokeBorder(Color.primary.opacity(0.14)))
                        }
                        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.10))
                        .help(concept.line)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func related(_ links: [AtlasNeighbourhood.Link]) -> some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Related")
                ForEach(links) { link in
                    Button { onFocus(link.concept.id) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(link.phrase)
                                .zoomedSystemFont(size: 10.5)
                                .italic()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                AtlasMemoryDot(standing: model.memory(of: link.concept.id), size: 6)
                                Text(link.concept.name)
                                    .zoomedSystemFont(size: 12.5, weight: .medium)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .matchedGeometryEffect(id: link.concept.id, in: namespace)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.08))
                    .help(link.concept.line)
                }
            }
        }
    }

    @ViewBuilder
    private func narrower(_ concepts: [AtlasConcept]) -> some View {
        if !concepts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Narrower")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(concepts) { concept in
                        Button { onFocus(concept.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    AtlasMemoryDot(standing: model.memory(of: concept.id), size: 7)
                                    Text(concept.name)
                                        .zoomedSystemFont(size: 13, weight: .semibold)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .matchedGeometryEffect(id: concept.id, in: namespace)
                                }
                                Text(concept.prose(at: model.level == .gist ? .gist : .line))
                                    .zoomedSystemFont(size: 12)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                if atlas.groundingPassages(of: concept.id).isEmpty {
                                    Text("✦ not in your library yet")
                                        .zoomedSystemFont(size: 11)
                                        .italic()
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(concept.kind.title)\(atlas.children(of: concept.id).isEmpty ? "" : " · \(atlas.children(of: concept.id).count) under it")")
                                    .zoomedSystemFont(size: 10.5)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.035))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 10, inset: 0, opacity: 0.06))
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .zoomedSystemFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .textSelection(.disabled)
    }
}

/// The focused concept: its name, kind and status, its text at the chosen
/// level (deepened on asking), its terms, its evidence with the passages
/// quoted, its open questions, its memory and Learn.
struct AtlasFocusCard: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let atlas: Atlas
    let concept: AtlasConcept
    let namespace: Namespace.ID

    @State private var shownTerm: String?
    @State private var showsAllEvidence = false

    private var model: AtlasModel { windowState.atlas }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .zoomedSystemFont(size: 10)
                        .foregroundStyle(Color.purple.opacity(0.75))
                        .help("Written by ForeverLM from your library")
                        .accessibilityLabel("Written by ForeverLM")
                    AtlasBadge(text: concept.kind.title)
                    AtlasBadge(text: concept.status.title, tint: AtlasBadge.tint(concept.status))
                }
                Text(concept.name)
                    .zoomedSystemFont(size: 22, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
                    .matchedGeometryEffect(id: concept.id, in: namespace)
            }
            prose
            if !concept.terms.isEmpty {
                terms
            }
            evidence
            if !concept.openQuestions.isEmpty {
                openQuestions
            }
            memoryRow
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(concept.name)
    }

    // MARK: Text at the level

    @ViewBuilder
    private var prose: some View {
        let level = model.level
        let isDeepening = model.deepeningID == concept.id
        VStack(alignment: .leading, spacing: 8) {
            switch level {
            case .gist:
                Text(concept.gist)
                    .zoomedSystemFont(size: 16)
                    .fixedSize(horizontal: false, vertical: true)
            case .line:
                Text(concept.line)
                    .zoomedSystemFont(size: 15)
                    .fixedSize(horizontal: false, vertical: true)
            case .paragraph:
                Text(concept.paragraph ?? concept.line)
                    .zoomedSystemFont(size: 14)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            case .steps:
                if let steps = concept.steps, !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)")
                                    .zoomedSystemFont(size: 12, weight: .semibold)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16, alignment: .trailing)
                                Text(step)
                                    .zoomedSystemFont(size: 14)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else {
                    Text(concept.paragraph ?? concept.line)
                        .zoomedSystemFont(size: 14)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isDeepening {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(level == .steps ? "✦ Writing it as steps…" : "✦ Writing the paragraph…")
                        .zoomedSystemFont(size: 12)
                        .italic()
                        .foregroundStyle(.secondary)
                }
                .textSelection(.disabled)
            } else if let error = model.deepenError, error.conceptID == concept.id {
                HStack(spacing: 8) {
                    Text("✦ Could not write more: \(error.message)")
                        .zoomedSystemFont(size: 12)
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") {
                        model.deepenError = nil
                        vm.inWindow(windowState) { vm.deepenAtlasFocusIfNeeded() }
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                }
                .textSelection(.disabled)
            }
        }
        .textSelection(.disabled)
        .animation(.easeOut(duration: 0.2), value: level)
    }

    // MARK: Terms

    private var terms: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Terms")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            ChipFlowLayout(spacing: 6) {
                ForEach(concept.terms, id: \.term) { term in
                    Button {
                        shownTerm = shownTerm == term.term ? nil : term.term
                    } label: {
                        Text(term.term)
                            .zoomedSystemFont(size: 12, weight: .medium)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                    }
                    .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.10))
                    .help(term.definition)
                    .popover(isPresented: Binding(
                        get: { shownTerm == term.term },
                        set: { if !$0, shownTerm == term.term { shownTerm = nil } }
                    ), arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(term.term)
                                .zoomedSystemFont(size: 13, weight: .semibold)
                            Text(term.definition)
                                .zoomedSystemFont(size: 12.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .textSelection(.disabled)
                        .padding(12)
                        .frame(width: 280, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: Evidence

    @ViewBuilder
    private var evidence: some View {
        let entries = atlas.groundingPassages(of: concept.id)
        VStack(alignment: .leading, spacing: 8) {
            Text(entries.isEmpty || atlas.citesItself(concept.id) ? "From your library" : "From your library, under it")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            if entries.isEmpty {
                Text("✦ Not in your library yet")
                    .zoomedSystemFont(size: 12.5)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            } else {
                let shown = showsAllEvidence ? entries : Array(entries.prefix(AtlasLimits.shownEvidence))
                ForEach(shown, id: \.passage.id) { entry in
                    evidenceRow(entry.passage, stance: entry.stance)
                }
                if entries.count > AtlasLimits.shownEvidence {
                    Button(showsAllEvidence ? "Fewer" : "\(entries.count - AtlasLimits.shownEvidence) more") {
                        showsAllEvidence.toggle()
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .zoomedSystemFont(size: 11.5)
                }
            }
        }
    }

    private func evidenceRow(_ passage: AtlasPassage, stance: AtlasEvidence.Stance) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    vm.task(in: windowState) { await vm.openAtlasPassage(passage) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text")
                            .zoomedSystemFont(size: 10.5)
                            .foregroundStyle(.secondary)
                        Text(passage.year.map { "\(passage.title) (\($0))" } ?? passage.title)
                            .zoomedSystemFont(size: 12, weight: .medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3, opacity: 0.10))
                .help("Open it in the Reader at this passage")
                if stance != .supports {
                    AtlasBadge(text: stance.rawValue.capitalized, tint: stance == .contradicts ? .orange : .secondary)
                }
            }
            Text("“\(passage.readableText)”")
                .zoomedSystemFont(size: 12.5)
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: 2)
                }
        }
    }

    // MARK: Open questions

    private var openQuestions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open questions")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            ForEach(concept.openQuestions, id: \.self) { question in
                Text("✦ \(question)")
                    .zoomedSystemFont(size: 12.5)
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.disabled)
    }

    // MARK: Memory and Learn

    private var memoryRow: some View {
        let standing = model.memory(of: concept.id)
        let hasEvidence = !atlas.groundingSourceIDs(of: concept.id).isEmpty
        let isLearning = model.learningID == concept.id
        return HStack(spacing: 8) {
            AtlasMemoryDot(standing: standing, size: 8)
            Text(standing.line)
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            Spacer(minLength: 8)
            if isLearning {
                ProgressView().controlSize(.small)
            }
            Button {
                vm.task(in: windowState) { await vm.learnAtlasConcept(concept.id) }
            } label: {
                Label("Learn", systemImage: "rectangle.stack.badge.plus")
                    .zoomedSystemFont(size: 12, weight: .medium)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
            .disabled(!hasEvidence || isLearning)
            .help(hasEvidence
                ? "Draft cards on this concept and its terms, each quoting its sources, into To Check"
                : "A card quotes a source, and nothing in your library covers this yet")
            .accessibilityIdentifier("atlas.learn")
        }
        .padding(.top, 2)
    }
}

// MARK: - Ladder

/// The whole Atlas as an outline, each row at the chosen level and the
/// focused branch one level deeper: a fisheye in the outline. Selecting a
/// row focuses it; the Fisheye shares the focus.
struct AtlasLadderView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let atlas: Atlas
    let onFocus: (String) -> Void

    private var model: AtlasModel { windowState.atlas }

    var body: some View {
        let focusID = model.focusID ?? atlas.rootID
        let branch = Set(atlas.branch(of: focusID).map(\.id))
        let rows = visibleRows()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.concept.id) { row in
                        ladderRow(row.concept, depth: row.depth, isFocused: row.concept.id == focusID, inBranch: branch.contains(row.concept.id))
                            .id(row.concept.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.focusID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// The outline less the rows under a folded one.
    private func visibleRows() -> [(concept: AtlasConcept, depth: Int)] {
        var hiddenUnder: Int?
        var rows: [(concept: AtlasConcept, depth: Int)] = []
        for row in atlas.outline() {
            if let depth = hiddenUnder {
                if row.depth > depth { continue }
                hiddenUnder = nil
            }
            rows.append(row)
            if model.collapsed.contains(row.concept.id) { hiddenUnder = row.depth }
        }
        return rows
    }

    private func ladderRow(_ concept: AtlasConcept, depth: Int, isFocused: Bool, inBranch: Bool) -> some View {
        let hasChildren = !atlas.children(of: concept.id).isEmpty
        let isCollapsed = model.collapsed.contains(concept.id)
        let level = inBranch ? model.level.deeper : model.level
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if hasChildren {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            if isCollapsed { model.collapsed.remove(concept.id) } else { model.collapsed.insert(concept.id) }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .zoomedSystemFont(size: 10, weight: .semibold)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 4, inset: 0, opacity: 0.10))
                    .help(isCollapsed ? "Show what is under it" : "Fold it")
                    .accessibilityLabel(isCollapsed ? "Expand \(concept.name)" : "Collapse \(concept.name)")
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
            }
            Button { onFocus(concept.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        AtlasMemoryDot(standing: model.memory(of: concept.id), size: 7)
                        Text(concept.name)
                            .zoomedSystemFont(size: depth == 0 ? 15 : 13.5, weight: .semibold)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(concept.kind.title)
                            .zoomedSystemFont(size: 10.5)
                            .foregroundStyle(.tertiary)
                        if concept.status != .established {
                            AtlasBadge(text: concept.status.title, tint: AtlasBadge.tint(concept.status))
                        }
                        if atlas.groundingPassages(of: concept.id).isEmpty {
                            Text("✦ not in your library yet")
                                .zoomedSystemFont(size: 10.5)
                                .italic()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(concept.prose(at: level))
                        .zoomedSystemFont(size: 12.5)
                        .foregroundStyle(isFocused ? .primary : .secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if isFocused, model.deepeningID == concept.id {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(level == .steps ? "✦ Writing it as steps…" : "✦ Writing the paragraph…")
                                .zoomedSystemFont(size: 11.5)
                                .italic()
                                .foregroundStyle(.secondary)
                        }
                    } else if isFocused, let error = model.deepenError, error.conceptID == concept.id {
                        Text("✦ Could not write more: \(error.message)")
                            .zoomedSystemFont(size: 11.5)
                            .italic()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isFocused ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: isFocused ? 0.04 : 0.06))
            .accessibilityAddTraits(isFocused ? .isSelected : [])
        }
        .padding(.leading, CGFloat(depth) * 20)
        .textSelection(.disabled)
    }
}
