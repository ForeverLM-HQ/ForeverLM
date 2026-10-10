// Zone names and the two redirect walks every client runs (docs/cloudkit-schema-design.md §2.2, §4.2,
// §5.2): the twin of Swift's NotebookResolution.swift and SourceResolution.swift. Vectors:
// schema/vectors/resolve.json.

import { LIMITS, SPACE_ZONE_PREFIX } from "./schema.generated.js";

export const LIBRARY_ZONE = "Library";
export const CATALOG_ZONE = "Catalog";
export const CONTENT_ZONE = "Content";

/**
 * Whether `name` is a zone: `Library`, `Catalog`, `Content` or `Space-<spaceID>`.
 * @param {unknown} name
 * @returns {name is string}
 */
export function isZoneName(name) {
  return name === LIBRARY_ZONE || name === CATALOG_ZONE || name === CONTENT_ZONE || isSpaceZone(name);
}

/** @param {unknown} name @returns {name is string} */
export function isSpaceZone(name) {
  return typeof name === "string" && name.startsWith(SPACE_ZONE_PREFIX) && name.length > SPACE_ZONE_PREFIX.length;
}

/** @param {string} spaceID */
export function spaceZone(spaceID) {
  return `${SPACE_ZONE_PREFIX}${spaceID}`;
}

/**
 * @typedef {{zone: string, id: string}} RecordLocation
 * @typedef {{mergedInto?: string | null, movedTo?: string | null, movingTo?: string | null}} NotebookRedirects
 */

/**
 * `resolveNotebook()` (§5.2): where a notebook id leads after merges, emptying splits and moves into
 * spaces, so a child that names a merged or moved notebook lands in the survivor or the space. From
 * `start`, up to 8 times: take the current notebook's `mergedInto` (same zone), else its `movedTo`
 * (same id in the space's zone); stop when there is none, when the next notebook is not held, or
 * when it was already visited. Returns the last notebook reached, or `start` itself when it is not
 * held. `movingTo` is never followed: the space copy may not exist yet (§4.4). `redirects` returns a
 * held notebook's redirect fields in that zone, or null when the client does not hold it there.
 * @param {RecordLocation} start
 * @param {(location: RecordLocation) => NotebookRedirects | null | undefined} redirects
 * @returns {RecordLocation}
 */
export function resolveNotebook(start, redirects) {
  let current = start;
  const visited = new Set([locationKey(start)]);
  for (let hop = 0; hop < LIMITS.redirectMaxHops; hop += 1) {
    const links = redirects(current);
    if (!links) break;
    let next;
    if (typeof links.mergedInto === "string" && links.mergedInto !== "") {
      next = { zone: current.zone, id: links.mergedInto };
    } else if (typeof links.movedTo === "string" && links.movedTo !== "") {
      next = { zone: spaceZone(links.movedTo), id: current.id };
    } else {
      break;
    }
    if (!redirects(next) || visited.has(locationKey(next))) break;
    visited.add(locationKey(next));
    current = next;
  }
  return current;
}

/**
 * `resolveSource()` (§4.2): a duplicate's loser keeps `mergedInto` for ever as a redirect to its
 * winner, and everything that names the loser and never changes (a highlight, a card's deck and
 * anchors, a sitting's answers, a reply's citations) is read through this walk. Follows `mergedInto`
 * within one zone up to 8 times, stopping at a source the client does not hold or one already
 * visited; an unknown start is returned as it is. `mergedInto(id)` is undefined for a source the
 * client does not hold, null for one with no redirect, else the id it redirects to.
 * @param {string} start
 * @param {(id: string) => string | null | undefined} mergedInto
 */
export function resolveSource(start, mergedInto) {
  let current = start;
  const visited = new Set([start]);
  for (let hop = 0; hop < LIMITS.redirectMaxHops; hop += 1) {
    const next = mergedInto(current);
    if (typeof next !== "string" || next === "" || mergedInto(next) === undefined || visited.has(next)) break;
    visited.add(next);
    current = next;
  }
  return current;
}

/** @param {RecordLocation} location */
function locationKey(location) {
  return `${location.zone}\u0000${location.id}`;
}
