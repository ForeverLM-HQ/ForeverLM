import AppKit
import SwiftUI

/// Settings › Chat › Quick assistant: the shortcut that brings up the
/// quick assistant over any app. This Mac's own; `set_app_setting`'s
/// `quick_assistant.shortcut` writes the same value.
struct QuickAssistantSettingsSection: View {
    @AppStorage(QuickAssistantShortcut.storageKey) private var storedShortcut: String?
    @State private var isRecording = false
    @State private var keyMonitor: Any?
    @State private var refusal: String?

    private var hotKey: QuickAssistantHotKey { .shared }

    private var shortcut: QuickAssistantShortcut? {
        guard let storedShortcut else { return .default }
        return try? QuickAssistantShortcut.parse(storedShortcut)
    }

    private var refusedByMacOS: Bool {
        if case .unavailable = hotKey.status { return true }
        return false
    }

    var body: some View {
        SettingsSection(title: "Quick assistant") {
            SettingsCard {
                HStack(spacing: 12) {
                    Text("Shortcut")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                    Button(action: toggleRecording) {
                        Text(isRecording ? "Type a shortcut" : (shortcut?.displayString ?? "Off"))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(isRecording ? .secondary : .primary)
                            .frame(minWidth: 120)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.primary.opacity(isRecording ? 0.10 : 0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(isRecording ? 0.8 : 0), lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0, opacity: 0.10))
                    .help(isRecording ? "Press the keys, Delete to turn it off, Esc to cancel" : "Change the shortcut")
                    .accessibilityIdentifier("settings.general.quickAssistantShortcut")

                    if shortcut != nil, !isRecording {
                        Button {
                            hotKey.choose(nil)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.10))
                        .help("Turn the shortcut off")
                        .accessibilityLabel("Turn the shortcut off")
                    }
                }
                if let refusal {
                    Text(refusal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else if refusedByMacOS, !isRecording, let shortcut {
                    Label("macOS would not let ForeverLM use \(shortcut.displayString). Choose another shortcut.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 6)
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        refusal = nil
        isRecording = true
        // Pressing the current shortcut must record it, not open the panel.
        hotKey.suspend()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        hotKey.resume()
    }

    private func record(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            refusal = nil
            stopRecording()
            return
        case 51, 117: // Delete, Forward Delete
            refusal = nil
            hotKey.choose(nil)
            stopRecording()
            return
        default:
            break
        }
        guard let pressed = QuickAssistantShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags) else {
            return
        }
        guard pressed.isUsable else {
            refusal = "Hold ⌃, ⌥ or ⌘ with the key."
            return
        }
        refusal = nil
        hotKey.choose(pressed)
        stopRecording()
    }
}
