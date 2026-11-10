// Citation contexts, try-again models, the transcript chooser and lookups for the chat transcript.
import SwiftUI
import AppKit

/// A walkthrough step's animation, opened large from its row.

// MARK: - One-page transcript

/// Which replies cite which sources, by number, for the whole transcript
/// (`ChatCitationLedger`): written by whichever transcript is on screen.
@MainActor
enum ReviewChatCitationContexts {
    static func contexts(for manager: ReviewSessionManager) -> [UUID: ChatCitationLedger.MessageContext] {
        ChatCitationLedger.contexts(
            for: manager.chatMessages.compactMap { message in
                // Only an assistant reply renders markdown, so only an
                // assistant reply can cite: a source link a learner typed is
                // their own text and never becomes a numbered citation.
                guard message.role == .assistant,
                      message.toolActivity == nil,
                      let markdown = ReviewSessionManager.displayableMessageContent(
                          role: message.role,
                          content: message.content
                      )
                else { return nil }
                return ChatCitationLedger.Entry(id: message.id, markdown: markdown)
            },
            open: manager.streamingMessageID
        )
    }
}

extension ReviewChatWorkingIndicator.Phase {
    /// What the running turn is doing, named for the learner.
    @MainActor
    static func current(manager: ReviewSessionManager, walkthroughPreparation: String?) -> Self {
        // A walk getting a step ready is preparing, whatever else is idle: its
        // detail names the step, and no model has been asked anything.
        if walkthroughPreparation != nil, !manager.isGenerating { return .preparing }
        if manager.isPlanningMemoryReview { return .planning }
        if manager.isSearching { return .searching }
        guard manager.isGenerating else { return .preparing }
        guard let streamingID = manager.streamingMessageID,
              let streamed = manager.chatMessages.last(where: { $0.id == streamingID }) else {
            return .thinking
        }
        return streamed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .thinking
            : .writing
    }
}

/// The chat picker's models for Try Again With on the page's ⋯, read off the
/// main thread the first time a menu opens and kept fresh each time after.
@MainActor
enum ChatTryAgainModels {
    private(set) static var entries: [AIModelCatalogEntry] = []
    private static var refreshing: Task<Void, Never>?

    static func refresh() {
        guard refreshing == nil else { return }
        refreshing = Task { @MainActor in
            let loaded = await Task.detached(priority: .utility) {
                InlineModelPicker.loadMenuEntries(task: .chat)
            }.value
            entries = loaded
            refreshing = nil
        }
    }
}

/// The one-page transcript for every chat, and the native one for a memory
/// review dealt as cards. It reads nothing per token, so a streamed token
/// re-evaluates the transcript and not the panel.
struct ReviewChatTranscriptChooser<Native: View, Page: View>: View {
    let showsNative: Bool
    let native: Native
    let page: Page

    init(
        showsNative: Bool,
        @ViewBuilder native: () -> Native,
        @ViewBuilder page: () -> Page
    ) {
        self.showsNative = showsNative
        self.native = native()
        self.page = page()
    }

    var body: some View {
        if showsNative {
            native
        } else {
            page
        }
    }
}

/// The lookups the page's rows need from the library and the panel, read as
/// the page is built: titles as they stand now, and what the panel decides.
struct ChatTranscriptLookups {
    /// A Page's title as the library holds it now, else the one the tool gave.
    let pageTitle: (ChatWrittenPage) -> String
    /// The name a walk's resume row gives its source or animation.
    let walkTitle: (String) -> String
    /// "2 of 5": a reviewed source's place in the day, when it has one.
    let reviewPosition: (String) -> String?
    /// The source a saved-cards card names, and how many cards were not saved.
    let savedCardsSubtitle: (ChatSavedCards) -> String?
    /// Skip, under the newest reply while a quiz question waits.
    let offersQuizSkip: (ReviewChatTranscriptRowContext) -> Bool
}
