// Pull-to-refresh for the source sidebar list.
import SwiftUI
import AppKit

/// Fires refresh callbacks when the user reaches or pulls past the top of the list
/// that this view backs. SwiftUI's `.refreshable` has no scroll-driven trigger on
/// macOS, so we observe the underlying `NSScrollView`'s clip-view bounds. The view
/// is invisible and sits behind the list, so it never intercepts clicks; it just
/// locates the scroll view and watches it.
///
/// A deliberate pull (fingers on the trackpad, gesture phase, no momentum) fires
/// `onRefresh` — the full refresh with loading UI. An ordinary upward scroll that
/// reaches the top fires `onSilentRefresh`: scrolling to the top is the user asking
/// "is there anything new?", so it should sync immediately — but through a quiet
/// path that shows no loading UI and republishes the list only when something
/// actually changed.
struct OverscrollRefresh: NSViewRepresentable {
    /// How far the content must be pulled past the top before a refresh fires.
    var threshold: CGFloat = 64
    var onRefresh: () -> Void
    var onSilentRefresh: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = TrackerView()
        view.threshold = threshold
        view.onRefresh = onRefresh
        view.onSilentRefresh = onSilentRefresh
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TrackerView else { return }
        view.threshold = threshold
        view.onRefresh = onRefresh
        view.onSilentRefresh = onSilentRefresh
    }

    final class TrackerView: NSView {
        var threshold: CGFloat = 64
        var onRefresh: (() -> Void)?
        var onSilentRefresh: (() -> Void)?

        private weak var clipView: NSClipView?
        private var observer: NSObjectProtocol?
        private var scrollEventMonitor: Any?
        private var armed = true
        private var isUserDragScrolling = false
        /// Starts false so constructing a List already positioned at the top is
        /// not mistaken for a user refresh. It becomes true only after this List
        /// has actually been scrolled down.
        private var hasScrolledAwayFromTop = false
        private var setupAttempts = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardown()
            guard window != nil else { return }
            setupAttempts = 0
            scheduleSetup()
        }

        private func scheduleSetup() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.attemptSetup()
            }
        }

        private func attemptSetup() {
            guard observer == nil, window != nil else { return }
            if let scrollView = locateScrollView() {
                let clip = scrollView.contentView
                clip.postsBoundsChangedNotifications = true
                clipView = clip
                hasScrolledAwayFromTop = clip.bounds.origin.y > 1
                observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clip,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleScroll()
                }
                scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.trackScrollPhases(of: event)
                    return event
                }
            } else if setupAttempts < 8 {
                setupAttempts += 1
                scheduleSetup()
            }
        }

        /// Older mouse wheels report no phases, but they also can't rubber-band, so
        /// they never reach the overscroll region and the flag's state is irrelevant.
        private func trackScrollPhases(of event: NSEvent) {
            if event.momentumPhase != [] {
                isUserDragScrolling = false
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                    finishScrollGesture()
                }
            } else if event.phase == .began || event.phase == .changed {
                isUserDragScrolling = true
            } else if event.phase == .ended || event.phase == .cancelled {
                isUserDragScrolling = false
                finishScrollGesture()
            }
        }

        private func finishScrollGesture() {
            guard let offset = clipView?.bounds.origin.y, offset <= 1 else { return }
            // A top-reaching silent refresh disarms a later elastic crossing in
            // the same gesture. Re-arm only when that gesture has settled, so a
            // new deliberate pull from the top can still request a full refresh.
            armed = true
        }

        private func handleScroll() {
            guard let clipView else { return }
            let offset = clipView.bounds.origin.y
            if offset <= -threshold {
                guard armed else { return }
                if isUserDragScrolling {
                    armed = false
                    onRefresh?()
                } else if let onSilentRefresh {
                    armed = false
                    onSilentRefresh()
                }
            } else if offset > 1 {
                hasScrolledAwayFromTop = true
                armed = true
            } else if offset <= 0, hasScrolledAwayFromTop {
                // Reaching the real top is enough. Requiring a 64-point elastic
                // bounce meant normal upward scrolling never synced plugins.
                hasScrolledAwayFromTop = false
                armed = false
                onSilentRefresh?()
            }
        }

        /// Finds the table-backed scroll view whose frame contains this (invisible)
        /// backing view's center — i.e. the list we're behind, ignoring any other
        /// scroll views elsewhere in the window.
        private func locateScrollView() -> NSScrollView? {
            guard let root = window?.contentView else { return nil }
            let frameInWindow = convert(bounds, to: nil)
            guard frameInWindow.width > 0, frameInWindow.height > 0 else { return nil }
            let center = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
            var match: NSScrollView?
            func walk(_ view: NSView) {
                // The list's vertical scroll view; the innermost one wins.
                if let scrollView = view as? NSScrollView, scrollView.hasVerticalScroller {
                    let frame = scrollView.convert(scrollView.bounds, to: nil)
                    if frame.contains(center) { match = scrollView }
                }
                for subview in view.subviews { walk(subview) }
            }
            walk(root)
            return match
        }

        private func teardown() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            if let scrollEventMonitor {
                NSEvent.removeMonitor(scrollEventMonitor)
                self.scrollEventMonitor = nil
            }
            clipView = nil
            armed = true
            isUserDragScrolling = false
            hasScrolledAwayFromTop = false
        }

        deinit { teardown() }
    }
}
