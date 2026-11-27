#!/bin/bash
# A commit that changes what a learner sees says which DESIGN.md rules it was
# checked against, so the rules are read before the change lands, not after.
#   scripts/check-design-review.sh <commit message file>   (the commit-msg hook)
# Install in a clone, beside the open-tree check:
#   printf '#!/bin/bash\nroot="$(git rev-parse --show-toplevel)"\n"$root/scripts/check-open-tree.sh" --message "$1" && exec "$root/scripts/check-design-review.sh" "$1"\n' > .git/hooks/commit-msg
#   chmod +x .git/hooks/commit-msg
#
# The message needs a line such as
#   Design: DESIGN.md reviewed; app addresses render as titles, text wraps in its column
# A merge, a revert or a fixup is exempt.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
msg_file="${1:?needs the commit message file}"
message=$(grep -v '^#' "$msg_file" || true)

# What a learner sees: the apps' Swift views and the web renderers they host
# (chat, Page editor, map, published page), not their tests.
ui_files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E \
  '^ForeverLMApp/(App|iOS|Shared/Views)/.*\.swift$|^ForeverLMApp/Web/.*\.(m?js|html|css)$' \
  | grep -vE '(Tests?|Mock|\.test|\.spec)[^/]*\.[a-z]+$' || true)
[ -z "$ui_files" ] && exit 0

first=$(printf '%s\n' "$message" | sed -n '1p')
case "$first" in Merge\ *|Revert\ *|fixup!*|squash!*) exit 0 ;; esac

if printf '%s\n' "$message" | grep -qE '^Design: .*[[:alnum:]]'; then
  exit 0
fi

{
  echo "refused: this commit changes what a learner sees:"
  printf '  %s\n' $ui_files
  echo "Read DESIGN.md, check the change against it (no foreverlm:// address shown as text,"
  echo "text wraps inside its container, ...), and add a line to the message:"
  echo "  Design: DESIGN.md reviewed; <the rules this change touches>"
} >&2
exit 1
