import SwiftUI

/// A notebook's own Think first level, in its ⋯ menu
/// (docs/fences-and-think-first-design.md, "Think first"): the library's
/// level, named so the learner sees what following it means, or one of the
/// three levels for this notebook alone. The choice is the learner's account
/// Setting `notebook.thinkFirst.<notebookID>`, so a teammate's never changes it.
struct NotebookThinkFirstMenu: View {
    let notebookID: String

    /// Observed so the menu follows another Mac, the web or MCP; written
    /// through `ThinkFirst.setNotebookLevel`, which removes the row to follow
    /// the library again.
    @SyncedStorage private var stored: String
    @SyncedStorage(wrappedValue: ThinkFirstLevel.off, ThinkFirst.levelKey)
    private var libraryLevel: ThinkFirstLevel

    init(notebookID: String) {
        self.notebookID = notebookID
        _stored = SyncedStorage(wrappedValue: "", ThinkFirst.notebookKey(notebookID))
    }

    private var selection: Binding<ThinkFirstLevel?> {
        Binding(
            get: { ThinkFirstLevel(rawValue: stored) },
            set: { ThinkFirst.setNotebookLevel($0, notebookID: notebookID) }
        )
    }

    var body: some View {
        Menu("Think First", systemImage: "lightbulb") {
            Picker("Think First", selection: selection) {
                Text("Library Setting (\(libraryLevel.title))").tag(ThinkFirstLevel?.none)
                Divider()
                ForEach(ThinkFirstLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(ThinkFirstLevel?.some(level))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help("Ask for your own line before ForeverLM's, in this notebook")
    }
}

/// Think first before **Find directions** (docs/fences-and-think-first-design.md):
/// "What would you try?" Find Directions keeps the learner's answer — a new
/// Idea on a Goal or Notebook, a line in an Idea's notes — and starts the
/// search with it as one of its candidates; Skip starts it at once. Asked
/// for, so a sheet, in the window the search was asked from.
struct DirectionTakeSheet: View {
    var vm: StudioViewModel
    let request: DirectionTakeRequest
    @Environment(\.dismiss) private var dismiss
    @State private var take = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What would you try?")
                .font(.headline)
            Text(request.launch.homeTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField("What would you try?", text: $take, prompt: Text("In your words"), axis: .vertical)
                .textFieldStyle(.plain)
                .labelsHidden()
                .lineLimit(3...8)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityIdentifier("directions.thinkFirst.field")
            HStack {
                Button("Skip") { finish(take: nil) }
                    .keyboardShortcut(.cancelAction)
                    .help("Find directions now")
                    .accessibilityIdentifier("directions.thinkFirst.skip")
                Spacer()
                Button("Find Directions") { finish(take: ThinkFirst.take(take)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ThinkFirst.take(take) == nil)
                    .help("Keep your idea, then search with it among the candidates")
                    .accessibilityIdentifier("directions.thinkFirst.find")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func finish(take: String?) {
        dismiss()
        let vm = vm
        let request = request
        Task { await vm.answerDirectionTake(request, take: take) }
    }
}

extension View {
    /// The Find directions ask of the window this is in
    /// (`StudioWindowState.pendingDirectionTake`).
    func directionTakeSheet() -> some View {
        modifier(DirectionTakeSheetHost())
    }
}

private struct DirectionTakeSheetHost: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    func body(content: Content) -> some View {
        @Bindable var windowState = windowState
        content.sheet(item: $windowState.pendingDirectionTake) { request in
            DirectionTakeSheet(vm: vm, request: request)
        }
    }
}

/// A learner question's guess, under the question it went with: "Your guess",
/// then the words as written. Quieter than the bubble, since the bubble is the
/// question and this is the thinking that went before it.
struct ReviewChatGuessLine: View {
    let guess: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Your guess")
                .zoomedSystemFont(size: 10.5, weight: .semibold)
                .foregroundStyle(.tertiary)
                .textSelection(.disabled)
            Text(guess)
                .zoomedSystemFont(size: ChatMarkdownView.baseFontSize - 1)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .padding(.trailing, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mac.chatGuess")
    }
}

/// The token that heads the composer while a question waits for its guess
/// (Think first's chat moment): "Your guess first?", and an × that sends the
/// question without one. Escape does the same.
struct ReviewChatGuessToken: View {
    let skip: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lightbulb")
                .zoomedSystemFont(size: 9, weight: .semibold)
            Text("Your guess first?")
                .zoomedSystemFont(size: 11, weight: .medium)
                .fixedSize()
            Button(action: skip) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 7, weight: .bold)
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.hoverWash(in: Circle(), opacity: 0.14))
            .help("Skip: send the question without a guess")
            .accessibilityLabel("Skip the guess")
            .accessibilityIdentifier("mac.chatGuessSkip")
        }
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .help("Write what you think the answer is; Return sends it with your question, and the answer says where the two agree and differ.")
        .accessibilityLabel("Your guess first")
        .accessibilityIdentifier("mac.chatGuessToken")
    }
}

/// The question waiting for its guess, above the composer's field, one or
/// two lines in the quiet of a quoted block.
struct ReviewChatGuessQuestion: View {
    let question: String

    var body: some View {
        Text(question)
            .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 9)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 3)
            }
            .accessibilityIdentifier("mac.chatGuessQuestion")
    }
}
