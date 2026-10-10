// Record names and the deterministic ids of docs/cloudkit-schema-design.md §3.4 and §4.1: the twin of
// Swift's RecordNaming.swift. `recordName = prefix + "_" + base32lower(HMAC-SHA256(zoneSalt,
// type + "\n" + id))[0..<26]`, and `root` for a zone's ZoneRoot. Names carry no title, URL or user
// text, since CloudKit shows them in clear. Hashing is WebCrypto (browsers, Node 20 and later,
// Workers), so every function that hashes returns a Promise. Vectors: schema/vectors/naming.json.

import { RECORD_NAME_HASH_LENGTH, ROOT_RECORD_NAME, TYPE_BY_PREFIX, TYPES } from "./schema.generated.js";
import { base64Decode, hexString, utf8Bytes } from "./json.js";
import { lowercased, trimmingWhitespacesAndNewlines } from "./swift-strings.js";

export const SALT_BYTE_COUNT = 32;
/** The device id migrated history is written under (`al:<day>:legacy22`); never drawn. */
export const LEGACY_DEVICE_ID = "legacy22";

/** @param {Uint8Array | string} value */
function bytesOf(value) {
  return typeof value === "string" ? utf8Bytes(value) : value;
}

/**
 * Lowercase hex sha256 of bytes, or of a string's UTF-8.
 * @param {Uint8Array | string} value
 * @returns {Promise<string>}
 */
export async function sha256Hex(value) {
  return hexString(new Uint8Array(await crypto.subtle.digest("SHA-256", bytesOf(value))));
}

/** @type {WeakMap<Uint8Array, Promise<CryptoKey>>} */
const saltKeys = new WeakMap();

/** @param {Uint8Array} salt */
function hmacKey(salt) {
  let key = saltKeys.get(salt);
  if (!key) {
    key = crypto.subtle.importKey("raw", salt, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    saltKeys.set(salt, key);
  }
  return key;
}

/**
 * The record name of `type`'s record `id` in a zone with `salt` (32 bytes).
 * @param {string} type
 * @param {string} id
 * @param {Uint8Array} salt
 * @returns {Promise<string>}
 */
export async function recordName(type, id, salt) {
  if (!Object.hasOwn(TYPES, type)) throw new RangeError(`${type} is not a record type`);
  const spec = TYPES[/** @type {keyof typeof TYPES} */ (type)];
  if (spec.fixedRecordName) return spec.fixedRecordName;
  const code = await crypto.subtle.sign("HMAC", await hmacKey(salt), utf8Bytes(`${type}\n${id}`));
  return `${spec.prefix}_${base32(new Uint8Array(code)).slice(0, RECORD_NAME_HASH_LENGTH)}`;
}

/**
 * The record type a name belongs to, from its prefix, so a bare deletion is routed without a
 * lookup; undefined for a name of no known type.
 * @param {string} name
 */
export function recordTypeOfRecordName(name) {
  if (name === ROOT_RECORD_NAME) return "ZoneRoot";
  const separator = name.indexOf("_");
  if (separator < 0) return undefined;
  const prefix = name.slice(0, separator);
  return Object.hasOwn(TYPE_BY_PREFIX, prefix) ? TYPE_BY_PREFIX[prefix] : undefined;
}

/**
 * A zone's salt from `ZoneRoot.salt`: base64 of exactly 32 bytes, else undefined.
 * @param {string} text
 */
export function saltFromBase64(text) {
  const bytes = base64Decode(text);
  return bytes && bytes.length === SALT_BYTE_COUNT ? bytes : undefined;
}

export function newSalt() {
  return crypto.getRandomValues(new Uint8Array(SALT_BYTE_COUNT));
}

/**
 * The first 8 hex characters of sha256 of the 32 salt bytes (§2.4 step 6), repeated in every payload.
 * @param {Uint8Array} salt
 */
export async function saltID(salt) {
  return (await sha256Hex(salt)).slice(0, 8);
}

const BASE32 = "abcdefghijklmnopqrstuvwxyz234567";

/**
 * RFC 4648 base32, lowercase, no padding.
 * @param {Uint8Array} bytes
 */
export function base32(bytes) {
  let output = "";
  let buffer = 0;
  let bits = 0;
  for (const byte of bytes) {
    buffer = ((buffer << 8) | byte) & 0xffff;
    bits += 8;
    while (bits >= 5) {
      output += BASE32[(buffer >> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) output += BASE32[(buffer << (5 - bits)) & 31];
  return output;
}

// MARK: - Deterministic ids (§4.1)

/** A new installation's device id: 5 random bytes as 8 base32 characters, never `legacy22`. */
export function newDeviceID() {
  for (;;) {
    const id = base32(crypto.getRandomValues(new Uint8Array(5)));
    if (id !== LEGACY_DEVICE_ID) return id;
  }
}

/**
 * A web source: `src_` + hex(sha256("source:v1:" + URLNormalizer v1 of its URL)), as the Mac's
 * `SourceIdentity.stableID` mints it. url-normalize-v1.js gives the normalized URL, or throws
 * HostNeedsMac for a host that needs IDNA, whose source a Mac mints (a Job), never this function.
 * @param {string} normalizedURL
 */
export async function sourceID(normalizedURL) {
  return `src_${await sha256Hex(`source:v1:${normalizedURL}`)}`;
}

/**
 * A file captured on the iPhone or the web (D47), from the lowercase hex sha256 of its bytes, so
 * the same bytes captured twice land on one source.
 * @param {string} fileHash
 */
export async function sourceFileID(fileHash) {
  return `src_${await sha256Hex(`source:v1:file:${fileHash}`)}`;
}

/**
 * A show or channel: `col_` + hex(sha256("collection:v1:<kind>:<externalKey>")).
 * @param {string} kind
 * @param {string} externalKey
 */
export async function collectionID(kind, externalKey) {
  return `col_${await sha256Hex(`collection:v1:${kind}:${externalKey}`)}`;
}

/**
 * Migrated history: `sit:legacy:` + the first 24 hex characters of sha256 of `session:<session_id>`,
 * `day:<YYYY-MM-DD>` or `quiz:<courseQuiz|lectureQuiz>:<preference key>`.
 * @param {string} input
 */
export async function sittingLegacyID(input) {
  return `sit:legacy:${(await sha256Hex(input)).slice(0, 24)}`;
}

/**
 * A notebook's research question, the key of its element in the Notebook's `researchQuestions` map:
 * `rq_` + the first 24 hex characters of sha256("researchQuestion:v1:<notebookID>:<text trimmed and
 * lowercased>"), as the Mac's `NotebookResearchQuestions.questionID` mints it. Every host derives it,
 * so two writing one list mint one map, and a question asked again comes back under its old id.
 * @param {string} notebookID
 * @param {string} text
 */
export async function researchQuestionID(notebookID, text) {
  const normalized = lowercased(trimmingWhitespacesAndNewlines(text));
  return `rq_${(await sha256Hex(`researchQuestion:v1:${notebookID}:${normalized}`)).slice(0, 24)}`;
}

/**
 * `en:<containerID>:<itemKind>:<itemID>`; a second span of one item in a lesson adds `#2`, `#3`…
 * @param {string} containerID
 * @param {string} itemKind
 * @param {string} itemID
 * @param {number} [span]
 */
export function entryID(containerID, itemKind, itemID, span = 1) {
  return `en:${containerID}:${itemKind}:${itemID}${span > 1 ? `#${span}` : ""}`;
}

/** @param {string} deviceID */
export const deviceRecordID = (deviceID) => `dev:${deviceID}`;
/** @param {string} courseID */
export const enrollmentID = (courseID) => `enr:${courseID}`;
/** @param {string} targetID */
export const readingStateID = (targetID) => `rs:${targetID}`;
/** @param {string} kind @param {string} target */
export const markID = (kind, target) => `mk:${kind}:${target}`;
/** @param {string} notebookID */
export const notebookStateID = (notebookID) => `ns:${notebookID}`;
/** @param {string} sourceID */
export const placementID = (sourceID) => `pl:${sourceID}`;
/** @param {string} day @param {string} deviceID */
export const activityLogID = (day, deviceID) => `al:${day}:${deviceID}`;
/** @param {string} deckSourceID @param {string} seedKey */
export const cardDraftID = (deckSourceID, seedKey) => `card:${deckSourceID}:${seedKey}`;
/** @param {string} ruleID @param {string} scope @param {string} period */
export const practiceID = (ruleID, scope, period) => `pr:${ruleID}:${scope}:${period}`;
/** @param {string} kind @param {string} target */
export const jobID = (kind, target) => `job:${kind}:${target}`;
/** @param {string} owner @param {string} role @param {string} partHash32 */
export const contentID = (owner, role, partHash32) => `ct:${owner}:${role}:${partHash32}`;
