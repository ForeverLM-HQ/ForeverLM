#!/bin/bash
# The ForeverLM tree names no person and no company, so it can be open-sourced as it
# stands. Run before committing (a pre-commit hook can call it with --staged).
#   scripts/check-open-tree.sh            every tracked file
#   scripts/check-open-tree.sh --staged   only lines added to the index
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
PATTERN='REDACTED'
SELF=':!scripts/check-open-tree.sh'
if [ "${1:-}" = "--staged" ]; then
  hits=$(git diff --cached -U0 --no-color -- . "$SELF" | grep -E '^\+[^+]' | grep -iE "$PATTERN" || true)
else
  hits=$(git grep -IinE "$PATTERN" -- . "$SELF" || true)
fi
if [ -n "$hits" ]; then
  echo "$hits" >&2
  echo "refused: the open tree names a person or a company. Attribute a decision as \"(product owner, YYYY-MM-DD: ...)\" and use made-up names (Zara Holt, Acme Lab, example.org) in tests." >&2
  exit 1
fi
