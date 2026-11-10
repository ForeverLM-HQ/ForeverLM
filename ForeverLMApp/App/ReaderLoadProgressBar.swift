import AppKit

/// What the reader's load progress bar should be showing, derived from the web
/// view's `isLoading` and `estimatedProgress`.
///
/// A click on a publisher page often has nothing to show for seconds: nature.com
/// answers with a blank bot-check page before the real one, and Google's sign-in
/// page is over a megabyte. The toolbar spinner is the reader's only feedback,
/// and the compact toolbar does not draw it at all, so a working click reads as a
/// dead one and gets clicked again — which restarts the navigation. The bar is
/// the browser answer to that: it appears the moment a load starts, creeps as
/// WebKit's estimate grows, fills when the page commits, and fades out.
struct ReaderLoadProgressModel: Equatable {
    enum Presentation: Equatable {
        case hidden
        /// A page is on its way; `fraction` is how far along, in 0...1.
        case loading(fraction: Double)
        /// The load just ended; draw the bar full, then let it fade.
        case completed
    }

    /// WebKit reports 0 before the first byte. A bar with no width is invisible,
    /// so a load that has only just started still draws this much.
    static let minimumVisibleFraction = 0.08

    private(set) var presentation: Presentation = .hidden

    mutating func update(isLoading: Bool, estimatedProgress: Double) {
        if isLoading {
            guard case .loading(let current) = presentation else {
                // A load is starting. `isLoading` flips before WebKit resets
                // its estimate, so the value alongside it is the previous
                // page's — usually 1. Taking it would draw a full bar for a
                // page that has not sent a byte; the next estimate grows it.
                presentation = .loading(fraction: Self.minimumVisibleFraction)
                return
            }
            // WebKit resets its estimate after a server redirect; the bar
            // moving backwards would read as a second load, not the same one.
            let reported = Self.clamp(estimatedProgress)
            presentation = .loading(fraction: max(current, reported))
        } else {
            switch presentation {
            case .loading:
                presentation = .completed
            case .completed, .hidden:
                // Idle web views — a freshly installed one, or a parked page
                // coming back — have nothing to announce.
                break
            }
        }
    }

    /// The fade after `.completed` has finished; the bar is gone until the next load.
    mutating func hideAfterCompletion() {
        guard presentation == .completed else { return }
        presentation = .hidden
    }

    mutating func reset() {
        presentation = .hidden
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// The thin bar along the top edge of the reader's web view that shows a page
/// load in progress, the way a browser's address bar does.
@MainActor
final class ReaderLoadProgressBar: NSView {
    static let thickness: CGFloat = 3

    private let fill = CALayer()
    private var model = ReaderLoadProgressModel()
    private var fadeTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        fill.anchorPoint = .zero
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.cornerRadius = 1.5
        layer?.addSublayer(fill)
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = fillFrame(for: model.presentation)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    /// The bar only ever learns about loads from here, so a web view that moves
    /// between hosts brings its own state along with it.
    func update(isLoading: Bool, estimatedProgress: Double) {
        model.update(isLoading: isLoading, estimatedProgress: estimatedProgress)
        apply(model.presentation)
    }

    func reset() {
        fadeTask?.cancel()
        fadeTask = nil
        model.reset()
        apply(.hidden, animated: false)
    }

    var presentationForTesting: ReaderLoadProgressModel.Presentation { model.presentation }

    private func apply(_ presentation: ReaderLoadProgressModel.Presentation, animated: Bool = true) {
        fadeTask?.cancel()
        fadeTask = nil
        switch presentation {
        case .hidden:
            alphaValue = 0
            isHidden = true
            setFillFrame(fillFrame(for: .hidden), animated: false)
        case .loading:
            isHidden = false
            alphaValue = 1
            setFillFrame(fillFrame(for: presentation), animated: animated)
        case .completed:
            isHidden = false
            alphaValue = 1
            setFillFrame(fillFrame(for: .completed), animated: animated)
            fadeTask = Task { @MainActor [weak self] in
                // Long enough for the full bar to register as "done".
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    self.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.model.presentation == .completed else { return }
                        self.model.hideAfterCompletion()
                        self.isHidden = true
                        self.setFillFrame(self.fillFrame(for: .hidden), animated: false)
                    }
                })
            }
        }
    }

    private func fillFrame(for presentation: ReaderLoadProgressModel.Presentation) -> CGRect {
        let fraction: Double
        switch presentation {
        case .hidden: fraction = 0
        case .loading(let value): fraction = value
        case .completed: fraction = 1
        }
        return CGRect(x: 0, y: 0, width: bounds.width * CGFloat(fraction), height: bounds.height)
    }

    private func setFillFrame(_ frame: CGRect, animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        fill.frame = frame
        CATransaction.commit()
    }
}
