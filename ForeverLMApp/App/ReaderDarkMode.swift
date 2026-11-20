#if os(macOS)
import AppKit
import CoreImage
import PDFKit
import QuartzCore
import SwiftUI
import WebKit

/// The reader's dark page.
///
/// ForeverLM shows a paper, a journal page or a Substack post the way its
/// publisher drew it, and in Light Mode that means a light page. In Dark Mode it
/// means a dark one — including for source material that ships no dark design of
/// its own and cannot be asked for one. There is no setting: the reader follows
/// the Mac, the same as the rest of the app.
///
/// Going dark escalates through three mechanisms, most faithful first, and never
/// reaches for a heavier one than the source needs:
///
/// 1. **The source's own dark design.** Everything whose page ForeverLM composes
///    — archived articles, EPUB chapters, transcripts, plain text — already
///    carries dark tokens and picks them up from `prefers-color-scheme`
///    (`ReaderColorTheme.system`). A live web page inherits the app's dark
///    `NSAppearance`, which is what `prefers-color-scheme` resolves against, so
///    every site that ships a dark theme renders its own.
/// 2. **Inversion, for a web page that stayed light.** Measured rather than
///    assumed: `forcedDarkWebPageScript` samples what the page actually paints
///    behind its text and inverts only a page that is still light. Photographs,
///    figures and embeds are inverted a second time so they keep their real
///    colors on the dark page.
/// 3. **Inversion, for PDFs.** A PDF is a finished rendering — there is no
///    stylesheet to swap and no element to exempt — so the page is inverted at
///    the layer, figures and all. Text stays sharp enough to read but is a touch
///    softer than the original; that is the fidelity Dark Mode costs a paper.
///
/// Mechanisms 2 and 3 invent a rendering the source never had, and that is the
/// wrong trade for a page whose colors are the content — a stained slide, a heat
/// map, a plate being read against a printed copy. `originalPageColorsKey` is
/// the opt-out for those two, and it lives in the overflow menu of the reader
/// showing the page rather than in a settings pane, because that is where the
/// page that provoked it is. Mechanism 1 is deliberately untouched: a source
/// that ships a dark design still renders it, since that page is the
/// publisher's own and not one ForeverLM made up.
///
/// Callers pass the current `ColorScheme` rather than reading a global, so a
/// reader repaints when the environment changes — including under
/// `preferredColorScheme`, which never reaches `NSApp.effectiveAppearance`.
enum ReaderDarkMode {
    // MARK: - The original page

    /// Show source material the way it was published rather than darkened. Off
    /// by default: Dark Mode still means a dark page.
    ///
    /// Deliberately undotted. `AppStorage` cross-view invalidation is KVO on the
    /// key, and `addObserver(forKeyPath: "reader.originalPageColors")` is parsed
    /// as a key path traversal rather than a literal key — a dotted key would
    /// leave the paper that is already open inverted until it was rebuilt, which
    /// is precisely the paper the reader just turned this off for. The other
    /// display toggles that must reach live views (`showReadStatus`,
    /// `uiZoomStep`) are undotted for the same reason. See `SyncedStorageObserver`.
    static let originalPageColorsKey = Prefs.Readers.originalPageColors.name
    /// Whether a reader rendering in `colorScheme` should darken a page that
    /// carries no dark design of its own.
    ///
    /// The preference is passed in rather than read here, so the view that holds
    /// it is the thing SwiftUI invalidates when it changes.
    static func darkensPage(in colorScheme: ColorScheme, originalPageColors: Bool) -> Bool {
        colorScheme == .dark && !originalPageColors
    }

    // MARK: - PDF

    /// Inverts a PDF's pages, and only its pages.
    ///
    /// Two things here are load-bearing. `layerUsesCoreImageFilters` is
    /// mandatory — AppKit silently ignores `layer.filters` on a view that has
    /// not opted into in-process rendering, which reads exactly like the filter
    /// not existing. And the filter is attached to the `PDFView` itself rather
    /// than to its document view so the offscreen buffer Core Animation needs
    /// stays the size of the viewport; hanging it on the document view would
    /// rasterize an entire 300-page paper at once.
    @MainActor
    static func apply(_ enabled: Bool, to pdfView: PDFView) {
        if defaultPDFBackground == nil {
            defaultPDFBackground = pdfView.backgroundColor
        }
        // `updateNSView` runs on every unrelated invalidation, and rebuilding
        // the filter chain each time would churn the layer for nothing.
        let isApplied = pdfView.layer?.filters?.isEmpty == false
        guard isApplied != enabled else { return }

        pdfView.wantsLayer = true
        if enabled {
            pdfView.layerUsesCoreImageFilters = true
            pdfView.layer?.filters = invertFilters()
        } else {
            pdfView.layer?.filters = nil
            pdfView.layerUsesCoreImageFilters = false
        }
        // A drop shadow survives inversion as a bright halo around every page.
        pdfView.pageShadowsEnabled = !enabled
        // The gutter around the page, pre-inversion: a light grey lands on the
        // soft near-black the rest of the app uses, where PDFKit's own grey
        // would come back as a muddy charcoal.
        pdfView.backgroundColor = enabled
            ? NSColor(white: 0.87, alpha: 1)
            : (defaultPDFBackground ?? pdfView.backgroundColor)
    }

    /// PDFKit's own gutter colour, captured from the first view we are handed
    /// and before we touch it, so turning the setting back off restores the
    /// stock appearance rather than a guess at it.
    @MainActor
    private static var defaultPDFBackground: NSColor?

    /// Invert, then rotate the hue a half turn. A straight inversion turns every
    /// figure into a photographic negative — blue plots come back orange; this
    /// pair swaps black for white and leaves hues where the author put them.
    private static func invertFilters() -> [CIFilter] {
        [
            CIFilter(name: "CIColorInvert"),
            CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi]),
        ].compactMap { $0 }
    }

    // MARK: - Web

    /// Applies the current scheme to a reader web view: the appearance the
    /// page's `prefers-color-scheme` resolves against, the colour WebKit paints
    /// around and before the page, and the forced-dark machinery for a page that
    /// turns out to have no dark design of its own.
    @MainActor
    static func apply(_ enabled: Bool, to webView: WKWebView) {
        let desiredAppearance: NSAppearance? = enabled ? NSAppearance(named: .darkAqua) : nil
        // The appearance doubles as the record of what this web view was last
        // told, which keeps an unrelated `updateNSView` from re-running the
        // script on every SwiftUI invalidation.
        guard webView.appearance?.name != desiredAppearance?.name else { return }
        webView.appearance = desiredAppearance
        webView.underPageBackgroundColor = enabled ? NSColor(white: 0.10, alpha: 1) : nil
        push(enabled, to: webView)
    }

    /// Hands the current scheme to whatever document the web view is showing.
    ///
    /// Also parks it on `window`, because the ordering between this call and the
    /// injected script is not guaranteed across a navigation: whichever arrives
    /// second finds the other's value and applies it.
    static func push(_ enabled: Bool, to webView: WKWebView) {
        webView.evaluateJavaScript(
            """
            window.__flmReaderDarkPending = \(enabled);
            if (window.__flmReaderDark) { window.__flmReaderDark.set(\(enabled)); }
            """
        )
    }

    /// Injected into every reader web view at document end, and inert until
    /// `push(_:to:)` turns it on — so a switch to Dark Mode reaches pages that
    /// are already open, not only the next one loaded.
    ///
    /// **Why a filter rather than rewritten colours.** Restyling an arbitrary
    /// publisher page means resolving every author stylesheet, and the result is
    /// wrong on exactly the pages that matter most. A filter is honest about
    /// what it is: the whole page is inverted, then media is inverted back.
    /// The cost is that `filter` on the root element makes it the containing
    /// block for `position: fixed` descendants, so a site's sticky header
    /// scrolls with the page here. That is the trade Dark Mode makes, and it
    /// applies only to pages that refused to go dark on their own.
    ///
    /// **Why the decision only goes one way.** A page can only be measured from
    /// what it has painted so far, and a site that picks its theme on hydration
    /// paints light first. Re-measuring a page that has since gone dark, and
    /// acting on the new answer each time, is what made a Substack post flicker:
    /// filter on, the site's dark theme arrives underneath it, and the reader
    /// shows a dark page inverted into a bright white one until the next tick
    /// takes the filter off again. So a page seen dark latches — it has a dark
    /// design, mechanism 1 owns it, and the filter never comes back for that
    /// document. Measuring often is then safe, and the script watches for the
    /// theme rather than polling for it.
    static let forcedDarkWebPageScript = """
    (function() {
      if (window.__flmReaderDark) {
        window.__flmReaderDark.refresh();
        return;
      }

      var STYLE_ID = 'foreverlm-reader-dark';
      var CLASS_NAME = 'flm-reader-dark';
      // The root's background is stated pre-inversion: `#e6e6e6` is what the
      // filter turns into the reader's `#191919`. WebKit paints the root's
      // background — the canvas it propagates to included — inside the root's
      // filter (measured on macOS 27), so a post-inverted
      // `#191919` stated here would come back as a light grey ground.
      // Pages that draw the ground on their own wrapper hid that; a page that
      // paints its text straight onto `html`, as press.asimov.com does, read as
      // pale grey on pale grey. The min-height keeps the root's box over the
      // whole window, so a short page stays dark to the bottom on an engine
      // that paints the canvas outside the filter. Overriding the background
      // at all is what lands every page on the same dark grey rather than on
      // whatever its own root colour inverts to.
      var CSS = [
        'html.' + CLASS_NAME + ' {',
        '  background-color: #e6e6e6 !important;',
        '  min-height: 100% !important;',
        '  filter: invert(1) hue-rotate(180deg);',
        '}',
        'html.' + CLASS_NAME + ' img,',
        'html.' + CLASS_NAME + ' picture,',
        'html.' + CLASS_NAME + ' video,',
        'html.' + CLASS_NAME + ' canvas,',
        'html.' + CLASS_NAME + ' iframe,',
        'html.' + CLASS_NAME + ' embed,',
        'html.' + CLASS_NAME + ' object {',
        '  filter: invert(1) hue-rotate(180deg);',
        '}'
      ].join('\\n');

      function parseColor(value) {
        var match = /rgba?\\(([^)]+)\\)/.exec(value || '');
        if (!match) { return null; }
        var parts = match[1].split(',').map(function(part) { return parseFloat(part); });
        if (parts.length < 3) { return null; }
        return {
          r: parts[0],
          g: parts[1],
          b: parts[2],
          a: parts.length > 3 ? parts[3] : 1
        };
      }

      function luminance(color) {
        return (0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b) / 255;
      }

      // What the page actually paints behind its text. Element backgrounds are
      // transparent by default and the canvas falls back to white, so a page
      // that never decides counts as light — which is the case this whole
      // mechanism exists for.
      //
      // Measured with the reader's own sheet switched off. Once the filter is
      // on, the root's computed background is the one this script states, not
      // the page's. A dark value would have a page whose body
      // is transparent — Substack's publication pages paint a white wrapper on
      // a bare body — read as dark on the very next measurement, latched as
      // having a dark design of its own, and lose the filter for good. The
      // value is light, which fails the other way: a site whose own
      // dark theme lands on `html` would stay hidden under it and be inverted
      // back to white. The sheet is off only between two synchronous reads, so
      // nothing is painted without it.
      function pageIsLight() {
        var ours = document.getElementById(STYLE_ID);
        var sheet = ours ? ours.sheet : null;
        if (sheet) { sheet.disabled = true; }
        try {
          var candidates = [document.body, document.documentElement];
          for (var i = 0; i < candidates.length; i += 1) {
            var element = candidates[i];
            if (!element) { continue; }
            var color = parseColor(getComputedStyle(element).backgroundColor);
            if (color && color.a > 0.5) { return luminance(color) > 0.5; }
          }
          return true;
        } finally {
          if (sheet) { sheet.disabled = false; }
        }
      }

      function installStyle(install) {
        var existing = document.getElementById(STYLE_ID);
        if (install && !existing) {
          var style = document.createElement('style');
          style.id = STYLE_ID;
          style.textContent = CSS;
          (document.head || document.documentElement).appendChild(style);
        } else if (!install && existing) {
          existing.remove();
        }
      }

      var enabled = false;
      // A page seen painting a dark background while the reader is dark has a
      // dark design of its own, and mechanism 1 owns it from that moment on.
      //
      // Latching that is what stops the flicker. The measurement can only be
      // taken from whatever the page has painted so far, and a site that picks
      // its theme on hydration paints light first — so the filter goes on, and
      // the site's own dark theme then arrives underneath it and comes back out
      // inverted, which is a bright white page. Without the latch every later
      // measurement re-litigates that, and the page flips. With it the decision
      // is monotonic: forcing can switch off exactly once per document, and can
      // never switch back on.
      var hasOwnDarkDesign = false;
      var pendingFrame = 0;
      var observer = null;

      function refresh() {
        var root = document.documentElement;
        if (!root) { return; }
        if (enabled && !hasOwnDarkDesign && !pageIsLight()) {
          hasOwnDarkDesign = true;
          // Nothing measured from here can change the answer again.
          if (observer) {
            observer.disconnect();
            observer = null;
          }
        }
        var forced = enabled && !hasOwnDarkDesign;
        installStyle(forced);
        root.classList.toggle(CLASS_NAME, forced);
      }

      // Re-measurements are coalesced onto a frame, so the page is read after
      // style has resolved rather than in the middle of the write that changed
      // it, and a burst of hydration DOM writes costs a single measurement.
      function scheduleRefresh() {
        if (pendingFrame) { return; }
        pendingFrame = requestAnimationFrame(function() {
          pendingFrame = 0;
          refresh();
        });
      }

      // Watching beats polling for a theme that lands late: a class or style
      // written to `html`/`body`, or a stylesheet appended to `head`, is seen
      // in the frame it happens rather than at the next fixed tick. The fixed
      // ticks stay as a backstop, because a `<link>` already in `head` can
      // repaint the page when it finishes loading without mutating anything.
      function watch() {
        if (observer || typeof MutationObserver !== 'function') { return; }
        observer = new MutationObserver(scheduleRefresh);
        var attributes = { attributes: true };
        observer.observe(document.documentElement, attributes);
        if (document.body) { observer.observe(document.body, attributes); }
        if (document.head) { observer.observe(document.head, { childList: true }); }
      }

      window.__flmReaderDark = {
        set: function(value) {
          enabled = !!value;
          // Synchronous, so toggling Dark Mode on a page that is already open
          // and settled repaints it now rather than a frame later.
          refresh();
        },
        refresh: refresh
      };

      watch();
      window.addEventListener('load', scheduleRefresh);
      setTimeout(scheduleRefresh, 250);
      setTimeout(scheduleRefresh, 1000);
      setTimeout(scheduleRefresh, 3000);

      if (window.__flmReaderDarkPending !== undefined) {
        window.__flmReaderDark.set(window.__flmReaderDarkPending);
      }
    })();
    """
}
/// The one-click way back to a paper's own light page, over the PDF itself.
///
/// The ⋯ menu's Original Page Colors does the same, but inversion turns a
/// figure's coloured panels around too, and a reader squinting at one wants the
/// fix where the figure is (product owner, 2026-11-19: "a quick button there to
/// change a paper pdf to the original light mode again"). Shown only in Dark
/// Mode, where there is something to undo; it flips the same preference, so a
/// press here and the menu item never disagree.
struct ReaderPageColorsButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @PreferenceStorage(Prefs.Readers.originalPageColors) private var originalPageColors

    var body: some View {
        if colorScheme == .dark {
            Button {
                originalPageColors.toggle()
            } label: {
                Image(systemName: originalPageColors ? "moon" : "sun.max")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: 0))
            .help(originalPageColors ? "Darken this page" : "Show the original light page")
            .accessibilityLabel(originalPageColors ? "Darken Page" : "Original Light Page")
            .accessibilityIdentifier("reader.pageColorsButton")
            .padding(10)
        }
    }
}

extension View {
    /// Puts `ReaderPageColorsButton` in the top trailing corner of a PDF.
    func readerPageColorsButton() -> some View {
        overlay(alignment: .topTrailing) { ReaderPageColorsButton() }
    }
}
#endif
