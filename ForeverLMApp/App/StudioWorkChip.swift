#if os(macOS)
import SwiftUI

// MARK: - Work running in the background, as one quiet chip (2026-10-06)
//
// The product owner, 2026-10-06: "make the app more slick; kind of like the chatgpt app.
// maybe cleaner and fewer buttons and bells and whistles". The Studio window's
// bottom stack drew a banner for each thing running in the background: every
// call an AI app made on ForeverLM's models (`MCPToolActivityCenter`), every
// explainer being written, a course import. Three at once were a pile over the
// chat. ChatGPT shows background work as one small indicator, so they are one
// chip: the one thing running said in full ("Codex is writing quizzes for
// Bioenergetics · 3 of 12"), or "3 things running". A click opens the list,
// each row with the action its banner had: Stop for an assistant's call,
// Cancel for an explainer, Hide for an import. What asks the learner for
// something keeps its own card in the stack: the publisher check, a deletion's
// Undo, the toast. The record is docs/ui-design.md, "Background work is one
// chip", and docs/mcp-gateway.md, "What the learner sees while a call runs".

/// One thing the work chip stands for.
struct StudioWorkItem: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A call an AI app made that set ForeverLM's models to work.
        case assistant(MCPToolActivityCenter.Activity)
        /// An explainer the learner asked for, being written.
        case explainer(ExplainerGenerationCoordinator.Writing)
        /// A course, playlist, Teachable or Gemini import, by its status line
        /// (`StudioViewModel.visiblePlaylistImportStatus`).
        case courseImport(String)
    }

    enum Glyph: Equatable {
        case spinner, finished, stopped, failed
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .assistant(let activity): return "assistant-\(activity.id.uuidString)"
        case .explainer(let writing): return "explainer-\(writing.id)"
        case .courseImport: return "import"
        }
    }

    /// Still going. An assistant's call stays listed for a few seconds after
    /// it ends, saying how it ended.
    var isRunning: Bool {
        if case .assistant(let activity) = kind { return !activity.hasEnded }
        return true
    }

    var glyph: Glyph {
        guard case .assistant(let activity) = kind else { return .spinner }
        switch activity.state {
        case .running, .stopping: return .spinner
        case .finished: return .finished
        case .stopped: return .stopped
        case .failed: return .failed
        }
    }

    /// The chip's line: who is doing what to what. A running call names the
    /// app that asked, the one thing the product owner asked to see while it works
    /// (2026-09-27).
    var chipTitle: String {
        switch kind {
        case .assistant(let activity):
            return activity.hasEnded ? activity.title : activity.runningLine
        case .explainer, .courseImport:
            return listTitle
        }
    }

    /// The list's line, with who asked in `listCaption` instead.
    var listTitle: String {
        switch kind {
        case .assistant(let activity): return activity.title
        case .explainer(let writing): return "Writing an explainer of \(writing.title)…"
        case .courseImport(let message): return message
        }
    }

    /// How far it has got, or how it ended; nil when there is nothing to say.
    var status: String? {
        guard case .assistant(let activity) = kind else { return nil }
        switch activity.state {
        case .running: return activity.detail
        case .stopping: return "Stopping…"
        case .finished: return "Done"
        case .stopped: return "Stopped"
        case .failed(let message): return message
        }
    }

    /// The list row's second line: the app that asked, then `status`.
    var listCaption: String? {
        guard case .assistant(let activity) = kind else { return nil }
        let parts = [activity.assistant, status].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension MCPToolActivityCenter.Activity {
    /// "Codex is writing quizzes for Bioenergetics". Every title starts with
    /// what is being done ("Writing quizzes for", `MCPToolActivityTitle`), so
    /// it reads on after "is"; a call from an app with no name is its title.
    var runningLine: String {
        guard let assistant, let first = title.first else { return title }
        return "\(assistant) is \(first.lowercased())\(title.dropFirst())"
    }
}

/// What the chip says for what is in the list: the one thing running in full,
/// a count when several run, and for a moment after the last one ends, how
/// it ended. Nil when nothing is listed.
struct StudioWorkSummary: Equatable {
    let glyph: StudioWorkItem.Glyph
    let title: String
    let status: String?

    init(glyph: StudioWorkItem.Glyph, title: String, status: String?) {
        self.glyph = glyph
        self.title = title
        self.status = status
    }

    init?(_ items: [StudioWorkItem]) {
        guard !items.isEmpty else { return nil }
        let running = items.filter(\.isRunning)
        if running.count > 1 {
            self.init(glyph: .spinner, title: "\(running.count) things running", status: nil)
        } else if let only = running.first ?? (items.count == 1 ? items.first : nil) {
            // One still running beside calls that just ended: the ended ones
            // say how they ended in the list.
            self.init(glyph: only.glyph, title: only.chipTitle, status: only.status)
        } else {
            // Several calls ended within seconds of each other.
            let failed = items.filter { $0.glyph == .failed }
            if let first = failed.first, failed.count == 1 {
                self.init(glyph: .failed, title: first.chipTitle, status: first.status)
            } else if !failed.isEmpty {
                self.init(glyph: .failed, title: "\(failed.count) failed", status: nil)
            } else {
                self.init(glyph: .finished, title: "\(items.count) done", status: nil)
            }
        }
    }
}

/// The chip at the bottom of a Studio window while anything runs in the
/// background, and the list it opens.
struct StudioWorkChip: View {
    enum Action: Equatable {
        /// Stop an assistant's running call.
        case stop(UUID)
        /// Dismiss an assistant's call that has ended.
        case dismiss(UUID)
        /// Stop writing an explainer, by its source's id.
        case cancelExplainer(String)
        /// Hide the import's line for the rest of the import.
        case hideImport
    }

    let items: [StudioWorkItem]
    let perform: (Action) -> Void

    @State private var isShowingList = false

    var body: some View {
        if let summary = StudioWorkSummary(items) {
            Button {
                isShowingList.toggle()
            } label: {
                StudioWorkChipWidthCap(maxWidth: 440).callAsFunction {
                    HStack(spacing: 7) {
                        StudioWorkGlyph(glyph: summary.glyph, isCompact: true)
                        line(summary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.right")
                            .zoomedSystemFont(size: 9, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 11)
                    .padding(.vertical, 6)
                }
            }
            .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.12))
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(radius: 3)
            .help(items.map { [$0.chipTitle, $0.status].compactMap { $0 }.joined(separator: " · ") }
                .joined(separator: "\n"))
            .accessibilityLabel([summary.title, summary.status].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Shows what is running")
            .accessibilityIdentifier("studio.work.chip")
            .popover(isPresented: $isShowingList, arrowEdge: .top) {
                StudioWorkList(items: items, perform: perform)
            }
        }
    }

    /// One line, so a long title trims the progress after it before itself.
    private func line(_ summary: StudioWorkSummary) -> Text {
        let title = Text(summary.title).font(.caption.weight(.medium))
        guard let status = summary.status else { return title }
        let rest = Text("· \(status)").foregroundStyle(.secondary)
        return Text("\(title) \(rest)").font(.caption)
    }
}

/// The chip's list: each thing running, with the action its banner had.
private struct StudioWorkList: View {
    let items: [StudioWorkItem]
    let perform: (StudioWorkChip.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                StudioWorkRow(item: item, perform: perform)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
    }
}

private struct StudioWorkRow: View {
    let item: StudioWorkItem
    let perform: (StudioWorkChip.Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            StudioWorkGlyph(glyph: item.glyph, isCompact: false)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.listTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let caption = item.listCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            action
        }
    }

    @ViewBuilder
    private var action: some View {
        switch item.kind {
        case .assistant(let activity):
            if activity.state == .running, activity.canStop {
                Button("Stop") { perform(.stop(activity.id)) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.hoverWash(tint: Color.accentColor))
                    .help("Stop this. What it already saved is kept, and \(activity.assistant ?? "the assistant") is told you stopped it.")
                    .accessibilityIdentifier("studio.assistantWork.stop")
            } else if activity.hasEnded {
                closeButton(help: "Dismiss", label: "Dismiss", identifier: "studio.assistantWork.hide") {
                    perform(.dismiss(activity.id))
                }
            } else if activity.stopIsOverdue {
                // Stop was pressed and the call has not answered since: it
                // can leave the list, though it may still finish its step.
                closeButton(
                    help: "Hide this. It has not answered Stop yet; whatever it saves is kept.",
                    label: "Hide",
                    identifier: "studio.assistantWork.hide"
                ) {
                    perform(.dismiss(activity.id))
                }
            }
        case .explainer(let writing):
            Button("Cancel") { perform(.cancelExplainer(writing.id)) }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.hoverWash(tint: Color.accentColor))
                .help("Stop writing this explainer; nothing is saved")
                .accessibilityIdentifier("studio.explainer.cancel")
        case .courseImport:
            // Nothing to act on: hiding it is all (product owner, 2026-09-21, "this
            // should be hidable"), and the course's sidebar row spins on.
            closeButton(
                help: "Hide this. The import keeps running; its course spins in the sidebar until it is done.",
                label: "Hide import progress",
                identifier: "studio.import.hide"
            ) {
                perform(.hideImport)
            }
        }
    }

    private func closeButton(
        help: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .zoomedSystemFont(size: 10, weight: .semibold)
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.12))
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// A spinner while it runs, then how it ended: grey for done or stopped, the
/// warning orange only for a failure ("Lists are monochrome",
/// docs/ui-design.md).
private struct StudioWorkGlyph: View {
    let glyph: StudioWorkItem.Glyph
    /// The chip's size rather than a list row's.
    let isCompact: Bool

    var body: some View {
        switch glyph {
        case .spinner:
            ProgressView()
                .controlSize(isCompact ? .mini : .small)
        case .finished:
            Image(systemName: "checkmark")
                .zoomedSystemFont(size: isCompact ? 10 : 12, weight: .semibold)
                .foregroundStyle(.secondary)
        case .stopped:
            Image(systemName: "stop.fill")
                .zoomedSystemFont(size: isCompact ? 8 : 10, weight: .semibold)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .zoomedSystemFont(size: isCompact ? 10 : 12, weight: .semibold)
                .foregroundStyle(.orange)
        }
    }
}

/// Lets the chip be as wide as its line up to `maxWidth`, where the line
/// truncates. A `frame(maxWidth:)` would make every chip that wide.
private struct StudioWorkChipWidthCap: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif
