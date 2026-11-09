import AppKit
import Foundation
import PDFKit
import WebKit

/// Finding the passage a chat citation quotes in the text a reader shows.
///
/// The assistant copies its excerpt from the text a retrieval tool returned,
/// which is not the text the reader has in hand: the PDF reader reads pages
/// through PDFKit, the web readers read a DOM, and neither agrees with the
/// stored text about line breaks, hyphenation at line ends, ligatures, curly
/// quotes or capitalisation. Both sides are therefore folded to their letters
/// before searching, and a quote that still fails whole is tried again by its
/// longest matching run of words from either end — an excerpt the model
/// shortened or slightly misremembered still lands on the sentence it came
/// from rather than nowhere.
///
/// Distinct from `ReaderTextAnchor` on purpose: that anchor identifies a
/// passage the learner marked, exactly, with context, for years. This one
/// finds a passage a model quoted, approximately, once.
enum ReaderPassageLocator {
    struct Match: Equatable {
        let range: Range<String.Index>
        /// Whether the whole excerpt was found, or only a run of its words.
        let isComplete: Bool
    }

    /// The shortest run of words worth calling a match. Below this a partial
    /// hit lands on words that recur everywhere in the source.
    static let minimumWindowWords = 4

    /// A folded text, and for each folded character the index it came from.
    struct Projection {
        var text: String
        var indices: [String.Index]
    }

    /// Where `passage` reads in `text`, or nil when no run of at least
    /// `minimumWindowWords` of its words does.
    static func locate(_ passage: String, in text: String) -> Match? {
        let haystack = project(text)
        guard !haystack.text.isEmpty else { return nil }
        for candidate in candidates(for: passage) {
            let needle = compact(candidate.needle)
            guard !needle.isEmpty, let range = haystack.text.range(of: needle) else { continue }
            let start = haystack.text.distance(from: haystack.text.startIndex, to: range.lowerBound)
            let end = start + haystack.text.distance(from: range.lowerBound, to: range.upperBound)
            guard start < haystack.indices.count, end <= haystack.indices.count, end > start else { continue }
            let lower = haystack.indices[start]
            // One past the last matched character's original index, not the
            // next folded character's, which may sit beyond dropped separators.
            let upper = text.index(after: haystack.indices[end - 1])
            guard lower < upper else { continue }
            return Match(range: lower..<upper, isComplete: candidate.isComplete)
        }
        return nil
    }

    /// The strings to try, most specific first: the folded excerpt whole, then
    /// its leading and trailing runs of words, longest first, down to
    /// `minimumWindowWords`. Words are space-separated here so the runs can be
    /// cut; the search itself drops the spaces again.
    static func candidates(for passage: String) -> [(needle: String, isComplete: Bool)] {
        let folded = normalize(passage)
        guard !folded.isEmpty else { return [] }
        let words = folded.split(separator: " ").map(String.init)
        guard words.count > minimumWindowWords else {
            return [(folded, true)]
        }
        var result: [(String, Bool)] = [(folded, true)]
        for length in stride(from: words.count - 1, through: minimumWindowWords, by: -1) {
            result.append((words.prefix(length).joined(separator: " "), false))
            result.append((words.suffix(length).joined(separator: " "), false))
        }
        return result
    }

    /// The excerpt as folded words: lower case, plain quotes, one space between
    /// words where the excerpt had whitespace, hyphens or dashes; stripped of
    /// the quotation marks and ellipses a model wraps an excerpt in, and reduced
    /// to its longest piece when an ellipsis inside it stands for words left out.
    static func normalize(_ passage: String) -> String {
        let folded = fold(passage, separatorsBecomeSpaces: true).text
        let pieces = folded
            .replacingOccurrences(of: "...", with: "\u{2026}")
            .split(separator: "\u{2026}", omittingEmptySubsequences: true)
            .map { piece in
                piece.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            .filter { !$0.isEmpty }
        return pieces.max { $0.count < $1.count } ?? ""
    }

    /// A reader's text in the form it is searched in: every separator gone.
    ///
    /// Whitespace, hyphens and dashes are dropped rather than normalised
    /// because the reader's text and the excerpt disagree about them in ways no
    /// rule can tell apart: a PDF breaks "compensation" into "compen-" and
    /// "sation" at a line end and breaks "whole-body energy" between the same
    /// hyphen and the same newline, so the hyphen-plus-break that must be
    /// joined in one is a word boundary in the other. Comparing the letters
    /// alone is right in both cases, and an excerpt of several words is far too
    /// specific for the lost boundaries to let a wrong passage match.
    static func project(_ text: String) -> Projection {
        fold(text, separatorsBecomeSpaces: false)
    }

    /// `normalize`'s spaced form without the spaces, ready to search a
    /// projection for.
    static func compact(_ spaced: String) -> String {
        spaced.replacingOccurrences(of: " ", with: "")
    }

    /// The folding every reader's text and every excerpt go through before
    /// they are compared. Letters go to lower case, typographic quotes become
    /// plain ones, soft hyphens vanish, f-ligatures expand, and separators —
    /// whitespace, hyphens and dashes — either collapse to one space between
    /// words or are dropped altogether.
    private static func fold(_ text: String, separatorsBecomeSpaces: Bool) -> Projection {
        var out = ""
        var indices: [String.Index] = []
        out.reserveCapacity(text.count)
        indices.reserveCapacity(text.count)

        var pendingSeparatorIndex: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if isSeparator(character) {
                if !out.isEmpty { pendingSeparatorIndex = pendingSeparatorIndex ?? index }
                index = next
                continue
            }
            if character == "\u{00AD}" {
                index = next
                continue
            }

            if let separatorIndex = pendingSeparatorIndex {
                if separatorsBecomeSpaces {
                    out.append(" ")
                    indices.append(separatorIndex)
                }
                pendingSeparatorIndex = nil
            }
            for folded in foldCharacter(character) {
                out.append(folded)
                indices.append(index)
            }
            index = next
        }
        return Projection(text: out, indices: indices)
    }

    private static func isSeparator(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline { return true }
        switch character {
        case "-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}":
            return true
        default:
            return false
        }
    }

    private static func foldCharacter(_ character: Character) -> [Character] {
        switch character {
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{00AB}", "\u{00BB}":
            return ["\""]
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}":
            return ["'"]
        case "\u{FB00}": return ["f", "f"]
        case "\u{FB01}": return ["f", "i"]
        case "\u{FB02}": return ["f", "l"]
        case "\u{FB03}": return ["f", "f", "i"]
        case "\u{FB04}": return ["f", "f", "l"]
        default:
            return Array(character.lowercased())
        }
    }
}

/// The transient mark a citation click leaves on the passage it came from.
///
/// Every reader draws it in its own engine — a PDFKit highlighted selection, a
/// CSS custom highlight, a temporary text attribute — and none of them through
/// the saved-highlight path: nothing is written, nothing is listed, nothing can
/// be clicked, and the mark takes itself away. The accent colour keeps it apart
/// from the marker colours a learner chooses for their own highlights.
enum ReaderPassageFlash {
    /// How long the mark holds before it fades.
    static let holdDuration: TimeInterval = 3.2
    /// The fade runs in steps this far apart; PDFKit and CSS highlights do not
    /// animate a colour on their own.
    static let fadeStep: TimeInterval = 0.22
    static let fadeAlphas: [CGFloat] = [0.24, 0.12]
    static let alpha: CGFloat = 0.38

    /// The mark's colour at `alpha`, in the colour space every engine paints in.
    static func color(alpha: CGFloat = alpha) -> NSColor {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        return accent.withAlphaComponent(alpha)
    }

    /// The accent's channels for the page script, which fades the alpha itself.
    static func cssChannels() -> [String: Any] {
        let color = color()
        return [
            "r": Int((color.redComponent * 255).rounded()),
            "g": Int((color.greenComponent * 255).rounded()),
            "b": Int((color.blueComponent * 255).rounded()),
            "alpha": Double(alpha),
            "hold": Int(holdDuration * 1000),
            "step": Int(fadeStep * 1000),
        ]
    }

    /// Runs `body` once `view` has a size. A reader applies a request in the
    /// same update that mounts it, before AppKit has laid it out, and a scroll
    /// asked of a zero-height view goes nowhere; a few short waits cover that.
    @MainActor
    static func whenLaidOut<View: NSView>(
        _ view: View,
        attempts: Int = 12,
        _ body: @escaping @MainActor (View) -> Void
    ) {
        Task { @MainActor [weak view] in
            var remaining = attempts
            while let current = view, current.bounds.isEmpty, remaining > 0 {
                remaining -= 1
                try? await Task.sleep(for: .milliseconds(120))
            }
            // Off the update that asked, even when the view already had a size.
            await Task.yield()
            guard let view, !view.bounds.isEmpty else { return }
            body(view)
        }
    }

    /// The web readers scroll a restored position into place shortly after a
    /// page finishes loading; the flash waits past that so the two do not fight.
    static let webSettleDelay: TimeInterval = 0.35

    // MARK: PDF

    /// Scrolls `pdfView` to the passage within the pages of `pageRange` and
    /// marks it. Returns whether the passage was found; a document that does
    /// not carry it is left where it was.
    @MainActor
    @discardableResult
    static func flash(_ passage: String, in pdfView: PDFView, pageRange: Range<Int>? = nil) -> Bool {
        guard let document = pdfView.document else { return false }
        let range = (pageRange ?? 0..<document.pageCount).clamped(to: 0..<document.pageCount)
        guard let (page, selection) = selection(for: passage, in: document, pageRange: range) else { return false }

        selection.color = color()
        pdfView.highlightedSelections = (pdfView.highlightedSelections ?? []) + [selection]
        scroll(pdfView, to: selection, on: page)

        Task { @MainActor [weak pdfView] in
            try? await Task.sleep(for: .seconds(holdDuration))
            for fadeAlpha in fadeAlphas {
                guard let pdfView,
                      pdfView.highlightedSelections?.contains(where: { $0 === selection }) == true else { return }
                selection.color = color(alpha: fadeAlpha)
                // Reassigned so PDFKit repaints; the colour alone does not.
                pdfView.highlightedSelections = pdfView.highlightedSelections
                try? await Task.sleep(for: .seconds(fadeStep))
            }
            guard let pdfView else { return }
            let remaining = (pdfView.highlightedSelections ?? []).filter { $0 !== selection }
            pdfView.highlightedSelections = remaining.isEmpty ? nil : remaining
        }
        return true
    }

    /// The passage as PDFKit geometry: the first page whose text carries the
    /// whole excerpt, else the first that carries a run of its words.
    static func selection(
        for passage: String,
        in document: PDFDocument,
        pageRange: Range<Int>
    ) -> (PDFPage, PDFSelection)? {
        var partial: (PDFPage, PDFSelection)?
        for index in pageRange {
            guard let page = document.page(at: index),
                  let text = page.string, !text.isEmpty,
                  let match = ReaderPassageLocator.locate(passage, in: text),
                  let selection = page.selection(for: NSRange(match.range, in: text)) else { continue }
            if match.isComplete { return (page, selection) }
            if partial == nil { partial = (page, selection) }
        }
        return partial
    }

    /// Brings the passage to the middle of the view rather than its edge, so
    /// the sentence it belongs to is readable around it.
    @MainActor
    private static func scroll(_ pdfView: PDFView, to selection: PDFSelection, on page: PDFPage) {
        let bounds = selection.bounds(for: page)
        guard !bounds.isNull, !bounds.isEmpty else {
            pdfView.go(to: selection)
            return
        }
        let scale = max(pdfView.scaleFactor, 0.01)
        let visibleHeight = pdfView.bounds.height / scale
        let margin = max(0, (visibleHeight - bounds.height) / 2)
        pdfView.go(to: bounds.insetBy(dx: 0, dy: -margin), on: page)
    }

    // MARK: Text views

    /// Scrolls `textView` to the passage and marks it with a temporary
    /// attribute, which the layout manager paints over whatever the text
    /// storage carries and drops without touching it. Returns whether the
    /// passage was found.
    @MainActor
    @discardableResult
    static func flash(_ passage: String, in textView: NSTextView) -> Bool {
        let text = textView.string
        guard let match = ReaderPassageLocator.locate(passage, in: text),
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return false }
        let range = NSRange(match.range, in: text)
        guard range.length > 0 else { return false }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        if let clipView = textView.enclosingScrollView?.contentView {
            let y = max(0, rect.midY - clipView.bounds.height / 2)
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
            textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        } else {
            textView.scrollRangeToVisible(range)
        }

        layoutManager.addTemporaryAttribute(.backgroundColor, value: color(), forCharacterRange: range)
        Task { @MainActor [weak layoutManager] in
            // The text may have been replaced under the mark; a range past its
            // end belongs to a document that is gone.
            func stillValid(_ layoutManager: NSLayoutManager) -> Bool {
                NSMaxRange(range) <= (layoutManager.textStorage?.length ?? 0)
            }
            try? await Task.sleep(for: .seconds(holdDuration))
            for fadeAlpha in fadeAlphas {
                guard let layoutManager, stillValid(layoutManager) else { return }
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color(alpha: fadeAlpha), forCharacterRange: range)
                try? await Task.sleep(for: .seconds(fadeStep))
            }
            guard let layoutManager, stillValid(layoutManager) else { return }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        return true
    }

    // MARK: Web

    /// Asks a loaded page to find the passage, scroll to it and mark it.
    /// `scope` names the chapter section to search when the page is an EPUB
    /// book read as one document: the passage is that chapter's, and the
    /// whole book is far too much text to fold for one citation.
    /// `found` answers whether the page carried the passage: a live page behind
    /// a paywall or a metered cut-off does not, and the caller can then show
    /// the saved copy instead.
    static func flash(
        _ passage: String,
        in webView: WKWebView,
        scope: String? = nil,
        world: WKContentWorld = .page,
        found: ((Bool) -> Void)? = nil
    ) {
        var payload = cssChannels()
        payload["passage"] = passage
        if let scope { payload["scope"] = scope }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            found?(false)
            return
        }
        webView.evaluateJavaScript(
            "!!(window.foreverLMFlashPassage && window.foreverLMFlashPassage(\(json)));",
            in: nil,
            in: world
        ) { result in
            found?(((try? result.get()) as? NSNumber)?.boolValue ?? false)
        }
    }

    /// One-time installer for the web readers. Folds the page's text the way
    /// `ReaderPassageLocator.project` folds it, keeping a map from each folded
    /// character to its text node, and paints the found range through the CSS
    /// Custom Highlight API so the page's own DOM is never rewritten.
    static let webInstallerScript = """
    (function() {
        if (window.foreverLMPassageFlashInstalled) { return; }
        window.foreverLMPassageFlashInstalled = true;

        var NAME = 'foreverlm-citation';
        var MIN_WORDS = \(ReaderPassageLocator.minimumWindowWords);
        var timers = [];

        var FOLD = {
            '\\u201C': '"', '\\u201D': '"', '\\u201E': '"', '\\u201F': '"', '\\u00AB': '"', '\\u00BB': '"',
            '\\u2018': "'", '\\u2019': "'", '\\u201A': "'", '\\u201B': "'", '\\u2032': "'",
            '\\uFB00': 'ff', '\\uFB01': 'fi', '\\uFB02': 'fl', '\\uFB03': 'ffi', '\\uFB04': 'ffl'
        };

        // Whitespace, hyphens and dashes: the boundaries the page and the
        // excerpt disagree about, so neither side keeps them when searching.
        function isSeparator(ch) {
            return /\\s/.test(ch) || ch === '-' || (ch >= '\\u2010' && ch <= '\\u2015') || ch === '\\u2212';
        }

        // Folds a run of characters given as [{ch, node, offset}] into text
        // plus a map from each folded character to where it came from. With
        // `spaced`, a run of separators between words becomes one space; the
        // page index is built without, and searched for spaceless needles.
        function foldRun(chars, spaced) {
            var text = '';
            var map = [];
            var pending = null;
            for (var i = 0; i < chars.length; i++) {
                var item = chars[i];
                var ch = item.ch;
                if (isSeparator(ch)) {
                    if (text.length && !pending) { pending = item; }
                    continue;
                }
                if (ch === '\\u00AD') { continue; }
                if (pending) {
                    if (spaced) { text += ' '; map.push(pending); }
                    pending = null;
                }
                var folded = FOLD[ch] !== undefined ? FOLD[ch] : ch.toLowerCase();
                for (var k = 0; k < folded.length; k++) { text += folded[k]; map.push(item); }
            }
            return { text: text, map: map };
        }

        function pageChars(root) {
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                acceptNode: function(node) {
                    var parent = node.parentNode;
                    if (!parent) { return NodeFilter.FILTER_REJECT; }
                    var name = parent.nodeName;
                    if (name === 'SCRIPT' || name === 'STYLE' || name === 'NOSCRIPT') {
                        return NodeFilter.FILTER_REJECT;
                    }
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            var chars = [];
            var node;
            while ((node = walker.nextNode())) {
                var value = node.nodeValue || '';
                for (var i = 0; i < value.length; i++) {
                    chars.push({ ch: value[i], node: node, offset: i });
                }
            }
            return chars;
        }

        function normalizePassage(passage) {
            var chars = [];
            for (var i = 0; i < passage.length; i++) { chars.push({ ch: passage[i] }); }
            var folded = foldRun(chars, true).text.replace(/\\.\\.\\./g, '\\u2026');
            var pieces = folded.split('\\u2026').map(function(piece) {
                return piece.replace(/^[ "']+|[ "']+$/g, '');
            }).filter(function(piece) { return piece.length > 0; });
            var best = '';
            for (var j = 0; j < pieces.length; j++) { if (pieces[j].length > best.length) { best = pieces[j]; } }
            return best;
        }

        function candidates(passage) {
            var folded = normalizePassage(passage);
            if (!folded) { return []; }
            var words = folded.split(' ');
            var result = [folded];
            for (var length = words.length - 1; length >= MIN_WORDS; length--) {
                result.push(words.slice(0, length).join(' '));
                result.push(words.slice(words.length - length).join(' '));
            }
            return result;
        }

        function scopeRoot(scope) {
            if (!scope) { return document.body; }
            var sections = document.querySelectorAll('[data-flm-chapter]');
            for (var i = 0; i < sections.length; i++) {
                if (sections[i].getAttribute('data-flm-chapter') === scope) { return sections[i]; }
            }
            return null;
        }

        function locate(passage, scope) {
            var root = scopeRoot(scope);
            if (!root) { return null; }
            var index = foldRun(pageChars(root), false);
            if (!index.text) { return null; }
            var list = candidates(passage);
            for (var i = 0; i < list.length; i++) {
                var needle = list[i].replace(/ /g, '');
                if (!needle) { continue; }
                var at = index.text.indexOf(needle);
                if (at < 0) { continue; }
                var head = index.map[at];
                var tail = index.map[at + needle.length - 1];
                if (!head || !tail) { continue; }
                try {
                    var range = document.createRange();
                    range.setStart(head.node, head.offset);
                    range.setEnd(tail.node, tail.offset + 1);
                    return range;
                } catch (e) {}
            }
            return null;
        }

        function styleElement() {
            var style = document.getElementById('foreverlm-citation-style');
            if (!style) {
                style = document.createElement('style');
                style.id = 'foreverlm-citation-style';
                (document.head || document.documentElement).appendChild(style);
            }
            return style;
        }

        function paint(options, alpha) {
            styleElement().textContent = '::highlight(' + NAME + ') { background-color: rgba('
                + options.r + ', ' + options.g + ', ' + options.b + ', ' + alpha + '); }';
        }

        function clear() {
            for (var i = 0; i < timers.length; i++) { clearTimeout(timers[i]); }
            timers = [];
            if (window.CSS && CSS.highlights) { CSS.highlights.delete(NAME); }
        }

        window.foreverLMFlashPassage = function(options) {
            options = options || {};
            var range = locate(String(options.passage || ''), options.scope ? String(options.scope) : '');
            if (!range) { return false; }
            clear();

            var rect = range.getBoundingClientRect();
            if (rect && (rect.height || rect.width)) {
                window.scrollTo({
                    top: window.scrollY + rect.top - (window.innerHeight - rect.height) / 2,
                    behavior: 'smooth'
                });
            }

            if (!window.CSS || !CSS.highlights || typeof Highlight === 'undefined') { return true; }
            try {
                var group = new Highlight();
                group.add(range);
                CSS.highlights.set(NAME, group);
            } catch (e) {
                return true;
            }
            var alpha = Number(options.alpha) || 0.38;
            paint(options, alpha);
            var hold = Number(options.hold) || 3200;
            var step = Number(options.step) || 220;
            var stops = [alpha * 0.63, alpha * 0.32];
            var delay = hold;
            for (var i = 0; i < stops.length; i++) {
                (function(value, when) {
                    timers.push(setTimeout(function() { paint(options, value); }, when));
                })(stops[i], delay);
                delay += step;
            }
            timers.push(setTimeout(clear, delay));
            return true;
        };
    })();
    """
}

/// Keeps a reader from replaying a passage request it has already answered.
///
/// A target waits in the view model until the reader showing its source acts on
/// it; the reader's coordinator reads it on every update, so it needs to know
/// which one it has seen. Finishing the request clears it from the view model,
/// off the SwiftUI update it was read in.
final class ReaderPassageTargetTracker {
    private var handledKey: String?
    /// The Studio window this reader is drawn in, set by the reader on each
    /// update; nil in a window that is no Studio window. A request naming
    /// another window is not this reader's (`ReaderRequestWindow`).
    var readerWindowID: UUID?

    /// Created in a coordinator's stored-property initialiser, which is not on
    /// any actor; everything it does afterwards is.
    nonisolated init() {}

    /// The request for `sourceID` this reader has not acted on yet, if any.
    @MainActor
    func pending(for sourceID: String, in vm: StudioViewModel) -> ReaderPassageTarget? {
        guard let target = vm.readerPassageTarget,
              target.sourceID == sourceID,
              ReaderRequestWindow.reaches(target.windowID, readerIn: readerWindowID),
              target.presentationKey != handledKey else { return nil }
        return target
    }

    @MainActor
    func finish(_ target: ReaderPassageTarget, in vm: StudioViewModel) {
        handledKey = target.presentationKey
        Task { @MainActor [weak vm] in
            vm?.finishReaderPassage(target)
        }
    }
}
