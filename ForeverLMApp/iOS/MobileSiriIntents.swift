import AppIntents
import Foundation

struct MobileSiriCommand: Codable, Equatable {
    enum Action: String, Codable {
        case ask
        case listSources
        case playSource
        case playLatestSource
        case playLatestPaper
        case quiz
        case memoryReview
        /// Memory Check by Voice: today's cards, then today's review, out loud
        /// (`MobileRealtimeVoice.startMemoryCheck`).
        case voiceMemoryCheck
        case askAboutSource
        case pausePlayback
        case resumePlayback
        case stopPlayback
        case stopReview
        case openToday
    }

    let action: Action
    let query: String?
    // Set when the command came from a resolved source entity (Siri AI / CarPlay), so
    // the review starts on an exact source_id instead of fuzzy-matching the query text.
    let sourceID: String?

    init(action: Action, query: String? = nil, sourceID: String? = nil) {
        self.action = action
        self.query = query
        self.sourceID = sourceID
    }

    static func ask(_ request: String) -> MobileSiriCommand {
        MobileSiriCommand(action: .ask, query: request)
    }

    static func quiz(_ topic: String, sourceID: String? = nil) -> MobileSiriCommand {
        MobileSiriCommand(action: .quiz, query: topic, sourceID: sourceID)
    }

    static func memoryReview() -> MobileSiriCommand {
        MobileSiriCommand(action: .memoryReview)
    }

    static func voiceMemoryCheck() -> MobileSiriCommand {
        MobileSiriCommand(action: .voiceMemoryCheck)
    }

    static func askAboutSource(_ source: SourceEntity, question: String? = nil) -> MobileSiriCommand {
        MobileSiriCommand(action: .askAboutSource, query: question, sourceID: source.id)
    }

    static func listSources(_ query: String? = nil) -> MobileSiriCommand {
        MobileSiriCommand(action: .listSources, query: query)
    }

    static func playSource(_ title: String, sourceID: String? = nil) -> MobileSiriCommand {
        MobileSiriCommand(action: .playSource, query: title, sourceID: sourceID)
    }

    static func playLatestSource() -> MobileSiriCommand {
        MobileSiriCommand(action: .playLatestSource, query: nil)
    }

    static func playLatestPaper() -> MobileSiriCommand {
        MobileSiriCommand(action: .playLatestPaper, query: nil)
    }

    static func openToday() -> MobileSiriCommand {
        MobileSiriCommand(action: .openToday)
    }
}

extension Notification.Name {
    static let mobileSiriCommandQueued = Notification.Name("MobileSiriCommandQueued")
}

final class MobileSiriCommandCenter {
    static let shared = MobileSiriCommandCenter()

    private let key = "ios.siri.pendingCommand"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    var hasPendingCommand: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }

    func enqueue(_ command: MobileSiriCommand) {
        guard let data = try? encoder.encode(command) else {
            return
        }

        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: .mobileSiriCommandQueued, object: nil)
    }

    func takePendingCommand() -> MobileSiriCommand? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let command = try? decoder.decode(MobileSiriCommand.self, from: data) else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }

        UserDefaults.standard.removeObject(forKey: key)
        return command
    }
}

enum MobileSiriSourceCatalog {
    static func loadSources() async -> [MobileCloudSource] {
        let manifests = await Task.detached(priority: .userInitiated) {
            (try? SyncedArticleAudioStore.loadAvailableManifests()) ?? []
        }.value
        let manifestIDs = Set(manifests.map(\.sourceID))

        do {
            let catalog = try await MobileCloudSourceCatalog.shared.loadSources(forceRefresh: true)
            return catalog
                .filter { !$0.isArchived }
                .map { source in
                    MobileCloudSource(
                        id: source.id,
                        title: source.title,
                        subtitle: source.subtitle,
                        sourceType: source.sourceType,
                        dateAdded: source.dateAdded,
                        hasAudio: manifestIDs.contains(source.id),
                        isArchived: false
                    )
                }
                .sorted { $0.dateAdded > $1.dateAdded }
        } catch {
            return manifests.map {
                MobileCloudSource(
                    id: $0.sourceID,
                    title: $0.title,
                    subtitle: $0.subtitle,
                    sourceType: canonicalSourceType($0.sourceType),
                    dateAdded: $0.createdAt,
                    hasAudio: true,
                    isArchived: false
                )
            }
        }
    }
}

struct AskForeverLMIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask ForeverLM"
    static var description = IntentDescription("Send a natural voice request to ForeverLM.")
    static var openAppWhenRun = true

    @Parameter(title: "Request")
    var request: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(.ask(request))
        return .result(dialog: "Opening ForeverLM.")
    }
}

struct QuizSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Quiz Me With ForeverLM"
    static var description = IntentDescription("Open ForeverLM and run a hands-free review on a source.")
    static var openAppWhenRun = true

    @Parameter(title: "Source")
    var source: SourceEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(.quiz(source.title, sourceID: source.id))
        return .result(dialog: "Opening ForeverLM to quiz you on \(source.title).")
    }
}

struct StartMemoryReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Memory Review"
    static var description = IntentDescription("Open ForeverLM and go through today's memory cards.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(.memoryReview())
        return .result(dialog: "Opening your memory review.")
    }
}

/// Today's memory check out loud, with nothing to tap: the due cards, then
/// today's memory review, asked and graded by voice (product owner,
/// 2026-11-09: "the memory check also fully via voice … so i can do it on my
/// way to the gym in the morning"; "imagine i'm walking on the street and
/// talking to it"). Siri's "Start my memory review" runs this one, since
/// whoever asks Siri is already talking; the deck on screen stays Start
/// Memory Review, in Shortcuts and on the reminder.
struct StartMemoryCheckByVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Memory Check by Voice"
    static var description = IntentDescription("Today's cards, then today's memory review, out loud: ForeverLM asks, you answer, and every answer is graded and saved.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(.voiceMemoryCheck())
        return .result(dialog: "Starting your memory check.")
    }
}

struct AskAboutSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask About a ForeverLM Source"
    static var description = IntentDescription("Open ForeverLM and ask questions about a source.")
    static var openAppWhenRun = true

    @Parameter(title: "Source")
    var source: SourceEntity

    @Parameter(title: "Question", default: "")
    var question: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        MobileSiriCommandCenter.shared.enqueue(
            .askAboutSource(source, question: trimmed.isEmpty ? nil : trimmed)
        )
        if trimmed.isEmpty {
            return .result(dialog: "Opening ForeverLM to discuss \(source.title).")
        }
        return .result(dialog: "Opening ForeverLM to answer your question about \(source.title).")
    }
}

struct ListSourcesIntent: AppIntent {
    static var title: LocalizedStringResource = "List ForeverLM Sources"
    static var description = IntentDescription("List the latest sources in ForeverLM.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sources = await MobileSiriSourceCatalog.loadSources()
        let response = MobileSourceVoiceFormatter.listPrompt(for: "list sources", sources: sources)
        return .result(dialog: IntentDialog(stringLiteral: response))
    }
}

struct FindSourcesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find ForeverLM Sources"
    static var description = IntentDescription("Find sources in ForeverLM by topic.")

    @Parameter(title: "Topic")
    var topic: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sources = await MobileSiriSourceCatalog.loadSources()
        let ranked = await MobileSemanticSourceSearch.search(for: topic, in: sources, limit: 20)
        let candidates = ranked.isEmpty ? sources : ranked
        let response = MobileSourceVoiceFormatter.listPrompt(
            for: "what sources do we have for \(topic)",
            sources: candidates
        )
        return .result(dialog: IntentDialog(stringLiteral: response))
    }
}

struct PlaySourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Play ForeverLM Source"
    static var description = IntentDescription("Open ForeverLM and play a source.")
    static var openAppWhenRun = true

    @Parameter(title: "Source")
    var source: SourceEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(.playSource(source.title, sourceID: source.id))
        return .result(dialog: "Opening ForeverLM to play \(source.title).")
    }
}

struct PlayLatestSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Latest ForeverLM Paper"
    static var description = IntentDescription("Open ForeverLM and play the latest paper, generating narration first when needed.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(.playLatestPaper())
        return .result(dialog: "Opening ForeverLM to play your latest paper.")
    }
}

struct PausePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause ForeverLM Playback"
    static var description = IntentDescription("Pause audio playback in ForeverLM.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(MobileSiriCommand(action: .pausePlayback))
        return .result(dialog: "Pausing playback.")
    }
}

struct ResumePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume ForeverLM Playback"
    static var description = IntentDescription("Resume audio playback in ForeverLM.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(MobileSiriCommand(action: .resumePlayback))
        return .result(dialog: "Resuming playback.")
    }
}

struct StopPlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop ForeverLM Playback"
    static var description = IntentDescription("Stop audio playback in ForeverLM.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(MobileSiriCommand(action: .stopPlayback))
        return .result(dialog: "Stopping playback.")
    }
}

struct StopReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Review"
    static var description = IntentDescription("End the active review or source chat in ForeverLM.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(MobileSiriCommand(action: .stopReview))
        return .result(dialog: "Ending the review.")
    }
}

enum CaptureType: String, AppEnum {
    case article
    case paper
    case podcast
    case video
    case xPost

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Source Type")
    static let caseDisplayRepresentations: [CaptureType: DisplayRepresentation] = [
        .article: "Article",
        .paper: "Paper",
        .podcast: "Podcast",
        .video: "Video",
        .xPost: "X Post",
    ]

    var storageValue: String {
        self == .xPost ? "xpost" : rawValue
    }
}

struct OpenTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Today's Learning Plan"
    static var description = IntentDescription("Open ForeverLM on today's scheduled sources.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileSiriCommandCenter.shared.enqueue(.openToday())
        return .result(dialog: "Opening today's learning plan.")
    }
}

struct ScheduleSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Schedule a ForeverLM Source"
    static var description = IntentDescription("Add a synced source to the ForeverLM Schedule.")

    @Parameter(title: "Source")
    var source: SourceEntity

    @Parameter(title: "Date")
    var date: Date

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await MobileCloudSourceCatalog.shared.loadSources(forceRefresh: true)
        guard let mobileSource = await MobileCloudSourceCatalog.shared
            .currentSources()
            .first(where: { $0.id == source.id }) else {
            throw MobileCloudMutationError.missingRecord
        }
        let placements = await MobileCloudSourceCatalog.shared.currentScheduledSources()
        let existing = placements.first { $0.sourceID == source.id }
        let order = placements.filter { Calendar.current.isDate($0.plannedAt, inSameDayAs: date) }.count
        try await MobileCloudMutationService.shared.schedule(
            source: mobileSource,
            on: date,
            notebookID: nil,
            existing: existing,
            order: order
        )
        return .result(dialog: "Scheduled \(source.title).")
    }
}

struct CaptureSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a Source to ForeverLM"
    static var description = IntentDescription("Capture a web link from Shortcuts or the Share Sheet.")

    @Parameter(title: "URL")
    var url: URL

    @Parameter(title: "Title", default: "")
    var sourceTitle: String

    @Parameter(title: "Type", default: .article)
    var sourceType: CaptureType

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await MobileCloudMutationService.shared.captureSource(
            url: url,
            title: title.isEmpty ? nil : title,
            sourceType: sourceType.storageValue
        )
        return .result(dialog: "Added the source to ForeverLM.")
    }
}

struct ForeverLMAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenTodayIntent(),
            phrases: [
                "Open today's plan in \(.applicationName)",
                "What am I learning today in \(.applicationName)"
            ],
            shortTitle: "Today's Plan",
            systemImageName: "calendar"
        )

        AppShortcut(
            intent: StartMemoryCheckByVoiceIntent(),
            phrases: [
                "Start my memory review in \(.applicationName)",
                "Start my memory check in \(.applicationName)",
                "Review what I remember with \(.applicationName)",
                "Review my cards with \(.applicationName)"
            ],
            shortTitle: "Memory Check",
            systemImageName: "waveform"
        )

        AppShortcut(
            intent: ScheduleSourceIntent(),
            phrases: [
                "Schedule \(\.$source) in \(.applicationName)"
            ],
            shortTitle: "Schedule Source",
            systemImageName: "calendar.badge.plus"
        )

        AppShortcut(
            intent: CaptureSourceIntent(),
            phrases: [
                "Add a source to \(.applicationName)"
            ],
            shortTitle: "Add Source",
            systemImageName: "plus"
        )

        AppShortcut(
            intent: AskForeverLMIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)"
            ],
            shortTitle: "Ask ForeverLM",
            systemImageName: "waveform"
        )

        AppShortcut(
            intent: QuizSourceIntent(),
            phrases: [
                "Quiz me with \(.applicationName)",
                "Quiz me on \(\.$source) with \(.applicationName)",
                "Review \(\.$source) with \(.applicationName)"
            ],
            shortTitle: "Quiz Me",
            systemImageName: "brain.head.profile"
        )

        AppShortcut(
            intent: AskAboutSourceIntent(),
            phrases: [
                "Ask \(.applicationName) about \(\.$source)",
                "Ask about \(\.$source) in \(.applicationName)"
            ],
            shortTitle: "Ask About Source",
            systemImageName: "text.bubble"
        )

        AppShortcut(
            intent: FindSourcesIntent(),
            phrases: [
                "Find sources in \(.applicationName)",
                "Search sources in \(.applicationName)"
            ],
            shortTitle: "Find Sources",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: PlayLatestSourceIntent(),
            phrases: [
                "Listen to my latest paper in \(.applicationName)",
                "Read me the latest paper from \(.applicationName)",
                "Play my latest paper in \(.applicationName)"
            ],
            shortTitle: "Play Latest Paper",
            systemImageName: "play.circle"
        )

        AppShortcut(
            intent: PlaySourceIntent(),
            phrases: [
                "Play \(\.$source) in \(.applicationName)",
                "Read \(\.$source) in \(.applicationName)"
            ],
            shortTitle: "Play Source",
            systemImageName: "speaker.wave.2"
        )
    }
}
