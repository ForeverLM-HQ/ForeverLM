import Foundation

/// The assistant turn a walkthrough step becomes when the chat plays it
/// (walkthrough-design.md, "the panel becomes a chat").
///
/// The turn is Markdown the chat renderer already draws: the step's title as
/// a heading, its paragraphs, the authors' own sentence about the panel as a
/// quotation, the panel the step is about as a source image
/// cropped to the panel's rectangle (the image grammar `SourceImageReference`
/// carries the crop and every client renders it from its own PDF) when no Reader beside
/// the chat is already showing the figure outlined, and, last, the step's
/// question. The first line is the `WalkthroughStepTurn` marker, which
/// the transcript reads to draw the anchor chip, panel letters and animation
/// beside the row and which is stripped before the model reads the turn.
///
/// Nothing here calls a model: composing a step costs a string. Both apps
/// compose with it: the phone's walkthrough chat writes the same turns, so a
/// chat begun on the phone plays on as a walk when the Mac reopens it.
enum WalkthroughStepComposer {

    /// What a figure step's turn repeats under its own words: the sentence
    /// of the text that cites the panel (`PaperWalkthroughStep.sourceMention`),
    /// as a quotation the renderer sets off with a rule (product owner, 2026-09-21:
    /// "repeat the sentence in the paper where they explain figure 1a").
    static let mentionLead = "In the authors’ words:"

    static func quotedMention(_ mention: String) -> String {
        "> \(mentionLead) “\(mention)”"
    }

    /// The turn's text for `step`, the `index`th of `count` steps of the
    /// record `sourceID` carries. `lens` is the panel to show enlarged, when
    /// the step is about one panel whose rectangle is known.
    static func markdown(
        step: PaperWalkthroughStep,
        marker: WalkthroughStepTurn.Marker,
        lens: SourceImageReference?
    ) -> String {
        var blocks: [String] = [WalkthroughStepTurn.line(marker)]
        let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            blocks.append("### \(title)")
        }
        for paragraph in paragraphs(of: step.body) {
            blocks.append(paragraph)
        }
        if let mention = step.sourceMention?.trimmingCharacters(in: .whitespacesAndNewlines), !mention.isEmpty {
            blocks.append(quotedMention(mention))
        }
        if let lens {
            let label = (step.anchor?.figureLabel ?? "Figure").trimmingCharacters(in: .whitespacesAndNewlines)
            let panel = step.anchor?.panelLabel.map(PaperWalkthroughValidation.panelDisplayName)
            blocks.append(lens.markdown(alt: PaperWalkthroughValidation.figurePanelLabel(label, panel: panel)))
        }
        if !step.more.isEmpty {
            // The chips' words ride the turn so the tutor knows what the
            // card offered; the card shows them only when pressed.
            for more in step.more {
                blocks.append("*\(more.label)* — \(more.text)" + (more.fromPaper ? "" : " (general knowledge)"))
            }
        }
        // The works the card shows under the point, so a question about
        // "the paper it cites" reaches a tutor that knows which one.
        for citation in step.cites {
            blocks.append("*Cites:* \(citation.referenceLine)")
        }
        if let quiz = step.quiz {
            let question = quiz.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty {
                blocks.append("**\(quiz.kind.label):** \(question)")
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    #if os(macOS)
    /// The panel enlarged, as the image line's reference: the figure's page
    /// with the panel's rectangle as the crop. Nil for a whole-figure step, a
    /// passage or a page — the outline on the page is the whole of those —
    /// and nil while a Reader beside the chat has the source on screen: the
    /// panel is then outlined on the page next to the row, and a second copy
    /// of it in the chat is the same picture twice (product owner, 2026-09-20). A
    /// chat with no Reader beside it — the source behind another tab, or the
    /// chat in a window of its own — keeps the lens, since the outline is
    /// out of sight.
    static func lensReference(
        sourceID: String,
        resolved: WalkthroughResolvedAnchor?,
        readerBesideChatShowsSource: Bool = false
    ) -> SourceImageReference? {
        guard !readerBesideChatShowsSource else { return nil }
        guard let resolved, resolved.panel != nil,
              case .figure(let pageIndex, let rect, _, _) = resolved.target,
              let rect, rect.isValid else { return nil }
        return SourceImageReference(sourceID: sourceID, location: .page(pageIndex + 1), crop: rect)
    }
    #endif

    /// What rides beside the learner's answer to a question step, so the
    /// tutor's next turn is the grade: the question, the writer's reference
    /// answer and key points, and how to grade (the rules the retired
    /// Walkthrough Grading prompt held, folded into the reply). Kept out of
    /// the visible message: the learner typed their answer, not the rubric.
    ///
    /// The reply is feedback that teaches, not a verdict
    /// (docs/walkthrough-design.md, "a walk explains the way a
    /// textbook does"): feedback that only says right or wrong does almost
    /// nothing, while the answer with why, tied back to what showed it, is
    /// what a question adds. An answer on the right track but short of it
    /// gets one follow-up first, as a course quiz's does (product owner,
    /// 2026-09-27: "maybe it should ask for a small follow up to clarify");
    /// a prediction and a pick of a panel are answered at once.
    static func gradingContext(step: PaperWalkthroughStep, quiz: PaperWalkthroughQuiz, marker: WalkthroughStepTurn.Marker) -> String {
        var lines: [String] = []
        let how: String
        let followUp: String
        switch quiz.kind {
        case .recall:
            how = "judge the answer on its meaning, not its wording — a key point made in other words counts, one merely hinted at does not."
            followUp = Self.followUpRule
        case .thinkFirst:
            how = "this was asked before the learner saw the evidence, so judge the reasoning, not the recall — a sound expectation that the data then contradict is still a good answer; say what the authors found."
            followUp = Self.followUpRule
        case .predict:
            how = "this is a prediction made with the panel's data hidden; judge whether the guess matches what the data show. A wrong guess is not a failure — say what the data show and what that means. The data are now shown."
            followUp = ""
        case .find:
            how = "the learner was asked which panel shows something and answered in words; say whether they named the right panel (\(quiz.targetPanel.map(PaperWalkthroughValidation.panelDisplayName) ?? "?")) and what it shows."
            followUp = ""
        }
        // A recall card's label is "Question" itself, so only the other kinds name theirs.
        let kind = quiz.kind == .recall ? "" : "\(quiz.kind.label.lowercased()) "
        lines.append("[ForeverLM] The learner is answering the \(kind)question of walkthrough step \(marker.index + 1) of \(marker.count) (\(step.title)). Reply as the tutor grading it: \(how) \(followUp)Say in a sentence what the answer got right and in a sentence what it left out or got wrong, then give the reference answer and, in a sentence or two of plain words, why it is right, pointing back to the card or the panel that showed it. Do not add facts the reference and the walk's cards do not contain. Be brief and concrete, then offer to go on with the walk.")
        lines.append("")
        lines.append("Question: \(quiz.question)")
        lines.append("Reference answer: \(quiz.answer)")
        if !quiz.keyPoints.isEmpty {
            lines.append("Key points a complete answer mentions:")
            for point in quiz.keyPoints { lines.append("- \(point)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The follow-up a recall or think-first answer on the right track gets
    /// before its grade: one question, no verdict and no hint of the answer.
    static let followUpRule = "When the answer is on the right track but short of the key points, do not grade it yet: ask one short follow-up that points at what is missing without giving it away, and grade their reply to it together with this answer. Otherwise grade it now. "

    /// What a question card graded by the learner leaves in the chat: the
    /// grade, the question and the reference answer, so the transcript — and
    /// the tutor reading it later — has the whole of it.
    static func recallRecord(quiz: PaperWalkthroughQuiz, remembered: Bool) -> String {
        var lines = [remembered ? "**Remembered.**" : "**Missed — worth coming back to.**"]
        lines.append("")
        lines.append("Question: \(quiz.question)")
        lines.append("")
        lines.append("Answer: \(quiz.answer)")
        return lines.joined(separator: "\n")
    }

    /// What a Find it answered on the figure leaves in the chat: the panel
    /// picked, whether it was the one, and what the right panel shows.
    static func findRecord(quiz: PaperWalkthroughQuiz, picked: String, correct: Bool) -> String {
        let target = PaperWalkthroughValidation.panelDisplayName(quiz.targetPanel ?? picked)
        let pickedShown = PaperWalkthroughValidation.panelDisplayName(picked)
        var lines = [correct ? "**Panel \(target) — that's the one.**" : "**Not panel \(pickedShown) — it's panel \(target).**"]
        lines.append("")
        lines.append("Question: \(quiz.question)")
        lines.append("")
        lines.append("Answer: \(quiz.answer)")
        return lines.joined(separator: "\n")
    }

    static func paragraphs(of body: String) -> [String] {
        body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

#if os(macOS)
/// What the transcript draws while a walk plays (product owner, 2026-09-22: the
/// walk as "cards that you go through", each one something to chat with):
/// the card the learner is on is drawn above the chat by the deck, so the
/// transcript under it holds that card's own conversation — the messages that
/// came after one of the card's turns and before the next card's — and
/// nothing said before the walk began, which belongs to no card. Step turns themselves are never drawn:
/// the card is their picture. The chat itself is untouched — every turn is
/// still in `chatMessages`, persisted and read by the tutor — only what is on
/// screen changes.
enum WalkthroughTranscriptFold {

    static func cardThread(
        _ messages: [ReviewSessionManager.Message],
        playback: ReviewSessionManager.WalkthroughPlayback?
    ) -> [ReviewSessionManager.Message] {
        guard let playback else { return resting(messages) }
        let walkID = playback.sourceID
        guard messages.contains(where: { $0.walkthroughStep?.sourceID == walkID }) else { return resting(messages) }
        let current = playback.currentStep?.id
        var owner: String?
        var inWalk = false
        var visible: [ReviewSessionManager.Message] = []
        for message in messages {
            if let marker = message.walkthroughStep {
                if marker.sourceID == walkID {
                    owner = marker.stepID
                    inWalk = true
                    continue
                }
                owner = nil
            }
            if inWalk, owner == current {
                visible.append(message)
            }
        }
        return visible
    }

    /// The chat with no walk playing: each walk's step turns fold to the one
    /// played last, which the transcript draws as a row that resumes the walk
    /// there. A step turn is a card's words, and drawn as a reply it made the
    /// walk read as a chat (product owner, 2026-09-23: "why is a walkthrough with
    /// cards still kind of a chat?"). What was said about the cards stays.
    static func resting(_ messages: [ReviewSessionManager.Message]) -> [ReviewSessionManager.Message] {
        var lastTurn: [String: UUID] = [:]
        for message in messages {
            if let marker = message.walkthroughStep { lastTurn[marker.sourceID] = message.id }
        }
        guard !lastTurn.isEmpty else { return messages }
        return messages.filter { message in
            guard let marker = message.walkthroughStep else { return true }
            return lastTurn[marker.sourceID] == message.id
        }
    }
}
#endif
