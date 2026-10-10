// Work keys (docs/cloudkit-schema-design.md §4.2): every identity key known for a work, normalized so
// two routes that import the same paper, video or episode look up the same key before they mint a
// source. The twin of Swift's WorkKey.swift, with Swift's String rules (swift-strings.js), so the web
// and the hosted MCP find what the Mac files. Vectors: schema/vectors/work-key.json.
//
// Normalizing returns null for a key of a known kind whose value cannot be one (`isbn:12`,
// `doi:abc`): the importer drops it rather than store a key that matches nothing. A kind this build
// does not know is kept as it came, its kind lowercased, since a newer client may define it.

import {
  canonicallyEqual,
  characters,
  containsCharacters,
  firstIndexOfCharacter,
  hasPrefix,
  hasSuffix,
  indexOfCharacters,
  isInRange,
  isNumberCharacter,
  lowercased,
  splitCharacters,
  trimmingWhitespaces,
  trimmingWhitespacesAndNewlines,
  uppercased,
} from "./swift-strings.js";
import { normalize as normalizeURL, normalizeRemote as normalizeRemoteURL } from "./url-normalize-v1.js";

/**
 * A work key as a client without local files computes it (the web, the hosted MCP, the iPhone): a
 * `url:` key naming a local path is no work key. A `url:` key, or a podcast key whose feed is a URL,
 * throws HostNeedsMac (url-normalize-v1.js) when that URL's host needs IDNA, which only a Mac computes.
 * @param {string} key
 * @returns {string | null}
 */
export function normalizeWorkKeyRemote(key) {
  return normalized(key, null);
}

/**
 * The target of the member's `Mark(dismissed)` for an address (§3.5.19): `wk:` and the address's `url:`
 * work key, or the address itself after `url:` when it has none. One form on every client (Swift's
 * `WorkKey.dismissalTarget`), so one client's un-dismiss flips the Mark another wrote. HostNeedsMac as
 * `normalizeWorkKeyRemote`.
 * @param {string} url
 * @returns {string}
 */
export function dismissalTarget(url) {
  return `wk:${normalizeWorkKeyRemote(`url:${url}`) ?? `url:${url}`}`;
}

/**
 * A work key as a client with local files computes it: a `url:` key naming a local path goes through
 * `localPath`, the client's own roots. HostNeedsMac as `normalizeWorkKeyRemote`.
 * @param {string} key
 * @param {(path: string) => string} localPath
 * @returns {string | null}
 */
export function normalizeWorkKey(key, localPath) {
  return normalized(key, localPath);
}

/**
 * @param {string} key
 * @param {((path: string) => string) | null} localPath
 * @returns {string | null}
 */
function normalized(key, localPath) {
  const trimmed = characters(trimmingWhitespacesAndNewlines(key));
  const colon = firstIndexOfCharacter(trimmed, ":");
  if (colon < 0) return null;
  const kind = lowercased(trimmed.slice(0, colon).join(""));
  const value = trimmingWhitespacesAndNewlines(trimmed.slice(colon + 1).join(""));
  if (value === "") return null;
  let result;
  switch (kind) {
    case "doi": result = doi(value); break;
    case "arxiv": result = arxiv(value); break;
    case "pmid": result = pmid(value); break;
    case "isbn": result = isbn(value); break;
    case "podcast": result = podcast(value); break;
    case "gh": result = gitHub(value); break;
    case "x": result = xPost(value); break;
    case "file": result = fileHash(value); break;
    case "url": result = localPath ? normalizeURL(value, localPath) : normalizeRemoteURL(value); break;
    // Kept as they are, since their case is part of the identity: YouTube video ids (yt:), Zoom
    // meeting ids (zoom:), meeting session keys (meeting:), course lessons (course:), native
    // sources' own ids (native:), and kinds a newer client defines.
    default: result = value;
  }
  return result === null || result === "" ? null : `${kind}:${result}`;
}

/**
 * `value` with its first `prefix` dropped when its lowercased form starts with one of `prefixes`
 * (Swift: `value.dropFirst(prefix.count)` after `lowered.hasPrefix(prefix)`).
 * @param {string} value
 * @param {string} lowered
 * @param {string[]} prefixes
 */
function droppingFirstPrefix(value, lowered, prefixes) {
  for (const prefix of prefixes) {
    if (hasPrefix(lowered, prefix)) return characters(value).slice(characters(prefix).length).join("");
  }
  return value;
}

/**
 * A DOI as `10.x/y`: resolver prefixes and a repeated `doi:` label dropped, lowercased, without
 * trailing punctuation or a preprint's version. A version is a trailing `v<digits>` after a digit,
 * `.` or `/`, dropped with the `.` or `/` it leaves behind; a `v` after a letter belongs to the DOI
 * (every 2015 Oxford DOI has one, `10.1093/nar/gkv1344`).
 * @param {string} raw
 */
function doi(raw) {
  let value = droppingFirstPrefix(raw, lowercased(raw),
    ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi.org/", "dx.doi.org/", "doi:"]);
  let chars = characters(lowercased(trimmingWhitespacesAndNewlines(value)));
  while (chars.length > 0 && [".", ",", ";"].some((mark) => canonicallyEqual(chars[chars.length - 1], mark))) chars.pop();
  // `(?<=[0-9./])v[0-9]+$`: Foundation hands a pattern with a lookbehind to NSRegularExpression (ICU),
  // so it reads scalars, and its `$` also matches before one final line terminator.
  const version = DOI_VERSION.exec(chars.join(""));
  if (version) {
    const unversioned = characters(chars.join("").slice(0, version.index));
    while (unversioned.length > 0 && (canonicallyEqual(unversioned[unversioned.length - 1], ".") || canonicallyEqual(unversioned[unversioned.length - 1], "/"))) {
      unversioned.pop();
    }
    // A version is never the whole suffix: `10.5555/v12` keeps its `v12`.
    const slash = firstIndexOfCharacter(unversioned, "/");
    if (slash >= 0 && slash + 1 < unversioned.length) chars = unversioned;
  }
  value = chars.join("");
  if (!hasPrefix(value, "10.") || !containsCharacters(value, "/")) return null;
  return value;
}

const DOI_VERSION = /(?<=[0-9./])v[0-9]+(?=(?:\r\n|[\n\v\f\r\u0085\u2028\u2029])?$)/u;

/**
 * An arXiv id without its version: `2503.09427`, or an old-style `hep-th/9901001`.
 * @param {string} raw
 */
function arxiv(raw) {
  const lowered = lowercased(raw);
  let chars = characters(droppingFirstPrefix(lowered, lowered,
    ["https://arxiv.org/abs/", "http://arxiv.org/abs/", "https://arxiv.org/pdf/", "http://arxiv.org/pdf/", "arxiv.org/abs/", "arxiv.org/pdf/", "arxiv:"]));
  if (hasSuffix(chars.join(""), ".pdf")) chars = chars.slice(0, -4);
  // Swift Regex `v\d+$`.
  let start = chars.length;
  while (start > 0 && isNumberCharacter(chars[start - 1])) start -= 1;
  if (start < chars.length && start > 0 && chars[start - 1] === "v") chars = chars.slice(0, start - 1);
  // `^\d{4}\.\d{4,5}$` and `^[a-z][a-z.-]*/\d{7}$`.
  const isModern = (chars.length === 9 || chars.length === 10) && chars.slice(0, 4).every(isNumberCharacter)
    && chars[4] === "." && chars.slice(5).every(isNumberCharacter);
  const slash = chars.length - 8;
  const isOldStyle = slash >= 1 && chars[slash] === "/" && chars.slice(slash + 1).every(isNumberCharacter)
    && isInRange(chars[0], "a", "z")
    && chars.slice(1, slash).every((character) => isInRange(character, "a", "z") || character === "." || character === "-");
  return isModern || isOldStyle ? chars.join("") : null;
}

/** @param {string} raw */
function pmid(raw) {
  let value = raw;
  if (hasPrefix(lowercased(value), "pmid:")) value = trimmingWhitespaces(characters(value).slice(5).join(""));
  return value !== "" && /^[0-9]+$/.test(value) ? value : null;
}

/**
 * 13 digits: an ISBN-10 gains the 978 prefix and a new check digit; a bad check digit is no ISBN.
 * @param {string} raw
 */
function isbn(raw) {
  const bytes = [...new TextEncoder().encode(uppercased(raw))].filter((byte) => byte !== 0x2d && byte !== 0x20);
  const digit = (/** @type {number} */ byte) => (byte >= 0x30 && byte <= 0x39 ? byte - 0x30 : null);
  if (bytes.length === 10) {
    const body = bytes.slice(0, 9).map(digit).filter((value) => value !== null);
    const check = bytes[9] === 0x58 ? 10 : digit(bytes[9]);
    if (body.length !== 9 || check === null) return null;
    const sum = [...body, check].reduce((total, value, index) => total + /** @type {number} */ (value) * (10 - index), 0);
    if (sum % 11 !== 0) return null;
    const thirteen = [9, 7, 8, .../** @type {number[]} */ (body)];
    return [...thirteen, isbn13CheckDigit(thirteen)].join("");
  }
  const digits = bytes.map(digit).filter((value) => value !== null);
  if (bytes.length !== 13 || digits.length !== 13) return null;
  const numbers = /** @type {number[]} */ (digits);
  return isbn13CheckDigit(numbers.slice(0, 12)) === numbers[12] ? numbers.join("") : null;
}

/** @param {number[]} twelve */
function isbn13CheckDigit(twelve) {
  const sum = twelve.reduce((total, value, index) => total + value * (index % 2 === 0 ? 1 : 3), 0);
  return (10 - (sum % 10)) % 10;
}

/**
 * `<feed>#<episode GUID>`, split at the first `#`. The feed is the podcast's GUID, lowercased, or its
 * feed URL through URLNormalizer v1, so `feed://`, `http://` and `https://` forms of one feed agree;
 * the episode GUID is kept exactly.
 * @param {string} raw
 */
function podcast(raw) {
  const chars = characters(raw);
  const hash = firstIndexOfCharacter(chars, "#");
  if (hash < 0) return null;
  const feed = trimmingWhitespaces(chars.slice(0, hash).join(""));
  const episode = trimmingWhitespaces(chars.slice(hash + 1).join(""));
  if (feed === "" || episode === "") return null;
  let normalizedFeed;
  if (containsCharacters(feed, "://") || containsCharacters(feed, ".")) {
    normalizedFeed = normalizeRemoteURL(feed);
    if (normalizedFeed === null) return null;
  } else {
    normalizedFeed = lowercased(feed);
  }
  return `${normalizedFeed}#${episode}`;
}

/**
 * `owner/repo`, lowercased (GitHub's names are case-insensitive), from a bare pair or a github.com
 * address (with or without its scheme and `www.`); `.git`, a trailing slash and deeper paths dropped.
 * @param {string} raw
 */
function gitHub(raw) {
  let value = lowercased(raw);
  value = droppingFirstPrefix(value, value, ["https://", "http://"]);
  if (hasPrefix(value, "www.")) value = characters(value).slice(4).join("");
  if (hasPrefix(value, "github.com/")) value = characters(value).slice(11).join("");
  const parts = splitCharacters(value, "/");
  if (parts.length < 2) return null;
  let repo = parts[1];
  if (hasSuffix(repo, ".git")) repo = characters(repo).slice(0, -4).join("");
  if (parts[0] === "" || repo === "") return null;
  return `${parts[0]}/${repo}`;
}

/**
 * A post id: its digits, from a bare id or an `x.com/<handle>/status/<id>` address.
 * @param {string} raw
 */
function xPost(raw) {
  if (/^[0-9]+$/.test(raw)) return raw;
  const chars = characters(raw);
  const status = indexOfCharacters(chars, "/status/");
  if (status < 0) return null;
  let id = "";
  for (const character of chars.slice(status + 8)) {
    if (!isInRange(character, "0", "9")) break;
    id += character;
  }
  return id !== "" ? id : null;
}

/**
 * The lowercase hex sha256 of a file's original bytes.
 * @param {string} raw
 */
function fileHash(raw) {
  const value = lowercased(raw);
  return /^[0-9a-f]{64}$/.test(value) ? value : null;
}
