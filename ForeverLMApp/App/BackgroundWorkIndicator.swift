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
        /// A step of the app's own processing (Text-to-Speech Preparation,
        /// Paper Metadata), for every source it is running on.
        case modelStep(step: String)
        /// Automatic source audio's run (`AutomaticSourceAudioGenerationService`).
        case automaticAudio
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
    /// Steps the learner stopped, on this Mac or another, until they resume them.
    @Published private(set) var stopped: [AIInFlightCalls.StoppedStep] = []

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
        // A stop made on another Mac refuses what starts here next; what was
        // already running here is cancelled now.
        AIInFlightCalls.shared.cancelInFlightOfStoppedSteps()
        let current = collect()
        if current != items { items = current }
        let ended = Self.collectFinished()
        if ended != finished { finished = ended }
        let held = AIInFlightCalls.shared.stoppedSteps
        if held != stopped { stopped = held }
    }

    func resume(_ step: AIInFlightCalls.StoppedStep) {
        if step.step == AutomaticAudioStep.step {
            AutomaticSourceAudioGenerationService.shared.resumeAfterStop()
        } else {
            AIInFlightCalls.shared.resume(step: step.step)
        }
        refresh()
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
        case .modelStep(let step):
            AIInFlightCalls.shared.stop(step: step)
        case .automaticAudio:
            AutomaticSourceAudioGenerationService.shared.stopFromBackgroundWork()
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

        // Automatic source audio makes narrations of its own, one source after
        // another, with nothing else showing them.
        if let progress = AutomaticSourceAudioGenerationService.shared.progress {
            var detail = "\(progress.completedCount) of \(progress.totalCount) made"
            if let current = progress.currentTitle { detail = "\(current) · " + detail }
            items.append(BackgroundWorkItem(
                id: "automatic-audio",
                kind: .narration,
                title: AIInFlightCalls.stepName(AutomaticAudioStep.step),
                sourceID: nil,
                detail: detail,
                fraction: progress.fractionCompleted,
                startedAt: nil,
                spend: nil,
                stop: .automaticAudio
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
        // quick one does not flash the spinner. One row per step, since Stop
        // stops the step wherever it runs: a queue would only move a stopped
        // source's spend on to the next source.
        let now = Date()
        var steps: [String: [AIInFlightCalls.Entry]] = [:]
        for entry in AIInFlightCalls.shared.snapshot where now.timeIntervalSince(entry.startedAt) >= 1 {
            steps[entry.step, default: []].append(entry)
        }
        let earliest = steps.mapValues { $0.map(\.startedAt).min() ?? now }
        for step in steps.keys.sorted(by: { (earliest[$0]!, $0) < (earliest[$1]!, $1) }) {
            let entries = steps[step]!
            // What it is working on: the source, or how many.
            let subjects = Set(entries.map { $0.subjectID ?? $0.sourceTitle ?? "" })
            var detail: [String] = []
            if subjects.count > 1 {
                detail.append("\(subjects.count) sources")
            } else if let title = entries.lazy.compactMap(\.sourceTitle).first {
                detail.append(title)
            }
            // The model each request is with, as the model picker names it.
            var models: [String] = []
            for entry in entries {
                guard let provider = entry.provider, let id = entry.model else { continue }
                let name = AIModelCatalog.pickerName(provider: provider, modelID: id)
                if !models.contains(name) { models.append(name) }
            }
            if !models.isEmpty { detail.append(models.sorted().joined(separator: ", ")) }
            if entries.count > 1 { detail.append("\(entries.count) requests") }
            items.append(BackgroundWorkItem(
                id: "model-\(step)",
                kind: .modelCall,
                title: AIInFlightCalls.stepName(step),
                sourceID: nil,
                detail: detail.joined(separator: " · "),
                fraction: nil,
                startedAt: earliest[step],
                spend: nil,
                stop: .modelStep(step: step)
            ))
        }
        return items
    }
}

/// The rail's OpenRouter button: always there, still and grey (a ring, when
/// one thing reports its share), and it opens the AI panel — what runs now,
/// what has run, the key and its limits (`AIUsagePanel`).
struct BackgroundWorkButton: View {
    @ObservedObject var monitor: BackgroundWorkMonitor
    /// Opens a Settings pane from a row in the panel.
    let onOpenSettings: (SettingsPane) -> Void
    @Environment(StudioViewModel.self) private var vm
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            indicator
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .railTooltip(helpText)
        .accessibilityLabel("AI Usage")
        .accessibilityValue(accessibilityState)
        .accessibilityIdentifier("rail.backgroundWork")
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            AIUsagePanel(
                monitor: monitor,
                title: title(for:),
                onOpenSettings: { pane in
                    isShown = false
                    onOpenSettings(pane)
                },
                onClose: { isShown = false }
            )
        }
        // Anything that asks for AI Usage (a missing key, a refused call)
        // lands here: Settings has no pane for it.
        .onChange(of: vm.aiUsageOpenRequest) { _, _ in isShown = true }
    }

    private var accessibilityState: String {
        if !monitor.items.isEmpty { return "\(monitor.items.count) running" }
        if !monitor.finished.isEmpty { return "Finished" }
        return monitor.stopped.isEmpty ? "Idle" : "Stopped"
    }

    private var helpText: String {
        switch monitor.items.count {
        case 0 where !monitor.finished.isEmpty: return "Audio finished — click to see how it went"
        case 0 where !monitor.stopped.isEmpty: return "Stopped work — click to resume it"
        case 0: return "AI Usage — what is running, what has run, your key"
        case 1: return "1 thing is running in the background — click to see it"
        default: return "\(monitor.items.count) things are running in the background — click to see them"
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if monitor.items.isEmpty && !monitor.finished.isEmpty {
            let hasProblem = monitor.finished.contains { $0.isProblem }
            Image(systemName: hasProblem ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hasProblem ? Color.orange : Color.secondary)
        } else if monitor.items.isEmpty && !monitor.stopped.isEmpty {
            // Only stopped steps are left: a pause, until they are resumed.
            Image(systemName: "pause.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.secondary)
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
        return "Narration"
    }
}

/// The rows of what runs, ended and is stopped, for the AI panel's
/// "Running now" section (`AIUsagePanel`).
struct BackgroundWorkList: View {
    @ObservedObject var monitor: BackgroundWorkMonitor
    let title: (BackgroundWorkItem) -> String
    /// Opens a Settings pane, for a row's Change Model link.
    let onOpenSettings: (SettingsPane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if monitor.items.isEmpty {
                Text("Nothing is running.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(monitor.items) { item in
                row(item)
            }
            if !monitor.finished.isEmpty {
                Divider()
                Text("Finished")
                    .font(.system(size: 12.5, weight: .semibold))
                ForEach(monitor.finished) { done in
                    finishedRow(done)
                }
                Button("Dismiss") { monitor.dismissFinished() }
                    .controlSize(.small)
                    .accessibilityIdentifier("rail.backgroundWork.dismiss")
            }
            if !monitor.stopped.isEmpty {
                Divider()
                Text("Stopped")
                    .font(.system(size: 12.5, weight: .semibold))
                ForEach(monitor.stopped) { step in
                    stoppedRow(step)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What Stop does, where it does more than stop the row.
    private func stopHelp(_ item: BackgroundWorkItem) -> String {
        switch item.stop {
        case .modelStep(let step) where AIInFlightCalls.staysStopped(step):
            return "Stop \(title(item)) for every source until you resume it"
        case .modelStep:
            return "Stop \(title(item)) for every source"
        case .automaticAudio:
            return "Stop automatic audio until you resume it"
        default:
            return "Stop"
        }
    }

    /// A step the learner stopped: it waits, on every Mac of the account,
    /// until they resume it here.
    private func stoppedRow(_ step: AIInFlightCalls.StoppedStep) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "pause.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(step.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
            Button { monitor.resume(step) } label: {
                Text("Resume")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0))
            .help("Let \(step.name) run again")
            .accessibilityLabel("Resume \(step.name)")
            .accessibilityIdentifier("rail.backgroundWork.resume")
        }
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

    /// Where the model behind a running step is set: its ledger task is the
    /// step's name, the same key the Activity list links from.
    private func modelSetting(of item: BackgroundWorkItem) -> AIModelSetting? {
        guard case .modelStep(let step) = item.stop else { return nil }
        return AIModelSetting(task: step)
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
                if let setting = modelSetting(of: item) {
                    Button("Change Model…") { setting.open(onOpenSettings) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help(setting.help)
                }
            }
            Spacer(minLength: 0)
            Button { monitor.stop(item) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0))
            .help(stopHelp(item))
            .accessibilityLabel("Stop \(title(item))")
        }
    }
}
#endif
