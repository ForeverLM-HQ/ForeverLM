// URL normalization v1 (docs/cloudkit-schema-design.md §4.1): the key every web source's id is minted
// from (naming.js `sourceID`) and the `url:` work key. v1 is frozen as the Mac's implementation
// (Shared/Sync/Core/URLNormalizer.swift): an existing id is never re-derived, and
// schema/vectors/url-normalize.json pins every branch, so a change here that alters one of its
// outputs is a bug.
//
// The Swift code is built on Foundation's URLComponents, so this port carries URLComponents too, as
// macOS 27 Foundation implements it: its RFC 3986 parser, which percent-encodes invalid characters;
// its getters, which decode; and its setters, which encode again. Swift's own String rules come from
// swift-strings.js. IDNA is not ported: v1 runs ICU's UTS 46 on a non-ASCII host and on an `xn--`
// label, a JS runtime has only its own URL's IDNA, which differs from the Mac's and between runtimes,
// so a URL whose host needs it throws HostNeedsMac and the caller leaves it to a Mac.

import {
  characters,
  canonicallyEqual,
  hasPrefix,
  hasSuffix,
  isASCIIText,
  isNumberCharacter,
  lowercased,
  removingPercentEncoding,
  replacingOccurrences,
  splitCharacters,
  trimmingWhitespacesAndNewlines,
} from "./swift-strings.js";

const TRACKING_PARAMETERS = new Set(["utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term", "ref", "source", "fbclid", "gclid"]);

/**
 * URLNormalizer v1 as the Mac computes it. A local file path (one starting with `/`) normalizes
 * through `localPath`, which only the Mac can supply (its content roots). A URL whose host needs IDNA
 * throws HostNeedsMac: its v1 form, and the source id and work key made from it, are a Mac's to mint.
 * @param {string} urlString
 * @param {(path: string) => string} localPath
 * @returns {string}
 */
export function normalize(urlString, localPath) {
  const trimmed = trimmingWhitespacesAndNewlines(urlString);
  if (hasPrefix(trimmed, "/")) return localPath(trimmed);
  const podcast = canonicalApplePodcastEpisodeURL(trimmed);
  if (podcast !== null) return podcast;
  const youtubeID = extractYouTubeVideoID(trimmed);
  if (youtubeID !== null) return `youtube.com/watch?v=${youtubeID}`;

  const components = URLComponents.parse(trimmed);
  if (!components || components.host === null) return trimmed;
  components.setScheme(null);
  const host = components.host;
  if (host !== null) {
    const lower = lowercased(host);
    components.setHost(hasPrefix(lower, "www.") ? characters(lower).slice(4).join("") : lower);
  }
  if (hasSuffix(components.path, "/") && characters(components.path).length > 1) {
    components.setPath(characters(components.path).slice(0, -1).join(""));
  }

  // arXiv: /abs/, /pdf/ and /html/ are one paper, and a version suffix is dropped.
  let currentHost = components.host;
  if (currentHost === "arxiv.org" || currentHost === "export.arxiv.org") {
    components.setHost("arxiv.org");
    let path = components.path;
    for (const prefix of ["/pdf/", "/html/", "/abs/"]) {
      if (hasPrefix(path, prefix)) {
        const id = replacingOccurrences(characters(path).slice(characters(prefix).length).join(""), ".pdf", "");
        path = `/abs/${id}`;
        break;
      }
    }
    path = removingTrailingVersion(path);
    components.setPath(path);
    components.setQueryItems(null);
  }

  // bioRxiv and medRxiv: the version suffix is dropped.
  currentHost = components.host;
  if (currentHost !== null && (hasSuffix(currentHost, "biorxiv.org") || hasSuffix(currentHost, "medrxiv.org"))) {
    const unversioned = removingDottedVersion(components.path);
    if (unversioned !== null) components.setPath(unversioned);
  }

  // ScienceDirect's /science/article/abs/pii/<PII> and /science/article/pii/<PII> are one paper.
  currentHost = components.host;
  if (currentHost !== null && hasSuffix(currentHost, "sciencedirect.com")) {
    const parts = splitCharacters(components.path, "/");
    const marker = parts.findIndex((part) => lowercased(part) === "pii");
    if (marker >= 0 && marker + 1 < parts.length) {
      const raw = parts[marker + 1];
      const decoded = removingPercentEncoding(raw);
      const pii = decoded === null ? raw : trimmingWhitespacesAndNewlines(decoded);
      if (pii !== "") {
        components.setPath(`/science/article/pii/${pii}`);
        components.setQueryItems(null);
      }
    }
  }

  // Cell Press journal paths and PDF endpoints: one key per PII.
  currentHost = components.host;
  if (currentHost !== null && hasSuffix(currentHost, "cell.com")) {
    const pii = cellPressPII(components);
    if (pii !== null) {
      components.setPath(`/pii/${pii}`);
      components.setQueryItems(null);
    }
  }

  // Springer Nature: /articles/<id> and its PDF, without recommendation query strings.
  currentHost = components.host;
  if (currentHost !== null && (currentHost === "nature.com" || hasSuffix(currentHost, ".nature.com"))) {
    const articleID = springerNatureArticleID(components.path);
    if (articleID !== null) {
      components.setHost("nature.com");
      components.setPath(`/articles/${articleID}`);
      components.setQueryItems(null);
    }
  }

  components.setFragment(null);
  const queryItems = components.queryItems;
  if (queryItems !== null) {
    const cleaned = queryItems.filter((item) => !TRACKING_PARAMETERS.has(lowercased(item.name)));
    components.setQueryItems(cleaned.length === 0 ? null : cleaned);
  }

  currentHost = components.host;
  if ((currentHost === "youtube.com" || currentHost === "m.youtube.com") && components.path === "/watch") {
    const video = (components.queryItems ?? []).find((item) => item.name === "v");
    if (video && video.value !== null) return `youtube.com/watch?v=${video.value}`;
  }

  const result = components.string;
  if (result === null) return trimmed;
  return hasPrefix(result, "//") ? characters(result).slice(2).join("") : result;
}

/**
 * v1 on a client that holds no local files (the web, the hosted MCP, the iPhone): null for a local
 * path, which only the Mac can normalize, and HostNeedsMac for a host that needs IDNA, as `normalize`.
 * @param {string} urlString
 * @returns {string | null}
 */
export function normalizeRemote(urlString) {
  if (hasPrefix(trimmingWhitespacesAndNewlines(urlString), "/")) return null;
  return normalize(urlString, (path) => path);
}

/**
 * The form iPhone builds of generation 1 minted source ids from (`MobileURLNormalizer`, the web-URL
 * subset of v1 with its own differences). It is never a new id: migration 155 keeps it as an extra
 * `url:` work key on a Source an old iPhone minted (§4.1), and a light client that meets such a
 * source can compute it the same way.
 * @param {string} value
 * @returns {string}
 */
export function normalizeAsLegacyIPhone(value) {
  const trimmed = trimmingWhitespacesAndNewlines(value);
  const components = URLComponents.parse(trimmed);
  if (!components || components.host === null) return trimmed;
  const videoID = legacyIPhoneYouTubeID(components);
  if (videoID !== null) return `youtube.com/watch?v=${videoID}`;
  components.setScheme(null);
  const host = components.host;
  if (host !== null) {
    const lower = lowercased(host);
    components.setHost(hasPrefix(lower, "www.") ? characters(lower).slice(4).join("") : lower);
  }
  if (hasSuffix(components.path, "/") && characters(components.path).length > 1) {
    components.setPath(characters(components.path).slice(0, -1).join(""));
  }
  let currentHost = components.host;
  if (currentHost === "arxiv.org" || currentHost === "export.arxiv.org") {
    components.setHost("arxiv.org");
    for (const prefix of ["/pdf/", "/html/", "/abs/"]) {
      if (hasPrefix(components.path, prefix)) {
        const id = replacingOccurrences(characters(components.path).slice(characters(prefix).length).join(""), ".pdf", "");
        components.setPath(`/abs/${id}`);
        break;
      }
    }
    const unversioned = removingTrailingVersionOrNull(components.path);
    if (unversioned !== null) components.setPath(unversioned);
    components.setQueryItems(null);
  }
  currentHost = components.host;
  if (currentHost !== null && (hasSuffix(currentHost, "biorxiv.org") || hasSuffix(currentHost, "medrxiv.org"))) {
    const unversioned = removingDottedVersion(components.path);
    if (unversioned !== null) components.setPath(unversioned);
  }
  currentHost = components.host;
  if (currentHost !== null && hasSuffix(currentHost, "sciencedirect.com")) {
    const parts = splitCharacters(components.path, "/");
    const marker = parts.findIndex((part) => lowercased(part) === "pii");
    if (marker >= 0 && marker + 1 < parts.length) {
      const raw = parts[marker + 1];
      const pii = trimmingWhitespacesAndNewlines(removingPercentEncoding(raw) ?? raw);
      if (pii !== "") {
        components.setPath(`/science/article/pii/${pii}`);
        components.setQueryItems(null);
      }
    }
  }
  currentHost = components.host;
  if (currentHost !== null && hasSuffix(currentHost, "cell.com")) {
    const pii = cellPressPII(components);
    if (pii !== null) {
      components.setPath(`/pii/${pii}`);
      components.setQueryItems(null);
    }
  }
  components.setFragment(null);
  const queryItems = components.queryItems;
  if (queryItems !== null) {
    const filtered = queryItems.filter((item) => !TRACKING_PARAMETERS.has(lowercased(item.name)));
    components.setQueryItems(filtered.length === 0 ? null : filtered);
  }
  const result = components.string;
  if (result === null) return trimmed;
  return hasPrefix(result, "//") ? characters(result).slice(2).join("") : result;
}

/** @param {URLComponents} components */
function legacyIPhoneYouTubeID(components) {
  const host = lowercased(components.host ?? "");
  if (host === "youtu.be" || host === "www.youtu.be") {
    const id = trimmingScalars(components.path, "/");
    return id === "" ? null : id;
  }
  if ((host === "youtube.com" || host === "www.youtube.com" || host === "m.youtube.com") && components.path === "/watch") {
    const video = (components.queryItems ?? []).find((item) => item.name === "v");
    return video ? video.value : null;
  }
  return null;
}

/** `text.trimmingCharacters(in: CharacterSet(charactersIn: set))`. @param {string} text @param {string} set */
function trimmingScalars(text, set) {
  let start = 0;
  let end = text.length;
  while (start < end && set.includes(text[start])) start += 1;
  while (end > start && set.includes(text[end - 1])) end -= 1;
  return text.slice(start, end);
}

// MARK: - Branches

const APPLE_PODCAST_EPISODE = /^apple-podcast:\/+episode\/([A-Za-z0-9._/-]+)(?=(?:\r\n|[\n\v\f\r\u0085\u2028\u2029])?$)/iu;

/**
 * `apple-podcast://episode/<id>` for any spelling of an Apple Podcasts episode key; any other string
 * that starts `apple-podcast:` is its own key. Null for everything else. (NSRegularExpression, whose
 * `$` also matches before one final line terminator.)
 * @param {string} urlString
 */
function canonicalApplePodcastEpisodeURL(urlString) {
  if (!hasPrefix(lowercased(urlString), "apple-podcast:")) return null;
  const match = APPLE_PODCAST_EPISODE.exec(urlString);
  return match ? `apple-podcast://episode/${match[1]}` : urlString;
}

const YOUTUBE_ID_CHARACTERS = /^[A-Za-z0-9_-]{11}$/;

/** @param {string} urlString */
function extractYouTubeVideoID(urlString) {
  const components = URLComponents.parse(urlString);
  if (!components) return null;
  const host = lowercased(components.host ?? "");
  if (host === "youtu.be" || host === "www.youtu.be") {
    const path = components.path;
    const id = hasPrefix(path, "/") ? characters(path).slice(1).join("") : path;
    return id === "" ? null : id;
  }
  if (host === "m.youtube.com" && components.path === "/watch") {
    const video = (components.queryItems ?? []).find((item) => item.name === "v");
    if (video && video.value !== null) return video.value;
  }
  // youtube.com/shorts/ID, /embed/ID, /v/ID and /live/ID are the same video the watch page shows.
  if (host === "youtube.com" || host === "www.youtube.com" || host === "m.youtube.com") {
    const parts = splitCharacters(components.path, "/");
    if (parts.length >= 2 && ["shorts", "embed", "v", "live"].includes(parts[0]) && YOUTUBE_ID_CHARACTERS.test(parts[1])) {
      return parts[1];
    }
  }
  return null;
}

/**
 * The article id in a Springer Nature path, `/articles/<id>` or `/articles/<id>.pdf`, else null.
 * @param {string} path
 */
function springerNatureArticleID(path) {
  const parts = splitCharacters(path, "/");
  if (parts.length !== 2 || parts[0] !== "articles") return null;
  let id = parts[1];
  if (hasSuffix(lowercased(id), ".pdf")) id = characters(id).slice(0, -4).join("");
  return id === "" ? null : id;
}

/** @param {URLComponents} components */
function cellPressPII(components) {
  const query = (components.queryItems ?? []).find((item) => lowercased(item.name) === "pii");
  if (query && query.value !== null && trimmingWhitespacesAndNewlines(query.value) !== "") {
    return trimmingWhitespacesAndNewlines(query.value);
  }
  const parts = splitCharacters(components.path, "/");
  for (const marker of ["fulltext", "abstract", "pdf"]) {
    const index = parts.findIndex((part) => lowercased(part) === marker);
    if (index < 0 || index + 1 >= parts.length) continue;
    const raw = parts[index + 1];
    const pii = trimmingWhitespacesAndNewlines(replacingOccurrences(removingPercentEncoding(raw) ?? raw, ".pdf", ""));
    if (pii !== "") return pii;
  }
  return null;
}

/**
 * `path` with Swift Regex `v\d+$` (Characters; `\d` is `Character.isNumber`) removed, or `path`.
 * @param {string} path
 */
function removingTrailingVersion(path) {
  return removingTrailingVersionOrNull(path) ?? path;
}

/** @param {string} path */
function removingTrailingVersionOrNull(path) {
  const chars = characters(path);
  let start = chars.length;
  while (start > 0 && isNumberCharacter(chars[start - 1])) start -= 1;
  if (start === chars.length || start === 0 || !canonicallyEqual(chars[start - 1], "v")) return null;
  return chars.slice(0, start - 1).join("");
}

/**
 * `path` with Swift Regex `\.\d+v\d+$` removed, or null when it does not match.
 * @param {string} path
 */
function removingDottedVersion(path) {
  const chars = characters(path);
  let end = chars.length;
  while (end > 0 && isNumberCharacter(chars[end - 1])) end -= 1;
  if (end === chars.length || end === 0 || !canonicallyEqual(chars[end - 1], "v")) return null;
  let start = end - 1;
  while (start > 0 && isNumberCharacter(chars[start - 1])) start -= 1;
  if (start === end - 1 || start === 0 || !canonicallyEqual(chars[start - 1], ".")) return null;
  return chars.slice(0, start - 1).join("");
}

// MARK: - URLComponents (macOS 27 Foundation)

// RFC 3986 character classes as URLComponents spells them (URLComponentAllowedMask), one bit per
// ASCII code: scheme, userinfo, host (reg-name), IPvFuture, zone id, path, first path segment, query
// and fragment, and a query item's name or value.
const MASKS = {
  scheme: 0x07fffffe07fffffe03ff680000000000n,
  user: 0x47fffffe87fffffe2bff7fd200000000n,
  host: 0x47fffffe87fffffe2bff7fd200000000n,
  hostIPvFuture: 0x47fffffe87fffffe2fff7fd200000000n,
  hostZoneID: 0x47fffffe87fffffe03ff600000000000n,
  path: 0x47fffffe87ffffff2fffffd200000000n,
  pathFirstSegment: 0x47fffffe87ffffff2bffffd200000000n,
  query: 0x47fffffe87ffffffafffffd200000000n,
  queryItem: 0x47fffffe87ffffff8fffff9200000000n,
};
/** @type {Record<keyof typeof MASKS, Uint8Array>} */
const ALLOWED = /** @type {any} */ (Object.fromEntries(Object.entries(MASKS).map(([name, mask]) => {
  const table = new Uint8Array(128);
  for (let code = 0; code < 128; code += 1) table[code] = Number((mask >> BigInt(code)) & 1n);
  return [name, table];
})));

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { ignoreBOM: true });
const strictDecoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const HEX = "0123456789ABCDEF";

/** @param {number} byte */
function isHexDigit(byte) {
  return (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66);
}

/** @param {number} byte */
function hexDigitValue(byte) {
  return byte <= 0x39 ? byte - 0x30 : byte <= 0x46 ? byte - 0x37 : byte - 0x57;
}

/**
 * Every byte outside `component`'s class written as `%XX`, `%` included.
 * @param {string} text
 * @param {keyof typeof MASKS} component
 */
function addingPercentEncoding(text, component) {
  const table = ALLOWED[component];
  let result = "";
  for (const byte of encoder.encode(text)) {
    result += byte < 128 && table[byte] ? String.fromCharCode(byte) : `%${HEX[byte >> 4]}${HEX[byte & 15]}`;
  }
  return result;
}

/**
 * Whether `text` is valid for `component`: ASCII of its class, and `%` only before two hex digits
 * (or no `%` at all when percent-encoding is not allowed).
 * @param {string} text
 * @param {keyof typeof MASKS} component
 * @param {boolean} [percentEncodingAllowed]
 */
function validateString(text, component, percentEncodingAllowed = true) {
  const table = ALLOWED[component];
  let hexDigitsRequired = 0;
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    if (code >= 128) return false;
    if (!percentEncodingAllowed) {
      if (!table[code]) return false;
      continue;
    }
    if (code === 0x25) {
      if (hexDigitsRequired !== 0) return false;
      hexDigitsRequired = 2;
    } else if (!table[code]) {
      return false;
    } else if (hexDigitsRequired > 0) {
      if (!isHexDigit(code)) return false;
      hexDigitsRequired -= 1;
    }
  }
  return hexDigitsRequired === 0;
}

/** @param {string} host */
function looksLikeIPLiteral(host) {
  return host.startsWith("[") && host.endsWith("]");
}

/** @param {string} host */
function validateIPLiteralHost(host) {
  const inner = host.slice(1, -1);
  const percent = host.indexOf("%");
  if (percent < 0) return validateString(inner, "hostIPvFuture", false);
  if (host[percent + 1] !== "2" || host[percent + 2] !== "5") return false;
  return validateString(host.slice(1, percent), "hostIPvFuture", false) && validateString(host.slice(percent + 3, -1), "hostZoneID");
}

/** @param {string} host @param {boolean} [knownIPLiteral] */
function validateHost(host, knownIPLiteral = false) {
  if (knownIPLiteral || looksLikeIPLiteral(host)) return validateIPLiteralHost(host);
  return validateString(host, "host");
}

/** @param {string} scheme */
function validateScheme(scheme) {
  return scheme.length > 0 && scheme.charCodeAt(0) >= 0x41 && validateString(scheme, "scheme", false);
}

const SCHEMES_TO_PERCENT_ENCODE_HOST = new Set(["tel", "telemergencycall", "telprompt", "callto", "facetime", "facetime-prompt",
  "facetime-audio", "facetime-audio-prompt", "imap", "pop", "addressbook", "contact", "phasset", "http+unix", "https+unix",
  "ws+unix", "wss+unix"]);

/** @param {string} host @param {string | null} scheme */
function shouldPercentEncodeHost(host, scheme) {
  if (looksLikeIPLiteral(host)) return true;
  return scheme !== null && SCHEMES_TO_PERCENT_ENCODE_HOST.has(lowercased(scheme));
}

/** @param {string} host @returns {string | null} */
function percentEncodeHost(host) {
  if (host === "") return "";
  if (!looksLikeIPLiteral(host)) return addingPercentEncoding(host, "host");
  const percent = host.indexOf("%");
  if (percent < 0) return validateHost(host, true) ? host : null;
  return `${host.slice(0, percent)}${addingPercentEncoding(host.slice(percent, -1), "hostZoneID")}]`;
}

/** @param {string} path */
function percentEncodePath(path) {
  if (path === "") return "";
  const slash = path.indexOf("/");
  if (slash < 0) return addingPercentEncoding(path, "pathFirstSegment");
  if (slash === 0) return addingPercentEncoding(path, "path");
  return addingPercentEncoding(path.slice(0, slash), "pathFirstSegment") + addingPercentEncoding(path.slice(slash), "path");
}

/**
 * URLComponents' percent decoding: null for a `%` not followed by two hex digits or for bytes that
 * are not UTF-8; an `excluding` byte keeps its escape (a file URL's path keeps `%00` and `%2F`).
 * Foundation makes the string with `String(bytes:encoding: .utf8)`, which drops one leading byte
 * order mark (`%EF%BB%BF`). Every string decoded here is ASCII, from a parse or a setter.
 * @param {string | null} text
 * @param {number[]} [excluding]
 * @returns {string | null}
 */
function percentDecode(text, excluding = []) {
  if (text === null) return null;
  if (text === "" || !text.includes("%")) return text;
  const input = encoder.encode(text);
  const output = [];
  for (let index = 0; index < input.length; index += 1) {
    const byte = input[index];
    if (byte !== 0x25) {
      output.push(byte);
      continue;
    }
    if (index + 2 >= input.length || !isHexDigit(input[index + 1]) || !isHexDigit(input[index + 2])) return null;
    const value = (hexDigitValue(input[index + 1]) << 4) | hexDigitValue(input[index + 2]);
    if (excluding.includes(value)) output.push(0x25, HEX.charCodeAt(value >> 4), input[index + 2]);
    else output.push(value);
    index += 2;
  }
  let decoded;
  try {
    decoded = strictDecoder.decode(new Uint8Array(output));
  } catch {
    return null;
  }
  return decoded.startsWith("\uFEFF") ? decoded.slice(1) : decoded;
}

/**
 * A component a parse found, by its byte range in the parsed string.
 * @typedef {{scheme: string | null, user: string | null, password: string | null, host: string | null,
 *   portString: string | null, path: string, query: string | null, fragment: string | null,
 *   isIPLiteral: boolean, didPercentEncodeHost: boolean, string: string}} ParseInfo
 */

/**
 * RFC3986Parser.parse(buffer:): delimiters only, no encoding. Null when the scheme is invalid, a
 * character follows an IP literal other than `:`, or a port is not digits.
 * @param {string} string
 * @returns {ParseInfo | null}
 */
function parseDelimiters(string) {
  const bytes = encoder.encode(string);
  const end = bytes.length;
  const text = (/** @type {number} */ from, /** @type {number} */ to) => decoder.decode(bytes.subarray(from, to));
  /** @type {ParseInfo} */
  const info = { scheme: null, user: null, password: null, host: null, portString: null, path: "", query: null, fragment: null,
    isIPLiteral: false, didPercentEncodeHost: false, string };
  if (end === 0) return info;
  let index = 0;
  let schemeEnd = -1;
  for (; index < end; index += 1) {
    const byte = bytes[index];
    if (byte === 0x3a) {
      if (index !== 0) {
        schemeEnd = index;
        index += 1;
        if (index === end) {
          info.scheme = text(0, schemeEnd);
          if (!validateScheme(info.scheme)) return null;
          return info;
        }
      }
      break;
    }
    if (byte === 0x2f || byte === 0x3f || byte === 0x23 || byte === 0x5b || byte === 0x5d || byte === 0x40) {
      index = 0;
      break;
    }
  }
  if (schemeEnd >= 0) {
    info.scheme = text(0, schemeEnd);
    if (!validateScheme(info.scheme)) return null;
  }
  if (index === end) index = 0;

  if (index + 1 < end && bytes[index] === 0x2f && bytes[index + 1] === 0x2f) {
    index += 2;
    const authorityStart = index;
    while (index < end && bytes[index] !== 0x2f && bytes[index] !== 0x3f && bytes[index] !== 0x23) index += 1;
    if (index === authorityStart) {
      info.host = "";
    } else {
      let hostStart = authorityStart;
      let hostEnd = index;
      let at = -1;
      for (let scan = authorityStart; scan < index; scan += 1) if (bytes[scan] === 0x40) at = scan;
      if (at >= 0) {
        let colon = -1;
        for (let scan = authorityStart; scan < at; scan += 1) {
          if (bytes[scan] === 0x3a) {
            colon = scan;
            break;
          }
        }
        if (colon >= 0) {
          info.user = text(authorityStart, colon);
          info.password = text(colon + 1, at);
        } else {
          info.user = text(authorityStart, at);
        }
        hostStart = at + 1;
      }
      let endBracket = -1;
      if (hostStart !== index && bytes[hostStart] === 0x5b) {
        for (let scan = hostStart; scan < index; scan += 1) {
          if (bytes[scan] === 0x5d) {
            endBracket = scan;
            break;
          }
        }
      }
      if (endBracket >= 0) {
        info.isIPLiteral = true;
        hostEnd = endBracket + 1;
        if (hostEnd !== index) {
          if (bytes[hostEnd] !== 0x3a) return null;
          info.portString = text(hostEnd + 1, index);
        }
      } else {
        for (let scan = hostStart; scan < index; scan += 1) {
          if (bytes[scan] === 0x3a) {
            hostEnd = scan;
            if (scan + 1 !== index) info.portString = text(scan + 1, index);
            break;
          }
        }
      }
      info.host = text(hostStart, hostEnd);
      info.didPercentEncodeHost = info.host.includes("%");
      if (info.portString !== null && !/^[0-9]*$/.test(info.portString)
        && !(info.scheme !== null && info.scheme === "addressbook")) {
        return null;
      }
    }
  }

  const pathStart = index;
  while (index < end && bytes[index] !== 0x3f && bytes[index] !== 0x23) index += 1;
  info.path = text(pathStart, index);
  if (index === end) return info;
  if (bytes[index] === 0x3f) {
    const queryStart = index + 1;
    let pound = -1;
    for (let scan = queryStart; scan < end; scan += 1) {
      if (bytes[scan] === 0x23) {
        pound = scan;
        break;
      }
    }
    if (pound >= 0) {
      info.query = text(queryStart, pound);
      info.fragment = text(pound + 1, end);
    } else {
      info.query = text(queryStart, end);
    }
  } else {
    info.fragment = text(index + 1, end);
  }
  return info;
}

/**
 * Swift's `Int(portString)` for a string of digits: leading zeros dropped, null past Int64.
 * @param {string | null} portString
 */
function portNumber(portString) {
  if (portString === null || !/^[0-9]+$/.test(portString)) return null;
  const value = BigInt(portString);
  return value > 9223372036854775807n ? null : value.toString();
}

/** @param {ParseInfo} info */
function hasAuthorityInfo(info) {
  return info.user !== null || info.password !== null || info.host !== null || info.portString !== null;
}

/**
 * RFC3986Parser.parse(urlString:encodingInvalidCharacters: true): the parse, then every invalid
 * component encoded (a host by IDNA, which is the Mac's (HostNeedsMac), or by percent-encoding for an
 * IP literal or a scheme that asks for it) and the result parsed again. Null when nothing valid can be
 * made of it.
 * @param {string} urlString
 * @returns {ParseInfo | null}
 */
function parseURL(urlString) {
  const info = parseDelimiters(urlString);
  if (!info) return null;
  const invalid = {
    user: info.user !== null && !validateString(info.user, "user"),
    password: info.password !== null && !validateString(info.password, "user"),
    host: info.host !== null && !validateHost(info.host, info.isIPLiteral),
    path: !validateString(info.path, "path"),
    query: info.query !== null && !validateString(info.query, "query"),
    fragment: info.fragment !== null && !validateString(info.fragment, "query"),
  };
  if (!Object.values(invalid).some(Boolean)) return info;
  let final = "";
  if (info.scheme !== null) final += `${info.scheme}:`;
  if (hasAuthorityInfo(info)) final += "//";
  if (info.user !== null) {
    final += invalid.user ? addingPercentEncoding(info.user, "user") : info.user;
    if (info.password !== null) final += `:${invalid.password ? addingPercentEncoding(info.password, "user") : info.password}`;
    final += "@";
  }
  if (info.host !== null) {
    if (!invalid.host) {
      final += info.host;
    } else if (info.isIPLiteral || shouldPercentEncodeHost(info.host, info.scheme)) {
      const encoded = percentEncodeHost(info.host);
      if (encoded === null) return null;
      if (info.isIPLiteral && !validateHost(encoded, true)) return null;
      final += encoded;
    } else {
      const encoded = idnaEncodeHost(info.host);
      if (encoded === null || !validateHost(encoded)) return null;
      final += encoded;
    }
  }
  const port = portNumber(info.portString);
  if (port !== null) final += `:${port}`;
  final += invalid.path ? percentEncodePath(info.path) : info.path;
  if (info.query !== null) final += `?${invalid.query ? addingPercentEncoding(info.query, "query") : info.query}`;
  if (info.fragment !== null) final += `#${invalid.fragment ? addingPercentEncoding(info.fragment, "query") : info.fragment}`;
  return parseDelimiters(final);
}

/**
 * @typedef {{name: string, value: string | null}} QueryItem
 */

/**
 * The parts of URLComponents the normalizers use: parsed from a string, then read and set as
 * Foundation does. A setter encodes what it is given; a getter decodes.
 */
class URLComponents {
  /** @param {ParseInfo} info */
  constructor(info) {
    this.info = info;
    this.modified = false;
    /** @type {{scheme?: string | null, host?: string | null, path?: string, query?: string | null, fragment?: string | null}} */
    this.set = {};
    this.didPercentEncodeHost = info.didPercentEncodeHost;
    this.didSetInvalidHost = false;
  }

  /** @param {string} string */
  static parse(string) {
    const info = parseURL(string);
    return info ? new URLComponents(info) : null;
  }

  get scheme() {
    return "scheme" in this.set ? /** @type {string | null} */ (this.set.scheme) : this.info.scheme;
  }

  get port() {
    return portNumber(this.info.portString);
  }

  get percentEncodedUser() {
    if (this.info.user !== null) return this.info.user;
    return this.info.password !== null ? "" : null;
  }

  get encodedHost() {
    if ("host" in this.set) {
      if (this.set.host !== null) return /** @type {string} */ (this.set.host);
    } else if (this.info.host !== null) {
      return this.info.host;
    }
    return this.port !== null || this.percentEncodedUser !== null ? "" : null;
  }

  /**
   * The host, decoded: percent-encoding when it was percent-encoded, else IDNA, which throws
   * HostNeedsMac for an `xn--` label. macOS 27 decodes a host's `%00` too, where the open-source
   * swift-foundation keeps it escaped.
   */
  get host() {
    const encoded = this.encodedHost;
    if (encoded === null) return null;
    if (encoded === "") return "";
    return this.didPercentEncodeHost ? percentDecode(encoded) : idnaDecodeHost(encoded);
  }

  /** @param {string | null} scheme */
  setScheme(scheme) {
    this.modified = true;
    this.set.scheme = scheme;
    // Setting the scheme sets the host again, so it takes the encoding the scheme asks for.
    if (this.encodedHost !== null) this.setHost(this.host);
  }

  /** @param {string | null} newValue */
  setHost(newValue) {
    this.modified = true;
    this.didPercentEncodeHost = false;
    this.didSetInvalidHost = false;
    if (newValue === null) {
      this.set.host = null;
      return;
    }
    if (validateHost(newValue)) {
      this.set.host = newValue;
      this.didPercentEncodeHost = newValue.includes("%");
      return;
    }
    if (shouldPercentEncodeHost(newValue, this.scheme)) {
      const encoded = percentEncodeHost(newValue);
      if (encoded === null) {
        this.set.host = null;
        this.didSetInvalidHost = true;
        return;
      }
      this.set.host = encoded;
      this.didPercentEncodeHost = true;
      return;
    }
    const idna = idnaEncodeHost(newValue);
    if (idna !== null && validateHost(idna)) {
      this.set.host = idna;
      return;
    }
    this.didSetInvalidHost = true;
    this.set.host = percentEncodeHost(newValue);
    this.didPercentEncodeHost = true;
  }

  get percentEncodedPath() {
    return "path" in this.set ? /** @type {string} */ (this.set.path) : this.info.path;
  }

  /** The path, decoded; empty when it cannot be decoded. */
  get path() {
    const scheme = this.scheme;
    const isFileURL = scheme !== null && scheme.length === 4 && lowercased(scheme) === "file";
    return percentDecode(this.percentEncodedPath, isFileURL ? [0, 0x2f] : []) ?? "";
  }

  /** @param {string} path */
  setPath(path) {
    this.modified = true;
    this.set.path = percentEncodePath(path);
  }

  get percentEncodedQuery() {
    return "query" in this.set ? /** @type {string | null} */ (this.set.query) : this.info.query;
  }

  /** The query's items, names and values decoded (a name that cannot be decoded is empty, such a value null). */
  get queryItems() {
    const query = this.percentEncodedQuery;
    if (query === null) return null;
    if (query === "") return [];
    return query.split("&").map((item) => {
      const equals = item.indexOf("=");
      const name = equals < 0 ? item : item.slice(0, equals);
      const value = equals < 0 ? null : item.slice(equals + 1);
      return { name: percentDecode(name) ?? "", value: percentDecode(value) };
    });
  }

  /** @param {QueryItem[] | null} items */
  setQueryItems(items) {
    this.modified = true;
    if (items === null) {
      this.set.query = null;
      return;
    }
    this.set.query = items.map((item) => {
      const name = validateString(item.name, "queryItem", false) ? item.name : addingPercentEncoding(item.name, "queryItem");
      if (item.value === null) return name;
      return `${name}=${validateString(item.value, "queryItem", false) ? item.value : addingPercentEncoding(item.value, "queryItem")}`;
    }).join("&");
  }

  get percentEncodedFragment() {
    return "fragment" in this.set ? /** @type {string | null} */ (this.set.fragment) : this.info.fragment;
  }

  /** @param {string | null} fragment */
  setFragment(fragment) {
    this.modified = true;
    this.set.fragment = fragment === null ? null : validateString(fragment, "query", false) ? fragment : addingPercentEncoding(fragment, "query");
  }

  /** The URL string the components make, or null when they cannot make one. */
  get string() {
    if (!this.modified) return this.info.string;
    if (this.didSetInvalidHost) return null;
    let result = "";
    const scheme = this.scheme;
    if (scheme !== null) result += `${scheme}:`;
    const user = this.percentEncodedUser;
    const password = this.info.password;
    const host = this.encodedHost;
    const port = this.port;
    const path = this.percentEncodedPath;
    if (host !== null || port !== null || user !== null || password !== null) {
      if (path !== "" && path[0] !== "/") return null;
      result += "//";
    } else if (path.startsWith("//")) {
      return null;
    }
    if (user !== null) result += user;
    if (password !== null) result += `:${password}`;
    if (user !== null || password !== null) result += "@";
    if (host !== null) result += host;
    if (port !== null) result += `:${port}`;
    else if (this.info.portString !== null) result += `:${this.info.portString}`;
    result += result === "" ? pathWithoutSchemeColon(path) : path;
    const query = this.percentEncodedQuery;
    if (query !== null) result += `?${query}`;
    const fragment = this.percentEncodedFragment;
    if (fragment !== null) result += `#${fragment}`;
    return result;
  }
}

/**
 * A path written with no scheme and no authority, with every `:` of its first segment encoded so it
 * cannot read as a scheme.
 * @param {string} path
 */
function pathWithoutSchemeColon(path) {
  const first = path.search(/[:/]/);
  if (first < 0 || path[first] !== ":" || first === 0) return path;
  const slash = path.indexOf("/");
  const end = slash < 0 ? path.length : slash;
  return path.slice(0, end).replaceAll(":", "%3A") + path.slice(end);
}

// MARK: - IDNA, which is the Mac's

/**
 * Thrown where v1 would run IDNA on a host: a host holding a non-ASCII character (as typed, or once
 * its percent escapes are decoded and the host is set again) or an `xn--` label. v1's IDNA is
 * Foundation's, ICU's UTS 46. A JS runtime has only its own URL's, which differs from the Mac's and
 * from one runtime to the next (Chromium 152 and workerd mint other ids than the Mac for hosts where
 * Node agrees), and a host holding both a non-ASCII character and a `%` escape differs in Node too.
 * So the JS core mints no source id and no `url:` or podcast-feed work key for such a URL: the caller
 * files `Job(ingestURL)` and a Mac mints them (docs/cloudkit-schema-design.md §4.1). Whether a URL is
 * refused is decided here, by plain code, so every runtime refuses the same URLs.
 */
export class HostNeedsMac extends Error {
  /** @param {string} host the host as the parser or a setter holds it */
  constructor(host) {
    super("the URL's host needs IDNA, which only a Mac computes as v1 does");
    this.name = "HostNeedsMac";
    this.code = "hostNeedsMac";
    this.host = host;
  }
}

/**
 * Foundation's IDNA encoding of a host it cannot take as it is: null for an ASCII host, which IDNA
 * would leave as it is and Foundation then refuses or percent-encodes; any other host is IDNA's.
 * @param {string} host
 * @returns {string | null}
 */
function idnaEncodeHost(host) {
  if (host === "") return "";
  if (isASCIIText(host)) return null;
  throw new HostNeedsMac(host);
}

/**
 * The host Foundation's getter gives for one it holds (always ASCII): the host itself, unless a label
 * is `xn--`, whose decoding is IDNA's.
 * @param {string} host
 * @returns {string | null}
 */
function idnaDecodeHost(host) {
  if (host === "") return "";
  if (!isASCIIText(host)) return null;
  if (host.split(".").some((label) => /^xn--/i.test(label))) throw new HostNeedsMac(host);
  return host;
}
