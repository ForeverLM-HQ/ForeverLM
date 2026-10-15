import AppKit
import PDFKit
import SwiftUI
import WebKit

// MARK: - Memory on the Canvas: the pane's side of it (docs/knowledge-map-design.md, "Memory on the Canvas")
//
// What `KnowledgeMapPane` draws for Memory: the review in place's question
// card, floating beside the card the Canvas flew to (`KnowledgeMapReviewLayer`);
// the Memory layer's switch with its legend (`KnowledgeMapMemoryToggle`); and
// when the marks are read again (`KnowledgeMapMemoryLifecycle`).

/// Where the question card floats: beside the card under review — to its
/// right, or to its left when the right has no room — and clamped into the
/// pane between the floating tools above and below. Pure, for the tests.
enum KnowledgeMapReviewPlacement {
    static let cardWidth: CGFloat = 340
    static let gap: CGFloat = 18
    static let sideMargin: CGFloat = 12
    /// Room kept for the tools floating at the top and the zoom at the bottom.
    static let verticalMargin: CGFloat = 58

    /// The card's top left beside `anchor`, in the pane's points.
    static func origin(beside anchor: CGRect, card: CGSize, pane: CGSize) -> CGPoint {
        let right = anchor.maxX + gap
        let left = anchor.minX - gap - card.width
        let x: CGFloat
        if right + card.width <= pane.width - sideMargin {
            x = right
        } else if left >= sideMargin {
            x = left
        } else {
            x = max(sideMargin, pane.width - sideMargin - card.width)
        }
        return CGPoint(x: x, y: clampedY(anchor.midY - card.height / 2, card: card, pane: pane))
    }

    /// Where the card waits when the page draws no card to float beside:
    /// the trailing side, halfway down.
    static func docked(card: CGSize, pane: CGSize) -> CGPoint {
        CGPoint(
            x: max(sideMargin, pane.width - sideMargin - card.width),
            y: clampedY((pane.height - card.height) / 2, card: card, pane: pane)
        )
    }

    private static func clampedY(_ y: CGFloat, card: CGSize, pane: CGSize) -> CGFloat {
        let top = min(verticalMargin, max(0, (pane.height - card.height) / 2))
        let bottom = max(top, pane.height - verticalMargin - card.height)
        return min(max(y, top), bottom)
    }
}

/// The review in place over the Canvas: the question card beside the card
/// under review, the keys, the goal's celebration. Drawn in the window the
/// review started in.
struct KnowledgeMapReviewLayer: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    var body: some View {
        if let review = vm.knowledgeMap.memory.review, review.windowID == windowState.id {
            KnowledgeMapReviewCardHost(review: review)
                .id(review.id)
        }
    }
}

private struct KnowledgeMapReviewCardHost: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let review: KnowledgeMapReview

    @State private var cardHeight: CGFloat = 240
    @State private var resizes = 0
    /// The page has drawn no card to float beside for a while: the question
    /// docks at the side rather than leave the review stuck.
    @State private var docked = false
    /// The engagement clock's handle on this card (`present(owner:...)`).
    @State private var presenterToken = UUID()
    @State private var focusToken = 0

    private var goalTracker: MemoryReviewEngagementTracker { MemoryReviewEngagementTracker.shared }
    private var isVisible: Bool { review.anchorRect != nil || docked }

    var body: some View {
        GeometryReader { geo in
            let card = CGSize(width: KnowledgeMapReviewPlacement.cardWidth, height: cardHeight)
            let origin = review.anchorRect.map {
                KnowledgeMapReviewPlacement.origin(beside: $0, card: card, pane: geo.size)
            } ?? KnowledgeMapReviewPlacement.docked(card: card, pane: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)
                KnowledgeMapReviewCard(review: review)
                    .frame(width: KnowledgeMapReviewPlacement.cardWidth)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        if abs(height - cardHeight) > 0.5 { cardHeight = height }
                    }
                    .offset(x: origin.x, y: origin.y)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .animation(.easeOut(duration: 0.22), value: origin)
                    .animation(.easeOut(duration: 0.15), value: isVisible)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onChange(of: geo.size) { resizes &+= 1 }
        }
        // The pane changed size (the Reader opened beside it): once it
        // settles, the Canvas flies to the card again, into the room it has.
        .task(id: resizes) {
            guard resizes > 0 else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            review.refocus()
        }
        .background(alignment: .topLeading) {
            KnowledgeMapReviewKeys(focusToken: focusToken) { key in handle(key) }
                .frame(width: 1, height: 1)
        }
        .overlay {
            if let celebration = goalTracker.celebration, celebration.sessionID == review.id {
                MemoryGoalCelebrationView(goalMinutes: celebration.goalMinutes, streak: celebration.streak) {
                    goalTracker.acknowledgeCelebration(celebration.id)
                }
                .transition(.opacity)
            }
        }
        // Hidden while the page draws no card to float beside — a flight
        // between cards — and docked once that lasts.
        .task(id: "\(review.focusKey ?? "")|\(review.anchorRect == nil)") {
            guard review.anchorRect == nil else {
                docked = false
                return
            }
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            if review.anchorRect == nil { docked = true }
        }
        .onChange(of: review.focusKey) { focusToken &+= 1 }
        // Once the answer field goes, the review takes the keyboard back
        // for Forgot and Remembered.
        .onChange(of: review.session.sitting.isAnswerShown) { focusToken &+= 1 }
        .onAppear {
            goalTracker.present(owner: review.session, panel: presenterToken, sessionID: review.session.id, storage: vm.storage)
        }
        .onDisappear {
            goalTracker.dismiss(panel: presenterToken)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("knowledgeMap.review")
    }

    private func handle(_ key: KnowledgeMapReviewKey) -> Bool {
        let sitting = review.session.sitting
        switch key {
        case .escape:
            vm.endKnowledgeMapReview()
            return true
        case .confirm:
            guard isVisible else { return false }
            if sitting.isRoundOver {
                vm.endKnowledgeMapReview()
                return true
            }
            // Return takes the check's verdict once it is in.
            guard sitting.verdictRemembers != nil else { return false }
            vm.confirmKnowledgeMapReviewVerdict()
            return true
        case .forgot, .remembered:
            guard isVisible, sitting.isAnswerShown, !sitting.isRoundOver else { return false }
            // A card not known is only ever Forgot.
            if key == .remembered, sitting.saidNotKnown { return true }
            vm.answerKnowledgeMapReview(remembered: key == .remembered)
            return true
        }
    }
}

/// The question card: "MEMORY · <source>", where the round stands, the card
/// in the wording the review asks it, the learner's answer typed or
/// dictated and Check (never a bare flip: product owner, 2026-10-11), then
/// their answer over the back, the check's verdict on it, why it is right
/// and the source it quotes, and Forgot or Remembered, the verdict's grade
/// first; I Don't Know leaves only Forgot. At the round's
/// end, how it went, Again for the forgotten ones, and Done.
private struct KnowledgeMapReviewCard: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let review: KnowledgeMapReview

    private var session: MemoryCardSessionModel { review.session }
    private var sitting: MemoryCardSitting { session.sitting }
    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    /// The height the answer field's text needs.
    @State private var attemptFieldHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if sitting.isRoundOver {
                endOfRound
            } else if let card = sitting.current {
                question(card)
                answerButtons
            }
            if let error = session.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: Self.shape)
        .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
    }

    // MARK: The parts

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.disabled)
            Spacer(minLength: 4)
            if let card = sitting.current, card.isVariant || card.alwaysAsk {
                wordingMenu(card)
            }
            Button {
                vm.endKnowledgeMapReview()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .help("End the review (Esc)")
            .accessibilityLabel("End the review")
            .accessibilityIdentifier("knowledgeMap.review.close")
        }
    }

    private var eyebrow: String {
        guard !sitting.isRoundOver, let sourceID = sitting.current?.sourceID,
              let title = session.sourceTitles[sourceID] else { return "MEMORY" }
        return "MEMORY \u{00B7} " + title.uppercased()
    }

    private func question(_ card: MemoryCardSitting.Card) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("\(sitting.cardNumber) of \(sitting.cardCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.disabled)
                if review.kind == .practice {
                    tag("PRACTICE", tint: .secondary, help: "Nothing here is due: these answers move no card's schedule")
                }
                if card.isNew { tag("NEW", tint: .accentColor, help: "Your first answer to this card sets when it comes back") }
                if sitting.isRepeat { tag("AGAIN", tint: .secondary, help: "Asked again; the first answer stands") }
            }
            Text(card.prompt.foldingMathSpans())
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(sitting.isAnswerShown ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("knowledgeMap.review.prompt")
            if !card.frontImages.isEmpty {
                MemoryCardImageGrid(images: card.frontImages)
            }
            if card.isFirstVariedServe, !sitting.isRepeat {
                Text("Worded differently on purpose \u{2014} same answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
            if !sitting.isAnswerShown {
                attemptField
            } else if let attempt = sitting.attempt {
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR ANSWER")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                    Text(attempt)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("knowledgeMap.review.yourAnswer")
            }
            if sitting.isAnswerShown {
                Divider()
                if let check = sitting.answerCheck {
                    MemoryCardVerdictLine(check: check)
                }
                Text(card.back.foldingMathSpans())
                    .font(.system(size: 14.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("knowledgeMap.review.back")
                if !card.backImages.isEmpty {
                    MemoryCardImageGrid(images: card.backImages)
                }
                if !card.why.isEmpty {
                    Text("Why: " + card.why.joined(separator: " "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let sourceID = card.sourceID {
                    sourceChip(sourceID: sourceID, quote: card.quote)
                }
                ForEach(Array(card.alsoFrom.enumerated()), id: \.offset) { _, link in
                    sourceChip(sourceID: link.sourceID, quote: link.quote)
                }
            }
        }
    }

    /// The learner's answer: Return checks it, Shift-Return a new line, and
    /// macOS dictation speaks into it. While it has the keyboard the review's
    /// keys rest (`KnowledgeMapReviewKeys.isTyping`); Escape still ends the
    /// review.
    private var attemptField: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let draft = Binding(get: { session.attemptDraft }, set: { session.attemptDraft = $0 })
        return ReviewChatComposerTextView(
            text: draft,
            onSubmit: { vm.checkKnowledgeMapReviewAnswer() },
            autoFocus: true,
            onCancel: { vm.endKnowledgeMapReview() },
            onHeightChange: { attemptFieldHeight = $0 }
        )
        .frame(height: min(max(attemptFieldHeight, 30), 120))
        .overlay(alignment: .topLeading) {
            if session.attemptDraft.isEmpty {
                Text("Type or dictate your answer")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, ReviewChatComposerTextView.overlayTextLeadingInset)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
                    .textSelection(.disabled)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(shape.fill(Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityLabel("Your answer")
        .accessibilityIdentifier("knowledgeMap.review.attempt")
    }

    @ViewBuilder
    private var answerButtons: some View {
        if sitting.isAnswerShown, sitting.saidNotKnown {
            capsule("Forgot", key: "1", prominent: true) { vm.answerKnowledgeMapReview(remembered: false) }
                .help("You didn't know it: Forgot (1 or \u{2190})")
                .disabled(session.isKeepingDraft)
                .accessibilityIdentifier("knowledgeMap.review.forgot")
        } else if sitting.isAnswerShown {
            // With the check's verdict, its grade is filled and Return takes
            // it; the other side is the override. While it checks, both are
            // pale; with no verdict, the learner's own grade as before.
            let verdict = sitting.verdictRemembers
            let checking = sitting.answerCheck == .checking
            HStack(spacing: 8) {
                capsule(
                    verdict == true ? "I Was Wrong" : "Forgot",
                    key: verdict == false ? "\u{21A9}" : "1",
                    prominent: verdict == false
                ) { vm.answerKnowledgeMapReview(remembered: false) }
                    .help(verdict == true ? "The check was wrong: Forgot (1 or \u{2190})" : "Forgot (1 or \u{2190})")
                    .accessibilityIdentifier("knowledgeMap.review.forgot")
                capsule(
                    verdict == false ? "I Was Right" : "Remembered",
                    key: verdict == true ? "\u{21A9}" : "2",
                    prominent: verdict == true || (verdict == nil && !checking)
                ) { vm.answerKnowledgeMapReview(remembered: true) }
                    .help(verdict == false ? "The check was wrong: Remembered (2 or \u{2192})" : "Remembered (2 or \u{2192})")
                    .accessibilityIdentifier("knowledgeMap.review.remembered")
            }
            .disabled(session.isKeepingDraft)
        } else {
            HStack(spacing: 8) {
                capsule("I Don\u{2019}t Know", prominent: false) { vm.showKnowledgeMapReviewAnswerNotKnown() }
                    .help("Show the answer; the card counts as forgot")
                    .accessibilityIdentifier("knowledgeMap.review.notKnown")
                capsule("Check", key: "\u{21A9}", prominent: true) { vm.checkKnowledgeMapReviewAnswer() }
                    .disabled(session.attemptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Check your answer against the card (Return)")
                    .accessibilityIdentifier("knowledgeMap.review.check")
            }
        }
    }

    private var endOfRound: some View {
        let forgotten = sitting.forgottenCount
        let count = sitting.cardCount
        return VStack(alignment: .leading, spacing: 12) {
            Text(sitting.isRepeat ? "Forgotten cards, again" : "That\u{2019}s the round")
                .font(.system(size: 17, design: .serif))
                .textSelection(.disabled)
            Text("\(count) reviewed \u{00B7} \(forgotten) forgotten")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.disabled)
            HStack(spacing: 8) {
                if forgotten > 0 {
                    capsule("Again for the \(forgotten)", prominent: false) { vm.againKnowledgeMapReview() }
                        .help("Ask the forgotten cards once more; the first answers stand")
                        .accessibilityIdentifier("knowledgeMap.review.again")
                }
                capsule("Done", key: "\u{21A9}", prominent: true) { vm.endKnowledgeMapReview() }
                    .help("End the review (Return)")
                    .accessibilityIdentifier("knowledgeMap.review.done")
            }
        }
    }

    // MARK: Pieces

    private func tag(_ text: String, tint: Color, help: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .textSelection(.disabled)
            .help(help)
    }

    /// The card's source, as the card review's chip draws it: its picture,
    /// its title, a chevron. It opens the Reader beside the Canvas at the
    /// passage the card quotes; the review goes on.
    private func sourceChip(sourceID: String, quote: String?) -> some View {
        let title = session.sourceTitles[sourceID] ?? "Source"
        let article = vm.articlesById[vm.canonicalSourceID(sourceID)]
        return Button {
            Task { await vm.openKnowledgeMapReviewSource(sourceID, quote: quote, in: windowState) }
        } label: {
            HStack(spacing: 8) {
                if let article {
                    let bookCoverPath = article.sourceType == .book
                        ? article.parentGroup.flatMap { vm.bookCoverPaths[$0] }
                        : nil
                    SourceThumbnail(source: article, size: 24, bookCoverPath: bookCoverPath)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 5)
            .padding(.trailing, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 9, inset: 0, opacity: 0.08))
        .help("Open \(title) beside the Canvas, at the passage this card quotes")
        .accessibilityLabel("Source: \(title)")
        .contextMenu {
            OtherWindowSourceMenuItem(sourceID: sourceID)
        }
        .accessibilityIdentifier("knowledgeMap.review.source")
    }

    /// How a card is worded, as the card review's ⋯ menu offers it.
    private func wordingMenu(_ card: MemoryCardSitting.Card) -> some View {
        Menu {
            if card.isVariant {
                Button("This Asks Something Else") { session.reportAskedSomethingElse() }
            }
            if card.alwaysAsk {
                Button("Let Its Wording Vary") { session.setAlwaysAsk(false) }
            } else {
                Button("Always Ask in Its Own Words") { session.setAlwaysAsk(true) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        // Drawn as the card review's own ⋯ (MemoryCardSessionView): a menu's
        // chrome comes off with the plain style, and its wash is
        // `hoverHighlight`, which a menu takes where a button style cannot.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(cornerRadius: 6, inset: 0)
        .help("How this card is worded")
        .accessibilityLabel("Wording")
    }

    /// The review's own buttons: a capsule, filled for the one that moves
    /// on, with the key that presses it beside its title.
    private func capsule(_ title: String, key: String? = nil, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let key {
                    Text(key)
                        .font(.caption2.weight(.medium))
                        .opacity(0.7)
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 10)
            .background(Capsule().fill(prominent ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.14), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: prominent ? 0.18 : 0.08))
        .accessibilityLabel(title)
    }
}

// MARK: - The keys

/// The keys a review in place answers to.
enum KnowledgeMapReviewKey: Equatable {
    /// 1 or ←.
    case forgot
    /// 2 or →.
    case remembered
    /// Escape: end the review.
    case escape
    /// Return: the check's verdict, once it is in; Done, at the round's end.
    case confirm

    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 123: self = .forgot
        case 124: self = .remembered
        case 53: self = .escape
        case 36, 76: self = .confirm
        default:
            switch event.charactersIgnoringModifiers {
            case "1": self = .forgot
            case "2": self = .remembered
            default: return nil
            }
        }
    }
}

/// Takes the keyboard for the review while it shows: the Canvas's page would
/// otherwise take Space, the numbers and the arrows as its own. A monitor
/// sees each key in this window before whatever holds the keyboard, and the
/// view takes the keyboard itself when the review starts and at each card,
/// so the page's own keys rest. Typing elsewhere in the window — the chat
/// beside the Canvas, a find field, the Reader — is left alone.
private struct KnowledgeMapReviewKeys: NSViewRepresentable {
    var focusToken: Int
    let handle: @MainActor (KnowledgeMapReviewKey) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.handle = handle
        if view.focusToken != focusToken {
            view.focusToken = focusToken
            view.takeKeyboardSoon()
        }
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class KeyView: NSView {
        var handle: (@MainActor (KnowledgeMapReviewKey) -> Bool)?
        var focusToken = 0
        private var monitor: Any?
        /// The Canvas's page, when it held the keyboard before the review
        /// took it: it gets it back when the review ends.
        private weak var canvasResponder: NSResponder?

        override var acceptsFirstResponder: Bool { true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let window, window.firstResponder === self {
                window.makeFirstResponder(canvasResponder)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
                return consumed ? nil : event
            }
            takeKeyboardSoon()
        }

        // Never in the way of the pointer: the Canvas under it takes every
        // click, drag and scroll.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Takes the keyboard from the page, never from a field being typed in.
        func takeKeyboardSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, !Self.isTyping(in: window),
                      window.firstResponder !== self else { return }
                if Self.isCanvas(window.firstResponder) { self.canvasResponder = window.firstResponder }
                window.makeFirstResponder(self)
            }
        }

        private static func isCanvas(_ responder: NSResponder?) -> Bool {
            var view = responder as? NSView
            while let current = view {
                if current is KnowledgeMapWebView { return true }
                view = current.superview
            }
            return false
        }

        // The review's keys arrive through the monitor; the rest rest while
        // the review holds the keyboard, rather than beep.
        override func keyDown(with event: NSEvent) {}

        private func consume(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !Self.isTyping(in: window),
                  let key = KnowledgeMapReviewKey(event) else { return false }
            return handle?(key) ?? false
        }

        /// Whether the keyboard is with something the learner types or reads
        /// in: a text field or view, or a page other than the Canvas's (the
        /// Reader, the chat), or a PDF.
        static func isTyping(in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder else { return false }
            if responder is NSText { return true }
            var view = responder as? NSView
            while let current = view {
                if current is KnowledgeMapWebView { return false }
                if current is WKWebView || current is PDFView { return true }
                view = current.superview
            }
            return false
        }
    }
}

// MARK: - The Memory layer's switch

/// The Memory layer's switch, beside the view caption's: each card's pip of
/// how its kept cards stand, and a tiny legend.
struct KnowledgeMapMemoryToggle: View {
    @Environment(StudioViewModel.self) private var vm
    @State private var showsLegend = false

    var body: some View {
        let memory = vm.knowledgeMap.memory
        HStack(spacing: 0) {
            Button {
                memory.isShown.toggle()
            } label: {
                Image(systemName: MemoryReviewSession.sidebarIcon)
                    .zoomedSystemFont(size: 14)
                    .frame(width: 32, height: 28)
                    .foregroundStyle(memory.isShown ? Color.accentColor : Color.primary.opacity(0.8))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(memory.isShown ? Color.accentColor.opacity(0.14) : .clear)
                    )
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: 0.10))
            .help(memory.isShown ? "Hide how your cards stand" : "Show how the cards behind each card stand: due, fading, holding")
            .accessibilityLabel("Memory layer")
            .accessibilityValue(memory.isShown ? "On" : "Off")
            .accessibilityIdentifier("knowledgeMap.memory.toggle")
            Button {
                showsLegend.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 28)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .help("What the Memory marks mean")
            .accessibilityLabel("Memory legend")
            .popover(isPresented: $showsLegend, arrowEdge: .bottom) {
                KnowledgeMapMemoryLegend()
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

/// What the marks mean.
struct KnowledgeMapMemoryLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(Color.green, "Solid", "Every card holds until a later day")
            row(Color.orange, "Due", "Cards to review now")
            row(Color(red: 0.80, green: 0.36, blue: 0.33), "Fading", "Overdue by more than two days")
            row(Color.secondary.opacity(0.45), "Dusty", "Mostly fading, or untouched for a month")
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
        .textSelection(.disabled)
    }

    private func row(_ color: Color, _ name: String, _ meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
            Text(meaning)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - When the marks are read

extension View {
    /// The Canvas pane's Memory: the marks read when it opens, when its
    /// cards change, when cards are kept, answered or retired anywhere, and
    /// when the layer is turned on; a review ended by Escape in the page, or
    /// stranded by the Canvas going away.
    func knowledgeMapMemory() -> some View {
        modifier(KnowledgeMapMemoryLifecycle())
    }
}

private struct KnowledgeMapMemoryLifecycle: ViewModifier {
    @Environment(StudioViewModel.self) private var vm

    func body(content: Content) -> some View {
        let memory = vm.knowledgeMap.memory
        content
            .task(id: "\(vm.knowledgeMap.contentRevision)|\(memory.isShown)|\(vm.memoryCardRevision)") {
                await vm.refreshKnowledgeMapMemory()
            }
            .onChange(of: memory.escapeRequests) {
                vm.endKnowledgeMapReview()
            }
            .onAppear {
                vm.endKnowledgeMapReviewIfStranded()
            }
            .onDisappear {
                guard memory.review != nil else { return }
                Task { @MainActor in
                    // A pane rebuilt in place (the Reader opening beside it)
                    // comes straight back; one that went away does not.
                    try? await Task.sleep(for: .milliseconds(600))
                    vm.endKnowledgeMapReviewIfStranded()
                }
            }
    }
}
