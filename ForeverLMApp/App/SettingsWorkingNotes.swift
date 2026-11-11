import SwiftUI
import os

// MARK: - Working notes (docs/planner-design.md, "The day is planned from a running log")

/// Settings → Data & Privacy → *Notes about your work*: the one switch over
/// the working notes ForeverLM keeps from the learner's chats and reading, and
/// the way to read, correct and forget them. The notes are kept in the
/// background, as ChatGPT keeps its memory, and are never a page
/// (`WorkingMemoryRecords`), so this list is the one place they are shown:
/// every note the learner added or asked ForeverLM to keep, and every chat is
/// handed, is here, one sentence each.
struct WorkingNotesSettingsSection: View {
    @PreferenceStorage(Prefs.Memory.workingNotesEnabled)
    private var keepsNotes: Bool
    @State private var noteCount: Int?
    @State private var isReviewing = false

    var body: some View {
        SettingsSection(title: "Notes about your work") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep notes about my work", isOn: $keepsNotes)
                        .accessibilityIdentifier("settings.workingNotes.enabled")
                    Text("Notes you add, or ask ForeverLM to remember, sent with your chats to the model you chose, so it knows what you have been working on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().padding(.vertical, 12)

                HStack(spacing: 12) {
                    Text(countLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Review Notes…") { isReviewing = true }
                        .accessibilityIdentifier("settings.workingNotes.review")
                }
            }
        }
        .task { await reloadCount() }
        .sheet(isPresented: $isReviewing, onDismiss: { Task { await reloadCount() } }) {
            WorkingNotesReviewSheet()
        }
    }

    private var countLine: String {
        switch noteCount {
        case nil: return " "
        case 0?: return "No notes yet."
        case 1?: return "1 note"
        case let count?: return "\(count) notes"
        }
    }

    private func reloadCount() async {
        noteCount = await StorageService().workingNotes().allNotes().count
    }
}

/// Every note, grouped by kind, each one editable in place and forgettable,
/// with a field to teach a new one. Changes are written to the notes and to
/// the record that carries them to the learner's other Macs
/// (`syncWorkingNotesMirror`) at once. Forget All also forgets the running
/// summary of what they are working on (`resetWorkingLog`).
struct WorkingNotesReviewSheet: View {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "WorkingNotes")
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [WorkingNote] = []
    @State private var isLoaded = false
    @State private var newText = ""
    @State private var newKind: WorkingNoteKind = .fact
    @State private var confirmsForgetAll = false

    private let storage = StorageService()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes about your work")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.workingNotes.done")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    addRow

                    if isLoaded, notes.isEmpty {
                        Text("Nothing yet. Add one above.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(WorkingNoteKind.allCases, id: \.self) { kind in
                        let group = notes.filter { $0.kind == kind }
                        if !group.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(Self.title(for: kind))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(group) { note in
                                    WorkingNoteRow(
                                        note: note,
                                        onCommit: { text in Task { await edit(note, text: text) } },
                                        onForget: { Task { await forget(note) } }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !notes.isEmpty {
                Divider()
                HStack {
                    Spacer()
                    Button("Forget All…", role: .destructive) { confirmsForgetAll = true }
                        .accessibilityIdentifier("settings.workingNotes.forgetAll")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 560, height: 560)
        .task { await load() }
        .alert("Forget all notes?", isPresented: $confirmsForgetAll) {
            Button("Forget All", role: .destructive) { Task { await forgetAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ForeverLM will stop knowing what you have been working on until it writes new notes from your next days.")
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Picker("Kind", selection: $newKind) {
                ForEach(WorkingNoteKind.allCases, id: \.self) { kind in
                    Text(Self.singular(for: kind)).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            TextField("Add a note", text: $newText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await add() } }
                .accessibilityIdentifier("settings.workingNotes.add")
        }
    }

    // MARK: Actions

    private func load() async {
        await storage.syncWorkingNotesMirror()
        notes = await storage.workingNotes().allNotes()
        isLoaded = true
    }

    private func reload() async {
        await storage.syncWorkingNotesMirror()
        notes = await storage.workingNotes().allNotes()
    }

    private func add() async {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newText = ""
        await storage.workingNotes().apply(
            WorkingNoteOps(add: [.init(kind: newKind.rawValue, text: text)], update: [], forget: [])
        )
        await reload()
    }

    private func edit(_ note: WorkingNote, text: String) async {
        await storage.workingNotes().edit(id: note.id, text: text)
        await reload()
    }

    private func forget(_ note: WorkingNote) async {
        await storage.workingNotes().forget(id: note.id)
        await reload()
    }

    private func forgetAll() async {
        await storage.workingNotes().forgetAll()
        do {
            try await storage.resetWorkingLog()
        } catch {
            Self.logger.error("Resetting the working log failed: \(error.localizedDescription, privacy: .public)")
        }
        await reload()
    }

    // MARK: Words

    static func title(for kind: WorkingNoteKind) -> String {
        switch kind {
        case .thread: return "In progress"
        case .interest: return "Keeps coming back to"
        case .preference: return "How you like to work"
        case .fact: return "Facts"
        case .outcome: return "Done and learned"
        }
    }

    static func singular(for kind: WorkingNoteKind) -> String {
        switch kind {
        case .thread: return "In progress"
        case .interest: return "Interest"
        case .preference: return "Preference"
        case .fact: return "Fact"
        case .outcome: return "Done"
        }
    }
}

/// One note: its sentence, editable in place and committed on Return or when
/// the field loses focus, its date, and a forget button that shows on hover.
private struct WorkingNoteRow: View {
    let note: WorkingNote
    let onCommit: (String) -> Void
    let onForget: () -> Void

    @State private var draft: String
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    init(note: WorkingNote, onCommit: @escaping (String) -> Void, onForget: @escaping () -> Void) {
        self.note = note
        self.onCommit = onCommit
        self.onForget = onForget
        _draft = State(initialValue: note.text)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("Note", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            Text(note.updatedAt, format: .dateTime.month(.abbreviated).day())
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button(action: onForget) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .help("Forget this note")
            .accessibilityLabel("Forget this note")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onHover { isHovering = $0 }
        .onChange(of: note.text) { _, text in if !isFocused { draft = text } }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != note.text else {
            if text.isEmpty { draft = note.text }
            return
        }
        onCommit(text)
    }
}
