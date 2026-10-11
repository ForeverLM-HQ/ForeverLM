#if os(macOS)
import SwiftUI

// MARK: - What is running in the background, and what it costs (2026-10-08)
//
// The product owner, clicking Listen and then looking away: "when i click away; what is
// happening? … whenever things are going on in the background that cost money,
// there should probably be an indicator in the bottom left that i can click to
// see progress." Narrations, explainer videos, mnemonic readings, scheduled
// task runs and paid assistant calls each kept their progress in a home of
// their own, and the only places that drew it were the screens that started
// them. This is the one place that lists them all, with a Stop on each. It
// reads the homes `list_running_ai_work` reads, and stops work through the
// same handles.

/// One piece of paid background work, as the popover draws it.
struct BackgroundWorkItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case narration, video, reading, scheduledTask, assistantCall, modelCall

        var systemImage: String {
            switch self {
            case .narration: return "waveform"
            case .video: return "film"
            case .reading: return "brain.head.profile"
            case .scheduledTask: return "clock"
            case .assistantCall: return "sparkles"
            case .modelCall: return "text.append"
            }
        }
    }

    /// How Stop reaches it.
    enum Stop: Equatable {
        case narration(sourceID: String)
        /// Narrations waiting their turn in the queue, listed as one row so a
        /// book's three hundred chapters do not fill the list.
        case queuedNarrations(sourceIDs: [String])
        case video(jobID: String)
        case reading(id: String)
        case scheduledTask(id: String)
        case registry(id: String)
        /// A model call inside the app's own processing; it ends by itself.
        case none
    }

    let id: String
    let kind: Kind
    /// Nil for a narration the monitor knows only by source id; the view names
    /// it from the library.
    var title: String?
    var sourceID: String?
    var detail: String
    /// Share done, when the work reports one.
    var fraction: Double?
    var startedAt: Date?
    /// "$0.42 of $3.00" for an assistant call that has a ceiling.
    var spend: String?
    let stop: Stop
}

/// A narration that ended and has not been dismissed: what the sidebar's
/// audio panel used to report, now beside the running work (product owner,
/// 2026-10-08: "it should be in the bottom left as a status indicator").
struct FinishedNarration: Identifiable, Equatable {
    let id: String
    let title: String
    let outcome: String
    let detail: String?
    let isProblem: Bool
}

@MainActor
final class BackgroundWorkMonitor: ObservableObject {
    static let shared = BackgroundWorkMonitor()

    @Published private(set) var items: [BackgroundWorkItem] = []
    @Published private(set) var finished: [FinishedNarration] = []

    private var timer: Timer?
    /// When each narration was first seen running, for how long it has taken
    /// and how long is left: the speech service records no start of its own
    /// for a run the learner began with Listen.
    private var firstSeen: [String: Date] = [:]

    private init() {}

    /// Starts the one-second refresh. The registry and the scheduled-task
    /// runner do not publish, so a quiet poll is the simplest way to see them;
    /// it publishes only when the list changed.
    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let current = collect()
        if current != items { items = current }
        let ended = Self.collectFinished()
        if ended != finished { finished = ended }
    }

    func dismissFinished() {
        SourceAudioGenerationQueue.shared.dismissFinished()
        refresh()
    }

    /// Narrations that ended since the learner last dismissed the list: the
    /// ones that need a word (failed, skipped) one by one, the rest counted.
    private static func collectFinished() -> [FinishedNarration] {
        let queue = SourceAudioGenerationQueue.shared
        let ended = queue.items.filter { !$0.status.isActive && ($0.endedAt ?? .distantPast) > queue.panelDismissedAt }
        var result: [FinishedNarration] = []
        for item in ended where item.status != .ready && item.status != .cancelled {
            result.append(FinishedNarration(
                id: "finished-\(item.sourceID)",
                title: item.title,
                outcome: item.status.label.capitalized,
                detail: item.status.detail,
                isProblem: true
            ))
        }
        let ready = ended.filter { $0.status == .ready }.count
        if ready > 0 {
            result.append(FinishedNarration(
                id: "finished-ready",
                title: ready == 1 ? "1 narration is ready" : "\(ready) narrations are ready",
                outcome: "Ready",
                detail: nil,
                isProblem: false
            ))
        }
        return result
    }

    func stop(_ item: BackgroundWorkItem) {
        switch item.stop {
        case .narration(let sourceID):
            ArticleSpeechService.shared.stopMakingNarration(sourceID: sourceID)
        case .queuedNarrations(let sourceIDs):
            _ = SourceAudioGenerationQueue.shared.cancel(sourceIDs: Set(sourceIDs))
        case .video(let jobID):
            ExplainerVideoGenerationCoordinator.shared.cancel(jobID)
        case .reading(let id):
            MnemonicReadingCoordinator.shared.cancel(id)
        case .scheduledTask(let id):
            _ = ScheduledTaskRunner.shared.stop(taskID: id)
        case .registry(let id):
            _ = MCPRunningWork.shared.stop(id, by: .learner)
        case .none:
            break
        }
        refresh()
    }

    private func collect() -> [BackgroundWorkItem] {
        var items: [BackgroundWorkItem] = []

        // Narrations: Listen's, Generate Audio's and the assistants' queue,
        // each source once. Listen's request counts from the click, so the
        // price question and the preparation show before a first part lands.
        let speech = ArticleSpeechService.shared
        let queue = SourceAudioGenerationQueue.shared
        let queued = queue.items.filter { $0.status.isActive }
        var narrationIDs = Set(queued.map(\.sourceID))
        narrationIDs.formUnion(speech.narrationRequests.sourceIDs)
        narrationIDs.formUnion(speech.backgroundGenerationSourceIDs)
        var waiting: [SourceAudioGenerationItem] = []
        for sourceID in narrationIDs.sorted() {
            let item = queued.first { $0.sourceID == sourceID }
            if item?.status == .queued, speech.backgroundGenerationProgress[sourceID] == nil {
                waiting.append(item!)
                continue
            }
            let progress = speech.backgroundGenerationProgress[sourceID]
            let started = firstSeen[sourceID] ?? Date()
            firstSeen[sourceID] = started
            let detail: String
            if let progress {
                var line = "\(progress.completedChunks) of \(progress.totalChunks) parts made"
                if progress.failedChunks > 0 {
                    line += " · \(progress.failedChunks) failed, retrying"
                }
                // The time left, once enough has landed to say: the parts are
                // made in parallel, so the average so far is a fair guide.
                if progress.completedChunks >= 5, progress.completedChunks < progress.totalChunks {
                    let perPart = Date().timeIntervalSince(started) / Double(progress.completedChunks)
                    let left = Int(perPart * Double(progress.totalChunks - progress.completedChunks))
                    line += " · about \(left >= 90 ? "\((left + 30) / 60) min" : "\(max(left, 5)) s") left"
                }
                detail = line
            } else {
                detail = speech.narrationStages[sourceID] ?? "Getting started"
            }
            items.append(BackgroundWorkItem(
                id: "narration-\(sourceID)",
                kind: .narration,
                title: item?.title,
                sourceID: sourceID,
                detail: detail,
                fraction: progress?.fractionCompleted,
                startedAt: item?.enqueuedAt ?? started,
                spend: nil,
                stop: .narration(sourceID: sourceID)
            ))
        }

        firstSeen = firstSeen.filter { narrationIDs.contains($0.key) }
        if !waiting.isEmpty {
            items.append(BackgroundWorkItem(
                id: "narration-waiting",
                kind: .narration,
                title: waiting.count == 1 ? waiting[0].title : "\(waiting.count) narrations",
                sourceID: nil,
                detail: "Waiting their turn",
                fraction: nil,
                startedAt: waiting.map(\.enqueuedAt).min(),
                spend: nil,
                stop: .queuedNarrations(sourceIDs: waiting.map(\.sourceID))
            ))
        }

        for job in ExplainerVideoGenerationCoordinator.shared.jobs {
            var fraction: Double?
            if case .drawingScenes(let done, let total) = job.stage, total > 0 {
                fraction = Double(done) / Double(total)
            }
            items.append(BackgroundWorkItem(
                id: "video-\(job.id)",
                kind: .video,
                title: job.concept,
                sourceID: nil,
                detail: job.stage.label,
                fraction: fraction,
                startedAt: job.startedAt,
                spend: nil,
                stop: .video(jobID: job.id)
            ))
        }

        // A reading an assistant started is its registry entry below.
        for run in MnemonicReadingCoordinator.shared.runs where run.workID == nil {
            items.append(BackgroundWorkItem(
                id: "reading-\(run.id)",
                kind: .reading,
                title: run.title,
                sourceID: nil,
                detail: run.progress.label,
                fraction: nil,
                startedAt: run.startedAt,
                spend: nil,
                stop: .reading(id: run.id)
            ))
        }

        let runner = ScheduledTaskRunner.shared
        for taskID in runner.runningTaskIDs.sorted() {
            let title = runner.details.first { $0.task.id == taskID }?.task.title ?? "A scheduled task"
            items.append(BackgroundWorkItem(
                id: "task-\(taskID)",
                kind: .scheduledTask,
                title: title,
                sourceID: nil,
                detail: "Running",
                fraction: nil,
                startedAt: nil,
                spend: nil,
                stop: .scheduledTask(id: taskID)
            ))
        }

        // Paid assistant calls and what tools leave running. Calls with no
        // ceiling are not paid work, and a text-to-speech call is the
        // narration row above.
        for entry in MCPRunningWork.shared.snapshot
        where entry.spendLimitUSD != nil && entry.stopRequestedAt == nil && entry.tool != "generate_source_audio" {
            var spend: String?
            if let limit = entry.spendLimitUSD, entry.spentUSD > 0 {
                spend = String(format: "$%.2f of $%.2f", entry.spentUSD, limit)
            }
            items.append(BackgroundWorkItem(
                id: "registry-\(entry.id)",
                kind: .assistantCall,
                title: entry.tool.replacingOccurrences(of: "_", with: " ").capitalized,
                sourceID: nil,
                detail: entry.detail ?? entry.about ?? "Asked by an assistant",
                fraction: nil,
                startedAt: entry.startedAt,
                spend: spend,
                stop: .registry(id: entry.id)
            ))
        }

        // Model calls the app makes for the library on its own: reading a
        // paper's first page, cleaning its text for Listen, formatting a
        // transcript. A call must have run a second before it is listed, so a
        // quick one does not flash the spinner; calls for one source and step
        // are one row.
        let now = Date()
        var groups: [String: (entry: AIInFlightCalls.Entry, count: Int, models: [String])] = [:]
        for entry in AIInFlightCalls.shared.snapshot where now.timeIntervalSince(entry.startedAt) >= 1 {
            let key = "\(entry.taskLabel ?? "")|\(entry.subjectID ?? entry.sourceTitle ?? "")"
            // The model each request is with, as the model picker names it.
            var model: String?
            if let provider = entry.provider, let id = entry.model {
                model = AIModelCatalog.pickerName(provider: provider, modelID: id)
            }
            if let existing = groups[key] {
                let earliest = existing.entry.startedAt <= entry.startedAt ? existing.entry : entry
                var models = existing.models
                if let model, !models.contains(model) { models.append(model) }
                groups[key] = (earliest, existing.count + 1, models)
            } else {
                groups[key] = (entry, 1, model.map { [$0] } ?? [])
            }
        }
        for (key, group) in groups.sorted(by: { $0.value.entry.startedAt < $1.value.entry.startedAt }) {
            let label = group.entry.taskLabel
            let step = label.flatMap { AITask(rawValue: $0)?.displayName }
                ?? label?.replacingOccurrences(of: "_", with: " ").capitalized
                ?? "Model call"
            var detail = [step]
            if !group.models.isEmpty { detail.append(group.models.sorted().joined(separator: ", ")) }
            if group.count > 1 { detail.append("\(group.count) requests") }
            items.append(BackgroundWorkItem(
                id: "model-\(key)",
                kind: .modelCall,
                title: group.entry.sourceTitle,
                sourceID: group.entry.subjectID,
                detail: detail.joined(separator: " · "),
                fraction: nil,
                startedAt: group.entry.startedAt,
                spend: nil,
                stop: .none
            ))
        }
        return items
    }
}

/// The rail's button: a still grey OpenRouter logo (a ring, when one thing
/// reports its share) that appears only while paid work runs, and opens the list.
struct BackgroundWorkButton: View {
    @ObservedObject var monitor: BackgroundWorkMonitor
    @Environment(StudioViewModel.self) private var vm
    @State private var isShown = false

    var body: some View {
        if !monitor.items.isEmpty || !monitor.finished.isEmpty {
            Button { isShown.toggle() } label: {
                indicator
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
            .railTooltip(helpText)
            .accessibilityLabel("Background work")
            .accessibilityValue(monitor.items.isEmpty ? "Finished" : "\(monitor.items.count) running")
            .accessibilityIdentifier("rail.backgroundWork")
            .popover(isPresented: $isShown, arrowEdge: .trailing) {
                BackgroundWorkList(monitor: monitor, title: title(for:))
            }
            .transition(.opacity)
        }
    }

    private var helpText: String {
        switch monitor.items.count {
        case 0: return "Audio finished — click to see how it went"
        case 1: return "1 thing is running in the background — click to see it"
        default: return "\(monitor.items.count) things are running in the background — click to see them"
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if monitor.items.isEmpty {
            let hasProblem = monitor.finished.contains { $0.isProblem }
            Image(systemName: hasProblem ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hasProblem ? Color.orange : Color.secondary)
        } else if monitor.items.count == 1, let fraction = monitor.items[0].fraction {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
        } else {
            // Still and grey: a spinning wheel in the rail is a distraction
            // (product owner, 2026-10-11: "not spinning because that's
            // distraction"). The popover says what is running.
            Image("OpenRouterIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(Color.secondary)
        }
    }

    private func title(for item: BackgroundWorkItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        if let sourceID = item.sourceID,
           let title = vm.articles.first(where: { $0.id == sourceID })?.title {
            return title
        }
        return item.kind == .modelCall ? "Library" : "Narration"
    }
}

private struct BackgroundWorkList: View {
    @ObservedObject var monitor: BackgroundWorkMonitor
    let title: (BackgroundWorkItem) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(monitor.items.isEmpty ? "Finished" : "Running in the background")
                .font(.system(size: 12.5, weight: .semibold))
            if monitor.items.isEmpty && monitor.finished.isEmpty {
                Text("Nothing is running.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(monitor.items) { item in
                row(item)
            }
            if !monitor.finished.isEmpty {
                if !monitor.items.isEmpty {
                    Divider()
                    Text("Finished")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                ForEach(monitor.finished) { done in
                    finishedRow(done)
                }
                Button("Dismiss") { monitor.dismissFinished() }
                    .controlSize(.small)
                    .accessibilityIdentifier("rail.backgroundWork.dismiss")
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func finishedRow(_ done: FinishedNarration) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done.isProblem ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(done.isProblem ? Color.orange : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(done.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                if done.isProblem {
                    Text([done.outcome, done.detail].compactMap { $0 }.joined(separator: " — "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ item: BackgroundWorkItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(item))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                Text(item.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                // A bar only for work that reports its share; the rail's
                // spinner already says the rest is running (product owner, 2026-10-10).
                if let fraction = item.fraction {
                    ProgressView(value: fraction).controlSize(.small)
                }
                HStack(spacing: 6) {
                    if let startedAt = item.startedAt {
                        Text(startedAt, style: .relative)
                    }
                    if let spend = item.spend { Text("· \(spend)") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if item.stop != .none {
                Button { monitor.stop(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0))
                .help("Stop")
                .accessibilityLabel("Stop \(title(item))")
            }
        }
    }
}
#endif
