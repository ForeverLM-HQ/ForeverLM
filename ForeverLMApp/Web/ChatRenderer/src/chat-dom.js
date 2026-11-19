// DOM passes that run after Markdown, shared by the Mac WebView and Web Studio.
//
// Each one repairs something Markdown cannot express or a model wrote wrong,
// operating on the parsed and sanitized element rather than on text, so a
// repair can never introduce markup.

export function escapedHTML(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function firstMeaningfulTextNode(root) {
  const walker = root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  let node = walker.nextNode();
  while (node && !String(node.nodeValue ?? "").trim()) node = walker.nextNode();
  return node;
}

/// Turns the `[ ]` and `[x]` markers `normalizeTaskLists` put at the head of
/// each list item into a styled box, so a review checklist reads as one.
export function renderTaskListCheckboxes(content) {
  for (const item of content.querySelectorAll("li")) {
    const textNode = firstMeaningfulTextNode(item);
    if (!textNode) continue;
    const marker = String(textNode.nodeValue ?? "").match(/^[ \t]*\[([ xX])\][ \t]?/);
    if (!marker) continue;

    const checked = marker[1].toLowerCase() === "x";
    textNode.nodeValue = textNode.nodeValue.slice(marker[0].length);

    const body = content.ownerDocument.createElement("span");
    body.className = "flm-task-body";
    while (item.firstChild) body.append(item.firstChild);

    const box = content.ownerDocument.createElement("span");
    box.className = `flm-check${checked ? " flm-check-on" : ""}`;
    box.setAttribute("aria-hidden", "true");
    if (checked) box.textContent = "✓";

    item.append(box, body);
    item.classList.add("flm-task");

    const list = item.parentElement;
    if (list && (list.tagName === "UL" || list.tagName === "OL")) list.classList.add("flm-task-list");
  }
}

/// A fence label the model wrote without its newline ("```text1. First") lands
/// inside an inline code span as a leading "text". Strip it rather than show a
/// language name as content.
export function removeLeakedCodeFenceLabels(content) {
  for (const code of content.querySelectorAll("code")) {
    if (code.parentElement?.tagName === "PRE") continue;
    const text = code.textContent ?? "";
    const normalized = text.replace(/^(?:text|txt|plain)(?=\d+\s)/i, "");
    if (normalized !== text) code.textContent = normalized;
  }
}

/// A `<br>` the model wrote inside text Markdown had already escaped survives
/// sanitization as the literal characters. Turn those back into line breaks,
/// outside code, where the model plainly meant a new line.
export function restoreEscapedLineBreakTags(content) {
  const document_ = content.ownerDocument;
  const walker = document_.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!/<br\s*\/?\s*>/i.test(node.nodeValue ?? "")) return NodeFilter.FILTER_REJECT;
      if (node.parentElement?.closest("pre, code, kbd, samp, script, style")) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  const nodes = [];
  let node = walker.nextNode();
  while (node) {
    nodes.push(node);
    node = walker.nextNode();
  }

  for (const textNode of nodes) {
    const parts = String(textNode.nodeValue ?? "").split(/<br\s*\/?\s*>/i);
    if (parts.length < 2) continue;
    const fragment = document_.createDocumentFragment();
    parts.forEach((part, index) => {
      if (index > 0) fragment.append(document_.createElement("br"));
      if (part) fragment.append(document_.createTextNode(part));
    });
    textNode.parentNode?.replaceChild(fragment, textNode);
  }
}

/// Typesets the placeholders `protectMath` left behind. Math is rendered from
/// the model's exact source, never from what Markdown made of it, which is the
/// whole point of lifting it out first.
///
/// `output` decides which KaTeX backend draws it. "mathml" needs no stylesheet
/// and no font files (the browser's own math font draws it), which is what
/// lets Web Studio keep its CSP closed and the Mac app render math offline.
/// "html" is KaTeX's own box model with its own fonts.
export function typesetMath(content, segments, { katex, output = "mathml" } = {}) {
  for (const placeholder of content.querySelectorAll("[data-chat-math]")) {
    const index = Number.parseInt(placeholder.dataset.chatMath, 10);
    const source = segments[index];
    if (source == null) {
      placeholder.remove();
      continue;
    }

    // Math inside a code fence is an example of math, not math. Put the
    // source back as the text the fence was showing.
    if (placeholder.parentElement?.closest("pre, code, kbd, samp")) {
      placeholder.replaceWith(content.ownerDocument.createTextNode(source));
      continue;
    }

    const display = source.startsWith("$$") || source.startsWith("\\[");
    const latex = mathBody(source);
    placeholder.className = display ? "chat-math-display" : "chat-math-inline";
    // The source stays on the element: a selection that runs through the
    // equation quotes this, not the text of KaTeX's boxes, which the browser
    // reads back as one line per stacked box.
    placeholder.dataset.chatMathSource = source;
    if (!katex?.render) {
      placeholder.textContent = source;
      continue;
    }
    try {
      katex.render(latex, placeholder, {
        displayMode: display,
        output,
        throwOnError: false,
        strict: "ignore",
      });
    } catch {
      placeholder.textContent = source;
    }
  }
}

/// Scales a display equation down to its column when it is wider, to no less
/// than 60% of the text size; past that it scrolls, as before. A model often
/// writes a chain of words and arrows as display math ("waking → low ATP demand
/// → electron surplus → …"), and at full size that line ran off the column's
/// edge with its end cut away, on screen and in every filmed answer.
/// Returns whether any equation's size changed, so a caller can skip a layout
/// report that would change nothing.
export function fitDisplayMath(content) {
  let changed = false;
  for (const element of content.querySelectorAll(".chat-math-display")) {
    const before = element.style.fontSize;
    element.style.fontSize = "";
    const available = element.clientWidth;
    // Width does not shrink in step with the font size (spacing and the
    // math font's own metrics), so narrow in a few passes.
    let scale = 1;
    for (let pass = 0; pass < 4 && available && element.scrollWidth > available + 1 && scale > 0.6; pass++) {
      scale = Math.max(0.6, scale * (available / element.scrollWidth) * 0.99);
      element.style.fontSize = `${scale * 100}%`;
    }
    const fitted = scale < 1 ? element.style.fontSize : "";
    element.style.fontSize = fitted;
    if (fitted !== before) changed = true;
  }
  return changed;
}

function mathBody(source) {
  if (source.startsWith("$$")) return source.slice(2, -2);
  if (source.startsWith("$")) return source.slice(1, -1);
  return source.slice(2, -2);
}

/// The picture on a source card: the source's own artwork when the host
/// resolved one, and its kind's letter otherwise, in the kind's colour.
export function sourceThumbnail(document_, card, sizeClass) {
  const frame = document_.createElement("span");
  frame.className = `source-thumbnail ${sizeClass} source-kind-${card.kind || "unclassified"}`;
  frame.setAttribute("aria-hidden", "true");

  if (card.thumbnailURL) {
    const image = document_.createElement("img");
    image.className = "source-thumbnail-image";
    image.src = card.thumbnailURL;
    image.alt = "";
    image.loading = "lazy";
    image.referrerPolicy = "no-referrer";
    image.addEventListener("error", () => {
      image.remove();
      frame.textContent = card.glyph || "S";
    }, { once: true });
    frame.append(image);
  } else {
    frame.textContent = card.glyph || "S";
  }
  return frame;
}

/// The moment a citation points at, read from the link's `t=` query. The
/// assistant is asked to write seconds, but it reads the time off a `[12:34]`
/// transcript marker, so every form that marker suggests is accepted: `754`,
/// `754s`, `12m34s`, `1h2m3s`, `12:34`, `1:02:03`. Anything else is no moment
/// at all rather than a guess, and the citation opens the source from the top.
export function secondsFromTimeAnchor(value) {
  const text = String(value ?? "").trim().toLowerCase();
  if (!text) return null;
  let seconds;
  if (/^\d+(\.\d+)?s?$/.test(text)) {
    seconds = Number.parseFloat(text);
  } else if (/^(\d+:)?\d{1,2}:\d{2}(\.\d+)?$/.test(text)) {
    seconds = text.split(":").reduce((total, part) => total * 60 + Number.parseFloat(part), 0);
  } else {
    const match = text.match(/^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?$/);
    if (!match) return null;
    seconds = Number(match[1] ?? 0) * 3600 + Number(match[2] ?? 0) * 60 + Number.parseFloat(match[3] ?? "0");
  }
  return Number.isFinite(seconds) && seconds >= 0 ? seconds : null;
}

/// `12:34`, or `1:02:03` past the hour, the way the transcript itself marks
/// the moment, so the citation and the reader agree on what to call it.
export function displayTime(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  const pad = (number) => String(number).padStart(2, "0");
  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(secs)}` : `${minutes}:${pad(secs)}`;
}

/// The `page=` query of a source link: the page of a PDF the citation names,
/// one-based and counted within the source's own pages. Anything but a
/// positive whole number is no page. Mirrors `SourceLinkPageAnchor` in the app.
export function pageFromPageAnchor(value) {
  const text = String(value ?? "").trim();
  if (!/^\d{1,6}$/.test(text)) return null;
  const page = Number.parseInt(text, 10);
  return page >= 1 ? page : null;
}

/// A `foreverlm://source/<id>[?t=<moment>][&q=<passage>][&page=<n>]` link taken
/// apart: the library token that names the source, the moment in seconds when
/// the link carries one, the passage a `q=` query quotes, and the page a
/// `page=` query names. The assistant writes the passage as the link's title
/// rather than a query; `passageFromLink` reads that form, and `q=` serves
/// links built by hand or by a tool.
export function sourceLinkFromHref(href) {
  try {
    const url = new URL(String(href ?? ""));
    if (url.protocol.toLowerCase() !== "foreverlm:" || url.hostname.toLowerCase() !== "source") return null;
    const token = decodeURIComponent(url.pathname.replace(/^\/+/, "")).trim();
    if (!token) return null;
    const passage = String(url.searchParams.get("q") ?? "").trim() || null;
    return {
      token,
      seconds: secondsFromTimeAnchor(url.searchParams.get("t")),
      passage,
      page: pageFromPageAnchor(url.searchParams.get("page")),
    };
  } catch {
    return null;
  }
}

/// The passage a citation link quotes: the title the assistant wrote on the
/// link, `[Title](foreverlm://source/ID "excerpt from the source")`, which is
/// taken off the element the first time it is read, before the card's subtitle
/// takes the title over as the hover text; or the `q=` query when the href
/// carries one.
export function passageFromLink(link) {
  if (!("sourcePassage" in link.dataset)) {
    const title = String(link.getAttribute("title") ?? "").trim();
    link.dataset.sourcePassage = title;
  }
  return link.dataset.sourcePassage || sourceLinkFromHref(link.getAttribute("href"))?.passage || null;
}

const hasValue = (value) => value !== null && value !== undefined;

/// How a cited page reads on a marker or a chip: `p. 26`, the page counted
/// within the source's own pages, the way the `[page N]` markers the model
/// read count them. The PDFs here carry no printed folios to translate to.
export const displayPage = (page) => `p. ${page}`;

/// The href a moment or page chip carries: the source link with the place
/// folded in as `t=` or `page=`, which both surfaces read back through
/// `sourceLinkFromHref`.
export function sourceHref(token, seconds = null, page = null) {
  const base = `foreverlm://source/${encodeURIComponent(token)}`;
  if (hasValue(seconds)) return `${base}?t=${Math.round(seconds)}`;
  if (hasValue(page)) return `${base}?page=${page}`;
  return base;
}

const isBlankText = (node) => (
  node.nodeType === Node.TEXT_NODE && !String(node.nodeValue ?? "").trim()
);

function isOnlyChildOf(link, tagName) {
  const parent = link.parentElement;
  if (!parent || parent.tagName !== tagName) return false;
  return Array.from(parent.childNodes).every((node) => node === link || isBlankText(node));
}

const firstContentNode = (element) => (
  Array.from(element.childNodes).find((node) => !isBlankText(node)) ?? null
);

export const isStandaloneSourceLink = (link) => isOnlyChildOf(link, "P");

/// Bold or italic a model puts around a list item's source link, as in
/// `- **[Title](…)**: …`. It says "this is the item's name", which the entry
/// already says.
const ENTRY_EMPHASIS = new Set(["STRONG", "B", "EM", "I"]);

/// The dash, colon or bar a model writes between an entry's title and the
/// rest of its item. The dashes are built from their code points because the
/// website's copy check refuses the characters in the renderer's sources.
const EM_DASH = String.fromCharCode(0x2014);
const ENTRY_JOINER = new RegExp(`^\\s*(?:[${EM_DASH}${String.fromCharCode(0x2013)}:|·,;]|-{1,2})?\\s*`);

/// A source link that opens a list item is that item's name, not a footnote:
/// `- [Title](…), 9 mentions. …` is how a reply lists sources with what it
/// found in each. Drawn as a citation marker, the title the model wrote became
/// `[1]`, so a list of thirteen sources read as thirteen numbers pointing at a
/// footer that repeated all thirteen (product owner, 2026-09-30, of a library
/// search: "any way to have it return these things more nicely?").
///
/// True when nothing comes before the link in its item but blank space --
/// allowing one bold or italic run that holds only the link, and a loose
/// list's paragraph when that paragraph opens the item.
const emphasisAround = (link) => {
  const wrapper = link.parentElement;
  return wrapper && ENTRY_EMPHASIS.has(wrapper.tagName) && isOnlyChildOf(link, wrapper.tagName)
    ? wrapper
    : null;
};

export function isSourceEntryLink(link) {
  const lead = emphasisAround(link) ?? link;
  const host = lead.parentElement;
  if (!host || firstContentNode(host) !== lead) return false;
  if (host.tagName === "LI") return true;
  const item = host.parentElement;
  return host.tagName === "P" && item?.tagName === "LI" && firstContentNode(item) === host;
}

/// U+2060, the word joiner: no line may break at it. Written as its escape,
/// since the character itself is invisible in the source.
const WORD_JOINER = "\u2060";

const joinerFreeCopyDocuments = new WeakSet();

/// A copy of words from a reply leaves out the word joiners that tie each
/// citation chip to its word: they are layout, not text, and would ride along
/// unseen into wherever the words are pasted ("membrane.1 It" with an
/// invisible character inside). Only a selection holding one is touched, so
/// every other copy stays the browser's own. The plain text and the HTML are
/// both written, so a paste into a rich editor keeps its bold and its links.
/// The Mac's ⌘C and its context menu's Copy both raise this event; the
/// footer's Copy answer copies the stored answer, which never held a joiner.
export function installJoinerFreeCopy(document_) {
  if (!document_?.addEventListener || joinerFreeCopyDocuments.has(document_)) return;
  joinerFreeCopyDocuments.add(document_);
  document_.addEventListener("copy", (event) => {
    const selection = document_.defaultView?.getSelection?.();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0 || !event.clipboardData) return;
    const text = selection.toString();
    if (!text.includes(WORD_JOINER)) return;
    const holder = document_.createElement("div");
    for (let index = 0; index < selection.rangeCount; index++) {
      holder.append(selection.getRangeAt(index).cloneContents());
    }
    event.clipboardData.setData("text/plain", text.replaceAll(WORD_JOINER, ""));
    event.clipboardData.setData("text/html", holder.innerHTML.replaceAll(WORD_JOINER, ""));
    event.preventDefault();
  });
}

/// A citation marker belongs after the punctuation that ends its clause, the
/// way a printed footnote does, not between the last word and the period. A
/// word joiner then ties it to that punctuation, so the chip never starts a
/// line of its own. A redecoration finds the joiner already there and adds no
/// second one.
function moveCitationAfterPunctuation(link) {
  // Read the word before the marker first: once the punctuation has been moved
  // in front of the link, the previous sibling is that punctuation, and the
  // space between the word and the marker would survive ("uniporter .[1]").
  const previous = link.previousSibling;
  if (previous?.nodeType === Node.TEXT_NODE) {
    previous.nodeValue = String(previous.nodeValue ?? "").replace(/\s+$/, "");
  }
  const next = link.nextSibling;
  if (next?.nodeType === Node.TEXT_NODE) {
    const punctuation = String(next.nodeValue ?? "").match(/^([.,;:!?]+)/);
    if (punctuation) {
      // A citation written as a sentence of its own after the claim's full stop
      // ("advantage. [Title](…). [Title](…).") already has its punctuation in
      // front of it: moving its own period there too read "advantage..2.4"
      // (product owner, 2026-11-19: "just have a normal sentence, and then
      // after that the clickable bubbles"). It is dropped instead.
      // After a run of chips ("more ([a.org](…), [b.com](…)).") the
      // punctuation goes in front of the whole run, not between its chips.
      const runStart = firstCitationOfRun(link);
      if (!citationAlreadyClosed(runStart, punctuation[1])) {
        const lead = runStart.previousSibling;
        const leadText = lead?.nodeType === Node.TEXT_NODE ? String(lead.nodeValue ?? "") : null;
        if (runStart !== link && leadText?.endsWith(WORD_JOINER)) {
          lead.nodeValue = leadText.slice(0, -WORD_JOINER.length) + punctuation[1] + WORD_JOINER;
        } else {
          runStart.parentNode?.insertBefore(link.ownerDocument.createTextNode(punctuation[1]), runStart);
        }
      }
      next.nodeValue = String(next.nodeValue ?? "").slice(punctuation[1].length);
    }
  }
  const before = link.previousSibling;
  if (!before) return;
  const glued = before.nodeType === Node.TEXT_NODE && String(before.nodeValue ?? "").endsWith(WORD_JOINER);
  if (!glued) link.parentNode?.insertBefore(link.ownerDocument.createTextNode(WORD_JOINER), link);
}

/// Whether what stands before a citation already closes its clause, so the
/// punctuation the reply wrote after the citation would only repeat it: another
/// citation (the second of a run), or a sentence's end. A comma or colon closes
/// it only for a comma or colon, so "A, B and C, [Title]." keeps its period.
function citationAlreadyClosed(link, punctuation) {
  const node = meaningfulSiblingBefore(link);
  if (!node) return false;
  if (node.nodeType === Node.ELEMENT_NODE && node.tagName === "A" && isCitationLink(node)) return true;
  const before = String(node.textContent ?? "").replaceAll(WORD_JOINER, "").replace(/\s+$/, "");
  if (/[.!?…]["'”’)\]]*$/.test(before)) return true;
  return /[,;:]$/.test(before) && /^[,;:]+$/.test(punctuation);
}

/// The node before `link`, past any text that is only spaces and joiners.
function meaningfulSiblingBefore(link) {
  let node = link.previousSibling;
  while (node?.nodeType === Node.TEXT_NODE && String(node.nodeValue ?? "").replaceAll(WORD_JOINER, "").trim() === "") {
    node = node.previousSibling;
  }
  return node;
}

/// The first citation of the run of citations `link` ends, with nothing but
/// spaces between them; `link` itself when it stands alone.
function firstCitationOfRun(link) {
  let first = link;
  for (let node = meaningfulSiblingBefore(first); node; node = meaningfulSiblingBefore(first)) {
    if (node.nodeType !== Node.ELEMENT_NODE || node.tagName !== "A" || !isCitationLink(node)) break;
    first = node;
  }
  return first;
}

/// A link that is, or is about to be drawn as, a citation chip.
function isCitationLink(link) {
  return link.classList.contains("source-citation-marker")
    || link.dataset.webCitation === "true"
    || /^foreverlm:\/\/source\//i.test(link.getAttribute("href") ?? "");
}

/// A link whose words are only a site's name, "nature.com" or
/// "pmc.ncbi.nlm.nih.gov", the label OpenAI's web search gives the citations it
/// writes into a reply.
const SITE_NAME_LABEL = /^(?:www\.)?[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)+$/u;

/// OpenAI's web search writes a citation as the site's name in brackets after
/// the claim, "the metabolism. ([nature.com](https://…))", and a run of them
/// as "([a.org](…), [b.com](…))". The chat draws its citations as numbered
/// chips after the sentence instead, as it does a library source's (product
/// owner, 2026-11-19: "just have a normal sentence, and then after that you
/// can have sort of the clickable bubbles with like 1, 2, 3, and 4"). This
/// takes the brackets and separators away, so each link stands where its chip
/// will be, and marks the web ones for `renderWebCitation`; a link the app
/// pointed at the learner's library copy is a library citation already. Only
/// a bracket holding site-name links and nothing else is unwrapped: a site
/// named in a sentence keeps its words.
export function unwrapBracketedSiteCitations(content) {
  const document_ = content.ownerDocument;
  const walker = document_.createTreeWalker(content, NodeFilter.SHOW_TEXT);
  const openers = [];
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (/\(\s*$/.test(String(node.nodeValue ?? ""))) openers.push(node);
  }
  for (const opener of openers) {
    const links = [];
    const separators = [];
    let closer = null;
    for (let node = opener.nextSibling; node; node = node.nextSibling) {
      if (node.nodeType === Node.ELEMENT_NODE && node.tagName === "A") {
        const href = node.getAttribute("href") ?? "";
        const isWebOrLibrary = /^https?:\/\//i.test(href) || /^foreverlm:\/\/source\//i.test(href);
        if (!isWebOrLibrary || !SITE_NAME_LABEL.test(String(node.textContent ?? "").trim())) break;
        links.push(node);
        continue;
      }
      if (node.nodeType !== Node.TEXT_NODE || links.length === 0) break;
      const text = String(node.nodeValue ?? "");
      if (/^\s*\)/.test(text)) {
        closer = node;
        break;
      }
      if (!/^\s*[,;]?\s*$/.test(text)) break;
      separators.push(node);
    }
    if (!closer || links.length === 0) continue;
    opener.nodeValue = String(opener.nodeValue ?? "").replace(/\s*\(\s*$/, " ");
    for (const separator of separators) separator.nodeValue = "";
    closer.nodeValue = String(closer.nodeValue ?? "").replace(/^\s*\)/, "");
    for (const link of links) {
      if (!/^https?:\/\//i.test(link.getAttribute("href") ?? "")) continue;
      link.dataset.webCitation = "true";
      link.dataset.webTitle = String(link.textContent ?? "").trim();
    }
  }
}

/// One key per web page, whatever tracking query or fragment a citation of it
/// carries, so a chip and the reply's Pages row for the same page agree.
export function webCitationKey(href) {
  try {
    const url = new URL(String(href ?? ""));
    const host = url.host.toLowerCase().replace(/^www\./, "");
    return `${host}${url.pathname.replace(/\/+$/, "")}`;
  } catch {
    return String(href ?? "");
  }
}

/// A web citation (`unwrapBracketedSiteCitations`) drawn as the same round
/// chip as a library source's, with its number, after its sentence's
/// punctuation. Hovering names the site; following it opens the page.
export function renderWebCitation(link, number) {
  const href = link.getAttribute("href") ?? "";
  let site = link.dataset.webTitle ?? "";
  try {
    site = new URL(href).host.replace(/^www\./, "");
  } catch {}
  link.classList.add("source-citation-marker", "web-citation-marker");
  link.dataset.webKey = webCitationKey(href);
  link.textContent = String(number);
  link.title = site;
  link.setAttribute("aria-label", `Web page ${number}: ${site}`);
  moveCitationAfterPunctuation(link);
}

/// The same chip twice in a row says nothing the first did not: a reply that
/// cites a paper by its title and again by its site's name, which the app has
/// pointed at the same library copy, read "mutation.33". The second goes,
/// with the joiner that tied it on.
export function removeRepeatedAdjacentCitations(content) {
  for (const chip of [...content.querySelectorAll("a.source-citation-marker")]) {
    let node = chip.previousSibling;
    while (node?.nodeType === Node.TEXT_NODE && String(node.nodeValue ?? "").replaceAll(WORD_JOINER, "").trim() === "") {
      node = node.previousSibling;
    }
    const same = node?.nodeType === Node.ELEMENT_NODE
      && node.classList.contains("source-citation-marker")
      && node.textContent === chip.textContent
      && node.getAttribute("href") === chip.getAttribute("href");
    if (!same) continue;
    for (let between = chip.previousSibling; between && between !== node; between = chip.previousSibling) {
      between.remove();
    }
    chip.remove();
  }
}

/// The words in a block before a link, back to the citation before it, without
/// the space they end in. Null when the link directly follows another
/// citation: it is then the second of a pair, and neither is part of a sentence.
function wordsBefore(link) {
  let text = "";
  for (let node = link.previousSibling; node && text.length < 80; node = node.previousSibling) {
    if (node.nodeType === Node.ELEMENT_NODE && node.tagName === "A") {
      return text.trim() === "" ? null : text.replace(/\s+$/, "");
    }
    if (node.nodeType === Node.ELEMENT_NODE && node.tagName === "BR") break;
    text = String(node.textContent ?? "") + text;
  }
  return text.replaceAll(WORD_JOINER, "").replace(/\s+$/, "");
}

const ENDS_A_SENTENCE = /[.!?…]["'”’)\]]*$/;
const OPENS_A_PHRASE = new RegExp(`[,:;(\\[“‘${EM_DASH}${String.fromCharCode(0x2013)}]$`);
const CLOSES_A_PHRASE = /^\s*(?:[.,;:!?)\]]|$)/;
const CARRIES_ON = /^(?:\s+\p{Ll}|['’]s(?![\p{L}\p{N}]))/u;
/// English words no claim ends on: after one of these, the linked title is the
/// thing the sentence names ("The second piece is [Title].", "as argued in
/// [Title]"). A reply in another language gets the two shapes above only.
const LEADS_INTO_A_TITLE = new Set([
  "a", "an", "the", "is", "are", "was", "were", "be", "by", "in", "of", "from", "to", "and", "or",
  "as", "than", "see", "called", "titled", "entitled", "named", "with", "for", "on", "at", "about",
  "like", "per", "via", "into", "his", "her", "their", "its", "my", "your", "our", "read",
  "reading", "versus", "vs", "cf",
]);

/// Whether the reply wrote a citation's title as words of its sentence, which
/// it is told not to do and does anyway: "The second piece is [Title].",
/// "written by one author, [Title].", "[Title] argues that ...". A chip in place
/// of those words leaves a sentence with a hole in it ("The second piece is.
/// 9", "one author,. 8": product owner, 2026-11-12: "the interpunction is weird
/// when sources / references are inserted"). Three shapes say so: the title
/// stands between an opening comma, colon or bracket and the punctuation that
/// closes the phrase; it follows a word no claim ends on; or it opens a
/// sentence that carries on in lower case after it. Anything else is a
/// citation placed after its claim, where the title was only ever the link's
/// label.
function titleBelongsToSentence(link) {
  const before = wordsBefore(link);
  if (before === null) return false;
  const after = link.nextSibling ? String(link.nextSibling.textContent ?? "") : "";
  if (before === "" || ENDS_A_SENTENCE.test(before)) return CARRIES_ON.test(after);
  // Link text that opens in lower case, in the middle of a sentence, is the
  // sentence's own words ("The authors had [a small sample], so ..."): a title
  // is capitalised. Drawn as a chip it left "The authors had,6 so the paper"
  // (product owner, 2026-11-15: "it should still say the text; otherwise the
  // sentence isn't complete").
  if (/^\p{Ll}/u.test(String(link.textContent ?? "").trim())) return true;
  if (OPENS_A_PHRASE.test(before)) return CLOSES_A_PHRASE.test(after);
  const lastWord = before.match(/([\p{L}'’]+)$/u)?.[1].toLowerCase();
  return lastWord !== undefined && LEADS_INTO_A_TITLE.has(lastWord);
}

/// Before a link is drawn as a citation chip: when its title is part of the
/// sentence (`titleBelongsToSentence`), the title stays in the sentence as
/// plain words and the chip follows it. Decided once per link, while the link
/// still holds the words the reply wrote; a redecoration finds the decision on
/// the link and leaves it.
export function keepTitleWrittenIntoSentence(link) {
  if (link.dataset.sourceWords) return;
  const words = String(link.textContent ?? "").trim();
  const keep = words !== "" && titleBelongsToSentence(link);
  link.dataset.sourceWords = keep ? "kept" : "dropped";
  if (keep) link.parentNode?.insertBefore(link.ownerDocument.createTextNode(words), link);
}

/// The place a citation points at, spelled for a hover line ("At 12:34",
/// "Page 26"), a marker ("3 · 12:34", "3 · p. 26") or a card's subtitle
/// ("From 12:34", "Page 26"). A moment wins when a link somehow carries both.
/// A marker in a reply that cites one source only drops the number
/// ("12:34", "p. 26"): with nothing to tell apart, it is noise beside the
/// place. A marker with no place keeps it, since the number is all it has.
/// The marker is a round chip, so it carries no brackets.
const placeLine = (seconds, page) => {
  if (hasValue(seconds)) return `At ${displayTime(seconds)}`;
  if (hasValue(page)) return `Page ${page}`;
  return null;
};
const placeDetail = (seconds, page) => {
  if (hasValue(seconds)) return `, at ${displayTime(seconds)}`;
  if (hasValue(page)) return `, page ${page}`;
  return "";
};
const citationMarker = (number, seconds, page, numbered = true) => {
  const prefix = numbered ? `${number} · ` : "";
  if (hasValue(seconds)) return `${prefix}${displayTime(seconds)}`;
  if (hasValue(page)) return `${prefix}${displayPage(page)}`;
  return String(number);
};
const cardTitle = (card, seconds = null, page = null) => {
  const lines = [card.title];
  if (card.subtitle) lines.push(card.subtitle);
  const place = placeLine(seconds, page);
  if (place) lines.push(place);
  return lines.join("\n");
};
const cardDetail = (card, number, seconds = null, page = null) => (
  `${number}: ${card.title}${card.subtitle ? `. ${card.subtitle}` : ""}` + placeDetail(seconds, page)
);

/// A citation whose card has not arrived: already the chip it will be, with
/// the number and place it will show and after the punctuation it will
/// follow, so the line it sits in has its final length from the first paint.
/// The model's own link text was the title, and drawn as a chip it wrapped a
/// line or two that closed again when the card landed. The card adds the
/// hover line and the label, which take no room.
export function renderPendingSourceCitation(link, number, seconds = null, page = null, numbered = true) {
  link.classList.add("source-citation-marker");
  link.textContent = citationMarker(number, seconds, page, numbered);
  moveCitationAfterPunctuation(link);
}

/// What a citation of a library source the chat's notebook does not hold
/// says on hover and to an assistive client. The host sets
/// `card.outsideNotebook` only in a notebook's chat.
export const OUTSIDE_NOTEBOOK_LABEL = "Not in this notebook";

export function renderInlineSourceCitation(link, card, number, seconds = null, page = null, numbered = true) {
  link.classList.remove("source-block-card");
  link.classList.add("source-smart-link", "source-citation-marker");
  link.classList.toggle("source-outside-notebook", card.outsideNotebook === true);
  link.dataset.sourceMode = "citation";
  link.textContent = citationMarker(number, seconds, page, numbered);
  const outside = card.outsideNotebook === true;
  link.title = cardTitle(card, seconds, page) + (outside ? `\n${OUTSIDE_NOTEBOOK_LABEL}` : "");
  link.setAttribute(
    "aria-label",
    `Source ${cardDetail(card, number, seconds, page)}${outside ? `. ${OUTSIDE_NOTEBOOK_LABEL}` : ""}`,
  );
  moveCitationAfterPunctuation(link);
}

/// A list item's leading source link (`isSourceEntryLink`) drawn as the item's
/// heading: the source's thumbnail in the item's gutter where the bullet was,
/// its title, and its byline with the moment or page the link points at. What
/// the reply wrote after the link follows on the next line, minus the dash or
/// colon that joined it to the title. The entry names its source in full, so
/// it takes no number and no row in the footer. With no card yet the title and
/// byline are placeholders, so the item already has its final height.
export function renderSourceEntryLink(link, card, seconds = null, page = null) {
  const document_ = link.ownerDocument;
  emphasisAround(link)?.replaceWith(link);
  link.closest("li")?.classList.add("source-entry");

  link.textContent = "";
  link.classList.remove("source-citation-marker", "source-block-card", "source-block-pending");
  link.classList.add("source-entry-link");
  link.dataset.sourceMode = "entry";

  if (card) {
    link.append(sourceThumbnail(document_, card, "source-entry-thumbnail"));
  } else {
    const frame = document_.createElement("span");
    frame.className = "source-thumbnail source-entry-thumbnail source-thumbnail-pending";
    frame.setAttribute("aria-hidden", "true");
    link.append(frame);
  }
  const title = document_.createElement("span");
  title.className = card ? "source-entry-title" : "source-entry-title source-footer-placeholder";
  title.textContent = card?.title || " ";
  const place = hasValue(seconds) ? `From ${displayTime(seconds)}` : placeLine(null, page);
  const byline = card ? [card.subtitle, place].filter(Boolean).join(" · ") : "";
  const subtitle = document_.createElement("span");
  // A card with no byline keeps the line, empty, so the item keeps the height
  // its placeholder gave it.
  subtitle.className = card ? "source-entry-subtitle" : "source-entry-subtitle source-footer-placeholder";
  subtitle.textContent = byline || " ";
  link.append(title, subtitle);

  const next = link.nextSibling;
  if (next?.nodeType === Node.TEXT_NODE) {
    next.nodeValue = String(next.nodeValue ?? "").replace(ENTRY_JOINER, "");
  }

  if (card) {
    link.title = cardTitle(card, seconds, page);
    link.setAttribute("aria-label", `Open ${card.title}${card.subtitle ? `. ${card.subtitle}` : ""}${placeDetail(seconds, page)}`);
  }
}

/// A list whose every item is a source entry drops its bullets: each item's
/// thumbnail stands where the bullet was. A list that mixes entries with
/// ordinary items keeps them, so the ordinary items still read as a list, and
/// a numbered list keeps its numbers.
export function markSourceEntryLists(content) {
  for (const list of content.querySelectorAll("ul")) {
    const items = Array.from(list.children).filter((child) => child.tagName === "LI");
    const allEntries = items.length > 0 && items.every((item) => item.classList.contains("source-entry"));
    list.classList.toggle("source-entry-list", allEntries);
  }
}

export function renderBlockSourceLink(link, card, seconds = null, page = null) {
  const document_ = link.ownerDocument;
  link.classList.remove("source-citation-marker");
  link.classList.add("source-smart-link", "source-block-card");
  link.dataset.sourceMode = "block";
  link.parentElement?.classList.add("source-card-paragraph");
  link.append(sourceThumbnail(document_, card, "source-block-thumbnail"));

  const copy = document_.createElement("span");
  copy.className = "source-card-copy";
  const title = document_.createElement("span");
  title.className = "source-card-title";
  title.textContent = card.title;
  const subtitle = document_.createElement("span");
  subtitle.className = "source-card-subtitle";
  const place = hasValue(seconds) ? `From ${displayTime(seconds)}` : placeLine(null, page);
  subtitle.textContent = place ? [card.subtitle, place].filter(Boolean).join(" · ") : card.subtitle;
  copy.append(title, subtitle);
  link.append(copy);

  const arrow = document_.createElement("span");
  arrow.className = "source-card-arrow";
  arrow.setAttribute("aria-hidden", "true");
  arrow.textContent = "›";
  link.append(arrow);
}

/// A standalone link drawn as the caption of the picture it stands beside,
/// which comes from the same source (`captionSourceImages`): a play mark for
/// a moment, the place, the source's title and the arrow, on one line under
/// the picture. No thumbnail: the picture above is the thumbnail. With no
/// card yet the title is a placeholder, so the caption already has its
/// height; the place is read off the link and needs no card.
export function renderCaptionSourceLink(link, card, seconds = null, page = null) {
  const document_ = link.ownerDocument;
  link.textContent = "";
  link.classList.remove("source-citation-marker", "source-block-card", "source-block-pending");
  link.classList.add("source-smart-link", "source-caption-link");
  link.dataset.sourceMode = "caption";

  if (hasValue(seconds)) {
    const play = document_.createElement("span");
    play.className = "source-caption-play";
    play.setAttribute("aria-hidden", "true");
    play.textContent = "▶";
    link.append(play);
  }
  const place = hasValue(seconds) ? `From ${displayTime(seconds)}` : placeLine(null, page);
  if (place) {
    const placeText = document_.createElement("span");
    placeText.className = "source-caption-place";
    placeText.textContent = place;
    link.append(placeText);
  }
  const title = document_.createElement("span");
  title.className = card ? "source-caption-title" : "source-caption-title source-footer-placeholder";
  title.textContent = card?.title || "\u00a0";
  link.append(title);

  const arrow = document_.createElement("span");
  arrow.className = "source-card-arrow";
  arrow.setAttribute("aria-hidden", "true");
  arrow.textContent = "›";
  link.append(arrow);

  if (card) {
    link.setAttribute("aria-label", `Open ${card.title}${placeDetail(seconds, page)}`);
  }
}

/// The block card's own structure for a standalone link whose card has not
/// arrived: frame, two placeholder lines and the arrow, so the paragraph is
/// already the height the card will be. The card replaces it in place.
export function renderPendingBlockSourceLink(link) {
  const document_ = link.ownerDocument;
  link.textContent = "";
  link.classList.add("source-smart-link", "source-block-card", "source-block-pending");
  link.parentElement?.classList.add("source-card-paragraph");

  const frame = document_.createElement("span");
  frame.className = "source-thumbnail source-block-thumbnail source-thumbnail-pending";
  frame.setAttribute("aria-hidden", "true");
  link.append(frame);

  const copy = document_.createElement("span");
  copy.className = "source-card-copy";
  const title = document_.createElement("span");
  title.className = "source-card-title source-footer-placeholder";
  title.textContent = "\u00a0";
  const subtitle = document_.createElement("span");
  subtitle.className = "source-card-subtitle source-footer-placeholder";
  subtitle.textContent = "\u00a0";
  copy.append(title, subtitle);
  link.append(copy);

  const arrow = document_.createElement("span");
  arrow.className = "source-card-arrow";
  arrow.setAttribute("aria-hidden", "true");
  arrow.textContent = "›";
  link.append(arrow);
}

export function renderInvalidSourceLink(link) {
  const wasEntry = link.dataset.sourceMode === "entry";
  // The title already stands in the sentence as words: only the chip goes,
  // with the joiner that tied it to them.
  if (link.dataset.sourceWords === "kept") {
    const glue = link.previousSibling;
    if (glue?.nodeType === Node.TEXT_NODE && String(glue.nodeValue ?? "").endsWith(WORD_JOINER)) {
      glue.nodeValue = String(glue.nodeValue).slice(0, -WORD_JOINER.length);
    }
    link.remove();
    return;
  }
  const replacement = link.ownerDocument.createElement("span");
  replacement.className = "source-invalid-link";
  replacement.textContent = "Unavailable source";
  replacement.title = "This source link does not match a record in the library.";
  replacement.setAttribute("aria-label", replacement.title);
  // An entry whose source turned out not to exist is an ordinary item again,
  // with back the dash the entry took off the text after it.
  if (wasEntry) link.closest("li")?.classList.remove("source-entry");
  link.replaceWith(replacement);
  // A citation drawn as a chip before its card arrived was glued to the word
  // before it; the words "Unavailable source" are no chip, so the joiner
  // becomes the space it took.
  const previous = replacement.previousSibling;
  if (previous?.nodeType === Node.TEXT_NODE && String(previous.nodeValue ?? "").endsWith(WORD_JOINER)) {
    previous.nodeValue = `${String(previous.nodeValue).slice(0, -WORD_JOINER.length)} `;
  }
  const next = replacement.nextSibling;
  const nextIsText = next && !isBlankText(next)
    && !(next.nodeType === Node.ELEMENT_NODE && /^(UL|OL|P|DIV|BLOCKQUOTE|PRE|TABLE)$/.test(next.tagName));
  if (wasEntry && nextIsText) replacement.after(link.ownerDocument.createTextNode(` ${EM_DASH} `));
}

/// The list under a reply that introduces a source, so the marker in the
/// sentence has somewhere to lead the first time it appears. Which citations
/// reach here is the caller's decision -- a reply that only cites what the
/// conversation already listed gets no footer at all. A source cited at
/// particular moments or pages lists them under its title as chips, each a
/// link to that place; `openPlace` receives the chip's token and the place --
/// `{ seconds }` for a moment, `{ page, passage }` for a page -- so the click
/// goes where the chip says and not where the row does. A source the chat's
/// notebook does not hold (`card.outsideNotebook`) is marked as its marker is,
/// and, when the host can add it (`addToNotebook`), carries **Add to
/// Notebook** beside its row; the host sends the card again once it is in.
export function renderSourcesFooter(content, citations, openPlace = null, addToNotebook = null) {
  content.querySelector(".source-citations-footer")?.remove();
  if (citations.length === 0) return;
  const document_ = content.ownerDocument;

  const section = document_.createElement("section");
  section.className = "source-citations-footer";
  section.setAttribute("aria-label", "Sources");

  const heading = document_.createElement("div");
  heading.className = "source-citations-heading";
  heading.textContent = "Sources";
  section.append(heading);

  const list = document_.createElement("ol");
  list.className = "source-citations-list";
  for (const { number, card, href, token, moments = [], pages = [], pending = false } of citations) {
    const item = document_.createElement("li");
    if (pending) {
      // A row for a citation whose card the host has not sent yet: the same
      // grid, index, thumbnail frame, two text lines and moment chips as the
      // finished row, so the footer is already its final height when the
      // message is first measured. The card fills it in without moving anything.
      section.setAttribute("aria-busy", "true");
      item.className = "source-footer-pending";
      item.setAttribute("aria-hidden", "true");
      const row = document_.createElement("span");
      row.className = "source-footer-link";
      const index = document_.createElement("span");
      index.className = "source-footer-index";
      index.textContent = String(number);
      const frame = document_.createElement("span");
      frame.className = "source-thumbnail source-footer-thumbnail source-thumbnail-pending";
      const copy = document_.createElement("span");
      copy.className = "source-footer-copy";
      const title = document_.createElement("span");
      title.className = "source-footer-title source-footer-placeholder";
      title.textContent = "\u00a0";
      const subtitle = document_.createElement("span");
      subtitle.className = "source-footer-subtitle source-footer-placeholder";
      subtitle.textContent = "\u00a0";
      copy.append(title, subtitle);
      if (moments.length > 0 || pages.length > 0) {
        const chips = document_.createElement("span");
        chips.className = "source-footer-moments";
        for (const seconds of moments) {
          const chip = document_.createElement("span");
          chip.className = "source-footer-moment";
          chip.textContent = displayTime(seconds);
          chips.append(chip);
        }
        for (const { page } of pages) {
          const chip = document_.createElement("span");
          chip.className = "source-footer-moment source-footer-page";
          chip.textContent = displayPage(page);
          chips.append(chip);
        }
        copy.append(chips);
      }
      row.append(index, frame, copy);
      item.append(row);
      list.append(item);
      continue;
    }
    const link = document_.createElement("a");
    link.className = "source-footer-link";
    link.href = href;
    link.dataset.sourceCard = "true";
    link.dataset.sourceMode = "footer";
    link.title = cardTitle(card);
    link.setAttribute("aria-label", `Open source ${cardDetail(card, number)}`);

    const index = document_.createElement("span");
    index.className = "source-footer-index";
    index.textContent = String(number);
    link.append(index, sourceThumbnail(document_, card, "source-footer-thumbnail"));

    const copy = document_.createElement("span");
    copy.className = "source-footer-copy";
    const title = document_.createElement("span");
    title.className = "source-footer-title";
    title.textContent = card.title;
    copy.append(title);
    if (card.subtitle) {
      const subtitle = document_.createElement("span");
      subtitle.className = "source-footer-subtitle";
      subtitle.textContent = card.subtitle;
      copy.append(subtitle);
    }
    if (moments.length > 0 || pages.length > 0) {
      const row = document_.createElement("span");
      row.className = "source-footer-moments";
      row.setAttribute("role", "list");
      const addChip = (chip, open) => {
        chip.setAttribute("role", "link");
        chip.tabIndex = 0;
        chip.addEventListener("click", open);
        chip.addEventListener("keydown", (event) => {
          if (event.key === "Enter" || event.key === " ") open(event);
        });
        row.append(chip);
      };
      for (const seconds of moments) {
        const chip = document_.createElement("span");
        chip.className = "source-footer-moment";
        chip.dataset.sourceMoment = String(Math.round(seconds));
        chip.textContent = displayTime(seconds);
        chip.title = `Open at ${displayTime(seconds)}`;
        chip.setAttribute("aria-label", `Open ${card.title} at ${displayTime(seconds)}`);
        addChip(chip, (event) => {
          event.preventDefault();
          event.stopPropagation();
          if (openPlace) openPlace(token, { seconds });
          else window.location.href = sourceHref(token, seconds);
        });
      }
      // A page chip carries the excerpt the citation quoted, so following it
      // flashes the words on that page and not only the page.
      for (const { page, passage = null } of pages) {
        const chip = document_.createElement("span");
        chip.className = "source-footer-moment source-footer-page";
        chip.dataset.sourcePage = String(page);
        if (passage) chip.dataset.sourcePassage = passage;
        chip.textContent = displayPage(page);
        chip.title = `Open at page ${page}`;
        chip.setAttribute("aria-label", `Open ${card.title} at page ${page}`);
        addChip(chip, (event) => {
          event.preventDefault();
          event.stopPropagation();
          if (openPlace) openPlace(token, { page, passage });
          else window.location.href = sourceHref(token, null, page);
        });
      }
      copy.append(row);
    }
    link.append(copy);
    item.append(link);
    if (card.outsideNotebook === true) {
      item.classList.add("source-footer-outside");
      link.classList.add("source-outside-notebook");
      link.title = `${link.title}\n${OUTSIDE_NOTEBOOK_LABEL}`;
      link.setAttribute("aria-label", `${link.getAttribute("aria-label")}. ${OUTSIDE_NOTEBOOK_LABEL}`);
      if (addToNotebook) {
        const add = document_.createElement("button");
        add.type = "button";
        add.className = "source-footer-add";
        add.textContent = "Add to Notebook";
        add.title = `Add ${card.title} to this notebook`;
        add.dataset.sourceToken = token;
        add.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          add.disabled = true;
          add.textContent = "Adding";
          addToNotebook(token);
        });
        item.append(add);
      }
    }
    list.append(item);
  }
  section.append(list);
  content.append(section);
}
