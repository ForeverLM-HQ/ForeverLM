import AppKit
import ScreenCaptureKit
import SwiftUI

/// The live meeting pane (`StudioCenterTab.liveMeeting`): a call's transcript
/// as it is said, and the slides kept from the window the learner picked.
///
/// Hierarchy: the chrome line holds the meeting's title, the clock while it
/// records, and the one primary action (Start, then Stop); Watch Slides and
/// Ask sit on the pane's own bar under it, where they act. The transcript fills
/// the pane, newest at the bottom, with what each side is still saying in grey
/// below the last line; the slides run in a strip across the bottom. Mac only:
/// the recording is this Mac's sound and screen. The web and the iPhone show
/// the filed session like any other meeting once it is saved.
struct LiveMeetingPane: View {
    @Environment(StudioViewModel.self) private var vm

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                LiveMeetingPaneContent(controller: .shared)
            } else {
                SpaceEmptyLine(systemImage: "waveform", text: LiveMeetingError.needsNewerMacOS.errorDescription ?? "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .studioCenterTabCloseChrome(for: .liveMeeting)
    }
}

@available(macOS 26.0, *)
private struct LiveMeetingPaneContent: View {
    @Environment(StudioViewModel.self) private var vm
    @Bindable var controller: LiveMeetingController
    @State private var draftTitle = ""
    @State private var slidePicker = LiveMeetingSlidePicker()
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch controller.phase {
            case .idle, .starting:
                startView
            case .running, .stopping, .finished:
                meetingView
            }
        }
        .studioChromeLineHeader(opaque: true) {
            header
                .padding(.horizontal, 16)
                .background(WindowDragBlocker())
        }
        .task {
            guard draftTitle.isEmpty, controller.phase == .idle,
                  let suggested = await LiveMeetingController.suggestedTitle() else { return }
            if draftTitle.isEmpty { draftTitle = suggested }
        }
        .onAppear {
            slidePicker.onPick = { filter in
                Task { await controller.watchSlides(filter: filter) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if controller.phase == .running || controller.phase == .stopping {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(headerTitle)
                .zoomedSystemFont(size: 13, weight: .semibold)
                .lineLimit(1)
                .textSelection(.disabled)
            if let startedAt = controller.startedAt, controller.phase == .running {
                Text(startedAt, style: .timer)
                    .zoomedSystemFont(size: 12)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
            Spacer(minLength: 8)
            primaryAction
        }
    }

    private var headerTitle: String {
        controller.title.isEmpty ? "Live Meeting" : controller.title
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch controller.phase {
        case .idle:
            SpaceDarkPillButton(title: "Start", systemImage: "record.circle", image: nil) { start() }
                .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .starting:
            ProgressView().controlSize(.small)
        case .running:
            SpaceDarkPillButton(title: "Stop", systemImage: "stop.fill", image: nil) {
                Task { await controller.stop() }
            }
        case .stopping:
            ProgressView().controlSize(.small)
        case .finished:
            Button("Open Meeting") { openSession() }
                .buttonStyle(.hoverWash)
        }
    }

    // MARK: Before it starts

    private var startView: some View {
        VStack(spacing: 14) {
            Spacer()
            TextField("Meeting name", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
                .focused($titleFocused)
                .onSubmit { start() }
                .disabled(controller.phase == .starting)
            if let problem = controller.problem {
                Text(problem)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .textSelection(.disabled)
            } else {
                // A privacy consequence, so it is said.
                Text("Transcribed on this Mac. Let the others know.")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { titleFocused = true }
    }

    private func start() {
        let title = draftTitle
        Task { await controller.start(title: title, vm: vm) }
    }

    // MARK: While it runs, and after

    private var meetingView: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            transcript
            if !controller.slides.isEmpty {
                Divider()
                slideStrip
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            if controller.phase == .running {
                Button {
                    if controller.isWatchingSlides {
                        Task { await controller.stopWatchingSlides() }
                    } else {
                        slidePicker.present()
                    }
                } label: {
                    Label(controller.isWatchingSlides ? "Stop Watching Slides" : "Watch Slides…",
                          systemImage: controller.isWatchingSlides ? "rectangle.slash" : "rectangle.on.rectangle")
                }
                .buttonStyle(.hoverWash)
            }
            Button {
                askInChat()
            } label: {
                Label("Ask", systemImage: "bubble.left")
            }
            .buttonStyle(.hoverWash)
            .disabled(controller.sourceID == nil)
            Spacer(minLength: 8)
            if let problem = controller.problem {
                Text(problem)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.disabled)
                    .help(problem)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if controller.lines.isEmpty && controller.hearing.isEmpty {
                        Text(controller.phase == .finished ? "Nothing was said." : "Listening…")
                            .zoomedSystemFont(size: 13)
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                    }
                    ForEach(controller.lines) { line in
                        LiveMeetingLineRow(line: line, startedAt: controller.startedAt)
                    }
                    ForEach(LiveMeetingVoice.allCases, id: \.self) { voice in
                        if let words = controller.hearing[voice] {
                            Text("\(voice.speakerName): \(words)")
                                .zoomedSystemFont(size: 13)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(16)
            }
            .onChange(of: controller.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
    }

    private static let bottomID = "live-meeting-bottom"

    private var slideStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(controller.slides) { slide in
                    LiveMeetingSlideThumb(slide: slide)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 96)
    }

    private func askInChat() {
        guard let sourceID = controller.sourceID else { return }
        vm.addSourceToContext(sourceID)
        vm.revealChat(beside: .liveMeeting)
    }

    private func openSession() {
        guard let sourceID = controller.sourceID else { return }
        Task { await vm.selectArticle(sourceID, in: vm.activeWindowState, revealingReader: true) }
    }
}

@available(macOS 26.0, *)
private struct LiveMeetingLineRow: View {
    let line: LiveMeetingLine
    let startedAt: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let startedAt {
                Text(LiveMeetingTranscriptRules.wallClock(startedAt.addingTimeInterval(line.start)))
                    .zoomedSystemFont(size: 11)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
            }
            (Text("\(line.voice.speakerName)  ").bold() + Text(line.text))
                .zoomedSystemFont(size: 13)
                .foregroundStyle(line.voice == .me ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LiveMeetingSlideThumb: View {
    let slide: LiveMeetingSlide
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.secondary.opacity(0.1)
                    .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .frame(height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("Slide \(slide.number)")
        .task(id: slide.imageURL) {
            let url = slide.imageURL
            image = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        }
    }
}

/// The system's window picker, which hands back the window (or display) the
/// learner chose for the slides. ScreenCaptureKit owns the sheet and its
/// permission; this only listens.
@MainActor
final class LiveMeetingSlidePicker: NSObject, SCContentSharingPickerObserver {
    var onPick: (@MainActor (SCContentFilter) -> Void)?

    func present() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            self.finish(picker)
            self.onPick?(filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(picker) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        LiveMeetingLog.capture.error("window picker failed: \(error.localizedDescription, privacy: .public)")
    }

    private func finish(_ picker: SCContentSharingPicker) {
        picker.remove(self)
        picker.isActive = false
    }
}
