// The merge (docs/cloudkit-schema-design.md §6.2): the twin of Swift's FieldMerge.swift.
// `merge(server S, local L, base B) → M`, field by field, by the policy letter of the server's stamp.
// S is the server record's envelope, L the local envelope (local state patched onto the replica's raw
// payload) and B the last acknowledged envelope this client holds (null for a create). M starts as a
// copy of S, so unknown fields and top-level keys of S survive, and takes a field or element from L
// only by its policy:
//
// - L last writer: L wins when its stamp is the later one. It also wins when the caller says the
//   local stamp was minted against the server's current stamp for that path (`mintedAgainst`, the
//   `seen` the stamp was minted with and pinned beside) and the base holds that stamp too: the writer
//   edited exactly the version the server still has. Every path without that provenance goes by stamp
//   order: a forwarded stub edit, pending fields re-applied to a moved copy, a reconciling Mac's
//   pending changes, a late-import patch, and each map or set element with no provenance of its own.
//   A terminal value (`Card.status` `retired`) is never left: when one side holds it and the other
//   does not, it is the merged value whatever the stamps (§6.1).
// - S server first: L wins only when the server has not moved the field since B (compare-and-set).
// - X, N: the larger or smaller value (numbers; number arrays lexicographically; objects by their
//   `ord` array, taken whole), stamped with the later stamp; on a tie or when the values do not
//   compare, the server's value stays.
// - T text body: L wins when the server has not moved the body since B; otherwise the server stays
//   and the field is listed in `needsTextMerge` for the three-way merge (text-merge.js).
//
// Maps and sets merge per key by the same rules. Vectors: schema/vectors/merge.json.

import { LIMITS, TYPES } from "./schema.generated.js";
import { compareStrings, copyJSON, isObject, jsonEquivalent, own, setOrRemove, setOwn, sortedKeys } from "./json.js";
import { stampIsLater } from "./stamp.js";
import { cardDraftID, sha256Hex } from "./naming.js";

/**
 * @typedef {import("./envelope.js").Envelope} Envelope
 * @typedef {import("./envelope.js").StampedPath} StampedPath
 * @typedef {{path: StampedPath, local: unknown, server: unknown, hook?: string}} ServerFirstLoss
 * @typedef {{field: string, element?: string, stamp: string}} MintedAgainst
 */

/** @param {unknown} type */
function specOf(type) {
  return typeof type === "string" && Object.hasOwn(TYPES, type) ? TYPES[/** @type {keyof typeof TYPES} */ (type)] : undefined;
}

/** @param {string} field @param {string} [element] */
function pathKey(field, element) {
  return element === undefined ? `f\u0000${field}` : `e\u0000${field}\u0000${element}`;
}

/** @param {StampedPath} path */
function description(path) {
  return path.element === undefined ? path.field : `${path.field}[${path.element}]`;
}

/**
 * The merge. `mintedAgainst` lists, for each local path whose stamp this device minted and pinned,
 * the stamp it was minted against (§6.3): the version of that field or element the writer saw. A
 * path it does not list compares by stamp alone, and an entry for a whole map or set field gives its
 * elements no provenance. Only a writer that minted the stamp itself may assert it; one that copies,
 * forwards or re-applies a stamp passes none.
 *
 * Returns `merged`; `needsTextMerge`, the T fields both sides changed since the base, sorted;
 * `serverFirstLosses`, the S fields and elements where a different local value lost to the server's,
 * each with its type's `onServerFirstLoss` hook (§6.2 step 2 runs it whether or not M is the server
 * record); `takenFromLocal`, what M took from L, sorted (every other local change lost: drop it); and
 * `isServerRecord`, true when M is the server record with nothing local pending.
 * @param {Envelope} server
 * @param {Envelope} local
 * @param {Envelope | null | undefined} base
 * @param {MintedAgainst[]} [mintedAgainst]
 */
export function merge(server, local, base, mintedAgainst = []) {
  const merged = copyJSON(server);
  /** @type {string[]} */
  const needsTextMerge = [];
  /** @type {ServerFirstLoss[]} */
  const losses = [];
  /** @type {StampedPath[]} */
  const taken = [];
  const spec = specOf(server.type);
  const hooks = spec?.onServerFirstLoss ?? {};
  /** @type {Map<string, string>} */
  const provenance = new Map(mintedAgainst.map((entry) => [pathKey(entry.field, entry.element), entry.stamp]));

  for (const field of sortedKeys(local.stamps)) {
    const localStamp = local.stamps[field];
    const baseStamp = base ? own(base.stamps, field) : undefined;
    const serverStamp = own(server.stamps, field);
    // The base's stamp means the writer did not change the field; the server's own stamp means the
    // local side holds exactly the server's write. Either way there is nothing to merge.
    if (jsonEquivalent(localStamp, baseStamp) || jsonEquivalent(localStamp, serverStamp)) continue;
    if (serverStamp === undefined) {
      setOrRemove(merged.fields, field, copyJSON(own(local.fields, field)));
      setOwn(merged.stamps, field, copyJSON(localStamp));
      taken.push({ field });
      continue;
    }
    if (typeof serverStamp === "string" && typeof localStamp === "string") {
      const fieldSchema = spec && Object.hasOwn(spec.fields, field) ? spec.fields[field] : undefined;
      const decision = decide(serverStamp, localStamp, typeof baseStamp === "string" ? baseStamp : undefined,
        own(server.fields, field), own(local.fields, field), provenance.get(pathKey(field)),
        /** @type {readonly string[]} */ (fieldSchema?.terminalValues ?? []));
      switch (decision.kind) {
        case "takeLocal":
          setOrRemove(merged.fields, field, copyJSON(own(local.fields, field)));
          setOwn(merged.stamps, field, localStamp);
          taken.push({ field });
          break;
        case "needsTextMerge":
          needsTextMerge.push(field);
          break;
        case "value":
          if (!sameOptional(own(merged.fields, field), decision.value) || own(merged.stamps, field) !== decision.stamp) {
            setOrRemove(merged.fields, field, copyJSON(decision.value));
            setOwn(merged.stamps, field, decision.stamp);
            taken.push({ field });
          }
          break;
        case "serverLost":
          if (!sameOptional(own(server.fields, field), own(local.fields, field))) {
            losses.push(loss({ field }, own(local.fields, field), own(server.fields, field), own(hooks, field)));
          }
          break;
        default:
          break;
      }
      continue;
    }
    if (isObject(serverStamp) && isObject(localStamp)) {
      const serverElements = /** @type {Record<string, string>} */ (serverStamp);
      const localElements = /** @type {Record<string, string>} */ (localStamp);
      const baseElements = isObject(baseStamp) ? /** @type {Record<string, string>} */ (baseStamp) : {};
      const serverValues = own(server.fields, field);
      /** @type {Record<string, unknown>} */
      const values = isObject(serverValues) ? copyJSON(serverValues) : {};
      /** @type {Record<string, string>} */
      const stamps = { ...serverElements };
      const localValuesRaw = own(local.fields, field);
      const localValues = isObject(localValuesRaw) ? localValuesRaw : {};
      for (const key of sortedKeys(localElements)) {
        const ls = localElements[key];
        const bs = own(baseElements, key);
        const ss = own(serverElements, key);
        if (ls === bs || ls === ss) continue;
        /** @type {StampedPath} */
        const path = { field, element: key };
        if (ss === undefined) {
          setOrRemove(values, key, copyJSON(own(localValues, key)));
          setOwn(stamps, key, ls);
          taken.push(path);
          continue;
        }
        const decision = decide(ss, ls, bs, own(values, key), own(localValues, key), provenance.get(pathKey(field, key)), []);
        switch (decision.kind) {
          case "takeLocal":
            setOrRemove(values, key, copyJSON(own(localValues, key)));
            setOwn(stamps, key, ls);
            taken.push(path);
            break;
          case "serverLost":
            if (!sameOptional(own(values, key), own(localValues, key))) {
              losses.push(loss(path, own(localValues, key), own(values, key), undefined));
            }
            break;
          case "value":
            if (!sameOptional(own(values, key), decision.value) || own(stamps, key) !== decision.stamp) {
              setOrRemove(values, key, copyJSON(decision.value));
              setOwn(stamps, key, decision.stamp);
              taken.push(path);
            }
            break;
          default:
            // keepServer, and needsTextMerge: no schema field holds T per key; such an element keeps
            // the server's, like S.
            break;
        }
      }
      setOwn(merged.fields, field, values);
      setOwn(merged.stamps, field, stamps);
    }
    // A scalar stamp on one side and per-key stamps on the other: the server's shape is the
    // schema's (its letter wins the same way), so the local edit cannot be merged.
  }
  taken.sort((a, b) => compareStrings(description(a), description(b)));
  needsTextMerge.sort(compareStrings);
  return {
    merged,
    needsTextMerge,
    serverFirstLosses: losses,
    takenFromLocal: taken,
    isServerRecord: taken.length === 0 && needsTextMerge.length === 0,
  };
}

/**
 * @param {StampedPath} path
 * @param {unknown} local
 * @param {unknown} server
 * @param {unknown} hook
 * @returns {ServerFirstLoss}
 */
function loss(path, local, server, hook) {
  /** @type {ServerFirstLoss} */
  const result = { path, local: copyJSON(local), server: copyJSON(server) };
  if (typeof hook === "string") result.hook = hook;
  return result;
}

/**
 * Two optional values are equal: both absent, or equal as Swift's `SyncJSON ==` finds them (strings by
 * canonical equivalence). @param {unknown} a @param {unknown} b
 */
function sameOptional(a, b) {
  if (a === undefined || b === undefined) return a === b;
  return jsonEquivalent(a, b);
}

/**
 * One field or element: `{kind: "takeLocal" | "keepServer" | "serverLost" | "needsTextMerge"}`, or
 * for X and N `{kind: "value", value, stamp}`, the winning value with the later stamp.
 * @param {string} ss
 * @param {string} ls
 * @param {string | undefined} bs
 * @param {unknown} serverValue
 * @param {unknown} localValue
 * @param {string | undefined} mintedAgainst
 * @param {readonly string[]} terminalValues
 * @returns {{kind: "takeLocal" | "keepServer" | "serverLost" | "needsTextMerge"} | {kind: "value", value: unknown, stamp: string}}
 */
function decide(ss, ls, bs, serverValue, localValue, mintedAgainst, terminalValues) {
  const serverUnmoved = ss === bs;
  switch (ss[0]) {
    case "L": {
      const serverTerminal = typeof serverValue === "string" && terminalValues.includes(serverValue);
      const localTerminal = typeof localValue === "string" && terminalValues.includes(localValue);
      if (serverTerminal !== localTerminal) return { kind: serverTerminal ? "keepServer" : "takeLocal" };
      const editedWhatTheServerHolds = serverUnmoved && mintedAgainst === ss;
      return { kind: editedWhatTheServerHolds || stampIsLater(ls, ss) ? "takeLocal" : "keepServer" };
    }
    case "S":
      return { kind: serverUnmoved ? "takeLocal" : "serverLost" };
    case "T":
      return { kind: serverUnmoved ? "takeLocal" : "needsTextMerge" };
    default: {
      // X and N.
      const later = stampIsLater(ls, ss) ? ls : ss;
      const order = serverValue === undefined || localValue === undefined ? null : compareOrdered(localValue, serverValue);
      if (order === null) return { kind: "value", value: serverValue, stamp: later };
      const localWins = ss[0] === "X" ? order > 0 : order < 0;
      return { kind: "value", value: localWins ? localValue : serverValue, stamp: later };
    }
  }
}

/**
 * -1, 0 or 1 for two values X and N can order: numbers, arrays of numbers (lexicographically, a
 * prefix first) or objects carrying an `ord` array of numbers; null for anything else.
 * @param {unknown} a
 * @param {unknown} b
 * @returns {number | null}
 */
export function compareOrdered(a, b) {
  if (typeof a === "number" && typeof b === "number") return a < b ? -1 : a > b ? 1 : 0;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (!a.every((value) => typeof value === "number") || !b.every((value) => typeof value === "number")) return null;
    for (let index = 0; index < Math.min(a.length, b.length); index += 1) {
      if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
    }
    return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
  }
  if (isObject(a) && isObject(b)) {
    const ordA = own(a, "ord");
    const ordB = own(b, "ord");
    if (!Array.isArray(ordA) || !Array.isArray(ordB)) return null;
    return compareOrdered(ordA, ordB);
  }
  return null;
}

// MARK: - Compaction (§3.2 rule 4)

/**
 * The envelope with every removal marker older than the horizon dropped: a `null` map value or a
 * `false` set element whose stamp's milliseconds are more than 90 days before `now`. The schema says
 * which fields are maps and sets; a field it does not list, every scalar and every unknown type are
 * left alone.
 * @param {Envelope} envelope
 * @param {number} now
 * @returns {Envelope}
 */
export function compact(envelope, now) {
  const spec = specOf(envelope.type);
  if (!spec) return copyJSON(envelope);
  const horizon = now - LIMITS.removalMarkerCompactionDays * 86_400_000;
  const compacted = copyJSON(envelope);
  for (const field of Object.keys(envelope.stamps)) {
    const elementStamps = envelope.stamps[field];
    const kind = Object.hasOwn(spec.fields, field) ? spec.fields[field].kind : undefined;
    const values = own(envelope.fields, field);
    if (!isObject(elementStamps) || kind === undefined || kind === "scalar" || !isObject(values)) continue;
    const keptValues = copyJSON(/** @type {Record<string, unknown>} */ (values));
    const keptStamps = { .../** @type {Record<string, string>} */ (elementStamps) };
    for (const [key, stamp] of Object.entries(/** @type {Record<string, string>} */ (elementStamps))) {
      if (!(Number(stamp.slice(1, 14)) < horizon)) continue;
      const value = own(keptValues, key);
      const isMarker = kind === "map" ? value === null : value === false;
      if (isMarker) {
        delete keptValues[key];
        delete keptStamps[key];
      }
    }
    setOwn(compacted.fields, field, keptValues);
    setOwn(compacted.stamps, field, keptStamps);
  }
  return compacted;
}

// MARK: - onServerFirstLoss hooks

/**
 * `Card.kept` (§3.5.22): a Keep that lost to another device's Keep with a different `fingerprint`
 * becomes a card of its own, so nothing the learner typed is lost. The new card is deterministic
 * (`card:<deck>:split:<cardID>:<first 16 hex of sha256(fingerprint)>`), so a merge run twice over the
 * same conflict makes one card. Null when nothing was lost: the same fingerprint, or the same
 * wording, or a lost Keep with no fingerprint to name the new card by. The patch writes a new Card
 * (`newEnvelope` plus `applyPatch`).
 * @param {string} cardID
 * @param {Envelope} server
 * @param {unknown} lostKept
 * @returns {Promise<import("./envelope.js").RecordPatch | null>}
 */
export async function splitKeptCard(cardID, server, lostKept) {
  const deck = own(server.fields, "deckSourceID");
  const fingerprint = own(lostKept, "fingerprint");
  if (!isObject(lostKept) || typeof deck !== "string" || typeof fingerprint !== "string") return null;
  const serverKept = own(server.fields, "kept");
  if ((serverKept !== undefined && jsonEquivalent(serverKept, lostKept)) || jsonEquivalent(fingerprint, own(serverKept, "fingerprint"))) return null;
  const seedKey = `split:${cardID}:${(await sha256Hex(fingerprint)).slice(0, 16)}`;
  /** @type {Record<string, {value: unknown}>} */
  const changes = {
    status: { value: "kept" },
    deckSourceID: { value: deck },
    seedKey: { value: seedKey },
    kept: { value: copyJSON(lostKept) },
    splitFrom: { value: cardID },
  };
  for (const field of ["origin", "madeBy", "draftedAt", "legacy"]) {
    const value = own(server.fields, field);
    if (value !== undefined) changes[field] = { value: copyJSON(value) };
  }
  const at = own(lostKept, "at");
  if (at !== undefined) changes.keptAt = { value: copyJSON(at) };
  return { type: "Card", id: cardDraftID(deck, seedKey), changes };
}
