import Observation
import SwiftUI

/// Where a paper's reader is, for the page pill: the page on screen and
/// whether the pointer is at the foot of the view.
///
/// A class of its own, observed only by the pill, so a page turning over while
/// the learner scrolls redraws a capsule and not the reader around it. The PDF
/// view writes `current` the moment PDFKit says the page changed (a number into
/// a property; the debounced progress save is a separate path).
@MainActor
@Observable
final class ReaderPageIndicator {
    /// Zero-based index of the page on screen.
    var current: Int?
    var pointerNearFoot = false

    init(current: Int? = nil) {
        self.current = current
    }
}

/// "2 / 33", at the foot of a paper's reading area.
///
/// The page position is not what the header is for, so it lives where it acts:
/// it appears over the page when the page changes and while the pointer is at
/// the foot of the view, then fades. Pressing it asks for a page, as Go to Page
/// in the ⋯ menu does. Hidden, it takes no clicks, so it is never a dead patch
/// over the document.
struct ReaderPagePill: View {
    let indicator: ReaderPageIndicator
    let pageCount: Int
    let goToPage: (Int) -> Void

    @State private var isShown = false
    @State private var isGoToPagePresented = false
    @State private var hideTask: Task<Void, Never>?

    /// How long the pill stays after the last thing that asked for it.
    private static let lingerDuration: Duration = .milliseconds(1_600)

    var body: some View {
        // Read here, so a new page redraws this view and nothing around it.
        let current = indicator.current
        Group {
            if let current, pageCount > 1 {
                pill(current: min(max(current, 0), pageCount - 1))
            }
        }
        .onChange(of: indicator.current) { _, _ in reveal() }
        .onChange(of: indicator.pointerNearFoot) { _, near in
            if near { reveal(holding: true) } else { reveal() }
        }
        .onAppear { reveal() }
        .onDisappear { hideTask?.cancel() }
    }

    private func pill(current: Int) -> some View {
        Button {
            isGoToPagePresented = true
        } label: {
            // `Text(verbatim:)`: a localized key would print a long book's
            // pages as "1,379".
            Text(verbatim: "\(current + 1) / \(pageCount)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0))
        .help("Go to page")
        .accessibilityLabel("Page \(current + 1) of \(pageCount)")
        .accessibilityHint("Go to a page")
        .accessibilityIdentifier("reader.pagePill")
        .padding(.bottom, 14)
        .opacity(isShown || isGoToPagePresented ? 1 : 0)
        .allowsHitTesting(isShown || isGoToPagePresented)
        .animation(.easeOut(duration: 0.2), value: isShown)
        .popover(isPresented: $isGoToPagePresented, arrowEdge: .top) {
            ReaderGoToPagePopover(
                navigation: ReaderPageNavigation(currentPage: current, pageCount: pageCount),
                goToPage: goToPage,
                dismiss: { isGoToPagePresented = false }
            )
        }
        .onChange(of: isGoToPagePresented) { _, presented in
            if !presented { reveal() }
        }
    }

    /// Shows the pill, and hides it again after a moment unless something
    /// holds it: the pointer at the foot of the view, or the page prompt.
    private func reveal(holding: Bool = false) {
        hideTask?.cancel()
        isShown = true
        guard !holding else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.lingerDuration)
            guard !Task.isCancelled, !indicator.pointerNearFoot, !isGoToPagePresented else { return }
            isShown = false
        }
    }
}
