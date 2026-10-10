// `zoneFor(type, home)` (docs/cloudkit-schema-design.md §4.4): the zone a record is written into,
// from its type's `home` in schema/cloudkit-schema.json (`TYPES[type].home`, documented in
// `homeRules`), so the Swift core (ZonePlacement.swift) and this one place every type by the same
// data. Placement always uses the resolved home: a child of a merged or moved notebook goes to the
// survivor's or the space's zone, and a child of a notebook still moving goes into the space only
// once the replica holds the notebook's copy there. Run before every send and every re-create.
// Vectors: schema/vectors/placement.json.

import { PERSONAL_SATELLITE_ROLES, TYPES } from "./schema.generated.js";
import { compareStrings, own } from "./json.js";
import { CATALOG_ZONE, LIBRARY_ZONE, isSpaceZone, resolveNotebook, spaceZone } from "./resolve.js";

/**
 * @typedef {object} PlacementReplica What a client's replica knows about where records are.
 * @property {(type: string, id: string) => string[]} zones Every zone where the client holds a
 *   record of `type` with logical id `id`.
 * @property {(location: {zone: string, id: string}) => import("./resolve.js").NotebookRedirects | null | undefined} notebookRedirects
 *   A notebook's redirect fields as that zone holds them; null when it is not held there.
 * @property {(kind: string, primaryID: string) => string | null | undefined} space The space whose root
 *   says it was made for record `primaryID` and is of `kind` (`ZoneRoot.primaryID`).
 */

/** @param {string} type */
function specOf(type) {
  if (!Object.hasOwn(TYPES, type)) throw new RangeError(`${type} is not a record type`);
  return TYPES[/** @type {keyof typeof TYPES} */ (type)];
}

/**
 * The zone for a record of `type` with id `id` and the field values it will be sent with, written
 * in `writtenIn`: `Library` for the personal library, or the `Space-<spaceID>` it is written in.
 * @param {string} type
 * @param {string} id
 * @param {Record<string, unknown>} fields
 * @param {string} writtenIn
 * @param {PlacementReplica} replica
 * @returns {string}
 */
export function zoneFor(type, id, fields, writtenIn, replica) {
  const spec = specOf(type);
  const home = /** @type {any} */ (spec.home);
  const rule = spec.spaceRule;
  if (rule) {
    const value = own(fields, rule.field);
    if (!rule.allowed.includes(typeof value === "string" ? value : "")) return LIBRARY_ZONE;
  }
  if ((home.personalIDPrefixes ?? []).some((/** @type {string} */ prefix) => id.startsWith(prefix))) return LIBRARY_ZONE;
  if (home.primaryOfSpace) {
    const space = replica.space(home.primaryOfSpace, id);
    if (space) return space;
  }
  switch (home.rule) {
    case "library":
      return LIBRARY_ZONE;
    case "current":
      return current(home.privateZone, writtenIn);
    case "parent": {
      if (home.parent) return parentZone(home.parent, stringField(fields, home.field), writtenIn, replica);
      const kind = own(fields, home.kindField);
      const parent = typeof kind === "string" ? own(home.parents, kind) : undefined;
      if (typeof parent !== "string") return current(LIBRARY_ZONE, writtenIn);
      return parentZone(parent, stringField(fields, home.field), writtenIn, replica);
    }
    case "owner": {
      const role = own(fields, home.roleField);
      if (typeof role === "string" && PERSONAL_SATELLITE_ROLES.includes(role)) return home.privateZone;
      const ownerType = own(fields, home.typeField);
      if (typeof ownerType !== "string" || !Object.hasOwn(TYPES, ownerType)) return current(home.privateZone, writtenIn);
      const ownerZone = parentZone(ownerType, stringField(fields, home.field), writtenIn, replica);
      return isSpaceZone(ownerZone) ? ownerZone : home.privateZone;
    }
    default:
      throw new RangeError(`${type} has no placement rule`);
  }
}

/** @param {Record<string, unknown>} fields @param {string} field */
function stringField(fields, field) {
  const value = own(fields, field);
  return typeof value === "string" ? value : undefined;
}

/**
 * The zone of the parent record `id` names: a notebook through `resolveNotebook`, any other parent
 * where the replica holds it (first in the library the record is written in, then the personal
 * library, then a space); with nothing known, where a new record of the parent's type written in
 * `writtenIn` would go.
 * @param {string} parent
 * @param {string | undefined} id
 * @param {string} writtenIn
 * @param {PlacementReplica} replica
 * @returns {string}
 */
function parentZone(parent, id, writtenIn, replica) {
  if (!id) return unknownParentZone(parent, writtenIn);
  if (specOf(parent).privateOnly) return LIBRARY_ZONE;
  const held = preferred(replica.zones(parent, id), writtenIn);
  if (!held) return unknownParentZone(parent, writtenIn);
  if (parent !== "Notebook") return held;
  const redirects = (/** @type {{zone: string, id: string}} */ location) => replica.notebookRedirects(location) ?? null;
  const resolved = resolveNotebook({ zone: held, id }, redirects);
  const movingTo = redirects(resolved)?.movingTo;
  if (typeof movingTo === "string" && movingTo !== "" && redirects({ zone: spaceZone(movingTo), id: resolved.id })) {
    return spaceZone(movingTo);
  }
  return resolved.zone;
}

/**
 * @param {string} parent
 * @param {string} writtenIn
 * @returns {string}
 */
function unknownParentZone(parent, writtenIn) {
  const home = /** @type {any} */ (specOf(parent).home);
  switch (home.rule) {
    case "library":
      return LIBRARY_ZONE;
    case "current":
      return current(home.privateZone, writtenIn);
    case "parent":
      return home.parent ? unknownParentZone(home.parent, writtenIn) : current(LIBRARY_ZONE, writtenIn);
    default:
      return current(LIBRARY_ZONE, writtenIn);
  }
}

/**
 * @param {string[]} zones
 * @param {string} writtenIn
 * @returns {string | undefined}
 */
function preferred(zones, writtenIn) {
  if (isSpaceZone(writtenIn) && zones.includes(writtenIn)) return writtenIn;
  const personal = zones.find((zone) => zone === LIBRARY_ZONE || zone === CATALOG_ZONE);
  if (personal) return personal;
  return zones.filter(isSpaceZone).sort(compareStrings)[0];
}

/** @param {string} privateZone @param {string} writtenIn */
function current(privateZone, writtenIn) {
  return isSpaceZone(writtenIn) ? writtenIn : privateZone;
}
