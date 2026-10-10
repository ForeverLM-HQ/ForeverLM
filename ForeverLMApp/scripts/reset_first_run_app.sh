#!/bin/bash
# Puts the First Run app (com.foreverlm.dev.firstrun, installed at
# ~/Applications/FirstRunLM.app) back to never having been opened, so
# the next launch walks through onboarding exactly as a new learner would.
#
#   bash reset_first_run_app.sh            # asks, then resets
#   bash reset_first_run_app.sh --yes      # no question (build_dev.sh --first-run --launch)
#   bash reset_first_run_app.sh --launch   # reset, then open the installed copy
#   bash reset_first_run_app.sh --dry-run  # list what would go
#
# Everything below belongs to the First Run app alone: its bundle identifier,
# product folder and keychain service are its own (ForeverLMRuntimeIdentity),
# so neither the Dev library nor the installed ForeverLM is touched. It does not
# delete the app itself.
#
# Two things only the app can clear, and how they are handled:
# - Its sign-in and keys live in the data-protection keychain under an access
#   group only the signed app can open. The script leaves a marker in the
#   emptied library folder; FirstRunFreshStart sees it at the next launch and
#   deletes every keychain item under the app's own service before anything
#   reads one.
# - CloudKit would hand the Dev library straight back, which is why the First
#   Run app never starts the sync engine. Its iCloud Drive folder is removed
#   here like any other.
#
# What it cannot reset: Sign in with Apple remembers that this Apple ID already
# approved ForeverLM, so the sign-in sheet says "Continue" rather than asking to
# share an email. Stop using Apple ID with the app in System Settings → Apple
# Account → Sign in with Apple to see the sheet a stranger sees.

set -uo pipefail
shopt -s nullglob

BUNDLE_ID=com.foreverlm.dev.firstrun
# PRODUCT names the app's data (its folder under Application Support, in iCloud
# Documents and in Logs); the app file has its own, shorter name.
PRODUCT="ForeverLM First Run"
APP="$HOME/Applications/FirstRunLM.app"
L="$HOME/Library"
# Keep in step with FirstRunFreshStart.markerURL.
MARKER="$L/Application Support/$PRODUCT/.fresh-start-requested"

dry_run=0
assume_yes=0
launch=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=1 ;;
        --yes) assume_yes=1 ;;
        --launch) launch=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# The personal team's retired iCloud container. The apps only read it by path
# since the move to the company team (2026-10-09); production's own `ForeverLM`
# folder there holds most of the learner's files and must never be removed.
# Only the First Run app's folder beside it, from runs of a personal-team build,
# is cleared, and the guard below refuses anything else.
OLD_CONTAINER_DOCUMENTS="$L/Mobile Documents/iCloud~com~foreverlm/Documents"

targets=(
    "$L/Application Support/$PRODUCT"
    "$L/Application Support/$BUNDLE_ID"
    "$OLD_CONTAINER_DOCUMENTS/$PRODUCT"
    "$L/Mobile Documents/com~apple~CloudDocs/Documents/$PRODUCT"
    "$L/Caches/$BUNDLE_ID"
    "$L/HTTPStorages/$BUNDLE_ID"
    "$L/HTTPStorages/$BUNDLE_ID.binarycookies"
    "$L/WebKit/$BUNDLE_ID"
    "$L/Cookies/$BUNDLE_ID.binarycookies"
    "$L/Saved Application State/$BUNDLE_ID.savedState"
    "$L/Logs/$PRODUCT"
    "$L/Preferences/$BUNDLE_ID.plist"
)

# Every target must be the First Run app's own: never the production or Dev
# product folder, and never the old container or a folder above one of them.
for t in "${targets[@]}"; do
    case "$t" in
        *"/$PRODUCT"|*"/$PRODUCT/"*|*"/$BUNDLE_ID"|*"/$BUNDLE_ID".*) ;;
        *) echo "Refusing: $t is not the First Run app's own folder." >&2; exit 1 ;;
    esac
done

echo "Resetting $PRODUCT ($BUNDLE_ID) to never opened."
echo "Will remove whichever of these exist:"
for t in "${targets[@]}"; do
    [[ -e "$t" ]] && echo "  $t"
done
echo "Will also: quit the app, delete its settings, reset its privacy permissions,"
echo "           and have its next launch clear its keychain items."

if [[ $dry_run -eq 1 ]]; then
    echo "Dry run: nothing was changed."
    exit 0
fi

if [[ $assume_yes -eq 0 && -t 0 ]]; then
    read -r -p "Type reset to continue: " answer
    [[ "$answer" == "reset" ]] || { echo "Cancelled."; exit 1; }
fi

# By bundle identifier, not pgrep -x: the process name is cut to 16 characters,
# so "ForeverLM First Run" never matches its own name.
is_running() {
    [[ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null)" == "true" ]]
}
if is_running; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
fi
for _ in 1 2 3 4 5 6 7 8 9 10; do
    is_running || break
    sleep 1
done
if is_running; then
    echo "$PRODUCT did not quit; quit it and run this again." >&2
    exit 1
fi

# cfprefsd caches the domain, so delete through defaults before the plist goes.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1

for t in "${targets[@]}"; do
    rm -rf "$t"
done

tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1

mkdir -p "$(dirname "$MARKER")"
: > "$MARKER"

echo "Reset done. The next launch of $PRODUCT is a first launch."

if [[ $launch -eq 1 ]]; then
    [[ -d "$APP" ]] || { echo "$APP is not installed yet." >&2; exit 1; }
    open -a "$APP"
fi
