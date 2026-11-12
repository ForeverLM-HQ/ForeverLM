#if os(macOS)
import SwiftUI

// MARK: - Work running in the background, as one quiet chip
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
//
// The chip is an icon in the strip's bottom left, above the
// OpenRouter one for paid work (product owner, 2026-10-13, of "2 things running"
// over the Reader: "should instead be in the bottom left as an icon", "perhaps
// with the chatgpt icon if it's codex; and with the claude icon if it's
// claude"). It draws the logo of the AI app that asked, and its line is the
// icon's tooltip.

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
    /// app that asked, the one thing the product owner asked to see while it works.
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

    /// What the strip's icon draws for it: the logo of the AI app that
    /// asked, as Getting Started tells them apart (Codex's is ChatGPT's,
    /// Claude Code's is Claude's), or a symbol for the app's own work and
    /// an app it does not know.
    enum Mark: Equatable {
        case logo(asset: String, isTemplate: Bool)
        case symbol(String)
    }

    var mark: Mark {
        switch kind {
        case .assistant(let activity):
            if let name = activity.assistant,
               let app = AISubscription.matching(clientName: name),
               let asset = app.logoAssetName {
                return .logo(asset: asset, isTemplate: app.usesTemplateLogo)
            }
            return .symbol("sparkles")
        case .explainer:
            return .symbol("lightbulb")
        case .courseImport:
            return .symbol("square.and.arrow.down")
        }
    }

    /// The item whose mark the icon draws: the first still running, or the
    /// first listed once they have all ended.
    static func lead(of items: [StudioWorkItem]) -> StudioWorkItem? {
        items.first(where: \.isRunning) ?? items.first
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

/// The strip's icon while anything runs in the background, above the
/// OpenRouter one (`BackgroundWorkButton`), and the list it opens: the logo
/// of the app behind what runs, still as the strip's other glyphs, with a
/// count when several run and a small badge for how they ended.
struct StudioWorkButton: View {
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

    @ObservedObject private var assistantWork = MCPToolActivityCenter.shared
    @ObservedObject private var explainers = ExplainerGenerationCoordinator.shared
    @Environment(StudioViewModel.self) private var vm
    @State private var isShowingList = false

    /// Everything running in the background: the calls an AI app made on
    /// ForeverLM's models, explainers being written, and a course import
    /// the learner has not hidden.
    private var items: [StudioWorkItem] {
        assistantWork.shown.map { StudioWorkItem(kind: .assistant($0)) }
            + explainers.writings.map { StudioWorkItem(kind: .explainer($0)) }
            + (vm.visiblePlaylistImportStatus.map { [StudioWorkItem(kind: .courseImport($0))] } ?? [])
    }

    var body: some View {
        let items = items
        if let summary = StudioWorkSummary(items), let lead = StudioWorkItem.lead(of: items) {
            let line = [summary.title, summary.status].compactMap { $0 }.joined(separator: " · ")
            Button {
                isShowingList.toggle()
            } label: {
                StudioWorkMark(mark: lead.mark)
                    .overlay(alignment: .bottomTrailing) {
                        StudioWorkBadge(
                            glyph: summary.glyph,
                            running: items.filter(\.isRunning).count
                        )
                        .offset(x: 6, y: 5)
                    }
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
            .railTooltip(line)
            .accessibilityLabel(line)
            .accessibilityHint("Shows what is running")
            .accessibilityIdentifier("rail.work")
            .popover(isPresented: $isShowingList, arrowEdge: .trailing) {
                StudioWorkList(items: items, perform: perform)
            }
            .transition(.opacity)
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .stop(let id): assistantWork.stop(id)
        case .dismiss(let id): assistantWork.dismiss(id)
        case .cancelExplainer(let sourceID): explainers.cancel(sourceID)
        case .hideImport: vm.playlistImportBannerHidden = true
        }
    }
}

/// The app's logo in the strip's grey, or its own colours where Getting
/// Started draws them (Claude's, Gemini's).
private struct StudioWorkMark: View {
    let mark: StudioWorkItem.Mark

    var body: some View {
        switch mark {
        case .logo(let asset, let isTemplate):
            if isTemplate {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Color.secondary)
            } else {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
    }
}

/// The corner of the icon: how many run when it is more than one, and once
/// everything has ended, how. One thing running carries nothing, as the
/// strip's glyphs never spin (product owner, 2026-10-11).
private struct StudioWorkBadge: View {
    let glyph: StudioWorkItem.Glyph
    let running: Int

    var body: some View {
        switch glyph {
        case .spinner:
            if running > 1 {
                Text("\(running)")
                    .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(StudioInsetCardStyle.chrome)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 12)
                    .background(Capsule().fill(Color(nsColor: .secondaryLabelColor)))
                    .overlay(Capsule().stroke(StudioInsetCardStyle.chrome, lineWidth: 1.5))
            }
        case .finished:
            symbol("checkmark.circle.fill", color: .secondary)
        case .stopped:
            symbol("stop.circle.fill", color: .secondary)
        case .failed:
            symbol("exclamationmark.circle.fill", color: .orange)
        }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .background(Circle().fill(StudioInsetCardStyle.chrome).padding(-1.5))
    }
}

/// The icon's list: each thing running, with the action its banner had.
private struct StudioWorkList: View {
    let items: [StudioWorkItem]
    let perform: (StudioWorkButton.Action) -> Void

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
    let perform: (StudioWorkButton.Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            StudioWorkGlyph(glyph: item.glyph)
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

    var body: some View {
        switch glyph {
        case .spinner:
            ProgressView()
                .controlSize(.small)
        case .finished:
            Image(systemName: "checkmark")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
        case .stopped:
            Image(systemName: "stop.fill")
                .zoomedSystemFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.orange)
        }
    }
}

#endif
