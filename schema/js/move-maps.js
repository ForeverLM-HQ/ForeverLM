// The `moveMaps` lookup (docs/cloudkit-schema-design.md §4.4, §6.2, D51): the twin of Swift's
// MoveMapIndex.swift, shared by the web's and the hosted MCP's writers. Every SpaceMoveJob pass, every
// re-homing pass and every reverse move writes one entry into the personal root's `ZoneRoot.moveMaps`,
// a FileRef to a gzip satellite (role `moveMap.<key>`) listing what that pass moved. A pending write
// that meets `unknownItem` or `zoneNotFound` asks this lookup whether its record was moved rather
// than deleted; if so, its fields, with their stamps, are applied to the copy in the zone the record
// lives in now (a space, or `Library` after a reverse move).
//
// The list's bytes are gzip of compact JSON, `{"v": 1, "moves": [{"type", "id", "from", "to", "at"}]}`:
// record type, logical id, the zone names it left and entered, and the epoch milliseconds the pass
// copied it. Entries are never rewritten; past 32 the maintenance Mac folds them into `folded.<n>`,
// whose list holds the same moves, so a lookup reads every entry the root names the same way.

import { compareStrings, isObject, own, parseJSON, serializeJSON, utf8Bytes, utf8Text } from "./json.js";
import { gzipCompress, gzipDecompress } from "./envelope.js";
import { isFileRef } from "./values.js";
import { isZoneName } from "./resolve.js";

export const MOVE_LIST_VERSION = 1;
/** The size a move list may inflate to when read: far above 32 folded entries of a large notebook. */
export const MOVE_LIST_MAX_INFLATED_BYTES = 16 * 1024 * 1024;

/** @typedef {{type: string, id: string, from: string, to: string, at: number}} Move */

export class MoveListError extends Error {
  /** @param {string} reason */
  constructor(reason) {
    super(`not a move list: ${reason}`);
    this.name = "MoveListError";
    this.reason = reason;
  }
}

/** The satellite role of the `moveMaps` entry `key` (`<moveJobID>.<pass>` or `folded.<n>`). @param {string} key */
export function moveMapRole(key) {
  return `moveMap.${key}`;
}

/**
 * The entries a personal root names, `{key, fileRef}` sorted by key; a key cleared by a fold (`null`)
 * names none.
 * @param {import("./envelope.js").Envelope} root
 * @returns {{key: string, fileRef: Record<string, unknown>}[]}
 */
export function moveMapEntries(root) {
  const entries = own(root?.fields, "moveMaps");
  if (!isObject(entries)) return [];
  return Object.keys(entries).sort(compareStrings)
    .filter((key) => isFileRef(entries[key]))
    .map((key) => ({ key, fileRef: entries[key] }));
}

/** @param {unknown} move @returns {move is Move} */
function isMove(move) {
  return typeof own(move, "type") === "string" && own(move, "type") !== ""
    && typeof own(move, "id") === "string" && own(move, "id") !== ""
    && isZoneName(own(move, "from")) && isZoneName(own(move, "to")) && own(move, "from") !== own(move, "to")
    && Number.isSafeInteger(own(move, "at")) && /** @type {number} */ (own(move, "at")) >= 0;
}

/**
 * A move list's stored bytes (gzip of compact JSON with sorted keys).
 * @param {Move[]} moves
 * @returns {Promise<Uint8Array>}
 */
export async function encodeMoveList(moves) {
  for (const move of moves) if (!isMove(move)) throw new MoveListError("a move needs type, id, two different zones and at");
  const list = moves.map(({ type, id, from, to, at }) => ({ type, id, from, to, at }));
  return gzipCompress(utf8Bytes(serializeJSON({ v: MOVE_LIST_VERSION, moves: list })));
}

/**
 * The moves a list's stored bytes hold. A list of another version, or one that is not a list, throws
 * MoveListError; a move this build cannot read inside a readable list is skipped, never guessed at.
 * @param {Uint8Array} stored
 * @returns {Move[]}
 */
export function decodeMoveList(stored) {
  let value;
  try {
    const text = utf8Text(gzipDecompress(stored, MOVE_LIST_MAX_INFLATED_BYTES));
    if (text === undefined) throw new MoveListError("not UTF-8");
    value = parseJSON(text);
  } catch (error) {
    throw error instanceof MoveListError ? error : new MoveListError("not gzip JSON");
  }
  if (!isObject(value)) throw new MoveListError("not an object");
  if (own(value, "v") !== MOVE_LIST_VERSION) throw new MoveListError(`version ${String(own(value, "v"))}`);
  const moves = own(value, "moves");
  if (!Array.isArray(moves)) throw new MoveListError("no moves");
  return moves.filter(isMove).map(({ type, id, from, to, at }) => ({ type, id, from, to, at }));
}

/** @param {string} type @param {string} id */
function recordKey(type, id) {
  return `${type}\u0000${id}`;
}

/**
 * Every move the root's entries list, by record. Two passes that moved one record (a move and its
 * reverse, or a re-homing) are ordered by `at`, then by entry key, then by place in the list.
 */
export class MoveMapIndex {
  /** @param {{key: string, moves: Move[]}[]} lists */
  constructor(lists = []) {
    /** @type {Map<string, (Move & {order: [string, number]})[]>} */
    this.byRecord = new Map();
    /** @type {Set<string>} */
    this.keys = new Set();
    for (const list of lists) this.add(list.key, list.moves);
  }

  /** @param {string} key @param {Move[]} moves */
  add(key, moves) {
    if (this.keys.has(key)) return;
    this.keys.add(key);
    moves.forEach((move, index) => {
      const record = recordKey(move.type, move.id);
      const held = this.byRecord.get(record) ?? [];
      held.push({ ...move, order: [key, index] });
      held.sort((a, b) => a.at - b.at || compareStrings(a.order[0], b.order[0]) || a.order[1] - b.order[1]);
      this.byRecord.set(record, held);
    });
  }

  /** @param {string} type @param {string} id @returns {Move[]} */
  moves(type, id) {
    return (this.byRecord.get(recordKey(type, id)) ?? []).map(({ type: t, id: i, from, to, at }) => ({ type: t, id: i, from, to, at }));
  }

  /**
   * Where a pending write aimed at record (`type`, `id`) in zone `zone` belongs now: the zone the
   * record's latest move took it to, when a move ever took it out of `zone` and the latest did not
   * bring it back there. Null when it never left `zone` (its absence there is a deletion, and the
   * delete wins, §6.2) or when it was moved back and is gone again.
   * @param {string} type
   * @param {string} id
   * @param {string} zone
   * @returns {string | null}
   */
  retarget(type, id, zone) {
    const moves = this.byRecord.get(recordKey(type, id)) ?? [];
    if (!moves.some((move) => move.from === zone)) return null;
    const latest = moves[moves.length - 1];
    return latest.to === zone ? null : latest.to;
  }

  /**
   * Whether a parent named by a late child counts as present (§4.4, §5.7): some move lists it.
   * @param {string} type
   * @param {string} id
   */
  moved(type, id) {
    return this.byRecord.has(recordKey(type, id));
  }
}
