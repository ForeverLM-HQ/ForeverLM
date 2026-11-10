// Whole-book audiobook plans and source language resolution.
#if os(macOS)
import AVFoundation
import CryptoKit
import Foundation
import MediaPlayer
import os
import PDFKit
import SwiftUI
import WebKit

extension ArticleSpeechService {
    // MARK: - Whole book

    /// What generating the rest of a book would take: the chapters that still
    /// need audio, in reading order, and one price for all of them.
    ///
    /// Listening already auto-advances chapter to chapter and quotes the book
    /// once, so the price is a book-level idea here too. The point of asking it
    /// up front is that the answer is one dialog rather than one per chapter.
    struct AudiobookPlan: Equatable {
        let groupID: String
        let title: String
        /// Readable chapters with no cached audio yet, in reading order.
        let chapters: [StudioArticle]
        /// Chapters already narrated, so a mostly-done book can say so.
        let readyChapterCount: Int
        let estimate: ArticleSpeechCostEstimate
        /// The model the quote was priced against.
        let model: String
        /// Whether generating this costs anything. An exact zero-price model
        /// still generates; it just does not need an answer first.
        var isBillable: Bool { (estimate.usd ?? 1) > 0 }
    }

    /// Prices a whole book without preparing any of its narration.
    ///
    /// Deliberately cheaper than the per-chapter path: it never extracts,
    /// chunks, or normalizes text. Stored content lengths stand in for
    /// narration length, with word counts behind them for a chapter whose text
    /// has not been extracted yet — the same approximation the existing
    /// whole-book line in the listening confirmation uses, and the same
    /// off-main lookups, because a forty-chapter book must not touch the main
    /// actor to answer this.
    func audiobookPlan(forBookGroup groupID: String) async -> AudiobookPlan? {
        guard let scope = bookScopeProvider?(groupID) else { return nil }
        let provider = MacArticleSpeechSettings.provider
        guard provider.isCloudProvider else { return nil }
        let model = MacArticleSpeechSettings.model(for: provider)
        let readable = scope.chapters.filter { ArticleSpeechContent.canAttemptRead($0) }
        guard !readable.isEmpty else { return nil }

        let wordCounts = Dictionary(
            readable.compactMap { chapter in chapter.wordCount.map { (chapter.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let ids = readable.map(\.id)
        let storage = activityStorage
        let pending = await Task.detached(priority: .userInitiated) { () async -> (uncached: Set<String>, characters: Int) in
            let uncached = ids.filter { !ArticleSpeechAudioCache.hasCachedAudio(sourceID: $0) }
            guard !uncached.isEmpty else { return ([], 0) }
            let lengths = await storage.sourceContentLengths(for: uncached)
            let characters = uncached.reduce(0) { total, id in
                if let length = lengths[id] { return total + length }
                guard let words = wordCounts[id] else { return total }
                return total + Int((Double(words) * ArticleSpeechCostEstimate.fallbackCharactersPerWord).rounded())
            }
            return (Set(uncached), characters)
        }.value

        let chapters = readable.filter { pending.uncached.contains($0.id) }
        guard !chapters.isEmpty else { return nil }
        return AudiobookPlan(
            groupID: groupID,
            title: scope.title,
            chapters: chapters,
            readyChapterCount: readable.count - chapters.count,
            estimate: ArticleSpeechCostEstimate(
                characters: pending.characters,
                sourceCount: chapters.count,
                provider: provider.rawValue,
                model: model
            ),
            model: model
        )
    }

    /// Asks once for the whole book. The suppression switch is deliberately
    /// absent: "don't ask again" belongs to a single chapter's small charge,
    /// not to an answer that authorizes a book-sized one.
    static func confirmAudiobookGeneration(_ plan: AudiobookPlan) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Generate the audiobook for \u{201C}\(plan.title)\u{201D}?"
        var lines = [plan.model, plan.estimate.summary(countingSourcesAs: "chapter")]
        if plan.readyChapterCount > 0 {
            let noun = plan.readyChapterCount == 1 ? "chapter" : "chapters"
            lines.append("\(plan.readyChapterCount) \(noun) already narrated, and not charged again.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Generate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Upfront price check before billable text-to-speech generation. Returns true
    /// when the user chooses to proceed. Checking "Don't ask again for this
    /// model" suppresses only this model, across all of its voices, and persists
    /// only on confirm — cancelling must never silently authorize future spend.
    static func confirmGenerationCost(
        provider: MacArticleSpeechMode,
        model: String,
        uncachedCharacters: Int,
        book: BookGenerationEstimate? = nil
    ) -> Bool {
        let source = ArticleSpeechCostEstimate(
            characters: uncachedCharacters,
            provider: provider.rawValue,
            model: model
        )

        let alert = NSAlert()
        if let book {
            let wholeBook = source.adding(book.remainingChapters)
            alert.messageText = "Generate text-to-speech audio for \u{201C}\(book.title)\u{201D}?"
            alert.informativeText = """
                \(model)
                This chapter · \(source.summary)
                Whole book · \(wholeBook.summary(countingSourcesAs: "chapter"))
                """
        } else {
            alert.messageText = "Generate text-to-speech audio?"
            alert.informativeText = "\(model) · \(source.summary)"
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again for this model"

        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on {
            MacArticleSpeechSettings.setConfirmsCostBeforeListening(false, for: model)
        }
        return confirmed
    }

    // MARK: - Source language

    /// The model, voice, and on-device voice this source's own language calls
    /// for, plus what the listener should be told about the choice.
    struct ResolvedSpeechSelection {
        let model: String
        let voice: String
        /// An `AVSpeechSynthesisVoice` identifier for on-device narration, when
        /// the source needs one the listener has not selected.
        let appleVoiceIdentifier: String?
        let notice: ArticleSpeechLanguageNotice?
        /// The language the notice is about, so one answer can cover a whole
        /// book instead of every chapter in it.
        let unnarratableLanguage: String?
    }

    /// Decides what will read this source aloud.
    ///
    /// The listener picks one voice in Settings and then imports a paper in
    /// German. Almost every catalog voice is English-only and will happily
    /// generate — and bill for — German words read with English phonemes, which
    /// is unlistenable and indistinguishable from a broken model. So the
    /// language is recognized from the narration itself, off-main, before
    /// anything is chunked, cached, or charged: if the catalog has a voice that
    /// speaks it, this source quietly gets that voice; if it does not, the
    /// listener is told before the money goes out.
    func resolveSpeechSelection(
        provider: MacArticleSpeechMode,
        content: String,
        sourceID: String
    ) async -> ResolvedSpeechSelection {
        var model = MacArticleSpeechSettings.model(for: provider)
        var voice = MacArticleSpeechSettings.voice(for: provider)

        if provider == .apple {
            let selected = appleVoiceIdentifier
            let resolved = await Task.detached(priority: .userInitiated) {
                Self.resolveAppleSpeechLanguage(content: content, selectedVoiceIdentifier: selected)
            }.value
            return ResolvedSpeechSelection(
                model: model,
                voice: resolved.identifier ?? voice,
                appleVoiceIdentifier: resolved.identifier,
                notice: resolved.notice.map {
                    ArticleSpeechLanguageNotice(sourceID: sourceID, kind: $0.kind, message: $0.message)
                },
                unnarratableLanguage: resolved.unnarratableLanguage
            )
        }

        // The catalog only describes the managed OpenRouter rail. A stored
        // retired provider is already rejected by `configurationError`; never
        // answer it by silently moving the listener onto OpenRouter.
        guard provider == .openRouter else {
            return ResolvedSpeechSelection(
                model: model,
                voice: voice,
                appleVoiceIdentifier: nil,
                notice: nil,
                unnarratableLanguage: nil
            )
        }

        // The catalog is OpenRouter's speech list; a Mac that has never read
        // it knows only the models this build records, and the language fit,
        // the chunk sizes and the price below all read the selected model's
        // entry. Returns at once when a read exists. A stored pick the list
        // stopped offering is repaired as Settings repairs it, and the
        // listener is told once; a model the list does not offer otherwise
        // is left as it is — the speech request refuses it by name — rather
        // than swapped for another model on account of its language.
        await OpenRouterAudioDirectory.prepare(.speech)
        let repair = await Task.detached(priority: .userInitiated) {
            MacArticleSpeechSettings.repairSelectionForUse()
        }.value
        var repairNotice: ArticleSpeechLanguageNotice?
        if let repair {
            model = repair.newModel
            voice = repair.newVoice
            apply(MacArticleSpeechConfiguration(provider: provider, voice: voice))
            repairNotice = ArticleSpeechLanguageNotice(sourceID: sourceID, kind: .adjusted, message: repair.message)
            ArticleSpeechDiagnostics.append(
                "SELECTION_REPAIRED source=\(sourceID) old=\(repair.oldModel) model=\(model) voice=\(voice)"
            )
        }
        // A pick applied while its test could not finish, or whose pass has
        // run out, is tested now, beside this request.
        AIModelQualification.testSpeechWhenDue(model: model, voice: voice)
        guard ArticleSpeechCatalog.model(id: model) != nil else {
            return ResolvedSpeechSelection(
                model: model,
                voice: voice,
                appleVoiceIdentifier: nil,
                notice: repairNotice,
                unnarratableLanguage: nil
            )
        }

        let resolution = await Task.detached(priority: .userInitiated) { [model, voice] in
            ArticleSpeechLanguageResolution.resolve(text: content, model: model, voice: voice)
        }.value
        let notice: ArticleSpeechLanguageNotice? = resolution.message.map { message in
            ArticleSpeechLanguageNotice(
                sourceID: sourceID,
                kind: resolution.changesSelection ? .adjusted : .unsupported,
                message: [repairNotice?.message, message].compactMap { $0 }.joined(separator: " ")
            )
        } ?? repairNotice
        if let language = resolution.languageCode {
            ArticleSpeechDiagnostics.append(
                "LANGUAGE source=\(sourceID) detected=\(language) model=\(resolution.model) voice=\(resolution.voice)"
            )
        }
        return ResolvedSpeechSelection(
            model: resolution.model,
            voice: resolution.voice,
            appleVoiceIdentifier: nil,
            notice: notice,
            unnarratableLanguage: resolution.outcome == .unsupported ? resolution.languageCode : nil
        )
    }

    struct AppleSpeechLanguageResolution: Sendable {
        let identifier: String?
        let notice: (kind: ArticleSpeechLanguageNotice.Kind, message: String)?
        let unnarratableLanguage: String?
    }

    /// On-device narration has its own catalog: whatever voices macOS has
    /// installed. Enumerating them and recognizing the language both walk real
    /// data — blocking work, never on the main actor.
    private nonisolated static func resolveAppleSpeechLanguage(
        content: String,
        selectedVoiceIdentifier: String?
    ) -> AppleSpeechLanguageResolution {
        guard let code = ArticleSpeechLanguage.detect(in: content) else {
            return AppleSpeechLanguageResolution(identifier: nil, notice: nil, unnarratableLanguage: nil)
        }
        let selected = selectedVoiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        let selectedLanguage = selected.flatMap { ArticleSpeechLanguage.primaryCode($0.language) }
            ?? ArticleSpeechLanguage.primaryCode(AVSpeechSynthesisVoice.currentLanguageCode())
        if selectedLanguage == code {
            return AppleSpeechLanguageResolution(identifier: nil, notice: nil, unnarratableLanguage: nil)
        }

        let name = ArticleSpeechLanguage.displayName(for: code)
        let installed = AVSpeechSynthesisVoice.speechVoices()
            .filter { ArticleSpeechLanguage.primaryCode($0.language) == code }
        guard let best = installed.max(by: { $0.quality.rawValue < $1.quality.rawValue }) else {
            return AppleSpeechLanguageResolution(
                identifier: nil,
                notice: (
                    .unsupported,
                    """
                    This source is in \(name), and macOS has no \(name) voice installed. \
                    Add one in System Settings › Accessibility › Spoken Content, or the \
                    narration will be read with the wrong pronunciation.
                    """
                ),
                unnarratableLanguage: code
            )
        }
        return AppleSpeechLanguageResolution(
            identifier: best.identifier,
            notice: (
                .adjusted,
                "This source is in \(name). Reading it with the on-device \(best.name) voice."
            ),
            unnarratableLanguage: nil
        )
    }

    /// Last stop before paying to generate narration no voice can pronounce.
    /// Unlike the price check this is not suppressible: the cost dialog answers
    /// "how much", and this answers "will the audio be usable at all".
    private static func confirmUnnarratableLanguage(message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Generate audio in a language no voice speaks?"
        alert.informativeText = message
        alert.addButton(withTitle: "Generate Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Presents the language decision for `article` and returns false when the
    /// listener backed out. One answer covers the book a chapter belongs to.
    ///
    /// `showsNotice` is false for background generation: the notice belongs to
    /// the player, and a source generating quietly in the background must not
    /// replace the one the listener is hearing right now.
    func acceptLanguageResolution(
        _ resolution: ResolvedSpeechSelection,
        article: StudioArticle,
        isBillable: Bool,
        showsNotice: Bool = true
    ) -> Bool {
        if showsNotice { languageNotice = resolution.notice }
        guard let language = resolution.unnarratableLanguage,
              let message = resolution.notice?.message,
              isBillable else { return true }

        let scope = article.parentGroup ?? article.id
        if acknowledgedUnnarratableLanguages[scope] == language { return true }
        guard Self.confirmUnnarratableLanguage(message: message) else { return false }
        acknowledgedUnnarratableLanguages[scope] = language
        return true
    }
}
#endif
