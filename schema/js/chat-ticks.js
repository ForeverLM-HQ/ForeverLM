// The chat-tick rule (docs/cloudkit-schema-design.md §5.6, D16, bug b5) and a notebook's context
// (D52): which sources a notebook surface reads, for one member. The twin of Swift's
// SyncNotebookChatContext.swift; generation 1's web rule is library-notebooks.js, over preference
// rows, and this one reads records. The Studio reads the notebook's own selected sources; a chat
// (`contextMode = notebook`) also reads those of the listed notebooks the member ticked into context,
// one level deep. A member's untick records the compared Entry's `state` and `approval` stamps in
// `NotebookState.excluded`; a source is left out only while those stamps are unchanged, so a re-add
// or a re-approval by anyone, from any device, ticks it again with no write to the member's record
// and no comparison of two devices' clocks. Vectors: schema/vectors/chat-ticks.json.

import { compareStrings, own } from "./json.js";

/**
 * @typedef {{containerID: string, itemKind: string, itemID: string, state: string,
 *            approval?: string | null, stateStamp: string, approvalStamp?: string | null}} TickEntry
 * An Entry as the rule reads it: its identity, its shared state and their stamps. An absent
 * `approval` means approved.
 */

/**
 * An Entry record as the rule reads it; null when it lacks the fields or the state stamp the rule needs.
 * @param {import("./envelope.js").Envelope} envelope
 * @returns {TickEntry | null}
 */
export function tickEntry(envelope) {
  if (envelope.type !== "Entry") return null;
  const fields = envelope.fields;
  const containerID = own(fields, "containerID");
  const itemKind = own(fields, "itemKind");
  const itemID = own(fields, "itemID");
  const state = own(fields, "state");
  const stateStamp = own(envelope.stamps, "state");
  if (typeof containerID !== "string" || typeof itemKind !== "string" || typeof itemID !== "string"
    || typeof state !== "string" || typeof stateStamp !== "string") {
    return null;
  }
  const approval = own(fields, "approval");
  const approvalStamp = own(envelope.stamps, "approval");
  return {
    containerID, itemKind, itemID, state, stateStamp,
    approval: typeof approval === "string" ? approval : null,
    approvalStamp: typeof approvalStamp === "string" ? approvalStamp : null,
  };
}

/** @param {TickEntry} entry */
function isInContext(entry) {
  return entry.itemKind === "source" && entry.state === "active" && (entry.approval == null || entry.approval === "approved");
}

/**
 * `stamps(e).state + "|" + (stamps(e).approval ?? "-")`, the value an untick stores.
 * @param {TickEntry} entry
 */
export function stampPair(entry) {
  return `${entry.stateStamp}|${entry.approvalStamp ?? "-"}`;
}

/**
 * `ctx(nb, m)`: the notebooks whose own sources a chat in `notebookID` also reads, sorted. Both lists
 * are resolved before they are intersected (R6-m1), so a context notebook that was merged or moved
 * keeps feeding the chat while the member's tick names the stub and the link the survivor, or the
 * reverse; the notebook itself is dropped. `contextNotebooks` is `NotebookState(nb).contextNotebooks`
 * and `relatedNotebookIDs` is `Notebook(nb).relatedNotebookIDs`, as their sets hold them (an element
 * counts while its value is `true`); `resolve` is `resolveNotebook()` (resolve.js) for an id, from
 * where the client holds that notebook.
 * @param {{notebookID: string, contextNotebooks?: Record<string, unknown> | null,
 *          relatedNotebookIDs?: Record<string, unknown> | null, resolve: (id: string) => string}} context
 * @returns {string[]}
 */
export function contextNotebookIDs({ notebookID, contextNotebooks, relatedNotebookIDs, resolve }) {
  const home = resolve(notebookID);
  const ticked = new Set(members(contextNotebooks).map(resolve));
  const listed = new Set(members(relatedNotebookIDs).map(resolve));
  return [...ticked].filter((notebook) => listed.has(notebook) && notebook !== home).sort(compareStrings);
}

/**
 * `studio(nb, m)`: the notebook's own selected sources, sorted. Every Studio maker and its counts
 * read this, never a context notebook's sources. `notebookID` is already resolved, and `excluded` is
 * that notebook's `NotebookState.excluded`.
 * @param {{notebookID: string, entries: TickEntry[], excluded?: Record<string, unknown> | null}} context
 */
export function studioSourceIDs({ notebookID, entries, excluded }) {
  return sourceIDs(notebookID, [], entries, excluded);
}

/**
 * `chat(nb, m)`: the notebook's own selected sources and those of its context notebooks
 * (`contextNotebookIDs`), sorted. One level deep: a context notebook's own context notebooks never
 * join. A source left out stays out only while `excluded` names the stamps of its `comparedEntry`.
 * @param {{notebookID: string, contextNotebookIDs: string[], entries: TickEntry[],
 *          excluded?: Record<string, unknown> | null}} context
 */
export function chatSourceIDs({ notebookID, contextNotebookIDs: context, entries, excluded }) {
  return sourceIDs(notebookID, context, entries, excluded);
}

/**
 * `e_s`: the Entry an exclusion of `sourceID` is compared with, which is the one an untick names: the
 * source's own Entry in the notebook, else its Entry in the context notebook with the smallest id
 * (plain string order). Null when neither holds the source in context.
 * @param {string} sourceID
 * @param {{notebookID: string, contextNotebookIDs?: string[], entries: TickEntry[]}} context
 */
export function comparedEntry(sourceID, { notebookID, contextNotebookIDs: context = [], entries }) {
  const held = holders(notebookID, context, entries).get(sourceID);
  return held ? compared(held, notebookID) : null;
}

/**
 * The `NotebookState.excluded` change that unticks `entry`'s source. The Entry must be the one
 * `comparedEntry` names, with the stamps the device holds now, a pending change's pinned stamp
 * included (§5.6).
 * @param {TickEntry} entry
 * @returns {import("./envelope.js").Change}
 */
export function untick(entry) {
  return { elements: { [entry.itemID]: stampPair(entry) } };
}

/**
 * The change that ticks `sourceID` again.
 * @param {string} sourceID
 * @returns {import("./envelope.js").Change}
 */
export function tick(sourceID) {
  return { elements: { [sourceID]: null } };
}

/**
 * @param {string} notebookID
 * @param {string[]} context
 * @param {TickEntry[]} entries
 * @param {Record<string, unknown> | null | undefined} excluded
 */
function sourceIDs(notebookID, context, entries, excluded) {
  const result = [];
  for (const [sourceID, held] of holders(notebookID, context, entries)) {
    const entry = compared(held, notebookID);
    if (entry && own(excluded, sourceID) !== stampPair(entry)) result.push(sourceID);
  }
  return result.sort(compareStrings);
}

/**
 * Source id → container id → the Entry that container holds in context, for the notebook and its
 * context notebooks. A container holds one Entry per source (`en:<containerID>:source:<itemID>`).
 * @param {string} notebookID
 * @param {string[]} context
 * @param {TickEntry[]} entries
 */
function holders(notebookID, context, entries) {
  const containers = new Set([...context, notebookID]);
  /** @type {Map<string, Map<string, TickEntry>>} */
  const result = new Map();
  for (const entry of entries) {
    if (!isInContext(entry) || !containers.has(entry.containerID)) continue;
    let held = result.get(entry.itemID);
    if (!held) {
      held = new Map();
      result.set(entry.itemID, held);
    }
    held.set(entry.containerID, entry);
  }
  return result;
}

/** @param {Map<string, TickEntry>} held @param {string} notebookID */
function compared(held, notebookID) {
  const own_ = held.get(notebookID);
  if (own_) return own_;
  const smallest = [...held.keys()].sort(compareStrings)[0];
  return smallest === undefined ? null : /** @type {TickEntry} */ (held.get(smallest));
}

/**
 * The elements a set field holds: the keys whose value is `true` (`false` marks a removal).
 * @param {Record<string, unknown> | null | undefined} set
 */
function members(set) {
  return set ? Object.keys(set).filter((element) => own(set, element) === true) : [];
}
