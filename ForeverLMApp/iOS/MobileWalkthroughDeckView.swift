import SwiftUI
import UIKit
import WebKit

/// A source's walkthrough on the phone: the story of the paper as a deck of
/// cards, flipped through by swiping, one point a card (product owner, 2026-09-23:
/// "I need to be able to go through the cards for a paper on my phone and
/// have a good understanding of the paper afterward … one point at a time
/// interspersed with some questions"). The Mac deals the same cards beside
/// the PDF, moving the page to each figure; a phone has no room for both, so
/// a card brings its figure or panel with it instead — cut from the PDF
/// where the Mac's figure analysis measured it — above its one sentence. A
/// question is a card of its own that turns over to the reference answer.
/// walkthrough-design.md, "the deck on the phone" and "one point a card".
struct MobileWalkthroughDeckView: View {
    let source: MobileCloudSource
    let deck: MobileWalkthroughDeck

    @Environment(\.dismiss) private var dismiss
    @State private var position: Int
    @State private var enlarged: MobileWalkthroughEnlargedFigure?
    /// The one chat the deck's cards share, as the Mac's walk is one chat:
    /// each card's sheet shows that card's part of it.
    @StateObject private var chat: MobileChatViewModel
    @State private var showsCardChat = false

    /// The deck as dealt, once: a card a point, a question a card of its own.
    private let cards: [MobileWalkthroughDeck.Card]

    /// `notebook` is the notebook the walk was opened in, when it was: the
    /// walk's chat is filed under it, as a walk started in a notebook window
    /// on the Mac plays in a chat of that notebook.
    init(
        source: MobileCloudSource,
        deck: MobileWalkthroughDeck,
        sourceText: String = "",
        notebook: MobileCloudNotebook? = nil
    ) {
        self.source = source
        self.deck = deck
        let cards = deck.cards
        self.cards = cards
        let restored = MobileWalkthroughDeckPosition.restored(
            sourceID: source.id,
            cardCount: cards.count + 2
        )
        _position = State(initialValue: restored)
        // The autoclosure runs once for the view's lifetime; a view model
        // made eagerly here would be made and dropped on every redraw.
        _chat = StateObject(wrappedValue: Self.makeChat(
            source: source,
            deck: deck,
            sourceText: sourceText,
            notebook: notebook,
            stepIndex: cards.indices.contains(restored - 1) ? cards[restored - 1].stepIndex : 0
        ))
    }

    private static func makeChat(
        source: MobileCloudSource,
        deck: MobileWalkthroughDeck,
        sourceText: String,
        notebook: MobileCloudNotebook?,
        stepIndex: Int
    ) -> MobileChatViewModel {
        let chat = MobileChatViewModel(
            source: source,
            sourceText: sourceText,
            selection: nil,
            walkthrough: deck.record,
            notebook: notebook
        )
        chat.currentStepIndex = max(0, min(deck.steps.count - 1, stepIndex))
        return chat
    }

    /// The card on screen, when it is a step's (not the cover or the end).
    private var currentCard: MobileWalkthroughDeck.Card? {
        cards.indices.contains(position - 1) ? cards[position - 1] : nil
    }

    /// The cover, one card a point or a question, and the last card.
    private var cardCount: Int { cards.count + 2 }
    private var lastPosition: Int { cardCount - 1 }

    private var relativePDFPath: String? {
        MobileSourceFilePath.relativePDFPath(localFilePath: source.localFilePath, url: source.url)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            TabView(selection: $position) {
                coverCard
                    .tag(0)

                ForEach(cards.indices, id: \.self) { index in
                    let card = cards[index]
                    let step = deck.steps[card.stepIndex]
                    Group {
                        switch card.face {
                        case .point(let point):
                            // The step's own figure, or the picture it shows
                            // without pointing at it (a figure it names, one
                            // drawn for it, or the one an earlier step of its
                            // chapter showed).
                            let picture = deck.pictureFigure(ofStepAt: card.stepIndex)
                            MobileWalkthroughPointCard(
                                step: step,
                                card: card,
                                point: point,
                                match: MobileWalkthroughDeck.figure(for: card, of: step, in: source.paperFigures)
                                    ?? picture.flatMap { MobileWalkthroughDeck.figure(labelled: $0.label, panel: $0.panel, in: source.paperFigures) },
                                figureLabel: MobileWalkthroughDeck.figureDisplayLabel(for: card, of: step)
                                    ?? picture.map { $0.label + ($0.panel ?? "") },
                                panelLabel: MobileWalkthroughDeck.panelLabel(for: card, of: step) ?? picture?.panel,
                                sourceID: source.id,
                                drawnImageID: deck.drawnPictureID(ofStepAt: card.stepIndex),
                                relativePDFPath: relativePDFPath,
                                onEnlarge: { enlarged = $0 }
                            )
                        case .animation:
                            MobileWalkthroughAnimationCard(
                                step: step,
                                animationReference: deck.record.flatMap { record in
                                    record.steps.indices.contains(card.stepIndex) ? record.steps[card.stepIndex].animation : nil
                                }
                            )
                        case .question(let question, let context):
                            let match = MobileWalkthroughDeck.figure(for: step, in: source.paperFigures)
                            MobileWalkthroughQuestionCard(
                                step: step,
                                question: question,
                                context: context,
                                match: match,
                                panelLetters: step.quizKind == .find ? MobileWalkthroughDeck.panelLetters(of: match) : [],
                                relativePDFPath: relativePDFPath,
                                recall: chat.recall[step.id],
                                canGrade: deck.record != nil,
                                onGrade: { remembered in
                                    chat.currentStepIndex = card.stepIndex
                                    chat.gradeRecall(remembered: remembered)
                                },
                                onPick: { picked, correct, firstTry in
                                    chat.currentStepIndex = card.stepIndex
                                    chat.gradeFind(picked: picked, correct: correct, firstTry: firstTry)
                                },
                                onAnswer: {
                                    chat.currentStepIndex = card.stepIndex
                                    showsCardChat = true
                                }
                            )
                        case .recap(let claim, let chapterTitle):
                            MobileWalkthroughRecapCard(
                                chapterTitle: chapterTitle,
                                claim: claim,
                                score: Self.chapterScore(closing: step, deck: deck, recall: chat.recall)
                            )
                        }
                    }
                    .tag(index + 1)
                }

                finishCard
                    .tag(lastPosition)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            footer
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .onChange(of: position) { _, value in
            MobileWalkthroughDeckPosition.save(value, sourceID: source.id, cardCount: cardCount)
            if cards.indices.contains(value - 1) { chat.currentStepIndex = cards[value - 1].stepIndex }
        }
        .fullScreenCover(item: $enlarged) { figure in
            MobileWalkthroughFigureViewer(figure: figure)
        }
        .sheet(isPresented: $showsCardChat) {
            MobileChatView(viewModel: chat, presentation: .walkthroughCard)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            // The tutor answers from the source; the card's chat opens at once
            // and its text arrives here, off the reader's own load.
            guard !chat.hasSourceText,
                  let text = try? await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: source.id) else { return }
            chat.provideSourceText(text)
        }
        .onDisappear { chat.finish() }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(spacing: MobileDesign.Spacing.small) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(
                            width: MobileDesign.Metrics.minimumTouchTarget,
                            height: MobileDesign.Metrics.minimumTouchTarget
                        )
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("walkthrough.close")

                Spacer()

                if currentCard != nil {
                    Text("\(position) of \(cards.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                }

                Spacer()

                // Balances the close button so the count sits centred.
                Color.clear.frame(width: MobileDesign.Metrics.minimumTouchTarget, height: 1)
            }

            ProgressView(value: Double(position), total: Double(lastPosition))
                .tint(.accentColor)
                .padding(.horizontal, MobileDesign.Spacing.large)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, MobileDesign.Spacing.small)
        .padding(.bottom, MobileDesign.Spacing.small)
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation { position = max(0, position - 1) }
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .frame(
                        width: MobileDesign.Metrics.minimumTouchTarget,
                        height: MobileDesign.Metrics.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .disabled(position == 0)

            Spacer()

            if currentCard != nil, deck.record != nil {
                Button {
                    showsCardChat = true
                } label: {
                    Label("Ask", systemImage: chat.displayedMessages.isEmpty ? "text.bubble" : "text.bubble.fill")
                        .font(.body.weight(.semibold))
                        .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Ask about this card")
                .accessibilityIdentifier("walkthrough.ask")

                Spacer()
            }

            Button {
                withAnimation { position = min(lastPosition, position + 1) }
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .frame(
                        width: MobileDesign.Metrics.minimumTouchTarget,
                        height: MobileDesign.Metrics.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .disabled(position == lastPosition)
            .accessibilityIdentifier("walkthrough.next")
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.bottom, MobileDesign.Spacing.small)
    }

    // MARK: Cover and end

    private var coverCard: some View {
        MobileWalkthroughCardSurface {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
                Label("Walkthrough", systemImage: "figure.walk")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(deck.title.isEmpty ? source.title : deck.title)
                    .font(.system(.title, design: .serif).weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if !deck.title.isEmpty, deck.title != source.title {
                    Text(source.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let citation = source.citationSubtitle {
                    Text(citation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(coverSummary)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    withAnimation { position = 1 }
                } label: {
                    Text("Begin")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, MobileDesign.Spacing.small)
            }
        }
    }

    /// How a chapter's questions went, for its recap: remembered (or found
    /// on the figure) against asked.
    static func chapterScore(closing step: MobileWalkthroughDeck.Step, deck: MobileWalkthroughDeck, recall: [String: Bool]) -> (remembered: Int, asked: Int) {
        guard let chapter = deck.chapter(ofStep: step.id) else { return (0, 0) }
        let asked = deck.steps.filter { chapter.stepIDs.contains($0.id) && $0.question != nil }
        return (asked.filter { recall[$0.id] == true }.count, asked.count)
    }

    private var coverSummary: String {
        var parts = ["\(cards.count) \(cards.count == 1 ? "card" : "cards")"]
        if let chapters = deck.chapters, chapters.count > 1 { parts.append("\(chapters.count) chapters") }
        let figures = deck.figureStepCount
        if figures > 0 { parts.append("\(figures) \(figures == 1 ? "figure" : "figures")") }
        let questions = deck.questionCount
        if questions > 0 { parts.append("\(questions) \(questions == 1 ? "question" : "questions")") }
        return parts.joined(separator: " · ")
    }

    private var finishCard: some View {
        MobileWalkthroughCardSurface {
            VStack(spacing: MobileDesign.Spacing.large) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Text(source.title)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: MobileDesign.Spacing.medium) {
                    Button {
                        withAnimation { position = 1 }
                    } label: {
                        Label("Start Over", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("Done") { dismiss() }
                        .controlSize(.large)
                }
                .padding(.top, MobileDesign.Spacing.small)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Cards

/// One card's surface: a rounded sheet the size of the page, scrolling its
/// own content when a card runs longer than the screen. A card with one
/// sentence on it sits that sentence in the middle of the sheet rather than
/// at its top (`centersContent`), so a short card reads as a card and not a
/// page with a heading.
private struct MobileWalkthroughCardSurface<Content: View>: View {
    var centersContent = false
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MobileDesign.Spacing.xLarge)
                    .frame(minHeight: centersContent ? proxy.size.height : 0, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: MobileDesign.Radius.composer, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: MobileDesign.Radius.composer, style: .continuous))
        .shadow(color: MobileDesign.elevatedShadow, radius: 12, y: 4)
        .frame(maxWidth: MobileDesign.Metrics.readableContentWidth)
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.small)
    }
}

/// The step's title, small, over each of its cards: the one line that says
/// what the point belongs to.
private struct MobileWalkthroughCardEyebrow: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .kerning(0.4)
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
            .accessibilityIdentifier("walkthrough.card.title")
    }
}

/// A step's animation on a card of its own, under the step's title and
/// with no figure above it (product owner, 2026-09-24: "animations should also
/// always be shown separately from an image"), so it has the card's height.
private struct MobileWalkthroughAnimationCard: View {
    let step: MobileWalkthroughDeck.Step
    /// A saved animation the step shows by reference, pinned to one of its
    /// own steps (`MobileWalkthroughReferencedAnimation`).
    let animationReference: WalkthroughAnimationReference?

    var body: some View {
        MobileWalkthroughCardSurface {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
                MobileWalkthroughCardEyebrow(text: step.title)
                if let html = step.animationHTML {
                    MobileWalkthroughAnimationView(html: html)
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
                                .stroke(MobileDesign.subtleStroke)
                        )
                } else if let animationReference {
                    MobileWalkthroughReferencedAnimation(reference: animationReference)
                        .frame(height: 460)
                        .clipShape(RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
                                .stroke(MobileDesign.subtleStroke)
                        )
                }
            }
        }
        .accessibilityIdentifier("walkthrough.card.animation")
    }
}

/// A point on a card of its own: the step's title above, the picture the
/// point is about — the figure or panel it names, or the one its step
/// shows — and the one sentence, set large. The step's animation has a
/// card of its own (`MobileWalkthroughAnimationCard`).
private struct MobileWalkthroughPointCard: View {
    let step: MobileWalkthroughDeck.Step
    let card: MobileWalkthroughDeck.Card
    let point: MobileWalkthroughDeck.Step.Point
    let match: MobileWalkthroughDeck.FigureMatch?
    /// "Figure 2d", following the point's own panel when it names one.
    let figureLabel: String?
    /// The panel the crop is cut to, when the figure analysis has not
    /// measured it: the letter the page prints for it.
    let panelLabel: String?
    let sourceID: String
    /// The picture drawn for the step, or borrowed from a step of its
    /// chapter, shown where the card has no figure.
    let drawnImageID: String?
    let relativePDFPath: String?
    let onEnlarge: (MobileWalkthroughEnlargedFigure) -> Void

    @State private var renderedFigure: UIImage?

    /// The drawn picture, when the card has no figure to show instead.
    private var shownDrawnImageID: String? {
        match == nil && figureLabel == nil ? drawnImageID : nil
    }

    var body: some View {
        MobileWalkthroughCardSurface(centersContent: match == nil && shownDrawnImageID == nil) {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
                MobileWalkthroughCardEyebrow(text: step.title)

                figure

                Text(point.text)
                    .font(.system(.title2, design: .default).weight(.medium))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("walkthrough.card.point")

                if !step.more.isEmpty {
                    MobileWalkthroughMoreChips(more: step.more)
                }

                if !step.cites.isEmpty {
                    MobileWalkthroughCitedWorks(citations: step.cites)
                }

                if card.countInStep > 1 {
                    stepDots
                }
            }
        }
    }

    /// Which of the step's cards this is, as dots under the point.
    private var stepDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<card.countInStep, id: \.self) { index in
                Circle()
                    .fill(index <= card.indexInStep ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var figure: some View {
        if let match {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                Button {
                    guard let renderedFigure else { return }
                    onEnlarge(MobileWalkthroughEnlargedFigure(
                        image: renderedFigure,
                        title: figureLabel ?? match.figure.figureLabel
                    ))
                } label: {
                    MobilePaperFigureImage(
                        figure: match.figure,
                        panel: match.panel,
                        panelLabel: panelLabel,
                        sharesPageWithOtherFigures: match.sharesPage,
                        relativePDFPath: relativePDFPath,
                        onLoad: { renderedFigure = $0 }
                    )
                    .padding(MobileDesign.Spacing.small)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
                            .stroke(MobileDesign.subtleStroke)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the figure full screen")

                HStack(alignment: .firstTextBaseline) {
                    Text(figureLabel ?? match.figure.figureLabel)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Page \(match.figure.pageNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.disabled)
            }
        } else if let figureLabel {
            // The figure is named but this phone has no crop of it yet (the
            // Mac has not analysed the paper's figures): say which one to
            // look at in the paper.
            Label(figureLabel, systemImage: "chart.xyaxis.line")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if let shownDrawnImageID {
            MobileWalkthroughDrawnPicture(
                sourceID: sourceID,
                imageID: shownDrawnImageID,
                title: step.title,
                onEnlarge: onEnlarge
            )
        }
    }
}

/// A picture drawn for a step, from the package the Mac put on the Source
/// record beside the walk (`MobileSourceFileStore.walkthroughPicture`), on the
/// same white plate as a figure; pressing it opens it full screen. Until the
/// package has come down, or when the Mac sent none for it, the card shows
/// none rather than a placeholder, as the Mac's card does.
private struct MobileWalkthroughDrawnPicture: View {
    let sourceID: String
    let imageID: String
    let title: String
    let onEnlarge: (MobileWalkthroughEnlargedFigure) -> Void

    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            // Something to hang the task on while nothing is shown.
            Color.clear.frame(height: 0)
            if let image {
                Button {
                    onEnlarge(MobileWalkthroughEnlargedFigure(image: image, title: title))
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 280)
                        .padding(MobileDesign.Spacing.small)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
                                .stroke(MobileDesign.subtleStroke)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityHint("Shows the picture full screen")
                .accessibilityIdentifier("walkthrough.card.drawnPicture")
            }
        }
        .task(id: "\(sourceID)#\(imageID)") {
            image = await MobileSourceFileStore.shared.walkthroughPicture(sourceID: sourceID, imageID: imageID)
        }
    }
}

/// Say more chips under a point (the lesson's): context
/// offered, never pushed. A chip pressed opens its words under the point,
/// labelled general knowledge when they are not the source's own.
private struct MobileWalkthroughMoreChips: View {
    let more: [MobileWalkthroughDeck.Step.More]
    @State private var opened: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MobileDesign.Spacing.small) {
                    ForEach(more, id: \.label) { chip in
                        let isOpen = opened.contains(chip.label)
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if isOpen { opened.remove(chip.label) } else { opened.insert(chip.label) }
                            }
                        } label: {
                            Text(chip.label)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, MobileDesign.Spacing.medium)
                                .frame(minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(.accentColor)
                        .accessibilityHint(chip.fromPaper ? "In the source's own words" : "General knowledge, not from the source")
                        .accessibilityIdentifier("walkthrough.more.chip")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            ForEach(more.filter { opened.contains($0.label) }, id: \.label) { chip in
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.xSmall) {
                    if !chip.fromPaper {
                        Text("General knowledge")
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                    }
                    Text(chip.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("walkthrough.more.text")
            }
        }
    }
}

/// The works a step cites, under its point (walkthrough-design.md,
/// "2026-09-30: a card shows the work it cites"): a source card each — what
/// it is, its title and byline — that opens the work's page, or searches
/// Google Scholar for a work named with no address. The Mac opens the
/// library's own copy when it holds one; the phone opens the page.
private struct MobileWalkthroughCitedWorks: View {
    let citations: [PaperWalkthroughCitation]
    @Environment(\.openURL) private var openURL

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            ForEach(citations, id: \.identityKey) { citation in
                Button {
                    if let url = citation.address ?? citation.scholarSearchURL { openURL(url) }
                } label: {
                    HStack(spacing: MobileDesign.Spacing.medium) {
                        Image(systemName: citation.kind?.symbolName ?? "text.quote")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PaperWalkthroughCitation.eyebrow(kind: citation.kind))
                                .font(.caption2.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                            Text(citation.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                            if let byline = citation.byline {
                                Text(byline)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(MobileDesign.Spacing.medium)
                    .background(Color.primary.opacity(0.04), in: shape)
                    .overlay(shape.stroke(MobileDesign.subtleStroke))
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .textSelection(.disabled)
                .accessibilityHint(citation.address != nil ? "Opens its page" : "Searches Google Scholar for it")
                .accessibilityIdentifier("walkthrough.cites.card")
            }
        }
    }
}

/// A chapter's recap card (the lesson's): the claim the
/// learner can now say, and how the chapter's questions went.
private struct MobileWalkthroughRecapCard: View {
    let chapterTitle: String
    let claim: String
    let score: (remembered: Int, asked: Int)

    var body: some View {
        MobileWalkthroughCardSurface(centersContent: true) {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
                MobileWalkthroughCardEyebrow(text: chapterTitle, tint: Color.accentColor)
                Text("You can now say")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                Text(claim)
                    .font(.system(.title2, design: .serif).weight(.medium))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("walkthrough.recap.claim")
                if score.asked > 0 {
                    Text("\(score.remembered) of \(score.asked) \(score.asked == 1 ? "question" : "questions") remembered")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                        .accessibilityIdentifier("walkthrough.recap.score")
                }
            }
        }
    }
}

/// A question as a card of its own that turns over: the question on the
/// front, under the reminder its writer gave it and — on a Predict — the
/// figure blurred until the learner has guessed; the reference answer and
/// what a full answer mentions on the back, then Forgot or Remembered. A
/// Find it offers the figure's panel letters as chips. Questions stay open
/// (walkthrough-design.md): nothing here grades a typed answer — Answer
/// opens the card's chat, where the tutor does.
private struct MobileWalkthroughQuestionCard: View {
    let step: MobileWalkthroughDeck.Step
    let question: String
    let context: String?
    /// The figure a Predict hides or a Find it is answered on; nil for a
    /// question about words.
    let match: MobileWalkthroughDeck.FigureMatch?
    /// A Find it's panel letters, each a chip; empty otherwise.
    let panelLetters: [String]
    let relativePDFPath: String?
    let recall: Bool?
    let canGrade: Bool
    let onGrade: (Bool) -> Void
    /// A Find it's pick: the letter, whether it was the one, and whether on
    /// the first try.
    let onPick: (String, Bool, Bool) -> Void
    let onAnswer: () -> Void

    @State private var showsAnswer = false
    @State private var missedOnce = false

    private var isPredict: Bool { step.quizKind == .predict }
    private var isFind: Bool { step.quizKind == .find && !panelLetters.isEmpty && step.targetPanel != nil }
    /// A prediction's data stay hidden until the card is turned or graded.
    private var veiled: Bool { isPredict && !showsAnswer && recall == nil }

    var body: some View {
        MobileWalkthroughCardSurface(centersContent: match == nil) {
            ZStack {
                front
                    .opacity(showsAnswer ? 0 : 1)
                    .accessibilityHidden(showsAnswer)
                back
                    .opacity(showsAnswer ? 1 : 0)
                    // Drawn pre-mirrored, so it reads the right way round once
                    // the card has turned.
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                    .accessibilityHidden(!showsAnswer)
            }
            .rotation3DEffect(.degrees(showsAnswer ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: showsAnswer)
        }
    }

    @ViewBuilder
    private var figure: some View {
        if let match {
            MobilePaperFigureImage(
                figure: match.figure,
                panel: isFind ? nil : match.panel,
                panelLabel: isFind ? nil : step.panelLabel,
                sharesPageWithOtherFigures: match.sharesPage,
                relativePDFPath: relativePDFPath,
                onLoad: nil
            )
            .blur(radius: veiled ? 16 : 0)
            .overlay {
                if veiled {
                    Text("Hidden until you answer")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MobileDesign.Spacing.medium)
                        .padding(.vertical, MobileDesign.Spacing.xSmall)
                        .background(.thinMaterial, in: Capsule())
                        .textSelection(.disabled)
                        .accessibilityIdentifier("walkthrough.card.veil")
                }
            }
            .padding(MobileDesign.Spacing.small)
            .background(Color.white, in: RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
                    .stroke(MobileDesign.subtleStroke)
            )
            .animation(.easeOut(duration: 0.3), value: veiled)
        }
    }

    private var front: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
            MobileWalkthroughCardEyebrow(text: step.quizKind.label, tint: Color.accentColor)
            figure
            if let context {
                Text(context)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("walkthrough.recall.context")
            }
            Text(question)
                .font(.system(.title2, design: .default).weight(.semibold))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("walkthrough.recall.question")
            if isFind, recall == nil, let target = step.targetPanel {
                // Answered on the figure: a chip a panel.
                HStack(spacing: MobileDesign.Spacing.small) {
                    ForEach(panelLetters, id: \.self) { letter in
                        Button {
                            let correct = PaperWalkthroughValidation.samePanel(letter, target)
                            if correct || missedOnce {
                                onPick(letter, correct, !missedOnce)
                                showsAnswer = true
                            } else {
                                withAnimation { missedOnce = true }
                            }
                        } label: {
                            Text(PaperWalkthroughValidation.panelDisplayName(letter))
                                .font(.body.weight(.semibold).monospaced())
                                .frame(minWidth: 44, minHeight: 40)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canGrade)
                        .accessibilityLabel("Panel \(PaperWalkthroughValidation.panelDisplayName(letter))")
                        .accessibilityIdentifier("walkthrough.find.\(letter.lowercased())")
                    }
                }
                if missedOnce {
                    Text("Not that one — look again at what each panel plots.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("walkthrough.find.miss")
                }
            }
            HStack(spacing: MobileDesign.Spacing.small) {
                if step.answer != nil || !step.keyPoints.isEmpty {
                    Button {
                        showsAnswer = true
                    } label: {
                        Label("Show Answer", systemImage: "arrow.turn.up.right")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("walkthrough.showAnswer")
                }
                if canGrade, recall == nil, !isFind {
                    Button {
                        onAnswer()
                    } label: {
                        Label(isPredict ? "Guess" : "Answer", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Type or dictate your answer; the tutor grades it")
                    .accessibilityIdentifier("walkthrough.answer")
                }
            }
            .padding(.top, MobileDesign.Spacing.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var back: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
            MobileWalkthroughCardEyebrow(text: "Answer", tint: .green)
            if isPredict || isFind { figure }
            if let answer = step.answer {
                Text(answer)
                    .font(.title3.weight(.medium))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !step.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.xSmall) {
                    ForEach(step.keyPoints.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(step.keyPoints[index])
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if canGrade {
                if let recall {
                    Label(
                        recall ? (isFind ? "Found it" : "Remembered") : "Missed — worth coming back to",
                        systemImage: recall ? "checkmark.seal" : "arrow.uturn.backward.circle"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(recall ? Color.green : Color.orange)
                    .textSelection(.disabled)
                } else if !isFind {
                    HStack(spacing: MobileDesign.Spacing.small) {
                        Button {
                            onGrade(false)
                        } label: {
                            Label("Forgot", systemImage: "xmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .accessibilityIdentifier("walkthrough.forgot")
                        Button {
                            onGrade(true)
                        } label: {
                            Label("Remembered", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .accessibilityIdentifier("walkthrough.remembered")
                    }
                    .padding(.top, MobileDesign.Spacing.small)
                }
            }
            Button {
                showsAnswer = false
            } label: {
                Label("Question", systemImage: "arrow.turn.up.left")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Figure full screen

struct MobileWalkthroughEnlargedFigure: Identifiable {
    let id = UUID()
    let image: UIImage
    let title: String
}

/// A figure at full screen, pinched and double-tapped to zoom, since a panel
/// cut from a printed page carries more than a card's width can show.
private struct MobileWalkthroughFigureViewer: View {
    let figure: MobileWalkthroughEnlargedFigure
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MobileZoomableImage(image: figure.image)
                .background(Color.white.ignoresSafeArea())
                .navigationTitle(figure.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct MobileZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isAccessibilityElement = true
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.toggleZoom(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func toggleZoom(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let scale = min(scrollView.maximumZoomScale, 3)
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                scrollView.zoom(
                    to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                    animated: true
                )
            }
        }
    }
}

// MARK: - Animation

/// A step's animation, under the same policy the Mac shows it with
/// (`PaperWalkthroughAnimationDocument`): one document in a store of its own,
/// nothing fetched, no navigation, no windows.
private struct MobileWalkthroughAnimationView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        load(into: webView, coordinator: context.coordinator)
    }

    private func load(into webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.loadedHTML != html else { return }
        coordinator.loadedHTML = html
        webView.loadHTMLString(PaperWalkthroughAnimationDocument.document(for: html), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let isDocument = navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.request.url?.absoluteString == "about:blank"
            decisionHandler(isDocument ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}

// MARK: - The reader's control

/// Walk Through in the reader's bottom bar. With a walkthrough, a tap opens
/// the deck and a hold offers Write Again; without one, a tap writes it and
/// the deck opens as soon as its steps are saved; while one is being
/// written, the control shows the stage and a hold offers Cancel.
struct MobileWalkthroughToolbarControl: View {
    let source: MobileCloudSource
    /// The deck to open, when the source has one.
    let deck: MobileWalkthroughDeck?
    let open: () -> Void

    @EnvironmentObject private var audio: MobileAudioReviewViewModel
    @ObservedObject private var generator = MobileWalkthroughGenerator.shared

    var body: some View {
        if let stage = generator.stages[source.id] {
            Menu {
                Text(stage.label)
                if deck != nil {
                    Button("Open Walkthrough", systemImage: "rectangle.stack") { open() }
                }
                Button("Stop Writing", systemImage: "xmark", role: .destructive) {
                    generator.cancel(source.id)
                }
                .accessibilityIdentifier("reader.walkthrough.cancel")
            } label: {
                ProgressView()
                    .frame(
                        minWidth: MobileDesign.Metrics.minimumTouchTarget,
                        minHeight: MobileDesign.Metrics.minimumTouchTarget
                    )
            }
            .accessibilityLabel(stage.label)
            .accessibilityIdentifier("reader.walkthrough.writing")
        } else if deck != nil {
            Menu {
                Button("Write Walkthrough Again", systemImage: "arrow.clockwise") {
                    generator.write(source, audio: audio)
                }
                .disabled(!MobileWalkthroughGenerator.canWalkThrough(source))
                .accessibilityIdentifier("reader.walkthrough.rewrite")
            } label: {
                label
            } primaryAction: {
                open()
            }
            .accessibilityLabel("Walk Through")
            .accessibilityHint("Touch and hold to write the walkthrough again")
            .accessibilityIdentifier("reader.walkthrough")
        } else {
            Button {
                generator.write(source, audio: audio)
            } label: {
                label
            }
            .accessibilityLabel("Write a Walkthrough")
            .accessibilityIdentifier("reader.walkthrough.write")
        }
    }

    private var label: some View {
        Label("Walk Through", systemImage: "rectangle.stack")
            .labelStyle(.iconOnly)
            .foregroundStyle(Color.accentColor)
            .frame(
                minWidth: MobileDesign.Metrics.minimumTouchTarget,
                minHeight: MobileDesign.Metrics.minimumTouchTarget
            )
            .contentShape(Rectangle())
    }
}
