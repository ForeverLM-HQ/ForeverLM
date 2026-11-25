import AppKit
import SwiftUI

/// The popover that follows a mark: its since-publication update, the papers
/// it cites, the learner's own note, its color, What's New or the chat the
/// update came from, and the way to remove it.
///
/// Highlighting is the gesture and commenting is optional, so this card never
/// holds unsaved work. The mark exists before the card opens, every control
/// writes straight through, and closing keeps whatever has been typed — there
/// is nothing here to confirm, and nothing to lose by ignoring it. The card
/// that follows a fresh mark retires itself for exactly that reason.
///
/// A mark research has updated leads with that update, set as reading rather
/// than as a field: a "Since publication" heading with when it was written,
/// its headline sentence, the detail with each cited paper numbered, and the
/// numbered papers under it. The learner's note is a line of its own below,
/// so their thinking and the literature's are never one text box. A mark
/// without an update is the comment field it always was.
///
/// It hangs below the mark rather than floating in a corner of the reader, so
/// there is never any doubt about which mark is being edited, no need to
/// repeat the passage inside the card, and none of the passage under the
/// card. The three reader engines measure a selection in coordinate spaces
/// that do not survive zoom identically, so each converts the mark's frame to
/// screen coordinates — the one space they all reach from their own — and the
/// presenter resolves it back into the reader's. A card opened where nothing
/// on screen is the mark (the notes list) hangs off the pointer instead. See
/// `readerHighlightCard(for:)`.
struct ReaderHighlightCardView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.uiZoomScale) private var uiZoomScale

    let card: ReaderHighlightCard

    @State private var comment: String = ""
    /// Which mark `comment` belongs to, so a card re-targeted at another one
    /// commits the typing it is leaving behind.
    @State private var commentingOn: String = ""
    @State private var retirement: Task<Void, Never>?
    @FocusState private var commentFocused: Bool

    /// Room for the swatches and three icon buttons on one line, and for an
    /// update to read as a paragraph rather than a column.
    private static let width: CGFloat = 380
    /// The tallest an update grows before it scrolls inside the card.
    private static let updateMaxHeight: CGFloat = 300
    /// How long the card after a fresh mark waits before retiring itself: long
    /// enough to read and reach for, short enough that a reader who carries on
    /// reading is not left with a card hanging off the page.
    private static let retirementDelay: Duration = .seconds(6)

    private var highlight: SourceHighlight? {
        vm.highlight(id: card.highlightID, sourceID: card.sourceID)
    }

    var body: some View {
        // A mark deleted while its card is open leaves nothing to edit.
        if let highlight {
            content(for: highlight)
        }
    }

    private func content(for highlight: SourceHighlight) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if highlight.hasPublicationUpdate {
                updateSection(for: highlight)
                Divider()
                noteLine
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    editor
                    if !highlight.references.isEmpty {
                        referenceList(for: highlight, numbered: false)
                    }
                }
                .padding(12)
            }
            Divider()
            controls(for: highlight)
        }
        // Width only — and then a content-sized height, which is what the
        // popover measures once and keeps.
        .frame(width: Self.width * uiZoomScale, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // Reaching for the card is intent: it stops counting down, and does not
        // start again when the pointer leaves.
        .onHover { hovering in
            if hovering { retirement?.cancel() }
        }
        .onChange(of: commentFocused) { _, focused in
            if focused { retirement?.cancel() }
        }
        .onChange(of: comment) { _, _ in retirement?.cancel() }
        .onAppear { adopt() }
        // A second mark while the card is open re-targets it rather than
        // stacking another card.
        .onChange(of: card.id) { adopt() }
        .onDisappear {
            retirement?.cancel()
            commitComment()
        }
    }

    // MARK: Since publication

    private func updateSection(for highlight: SourceHighlight) -> some View {
        let layout = PublicationUpdateLayout(
            update: highlight.publicationUpdate,
            references: highlight.references
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text("Since publication")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if let written = highlight.publicationUpdateAt {
                    Text("Checked \(written.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(Color.accentColor)
            .accessibilityElement(children: .combine)

            // A short update reads in place; a long one scrolls inside the
            // card rather than pushing the card off the screen.
            ViewThatFits(in: .vertical) {
                updateText(layout)
                ScrollView(.vertical) {
                    updateText(layout)
                }
            }
            .frame(maxHeight: Self.updateMaxHeight * uiZoomScale, alignment: .top)

            if !highlight.references.isEmpty {
                referenceList(for: highlight, numbered: true)
                    .padding(.horizontal, -4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func updateText(_ layout: PublicationUpdateLayout) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let headline = layout.headline {
                Text(Self.attributed(headline, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text(Self.attributed(layout.body, weight: .regular))
                .foregroundStyle(layout.headline == nil ? .primary : .secondary)
        }
        .font(.system(size: 13))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // An update is research's reading, and the passage is the reader's
        // to quote: copying a sentence out of it is ordinary.
        .textSelection(.enabled)
    }

    /// The segments as one run of text: each citation its words, if they are
    /// part of the sentence, then its number raised in the accent color.
    private static func attributed(_ segments: [PublicationUpdateLayout.Segment], weight: Font.Weight) -> AttributedString {
        var text = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let words):
                var run = AttributedString(words)
                run.swiftUI.font = Font.system(size: 13, weight: weight)
                text += run
            case .citation(let number, let words):
                if let words {
                    var run = AttributedString(words)
                    run.swiftUI.font = Font.system(size: 13, weight: weight)
                    text += run
                }
                var mark = AttributedString("\(number)")
                mark.swiftUI.font = Font.system(size: 9, weight: .semibold)
                mark.swiftUI.baselineOffset = 5
                mark.swiftUI.foregroundColor = Color.accentColor
                text += mark
            }
        }
        return text
    }

    /// The learner's own note under an update: one quiet line until written.
    private var noteLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Your note", text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .focused($commentFocused)
                .onSubmit(close)
                .onAppear {
                    if card.focusesComment { commentFocused = true }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Comment

    /// The comment, or the place to type one. Always present: a reader who
    /// clicked a mark either came to read what they wrote or to write it, and
    /// neither should cost a second click.
    private var editor: some View {
        TextField("Add a comment", text: $comment, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...6)
            .focused($commentFocused)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onSubmit(close)
            // Focus when the field arrives rather than when the card decides to
            // show it: a `@FocusState` set in the same update that creates the
            // field lands on a view that does not exist yet.
            .onAppear {
                if card.focusesComment { commentFocused = true }
            }
    }

    /// The papers the mark cites, each one to open or to keep; numbered when
    /// the update above names them by number.
    private func referenceList(for highlight: SourceHighlight, numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(highlight.references.enumerated()), id: \.offset) { offset, reference in
                ReaderHighlightReferenceRow(reference: reference, number: numbered ? offset + 1 : nil) {
                    retirement?.cancel()
                    commitComment()
                    vm.dismissReaderHighlightCard()
                }
            }
        }
        .onHover { hovering in
            if hovering { retirement?.cancel() }
        }
    }

    // MARK: Controls

    private func controls(for highlight: SourceHighlight) -> some View {
        HStack(spacing: 4) {
            colorRow(for: highlight)
            Spacer(minLength: 8)
            if highlight.linkedChatID != nil {
                // A mark with its chat opens that chat; a second conversation
                // about the passage is one menu away in the notes list.
                openChatButton(for: highlight)
            } else {
                if !highlight.isPictureOnly {
                    researchButton(for: highlight)
                }
                chatButton(for: highlight)
            }
            removeButton(for: highlight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.25))
    }

    /// One of the footer's actions: a symbol, named by its tooltip.
    private func footerButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(inset: -1))
        .help(help)
        .accessibilityLabel(help)
    }

    /// What's New: what has been published since the source was written,
    /// researched in a Deep Research chat that writes its short version back
    /// here as the mark's update.
    private func researchButton(for highlight: SourceHighlight) -> some View {
        footerButton(
            Self.researchSymbol,
            help: highlight.hasPublicationUpdate
                ? "Research what has been published since, again"
                : "What's new since this was written"
        ) {
            retirement?.cancel()
            commitComment()
            vm.requestResearchUpdate(for: highlight)
        }
    }

    /// The chat this mark's update came from: What's New research, or a chat
    /// an assistant linked here.
    private func openChatButton(for highlight: SourceHighlight) -> some View {
        footerButton(
            "bubble.left.and.text.bubble.right",
            help: vm.linkedChat(for: highlight).map { "Open \"\($0.title)\"" } ?? "Open the chat this came from"
        ) {
            retirement?.cancel()
            if let chatID = highlight.linkedChatID {
                commitComment()
                vm.openLinkedChat(chatID)
                vm.dismissReaderHighlightCard()
            }
        }
    }

    static let researchLabel = "What's New"
    static let researchSymbol = "sparkle.magnifyingglass"

    /// A mark is a passage the reader cared about, so chatting about it is
    /// one press away from the card, not only from the notes list's menu.
    private func chatButton(for highlight: SourceHighlight) -> some View {
        footerButton(
            "text.bubble",
            help: highlight.isPictureOnly ? "Chat about this picture" : "Chat about this passage"
        ) {
            retirement?.cancel()
            vm.requestChatAboutHighlight(highlight)
            close()
        }
    }

    private func colorRow(for highlight: SourceHighlight) -> some View {
        HStack(spacing: 6) {
            ForEach(SourceHighlightColor.allCases, id: \.self) { option in
                Button {
                    retirement?.cancel()
                    Task {
                        await vm.setReaderNoteColor(
                            option,
                            highlightID: highlight.id,
                            sourceID: card.sourceID
                        )
                    }
                } label: {
                    Circle()
                        .fill(option.swatch)
                        .frame(width: 15, height: 15)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    option == highlight.color
                                        ? Color.primary.opacity(0.75)
                                        : Color.black.opacity(0.12),
                                    lineWidth: option == highlight.color ? 2 : 1
                                )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.hoverWash(in: Circle(), inset: -4))
                .help(option.meaning)
                .accessibilityLabel(option.spokenName)
            }
        }
    }

    private func removeButton(for highlight: SourceHighlight) -> some View {
        footerButton("trash", help: "Remove highlight") {
            Task {
                await vm.removeReaderHighlight(
                    highlightID: highlight.id,
                    sourceID: card.sourceID
                )
            }
        }
    }

    /// Seeds the field from the mark the card is now on, committing anything
    /// typed against the mark it was on before.
    private func adopt() {
        guard commentingOn != card.highlightID else { return }
        commitComment()
        commentingOn = card.highlightID
        comment = highlight?.note ?? ""
        scheduleRetirementIfNeeded()
    }

    private func close() {
        commitComment()
        vm.dismissReaderHighlightCard()
    }

    /// Writes the typed comment to the mark it belongs to. Closing the card,
    /// leaving the source and re-targeting all route through here: typing is
    /// never thrown away for want of pressing the right button.
    private func commitComment() {
        let target = commentingOn
        guard !target.isEmpty else { return }
        let typed = comment
        Task {
            await vm.setReaderNoteComment(
                typed,
                highlightID: target,
                sourceID: card.sourceID
            )
        }
    }

    private func scheduleRetirementIfNeeded() {
        retirement?.cancel()
        guard card.retiresUntouched, !card.focusesComment else { return }
        retirement = Task { @MainActor in
            try? await Task.sleep(for: Self.retirementDelay)
            guard !Task.isCancelled,
                  vm.readerHighlightCard?.id == card.id else { return }
            vm.dismissReaderHighlightCard()
        }
    }
}

// MARK: - Presentation

extension View {
    /// Presents the open highlight card for `sourceID` as a popover hanging
    /// below the mark's frame — or, when the card was opened without one, off
    /// the point where the pointer was when the card opened.
    ///
    /// Attach this to the view that fills the reader's content area: the
    /// anchor is resolved in its coordinates, a mark scrolled partly out of it
    /// anchors by the part that shows, and a pointer outside it (the notes
    /// list, say) is pulled to its nearest edge, so the popover always hangs
    /// off the page it belongs to.
    func readerHighlightCard(for sourceID: String) -> some View {
        modifier(ReaderHighlightCardPresenter(sourceID: sourceID))
    }
}

private struct ReaderHighlightCardPresenter: ViewModifier {
    @Environment(StudioViewModel.self) private var vm

    let sourceID: String

    /// The card being shown, and the rect it hangs off. Both are set in one
    /// update so the popover never presents against a stale anchor: a
    /// popover reads its attachment once, on the way up.
    @State private var presented: ReaderHighlightCard?
    @State private var anchor: CGRect = .zero
    @State private var locator = ReaderCardAnchorLocator()

    private var card: ReaderHighlightCard? {
        guard let card = vm.readerHighlightCard, card.sourceID == sourceID else { return nil }
        return card
    }

    func body(content: Content) -> some View {
        content
            .background { ReaderCardAnchorProbe(locator: locator) }
            .onAppear { sync(to: card) }
            .onChange(of: card?.id) { _, _ in sync(to: card) }
            .popover(
                item: Binding(
                    get: { presented },
                    set: { newValue in
                        // Only the popover itself sets this, and only to nil —
                        // a click outside, or Escape. That is a dismissal.
                        if newValue == nil, presented != nil {
                            presented = nil
                            if vm.readerHighlightCard?.sourceID == sourceID {
                                vm.dismissReaderHighlightCard()
                            }
                        }
                    }
                ),
                attachmentAnchor: .rect(.rect(anchor)),
                arrowEdge: .bottom
            ) { card in
                ReaderHighlightCardView(card: card)
            }
    }

    private func sync(to card: ReaderHighlightCard?) {
        guard card?.id != presented?.id else { return }
        if let card {
            anchor = locator.anchor(below: card.markOnScreen)
        }
        presented = card
    }
}

extension View {
    /// Presents the Reader's open side chat for `sourceID` as a popover
    /// hanging off the passage it is about (`StudioViewModel.readerSideChat`),
    /// on the side of the words with room for it to grow. Attach it where
    /// `readerHighlightCard(for:)` goes; the two hang off separate views, so
    /// a side chat and a mark's card can be open at once.
    func readerSideChat(for sourceID: String) -> some View {
        modifier(ReaderSideChatPresenter(sourceID: sourceID))
    }
}

private struct ReaderSideChatPresenter: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.uiZoomScale) private var zoom

    let sourceID: String

    /// The side chat being shown and the rect it hangs off, set in one update
    /// for the same reason as the highlight card's.
    @State private var presented: ReaderSideChat?
    @State private var anchor: CGRect = .zero
    @State private var locator = ReaderCardAnchorLocator()

    private var sideChat: ReaderSideChat? {
        guard let open = vm.readerSideChat, open.sourceID == sourceID else { return nil }
        return open
    }

    func body(content: Content) -> some View {
        content.overlay {
            Color.clear
                .allowsHitTesting(false)
                .background { ReaderCardAnchorProbe(locator: locator) }
                .onAppear { sync(to: sideChat) }
                .onChange(of: sideChat?.id) { _, _ in sync(to: sideChat) }
                // The page it hangs off is gone: a popover over nothing would
                // come back over whatever the pane shows next.
                .onDisappear {
                    if let presented { vm.closeReaderSideChat(presented) }
                }
                .popover(
                    item: Binding(
                        get: { presented },
                        set: { newValue in
                            // The popover refuses a click outside and Escape,
                            // so this is only ever AppKit taking it down.
                            if newValue == nil, let shown = presented {
                                presented = nil
                                vm.closeReaderSideChat(shown)
                            }
                        }
                    ),
                    attachmentAnchor: .rect(.rect(anchor)),
                    arrowEdge: presented?.model.placement.side == .above ? .top : .bottom
                ) { sideChat in
                    ReviewChatSideChatPopover(
                        presentation: ChatReplySideChatPresentation(
                            model: sideChat.model,
                            dismiss: { vm.closeReaderSideChat(sideChat) },
                            continueInChat: { vm.continueReaderSideChatInNewChat(sideChat) }
                        )
                    )
                    .id(sideChat.id)
                }
        }
    }

    private func sync(to sideChat: ReaderSideChat?) {
        guard sideChat?.id != presented?.id else { return }
        guard let sideChat, belongsHere(sideChat) else {
            // Still open while this reader moved to another source: it has
            // lost the page it hung off.
            if let shown = presented, vm.readerSideChat?.id == shown.id {
                vm.closeReaderSideChat(shown)
            }
            presented = nil
            return
        }
        anchor = locator.anchor(below: sideChat.markOnScreen)
        // Which side of the words it opens on is settled once, for the height
        // it can grow to at this zoom, so it never jumps across them while an
        // answer streams in (`ChatReplySideChatPlacement`).
        sideChat.model.placement = ChatReplySideChatPlacement.choose(
            room: locator.screenRoom(around: anchor),
            fullHeight: ReviewChatSideChatPopover.fullHeight(zoom: zoom)
        )
        presented = sideChat
    }

    /// The same source open in another window shows nothing: the exchange
    /// belongs to the page the words were selected on.
    private func belongsHere(_ sideChat: ReaderSideChat) -> Bool {
        guard let windowNumber = sideChat.windowNumber,
              let here = locator.view?.window?.windowNumber else { return true }
        return windowNumber == here
    }
}

/// Resolves the rect the card hangs off, in the coordinates of the view the
/// probe sits behind: the mark's frame when the reader gave one, the pointer
/// otherwise.
@MainActor
private final class ReaderCardAnchorLocator {
    fileprivate weak var view: NSView?

    /// How far around the pointer the anchor reaches. Wide enough that the
    /// arrow clears the line being pointed at, narrow enough to point at it.
    private static let reach: CGFloat = 8

    /// The anchor rect for a card about `markOnScreen`: the mark's frame in
    /// the probed view's coordinates, cut to the part of it on screen — the
    /// popover hangs below it, so a mark that runs off the bottom anchors at
    /// the edge and the popover flips above. A mark entirely off screen, or no
    /// mark, anchors at the pointer.
    func anchor(below markOnScreen: CGRect?) -> CGRect {
        guard let view else { return .zero }
        if let markOnScreen, let window = view.window {
            let inWindow = window.convertFromScreen(markOnScreen)
            var local = view.convert(inWindow, from: nil)
            // SwiftUI's coordinates grow downward; AppKit's only do when the
            // view says so.
            if !view.isFlipped {
                local.origin.y = view.bounds.height - local.maxY
            }
            let shown = local.intersection(view.bounds)
            if !shown.isNull, shown.height > 0 {
                return shown
            }
        }
        return pointerAnchor()
    }

    /// The room the screen leaves above and below `anchor`, a rect as
    /// `anchor(below:)` makes them; nil when the view is on no screen.
    func screenRoom(around anchor: CGRect) -> ChatReplySideChatPlacement.ScreenRoom? {
        guard let view else { return nil }
        var local = anchor
        // Back from SwiftUI's downward coordinates to the view's own.
        if !view.isFlipped {
            local.origin.y = view.bounds.height - local.maxY
        }
        return ChatSelectionAnchor.screenRoom(around: local, in: view)
    }

    /// The anchor rect around the pointer, clamped inside the probed view; its
    /// center when the pointer cannot be resolved (no window yet, or a card
    /// opened without a pointer anywhere near).
    private func pointerAnchor() -> CGRect {
        guard let view else { return .zero }
        let bounds = view.bounds
        var point = CGPoint(x: bounds.midX, y: bounds.midY)
        if let window = view.window {
            let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            var local = view.convert(inWindow, from: nil)
            // SwiftUI's coordinates grow downward; AppKit's only do when the
            // view says so.
            if !view.isFlipped { local.y = bounds.height - local.y }
            point = CGPoint(
                x: min(max(local.x, bounds.minX), bounds.maxX),
                y: min(max(local.y, bounds.minY), bounds.maxY)
            )
        }
        return CGRect(
            x: point.x - Self.reach,
            y: point.y - Self.reach,
            width: Self.reach * 2,
            height: Self.reach * 2
        )
    }
}

private struct ReaderCardAnchorProbe: NSViewRepresentable {
    let locator: ReaderCardAnchorLocator

    func makeNSView(context: Context) -> NSView {
        let view = ReaderCardAnchorView()
        locator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        locator.view = nsView
    }
}

/// The probe's view: only its frame is read, so it never takes an event.
/// The side chat's probe lies over the whole page, and a plain `NSView` there
/// was what AppKit hit-tested for every scroll and click: in build 173 no
/// reader scrolled. `allowsHitTesting(false)` on the SwiftUI view it backs
/// does not reach a platform view hosted in its background.
private final class ReaderCardAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One paper a mark's note cites. Its citation opens it, the saved copy when
/// the library holds it and the live page beside Chat when not
/// (`openWebCitation`); the button beside it keeps it, through the
/// import a chat's Web sources row uses (`addCitedPageToSources`), and reads
/// Open once the library has it, the way a citation card in a PDF does.
private struct ReaderHighlightReferenceRow: View {
    @Environment(StudioViewModel.self) private var vm

    let reference: SourceHighlightReference
    /// Its number in the update above, which names it by that number; nil
    /// when nothing on the card numbers it.
    var number: Int? = nil
    /// Called when the row opens the paper, so the card can close behind it.
    let opened: () -> Void

    @State private var isAdding = false

    var body: some View {
        // A memoized lookup by address and by DOI, cheap enough for a body.
        let inLibrary = vm.libraryContainsSource(url: reference.url)
        HStack(spacing: 6) {
            Button(action: open) {
                Label {
                    Text(reference.citation)
                } icon: {
                    if let number {
                        Text("\(number)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(minWidth: 12)
                    } else {
                        Image(systemName: "doc.text")
                    }
                }
                    .font(.system(size: 11))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(inset: -2))
            .help(reference.title.isEmpty ? reference.url : reference.title)

            Button {
                if inLibrary { open() } else { add() }
            } label: {
                Group {
                    if isAdding {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Adding…")
                        }
                    } else if inLibrary {
                        Label("Open", systemImage: "arrow.up.right")
                    } else {
                        Label("Add to Library", systemImage: "plus")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(inLibrary ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(inset: -2))
            .disabled(isAdding)
            .help(inLibrary ? "Open the saved copy" : "Add this paper to your library")
        }
    }

    private func open() {
        guard let url = URL(string: reference.url) else { return }
        vm.openWebCitation(url, title: reference.title.isEmpty ? reference.citation : reference.title)
        opened()
    }

    private func add() {
        guard !isAdding, let url = URL(string: reference.url) else { return }
        isAdding = true
        Task {
            await vm.addCitedPageToSources(url)
            isAdding = false
        }
    }
}
