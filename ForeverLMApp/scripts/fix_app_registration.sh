#!/bin/bash
#
# Repair the LaunchServices records for ForeverLM's bundle identifiers.
#
# The native Sign in with Apple sheet does not read the running bundle. AuthKitUI's
# AKIcon resolves the app icon through -[AKIcon _applicationProxyForBundleID:], i.e.
# LaunchServices keyed on the caller's bundle identifier, and falls back to its own
# blank PlaceholderIcon when that lookup comes up empty.
#
# A machine that builds this app all day accumulates a registration per copy: every
# DerivedData tree, every worktree build directory, every scratchpad, the .xcarchive,
# the DMG export, mounted installer volumes, .app backups under Application Support,
# and copies sitting in the Trash. Most of those paths are deleted soon after, but the
# record stays. Once LaunchServices picks a dangling record as the preferred one for
# com.foreverlm, the sign-in sheet shows a blank icon even though every real copy's
# icon is perfectly fine. (Observed 2026-08-31: ~90 records for com.foreverlm, the
# majority pointing at deleted directories, two of them in the Trash.)
#
# This script never touches files. It only unregisters copies that should not be
# answering for these identifiers, then re-asserts the installed app.
#
# Usage:  ./scripts/fix_app_registration.sh [--check]
#           --check   report current state and exit without changing anything

set -euo pipefail

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
CANONICAL="/Applications/ForeverLM.app"
IDENTIFIERS=(com.foreverlm com.foreverlm.dev)

CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

info() { printf '\033[0;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33mwarn\033[0m %s\n' "$1"; }

[ -x "$LSREGISTER" ] || { echo "lsregister not found at $LSREGISTER" >&2; exit 1; }

# Every path LaunchServices has on file for one identifier, present or not.
registered_paths() {
    "$LSREGISTER" -dump 2>/dev/null | /usr/bin/python3 -c '
import sys
wanted = sys.argv[1]
path = None
for line in sys.stdin:
    line = line.strip()
    if line.startswith("path:"):
        path = line.split("path:", 1)[1].strip().rsplit(" (0x", 1)[0].strip()
    elif line.startswith("identifier:") and path:
        found = line.split("identifier:", 1)[1].strip().rsplit(" (0x", 1)[0].strip()
        if found == wanted:
            print(path)
        path = None
' "$1"
}

# What LaunchServices would actually hand AuthKit, in preference order. This is
# LSCopyApplicationURLsForBundleIdentifier — the same record AKIcon reads. Do not
# substitute mdfind here: Spotlight is a separate index and disagrees.
resolved_order() {
    /usr/bin/python3 -c '
import ctypes, ctypes.util, sys
cf = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
cs = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreServices.framework/CoreServices")
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFArrayGetCount.restype = ctypes.c_long
cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
cf.CFURLCopyFileSystemPath.restype = ctypes.c_void_p
cf.CFURLCopyFileSystemPath.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
cs.LSCopyApplicationURLsForBundleIdentifier.restype = ctypes.c_void_p
cs.LSCopyApplicationURLsForBundleIdentifier.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
UTF8 = 0x08000100
def to_str(s):
    buf = ctypes.create_string_buffer(4096)
    cf.CFStringGetCString(s, buf, 4096, UTF8)
    return buf.value.decode("utf-8")
ident = cf.CFStringCreateWithCString(None, sys.argv[1].encode(), UTF8)
urls = cs.LSCopyApplicationURLsForBundleIdentifier(ident, None)
if not urls:
    sys.exit(0)
for i in range(cf.CFArrayGetCount(urls)):
    print(to_str(cf.CFURLCopyFileSystemPath(cf.CFArrayGetValueAtIndex(urls, i), 0)))
' "$1"
}

report() {
    local bundle_id total missing
    for bundle_id in "${IDENTIFIERS[@]}"; do
        total=0; missing=0
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            total=$((total + 1))
            if [ ! -d "$p" ]; then
                missing=$((missing + 1))
            elif [ ! -f "$p/Contents/Resources/AppIcon.icns" ]; then
                warn "  no icon  $p"
            fi
        done < <(registered_paths "$bundle_id")
        info "$bundle_id — $total registered, $missing dangling"
        local first=true
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            if [ "$first" = true ]; then
                echo "      resolves to  $p"
                first=false
            else
                echo "      fallback     $p"
            fi
        done < <(resolved_order "$bundle_id")
    done
}

if [ "$CHECK_ONLY" = true ]; then
    report
    exit 0
fi

# Drop every com.foreverlm registration that is not the installed app. Anything still
# on disk re-registers itself next time it is launched, so this is not destructive —
# it just stops a build directory, a backup, or a Trash copy from being the one
# AuthKit asks for an icon.
info "Unregistering non-canonical copies of com.foreverlm"
count=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$p" = "$CANONICAL" ] && continue
    "$LSREGISTER" -u "$p" 2>/dev/null || true
    count=$((count + 1))
done < <(registered_paths com.foreverlm)
echo "      unregistered $count"

# The Dev flavour has no canonical install, so only prune records whose bundle is
# gone or has lost its icon — those are the ones that produce a blank sheet.
info "Pruning dead com.foreverlm.dev records"
count=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -d "$p" ] || [ ! -f "$p/Contents/Resources/AppIcon.icns" ]; then
        "$LSREGISTER" -u "$p" 2>/dev/null || true
        count=$((count + 1))
    fi
done < <(registered_paths com.foreverlm.dev)
echo "      unregistered $count"

if [ -d "$CANONICAL" ]; then
    info "Re-asserting $CANONICAL"
    "$LSREGISTER" -f "$CANONICAL"
else
    warn "$CANONICAL is not installed — nothing to re-assert"
fi

info "Result"
report
