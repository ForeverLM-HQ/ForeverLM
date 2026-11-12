#!/bin/bash
# The ForeverLM tree names no person and no company, so it can be open-sourced as it
# stands. Run before committing (a pre-commit hook can call it with --staged).
#   scripts/check-open-tree.sh            every tracked file
#   scripts/check-open-tree.sh --staged   only lines added to the index
#   scripts/check-open-tree.sh --message <file>   a commit message (the commit-msg hook)
# Install both hooks in a clone:
#   printf '#!/bin/bash\nexec "$(git rev-parse --show-toplevel)/scripts/check-open-tree.sh" --staged\n' > .git/hooks/pre-commit
#   printf '#!/bin/bash\nexec "$(git rev-parse --show-toplevel)/scripts/check-open-tree.sh" --message "$1"\n' > .git/hooks/commit-msg
#   chmod +x .git/hooks/pre-commit .git/hooks/commit-msg
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
PATTERN='REDACTED'
SELF=':!scripts/check-open-tree.sh'
if [ "${1:-}" = "--message" ]; then
  hits=$(grep -v '^#' "${2:?--message needs the message file}" | grep -inE "$PATTERN" || true)
  if [ -n "$hits" ]; then
    echo "$hits" >&2
    echo "refused: the commit message names a person or a company; history goes public with the tree. Write \"the product owner\" instead." >&2
    exit 1
  fi
  exit 0
fi
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
