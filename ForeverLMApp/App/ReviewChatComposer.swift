import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A picture the learner pasted into the composer: raw bytes from a
/// screenshot or a browser copy, or a copied file to be read off the main
/// actor by whoever attaches it.
enum ChatPastedImage: Equatable {
    case bytes(Data, name: String)
    case file(URL)
}

struct ReviewChatComposerTextView: NSViewRepresentable {
    /// Keep SwiftUI overlays aligned with AppKit's actual glyph origin. NSTextView's
    /// line-fragment padding is otherwise implicit, which let the empty-state
    /// placeholder start underneath the insertion caret.
    static let outerHorizontalPadding: CGFloat = 2
    static let textContainerHorizontalInset: CGFloat = 3
    static let lineFragmentPadding: CGFloat = 5
    static let overlayTextLeadingInset = outerHorizontalPadding
        + textContainerHorizontalInset
        + lineFragmentPadding
    static let placeholderCaretGap: CGFloat = 2

    @Binding var text: String
    let onSubmit: () -> Void
    /// When true, the text view grabs first-responder focus as soon as it appears.
    /// Used by the ⌘K command bar so the learner can type immediately; off for the
    /// docked Chat column, which should not steal focus on launch.
    var autoFocus: Bool = false
    /// A changed non-nil token focuses an already-mounted docked composer.
    var focusRequestID: UUID? = nil
    /// Invoked when the learner presses Escape. The text view consumes Escape before it
    /// reaches SwiftUI, so the ⌘K command bar handles dismissal through here.
    var onCancel: (() -> Void)? = nil

    // MARK: Slash-command and mention autocomplete
    /// Number of rows currently shown in the `/` command or `@` mention popup. When > 0
    /// the text view intercepts arrow / Tab / Return / Escape keys to drive the popup
    /// instead of editing.
    var suggestionCount: Int = 0
    /// The connected plugins whose `@name` mention the box paints as a token.
    var mentionPlugins: [ChatPlugin] = []
    /// Move the popup highlight by the given delta (-1 up, +1 down).
    var onMoveSelection: ((Int) -> Void)? = nil
    /// Accept the highlighted suggestion. Returns `true` when it consumed the key.
    var onCommitSelection: (() -> Bool)? = nil
    /// Dismiss the popup (Escape) when it is open.
    var onDismissSuggestions: (() -> Void)? = nil

    /// Height the wrapped text needs, reported back so the composer box can grow
    /// with the draft instead of clipping it. The caller clamps it.
    var onHeightChange: ((CGFloat) -> Void)? = nil

    /// Pictures on the pasteboard when the learner pastes. When set, a paste
    /// that carries a picture goes here instead of into the text; a plain
    /// text paste is unaffected. Nil leaves paste to the text view.
    var onPasteImages: (([ChatPastedImage]) -> Void)? = nil
    /// Invoked for ⌥Return: the draft goes as a side question, one the tutor
    /// answers without grading while its own question stays open.
    var onSubmitSideQuestion: (() -> Void)? = nil
    /// Invoked for Backspace with the caret at the very start of an empty
    /// selection: the thing before the text (a side-question token) is what
    /// goes. Nil leaves Backspace to the text view.
    var onDeleteBackwardAtStart: (() -> Void)? = nil

    /// The text view is AppKit, so it never sees SwiftUI's font environment.
    /// Scaling its font off the app zoom keeps the draft the same size as the
    /// bubble it becomes once sent.
    @Environment(\.uiZoomScale) private var uiZoomScale

    private var scaledFontSize: CGFloat {
        (ChatMarkdownView.baseFontSize * uiZoomScale).rounded()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, focusRequestID: focusRequestID)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // TextKit 1: on macOS 26, TextKit 2's NSTextSelectionNavigation can spin
        // forever inside mouseDown selection hit-testing (enumerateSubstrings never
        // converges), hanging the main thread until force quit. No TextKit 2-only
        // API is used here, so opt out at creation.
        let textView = SubmitOnReturnTextView(usingTextLayoutManager: false)
        textView.onSubmit = context.coordinator.onSubmit
        textView.onCancel = onCancel
        textView.onSubmitAlternate = onSubmitSideQuestion
        textView.onDeleteBackwardAtStart = onDeleteBackwardAtStart
        textView.suggestionCount = suggestionCount
        textView.onMoveSelection = onMoveSelection
        textView.onCommitSelection = onCommitSelection
        textView.onDismissSuggestions = onDismissSuggestions
        textView.onHeightChange = onHeightChange
        textView.onPasteImages = onPasteImages
        textView.mentionPlugins = mentionPlugins
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: scaledFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        if #available(macOS 15.0, *) {
            // NSViewRepresentable-backed text views don't reliably inherit every
            // SwiftUI text-input environment value, so enforce the app-wide policy.
            textView.writingToolsBehavior = .none
        }
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: Self.textContainerHorizontalInset, height: 7)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = Self.lineFragmentPadding
        textView.refreshComposerTokenStyle()

        scrollView.documentView = textView

        if autoFocus || focusRequestID != nil {
            DispatchQueue.main.async { [weak textView] in
                textView?.window?.makeFirstResponder(textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit

        guard let textView = scrollView.documentView as? SubmitOnReturnTextView else { return }
        if textView.font?.pointSize != scaledFontSize {
            textView.font = .systemFont(ofSize: scaledFontSize)
        }
        textView.onSubmit = context.coordinator.onSubmit
        textView.onCancel = onCancel
        textView.onSubmitAlternate = onSubmitSideQuestion
        textView.onDeleteBackwardAtStart = onDeleteBackwardAtStart
        textView.suggestionCount = suggestionCount
        textView.onMoveSelection = onMoveSelection
        textView.onCommitSelection = onCommitSelection
        textView.onDismissSuggestions = onDismissSuggestions
        textView.onHeightChange = onHeightChange
        textView.onPasteImages = onPasteImages
        textView.mentionPlugins = mentionPlugins
        if context.coordinator.focusRequestID != focusRequestID {
            context.coordinator.focusRequestID = focusRequestID
            if focusRequestID != nil {
                DispatchQueue.main.async { [weak textView] in
                    textView?.window?.makeFirstResponder(textView)
                }
            }
        }
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            // A caret at the end of the old draft stays at the end of the new
            // one: a quoted passage, an accepted `/` command or a dictated
            // sentence lands with typing resuming after it, not before it.
            let wasAtEnd = selectedRange.location >= (textView.string as NSString).length
            textView.string = text
            let newLength = (text as NSString).length
            let clampedLocation = wasAtEnd ? newLength : min(selectedRange.location, newLength)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
            textView.scrollRangeToVisible(NSRange(location: clampedLocation, length: 0))
            // Setting `string` doesn't call didChangeText, so a programmatic
            // change — clearing the draft after send — would leave the box
            // stuck at the old height.
            textView.reportHeight()
        }
        textView.refreshComposerTokenStyle()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var focusRequestID: UUID?

        init(text: Binding<String>, onSubmit: @escaping () -> Void, focusRequestID: UUID?) {
            self.text = text
            self.onSubmit = onSubmit
            self.focusRequestID = focusRequestID
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }

    final class SubmitOnReturnTextView: NSTextView {
        var onSubmit: (() -> Void)?
        /// ⌥Return. Nil where the composer has no second way to send.
        var onSubmitAlternate: (() -> Void)?
        var onCancel: (() -> Void)?
        /// Backspace at the start. See `ReviewChatComposerTextView.onDeleteBackwardAtStart`.
        var onDeleteBackwardAtStart: (() -> Void)?
        var suggestionCount: Int = 0
        var onMoveSelection: ((Int) -> Void)?
        var onCommitSelection: (() -> Bool)?
        var onDismissSuggestions: (() -> Void)?
        var onHeightChange: ((CGFloat) -> Void)?
        var onPasteImages: (([ChatPastedImage]) -> Void)?
        /// See `ReviewChatComposerTextView.mentionPlugins`.
        var mentionPlugins: [ChatPlugin] = []

        private var lastReportedHeight: CGFloat = 0
        private var isMeasuring = false

        /// A paste that carries a picture attaches it to the message rather
        /// than dropping an attachment cell, or nothing, into the draft.
        /// `importsGraphics` is off, so without this a screenshot pasted into
        /// the composer simply vanished.
        override func paste(_ sender: Any?) {
            if let onPasteImages {
                let images = Self.pastedImages(from: .general)
                if !images.isEmpty {
                    onPasteImages(images)
                    return
                }
            }
            super.paste(sender)
        }

        /// Every picture on the pasteboard: a copied file whose type is a
        /// picture, or raw picture bytes. A browser copies an image as HTML
        /// and as bytes together; the bytes are what the learner meant.
        static func pastedImages(from pasteboard: NSPasteboard) -> [ChatPastedImage] {
            var result: [ChatPastedImage] = []
            for item in pasteboard.pasteboardItems ?? [] {
                if let urlString = item.string(forType: .fileURL),
                   let url = URL(string: urlString),
                   url.isFileURL,
                   UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                    result.append(.file(url))
                    continue
                }
                let imageType = item.types
                    .compactMap { UTType($0.rawValue) }
                    .first { $0.conforms(to: .image) }
                if let imageType,
                   let data = item.data(forType: NSPasteboard.PasteboardType(imageType.identifier)),
                   !data.isEmpty {
                    let ext = imageType.preferredFilenameExtension ?? "png"
                    result.append(.bytes(data, name: "Pasted image.\(ext)"))
                }
            }
            return result
        }

        /// Draws a recognized leading slash-command token, or the first `@` mention
        /// of a connected plugin, with semantic color and weight. Temporary
        /// TextKit attributes keep the bound draft plain text and do not leak into
        /// typing attributes, undo history, copy/paste, or the submitted message.
        func refreshComposerTokenStyle() {
            guard let layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (string as NSString).length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)

            let token: (range: Range<String.Index>, color: NSColor)
            if let prefix = ReviewSlashCommandParser.commandPrefix(in: string) {
                token = (prefix.range, prefix.command.kind.composerTokenColor)
            } else if let mention = ChatPluginRequest.Mention.first(in: string, plugins: mentionPlugins) {
                token = (mention.range, mention.plugin.composerTokenColor)
            } else {
                return
            }
            let tokenRange = NSRange(token.range, in: string)
            let tokenFont = NSFont.systemFont(
                ofSize: font?.pointSize ?? ChatMarkdownView.baseFontSize,
                weight: .semibold
            )
            layoutManager.addTemporaryAttribute(.foregroundColor, value: token.color, forCharacterRange: tokenRange)
            layoutManager.addTemporaryAttribute(.font, value: tokenFont, forCharacterRange: tokenRange)
        }

        /// Height the laid-out text occupies, insets included. Reported on every
        /// edit and relayout so the SwiftUI box can track it.
        func reportHeight() {
            // ensureLayout can resize the text view, which re-enters through
            // setFrameSize.
            guard !isMeasuring, let layoutManager, let textContainer else { return }
            isMeasuring = true
            defer { isMeasuring = false }

            layoutManager.ensureLayout(for: textContainer)
            let height = ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2)
            guard height > 0, abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            // Hop off the current layout pass: reporting synchronously would
            // mutate SwiftUI state mid-update.
            DispatchQueue.main.async { [weak self] in
                self?.onHeightChange?(height)
            }
        }

        override func didChangeText() {
            super.didChangeText()
            refreshComposerTokenStyle()
            reportHeight()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            // Catches re-wrapping from a width or font-size change, which never
            // goes through didChangeText.
            reportHeight()
        }

        override func keyDown(with event: NSEvent) {
            guard !hasMarkedText() else {
                super.keyDown(with: event)
                return
            }

            // ⌥Return sends the draft as a side question wherever the popup is
            // not the thing being driven.
            if event.isReturnKey, event.modifierFlags.contains(.option), suggestionCount == 0,
               let onSubmitAlternate {
                onSubmitAlternate()
                return
            }

            // While the `/` command popup is open, arrow / Tab / Return drive the popup.
            if suggestionCount > 0 {
                switch event.keyCode {
                case 126: onMoveSelection?(-1); return // up arrow
                case 125: onMoveSelection?(1); return  // down arrow
                case 48:                                // tab
                    if onCommitSelection?() == true { return }
                default:
                    break
                }
                if event.isReturnKey, !event.modifierFlags.contains(.shift) {
                    if onCommitSelection?() == true { return }
                    onSubmit?()
                    return
                }
            }

            if event.isReturnKey, !event.modifierFlags.contains(.shift) {
                onSubmit?()
                return
            }
            super.keyDown(with: event)
        }

        /// Backspace with nothing selected and the caret at the start reaches
        /// past the text to whatever sits before it in the composer, the way
        /// Backspace before the first character of a mail body reaches the
        /// recipient tokens above it.
        override func deleteBackward(_ sender: Any?) {
            if let onDeleteBackwardAtStart, !hasMarkedText(), selectedRange() == NSRange(location: 0, length: 0) {
                onDeleteBackwardAtStart()
                return
            }
            super.deleteBackward(sender)
        }

        override func cancelOperation(_ sender: Any?) {
            if suggestionCount > 0, let onDismissSuggestions {
                onDismissSuggestions()
            } else if let onCancel {
                onCancel()
            } else {
                super.cancelOperation(sender)
            }
        }
    }
}

private extension ReviewSlashCommand.Kind {
    var composerTokenColor: NSColor {
        switch self {
        case .goal: return .systemPurple
        case .source: return .systemBlue
        case .doc: return .systemBrown
        // An animation is hosted the way a Site is, so it takes the Site's colour.
        case .site, .sitePrompt, .animate: return .systemCyan
        case .video: return .systemPurple
        case .today: return .systemOrange
        case .plan, .course: return .systemIndigo
        case .review: return .systemGreen
        case .notebook: return .systemTeal
        case .new: return .systemMint
        case .model: return .systemPink
        case .settings, .help: return .secondaryLabelColor
        case .end: return .systemRed
        case .skill: return .systemYellow
        }
    }
}

extension NSEvent {
    var isReturnKey: Bool {
        keyCode == 36 || keyCode == 76
    }

    var isTabKey: Bool {
        keyCode == 48
    }
}

// MARK: - Composer state the pane never reads in its body

/// The composer's live state, deliberately not `@State` on the chat pane.
///
/// With the draft stored on `InternalReviewPanelContent`, every keystroke
/// re-ran that pane's whole body — transcript, header, idle welcome — and relaid
/// out its hosting view before the glyph could appear. Sampled on 2026-09-01 at
/// about 5 ms per keystroke on a quiet machine and 15 ms under a sibling build,
/// two thirds of it rebucketing the Schedule for the idle welcome. Now only the
/// views that read `text` in their body re-render on a keystroke: the box that
/// hosts the text view and the `/` popup. The pane reads and writes this from
/// actions only, through `nonmutating` shims that keep its call sites unchanged.
@Observable
final class ReviewComposerDraft {
    var text = ""
    /// A passage quoted out of the transcript that the next message carries.
    /// Held apart from `text` so the composer can draw it as a quote and the
    /// learner types only their question; it is folded back into the message as
    /// a Markdown blockquote on send (`ChatQuoteDraft.compose`).
    var quotedPassage = ""
    /// A machine-inserted opener the learner has not edited. It is regenerated
    /// from the chat's sources rather than persisted, and dictation or a
    /// suggested prompt may overwrite it.
    var lastInsertedDefaultPrompt: String?
    /// Highlighted row in the `/` command or `@` mention autocomplete popup.
    var slashSelectionIndex = 0
    /// Library rows the popup shows for a `/source`, `/doc` or `/site` query, stamped
    /// with the draft they answer. Written by `ReviewSlashSuggestionsOverlay`,
    /// which runs the search; read by the box so Return and the arrows act on
    /// exactly the rows that are on screen.
    var liveArguments: ReviewSlashLiveArguments?
    /// What the library search found for the `@` query being typed, stamped
    /// with that query, written by the overlay as `liveArguments` is.
    var liveMentions: ChatMention.LiveResults?
    /// The `@` popup's tab. Back to All whenever no `@` is being typed.
    var mentionTab: ChatMention.Tab = .all
    /// Chats the learner pointed at with `@`, drawn as chips above the field;
    /// their transcripts go with the next message as reference material.
    var referencedChats: [ChatMention.Item] = []
}

/// The editable box: the AppKit text view and the empty-state placeholder.
/// This is the one SwiftUI view whose body reads the draft, so a keystroke
/// invalidates it and nothing above it.
struct ReviewChatComposerBox: View {
    @Bindable var composer: ReviewComposerDraft
    /// Shown while the draft is empty, however far the chat has gone:
    /// "Ask anything", as in ChatGPT's composer (product owner, 2026-10-06), or
    /// what the field is for right now (a guess, an aside, a passage).
    let placeholder: String
    /// A changed non-nil token focuses the text view. See `ReviewChatComposerTextView`.
    let focusRequestID: UUID?
    /// Commands the `/` popup offers; `/notebook` carries live Notebook titles.
    let slashCommands: [ReviewSlashCommand]
    /// Connected plugins the `@` popup offers, and whose mention the box
    /// paints as a token.
    let mentions: [ReviewComposerMention]
    let onSubmit: () -> Void
    let onAcceptSuggestion: (ReviewSlashSuggestion) -> Void
    let onDismissSuggestions: () -> Void
    /// Fired for every edit so the owner can file the draft for its chat.
    let onTextChange: (String) -> Void
    /// Pictures pasted into the box. See `ReviewChatComposerTextView.onPasteImages`.
    var onPasteImages: (([ChatPastedImage]) -> Void)? = nil
    /// ⌥Return: send the draft as a side question. See `ReviewChatComposerTextView`.
    var onSubmitSideQuestion: (() -> Void)? = nil
    /// Non-nil while the next message is a side question: a "Side question"
    /// token is drawn at the head of the field, and this removes it — from
    /// its ×, from Escape, or from Backspace with the caret at the start.
    var removeSideQuestionToken: (() -> Void)? = nil
    /// The first line of the reply the armed side question is about, when it
    /// is not the newest reply; the token shows it so the learner can see
    /// which reply the aside will hang under.
    var sideQuestionAbout: String? = nil
    /// Think first: the question waiting for the learner's guess, drawn above
    /// the field while the field takes the guess (`ChatGuess`).
    var guessQuestion: String? = nil
    /// Non-nil while a question waits for its guess: a "Your guess first?"
    /// token heads the field, and this sends the question without one —
    /// from its × or from Escape.
    var skipGuess: (() -> Void)? = nil
    /// Drops the passage quoted into this composer. The block above the field
    /// draws `composer.quotedPassage`; this is its ×.
    var onRemoveQuote: (() -> Void)? = nil
    /// True while the chat is in Deep Research: a "Deep research" token heads
    /// the field. The composer's "+" menu turns the mode on.
    var showsDeepResearchToken = false
    /// Turns Deep Research off — from the token's ×, from Escape, or from
    /// Backspace with the caret at the start. Nil while a turn runs, which
    /// the mode cannot change under: the × is dimmed and the keys do what
    /// they do in any draft, as the "+" menu's toggle is dimmed then.
    var removeDeepResearchToken: (() -> Void)? = nil

    @Environment(\.uiZoomScale) private var uiZoomScale
    /// Height the text currently needs, reported by the AppKit text view so the
    /// box grows with a multi-line draft instead of clipping it.
    @State private var contentHeight: CGFloat = 0

    private var suggestions: [ReviewSlashSuggestion] {
        ReviewSlashCommandParser.suggestions(
            for: composer.text,
            commands: slashCommands,
            mentions: mentions,
            liveArguments: composer.liveArguments,
            liveMentions: composer.liveMentions,
            mentionTab: composer.mentionTab
        )
    }

    /// Zoom factor relative to the default step, for chrome that was sized by
    /// eye at that step rather than at scale 1.
    private var zoom: CGFloat {
        uiZoomScale / UIZoom.scale(for: UIZoom.defaultStep)
    }

    /// One line at rest, growing with the draft, capped before it eats the transcript.
    private var boxHeight: CGFloat {
        min(max(contentHeight, 36 * zoom), 220 * zoom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !composer.quotedPassage.isEmpty, let onRemoveQuote {
                // Above the field, drawn the way the sent bubble will draw it,
                // rather than as the `> ` lines it becomes on the wire.
                ReviewChatComposerQuote(passage: composer.quotedPassage, remove: onRemoveQuote)
                    .padding(.leading, ReviewChatComposerTextView.overlayTextLeadingInset)
                    .padding(.trailing, 4)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !composer.referencedChats.isEmpty {
                ReviewChatReferencedChats(chats: composer.referencedChats) { item in
                    composer.referencedChats.removeAll { $0.id == item.id }
                }
                .padding(.leading, ReviewChatComposerTextView.overlayTextLeadingInset)
                .padding(.trailing, 4)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let guessQuestion, skipGuess != nil {
                ReviewChatGuessQuestion(question: guessQuestion)
                    .padding(.leading, ReviewChatComposerTextView.overlayTextLeadingInset)
                    .padding(.trailing, 4)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .top, spacing: 6) {
                if showsDeepResearchToken, skipGuess == nil {
                    ReviewChatDeepResearchToken(remove: removeDeepResearchToken)
                        .modifier(ComposerTokenPlacement(zoom: zoom))
                }
                if let skipGuess {
                    ReviewChatGuessToken(skip: skipGuess)
                        .modifier(ComposerTokenPlacement(zoom: zoom))
                } else if let removeSideQuestionToken {
                    ReviewChatSideQuestionToken(remove: removeSideQuestionToken, about: sideQuestionAbout)
                        .modifier(ComposerTokenPlacement(zoom: zoom))
                }
                textField
            }
        }
        .animation(.easeOut(duration: 0.12), value: removeSideQuestionToken != nil)
        .animation(.easeOut(duration: 0.12), value: showsDeepResearchToken)
        .animation(.easeOut(duration: 0.12), value: skipGuess != nil)
        .animation(.easeOut(duration: 0.12), value: composer.quotedPassage.isEmpty)
        .animation(.easeOut(duration: 0.12), value: composer.referencedChats)
    }

    /// Escape takes off the token nearest the words: the guess's, then the
    /// side question's, then Deep Research's.
    private var cancelToken: (() -> Void)? {
        skipGuess ?? removeSideQuestionToken ?? removeDeepResearchToken
    }

    private var textField: some View {
        ZStack(alignment: .topLeading) {
            ReviewChatComposerTextView(
                text: $composer.text,
                onSubmit: onSubmit,
                focusRequestID: focusRequestID,
                onCancel: cancelToken,
                suggestionCount: suggestions.count,
                mentionPlugins: mentions.map(\.plugin),
                onMoveSelection: { delta in moveSelection(delta) },
                onCommitSelection: { commitSelection() },
                onDismissSuggestions: onDismissSuggestions,
                onHeightChange: { contentHeight = $0 },
                onPasteImages: onPasteImages,
                onSubmitSideQuestion: onSubmitSideQuestion,
                onDeleteBackwardAtStart: removeSideQuestionToken
                    ?? (skipGuess == nil ? removeDeepResearchToken : nil)
            )
            .frame(height: boxHeight)
            .padding(.horizontal, ReviewChatComposerTextView.outerHorizontalPadding)
            .padding(.vertical, 2)

            if composer.text.isEmpty {
                Text(placeholder)
                    // Color the raw Text, not the font-wrapped ModifiedContent
                    // that `zoomedSystemFont` returns: the hierarchical `.tertiary`
                    // style doesn't cross that modifier boundary and the
                    // placeholder rendered in the primary label color instead.
                    .foregroundStyle(.tertiary)
                    .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
                    // Start just after the empty NSTextView's insertion caret,
                    // matching native composer placeholders instead of painting
                    // the blue caret through the first glyph.
                    .padding(
                        .leading,
                        ReviewChatComposerTextView.overlayTextLeadingInset
                            + ReviewChatComposerTextView.placeholderCaretGap
                    )
                    .padding(.trailing, 7)
                    // Matches the text view's own top offset (2pt box padding
                    // + 7pt text container inset) now that the ZStack is top-aligned.
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: composer.text) { _, text in
            onTextChange(text)
            let count = ReviewSlashCommandParser.suggestions(
                for: text,
                commands: slashCommands,
                mentions: mentions,
                liveArguments: composer.liveArguments,
                liveMentions: composer.liveMentions,
                mentionTab: composer.mentionTab
            ).count
            if composer.slashSelectionIndex >= count {
                composer.slashSelectionIndex = 0
            }
        }
        .onChange(of: composer.liveArguments) { _, _ in
            // A fresh search result is a fresh list: the highlight goes back to
            // the top rather than pointing at whatever row number it was on.
            composer.slashSelectionIndex = 0
        }
        .onChange(of: composer.liveMentions) { _, _ in
            composer.slashSelectionIndex = 0
        }
        .onChange(of: composer.mentionTab) { _, _ in
            composer.slashSelectionIndex = 0
        }
    }

    /// Move the popup highlight by `delta` rows, wrapping at either end.
    private func moveSelection(_ delta: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        composer.slashSelectionIndex = (composer.slashSelectionIndex + delta + count) % count
    }

    /// Accepts the highlighted suggestion when the popup is open. Returns `true`
    /// when it consumed the keypress so the text view does not also submit.
    private func commitSelection() -> Bool {
        let suggestions = suggestions
        guard !suggestions.isEmpty else { return false }
        let index = min(max(composer.slashSelectionIndex, 0), suggestions.count - 1)
        onAcceptSuggestion(suggestions[index])
        return true
    }
}

/// A passage quoted out of the transcript, drawn above the field as the quote
/// it will be once sent rather than as the `> ` lines it becomes on the wire.
///
/// It is not editable text: the field below holds only the question, so a long
/// passage never has to be typed around or scrolled past. A passage taller than
/// the block scrolls inside it, and the × drops it.
struct ReviewChatComposerQuote: View {
    let passage: String
    let remove: () -> Void

    @Environment(\.uiZoomScale) private var uiZoomScale
    /// Height the passage needs, so a short quote hugs its lines and only a
    /// long one is capped and scrolls.
    @State private var contentHeight: CGFloat = 0

    private var zoom: CGFloat {
        uiZoomScale / UIZoom.scale(for: UIZoom.defaultStep)
    }

    /// Tall enough for a paragraph, short enough that the field and the
    /// transcript above it keep their room.
    private var maximumHeight: CGFloat { 104 * zoom }

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            ScrollView(.vertical) {
                // The same face and weight the bubble will draw it in, and the
                // same folding of any TeX in the passage into readable text, so
                // the composer shows what the message is about to look like.
                // The message itself still carries the TeX.
                Text(passage.foldingTeXForPreview())
                    .zoomedSystemFont(size: ChatMarkdownView.baseFontSize)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        contentHeight = height
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), maximumHeight))
            .padding(.leading, 9)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 3)
            }

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.hoverWash(in: Circle(), opacity: 0.14))
            .help("Send the message without the quoted passage")
            .accessibilityLabel("Remove quoted passage")
            .accessibilityIdentifier("mac.chatComposerQuoteRemove")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quoting: \(passage)")
        .accessibilityIdentifier("mac.chatComposerQuote")
    }
}

/// Chats the learner pointed at with `@`, above the field as chips: each
/// chat's transcript goes with the next message as reference material, and
/// its × leaves it out (`ChatMention.chatReferenceContext`).
struct ReviewChatReferencedChats: View {
    let chats: [ChatMention.Item]
    let remove: (ChatMention.Item) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chats) { chat in
                HStack(spacing: 4) {
                    Image(systemName: ChatMention.Kind.chat.systemImage)
                        .zoomedSystemFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text(chat.title)
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 220, alignment: .leading)
                        .textSelection(.disabled)
                    Button {
                        remove(chat)
                    } label: {
                        Image(systemName: "xmark")
                            .zoomedSystemFont(size: 7, weight: .bold)
                            .frame(width: 14, height: 14)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.hoverWash(in: Circle(), opacity: 0.14))
                    .help("Send the message without this chat")
                    .accessibilityLabel("Remove \(chat.title)")
                }
                .padding(.leading, 6)
                .padding(.trailing, 2)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("The next message carries this chat's transcript")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mac.chatReferencedChat")
            }
            Spacer(minLength: 0)
        }
    }
}

/// The mark on a message that is about to go as a side question, drawn at the
/// head of the composer's field where the words begin. It is the whole of the
/// state: while it is there the next Return sends a side question. It stays
/// after the send, since what follows a side question is taken to be a
/// follow-up, until the learner answers or skips the tutor's question. Its ×
/// takes it off; so do Escape and Backspace with the caret at the start of the
/// draft. When the aside is about a reply other than the newest, the reply's
/// first line sits in the token so the learner can see which.
struct ReviewChatSideQuestionToken: View {
    let remove: () -> Void
    var about: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .zoomedSystemFont(size: 9, weight: .semibold)
            Text("Side question")
                .zoomedSystemFont(size: 11, weight: .medium)
                .fixedSize()
            if let about {
                Text(about)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)
                    // The Studio window enables selection on every Text; a
                    // labelled one must opt out first (AGENTS.md, "Text that
                    // speaks for itself").
                    .textSelection(.disabled)
                    .accessibilityLabel("About the reply: \(about)")
            }
            Button(action: remove) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 7, weight: .bold)
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.hoverWash(in: Circle(), opacity: 0.14))
            .help("Take the side question off; the next message goes as usual")
            .accessibilityLabel("Remove side question")
            .accessibilityIdentifier("mac.chatSideQuestionRemove")
        }
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        // The help goes below the group: above it, it replaced the remove
        // button's own help.
        .accessibilityElement(children: .contain)
        .help("The next message is a side question about a reply: answered beside the conversation, not read as its next step, and never graded. ⌥Return sends one without the token.")
        .accessibilityLabel("Side question")
        .accessibilityIdentifier("mac.chatSideQuestionToken")
    }
}

/// Where a token sits at the head of the field: level with the first line of
/// the draft, since the text view sits 2pt into the box and its container
/// inset is 7pt more.
private struct ComposerTokenPlacement: ViewModifier {
    let zoom: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.top, 8 * zoom)
            .padding(.leading, ReviewChatComposerTextView.outerHorizontalPadding)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
    }
}

/// The mark of a chat in Deep Research, at the head of the field the way
/// ChatGPT's composer shows a tool it has switched on (product owner, 2026-10-06:
/// "make the app more slick; kind of like the chatgpt app"). The composer's
/// "+" menu turns the mode on; the token is how it reads, and its ×, Escape
/// or Backspace at the start of the draft turn it off. It stays while the
/// chat is in the mode: every turn of a Deep Research chat researches. While
/// a turn runs the mode cannot change, so `remove` is nil and the × dimmed.
struct ReviewChatDeepResearchToken: View {
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .zoomedSystemFont(size: 9, weight: .semibold)
            Text("Deep research")
                .zoomedSystemFont(size: 11, weight: .medium)
                .fixedSize()
            Button {
                remove?()
            } label: {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 7, weight: .bold)
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.hoverWash(in: Circle(), opacity: 0.14))
            .disabled(remove == nil)
            .help("Turn Deep Research off; the next message goes as an ordinary chat")
            .accessibilityLabel("Turn off Deep Research")
            .accessibilityIdentifier("mac.chatDeepResearchRemove")
        }
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .help("Live web research is on: the chat searches and reads the web, keeps notes, and writes a cited report")
        .accessibilityLabel("Deep research")
        .accessibilityIdentifier("mac.chatDeepResearchToken")
    }
}

/// The composer's send arrow, on its trailing edge, as in Codex's composer: a
/// dark circle that is always there, full ink while there is something to
/// send and faint while there is not (product owner, 2026-10-11: "make the
/// chat experience more look chatgpt codex"). It does what Return does. It
/// reads the draft itself, so a keystroke re-renders this button and not the
/// pane (`ReviewComposerDraft`).
struct ReviewChatSendButton: View {
    static let diameter: CGFloat = StudioDesign.Chat.actionDiameter

    let composer: ReviewComposerDraft
    /// Pictures wait in the tray: a message on their own.
    let hasAttachments: Bool
    /// Off while the chat is busy outside a turn (a saved chat hydrating,
    /// sources being attached), when Return does nothing either.
    let isEnabled: Bool
    let send: () -> Void

    private var hasSomethingToSend: Bool {
        hasAttachments
            || !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !composer.quotedPassage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let canSend = isEnabled && hasSomethingToSend
        Button(action: send) {
            ChatComposerActionCircle(systemImage: "arrow.up", glyphSize: 12, isEnabled: canSend)
        }
        .buttonStyle(.hoverWash(in: Circle(), inset: -2, opacity: 0.12))
        .disabled(!canSend)
        .animation(.easeOut(duration: 0.12), value: canSend)
        .help("Send (Return)")
        .accessibilityLabel("Send message")
        .accessibilityIdentifier("mac.chatSend")
    }
}

/// The `/` and `@` autocomplete popup, floated above whatever it is overlaid on.
/// It owns its measured height and reads the draft itself, so an open popup
/// tracks typing without the composer's parent taking part in the render.
struct ReviewSlashSuggestionsOverlay: View {
    @Bindable var composer: ReviewComposerDraft
    let slashCommands: [ReviewSlashCommand]
    /// Connected plugins the `@` popup offers.
    let mentions: [ReviewComposerMention]
    /// Runs the library search a `/source` or `/doc` draft asks for and returns
    /// the rows to show, already matched and ranked. Called from a task keyed
    /// on the query, so a keystroke cancels the search it superseded.
    let resolveLiveArguments: (ReviewSlashCommand, String) async -> [ReviewSlashCommand.Argument]
    /// Runs the library search an `@` query asks for: sources, Pages, Sites,
    /// chats and notebooks matching it, each kind ranked (`ChatMention`).
    var resolveMentions: (String) async -> [ChatMention.Item] = { _ in [] }
    let onSelect: (ReviewSlashSuggestion) -> Void

    /// Measured height of the popup so it can float above the composer.
    @State private var popupHeight: CGFloat = 0

    /// The `@` query being typed, as a value `task(id:)` can key on.
    private var mentionQuery: String? {
        ChatMention.pendingQuery(in: composer.text)?.query
    }

    /// The search the draft currently asks for, as a value `task(id:)` can key on.
    private var liveQuery: LiveQuery? {
        guard let live = ReviewSlashCommandParser.liveArgumentQuery(
            in: composer.text,
            commands: slashCommands
        ) else { return nil }
        return LiveQuery(commandName: live.command.name, query: live.query)
    }

    private struct LiveQuery: Equatable {
        let commandName: String
        let query: String
    }

    var body: some View {
        let suggestions = ReviewSlashCommandParser.suggestions(
            for: composer.text,
            commands: slashCommands,
            mentions: mentions,
            liveArguments: composer.liveArguments,
            liveMentions: composer.liveMentions,
            mentionTab: composer.mentionTab
        )
        // An `@` being typed opens the popup even before there is a row to
        // pick: it says what to type, then that it is searching, as Codex's.
        let mentionHeader = mentionQuery.map { query in
            ReviewMentionPopupHeader(
                tab: composer.mentionTab,
                statusLine: ReviewMentionPopupHeader.statusLine(
                    query: query,
                    tab: composer.mentionTab,
                    hasRows: !suggestions.isEmpty,
                    hasAnswer: composer.liveMentions?.answers(query) == true
                ),
                selectTab: { composer.mentionTab = $0 }
            )
        }
        ZStack(alignment: .topLeading) {
            if !suggestions.isEmpty || mentionHeader != nil {
                ReviewSlashCommandPopup(
                    suggestions: suggestions,
                    selectedIndex: composer.slashSelectionIndex,
                    mentionHeader: mentionHeader,
                    onSelect: onSelect
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { popupHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, height in popupHeight = height }
                    }
                )
                .offset(y: -(popupHeight + 8))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: suggestions)
        .task(id: liveQuery) {
            guard let liveQuery,
                  let command = slashCommands.first(where: { $0.name == liveQuery.commandName }) else {
                composer.liveArguments = nil
                return
            }
            // Typing outruns the search, so a keystroke waits a beat before
            // asking — the same debounce as the Docs source picker.
            if !liveQuery.query.isEmpty {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            let arguments = await resolveLiveArguments(command, liveQuery.query)
            guard !Task.isCancelled else { return }
            composer.liveArguments = ReviewSlashLiveArguments(
                commandName: command.name,
                query: liveQuery.query,
                arguments: arguments
            )
        }
        .task(id: mentionQuery) {
            guard let query = mentionQuery else {
                // The `@` is over: the next one opens on All again.
                composer.liveMentions = nil
                composer.mentionTab = .all
                return
            }
            guard !query.isEmpty else {
                composer.liveMentions = ChatMention.LiveResults(query: query, items: [])
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let items = await resolveMentions(query)
            guard !Task.isCancelled else { return }
            composer.liveMentions = ChatMention.LiveResults(query: query, items: items)
        }
    }
}

/// The chat's one visible drop target: the box the learner already types into.
///
/// A drag out of Sources used to light the whole chat pane with a dashed
/// outline, and `StudioDropZoneOverlay` renders no title, so the pane said
/// "something can happen here" without saying what or where. The panel still
/// takes a drop anywhere over the transcript — this is the only thing that
/// advertises it, so a dragged source has one obvious place to land.
struct ReviewChatComposerDropTarget: View {
    /// The pointer is over the chat right now, so letting go drops here.
    let isTargeted: Bool
    /// What the drag is carrying, when the app knows: a quoted title, or a
    /// count. Nil for a Finder file or dragged text, which arrive with no
    /// in-app payload to name.
    let payloadDescription: String?
    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            // Two steps, not one: a drag anywhere in the window marks the
            // composer as somewhere a source can go, and the pointer arriving
            // over the chat arms it. Without the gap between them there is no
            // way to tell "you could drop here" from "let go now".
            shape
                .fill(Color.accentColor.opacity(isTargeted ? 0.16 : 0.05))
            shape
                .strokeBorder(
                    Color.accentColor.opacity(isTargeted ? 0.95 : 0.4),
                    style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [7, 5])
                )

            // Opaque so it stays legible over the draft and the control row it
            // covers; the tint around it is light enough to leave the composer
            // recognisable underneath.
            Label(title, systemImage: "plus.bubble.fill")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.white)
                .lineLimit(1)
                // A narrow pane (the bottom sheet, a split centre) should shrink
                // the sentence rather than cut "into this chat" off the end of it.
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(isTargeted ? 1 : 0.9), in: Capsule())
                .shadow(color: Color.black.opacity(isTargeted ? 0.18 : 0.10), radius: 6, y: 2)
                .padding(.horizontal, 10)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var title: String {
        guard let payloadDescription else { return "Drop into this chat" }
        return "Drop \(payloadDescription) into this chat"
    }
}

// MARK: - Quoting a passage into the draft

/// The shape a passage quoted from the transcript takes, and how a message
/// carrying one is read back apart from it.
///
/// On the wire a quote is a Markdown blockquote at the head of the message, one
/// `> ` per line, followed by a blank line for the question: the learner's
/// bubble draws the block as a quote, and the model reads the same Markdown any
/// reply already uses. In the composer it is never those characters — the
/// passage is held beside the draft and drawn as a quote there too, so nobody
/// types around a wall of `> `.
enum ChatQuoteDraft {
    /// `passage` as a blockquote: every line prefixed, blank lines kept as a
    /// bare `>` so a multi-paragraph quote stays one block.
    static func blockquote(_ passage: String) -> String {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .components(separatedBy: .newlines)
            .map { line in
                let content = line.trimmingCharacters(in: .whitespaces)
                return content.isEmpty ? ">" : "> \(content)"
            }
            .joined(separator: "\n")
    }

    /// The passage a second quote leaves pending: the two stand as one block,
    /// a blank line between them, in the order they were quoted. An empty
    /// passage changes nothing.
    static func adding(_ passage: String, to pending: String) -> String {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pending }
        let existing = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existing.isEmpty else { return trimmed }
        return existing + "\n\n" + trimmed
    }

    /// The message the composer sends, and the text its draft is filed as: the
    /// pending passage as a blockquote, then a blank line, then the words.
    /// Without a passage it is the words alone.
    static func compose(quote: String, body: String) -> String {
        let block = blockquote(quote)
        let words = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !block.isEmpty else { return body }
        guard !words.isEmpty else { return block + "\n\n" }
        return block + "\n\n" + words
    }

    /// A sent message split into the passage it opened with and the words the
    /// learner typed. Nil when the message does not start with a blockquote;
    /// then it is drawn as it was typed.
    static func split(userMessage content: String) -> (quote: String, body: String)? {
        let lines = content.components(separatedBy: .newlines)
        var quoteLines: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var text = trimmed.dropFirst()
            if text.hasPrefix(" ") { text = text.dropFirst() }
            quoteLines.append(String(text))
            index += 1
        }
        guard !quoteLines.isEmpty else { return nil }
        let quote = quoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return nil }
        let body = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (quote, body)
    }
}
