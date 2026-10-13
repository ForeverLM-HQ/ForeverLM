import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Skills, in the Plugins place

/// The Skills tab of the Plugins place, as Codex has Skills beside Plugins
/// (`skills.appsPage.browseTabs`, `skills.page.*`): the learner's chat skills
/// by name, a search over their names and descriptions, and a page for each
/// (`SkillPage`). A skill is instructions the learner wrote for one kind of
/// work in the shape of a `SKILL.md` (`SkillRecord`); the chat offers each as
/// `/name` and `$name` and uses it on its own when a request matches its
/// description (docs/chat-design.md, "Skills"). Until this list, skills had
/// no window of their own: only MCP's `save_skill` wrote them.
///
/// The list reads `SkillLibrary`, which reads the store again when a skill is
/// written here, over MCP or on the other Mac.
struct SkillsListView: View {
    @Environment(StudioViewModel.self) private var vm
    let query: String
    let go: (PluginsPlaceLocation) -> Void
    @State private var pendingDeletion: SkillRecord?

    var body: some View {
        let library = SkillLibrary.shared
        let rows = SkillsDirectory.rows(library.skills, query: query)
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            if !library.hasLoaded {
                ProgressView("Loading skills…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.top, SpacePlaceMetrics.emptyTopPadding - StudioDesign.Spacing.xLarge)
            } else if let error = library.loadError, library.skills.isEmpty {
                SpaceEmptyLine(systemImage: "exclamationmark.circle", text: "Skills could not be read. \(error)")
                    .frame(maxWidth: .infinity)
                    .padding(.top, SpacePlaceMetrics.emptyTopPadding - StudioDesign.Spacing.xLarge)
            } else if library.skills.isEmpty {
                emptyState
            } else if rows.isEmpty {
                SpaceEmptyLine(systemImage: "magnifyingglass", text: "No results for “\(words)”")
                    .frame(maxWidth: .infinity)
                    .padding(.top, SpacePlaceMetrics.emptyTopPadding - StudioDesign.Spacing.xLarge)
            } else {
                Text("Your Skills")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                ForEach(rows) { skill in
                    SkillRow(skill: skill, go: go) { pendingDeletion = skill }
                }
            }
        }
        .task { await SkillLibrary.shared.loadIfNeeded() }
        .skillDeletionDialog(pending: $pendingDeletion, vm: vm, after: {})
    }

    /// No skills yet: what one is, and New Skill again.
    private var emptyState: some View {
        VStack(spacing: StudioDesign.Spacing.medium) {
            SpaceEmptyLine(systemImage: "wand.and.stars", text: "No skills yet")
            Text("A skill is instructions for one kind of work. Type /name or $name in a chat to use it, and the chat uses it on its own when a request matches what it is for.")
                .zoomedSystemFont(size: 12.5)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            SpaceDarkPillButton(title: "New Skill", systemImage: "plus", image: nil) { go(.newSkill) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, SpacePlaceMetrics.emptyTopPadding - StudioDesign.Spacing.xLarge)
    }
}

/// One skill in the list: its name and description, a click to its page,
/// and Codex's card actions in the ⋯ and on a right-click.
private struct SkillRow: View {
    @Environment(StudioViewModel.self) private var vm
    let skill: SkillRecord
    let go: (PluginsPlaceLocation) -> Void
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button { go(.skill(skill.id)) } label: {
            PluginPickerRow(title: skill.name, subtitle: skill.description, status: nil, reservesMenuSpace: true) {
                SkillGlyph()
            }
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 18, inset: 0)
        .overlay(alignment: .trailing) {
            Menu {
                SkillMenuItems(skill: skill, open: { go(.skill(skill.id)) }, delete: delete)
            } label: {
                Image(systemName: "ellipsis")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .opacity(isHovering ? 1 : 0)
            .padding(.trailing, 40)
            .accessibilityLabel("More actions for \(skill.name)")
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            SkillMenuItems(skill: skill, open: { go(.skill(skill.id)) }, delete: delete)
        }
        .accessibilityIdentifier("skills.row.\(skill.name)")
    }
}

/// A skill's actions, the same in its row's ⋯, its right-click and its
/// page's ⋯ (Codex's `skills.card.*`): Open, Open in Other Window, Copy Link,
/// Copy Markdown (the `SKILL.md` Claude, Codex and the Gemini CLI read), and
/// Delete, which asks first.
private struct SkillMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    let skill: SkillRecord
    /// nil on the skill's own page, which is already open.
    let open: (() -> Void)?
    let delete: () -> Void

    var body: some View {
        if let open {
            Button("Open", action: open)
        }
        OtherWindowMenuItem(.plugins(.skill(skill.id)))
        Divider()
        Button("Copy Link") { PluginsPlace.copy(.skills(name: skill.name), vm: vm) }
        Button("Copy Markdown") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(skill.skillMarkdown, forType: .string)
            vm.showToast("Copied /\(skill.name) as a SKILL.md.")
        }
        Divider()
        Button("Delete…", role: .destructive, action: delete)
    }
}

/// A skill's tile: the wand the chat's skill tools wear.
private struct SkillGlyph: View {
    var body: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

private extension View {
    /// Delete a skill, asked first: chats that used it keep what they were
    /// told, and nothing brings it back.
    func skillDeletionDialog(pending: Binding<SkillRecord?>, vm: StudioViewModel, after: @escaping () -> Void) -> some View {
        confirmationDialog(
            "Delete /\(pending.wrappedValue?.name ?? "")?",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { skill in
            Button("Delete Skill", role: .destructive) {
                Task { @MainActor in
                    do {
                        try await SkillLibrary.shared.delete(skill.id)
                        vm.showToast("Deleted /\(skill.name).")
                        after()
                    } catch {
                        vm.showToast("/\(skill.name) could not be deleted. \(error.localizedDescription)")
                    }
                }
            }
        } message: { _ in
            Text("Chats that already used it keep what they were told. This can't be undone.")
        }
    }
}

// MARK: - A skill's page

/// One skill's page in the Plugins place: Codex's breadcrumb (Skills › its
/// name), its name and description, Edit and the ⋯, then the skill itself —
/// the instructions the chat follows (`plugins.skillDetails.skill`). Edit
/// turns the page into its three fields; a new skill opens that way, with
/// Import SKILL.md… to fill them from a file. Leaving changes unsaved asks
/// first.
struct SkillPage: View {
    @Environment(StudioViewModel.self) private var vm
    /// nil for a skill being written.
    let skillID: String?
    let go: (PluginsPlaceLocation) -> Void

    @State private var isEditing = false
    @State private var draft = SkillDraft()
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var pendingDeletion: SkillRecord?
    /// Where to go once the learner agrees to throw the draft away; nil
    /// stays on the page and only ends editing.
    @State private var pendingDiscard: PluginsPlaceLocation??
    @State private var isImporting = false

    private var skill: SkillRecord? {
        skillID.flatMap { id in SkillLibrary.shared.skills.first { $0.id == id } }
    }

    private var editing: Bool { skillID == nil || isEditing }

    var body: some View {
        let library = SkillLibrary.shared
        ScrollView {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
                PluginsPlaceBreadcrumb(root: "Skills", current: skill?.name ?? (skillID == nil ? "New Skill" : "Skill")) {
                    leave(to: .skills)
                }
                if skillID != nil, library.hasLoaded, skill == nil {
                    SpaceEmptyLine(systemImage: "wand.and.stars", text: "This skill is gone. It was deleted here, over MCP or on another Mac.")
                        .frame(maxWidth: .infinity)
                        .padding(.top, SpacePlaceMetrics.emptyTopPadding - StudioDesign.Spacing.xLarge)
                } else if editing {
                    editor
                } else if let skill {
                    reader(skill)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .spacePlaceColumn()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await SkillLibrary.shared.loadIfNeeded()
        }
        .onExitCommand {
            if editing, skillID != nil { leave(to: nil) } else { leave(to: .skills) }
        }
        .skillDeletionDialog(pending: $pendingDeletion, vm: vm) { go(.skills) }
        .confirmationDialog(
            "Discard your changes?",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                let destination = pendingDiscard ?? nil
                pendingDiscard = nil
                finishLeaving(to: destination)
            }
            Button("Keep Editing", role: .cancel) { pendingDiscard = nil }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.skillFileTypes) { result in
            importSkillFile(result)
        }
        .accessibilityIdentifier("skills.page")
    }

    // MARK: Reading

    private func reader(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    SkillGlyph()
                }
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(skill.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button {
                    draft = SkillDraft(skill)
                    saveError = nil
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .zoomedSystemFont(size: 12.5, weight: .medium)
                }
                .buttonStyle(.hoverWash)
                .help("Edit this skill")
                .accessibilityIdentifier("skills.page.edit")
                Menu {
                    SkillMenuItems(skill: skill, open: nil) { pendingDeletion = skill }
                } label: {
                    Image(systemName: "ellipsis")
                        .zoomedSystemFont(size: 13, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }
            Text("Type /\(skill.name) or $\(skill.name) in a chat to use it. The chat also uses it on its own when a request matches the description.")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            SettingsSection(title: "Skill") {
                SettingsCard {
                    Text(skill.instructions)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Edited \(skill.updatedAt.formatted(.relative(presentation: .named)))")
                .zoomedSystemFont(size: 11.5)
                .foregroundStyle(.tertiary)
                .textSelection(.disabled)
        }
    }

    // MARK: Writing

    private var editor: some View {
        let problem = draft.problem(among: SkillLibrary.shared.skills, editing: skillID)
        return VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
            HStack(alignment: .firstTextBaseline) {
                Text(skillID == nil ? "New Skill" : "Edit Skill")
                    .font(.title3.weight(.semibold))
                Spacer()
                if skillID == nil {
                    Button("Import SKILL.md…") { isImporting = true }
                        .buttonStyle(.hoverWash)
                        .help("Fill the fields from a SKILL.md file")
                        .accessibilityIdentifier("skills.page.import")
                }
            }
            field("Name", hint: draft.command.isEmpty ? "What you type after / or $ in a chat." : "In a chat: /\(draft.command)") {
                TextField("paper-walkthrough", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("skills.page.name")
            }
            field("Description", hint: "When the skill applies and what it does. The chat reads this to decide when to use it.") {
                TextField("Walk through a paper section by section, with cards", text: $draft.description, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("skills.page.description")
            }
            field("Instructions", hint: "Markdown: how to do the work, step by step.") {
                TextEditor(text: $draft.instructions)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 260)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .accessibilityIdentifier("skills.page.instructions")
            }
            if let message = saveError ?? (draft.hasChanges(from: skill) ? problem : nil) {
                Text(message)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { leave(to: skillID == nil ? .skills : nil) }
                    .buttonStyle(.hoverWash)
                    .accessibilityIdentifier("skills.page.cancel")
                SpaceDarkPillButton(title: skillID == nil ? "Create Skill" : "Save", systemImage: nil, image: nil) {
                    save()
                }
                .disabled(problem != nil || isSaving)
                .opacity(problem != nil || isSaving ? 0.45 : 1)
                .accessibilityIdentifier("skills.page.save")
            }
        }
    }

    private func field<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .zoomedSystemFont(size: 12, weight: .semibold)
                .textSelection(.disabled)
            content()
            Text(hint)
                .zoomedSystemFont(size: 11.5)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
        }
    }

    private func save() {
        guard draft.problem(among: SkillLibrary.shared.skills, editing: skillID) == nil, !isSaving else { return }
        isSaving = true
        saveError = nil
        let fields = draft
        Task { @MainActor in
            defer { isSaving = false }
            do {
                if let skillID {
                    let saved = try await SkillLibrary.shared.update(
                        skillID, name: fields.name, description: fields.description, instructions: fields.instructions
                    )
                    isEditing = false
                    vm.showToast("Saved /\(saved.name).")
                } else {
                    let created = try await SkillLibrary.shared.create(
                        name: fields.name, description: fields.description, instructions: fields.instructions
                    )
                    vm.showToast("Created /\(created.name).")
                    go(.skill(created.id))
                }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// Leaves the editor for `destination` (nil: back to reading this
    /// skill), asking first when the draft holds changes.
    private func leave(to destination: PluginsPlaceLocation?) {
        if editing, draft.hasChanges(from: skill) {
            pendingDiscard = .some(destination)
        } else {
            finishLeaving(to: destination)
        }
    }

    private func finishLeaving(to destination: PluginsPlaceLocation?) {
        isEditing = false
        saveError = nil
        if let destination { go(destination) }
    }

    // MARK: Import

    private static let skillFileTypes: [UTType] = [UTType(filenameExtension: "md") ?? .plainText, .plainText]

    private func importSkillFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            saveError = "\(url.lastPathComponent) could not be read as text."
            return
        }
        guard let filled = draft.filled(fromSkillMarkdown: text) else {
            saveError = "\(url.lastPathComponent) is not a SKILL.md: it has no --- block with name: and description:."
            return
        }
        draft = filled
        saveError = nil
    }
}
