#!/bin/bash
# Imports schema/generated/foreverlm-library.ckdb into the Development
# environment of the schema-v2 container, exports it again and requires a clean
# round trip (docs/cloudkit-schema-design.md §2.1 C7, §12.2, §12.4).
#
# Usage: bash scripts/schema/import-development.sh [--dry-run]
#   --dry-run  only `cktool validate-schema`, which checks the file against the
#              environment and applies nothing
#
# Development only. Production is deployed from the CloudKit Console (§2.1 C9);
# cktool refuses import-schema there. Never use `import-schema --validate` as a
# dry run: it applies the import. Never run `xcrun cktool reset-schema` either
# (§2.1 C7): it resets Development to Production and deletes every Development
# record. CloudKit accepts added types and fields; a field rename or retype that
# Development refuses goes to the maintainer, never to a reset.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/schema/signing-team.sh"
TEAM_ID="$(signing_team)"
SCHEMA_FILE="$ROOT/schema/generated/foreverlm-library.ckdb"
DRY_RUN=0
for argument in "$@"; do
  case "$argument" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "usage: bash scripts/schema/import-development.sh [--dry-run]" >&2; exit 2 ;;
  esac
done

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONTAINER="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).container)' "$ROOT/schema/cloudkit-schema.json")"
# Only the container the apps sync, the company team's
# iCloud.com.foreverlm.knowledge. The personal team's iCloud.com.foreverlm and
# iCloud.com.foreverlm.library are retired and nothing is imported into them
# or any other container (§2.1, D2).
if [ "$CONTAINER" != "iCloud.com.foreverlm.knowledge" ]; then
  echo "Refusing to import into $CONTAINER: this script imports only into iCloud.com.foreverlm.knowledge." >&2
  exit 1
fi

node "$ROOT/scripts/schema/check-generated.mjs"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/foreverlm-schema-import.XXXXXX")"
CK=(--team-id "$TEAM_ID" --container-id "$CONTAINER" --environment development)

echo "Exporting the current Development schema of $CONTAINER…"
xcrun cktool export-schema "${CK[@]}" --output-file "$WORK/before.ckdb"
# What Development holds beyond the file is listed so it is not a surprise.
node "$ROOT/scripts/schema/ckdb.mjs" covers "$SCHEMA_FILE" "$WORK/before.ckdb" | grep '^extra' || true

echo "Validating $SCHEMA_FILE (applies nothing)…"
xcrun cktool validate-schema "${CK[@]}" --file "$SCHEMA_FILE"
if [ "$DRY_RUN" = 1 ]; then
  rm -rf "$WORK"
  exit 0
fi

echo "Importing into Development…"
xcrun cktool import-schema "${CK[@]}" --file "$SCHEMA_FILE"

echo "Exporting again to compare…"
xcrun cktool export-schema "${CK[@]}" --output-file "$WORK/after.ckdb"
if ! node "$ROOT/scripts/schema/ckdb.mjs" roundtrip "$SCHEMA_FILE" "$WORK/after.ckdb"; then
  echo "Exports kept in $WORK" >&2
  exit 1
fi
rm -rf "$WORK"
