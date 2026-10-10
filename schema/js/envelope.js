// The payload envelope (docs/cloudkit-schema-design.md §3.2, §6.5): the twin of Swift's
// Envelope.swift. Every record's `payload` is one JSON object of `env`, `type`, `id`, `rev`,
// `saltID`, `fields` and `stamps`. Here an envelope is that plain object itself, so a top-level key,
// field, map key or set element this build does not know survives a read and a write back by
// construction, and a client writes only by patching the envelope it holds (`applyPatch`), never
// by encoding a record from its own model. Vectors: schema/vectors/envelope.json.

import { ENVELOPE_VERSION, LIMITS, SCHEMA_REVISION, SPILL_MARKER_KEY, TYPES } from "./schema.generated.js";
import {
  compareStrings,
  copyJSON,
  integerValue,
  isObject,
  isPlainObject,
  isWellFormedText,
  jsonEquivalent,
  jsonValueProblem,
  own,
  parseJSON,
  serializeJSON,
  setOwn,
  utf8Bytes,
  utf8Text,
} from "./json.js";
import { isStamp } from "./stamp.js";
import { sha256Hex } from "./naming.js";
import { isFileRef } from "./values.js";

/**
 * @typedef {Record<string, any> & {env: number, type: string, id: string, rev: number, saltID: string,
 *   fields: Record<string, any>, stamps: Record<string, string | Record<string, string>>}} Envelope
 */

/** The record type's schema, or undefined for a type this build does not know. @param {unknown} type */
export function typeSpec(type) {
  return typeof type === "string" && Object.hasOwn(TYPES, type) ? TYPES[/** @type {keyof typeof TYPES} */ (type)] : undefined;
}

/** A field's schema in a type's schema, or undefined. @param {any} spec @param {string} field */
export function fieldSpec(spec, field) {
  return spec && Object.hasOwn(spec.fields, field) ? spec.fields[field] : undefined;
}

/**
 * Why a payload could not be read: `notAnEnvelope` (not JSON, not an object, missing an envelope
 * key, or gzip that does not inflate within `LIMITS.payloadMaxInflatedBytes`), `unsupportedEnvelope`
 * (an envelope version this build cannot read; keep the raw payload), `invalidStamp` (a stamp outside
 * the grammar) or `payloadTooLarge` (stored bytes over 256 KiB: park the record in quarantine).
 */
export class SyncEnvelopeError extends Error {
  /** @param {"notAnEnvelope" | "unsupportedEnvelope" | "invalidStamp" | "payloadTooLarge"} code @param {Record<string, unknown>} [detail] */
  constructor(code, detail = {}) {
    super(detail.field ? `${code}: ${detail.field}` : code);
    this.name = "SyncEnvelopeError";
    this.code = code;
    this.detail = detail;
  }
}

/**
 * The envelope a JSON value holds, checked as Swift's `SyncEnvelope(json:)` checks it; throws
 * SyncEnvelopeError. The value is copied, never shared.
 * @param {unknown} value
 * @returns {Envelope}
 */
export function envelopeFromJSON(value) {
  if (!isObject(value)) throw new SyncEnvelopeError("notAnEnvelope");
  const object = /** @type {Record<string, any>} */ (value);
  const env = integerValue(own(object, "env"));
  if (env === undefined) throw new SyncEnvelopeError("notAnEnvelope");
  if (env !== ENVELOPE_VERSION) throw new SyncEnvelopeError("unsupportedEnvelope", { env });
  if (typeof own(object, "type") !== "string" || typeof own(object, "id") !== "string"
    || integerValue(own(object, "rev")) === undefined || typeof own(object, "saltID") !== "string"
    || !isObject(own(object, "fields")) || !isObject(own(object, "stamps"))) {
    throw new SyncEnvelopeError("notAnEnvelope");
  }
  for (const [field, stamp] of Object.entries(object.stamps)) {
    if (typeof stamp === "string") {
      if (!isStamp(stamp)) throw new SyncEnvelopeError("invalidStamp", { field });
    } else if (isObject(stamp)) {
      for (const element of Object.values(stamp)) {
        if (!isStamp(element)) throw new SyncEnvelopeError("invalidStamp", { field });
      }
    } else {
      throw new SyncEnvelopeError("invalidStamp", { field });
    }
  }
  return /** @type {Envelope} */ (copyJSON(object));
}

/**
 * Reads stored payload bytes: gzip when they start `1F 8B`, else UTF-8 JSON (§3.2 rule 1; Swift's
 * JSONSerialization also reads UTF-16 and UTF-32, which lane A is to refuse as this does). Gzip that
 * would inflate past `LIMITS.payloadMaxInflatedBytes` is refused before it is inflated, so a small
 * record written into a space cannot make every member's device hold hundreds of megabytes.
 * @param {Uint8Array} bytes
 * @returns {Envelope}
 */
export function decodeStoredPayload(bytes) {
  let text = bytes;
  if (isGzip(bytes)) {
    try {
      text = gzipDecompress(bytes, LIMITS.payloadMaxInflatedBytes);
    } catch {
      throw new SyncEnvelopeError("notAnEnvelope");
    }
  }
  const json = utf8Text(text);
  if (json === undefined) throw new SyncEnvelopeError("notAnEnvelope");
  let value;
  try {
    value = parseJSON(json);
  } catch {
    throw new SyncEnvelopeError("notAnEnvelope");
  }
  return envelopeFromJSON(value);
}

/**
 * The bytes stored in `payload`: compact JSON with sorted keys, gzip above 16 KiB, refused
 * (`payloadTooLarge`) above 256 KiB. An envelope holding a value no reader would take back, which
 * only one built by hand can, throws JSONValueError rather than be written.
 * @param {Envelope} envelope
 * @returns {Promise<Uint8Array>}
 */
export async function encodeStoredPayload(envelope) {
  const text = utf8Bytes(serializeJSON(envelope));
  const stored = storageForm(text.length) === "gzip" ? await gzipCompress(text) : text;
  checkStoredSize(stored.length);
  return stored;
}

/** "plain" or "gzip" for an encoded JSON of `jsonByteCount` bytes. @param {number} jsonByteCount */
export function storageForm(jsonByteCount) {
  return jsonByteCount > LIMITS.payloadGzipThresholdBytes ? "gzip" : "plain";
}

/** Throws `payloadTooLarge` for stored bytes over the cap. @param {number} storedBytes */
export function checkStoredSize(storedBytes) {
  if (storedBytes > LIMITS.payloadMaxBytes) throw new SyncEnvelopeError("payloadTooLarge", { storedBytes });
}

/**
 * An empty envelope for a record this client creates.
 * @param {string} type
 * @param {string} id
 * @param {string} saltID
 * @returns {Envelope}
 */
export function newEnvelope(type, id, saltID) {
  return { env: ENVELOPE_VERSION, type, id, rev: SCHEMA_REVISION, saltID, fields: {}, stamps: {} };
}

// MARK: - Spilled strings (§3.2 rule 8)

/**
 * Whether a string of `utf8Count` bytes in `type.field` is stored as a `field.<name>` satellite:
 * above 32 KiB, and only for a plain scalar string field (never an enum, a set or a field marked
 * `spill: false`).
 * @param {string} type
 * @param {string} field
 * @param {number} utf8Count
 */
export function spills(type, field, utf8Count) {
  const spec = fieldSpec(typeSpec(type), field);
  return Boolean(spec?.spills) && utf8Count > LIMITS.spillStringBytes;
}

/** `{"$file": FileRef}`, the value a spilled field holds under its own stamp. @param {object} fileRef */
export function spillMarker(fileRef) {
  /** @type {Record<string, unknown>} */
  const marker = {};
  setOwn(marker, SPILL_MARKER_KEY, fileRef);
  return marker;
}

/** The FileRef a spilled field's value points at, or undefined. @param {unknown} value */
export function spilledFile(value) {
  if (!isObject(value)) return undefined;
  const keys = Object.keys(/** @type {object} */ (value));
  if (keys.length !== 1 || keys[0] !== SPILL_MARKER_KEY) return undefined;
  const file = own(value, SPILL_MARKER_KEY);
  return isFileRef(file) ? file : undefined;
}

/** The fields whose value is a spilled string, sorted. @param {Envelope} envelope */
export function spilledFields(envelope) {
  return Object.keys(envelope.fields).filter((field) => spilledFile(envelope.fields[field]) !== undefined).sort(compareStrings);
}

// MARK: - Writing (§6.5 rule 1)

/**
 * @typedef {{value: unknown} | {elements: Record<string, unknown>}} Change
 * A scalar field's whole new value (`null` clears it), or a map's changed keys (`null` removes one)
 * or a set's changed elements (`true`, `false`).
 * @typedef {{type: string, id: string, changes: Record<string, Change>}} RecordPatch
 * @typedef {{field: string, element?: string}} StampedPath
 */

/**
 * Why a patch was refused. Two codes are the JS core's own, since Swift's types rule out what they
 * catch: `notAChange` (a change that is not `{value}` or `{elements}`: a bare value, `{}`, both) and
 * `notJSON` (a value or element a payload cannot hold, `reason` says which: see `jsonValueProblem`).
 */
export class RecordPatchError extends Error {
  /**
   * @param {"wrongRecord" | "unknownType" | "unknownField" | "wrongKind" | "notASetElement" | "leavesTerminalValue" | "notAChange" | "notJSON"} code
   * @param {string} [field]
   * @param {string} [element]
   * @param {string} [reason]
   */
  constructor(code, field, element, reason) {
    super(`${field ? `${code}: ${field}${element === undefined ? "" : `[${element}]`}` : code}${reason ? ` (${reason})` : ""}`);
    this.name = "RecordPatchError";
    this.code = code;
    this.field = field;
    this.element = element;
    this.reason = reason;
  }
}

/** `field` or `field[key]`. @param {StampedPath} path */
export function pathDescription(path) {
  return path.element === undefined ? path.field : `${path.field}[${path.element}]`;
}

/**
 * Patches `patch` onto `held` and returns the patched envelope with the paths it stamped, sorted.
 * `held` is never changed: a refusal, or a stamp that cannot be minted, throws and leaves nothing
 * half written.
 *
 * A value equal to the one held (compared in the wire domain, rule 9) is dropped and keeps its
 * stamp, so re-saving a form or restoring a position stamps nothing; so is a long string whose
 * sha256 is the hash of the satellite the field already spilled into. Every other value gets
 * `await stamp(path, policy, seen)`, where `seen` is the stamp held for that path: the writer's
 * pinned stamp for the change, or one `StampClock.mint` makes against `seen`. A writer that pins a
 * minted stamp keeps the `seen` it was minted against beside it and gives it back to the merge
 * (`merge(…, mintedAgainst)`). Keys of a map or set the patch does not name, and every field it does
 * not name, stay exactly as held. Fields are stamped in name order, elements in key order. This is
 * async (WebCrypto, and the stamp callback) where Swift's apply is not, so a writer applies one
 * record's patches one at a time: two started on one held envelope each patch the same base, and
 * the result saved later drops the change of the other (WP22's and WP25b's writers). A record
 * type this build does not know is never written (`unknownType`), and a change that is not one, or a
 * value a payload cannot hold, is refused before anything is stamped (`notAChange`, `notJSON`): a
 * missing value is never a clear (§3.2 rule 6), and nothing a patch writes is unreadable.
 * @param {Envelope} held
 * @param {RecordPatch} patch
 * @param {(path: StampedPath, policy: string, seen: string | undefined) => string | Promise<string>} stamp
 * @returns {Promise<{envelope: Envelope, stamped: StampedPath[]}>}
 */
export async function applyPatch(held, patch, stamp) {
  if (patch.type !== held.type || patch.id !== held.id) throw new RecordPatchError("wrongRecord");
  const spec = typeSpec(patch.type);
  if (!spec) throw new RecordPatchError("unknownType", patch.type);
  checkChanges(spec, patch);
  const patched = copyJSON(held);
  /** @type {StampedPath[]} */
  const stamped = [];
  for (const field of Object.keys(patch.changes).sort(compareStrings)) {
    const change = /** @type {any} */ (patch.changes[field]);
    const fieldSchema = fieldSpec(spec, field);
    if (fieldSchema.kind === "scalar") {
      const value = change.value;
      const heldValue = own(patched.fields, field);
      if (heldValue !== undefined && await sameWireValue(heldValue, value)) continue;
      if (typeof heldValue === "string" && (fieldSchema.terminalValues ?? []).includes(heldValue)) {
        throw new RecordPatchError("leavesTerminalValue", field);
      }
      const heldStamp = own(patched.stamps, field);
      /** @type {StampedPath} */
      const path = { field };
      const minted = await stamp(path, fieldSchema.policy, typeof heldStamp === "string" ? heldStamp : undefined);
      if (!isStamp(minted)) throw new TypeError(`no stamp minted for ${field}`);
      setOwn(patched.stamps, field, minted);
      setOwn(patched.fields, field, copyJSON(value));
      stamped.push(path);
    } else {
      const heldObject = own(patched.fields, field);
      const heldStamps = own(patched.stamps, field);
      /** @type {Record<string, any>} */
      const values = isObject(heldObject) ? heldObject : {};
      /** @type {Record<string, string>} */
      const stamps = isObject(heldObject) && isObject(heldStamps) ? heldStamps : {};
      let changed = false;
      for (const element of Object.keys(change.elements).sort(compareStrings)) {
        const value = change.elements[element];
        const heldValue = own(values, element);
        if (heldValue !== undefined && own(stamps, element) !== undefined && await sameWireValue(heldValue, value)) continue;
        /** @type {StampedPath} */
        const path = { field, element };
        const minted = await stamp(path, fieldSchema.policy, own(stamps, element));
        if (!isStamp(minted)) throw new TypeError(`no stamp minted for ${pathDescription(path)}`);
        setOwn(stamps, element, minted);
        setOwn(values, element, copyJSON(value));
        stamped.push(path);
        changed = true;
      }
      if (changed) {
        setOwn(patched.fields, field, values);
        setOwn(patched.stamps, field, stamps);
      }
    }
  }
  if (stamped.length > 0) patched.rev = SCHEMA_REVISION;
  stamped.sort((a, b) => compareStrings(pathDescription(a), pathDescription(b)));
  return { envelope: patched, stamped };
}

/** Where a scalar field's value sits in a payload (envelope, `fields`, value), and a map's element. */
const VALUE_DEPTH = 2;
const ELEMENT_DEPTH = 3;

/**
 * Refuses a patch, before anything is stamped, whose changes are not changes of the type's fields of
 * the right kind or hold what a payload cannot (RecordPatchError), in the order the fields and
 * elements are stamped.
 * @param {any} spec
 * @param {RecordPatch} patch
 */
function checkChanges(spec, patch) {
  if (!isPlainObject(patch.changes)) throw new RecordPatchError("notAChange");
  for (const field of Object.keys(patch.changes).sort(compareStrings)) {
    const change = /** @type {unknown} */ (patch.changes[field]);
    const fieldSchema = fieldSpec(spec, field);
    if (!fieldSchema) throw new RecordPatchError("unknownField", field);
    const hasValue = isPlainObject(change) && Object.hasOwn(change, "value");
    const hasElements = isPlainObject(change) && Object.hasOwn(change, "elements");
    if (hasValue === hasElements) throw new RecordPatchError("notAChange", field);
    if ((fieldSchema.kind === "scalar") !== hasValue) throw new RecordPatchError("wrongKind", field);
    const changeObject = /** @type {Record<string, unknown>} */ (change);
    if (hasValue) {
      const problem = jsonValueProblem(changeObject.value, VALUE_DEPTH);
      if (problem !== undefined) throw new RecordPatchError("notJSON", field, undefined, problem);
      continue;
    }
    const elements = changeObject.elements;
    if (!isPlainObject(elements)) throw new RecordPatchError("wrongKind", field);
    for (const element of Object.keys(elements).sort(compareStrings)) {
      const value = elements[element];
      if (fieldSchema.kind === "set" && typeof value !== "boolean") throw new RecordPatchError("notASetElement", field, element);
      if (!isWellFormedText(element)) throw new RecordPatchError("notJSON", field, element, "a lone surrogate in a key");
      const problem = jsonValueProblem(value, ELEMENT_DEPTH);
      if (problem !== undefined) throw new RecordPatchError("notJSON", field, element, problem);
    }
  }
}

/**
 * Equal in the wire domain, as Swift's `sameWireValue` compares (`SyncJSON ==`: strings by canonical
 * equivalence), where a long string equals the spilled satellite of the same text.
 * @param {unknown} held
 * @param {unknown} value
 */
export async function sameWireValue(held, value) {
  if (jsonEquivalent(held, value)) return true;
  const file = spilledFile(held);
  if (file && typeof value === "string") return (await sha256Hex(value)) === own(file, "hash");
  return false;
}

// MARK: - Milliseconds

const COCOA_EPOCH_OFFSET_SECONDS = 978_307_200;

/**
 * The wire's dates are integer epoch milliseconds (§3.2 rule 6). The Mac stores Cocoa seconds
 * (`Date.timeIntervalSinceReferenceDate`); converting rounds half away from zero in IEEE double, as
 * the `cocoaToMs` and `msRoundTrip` vectors pin, so an unchanged date compares equal.
 * @param {number} cocoaSeconds
 */
export function millisecondsFromCocoaSeconds(cocoaSeconds) {
  const scaled = (cocoaSeconds + COCOA_EPOCH_OFFSET_SECONDS) * 1000;
  const rounded = Math.sign(scaled) * Math.round(Math.abs(scaled));
  return rounded === 0 ? 0 : rounded;
}

/** @param {number} milliseconds */
export function cocoaSecondsFromMilliseconds(milliseconds) {
  return milliseconds / 1000 - COCOA_EPOCH_OFFSET_SECONDS;
}

// MARK: - gzip (RFC 1952 around raw DEFLATE, RFC 1951)

/** @param {Uint8Array} bytes */
export function isGzip(bytes) {
  return bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b;
}

/**
 * Why gzip was refused: `notGzip` (no gzip magic or deflate method), `header` (a header that runs into
 * the trailer), `claimTooLarge` (the trailer claims more than the limit, refused before inflating),
 * `pastClaim` (the stream inflates past what its trailer claims; never more than one byte past it is
 * held), `sizeDiffers` or `crcDiffers` (the bytes do not match the trailer; a stream that cannot be
 * inflated gives no bytes).
 */
export class GzipError extends Error {
  /** @param {"notGzip" | "header" | "claimTooLarge" | "pastClaim" | "sizeDiffers" | "crcDiffers"} reason */
  constructor(reason) {
    super(reason);
    this.name = "GzipError";
    this.reason = reason;
  }
}

/** A raw DEFLATE stream that cannot be inflated, or one that would pass its output limit. */
class InflateError extends Error {
  /** @param {string} message @param {boolean} [pastLimit] */
  constructor(message, pastLimit = false) {
    super(message);
    this.name = "InflateError";
    this.pastLimit = pastLimit;
  }
}

/**
 * The bytes a gzip member holds, refused (GzipError) when they would be more than `maxBytes`. The
 * trailer's size is only a claim: nothing past one byte more than it is ever inflated, so a stream
 * that inflates past its claim is refused without holding more, and nothing past `maxBytes` is
 * inflated. As Swift's `SyncGzip` reads it: the member's DEFLATE data runs from the end of its header
 * to the 8-byte trailer, which must give the inflated size and CRC-32; bytes after the final block
 * are not read, and a stored block's length complement is not checked. One difference is the Swift
 * side's to close (lane A): Apple's decoder gives partial output for some streams cut before their
 * final block ends, which SyncGzip then accepts when it matches the trailer, while this inflate
 * refuses any stream that ends early. The inflate is written here because a platform decompressor
 * can neither stop at a size nor read a member exactly so.
 * @param {Uint8Array} bytes
 * @param {number} maxBytes
 * @returns {Uint8Array}
 */
export function gzipDecompress(bytes, maxBytes) {
  if (bytes.length < 18 || bytes[0] !== 0x1f || bytes[1] !== 0x8b || bytes[2] !== 0x08) throw new GzipError("notGzip");
  const flags = bytes[3];
  let index = 10;
  if (flags & 0x04) {
    if (index + 2 > bytes.length) throw new GzipError("header");
    index += 2 + bytes[index] + (bytes[index + 1] << 8);
  }
  for (const flag of [0x08, 0x10]) {
    if (flags & flag) {
      while (index < bytes.length && bytes[index] !== 0) index += 1;
      index += 1;
    }
  }
  if (flags & 0x02) index += 2;
  if (!(index < bytes.length - 8)) throw new GzipError("header");
  const trailer = bytes.length - 8;
  const expectedCRC = (bytes[trailer] | (bytes[trailer + 1] << 8) | (bytes[trailer + 2] << 16) | (bytes[trailer + 3] << 24)) >>> 0;
  const expectedSize = (bytes[trailer + 4] | (bytes[trailer + 5] << 8) | (bytes[trailer + 6] << 16) | (bytes[trailer + 7] << 24)) >>> 0;
  if (expectedSize > maxBytes) throw new GzipError("claimTooLarge");
  let inflated;
  try {
    inflated = inflateRaw(bytes.subarray(index, trailer), expectedSize);
  } catch (error) {
    if (error instanceof InflateError && error.pastLimit) throw new GzipError("pastClaim");
    inflated = new Uint8Array(0);
  }
  if (inflated.length !== expectedSize) throw new GzipError("sizeDiffers");
  if (crc32(inflated) !== expectedCRC) throw new GzipError("crcDiffers");
  return inflated;
}

/**
 * Gzip of `bytes` (payloads above 16 KiB, text satellites and spilled strings), through the
 * platform's CompressionStream; any reader inflates it.
 * @param {Uint8Array} bytes
 * @returns {Promise<Uint8Array>}
 */
export async function gzipCompress(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let index = 0; index < 256; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    table[index] = value >>> 0;
  }
  return table;
})();

/** @param {Uint8Array} bytes */
export function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

const LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LENGTH_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DISTANCE_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
  4097, 6145, 8193, 12289, 16385, 24577];
const DISTANCE_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
const CODE_LENGTH_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

/**
 * A canonical Huffman decoding table from code lengths: `counts[length]` codes of each length and
 * the symbols in code order.
 * @param {ArrayLike<number>} lengths
 */
function huffmanTable(lengths) {
  const counts = new Uint16Array(16);
  for (let index = 0; index < lengths.length; index += 1) counts[lengths[index]] += 1;
  counts[0] = 0;
  let left = 1;
  for (let length = 1; length < 16; length += 1) {
    left = (left << 1) - counts[length];
    if (left < 0) throw new InflateError("over-subscribed Huffman code");
  }
  const offsets = new Uint16Array(16);
  for (let length = 1; length < 16; length += 1) offsets[length] = offsets[length - 1] + counts[length - 1];
  const symbols = new Uint16Array(lengths.length);
  for (let symbol = 0; symbol < lengths.length; symbol += 1) {
    if (lengths[symbol] !== 0) symbols[offsets[lengths[symbol]]++] = symbol;
  }
  return { counts, symbols };
}

const FIXED_LITERALS = huffmanTable(Array.from({ length: 288 }, (_, symbol) => (symbol < 144 ? 8 : symbol < 256 ? 9 : symbol < 280 ? 7 : 8)));
const FIXED_DISTANCES = huffmanTable(new Array(30).fill(5));

/**
 * Raw DEFLATE, stopping with an error once the output would pass `limit` bytes, so it never holds
 * more than `limit` bytes. Reading stops at the end of the final block.
 * @param {Uint8Array} input
 * @param {number} limit
 */
function inflateRaw(input, limit) {
  let output = new Uint8Array(Math.min(limit, Math.max(1024, input.length * 4)));
  let written = 0;
  let position = 0;
  let bitBuffer = 0;
  let bitCount = 0;
  const need = (count) => {
    while (bitCount < count) {
      if (position >= input.length) throw new InflateError("input ends early");
      bitBuffer |= input[position++] << bitCount;
      bitCount += 8;
    }
  };
  const bits = (count) => {
    if (count === 0) return 0;
    need(count);
    const value = bitBuffer & ((1 << count) - 1);
    bitBuffer >>>= count;
    bitCount -= count;
    return value;
  };
  const decode = (table) => {
    let code = 0;
    let first = 0;
    let index = 0;
    for (let length = 1; length < 16; length += 1) {
      if (bitCount === 0) {
        if (position >= input.length) throw new InflateError("input ends early");
        bitBuffer = input[position++];
        bitCount = 8;
      }
      code |= bitBuffer & 1;
      bitBuffer >>>= 1;
      bitCount -= 1;
      const count = table.counts[length];
      if (code - first < count) return table.symbols[index + code - first];
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    throw new InflateError("invalid Huffman code");
  };
  const reserve = (count) => {
    if (written + count > limit) throw new InflateError("inflates past the limit", true);
    if (written + count > output.length) {
      const grown = new Uint8Array(Math.min(limit, Math.max(output.length * 2, written + count)));
      grown.set(output.subarray(0, written));
      output = grown;
    }
  };
  let final = 0;
  while (!final) {
    final = bits(1);
    const type = bits(2);
    if (type === 0) {
      bitBuffer = 0;
      bitCount = 0;
      if (position + 4 > input.length) throw new InflateError("input ends early");
      const length = input[position] | (input[position + 1] << 8);
      position += 4;
      const available = Math.min(length, input.length - position);
      reserve(available);
      output.set(input.subarray(position, position + available), written);
      written += available;
      position += available;
      if (available < length) break;
      continue;
    }
    let literals = FIXED_LITERALS;
    let distances = FIXED_DISTANCES;
    if (type === 2) {
      const literalCount = bits(5) + 257;
      const distanceCount = bits(5) + 1;
      const codeLengthCount = bits(4) + 4;
      const codeLengths = new Uint8Array(19);
      for (let index = 0; index < codeLengthCount; index += 1) codeLengths[CODE_LENGTH_ORDER[index]] = bits(3);
      const codeLengthTable = huffmanTable(codeLengths);
      const lengths = new Uint8Array(literalCount + distanceCount);
      for (let index = 0; index < lengths.length;) {
        const symbol = decode(codeLengthTable);
        if (symbol < 16) {
          lengths[index++] = symbol;
          continue;
        }
        let repeat = 0;
        let value = 0;
        if (symbol === 16) {
          if (index === 0) throw new InflateError("repeat with no previous length");
          value = lengths[index - 1];
          repeat = 3 + bits(2);
        } else if (symbol === 17) {
          repeat = 3 + bits(3);
        } else {
          repeat = 11 + bits(7);
        }
        if (index + repeat > lengths.length) throw new InflateError("too many code lengths");
        lengths.fill(value, index, index + repeat);
        index += repeat;
      }
      if (lengths[256] === 0) throw new InflateError("no end-of-block code");
      literals = huffmanTable(lengths.subarray(0, literalCount));
      distances = huffmanTable(lengths.subarray(literalCount));
    } else if (type !== 1) {
      throw new InflateError("invalid block type");
    }
    for (;;) {
      const symbol = decode(literals);
      if (symbol < 256) {
        reserve(1);
        output[written++] = symbol;
        continue;
      }
      if (symbol === 256) break;
      const lengthIndex = symbol - 257;
      if (lengthIndex >= 29) throw new InflateError("invalid length code");
      const length = LENGTH_BASE[lengthIndex] + bits(LENGTH_EXTRA[lengthIndex]);
      const distanceIndex = decode(distances);
      if (distanceIndex >= 30) throw new InflateError("invalid distance code");
      const distance = DISTANCE_BASE[distanceIndex] + bits(DISTANCE_EXTRA[distanceIndex]);
      if (distance > written) throw new InflateError("distance before the start");
      reserve(length);
      for (let copied = 0; copied < length; copied += 1) {
        output[written] = output[written - distance];
        written += 1;
      }
    }
  }
  return output.subarray(0, written);
}
