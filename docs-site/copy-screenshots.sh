#!/bin/bash
# Copy App Store screenshots into the docs site public directory.
# Run after generating new screenshots with the UI test suites.
# These are the same images submitted to developer.apple.com.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/ForeverLMApp/Screenshots"
DST="$REPO/docs-site/public/screenshots"

mkdir -p "$DST"

# One hero screenshot per platform
cp "$SRC/iOS/05_studio.png"           "$DST/ios.png"
cp "$SRC/iPad/05_studio.png"          "$DST/ipad.png"
cp "$SRC/macOS/01_studio.png"         "$DST/macos.png"
cp "$SRC/visionOS/01_studio.png"      "$DST/visionos.png"

echo "Copied screenshots to $DST:"
ls -lh "$DST"
