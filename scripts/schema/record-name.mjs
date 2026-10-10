// Record names and payload bytes for the schema tools (tools/ckname,
// scripts/schema/ckdecode.mjs). Node's crypto and zlib; the clients have their
// own implementations (Swift RecordNaming/Envelope, schema/js), all pinned by
// schema/vectors/naming.json and envelope.json.

import { createHmac } from "node:crypto";
import { gunzipSync } from "node:zlib";

const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

/// RFC 4648 base32, lowercase, no padding.
export function base32Lower(bytes) {
  let output = "";
  let buffer = 0;
  let bits = 0;
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += BASE32_ALPHABET[(buffer >>> (bits - 5)) & 31];
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) output += BASE32_ALPHABET[(buffer << (5 - bits)) & 31];
  return output;
}

/// recordName = prefix + "_" + base32lower(HMAC-SHA256(salt, type + "\n" + id))[0..<26] (§3.4).
export function recordName(schema, saltBase64, typeName, logicalID) {
  const type = schema.types[typeName];
  if (!type) throw new Error(`unknown record type ${typeName}`);
  if (type.fixedRecordName) return type.fixedRecordName;
  const salt = Buffer.from(saltBase64, "base64");
  if (salt.length !== 32) throw new Error(`a zone salt is 32 bytes; this one decodes to ${salt.length}`);
  const digest = createHmac("sha256", salt).update(`${typeName}\n${logicalID}`, "utf8").digest();
  return `${type.prefix}${schema.recordName.separator}${base32Lower(digest).slice(0, schema.recordName.length)}`;
}

/// Payload bytes are UTF-8 JSON, gzip when they start with 1F 8B (§3.2 rule 1).
export function decodePayload(bytes) {
  const buffer = Buffer.from(bytes);
  const json = buffer[0] === 0x1f && buffer[1] === 0x8b ? gunzipSync(buffer) : buffer;
  return JSON.parse(json.toString("utf8"));
}
