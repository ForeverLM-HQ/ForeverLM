// The Mac app's whole chat transcript as one page.
//
// Until this page, every reply was its own WKWebView inside a lazy native list.
// The list had to place a reply before the reply's page could say how tall it
// was, so it guessed, the page answered a few frames later, and the difference
// moved the text under the learner's scroll. Here the browser lays out the
// whole conversation, scrolls it, and keeps the learner's place when something
// above changes, the way Codex's and Claude's desktop apps draw theirs.
//
// Swift owns the conversation and every action. It sends blocks as data
// (`window.transcriptApply`), and the page draws them and posts back what the
// learner did (`webkit.messageHandlers.action`), naming the block it was on.
// Replies render with the same renderer the per-reply pages use
// (`createChatRenderer`), so citations, source cards, pictures, equations and
// visualizations draw exactly as they did.

import { createChatRenderer } from "./chat-render.js";
import { installSelectionActions } from "./mac-selection-actions.js";

const post = (name, body) => window.webkit?.messageHandlers?.[name]?.postMessage(body);

const headRoot = document.getElementById("head");
const blocksRoot = document.getElementById("blocks");
const tailRoot = document.getElementById("tail");
const reserve = document.getElementById("reserve");
const jumpButton = document.getElementById("jump-latest");

// ---------------------------------------------------------------------------
// Keeping the learner's place

/// What the learner is looking at: the deepest element under the top of the
/// viewport, with the elements above it in the tree to fall back on when a
/// re-render replaces it, and where it stood. A change of size anywhere moves
/// the page back by however far that element moved, before the frame paints,
/// so the words on screen stay where they are. WebKit has no CSS scroll
/// anchoring (`overflow-anchor`), so this is that, by hand.
///
/// Each element in the chain keeps its own top. A streamed token re-renders
/// the reply's paragraphs, so the deepest element is usually gone by the next
/// correction; its parent is then measured against where the parent stood,
/// never against where the gone paragraph stood. Measured against the
/// paragraph, the page jumped back to the start of the reply on every token
/// while the learner scrolled through it.
const anchor = { chain: [], active: false };

/// The last scroll the page made itself, so `scroll` events it causes are not
/// read as the learner's.
let programmaticScrollAt = 0;

function scrollByAnchorDelta() {
  if (!anchor.active) return;
  const held = anchor.chain.find((candidate) => candidate.element.isConnected);
  if (!held) return;
  const delta = held.element.getBoundingClientRect().top - held.top;
  if (Math.abs(delta) < 0.5) return;
  programmaticScrollAt = performance.now();
  window.scrollBy(0, delta);
}

function captureAnchor() {
  anchor.chain = [];
  anchor.active = false;
  // At the very top nothing above can move what is seen.
  if (window.scrollY <= 0) return;
  const probe = 6;
  let parent = blocksRoot;
  for (let depth = 0; depth < 8; depth += 1) {
    let found = null;
    for (const child of parent.children) {
      const box = child.getBoundingClientRect();
      if (box.height === 0) continue;
      if (box.bottom > probe) {
        found = box.top <= probe ? child : null;
        break;
      }
    }
    if (!found) break;
    anchor.chain.unshift({ element: found, top: found.getBoundingClientRect().top });
    parent = found;
  }
  anchor.active = anchor.chain.length > 0;
}

/// Runs a change to the page with the learner's place kept across it.
function keepingPlace(change) {
  captureAnchor();
  change();
  scrollByAnchorDelta();
  captureAnchor();
}

// Sizes that change on their own after a render (a picture loading, a source
// card resolving, a font arriving) are caught here, after layout and before
// paint, which is what makes the correction invisible.
const resizeObserver = new ResizeObserver(() => {
  scrollByAnchorDelta();
  captureAnchor();
  updateJumpButton();
});
resizeObserver.observe(blocksRoot);
resizeObserver.observe(tailRoot);

window.addEventListener("scroll", () => {
  captureAnchor();
  updateJumpButton();
}, { passive: true });

window.addEventListener("resize", () => {
  // A narrower column rewraps everything; the element at the top keeps its
  // place, as it does for any other change.
  scrollByAnchorDelta();
  captureAnchor();
  updateJumpButton();
});

// ---------------------------------------------------------------------------
// Scrolling on request

function maxScrollY() {
  return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
}

function scrollToY(y, animated) {
  programmaticScrollAt = performance.now();
  window.scrollTo({ top: Math.max(0, Math.min(y, maxScrollY())), behavior: animated ? "smooth" : "auto" });
  if (!animated) captureAnchor();
}

/// Brings a block into view: "bottom" puts its end at the foot of the screen
/// (a chat opened from history), "center" its middle at the middle (a message
/// just sent, with the reply to stream under it), "top" its start at the top.
window.transcriptScrollTo = (id, position = "bottom", animated = false, opensLane = false) => {
  if (opensLane && id) {
    keepingPlace(() => {
      laneChoices.set(id, true);
      applyLaneFolds();
    });
  }
  const element = id ? blocksRoot.querySelector(`[data-block-id="${CSS.escape(id)}"]`) : null;
  if (!element) {
    if (position === "bottom") scrollToY(maxScrollY(), animated);
    return;
  }
  const box = element.getBoundingClientRect();
  const top = box.top + window.scrollY;
  if (position === "top") {
    scrollToY(top - 12, animated);
  } else if (position === "center") {
    scrollToY(top + box.height / 2 - window.innerHeight / 2, animated);
  } else {
    // The end of the block, not of the page: the reserve under the last row
    // stays below the fold.
    scrollToY(top + box.height - window.innerHeight + 24, animated);
  }
};

function isScrolledUp() {
  const reserveHeight = reserve.getBoundingClientRect().height;
  const distance = document.documentElement.scrollHeight - (window.scrollY + window.innerHeight);
  return distance > reserveHeight + 120;
}

let lastScrolledUp = null;
function updateJumpButton() {
  const up = isScrolledUp();
  if (up === lastScrolledUp) return;
  lastScrolledUp = up;
  jumpButton.classList.toggle("visible", up);
}

jumpButton.addEventListener("click", (event) => {
  event.preventDefault();
  const last = blocksRoot.lastElementChild;
  window.transcriptScrollTo(last?.dataset.blockId ?? null, "bottom", true);
});

// ---------------------------------------------------------------------------
// The renderer

const renderer = createChatRenderer({
  mathOutput: document.documentElement.dataset.mathOutput || "html",
  requestSourceCards: (tokens) => post("sourceCards", tokens),
  requestSourceImages: (tokens) => post("sourceImages", tokens),
  copySourceImage: (token) => {
    post("copySourceImage", token);
    return true;
  },
  zoomSourceImage: (token, img) => post("zoomSourceImage", { token, alt: img.alt ?? "" }),
  openSourceImageBeside: (token, img) => post("openSourceImageBeside", { token, alt: img.alt ?? "" }),
  openSource: (token, { seconds = null, passage = null, page = null } = {}) =>
    post("openSource", { token, seconds, passage, page }),
  openWebLink: (url, title) => post("webLinks", { url, title }),
  // Sizes that settle later are caught by the ResizeObserver above.
  onLayoutChange: () => {},
  runsVisualizations: true,
});

window.setSourceCards = (cards) => keepingPlace(() => renderer.setSourceCards(cards));
window.setSourceImages = (images) => keepingPlace(() => renderer.setSourceImages(images));

/// The frames video moments were asked at, by "sourceID@seconds".
const momentFrames = new Map();
const requestedMomentFrames = new Set();
window.setMomentFrames = (frames) => keepingPlace(() => {
  for (const [key, url] of Object.entries(frames ?? {})) {
    momentFrames.set(key, url);
    for (const thumb of blocksRoot.querySelectorAll(`[data-moment-key="${CSS.escape(key)}"]`)) {
      thumb.replaceChildren(momentImage(url));
    }
  }
});

/// Selecting words in a reply offers the same three actions the per-reply
/// pages did; the post says which message the words were read in.
function selectionMessageID() {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) return null;
  const nodes = [selection.getRangeAt(0).commonAncestorContainer, selection.anchorNode];
  for (const node of nodes) {
    const element = node?.nodeType === 1 ? node : node?.parentElement;
    const owner = element?.closest?.("[data-message-id]");
    if (owner) return owner.dataset.messageId;
  }
  return null;
}

window.requestSelectionAction = installSelectionActions({
  post: (payload) => post("selectionAction", { ...payload, messageID: selectionMessageID() }),
});

// ---------------------------------------------------------------------------
// Drawing

const icons = {
  copy: '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5.25" y="5.25" width="8" height="8.5" rx="1.6"/><path d="M10.75 5.25V3.9c0-.88-.72-1.6-1.6-1.6H4.1c-.88 0-1.6.72-1.6 1.6v5.4c0 .88.72 1.6 1.6 1.6h1.15"/></svg>',
  check: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7"/></svg>',
  side: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 2.75v4.5c0 1.24 1 2.25 2.25 2.25h6.5"/><path d="M9.75 6.75l2.75 2.75-2.75 2.75"/></svg>',
  more: '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="3.5" cy="8" r="1.15"/><circle cx="8" cy="8" r="1.15"/><circle cx="12.5" cy="8" r="1.15"/></svg>',
  edit: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M10.6 2.9l2.5 2.5-7.4 7.4-3.1.6.6-3.1z"/></svg>',
  chevronRight: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6 3.5L10.5 8 6 12.5"/></svg>',
  chevronDown: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 6L8 10.5 12.5 6"/></svg>',
  arrowDown: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.75v10.5"/><path d="M3.75 9L8 13.25 12.25 9"/></svg>',
  warning: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.2l6.2 11H1.8z"/><path d="M8 6.5v3"/><circle cx="8" cy="11.4" r=".4"/></svg>',
  skip: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 3.5l5 4.5-5 4.5z"/><path d="M11.5 3.5v9"/></svg>',
  play: '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="2" y="3.5" width="12" height="9" rx="1.6"/><path d="M7 6.3v3.4L9.8 8z"/></svg>',
  doc: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 2.25h5.5L12.5 5.2v8.55H4z"/><path d="M9.5 2.25V5.2h3"/><path d="M6 8.25h4.5M6 10.5h4.5"/></svg>',
  stack: '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="2.75" y="5.25" width="10.5" height="8" rx="1.6"/><path d="M4.5 3.25h7"/></svg>',
  magnify: '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="3.75"/><path d="M9.8 9.8l3.2 3.2"/></svg>',
  back: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4.5L3 7.5l3 3"/><path d="M3.5 7.5h6.25a3 3 0 010 6H8"/></svg>',
  deeper: '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.75"/><path d="M6 6l4 4M10 6.6V10H6.6"/></svg>',
  next: '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.75"/><path d="M5.5 8h5M8.4 5.9L10.5 8l-2.1 2.1"/></svg>',
};
jumpButton.innerHTML = icons.arrowDown;

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

function iconButton(icon, label, onClick, className = "") {
  const button = element("button", `icon-button ${className}`.trim());
  button.type = "button";
  button.innerHTML = icons[icon];
  button.title = label;
  button.setAttribute("aria-label", label);
  button.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    onClick(button);
  });
  return button;
}

function rectOf(node) {
  const box = node.getBoundingClientRect();
  return { x: box.left, y: box.top, width: box.width, height: box.height };
}

function sendAction(type, blockID, extra = {}) {
  post("action", { type, blockID, ...extra });
}

/// A copy button shows a tick for two seconds once Swift has the words.
function flashCopied(button) {
  button.innerHTML = icons.check;
  button.classList.add("copied");
  clearTimeout(button.copiedTimer);
  button.copiedTimer = setTimeout(() => {
    button.innerHTML = icons.copy;
    button.classList.remove("copied");
  }, 2000);
}

/// One drawn block, by id: its element, the data it was drawn from, and what
/// each of its prose parts last rendered, so a streamed token re-renders one
/// reply and leaves the rest of the page alone.
const drawn = new Map();
/// The learner opened or closed a reply's steps; that outranks the default.
const foldChoices = new Map();

/// "Added 3 articles to context", opening onto the sources by name, each
/// opening its source in the Reader.
function addedRow(added) {
  const row = element("div", "user-added");
  const toggle = element("button", "user-added-toggle", added.summary);
  toggle.type = "button";
  const list = element("div", "user-added-list");
  list.hidden = true;
  for (const source of added.sources) {
    const name = element("button", "user-added-source", source.title);
    name.type = "button";
    name.title = `Open ${source.title} in the reader`;
    name.addEventListener("click", (event) => {
      event.preventDefault();
      sendAction("openContextSource", null, { sourceID: source.id });
    });
    list.append(name);
  }
  toggle.addEventListener("click", (event) => {
    event.preventDefault();
    keepingPlace(() => {
      list.hidden = !list.hidden;
    });
  });
  row.append(toggle, list);
  return row;
}

function momentImage(url) {
  const img = element("img");
  img.src = url;
  img.alt = "";
  return img;
}

/// The moment of a video a question was asked at: the frame the tutor was
/// shown, the time and the video's name. A click plays it from there.
function momentButton(moment) {
  const button = element("button", "user-moment");
  button.type = "button";
  button.title = `Play from ${moment.clock}`;
  const key = `${moment.sourceID}@${moment.seconds}`;
  const thumb = element("span", "user-moment-thumb");
  thumb.dataset.momentKey = key;
  if (momentFrames.has(key)) thumb.append(momentImage(momentFrames.get(key)));
  else thumb.innerHTML = icons.play;
  const words = element("span", "user-moment-words");
  words.append(element("span", "user-moment-clock", moment.clock), element("span", "user-moment-title", moment.title));
  button.append(thumb, words);
  button.addEventListener("click", (event) => {
    event.preventDefault();
    sendAction("openMoment", null, { sourceID: moment.sourceID, seconds: moment.seconds });
  });
  return button;
}

function requestMomentFrames(moments) {
  const wanted = moments.filter((moment) => {
    const key = `${moment.sourceID}@${moment.seconds}`;
    if (!moment.hasFrame || momentFrames.has(key) || requestedMomentFrames.has(key)) return false;
    requestedMomentFrames.add(key);
    return true;
  });
  if (wanted.length) post("momentFrames", wanted.map(({ sourceID, seconds }) => ({ sourceID, seconds })));
}

function drawUser(block, entry) {
  const root = entry.element;
  root.className = "block user";
  if (entry.images) {
    renderer.forgetContainer(entry.images);
    entry.images = null;
  }
  root.replaceChildren();
  const column = element("div", "user-column");
  if (block.added) column.append(addedRow(block.added));
  if (block.moments?.length) {
    const moments = element("div", "user-moments");
    for (const moment of block.moments) moments.append(momentButton(moment));
    column.append(moments);
    requestMomentFrames(block.moments);
  }
  if (block.images) {
    // The pictures go through the reply renderer, which resolves them from
    // the same store the model read them from and opens one full-window.
    const images = element("div", "user-images chat-rendered");
    images.dataset.messageId = block.messageID;
    renderer.render(images, block.images, {});
    entry.images = images;
    column.append(images);
  }
  if (block.passage) {
    const quote = element("button", "user-passage", `“${block.passage}”`);
    quote.type = "button";
    quote.title = "Open in the Reader";
    quote.addEventListener("click", (event) => {
      event.preventDefault();
      sendAction("openPassage", block.id);
    });
    column.append(quote);
  }
  if (block.text) {
    const bubble = element("div", "user-bubble");
    bubble.dataset.messageId = block.messageID;
    const text = element("div", "user-text", block.text);
    bubble.append(text);
    if (block.collapses) {
      bubble.classList.add("collapsed");
      const toggle = element("button", "user-more", "Show more");
      toggle.type = "button";
      toggle.addEventListener("click", (event) => {
        event.preventDefault();
        keepingPlace(() => {
          const collapsed = bubble.classList.toggle("collapsed");
          toggle.textContent = collapsed ? "Show more" : "Show less";
        });
      });
      bubble.append(toggle);
    }
    column.append(bubble);
  }
  if (block.guess) {
    column.append(element("div", "user-guess", `Your guess: ${block.guess}`));
  }
  if (block.text) {
    const actions = element("div", "user-actions");
    if (block.canEdit) {
      actions.append(iconButton("edit", "Edit message", () => sendAction("editMessage", block.id)));
    }
    actions.append(iconButton("copy", "Copy message", (button) => {
      sendAction("copyMessage", block.id);
      flashCopied(button);
    }));
    column.append(actions);
  }
  root.append(column);
}

function drawWork(part, previous) {
  const wrapper = previous?.element ?? element("div", "work");
  // The fold redraws while the turn works; the cards of the pages it wrote
  // stay put while they are the same, so an animation playing in one is not
  // reloaded by every step.
  const pagesJSON = part.pages?.length ? JSON.stringify(part.pages) : null;
  const kept = wrapper.querySelector(":scope > .page-cards");
  const keepsCards = Boolean(kept && pagesJSON && kept.dataset.pagesJson === pagesJSON);
  for (const child of [...wrapper.children]) {
    if (!(keepsCards && child === kept)) child.remove();
  }
  const add = (node) => (keepsCards ? wrapper.insertBefore(node, kept) : wrapper.append(node));
  wrapper.dataset.partId = part.id;
  const choice = foldChoices.get(part.id);
  const expanded = choice ?? part.opensWhileLive;
  const line = element("button", "work-line");
  line.type = "button";
  line.setAttribute("aria-expanded", String(expanded));
  if (part.running) line.append(element("span", "work-spinner"));
  line.append(element("span", "work-title", part.title));
  if (part.failed) line.append(element("span", "work-failed", part.failed));
  const chevron = element("span", "work-chevron");
  chevron.innerHTML = expanded ? icons.chevronDown : icons.chevronRight;
  line.append(chevron);
  line.title = expanded ? "Hide the steps" : "Show the steps";
  line.addEventListener("click", (event) => {
    event.preventDefault();
    keepingPlace(() => {
      foldChoices.set(part.id, !expanded);
      drawWork(part, { element: wrapper });
    });
  });
  add(line);
  if (expanded) {
    const steps = element("div", "work-steps");
    let card = null;
    for (const [index, step] of (part.steps ?? []).entries()) {
      if (step.kind === "thinking") {
        card = null;
        const reasoning = element("div", "work-reasoning");
        for (const paragraph of step.paragraphs ?? []) reasoning.append(element("p", null, paragraph));
        steps.append(reasoning);
        continue;
      }
      if (!card) {
        card = element("div", "work-card");
        steps.append(card);
      }
      const row = element("div", `work-step ${step.state}`);
      const mark = element("span", "work-step-mark");
      if (step.state === "running") mark.append(element("span", "work-spinner"));
      else mark.innerHTML = step.state === "failed" ? icons.warning : icons.check;
      row.append(mark, element("span", "work-step-title", step.title));
      if (step.summary) row.append(element("span", "work-step-summary", step.summary));
      card.append(row);
      if (part.preview && index === part.previewStep) card.append(browserPreview(part));
    }
    add(steps);
  } else if (part.preview && (!part.settled || part.running)) {
    // Folded while the turn still runs: the learner watches the chat work
    // in the Browser without opening the steps.
    add(browserPreview(part));
  }
  if (part.settled) add(element("div", "work-rule"));
  (part.setup ?? []).forEach((need, index) => add(setupCard(need, index, part.id)));
  if (pagesJSON && !keepsCards) {
    const cards = pageCards(part.pages);
    cards.dataset.pagesJson = pagesJSON;
    wrapper.append(cards);
  }
  return { kind: "work", element: wrapper, json: JSON.stringify(part) };
}

/// The newest browser step's picture; a click opens the tab in the Browser.
function browserPreview(part) {
  const button = element("button", "browser-preview");
  button.type = "button";
  button.title = "Open this tab in the Browser";
  const img = element("img");
  img.src = part.preview;
  img.alt = "Browser preview";
  button.append(img);
  if (part.running) button.append(element("span", "work-spinner browser-preview-spinner"));
  button.addEventListener("click", (event) => {
    event.preventDefault();
    sendAction("revealBrowser", null);
  });
  return button;
}

/// A plugin a failed step needed, and the button that sets it up.
function setupCard(need, index, partID) {
  const card = element("div", "inline-card setup-card");
  const words = element("div", "inline-card-words");
  words.append(element("div", "inline-card-title", need.title), element("div", "inline-card-body", need.body));
  const button = element("button", "pill-button prominent", need.action);
  button.type = "button";
  button.title = need.help;
  button.addEventListener("click", (event) => {
    event.preventDefault();
    const blockID = card.closest("[data-block-id]")?.dataset.blockId ?? null;
    sendAction("pluginSetup", blockID, { partID, index });
  });
  card.append(words, button);
  return card;
}

/// The Pages a reply wrote, a card each: its title, "Page", and Open. An
/// animation the reply saved plays in its card instead (`animationCard`).
function pageCards(pages) {
  const list = element("div", "page-cards");
  for (const page of pages) {
    if (page.kind === "animation" && page.url) {
      list.append(animationCard(page));
      continue;
    }
    const card = element("button", "page-card");
    card.type = "button";
    card.title = `Open ${page.title}`;
    const glyph = element("span", "page-card-glyph");
    glyph.innerHTML = icons.doc;
    const words = element("span", "page-card-words");
    words.append(element("span", "page-card-title", page.title), element("span", "page-card-kind", "Page"));
    card.append(glyph, words, element("span", "page-card-open", "Open"));
    card.addEventListener("click", (event) => {
      event.preventDefault();
      sendAction("openPage", null, { pageID: page.id });
    });
    list.append(card);
  }
  return list;
}

/// An animation a reply saved (`save_animation`), playing in a frame from its
/// library address, which the app serves under the card player's policy:
/// scripts run, sandboxed, and nothing loads from the network. Under it, its
/// title with Enlarge (a sheet) and Open (the Animations pane).
function animationCard(page) {
  const card = element("div", "animation-card");
  const frame = document.createElement("iframe");
  frame.className = "animation-card-frame";
  frame.src = page.url;
  frame.title = page.title;
  frame.loading = "lazy";
  frame.setAttribute("sandbox", "allow-scripts");
  const row = element("div", "animation-card-row");
  const glyph = element("span", "page-card-glyph");
  glyph.innerHTML = icons.play;
  const words = element("span", "page-card-words");
  words.append(element("span", "page-card-title", page.title), element("span", "page-card-kind", "Animation"));
  const enlarge = element("button", "page-card-open", "Enlarge");
  enlarge.type = "button";
  enlarge.title = "Play the animation larger";
  enlarge.addEventListener("click", (event) => {
    event.preventDefault();
    sendAction("enlargeAnimation", null, { pageID: page.id, title: page.title });
  });
  const open = element("button", "page-card-open", "Open");
  open.type = "button";
  open.title = `Open ${page.title} in Animations`;
  open.addEventListener("click", (event) => {
    event.preventDefault();
    sendAction("openPage", null, { pageID: page.id });
  });
  row.append(glyph, words, enlarge, open);
  card.append(frame, row);
  return card;
}

/// A part that is not prose or steps: Pages, a walk's resume row, a memory
/// review's turn heading, or the cards a call saved.
function drawCardPart(part, previous) {
  const json = JSON.stringify(part);
  if (previous?.json === json) return previous;
  let node;
  if (part.kind === "pages") {
    node = pageCards(part.pages ?? []);
  } else if (part.kind === "resume") {
    node = element("div", "inline-card resume-card");
    const glyph = element("span", "inline-card-glyph accent");
    glyph.innerHTML = icons.stack;
    const words = element("div", "inline-card-words");
    words.append(element("div", "inline-card-title", part.title), element("div", "inline-card-body", part.subtitle));
    const button = element("button", "pill-button prominent", "Resume");
    button.type = "button";
    button.title = "Go back to the cards, on the step you stopped at";
    button.addEventListener("click", (event) => {
      event.preventDefault();
      sendAction("resumeWalk", null, { sourceID: part.sourceID });
    });
    node.append(glyph, words, button);
  } else if (part.kind === "turn") {
    node = element(part.sourceID ? "button" : "div", "turn-heading");
    if (part.sourceID) {
      node.type = "button";
      node.title = `Open ${part.title}`;
      node.addEventListener("click", (event) => {
        event.preventDefault();
        sendAction("openContextSource", null, { sourceID: part.sourceID });
      });
    }
    const words = element("span", "turn-words");
    words.append(element("span", "turn-kicker", part.subtitle), element("span", "turn-title", part.title));
    node.append(element("span", "turn-rule short"), words, element("span", "turn-rule"));
  } else {
    node = element("div", "inline-card saved-cards");
    const glyph = element("span", "inline-card-glyph accent");
    glyph.innerHTML = icons.stack;
    const words = element("div", "inline-card-words");
    words.append(element("div", "inline-card-title", part.title));
    if (part.subtitle) words.append(element("div", "inline-card-body", part.subtitle));
    const button = element("button", "pill-button", "Open");
    button.type = "button";
    button.title = "Check, keep and page through these cards";
    button.addEventListener("click", (event) => {
      event.preventDefault();
      const blockID = node.closest("[data-block-id]")?.dataset.blockId ?? null;
      sendAction("openSavedCards", blockID, { partID: part.id, rect: rectOf(button) });
    });
    node.append(glyph, words, button);
  }
  return { kind: part.kind, element: node, json };
}

function drawProse(part, previous) {
  const wrapper = previous?.element ?? element("div", "prose");
  let body = wrapper.querySelector(":scope > .chat-rendered");
  if (!body) {
    body = element("div", "chat-rendered");
    wrapper.prepend(body);
  }
  body.dataset.messageId = part.id;
  const citations = part.citations ?? null;
  const citationKey = JSON.stringify(citations);
  if (!previous || previous.markdown !== part.markdown || previous.citationKey !== citationKey) {
    renderer.render(body, part.markdown, { citations });
  }
  wrapper.querySelector(":scope > .web-sources")?.remove();
  if (part.webSources?.length) {
    const list = element("div", "web-sources");
    list.append(element("div", "web-sources-heading", "Pages"));
    for (const source of part.webSources) {
      const row = element("button", "web-source");
      row.type = "button";
      row.append(element("span", "web-source-title", source.title || source.host || source.url));
      if (source.host) row.append(element("span", "web-source-host", source.host));
      row.title = source.url;
      row.addEventListener("click", (event) => {
        event.preventDefault();
        post("webLinks", { url: source.url, title: source.title ?? "" });
      });
      list.append(row);
    }
    wrapper.append(list);
  }
  return { kind: "prose", element: wrapper, markdown: part.markdown, citationKey };
}

function drawAnswer(block, entry) {
  const root = entry.element;
  root.className = `block answer${block.isLatest ? " latest" : ""}${block.isLive ? " live" : ""}`;
  const previousParts = entry.parts ?? new Map();
  const parts = new Map();
  const children = [];
  for (const part of block.parts ?? []) {
    const previous = previousParts.get(part.id);
    let drawnPart;
    if (part.kind === "work") {
      const json = JSON.stringify(part);
      drawnPart = previous?.kind === "work" && previous.json === json ? previous : drawWork(part, previous?.kind === "work" ? previous : null);
    } else if (part.kind === "prose") {
      drawnPart = drawProse(part, previous?.kind === "prose" ? previous : null);
    } else {
      drawnPart = drawCardPart(part, previous?.kind === part.kind ? previous : null);
    }
    parts.set(part.id, drawnPart);
    children.push(drawnPart.element);
  }
  for (const [id, old] of previousParts) {
    if (!parts.has(id)) {
      const body = old.element.querySelector(":scope > .chat-rendered");
      if (body) renderer.forgetContainer(body);
    }
  }
  if (block.footer) {
    children.push(drawFooter(block));
  }
  // Keep the parts that did not change in place; only reorder when needed.
  const current = [...root.children];
  if (current.length !== children.length || current.some((child, index) => child !== children[index])) {
    root.replaceChildren(...children);
  }
  entry.parts = parts;
}

function drawFooter(block) {
  const footer = element("div", "answer-footer");
  const { footer: actions } = block;
  footer.append(iconButton("copy", actions.copyLabel ?? "Copy answer", (button) => {
    sendAction("copyAnswer", block.id);
    flashCopied(button);
  }));
  if (actions.sideQuestion) {
    const asks = actions.sideQuestion.followUp
      ? "Ask a follow-up about this reply in the side question (⌥Return sends one)"
      : "Ask a side question about this reply (⌥Return sends one)";
    const side = iconButton(
      "side",
      actions.sideQuestion.armed ? "Take the side question off" : asks,
      () => sendAction("sideQuestion", block.id),
      actions.sideQuestion.armed ? "armed" : "",
    );
    footer.append(side);
  }
  if (actions.skip) {
    footer.append(iconButton("skip", "Skip this question", () => sendAction("skipQuizQuestion", null)));
  }
  if (actions.more) {
    footer.append(iconButton("more", "More", (button) => sendAction("moreMenu", block.id, { rect: rectOf(button) })));
  }
  return footer;
}

/// A side question's lane heading: folds the lane, and says what the folded
/// lane holds (`ReviewChatAsideLane`).
function drawLaneHead(block, entry) {
  const root = entry.element;
  root.className = "block lane-head";
  const open = laneChoices.get(block.id) ?? Boolean(block.laneOpen);
  const button = element("button", "lane-heading");
  button.type = "button";
  button.setAttribute("aria-expanded", String(open));
  const glyph = element("span", "lane-glyph");
  glyph.innerHTML = block.laneMoreDetails ? icons.magnify : icons.side;
  button.append(glyph, element("span", "lane-title", block.laneTitle));
  if (!open) {
    if (block.laneLine) button.append(element("span", "lane-line", block.laneLine));
    if (block.laneReplies) button.append(element("span", "lane-note", `${block.laneReplies} replies`));
  } else if (block.laneWaits) {
    button.append(element("span", "lane-note", "the quiz waits"));
  }
  const chevron = element("span", "work-chevron");
  chevron.innerHTML = open ? icons.chevronDown : icons.chevronRight;
  button.append(chevron);
  button.title = block.laneMoreDetails
    ? (open ? "Fold the details away" : "Show the details")
    : (open ? "Fold the side question away" : "Show the side question and its replies");
  button.addEventListener("click", (event) => {
    event.preventDefault();
    keepingPlace(() => {
      laneChoices.set(block.id, !open);
      drawLaneHead(block, entry);
      applyLaneFolds();
    });
  });
  root.replaceChildren(button);
}

/// The card under the newest lane: stay with the side question (Follow up,
/// New chat) or go back to the tutor's open question (Answer it, Skip).
function drawLaneCard(block, entry) {
  const root = entry.element;
  root.className = "block lane-card";
  const card = element("div", "lane-card-box");
  if (block.followUp || block.newChat) {
    const row = element("div", "lane-card-row");
    const glyph = element("span", "lane-card-glyph");
    glyph.innerHTML = icons.side;
    const words = element("div", "lane-card-words");
    words.append(
      element("div", "lane-card-kicker", "Still on the side question?"),
      element("div", "lane-card-text muted", "Ask more here, or take it to a chat of its own."),
    );
    row.append(glyph, words);
    if (block.followUp) row.append(pillButton("Follow up", "laneFollowUp", block.openQuestion
      ? "Ask more about the side question here; the quiz keeps waiting"
      : "Ask more about the side question here", "bordered"));
    if (block.newChat) row.append(pillButton("New chat", "laneNewChat", "Take the side question and its replies to a new chat, where nothing is held back", "quiet"));
    card.append(row);
  }
  if (block.openQuestion) {
    const row = element("div", "lane-card-row");
    const glyph = element("span", "lane-card-glyph");
    glyph.innerHTML = icons.back;
    const words = element("div", "lane-card-words");
    words.append(element("div", "lane-card-kicker", "Back to the question"), element("div", "lane-card-text clamp", block.openQuestion));
    row.append(glyph, words);
    row.append(pillButton("Answer it", "laneAnswer", "Go back to answering the tutor's question", "bordered"));
    row.append(pillButton("Skip", "laneSkip", "Let this question go and ask the tutor to move on", "quiet"));
    card.append(row);
  }
  root.replaceChildren(card);
}

function pillButton(label, action, help, style, extra = {}) {
  const button = element("button", `pill-button ${style}`, label);
  button.type = "button";
  button.title = help;
  button.addEventListener("click", (event) => {
    event.preventDefault();
    sendAction(action, null, extra);
  });
  return button;
}

/// Lanes the learner opened or folded; that outranks the default.
const laneChoices = new Map();

/// Hides the rows of every folded lane.
function applyLaneFolds() {
  for (const [id, entry] of drawn) {
    const lane = entry.lane;
    if (!lane) continue;
    const head = drawn.get(lane);
    const open = laneChoices.get(lane) ?? Boolean(head?.block?.laneOpen);
    entry.element.classList.toggle("lane-folded", !open);
  }
}

function forgetEntry(entry) {
  for (const part of entry.parts?.values() ?? []) {
    const body = part.element.querySelector(":scope > .chat-rendered");
    if (body) renderer.forgetContainer(body);
  }
  if (entry.images) renderer.forgetContainer(entry.images);
  entry.parts = null;
  entry.images = null;
}

function drawBlock(block) {
  let entry = drawn.get(block.id);
  if (!entry) {
    entry = { element: element("section", "block") };
    entry.element.dataset.blockId = block.id;
    drawn.set(block.id, entry);
  } else if (entry.kind !== block.kind) {
    forgetEntry(entry);
    entry.element.replaceChildren();
  }
  entry.kind = block.kind;
  entry.block = block;
  entry.lane = block.lane ?? null;
  if (block.kind === "user") drawUser(block, entry);
  else if (block.kind === "laneHead") drawLaneHead(block, entry);
  else if (block.kind === "laneCard") drawLaneCard(block, entry);
  else drawAnswer(block, entry);
  entry.element.classList.toggle("in-lane", Boolean(block.lane));
  entry.element.classList.toggle("find-match", Boolean(block.isFindMatch));
}

// ---------------------------------------------------------------------------
// The tail: suggested questions, the working line, an error

let workingTimer = null;

function elapsedText(startedAt) {
  const seconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  return `${minutes}m ${seconds % 60}s`;
}

function drawTail(tail) {
  clearInterval(workingTimer);
  workingTimer = null;
  tailRoot.replaceChildren();
  if (!tail) return;
  if (tail.pending) {
    // Sources brought in since the last message: they go with the next one.
    const column = element("div", "user-column");
    column.append(addedRow(tail.pending));
    tailRoot.append(column);
  }
  if (tail.steer) {
    const chips = element("div", "steer");
    const deeper = pillButton("Go deeper", "steer", "Stay on this source for a probe: on what did not come back, or past what did", "bordered", { next: false });
    deeper.insertAdjacentHTML("afterbegin", icons.deeper);
    const next = pillButton("Next", "steer", "Move on to the next source", "bordered", { next: true });
    next.insertAdjacentHTML("afterbegin", icons.next);
    chips.append(deeper, next);
    tailRoot.append(chips);
  }
  if (tail.suggested?.length) {
    const list = element("div", "suggested");
    for (const question of tail.suggested) {
      const card = element("button", "suggested-question", question);
      card.type = "button";
      card.addEventListener("click", (event) => {
        event.preventDefault();
        sendAction("suggestedQuestion", null, { question });
      });
      list.append(card);
    }
    tailRoot.append(list);
  }
  if (tail.working) {
    const line = element("div", "working");
    line.append(element("span", "working-mark"));
    line.append(element("span", "working-label", tail.working.label));
    const clock = element("span", "working-clock", elapsedText(tail.working.startedAt));
    line.append(clock);
    workingTimer = setInterval(() => {
      clock.textContent = elapsedText(tail.working.startedAt);
    }, 1000);
    tailRoot.append(line);
  }
  if (tail.error) {
    tailRoot.append(element("div", "error", tail.error));
  }
}

// ---------------------------------------------------------------------------
// Swift's entry point

/// Applies what changed: `upserts` are blocks drawn new or again, `order` is
/// every block's id top to bottom (a block missing from it is gone), and the
/// tail, the reserve under the last row and the layout come when they change.
window.transcriptApply = (update) => {
  keepingPlace(() => {
    if (update.layout) {
      const root = document.documentElement.style;
      root.setProperty("--chat-font-size", `${update.layout.fontSize}px`);
      root.setProperty("--column-max", `${update.layout.columnMaxWidth}px`);
      root.setProperty("--message-max", `${update.layout.messageMaxWidth}px`);
    }
    for (const block of update.upserts ?? []) drawBlock(block);
    if (update.order) {
      const keep = new Set(update.order);
      for (const [id, entry] of drawn) {
        if (keep.has(id)) continue;
        forgetEntry(entry);
        entry.element.remove();
        drawn.delete(id);
      }
      const wanted = update.order.map((id) => drawn.get(id)?.element).filter(Boolean);
      const current = [...blocksRoot.children];
      if (current.length !== wanted.length || current.some((child, index) => child !== wanted[index])) {
        blocksRoot.replaceChildren(...wanted);
      }
    }
    applyLaneFolds();
    if ("summary" in update) {
      // A finished review's graded summary: a quiet caption over the turns.
      headRoot.replaceChildren();
      if (update.summary) headRoot.append(element("div", "summary", update.summary));
    }
    if ("tail" in update) drawTail(update.tail);
    if (typeof update.reserve === "number") reserve.style.height = `${Math.max(0, update.reserve)}px`;
  });
  updateJumpButton();
};

post("ready", true);
