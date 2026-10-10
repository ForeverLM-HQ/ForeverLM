// The JSON values the sync core works on (docs/cloudkit-schema-design.md §3.2): the twin of Swift's
// SyncJSON. A payload's fields, the shared shapes (§3.3) and every vector case are plain JSON:
// numbers are doubles, objects are plain objects. Keys come from the wire, so every lookup by a
// key that data names goes through `own`, never `object[key]`, which would find `constructor` or
// `__proto__` on Object.prototype, and every write through `setOwn`.

/** @param {unknown} value */
export function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/**
 * An object a JSON reader makes (`{}`), never a Date, a Map, a typed array or a class instance.
 * @param {unknown} value
 * @returns {value is Record<string, unknown>}
 */
export function isPlainObject(value) {
  if (!isObject(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

/**
 * The value `object` holds under `key` itself, never one it inherits.
 * @param {any} object
 * @param {string} key
 */
export function own(object, key) {
  return isObject(object) && Object.hasOwn(object, key) ? object[key] : undefined;
}

/**
 * Sets `object[key]` as an own data property, so a `__proto__` key stays a key.
 * @param {Record<string, any>} object
 * @param {string} key
 * @param {any} value
 */
export function setOwn(object, key, value) {
  if (key === "__proto__") {
    Object.defineProperty(object, key, { value, writable: true, enumerable: true, configurable: true });
  } else {
    object[key] = value;
  }
}

/**
 * Sets `object[key]`, or removes the key when `value` is undefined: Swift's `dictionary[key] = optional`.
 * @param {Record<string, any>} object
 * @param {string} key
 * @param {any} value
 */
export function setOrRemove(object, key, value) {
  if (value === undefined) delete object[key];
  else setOwn(object, key, value);
}

/**
 * A deep copy of a JSON value.
 * @template T
 * @param {T} value
 * @returns {T}
 */
export function copyJSON(value) {
  if (Array.isArray(value)) return /** @type {any} */ (value.map(copyJSON));
  if (isObject(value)) {
    /** @type {Record<string, any>} */
    const copy = {};
    for (const key of Object.keys(value)) setOwn(copy, key, copyJSON(/** @type {any} */ (value)[key]));
    return /** @type {any} */ (copy);
  }
  return value;
}

/**
 * Two JSON values are equal: numbers by value (`1` is `1.0`), arrays in order, objects by their keys.
 * @param {unknown} a
 * @param {unknown} b
 * @returns {boolean}
 */
export function jsonEqual(a, b) {
  if (a === b) return true;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let index = 0; index < a.length; index += 1) {
      if (!jsonEqual(a[index], b[index])) return false;
    }
    return true;
  }
  if (!isObject(a) || !isObject(b)) return false;
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  for (const key of keys) {
    if (!Object.hasOwn(b, key) || !jsonEqual(/** @type {any} */ (a)[key], /** @type {any} */ (b)[key])) return false;
  }
  return true;
}

/**
 * Two JSON values are equal as Swift's `SyncJSON ==` finds them, where it differs from `jsonEqual`:
 * strings, and the keys of objects, compare by canonical equivalence (their NFC forms), so `café`
 * spelled NFC and NFD is one value. The core compares a patch with the value held (rule 9) and a
 * local value with the server's (a server-first loss) this way, so a JS client re-stamps nothing and
 * reports no loss that a Mac would not. (An object holding two keys that differ only in normalization,
 * which Swift's reader would have made one and no writer makes, is compared by its keys as they are.)
 * @param {unknown} a
 * @param {unknown} b
 * @returns {boolean}
 */
export function jsonEquivalent(a, b) {
  if (a === b) return true;
  if (typeof a === "string") return typeof b === "string" && (!isASCII(a) || !isASCII(b)) && a.normalize("NFC") === b.normalize("NFC");
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let index = 0; index < a.length; index += 1) {
      if (!jsonEquivalent(a[index], b[index])) return false;
    }
    return true;
  }
  if (!isObject(a) || !isObject(b)) return false;
  const left = keysByNFC(/** @type {Record<string, unknown>} */ (a));
  const right = keysByNFC(/** @type {Record<string, unknown>} */ (b));
  if (left === null || right === null) return jsonEqual(a, b);
  if (left.size !== right.size) return false;
  for (const [key, value] of left) {
    if (!right.has(key) || !jsonEquivalent(value, right.get(key))) return false;
  }
  return true;
}

/** An object's values by the NFC form of their keys, or null when two keys share one. @param {Record<string, unknown>} object */
function keysByNFC(object) {
  /** @type {Map<string, unknown>} */
  const byKey = new Map();
  for (const key of Object.keys(object)) {
    const normalized = isASCII(key) ? key : key.normalize("NFC");
    if (byKey.has(normalized)) return null;
    byKey.set(normalized, object[key]);
  }
  return byKey;
}

/**
 * Orders two strings as Swift does: by the Unicode scalars of their NFC forms. Wire keys and ids
 * are ASCII, where this is plain string order.
 * @param {string} a
 * @param {string} b
 * @returns {number}
 */
export function compareStrings(a, b) {
  if (a === b) return 0;
  const left = isASCII(a) ? a : a.normalize("NFC");
  const right = isASCII(b) ? b : b.normalize("NFC");
  if (left === right) return 0;
  const length = Math.min(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const x = left.codePointAt(index) ?? 0;
    const y = right.codePointAt(index) ?? 0;
    if (x !== y) return x < y ? -1 : 1;
    if (x > 0xffff) index += 1;
  }
  return left.length < right.length ? -1 : left.length > right.length ? 1 : 0;
}

/** @param {string} text */
export function isASCII(text) {
  return /^[\x00-\x7f]*$/.test(text);
}

/**
 * The keys of an object, sorted as Swift sorts them.
 * @param {object} object
 */
export function sortedKeys(object) {
  return Object.keys(object).sort(compareStrings);
}

// MARK: - What a payload can hold

const nativeIsWellFormed = typeof (/** @type {any} */ (String.prototype)).isWellFormed === "function";

/**
 * Whether `text` is well-formed UTF-16. A lone surrogate (a string cut inside an emoji by `slice`) is
 * refused by both readers and cannot be held by a Swift String.
 * @param {string} text
 */
export function isWellFormedText(text) {
  if (nativeIsWellFormed) return /** @type {any} */ (text).isWellFormed();
  for (let index = 0; index < text.length; index += 1) {
    const unit = text.charCodeAt(index);
    if (unit < 0xd800 || unit > 0xdfff) continue;
    const next = text.charCodeAt(index + 1);
    if (unit > 0xdbff || !(next >= 0xdc00 && next <= 0xdfff)) return false;
    index += 1;
  }
  return true;
}

/**
 * Why `value` cannot stand in a payload, or undefined when it can. Refused: what no reader takes back
 * (a lone surrogate in a string or a key, an array with a hole, containers past the readers' 512
 * levels, counted from `depth`, where `value` sits in the document), and what JSON cannot say, which
 * a writer would otherwise turn into something else (undefined, a missing value, into a stamped clear;
 * a number that is not finite into null; a Date, a Map or a class instance into `{}`; a function, a
 * symbol or a bigint). Swift's SyncJSON can hold none of them.
 * @param {unknown} value
 * @param {number} [depth]
 * @returns {string | undefined}
 */
export function jsonValueProblem(value, depth = 0) {
  switch (typeof value) {
    case "string": return isWellFormedText(value) ? undefined : "a lone surrogate";
    case "number": return Number.isFinite(value) ? undefined : "a number that is not finite";
    case "boolean": return undefined;
    case "undefined": return "undefined, a missing value";
    case "object": break;
    default: return `a ${typeof value}`;
  }
  if (value === null) return undefined;
  if (depth >= MAX_DEPTH) return "nesting past 512 levels";
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      if (!Object.hasOwn(value, index)) return "an array with a hole";
      const problem = jsonValueProblem(value[index], depth + 1);
      if (problem !== undefined) return problem;
    }
    return undefined;
  }
  if (!isPlainObject(value)) return "an object that is not plain (a Date, a Map, a class instance)";
  for (const key of Object.keys(value)) {
    if (!isWellFormedText(key)) return "a lone surrogate in a key";
    const problem = jsonValueProblem(value[key], depth + 1);
    if (problem !== undefined) return problem;
  }
  return undefined;
}

/** A value serializeJSON will not write, because no reader would take it back as it was. */
export class JSONValueError extends TypeError {
  /** @param {string} reason */
  constructor(reason) {
    super(`not a JSON value a payload can hold: ${reason}`);
    this.name = "JSONValueError";
    this.reason = reason;
  }
}

// MARK: - Text

/**
 * Compact JSON with sorted keys, so equal values serialize to equal bytes. Numbers print as Swift
 * prints them (`SyncJSON.numberText`): an integer below 2^53 as digits, any other number in Swift's
 * shortest round-trip form. It never writes what a reader refuses or what JSON cannot say: anything
 * `jsonValueProblem` names throws JSONValueError, so neither a merge nor an envelope built by hand
 * can make a record no client reads. The one exception is −∞, the only number that is not finite a
 * payload can hold (Foundation reads a negative overflow such as `-1e400` so, and parseJSON with it):
 * it is written back as `null`, as Swift's numberText writes it.
 * @param {unknown} value
 * @returns {string}
 */
export function serializeJSON(value) {
  return writeJSON(value, 0);
}

/** @param {unknown} value @param {number} depth @returns {string} */
function writeJSON(value, depth) {
  switch (typeof value) {
    case "boolean": return value ? "true" : "false";
    case "number":
      if (value === -Infinity) return "null";
      if (!Number.isFinite(value)) throw new JSONValueError("a number that is not finite");
      return numberText(value);
    case "string": return quoted(value);
    case "object": break;
    case "undefined": throw new JSONValueError("undefined, a missing value");
    default: throw new JSONValueError(`a ${typeof value}`);
  }
  if (value === null) return "null";
  if (depth >= MAX_DEPTH) throw new JSONValueError("nesting past 512 levels");
  if (Array.isArray(value)) {
    const parts = [];
    for (let index = 0; index < value.length; index += 1) {
      if (!Object.hasOwn(value, index)) throw new JSONValueError("an array with a hole");
      parts.push(writeJSON(value[index], depth + 1));
    }
    return `[${parts.join(",")}]`;
  }
  if (!isPlainObject(value)) throw new JSONValueError("an object that is not plain (a Date, a Map, a class instance)");
  return `{${sortedKeys(value).map((key) => `${quoted(key)}:${writeJSON(value[key], depth + 1)}`).join(",")}}`;
}

/** @param {string} text */
function quoted(text) {
  if (!isWellFormedText(text)) throw new JSONValueError("a lone surrogate");
  return JSON.stringify(text);
}

/**
 * A number as Swift's SyncJSON writes it.
 * @param {number} value
 */
export function numberText(value) {
  if (!Number.isFinite(value)) return "null";
  if (Number.isInteger(value) && Math.abs(value) < 9007199254740992) return String(value === 0 ? 0 : value);
  // Swift's Double description: the shortest digits that read back as the same double, in fixed
  // notation from 1e-4 up to 2^53 (both included), else as d.ddde+XX or d.ddde-XX with at least two
  // exponent digits.
  const [mantissa, exponentText] = Math.abs(value).toExponential().split("e");
  const exponent = Number(exponentText);
  const digits = mantissa.replace(".", "");
  const sign = value < 0 ? "-" : "";
  if (exponent >= -4 && Math.abs(value) <= 9007199254740992) {
    if (exponent < 0) return `${sign}0.${"0".repeat(-exponent - 1)}${digits}`;
    const whole = digits.slice(0, exponent + 1).padEnd(exponent + 1, "0");
    const fraction = digits.slice(exponent + 1);
    return `${sign}${whole}.${fraction || "0"}`;
  }
  const fraction = digits.slice(1);
  const exponentDigits = String(Math.abs(exponent)).padStart(2, "0");
  return `${sign}${digits[0]}${fraction ? `.${fraction}` : ""}e${exponent < 0 ? "-" : "+"}${exponentDigits}`;
}

export class JSONParseError extends Error {
  /** @param {string} message @param {number} offset */
  constructor(message, offset) {
    super(`${message} at ${offset}`);
    this.name = "JSONParseError";
    this.offset = offset;
  }
}

const MAX_DEPTH = 512;
const NUMBER = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/y;
/** @type {ReadonlyArray<[string, boolean | null]>} */
const LITERALS = [["true", true], ["false", false], ["null", null]];

/**
 * Parses JSON text as the Swift reader (`JSONSerialization`) reads a payload, where the two differ
 * from `JSON.parse` in what a value means: the first of two equal keys wins, an escaped lone
 * surrogate is refused, a trailing comma before `]` or `}` is read past, a number too large for a
 * double is refused (Foundation's own quirk keeps a negative one as -Infinity), nesting stops at
 * 512 levels, and every string, key or value, loses one leading U+FEFF, raw or escaped, as
 * Foundation's `String(bytes:encoding: .utf8)` drops it. Any JSON value may stand at the top.
 * Where the Swift reader is looser, this one is the rule and the Swift core is to follow it (lane A):
 * JSONSerialization also reads an empty container at the 513th level, and UTF-16 or UTF-32 text,
 * which decodeStoredPayload refuses before this reader sees it; and it reads some long fractions a
 * few ulps off, where this one reads every number exactly.
 * @param {string} text
 * @returns {unknown}
 */
export function parseJSON(text) {
  let index = text.charCodeAt(0) === 0xfeff ? 1 : 0;
  const fail = (message) => {
    throw new JSONParseError(message, index);
  };
  const skipSpace = () => {
    for (;;) {
      const code = text.charCodeAt(index);
      if (code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0d) index += 1;
      else return;
    }
  };
  const parseString = () => {
    index += 1;
    let result = "";
    let start = index;
    for (;;) {
      if (index >= text.length) fail("unterminated string");
      const code = text.charCodeAt(index);
      if (code === 0x22) {
        result += text.slice(start, index);
        index += 1;
        return result.charCodeAt(0) === 0xfeff ? result.slice(1) : result;
      }
      if (code < 0x20) fail("unescaped control character");
      if (code !== 0x5c) {
        index += 1;
        continue;
      }
      result += text.slice(start, index);
      const escape = text[index + 1];
      index += 2;
      switch (escape) {
        case '"': result += '"'; break;
        case "\\": result += "\\"; break;
        case "/": result += "/"; break;
        case "b": result += "\b"; break;
        case "f": result += "\f"; break;
        case "n": result += "\n"; break;
        case "r": result += "\r"; break;
        case "t": result += "\t"; break;
        case "u": {
          const unit = hexUnit(text, index) ?? fail("bad unicode escape");
          index += 4;
          if (unit >= 0xdc00 && unit <= 0xdfff) fail("low surrogate without a high one");
          if (unit >= 0xd800 && unit <= 0xdbff) {
            const low = text.startsWith("\\u", index) ? hexUnit(text, index + 2) : null;
            if (low === null || low < 0xdc00 || low > 0xdfff) fail("high surrogate without a low one");
            index += 6;
            result += String.fromCharCode(unit, /** @type {number} */ (low));
          } else {
            result += String.fromCharCode(unit);
          }
          break;
        }
        default:
          fail("invalid escape");
      }
      start = index;
    }
  };
  const parseNumber = () => {
    NUMBER.lastIndex = index;
    const match = NUMBER.exec(text);
    if (!match) return fail("invalid number");
    const literal = match[0];
    index += literal.length;
    const next = text.charCodeAt(index);
    if ((literal === "0" || literal === "-0") && next >= 0x30 && next <= 0x39) fail("number with a leading zero");
    const value = Number(literal);
    if (value === Infinity || Number.isNaN(value)) fail("number out of range");
    return value;
  };
  /** @param {number} depth @returns {unknown} */
  const parseValue = (depth) => {
    skipSpace();
    const code = text.charCodeAt(index);
    if (code === 0x7b || code === 0x5b) {
      if (depth >= MAX_DEPTH) fail("too deeply nested");
      const isArray = code === 0x5b;
      const close = isArray ? 0x5d : 0x7d;
      index += 1;
      /** @type {any} */
      const container = isArray ? [] : {};
      skipSpace();
      if (text.charCodeAt(index) === close) {
        index += 1;
        return container;
      }
      for (;;) {
        if (isArray) {
          container.push(parseValue(depth + 1));
        } else {
          skipSpace();
          if (text.charCodeAt(index) !== 0x22) fail("expected a key");
          const key = parseString();
          skipSpace();
          if (text.charCodeAt(index) !== 0x3a) fail("expected a colon");
          index += 1;
          const value = parseValue(depth + 1);
          if (!Object.hasOwn(container, key)) setOwn(container, key, value);
        }
        skipSpace();
        const next = text.charCodeAt(index);
        if (next === close) {
          index += 1;
          return container;
        }
        if (next !== 0x2c) fail("expected a comma");
        index += 1;
        skipSpace();
        if (text.charCodeAt(index) === close) {
          index += 1;
          return container;
        }
      }
    }
    if (code === 0x22) return parseString();
    if (code === 0x2d || (code >= 0x30 && code <= 0x39)) return parseNumber();
    for (const [literal, value] of LITERALS) {
      if (text.startsWith(literal, index)) {
        index += literal.length;
        return value;
      }
    }
    return fail("invalid value");
  };
  const value = parseValue(0);
  skipSpace();
  if (index !== text.length) fail("garbage at end");
  return value;
}

/** @param {string} text @param {number} at */
function hexUnit(text, at) {
  const digits = text.slice(at, at + 4);
  return /^[0-9a-fA-F]{4}$/.test(digits) ? parseInt(digits, 16) : null;
}

// MARK: - Numbers

/**
 * A number with no fraction below 2^63 (milliseconds, counts, revisions), else undefined: Swift's
 * `SyncJSON.int64Value`.
 * @param {unknown} value
 */
export function integerValue(value) {
  return typeof value === "number" && Number.isInteger(value) && Math.abs(value) < 9223372036854775808 ? value : undefined;
}

// MARK: - Bytes

const textEncoder = new TextEncoder();
const strictUTF8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

/** @param {string} text */
export function utf8Bytes(text) {
  return textEncoder.encode(text);
}

/**
 * UTF-8 text from bytes, or undefined for bytes that are not UTF-8.
 * @param {Uint8Array} bytes
 */
export function utf8Text(bytes) {
  try {
    return strictUTF8.decode(bytes);
  } catch {
    return undefined;
  }
}

/** @param {string} text */
export function utf8Length(text) {
  let length = 0;
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    if (code < 0x80) length += 1;
    else if (code < 0x800) length += 2;
    else if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        length += 4;
        index += 1;
      } else {
        length += 3;
      }
    } else length += 3;
  }
  return length;
}

/** @param {Uint8Array} bytes */
export function hexString(bytes) {
  let text = "";
  for (const byte of bytes) text += byte.toString(16).padStart(2, "0");
  return text;
}

const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** @param {Uint8Array} bytes */
export function base64Encode(bytes) {
  let text = "";
  for (let index = 0; index < bytes.length; index += 3) {
    const a = bytes[index];
    const b = index + 1 < bytes.length ? bytes[index + 1] : 0;
    const c = index + 2 < bytes.length ? bytes[index + 2] : 0;
    text += BASE64[a >> 2] + BASE64[((a & 3) << 4) | (b >> 4)];
    text += index + 1 < bytes.length ? BASE64[((b & 15) << 2) | (c >> 6)] : "=";
    text += index + 2 < bytes.length ? BASE64[c & 63] : "=";
  }
  return text;
}

/**
 * Bytes from padded base64, as Foundation's `Data(base64Encoded:)` reads it: undefined for any
 * character outside the alphabet, a length that is not a multiple of four, or misplaced padding.
 * @param {string} text
 */
export function base64Decode(text) {
  if (text.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(text)) return undefined;
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  const bytes = new Uint8Array((text.length / 4) * 3 - padding);
  let output = 0;
  for (let index = 0; index < text.length; index += 4) {
    const values = [0, 1, 2, 3].map((offset) => {
      const character = text[index + offset];
      return character === "=" ? 0 : BASE64.indexOf(character);
    });
    const triple = (values[0] << 18) | (values[1] << 12) | (values[2] << 6) | values[3];
    for (const shift of [16, 8, 0]) {
      if (output < bytes.length) bytes[output++] = (triple >> shift) & 255;
    }
  }
  return bytes;
}
