// The shared value shapes of docs/cloudkit-schema-design.md §3.3: the twin of Swift's Values.swift.
// Each shape is the plain JSON object a payload holds, read in place, so a key this build does not
// know survives a read and a write back (§6.5). Vectors: schema/vectors/locator.json.

import { LIMITS, PERSONAL_SATELLITE_ROLES } from "./schema.generated.js";
import { isObject, own } from "./json.js";
import { contentID, sha256Hex } from "./naming.js";

/**
 * A CloudKit user in a space: `{"user": "<user record name>", "name": "<display name>"}`.
 * @param {unknown} value
 */
export function isPerson(value) {
  const user = own(value, "user");
  return typeof user === "string" && user.length > 0;
}

const ITEM_REF_KINDS = new Set(["src", "col", "nb", "gl", "crs", "les", "qz", "cht", "exc", "art", "crd", "wk", "all"]);

/**
 * `"<kind>:<id>"` with an optional `#<subKey>`, such as `src:src_2cd9#idea-17` or `qz:cq-1913#q3`, read
 * as `{kind, id, subKey?}`, or null. The sub-key is what follows the first `#`, except for card and
 * work-key references, whose ids carry `#` themselves (`card:<deck>:walk:<src>#q3`,
 * `podcast:<feed>#<guid>`): those, and kinds this build does not know, keep everything after the colon
 * as the id. `all` alone is the kind `all` with an empty id.
 * @param {string} text
 * @returns {{kind: string, id: string, subKey?: string} | null}
 */
export function parseItemRef(text) {
  if (text === "all") return { kind: "all", id: "" };
  const colon = text.indexOf(":");
  if (colon < 0) return null;
  const kind = text.slice(0, colon);
  const rest = text.slice(colon + 1);
  const takesSubKey = ITEM_REF_KINDS.has(kind) && kind !== "crd" && kind !== "wk";
  const hash = rest.indexOf("#");
  if (takesSubKey && hash >= 0) {
    const id = rest.slice(0, hash);
    return id ? { kind, id, subKey: rest.slice(hash + 1) } : null;
  }
  return rest ? { kind, id: rest } : null;
}

/** @param {{kind: string, id: string, subKey?: string}} ref */
export function formatItemRef(ref) {
  if (ref.kind === "all" && ref.id === "") return "all";
  return `${ref.kind}:${ref.id}${ref.subKey === undefined ? "" : `#${ref.subKey}`}`;
}

const LOCATOR_KINDS = new Set(["pdf", "text", "epub", "media", "web", "slide", "doc"]);

/**
 * A place in a source or Doc: an object with a string `t` (`pdf`, `text`, `epub`, `media`, `web`,
 * `slide`, `doc`, or a kind this build does not know, kept raw).
 * @param {unknown} value
 */
export function isLocator(value) {
  return typeof own(value, "t") === "string";
}

/** A locator's kind, `unknown` for a `t` this build does not know. @param {unknown} locator */
export function locatorKind(locator) {
  const kind = own(locator, "t");
  return typeof kind === "string" && LOCATOR_KINDS.has(kind) ? kind : "unknown";
}

/**
 * The rules the spec states: a PDF quad is 8 numbers, each within 0…1 (page-normalized, origin top-left).
 * @param {unknown} locator
 */
export function isValidLocator(locator) {
  if (own(locator, "t") !== "pdf" || own(locator, "quads") === undefined) return true;
  const quads = own(locator, "quads");
  if (!Array.isArray(quads)) return false;
  return quads.every((quad) => Array.isArray(quad) && quad.length === 8
    && quad.every((number) => typeof number === "number" && number >= 0 && number <= 1));
}

/**
 * The shape `Span`, a lesson item's range of a source: an object whose `from` and `to` are Locators.
 * @param {unknown} value
 */
export function isSpan(value) {
  return isObject(value) && isLocator(own(value, "from")) && isLocator(own(value, "to"));
}

/** Both ends valid and of one kind. @param {unknown} span */
export function isValidSpan(span) {
  const from = own(span, "from");
  const to = own(span, "to");
  return isValidLocator(from) && isValidLocator(to) && own(from, "t") === own(to, "t");
}

/**
 * Provenance of a record: `{"route", "device", "at", "model"?, "chatID"?}`; `route` is required.
 * @param {unknown} value
 */
export function isMadeBy(value) {
  return typeof own(value, "route") === "string";
}

/**
 * A pointer to immutable `Content` satellites (§3.3, §3.5.30): an object naming its `owner` and
 * `role` and at least one part hash. Every satellite's logical id, `ct:<owner>:<role>:<partHash32>`,
 * follows from `owner`, `role` and one entry of `parts`, the first 32 hex characters of the sha256 of
 * that part's stored bytes (after gzip when `enc` is gzip). A copy of a FileRef into another record
 * keeps it verbatim, owner included (D41), so its names stay valid.
 * @param {unknown} value
 */
export function isFileRef(value) {
  const owner = own(value, "owner");
  const role = own(value, "role");
  const parts = own(value, "parts");
  return typeof owner === "string" && owner.length > 0 && typeof role === "string" && role.length > 0
    && Array.isArray(parts) && parts.length > 0 && parts.every((part) => typeof part === "string");
}

/** The FileRefs a FileRef lists as `children` (walkthrough pictures, narration chunks). @param {unknown} fileRef */
export function fileRefChildren(fileRef) {
  const children = own(fileRef, "children");
  return Array.isArray(children) ? children.filter(isFileRef) : [];
}

/** Personal satellites (understanding, learner model, draft bases) always stay in private `Content`. @param {unknown} fileRef */
export function isPersonalFileRef(fileRef) {
  return PERSONAL_SATELLITE_ROLES.includes(own(fileRef, "role"));
}

/**
 * The satellites' logical ids: this file's parts in order, then each child's, so GC and prefetch
 * never parse a body.
 * @param {unknown} fileRef
 * @returns {string[]}
 */
export function fileRefSatelliteIDs(fileRef) {
  const parts = own(fileRef, "parts");
  const own_ = Array.isArray(parts) ? parts.filter((part) => typeof part === "string") : [];
  return [
    ...own_.map((part) => contentID(String(own(fileRef, "owner") ?? ""), String(own(fileRef, "role") ?? ""), part)),
    ...fileRefChildren(fileRef).flatMap(fileRefSatelliteIDs),
  ];
}

/**
 * A FileRef as the spec shapes it: a 64-hex `hash`, every part a 32-hex hash, an inline body in
 * exactly one part, and well-formed children.
 * @param {unknown} fileRef
 * @returns {boolean}
 */
export function isWellFormedFileRef(fileRef) {
  if (!isFileRef(fileRef)) return false;
  const hash = own(fileRef, "hash");
  const parts = /** @type {string[]} */ (own(fileRef, "parts"));
  return isHex(typeof hash === "string" ? hash : "", 64) && parts.every((part) => isHex(part, 32))
    && (own(fileRef, "inline") !== true || parts.length === 1)
    && fileRefChildren(fileRef).every(isWellFormedFileRef);
}

/**
 * The first 32 hex characters of the sha256 of one stored part.
 * @param {Uint8Array} storedPart
 */
export async function partHash32(storedPart) {
  return (await sha256Hex(storedPart)).slice(0, 32);
}

/**
 * `stored` cut into parts of `partSize` bytes, the last smaller (§3.5.30 rule 7); the web uses
 * `LIMITS.satellitePartBytesWeb`.
 * @param {Uint8Array} stored
 * @param {number} partSize
 */
export function splitStoredBytes(stored, partSize) {
  if (!(partSize > 0)) throw new RangeError("a part has at least one byte");
  if (stored.length === 0) return [new Uint8Array(0)];
  const parts = [];
  for (let offset = 0; offset < stored.length; offset += partSize) parts.push(stored.subarray(offset, Math.min(offset + partSize, stored.length)));
  return parts;
}

/**
 * The FileRef of a body already split into stored parts.
 * @param {{owner: string, role: string, hash: string, size: number, mime: string, encoding: string,
 *          storedParts: Uint8Array[], children?: object[], heldBy?: string}} file
 */
export async function makeFileRef({ owner, role, hash, size, mime, encoding, storedParts, children = [], heldBy }) {
  if (storedParts.length === 0) throw new RangeError("a FileRef names at least one part");
  const stored = storedParts.reduce((total, part) => total + part.length, 0);
  /** @type {Record<string, unknown>} */
  const fileRef = {
    owner, role, hash, size, mime, enc: encoding, stored,
    parts: await Promise.all(storedParts.map(partHash32)),
    inline: storedParts.length === 1 && stored <= LIMITS.inlineSatelliteMaxBytes,
  };
  if (children.length > 0) fileRef.children = children;
  if (heldBy !== undefined) fileRef.heldBy = heldBy;
  return fileRef;
}

/** @param {string} value @param {number} count */
function isHex(value, count) {
  return value.length === count && /^[0-9a-f]*$/.test(value);
}
