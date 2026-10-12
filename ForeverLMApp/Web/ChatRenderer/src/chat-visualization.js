// A visualization a reply draws: one self-contained HTML document the model
// wrote, run in a frame that cannot reach the transcript or the network.
//
// The contract is a page's Visualize block (`visualizationFrame` in the page
// editor, `Prompts.docVisualization`): the same policy, the same shell, the
// same height report, so the same Markdown runs in a page too.

/// What a visualization's frame may do: run its own script and style, show
/// pictures and fonts it carries as data, and nothing else. No request goes
/// out, whatever the model wrote.
const VISUALIZATION_POLICY = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; form-action 'none'; base-uri 'none'";
const HEIGHT_REPORTER = '<script>(function(){function r(){parent.postMessage({foreverlmVisualizationHeight:Math.ceil(document.body.scrollHeight)},"*")}new ResizeObserver(r).observe(document.body);addEventListener("load",r)})()<\/script>';
const MIN_HEIGHT = 80;
const MAX_HEIGHT = 720;

/// The document a frame loads: the model's HTML inside a shell whose first
/// element is the policy above. The document, head and body tags the model
/// wrote, and any meta or base, are taken out so nothing runs or navigates
/// before the policy is in force.
export function visualizationDocument(html) {
  const body = String(html ?? "")
    .replace(/<!doctype[^>]*>/gi, "")
    .replace(/<\/?(?:html|head|body)\b[^>]*>/gi, "")
    .replace(/<(?:meta|base)\b[^>]*>/gi, "");
  return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${VISUALIZATION_POLICY}"><meta name="color-scheme" content="light dark"><style>html,body{margin:0;background:transparent;font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;color:CanvasText}</style></head><body>${body}${HEIGHT_REPORTER}</body></html>`;
}

/// A short, stable key for one visualization's source, so a reply that keeps
/// streaming after the block leaves the running frame alone.
export function visualizationKey(html, complete) {
  const text = String(html ?? "");
  let hash = 5381;
  for (let index = 0; index < text.length; index += 1) hash = ((hash << 5) + hash + text.charCodeAt(index)) | 0;
  return `${complete ? "run" : "pending"}:${text.length}:${(hash >>> 0).toString(36)}`;
}

// One listener for every frame on the page. Each frame says how tall it wants
// to be; the message is matched to its frame by the window that sent it, so a
// frame removed with its reply leaves nothing behind to clean up.
const layoutCallbacks = new WeakMap();
let listening = false;
function listenForHeights(window_) {
  if (listening || !window_?.addEventListener) return;
  listening = true;
  window_.addEventListener("message", (event) => {
    const height = Number(event.data?.foreverlmVisualizationHeight);
    if (!Number.isFinite(height) || height <= 0) return;
    for (const frame of window_.document.querySelectorAll("iframe.chat-visualization-frame")) {
      if (frame.contentWindow !== event.source) continue;
      const next = `${Math.round(Math.min(MAX_HEIGHT, Math.max(MIN_HEIGHT, height)))}px`;
      if (frame.style.height !== next) {
        frame.style.height = next;
        layoutCallbacks.get(frame)?.();
      }
      return;
    }
  });
}

/// The element for one visualization part of a reply. A finished block runs
/// in a sandboxed frame without `allow-same-origin`, so it has no way to the
/// page. One still streaming is a quiet stand-in of the same shape: half a
/// program would only throw. A host that cannot run one says so in a line.
export function visualizationElement(document_, part, { runs = true, onLayoutChange = null } = {}) {
  const wrapper = document_.createElement("div");
  wrapper.className = "chat-visualization";
  wrapper.dataset.visualizationKey = visualizationKey(part.html, part.complete && runs);

  if (!runs) {
    wrapper.classList.add("chat-visualization-unavailable");
    wrapper.textContent = "Interactive visualization · runs in the Mac app";
    return wrapper;
  }
  if (!part.complete) {
    wrapper.classList.add("chat-visualization-pending");
    wrapper.setAttribute("aria-label", "Drawing a visualization");
    return wrapper;
  }

  listenForHeights(document_.defaultView);
  const frame = document_.createElement("iframe");
  frame.className = "chat-visualization-frame";
  frame.setAttribute("sandbox", "allow-scripts");
  frame.setAttribute("referrerpolicy", "no-referrer");
  frame.title = "Visualization";
  frame.srcdoc = visualizationDocument(part.html);
  if (onLayoutChange) layoutCallbacks.set(frame, onLayoutChange);
  wrapper.append(frame);
  return wrapper;
}
