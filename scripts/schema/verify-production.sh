#!/bin/bash
# Checks that the Production environment of the schema-v2 container holds every
# record type and field the generated schema declares (the system types Users
# and cloudkit.share are not compared), and that cloudkit.share exists, since
# spaces cannot save a CKShare without it (docs/cloudkit-schema-design.md §2.1
# C8–C9, §12.2, §12.4). Exit 1 names what is missing: Development has not been
# deployed to Production with the CloudKit Console's Deploy Schema Changes, and
# a build that writes those records must not ship. release_macos.sh runs it for
# every generation-2 Release build.
#
# Usage: bash scripts/schema/verify-production.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/schema/signing-team.sh"
SCHEMA_FILE="$ROOT/schema/generated/foreverlm-library.ckdb"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONTAINER="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).container)' "$ROOT/schema/cloudkit-schema.json")"

node "$ROOT/scripts/schema/check-generated.mjs"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/foreverlm-schema-production.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# FOREVERLM_PRODUCTION_SCHEMA_FILE names a Production export from the CloudKit
# Console (Production › Export Schema…) to check instead of asking cktool, for a
# Mac whose cktool holds no management token for the team yet.
if [ -n "${FOREVERLM_PRODUCTION_SCHEMA_FILE:-}" ]; then
  [ -f "$FOREVERLM_PRODUCTION_SCHEMA_FILE" ] || { echo "FOREVERLM_PRODUCTION_SCHEMA_FILE does not exist: $FOREVERLM_PRODUCTION_SCHEMA_FILE" >&2; exit 1; }
  echo "Checking the Console export $FOREVERLM_PRODUCTION_SCHEMA_FILE, not cktool."
  cp "$FOREVERLM_PRODUCTION_SCHEMA_FILE" "$WORK/production.ckdb"
else
  TEAM_ID="$(signing_team)"
  xcrun cktool export-schema --team-id "$TEAM_ID" --container-id "$CONTAINER" \
    --environment production --output-file "$WORK/production.ckdb"
fi

STATUS=0
node "$ROOT/scripts/schema/ckdb.mjs" covers "$SCHEMA_FILE" "$WORK/production.ckdb" || STATUS=1
if ! grep -q 'RECORD TYPE "cloudkit.share"' "$WORK/production.ckdb"; then
  echo "missing  type cloudkit.share: save one CKShare from a Dev build, then deploy again (§2.1 C8)"
  STATUS=1
fi
if [ "$STATUS" = 0 ]; then
  echo "Production of $CONTAINER carries the generated schema."
fi
exit "$STATUS"
