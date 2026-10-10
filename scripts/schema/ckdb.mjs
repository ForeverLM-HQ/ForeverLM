#!/usr/bin/env node
// Reads and compares CloudKit schema files in the format `xcrun cktool
// export-schema` writes (docs/cloudkit-schema-design.md §12.2).
//
//   node scripts/schema/ckdb.mjs roundtrip <generated.ckdb> <exported.ckdb>
//     exit 1 unless the export equals the generated file, whitespace-normalized
//     (types listed in the schema's cloudKit.ignoredOnExport are dropped first)
//   node scripts/schema/ckdb.mjs covers <generated.ckdb> <exported.ckdb>
//     exit 1 if the export lacks a type or field of the generated file or types
//     one differently; extra types and fields in the export are reported only,
//     and the system types (Users, cloudkit.share) are not compared

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadSchema } from "./generate.mjs";

const unquote = (name) => (name.startsWith("\"") && name.endsWith("\"") ? name.slice(1, -1) : name);

/// { typeName: { fields: { name: "TYPE [QUERYABLE…]" }, grants: [...] } }
export function parseCkdb(text) {
  const types = {};
  const blockPattern = /RECORD TYPE\s+("[^"]+"|[A-Za-z0-9_.]+)\s*\(([\s\S]*?)\n\s*\);/g;
  for (const match of text.matchAll(blockPattern)) {
    const name = unquote(match[1]);
    const fields = {};
    const grants = [];
    for (const raw of match[2].split("\n")) {
      const line = raw.trim().replace(/,$/, "");
      if (!line) continue;
      if (line.startsWith("GRANT ")) {
        grants.push(line.replace(/\s+/g, " "));
        continue;
      }
      const field = line.match(/^("[^"]+"|\S+)\s+(.+)$/);
      if (!field) throw new Error(`cannot read the line "${line}" in RECORD TYPE ${name}`);
      fields[unquote(field[1])] = field[2].replace(/\s+/g, " ");
    }
    types[name] = { fields, grants };
  }
  return types;
}

export function dropTypes(text, names) {
  let result = text;
  for (const name of names) {
    const quoted = /^[A-Za-z][A-Za-z0-9_]*$/.test(name) ? name : `"${name}"`;
    const escaped = quoted.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    result = result.replace(new RegExp(`\\n?\\s*RECORD TYPE ${escaped} \\([\\s\\S]*?\\n\\s*\\);\\n?`, "g"), "\n");
  }
  return result;
}

export const normalizeWhitespace = (text) => text.split("\n").map((line) => line.trim().replace(/\s+/g, " ")).filter(Boolean).join("\n");

/// Differences between what the generated file declares and what an export holds.
/// Types named in `skipTypes` are left out on both sides.
export function compareCkdb(expectedText, actualText, skipTypes = []) {
  const skip = (types) => Object.fromEntries(Object.entries(types).filter(([name]) => !skipTypes.includes(name)));
  const expected = skip(parseCkdb(expectedText));
  const actual = skip(parseCkdb(actualText));
  const missing = [];
  const changed = [];
  const extra = [];
  for (const [typeName, type] of Object.entries(expected)) {
    const other = actual[typeName];
    if (!other) {
      missing.push(`type ${typeName}`);
      continue;
    }
    for (const [fieldName, fieldType] of Object.entries(type.fields)) {
      if (!(fieldName in other.fields)) missing.push(`field ${typeName}.${fieldName} (${fieldType})`);
      else if (other.fields[fieldName] !== fieldType) changed.push(`field ${typeName}.${fieldName}: expected ${fieldType}, found ${other.fields[fieldName]}`);
    }
    for (const fieldName of Object.keys(other.fields)) {
      if (!(fieldName in type.fields)) extra.push(`field ${typeName}.${fieldName} (${other.fields[fieldName]})`);
    }
    const grants = [...type.grants].sort().join("; ");
    const otherGrants = [...other.grants].sort().join("; ");
    if (grants !== otherGrants) changed.push(`grants of ${typeName}: expected ${grants}, found ${otherGrants}`);
  }
  for (const typeName of Object.keys(actual)) if (!expected[typeName]) extra.push(`type ${typeName}`);
  return { missing, changed, extra };
}

function report({ missing, changed, extra }) {
  for (const line of missing) console.log(`missing  ${line}`);
  for (const line of changed) console.log(`changed  ${line}`);
  for (const line of extra) console.log(`extra    ${line}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, expectedPath, actualPath] = process.argv.slice(2);
  if (!["roundtrip", "covers"].includes(mode) || !expectedPath || !actualPath) {
    console.error("usage: node scripts/schema/ckdb.mjs roundtrip|covers <generated.ckdb> <exported.ckdb>");
    process.exit(2);
  }
  const { cloudKit } = loadSchema();
  const ignored = cloudKit.ignoredOnExport ?? [];
  const expectedText = readFileSync(expectedPath, "utf8");
  const actualText = dropTypes(readFileSync(actualPath, "utf8"), ignored);
  const differences = compareCkdb(expectedText, actualText, mode === "covers" ? Object.keys(cloudKit.systemTypes) : []);
  if (mode === "roundtrip") {
    const same = normalizeWhitespace(expectedText) === normalizeWhitespace(actualText);
    report(differences);
    if (!same) {
      console.log("The export differs from the generated file (whitespace-normalized).");
      process.exit(1);
    }
    console.log(`Round trip clean: ${Object.keys(parseCkdb(expectedText)).length} record types match.`);
  } else {
    report(differences);
    if (differences.missing.length || differences.changed.length) {
      console.log(`The export lacks ${differences.missing.length} and differs on ${differences.changed.length} item(s) the generated schema declares.`);
      process.exit(1);
    }
    console.log(`Every type and field of the generated schema is present (${differences.extra.length} extra item(s) reported).`);
  }
}
