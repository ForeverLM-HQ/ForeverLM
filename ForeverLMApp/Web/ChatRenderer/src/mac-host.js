// The Mac app's half of the chat renderer: what a WKWebView showing one
// assistant message needs that a browser page does not.
//
// Swift drives the page through the `window.*` functions at the bottom, and the
// page answers through `webkit.messageHandlers`. Source cards and pictures are
// resolved by the app rather than the page, because both come out of the
// library database and the local files behind it.

import { createChatRenderer, normalizeLatexDisplayBlocks, renderChatMarkdownToHTML } from "./chat-render.js";
import { installSelectionActions } from "./mac-selection-actions.js";

const content = document.getElementById("content");
const post = (name, body) => window.webkit?.messageHandlers?.[name]?.postMessage(body);

/// Selecting words in the reply offers to add them to the composer as a quote,
/// to have the tutor expand on them, or to ask about them in a small chat that
/// pops over the passage. The app's context menu reaches the same actions
/// through `requestSelectionAction("quote" | "moreDetails" | "sideChat")`.
const selectionActions = installSelectionActions({
  post: (payload) => post("selectionAction", payload),
});
window.requestSelectionAction = selectionActions.run;

/// Measure the message, not the WebView viewport. A pooled WebView can still
/// have its previous row's much taller frame when new markdown is pushed into
/// it. document/body scrollHeight is never smaller than that viewport, so
/// feeding it back into SwiftUI made a short reused row permanently inherit a
/// large invisible tail.
///
/// The number is where the message ends on the page, not how tall #content is:
/// the top margin of a first child collapses out through #content, which leaves
/// its own height short of the space the message occupies while drawing it that
/// far down the page. The stylesheet zeroes those margins, and measuring the
/// bottom edge means a new one can never cut the last line off again.
function reportHeight() {
  // An empty page says nothing about the message. The template posts once on
  // load and the observer once on attach, both before any markdown has been
  // pushed; a zero there collapsed the row from its estimate to one line and
  // let the real height spring it open a frame later.
  if (!content || !content.firstChild) return;
  // A page with no width yet has no line to wrap to: every word lands on a
  // line of its own and a three-paragraph reply measures six thousand points.
  // A row's web view is created at a zero frame, and on a chat opened from
  // history its page can finish loading, and take its markdown, before SwiftUI
  // has sized it, so that was the first height several rows applied, for one
  // frame, before the real one landed. Say nothing; the ResizeObserver reports
  // again the moment the content takes its width.
  if (document.documentElement.clientWidth === 0) return;
  const box = content.getBoundingClientRect();
  post("height", Math.max(content.scrollHeight, box.height, box.bottom + window.scrollY));
}

const renderer = createChatRenderer({
  // Set by Swift before the document runs, so the app decides in one place
  // whether equations are drawn by KaTeX's own boxes and fonts ("html") or by
  // the system math font ("mathml").
  mathOutput: document.documentElement.dataset.mathOutput || "html",
  requestSourceCards: (tokens) => post("sourceCards", tokens),
  requestSourceImages: (tokens) => post("sourceImages", tokens),
  // The app owns the pasteboard: it writes the original bytes under their own
  // type alongside a bitmap, which a canvas round-trip in the page could not.
  copySourceImage: (token) => {
    post("copySourceImage", token);
    return true;
  },
  // A click on a picture opens it full-window, above the whole transcript.
  // Each row is its own web view, so a backdrop drawn in the page could cover
  // only the row; the app draws it over the window and reads the same bytes
  // it resolved for the figure.
  zoomSourceImage: (token, img) => post("zoomSourceImage", { token, alt: img.alt ?? "" }),
  // Open beside: the app docks the same bytes in a pane next to the chat (a
  // notebook's document slot) or, with no such place, in a picture window.
  openSourceImageBeside: (token, img) => post("openSourceImageBeside", { token, alt: img.alt ?? "" }),
  // Redraw: the app raises a menu of image models under the button and draws
  // the picture again, from its kept prompt, with the one chosen.
  redrawSourceImage: (token) => post("redrawSourceImage", { token }),
  // Add under a slide's papers: the app imports the paper and hands the
  // picture back, its list now linking to the new source.
  addSlideCitedPaper: (token, paperID) => post("addSlideCitedPaper", { token, paperID }),
  // Add to Notebook beside a Sources row the chat's notebook does not hold:
  // the app adds the source through its notebook write and sends the card
  // again, now unmarked.
  addSourceToNotebook: (token) => post("addSourceToNotebook", token),
  // A citation carries the source token and, for a video or recording, the
  // moment it points at, or for a text source the passage it quotes; the app
  // resolves the token, seeks the reader or flashes the passage.
  openSource: (token, { seconds = null, passage = null, page = null } = {}) =>
    post("openSource", { token, seconds, passage, page }),
  openWebLink: (url, title) => post("webLinks", { url, title }),
  onLayoutChange: () => requestAnimationFrame(reportHeight),
  // A visualization runs in a sandboxed frame inside this row's web view; the
  // app lets that frame load its own document and nothing else.
  runsVisualizations: true,
});

/// What the rest of the conversation already established about this message's
/// citations. The app works it out over the whole transcript -- a web view here
/// holds one reply and can see no further -- and sets it before pushing the
/// markdown it belongs to.
let citationContext = null;

window.setCitationContext = (context) => {
  citationContext = context ?? null;
};
window.setMarkdown = (markdown) => {
  if (content) renderer.render(content, markdown, { citations: citationContext });
  selectionActions.refresh();
};
window.setSourceCards = (cards) => {
  renderer.setSourceCards(cards);
  selectionActions.refresh();
};
window.setSourceImages = (images) => {
  renderer.setSourceImages(images);
  selectionActions.refresh();
};
window.resetSourceCards = () => renderer.resetSourceCards();
window.resetSourceImages = () => renderer.resetSourceImages();

/// The text pipeline on its own, for the app's unit tests and for poking at
/// a repair from the Web Inspector. Nothing in Swift renders through this.
window.foreverLMChat = { normalizeLatexDisplayBlocks, renderChatMarkdownToHTML };

if (content) new ResizeObserver(reportHeight).observe(content);
reportHeight();
