import SwiftUI

/// When a chat on a free model has been waiting long enough to be offered a
/// paid one (product owner, 2026-09-28: "if a user is waiting a long time for a chat
/// to respond when using a free model, can we ask them to switch to a paid
/// model? they need to be able to dismiss those popups though forever").
enum SlowFreeModelWait {
    /// How long a turn on a free model may go without a word of its reply
    /// before the offer appears. A paid chat model's first words usually land
    /// within a few seconds; a free one is served by fewer hosts and
    /// rate-limited by OpenRouter, and can sit silent for a minute.
    static let offerDelay: TimeInterval = 20

    /// Don't Ask Again. Synced (`SyncedPreferenceKeys.synced`), so a learner
    /// who said it once is not asked on their other Mac either.
    static let dismissedKey = "chat.slowFreeModelOffer.dismissed"

    static func shouldOffer(
        isOnFreeModel: Bool,
        isWaitingForText: Bool,
        waited: TimeInterval,
        isDismissed: Bool
    ) -> Bool {
        isOnFreeModel && isWaitingForText && !isDismissed && waited >= offerDelay
    }
}

/// The offer under the "Thinking" status line when a free model is slow to
/// answer: one line, a paid model to ask instead, and Don't Ask Again.
///
/// Picking a model switches the chat to it, as the composer's picker would,
/// and asks the waiting message again on it at once
/// (`ReviewSessionManager.restartTurnOnSelectedModel`); the free model's
/// silence is dropped, not kept. A turn that already ran a tool is not asked
/// twice, so the pick then takes the next message, and the line says so. With
/// Free mode on no paid model can run, so the line leads to where Free mode
/// is turned off instead. The line goes when the answer starts, and never
/// comes back once Don't Ask Again is pressed.
struct SlowFreeModelOffer: View {
    let turnModel: ReviewSessionManager.TurnModel?
    /// The turn has not written a word of its reply yet.
    let isWaitingForText: Bool
    /// Asks the running turn again on the model the chat is now set to.
    /// False when it can no longer be asked again.
    let askAgain: () -> Bool

    @SyncedStorage(SlowFreeModelWait.dismissedKey) private var isDismissed = false
    /// The paid models the chat's picker lists, loaded off-main.
    @State private var paidEntries: [AIModelCatalogEntry] = []
    /// A model picked for the first time is tested before it is selected,
    /// as in the composer's picker (`AIModelQualification`).
    @State private var switching: AIModelCatalogEntry?
    @State private var refusal: String?
    /// The model now set for the chat, when the running turn could not be
    /// asked again and it takes the next message instead.
    @State private var nextMessageModel: String?

    var body: some View {
        if let turnModel, turnModel.isFree, !isDismissed {
            TimelineView(.periodic(from: turnModel.startedAt, by: 1)) { context in
                if let nextMessageModel {
                    confirmation(nextMessageModel)
                } else if switching != nil || (isWaitingForText && refusal != nil) || SlowFreeModelWait.shouldOffer(
                    isOnFreeModel: true,
                    isWaitingForText: isWaitingForText,
                    waited: context.date.timeIntervalSince(turnModel.startedAt),
                    isDismissed: isDismissed
                ) {
                    offer
                }
            }
            .task(id: turnModel.startedAt) {
                await loadPaidEntries()
            }
        }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A side chat is narrow: there the actions go without the reason.
            ViewThatFits(in: .horizontal) {
                actions(withReason: true)
                actions(withReason: false)
            }

            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, ForeverLMLoadingIndicator.inlineWidth + 8)
        .padding(.top, 2)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Offer to ask a paid model")
    }

    private func actions(withReason: Bool) -> some View {
        HStack(spacing: 6) {
            if withReason {
                Text("Free models can be slow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if AIFreeMode.isOn {
                Button {
                    NotificationCenter.default.post(name: .requestOpenStudioSettings, object: SettingsPane.aiUsage)
                } label: {
                    Text("Turn off Free mode…")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3))
                .foregroundStyle(Color.accentColor)
                .help("Free mode keeps every AI request on free models. To ask a paid one, \(AIFreeMode.leaveAdvice).")
                .accessibilityIdentifier("mac.chatSlowFreeModel.freeMode")
            } else {
                paidModelMenu
                    .disabled(switching != nil)
                    .help("Ask this message again on a paid model, and keep the chat on it")
                    .accessibilityIdentifier("mac.chatSlowFreeModel.switch")
            }

            Button {
                isDismissed = true
            } label: {
                Text("Don't ask again")
                    .font(.caption)
            }
            .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("mac.chatSlowFreeModel.dismiss")

            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func confirmation(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(name) answers your next message.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, ForeverLMLoadingIndicator.inlineWidth + 8)
        .padding(.top, 2)
        .transition(.opacity)
        .accessibilityIdentifier("mac.chatSlowFreeModel.confirmation")
    }

    /// Opens above the line, like the composer's model chip: the line sits at
    /// the foot of the transcript, and a menu dropping down from it would run
    /// under the composer.
    @ViewBuilder
    private var paidModelMenu: some View {
        if #available(macOS 14.4, *) {
            UpwardMenuChip {
                paidModelItems
            } label: {
                menuLabel
            }
        } else {
            Menu {
                paidModelItems
            } label: {
                menuLabel
            }
            .pickerPillMenu()
        }
    }

    private var menuLabel: some View {
        HStack(spacing: 3) {
            if let switching {
                Text("Switching to \(AIModelCatalog.pickerName(provider: switching.provider, modelID: switching.modelID))…")
                    .font(.caption.weight(.medium))
            } else {
                Text("Ask a paid model")
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Color.accentColor)
        .fixedSize()
    }

    /// The composer picker's paid models, priced the same way, and its way
    /// to every other model.
    @ViewBuilder
    private var paidModelItems: some View {
        if !paidEntries.isEmpty {
            Section(InlineModelPicker.priceUnitHeader) {
                ForEach(paidEntries) { entry in
                    Button {
                        pick(entry)
                    } label: {
                        // Flat siblings: the first Text is the item's title,
                        // the second its gray subtitle.
                        Text(AIModelCatalog.pickerName(provider: entry.provider, modelID: entry.modelID))
                        if let subtitle = InlineModelPicker.modelRowSubtitle(
                            rates: AIModelListPrice.rates(for: entry),
                            promotion: nil,
                            currentSpeedQuote: nil
                        ) {
                            Text(subtitle)
                        }
                    }
                }
            }
            Divider()
        }
        Button {
            ModelPickerSheetRequest.open(.chat)
        } label: {
            Label("Choose Models…", systemImage: "square.grid.2x2")
        }
    }

    private func loadPaidEntries() async {
        let entries = await Task.detached(priority: .userInitiated) {
            InlineModelPicker.loadMenuEntries(task: .chat).filter {
                !AIModelCatalog.isFree(provider: $0.provider, modelID: $0.modelID)
            }
        }.value
        guard !Task.isCancelled else { return }
        paidEntries = entries
    }

    private func pick(_ entry: AIModelCatalogEntry) {
        guard switching == nil else { return }
        refusal = nil
        if AIModelQualification.isPassed(provider: entry.provider, model: entry.modelID, role: .chat) {
            switchChat(to: entry)
            return
        }
        switching = entry
        Task {
            let verdict = await Task.detached(priority: .userInitiated) {
                await AIModelQualification.testBeforeSelecting(provider: entry.provider, model: entry.modelID, role: .chat)
            }.value
            switching = nil
            if verdict == .go {
                switchChat(to: entry)
            } else {
                refusal = AIModelQualification.refusalText(name: entry.displayName, role: .chat, verdict: verdict)
            }
        }
    }

    /// The composer picker's apply for the chat, then the waiting message
    /// asked again.
    private func switchChat(to entry: AIModelCatalogEntry) {
        KeychainService.setTaskRoute(provider: entry.provider, model: entry.modelID, for: .chat)
        if !askAgain() {
            withAnimation(.easeInOut(duration: 0.2)) {
                nextMessageModel = AIModelCatalog.pickerName(provider: entry.provider, modelID: entry.modelID)
            }
        }
    }
}
