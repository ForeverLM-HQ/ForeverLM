import SwiftUI

// The three surfaces of Explain on the phone: the badge beside a paper or
// article in every list, the row's menu item, and the reader's toolbar
// control. All three read one status so they can never disagree about the
// same source.

/// Where a source's explainer stands, from what the phone can see: whether
/// there is one, whether it is being written, and what its audio is doing.
struct MobileExplainerStatus: Equatable {
    enum Phase: Equatable {
        /// No explainer yet; Explain writes one.
        case none
        case writing
        /// The script exists and has no audio yet; Listen generates it.
        case scriptOnly
        case generatingAudio
        /// Audio is ready; Listen plays it.
        case ready
        case playing
        case paused
    }

    let explainerID: String?
    let phase: Phase

    @MainActor
    static func current(
        for source: MobileCloudSource,
        audio: MobileAudioReviewViewModel,
        generator: MobileExplainerGenerator
    ) -> MobileExplainerStatus {
        let explainerID = audio.explainerID(explaining: source.id)
        if generator.isWriting(source.id) {
            return MobileExplainerStatus(explainerID: explainerID, phase: .writing)
        }
        guard let explainerID else {
            return MobileExplainerStatus(explainerID: nil, phase: .none)
        }
        if audio.isPreparingAudio(sourceID: explainerID) {
            return MobileExplainerStatus(explainerID: explainerID, phase: .generatingAudio)
        }
        if audio.currentItem?.id == explainerID {
            return MobileExplainerStatus(explainerID: explainerID, phase: audio.isPlaying ? .playing : .paused)
        }
        if audio.hasSyncedTextToSpeechAudio(sourceID: explainerID) {
            return MobileExplainerStatus(explainerID: explainerID, phase: .ready)
        }
        return MobileExplainerStatus(explainerID: explainerID, phase: .scriptOnly)
    }

    /// Whether Explain shows for a source at all: a paper or article that is
    /// not an explainer itself, with its text in (a paper still waiting on its
    /// PDF has nothing to explain yet).
    static func isExplainable(_ source: MobileCloudSource) -> Bool {
        ExplainerScript.isExplainable(sourceType: source.sourceType, url: source.url)
            && source.state == "ready"
            && !source.isPaywalled
    }

    var title: String {
        switch phase {
        case .none: return "Explain"
        case .writing: return "Writing Explainer…"
        case .scriptOnly: return "Generate Explainer Audio"
        case .generatingAudio: return "Generating Explainer Audio…"
        case .ready: return "Listen to Explainer"
        case .playing: return "Pause Explainer"
        case .paused: return "Resume Explainer"
        }
    }

    var icon: String {
        switch phase {
        case .none: return "lightbulb"
        case .writing: return "hourglass"
        case .scriptOnly: return "lightbulb.fill"
        case .generatingAudio: return "waveform"
        case .ready: return "lightbulb.circle.fill"
        case .playing: return "pause.fill"
        case .paused: return "play.fill"
        }
    }

    var isBusy: Bool {
        phase == .writing || phase == .generatingAudio
    }

    /// What a tap does: write the explainer, or hand the explainer to Listen —
    /// which generates its audio when there is none and plays it otherwise.
    /// nil while work is in flight.
    @MainActor
    func action(
        for source: MobileCloudSource,
        audio: MobileAudioReviewViewModel,
        generator: MobileExplainerGenerator
    ) -> (@MainActor () async -> Void)? {
        switch phase {
        case .none:
            return { await generator.explain(source, audio: audio) }
        case .writing, .generatingAudio:
            return nil
        case .scriptOnly, .ready, .playing, .paused:
            guard let explainerID else { return nil }
            return { await audio.toggleTextToSpeech(sourceID: explainerID) }
        }
    }
}

/// The explainer a reader pushes when its Explain menu says Open Explainer.
/// Hashable by the source's id, which is what `navigationDestination(item:)`
/// needs and all a push has to tell apart.
struct MobileExplainerDestination: Hashable {
    let source: MobileCloudSource

    static func == (lhs: MobileExplainerDestination, rhs: MobileExplainerDestination) -> Bool {
        lhs.source.id == rhs.source.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source.id)
    }
}

/// The row menu's item. Deliberately always one `Button` (see
/// `MobileOfflineSaveButton`): while the explainer is being written it is the
/// cancel, otherwise it is whatever a tap on the badge would do.
struct MobileExplainerMenuButton: View {
    let source: MobileCloudSource

    @EnvironmentObject private var audio: MobileAudioReviewViewModel
    @ObservedObject private var generator = MobileExplainerGenerator.shared

    var body: some View {
        let status = MobileExplainerStatus.current(for: source, audio: audio, generator: generator)
        if status.phase == .writing {
            Button("Cancel Writing Explainer", systemImage: "xmark") {
                generator.cancel(source.id)
            }
            .accessibilityIdentifier("source.explainer.cancel")
        } else {
            let action = status.action(for: source, audio: audio, generator: generator)
            Button(status.title, systemImage: status.icon) {
                guard let action else { return }
                Task { await action() }
            }
            .disabled(action == nil)
            .accessibilityIdentifier("source.explainer")
        }
    }
}

/// The reader's Explain control, beside Listen. A tap does what comes next
/// for this source's explainer; a hold offers to open the explainer in its own
/// reader or to rewrite it. While the explainer is being written a tap opens
/// the menu, whose one item is Cancel.
struct MobileExplainerToolbarControl: View {
    let source: MobileCloudSource
    /// Opens the explainer's reader; the reader owns the navigation.
    let open: (MobileCloudSource) -> Void

    @EnvironmentObject private var audio: MobileAudioReviewViewModel
    @ObservedObject private var generator = MobileExplainerGenerator.shared

    var body: some View {
        let status = MobileExplainerStatus.current(for: source, audio: audio, generator: generator)
        if status.phase == .writing {
            Menu {
                Button("Cancel Writing Explainer", systemImage: "xmark", role: .destructive) {
                    generator.cancel(source.id)
                }
                .accessibilityIdentifier("reader.explainer.cancel")
            } label: {
                label(for: status)
            }
            .accessibilityLabel(status.title)
            .accessibilityIdentifier("reader.explainer.writing")
        } else {
            let action = status.action(for: source, audio: audio, generator: generator)
            Menu {
                if let explainer = explainerSource(status) {
                    Button("Open Explainer", systemImage: "doc.text") {
                        open(explainer)
                    }
                    .accessibilityIdentifier("reader.explainer.open")
                    Button("Rewrite Explainer", systemImage: "arrow.clockwise") {
                        Task { await generator.explain(source, audio: audio) }
                    }
                    .disabled(status.isBusy)
                    .accessibilityIdentifier("reader.explainer.rewrite")
                } else {
                    Button("Explain", systemImage: "lightbulb") {
                        Task { await generator.explain(source, audio: audio) }
                    }
                }
            } label: {
                label(for: status)
            } primaryAction: {
                guard let action else { return }
                Task { await action() }
            }
            .disabled(action == nil)
            .accessibilityLabel(status.title)
            .accessibilityHint("Touch and hold to open or rewrite the explainer")
            .accessibilityIdentifier("reader.explainer")
        }
    }

    private func label(for status: MobileExplainerStatus) -> some View {
        Label(status.title, systemImage: status.icon)
            .labelStyle(.iconOnly)
            .foregroundStyle(status.isBusy ? Color.secondary : Color.accentColor)
            .frame(
                minWidth: MobileDesign.Metrics.minimumTouchTarget,
                minHeight: MobileDesign.Metrics.minimumTouchTarget
            )
            .contentShape(Rectangle())
    }

    private func explainerSource(_ status: MobileExplainerStatus) -> MobileCloudSource? {
        guard let explainerID = status.explainerID else { return nil }
        return audio.allSources.first { $0.id == explainerID }
    }
}
