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

struct MobilePreparedTextToSpeechNarration {
    let text: String
    let sourceContentSignature: String?
    let preparationSignature: String?
}

extension Notification.Name {
    static let mobileListeningCatalogDidChange = Notification.Name("MobileListeningCatalogDidChange")
}
