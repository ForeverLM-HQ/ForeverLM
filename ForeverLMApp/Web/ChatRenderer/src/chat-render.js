// One chat renderer for every surface that shows a ForeverLM reply.
//
// The Mac app draws each assistant message in its own WKWebView; Web Studio
// draws them into the page it is already running in. Both load this bundle and
// call `createChatRenderer`, so a repair, a citation style, or a math setting
// lands on both at once. Before this module the two were hand-translated
// copies of each other, and the fix for math-mode italics had to be written
// twice, which is what made the duplication worth removing.
//
// What stays per-surface is only the host integration: how a source card or a
// picture is resolved, what a click on a source opens, and what to do when the
// rendered height changes. Those arrive as functions.

import DOMPurify from "dompurify";
import MarkdownIt from "markdown-it";
import { isChatImageURL, parseSourceImageReference } from "#source-images";
import { normalizeChatMarkdown, restoreMath, splitVisualizations } from "./chat-markdown.js";
import { visualizationElement, visualizationKey } from "./chat-visualization.js";
import {
  escapedHTML,
  installJoinerFreeCopy,
  isSourceEntryLink,
  isStandaloneSourceLink,
  markSourceEntryLists,
  passageFromLink,
  removeLeakedCodeFenceLabels,
  renderBlockSourceLink,
  renderCaptionSourceLink,
  renderInlineSourceCitation,
  renderInvalidSourceLink,
  renderPendingBlockSourceLink,
  renderPendingSourceCitation,
  renderSourceEntryLink,
  renderSourcesFooter,
  renderTaskListCheckboxes,
  restoreEscapedLineBreakTags,
  sourceHref,
  sourceLinkFromHref,
  typesetMath,
  fitDisplayMath,
} from "./chat-dom.js";

export * from "./chat-markdown.js";

// DOMPurify's default URI allowlist strips the app's own deep-link scheme
// (foreverlm://source/<id>), which the assistant emits so a source opens where
// the learner is reading. Same as the default, plus foreverlm.
const ALLOWED_URI_REGEXP = /^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|foreverlm):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i;

const markdown = new MarkdownIt({
  html: false,
  linkify: true,
  typographer: true,
  breaks: true,
});

// A source picture is emitted without a src: the reference is not a URL any
// browser can fetch, and letting it try would log a failed load per picture.
// The renderer fills the src in once the host has resolved the bytes.
const defaultImageRule = markdown.renderer.rules.image;
markdown.renderer.rules.image = function image(tokens, index, options, environment, self) {
  const token = tokens[index];
  const source = token.attrGet("src") ?? "";
  if (!isChatImageURL(source)) {
    return defaultImageRule
      ? defaultImageRule(tokens, index, options, environment, self)
      : self.renderToken(tokens, index, options);
  }
  const alt = self.renderInlineAsText(token.children ?? [], options, environment);
  return `<img class="source-image" data-source-image="${escapedHTML(source)}" alt="${escapedHTML(alt)}">`;
};

/// Markdown to sanitized HTML, with math lifted out and put back as inert
/// placeholders for `typesetMath`. Exported for tests and for any surface that
/// wants the HTML without the host-dependent decorations.
export function renderChatMarkdownToHTML(text) {
  const normalized = normalizeChatMarkdown(text);
  const rendered = markdown.render(normalized.markdown);
  const sanitized = DOMPurify.sanitize(rendered, {
    ADD_ATTR: ["target", "rel", "class"],
    ALLOWED_URI_REGEXP,
  });
  return {
    html: restoreMath(sanitized, normalized.segments, (_, index) => `<span data-chat-math="${index}"></span>`),
    segments: normalized.segments,
  };
}

export function createChatRenderer({
  mathOutput = "mathml",
  katex = () => globalThis.katex,
  requestSourceCards = null,
  requestSourceImages = null,
  copySourceImage = null,
  openSourceImage = null,
  zoomSourceImage = null,
  // Open beside: the picture takes a pane next to the conversation, so the
  // question stays readable while the figure is big. A host with no such place
  // leaves it null and the figure carries no button for it.
  openSourceImageBeside = null,
  addSlideCitedPaper = null,
  addSourceToNotebook = null,
  openSource = null,
  openWebLink = null,
  onLayoutChange = null,
  // Whether this host runs a reply's visualizations. One that cannot shows a
  // line in the block's place instead of the program's source.
  runsVisualizations = false,
} = {}) {
  const cardsByToken = new Map();
  const pendingCardTokens = new Set();
  const invalidCardTokens = new Set();

  // A copied passage carries no citation glue (`installJoinerFreeCopy`).
  if (typeof document !== "undefined") installJoinerFreeCopy(document);

  const imagesByToken = new Map();
  const pendingImageTokens = new Set();
  const invalidImageTokens = new Set();

  // Every container this renderer has painted, so a card or picture that
  // arrives later can be dropped into each of them. Web Studio has a whole
  // transcript of them; the Mac has exactly one per web view.
  const containers = new Set();

  const liveContainers = () => {
    for (const container of containers) {
      if (!container.isConnected) containers.delete(container);
    }
    return containers;
  };

  // Display equations are fitted to their column (`fitDisplayMath`) again
  // once the math font has loaded, since an equation measured before that is
  // narrower than it draws, and whenever the page resizes. A timer rather
  // than an animation frame: a hidden web view never runs frames.
  const refitMath = () => {
    let changed = false;
    for (const container of liveContainers()) changed = fitDisplayMath(container) || changed;
    if (changed) onLayoutChange?.();
  };
  const scheduleMathRefit = () => {
    if (typeof setTimeout === "function") setTimeout(refitMath, 0);
    const fonts = typeof document !== "undefined" ? document.fonts : null;
    fonts?.ready?.then(refitMath);
  };
  if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
    let refitTimer = 0;
    window.addEventListener("resize", () => {
      clearTimeout(refitTimer);
      refitTimer = setTimeout(refitMath, 50);
    });
  }

  /// What the transcript above a message already settled: the number each source
  /// keeps for the whole conversation, and whose card has been listed before.
  /// Neither can be worked out from one reply, and one reply is all this
  /// renderer ever sees at once -- on the Mac each of them has its own web view
  /// -- so the host works them out over the transcript and hands them in with
  /// the markdown. A container rendered without one keeps the older behaviour:
  /// numbering from one per message, and every citation listed under it.
  const citationContexts = new WeakMap();

  function decorateSourceImages(content) {
    const missingTokens = [];
    for (const img of content.querySelectorAll("img[data-source-image]")) {
      const token = String(img.dataset.sourceImage ?? "").trim();
      if (!token) continue;
      const figure = sourceImageFigure(img, token);
      figure.querySelector(".source-image-note")?.remove();

      if (invalidImageTokens.has(token)) {
        markImageUnavailable(figure, img);
        continue;
      }

      const resolved = imagesByToken.get(token);
      if (resolved) {
        paintResolvedImage(figure, img, token, resolved);
        continue;
      }

      figure.classList.add("source-image-pending");
      if (!pendingImageTokens.has(token)) {
        pendingImageTokens.add(token);
        missingTokens.push(token);
      }
    }
    if (missingTokens.length > 0) requestSourceImages?.(missingTokens);
  }

  function sourceImageFigure(img, token) {
    const existing = img.closest("figure.source-image-figure");
    if (existing) return existing;
    const document_ = img.ownerDocument;
    const figure = document_.createElement("figure");
    figure.className = "source-image-figure";
    // Kept on the figure, since a page shown in a frame takes the img's place.
    figure.dataset.sourceImage = token;
    // Markdown wraps a picture on its own line in a paragraph; the figure takes
    // that paragraph's place so the picture is a block. A picture with words
    // around it in one paragraph, as a model writes "text, picture, text" with
    // no blank lines, splits the paragraph around the figure instead: a block
    // inside a paragraph would sit in the prose's measure and squeeze the
    // picture into it.
    const paragraph = img.parentElement;
    if (paragraph?.tagName === "P" && paragraph.childNodes.length === 1) paragraph.replaceWith(figure);
    else if (paragraph?.tagName === "P") liftOutOfParagraph(paragraph, img, figure);
    else img.replaceWith(figure);
    figure.append(img);

    const actions = document_.createElement("span");
    actions.className = "source-image-actions";
    figure.append(actions);
    return figure;
  }

  /// The figure between the paragraph's words before the picture and a new
  /// paragraph of the words after it. The line breaks that set the picture on
  /// its own line go with it, and a half left with nothing in it goes too.
  function liftOutOfParagraph(paragraph, img, figure) {
    const after = paragraph.ownerDocument.createElement("p");
    while (img.nextSibling) after.append(img.nextSibling);
    img.remove();
    paragraph.after(figure);
    figure.after(after);
    for (const half of [paragraph, after]) {
      const isBlank = (node) => node?.nodeName === "BR" || (node?.nodeType === Node.TEXT_NODE && !node.nodeValue.trim());
      while (isBlank(half.lastChild)) half.lastChild.remove();
      while (isBlank(half.firstChild)) half.firstChild.remove();
      if (!half.hasChildNodes()) half.remove();
    }
  }

  function figureActions(figure) {
    return figure.querySelector(".source-image-actions");
  }

  function actionButton(document_, label, title) {
    const button = document_.createElement("button");
    button.type = "button";
    button.className = "source-image-copy";
    button.textContent = label;
    if (title) {
      button.title = title;
      button.setAttribute("aria-label", title);
    }
    return button;
  }

  function markImageUnavailable(figure, img) {
    img.removeAttribute("src");
    figure.classList.remove("source-image-pending");
    figure.classList.add("source-image-unavailable");
    const note = figure.ownerDocument.createElement("span");
    note.className = "source-image-note";
    note.textContent = img.alt
      ? `${img.alt}: picture unavailable on this device`
      : "Picture unavailable on this device";
    const caption = figure.querySelector(":scope > .source-image-caption");
    if (caption) caption.before(note);
    else figure.append(note);
  }

  /// A resolved picture is either something the browser can show as an image
  /// (the Mac hands over a data URL, the browser a blob URL) or a page of a PDF,
  /// which only a host with a page rasterizer can turn into one. In the browser
  /// that page shows in a frame instead, with a way to open it where it lives.
  function paintResolvedImage(figure, img, token, resolved) {
    const document_ = figure.ownerDocument;
    const actions = figureActions(figure);
    const source = resolved.src ?? resolved.dataURL ?? null;
    figure.classList.remove("source-image-pending", "source-image-unavailable");

    if (source) {
      figure.querySelector(".source-image-frame")?.remove();
      if (img.getAttribute("src") !== source) img.src = source;
      img.hidden = false;
      img.draggable = true;
      // A picture squeezed into the column opens full-window on a click, the
      // way a figure in the reader does. A drag out of the transcript never
      // fires a click, so the two gestures do not compete.
      if (zoomSourceImage && !img.dataset.zoomBound) {
        img.dataset.zoomBound = "true";
        img.classList.add("source-image-zoomable");
        img.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          zoomSourceImage(token, img);
        });
      }
      if (copySourceImage && actions && !actions.querySelector(".source-image-copy")) {
        const copy = actionButton(document_, "Copy", "Copy image");
        copy.addEventListener("click", async (event) => {
          event.preventDefault();
          event.stopPropagation();
          const copied = await copySourceImage(token, img);
          copy.textContent = copied === false ? "Copy failed" : "Copied";
          copy.classList.add("source-image-copied");
          document_.defaultView?.setTimeout(() => {
            copy.textContent = "Copy";
            copy.classList.remove("source-image-copied");
          }, 1400);
        });
        actions.append(copy);
        if (openSourceImageBeside) {
          const beside = actionButton(document_, "Open beside", "Open beside the chat");
          beside.classList.add("source-image-beside");
          beside.addEventListener("click", (event) => {
            event.preventDefault();
            event.stopPropagation();
            openSourceImageBeside(token, img);
          });
          actions.append(beside);
        }
      }
      paintSlidePapers(figure, token, resolved.citedPapers);
      return;
    }

    if (resolved.pdfURL) {
      img.remove();
      if (!figure.querySelector(".source-image-frame")) {
        const frame = document_.createElement("iframe");
        frame.className = "source-image-frame";
        frame.title = img.alt || "Source page";
        frame.src = `${resolved.pdfURL}#page=${resolved.page}&view=Fit`;
        figure.prepend(frame);
      }
      if (openSourceImage && actions && !actions.querySelector(".source-image-copy")) {
        const open = actionButton(document_, "Open in Reader", null);
        open.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          openSourceImage(token, resolved);
        });
        actions.append(open);
      }
      return;
    }

    markImageUnavailable(figure, img);
  }

  /// The papers "Extract papers" read off a slide, listed under the picture of
  /// it: one in the library opens in the Reader, one still on offer has Add.
  /// Redrawn only when the host hands the picture over again, not on every
  /// redecoration a card or picture landing causes: an Add in flight keeps its
  /// "Adding" until the host answers, and the answer -- the same list after a
  /// failed add included -- always redraws it.
  const paintedSlidePapers = new WeakMap();
  function paintSlidePapers(figure, token, papers) {
    const existing = figure.querySelector(".source-image-papers");
    if (paintedSlidePapers.get(figure) === papers && (existing || !papers?.length)) return;
    paintedSlidePapers.set(figure, papers);
    existing?.remove();
    const shown = Array.isArray(papers) ? papers : [];
    if (shown.length === 0) return;

    const document_ = figure.ownerDocument;
    const list = document_.createElement("div");
    list.className = "source-image-papers";
    const heading = document_.createElement("div");
    heading.className = "source-image-papers-heading";
    heading.textContent = shown.length === 1 ? "Paper on this slide" : "Papers on this slide";
    list.append(heading);

    for (const paper of shown) {
      const row = document_.createElement("div");
      row.className = "source-image-paper";
      const copy = document_.createElement("div");
      copy.className = "source-image-paper-copy";

      const opensSource = Boolean(paper.sourceID && openSource);
      const title = document_.createElement(opensSource ? "button" : "span");
      title.className = "source-image-paper-title";
      title.textContent = paper.title ?? "";
      if (opensSource) {
        title.type = "button";
        title.title = "Open in Reader";
        title.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          openSource(paper.sourceID, {});
        });
      }
      copy.append(title);
      if (paper.subtitle) {
        const subtitle = document_.createElement("span");
        subtitle.className = "source-image-paper-subtitle";
        subtitle.textContent = paper.subtitle;
        copy.append(subtitle);
      }
      row.append(copy);

      if (!paper.sourceID && paper.canAdd && addSlideCitedPaper) {
        const add = document_.createElement("button");
        add.type = "button";
        add.className = "source-image-paper-add";
        add.textContent = "Add";
        add.title = "Add this paper to your library";
        add.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          add.disabled = true;
          add.textContent = "Adding";
          addSlideCitedPaper(token, paper.id);
        });
        row.append(add);
      }
      list.append(row);
    }
    figure.append(list);
  }

  /// Which of a reply's citations earn a card under it. One the conversation
  /// has already introduced does not: the marker in the sentence is itself a
  /// link to the source, and repeating the same title, byline and thumbnail
  /// under every turn of a review that circles one paper is the noise this
  /// removes. A reply that points at a moment no earlier reply pointed at is
  /// naming somewhere new, so that source is listed again. A page is not
  /// tracked this way: the host records the moments a transcript has shown and
  /// nothing about pages, so a later page citation keeps to its marker, which
  /// already names and opens the page.
  function listedCitations(citations, context) {
    const presented = context?.presented;
    if (!presented) return citations;
    return citations.filter((citation) => {
      const shown = presented[citation.token];
      if (!Array.isArray(shown)) return true;
      const seen = new Set(shown);
      return citation.moments.some((moment) => !seen.has(Math.round(moment)));
    });
  }

  function decorateSourceLinks(content) {
    const missingTokens = [];
    const blockSourceIDs = new Set();
    /// Sources a list item in this reply already names. A marker elsewhere in
    /// the reply still links to one, but the footer does not list it again:
    /// the entry is its row (product owner, 2026-09-30: "there should just be 13
    /// bulletpoints").
    const entrySources = new Set();
    const citationNumbers = new Map();
    const citationsByNumber = new Map();
    const markers = [];
    const context = citationContexts.get(content) ?? null;
    const hostNumbers = context?.numbers ?? {};
    const spokenFor = new Set(Object.values(hostNumbers).filter(Number.isInteger));

    /// A number for a source the host did not name -- a reply rendered without
    /// a context, or a link the transcript scan did not see. The lowest one
    /// nobody else holds, so it can never read as another work's citation.
    const fallbackNumber = () => {
      let candidate = 1;
      while (spokenFor.has(candidate) || citationsByNumber.has(candidate)) candidate += 1;
      return candidate;
    };

    content.querySelector(".source-citations-footer")?.remove();

    /// One number per source, however many moments or pages of it are cited:
    /// the footer names the work once and lists the places under it. The host's number
    /// wins where there is one, so chip 1 means the same work in the first reply
    /// of a session and in the fortieth. A citation whose card has not arrived
    /// is registered under its token, so its footer row is reserved from the
    /// first paint and the card, when it lands, fills a row that already exists.
    const registerCitation = (sourceID, token, card, seconds, pending, page = null, passage = null) => {
      let number = citationNumbers.get(sourceID);
      if (number === undefined) {
        number = Number.isInteger(hostNumbers[token]) ? hostNumbers[token] : fallbackNumber();
        // Two sources cannot share a marker, whatever the host sent.
        if (citationsByNumber.has(number)) number = fallbackNumber();
        citationNumbers.set(sourceID, number);
        citationsByNumber.set(number, {
          number, card, token, href: sourceHref(token), moments: [], pages: [], pending,
        });
      }
      const citation = citationsByNumber.get(number);
      if (seconds !== null) {
        if (!citation.moments.includes(seconds)) {
          citation.moments.push(seconds);
          citation.moments.sort((left, right) => left - right);
        }
      } else if (page !== null) {
        // One chip per page; the first excerpt cited on it is the one the chip
        // flashes.
        if (!citation.pages.some((cited) => cited.page === page)) {
          citation.pages.push({ page, passage });
          citation.pages.sort((left, right) => left.page - right.page);
        }
      }
      return number;
    };

    for (const link of content.querySelectorAll("a[href]")) {
      const sourceLink = sourceLinkFromHref(link.getAttribute("href"));
      if (!sourceLink) continue;
      const { token, seconds, page } = sourceLink;
      // Read before the card's subtitle replaces the title attribute.
      const passage = passageFromLink(link);
      if (invalidCardTokens.has(token)) {
        renderInvalidSourceLink(link);
        continue;
      }
      const card = cardsByToken.get(token);
      if (!card) {
        link.classList.add("source-pending-link");
        link.setAttribute("aria-disabled", "true");
        if (!pendingCardTokens.has(token)) {
          pendingCardTokens.add(token);
          missingTokens.push(token);
        }
        if (link.dataset.sourceMode === "caption") {
          renderCaptionSourceLink(link, null, seconds, page);
          continue;
        }
        // A list item's name, not a citation: no number, no footer row.
        if (link.dataset.sourceMode === "entry" || isSourceEntryLink(link)) {
          renderSourceEntryLink(link, null, seconds, page);
          entrySources.add(token);
          continue;
        }
        // Reserve the room the resolved link will take. The host measures the
        // message as soon as it is painted and sizes the row from that number;
        // a footer that only appeared once the cards arrived made every reply
        // with citations measure short first and spring open by a row per
        // source afterwards -- under a scroll, the transcript jumping. The
        // token stands in for the source id until the card says otherwise.
        if (isStandaloneSourceLink(link) && !blockSourceIDs.has(token)) {
          renderPendingBlockSourceLink(link);
          blockSourceIDs.add(token);
          continue;
        }
        // The marker's own chip, drawn below once every citation is counted,
        // so the line it sits in is already its final height.
        const number = registerCitation(
          token,
          token,
          { sourceID: token, title: "", subtitle: "", kind: "unclassified", glyph: "" },
          seconds,
          true,
          page,
          passage,
        );
        markers.push({ link, card: null, number, seconds, page });
        continue;
      }

      const existingMode = link.dataset.sourceMode;
      const isEntry = existingMode === "entry" || (!existingMode && isSourceEntryLink(link));
      const canRenderBlock = existingMode === "block"
        || (!existingMode && isStandaloneSourceLink(link) && !blockSourceIDs.has(card.sourceID));
      link.textContent = "";
      link.classList.remove("source-pending-link", "source-block-pending", "source-citation-marker");
      link.removeAttribute("aria-disabled");
      link.dataset.sourceCard = "true";
      // The hover text says where the claim came from when the citation knows.
      link.title = [passage ? `“${passage}”` : null, page !== null ? `Page ${page}` : null, card.subtitle]
        .filter(Boolean)
        .join(" · ");
      link.setAttribute("aria-label", `Open ${card.title}. ${card.subtitle}`);
      if (existingMode === "caption") {
        renderCaptionSourceLink(link, card, seconds, page);
        continue;
      }
      if (isEntry) {
        renderSourceEntryLink(link, card, seconds, page);
        entrySources.add(token);
        entrySources.add(card.sourceID);
        continue;
      }
      if (canRenderBlock) {
        renderBlockSourceLink(link, card, seconds, page);
        blockSourceIDs.add(card.sourceID);
        continue;
      }

      const number = registerCitation(card.sourceID, token, card, seconds, false, page, passage);
      markers.push({ link, card, number, seconds, page });
    }
    markSourceEntryLists(content);

    // Drawn once every citation is counted: whether a marker needs its number
    // depends on how many sources the whole reply cites, pending ones included.
    const numbered = citationsByNumber.size > 1;
    for (const { link, card, number, seconds, page } of markers) {
      if (card) renderInlineSourceCitation(link, card, number, seconds, page, numbered);
      else renderPendingSourceCitation(link, number, seconds, page, numbered);
    }

    const citations = [...citationsByNumber.values()]
      .filter((citation) => !entrySources.has(citation.token) && !entrySources.has(citation.card.sourceID))
      .sort((left, right) => left.number - right.number);
    renderSourcesFooter(
      content,
      listedCitations(citations, context),
      openSource ? (token, place) => openSource(token, place) : null,
      addSourceToNotebook,
    );
    if (missingTokens.length > 0) requestSourceCards?.(missingTokens);
  }

  /// Where each kind of link goes. A source link is the host's business; a web
  /// link opens where the host says, which on the Mac is ForeverLM's own reader
  /// rather than a browser.
  function installLinkBehavior(content) {
    for (const link of content.querySelectorAll("a[href]")) {
      const href = link.getAttribute("href") ?? "";
      if (/^foreverlm:\/\/source\//i.test(href)) {
        link.removeAttribute("target");
        link.removeAttribute("rel");
        if (openSource && !link.dataset.sourceOpenInstalled) {
          link.dataset.sourceOpenInstalled = "true";
          link.addEventListener("click", (event) => {
            const sourceLink = sourceLinkFromHref(link.getAttribute("href"));
            if (!sourceLink) return;
            event.preventDefault();
            openSource(sourceLink.token, {
              seconds: sourceLink.seconds,
              passage: passageFromLink(link),
              page: sourceLink.page,
            });
          });
        }
      } else if (/^https?:\/\//i.test(href)) {
        if (openWebLink) {
          link.removeAttribute("target");
          link.removeAttribute("rel");
          if (!link.dataset.webLinkInstalled) {
            link.dataset.webLinkInstalled = "true";
            link.addEventListener("click", (event) => {
              event.preventDefault();
              openWebLink(link.href, String(link.textContent ?? "").trim());
            });
          }
        } else {
          link.setAttribute("target", "_blank");
          link.setAttribute("rel", "noopener noreferrer");
        }
      } else {
        link.setAttribute("target", "_blank");
        link.setAttribute("rel", "noopener noreferrer");
      }
    }
  }

  /// A picture from a source and a link to that same source on a line of its
  /// own right after it, or right before it, are one thing: the link becomes
  /// the picture's caption, saying where the picture comes from and opening
  /// the source there. Apart, a quiz's feedback read as a card for a lecture
  /// video and then a slide with nothing to say it was that video's, at that
  /// moment (product owner, 2026-09-28: "it's just not super clear what this has to
  /// do with it"). Run before the links are drawn, so a caption is never
  /// first drawn as a card or counted as a citation.
  function captionSourceImages(content) {
    for (const figure of content.querySelectorAll("figure.source-image-figure")) {
      if (figure.querySelector(":scope > .source-image-caption")) continue;
      const sourceID = parseSourceImageReference(figure.dataset.sourceImage)?.sourceID;
      if (!sourceID) continue;
      const link = [figure.nextElementSibling, figure.previousElementSibling]
        .map((sibling) => captionLink(sibling, sourceID))
        .find(Boolean);
      if (!link) continue;
      const paragraph = link.parentElement;
      const caption = figure.ownerDocument.createElement("figcaption");
      caption.className = "source-image-caption";
      caption.append(link);
      // Under the picture, or under the note standing in for it.
      const above = figure.querySelector(":scope > .source-image-note")
        ?? figure.querySelector(":scope > img, :scope > .source-image-frame");
      if (above) above.after(caption);
      else figure.prepend(caption);
      figure.classList.add("source-image-captioned");
      paragraph.remove();
      link.dataset.sourceMode = "caption";
    }
  }

  /// The link a paragraph holds when it holds nothing else and names the source.
  function captionLink(element, sourceID) {
    if (element?.tagName !== "P") return null;
    const link = element.querySelector(":scope > a[href]");
    if (!link || !isStandaloneSourceLink(link)) return null;
    return sourceLinkFromHref(link.getAttribute("href"))?.token === sourceID ? link : null;
  }

  function decorate(content) {
    decorateSourceImages(content);
    captionSourceImages(content);
    decorateSourceLinks(content);
  }

  function render(container, text, { citations } = {}) {
    if (citations !== undefined) {
      if (citations) citationContexts.set(container, citations);
      else citationContexts.delete(container);
    }
    const parts = splitVisualizations(text);
    if (parts.some((part) => part.kind === "visualization")) paintParts(container, parts);
    else paintMarkdown(container, text);
    containers.add(container);
    decorate(container);
    installLinkBehavior(container);
    fitDisplayMath(container);
    scheduleMathRefit();
    onLayoutChange?.();
    return container;
  }

  function paintMarkdown(element, text) {
    const { html, segments } = renderChatMarkdownToHTML(text);
    element.innerHTML = html;
    removeLeakedCodeFenceLabels(element);
    restoreEscapedLineBreakTags(element);
    renderTaskListCheckboxes(element);
    typesetMath(element, segments, { katex: katex(), output: mathOutput });
  }

  /// A reply with a visualization in it, painted a child per part. Prose parts
  /// are drawn into elements that lay out as if their contents were the
  /// container's own, so the reply reads as one. Each paint keeps the leading
  /// children whose part is unchanged and redraws from the first that is not:
  /// a reply streaming on after its visualization redraws only the prose
  /// below it, and the frame above, already running, is never moved or
  /// reloaded (moving a frame reloads it).
  function paintParts(container, parts) {
    container.querySelector(":scope > .source-citations-footer")?.remove();
    const document_ = container.ownerDocument;
    const existing = [...container.children].filter(
      (child) => child.classList.contains("chat-part") || child.classList.contains("chat-visualization"),
    );
    // Anything else is what a paint without parts left behind.
    if (existing.length !== container.children.length) {
      container.replaceChildren();
      existing.length = 0;
    }
    let kept = 0;
    for (; kept < parts.length && kept < existing.length; kept += 1) {
      const part = parts[kept];
      const child = existing[kept];
      if (part.kind === "markdown") {
        if (!child.classList.contains("chat-part")) break;
        paintMarkdown(child, part.text);
      } else if (child.dataset.visualizationKey !== visualizationKey(part.html, part.complete && runsVisualizations)) {
        break;
      }
    }
    for (const stale of existing.slice(kept)) stale.remove();
    for (const part of parts.slice(kept)) {
      if (part.kind === "markdown") {
        const element = document_.createElement("div");
        // Its own `chat-rendered` too: the rhythm is written as rules on the
        // message's direct children, and these are a part's.
        element.className = "chat-part chat-rendered";
        container.append(element);
        paintMarkdown(element, part.text);
      } else {
        container.append(visualizationElement(document_, part, { runs: runsVisualizations, onLayoutChange }));
      }
    }
  }

  // Cards arrive after the first paint, and the footer they produce is new
  // markup: its links need the same click behaviour the message's own links
  // got at render time. Installing is idempotent, so the rest is untouched.
  function redecorate() {
    for (const container of liveContainers()) {
      decorate(container);
      installLinkBehavior(container);
    }
    onLayoutChange?.();
  }

  return {
    render,

    setSourceCards(cards) {
      for (const [token, card] of Object.entries(cards ?? {})) {
        pendingCardTokens.delete(token);
        if (card) {
          invalidCardTokens.delete(token);
          cardsByToken.set(token, card);
        } else {
          cardsByToken.delete(token);
          invalidCardTokens.add(token);
        }
      }
      redecorate();
    },

    setSourceImages(images) {
      for (const [token, image] of Object.entries(images ?? {})) {
        pendingImageTokens.delete(token);
        if (image && (image.src || image.dataURL || image.pdfURL)) {
          invalidImageTokens.delete(token);
          imagesByToken.set(token, image);
        } else {
          imagesByToken.delete(token);
          invalidImageTokens.add(token);
        }
      }
      redecorate();
    },

    resetSourceCards() {
      cardsByToken.clear();
      pendingCardTokens.clear();
      invalidCardTokens.clear();
    },

    resetSourceImages() {
      imagesByToken.clear();
      pendingImageTokens.clear();
      invalidImageTokens.clear();
    },

    forgetContainer(container) {
      containers.delete(container);
      citationContexts.delete(container);
    },
  };
}
