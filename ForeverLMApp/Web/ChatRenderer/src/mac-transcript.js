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
const anchor = { chain: [], top: 0, active: false };

/// The last scroll the page made itself, so `scroll` events it causes are not
/// read as the learner's.
let programmaticScrollAt = 0;

function scrollByAnchorDelta() {
  if (!anchor.active) return;
  const element = anchor.chain.find((candidate) => candidate.isConnected);
  if (!element) return;
  const delta = element.getBoundingClientRect().top - anchor.top;
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
    anchor.chain.unshift(found);
    parent = found;
  }
  const element = anchor.chain[0];
  if (!element) return;
  anchor.top = element.getBoundingClientRect().top;
  anchor.active = true;
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
window.transcriptScrollTo = (id, position = "bottom", animated = false) => {
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

function drawUser(block, entry) {
  const root = entry.element;
  root.className = "block user";
  root.replaceChildren();
  const column = element("div", "user-column");
  if (block.added) {
    // Sources the learner brought in just before this message: a summary
    // that opens onto their names, each opening its source in the Reader.
    const added = element("div", "user-added");
    const toggle = element("button", "user-added-toggle", block.added.summary);
    toggle.type = "button";
    const list = element("div", "user-added-list");
    list.hidden = true;
    for (const source of block.added.sources) {
      const row = element("button", "user-added-source", source.title);
      row.type = "button";
      row.title = `Open ${source.title} in the reader`;
      row.addEventListener("click", (event) => {
        event.preventDefault();
        sendAction("openContextSource", null, { sourceID: source.id });
      });
      list.append(row);
    }
    toggle.addEventListener("click", (event) => {
      event.preventDefault();
      keepingPlace(() => {
        list.hidden = !list.hidden;
      });
    });
    added.append(toggle, list);
    column.append(added);
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
  wrapper.replaceChildren();
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
  wrapper.append(line);
  if (expanded) {
    const steps = element("div", "work-steps");
    let card = null;
    for (const step of part.steps ?? []) {
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
    }
    wrapper.append(steps);
  }
  if (part.settled) wrapper.append(element("div", "work-rule"));
  return { kind: "work", element: wrapper, json: JSON.stringify(part) };
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
    } else {
      drawnPart = drawProse(part, previous?.kind === "prose" ? previous : null);
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
    const side = iconButton(
      "side",
      actions.sideQuestion.armed ? "Take the side question off" : "Ask a side question about this reply (⌥Return sends one)",
      () => sendAction("sideQuestion", block.id),
      actions.sideQuestion.armed ? "armed" : "",
    );
    footer.append(side);
  }
  if (actions.more) {
    footer.append(iconButton("more", "More", (button) => sendAction("moreMenu", block.id, { rect: rectOf(button) })));
  }
  return footer;
}

function drawBlock(block) {
  let entry = drawn.get(block.id);
  if (!entry) {
    entry = { element: element("section", "block") };
    entry.element.dataset.blockId = block.id;
    drawn.set(block.id, entry);
  } else if (entry.kind !== block.kind) {
    entry.parts = null;
    entry.element.replaceChildren();
  }
  entry.kind = block.kind;
  if (block.kind === "user") drawUser(block, entry);
  else drawAnswer(block, entry);
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
        for (const part of entry.parts?.values() ?? []) {
          const body = part.element.querySelector(":scope > .chat-rendered");
          if (body) renderer.forgetContainer(body);
        }
        entry.element.remove();
        drawn.delete(id);
      }
      const wanted = update.order.map((id) => drawn.get(id)?.element).filter(Boolean);
      const current = [...blocksRoot.children];
      if (current.length !== wanted.length || current.some((child, index) => child !== wanted[index])) {
        blocksRoot.replaceChildren(...wanted);
      }
    }
    if ("tail" in update) drawTail(update.tail);
    if (typeof update.reserve === "number") reserve.style.height = `${Math.max(0, update.reserve)}px`;
  });
  updateJumpButton();
};

post("ready", true);
