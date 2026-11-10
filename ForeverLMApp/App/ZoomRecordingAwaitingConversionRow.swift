// The sidebar row for a Zoom recording awaiting conversion.
import SwiftUI
import AppKit

/// One Zoom recording on this Mac that only Zoom can convert, with the two
/// things the learner can say about it. **Convert in Zoom** is their own
/// double-click made once — Zoom converts once its unknown-source dialog is
/// answered, by ForeverLM when it may use Accessibility (macOS asks at the
/// first click when it may not), and the watcher files and transcribes the
/// result; **Ignore** leaves the
/// recording in the folder and takes it off the tab, for a meeting that did
/// not happen. Shared by the Meetings tab, which shows the ones not ignored,
/// and Settings › Sources, which shows all of them so an Ignore can be undone.
struct ZoomRecordingAwaitingConversionRow: View {
    @Environment(StudioViewModel.self) private var vm
    let recording: StudioViewModel.ZoomLocalRecordingAwaitingConversion

    private var isIgnored: Bool {
        vm.zoomLocalRecordingIgnoredFolders.contains(recording.folder.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isIgnored ? "waveform.slash" : "waveform.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(isIgnored ? Color.secondary : .orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Spacer()
                Button(isIgnored ? "Stop Ignoring" : "Ignore") {
                    vm.setZoomLocalRecordingIgnored(recording, !isIgnored)
                }
                .accessibilityLabel(isIgnored ? "Stop ignoring this recording" : "Ignore this recording")
                Button("Convert in Zoom") { convert() }
                    .accessibilityLabel("Convert this recording in Zoom")
            }
            .buttonStyle(.hoverWash)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("zoom-recording-awaiting-conversion")
    }

    private var message: String {
        let when = recording.folder.startedAt.formatted(date: .abbreviated, time: .shortened)
        return isIgnored
            ? "Ignored: the Zoom recording of \(recording.title), \(when)."
            : "Zoom hasn't converted its recording of \(recording.title), \(when). Convert it to file and transcribe the meeting, or ignore it."
    }

    private func convert() {
        if vm.convertZoomLocalRecordingInZoom(recording) {
            vm.showToast(AXIsProcessTrusted()
                ? "Zoom is converting the recording. ForeverLM files and transcribes it when Zoom is done."
                : "Allow ForeverLM under Accessibility and it answers Zoom's question about unknown sources for you.")
        } else {
            vm.showToast("Nothing on this Mac opens Zoom recordings. Convert it from Zoom's Recorded tab instead.")
        }
    }
}
