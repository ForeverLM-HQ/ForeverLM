import AppKit
import SwiftUI

/// The quick assistant's content: the conversation, once there is one, over
/// the bar. Laid out from the bottom so the panel grows upward as the answer
/// arrives (`QuickAssistantController`).
struct QuickAssistantView: View {
    @Bindable var model: QuickAssistantModel
    @ObservedObject var dictation: ReviewDictationService
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let manager = model.manager {
                QuickAssistantConversation(model: model, manager: manager)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            QuickAssistantBar(model: model, dictation: dictation)
        }
        // Room for the shadows, which a borderless panel would clip.
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChange(height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.18), value: model.manager == nil)
        .environment(\.openURL, OpenURLAction { url in
            QuickAssistantController.shared.open(url)
            return .handled
        })
    }
}

// MARK: - The bar

private struct QuickAssistantBar: View {
    @Bindable var model: QuickAssistantModel
    @ObservedObject var dictation: ReviewDictationService
    @FocusState private var fieldFocused: Bool

    private var shortcutLabel: String? {
        if case .listening(let shortcut) = QuickAssistantHotKey.shared.status { return shortcut.displayString }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            ForeverLMMark(width: 30, motion: dictation.isRecording ? .drifting : .still)
                .accessibilityHidden(true)

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .onAppear { fieldFocused = model.input == .keyboard }
        .onChange(of: model.input) { _, input in
            fieldFocused = input == .keyboard
            guard input == .keyboard else { return }
            // Focusing a field selects its text; a letter typed into the bar
            // must carry on after itself, not be replaced by the next one.
            DispatchQueue.main.async {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if dictation.isRecording {
            ReviewDictationWaveform(
                meter: dictation.meter,
                onStop: { Task { await model.finishListening(sending: true) } },
                onKeepInDraft: { Task { await model.finishListening(sending: false) } }
            )
        } else if dictation.isTranscribing {
            HStack(spacing: 8) {
                ForeverLMLoadingIndicator(width: ForeverLMLoadingIndicator.inlineWidth)
                Text("Transcribing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
        } else if model.input == .keyboard {
            TextField(
                model.manager == nil ? "Ask ForeverLM to do something" : "Ask a follow-up",
                text: $model.draft
            )
            .textFieldStyle(.plain)
            .font(.body)
            .focused($fieldFocused)
            .onSubmit { model.submitDraft() }
            .accessibilityIdentifier("quickAssistant.field")
        } else {
            Text("Listening")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if dictation.isRecording {
            if let shortcutLabel {
                HStack(spacing: 6) {
                    Text(shortcutLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                    Text("to send")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.disabled)
                .accessibilityElement(children: .combine)
            }
        } else if model.input == .keyboard, !dictation.isTranscribing {
            Button {
                Task { await model.startListening() }
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.10))
            .help("Speak instead")
            .accessibilityLabel("Speak instead")
        }
    }
}

// MARK: - The conversation

private struct QuickAssistantConversation: View {
    let model: QuickAssistantModel
    let manager: ReviewSessionManager
    @State private var transcriptHeight: CGFloat = 0

    private static let maximumTranscriptHeight: CGFloat = 380

    /// The exchange as the learner sees it: their words and the answers, the
    /// app's activity rows left to the status line.
    private struct Turn: Identifiable {
        let id: UUID
        let isLearner: Bool
        let text: String
    }

    private var allTurns: [Turn] {
        manager.chatMessages.compactMap { message in
            switch message.role {
            case .tool:
                return nil
            case .user, .assistant:
                guard let text = ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content) else {
                    return nil
                }
                return Turn(id: message.id, isLearner: message.role == .user, text: text)
            }
        }
    }

    /// The first request heads the card, beside its buttons; everything
    /// after it is the transcript.
    private var request: Turn? {
        allTurns.first.flatMap { $0.isLearner ? $0 : nil }
    }

    private var turns: [Turn] {
        request == nil ? allTurns : Array(allTurns.dropFirst())
    }

    /// What the chat is doing right now, in the words its transcript uses.
    private var status: String? {
        guard manager.hasGenerationWorkInFlight else { return nil }
        if let running = manager.chatMessages.last(where: { $0.role == .tool && $0.toolActivity?.state == .running })?.toolActivity {
            if let detail = running.detail, !detail.isEmpty { return "\(running.title) · \(detail)" }
            return running.title
        }
        if manager.isPreparingGeneration { return manager.sendPreparationDetail ?? "Getting ready" }
        if let streamingID = manager.streamingMessageID,
           let streaming = manager.chatMessages.first(where: { $0.id == streamingID }),
           !streaming.content.isEmpty {
            return nil
        }
        return "Thinking"
    }

    /// Changes whenever the transcript grows, so it can keep its end in view.
    private var revision: Int {
        manager.chatMessages.count &* 31 &+ (manager.chatMessages.last?.content.count ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(turns) { turn in
                            if turn.isLearner {
                                Text(turn.text)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            } else {
                                QuickAssistantAnswerText(markdown: turn.text)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        transcriptHeight = height
                    }
                }
                .frame(height: min(transcriptHeight, Self.maximumTranscriptHeight))
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: revision) { _, _ in
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }

            if let status {
                HStack(spacing: 8) {
                    ForeverLMLoadingIndicator(width: ForeverLMLoadingIndicator.inlineWidth, style: .flowingGoo)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.disabled)
                    Spacer(minLength: 0)
                    if manager.canStopGeneration {
                        Button("Stop") { model.stop() }
                            .buttonStyle(.hoverWash(cornerRadius: 6))
                            .font(.caption.weight(.medium))
                    }
                }
            } else if let error = manager.errorMessage, !error.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    if manager.canRetryLastGeneration {
                        Button("Retry") { model.retry() }
                            .buttonStyle(.hoverWash(cornerRadius: 6))
                            .font(.caption.weight(.medium))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let request {
                Text(request.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(request.text)
            }
            Spacer(minLength: 8)
            if model.sessionID != nil {
                Button {
                    model.openInForeverLM()
                } label: {
                    Label("Open in ForeverLM", systemImage: "arrow.up.forward.app")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6))
                .help("Continue this chat in ForeverLM")
                .accessibilityIdentifier("quickAssistant.open")
            }
            Button {
                model.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.10))
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("quickAssistant.close")
        }
    }
}

/// An answer drawn as text: the chat's Markdown read inline (bold, italics,
/// code, links), a heading line set in bold and a list item given a bullet.
/// The panel is a glance, not the chat page; a table or a picture reads in
/// full once the chat is opened in ForeverLM.
struct QuickAssistantAnswerText: View {
    let markdown: String

    struct Paragraph: Equatable {
        let text: String
        let isHeading: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.paragraphs(markdown).enumerated()), id: \.offset) { _, paragraph in
                Text(Self.attributed(paragraph.text))
                    .font(paragraph.isHeading ? .body.weight(.semibold) : .body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }

    static func paragraphs(_ markdown: String) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var current: [String] = []

        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { paragraphs.append(Paragraph(text: text, isHeading: false)) }
            current = []
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") || line == "---" {
                flush()
                continue
            }
            if line.hasPrefix("#") {
                flush()
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { paragraphs.append(Paragraph(text: title, isHeading: true)) }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let indent = rawLine.prefix(while: { $0 == " " }).count >= 2 ? "    " : ""
                current.append(indent + "• " + line.dropFirst(2))
                continue
            }
            current.append(line)
        }
        flush()
        return paragraphs
    }

    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
