// The update pill on the rail.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Update button

/// Codex-style update pill at the trailing edge of the rail's footer, beside
/// Voice. Sparkle keeps its own install window. Clicking the pill runs a fresh
/// check, so the dialog that opens offers the newest build on the feed rather
/// than the one the pill was found with (see `AppUpdateOfferPolicy`); during a
/// download or install it brings that progress back into focus instead.
struct RailUpdateButton: View {
    @ObservedObject var updateController: AppUpdateController
    /// In a notebook window's icon strip: a blue disc with the phase's glyph,
    /// the word in its help.
    var isCompact = false

    @State private var isHovering = false

    private var compactSymbol: String {
        switch updateController.phase {
        case .idle, .available: return "arrow.down"
        case .downloading, .preparing: return "arrow.down"
        case .readyToInstall, .relaunchToFinish: return "arrow.clockwise"
        }
    }

    private var versionText: String {
        if let version = updateController.phase.version {
            return "ForeverLM \(version)"
        }
        return "ForeverLM update"
    }

    private var helpText: String {
        switch updateController.phase {
        case .idle:
            return "ForeverLM is up to date"
        case .available:
            return "\(versionText) is available — click to update"
        case .downloading:
            return "Downloading \(versionText) — click to show progress"
        case .preparing:
            return "Preparing \(versionText) — click to show progress"
        case .readyToInstall:
            return "\(versionText) is ready — click to install and relaunch"
        case .relaunchToFinish:
            return "\(versionText) is already installed — click to relaunch"
        }
    }

    /// One word: the pill is a status, the tooltip carries the sentence.
    private var labelText: String {
        switch updateController.phase {
        case .idle, .available:
            return "Update"
        case .downloading, .preparing:
            return "Updating"
        case .readyToInstall, .relaunchToFinish:
            return "Restart"
        }
    }

    /// Relaunching needs no Sparkle session, so it stays clickable while
    /// Sparkle cannot check.
    private var isRelaunchOnly: Bool {
        if case .relaunchToFinish = updateController.phase { return true }
        return false
    }

    private var isInProgress: Bool {
        switch updateController.phase {
        case .downloading, .preparing:
            return true
        case .idle, .available, .readyToInstall, .relaunchToFinish:
            return false
        }
    }

    var body: some View {
        Button {
            updateController.checkForUpdates()
        } label: {
            HStack(spacing: 5) {
                if isInProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
                if isCompact {
                    if !isInProgress {
                        Image(systemName: compactSymbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else {
                    Text(labelText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, isCompact ? 0 : 10)
            .frame(width: isCompact ? 24 : nil, height: isCompact ? 24 : 22)
            // The pill is opaque, so the shared grey hover wash would paint
            // behind it and never show. Brighten the fill itself instead.
            .background(
                Capsule().fill(Color.blue)
                    .overlay { Capsule().fill(Color.white.opacity(isHovering ? 0.14 : 0)) }
            )
            // The same 32pt row height as Voice and the MCP light, so the pill
            // centres on the footer's rhythm without stretching the hit area.
            .frame(height: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .disabled(!updateController.canCheckForUpdates && !isRelaunchOnly)
        .modifier(RailHelpOrTooltip(text: helpText, isCompact: isCompact))
        .accessibilityLabel("App update")
        .accessibilityValue(helpText)
        .accessibilityIdentifier(AccessibilityID.appUpdateButton)
    }
}
