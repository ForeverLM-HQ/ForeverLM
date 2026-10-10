// Runs the shared vectors (schema/vectors/*.json) through the JS sync core (schema/js/), case by case,
// and says which failed and why: the twin of Swift's SyncVectorRunner. The website's and the gateway's
// sync-core tests both run every file through it, so what one proves the other proves too
// (docs/cloudkit-schema-design.md §12.1, WP3).

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { ENVELOPE_KEYS, LIMITS, SCHEMA_REVISION, TYPES } from "../js/schema.generated.js";
import { base64Decode, jsonEqual, serializeJSON } from "../js/json.js";
import { compareStamps, isStamp, StampClock } from "../js/stamp.js";
import {
  applyPatch,
  checkStoredSize,
  cocoaSecondsFromMilliseconds,
  decodeStoredPayload,
  encodeStoredPayload,
  envelopeFromJSON,
  gzipDecompress,
  isGzip,
  millisecondsFromCocoaSeconds,
  newEnvelope,
  pathDescription,
  RecordPatchError,
  spilledFields,
  spills,
  storageForm,
  SyncEnvelopeError,
} from "../js/envelope.js";
import { compact, merge, splitKeptCard } from "../js/merge.js";
import {
  collectionID,
  recordName,
  recordTypeOfRecordName,
  saltFromBase64,
  saltID,
  sha256Hex,
  sittingLegacyID,
  sourceFileID,
  sourceID,
} from "../js/naming.js";
import { InvalidOrderKey, keyBetween, keysBetween } from "../js/fractional-index.js";
import { isLocator, isSpan, isValidLocator, isValidSpan, locatorKind } from "../js/values.js";
import { isSpaceZone, isZoneName, LIBRARY_ZONE, resolveNotebook, resolveSource } from "../js/resolve.js";
import { chatSourceIDs, contextNotebookIDs, studioSourceIDs } from "../js/chat-ticks.js";
import { zoneFor } from "../js/placement.js";
import { chatKind } from "../js/chat-kind.js";
import { threeWayMerge } from "../js/text-merge.js";
import { HostNeedsMac, normalize, normalizeAsLegacyIPhone } from "../js/url-normalize-v1.js";
import { normalizeWorkKeyRemote } from "../js/work-key.js";

export const VECTORS_DIRECTORY = fileURLToPath(new URL("../vectors/", import.meta.url));

/** Files whose implementation belongs to a later package: only their shape is checked here. */
export const PENDING_FILES = {
  "card-schedule": "the Swift CardScheduleFold runs it (WP13); the gateway's TS port and the web's wasm fold run it when they switch",
  "replica-audit": "WP22's library-sync.js and WP25a's hosted mirror run it",
};

export const HANDLED_FILES = [
  "chat-kind", "chat-ticks", "envelope", "fractional-index", "locator", "merge", "naming", "placement",
  "resolve", "stamp-clock", "text-merge", "url-normalize", "work-key",
];

/** @param {string} directory */
export function vectorFileNames(directory = VECTORS_DIRECTORY) {
  return readdirSync(directory).filter((name) => name.endsWith(".json")).map((name) => name.slice(0, -5)).sort();
}

/**
 * @param {string} name
 * @param {string} [directory]
 * @returns {Promise<{cases: number, failures: {file: string, name: string, detail: string}[]}>}
 */
export async function runVectorFile(name, directory = VECTORS_DIRECTORY) {
  const report = { cases: 0, failures: /** @type {{file: string, name: string, detail: string}[]} */ ([]) };
  let file;
  try {
    file = JSON.parse(readFileSync(join(directory, `${name}.json`), "utf8"));
  } catch (error) {
    report.failures.push({ file: name, name: "(file)", detail: `missing or not a vector file: ${error}` });
    return report;
  }
  if (!Array.isArray(file.cases)) {
    report.failures.push({ file: name, name: "(file)", detail: "no cases" });
    return report;
  }
  if (typeof file.format !== "string" || typeof file.spec !== "string" || file.vectors !== name) {
    report.failures.push({ file: name, name: "(file)", detail: "a vector file names itself, its spec and its format" });
  }
  for (const [index, entry] of file.cases.entries()) {
    report.cases += 1;
    const caseName = typeof entry?.name === "string" ? entry.name : `case ${index + 1}`;
    try {
      const detail = await check(name, entry, file);
      if (detail) report.failures.push({ file: name, name: caseName, detail });
    } catch (error) {
      report.failures.push({ file: name, name: caseName, detail: `threw ${error?.stack ?? error}` });
    }
  }
  return report;
}

/** Every vector file in the folder, run. @param {string} [directory] */
export async function runAllVectorFiles(directory = VECTORS_DIRECTORY) {
  const reports = {};
  for (const name of vectorFileNames(directory)) reports[name] = await runVectorFile(name, directory);
  return reports;
}

// MARK: - One case

/** Null when equal, else both sides as JSON. @param {unknown} got @param {unknown} expected */
export function compare(got, expected) {
  return jsonEqual(got, expected) ? null : `got ${shown(got)}, expected ${shown(expected)}`;
}

/** A value as JSON for a failure message, or as JS text when it is no JSON value. @param {unknown} value */
function shown(value) {
  try {
    return serializeJSON(value);
  } catch {
    return String(value);
  }
}

/** @param {any} value @param {string} key */
function string(value, key) {
  const text = value?.[key];
  if (typeof text !== "string") throw new Error(`${key} missing`);
  return text;
}

/** @param {any} value @param {string} key */
function integer(value, key) {
  const number = value?.[key];
  if (!Number.isInteger(number)) throw new Error(`${key} missing`);
  return number;
}

/**
 * Null when the case holds, else what differed.
 * @param {string} name
 * @param {any} entry
 * @param {any} file
 * @returns {Promise<string | null>}
 */
async function check(name, entry, file) {
  switch (name) {
    case "envelope": return envelope(entry);
    case "merge": return mergeCase(entry);
    case "naming": return naming(entry, file);
    case "fractional-index": return fractionalIndex(entry);
    case "locator": return locator(entry);
    case "resolve": return resolve(entry);
    case "chat-ticks": return chatTicks(entry);
    case "placement": return placement(entry);
    case "stamp-clock": return stampClock(entry);
    case "chat-kind": return chatKindCase(entry);
    case "text-merge": return compare(threeWayMerge(string(entry, "base"), string(entry, "mine"), string(entry, "theirs")), entry.expect ?? null);
    case "card-schedule": {
      // Only the shape here: no JS fold exists yet (the web schedules with library-cards.js, §8c).
      const input = entry.input;
      const ok = Array.isArray(input?.cards) && Array.isArray(input?.answers) && Array.isArray(input?.offsets?.samples)
        && entry.expect !== null && typeof entry.expect === "object" && !Array.isArray(entry.expect)
        && input.cards.every((card) => typeof card?.id === "string" && Number.isInteger(card?.keptAt) && Number.isInteger(entry.expect[card.id]?.dueAt));
      return ok ? null : "a card-schedule case has input.cards, input.answers, input.offsets.samples and a dueAt per card in expect";
    }
    case "replica-audit": {
      const ok = Array.isArray(entry.rows) && Array.isArray(entry.walk?.names) && Array.isArray(entry.expect?.delete);
      return ok ? null : "a replica-audit case has rows, walk.names and expect.delete";
    }
    case "url-normalize": {
      // URL normalization v1 as the client runs it; the vectors hold no local path.
      const input = string(entry, "input");
      let normalized;
      let iphone;
      try {
        normalized = normalize(input, (path) => `<local path ${path} in the URL vectors>`);
        // The iPhone's historical form, recorded only where it differs.
        iphone = normalizeAsLegacyIPhone(input);
      } catch (error) {
        return refusedForIDNA(error, input);
      }
      if (normalized !== string(entry, "normalized")) return `normalized to ${normalized}`;
      const id = await sourceID(normalized);
      if (id !== string(entry, "sourceID")) return `source id ${id}`;
      const expected = typeof entry.iphoneNormalized === "string" ? entry.iphoneNormalized : normalized;
      return iphone === expected ? null : `the iPhone's form is ${iphone}, not ${expected}`;
    }
    case "work-key": {
      const input = string(entry, "input");
      let key;
      try {
        key = normalizeWorkKeyRemote(input);
      } catch (error) {
        return refusedForIDNA(error, input);
      }
      return compare(key, entry.expect ?? null);
    }
    default:
      return `no runner for ${name}.json: add it to schema/test/sync-vectors.mjs`;
  }
}

/**
 * A URL case the JS core refused. Right only for a host that needs IDNA, whose v1 form is a Mac's
 * (HostNeedsMac, docs/cloudkit-schema-design.md §4.1): the client files a Job instead of minting, so
 * the case holds. The input itself must show why (a non-ASCII character, a percent escape or an
 * `xn--` label), so a refused plain ASCII URL fails.
 * @param {unknown} error
 * @param {string} input
 */
function refusedForIDNA(error, input) {
  if (!(error instanceof HostNeedsMac)) throw error;
  return /[^\x00-\x7f]|%|xn--/i.test(input) ? null : `refused ${input} as a host that needs IDNA`;
}

// MARK: - envelope.json

/** @param {any} entry */
async function envelope(entry) {
  switch (string(entry, "op")) {
    case "decode": {
      const bytes = base64Decode(string(entry, "bytesBase64"));
      if (!bytes) throw new Error("bad base64");
      let decoded;
      try {
        decoded = decodeStoredPayload(bytes);
      } catch (error) {
        if (!(error instanceof SyncEnvelopeError)) throw error;
        if (typeof entry.expectError !== "string") return `refused: ${error.message}`;
        return error.code === entry.expectError ? null : `refused as ${error.code}, not ${entry.expectError}`;
      }
      if (typeof entry.expectError === "string") return `decoded, though ${entry.expectError} was expected`;
      if (entry.expectSummary) {
        const summary = entry.expectSummary;
        const text = isGzip(bytes) ? gzipDecompress(bytes, LIMITS.payloadMaxInflatedBytes) : bytes;
        const problems = [];
        if (decoded.type !== summary.type || decoded.id !== summary.id) problems.push("type or id");
        if (text.length !== summary.decodedJSONBytes) problems.push(`decoded ${text.length} bytes`);
        if ((await sha256Hex(text)) !== summary.decodedJSONSha256) problems.push("decoded sha256");
        for (const [field, length] of Object.entries(summary.fieldLengths ?? {})) {
          const value = decoded.fields[field];
          if (typeof value !== "string" || value.length !== length) problems.push(`${field} length`);
        }
        return problems.length === 0 ? null : problems.join(", ");
      }
      if (entry.expectSpilled !== undefined && compare(spilledFields(decoded), entry.expectSpilled) !== null) {
        return `spilled fields ${spilledFields(decoded)}`;
      }
      return compare(decoded, entry.expect ?? null);
    }
    case "roundTrip": {
      const original = entry.envelope ?? null;
      const decoded = decodeStoredPayload(await encodeStoredPayload(envelopeFromJSON(original)));
      return compare(decoded, original);
    }
    case "storageForm":
      return storageForm(integer(entry, "jsonBytes")) === string(entry, "expect") ? null : `stored ${storageForm(entry.jsonBytes)}`;
    case "sizeCheck": {
      let result = "ok";
      try {
        checkStoredSize(integer(entry, "storedBytes"));
      } catch (error) {
        if (!(error instanceof SyncEnvelopeError)) throw error;
        result = error.code;
      }
      return result === string(entry, "expect") ? null : `gave ${result}`;
    }
    case "stampValid":
      return isStamp(string(entry, "stamp")) === entry.expect ? null : "validity differs";
    case "stampCompare": {
      const a = string(entry, "a");
      const b = string(entry, "b");
      if (!isStamp(a) || !isStamp(b)) return "not stamps";
      const order = compareStamps(a, b);
      return order === integer(entry, "expect") ? null : `compared ${order}`;
    }
    case "spillDecision": {
      const type = string(entry, "type");
      const field = typeof entry.field === "string" ? entry.field : "";
      const utf8Bytes = Number.isInteger(entry.utf8Bytes) ? entry.utf8Bytes : 0;
      const result = Object.hasOwn(TYPES, type) ? spills(type, field, utf8Bytes) : false;
      return result === entry.expect ? null : `spills: ${result}`;
    }
    case "cocoaToMs": {
      if (typeof entry.cocoaSeconds !== "number") throw new Error("cocoaSeconds");
      const ms = millisecondsFromCocoaSeconds(entry.cocoaSeconds);
      return ms === entry.expect ? null : `gave ${ms}`;
    }
    case "msRoundTrip": {
      if (!Number.isInteger(entry.ms) || typeof entry.cocoaSeconds !== "number") throw new Error("ms");
      const back = cocoaSecondsFromMilliseconds(entry.ms);
      if (back !== entry.cocoaSeconds) return `ms gave ${back} seconds`;
      return millisecondsFromCocoaSeconds(back) === entry.ms ? null : "seconds did not give the ms back";
    }
    case "patch":
      return patch(entry);
    default:
      return "unknown op";
  }
}

/** @param {any} entry */
async function patch(entry) {
  const type = string(entry, "type");
  if (!Object.hasOwn(TYPES, type)) throw new Error("type");
  const id = string(entry, "id");
  const held = entry.held !== undefined && entry.held !== null
    ? envelopeFromJSON(entry.held)
    : newEnvelope(type, id, string(entry, "saltID"));
  /** @type {Record<string, any>} */
  const changes = {};
  for (const [field, change] of Object.entries(entry.changes ?? {})) {
    const elements = /** @type {any} */ (change)?.elements;
    changes[field] = elements !== null && typeof elements === "object" && !Array.isArray(elements)
      ? { elements }
      : { value: /** @type {any} */ (change)?.value ?? null };
  }
  const stamps = entry.stamps ?? {};
  const unexpected = [];
  let result;
  try {
    result = await applyPatch(held, { type, id, changes }, (path) => {
      const text = stamps[pathDescription(path)];
      if (!isStamp(text)) {
        unexpected.push(pathDescription(path));
        return "L0000000000000.0000.aaaaaaaa";
      }
      return text;
    });
  } catch (error) {
    if (!(error instanceof RecordPatchError)) throw error;
    if (typeof entry.expectError !== "string") return `refused: ${error.message}`;
    return error.code === entry.expectError ? null : `refused as ${error.code}, not ${entry.expectError}`;
  }
  if (typeof entry.expectError === "string") return `applied, though ${entry.expectError} was expected`;
  if (unexpected.length > 0) return `stamped paths the case gives no stamp for: ${unexpected}`;
  const stamped = result.stamped.map(pathDescription);
  const mismatch = compare(stamped, entry.expectStamped ?? null);
  if (mismatch) return `stamped ${stamped}: ${mismatch}`;
  return compare(result.envelope, entry.expect ?? null);
}

// MARK: - merge.json

/** The case's partial records (`fields`, `stamps`, unknown keys) as envelopes of `type`. @param {any} value @param {string} type */
function partialEnvelope(value, type) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("not a record");
  return envelopeFromJSON({
    ...value, env: 1, type, id: "vector-record", rev: SCHEMA_REVISION, saltID: "00000000",
    fields: value.fields ?? {}, stamps: value.stamps ?? {},
  });
}

/** @param {Record<string, unknown>} envelope */
function partialJSON(envelope) {
  const result = { ...envelope };
  for (const key of ENVELOPE_KEYS) if (key !== "fields" && key !== "stamps") delete result[key];
  return result;
}

/** @param {any} entry */
async function mergeCase(entry) {
  const type = typeof entry.type === "string" ? entry.type : "VectorRecord";
  switch (entry.op) {
    case undefined: {
      const server = partialEnvelope(entry.server ?? null, type);
      const local = partialEnvelope(entry.local ?? null, type);
      const base = entry.base === undefined || entry.base === null ? null : partialEnvelope(entry.base, type);
      const mintedAgainst = (entry.mintedAgainst ?? []).map((/** @type {any} */ path) => {
        if (!isStamp(path.stamp)) throw new Error("mintedAgainst stamp");
        return { field: string(path, "field"), element: typeof path.element === "string" ? path.element : undefined, stamp: path.stamp };
      });
      const outcome = merge(server, local, base, mintedAgainst);
      const { needsTextMerge: expectedText = [], ...expected } = entry.expect ?? {};
      const mismatch = compare(partialJSON(outcome.merged), expected);
      if (mismatch) return mismatch;
      const textMismatch = compare(outcome.needsTextMerge, expectedText);
      if (textMismatch) return `needsTextMerge: ${textMismatch}`;
      const losses = outcome.serverFirstLosses.map((loss) => ({
        field: loss.path.field,
        ...(loss.path.element === undefined ? {} : { element: loss.path.element }),
        ...(loss.hook === undefined ? {} : { hook: loss.hook }),
      }));
      const lossMismatch = compare(losses, entry.expectLosses ?? []);
      return lossMismatch ? `losses: ${lossMismatch}` : null;
    }
    case "compact":
      return compare(partialJSON(compact(partialEnvelope(entry.record ?? null, type), integer(entry, "now"))), entry.expect ?? null);
    case "splitKeptCard": {
      const server = partialEnvelope(entry.server ?? null, "Card");
      const result = await splitKeptCard(string(entry, "cardID"), server, entry.lostKept ?? null);
      const got = result
        ? { type: result.type, id: result.id, fields: Object.fromEntries(Object.entries(result.changes).map(([field, change]) => [field, /** @type {any} */ (change).value])) }
        : null;
      return compare(got, entry.expect ?? null);
    }
    default:
      return "unknown op";
  }
}

// MARK: - naming.json

/** @param {any} entry @param {any} file */
async function naming(entry, file) {
  const saltName = string(entry, "salt");
  const saltText = file.salts?.[saltName];
  const salt = typeof saltText === "string" ? saltFromBase64(saltText) : undefined;
  if (!salt) return `salt ${saltName} is not 32 bytes of base64`;
  const expectedSaltID = file.saltIDs?.[saltName];
  if (typeof expectedSaltID === "string" && (await saltID(salt)) !== expectedSaltID) return `saltID ${await saltID(salt)}`;
  const type = string(entry, "type");
  if (!Object.hasOwn(TYPES, type)) return "unknown type";
  const id = string(entry, "id");
  if (entry.idFrom) {
    const input = string(entry.idFrom, "input");
    let derived;
    switch (string(entry.idFrom, "rule")) {
      case "SittingLegacyID": derived = await sittingLegacyID(input); break;
      case "SourceFileID": derived = await sourceFileID(input); break;
      case "SourceURLID": derived = await sourceID(input); break;
      case "CollectionID": {
        const colon = input.indexOf(":");
        if (colon < 0) return "CollectionID input without a kind";
        derived = await collectionID(input.slice(0, colon), input.slice(colon + 1));
        break;
      }
      default: return "unknown idFrom rule";
    }
    if (derived !== id) return `derived id ${derived}`;
  }
  const name = await recordName(type, id, salt);
  if (name !== string(entry, "recordName")) return `named ${name}`;
  return recordTypeOfRecordName(name) === type ? null : "the name's prefix does not give the type back";
}

// MARK: - fractional-index.json

/** @param {any} entry */
function fractionalIndex(entry) {
  const a = typeof entry.a === "string" ? entry.a : null;
  const b = typeof entry.b === "string" ? entry.b : null;
  let got;
  try {
    switch (string(entry, "op")) {
      case "between": got = keyBetween(a, b); break;
      case "nBetween": got = keysBetween(a, b, integer(entry, "n")); break;
      default: return "unknown op";
    }
  } catch (error) {
    if (!(error instanceof InvalidOrderKey)) throw error;
    return entry.expectError === true ? null : "refused the keys";
  }
  if (entry.expectError === true) return `gave ${shown(got)}, though an error was expected`;
  return compare(got, entry.expect ?? null);
}

// MARK: - locator.json

/** @param {any} entry */
function locator(entry) {
  switch (string(entry, "op")) {
    case "roundTrip": {
      const raw = entry.locator ?? null;
      if (!isLocator(raw)) return "not read as a locator";
      const mismatch = compare(JSON.parse(JSON.stringify(raw)), raw);
      if (mismatch) return mismatch;
      const kind = locatorKind(raw);
      if (kind !== string(entry, "expectKind")) return `kind ${kind}`;
      return isValidLocator(raw) === entry.expectValid ? null : `valid: ${isValidLocator(raw)}`;
    }
    case "parse":
      return isLocator(entry.input ?? null) === entry.expectLocator ? null : `is a locator: ${isLocator(entry.input ?? null)}`;
    case "span": {
      const raw = entry.span ?? null;
      const span = isSpan(raw);
      if (span !== entry.expectSpan) return `is a span: ${span}`;
      if (!span) return null;
      return isValidSpan(raw) === entry.expectValid ? null : `valid: ${isValidSpan(raw)}`;
    }
    default:
      return "unknown op";
  }
}

// MARK: - resolve.json

/** A redirects reader over a case's `notebooks` (zone → id → fields). @param {any} notebooks */
function notebookRedirects(notebooks) {
  return (/** @type {{zone: string, id: string}} */ location) => {
    const zone = notebooks?.[location.zone];
    if (!zone || !Object.hasOwn(zone, location.id)) return null;
    const fields = zone[location.id] ?? {};
    const text = (/** @type {string} */ key) => (typeof fields[key] === "string" ? fields[key] : undefined);
    return { mergedInto: text("mergedInto"), movedTo: text("movedTo"), movingTo: text("movingTo") };
  };
}

/** @param {any} entry */
function resolve(entry) {
  switch (string(entry, "op")) {
    case "resolveNotebook": {
      const zone = string(entry.start ?? null, "zone");
      if (!isZoneName(zone)) return "bad start zone";
      const resolved = resolveNotebook({ zone, id: string(entry.start, "id") }, notebookRedirects(entry.notebooks ?? {}));
      return compare(resolved, entry.expect ?? null);
    }
    case "resolveSource": {
      const sources = entry.sources ?? {};
      const resolved = resolveSource(string(entry, "start"), (id) => {
        if (!Object.hasOwn(sources, id)) return undefined;
        const mergedInto = sources[id]?.mergedInto;
        return typeof mergedInto === "string" ? mergedInto : null;
      });
      return resolved === string(entry, "expect") ? null : `resolved to ${resolved}`;
    }
    default:
      return "unknown op";
  }
}

// MARK: - chat-ticks.json

/** @param {any} entry */
function chatTicks(entry) {
  const entries = (entry.entries ?? []).map((/** @type {any} */ raw) => {
    const stateStamp = raw.stamps?.state;
    if (!isStamp(stateStamp)) throw new Error("state stamp");
    const approvalStamp = raw.stamps?.approval;
    return {
      containerID: string(raw, "containerID"), itemKind: string(raw, "itemKind"), itemID: string(raw, "itemID"),
      state: string(raw, "state"), approval: typeof raw.approval === "string" ? raw.approval : null,
      stateStamp, approvalStamp: isStamp(approvalStamp) ? approvalStamp : null,
    };
  });
  // resolveNotebook() for an id, from the zone that holds it: Library first, then the spaces by name.
  const notebooks = entry.notebooks ?? {};
  const redirects = notebookRedirects(notebooks);
  const zones = Object.keys(notebooks).sort((a, b) => (a === LIBRARY_ZONE ? 0 : 1) - (b === LIBRARY_ZONE ? 0 : 1) || (a < b ? -1 : a > b ? 1 : 0));
  const resolveID = (/** @type {string} */ id) => {
    const held = zones.find((zone) => Object.hasOwn(notebooks[zone] ?? {}, id));
    if (!held || !isZoneName(held)) return id;
    return resolveNotebook({ zone: held, id }, redirects).id;
  };
  const notebookID = string(entry, "notebookID");
  const excluded = entry.excluded ?? {};
  const context = contextNotebookIDs({
    notebookID, contextNotebooks: entry.contextNotebooks ?? {}, relatedNotebookIDs: entry.relatedNotebookIDs ?? {}, resolve: resolveID,
  });
  if (entry.expectContextNotebooks !== undefined) {
    const failure = compare(context, entry.expectContextNotebooks);
    if (failure) return `context notebooks: ${failure}`;
  }
  const chat = chatSourceIDs({ notebookID, contextNotebookIDs: context, entries, excluded });
  const chatFailure = compare(chat, entry.expect ?? null);
  if (chatFailure) return `chat: ${chatFailure}`;
  const studio = studioSourceIDs({ notebookID, entries, excluded });
  const studioFailure = compare(studio, entry.expectStudio ?? entry.expect ?? null);
  return studioFailure ? `studio: ${studioFailure}` : null;
}

// MARK: - placement.json

/** The replica a case describes: zone name → record type → id → fields. @param {any} records */
function vectorReplica(records) {
  return {
    zones: (/** @type {string} */ type, /** @type {string} */ id) => Object.keys(records)
      .filter((zone) => isZoneName(zone) && Object.hasOwn(records[zone]?.[type] ?? {}, id)),
    notebookRedirects: notebookRedirectsFrom(records),
    space: (/** @type {string} */ kind, /** @type {string} */ primaryID) => Object.keys(records).sort().find((zone) => {
      const root = records[zone]?.ZoneRoot?.root;
      return isSpaceZone(zone) && root && root.kind === kind && root.primaryID === primaryID;
    }) ?? null,
  };
}

/** @param {any} records */
function notebookRedirectsFrom(records) {
  const byZone = {};
  for (const zone of Object.keys(records)) byZone[zone] = records[zone]?.Notebook ?? {};
  return notebookRedirects(byZone);
}

/** @param {any} entry */
function placement(entry) {
  const type = string(entry, "type");
  const writtenIn = string(entry, "writtenIn");
  if (!Object.hasOwn(TYPES, type) || !isZoneName(writtenIn)) return "bad type or zone";
  const zone = zoneFor(type, string(entry, "id"), entry.fields ?? {}, writtenIn, vectorReplica(entry.replica ?? {}));
  return zone === string(entry, "expect") ? null : `placed in ${zone}`;
}

// MARK: - stamp-clock.json

/** @param {any} entry */
function stampClock(entry) {
  const samples = (entry.samples ?? []).filter((/** @type {unknown} */ sample) => Number.isInteger(sample));
  switch (string(entry, "op")) {
    case "offset":
      return compare(new StampClock("k3f7ab2q", { offsetSamples: samples }).serverOffset, entry.expect ?? null);
    case "mint": {
      const policy = string(entry, "policy");
      if (!["L", "S", "X", "N", "T"].includes(policy)) return "policy";
      /** @type {Map<number, number>} */
      const earlierCounters = new Map();
      for (const [key, counter] of Object.entries(entry.earlierCounters ?? {})) {
        if (!/^-?[0-9]+$/.test(key) || !Number.isInteger(counter)) throw new Error("earlierCounters");
        earlierCounters.set(Number(key), /** @type {number} */ (counter));
      }
      const clock = new StampClock(string(entry, "deviceID"), {
        offsetSamples: samples, lastMilliseconds: integer(entry, "lastMilliseconds"), lastCounter: integer(entry, "lastCounter"),
        earlierCounters,
      });
      const seen = isStamp(entry.seen) ? entry.seen : null;
      const stamp = clock.mint(policy, integer(entry, "eventTime"), seen, integer(entry, "now"));
      const mismatch = compare(stamp, entry.expect ?? null);
      if (mismatch) return mismatch;
      const last = { lastMilliseconds: clock.lastMilliseconds, lastCounter: clock.lastCounter, earlierCounters: clock.toJSON().earlierCounters };
      const lastMismatch = compare(last, entry.expectLast ?? null);
      return lastMismatch ? `last stamp: ${lastMismatch}` : null;
    }
    default:
      return "unknown op";
  }
}

// MARK: - chat-kind.json

/** @param {any} entry */
function chatKindCase(entry) {
  const evidence = entry.evidence ?? {};
  const flag = (/** @type {string} */ key) => evidence[key] === true;
  const kind = chatKind({
    id: string(evidence, "id"), kind: typeof evidence.kind === "string" ? evidence.kind : null,
    isTeamSnapshot: flag("isTeamSnapshot"), isNamedByWalkthroughProgress: flag("isNamedByWalkthroughProgress"),
    holdsWalkthroughStep: flag("holdsWalkthroughStep"), hasOverallScore: flag("hasOverallScore"),
    hasCardIDs: flag("hasCardIDs"), hasGradedExchange: flag("hasGradedExchange"),
  });
  return kind === string(entry, "expect") ? null : `classified ${kind}`;
}

