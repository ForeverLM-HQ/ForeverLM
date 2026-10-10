#!/usr/bin/env node
// Builds the vector files whose expected values need a computation: schema/vectors/merge.json,
// placement.json, stamp-clock.json and chat-kind.json (docs/cloudkit-schema-design.md §6.2, §4.4,
// §6.3, §10). The cases
// are written out below; every expected value comes from the small reference implementations in
// this file, written from the spec and independent of the Swift and JS sync cores, which must
// agree with them. The merge cases WP1 checked in come first and are verified, not recomputed.
//
// Usage: node scripts/schema/build-vectors.mjs [--check]
// --check exits 1 when a checked-in file differs from what this script builds.

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, loadSchema } from "./generate.mjs";

const schema = loadSchema();
const DAY = 86_400_000;
const WP1_CASE_COUNT = 45;

// MARK: - JSON helpers

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const clone = (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));

function deepEqual(a, b) {
  if (a === b) return true;
  if (Array.isArray(a)) return Array.isArray(b) && a.length === b.length && a.every((value, index) => deepEqual(value, b[index]));
  if (isObject(a)) {
    if (!isObject(b)) return false;
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every((key) => key in b && deepEqual(a[key], b[key]));
  }
  return false;
}

/// JSON with sorted keys, one case per line in the files.
function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (isObject(value)) return `{${Object.keys(value).map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}

/// One case per line, keys in the order the case was built, as WP1 wrote its files.
const caseLine = (entry) => JSON.stringify(entry);

// MARK: - Reference merge (§6.2 with the WP2 corrections)

const order = (stamp) => stamp.slice(1);
const isLater = (a, b) => order(a) > order(b);
const letterOf = (stamp) => stamp[0];

function ordered(a, b) {
  if (typeof a === "number" && typeof b === "number") return a < b ? -1 : a > b ? 1 : 0;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (!a.every((x) => typeof x === "number") || !b.every((x) => typeof x === "number")) return null;
    for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
    return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
  }
  if (isObject(a) && isObject(b) && Array.isArray(a.ord) && Array.isArray(b.ord)) return ordered(a.ord, b.ord);
  return null;
}

/// One field or element: "local", "server", "lost" (an S field the server moved), "text" or {value, stamp}.
/// mintedAgainst: the stamp the local stamp was minted against, when the case gives one (provenance).
/// terminalValues: the values an L field never leaves (Card.status retired).
function decide(ss, ls, bs, serverValue, localValue, mintedAgainst, terminalValues = []) {
  const unmoved = ss === bs;
  switch (letterOf(ss)) {
    case "L": {
      const serverTerminal = typeof serverValue === "string" && terminalValues.includes(serverValue);
      const localTerminal = typeof localValue === "string" && terminalValues.includes(localValue);
      if (serverTerminal !== localTerminal) return serverTerminal ? "server" : "local";
      return (unmoved && mintedAgainst === ss) || isLater(ls, ss) ? "local" : "server";
    }
    case "S": return unmoved ? "local" : "lost";
    case "T": return unmoved ? "local" : "text";
    default: {
      const stamp = isLater(ls, ss) ? ls : ss;
      const comparison = serverValue === undefined || localValue === undefined ? null : ordered(localValue, serverValue);
      const localWins = comparison !== null && (letterOf(ss) === "X" ? comparison > 0 : comparison < 0);
      return { value: localWins ? localValue : serverValue, stamp };
    }
  }
}

function setOrDelete(object, key, value) {
  if (value === undefined) delete object[key];
  else object[key] = clone(value);
}

export function referenceMerge(server, local, base, type, mintedAgainst = []) {
  const provenance = (field, element) =>
    mintedAgainst.find((path) => path.field === field && (path.element ?? null) === (element ?? null))?.stamp;
  const terminalValues = (field) => (type && schema.types[type]?.fields[field]?.terminalValues) ?? [];
  const merged = clone(server);
  merged.fields ??= {};
  merged.stamps ??= {};
  const needsTextMerge = [];
  const losses = [];
  const hooks = (type && schema.types[type]?.onServerFirstLoss) ?? {};
  for (const field of Object.keys(local.stamps ?? {}).sort()) {
    const ls = local.stamps[field];
    const bs = base?.stamps?.[field];
    const ss = server.stamps?.[field];
    if (deepEqual(ls, bs) || deepEqual(ls, ss)) continue;
    if (ss === undefined) {
      setOrDelete(merged.fields, field, local.fields?.[field]);
      merged.stamps[field] = clone(ls);
      continue;
    }
    if (typeof ss === "string" && typeof ls === "string") {
      const decision = decide(ss, ls, typeof bs === "string" ? bs : undefined, server.fields?.[field], local.fields?.[field], provenance(field), terminalValues(field));
      if (decision === "local") {
        setOrDelete(merged.fields, field, local.fields?.[field]);
        merged.stamps[field] = ls;
      } else if (decision === "text") {
        needsTextMerge.push(field);
      } else if (decision === "lost") {
        if (!deepEqual(server.fields?.[field], local.fields?.[field])) {
          const loss = { field };
          if (hooks[field]) loss.hook = hooks[field];
          losses.push(loss);
        }
      } else if (isObject(decision)) {
        setOrDelete(merged.fields, field, decision.value);
        merged.stamps[field] = decision.stamp;
      }
    } else if (isObject(ss) && isObject(ls)) {
      const baseElements = isObject(bs) ? bs : {};
      const values = isObject(server.fields?.[field]) ? clone(server.fields[field]) : {};
      const stamps = clone(ss);
      const localValues = isObject(local.fields?.[field]) ? local.fields[field] : {};
      for (const key of Object.keys(ls).sort()) {
        if (ls[key] === baseElements[key] || ls[key] === ss[key]) continue;
        if (ss[key] === undefined) {
          setOrDelete(values, key, localValues[key]);
          stamps[key] = ls[key];
          continue;
        }
        const decision = decide(ss[key], ls[key], baseElements[key], values[key], localValues[key], provenance(field, key));
        if (decision === "local") {
          setOrDelete(values, key, localValues[key]);
          stamps[key] = ls[key];
        } else if (decision === "lost") {
          if (!deepEqual(values[key], localValues[key])) losses.push({ field, element: key });
        } else if (isObject(decision)) {
          setOrDelete(values, key, decision.value);
          stamps[key] = decision.stamp;
        }
      }
      merged.fields[field] = values;
      merged.stamps[field] = stamps;
    }
  }
  return { merged, needsTextMerge: needsTextMerge.sort(), losses };
}

export function referenceCompact(record, type, now) {
  const spec = schema.types[type];
  const result = clone(record);
  if (!spec) return result;
  const horizon = now - schema.limits.removalMarkerCompactionDays * DAY;
  for (const [field, stamps] of Object.entries(record.stamps ?? {})) {
    const kind = spec.fields[field]?.kind;
    if (!isObject(stamps) || !kind || kind === "scalar" || !isObject(record.fields?.[field])) continue;
    for (const [key, stamp] of Object.entries(stamps)) {
      if (Number(stamp.slice(1, 14)) >= horizon) continue;
      const value = record.fields[field][key];
      if (kind === "map" ? value === null : value === false) {
        delete result.fields[field][key];
        delete result.stamps[field][key];
      }
    }
  }
  return result;
}

const sha256 = async (text) => {
  const { createHash } = await import("node:crypto");
  return createHash("sha256").update(text, "utf8").digest("hex");
};

export async function referenceSplitKeptCard(cardID, server, lostKept) {
  const deck = server.fields?.deckSourceID;
  if (!isObject(lostKept) || typeof deck !== "string") return null;
  const serverKept = server.fields?.kept;
  if (deepEqual(serverKept, lostKept)) return null;
  const fingerprint = lostKept.fingerprint;
  if (typeof fingerprint !== "string" || fingerprint === serverKept?.fingerprint) return null;
  const seedKey = `split:${cardID}:${(await sha256(fingerprint)).slice(0, 16)}`;
  const fields = { status: "kept", deckSourceID: deck, seedKey, kept: lostKept, splitFrom: cardID };
  for (const field of ["origin", "madeBy", "draftedAt", "legacy"]) if (field in (server.fields ?? {})) fields[field] = server.fields[field];
  if ("at" in lostKept) fields.keptAt = lostKept.at;
  return { type: "Card", id: `card:${deck}:${seedKey}`, fields };
}

// MARK: - Merge cases

const D = { a: "aaaaaaaa", b: "bbbbbbbb", c: "cccccccc", f: "ffffffff" };
const T0 = 1759400000000;
/// A stamp: letter, milliseconds after T0, device letter, counter.
const st = (letter, offset, device = "a", counter = 0) => `${letter}${String(T0 + offset).padStart(13, "0")}.${String(counter).padStart(4, "0")}.${D[device]}`;
const rec = (fields, stamps, extra = {}) => ({ fields, stamps, ...extra });

function mergeCases() {
  const cases = [];
  const add = (name, server, local, base, extra = {}) => cases.push({ name, server, local, base, ...extra });

  // A. Every policy against every situation, on a scalar field.
  const values = { L: ["Base", "Server", "Local"], S: [{ d: "base" }, { d: "server" }, { d: "local" }], T: [{ hash: "b0" }, { hash: "s1" }, { hash: "l2" }], X: [5, 9, 7], N: [5, 3, 4] };
  for (const policy of ["L", "S", "T", "X", "N"]) {
    const [baseValue, serverValue, localValue] = values[policy];
    const f = "v";
    add(`${policy}: the writer did not change the field (local stamp is the base's): the server's value stays`,
      rec({ [f]: serverValue }, { [f]: st(policy, 2000, "c") }), rec({ [f]: baseValue }, { [f]: st(policy, 0) }), rec({ [f]: baseValue }, { [f]: st(policy, 0) }));
    add(`${policy}: the server has no value for the field: the local value is taken whatever its stamp`,
      rec({ other: 1 }, { other: st("L", 0) }), rec({ other: 1, [f]: localValue }, { other: st("L", 0), [f]: st(policy, -5000) }), rec({ other: 1 }, { other: st("L", 0) }));
    add(`${policy}: the server has not moved the field since the base: the local edit is next`,
      rec({ [f]: baseValue }, { [f]: st(policy, 0, "c") }), rec({ [f]: localValue }, { [f]: st(policy, 1000) }), rec({ [f]: baseValue }, { [f]: st(policy, 0, "c") }));
    add(`${policy}: both sides changed the field and the local stamp is later`,
      rec({ [f]: serverValue }, { [f]: st(policy, 500, "c") }), rec({ [f]: localValue }, { [f]: st(policy, 1000) }), rec({ [f]: baseValue }, { [f]: st(policy, 0) }));
    add(`${policy}: both sides changed the field and the server stamp is later`,
      rec({ [f]: serverValue }, { [f]: st(policy, 1000, "c") }), rec({ [f]: localValue }, { [f]: st(policy, 500) }), rec({ [f]: baseValue }, { [f]: st(policy, 0) }));
    add(`${policy}: a create (no base) against a server record with a later stamp`,
      rec({ [f]: serverValue }, { [f]: st(policy, 1000, "c") }), rec({ [f]: localValue }, { [f]: st(policy, 500) }), null);
    add(`${policy}: a create (no base) against a server record with an earlier stamp`,
      rec({ [f]: serverValue }, { [f]: st(policy, 500, "c") }), rec({ [f]: localValue }, { [f]: st(policy, 1000) }), null);
    add(`${policy}: the same milliseconds on both sides: the counter decides the order`,
      rec({ [f]: serverValue }, { [f]: st(policy, 700, "c", 3) }), rec({ [f]: localValue }, { [f]: st(policy, 700, "a", 4) }), rec({ [f]: baseValue }, { [f]: st(policy, 0) }));
    add(`${policy}: the same milliseconds and counter: the device id decides the order`,
      rec({ [f]: serverValue }, { [f]: st(policy, 700, "c") }), rec({ [f]: localValue }, { [f]: st(policy, 700, "b") }), rec({ [f]: baseValue }, { [f]: st(policy, 0) }));
    add(`${policy}: an explicit null from the local side merges like any value`,
      rec({ [f]: serverValue }, { [f]: st(policy, 500, "c") }), rec({ [f]: null }, { [f]: st(policy, 1000) }), rec({ [f]: baseValue }, { [f]: st(policy, 0) }));
    add(`${policy}: a null on the server merges like any value`,
      rec({ [f]: null }, { [f]: st(policy, 500, "c") }), rec({ [f]: localValue }, { [f]: st(policy, 1000) }), rec({ [f]: baseValue }, { [f]: st(policy, 0) }));
  }

  // B. X and N compare values, never stamps; the result carries the later stamp.
  const xn = [
    ["X", "negative numbers", -3, -7],
    ["X", "fractions", 0.25, 0.5],
    ["X", "an array that extends an equal prefix is larger", [2, 0.5], [2, 0.5, 1]],
    ["X", "equal arrays keep the server's", [3, 0.4], [3, 0.4]],
    ["X", "objects by ord, taken whole", { ord: [1, 2], state: "fetching" }, { ord: [1, 4], state: "ready", at: 9 }],
    ["X", "a number and a string do not compare: the server's value stays", 5, "7"],
    ["X", "a number against null does not compare: the server's value stays", 5, null],
    ["X", "objects without ord do not compare", { a: 1 }, { a: 2 }],
    ["X", "arrays holding a string do not compare", [1, "x"], [2, 0]],
    ["X", "an array and a number do not compare", [1], 2],
    ["N", "the smaller number wins", 1759100000000, 1759000000000],
    ["N", "equal values keep the server's", 1759000000000, 1759000000000],
    ["N", "arrays lexicographically", [1, 5], [1, 4]],
    ["N", "objects by ord", { ord: [0, 3] }, { ord: [0, 1], x: true }],
    ["N", "a string and a number do not compare", "a", 1],
    ["N", "booleans do not compare", true, false],
  ];
  for (const [policy, label, serverValue, localValue] of xn) {
    add(`${policy} by value: ${label}`,
      rec({ v: serverValue }, { v: st(policy, 1000, "c") }), rec({ v: localValue }, { v: st(policy, 500) }), rec({ v: 0 }, { v: st(policy, 0) }));
  }
  add("X: commutative in S and L (the same two records the other way round)",
    rec({ v: 7 }, { v: st("X", 500) }), rec({ v: 9 }, { v: st("X", 1000, "c") }), rec({ v: 0 }, { v: st("X", 0) }));
  add("N: commutative in S and L (the same two records the other way round)",
    rec({ v: 4 }, { v: st("N", 500) }), rec({ v: 3 }, { v: st("N", 1000, "c") }), rec({ v: 5 }, { v: st("N", 0) }));

  // C. Maps: every key on its own.
  const m = "m";
  add("Map L: a key only the server changed keeps the server's value",
    rec({ [m]: { k1: "S", k2: "base" } }, { [m]: { k1: st("L", 900, "c"), k2: st("L", 0) } }),
    rec({ [m]: { k1: "base", k2: "L" } }, { [m]: { k1: st("L", 0), k2: st("L", 1000) } }),
    rec({ [m]: { k1: "base", k2: "base" } }, { [m]: { k1: st("L", 0), k2: st("L", 0) } }));
  add("Map L: a key the server has not moved since the base takes the local value",
    rec({ [m]: { k1: "base" } }, { [m]: { k1: st("L", 0, "c") } }), rec({ [m]: { k1: "L" } }, { [m]: { k1: st("L", 300) } }), rec({ [m]: { k1: "base" } }, { [m]: { k1: st("L", 0, "c") } }));
  add("Map L: a local removal (null) older than the server's write loses",
    rec({ [m]: { k1: "S" } }, { [m]: { k1: st("L", 900, "c") } }), rec({ [m]: { k1: null } }, { [m]: { k1: st("L", 500) } }), rec({ [m]: { k1: "base" } }, { [m]: { k1: st("L", 0) } }));
  add("Map L: a local removal (null) later than the server's write wins and keeps its stamp",
    rec({ [m]: { k1: "S" } }, { [m]: { k1: st("L", 500, "c") } }), rec({ [m]: { k1: null } }, { [m]: { k1: st("L", 900) } }), rec({ [m]: { k1: "base" } }, { [m]: { k1: st("L", 0) } }));
  add("Map L: a server removal (null) later than a local edit stays",
    rec({ [m]: { k1: null } }, { [m]: { k1: st("L", 900, "c") } }), rec({ [m]: { k1: "L" } }, { [m]: { k1: st("L", 500) } }), rec({ [m]: { k1: "base" } }, { [m]: { k1: st("L", 0) } }));
  add("Map L: a key the server has never had is added with its stamp",
    rec({ [m]: { k1: "S" } }, { [m]: { k1: st("L", 0, "c") } }), rec({ [m]: { k1: "S", k9: { deep: [1, 2] } } }, { [m]: { k1: st("L", 0, "c"), k9: st("L", 100) } }), rec({ [m]: { k1: "S" } }, { [m]: { k1: st("L", 0, "c") } }));
  add("Map L: keys of the base the local side never stamped again are not touched",
    rec({ [m]: { k1: "S", k2: "S2" } }, { [m]: { k1: st("L", 900, "c"), k2: st("L", 900, "c") } }), rec({ [m]: { k3: "L" } }, { [m]: { k3: st("L", 100) } }), rec({ [m]: { k1: "base", k2: "base" } }, { [m]: { k1: st("L", 0), k2: st("L", 0) } }));
  add("Map L: the server's map field is absent: the local map is taken whole",
    rec({ t: "x" }, { t: st("L", 0) }), rec({ t: "x", [m]: { k1: "L", k2: null } }, { t: st("L", 0), [m]: { k1: st("L", 100), k2: st("L", 200) } }), rec({ t: "x" }, { t: st("L", 0) }));
  add("Map L: the server's map is empty but stamped: the local keys are added",
    rec({ [m]: {} }, { [m]: {} }), rec({ [m]: { k1: "L" } }, { [m]: { k1: st("L", 100) } }), rec({ [m]: {} }, { [m]: {} }));
  add("Map L: a local stamp equal to the base's for one key and newer for another",
    rec({ [m]: { k1: "S1", k2: "S2" } }, { [m]: { k1: st("L", 600, "c"), k2: st("L", 600, "c") } }),
    rec({ [m]: { k1: "base", k2: "L2" } }, { [m]: { k1: st("L", 0), k2: st("L", 800) } }),
    rec({ [m]: { k1: "base", k2: "base" } }, { [m]: { k1: st("L", 0), k2: st("L", 0) } }));
  add("Map S: an element the server has not moved since the base takes the local value",
    rec({ [m]: { a1: { r: 1 } } }, { [m]: { a1: st("S", 0, "c") } }), rec({ [m]: { a1: { r: 2 } } }, { [m]: { a1: st("S", 500) } }), rec({ [m]: { a1: { r: 1 } } }, { [m]: { a1: st("S", 0, "c") } }));
  add("Map S: an element the server moved stays, whatever the stamps",
    rec({ [m]: { a1: { r: 1 } } }, { [m]: { a1: st("S", 100, "c") } }), rec({ [m]: { a1: { r: 2 } } }, { [m]: { a1: st("S", 900) } }), rec({ [m]: { a1: { r: 0 } } }, { [m]: { a1: st("S", 0) } }));
  add("Map S: the same element written with the same value on both sides is no loss",
    rec({ [m]: { a1: { r: 1 } } }, { [m]: { a1: st("S", 100, "c") } }), rec({ [m]: { a1: { r: 1 } } }, { [m]: { a1: st("S", 900) } }), rec({ [m]: {} }, { [m]: {} }));
  add("Map X: per element by value, with the later stamp",
    rec({ [m]: { k: 3 } }, { [m]: { k: st("X", 900, "c") } }), rec({ [m]: { k: 8 } }, { [m]: { k: st("X", 100) } }), rec({ [m]: { k: 1 } }, { [m]: { k: st("X", 0) } }));
  add("Map N: per element by value, with the later stamp",
    rec({ [m]: { k: 3 } }, { [m]: { k: st("N", 100, "c") } }), rec({ [m]: { k: 2 } }, { [m]: { k: st("N", 900) } }), rec({ [m]: { k: 5 } }, { [m]: { k: st("N", 0) } }));
  add("Map T (no schema field has one): an element the server moved stays, with no text merge",
    rec({ [m]: { k: "S" } }, { [m]: { k: st("T", 500, "c") } }), rec({ [m]: { k: "L" } }, { [m]: { k: st("T", 900) } }), rec({ [m]: { k: "B" } }, { [m]: { k: st("T", 0) } }));
  add("Map T (no schema field has one): an element the server has not moved takes the local value",
    rec({ [m]: { k: "B" } }, { [m]: { k: st("T", 0) } }), rec({ [m]: { k: "L" } }, { [m]: { k: st("T", 900) } }), rec({ [m]: { k: "B" } }, { [m]: { k: st("T", 0) } }));
  add("Shape mismatch: a scalar stamp on the server and per-key stamps locally keep the server's field",
    rec({ [m]: "scalar" }, { [m]: st("L", 100, "c") }), rec({ [m]: { k: "L" } }, { [m]: { k: st("L", 900) } }), rec({ [m]: "scalar" }, { [m]: st("L", 0) }));
  add("Shape mismatch: per-key stamps on the server and a scalar stamp locally keep the server's field",
    rec({ [m]: { k: "S" } }, { [m]: { k: st("L", 100, "c") } }), rec({ [m]: "L" }, { [m]: st("L", 900) }), rec({ [m]: { k: "B" } }, { [m]: { k: st("L", 0) } }));

  // D. Sets.
  const s = "set";
  add("Set: a removal on the server and an add of another element locally both land",
    rec({ [s]: { e1: false, e2: true } }, { [s]: { e1: st("L", 500, "c"), e2: st("L", 0) } }), rec({ [s]: { e1: true, e2: true, e3: true } }, { [s]: { e1: st("L", 0), e2: st("L", 0), e3: st("L", 600) } }), rec({ [s]: { e1: true, e2: true } }, { [s]: { e1: st("L", 0), e2: st("L", 0) } }));
  add("Set: a local removal of an element the server has not moved wins even with an older stamp than another server element",
    rec({ [s]: { e1: true, e2: true } }, { [s]: { e1: st("L", 0), e2: st("L", 2000, "c") } }), rec({ [s]: { e1: false, e2: true } }, { [s]: { e1: st("L", 100), e2: st("L", 0) } }), rec({ [s]: { e1: true, e2: true } }, { [s]: { e1: st("L", 0), e2: st("L", 0) } }));
  add("Set: a re-add later than the server's removal comes back",
    rec({ [s]: { e1: false } }, { [s]: { e1: st("L", 500, "c") } }), rec({ [s]: { e1: true } }, { [s]: { e1: st("L", 900) } }), rec({ [s]: { e1: true } }, { [s]: { e1: st("L", 0) } }));
  add("Set: a re-add earlier than the server's removal stays removed",
    rec({ [s]: { e1: false } }, { [s]: { e1: st("L", 900, "c") } }), rec({ [s]: { e1: true } }, { [s]: { e1: st("L", 500) } }), rec({ [s]: { e1: true } }, { [s]: { e1: st("L", 0) } }));
  add("Set: removal markers the writer did not touch are kept as the server has them",
    rec({ [s]: { e1: false, e2: false } }, { [s]: { e1: st("L", 10, "c"), e2: st("L", 20, "c") } }), rec({ [s]: { e3: true } }, { [s]: { e3: st("L", 30) } }), rec({ [s]: {} }, { [s]: {} }));
  add("Set: both sides add the same element: the later stamp is kept",
    rec({ [s]: { e1: true } }, { [s]: { e1: st("L", 500, "c") } }), rec({ [s]: { e1: true } }, { [s]: { e1: st("L", 700) } }), rec({ [s]: {} }, { [s]: {} }));
  add("Set: both sides remove the same element: the later stamp is kept",
    rec({ [s]: { e1: false } }, { [s]: { e1: st("L", 900, "c") } }), rec({ [s]: { e1: false } }, { [s]: { e1: st("L", 700) } }), rec({ [s]: { e1: true } }, { [s]: { e1: st("L", 0) } }));
  add("Set: a create (no base) of a set field the server already holds merges element by element",
    rec({ [s]: { e1: true, e2: false } }, { [s]: { e1: st("L", 100, "c"), e2: st("L", 900, "c") } }), rec({ [s]: { e1: false, e2: true } }, { [s]: { e1: st("L", 500), e2: st("L", 500) } }), null);

  // E. Far-future stamps (§6.3 as corrected by WP2): stamps compare unclamped, by their 27 characters.
  // An edit made after seeing a far-future stamp wins only through its provenance: the stamp it was
  // minted against (mintedAgainst) is the one the server and the base still hold.
  const future = 30 * DAY;
  const bad = st("L", future, "f");
  add("Far future: an edit made after seeing a far-future value is stamped one millisecond past now + 1 day, and wins because it was minted against the stamp the server still holds",
    rec({ v: "Bad clock" }, { v: bad }), rec({ v: "Fixed" }, { v: st("L", DAY + 1) }), rec({ v: "Bad clock" }, { v: bad }),
    { mintedAgainst: [{ field: "v", stamp: bad }] });
  add("Far future: the same edit without its provenance (a stamp copied, not minted here) goes by stamp order and loses",
    rec({ v: "Bad clock" }, { v: bad }), rec({ v: "Fixed" }, { v: st("L", DAY + 1) }), rec({ v: "Bad clock" }, { v: bad }));
  add("Far future: a concurrent honest edit loses to a far-future stamp it never saw (the stamps' order decides)",
    rec({ v: "Bad clock" }, { v: bad }), rec({ v: "Honest" }, { v: st("L", 1000) }), rec({ v: "Base" }, { v: st("L", 0) }));
  add("Far future: two far-future stamps compare by their own order, never by a clamp",
    rec({ v: "Later" }, { v: bad }), rec({ v: "Earlier" }, { v: st("L", future - 1, "b") }), rec({ v: "Base" }, { v: st("L", 0) }));
  add("Far future: a map element edited after seeing a far-future element wins the same way, through the element's own provenance",
    rec({ m: { k: "Bad clock", j: "j" } }, { m: { k: bad, j: st("L", 5000, "c") } }), rec({ m: { k: "Fixed", j: "j0" } }, { m: { k: st("L", DAY + 1), j: st("L", 0) } }),
    rec({ m: { k: "Bad clock", j: "j0" } }, { m: { k: bad, j: st("L", 0) } }),
    { mintedAgainst: [{ field: "m", element: "k", stamp: bad }] });
  add("Far future: provenance given for a map field as a whole is no element's provenance, so its elements go by stamp order",
    rec({ m: { k: "Bad clock" } }, { m: { k: bad } }), rec({ m: { k: "Fixed" } }, { m: { k: st("L", DAY + 1) } }), rec({ m: { k: "Bad clock" } }, { m: { k: bad } }),
    { mintedAgainst: [{ field: "m", stamp: bad }] });
  add("Far future: minted against the server's stamp while the base holds another, the edit goes by stamp order",
    rec({ v: "Bad clock" }, { v: bad }), rec({ v: "Fixed" }, { v: st("L", DAY + 1) }), rec({ v: "Base" }, { v: st("L", 0) }),
    { mintedAgainst: [{ field: "v", stamp: bad }] });
  add("Far future: X keeps the larger value and the later stamp, far future or not",
    rec({ v: 3 }, { v: st("X", future, "f") }), rec({ v: 4 }, { v: st("X", 500) }), rec({ v: 1 }, { v: st("X", 0) }));
  add("Far future: S is decided by compare-and-set, never by stamps",
    rec({ v: "first" }, { v: st("S", future, "f") }), rec({ v: "second" }, { v: st("S", DAY + 1) }), rec({ v: "first" }, { v: st("S", future, "f") }));

  // E2. Every other path goes by stamp order (§6.2 as corrected by WP2's review): a pinned edit
  // whose server version moved, a stub edit forwarded verbatim (§5.2), pending fields re-applied
  // to a moved copy (§6.2, §4.4), a reconciling Mac's pending changes (§13.5) and late-import
  // patches (§13.6), whose stamps are times of their own.
  add("Provenance: a pinned edit whose server version has moved since it was minted goes by stamp order, and the newer server edit stays",
    rec({ v: "Newer" }, { v: st("L", 9000, "c") }), rec({ v: "Mine" }, { v: st("L", 5000, "b") }), rec({ v: "Seen" }, { v: st("L", 1000) }),
    { mintedAgainst: [{ field: "v", stamp: st("L", 1000) }] });
  add("Provenance: a pinned edit whose server version has moved still wins when its own stamp is later",
    rec({ v: "Other" }, { v: st("L", 4000, "c") }), rec({ v: "Mine" }, { v: st("L", 5000, "b") }), rec({ v: "Seen" }, { v: st("L", 1000) }),
    { mintedAgainst: [{ field: "v", stamp: st("L", 1000) }] });
  add("Forwarded stub edit: a late rename forwarded verbatim (its stamp copied, no provenance) loses to a newer rename made in the space",
    rec({ title: "Renamed in the space" }, { title: st("L", 5000, "c") }), rec({ title: "Stale rename" }, { title: st("L", 3000, "b") }),
    rec({ title: "Renamed in the space" }, { title: st("L", 5000, "c") }));
  add("Forwarded stub edit: a forwarded rename later than the space copy's title wins by its stamp",
    rec({ title: "Renamed in the space" }, { title: st("L", 5000, "c") }), rec({ title: "Late rename" }, { title: st("L", 7000, "b") }),
    rec({ title: "Renamed in the space" }, { title: st("L", 5000, "c") }));
  add("Re-applied after a move: a pending field re-applied to the moved copy, still naming the original's stamp, loses to an edit made in the space",
    rec({ title: "Edited in the space" }, { title: st("L", 6000, "c") }), rec({ title: "Pending edit" }, { title: st("L", 4000, "b") }), null,
    { mintedAgainst: [{ field: "title", stamp: st("L", 1000) }] });
  add("Re-applied after a move: a pending field later than the copy's wins by its stamp",
    rec({ title: "Copied" }, { title: st("L", 1000) }), rec({ title: "Pending edit" }, { title: st("L", 4000, "b") }), rec({ title: "Copied" }, { title: st("L", 1000) }));
  add("Reconcile: a second Mac's older pending edit loses to a newer server edit after its fetch made the base the server's record",
    rec({ body: "A's newer words" }, { body: st("L", 9000, "c") }), rec({ body: "B's older words" }, { body: st("L", 1000, "b") }),
    rec({ body: "A's newer words" }, { body: st("L", 9000, "c") }));
  add("Reconcile: a pending change whose provenance names the version before the fetch goes by stamp order",
    rec({ body: "A's newer words" }, { body: st("L", 9000, "c") }), rec({ body: "B's words" }, { body: st("L", 1000, "b") }),
    rec({ body: "A's newer words" }, { body: st("L", 9000, "c") }),
    { mintedAgainst: [{ field: "body", stamp: st("L", 500) }] });
  add("Reconcile: a pending change later than the server's field wins by its stamp",
    rec({ body: "A's words" }, { body: st("L", 9000, "c") }), rec({ body: "B's newer words" }, { body: st("L", 12000, "b") }),
    rec({ body: "A's words" }, { body: st("L", 9000, "c") }));
  add("Late import: an old-world patch older than the value the server still holds from the base loses",
    rec({ v: "New world" }, { v: st("L", 5000, "c") }), rec({ v: "Old world" }, { v: st("L", 3000, "b") }), rec({ v: "New world" }, { v: st("L", 5000, "c") }));
  add("Late import: an old-world patch newer than the server's value wins",
    rec({ v: "New world" }, { v: st("L", 5000, "c") }), rec({ v: "Old world, later" }, { v: st("L", 7000, "b") }), rec({ v: "New world" }, { v: st("L", 5000, "c") }));
  add("Late import: per element, an old patch of one key loses while the other key's edit, minted against its far-future server stamp, wins",
    rec({ m: { old: "server", minted: "Bad clock" } }, { m: { old: st("L", 5000, "c"), minted: bad } }),
    rec({ m: { old: "patch", minted: "Fixed" } }, { m: { old: st("L", 3000, "b"), minted: st("L", DAY + 1) } }),
    rec({ m: { old: "server", minted: "Bad clock" } }, { m: { old: st("L", 5000, "c"), minted: bad } }),
    { mintedAgainst: [{ field: "m", element: "minted", stamp: bad }] });
  add("Late import: S fields are compare-and-set either way (the server unmoved since the base takes the patch)",
    rec({ v: "first" }, { v: st("S", 5000, "c") }), rec({ v: "imported" }, { v: st("S", 3000, "b") }), rec({ v: "first" }, { v: st("S", 5000, "c") }));
  add("Late import: X compares values, stamps only for the result's",
    rec({ v: 4 }, { v: st("X", 5000, "c") }), rec({ v: 6 }, { v: st("X", 3000, "b") }), rec({ v: 4 }, { v: st("X", 5000, "c") }));

  // E3. Terminal values (§6.1: Card.status never leaves retired): one side holding it decides.
  add("Card.status: a retire is never undone by a later skip on the server",
    rec({ deckSourceID: "src_1", status: "skipped" }, { deckSourceID: st("S", 0), status: st("L", 6000, "c") }),
    rec({ deckSourceID: "src_1", status: "retired" }, { deckSourceID: st("S", 0), status: st("L", 5000, "b") }),
    rec({ deckSourceID: "src_1", status: "draft" }, { deckSourceID: st("S", 0), status: st("L", 0) }), { type: "Card" });
  add("Card.status: a later keep elsewhere does not take a retired card out of retirement",
    rec({ deckSourceID: "src_1", status: "retired" }, { deckSourceID: st("S", 0), status: st("L", 5000, "c") }),
    rec({ deckSourceID: "src_1", status: "kept" }, { deckSourceID: st("S", 0), status: st("L", 6000, "b") }),
    rec({ deckSourceID: "src_1", status: "draft" }, { deckSourceID: st("S", 0), status: st("L", 0) }), { type: "Card" });
  add("Card.status: retired on both sides keeps the later stamp",
    rec({ deckSourceID: "src_1", status: "retired" }, { deckSourceID: st("S", 0), status: st("L", 5000, "c") }),
    rec({ deckSourceID: "src_1", status: "retired" }, { deckSourceID: st("S", 0), status: st("L", 6000, "b") }),
    rec({ deckSourceID: "src_1", status: "draft" }, { deckSourceID: st("S", 0), status: st("L", 0) }), { type: "Card" });
  add("Card.status: without a terminal value on either side the last writer wins",
    rec({ deckSourceID: "src_1", status: "skipped" }, { deckSourceID: st("S", 0), status: st("L", 6000, "c") }),
    rec({ deckSourceID: "src_1", status: "kept" }, { deckSourceID: st("S", 0), status: st("L", 5000, "b") }),
    rec({ deckSourceID: "src_1", status: "draft" }, { deckSourceID: st("S", 0), status: st("L", 0) }), { type: "Card" });
  add("Terminal values come from the schema: the same values on a type without them merge by stamp",
    rec({ status: "skipped" }, { status: st("L", 6000, "c") }), rec({ status: "retired" }, { status: st("L", 5000, "b") }), rec({ status: "draft" }, { status: st("L", 0) }));

  // F. Unknown fields and keys.
  add("Unknown fields of the server that the local side also has unchanged survive",
    rec({ t: "S", future: [1] }, { t: st("L", 900, "c"), future: st("L", 50, "c") }), rec({ t: "L", future: [1] }, { t: st("L", 500), future: st("L", 50, "c") }), rec({ t: "B", future: [1] }, { t: st("L", 0), future: st("L", 50, "c") }));
  add("An unknown field changed on both sides merges by the server stamp's letter",
    rec({ future: "S" }, { future: st("S", 900, "c") }), rec({ future: "L" }, { future: st("L", 1000) }), rec({ future: "B" }, { future: st("S", 0) }));
  add("Unknown top-level keys of the local side are not carried (the server's are)",
    rec({ t: "S" }, { t: st("L", 100, "c") }, { serverOnly: 1 }), rec({ t: "L" }, { t: st("L", 900) }, { localOnly: 2 }), rec({ t: "B" }, { t: st("L", 0) }));
  add("A local field with a value but no stamp is not merged",
    rec({ t: "S" }, { t: st("L", 100, "c") }), rec({ t: "S", stray: "x" }, { t: st("L", 100, "c") }), rec({ t: "S" }, { t: st("L", 100, "c") }));
  add("A server field with no local stamp is kept as is",
    rec({ t: "S", only: { a: 1 } }, { t: st("L", 100, "c"), only: st("L", 100, "c") }), rec({ t: "L" }, { t: st("L", 900) }), rec({ t: "B" }, { t: st("L", 0) }));

  // G. Lost first writes and the onServerFirstLoss hook (§6.2 step 2).
  const keptA = { front: "Q", back: "Mine", anchors: [], fingerprint: "fp-mine", at: T0 + 500 };
  const keptB = { front: "Q", back: "Theirs", anchors: [], fingerprint: "fp-theirs", at: T0 + 400 };
  add("Card.kept: a Keep that lost to another device's Keep is a loss with the splitKeptCard hook",
    rec({ deckSourceID: "src_1", kept: keptB, status: "kept" }, { deckSourceID: st("S", 0), kept: st("S", 400, "c"), status: st("L", 400, "c") }),
    rec({ deckSourceID: "src_1", kept: keptA, status: "kept" }, { deckSourceID: st("S", 0), kept: st("S", 500), status: st("L", 500) }),
    rec({ deckSourceID: "src_1", status: "draft" }, { deckSourceID: st("S", 0), status: st("L", 0) }), { type: "Card" });
  add("Card.kept: a Keep the server has not moved past is taken, no loss",
    rec({ deckSourceID: "src_1", status: "draft" }, { deckSourceID: st("S", 0), status: st("L", 0) }),
    rec({ deckSourceID: "src_1", kept: keptA, status: "kept" }, { deckSourceID: st("S", 0), kept: st("S", 500), status: st("L", 500) }),
    rec({ deckSourceID: "src_1", status: "draft" }, { deckSourceID: st("S", 0), status: st("L", 0) }), { type: "Card" });
  add("Card.kept: the same Keep on both sides (one wording) is no loss",
    rec({ deckSourceID: "src_1", kept: keptA }, { deckSourceID: st("S", 0), kept: st("S", 400, "c") }),
    rec({ deckSourceID: "src_1", kept: keptA }, { deckSourceID: st("S", 0), kept: st("S", 500) }),
    rec({ deckSourceID: "src_1" }, { deckSourceID: st("S", 0) }), { type: "Card" });
  add("Card.draft is a last-writer field: losing it is no loss",
    rec({ draft: { front: "S" } }, { draft: st("L", 900, "c") }), rec({ draft: { front: "L" } }, { draft: st("L", 500) }), rec({ draft: { front: "B" } }, { draft: st("L", 0) }), { type: "Card" });
  add("An S field without a hook (ZoneRoot.seedClaim) still reports its loss",
    rec({ seedClaim: { device: "cccccccc", leaseUntil: 9 } }, { seedClaim: st("S", 500, "c") }), rec({ seedClaim: { device: "aaaaaaaa", leaseUntil: 8 } }, { seedClaim: st("S", 600) }), rec({}, {}), { type: "ZoneRoot" });
  add("Sitting.answers: an answer id written with another value on the server is an element loss with no hook",
    rec({ answers: { a1: { subject: "crd:1", at: 1, rating: "good", counted: true, practice: false } } }, { answers: { a1: st("S", 100, "c") } }),
    rec({ answers: { a1: { subject: "crd:1", at: 1, rating: "hard", counted: true, practice: false }, a2: { subject: "crd:2", at: 2, counted: true, practice: false } } }, { answers: { a1: st("S", 200), a2: st("S", 300) } }),
    rec({ answers: {} }, { answers: {} }), { type: "Sitting" });

  // H. Idempotence: merging the server record into itself is the server record.
  const sample = rec({ t: "S", n: 4, low: 2, m: { k: "v", gone: null }, set: { e: true, x: false }, body: { hash: "s" }, claim: { d: 1 } },
    { t: st("L", 900, "c"), n: st("X", 800, "c"), low: st("N", 700, "c"), m: { k: st("L", 600, "c"), gone: st("L", 650, "c") }, set: { e: st("L", 500, "c"), x: st("L", 550, "c") }, body: st("T", 400, "c"), claim: st("S", 300, "c") },
    { future: true });
  add("Idempotent over every policy, map and set: merge(S, S, B) is S (with an older base)", sample, clone(sample), rec({ t: "B" }, { t: st("L", 0) }));
  add("Idempotent over every policy, map and set: merge(S, S, B) is S (as a create)", sample, clone(sample), null);
  add("Idempotent over every policy, map and set: merge(S, S, S) is S", sample, clone(sample), clone(sample));
  return cases;
}

// Random cases: a base record, then a server and a local side that each edit, remove or keep
// fields and elements from it, stamped by two devices. Seeded, so the file is stable.
function mulberry32(seed) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randomCases(count, seed) {
  const random = mulberry32(seed);
  const pick = (list) => list[Math.floor(random() * list.length)];
  const scalarValues = ["a", "b", "c", 1, 2, 3.5, null, true, [1, 2], { k: 1 }, { ord: [0, 2] }, { ord: [1, 1] }];
  const fieldPlan = [["l1", "L", "scalar"], ["l2", "L", "scalar"], ["s1", "S", "scalar"], ["x1", "X", "scalar"], ["n1", "N", "scalar"], ["t1", "T", "scalar"], ["m1", "L", "map"], ["e1", "L", "set"], ["a1", "S", "map"]];
  const cases = [];
  for (let index = 0; index < count; index++) {
    let clock = 0;
    const stampFor = (letter, device) => st(letter, (clock += 1 + Math.floor(random() * 50)), device, Math.floor(random() * 3));
    const isCreate = random() < 0.15;
    const base = { fields: {}, stamps: {} };
    for (const [name, letter, kind] of fieldPlan) {
      if (random() < 0.2) continue;
      if (kind === "scalar") {
        base.fields[name] = pick(scalarValues);
        base.stamps[name] = stampFor(letter, "a");
      } else {
        base.fields[name] = {};
        base.stamps[name] = {};
        for (const key of ["k1", "k2", "k3"]) {
          if (random() < 0.4) continue;
          base.fields[name][key] = kind === "set" ? random() < 0.7 : pick(scalarValues);
          base.stamps[name][key] = stampFor(letter, "a");
        }
      }
    }
    const edit = (device) => {
      const side = clone(base);
      for (const [name, letter, kind] of fieldPlan) {
        if (random() < 0.45) continue;
        if (kind === "scalar") {
          side.fields[name] = pick(scalarValues);
          side.stamps[name] = stampFor(letter, device);
        } else {
          side.fields[name] ??= {};
          side.stamps[name] = isObject(side.stamps[name]) ? side.stamps[name] : {};
          for (const key of ["k1", "k2", "k3", "k4"]) {
            if (random() < 0.5) continue;
            side.fields[name][key] = kind === "set" ? random() < 0.5 : pick(scalarValues.concat([null]));
            side.stamps[name][key] = stampFor(letter, device);
          }
        }
      }
      return side;
    };
    const server = edit("c");
    const local = edit("b");
    if (random() < 0.3) server.unknownKey = { n: index };
    cases.push({ name: `random ${index + 1} (seed ${seed})`, server, local, base: isCreate ? null : base });
  }
  return cases;
}

function compactCases() {
  const now = 1759500000000;
  const old = st("L", now - T0 - 91 * DAY);
  const young = st("L", now - T0 - 10 * DAY);
  return [
    { op: "compact", name: "a false value in a map is a value, not a removal marker (Source.meta), whatever its age", type: "Source", record: rec({ meta: { protected: false, gone: null } }, { meta: { protected: old, gone: old } }), now },
    { op: "compact", name: "a null in a set is not a set's removal marker (only false is)", type: "Artifact", record: rec({ sourceIDs: { s1: null, s2: false } }, { sourceIDs: { s1: old, s2: old } }), now },
    { op: "compact", name: "a field the schema does not list is never compacted", type: "Source", record: rec({ futureMap: { k: null } }, { futureMap: { k: old } }), now },
    { op: "compact", name: "a record type the schema does not list is never compacted", type: "FutureType", record: rec({ files: { pdf: null } }, { files: { pdf: old } }), now },
    { op: "compact", name: "young markers stay and old ones go in the same map", type: "Notebook", record: rec({ researchQuestions: { q1: null, q2: null, q3: { text: "kept" } } }, { researchQuestions: { q1: old, q2: young, q3: old } }), now },
    { op: "compact", name: "Device.roles (a set) drops an old false element", type: "Device", record: rec({ roles: { seeder: false, maintenance: true } }, { roles: { seeder: old, maintenance: old } }), now },
    { op: "compact", name: "NotebookState.excluded (a map) drops an old null and keeps an untick pair", type: "NotebookState", record: rec({ excluded: { src_a: null, src_b: `${st("L", 0)}|-` } }, { excluded: { src_a: old, src_b: old } }), now },
    { op: "compact", name: "Sitting.answers (a map of S elements) drops an old null like any map", type: "Sitting", record: rec({ answers: { a1: null, a2: { subject: "crd:1", at: 1, counted: true, practice: false } } }, { answers: { a1: st("S", now - T0 - 91 * DAY), a2: st("S", now - T0 - 91 * DAY) } }), now },
  ];
}

async function splitCases() {
  const keptMine = { front: "Q", back: "Mine", anchors: [], fingerprint: "fp-mine", at: T0 + 500 };
  const keptTheirs = { front: "Q", back: "Theirs", anchors: [], fingerprint: "fp-theirs", at: T0 + 400 };
  const server = (kept, extra = {}) => ({ fields: { deckSourceID: "src_1", origin: "walkthrough", status: "kept", kept, madeBy: { model: "m", at: 1 }, draftedAt: T0, ...extra }, stamps: {} });
  return [
    { op: "splitKeptCard", name: "a lost Keep with another fingerprint becomes its own kept card, split from the original", cardID: "card:src_1:walk:src_1#q3", server: server(keptTheirs), lostKept: keptMine },
    { op: "splitKeptCard", name: "the same fingerprint: nothing was lost", cardID: "card-1", server: server(keptTheirs), lostKept: { ...keptMine, fingerprint: "fp-theirs" } },
    { op: "splitKeptCard", name: "the same wording: nothing was lost", cardID: "card-1", server: server(keptMine), lostKept: keptMine },
    { op: "splitKeptCard", name: "a lost Keep without a fingerprint cannot be split deterministically and is not", cardID: "card-1", server: server(keptTheirs), lostKept: { front: "Q", back: "Mine" } },
    { op: "splitKeptCard", name: "a server card without a Keep still gets the split card (legacy carried)", cardID: "mi-77", server: { fields: { deckSourceID: "src_9", legacy: { kind: "k" } }, stamps: {} }, lostKept: keptMine },
  ];
}

async function buildMerge() {
  const path = join(REPO_ROOT, "schema/vectors/merge.json");
  const existing = JSON.parse(readFileSync(path, "utf8"));
  // WP1's seed cases are the file's first 45, kept in place and checked against the reference.
  const wp1 = existing.cases.slice(0, WP1_CASE_COUNT);
  const out = [];
  const finish = (entry) => {
    if (entry.op === "compact") {
      const { expect, ...rest } = entry;
      return { ...rest, expect: referenceCompact(entry.record, entry.type, entry.now) };
    }
    const { expect, expectLosses, ...rest } = entry;
    const result = referenceMerge(entry.server, entry.local, entry.base, entry.type, entry.mintedAgainst);
    const merged = { ...result.merged };
    if (result.needsTextMerge.length) merged.needsTextMerge = result.needsTextMerge;
    const finished = { ...rest, expect: merged };
    if (result.losses.length) finished.expectLosses = result.losses;
    return finished;
  };
  for (const entry of wp1) {
    // WP1's compaction cases named no type; their fields are Source.files and Artifact.sourceIDs.
    const typed = entry.op === "compact" && !entry.type
      ? { ...entry, type: entry.record.stamps.sourceIDs ? "Artifact" : "Source" }
      : entry;
    const finished = finish(typed);
    if (!deepEqual(finished.expect, entry.expect)) {
      throw new Error(`a WP1 case would change meaning: ${entry.name}\n${stable(finished.expect)}\n${stable(entry.expect)}`);
    }
    out.push(finished);
  }
  for (const entry of mergeCases()) out.push(finish(entry));
  for (const entry of compactCases()) out.push(finish(entry));
  for (const entry of randomCases(70, 20261002)) out.push(finish(entry));
  for (const entry of await splitCases()) {
    out.push({ ...entry, expect: await referenceSplitKeptCard(entry.cardID, entry.server, entry.lostKept) });
  }
  const file = {
    vectors: "merge",
    version: 1,
    spec: existing.spec,
    implementations: existing.implementations,
    compactionHorizonDays: schema.limits.removalMarkerCompactionDays,
    format:
      "Cases without op: merge(server, local, base) = expect. server, local and base hold only the envelope parts the merge reads (fields, stamps; base null for a create); any other top-level key is an unknown key that must survive from the server, and the local side's are not carried. expect is the merged envelope; needsTextMerge lists the T fields that need the three-way text merge (absent when none). expectLosses lists, in field order, the S fields and S elements (element names the key) where a local value different from the server's lost because the server had moved them since the base, with the type's onServerFirstLoss hook when it declares one (type names the record type for that lookup); absent means none. The policy letter is the server stamp's first character (a T stamp on a map element merges like S, with no text merge). mintedAgainst, when present, lists ({field, element?, stamp}) the local paths whose stamps this device minted and pinned, each with the stamp it was minted against (the version of that field or element the writer saw, §6.3); a path it does not list has no provenance, and an entry naming a map or set field without an element gives none of its elements provenance. For each field the local side stamped: skip it when its stamp equals the base's or the server's (the local side then holds the server's own write); take the local value and stamp when the server has none; a scalar stamp on one side and per-key stamps on the other keep the server's field. L: when exactly one side's value is one of the field's terminalValues in the schema of type (Card.status retired), that side's value and stamp win whatever the stamps; otherwise the local value wins when the local stamp is later, or when the path's mintedAgainst stamp equals both the server's stamp and the base's (the writer edited exactly the version the server still holds). Every path without that provenance goes by stamp order: a stub edit forwarded verbatim, pending fields re-applied to a moved copy, a reconciling Mac's pending changes, late-import patches. S and T: the local value wins only when the server's stamp equals the base's; otherwise S keeps the server's (a loss when the values differ) and T keeps the server's and lists the field in needsTextMerge. X and N: the larger or smaller value, the server's on a tie or when the two do not compare, under the later of the two stamps. Stamps order by the 27 characters after the letter, as plain strings, never clamped (§6.3 as corrected by WP2: a clamp with its tie broken by those characters is the same order). Map and set fields carry one stamp per key and merge per key by the same rules. X and N compare numbers, arrays of numbers lexicographically (a prefix first), and objects by their ord array (the winning object is taken whole); anything else does not compare. Cases with op compact: the next writer of record drops every removal marker whose stamp's milliseconds are more than compactionHorizonDays before now; type names the record type whose schema says which fields are maps (marker: a null value) and sets (marker: false); scalars, fields the schema does not list and types it does not know are never compacted. Cases with op splitKeptCard: the Card.kept hook for the card cardID given the server's card and the lost Keep = expect, the new card ({type, id, fields}) or null: null when the lost Keep has no fingerprint, has the server Keep's fingerprint or equals it; else id card:<deckSourceID>:<seedKey> with seedKey split:<cardID>:<the first 16 hex characters of sha256 of the lost fingerprint>, fields status kept, deckSourceID, seedKey, kept (the lost Keep), splitFrom (cardID), keptAt (the lost Keep's at, when present) and the server's origin, madeBy, draftedAt and legacy when present.",
    status: "WP1's seed cases first (each re-checked against the reference), then WP2's: every policy against every situation, X and N value domains, maps, sets, far-future stamps and provenance (mintedAgainst) for every path that copies or re-applies stamps, terminal values, unknown fields, lost first writes with their hooks, idempotence, type-aware compaction, the splitKeptCard output, and 70 seeded random cases. Built by scripts/schema/build-vectors.mjs, whose reference merge is independent of both sync cores; regenerate with it, never by hand.",
    cases: out,
  };
  return { path, text: renderVectorFile(file) };
}

// MARK: - Reference placement (§4.4, the schema's home rules)

function holding(replica, type, id) {
  return Object.keys(replica).filter((zone) => replica[zone]?.[type]?.[id] !== undefined);
}

function preferredZone(zones, library) {
  if (library.startsWith("Space-") && zones.includes(library)) return library;
  const personal = zones.find((zone) => zone === "Library" || zone === "Catalog");
  if (personal) return personal;
  return zones.filter((zone) => zone.startsWith("Space-")).sort()[0];
}

const currentZone = (privateZone, library) => (library.startsWith("Space-") ? library : privateZone);

function unknownParentZone(parent, library) {
  const home = schema.types[parent].home;
  if (home.rule === "library") return "Library";
  if (home.rule === "current") return currentZone(home.privateZone, library);
  if (home.rule === "parent" && home.parent) return unknownParentZone(home.parent, library);
  return currentZone("Library", library);
}

function redirectsOf(replica, zone, id) {
  return replica[zone]?.Notebook?.[id];
}

function resolveNotebook(replica, zone, id) {
  let current = { zone, id };
  const seen = new Set([`${zone}\n${id}`]);
  for (let hop = 0; hop < schema.limits.redirectMaxHops; hop++) {
    const links = redirectsOf(replica, current.zone, current.id);
    if (!links) break;
    let next;
    if (links.mergedInto) next = { zone: current.zone, id: links.mergedInto };
    else if (links.movedTo) next = { zone: `Space-${links.movedTo}`, id: current.id };
    else break;
    if (!redirectsOf(replica, next.zone, next.id) || seen.has(`${next.zone}\n${next.id}`)) break;
    seen.add(`${next.zone}\n${next.id}`);
    current = next;
  }
  return current;
}

function parentZone(parent, id, library, replica) {
  if (typeof id !== "string" || id === "") return unknownParentZone(parent, library);
  if (schema.types[parent].privateOnly) return "Library";
  const held = preferredZone(holding(replica, parent, id), library);
  if (!held) return unknownParentZone(parent, library);
  if (parent !== "Notebook") return held;
  const resolved = resolveNotebook(replica, held, id);
  const moving = redirectsOf(replica, resolved.zone, resolved.id)?.movingTo;
  if (moving && redirectsOf(replica, `Space-${moving}`, resolved.id)) return `Space-${moving}`;
  return resolved.zone;
}

export function referencePlacement({ type, id, fields, writtenIn, replica }) {
  const spec = schema.types[type];
  const home = spec.home;
  if (spec.spaceRule && !spec.spaceRule.allowed.includes(fields[spec.spaceRule.field])) return "Library";
  if ((home.personalIDPrefixes ?? []).some((prefix) => id.startsWith(prefix))) return "Library";
  if (home.primaryOfSpace) {
    const space = Object.keys(replica).find((zone) => {
      const root = replica[zone]?.ZoneRoot?.root;
      return zone.startsWith("Space-") && root?.kind === home.primaryOfSpace && root?.primaryID === id;
    });
    if (space) return space;
  }
  switch (home.rule) {
    case "library": return "Library";
    case "current": return currentZone(home.privateZone, writtenIn);
    case "parent": {
      const parent = home.kindField ? home.parents[fields[home.kindField]] : home.parent;
      if (!parent) return currentZone("Library", writtenIn);
      return parentZone(parent, fields[home.field], writtenIn, replica);
    }
    case "owner": {
      if (schema.personalSatelliteRoles.includes(fields[home.roleField])) return home.privateZone;
      const ownerType = fields[home.typeField];
      if (!schema.types[ownerType]) return currentZone(home.privateZone, writtenIn);
      const zone = parentZone(ownerType, fields[home.field], writtenIn, replica);
      return zone.startsWith("Space-") ? zone : home.privateZone;
    }
  }
  throw new Error(`no rule for ${type}`);
}

function placementCases() {
  const nb = (links = {}) => links;
  const cases = [];
  const add = (name, type, id, fields, writtenIn, replica) => cases.push({ name, type, id, fields, writtenIn, replica });
  const personal = { Library: { Notebook: { nb1: nb() } }, Catalog: { Source: { src_1: {} } } };
  for (const type of ["Device", "Goal", "Mark", "ReadingState", "Card", "Sitting", "Job"]) {
    add(`${type} is priv-only: always Library, even written in a space`, type, `${type.toLowerCase()}-1`, {}, "Space-s1", personal);
  }
  add("ZoneRoot of the personal library", "ZoneRoot", "root", { kind: "personal" }, "Library", personal);
  add("ZoneRoot of a space", "ZoneRoot", "root", { kind: "team" }, "Space-s1", personal);
  add("Setting with account scope", "Setting", "chat.defaultModel", {}, "Library", personal);
  add("Setting with space scope", "Setting", "chat.defaultModel", {}, "Space-s1", personal);
  add("Source in the personal library: Catalog", "Source", "src_1", {}, "Library", personal);
  add("Source copied into a space: the space", "Source", "src_1", {}, "Space-s1", personal);
  add("Collection in the personal library: Catalog", "Collection", "col_1", {}, "Library", personal);
  add("Notebook in the personal library", "Notebook", "nb9", {}, "Library", personal);
  add("Notebook created in a space", "Notebook", "nb9", {}, "Space-s1", personal);
  const entry = (containerKind, containerID) => ({ containerKind, containerID, itemKind: "source", itemID: "src_1" });
  add("Entry of a notebook in Library", "Entry", "en:nb1:source:src_1", entry("notebook", "nb1"), "Library", personal);
  const moved = { Library: { Notebook: { nb1: nb({ movedTo: "s1" }) } }, "Space-s1": { Notebook: { nb1: nb() } } };
  add("Entry of a notebook moved into a space: the space (resolved through the stub)", "Entry", "en:nb1:source:src_1", entry("notebook", "nb1"), "Library", moved);
  add("Entry of a moved notebook whose space copy has not arrived: Library, where the move's catch-up finds it", "Entry", "en:nb1:source:src_1", entry("notebook", "nb1"), "Library", { Library: { Notebook: { nb1: nb({ movedTo: "s1" }) } } });
  add("Entry of a merged notebook: the survivor's zone", "Entry", "en:nb1:source:src_1", entry("notebook", "nb1"), "Library", { Library: { Notebook: { nb1: nb({ mergedInto: "nb2" }), nb2: nb() } } });
  add("Entry of a notebook merged into one that then moved: the space", "Entry", "en:nb1:source:src_1", entry("notebook", "nb1"), "Library", { Library: { Notebook: { nb1: nb({ mergedInto: "nb2" }), nb2: nb({ movedTo: "s2" }) } }, "Space-s2": { Notebook: { nb2: nb() } } });
  add("Entry of a notebook still moving, its space copy held: the space", "Entry", "en:nb1:source:src_1", entry("notebook", "nb1"), "Library", { Library: { Notebook: { nb1: nb({ movingTo: "s1" }) } }, "Space-s1": { Notebook: { nb1: nb() } } });
  add("Entry of a notebook still moving, its space copy not held: Library", "Entry", "en:nb1:source:src_1", entry("notebook", "nb1"), "Library", { Library: { Notebook: { nb1: nb({ movingTo: "s1" }) } } });
  add("Entry of a notebook the client does not hold, written in the personal library", "Entry", "en:nbX:source:src_1", entry("notebook", "nbX"), "Library", personal);
  add("Entry of a notebook the client does not hold, written in a space", "Entry", "en:nbX:source:src_1", entry("notebook", "nbX"), "Space-s1", personal);
  add("Entry of a space notebook written from the personal library: the space", "Entry", "en:nb7:source:src_1", entry("notebook", "nb7"), "Library", { "Space-t1": { Notebook: { nb7: nb() } } });
  add("Entry of a Goal: Library, even written in a space", "Entry", "en:gl1:source:src_1", entry("goal", "gl1"), "Space-s1", personal);
  add("Entry of a lesson held in a space", "Entry", "en:les1:source:src_1", entry("lesson", "les1"), "Library", { "Space-s1": { Lesson: { les1: {} } } });
  add("Entry of a lesson the client does not hold: where a new lesson would go", "Entry", "en:les1:source:src_1", entry("lesson", "les1"), "Library", personal);
  add("Entry of a playlist in the personal library: Catalog", "Entry", "en:PL1:source:src_1", entry("playlist", "PL1"), "Library", { Catalog: { Collection: { PL1: {} } } });
  add("Entry of a playlist the client does not hold: Catalog", "Entry", "en:PL1:source:src_1", entry("playlist", "PL1"), "Library", personal);
  add("Entry of a playlist copied into a space, written there", "Entry", "en:PL1:source:src_1", entry("playlist", "PL1"), "Space-s1", { Catalog: { Collection: { PL1: {} } }, "Space-s1": { Collection: { PL1: {} } } });
  add("Entry of a container kind this build does not know: the library it is written in", "Entry", "en:x:source:src_1", { containerKind: "shelf", containerID: "x" }, "Library", personal);
  add("Course naming a space notebook in its retired notebookID stays in the library it is written in (a course lives in no notebook)", "Course", "crs1", { notebookID: "nb7" }, "Library", { "Space-t1": { Notebook: { nb7: nb() } } });
  add("Course in the personal library", "Course", "crs1", {}, "Library", personal);
  add("Course written in a space is that space's own", "Course", "crs1", {}, "Space-t1", personal);
  add("Lesson of a course held in a space", "Lesson", "les1", { courseID: "crs1" }, "Library", { "Space-t1": { Course: { crs1: {} } } });
  add("Quiz of a course held in Library", "Quiz", "cq-1", { courseID: "crs1" }, "Library", { Library: { Course: { crs1: {} } } });
  add("Quiz of a course mid-move (held in Library and the space), written in the space", "Quiz", "cq-1", { courseID: "crs1" }, "Space-t1", { Library: { Course: { crs1: {} } }, "Space-t1": { Course: { crs1: {} } } });
  add("Quiz of a course mid-move, written in the personal library: Library", "Quiz", "cq-1", { courseID: "crs1" }, "Library", { Library: { Course: { crs1: {} } }, "Space-t1": { Course: { crs1: {} } } });
  add("Chat of kind chat filed in a space notebook: the space", "Chat", "cht1", { kind: "chat", notebookID: "nb7" }, "Library", { "Space-t1": { Notebook: { nb7: nb() } } });
  add("Chat of a private kind filed in a space notebook: Library (D19)", "Chat", "cht1", { kind: "review", notebookID: "nb7" }, "Library", { "Space-t1": { Notebook: { nb7: nb() } } });
  add("Chat of a transcript kind written in a space with no notebook", "Chat", "cht1", { kind: "transcript" }, "Space-t1", personal);
  add("Chat without a kind is kept private", "Chat", "cht1", { notebookID: "nb7" }, "Library", { "Space-t1": { Notebook: { nb7: nb() } } });
  add("Exchange of a chat held in a space", "Exchange", "e1", { chatID: "cht1" }, "Library", { "Space-t1": { Chat: { cht1: {} } } });
  add("Exchange of a chat the client does not hold, written in the personal library", "Exchange", "e1", { chatID: "cht9" }, "Library", personal);
  add("Artifact filed in a space notebook", "Artifact", "art1", { notebookID: "nb7" }, "Library", { "Space-t1": { Notebook: { nb7: nb() } } });
  add("Artifact that is a member's draft of a space Doc: Library", "Artifact", "draft:art1", { notebookID: "nb7" }, "Space-t1", { "Space-t1": { Notebook: { nb7: nb() } } });
  add("Artifact a Doc space was made for: that space, though its notebook is the owner's own (D5)", "Artifact", "art2", { notebookID: "nb1" }, "Library", { Library: { Notebook: { nb1: nb() } }, "Space-d1": { ZoneRoot: { root: { kind: "doc", primaryID: "art2" } }, Artifact: { art2: {} } } });
  add("Artifact named by a notebook space's primaryID is placed by its notebook", "Artifact", "art2", { notebookID: "nb1" }, "Library", { Library: { Notebook: { nb1: nb() } }, "Space-n1": { ZoneRoot: { root: { kind: "notebook", primaryID: "art2" } } } });
  add("Artifact with no notebook written in a space", "Artifact", "art3", {}, "Space-t1", personal);
  add("Comment on a Doc in a Doc space", "Comment", "c1", { artifactID: "art2" }, "Library", { "Space-d1": { Artifact: { art2: {} } } });
  add("Comment on a Doc the client does not hold, written in the personal library", "Comment", "c1", { artifactID: "art9" }, "Library", personal);
  add("Task of a space notebook", "Task", "t1", { notebookID: "nb7" }, "Library", { "Space-t1": { Notebook: { nb7: nb() } } });
  add("Task with no notebook written in a space", "Task", "t1", {}, "Space-t1", personal);
  add("Task with no notebook in the personal library", "Task", "t1", {}, "Library", personal);
  const content = (ownerType, ownerID, role) => ({ ownerType, ownerID, role });
  add("Content of a personal source: private Content", "Content", "ct:src_1:pdf:00", content("Source", "src_1", "pdf"), "Library", personal);
  add("Content of a space's copy of a source, written in the space: the space", "Content", "ct:src_1:pdf:00", content("Source", "src_1", "pdf"), "Space-s1", { Catalog: { Source: { src_1: {} } }, "Space-s1": { Source: { src_1: {} } } });
  add("Content of a Doc in a space: the space", "Content", "ct:art1:body:00", content("Artifact", "art1", "body"), "Library", { "Space-t1": { Artifact: { art1: {} } } });
  add("Content with a personal role is private Content, even for a space owner", "Content", "ct:art1:draftBase:00", content("Artifact", "art1", "draftBase"), "Space-t1", { "Space-t1": { Artifact: { art1: {} } } });
  add("Content of the personal root (the learner model): private Content", "Content", "ct:root:learnerModel:00", content("ZoneRoot", "root", "learnerModel"), "Library", { Library: { ZoneRoot: { root: { kind: "personal" } } } });
  add("Content of a spilled field of a space notebook", "Content", "ct:nb7:field.instructions:00", content("Notebook", "nb7", "field.instructions"), "Library", { "Space-t1": { Notebook: { nb7: nb() } } });
  add("Content whose owner type this build does not know, in the personal library", "Content", "ct:x:y:00", content("FutureType", "x", "y"), "Library", personal);
  add("Content whose owner the client does not hold, written in a space", "Content", "ct:art9:body:00", content("Artifact", "art9", "body"), "Space-t1", personal);
  return cases.map((entry) => ({ ...entry, expect: referencePlacement(entry) }));
}

function buildPlacement() {
  const file = {
    vectors: "placement",
    version: 1,
    spec: "docs/cloudkit-schema-design.md §4.4 (zoneFor), §2.2, §3.5 (each type's zones)",
    implementations: { swift: "ForeverLMApp/Shared/Sync/Core/ZonePlacement.swift", js: "schema/js/placement.js" },
    format:
      "Each case: zoneFor(type, id, fields) for a record written in writtenIn (Library for the personal library, or Space-<spaceID>) = expect, a zone name. replica is what the client holds: zone name → record type → id → the record's fields as placement reads them (a Notebook's redirect fields mergedInto, movedTo and movingTo; a ZoneRoot's kind and primaryID; {} otherwise). Each type's rule is its home in schema/cloudkit-schema.json (homeRules). In order: a type with a spaceRule whose field value is not allowed (or absent) is Library; an id starting with one of home.personalIDPrefixes is Library; a record whose id is the primaryID of a held space root of kind home.primaryOfSpace is that space. Then by rule: library → Library; current → writtenIn when it is a space, else privateZone; parent → the zone of the parent named by fields[field] (its type is parent, or parents[fields[kindField]]; an unknown kind gives the current rule with Library): a priv-only parent type is Library; otherwise the zones holding that parent id are taken in the order writtenIn (when a space), then Library or Catalog, then the first space by name; a Notebook parent is then resolved from there (resolve.json) and, when the notebook it reaches shows movingTo S and the replica holds the same id in Space-S, it is Space-S; a parent not held, or an empty field, gives the zone a new record of the parent type would get (its own home applied with nothing known); owner → privateZone for a personal role (fields[roleField]); the owner type fields[typeField] unknown → the current rule with privateZone; else the owner's zone by the parent rule, kept when it is a space, privateZone otherwise.",
    status: "Written with WP2 from the home rules; built by scripts/schema/build-vectors.mjs, whose reference placement is independent of both sync cores.",
    cases: placementCases(),
  };
  return { path: join(REPO_ROOT, "schema/vectors/placement.json"), text: renderVectorFile(file) };
}

// MARK: - Reference stamp clock (§6.3)

const EARLIER_MILLISECONDS = 64;
const MAX_MS = 9999999999999;

/// The counters a clock remembers below its last stamp: keys below lastMilliseconds (and not
/// negative), at most the 64 latest.
function keptEarlier(earlier, lastMilliseconds) {
  const kept = [...earlier.entries()].filter(([ms]) => ms >= 0 && ms < lastMilliseconds).sort((a, b) => a[0] - b[0]);
  return new Map(kept.slice(Math.max(0, kept.length - EARLIER_MILLISECONDS)));
}

const earlierJSON = (earlier) => Object.fromEntries([...earlier.entries()].sort((a, b) => a[0] - b[0]).map(([ms, counter]) => [String(ms), counter]));

export function referenceMint({ deviceID, samples, lastMilliseconds, lastCounter, earlierCounters = {}, policy, eventTime, seen, now }) {
  let earlier = keptEarlier(new Map(Object.entries(earlierCounters).map(([ms, counter]) => [Number(ms), counter])), lastMilliseconds);
  const kept = samples.slice(-20);
  if (kept.length === 0) return { stamp: null, lastMilliseconds, lastCounter, earlierCounters: earlierJSON(earlier) };
  const sorted = [...kept].sort((a, b) => a - b);
  const offset = sorted[Math.floor((sorted.length - 1) / 2)];
  let ms = eventTime + offset;
  if (seen) ms = Math.max(ms, Math.min(Number(seen.slice(1, 14)), now + offset + schema.limits.receivedStampFutureClampMs) + 1);
  ms = Math.min(Math.max(ms, 0), MAX_MS);
  const next = (at) => (at === lastMilliseconds ? lastCounter + 1 : earlier.has(at) ? earlier.get(at) + 1 : 0);
  let counter = next(ms);
  while (counter > 9999 && ms < MAX_MS) {
    ms += 1;
    counter = next(ms);
  }
  counter = Math.min(counter, 9999);
  if (ms > lastMilliseconds) {
    if (lastMilliseconds >= 0) earlier.set(lastMilliseconds, lastCounter);
    lastMilliseconds = ms;
    lastCounter = counter;
  } else if (ms === lastMilliseconds) {
    lastCounter = counter;
  } else {
    earlier.set(ms, counter);
  }
  earlier = keptEarlier(earlier, lastMilliseconds);
  const stamp = `${policy}${String(ms).padStart(13, "0")}.${String(counter).padStart(4, "0")}.${deviceID}`;
  return { stamp, lastMilliseconds, lastCounter, earlierCounters: earlierJSON(earlier) };
}

function stampCases() {
  const device = "k3f7ab2q";
  const now = 1759400000000;
  const cases = [];
  const offset = (name, samples) => {
    const kept = samples.slice(-20);
    const sorted = [...kept].sort((a, b) => a - b);
    cases.push({ op: "offset", name, samples, expect: kept.length ? sorted[Math.floor((kept.length - 1) / 2)] : null });
  };
  offset("no server time seen yet: no offset", []);
  offset("one sample", [1200]);
  offset("an odd count: the median", [30, -10, 5000]);
  offset("an even count: the lower middle sample", [40, 10, 30, 20]);
  offset("only the last 20 samples count", [9e6, 9e6, 9e6, 9e6, 9e6, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]);
  offset("negative offsets", [-500, -300, -400]);
  const mint = (name, input) => {
    const state = { deviceID: device, samples: [250], lastMilliseconds: -1, lastCounter: 0, earlierCounters: {}, policy: "L", eventTime: now, seen: null, now, ...input };
    const result = referenceMint(state);
    cases.push({ op: "mint", name, ...state, expect: result.stamp,
      expectLast: { lastMilliseconds: result.lastMilliseconds, lastCounter: result.lastCounter, earlierCounters: result.earlierCounters } });
  };
  mint("no offset yet: nothing is minted", { samples: [] });
  mint("event time plus the server offset", {});
  mint("the policy letter is the field's", { policy: "X" });
  mint("an edit after seeing an older stamp keeps its own time", { seen: `L${String(now - 9000).padStart(13, "0")}.0003.bbbbbbbb` });
  mint("an edit made after seeing a later stamp is stamped one millisecond past it", { seen: `L${String(now + 5000).padStart(13, "0")}.0000.bbbbbbbb` });
  mint("a column changed earlier keeps its own event time (per-column time)", { eventTime: now - 60000 });
  mint("an edit after seeing a far-future stamp is stamped one millisecond past now + 1 day, never past it", { seen: `L${String(now + 40 * DAY).padStart(13, "0")}.0000.ffffffff` });
  mint("a seen stamp exactly at now + 1 day is passed by one millisecond", { seen: `L${String(now + 250 + DAY).padStart(13, "0")}.0000.ffffffff` });
  mint("the same millisecond as the last stamp: the counter moves on", { lastMilliseconds: now + 250, lastCounter: 4 });
  mint("the counter at 9999: the next millisecond, counter 0", { lastMilliseconds: now + 250, lastCounter: 9999 });
  mint("an event older than the last stamp: counter 0, the clock's last stamp unchanged, that millisecond's counter remembered", { lastMilliseconds: now + 9000, lastCounter: 2, eventTime: now - 1000 });
  mint("a second event in the same older millisecond takes the next counter, never the same stamp twice", { lastMilliseconds: now + 9000, lastCounter: 2, earlierCounters: { [String(now - 750)]: 0 }, eventTime: now - 1000 });
  mint("moving past the last stamp keeps its counter for that millisecond", { lastMilliseconds: now + 250, lastCounter: 3, eventTime: now + 750 });
  mint("an older event in a millisecond that was once the last stamp's takes the next counter after it", { lastMilliseconds: now + 1000, lastCounter: 0, earlierCounters: { [String(now + 250)]: 3 } });
  mint("an older millisecond at counter 9999: the next millisecond, after its own counters", { lastMilliseconds: now + 9000, lastCounter: 0, earlierCounters: { [String(now + 250)]: 9999, [String(now + 251)]: 4 } });
  mint("the clock remembers the 64 latest earlier milliseconds and forgets the oldest",
    { lastMilliseconds: now + 9000, lastCounter: 0, earlierCounters: Object.fromEntries(Array.from({ length: 64 }, (_, index) => [String(now + 1000 + index), 1])), eventTime: now + 2000 });
  mint("an earlier millisecond the clock no longer remembers starts at counter 0",
    { lastMilliseconds: now + 9000, lastCounter: 0, earlierCounters: { [String(now + 5000)]: 7 }, eventTime: now - 60000 });
  mint("counters saved at or above the last stamp are not kept", { lastMilliseconds: now + 9000, lastCounter: 1, earlierCounters: { [String(now + 9000)]: 5, [String(now + 9500)]: 2 }, eventTime: now + 100 });
  mint("a negative server offset", { samples: [-2000, -1800, -2200] });
  mint("a large offset (over two minutes) still stamps in server time", { samples: [3600000] });
  mint("the provisional stamp is never seen as later (milliseconds 1)", { seen: "L0000000000001.0000.bbbbbbbb" });
  return cases;
}

function buildStampClock() {
  const file = {
    vectors: "stamp-clock",
    version: 1,
    spec: "docs/cloudkit-schema-design.md §6.3 (Clocks and stamps), D9",
    implementations: { swift: "ForeverLMApp/Shared/Sync/Core/StampClock.swift", js: "schema/js/stamp.js" },
    format:
      "op offset: the server offset from samples (server − local milliseconds, recorded oldest first) = expect: of the last 20 samples, sorted ascending, the one at index (count − 1) / 2 rounded down (the lower middle for an even count); null with no sample. op mint: a clock for deviceID holding samples and its last issued stamp (lastMilliseconds, lastCounter; lastMilliseconds −1 before the first) mints the stamp of a change made at local time eventTime, to a field whose replica stamp is seen (or null), at local time now = expect (null when there is no offset yet), and expectLast is the clock's state afterwards (its last issued stamp and earlierCounters). earlierCounters (milliseconds as a decimal string → the last counter issued in that millisecond) are the counters the clock remembers below lastMilliseconds: only keys below lastMilliseconds and not negative, at most the 64 latest (the smallest go first), both as given and after a mint. milliseconds = max(eventTime + offset, min(seen's milliseconds, now + offset + 86400000) + 1), at least 0 and at most 9999999999999; counter = lastCounter + 1 when the milliseconds equal lastMilliseconds, else earlierCounters[milliseconds] + 1 when remembered, else 0; past 9999 the next millisecond, whose counter follows the same rule. Afterwards: milliseconds above lastMilliseconds make them the last stamp (the previous last stamp's counter, when there was one, joins earlierCounters); equal ones move lastCounter; lower ones are remembered in earlierCounters.",
    status: "Written with WP2; built by scripts/schema/build-vectors.mjs from its reference clock.",
    cases: stampCases(),
  };
  return { path: join(REPO_ROOT, "schema/vectors/stamp-clock.json"), text: renderVectorFile(file) };
}

// MARK: - Reference chat kinds (D50, §10)

export function referenceChatKind(evidence) {
  const { id, kind = null } = evidence;
  if (evidence.isTeamSnapshot) return "transcript";
  if (kind === "memory" || id.startsWith("memory-") || id.startsWith("mcp-memory-review-")) return "memory";
  if (id.startsWith("course-quiz-")) return "quizSitting";
  if (id.includes("-live-")) return "voice";
  if (evidence.isNamedByWalkthroughProgress || evidence.holdsWalkthroughStep) return "walkthrough";
  if (kind === "review" || evidence.hasOverallScore || evidence.hasCardIDs || evidence.hasGradedExchange) return "review";
  return "chat";
}

function chatKindCases() {
  const uuid = "6F1C0E8A-0B8D-4D5C-9F5E-3F0E1C2B9A77";
  const cases = [];
  const add = (name, evidence) => cases.push({ name, evidence, expect: referenceChatKind(evidence) });
  add("a chat recorded before kinds, with nothing else to tell: chat", { id: uuid });
  add("generation-1 kind chat stays chat", { id: uuid, kind: "chat" });
  add("generation-1 kind review is review", { id: uuid, kind: "review" });
  add("generation-1 kind memory is memory", { id: uuid, kind: "memory" });
  add("production shape: a NULL-kind ios-live- session is voice", { id: `ios-live-${uuid}` });
  add("production shape: a mac-live- session is voice", { id: `mac-live-${uuid}` });
  add("production shape: a carplay-live- session is voice", { id: `carplay-live-${uuid}` });
  add("production shape: a course-quiz- sitting is quizSitting", { id: `course-quiz-cq-0123456789abcdef0123456789abcdef-${uuid}` });
  add("production shape: a walkthrough chat named by a walk's progress", { id: uuid, isNamedByWalkthroughProgress: true });
  add("production shape: a walkthrough chat holding a step line", { id: uuid, holdsWalkthroughStep: true });
  add("production shape: a scored review recorded before kinds", { id: uuid, hasOverallScore: true });
  add("production shape: an mcp-memory-review-operation- chat is memory", { id: `mcp-memory-review-operation-${uuid}` });
  add("production shape: an mcp-memory-review- daily review is memory", { id: `mcp-memory-review-${uuid}` });
  add("production shape: a memory- review is memory", { id: `memory-${uuid}` });
  add("production shape: a team snapshot is a transcript, scores already stripped", { id: `teamchat-${"ab".repeat(32)}`, kind: "chat", isTeamSnapshot: true });
  add("a chat holding card ids is a review", { id: uuid, hasCardIDs: true });
  add("a chat with a graded exchange (a score or an idea coverage) is a review", { id: uuid, hasGradedExchange: true });
  add("rule order: a team snapshot of a memory review is still a transcript", { id: `memory-${uuid}`, kind: "memory", isTeamSnapshot: true });
  add("rule order: a team snapshot that held a step line is still a transcript", { id: `teamchat-${"cd".repeat(32)}`, isTeamSnapshot: true, holdsWalkthroughStep: true });
  add("rule order: memory before a live id (memory- prefix wins over -live-)", { id: `memory-live-${uuid}` });
  add("rule order: memory before a quiz (kind memory on a course-quiz- id)", { id: `course-quiz-${uuid}`, kind: "memory" });
  add("rule order: a course-quiz- sitting with a score is quizSitting, not review", { id: `course-quiz-${uuid}`, hasOverallScore: true, hasGradedExchange: true });
  add("rule order: a course-quiz- id containing -live- is quizSitting", { id: `course-quiz-live-${uuid}` });
  add("rule order: a live session that played a walkthrough step is voice", { id: `ios-live-${uuid}`, holdsWalkthroughStep: true });
  add("rule order: a walkthrough chat with a score is walkthrough, not review", { id: uuid, isNamedByWalkthroughProgress: true, hasOverallScore: true });
  add("rule order: kind review that holds a step line is walkthrough", { id: uuid, kind: "review", holdsWalkthroughStep: true });
  add("rule order: kind chat with a score is review (the first rule that holds decides)", { id: uuid, kind: "chat", hasOverallScore: true });
  add("ids are matched by their prefixes exactly: a memory word elsewhere is no memory id", { id: `chat-memory-${uuid}` });
  add("ids are matched exactly: live without the dashes on both sides is no voice id", { id: `delivery-${uuid}` });
  add("ids are matched exactly: an uppercase prefix is no quiz id", { id: `COURSE-QUIZ-${uuid}` });
  add("ids are matched exactly: memory without its dash is no memory id", { id: `memoryx-${uuid}` });
  add("a generation-1 kind this build does not know falls through the rules", { id: uuid, kind: "lecture" });
  return cases;
}

function buildChatKind() {
  const file = {
    vectors: "chat-kind",
    version: 1,
    spec: "docs/cloudkit-schema-design.md §10 (ReviewSession, kind), D50, D19",
    implementations: { swift: "ForeverLMApp/Shared/Sync/Core/ChatKindClassifier.swift", js: "schema/js/chat-kind.js" },
    format:
      "Each case: the kind of the chat described by evidence = expect, a ChatKind. evidence: id (review_sessions.id); kind (the generation-1 kind column: chat, review, memory, or absent before schema 89); isTeamSnapshot (team_id set); isNamedByWalkthroughProgress (a walk's progress_json.chat_session_id names it); holdsWalkthroughStep (an exchange carries a WalkthroughStepTurn step line); hasOverallScore; hasCardIDs; hasGradedExchange (an exchange with a score or an idea coverage); every flag absent means false. The first rule that holds: (1) isTeamSnapshot -> transcript; (2) kind memory, or the id starts memory- or mcp-memory-review- -> memory; (3) the id starts course-quiz- -> quizSitting; (4) the id contains -live- -> voice; (5) isNamedByWalkthroughProgress or holdsWalkthroughStep -> walkthrough; (6) kind review, hasOverallScore, hasCardIDs or hasGradedExchange -> review; (7) chat. Prefixes and markers match exactly (letter case included).",
    status: "Written with WP2 from the production chat shapes of §10; built by scripts/schema/build-vectors.mjs from its reference classifier.",
    cases: chatKindCases(),
  };
  return { path: join(REPO_ROOT, "schema/vectors/chat-kind.json"), text: renderVectorFile(file) };
}

// MARK: - Files

function renderVectorFile(file) {
  const headValue = (value) => (isObject(value)
    ? `{\n${Object.entries(value).map(([key, inner]) => `    ${JSON.stringify(key)}: ${JSON.stringify(inner)}`).join(",\n")}\n  }`
    : JSON.stringify(value));
  const head = Object.entries(file).filter(([key]) => key !== "cases").map(([key, value]) => `  ${JSON.stringify(key)}: ${headValue(value)}`);
  const cases = file.cases.map((entry) => `    ${caseLine(entry)}`).join(",\n");
  return `{\n${head.join(",\n")},\n  "cases": [\n${cases}\n  ]\n}\n`;
}

export async function buildVectors() {
  return [await buildMerge(), buildPlacement(), buildStampClock(), buildChatKind()];
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const check = process.argv.includes("--check");
  let stale = 0;
  for (const { path, text } of await buildVectors()) {
    let current = null;
    try { current = readFileSync(path, "utf8"); } catch { current = null; }
    if (current === text) continue;
    if (check) {
      console.error(`stale: ${path}`);
      stale++;
    } else {
      writeFileSync(path, text);
      console.log(`wrote ${path}`);
    }
  }
  if (check && stale) process.exit(1);
}
