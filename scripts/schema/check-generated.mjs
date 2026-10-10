#!/usr/bin/env node
// Fails when a checked-in file generated from schema/cloudkit-schema.json is
// stale: regenerates every output into a temporary directory and compares it
// byte for byte with the repository's copy (docs/cloudkit-schema-design.md
// §12.1). Runs inside `npm run website:check` (docs-site) and `npm run verify`
// (workers/mcp-gateway).

import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_ROOT, generate, writeOutputs } from "./generate.mjs";

const scratch = mkdtempSync(join(tmpdir(), "foreverlm-schema-"));
try {
  let files;
  try {
    files = generate();
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
  writeOutputs(files, scratch);
  const stale = [];
  for (const relativePath of Object.keys(files)) {
    const checkedIn = join(REPO_ROOT, relativePath);
    const fresh = readFileSync(join(scratch, relativePath));
    if (!existsSync(checkedIn)) stale.push(`${relativePath} (missing)`);
    else if (!readFileSync(checkedIn).equals(fresh)) stale.push(relativePath);
  }
  if (stale.length > 0) {
    console.error(`Generated schema files are stale:\n  ${stale.join("\n  ")}\nRun: node scripts/schema/generate.mjs`);
    process.exit(1);
  }
  console.log(`Generated schema files are current (${Object.keys(files).length} files).`);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
