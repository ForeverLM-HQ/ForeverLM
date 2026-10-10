#!/bin/bash
# ─── Build and test leftovers: the disk keeps only what is current ───────────
# Usage: bash ForeverLMApp/scripts/prune_build_leftovers.sh
#
# The product owner keeps one Dev, one First Run and one production ForeverLM on disk:
# the installed copies. Everything a build or a test run leaves beside them is
# disposable, and on 2026-10-03 it had filled the volume: 19 GB of gate derived
# data for worktrees no one had built in days (the old rule waited for the
# checkout to be removed, and scratch worktrees outlive their sessions), and
# 33 GB of temporary folders the unit tests make and never remove (15,000
# StudioVMTests_<UUID> folders in four days).
#
# xcb.sh runs this before every gated build. It deletes:
#   - a gate derived-data folder whose checkout is gone;
#   - a gate derived-data folder no build or test has touched for two hours
#     (the checkout being built now is in use, so its warm folder stays);
#   - a <prefix>_<UUID> folder in the temporary directory, untouched for two
#     hours, whose prefix a unit or UI test names.
# A derived-data folder that a running process names (an xcodebuild given it
# as -derivedDataPath, a test host launched out of it) is never deleted.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "${SCRIPT_DIR}")"
SHARED_DD_ROOT="${FOREVERLM_GATE_DD_ROOT:-${HOME}/Developer/ForeverLM-DerivedData/gate}"
TMP_ROOT="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}"
TMP_ROOT="${TMP_ROOT%/}"
IDLE_MINUTES=120
UUID_SUFFIX='[_-]????????-????-????-????-????????????'

PROCESSES="$(ps -axo command=)"
in_use() { grep -qF -- "$1" <<<"${PROCESSES}"; }
touched_recently() { [ -n "$(find "$1" -maxdepth 3 -mmin "-${IDLE_MINUTES}" -print -quit 2>/dev/null)" ]; }

# ─── Gate derived data ──────────────────────────────────────────────────────
for dd in "${SHARED_DD_ROOT}"/*-macos "${SHARED_DD_ROOT}"/*-ios; do
    [ -d "${dd}" ] || continue
    in_use "${dd}" && continue
    checkout="$(head -1 "${dd}/.checkout" 2>/dev/null)"
    if [ -n "${checkout}" ] && [ ! -e "$(dirname "${checkout}")" ]; then
        reason="its checkout ${checkout} is gone"
    elif touched_recently "${dd}"; then
        continue
    else
        reason="no build has touched it for ${IDLE_MINUTES} minutes"
    fi
    rm -rf "${dd}" && echo "[prune] removed ${dd}: ${reason}" >&2
done

# ─── Temporary folders the unit tests leave behind ──────────────────────────
# A test names its folder "SourceRemovalTests_\(UUID().uuidString)" or
# "WalkthroughChatTests_\(name)_\(UUID().uuidString)", so a prefix counts when
# the test sources quote it, or quote it with trailing _parts dropped.
named_by_a_test() {
    local prefix="$1"
    while [ "${#prefix}" -ge 4 ]; do
        grep -rqsF --include='*.swift' -- "\"${prefix}" \
            "${APP_DIR}/UnitTests" "${APP_DIR}/UITests" "${APP_DIR}/iOSUnitTests" && return 0
        case "${prefix}" in
            *_*) prefix="${prefix%_*}" ;;
            *) return 1 ;;
        esac
    done
    return 1
}

checked=" "
test_prefixes=" "
removed=0
while IFS= read -r -d '' entry; do
    base="${entry##*/}"
    prefix="${base%${UUID_SUFFIX}}"
    [ -n "${prefix}" ] && [ "${prefix}" != "${base}" ] || continue
    case "${checked}" in
        *" ${prefix} "*) ;;
        *)
            checked+="${prefix} "
            named_by_a_test "${prefix}" && test_prefixes+="${prefix} "
            ;;
    esac
    case "${test_prefixes}" in
        *" ${prefix} "*) rm -rf "${entry}" && removed=$((removed + 1)) ;;
    esac
done < <(find "${TMP_ROOT}" -mindepth 1 -maxdepth 1 -mmin "+${IDLE_MINUTES}" -name "*${UUID_SUFFIX}" -print0 2>/dev/null)

(( removed > 0 )) && echo "[prune] removed ${removed} temporary folders unit tests left in ${TMP_ROOT}" >&2
exit 0
