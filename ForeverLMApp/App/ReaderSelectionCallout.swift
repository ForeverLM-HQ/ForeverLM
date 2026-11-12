import AppKit
import PDFKit
import SwiftUI
import WebKit

/// The actions that follow the reader's selection: "Chat", spelled out as the
/// bar's one primary action, then "Side chat" and "Highlight" as glyphs that
/// name themselves on hover and to VoiceOver (Quiet chrome,
/// docs/ui-design.md: ChatGPT's bar over a selection is one
/// labelled button). A
/// selection is words, pictures, or both: a drag over a web page's figure with
/// no words in it summons the same bar, Chat attaches the figure to the
/// message, and Highlight marks the picture (`ReaderSelectionImage`). Side
/// chat asks about words, so a selection of pictures alone does not offer it.
///
/// Side chat is the popover a reply's selection bar opens in a chat
/// (`ChatReplySideChat`), hung off the passage in the page (product owner,
/// 2026-09-29: "shoudl also have a side chat option here just like for within
/// a chat"): a question about these words answered beside them, with no new
/// chat started (`StudioViewModel.openReaderSideChat`).
///
/// They appear as a small bar hugging the selection itself, not in the reader
/// toolbar far from the words the reader just highlighted: above the highlighted passage when there is room, below it when the
/// selection starts at the top of the viewport, always clear of the text it
/// refers to.
///
/// Web readers draw the bar inside the page (shadow DOM, so page CSS can't
/// reach it) — that way it tracks scrolling, reflow and zoom for free. PDFs and
/// plain-text chapters get the same bar as a SwiftUI view hosted over the
/// AppKit reader.
enum ReaderSelectionCallout {
    static let chatLabel = "Chat"
    static let sideChatLabel = "Side chat"
    static let highlightLabel = "Highlight"

    /// Routes a pill press through the same path as ⇧⌘K, which chats about
    /// whatever the active reader selection is.
    static func requestChat() {
        NotificationCenter.default.post(name: .toggleStudioAssistant, object: nil)
    }
}

// MARK: - Web readers

/// The portable anchor a web reader reports for a marked selection.
///
/// The page computes it because only the page knows its own text: the offset is
/// measured in the same whitespace-collapsed projection `ReaderTextAnchor` uses,
/// so an anchor made here resolves against text extracted anywhere else. A
/// selection over pictures carries them too; one over pictures alone has an
/// empty passage and is anchored by the pictures.
struct ReaderWebSelectionAnchor {
    var text: String
    var prefix: String
    var suffix: String
    var offset: Int
    var images: [ReaderSelectionImage]
    /// The selection's box in the page's viewport, in CSS pixels, so the
    /// card that follows the mark can hang below it. See
    /// `ReaderWebViewportRect`.
    var viewportRect: CGRect?
    /// The chapter the selection is in, when the page is an EPUB book read as
    /// one document; nil for a page that is one source.
    var scope: String?

    init?(payload: [String: Any]) {
        let text = payload["text"] as? String ?? ""
        let images = ReaderSelectionImage.list(from: payload["images"])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return nil }
        self.text = text
        self.images = images
        prefix = payload["prefix"] as? String ?? ""
        suffix = payload["suffix"] as? String ?? ""
        offset = payload["offset"] as? Int ?? 0
        viewportRect = ReaderWebViewportRect.parse(payload["rect"])
        scope = ReaderSelectionMessage.scope(in: payload)
    }

    var anchor: ReaderTextAnchor {
        ReaderTextAnchor(exact: text, prefix: prefix, suffix: suffix, offset: offset)
    }

    var imageAnchors: [ReaderImageAnchor] { images.map(\.anchor) }
}

/// A box a reader page measured in its viewport — `getBoundingClientRect`,
/// CSS pixels, y growing downward — and its way onto the screen.
///
/// The page's pixels are the web view's points scaled by the reader's page
/// zoom (`ReaderSelectionImageResolver` photographs pictures by the same
/// rule), and the screen is the one coordinate space every reader engine can
/// reach, which is why the highlight card asks for the mark there.
enum ReaderWebViewportRect {
    /// The `{top, left, right, bottom}` object the page's scripts post.
    static func parse(_ value: Any?) -> CGRect? {
        guard let box = value as? [String: Any],
              let top = (box["top"] as? NSNumber)?.doubleValue,
              let left = (box["left"] as? NSNumber)?.doubleValue,
              let right = (box["right"] as? NSNumber)?.doubleValue,
              let bottom = (box["bottom"] as? NSNumber)?.doubleValue,
              right > left, bottom > top
        else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// `cssRect` in screen coordinates, or nil when the web view is not on
    /// screen to convert through.
    @MainActor
    static func onScreen(_ cssRect: CGRect?, in webView: WKWebView?) -> CGRect? {
        guard let cssRect, let webView else { return nil }
        let zoom = webView.pageZoom
        var inView = CGRect(
            x: cssRect.minX * zoom,
            y: cssRect.minY * zoom,
            width: cssRect.width * zoom,
            height: cssRect.height * zoom
        )
        if !webView.isFlipped {
            inView.origin.y = webView.bounds.height - inView.maxY
        }
        return webView.screenFrame(of: inView)
    }
}

extension NSView {
    /// `rect`, in this view's coordinates, on the screen — nil until the view
    /// is in a window.
    func screenFrame(of rect: CGRect) -> CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(rect, to: nil))
    }
}

/// What a reader web view reports back over its selection message handler.
enum ReaderSelectionMessage {
    /// The user changed the selection (empty text and no pictures when they
    /// deselected).
    case selection(text: String, images: [ReaderSelectionImage])
    /// The user pressed the floating "Chat" pill.
    case chatRequest(text: String, images: [ReaderSelectionImage])
    /// The user pressed "Side chat", with the passage's box in the viewport
    /// when the page could measure it: the popover hangs off it.
    case sideChatRequest(text: String, viewportRect: CGRect?)
    /// The user pressed the "Highlight" pill, with the anchor the page
    /// computed.
    case highlightRequest(ReaderWebSelectionAnchor)
    /// The user clicked an already-painted highlight, by highlight ID, with
    /// the mark's box in the viewport when the page could measure it.
    case openNote(id: String, viewportRect: CGRect?)

    init?(body: Any) {
        // Older payloads were a bare selection string.
        if let text = body as? String {
            self = .selection(text: text, images: [])
            return
        }
        guard let payload = body as? [String: Any] else { return nil }
        switch payload["type"] as? String {
        case "highlightRequest":
            guard let anchor = ReaderWebSelectionAnchor(payload: payload) else { return nil }
            self = .highlightRequest(anchor)
        case "openNote":
            guard let id = payload["highlightId"] as? String, !id.isEmpty else { return nil }
            self = .openNote(id: id, viewportRect: ReaderWebViewportRect.parse(payload["rect"]))
        case "chatRequest":
            guard let text = payload["text"] as? String else { return nil }
            self = .chatRequest(text: text, images: ReaderSelectionImage.list(from: payload["images"]))
        case "sideChatRequest":
            guard let text = payload["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .sideChatRequest(text: text, viewportRect: ReaderWebViewportRect.parse(payload["rect"]))
        case "selection":
            guard let text = payload["text"] as? String else { return nil }
            self = .selection(text: text, images: ReaderSelectionImage.list(from: payload["images"]))
        default:
            return nil
        }
    }

    /// The chapter section the selection is in, when the page is an EPUB
    /// book read as one document: every source on it but the chapter itself
    /// would file the selection under the wrong chapter. Nil elsewhere.
    static func scope(in body: Any) -> String? {
        guard let scope = (body as? [String: Any])?["scope"] as? String, !scope.isEmpty else { return nil }
        return scope
    }

    /// The selected passage, for the cases that carry one.
    var text: String {
        switch self {
        case .selection(let text, _), .chatRequest(let text, _), .sideChatRequest(let text, _): return text
        case .highlightRequest(let anchor): return anchor.text
        case .openNote: return ""
        }
    }

    /// The pictures the selection covered, for the cases that carry them.
    var images: [ReaderSelectionImage] {
        switch self {
        case .selection(_, let images), .chatRequest(_, let images): return images
        case .highlightRequest(let anchor): return anchor.images
        case .sideChatRequest, .openNote: return []
        }
    }
}

/// Selection reporting plus the in-page pill, shared by every WebKit reader.
///
/// Reports selections only after an explicit user gesture (mouse-up / keyboard
/// selection) so find-in-page and search jumps don't surface the affordance.
enum ReaderSelectionCalloutJavaScript {
    /// - Parameter handlerName: the `window.webkit.messageHandlers` channel the
    ///   host reader already registers.
    static func injectionScript(handlerName: String) -> String {
        template.replacingOccurrences(of: "__FOREVERLM_HANDLER__", with: handlerName)
            .replacingOccurrences(of: "__FOREVERLM_CHAT_LABEL__", with: ReaderSelectionCallout.chatLabel)
            .replacingOccurrences(of: "__FOREVERLM_SIDE_CHAT_LABEL__", with: ReaderSelectionCallout.sideChatLabel)
            .replacingOccurrences(of: "__FOREVERLM_HIGHLIGHT_LABEL__", with: ReaderSelectionCallout.highlightLabel)
            .replacingOccurrences(of: "__FOREVERLM_CONTEXT__", with: String(ReaderTextAnchor.contextLength))
            .replacingOccurrences(of: "__FOREVERLM_PICTURE_LIMIT__", with: String(ReaderSelectionImage.maximumPerSelection))
    }

    private static let template = """
    (function() {
        if (window.foreverLMReaderUserSelectionInstalled) { return; }
        window.foreverLMReaderUserSelectionInstalled = true;

        var HANDLER = '__FOREVERLM_HANDLER__';
        var GAP = 8;
        var MARGIN = 8;
        var CONTEXT = __FOREVERLM_CONTEXT__;

        function post(payload) {
            try {
                window.webkit.messageHandlers[HANDLER].postMessage(payload);
            } catch (e) {}
        }

        // What a selection says, once the characters that only shape text
        // are gone: zero-width spaces and joiners (Webflow pages set them
        // between figures and captions) are not words, so a drag over a
        // picture alone reads as no words even when the page put one there.
        function words(text) {
            return (text || '').replace(/[\\u200B-\\u200D\\u2060\\uFEFF]/g, '').trim();
        }

        function selectionText() {
            var sel = window.getSelection();
            return sel ? words(sel.toString()) : '';
        }

        // The pictures the selection covers: the page's <img> elements the
        // live range intersects — a figure, an infographic, a diagram — in
        // page order, capped, with tracking pixels and spacers skipped by
        // size. The twin of ReaderSelectionImage on the Swift side, which
        // reads what describePictures posts.
        var PICTURE_LIMIT = __FOREVERLM_PICTURE_LIMIT__;
        function selectionPictures() {
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount === 0) { return []; }
            var range = sel.getRangeAt(0);
            var root = range.commonAncestorContainer;
            if (root && root.nodeType !== 1) { root = root.parentNode; }
            if (!root || !root.querySelectorAll) { return []; }
            var candidates = root.nodeName === 'IMG' ? [root] : root.querySelectorAll('img');
            var found = [];
            for (var i = 0; i < candidates.length && found.length < PICTURE_LIMIT; i++) {
                var img = candidates[i];
                if (!(img.currentSrc || img.src)) { continue; }
                try { if (!range.intersectsNode(img)) { continue; } } catch (e) { continue; }
                var box = img.getBoundingClientRect();
                if (box.width < 16 || box.height < 16) { continue; }
                found.push(img);
            }
            return found;
        }

        // What the app is told about each picture. The app fetches the bytes
        // itself, with the page's cookies; only a blob: picture, which nothing
        // outside the page can read, is handed over as a data URL — and only
        // when the canvas can read it back, which a cross-origin blob refuses.
        function describePictures(imgs) {
            var out = [];
            for (var i = 0; i < imgs.length; i++) {
                var img = imgs[i];
                var box = img.getBoundingClientRect();
                var src = img.currentSrc || img.src || '';
                out.push({
                    src: src,
                    alt: img.getAttribute('alt') || '',
                    width: img.naturalWidth || 0,
                    height: img.naturalHeight || 0,
                    left: box.left, top: box.top, right: box.right, bottom: box.bottom,
                    dataURL: pictureDataURL(img, src)
                });
            }
            return out;
        }

        function pictureDataURL(img, src) {
            if (src.indexOf('blob:') !== 0) { return null; }
            if (!img.complete || !img.naturalWidth || !img.naturalHeight) { return null; }
            if (img.naturalWidth * img.naturalHeight > 16000000) { return null; }
            try {
                var canvas = document.createElement('canvas');
                canvas.width = img.naturalWidth;
                canvas.height = img.naturalHeight;
                canvas.getContext('2d').drawImage(img, 0, 0);
                return canvas.toDataURL('image/png');
            } catch (e) {
                return null;
            }
        }

        function pictureKey(imgs) {
            var parts = [];
            for (var i = 0; i < imgs.length; i++) { parts.push(imgs[i].currentSrc || imgs[i].src || ''); }
            return parts.join('\\u001e');
        }

        // Must match ReaderTextAnchor.normalize on the Swift side: soft hyphens
        // go, runs of whitespace collapse to one space and both ends are
        // trimmed, so an offset measured here means the same thing when the
        // note is resolved against text extracted by any other reader.
        function normalize(text) {
            return text.replace(/\\u00AD/g, '').replace(/\\s+/g, ' ').trim();
        }

        /// The chapter section a selection starts in, when the page is an
        /// EPUB book read as one document (`data-flm-chapter`); null on every
        /// other page, which is one source from top to bottom.
        function selectionSection(range) {
            var node = range ? range.startContainer : null;
            var element = node && node.nodeType === 1 ? node : (node ? node.parentElement : null);
            return element && element.closest ? element.closest('[data-flm-chapter]') : null;
        }

        function selectionScope() {
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0) { return ''; }
            var section = selectionSection(sel.getRangeAt(0));
            return section ? section.getAttribute('data-flm-chapter') || '' : '';
        }

        /// The portable anchor for the live selection: the passage, a little
        /// text either side of it, and how far into the page it starts — into
        /// its chapter's section, in a book, because that section is the
        /// chapter's own text and the mark is the chapter's.
        function anchorPayload() {
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount === 0) { return null; }
            var range = sel.getRangeAt(0);
            var exact = sel.toString();
            // A selection that is only pictures still anchors: the passage is
            // empty and the context either side says where the picture sat.
            // A passage of shaping characters alone is that empty passage.
            if (!words(exact)) { exact = ''; }
            var pictures = describePictures(selectionPictures());
            if (!exact && !pictures.length) { return null; }

            var section = selectionSection(range);
            var root = section || document.body;
            var prefix = '';
            var suffix = '';
            var offset = 0;
            try {
                var before = document.createRange();
                before.setStart(root, 0);
                before.setEnd(range.startContainer, range.startOffset);
                var beforeText = before.toString();
                prefix = beforeText.slice(-CONTEXT);
                offset = normalize(beforeText).length;

                var after = document.createRange();
                after.setStart(range.endContainer, range.endOffset);
                after.setEnd(root, root.childNodes.length);
                suffix = after.toString().slice(0, CONTEXT);
            } catch (e) {
                // A selection spanning shadow or frame boundaries can refuse
                // these ranges. The passage alone still anchors, just without
                // the context that disambiguates repeats.
            }
            return {
                type: 'highlightRequest',
                scope: section ? section.getAttribute('data-flm-chapter') || '' : '',
                text: exact,
                prefix: prefix,
                suffix: suffix,
                offset: offset,
                images: pictures,
                // Where the passage is, so the card that follows the mark can
                // hang below it rather than over it.
                rect: boxPayload(selectionRect())
            };
        }

        function boxPayload(box) {
            if (!box) { return null; }
            return { top: box.top, left: box.left, right: box.right, bottom: box.bottom };
        }

        var host = null;
        var pill = null;
        var placeFrame = null;

        function buildPill() {
            if (host && host.isConnected) { return; }
            host = document.createElement('div');
            host.setAttribute('data-foreverlm-selection-callout', '');
            // width:max-content so the shadow buttons lay out at their natural
            // size instead of shrink-to-fitting inside a zero-width host.
            host.style.cssText = 'position:fixed;top:0;left:0;width:max-content;height:auto;' +
                'margin:0;padding:0;border:0;z-index:2147483647;display:none;';
            var root = host.attachShadow({ mode: 'open' });
            root.innerHTML =
                '<style>' +
                ':host { all: initial; }' +
                '.bar {' +
                '  all: unset; box-sizing: border-box; display: inline-flex; align-items: stretch;' +
                '  border-radius: 999px; overflow: hidden;' +
                '  box-shadow: 0 1px 2px rgba(0,0,0,.22), 0 6px 16px rgba(0,0,0,.20);' +
                '  opacity: 0; transform: translateY(3px) scale(.97);' +
                '  transition: opacity .13s ease-out, transform .13s ease-out;' +
                '}' +
                '.bar.visible { opacity: 1; transform: none; }' +
                '.pill {' +
                '  all: unset; box-sizing: border-box;' +
                '  display: inline-flex; align-items: center; gap: 5px;' +
                '  font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;' +
                '  font-size: 12px; font-weight: 600; line-height: 1; letter-spacing: .01em;' +
                '  white-space: nowrap; color: #fff; cursor: default;' +
                '  padding: 7px 11px 7px 9px;' +
                '  background: rgba(10, 110, 235, 0.97);' +
                '}' +
                '.pill:hover { background: rgba(0, 96, 214, 0.99); }' +
                '.pill:active { background: rgba(0, 82, 186, 1); }' +
                // A hairline keeps the two actions readable as separate targets
                // without splitting the bar into two floating pills.
                '.pill + .pill { box-shadow: inset 1px 0 0 rgba(255,255,255,.28); }' +
                // Side chat and Highlight are glyphs, named by their title
                // and aria-label; Chat alone is spelled out.
                '.pill.icon { padding: 7px 9px; }' +
                'svg { width: 13px; height: 13px; fill: currentColor; }' +
                '</style>' +
                '<div class="bar">' +
                '<button type="button" class="pill" data-action="chat" aria-label="__FOREVERLM_CHAT_LABEL__">' +
                '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2C4.4 2 1.5 4.3 1.5 7.2' +
                'c0 1.7 1 3.2 2.6 4.2-.1.7-.5 1.6-1.2 2.3 1.3-.2 2.4-.7 3.2-1.4.6.1 1.2.2 1.9.2' +
                'C11.6 12.5 14.5 10.2 14.5 7.2S11.6 2 8 2z"/></svg>' +
                '<span>__FOREVERLM_CHAT_LABEL__</span></button>' +
                // Hidden while the selection has no words: a side chat is a
                // question about words, and a figure alone goes to Chat.
                '<button type="button" class="pill icon" data-action="sideChat" aria-label="__FOREVERLM_SIDE_CHAT_LABEL__" title="__FOREVERLM_SIDE_CHAT_LABEL__">' +
                '<svg viewBox="0 0 16 16" aria-hidden="true"><path fill-rule="evenodd" d="M3.5 2.5h9a2 2 0 0 1 2 2v7' +
                'a2 2 0 0 1-2 2h-9a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2zm0 1.3a.7.7 0 0 0-.7.7v7c0 .39.31.7.7.7h3.85V3.8H3.5z' +
                'm5.15 0v8.4h3.85a.7.7 0 0 0 .7-.7v-7a.7.7 0 0 0-.7-.7H8.65z"/></svg>' +
                '</button>' +
                '<button type="button" class="pill icon" data-action="highlight" aria-label="__FOREVERLM_HIGHLIGHT_LABEL__" title="__FOREVERLM_HIGHLIGHT_LABEL__">' +
                '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M11.4 1.6c.4-.4 1-.4 1.4 0l1.6 1.6' +
                'c.4.4.4 1 0 1.4l-7.7 7.7-3 .6.6-3 7.1-8.3zM2 13.5h12v1.2H2z"/></svg>' +
                '</button>' +
                '</div>';
            var bar = root.querySelector('.bar');
            pill = bar;
            var buttons = root.querySelectorAll('.pill');
            for (var i = 0; i < buttons.length; i++) {
                var button = buttons[i];
                // Pressing a pill must not collapse the selection it acts on.
                button.addEventListener('mousedown', function(event) {
                    event.preventDefault();
                    event.stopPropagation();
                });
                button.addEventListener('click', function(event) {
                    event.preventDefault();
                    event.stopPropagation();
                    var action = this.getAttribute('data-action');
                    if (action === 'sideChat') {
                        // The words stay selected, as Chat leaves them: the
                        // popover is about them, and hangs off their box.
                        var asked = selectionText();
                        if (asked) {
                            post({
                                type: 'sideChatRequest',
                                scope: selectionScope(),
                                text: asked,
                                rect: boxPayload(selectionRect())
                            });
                        }
                        hide();
                        return;
                    }
                    if (action === 'highlight') {
                        var payload = anchorPayload();
                        if (payload) { post(payload); }
                        // Drop the selection so the mark about to be painted is
                        // what the reader sees, not the blue band over it. The
                        // anchor is already computed, so nothing needs it now.
                        try { window.getSelection().removeAllRanges(); } catch (e) {}
                    } else {
                        post({
                            type: 'chatRequest',
                            scope: selectionScope(),
                            text: selectionText(),
                            images: describePictures(selectionPictures())
                        });
                    }
                    hide();
                });
            }
            document.body.appendChild(host);
        }

        function selectionRect() {
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount === 0) { return null; }
            var rects = Array.prototype.slice.call(sel.getRangeAt(0).getClientRects());
            // A picture the range covers is a box too, whether or not the
            // range's own rects listed it (they do not when its whole parent
            // is selected).
            var pictures = selectionPictures();
            for (var p = 0; p < pictures.length; p++) { rects.push(pictures[p].getBoundingClientRect()); }
            var union = null;
            for (var i = 0; i < rects.length; i++) {
                var r = rects[i];
                if (r.width <= 0 && r.height <= 0) { continue; }
                if (!union) {
                    union = { top: r.top, left: r.left, right: r.right, bottom: r.bottom };
                } else {
                    union.top = Math.min(union.top, r.top);
                    union.left = Math.min(union.left, r.left);
                    union.right = Math.max(union.right, r.right);
                    union.bottom = Math.max(union.bottom, r.bottom);
                }
            }
            return union;
        }

        function hide() {
            if (!host) { return; }
            host.style.display = 'none';
            if (pill) { pill.classList.remove('visible'); }
        }

        function place() {
            var rect = selectionRect();
            if (!rect) { hide(); return; }
            buildPill();

            host.style.display = 'block';
            var sideChat = host.shadowRoot.querySelector('[data-action="sideChat"]');
            if (sideChat) {
                sideChat.style.display = selectionText() ? 'inline-flex' : 'none';
            }
            var width = pill.offsetWidth;
            var height = pill.offsetHeight;
            var viewWidth = document.documentElement.clientWidth || window.innerWidth || 0;
            var viewHeight = window.innerHeight || document.documentElement.clientHeight || 0;

            // Centered on the passage, clamped so it never hangs off the page.
            var left = (rect.left + rect.right) / 2 - width / 2;
            left = Math.max(MARGIN, Math.min(left, viewWidth - width - MARGIN));

            // Above the passage by default: the reader's eyes and cursor are at
            // the end of the selection, and the line above is already read.
            var top = rect.top - height - GAP;
            if (top < MARGIN) {
                var below = rect.bottom + GAP;
                top = (below + height + MARGIN <= viewHeight) ? below : MARGIN;
            }

            host.style.transform = 'translate(' + Math.round(left) + 'px,' + Math.round(top) + 'px)';
            pill.classList.add('visible');
        }

        function schedulePlace() {
            if (placeFrame) { return; }
            placeFrame = requestAnimationFrame(function() {
                placeFrame = null;
                if (host && host.style.display !== 'none') { place(); }
            });
        }

        var lastSelection = '';
        function checkSelection() {
            var text = selectionText();
            var pictures = selectionPictures();
            var key = pictures.length ? text + '\\u001f' + pictureKey(pictures) : text;
            if (key !== lastSelection) {
                lastSelection = key;
                post({ type: 'selection', scope: selectionScope(), text: text, images: describePictures(pictures) });
            }
            if (text || pictures.length) { place(); } else { hide(); }
        }

        document.addEventListener('mouseup', function() { setTimeout(checkSelection, 50); });
        document.addEventListener('keyup', checkSelection);
        // A new drag or a click-away retires the pill immediately; it comes back
        // on mouse-up if that gesture produced a selection. Presses on the pill
        // itself are exempt — hiding it here would swallow its own click.
        document.addEventListener('mousedown', function(event) {
            if (!host) { return; }
            var path = event.composedPath ? event.composedPath() : [];
            if (path.indexOf(host) !== -1 || host.contains(event.target)) { return; }
            hide();
        }, true);
        document.addEventListener('selectionchange', function() {
            if (!selectionText() && !selectionPictures().length) {
                if (lastSelection !== '') {
                    lastSelection = '';
                    post({ type: 'selection', text: '', images: [] });
                }
                hide();
            }
        });
        window.addEventListener('scroll', schedulePlace, { passive: true });
        window.addEventListener('resize', schedulePlace, { passive: true });
    })();
    """
}

// MARK: - PDF readers

/// The same bar, drawn over a `PDFView` or `NSTextView` where there is no DOM
/// to inject into.
private struct ReaderSelectionPill: View {
    var chatAction: () -> Void
    /// nil when the reader hosting the bar has no side chat to open.
    var sideChatAction: (() -> Void)?
    var highlightAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            pill(ReaderSelectionCallout.chatLabel, systemImage: "text.bubble.fill", action: chatAction)
            // A hairline divider, matching the web bar: several targets, one object.
            if let sideChatAction {
                divider
                iconPill(
                    ReaderSelectionCallout.sideChatLabel,
                    systemImage: ChatReplySelectionAction.sideChat.symbolName,
                    action: sideChatAction
                )
            }
            divider
            iconPill(ReaderSelectionCallout.highlightLabel, systemImage: "highlighter", action: highlightAction)
        }
        .background(Color.accentColor, in: Capsule())
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.28))
            .frame(width: 1)
    }

    private func pill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.leading, 9)
                .padding(.trailing, 11)
                .padding(.vertical, 7)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.14))
    }

    /// Side chat and Highlight: the glyph alone, named on hover and to
    /// VoiceOver.
    private func iconPill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.14))
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Keeps a "Chat" pill positioned over an AppKit reader's selection.
///
/// The host supplies the selection rect in its own coordinates; placement,
/// hosting and scroll tracking are the same for every reader that has no DOM to
/// draw the pill into (PDFs, plain-text chapters).
final class ReaderSelectionCalloutOverlay {
    /// Invoked when the reader presses Highlight. The host supplies this
    /// because only it knows which source the selection belongs to and how to
    /// turn the AppKit selection into an anchor.
    var onHighlight: (() -> Void)?
    /// Invoked when the reader presses Side chat, for the same reason. A host
    /// that leaves it nil draws no Side chat.
    var onSideChat: (() -> Void)?

    private weak var container: NSView?
    private var hostingView: NSHostingView<ReaderSelectionPill>?
    private var scrollObserver: NSObjectProtocol?
    /// The current selection's rect in the container's coordinates, if any.
    private var selectionRect: (() -> CGRect?)?
    /// Set when the container's own coordinates shift as the reader scrolls, so
    /// the pill has to be replaced rather than riding along with the content.
    private var tracksScrolling = false
    /// The selection the bar was last placed on, in the container's
    /// coordinates: what a Highlight press is about even if the press itself
    /// has since disturbed the live selection.
    private var placedSelection: CGRect?

    func attach(
        to container: NSView,
        selectionRect: @escaping () -> CGRect?,
        tracksScrolling: Bool
    ) {
        self.container = container
        self.selectionRect = selectionRect
        self.tracksScrolling = tracksScrolling
        if tracksScrolling { observeScrolling() }
    }

    func detach() {
        stopObservingScrolling()
        hostingView?.removeFromSuperview()
        hostingView = nil
        container = nil
        selectionRect = nil
    }

    /// Recomputes placement from the current selection. Safe to call on every
    /// selection, scroll, scale or page change.
    func refresh() {
        guard let container, let rect = selectionRect?(), !rect.isNull, !rect.isEmpty else {
            hide()
            return
        }

        // PDFKit builds its scroll view lazily, so the first selection is the
        // reliable moment to start tracking scrolls if attach() was too early.
        if tracksScrolling, scrollObserver == nil { observeScrolling() }

        placedSelection = rect
        let pill = ensureHostingView(in: container)
        pill.rootView.sideChatAction = onSideChat == nil ? nil : { [weak self] in self?.onSideChat?() }
        pill.isHidden = false
        let size = pill.fittingSize
        pill.frame = CGRect(origin: origin(for: rect, size: size, in: container), size: size)
    }

    /// Repositions only when the pill is already on screen, so a scroll or zoom
    /// never surfaces it for a selection the user didn't just make.
    func refreshIfVisible() {
        guard hostingView?.isHidden == false else { return }
        refresh()
    }

    func hide() {
        hostingView?.isHidden = true
    }

    /// The passage the bar is about, in screen coordinates, for the card
    /// that follows a Highlight press: it hangs below the passage, not off the
    /// pill. The live selection when there still is one, otherwise the one the
    /// bar was placed on.
    func selectionOnScreen() -> CGRect? {
        guard let container else { return nil }
        let live = selectionRect?() ?? nil
        guard let rect = live ?? placedSelection, !rect.isNull, !rect.isEmpty else { return nil }
        return container.screenFrame(of: rect)
    }

    // MARK: Placement

    private func origin(for selection: CGRect, size: CGSize, in container: NSView) -> CGPoint {
        let visible = container.visibleRect.isEmpty ? container.bounds : container.visibleRect
        let gap: CGFloat = 8
        let margin: CGFloat = 8

        var x = selection.midX - size.width / 2
        x = max(visible.minX + margin, min(x, visible.maxX - size.width - margin))

        // Sit above the passage, dropping below it when the selection starts at
        // the top edge. Which end of the rect is "above" depends on whether the
        // reader hands us a flipped view, so ask rather than assume.
        let onScreenAbove = container.isFlipped
            ? selection.minY - gap - size.height
            : selection.maxY + gap
        let onScreenBelow = container.isFlipped
            ? selection.maxY + gap
            : selection.minY - gap - size.height

        var y = onScreenAbove
        if y < visible.minY + margin || y + size.height > visible.maxY - margin {
            y = onScreenBelow
        }
        y = max(visible.minY + margin, min(y, visible.maxY - size.height - margin))
        return CGPoint(x: x, y: y)
    }

    private func ensureHostingView(in container: NSView) -> NSHostingView<ReaderSelectionPill> {
        if let hostingView, hostingView.superview === container {
            // A container that keeps adding views of its own (a SwiftUI scroll
            // document growing new paragraphs) would otherwise stack them over
            // the bar, where they take its clicks.
            if container.subviews.last !== hostingView {
                container.addSubview(hostingView, positioned: .above, relativeTo: nil)
            }
            return hostingView
        }
        hostingView?.removeFromSuperview()
        let pill = NSHostingView(
            rootView: ReaderSelectionPill(
                chatAction: { ReaderSelectionCallout.requestChat() },
                sideChatAction: nil,
                highlightAction: { [weak self] in self?.onHighlight?() }
            )
        )
        pill.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(pill)
        hostingView = pill
        return pill
    }

    // MARK: Scrolling

    private func observeScrolling() {
        stopObservingScrolling()
        guard let clipView = (container as? PDFView)?.enclosedScrollView?.contentView
            ?? container?.enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshIfVisible()
        }
    }

    private func stopObservingScrolling() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        scrollObserver = nil
    }
}

extension ReaderSelectionCalloutOverlay {
    /// Anchors the pill to a PDF view's selection. PDFKit reports selection
    /// bounds in view space, which shifts under scrolling, so the pill is
    /// replaced as the document moves.
    func attach(toPDFView pdfView: PDFView) {
        attach(
            to: pdfView,
            selectionRect: { [weak pdfView] in
                guard let pdfView,
                      let selection = pdfView.currentSelection,
                      !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                var union: CGRect?
                for page in selection.pages {
                    let pageBounds = selection.bounds(for: page)
                    guard !pageBounds.isNull, !pageBounds.isEmpty else { continue }
                    let viewBounds = pdfView.convert(pageBounds, from: page)
                    union = union.map { $0.union(viewBounds) } ?? viewBounds
                }
                return union
            },
            tracksScrolling: true
        )
    }

    /// Anchors the pill to a text view's selection. The pill lives in the text
    /// view's own (document) coordinates, so it rides along as the reader
    /// scrolls without any repositioning.
    func attach(toTextView textView: NSTextView) {
        attach(
            to: textView,
            selectionRect: { [weak textView] in
                guard let textView,
                      let layoutManager = textView.layoutManager,
                      let textContainer = textView.textContainer else { return nil }
                let range = textView.selectedRange()
                guard range.length > 0 else { return nil }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                let inset = textView.textContainerOrigin
                rect.origin.x += inset.x
                rect.origin.y += inset.y
                return rect
            },
            tracksScrolling: false
        )
    }
}

extension PDFView {
    /// PDFKit keeps its scroll view as a descendant rather than an ancestor.
    var enclosedScrollView: NSScrollView? {
        var queue: [NSView] = subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? NSScrollView { return scrollView }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
