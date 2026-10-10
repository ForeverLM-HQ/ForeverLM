import SwiftUI

/// "Before you share" (docs/teams-design.md, decision 22): the two-sentence
/// statement, the box, **Share** (only once the box is ticked) and **Cancel**,
/// and nothing else. The window's sheet shows it for a share chosen in a menu
/// (`SharingRightsPrompt`); a share popover shows it in place of its own face,
/// where the learner pressed Invite or Copy.
struct SharingRightsAffirmationView: View {
    let onShare: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    @State private var hasRights = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SharingRightsAffirmation.title)
                .font(.system(size: 14, weight: .semibold))
            Text(SharingRightsAffirmation.statement)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(SharingRightsAffirmation.checkboxLabel, isOn: $hasRights)
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(SharingRightsAffirmation.cancelButtonTitle, role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(SharingRightsAffirmation.shareButtonTitle) { onShare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasRights)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sharing.rightsAffirmation")
    }
}

/// The window's "Before you share" sheet, for a share chosen in a menu: a
/// menu item has no sheet of its own to present (as with the New Team
/// prompt), so the Studio window hosts it once (`sharingRightsPrompt()`) and
/// only the active window shows it.
@MainActor
@Observable
final class SharingRightsPrompt {
    static let shared = SharingRightsPrompt()

    private(set) var isPresented = false
    @ObservationIgnored private var pendingShare: (@MainActor () -> Void)?

    init() {}

    /// Runs `share` at once when the learner's affirmation is current;
    /// otherwise asks first, and runs it only once they tick the box and
    /// press Share. Cancel shares nothing.
    func askIfNeeded(then share: @escaping @MainActor () -> Void) {
        guard SharingRightsRow.needsAsking else {
            share()
            return
        }
        pendingShare = share
        isPresented = true
    }

    /// Share pressed: the affirmation is recorded, then the share runs.
    func confirm() {
        let share = pendingShare
        pendingShare = nil
        isPresented = false
        SharingRightsRow.affirm()
        share?()
    }

    func cancel() {
        pendingShare = nil
        isPresented = false
    }
}

extension View {
    /// Hosts the "Before you share" sheet. Applied once per Studio window;
    /// only the active window shows it, so two windows never ask at once.
    func sharingRightsPrompt() -> some View {
        modifier(SharingRightsPromptModifier())
    }
}

private struct SharingRightsPromptModifier: ViewModifier {
    @Environment(StudioWindowState.self) private var windowState
    @State private var prompt = SharingRightsPrompt.shared

    private var isPresented: Binding<Bool> {
        Binding(
            get: { prompt.isPresented && StudioWindowRegistry.shared.activeState === windowState },
            set: { if !$0, prompt.isPresented { prompt.cancel() } }
        )
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented) {
            SharingRightsAffirmationView(onShare: { prompt.confirm() }, onCancel: { prompt.cancel() })
                .padding(20)
                .frame(width: 420)
        }
    }
}
