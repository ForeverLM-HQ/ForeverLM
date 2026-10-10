#!/bin/bash
# ─── The build gate: one xcodebuild at a time, machine-wide ──────────────────
# Usage: bash ForeverLMApp/scripts/xcb.sh <xcodebuild arguments…>
#
# Only the orchestrator session builds ForeverLM (AGENTS.md, "Builds belong to
# the orchestrator"), and it builds through this script instead of calling
# `xcodebuild` directly, so its own subagents queue too. On 2026-09-22, twenty minutes after a
# reboot, ten sessions each started their own cold build into a private
# scratchpad derived-data folder: 43 compiler processes, load average 207 on a
# 12-core machine, every window beachballing, and none of the builds finishing
# sooner than it would have alone. Running them one after another is faster
# for everyone, including the session that waits.
#
# What the gate does:
#   - Takes a machine-wide lock (`mkdir` is atomic) before running a heavy
#     xcodebuild action, and waits — printing who holds it — while another
#     session's build runs. A lock whose owner died is reclaimed.
#   - Passes cheap queries (-list, -version, -showBuildSettings, -showsdks,
#     -showdestinations) straight through without waiting.
#   - When the caller gives no -derivedDataPath, uses one shared, warm folder
#     per checkout and platform, so builds are incremental instead of cold.
#     The lock is what makes sharing safe: nothing rebuilds a tree while a test
#     host is loading from it. It prints the folder so callers can find
#     Build/Products. Pass your own -derivedDataPath only when you need an
#     isolated tree (a release archive, a borrowed-state experiment).
#   - Is reentrant: a script already inside the gate (build_dev.sh calling it
#     again) does not deadlock on itself.
#
# `xcb.sh --claim-orchestrator` makes the calling Claude session the
# orchestrator. The PreToolUse hook (build_gate_hook.sh) records the session;
# this script only confirms.
#
# Waiting can take many minutes. Run it with the Bash tool's
# run_in_background, not in the foreground against a 10-minute timeout.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

LOCK_DIR="/tmp/foreverlm-build-gate.lock"
SHARED_DD_ROOT="${HOME}/Developer/ForeverLM-DerivedData/gate"

# Xcode.app (the App Store release) is the only Xcode here, and xcode-select
# points at it. Should a Mac's selection be the Command Line Tools, which have
# no xcodebuild, fall back to the app (see AGENTS.md, "After Code Changes").
if ! xcodebuild -version >/dev/null 2>&1; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -x "${candidate}/Contents/Developer/usr/bin/xcodebuild" ]; then
            export DEVELOPER_DIR="${candidate}/Contents/Developer"
            break
        fi
    done
fi

# Each checkout gets its own folder under SHARED_DD_ROOT (below), 2–6 GB once
# built. prune_build_leftovers.sh deletes a folder once its checkout is gone or
# no build has touched it for two hours, and the temporary folders unit tests
# leave behind, so the disk keeps only the installed Dev, First Run and
# production apps plus the tree being built now.
prune_build_leftovers() {
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prune_build_leftovers.sh"
}

if [ "${1:-}" = "--prune-derived-data" ]; then
    prune_build_leftovers
    exit 0
fi
prune_build_leftovers

if [ "${1:-}" = "--claim-orchestrator" ]; then
    echo "[xcb] orchestrator: $(cat "${SHARED_DD_ROOT}/orchestrator" 2>/dev/null || echo "not recorded (no hook ran)")"
    exit 0
fi

args=("$@")

is_query=false
has_dd=false
project=""
scheme=""
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
        -list|-version|-showBuildSettings|-showsdks|-showdestinations|-showTestPlans|-help)
            is_query=true ;;
        -derivedDataPath) has_dd=true ;;
        -project) project="${args[i+1]:-}" ;;
        -scheme) scheme="${args[i+1]:-}" ;;
    esac
done

if ! $has_dd; then
    # One folder per checkout (worktrees have other paths, so other sources)
    # and per platform (iOS and macOS builds do not share products).
    project_abs="$(cd "$(dirname "${project:-.}")" 2>/dev/null && pwd)/$(basename "${project:-.}")"
    platform=macos
    case "${scheme}" in *iOS*) platform=ios ;; esac
    key="$(printf '%s' "${project_abs}" | shasum | cut -c1-10)"
    dd="${SHARED_DD_ROOT}/${key}-${platform}"
    mkdir -p "${dd}"
    printf '%s\n' "${project_abs}" > "${dd}/.checkout"
    args+=(-derivedDataPath "${dd}")
    $is_query || echo "[xcb] derived data: ${dd}" >&2
fi

# Queries carry the same derived-data path, so -showBuildSettings reports the
# products a gated build actually made.
if $is_query || [ -n "${FOREVERLM_BUILD_GATE_HELD:-}" ]; then
    exec xcodebuild "${args[@]}"
fi

holder_info() { cat "${LOCK_DIR}/info" 2>/dev/null || echo "unknown"; }

owned=false
release() { $owned && rm -rf "${LOCK_DIR}"; }
trap release EXIT
trap 'exit 130' INT TERM

waited=0
while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
    pid="$(sed -n 's/^pid=//p' "${LOCK_DIR}/info" 2>/dev/null)"
    if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
        echo "[xcb] reclaiming the gate from dead process ${pid}" >&2
        rm -rf "${LOCK_DIR}"
        continue
    fi
    # A lock directory with no info yet is being taken right now; an old one
    # with no info is debris from a crash between mkdir and the write.
    if [ -z "${pid}" ] && [ -n "$(find "${LOCK_DIR}" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
        rm -rf "${LOCK_DIR}"
        continue
    fi
    if (( waited % 60 == 0 )); then
        echo "[xcb] waiting ${waited}s for the build gate, held by: $(holder_info | tr '\n' ' ')" >&2
    fi
    sleep 5
    waited=$((waited + 5))
done
owned=true
{
    echo "pid=$$"
    echo "since=$(date '+%H:%M:%S')"
    echo "cwd=${PWD}"
    echo "cmd=xcodebuild ${args[*]:0:8}"
} > "${LOCK_DIR}/info"
(( waited > 0 )) && echo "[xcb] got the gate after ${waited}s" >&2

export FOREVERLM_BUILD_GATE_HELD=1
xcodebuild "${args[@]}"
status=$?
exit "${status}"
