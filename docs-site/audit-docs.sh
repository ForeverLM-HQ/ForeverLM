#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$SCRIPT_DIR"

LLMS_FULL_BEFORE="$(shasum -a 256 public/llms-full.txt 2>/dev/null | awk '{print $1}')"

echo "▸ Regenerating llms-full.txt"
npm run llms

LLMS_FULL_AFTER="$(shasum -a 256 public/llms-full.txt | awk '{print $1}')"

echo "▸ Checking docs index and screenshot manifest"
node check-docs.mjs

echo "▸ Building VitePress and checking internal links"
npm run build

if [ "$LLMS_FULL_BEFORE" != "$LLMS_FULL_AFTER" ]; then
  echo "✗ docs-site/public/llms-full.txt was stale and has been regenerated." >&2
  echo "  Review and commit it before releasing." >&2
  exit 1
fi

echo "✓ Docs audit passed"
