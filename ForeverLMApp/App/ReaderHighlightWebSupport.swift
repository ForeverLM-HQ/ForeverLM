import Foundation
import WebKit

/// Painting saved notes into the WebKit readers.
///
/// The page re-finds each passage itself, using the same whitespace-collapsed
/// projection and the same scoring as `ReaderTextAnchor` — that is what lets a
/// note made in the archived-article reader still land after the article is
/// re-fetched with different markup. Marks are drawn with the CSS Custom
/// Highlight API, so nothing in the page's own DOM is rewritten and the
/// reader's find-in-page, selection and layout are untouched.
///
/// A mark on a picture (`ReaderImageAnchor`) is the one exception: the
/// highlight API tints text runs and cannot tint a replaced element, so the
/// page re-finds the `<img>` — by the URL it was marked at, else by file name
/// (a CDN rewrites the query and size segment between fetches) with the alt
/// text breaking ties — and outlines it through two data attributes on the
/// element and one stylesheet rule. Attributes, not styles, so the page's own
/// CSS is left alone and clearing a mark is removing the attribute.
enum ReaderWebHighlightSupport {
    /// One-time installer, added beside the selection callout's user script.
    ///
    /// - Parameter handlerName: the `window.webkit.messageHandlers` channel the
    ///   host reader already registers, used to report clicks on a highlight.
    static func installerScript(handlerName: String) -> String {
        template.replacingOccurrences(of: "__FOREVERLM_HANDLER__", with: handlerName)
    }

    /// Pushes the current set of highlights into a loaded page.
    ///
    /// `scopedBySource` is for a page holding several sources — an EPUB book
    /// read as one document, one `data-flm-chapter` section per chapter. Each
    /// mark is then found in its own chapter's section, whose text its anchor
    /// was measured in, rather than in the whole page.
    ///
    /// `world` is the content world the installer script runs in: a reader
    /// that keeps its scripts out of the page's reach
    /// (`WebViewReader.scriptWorld`) calls them there.
    static func apply(_ highlights: [SourceHighlight], to webView: WKWebView, scopedBySource: Bool = false, world: WKContentWorld = .page) {
        let payload = highlights.map { highlight in
            [
                "id": highlight.id,
                "scope": scopedBySource ? highlight.sourceID : "",
                "exact": highlight.quote,
                "prefix": highlight.anchor.prefix,
                "suffix": highlight.anchor.suffix,
                "offset": highlight.anchor.offset,
                "color": highlight.color.rawValue,
                "images": highlight.imageAnchors.map { anchor in
                    ["src": anchor.src, "alt": anchor.alt, "file": anchor.fileName] as [String: Any]
                },
            ] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.foreverLMApplyHighlights && window.foreverLMApplyHighlights(\(json)); true;",
            in: nil,
            in: world
        )
    }

    /// Scrolls a page to a saved note and flashes it.
    static func reveal(_ highlight: SourceHighlight, in webView: WKWebView, world: WKContentWorld = .page) {
        let escaped = highlight.id.replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript(
            "window.foreverLMRevealHighlight && window.foreverLMRevealHighlight('\(escaped)'); true;",
            in: nil,
            in: world
        )
    }

    /// CSS for the highlight pseudo-elements, one rule per color, and the
    /// outline a marked picture wears in the same colors.
    private static var highlightCSS: String {
        let text = SourceHighlightColor.allCases.map { color in
            "::highlight(foreverlm-note-\(color.rawValue)) { background-color: \(color.cssColor(alpha: 0.42)); }"
        }
        let pictures = ["img[data-foreverlm-note] { outline: 4px solid \(SourceHighlightColor.default.cssColor(alpha: 0.9)); outline-offset: 3px; border-radius: 2px; cursor: pointer; }"]
            + SourceHighlightColor.allCases.map { color in
                "img[data-foreverlm-note][data-foreverlm-note-color=\"\(color.rawValue)\"] { outline-color: \(color.cssColor(alpha: 0.9)); }"
            }
        return (text + pictures).joined(separator: " ")
    }

    private static var template: String {
        rawTemplate.replacingOccurrences(of: "__FOREVERLM_HIGHLIGHT_CSS__", with: highlightCSS)
            .replacingOccurrences(of: "__FOREVERLM_COLORS__", with: SourceHighlightColor.allCases.map(\.rawValue).joined(separator: ","))
    }

    private static let rawTemplate = """
    (function() {
        if (window.foreverLMReaderHighlightsInstalled) { return; }
        window.foreverLMReaderHighlightsInstalled = true;

        var HANDLER = '__FOREVERLM_HANDLER__';
        var COLORS = '__FOREVERLM_COLORS__'.split(',');
        var CONTEXT_WEIGHT = 2.0;
        var entries = [];

        function post(payload) {
            if (!HANDLER) { return; }
            try {
                window.webkit.messageHandlers[HANDLER].postMessage(payload);
            } catch (e) {}
        }

        function installStyle() {
            if (document.getElementById('foreverlm-note-style')) { return; }
            var style = document.createElement('style');
            style.id = 'foreverlm-note-style';
            style.textContent = '__FOREVERLM_HIGHLIGHT_CSS__';
            (document.head || document.documentElement).appendChild(style);
        }

        // The page's text in the same projection ReaderTextAnchor.normalize
        // produces, plus a map from each character back to the text node it
        // came from — resolving an anchor means searching the first and
        // rebuilding a DOM Range through the second.
        function buildIndex(root) {
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

            var text = '';
            var map = [];
            var pending = null;
            var node;
            while ((node = walker.nextNode())) {
                var value = node.nodeValue || '';
                for (var i = 0; i < value.length; i++) {
                    // A soft hyphen is where the page may break a word, not a
                    // character of it; the stored text has none.
                    if (value[i] === '\\u00AD') { continue; }
                    if (/\\s/.test(value[i])) {
                        // A run of whitespace becomes at most one space, and
                        // only after something has been emitted.
                        if (text.length && !pending) { pending = { node: node, offset: i }; }
                    } else {
                        if (pending) { text += ' '; map.push(pending); pending = null; }
                        text += value[i];
                        map.push({ node: node, offset: i });
                    }
                }
            }
            return { text: text, map: map };
        }

        function normalize(text) {
            return text.replace(/\\u00AD/g, '').replace(/\\s+/g, ' ').trim();
        }

        function leadingOverlap(pattern, candidate) {
            if (!pattern.length || !candidate.length) { return 0; }
            var matched = 0;
            while (matched < pattern.length && matched < candidate.length &&
                   pattern[matched] === candidate[matched]) { matched++; }
            return matched / pattern.length;
        }

        function trailingOverlap(pattern, candidate) {
            if (!pattern.length || !candidate.length) { return 0; }
            var matched = 0;
            while (matched < pattern.length && matched < candidate.length &&
                   pattern[pattern.length - 1 - matched] === candidate[candidate.length - 1 - matched]) {
                matched++;
            }
            return matched / pattern.length;
        }

        // Mirrors ReaderTextAnchor.score: context agreement dominates, the
        // recorded offset only separates otherwise equal candidates.
        function score(haystack, start, length, prefix, suffix, expectedOffset) {
            var value = 0;
            if (prefix.length) {
                value += CONTEXT_WEIGHT * trailingOverlap(
                    prefix, haystack.slice(Math.max(0, start - prefix.length), start)
                );
            }
            if (suffix.length) {
                var afterStart = start + length;
                value += CONTEXT_WEIGHT * leadingOverlap(
                    suffix, haystack.slice(afterStart, afterStart + suffix.length)
                );
            }
            return value + 1 / (1 + Math.abs(start - expectedOffset) / 500);
        }

        function resolve(index, item) {
            var needle = normalize(item.exact || '');
            if (!needle) { return null; }
            var prefix = normalize(item.prefix || '');
            var suffix = normalize(item.suffix || '');
            var offset = item.offset || 0;

            var best = -1;
            var bestScore = -1;
            var from = 0;
            var found;
            var seen = 0;
            while ((found = index.text.indexOf(needle, from)) !== -1 && seen < 64) {
                var value = score(index.text, found, needle.length, prefix, suffix, offset);
                if (value > bestScore) { bestScore = value; best = found; }
                from = found + 1;
                seen++;
            }
            if (best < 0) { return null; }

            var head = index.map[best];
            var tail = index.map[best + needle.length - 1];
            if (!head || !tail) { return null; }
            try {
                var range = document.createRange();
                range.setStart(head.node, head.offset);
                range.setEnd(tail.node, tail.offset + 1);
                return range;
            } catch (e) {
                return null;
            }
        }

        function clearHighlights() {
            var marked = document.querySelectorAll('img[data-foreverlm-note]');
            for (var m = 0; m < marked.length; m++) {
                marked[m].removeAttribute('data-foreverlm-note');
                marked[m].removeAttribute('data-foreverlm-note-color');
            }
            if (!window.CSS || !CSS.highlights) { return; }
            for (var i = 0; i < COLORS.length; i++) {
                CSS.highlights.delete('foreverlm-note-' + COLORS[i]);
            }
        }

        function fileName(url) {
            try {
                var parts = new URL(url, document.baseURI).pathname.split('/');
                return decodeURIComponent(parts[parts.length - 1] || '');
            } catch (e) {
                return '';
            }
        }

        // The page's <img> for a marked picture. Mirrors ReaderImageAnchor's
        // contract: the URL it was marked at wins; failing that, the file the
        // URL named, with the alt text breaking a tie; a file name several
        // pictures share and no alt to tell them apart resolves nothing
        // rather than the wrong picture.
        function resolvePicture(wanted, taken, root) {
            var imgs = root === document.body ? document.images : root.querySelectorAll('img');
            var byFile = [];
            for (var i = 0; i < imgs.length; i++) {
                var img = imgs[i];
                if (taken.indexOf(img) !== -1) { continue; }
                var srcs = [img.currentSrc, img.src, img.getAttribute('src')];
                for (var j = 0; j < srcs.length; j++) {
                    if (srcs[j] && srcs[j] === wanted.src) { return img; }
                }
                var file = wanted.file || fileName(wanted.src);
                if (file && (fileName(img.currentSrc || '') === file || fileName(img.src || '') === file)) {
                    byFile.push(img);
                }
            }
            if (byFile.length === 1) { return byFile[0]; }
            for (var k = 0; k < byFile.length; k++) {
                if ((byFile[k].getAttribute('alt') || '') === (wanted.alt || '')) { return byFile[k]; }
            }
            return null;
        }

        // A mark with a scope lives in that chapter's section of a book read
        // as one page, and its anchor was measured in that section's text.
        // A scope the page does not hold resolves nothing rather than
        // landing in some other chapter.
        function scopeRoot(scope) {
            if (!scope) { return document.body; }
            var sections = document.querySelectorAll('[data-flm-chapter]');
            for (var i = 0; i < sections.length; i++) {
                if (sections[i].getAttribute('data-flm-chapter') === scope) { return sections[i]; }
            }
            return null;
        }

        window.foreverLMApplyHighlights = function(items) {
            entries = [];
            clearHighlights();
            if (!items || !items.length || !document.body) { return; }
            installStyle();

            var indexes = {};
            var byColor = {};
            var taken = [];
            for (var i = 0; i < items.length; i++) {
                var scope = items[i].scope || '';
                if (!indexes.hasOwnProperty(scope)) {
                    var scopedRoot = scopeRoot(scope);
                    indexes[scope] = scopedRoot ? { root: scopedRoot, index: buildIndex(scopedRoot) } : null;
                }
                var scoped = indexes[scope];
                if (!scoped) { continue; }
                var color = items[i].color || 'yellow';
                var range = resolve(scoped.index, items[i]);
                var pictures = [];
                var wantedPictures = items[i].images || [];
                for (var w = 0; w < wantedPictures.length; w++) {
                    var img = resolvePicture(wantedPictures[w], taken, scoped.root);
                    if (!img) { continue; }
                    taken.push(img);
                    pictures.push(img);
                    img.setAttribute('data-foreverlm-note', items[i].id);
                    img.setAttribute('data-foreverlm-note-color', color);
                }
                if (!range && !pictures.length) { continue; }
                entries.push({ id: items[i].id, range: range, pictures: pictures });
                if (range) { (byColor[color] = byColor[color] || []).push(range); }
            }

            // Without the Custom Highlight API the notes still exist and the
            // notes list still works; only the in-page tint is missing.
            if (!window.CSS || !CSS.highlights || typeof Highlight === 'undefined') { return; }
            for (var color in byColor) {
                if (!byColor.hasOwnProperty(color)) { continue; }
                try {
                    var group = new Highlight();
                    for (var j = 0; j < byColor[color].length; j++) {
                        group.add(byColor[color][j]);
                    }
                    CSS.highlights.set('foreverlm-note-' + color, group);
                } catch (e) {}
            }
        };

        window.foreverLMRevealHighlight = function(id) {
            for (var i = 0; i < entries.length; i++) {
                if (entries[i].id !== id) { continue; }
                var target = entries[i].range || entries[i].pictures[0];
                var rect = target ? target.getBoundingClientRect() : null;
                if (!rect) { return; }
                window.scrollTo({
                    top: window.scrollY + rect.top - (window.innerHeight / 3),
                    behavior: 'smooth'
                });
                return;
            }
        };

        // Clicking a marked passage opens its note. Hit-testing goes through
        // the caret position because CSS highlights are paint-only and cannot
        // receive events themselves.
        document.addEventListener('click', function(event) {
            if (!entries.length) { return; }
            var sel = window.getSelection();
            if (sel && !sel.isCollapsed) { return; }
            // A marked picture is an element and takes the click itself.
            var target = event.target;
            if (target && target.getAttribute && target.getAttribute('data-foreverlm-note')) {
                post({
                    type: 'openNote',
                    highlightId: target.getAttribute('data-foreverlm-note'),
                    rect: boxPayload(target.getBoundingClientRect())
                });
                return;
            }
            if (!document.caretRangeFromPoint) { return; }
            var caret = document.caretRangeFromPoint(event.clientX, event.clientY);
            if (!caret) { return; }
            for (var i = 0; i < entries.length; i++) {
                if (!entries[i].range) { continue; }
                try {
                    if (entries[i].range.comparePoint(caret.startContainer, caret.startOffset) === 0) {
                        // The mark's box, so its card hangs below the whole
                        // passage rather than the line that was clicked.
                        post({
                            type: 'openNote',
                            highlightId: entries[i].id,
                            rect: boxPayload(entries[i].range.getBoundingClientRect())
                        });
                        return;
                    }
                } catch (e) {}
            }
        });

        function boxPayload(box) {
            if (!box || (box.width <= 0 && box.height <= 0)) { return null; }
            return { top: box.top, left: box.left, right: box.right, bottom: box.bottom };
        }
    })();
    """
}
