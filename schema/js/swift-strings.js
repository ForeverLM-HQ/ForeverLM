// The String rules of Swift and Foundation that the Mac's identity code relies on, so the JS twins of
// URLNormalizer and WorkKey (url-normalize-v1.js, work-key.js) mint the same keys. A Swift String is
// a sequence of Characters (extended grapheme clusters), compared by canonical equivalence: a "/"
// followed by a combining mark is not a "/", and U+212A KELVIN SIGN is a "K". Case mapping and
// trimming work on Unicode scalars. Measured against macOS 27 Foundation; on ASCII text every rule
// here is the plain JS one.

const segmenter = typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
  ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
  : null;

/** @param {string} text */
export function isASCIIText(text) {
  return /^[\x00-\x7f]*$/.test(text);
}

/**
 * A string's Characters: its extended grapheme clusters (`"\r\n"` is one).
 * @param {string} text
 * @returns {string[]}
 */
export function characters(text) {
  if (isASCIIText(text)) {
    if (!text.includes("\r\n")) return text.split("");
    return text.match(/\r\n|[\s\S]/g) ?? [];
  }
  if (segmenter) return Array.from(segmenter.segment(text), (segment) => segment.segment);
  return text.match(/\r\n|\P{M}[\p{M}\u200D]*|[\s\S]/gu) ?? [];
}

/** @param {string} text */
function canonical(text) {
  return isASCIIText(text) ? text : text.normalize("NFC");
}

/**
 * Two strings or Characters are equal as Swift compares them: by canonical equivalence.
 * @param {string} a
 * @param {string} b
 */
export function canonicallyEqual(a, b) {
  return a === b || canonical(a) === canonical(b);
}

/**
 * Swift's `text.hasPrefix(prefix)`: the first Characters of `text` are those of `prefix`.
 * @param {string} text
 * @param {string} prefix
 */
export function hasPrefix(text, prefix) {
  if (prefix === "") return true;
  if (isASCIIText(text) && isASCIIText(prefix)) {
    return text.startsWith(prefix) && !(prefix.endsWith("\r") && text[prefix.length] === "\n");
  }
  const chars = characters(text);
  const wanted = characters(prefix);
  return wanted.length <= chars.length && wanted.every((character, index) => canonicallyEqual(character, chars[index]));
}

/**
 * Swift's `text.hasSuffix(suffix)`.
 * @param {string} text
 * @param {string} suffix
 */
export function hasSuffix(text, suffix) {
  if (suffix === "") return true;
  if (isASCIIText(text) && isASCIIText(suffix)) {
    return text.endsWith(suffix) && !(suffix.startsWith("\n") && text[text.length - suffix.length - 1] === "\r");
  }
  const chars = characters(text);
  const wanted = characters(suffix);
  const offset = chars.length - wanted.length;
  return offset >= 0 && wanted.every((character, index) => canonicallyEqual(character, chars[offset + index]));
}

/**
 * Swift's `text.split(separator: character, omittingEmptySubsequences:)`.
 * @param {string} text
 * @param {string} separator one Character
 * @param {boolean} [omittingEmpty]
 */
export function splitCharacters(text, separator, omittingEmpty = true) {
  /** @type {string[]} */
  const pieces = [];
  let current = "";
  for (const character of characters(text)) {
    if (canonicallyEqual(character, separator)) {
      pieces.push(current);
      current = "";
    } else {
      current += character;
    }
  }
  pieces.push(current);
  return omittingEmpty ? pieces.filter((piece) => piece !== "") : pieces;
}

/**
 * The index of the first Character of `chars` equal to `character`, or -1.
 * @param {string[]} chars
 * @param {string} character
 */
export function firstIndexOfCharacter(chars, character) {
  return chars.findIndex((candidate) => canonicallyEqual(candidate, character));
}

/**
 * The Character index where `needle` first occurs in `chars`, comparing Characters (Foundation's
 * non-literal search: a match never splits a Character), or -1.
 * @param {string[]} chars
 * @param {string} needle
 * @param {number} [from]
 */
export function indexOfCharacters(chars, needle, from = 0) {
  const wanted = characters(needle);
  if (wanted.length === 0) return -1;
  for (let start = from; start + wanted.length <= chars.length; start += 1) {
    if (wanted.every((character, index) => canonicallyEqual(character, chars[start + index]))) return start;
  }
  return -1;
}

/**
 * Swift's `text.contains(needle)` for a string needle.
 * @param {string} text
 * @param {string} needle
 */
export function containsCharacters(text, needle) {
  if (isASCIIText(text) && isASCIIText(needle) && !text.includes("\r") && !needle.includes("\r")) return text.includes(needle);
  return indexOfCharacters(characters(text), needle) >= 0;
}

/**
 * Foundation's `text.replacingOccurrences(of: needle, with: replacement)`, a non-literal search.
 * @param {string} text
 * @param {string} needle
 * @param {string} replacement
 */
export function replacingOccurrences(text, needle, replacement) {
  if (isASCIIText(text) && isASCIIText(needle) && !text.includes("\r") && !needle.includes("\r")) return text.split(needle).join(replacement);
  const chars = characters(text);
  const length = characters(needle).length;
  let result = "";
  let start = 0;
  for (;;) {
    const found = indexOfCharacters(chars, needle, start);
    if (found < 0) break;
    result += chars.slice(start, found).join("") + replacement;
    start = found + length;
  }
  return result + chars.slice(start).join("");
}

/**
 * Swift's `lowercased()`: each scalar's full lowercase mapping, with no context (a final sigma
 * stays small sigma).
 * @param {string} text
 */
export function lowercased(text) {
  if (isASCIIText(text)) return text.toLowerCase();
  let result = "";
  for (const scalar of text) result += scalar.toLowerCase();
  return result;
}

/**
 * Swift's `uppercased()`: each scalar's full uppercase mapping (sharp s becomes SS).
 * @param {string} text
 */
export function uppercased(text) {
  if (isASCIIText(text)) return text.toUpperCase();
  let result = "";
  for (const scalar of text) result += scalar.toUpperCase();
  return result;
}

// CharacterSet.whitespaces and .whitespacesAndNewlines, as Foundation defines them (U+200B is one,
// U+FEFF is not).
const WHITESPACES = "\t \u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u200B\u202F\u205F\u3000";
const WHITESPACES_AND_NEWLINES = `${WHITESPACES}\n\u000b\u000c\r\u0085\u2028\u2029`;

/**
 * `text.trimmingCharacters(in: set)`: scalars of the set dropped from both ends.
 * @param {string} text
 * @param {string} set
 */
function trimming(text, set) {
  let start = 0;
  let end = text.length;
  while (start < end && set.includes(text[start])) start += 1;
  while (end > start && set.includes(text[end - 1])) end -= 1;
  return text.slice(start, end);
}

/** `text.trimmingCharacters(in: .whitespacesAndNewlines)`. @param {string} text */
export function trimmingWhitespacesAndNewlines(text) {
  return trimming(text, WHITESPACES_AND_NEWLINES);
}

/** `text.trimmingCharacters(in: .whitespaces)`. @param {string} text */
export function trimmingWhitespaces(text) {
  return trimming(text, WHITESPACES);
}

/**
 * Foundation's `removingPercentEncoding`: every `%XX` decoded, the bytes read as UTF-8; null for a `%`
 * not followed by two hex digits or bytes that are not UTF-8.
 * @param {string} text
 * @param {number[]} [excluding] bytes kept percent-encoded (URLComponents keeps %00 in a host)
 * @returns {string | null}
 */
export function removingPercentEncoding(text, excluding = []) {
  if (!text.includes("%")) return text;
  const input = new TextEncoder().encode(text);
  const output = [];
  for (let index = 0; index < input.length; index += 1) {
    const byte = input[index];
    if (byte !== 0x25) {
      output.push(byte);
      continue;
    }
    const high = hexValue(input[index + 1]);
    const low = hexValue(input[index + 2]);
    if (high < 0 || low < 0) return null;
    const value = (high << 4) | low;
    if (excluding.includes(value)) output.push(0x25, input[index + 1], input[index + 2]);
    else output.push(value);
    index += 2;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(new Uint8Array(output));
  } catch {
    return null;
  }
}

/** @param {number | undefined} byte */
function hexValue(byte) {
  if (byte === undefined) return -1;
  if (byte >= 0x30 && byte <= 0x39) return byte - 0x30;
  if (byte >= 0x41 && byte <= 0x46) return byte - 0x37;
  if (byte >= 0x61 && byte <= 0x66) return byte - 0x57;
  return -1;
}

// Swift Regex `\d` matches a Character whose first scalar has a numeric type (`Character.isNumber`):
// the general category N, and these CJK and cuneiform numerals besides.
const NUMBER = new RegExp(String.raw`^[\p{N}\u3405\u3483\u382A\u3B4D\u4E00\u4E03\u4E07\u4E09\u4E24\u4E5D\u4E8C\u4E94\u4E96\u4EAC\u4EBF\u4EC0\u4EDF\u4EE8\u4F0D\u4F70\u4FE9\u5006\u5104\u5146\u5169\u516B\u516D\u5341\u5343-\u5345\u534C\u53C1-\u53C4\u56DB\u58F1\u58F9\u5E7A\u5EFE\u5EFF\u5F0C-\u5F0E\u5F10\u62D0\u62FE\u634C\u67D2\u6D1E\u6F06\u7396\u767E\u7695\u79ED\u8086\u842C\u8CAE\u8CB3\u8D30\u920E\u94A9\u9621\u9646\u964C\u9678\u96F6\uF96B\uF973\uF978\uF9B2\uF9D1\uF9D3\uF9FD\u{12038}\u{12039}\u{12079}\u{12226}\u{1222B}\u{1230B}\u{1230D}\u{12399}\u{20001}\u{20064}\u{200E2}\u{20121}\u{2092A}\u{20983}\u{2098C}\u{2099C}\u{20AEA}\u{20AFD}\u{20B19}\u{22390}\u{22998}\u{23B1B}\u{2626D}\u{2F890}]`, "u");

/**
 * Whether Swift Regex `\d` (grapheme semantics, as Foundation's `range(of:options: .regularExpression)`
 * runs it) matches this Character.
 * @param {string | undefined} character
 */
export function isNumberCharacter(character) {
  return character !== undefined && NUMBER.test(character);
}

/**
 * Whether a Swift Regex custom class range matches this Character: one scalar within the range.
 * @param {string | undefined} character
 * @param {string} from
 * @param {string} to
 */
export function isInRange(character, from, to) {
  return character !== undefined && character.length === 1 && character >= from && character <= to;
}
