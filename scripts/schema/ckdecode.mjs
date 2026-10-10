#!/usr/bin/env node
// Decodes exported schema-v2 records for debugging (docs/cloudkit-schema-design.md §3.2, §3.4).
//
// Usage: node scripts/schema/ckdecode.mjs [file | -] [--salt <base64>]
//
// Reads JSON from `xcrun cktool query-records`, CloudKit Web Services
// (records/lookup, records/query, changes/zone), a single record object, a
// payload envelope, raw payload bytes (JSON or gzip), or a base64 payload, and
// prints each record's name, type and decoded envelope. With --salt, it also
// checks that each record name is the one the logical id in its payload maps to.

import { readFileSync } from "node:fs";
import { loadSchema } from "./generate.mjs";
import { decodePayload, recordName } from "./record-name.mjs";

const args = process.argv.slice(2);
let salt;
let input = "-";
for (let index = 0; index < args.length; index++) {
  if (args[index] === "--salt") salt = args[++index];
  else if (args[index].startsWith("--")) {
    console.error("usage: node scripts/schema/ckdecode.mjs [file | -] [--salt <base64>]");
    process.exit(2);
  } else input = args[index];
}

const bytes = readFileSync(input === "-" ? 0 : input);
const schema = loadSchema();

/// The base64 bytes of a CloudKit BYTES field, whichever exporter wrote it.
function fieldBytes(field) {
  if (typeof field === "string") return Buffer.from(field, "base64");
  if (field && typeof field.value === "string") return Buffer.from(field.value, "base64");
  return null;
}

function describe(record) {
  const fields = record.fields ?? {};
  const payloadBytes = fieldBytes(fields.payload ?? record.payload);
  const result = {
    recordName: record.recordName ?? record.recordID?.recordName,
    recordType: record.recordType,
    zone: record.zoneID?.zoneName ?? record.zoneName,
  };
  if (!payloadBytes) {
    result.error = record.deleted ? "deleted" : "no payload field";
    return result;
  }
  try {
    result.envelope = decodePayload(payloadBytes);
  } catch (error) {
    result.error = `payload does not decode: ${error.message}`;
    return result;
  }
  if (fields.data) result.dataBytes = fieldBytes(fields.data)?.length ?? null;
  if (fields.asset) result.asset = { size: fields.asset.value?.size ?? fields.asset.size ?? null };
  const type = result.envelope.type ?? result.recordType;
  if (salt && type && schema.types[type] && result.recordName) {
    const expected = recordName(schema, salt, type, result.envelope.id);
    result.nameCheck = expected === result.recordName ? "ok" : `mismatch: the id names ${expected}`;
  }
  return result;
}

let output;
if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
  output = decodePayload(bytes);
} else {
  const text = bytes.toString("utf8").trim();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = undefined;
  }
  if (json === undefined) output = decodePayload(Buffer.from(text, "base64"));
  else if (json.env !== undefined && json.fields !== undefined) output = json;
  else if (Array.isArray(json.records)) output = json.records.map(describe);
  else if (Array.isArray(json)) output = json.map(describe);
  else output = describe(json);
}
console.log(JSON.stringify(output, null, 2));
