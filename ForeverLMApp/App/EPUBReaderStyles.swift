#if os(macOS)
import Foundation

enum EPUBReaderStyles {
    static let css = """
    :root, html[data-flm-reader-theme="system"], html[data-flm-reader-theme="light"] {
        color-scheme: light dark;
        --flm-text: #1d1d1f;
        --flm-muted: #6e6e73;
        --flm-link: #0066cc;
        --flm-rule: #d1d1d6;
        --flm-code-bg: rgba(128,128,128,0.12);
    }
    html {
        margin: 0 !important;
        padding: 0 !important;
        background: transparent !important;
        -webkit-text-size-adjust: 100%;
    }
    body {
        font-family: Georgia, 'Times New Roman', serif;
        font-size: 18px;
        line-height: 1.66;
        box-sizing: border-box !important;
        width: min(100%, 780px) !important;
        max-width: 780px !important;
        min-height: 100vh;
        margin: 0 auto !important;
        padding: 34px clamp(24px, 5vw, 64px) 76px !important;
        color: var(--flm-text) !important;
        background: transparent !important;
        -webkit-font-smoothing: antialiased;
        overflow-wrap: break-word;
    }
    html[data-flm-reader-theme="light"] {
        color-scheme: light;
    }
    html[data-flm-reader-theme="dark"] {
        color-scheme: dark;
        --flm-text: #f5f5f7;
        --flm-muted: #a1a1aa;
        --flm-link: #5ac8fa;
        --flm-rule: #38383a;
        --flm-code-bg: rgba(255,255,255,0.12);
    }
    @media (prefers-color-scheme: dark) {
        html[data-flm-reader-theme="system"] {
            color-scheme: dark;
            --flm-text: #f5f5f7;
            --flm-muted: #a1a1aa;
            --flm-link: #5ac8fa;
            --flm-rule: #38383a;
            --flm-code-bg: rgba(255,255,255,0.12);
        }
    }
    body * { box-sizing: border-box; }
    body > *:first-child { margin-top: 0 !important; }
    h1, h2, h3, h4, h5, h6 {
        font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
        font-weight: 650;
        line-height: 1.25 !important;
        margin: 1.45em 0 0.55em !important;
        color: var(--flm-text) !important;
        text-align: start !important;
        clear: both;
    }
    h1 { font-size: 1.8em; }
    h2 { font-size: 1.45em; }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1.12em; }
    h5 { font-size: 1.05em; }
    h6 { font-size: 1em; }
    p {
        margin: 0.82em 0 !important;
        padding: 0 !important;
        line-height: 1.66 !important;
        text-align: start !important;
        color: var(--flm-text) !important;
    }
    p.indent { text-indent: 1.2em !important; }
    p.nonindent, p.noindent { text-indent: 0 !important; }
    .flm-epub-hidden,
    .pagenum, span.page, a.page,
    [role="doc-pagebreak"], [epub\\:type~="pagebreak"] {
        display: none !important;
    }
    .flm-epub-heading,
    .A_header1, .A_header2, .A_header3, .A_header,
    .B_header:not(.flm-epub-hidden),
    .chaptertitle, .chapter-title,
    .section-title, .sectiontitle, .secthead, .Heading,
    .title, .subtitle,
    [epub\\:type="title"], [epub\\:type="subtitle"],
    [role="doc-subtitle"],
    p[class*="head_"], div[class*="head_"],
    p[class*="Head_"], div[class*="Head_"],
    p[class*="header"]:not(.flm-epub-hidden),
    div[class*="header"]:not(.flm-epub-hidden),
    [class*="A_header"]:not(.flm-epub-hidden),
    hgroup p {
        display: block !important;
        font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif !important;
        font-weight: 650 !important;
        line-height: 1.22 !important;
        text-align: start !important;
        color: var(--flm-text) !important;
        clear: both;
    }
    .A_header1, .chaptertitle, .chapter-title, h1, [class*="A_header1"],
    .flm-epub-chapter-heading {
        font-size: 1.65em !important;
        margin: 0 0 1.1em !important;
    }
    .flm-epub-chapter-heading {
        margin-top: 1.75em !important;
    }
    .flm-epub-section-heading,
    .A_header2, .B_header:not(.flm-epub-hidden), h2,
    p.head_b, div.head_b, [class*="A_header2"], [class*="head_b"] {
        font-size: 1.35em !important;
        margin: 1.65em 0 0.65em !important;
    }
    .A_header3, h3, p.head_c, div.head_c, [class*="A_header3"], [class*="head_c"] {
        font-size: 1.18em !important;
        margin: 1.35em 0 0.5em !important;
    }
    .A_header, .subtitle, [epub\\:type="subtitle"], [role="doc-subtitle"] {
        font-size: 1.15em !important;
        margin: 1.25em 0 0.55em !important;
    }
    .dropcaps, .dropcap, .dropcaps1line, .dropcaps2line, .dropcaps3line {
        float: left !important;
        display: block !important;
        font-size: 3.1em !important;
        line-height: 0.82 !important;
        margin: 0.08em 0.1em 0 0 !important;
        padding: 0 !important;
        font-family: Georgia, 'Times New Roman', serif !important;
    }
    .small { font-variant: small-caps; letter-spacing: 0.02em; }
    blockquote {
        margin: 1em 0;
        padding: 0.5em 1.2em;
        border-left: 3px solid var(--flm-rule);
        color: var(--flm-muted);
        font-style: italic;
    }
    ul, ol { padding-left: 1.5em; }
    li { margin: 0.3em 0; }
    a { color: var(--flm-link) !important; text-decoration: none; }
    figure, .figure, .image, .imagecaption, .caption {
        clear: both;
        margin: 1.35em auto !important;
        text-align: center !important;
        color: var(--flm-muted) !important;
    }
    div.page:has(img), div.page:has(svg), section.page:has(img), section.page:has(svg) {
        display: block !important;
        clear: both;
        margin: 1.35em auto !important;
        text-align: center !important;
    }
    figcaption, .caption, .imagecaption p {
        font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif !important;
        font-size: 0.88em !important;
        line-height: 1.4 !important;
        color: var(--flm-muted) !important;
        text-align: center !important;
    }
    img, svg, picture, video, object[type^="image/"] {
        max-width: 100% !important;
        height: auto !important;
        display: block !important;
        margin: 1em auto !important;
    }
    /* A Greek letter or arrow the publisher drew as a picture a line high,
       sitting in the sentence. The block rule above would break the equation
       across lines; `ReaderInlineGlyphScript` marks these. */
    img.flm-inline-glyph {
        display: inline !important;
        width: auto !important;
        height: auto !important;
        max-height: 1.4em !important;
        margin: 0 0.04em !important;
        vertical-align: baseline !important;
    }
    pre, code {
        font-family: Menlo, Monaco, monospace;
        font-size: 0.85em;
        background: var(--flm-code-bg);
        border-radius: 4px;
    }
    pre { padding: 12px; overflow-x: auto; }
    code { padding: 2px 4px; }
    hr { border: none; border-top: 1px solid var(--flm-rule); margin: 2em 0; }
    table { border-collapse: collapse; margin: 1em 0; width: 100%; }
    th, td { border: 1px solid var(--flm-rule); padding: 8px 12px; text-align: left; }
    ::selection { background: rgba(0, 102, 204, 0.3); }
    .flm-chapter-footer { margin: 3em 0 1.5em; padding-top: 1.25em; border-top: 1px solid var(--flm-rule); }
    .flm-chapter-next { display: flex; align-items: center; justify-content: space-between; gap: 16px;
        padding: 12px 14px; border-radius: 12px; cursor: pointer; color: var(--flm-text) !important;
        -webkit-user-select: none; user-select: none; }
    .flm-chapter-next:hover { background: var(--flm-code-bg); }
    .flm-chapter-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
    .flm-chapter-kicker { font-size: 0.75em; letter-spacing: 0.04em; text-transform: uppercase; color: var(--flm-muted) !important; }
    .flm-chapter-title { font-weight: 600; }
    .flm-chapter-arrow { color: var(--flm-muted) !important; font-size: 1.1em; }
    section.flm-book-chapter { display: block; }
    section.flm-book-chapter > *:first-child { margin-top: 0 !important; }
    section.flm-book-chapter + section.flm-book-chapter {
        margin-top: 4em !important;
        padding-top: 3em !important;
        border-top: 1px solid var(--flm-rule);
    }
    """

    /// The way on from the end of a chapter. A book chapter is its own document,
    /// so without this the page simply stopped and the reader had to go back up
    /// to the Contents menu to keep reading. The reader calls
    /// `__flmSetChapterFooter(title)` once it knows the next chapter (or `null`
    /// on the last one), and a click posts `chapterNavigation` back to it.
    static let chapterFooterScript = """
    (function() {
        if (window.__flmSetChapterFooter) { return; }
        var FOOTER_ID = 'foreverlm-chapter-footer';
        window.__flmSetChapterFooter = function(nextTitle) {
            var footer = document.getElementById(FOOTER_ID);
            if (!nextTitle) {
                if (footer) { footer.remove(); }
                return;
            }
            if (!footer) {
                footer = document.createElement('nav');
                footer.id = FOOTER_ID;
                footer.className = 'flm-chapter-footer';
                footer.setAttribute('aria-label', 'Chapter navigation');
                var button = document.createElement('div');
                button.className = 'flm-chapter-next';
                button.setAttribute('role', 'button');
                button.setAttribute('tabindex', '0');
                var text = document.createElement('span');
                text.className = 'flm-chapter-text';
                var kicker = document.createElement('span');
                kicker.className = 'flm-chapter-kicker';
                kicker.textContent = 'Next chapter';
                var title = document.createElement('span');
                title.className = 'flm-chapter-title';
                text.appendChild(kicker);
                text.appendChild(title);
                var arrow = document.createElement('span');
                arrow.className = 'flm-chapter-arrow';
                arrow.textContent = '\u{2192}';
                button.appendChild(text);
                button.appendChild(arrow);
                function go(event) {
                    event.preventDefault();
                    var handlers = window.webkit && window.webkit.messageHandlers;
                    if (handlers && handlers.chapterNavigation) {
                        handlers.chapterNavigation.postMessage('next');
                    }
                }
                button.addEventListener('click', go);
                button.addEventListener('keydown', function(event) {
                    if (event.key === 'Enter' || event.key === ' ') { go(event); }
                });
                footer.appendChild(button);
                (document.body || document.documentElement).appendChild(footer);
            }
            footer.querySelector('.flm-chapter-title').textContent = nextTitle;
        };
    })();
    """

    /// The page side of an EPUB book read as one document
    /// (`EPUBBookDocument`): one `section[data-flm-chapter]` per chapter.
    /// Inert on any other page.
    ///
    /// - Reports, over `bookPosition`, the chapter under the reading line a
    ///   quarter of the way down the window and how far through its section
    ///   that line is, plus — after a scroll the learner made — every chapter
    ///   read past since the last report.
    /// - `__flmBook.go(id, fraction, mode)` scrolls to a chapter and holds the
    ///   place while pictures and fonts above it finish loading, until the
    ///   learner scrolls. Reports wait until the place is let go, so a layout
    ///   still settling never moves the selection to another chapter.
    /// - A width change keeps the chapter and the fraction, which a fraction
    ///   of the whole book cannot: only some of it reflows.
    /// - A link to another chapter's file scrolls there instead of loading
    ///   that file over the book.
    static let bookScript = """
    (function() {
        if (window.__flmBook) { return; }
        var SELECTOR = 'section[data-flm-chapter]';
        if (!document.querySelector(SELECTOR)) { return; }
        window.__flmBookOwnsScroll = true;

        var READING_LINE = 0.25;
        var START_MARGIN = 12;
        var PIN_SETTLE = 1200;
        var PIN_LIMIT = 10000;
        var MAX_PASSED_STEP = 2;
        var sections = Array.prototype.slice.call(document.querySelectorAll(SELECTOR));
        var lastPosted = null;
        var lastPosition = null;
        var pin = null;
        var pinTimer = null;
        var scrollTimer = null;
        var userScrollPending = false;

        function viewportHeight() {
            return window.innerHeight || document.documentElement.clientHeight || 0;
        }
        function scrollTop() { return window.scrollY || window.pageYOffset || 0; }
        function documentHeight() {
            var doc = document.documentElement;
            var body = document.body;
            return Math.max(doc ? doc.scrollHeight : 0, body ? body.scrollHeight : 0);
        }
        function clamp(value) { return Math.max(0, Math.min(1, value)); }
        function chapterID(index) { return sections[index].getAttribute('data-flm-chapter'); }
        function indexOf(id) {
            for (var i = 0; i < sections.length; i++) {
                if (chapterID(i) === id) { return i; }
            }
            return -1;
        }

        function position() {
            if (!sections.length) { return null; }
            var height = viewportHeight();
            var line = height * READING_LINE;
            var maxScroll = Math.max(0, documentHeight() - height);
            // At the foot of the book the last chapter has been read to its
            // end, however short it is.
            if (maxScroll > 0 && scrollTop() >= maxScroll - 2) {
                return { index: sections.length - 1, fraction: 1 };
            }
            var index = 0;
            for (var i = 0; i < sections.length; i++) {
                if (sections[i].getBoundingClientRect().top <= line) { index = i; } else { break; }
            }
            var rect = sections[index].getBoundingClientRect();
            return { index: index, fraction: clamp((line - rect.top) / Math.max(1, rect.height)) };
        }

        function post(userInitiated) {
            if (pin) { return; }
            var current = position();
            if (!current) { return; }
            lastPosition = current;
            // Read past, not skipped: a short chapter can go by between two
            // reports, but End or a long drag of the scroller is no reading.
            var passed = [];
            if (userInitiated && lastPosted && current.index > lastPosted.index
                && current.index - lastPosted.index <= MAX_PASSED_STEP) {
                for (var i = lastPosted.index; i < current.index; i++) { passed.push(chapterID(i)); }
            }
            if (lastPosted && lastPosted.index === current.index && !passed.length
                && Math.abs(lastPosted.fraction - current.fraction) < 0.001) { return; }
            lastPosted = current;
            try {
                window.webkit.messageHandlers.bookPosition.postMessage({
                    chapter: chapterID(current.index),
                    fraction: current.fraction,
                    passed: passed,
                    userInitiated: !!userInitiated
                });
            } catch (e) {}
        }

        function applyPin() {
            if (!pin) { return; }
            var index = indexOf(pin.id);
            if (index < 0) { pin = null; return; }
            var rect = sections[index].getBoundingClientRect();
            var top = rect.top + scrollTop();
            var y = (pin.mode === 'start' || pin.fraction <= 0)
                ? top - START_MARGIN
                : top + pin.fraction * rect.height - viewportHeight() * READING_LINE;
            window.scrollTo(0, Math.max(0, y));
        }
        function releasePin() {
            if (pinTimer) { clearTimeout(pinTimer); pinTimer = null; }
            if (!pin) { return; }
            pin = null;
            post(false);
        }
        function holdPin() {
            if (!pin) { return; }
            if (pinTimer) { clearTimeout(pinTimer); }
            if (Date.now() > pin.deadline) { releasePin(); return; }
            pinTimer = setTimeout(releasePin, PIN_SETTLE);
        }
        function pinTo(id, fraction, mode) {
            if (indexOf(id) < 0) { return false; }
            pin = {
                id: id,
                fraction: clamp(Number(fraction) || 0),
                mode: mode === 'resume' ? 'resume' : 'start',
                deadline: Date.now() + PIN_LIMIT
            };
            applyPin();
            holdPin();
            return true;
        }

        if (window.ResizeObserver && document.body) {
            new ResizeObserver(function() {
                if (pin) { applyPin(); holdPin(); }
            }).observe(document.body);
        }

        function noteUserScroll() {
            userScrollPending = true;
            if (pin) {
                if (pinTimer) { clearTimeout(pinTimer); pinTimer = null; }
                pin = null;
            }
        }
        window.addEventListener('wheel', noteUserScroll, { passive: true });
        window.addEventListener('touchstart', noteUserScroll, { passive: true });
        window.addEventListener('mousedown', noteUserScroll, { passive: true });
        window.addEventListener('keydown', function(event) {
            var keys = ['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', 'Home', 'End', ' '];
            if (keys.indexOf(event.key) >= 0) { noteUserScroll(); }
        }, true);
        window.addEventListener('scroll', function() {
            if (scrollTimer) { return; }
            scrollTimer = setTimeout(function() {
                scrollTimer = null;
                var userInitiated = userScrollPending;
                userScrollPending = false;
                post(userInitiated);
            }, 120);
        }, { passive: true });

        var lastWidth = window.innerWidth;
        window.addEventListener('resize', function() {
            if (window.innerWidth === lastWidth) { return; }
            lastWidth = window.innerWidth;
            if (pin) { applyPin(); holdPin(); return; }
            var current = lastPosition || position();
            if (current) { pinTo(chapterID(current.index), current.fraction, 'resume'); }
        });

        // A link inside the book names a chapter file, often with a fragment
        // (the contents page, an endnote and its way back). Undefined for a
        // link that is not to a file, which the reader's own policy handles.
        function linkTarget(href) {
            var url;
            try { url = new URL(href, document.baseURI); } catch (e) { return undefined; }
            if (url.protocol !== 'file:' && url.protocol !== '\(EPUBBookScheme.name):') { return undefined; }
            var basePath = decodeURIComponent(new URL(document.baseURI).pathname).replace(/[^\\/]*$/, '');
            var path = decodeURIComponent(url.pathname);
            var relative = path.indexOf(basePath) === 0 ? path.slice(basePath.length) : '';
            var id = url.hash ? decodeURIComponent(url.hash.slice(1)) : '';
            var section = null;
            if (relative) {
                for (var i = 0; i < sections.length; i++) {
                    if (sections[i].getAttribute('data-flm-chapter-path') === relative) { section = sections[i]; break; }
                }
            }
            var element = null;
            if (id) {
                var selector = '[id="' + (window.CSS && CSS.escape ? CSS.escape(id) : id) + '"]';
                element = (section && section.querySelector(selector)) || document.getElementById(id);
            }
            return element || section || null;
        }
        function reveal(element) {
            var top = element.getBoundingClientRect().top + scrollTop();
            window.scrollTo(0, Math.max(0, top - START_MARGIN));
        }
        document.addEventListener('click', function(event) {
            if (event.defaultPrevented || event.button !== 0
                || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) { return; }
            var anchor = event.target && event.target.closest ? event.target.closest('a[href]') : null;
            if (!anchor) { return; }
            var target = linkTarget(anchor.getAttribute('href'));
            if (target === undefined) { return; }
            event.preventDefault();
            noteUserScroll();
            if (target) { reveal(target); }
        }, true);

        window.__flmBook = {
            go: pinTo,
            // Another scroll is about to take over — a citation, a note — so
            // the place a jump was holding must not pull the view back.
            release: function() {
                if (pinTimer) { clearTimeout(pinTimer); pinTimer = null; }
                pin = null;
            },
            open: function(href) {
                var target = linkTarget(href);
                if (!target) { return false; }
                noteUserScroll();
                reveal(target);
                return true;
            },
            position: function() {
                var current = position();
                return current ? { chapter: chapterID(current.index), fraction: current.fraction } : null;
            }
        };
    })();
    """

    static func injectionScript(theme: ReaderColorTheme, extendedMediaNormalization: Bool) -> String {
        let mediaNormalization = extendedMediaNormalization ? extendedMediaNormalizationJS : basicMediaNormalizationJS
        let escapedCSS = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return """
        (function() {
            function applyReaderTheme(theme, colorScheme) {
                document.documentElement.setAttribute('data-flm-reader-theme', theme);
                document.documentElement.style.setProperty('color-scheme', colorScheme);
            }
            function normalizeImageDataURI(value) {
                if (!value) { return value; }
                return value
                    .replace(/data:image\\/\\.(?:jpg|jpeg);base64,/gi, 'data:image/jpeg;base64,')
                    .replace(/data:image\\/jpg;base64,/gi, 'data:image/jpeg;base64,')
                    .replace(/data:image\\/\\.png;base64,/gi, 'data:image/png;base64,')
                    .replace(/data:image\\/\\.gif;base64,/gi, 'data:image/gif;base64,')
                    .replace(/data:image\\/\\.webp;base64,/gi, 'data:image/webp;base64,')
                    .replace(/data:image\\/\\.svg\\+xml;base64,/gi, 'data:image/svg+xml;base64,');
            }
            function promotePublisherHeadings() {
                var selectors = [
                    '[epub\\\\:type="title"]', '[epub\\\\:type="subtitle"]',
                    '[role="doc-subtitle"]'
                ];
                selectors.forEach(function(selector) {
                    document.querySelectorAll(selector).forEach(function(el) {
                        if (!el.classList.contains('flm-epub-hidden')) {
                            el.classList.add('flm-epub-heading');
                        }
                    });
                });
            }
            \(mediaNormalization)
            \(ReaderInlineGlyphScript.source)
            promotePublisherHeadings();
            applyReaderTheme('\(theme.rawValue)', '\(theme.cssColorScheme)');
            if (document.getElementById('foreverlm-epub-reader-css')) { return; }
            var style = document.createElement('style');
            style.id = 'foreverlm-epub-reader-css';
            style.textContent = `\(escapedCSS)`;
            (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    /// Click-to-expand for figures and wide tables. Web pages give you a
    /// full-size view of a screenshot or table by clicking it; the reader
    /// squeezes everything to the 780px column instead, which makes dense
    /// figures unreadable. This puts the clicked element on a full-window
    /// backdrop, where a second click toggles between fit-to-window and
    /// natural size.
    static let mediaLightboxScript = """
    (function() {
        if (window.__flmReaderLightbox) { return; }
        window.__flmReaderLightbox = true;

        var MIN_WIDTH = 120;
        var MIN_HEIGHT = 60;
        var IMAGE_SUFFIXES = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg', '.avif'];
        var backdrop = null;
        var stage = null;
        var content = null;
        var caption = null;
        var previousOverflow = '';

        var css = [
            '.flm-zoomable { cursor: zoom-in !important; }',
            '.flm-lightbox { position: fixed !important; top: 0; left: 0; right: 0; bottom: 0;',
            '  z-index: 2147483000; background: rgba(0,0,0,0.86); display: none; }',
            '.flm-lightbox.flm-open { display: block; }',
            '.flm-lightbox-stage { position: absolute; top: 0; left: 0; right: 0; bottom: 0;',
            '  overflow: auto; display: flex; align-items: center; justify-content: center; padding: 48px 32px; }',
            '.flm-lightbox-stage.flm-actual-size { display: block; }',
            '.flm-lightbox-content { margin: auto; }',
            '.flm-lightbox-content img, .flm-lightbox-content svg, .flm-lightbox-content picture {',
            '  max-width: 100% !important; max-height: calc(100vh - 128px) !important;',
            '  width: auto !important; height: auto !important; margin: 0 auto !important;',
            '  display: block !important; cursor: zoom-out !important; border-radius: 6px; }',
            '.flm-actual-size .flm-lightbox-content img, .flm-actual-size .flm-lightbox-content svg {',
            '  max-width: none !important; max-height: none !important; }',
            '.flm-lightbox-content table { background: Canvas; color: CanvasText; margin: 0 !important;',
            '  border-radius: 6px; font-size: 15px; width: auto !important; }',
            '.flm-lightbox-caption { max-width: 720px; margin: 14px auto 0; text-align: center;',
            '  font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px;',
            '  line-height: 1.45; color: rgba(255,255,255,0.72); }',
            '.flm-lightbox-close { position: absolute; top: 14px; right: 18px; width: 30px; height: 30px;',
            '  border: none; border-radius: 15px; background: rgba(255,255,255,0.16); color: #fff;',
            '  font-size: 17px; line-height: 30px; text-align: center; cursor: pointer; padding: 0; }',
            '.flm-lightbox-close:hover { background: rgba(255,255,255,0.28); }'
        ].join('\\n');

        function installStyle() {
            if (document.getElementById('foreverlm-lightbox-css')) { return; }
            var style = document.createElement('style');
            style.id = 'foreverlm-lightbox-css';
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
        }

        function bodyWidth() {
            var body = document.body;
            return body ? body.clientWidth : 0;
        }

        function isZoomableImage(element) {
            var rect = element.getBoundingClientRect();
            var width = rect.width || element.naturalWidth || 0;
            var height = rect.height || element.naturalHeight || 0;
            return width >= MIN_WIDTH && height >= MIN_HEIGHT;
        }

        /// Only tables that genuinely overflow the reading column: a table that
        /// already fits is readable in place, and stealing its clicks would
        /// fight text selection.
        function isZoomableTable(table) {
            var available = bodyWidth();
            if (!available) { return false; }
            return table.getBoundingClientRect().width > available + 4;
        }

        function looksLikeImageLink(anchor, image) {
            if (!anchor) { return false; }
            var href = (anchor.getAttribute('href') || '').toLowerCase().split('?')[0];
            if (!href) { return false; }
            if (href.indexOf('data:image/') === 0) { return true; }
            for (var i = 0; i < IMAGE_SUFFIXES.length; i += 1) {
                if (href.length >= IMAGE_SUFFIXES[i].length &&
                    href.lastIndexOf(IMAGE_SUFFIXES[i]) === href.length - IMAGE_SUFFIXES[i].length) {
                    return true;
                }
            }
            return image && anchor.href === image.src;
        }

        function markZoomable() {
            document.querySelectorAll('img, svg, table').forEach(function(element) {
                if (element.closest('.flm-lightbox')) { return; }
                var zoomable;
                if (element.tagName.toLowerCase() === 'table') {
                    zoomable = isZoomableTable(element);
                } else {
                    var anchor = element.closest('a');
                    zoomable = isZoomableImage(element)
                        && (!anchor || looksLikeImageLink(anchor, element));
                }
                element.classList.toggle('flm-zoomable', zoomable);
            });
        }

        function captionFor(element) {
            var figure = element.closest('figure');
            var text = '';
            if (figure) {
                var figcaption = figure.querySelector('figcaption');
                if (figcaption) { text = figcaption.textContent || ''; }
            }
            if (!text && element.tagName.toLowerCase() === 'img') {
                text = element.getAttribute('alt') || '';
            }
            if (!text && element.tagName.toLowerCase() === 'table') {
                var tableCaption = element.querySelector('caption');
                if (tableCaption) { text = tableCaption.textContent || ''; }
            }
            return text.replace(/\\s+/g, ' ').trim();
        }

        function buildOverlay() {
            backdrop = document.createElement('div');
            backdrop.className = 'flm-lightbox';
            stage = document.createElement('div');
            stage.className = 'flm-lightbox-stage';
            var wrapper = document.createElement('div');
            content = document.createElement('div');
            content.className = 'flm-lightbox-content';
            caption = document.createElement('div');
            caption.className = 'flm-lightbox-caption';
            var close = document.createElement('button');
            close.className = 'flm-lightbox-close';
            close.type = 'button';
            close.setAttribute('aria-label', 'Close');
            close.textContent = '\\u2715';
            wrapper.appendChild(content);
            wrapper.appendChild(caption);
            stage.appendChild(wrapper);
            backdrop.appendChild(stage);
            backdrop.appendChild(close);
            document.body.appendChild(backdrop);

            close.addEventListener('click', hide);
            stage.addEventListener('click', function(event) {
                if (content.contains(event.target)) {
                    toggleActualSize();
                } else {
                    hide();
                }
            });
        }

        function toggleActualSize() {
            stage.classList.toggle('flm-actual-size');
            stage.scrollTop = 0;
            stage.scrollLeft = 0;
        }

        function show(element) {
            if (!backdrop) { buildOverlay(); }
            var clone = element.cloneNode(true);
            clone.classList.remove('flm-zoomable');
            clone.removeAttribute('id');
            content.innerHTML = '';
            content.appendChild(clone);
            var text = captionFor(element);
            caption.textContent = text;
            caption.style.display = text ? 'block' : 'none';
            stage.classList.remove('flm-actual-size');
            stage.scrollTop = 0;
            stage.scrollLeft = 0;
            backdrop.classList.add('flm-open');
            previousOverflow = document.documentElement.style.overflow;
            document.documentElement.style.overflow = 'hidden';
        }

        function hide() {
            if (!backdrop) { return; }
            backdrop.classList.remove('flm-open');
            content.innerHTML = '';
            document.documentElement.style.overflow = previousOverflow;
        }

        function isOpen() {
            return !!backdrop && backdrop.classList.contains('flm-open');
        }

        document.addEventListener('click', function(event) {
            if (event.defaultPrevented || event.button !== 0) { return; }
            if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) { return; }
            if (isOpen()) { return; }
            // A drag that ended on a figure is a selection, not a click.
            var selection = window.getSelection();
            if (selection && !selection.isCollapsed) { return; }

            var target = event.target;
            if (!target || !target.closest) { return; }
            var element = target.closest('img, svg, table');
            if (!element || element.closest('.flm-lightbox')) { return; }

            var anchor = element.closest('a');
            if (anchor && !looksLikeImageLink(anchor, element)) { return; }

            var tag = element.tagName.toLowerCase();
            if (tag === 'table' ? !isZoomableTable(element) : !isZoomableImage(element)) { return; }

            event.preventDefault();
            event.stopPropagation();
            show(element);
        }, true);

        document.addEventListener('keydown', function(event) {
            if (event.key === 'Escape' && isOpen()) {
                event.preventDefault();
                hide();
            }
        });

        installStyle();
        markZoomable();
        window.addEventListener('load', markZoomable);
        window.addEventListener('resize', markZoomable);
        document.addEventListener('load', function(event) {
            var target = event.target;
            if (target && target.tagName && target.tagName.toLowerCase() === 'img') {
                markZoomable();
            }
        }, true);
        setTimeout(markZoomable, 600);
        setTimeout(markZoomable, 2000);
    })();
    """

    private static let basicMediaNormalizationJS = """
    function normalizeAttribute(element, attributeName) {
        var value = element.getAttribute(attributeName);
        if (!value) { return; }
        var fixed = normalizeImageDataURI(value);
        if (fixed !== value) {
            element.setAttribute(attributeName, fixed);
        }
    }
    document.querySelectorAll('img[src^="data:image/"]').forEach(function(img) {
        normalizeAttribute(img, 'src');
        var fixed = normalizeImageDataURI(img.getAttribute('src') || '');
        if (fixed && fixed !== img.getAttribute('src')) {
            img.setAttribute('src', fixed);
        }
    });
    """

    private static let extendedMediaNormalizationJS = """
    function normalizeAttribute(element, attributeName) {
        var value = element.getAttribute(attributeName);
        if (!value) { return; }
        var fixed = normalizeImageDataURI(value);
        if (fixed !== value) {
            element.setAttribute(attributeName, fixed);
        }
    }
    function firstAttribute(element, names) {
        for (var i = 0; i < names.length; i += 1) {
            var value = element.getAttribute(names[i]);
            if (value && value.trim()) { return value.trim(); }
        }
        return '';
    }
    function imageLooksLikePlaceholder(img) {
        var src = (img.getAttribute('src') || '').toLowerCase();
        return !src
            || src === 'about:blank'
            || src.indexOf('blank') !== -1
            || src.indexOf('spacer') !== -1
            || src.indexOf('transparent') !== -1
            || src.indexOf('data:image/gif;base64,r0lgod') === 0;
    }
    function unhideMediaElement(element) {
        element.removeAttribute('hidden');
        element.removeAttribute('aria-hidden');
        if (element.style) {
            if (element.style.display === 'none') { element.style.display = ''; }
            if (element.style.visibility === 'hidden') { element.style.visibility = ''; }
            if (element.style.opacity === '0') { element.style.opacity = ''; }
        }
        var parent = element.parentElement;
        var depth = 0;
        while (parent && parent !== document.body && depth < 3) {
            var className = (parent.getAttribute('class') || '').toLowerCase();
            var tagName = parent.tagName.toLowerCase();
            var isImageWrapper = tagName === 'figure'
                || tagName === 'picture'
                || className.indexOf('figure') !== -1
                || className.indexOf('image') !== -1
                || className.indexOf('illustration') !== -1
                || className.indexOf('page') !== -1;
            if (!isImageWrapper) { break; }
            parent.removeAttribute('hidden');
            parent.removeAttribute('aria-hidden');
            if (parent.style) {
                if (parent.style.display === 'none') { parent.style.display = ''; }
                if (parent.style.visibility === 'hidden') { parent.style.visibility = ''; }
                if (parent.style.opacity === '0') { parent.style.opacity = ''; }
            }
            parent = parent.parentElement;
            depth += 1;
        }
    }
    document.querySelectorAll('img').forEach(function(img) {
        normalizeAttribute(img, 'src');
        normalizeAttribute(img, 'srcset');
        var lazySource = firstAttribute(img, ['data-src', 'data-original', 'data-lazy-src', 'data-actualsrc', 'data-fullsrc']);
        if (lazySource && imageLooksLikePlaceholder(img)) {
            img.setAttribute('src', normalizeImageDataURI(lazySource));
        }
        var lazySourceSet = firstAttribute(img, ['data-srcset', 'data-lazy-srcset']);
        if (lazySourceSet && !img.getAttribute('srcset')) {
            img.setAttribute('srcset', normalizeImageDataURI(lazySourceSet));
        }
        unhideMediaElement(img);
    });
    document.querySelectorAll('source').forEach(function(source) {
        normalizeAttribute(source, 'srcset');
        var lazySourceSet = firstAttribute(source, ['data-srcset', 'data-lazy-srcset']);
        if (lazySourceSet && !source.getAttribute('srcset')) {
            source.setAttribute('srcset', normalizeImageDataURI(lazySourceSet));
        }
    });
    document.querySelectorAll('svg image, image').forEach(function(image) {
        normalizeAttribute(image, 'href');
        normalizeAttribute(image, 'xlink:href');
        var lazySource = firstAttribute(image, ['data-src', 'data-href', 'data-original']);
        if (lazySource && !firstAttribute(image, ['href', 'xlink:href'])) {
            image.setAttribute('href', normalizeImageDataURI(lazySource));
        }
        unhideMediaElement(image);
    });
    document.querySelectorAll('object[type^="image/"], object[data^="data:image/"]').forEach(function(object) {
        normalizeAttribute(object, 'data');
        unhideMediaElement(object);
    });
    """
}
#endif
