// The rules for writing into a shared space (docs/cloudkit-schema-design.md §9.2, D18, D19, D20),
// checked before anything is queued: the twin of Swift's SpaceWriteGuard.swift. Nothing per member
// ever reaches a shared record, because the codec refuses it rather than strip it on the way out.
// Refused: priv-only types; member-local fields; private chat kinds; the fields only private chat
// kinds carry (`privateKindsOnly`: `Exchange.grading`, `Exchange.score`, `Chat.overallScore`), so a
// review misfiled as a chat never carries a score into a space; personal satellites; any write by a
// read-only participant; and a delete of a Notebook, Artifact, Course or Chat by a participant who
// is neither the space owner nor its `createdBy`. CloudKit enforces read-only itself; the delete
// rule is the clients' (CloudKit has no per-record permissions).

import { PERSONAL_SATELLITE_ROLES, TYPES } from "./schema.generated.js";
import { copyJSON, isObject, own, setOwn, sortedKeys } from "./json.js";
import { isFileRef, isPersonalFileRef, isPerson } from "./values.js";

/**
 * @typedef {{user: string, permission: "readOnly" | "readWrite", isOwner: boolean}} SpaceWriter
 * The participant writing, from the space's CKShare: the CloudKit user record name, the share
 * permission and whether they own the space.
 * @typedef {{code: "readOnlyParticipant" | "unknownType" | "privateOnlyType" | "privateKind" |
 *   "privateKindsOnlyField" | "memberLocalField" | "personalSatellite" | "deleteNotAllowed",
 *   type?: string, field?: string, value?: string, message: string}} SpaceRefusal
 */

const OWNED_DELETES = new Set(["Notebook", "Artifact", "Course", "Chat"]);

export class SpaceWriteRefused extends Error {
  /** @param {SpaceRefusal} refusal */
  constructor(refusal) {
    super(refusal.message);
    this.name = "SpaceWriteRefused";
    this.refusal = refusal;
  }
}

/**
 * Every refusal for writing a record of `type` that will hold `fields` (the held record with the
 * patch applied) into a space, in field order. `spec` is the type's schema; it is a parameter so a
 * test can show the guard refuses what the generator already keeps off shareable types.
 * @param {string} type
 * @param {Record<string, unknown>} fields
 * @param {SpaceWriter} writer
 * @param {any} [spec]
 * @returns {SpaceRefusal[]}
 */
export function refusalsForWrite(type, fields, writer, spec) {
  /** @type {SpaceRefusal[]} */
  const refusals = [];
  if (writer.permission === "readOnly") refusals.push(refusal("readOnlyParticipant", {}));
  const schema = spec ?? (Object.hasOwn(TYPES, type) ? TYPES[/** @type {keyof typeof TYPES} */ (type)] : undefined);
  if (!schema) return [...refusals, refusal("unknownType", { type })];
  if (schema.privateOnly) refusals.push(refusal("privateOnlyType", { type }));
  if (schema.spaceRule) {
    const raw = own(fields, schema.spaceRule.field);
    const value = typeof raw === "string" ? raw : "";
    if (!schema.spaceRule.allowed.includes(value)) refusals.push(refusal("privateKind", { type, field: schema.spaceRule.field, value }));
  }
  for (const name of sortedKeys(fields)) {
    const field = Object.hasOwn(schema.fields, name) ? schema.fields[name] : undefined;
    const value = own(fields, name);
    if (!field || value === undefined || value === null) continue;
    if (field.privateKindsOnly) refusals.push(refusal("privateKindsOnlyField", { type, field: name }));
    if (field.memberLocal) refusals.push(refusal("memberLocalField", { type, field: name }));
    if (field.json === "FileRef" && holdsPersonalFile(value, field.kind, field.personalSatellite === true)) {
      refusals.push(refusal("personalSatellite", { type, field: name }));
    }
  }
  if (schema.name === "Content") {
    const role = own(fields, "role");
    if ((typeof role === "string" && PERSONAL_SATELLITE_ROLES.includes(role)) || own(fields, "personal") === true) {
      refusals.push(refusal("personalSatellite", { type, field: "role" }));
    }
  }
  return refusals;
}

/**
 * Throws SpaceWriteRefused with the first refusal for writing such a record into a space.
 * @param {string} type
 * @param {Record<string, unknown>} fields
 * @param {SpaceWriter} writer
 */
export function checkWrite(type, fields, writer) {
  const [first] = refusalsForWrite(type, fields, writer);
  if (first) throw new SpaceWriteRefused(first);
}

/**
 * Checks a patch against the record it will produce from `held` (null for a create).
 * @param {import("./envelope.js").RecordPatch} patch
 * @param {import("./envelope.js").Envelope | null | undefined} held
 * @param {SpaceWriter} writer
 */
export function checkPatch(patch, held, writer) {
  /** @type {Record<string, any>} */
  const fields = copyJSON(held?.fields ?? {});
  for (const [name, change] of Object.entries(patch.changes)) {
    const elements = own(change, "elements");
    if (isObject(change) && Object.hasOwn(change, "elements") && isObject(elements)) {
      const current = own(fields, name);
      const object = isObject(current) ? current : {};
      for (const [key, value] of Object.entries(elements)) setOwn(object, key, value);
      setOwn(fields, name, object);
    } else {
      setOwn(fields, name, own(change, "value") ?? null);
    }
  }
  checkWrite(patch.type, fields, writer);
}

/**
 * Every refusal for deleting a record of `type` whose fields are `fields` from a space. A Course has
 * no `createdBy` (§3.5.9), so only the owner deletes a space's courses.
 * @param {string} type
 * @param {Record<string, unknown>} fields
 * @param {SpaceWriter} writer
 * @returns {SpaceRefusal[]}
 */
export function refusalsForDelete(type, fields, writer) {
  if (writer.permission === "readOnly") return [refusal("readOnlyParticipant", {})];
  if (!OWNED_DELETES.has(type) || writer.isOwner) return [];
  const createdBy = own(fields, "createdBy");
  return isPerson(createdBy) && own(createdBy, "user") === writer.user ? [] : [refusal("deleteNotAllowed", { type })];
}

/**
 * @param {string} type
 * @param {Record<string, unknown>} fields
 * @param {SpaceWriter} writer
 */
export function checkDelete(type, fields, writer) {
  const [first] = refusalsForDelete(type, fields, writer);
  if (first) throw new SpaceWriteRefused(first);
}

/**
 * @param {unknown} value
 * @param {string} kind
 * @param {boolean} personalField
 */
function holdsPersonalFile(value, kind, personalField) {
  const files = kind === "scalar" ? [value] : isObject(value) ? Object.values(/** @type {object} */ (value)) : [];
  return files.some((file) => file !== null && (personalField || (isFileRef(file) && isPersonalFileRef(file))));
}

/**
 * @param {SpaceRefusal["code"]} code
 * @param {{type?: string, field?: string, value?: string}} detail
 * @returns {SpaceRefusal}
 */
function refusal(code, { type, field, value }) {
  const messages = {
    readOnlyParticipant: "A read-only participant cannot change this space.",
    unknownType: `${type} is not a record type this version writes.`,
    privateOnlyType: `${type} is personal and never goes into a space.`,
    privateKind: `A ${type} whose ${field} is ${value} stays in your own library.`,
    privateKindsOnlyField: `${type}.${field} belongs to your own private chats and never goes into a space.`,
    memberLocalField: `${type}.${field} belongs to one member and never goes into a space.`,
    personalSatellite: `${type}.${field} points at a personal file, which stays in your own iCloud.`,
    deleteNotAllowed: `Only the space owner or whoever made this ${type} can delete it.`,
  };
  /** @type {SpaceRefusal} */
  const result = { code, message: messages[code] };
  if (type !== undefined) result.type = type;
  if (field !== undefined) result.field = field;
  if (value !== undefined) result.value = value;
  return result;
}
