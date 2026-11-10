// The sidebar toggle and the place arrows.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Sidebar toggle

/// Compact show/hide control for the navigation rail, styled to sit in the
/// window's top-left chrome next to the macOS traffic lights (Claude/Codex-style).
struct NavigationRailToggle: View {
    @Binding var isVisible: Bool

    var body: some View {
        StudioChromeIconButton(
            systemImage: "sidebar.left",
            label: isVisible ? "Hide sidebar" : "Show sidebar"
        ) {
            isVisible.toggle()
        }
    }
}

/// ‹ › beside the traffic lights, Codex's (product owner, 2026-10-12: "can do
/// front and back arrow"): back to the place this window showed before, and
/// forward again (`StudioWindowState.placeHistory`). Greyed where there is
/// nowhere to go. It also settles each place the window comes to rest on,
/// here rather than in `StudioView`, so only this small view redraws as the
/// window moves.
struct WindowPlaceArrows: View {
    @Environment(StudioWindowState.self) private var windowState
    /// Reopens what `place` showed that the window state does not hold: its
    /// chat and its source.
    let reopen: (StudioWindowPlace) -> Void
    @State private var settle: Task<Void, Never>?

    var body: some View {
        HStack(spacing: StudioTopBar.leadingControlsSpacing) {
            arrow("arrow.left", label: "Back", identifier: "studio.window.back", enabled: windowState.canGoBackInPlaces) {
                if let place = windowState.goBackInPlaces() { reopen(place) }
            }
            arrow("arrow.right", label: "Forward", identifier: "studio.window.forward", enabled: windowState.canGoForwardInPlaces) {
                if let place = windowState.goForwardInPlaces() { reopen(place) }
            }
        }
        // A move changes the window in several steps — the pane, then the
        // chat or the source it shows — so a place is settled once the
        // window has stopped changing, as one step back.
        .onChange(of: windowState.currentPlace.identity, initial: true) { _, _ in
            settle?.cancel()
            settle = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                windowState.notePlaceSettled()
            }
        }
    }

    private func arrow(
        _ systemImage: String,
        label: String,
        identifier: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        StudioChromeIconButton(systemImage: systemImage, label: label) {
            withAnimation(.easeInOut(duration: 0.18)) { action() }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityIdentifier(identifier)
    }
}
