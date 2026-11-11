#!/bin/sh
set -eu

# A preference is declared once, under Shared/Preferences (`Prefs`). This check
# counts, per Swift file, the lines that still reach defaults by a string key
# or spell a declared key, and fails when a file's count is above what
# scripts/preference_keys_allowlist.txt allows or a file that is not listed has
# any. The list is a ratchet: it starts at the counts of the day the typed
# layer landed and only shrinks, as each file moves to typed keys.
#
#   sh scripts/check_preference_keys.sh            check (a build phase runs this)
#   sh scripts/check_preference_keys.sh --counts   print today's counts, in the list's format
#   sh scripts/check_preference_keys.sh --update   rewrite the list from today's counts
#                                                  (only to lower it; read the diff)
#
# UnitTests/PreferenceKeyLiteralTests.swift applies the same rules, so a run
# that skips the build phase still fails. Keep the two in step.
#
# What counts, on a line that is not a `//` comment:
#   1. a defaults call: `UserDefaults.standard`, `UserDefaults(suiteName:`,
#      `@AppStorage(`, `@SyncedStorage(`, `PreferenceStore.set(` / `.remove(` /
#      `.mirrorExternalWrite(`, or a read, write or removal on a receiver whose
#      name ends in `defaults`;
#   2. a string literal that is a declared key's name, or that starts with a
#      declared family's prefix (the names are read out of Shared/Preferences).
# Plain grep, not rg: rg is not installed on the build Mac.

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LIST="$ROOT/scripts/preference_keys_allowlist.txt"
MODE="${1:-check}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/preference-keys.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"

# The declared names: a key's stored name, and a family's prefix. The system's
# own prefixes (Prefs+System.swift: "CK", "SU", ...) are too short to scan for.
grep -h -o -E '(AccountKey|DeviceKey)<[^>]*>(\.unread)?\("[^"]*"' Shared/Preferences/Prefs+*.swift \
  | sed -e 's/^[^"]*"//' -e 's/"$//' > "$WORK/names"
grep -h -o -E 'prefix: "[^"]*"' Shared/Preferences/Prefs+Families.swift \
  | sed -e 's/^prefix: "//' -e 's/"$//' > "$WORK/prefixes"
[ -s "$WORK/names" ] && [ -s "$WORK/prefixes" ] \
  || { echo "error: no declared preference keys found under Shared/Preferences" >&2; exit 1; }

# One pass over the sources. A string literal is what sits between two quotes on
# a line (the even pieces of the line split at `"`); the Swift test splits the
# same way, so the two agree line for line.
find App Shared MCP iOS -name '*.swift' -not -path 'Shared/Preferences/*' -print0 \
  | LC_ALL=C xargs -0 awk -v names="$WORK/names" -v prefixes="$WORK/prefixes" '
    BEGIN {
      while ((getline line < names) > 0) name[line] = 1
      while ((getline line < prefixes) > 0) prefix[++prefixCount] = line
      calls = "UserDefaults\\.standard|UserDefaults\\(suiteName:|@AppStorage\\(|@SyncedStorage\\(|PreferenceStore\\.(set|remove|mirrorExternalWrite)\\(|[Dd]efaults[?!]?\\.(set|removeObject|object|string|bool|integer|double|float|data|array|stringArray|dictionary|url)\\("
    }
    /^[ \t]*\/\// { next }
    {
      hit = ($0 ~ calls)
      if (!hit && index($0, "\"") > 0) {
        pieces = split($0, piece, "\"")
        for (i = 2; i <= pieces && !hit; i += 2) {
          if (piece[i] in name) { hit = 1; break }
          for (p = 1; p <= prefixCount; p++) {
            if (index(piece[i], prefix[p]) == 1) { hit = 1; break }
          }
        }
      }
      if (hit) count[FILENAME]++
    }
    END { for (file in count) print count[file] "\t" file }
  ' | sort -t "$(printf '\t')" -k2 > "$WORK/counts"

case "$MODE" in
  --counts)
    cat "$WORK/counts"
    exit 0
    ;;
  --update)
    {
      grep -E '^(#|$)' "$LIST" 2>/dev/null || true
      cat "$WORK/counts"
    } > "$WORK/list"
    cp "$WORK/list" "$LIST"
    echo "Rewrote $LIST ($(wc -l < "$WORK/counts" | tr -d ' ') files)."
    exit 0
    ;;
esac

[ -f "$LIST" ] || { echo "error: $LIST is missing" >&2; exit 1; }

OVER=$(awk -F '\t' '
  FNR == NR { if ($0 !~ /^#/ && NF == 2) allowed[$2] = $1; next }
  {
    limit = ($2 in allowed) ? allowed[$2] : 0
    if ($1 > limit) printf "%s: %d lines reach defaults by a string key or spell a preference key; %d allowed\n", $2, $1, limit
  }' "$LIST" "$WORK/counts")

if [ -n "$OVER" ]; then
  printf 'error: preference keys are declared once, under Shared/Preferences (Prefs). Use the typed key (Preferences.value / Preferences.set, @PreferenceStorage, or MobileModelPreferenceStore.value(for:) on the iPhone) instead of a string key:\n%s\n' "$OVER" >&2
  exit 1
fi
