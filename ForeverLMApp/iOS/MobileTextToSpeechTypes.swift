// The value types behind text-to-speech preparation, progress and cost.

import Foundation

struct MobileAudioItem: Identifiable, Equatable {
    let manifest: SyncedArticleAudioManifest

    var id: String { manifest.sourceID }
    var title: String { manifest.title }
    var subtitle: String? { manifest.subtitle }
    var createdAt: Date { manifest.createdAt }
}

/// Concrete text-to-speech generation state for the iPhone's progress surfaces.
/// A chunk is one bounded speech request group; split retries stay within that
/// group so progress never jumps backwards when a provider rejects long text.
struct MobileTextToSpeechGenerationProgress: Equatable {
    let completedChunks: Int
    let totalChunks: Int
    let startedAt: Date
    /// The catalog name of the model narrating — the resolved one, which a
    /// language substitution may have chosen over the Settings pick.
    let modelName: String

    init(completedChunks: Int, totalChunks: Int, startedAt: Date, model: String) {
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.startedAt = startedAt
        self.modelName = ArticleSpeechCatalog.model(id: model)?.name ?? model
    }

    var fractionCompleted: Double {
        guard totalChunks > 0 else { return 0 }
        return min(max(Double(completedChunks) / Double(totalChunks), 0), 1)
    }

    var percentCompleted: Int {
        Int((fractionCompleted * 100).rounded())
    }

    func estimatedRemaining(at date: Date) -> TimeInterval? {
        guard completedChunks > 0, completedChunks < totalChunks else { return nil }
        let elapsed = max(date.timeIntervalSince(startedAt), 0)
        return (elapsed / Double(completedChunks)) * Double(totalChunks - completedChunks)
    }
}

/// A narration coming down from iCloud for the iPhone's progress surfaces.
/// Its remedy is different from generation's — wait, or find better Wi-Fi —
/// so the UI names it apart, with the count that tells the listener how far
/// the phone is from having the whole chapter.
struct MobileNarrationDownloadProgress: Equatable {
    let title: String
    let readyChunks: Int
    let contiguousChunks: Int
    let totalChunks: Int
    let startedAt: Date
    /// True once the chunks that have arrived are already playing.
    let isPlayingPrefix: Bool

    var fractionCompleted: Double {
        guard totalChunks > 0 else { return 0 }
        return min(max(Double(readyChunks) / Double(totalChunks), 0), 1)
    }

    var percentCompleted: Int {
        Int((fractionCompleted * 100).rounded())
    }

    func estimatedRemaining(at date: Date) -> TimeInterval? {
        guard readyChunks > 0, readyChunks < totalChunks else { return nil }
        let elapsed = max(date.timeIntervalSince(startedAt), 0)
        return (elapsed / Double(readyChunks)) * Double(totalChunks - readyChunks)
    }

    /// The one line a banner shows: what is happening, how far it is, and how
    /// long is left once there is enough history to say.
    func statusLabel(at date: Date) -> String {
        var parts: [String] = [isPlayingPrefix ? "Playing · downloading the rest" : "Downloading narration"]
        parts.append("\(readyChunks) of \(totalChunks) chunks")
        parts.append("\(percentCompleted)%")
        if let remaining = estimatedRemaining(at: date) {
            parts.append(MobileNarrationDownloadProgress.formatDuration(remaining))
        }
        return parts.joined(separator: " · ")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let rounded = max(1, Int(seconds.rounded(.up)))
        if rounded < 60 { return "\(rounded)s left" }
        let minutes = rounded / 60
        let remainder = rounded % 60
        if minutes < 60 {
            return remainder == 0 ? "\(minutes)m left" : "\(minutes)m \(remainder)s left"
        }
        return "\(minutes / 60)h \(minutes % 60)m left"
    }
}

enum MobileTextToSpeechPricingPreferences {
    /// Device-local presentation preference. Automatic generation remains an
    /// explicit Settings opt-in and never blocks on a modal confirmation.
    static var confirmsEstimatedCost: Bool {
        Preferences.value(Prefs.Mobile.readAloudConfirmsEstimatedCost) ?? true
    }
}

/// The price disclosure shown before an uncached, user-initiated narration.
/// Rates are estimates from the app's versioned speech table; the managed
/// ledger remains the exact charge and is visible in Usage.
struct MobileTextToSpeechCostConfirmation: Identifiable, Equatable {
    /// The book a chapter belongs to, when playback will carry on through it.
    /// Continuing to the next chapter generates it without asking again, so the
    /// price quoted here has to be the book's, not this chapter's.
    struct BookScope: Equatable {
        let title: String
        /// Chapters after this one that still have no audio on the phone.
        let remainingChapters: Int
        /// Narration characters for those chapters, sized from their word
        /// counts against the ratio this chapter's own narration measured.
        let remainingCharacters: Int
    }

    let id = UUID()
    let sourceID: String
    let sourceTitle: String
    let modelName: String
    let modelID: String
    let characterCount: Int
    let book: BookScope?
    /// What the language check found, when it found anything: the source is
    /// not in a language the selected voice speaks. It leads the message
    /// because it decides whether the audio is worth any price at all.
    let languageNotice: String?

    init(
        sourceID: String,
        sourceTitle: String,
        characterCount: Int,
        modelID: String,
        languageNotice: String? = nil,
        book: BookScope? = nil
    ) {
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.characterCount = characterCount
        self.modelID = modelID
        self.languageNotice = languageNotice
        self.book = book
        modelName = ArticleSpeechCatalog.model(id: modelID)?.name ?? modelID
    }

    /// This chapter alone.
    var chapterEstimate: ArticleSpeechCostEstimate {
        ArticleSpeechCostEstimate(
            characters: characterCount,
            provider: ArticleSpeechCatalog.provider,
            model: modelID
        )
    }

    /// Everything the listener is agreeing to: this chapter plus the rest of
    /// the book when there is one.
    var totalEstimate: ArticleSpeechCostEstimate {
        guard let book else { return chapterEstimate }
        return chapterEstimate.adding(
            ArticleSpeechCostEstimate(
                characters: book.remainingCharacters,
                sourceCount: book.remainingChapters,
                provider: ArticleSpeechCatalog.provider,
                model: modelID
            )
        )
    }

    var estimatedUSD: Double? { totalEstimate.usd }

    /// The price as voice mode says it before a narration is made
    /// (`listen_to_source`): the estimate, or the model's own price when
    /// there is no total to give.
    var spokenPrice: String {
        guard let estimatedUSD else {
            return "\(modelName)'s price, \(ArticleSpeechCatalog.priceLabel(forModel: modelID)); there is no total to give before it is made"
        }
        let amount = "about \(Self.priceLabel(estimatedUSD))"
        guard let book else { return amount }
        return "\(amount) for the rest of \(book.title) too, since listening carries on through its chapters"
    }

    var title: String {
        guard let estimatedUSD else { return "Generate text-to-speech audio?" }
        if estimatedUSD == 0 { return "Generate audio for free?" }
        if book != nil { return "Generate the whole book for about \(Self.priceLabel(estimatedUSD))?" }
        return "Generate audio for about \(Self.priceLabel(estimatedUSD))?"
    }

    var message: String {
        var parts: [String] = []
        if let languageNotice { parts.append(languageNotice) }
        parts.append(sourceTitle)
        if let book {
            let total = totalEstimate
            parts.append(modelName)
            parts.append("This chapter · \(Self.lengthLabel(chapterEstimate))")
            parts.append(
                "\(book.title) · \(total.sourceCount.formatted()) chapters · \(Self.lengthLabel(total))"
            )
            parts.append("Continuing to the next chapter generates it without asking again.")
        } else {
            parts.append("\(modelName) · \(Self.lengthLabel(chapterEstimate))")
        }
        if estimatedUSD == nil {
            parts.append("An estimate is unavailable. The exact charge will appear in Usage.")
        }
        if estimatedUSD == 0 {
            parts.append("This model is free; cached audio is free to replay.")
        } else {
            parts.append("Retries can add cost; cached audio is free to replay.")
        }
        return parts.joined(separator: "\n")
    }

    /// "24,000 characters · about 32 min · 36¢". Money follows the phone's
    /// house unit (cents below a dollar), not the Mac's always-dollars label.
    private static func lengthLabel(_ estimate: ArticleSpeechCostEstimate) -> String {
        var parts = [
            "\(estimate.characters.formatted()) characters",
            estimate.durationLabel,
        ]
        if let usd = estimate.usd, usd > 0 {
            parts.append(priceLabel(usd))
        }
        return parts.joined(separator: " · ")
    }

    private static func priceLabel(_ usd: Double) -> String {
        MobileCostFormat.money(microUSD: Int((usd * 1_000_000).rounded()))
    }
}

/// What generating the rest of a book takes: the chapters that still need
/// audio, in the order they will be made, and one price for all of them. The
/// phone's `ArticleSpeechService.AudiobookPlan`: asked once for the book, so
/// the answer is one question rather than one per chapter.
struct MobileAudiobookPlan: Identifiable, Equatable {
    let id = UUID()
    let bookID: String
    let title: String
    /// Chapters with no audio yet, in the order they will be generated.
    let chapterIDs: [String]
    /// Chapters already narrated, so a mostly-done book can say so.
    let readyChapterCount: Int
    let estimate: ArticleSpeechCostEstimate
    let modelName: String

    /// Whether generating this costs anything. A model priced at exactly
    /// nothing still generates; it only needs no answer first. An unknown
    /// price is asked about.
    var isBillable: Bool { (estimate.usd ?? 1) > 0 }

    /// The chapters a whole-book generation still has to make, in the order
    /// it makes them: reading order, starting after the chapter being listened
    /// to when it is one of the book's, so what the listener reaches next is
    /// ready first, and coming round to the chapters before it at the end. A
    /// chapter already being generated (a Listen tapped on it) is left to that
    /// generation, and one whose text has not arrived cannot be narrated yet.
    static func pendingChapters(
        _ chapters: [MobileCloudSource],
        hasAudio: (MobileCloudSource) -> Bool,
        isPreparing: (MobileCloudSource) -> Bool,
        listeningTo playingSourceID: String?
    ) -> [MobileCloudSource] {
        let current = chapters.filter { !$0.isArchived }
        var ordered = current
        if let playingSourceID, let index = current.firstIndex(where: { $0.id == playingSourceID }) {
            ordered = Array(current[(index + 1)...]) + Array(current[...index])
        }
        return ordered.filter { $0.state == "ready" && !hasAudio($0) && !isPreparing($0) }
    }

    /// nil when no chapter of the book is waiting for audio.
    ///
    /// Priced without preparing any narration: a chapter's listenable length
    /// when the Mac measured one, else its word count at the fallback ratio. A
    /// chapter with neither is counted but not priced, which understates the
    /// book rather than inventing a number for it.
    static func plan(
        bookID: String,
        title: String,
        chapters: [MobileCloudSource],
        hasAudio: (MobileCloudSource) -> Bool,
        isPreparing: (MobileCloudSource) -> Bool,
        listeningTo playingSourceID: String?,
        provider: String,
        modelID: String
    ) -> MobileAudiobookPlan? {
        let pending = pendingChapters(
            chapters,
            hasAudio: hasAudio,
            isPreparing: isPreparing,
            listeningTo: playingSourceID
        )
        guard !pending.isEmpty else { return nil }
        let characters = pending.reduce(0) { total, chapter in
            if let listenable = chapter.listenableCharacterCount, listenable > 0 {
                return total + listenable
            }
            guard let words = chapter.wordCount, words > 0 else { return total }
            return total + Int((Double(words) * ArticleSpeechCostEstimate.fallbackCharactersPerWord).rounded())
        }
        return MobileAudiobookPlan(
            bookID: bookID,
            title: title,
            chapterIDs: pending.map(\.id),
            readyChapterCount: chapters.filter { !$0.isArchived && hasAudio($0) }.count,
            estimate: ArticleSpeechCostEstimate(
                characters: characters,
                sourceCount: pending.count,
                provider: provider,
                model: modelID
            ),
            modelName: ArticleSpeechCatalog.model(id: modelID)?.name ?? modelID
        )
    }

    var confirmationTitle: String {
        "Generate the audiobook for \u{201C}\(title)\u{201D}?"
    }

    /// "12 chapters · 240,000 characters · about 5 hr · $3.60", then what is
    /// already narrated. Money in the phone's house unit, as the chapter
    /// confirmation writes it.
    var confirmationMessage: String {
        let count = estimate.sourceCount
        var summary = [
            "\(count.formatted()) \(count == 1 ? "chapter" : "chapters")",
            "\(estimate.characters.formatted()) characters",
            estimate.durationLabel,
        ]
        if let usd = estimate.usd, usd > 0 {
            summary.append(MobileCostFormat.money(microUSD: Int((usd * 1_000_000).rounded())))
        }
        var lines = [modelName, summary.joined(separator: " · ")]
        if readyChapterCount > 0 {
            let noun = readyChapterCount == 1 ? "chapter is" : "chapters are"
            lines.append("\(readyChapterCount.formatted()) \(noun) already narrated, and not charged again.")
        }
        if estimate.usd == nil {
            lines.append("An estimate is unavailable. The exact charge will appear in Usage.")
        }
        lines.append("Chapters are generated one after another. Stopping keeps every finished chapter.")
        return lines.joined(separator: "\n")
    }
}

/// A whole book's audio being generated, chapter after chapter.
struct MobileAudiobookGeneration: Equatable {
    let runID: UUID
    let bookID: String
    let title: String
    /// Chapters of the book that have audio now, whoever made it.
    var readyChapters: Int
    var totalChapters: Int
    var currentChapterID: String?
    var currentChapterTitle: String?
    /// The chapter in hand stopped for a reason that mends itself (the phone
    /// was locked, the network went away). Its own resume finishes it, and the
    /// book carries on from there.
    var isWaitingToResume = false
    /// Chapters this run could not narrate, left for the report at its end.
    var setAsideChapterIDs: [String] = []

    var fractionCompleted: Double {
        guard totalChapters > 0 else { return 0 }
        return min(max(Double(readyChapters) / Double(totalChapters), 0), 1)
    }

    /// "3 of 12 chapters · 4. The human side"
    var statusLabel: String {
        var parts = ["\(readyChapters) of \(totalChapters) chapters"]
        if isWaitingToResume {
            parts.insert("Waiting to resume", at: 0)
        } else if let currentChapterTitle {
            parts.append(currentChapterTitle)
        }
        return parts.joined(separator: " · ")
    }
}

/// How far the shell's bar (the player, a session banner) rises so that it
/// sits above a screen's own bottom toolbar instead of on top of it.
///
/// The bar is a safe-area inset on the shell's NavigationStack, and the stack
/// does not hand that inset on to the screens it shows, so a screen's bottom
/// toolbar (the Reader's Listen, Voice and Ask) is drawn at the bottom of the
/// window, under the bar. A screen reports where its safe area ends and where
/// the screen itself ends; one that reaches under the bar and whose safe area
/// ends above the bar's bottom has a toolbar there, and the bar rises by that
/// much. Where the system does hand the inset on, the screen ends at the bar's
/// top and nothing rises.
enum MobileShellBarLift {
    struct Screen: Equatable {
        /// Bottom of the screen's safe area, in window coordinates.
        let safeBottom: CGFloat
        /// Bottom of the screen itself, ignoring its safe area.
        let fullBottom: CGFloat
    }

    /// `barTop` and `barBottom` are the bar's edges where it rests, unlifted.
    static func lift(barTop: CGFloat, barBottom: CGFloat, screens: [Screen]) -> CGFloat {
        guard barBottom - barTop >= 1 else { return 0 }
        return screens.reduce(0) { lift, screen in
            guard screen.fullBottom > barTop + 1, screen.safeBottom > 0 else { return lift }
            return max(lift, barBottom - screen.safeBottom)
        }
    }
}

struct MobilePreparedTextToSpeechNarration {
    let text: String
    let sourceContentSignature: String?
    let preparationSignature: String?
}

extension Notification.Name {
    static let mobileListeningCatalogDidChange = Notification.Name("MobileListeningCatalogDidChange")
}
