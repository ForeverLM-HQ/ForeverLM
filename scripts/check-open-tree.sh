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
#
# The words it refuses are not written here, since this file is public too.
# scripts/open-tree-patterns.txt, one extended regex per line, holds them where the
# maintainers' private overlay links it in (it is not tracked). Without that file the
# check falls back to SHA-256 digests of the same words, matched against every
# lowercased word in the text (camelCase split, neighbouring words also joined).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
PATTERNS_FILE="${OPEN_TREE_PATTERNS:-scripts/open-tree-patterns.txt}"
SELF='scripts/check-open-tree.sh'

mode="${1:-tree}"
case "$mode" in
  --message) input=$(grep -v '^#' "${2:?--message needs the message file}" || true) ;;
  --staged) input=$(git diff --cached -U0 --no-color -- . ":!$SELF" | grep -E '^\+[^+]' || true) ;;
  *) input="" ;;
esac

if [ -f "$PATTERNS_FILE" ]; then
  pattern=$(grep -vE '^\s*(#|$)' "$PATTERNS_FILE" | paste -sd'|' -)
  if [ "$mode" = tree ]; then
    hits=$(git grep -IinE "$pattern" -- . ":!$SELF" || true)
  else
    hits=$(printf '%s\n' "$input" | grep -inE "$pattern" || true)
  fi
else
  hits=$(MODE="$mode" SELF="$SELF" INPUT="$input" python3 -I -c '
import hashlib, os, re, subprocess, sys
DIGESTS = set(open(0).read().split())
def words(line):
    parts = re.findall(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|[0-9]+", line)
    low = [p.lower() for p in parts]
    yield from low
    yield from (a + b for a, b in zip(low, low[1:]))
    yield from (w.lower() for w in re.findall(r"[A-Za-z0-9]+", line))
def bad(line):
    return any(hashlib.sha256(w.encode()).hexdigest() in DIGESTS for w in words(line))
mode, self_path = os.environ["MODE"], os.environ["SELF"]
if mode == "tree":
    files = subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0")
    for name in files:
        if not name or name.decode() == self_path or not os.path.isfile(name):
            continue
        data = open(name, "rb").read()
        if b"\0" in data[:8000]:
            continue
        for n, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            if bad(line):
                print(f"{name.decode()}:{n}:{line[:200]}")
else:
    for n, line in enumerate(os.environ.get("INPUT", "").splitlines(), 1):
        if bad(line):
            print(f"{n}:{line[:200]}")
' <<'DIGESTS'
42a343fb032d282ddadc43a394b5434d7995cbeb3aaee6a9fe0fe2bf2379d040
135f7077ed9253d43eaa89e11e6afd9e0d1d0250a3ad30b75274ab3d1f7a5a0c
58549f7970bdd635e8713590cf773d0bbea4ca2882c5f7ae57bdb6de8f759f87
1e312b3d1442413d3d2aa6bc58a13a96730af07eceb7b3478bdb93120f4d1a7c
e62c5b267e9d72c42f2b8b80c6adaab3a19b5f754a1a8b2521c99301d0760017
6078a57230dad2a34aa9347f89f20cc6b786cdd47d493c55eaa9497867612dcf
7b094af0efbe3a2920d324a55e03fa4359e90bddefd7ed72705be9a774379bbe
848d415fa3bc51764ca7f1420a4da8bdedcbbf6fc98b83a13416c5d4c32f005e
DIGESTS
)
fi

if [ -n "$hits" ]; then
  echo "$hits" >&2
  if [ "$mode" = --message ]; then
    echo "refused: the commit message names a person or a company; history goes public with the tree. Write \"the product owner\" instead." >&2
  else
    echo "refused: the open tree names a person or a company. Attribute a decision as \"(product owner, YYYY-MM-DD: ...)\" and use made-up names (Zara Holt, Acme Lab, example.org) in tests." >&2
  fi
  exit 1
fi
