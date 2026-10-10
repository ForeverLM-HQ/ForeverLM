#!/bin/sh
set -eu

# The iPhone app lays out by the size classes and the width it is given,
# never by the device it runs on (docs/iphone-duo.md). An iPhone Duo's open
# inner display is an iPhone whose size classes are an iPad's, its outer
# display is a phone's, and the one window moves between them as the device
# folds, so none of these says anything true about the screen:
#   - the main screen (`UIScreen.main`): a device with two displays has no
#     single one, and a size read once at launch is wrong after a fold;
#   - the idiom (`userInterfaceIdiom`): an iPhone is not a small screen;
#   - the orientation (`UIDevice.current.orientation`,
#     `statusBarOrientation`, `interfaceOrientation`): the inner display does
#     not honour the supported orientations, and a window can be any shape;
#   - a window built from the main screen (`UIWindow(frame:)`).
# Use `horizontalSizeClass` and `verticalSizeClass`, `GeometryReader` or
# `onGeometryChange` for the room a view has, `displayScale` for the scale and
# `view.window?.windowScene` for a screen.
#
# Runs from check_ai_model_routing.sh, which is a build phase of the Mac and
# iPhone targets. Plain grep, not rg, as there: rg is not installed on the
# build Mac. A line that is only a comment is not code and is not checked.

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

fail() {
  printf 'error: %b\n' "$1" >&2
  exit 1
}

FOUND=$(grep -rnE 'UIScreen\.main|userInterfaceIdiom|statusBarOrientation|UIDevice\.current\.orientation|\.interfaceOrientation|UIWindow\(frame:' \
  "$ROOT/iOS" "$ROOT/iOSShare" "$ROOT/iOSWidget" \
  --include='*.swift' || true)
CODE=$(printf '%s\n' "$FOUND" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v '^$' || true)
[ -z "$CODE" ] || fail "The iPhone app must not lay out by the main screen, the idiom or the orientation (docs/iphone-duo.md); read the size classes or the view's own size instead:\n$CODE"
