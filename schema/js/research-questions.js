// A notebook's research questions (docs/cloudkit-schema-design.md §3.5.6, `researchQuestions`): the
// twin of the Mac's `NotebookResearchQuestions.syncRows`, for the hosts that write the map without
// the Mac's rows (the always-on server's MCP tools and the web). Every host keys a question by the
// id it derives from its text (`researchQuestionID`), so two writing one list mint one map.

import { keysBetween } from "./fractional-index.js";
import { isObject } from "./json.js";
import { researchQuestionID } from "./naming.js";
import { trimmingWhitespacesAndNewlines } from "./swift-strings.js";

/**
 * The elements to write when the learner's list replaces a notebook's research questions: each
 * question under its derived id, in the list's order; the same text twice is one question; a held
 * one keeps its `createdAt`; one dropped and asked again is open again; one no longer listed is
 * removed (null) unless it was dropped. A question held under an id of the old rule (a UUID the
 * server or the web minted before 2026-10-10) moves to its derived id with its `createdAt`, as the
 * Mac's next edit would move it.
 * @param {unknown} held the Notebook's `researchQuestions` map as the record holds it (none for a new notebook)
 * @param {string} notebookID
 * @param {string[]} questions the list, in order
 * @param {number} now a new question's `createdAt`, in milliseconds
 * @returns {Promise<Record<string, unknown>>}
 */
export async function researchQuestionElements(held, notebookID, questions, now) {
  const heldEntries = Object.entries(isObject(held) ? held : {})
    .filter(([, question]) => isObject(question) && typeof question.text === "string");
  /** @type {Array<{ id: string, text: string }>} */
  const wanted = [];
  for (const raw of questions) {
    const text = trimmingWhitespacesAndNewlines(raw);
    if (!text) continue;
    const id = await researchQuestionID(notebookID, text);
    if (!wanted.some((question) => question.id === id)) wanted.push({ id, text });
  }
  /** @type {Map<string, any>} */
  const heldByID = new Map(heldEntries);
  /** @type {Map<string, unknown>} */
  const createdAtByID = new Map();
  for (const [id, question] of heldEntries) {
    const derived = await researchQuestionID(notebookID, question.text);
    if (!createdAtByID.has(derived) || derived === id) createdAtByID.set(derived, question.createdAt);
  }
  const keys = wanted.length > 0 ? keysBetween(null, null, wanted.length) : [];
  /** @type {Record<string, unknown>} */
  const elements = {};
  wanted.forEach(({ id, text }, index) => {
    const createdAt = heldByID.get(id)?.createdAt ?? createdAtByID.get(id) ?? now;
    elements[id] = { ...heldByID.get(id), text, status: "open", orderKey: keys[index], createdAt };
  });
  const wantedIDs = new Set(wanted.map((question) => question.id));
  for (const [id, question] of heldEntries) {
    if (question.status !== "dropped" && !wantedIDs.has(id)) elements[id] = null;
  }
  return elements;
}
