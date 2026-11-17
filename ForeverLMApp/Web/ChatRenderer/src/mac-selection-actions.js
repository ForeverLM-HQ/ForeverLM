// The bar that follows selecting text in an assistant reply.
//
// The Reader answers a selection with a "Chat" pill hugging the passage; a
// reply in the transcript answers with a bar of three actions, the way
// Claude's transcript does: "Add to chat" drops the passage into the composer
// as a quote, "More details" asks the tutor to expand on it here, and "Ask in
// side chat" opens a small chat in a popover over the passage, so the
// question is asked and answered without leaving this chat. The bar lives in
// the page for the reason the Reader's does: only the page knows where the
// selected words are, and here it tracks the reply's own reflow for free. The
// page only names the action and says where the words are; what each one does
// is the app's.
//
// One difference from the Reader shapes the placement. A message web view is
// exactly as tall as its message, so `position: fixed` is clipped to the
// reply, not the window: above the passage when the reply has a line of room
// there, below it when not, and beside the end of the selection in a reply
// too short for either.

const GAP = 6;
const MARGIN = 4;

/// The actions the bar offers, in order, and the words on them. The `action`
/// is what the page posts; the app reads it and does the work.
export const SELECTION_ACTIONS = [
  { action: "quote", label: "Add to chat" },
  { action: "moreDetails", label: "More details" },
  { action: "sideChat", label: "Ask in side chat" },
];

/// Installs the bar on `document`, posting `{ action, text }` through `post`
/// when one of its actions is pressed. Returns `run`, which the app's context
/// menu calls to run an action on the current selection without the bar, and
/// `refresh`, which the page calls after it redraws anything under the bar.
export function installSelectionActions({ document: document_ = document, actions = SELECTION_ACTIONS, post }) {
  const window_ = document_.defaultView;
  let host = null;
  let bar = null;
  let placeFrame = null;

  // KaTeX draws an equation as stacked boxes, and `Selection.toString()`
  // reads each box as its own line, so "Δψₘ" came out as "Δψ", "m" and a blank
  // line, and the composer put a `>` in front of each. The selection's text is
  // therefore read from a copy in which every equation is its source again
  // (`$\Delta\psi_\mathrm{m}$`), the way the reply wrote it and the model
  // reads it. A selection with no math in it keeps the browser's own reading.
  const MATH = "[data-chat-math-source]";

  const mathText = (element) => {
    const source = element.dataset.chatMathSource;
    if (!element.classList.contains("chat-math-display")) return document_.createTextNode(source);
    // Display math is a block of its own; keep it on its own line.
    const block = document_.createElement("div");
    block.textContent = source;
    return block;
  };

  const selectionText = () => {
    const selection = window_.getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return "";
    const range = selection.getRangeAt(0);
    const ancestor = range.commonAncestorContainer;
    const within = (ancestor.nodeType === 1 ? ancestor : ancestor.parentElement)?.closest(MATH);
    // A selection that starts and ends inside one equation is that equation.
    if (within) return within.dataset.chatMathSource.trim();

    const fragment = range.cloneContents();
    const equations = fragment.querySelectorAll(MATH);
    if (equations.length === 0) return selection.toString().trim();
    for (const equation of equations) equation.replaceWith(mathText(equation));
    // `innerText` gives the paragraph breaks `toString()` would, but only for
    // an element with layout, so the copy is laid out off-screen for a moment.
    // Off-screen and transparent, not `visibility: hidden`: `innerText` skips
    // hidden text, which is the point of `visibility`, and would read nothing.
    const scratch = document_.createElement("div");
    scratch.setAttribute("aria-hidden", "true");
    scratch.style.cssText =
      "position:fixed;top:0;left:-100000px;width:100000px;opacity:0;pointer-events:none;";
    scratch.append(fragment);
    document_.body.append(scratch);
    try {
      return scratch.innerText.trim();
    } finally {
      scratch.remove();
    }
  };

  const selectionRect = () => {
    const selection = window_.getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;
    let union = null;
    for (const rect of selection.getRangeAt(0).getClientRects()) {
      if (rect.width <= 0 && rect.height <= 0) continue;
      union = union
        ? {
            top: Math.min(union.top, rect.top),
            left: Math.min(union.left, rect.left),
            right: Math.max(union.right, rect.right),
            bottom: Math.max(union.bottom, rect.bottom),
            lastRight: rect.right,
            lastTop: rect.top,
            lastBottom: rect.bottom,
          }
        : {
            top: rect.top,
            left: rect.left,
            right: rect.right,
            bottom: rect.bottom,
            lastRight: rect.right,
            lastTop: rect.top,
            lastBottom: rect.bottom,
          };
    }
    return union;
  };

  /// Where the selected words are, in the page's own pixels: the box around
  /// every line of the selection. A message web view is exactly as tall as
  /// its message, so the app can hang a popover off this box directly.
  const selectionBox = () => {
    const rect = selectionRect();
    if (!rect) return null;
    return {
      x: rect.left,
      y: rect.top,
      width: Math.max(0, rect.right - rect.left),
      height: Math.max(0, rect.bottom - rect.top),
    };
  };

  const run = (action = "quote") => {
    if (!actions.some((candidate) => candidate.action === action)) return false;
    // Without the word joiners that tie each citation chip to its word: they
    // are layout, not words, and would ride into the quote unseen.
    const text = selectionText().replaceAll("\u2060", "");
    if (!text) return false;
    // The box is read before the selection is dropped below, or there would
    // be nothing left to measure.
    post({ action, text, rect: selectionBox() });
    try {
      window_.getSelection().removeAllRanges();
    } catch {
      // A selection that refuses to collapse leaves the blue band; the
      // passage has already gone.
    }
    hide();
    return true;
  };

  const build = () => {
    if (host && host.isConnected) return;
    host = document_.createElement("div");
    host.setAttribute("data-foreverlm-selection-bar", "");
    host.style.cssText =
      "position:fixed;top:0;left:0;width:max-content;height:auto;margin:0;padding:0;border:0;" +
      "z-index:2147483647;display:none;";
    const root = host.attachShadow({ mode: "open" });
    // System colours, so the bar is white in a light window and dark in a
    // dark one, the way the transcript around it already is. `all: initial`
    // on the host resets `color-scheme`, so the bar sets it again.
    root.innerHTML =
      "<style>" +
      ":host { all: initial; }" +
      ".bar {" +
      "  all: unset; box-sizing: border-box; display: inline-flex; align-items: stretch;" +
      "  color-scheme: light dark;" +
      "  border-radius: 9px; overflow: hidden;" +
      "  background: Canvas; color: CanvasText;" +
      "  border: 1px solid color-mix(in srgb, CanvasText 14%, transparent);" +
      "  box-shadow: 0 1px 2px rgba(0,0,0,.14), 0 6px 18px rgba(0,0,0,.16);" +
      "  opacity: 0; transform: translateY(3px) scale(.97);" +
      "  transition: opacity .13s ease-out, transform .13s ease-out;" +
      "}" +
      ".bar.visible { opacity: 1; transform: none; }" +
      ".action {" +
      "  all: unset; box-sizing: border-box;" +
      "  display: inline-flex; align-items: center;" +
      "  font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;" +
      "  font-size: 12px; font-weight: 500; line-height: 1; letter-spacing: .005em;" +
      "  white-space: nowrap; color: inherit; cursor: default;" +
      "  padding: 7px 11px;" +
      "}" +
      ".action + .action { border-left: 1px solid color-mix(in srgb, CanvasText 12%, transparent); }" +
      ".action:hover { background: color-mix(in srgb, CanvasText 7%, transparent); }" +
      ".action:active { background: color-mix(in srgb, CanvasText 13%, transparent); }" +
      "</style>" +
      '<div class="bar" role="toolbar">' +
      actions
        .map(
          ({ action, label }) =>
            `<button type="button" class="action" data-action="${action}" aria-label="${label}">${label}</button>`,
        )
        .join("") +
      "</div>";
    bar = root.querySelector(".bar");
    for (const button of root.querySelectorAll(".action")) {
      // Pressing an action must not collapse the selection it acts on.
      button.addEventListener("mousedown", (event) => {
        event.preventDefault();
        event.stopPropagation();
      });
      button.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        run(button.dataset.action);
      });
    }
    document_.body.appendChild(host);
  };

  const hide = () => {
    if (!host) return;
    host.style.display = "none";
    if (bar) bar.classList.remove("visible");
  };

  const place = () => {
    const rect = selectionRect();
    if (!rect) {
      hide();
      return;
    }
    build();
    host.style.display = "block";
    const width = bar.offsetWidth;
    const height = bar.offsetHeight;
    const viewWidth = document_.documentElement.clientWidth || window_.innerWidth || 0;
    const viewHeight = window_.innerHeight || document_.documentElement.clientHeight || 0;

    // Centered on the passage, above it, as in the Reader.
    let left = (rect.left + rect.right) / 2 - width / 2;
    let top = rect.top - height - GAP;
    if (top < MARGIN) {
      const below = rect.bottom + GAP;
      if (below + height + MARGIN <= viewHeight) {
        top = below;
      } else {
        // A reply of a line or two has no room over or under the passage.
        // Sit at the end of the selection instead, where the pointer let go,
        // and only over the words when even that edge is out of room.
        top = Math.max(MARGIN, Math.min((rect.lastTop + rect.lastBottom) / 2 - height / 2, viewHeight - height - MARGIN));
        left = rect.lastRight + GAP;
        if (left + width + MARGIN > viewWidth) left = rect.left - width - GAP;
      }
    }
    left = Math.max(MARGIN, Math.min(left, viewWidth - width - MARGIN));
    host.style.transform = `translate(${Math.round(left)}px,${Math.round(top)}px)`;
    bar.classList.add("visible");
  };

  const schedulePlace = () => {
    if (placeFrame) return;
    placeFrame = window_.requestAnimationFrame(() => {
      placeFrame = null;
      if (host && host.style.display !== "none") place();
    });
  };

  // The selection band is drawn here, not by WebKit. WebKit paints each
  // selected line at the height of its font and fills the space between
  // lines, and between paragraphs, from a separate pass that invalidates
  // separately: while a drag grew the selection, that pass left a strip of
  // plain background under one line of an otherwise solid band (product owner,
  // 2026-11-08 and again 2026-11-16: "when i highlight text i get the stripe").
  // Repainting the reply afterwards, and whole-pixel line heights, did not
  // remove it. Here every line is a box of the whole line height, boxes that
  // meet share one edge, and the space between paragraphs is its own box, so
  // there is no gap pass left to go stale. WebKit's own band is made
  // transparent by `.chat-own-selection` (`chat-render.css`).
  const layer = document_.createElement("div");
  layer.setAttribute("aria-hidden", "true");
  layer.id = "chat-selection-layer";
  layer.style.cssText = "position:absolute;left:0;top:0;width:0;height:0;pointer-events:none;z-index:-1;";
  document_.documentElement.classList.add("chat-own-selection");

  const BLOCK_GAP_LIMIT = 80;
  let paintFrame = null;

  const blockOf = (element, root) => {
    let node = element;
    while (node && node !== root) {
      const display = window_.getComputedStyle(node).display;
      if (!display.startsWith("inline") && display !== "contents") return node;
      node = node.parentElement;
    }
    return root;
  };

  /// The lines of the selection inside one reply: one box per visual line, as
  /// tall as the reply's line height, with the text's own left and right.
  const linesOf = (range, reply) => {
    const found = [];
    const walker = document_.createTreeWalker(reply, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!range.intersectsNode(node)) continue;
      const start = node === range.startContainer ? range.startOffset : 0;
      const end = node === range.endContainer ? range.endOffset : node.length;
      if (end <= start) continue;
      const parent = node.parentElement;
      if (!parent) continue;
      const sub = document_.createRange();
      sub.setStart(node, start);
      sub.setEnd(node, end);
      const lineHeight = Number.parseFloat(window_.getComputedStyle(parent).lineHeight);
      const block = blockOf(parent, reply);
      for (const rect of sub.getClientRects()) {
        if (rect.width < 0.5 || rect.height <= 0) continue;
        const pad = Number.isFinite(lineHeight) && lineHeight > rect.height ? (lineHeight - rect.height) / 2 : 0;
        found.push({ top: rect.top - pad, bottom: rect.bottom + pad, left: rect.left, right: rect.right, block, reply });
      }
    }
    found.sort((a, b) => a.top - b.top || a.left - b.left);
    // Pieces of one line (words, a chip, an inline code run) become one box.
    const lines = [];
    for (const piece of found) {
      const line = lines[lines.length - 1];
      const overlap = line ? Math.min(line.bottom, piece.bottom) - Math.max(line.top, piece.top) : 0;
      if (line && line.block === piece.block && overlap > 0.5 * Math.min(line.bottom - line.top, piece.bottom - piece.top)) {
        line.top = Math.min(line.top, piece.top);
        line.bottom = Math.max(line.bottom, piece.bottom);
        line.left = Math.min(line.left, piece.left);
        line.right = Math.max(line.right, piece.right);
      } else {
        lines.push({ ...piece });
      }
    }
    return lines;
  };

  const paintSelection = () => {
    paintFrame = null;
    const selection = window_.getSelection();
    const boxes = [];
    if (selection && !selection.isCollapsed && selection.rangeCount > 0) {
      const range = selection.getRangeAt(0);
      const lines = [];
      for (const reply of document_.querySelectorAll(".chat-rendered")) {
        if (range.intersectsNode(reply)) lines.push(...linesOf(range, reply));
      }
      // A line that is followed by another runs to the edge of its block, as
      // a selection does in any text view; only the last line stops at its words.
      lines.forEach((line, index) => {
        if (index === lines.length - 1) return;
        const style = window_.getComputedStyle(line.block);
        const edge = line.block.getBoundingClientRect().right - Number.parseFloat(style.paddingRight || "0");
        if (edge > line.right) line.right = edge;
      });
      const scaleOf = window_.devicePixelRatio || 1;
      const snap = (value) => Math.round(value * scaleOf) / scaleOf;
      const scrollX = window_.scrollX;
      const scrollY = window_.scrollY;
      lines.forEach((line, index) => {
        line.top = snap(line.top + scrollY);
        line.bottom = snap(line.bottom + scrollY);
        line.left = snap(line.left + scrollX);
        line.right = snap(line.right + scrollX);
        const above = lines[index - 1];
        if (!above) return;
        // Lines that meet share one edge, and the space between two blocks of
        // one reply is a box of its own, so nothing is left unpainted.
        if (line.top >= above.bottom - 2) {
          const gap = line.top - above.bottom;
          if (gap > 0 && gap <= BLOCK_GAP_LIMIT && above.reply === line.reply) {
            boxes.push({ left: Math.min(above.left, line.left), right: Math.max(above.right, line.right), top: above.bottom, bottom: line.top });
          } else if (gap < 0) {
            line.top = above.bottom;
          }
        }
      });
      for (const line of lines) {
        if (line.bottom > line.top && line.right > line.left) boxes.push(line);
      }
    }
    const nodes = boxes.map((box) => {
      const element = document_.createElement("div");
      element.style.cssText =
        `position:absolute;left:${box.left}px;top:${box.top}px;width:${box.right - box.left}px;` +
        `height:${box.bottom - box.top}px;background:var(--chat-selection, color-mix(in srgb, Highlight 60%, transparent));`;
      return element;
    });
    layer.replaceChildren(...nodes);
    if (nodes.length > 0 && !layer.isConnected) document_.body.append(layer);
  };

  const schedulePaint = () => {
    if (paintFrame) return;
    paintFrame = window_.requestAnimationFrame(paintSelection);
  };

  const check = () => {
    if (selectionText()) {
      place();
    } else hide();
  };

  // Only a finished gesture shows the bar: mouse-up, or a keyboard selection.
  // Programmatic selections, such as find-in-page, never do.
  document_.addEventListener("mouseup", () => window_.setTimeout(check, 50));
  document_.addEventListener("keyup", check);
  // A new drag or a click away retires the bar at once; it returns on mouse-up
  // if that gesture selected something. The bar's own press is exempt, or the
  // hide here would swallow its click.
  document_.addEventListener(
    "mousedown",
    (event) => {
      if (!host) return;
      const path = event.composedPath ? event.composedPath() : [];
      if (path.includes(host) || host.contains(event.target)) return;
      hide();
    },
    true,
  );
  document_.addEventListener("selectionchange", () => {
    schedulePaint();
    if (!selectionText()) hide();
  });
  window_.addEventListener("scroll", schedulePlace, { passive: true });
  window_.addEventListener("resize", () => {
    schedulePlace();
    schedulePaint();
  }, { passive: true });

  // A redraw that takes the selected words out of the document drops the
  // selection without a `selectionchange`, and the bar stayed up over words
  // that were no longer selected, pressing to nothing (product owner,
  // 2026-11-13: "it's not nicely selecting what i'm expecting"). A redraw
  // that only moves the words takes the bar with them.
  const refresh = () => {
    schedulePaint();
    if (!host || host.style.display === "none") return;
    if (selectionText()) place();
    else hide();
  };

  return { run, refresh };
}
