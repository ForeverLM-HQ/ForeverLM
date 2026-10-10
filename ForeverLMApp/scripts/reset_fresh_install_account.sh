#!/bin/bash
# Puts a throwaway macOS test account back to "never had ForeverLM", so the
# public DMG can be installed and onboarded again as a stranger would.
#
# Run it INSIDE the test account (a Standard user made for this), never in the
# account you use ForeverLM from: the downloaded app is the production bundle,
# com.foreverlm, so everything below is also where your real library lives.
# The script refuses admin accounts for that reason.
#
#   bash reset_fresh_install_account.sh            # reset, then log out
#   bash reset_fresh_install_account.sh --dry-run  # list what would go
#   bash reset_fresh_install_account.sh --icloud   # also empty this account's
#                                                  # ForeverLM iCloud Drive folder
#
# What it cannot reset: CloudKit records and iCloud key-value settings live on
# Apple's servers under the Apple ID. If the test account is signed in to
# iCloud, the next run syncs the previous run's library back down. For a clean
# run every time, leave the test account signed out of iCloud in macOS.
#
# The app keeps its sign-in and keys in the data-protection keychain, which no
# command-line tool can edit. The script removes this account's local-items
# keychain folder instead (macOS rebuilds it at the next login), which is why
# it logs you out at the end. That also forgets anything else this account saved
# there, which is fine for a throwaway account and the other reason it refuses
# admin accounts.

set -uo pipefail
shopt -s nullglob

dry_run=0
include_icloud=0
allow_admin=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=1 ;;
        --icloud) include_icloud=1 ;;
        --allow-admin) allow_admin=1 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $dry_run -eq 0 ]]; then
    if id -Gn | tr ' ' '\n' | grep -qx admin && [[ $allow_admin -eq 0 ]]; then
        echo "Refusing: $(id -un) is an admin account." >&2
        echo "Run this inside the Standard test account, not the one you use ForeverLM from." >&2
        exit 1
    fi
fi

L="$HOME/Library"
targets=(
    "$HOME/Applications/ForeverLM.app"
    "$HOME/Downloads/"ForeverLM*.dmg
    "$HOME/Downloads/"ForeverLM*.zip
    "$L/Application Support/ForeverLM"
    "$L/Application Support/ForeverLM Shared"
    "$L/Application Support/com.foreverlm"*
    "$L/Caches/com.foreverlm"*
    "$L/HTTPStorages/com.foreverlm"*
    "$L/WebKit/com.foreverlm"*
    "$L/Cookies/com.foreverlm"*
    "$L/Saved Application State/com.foreverlm"*
    "$L/Containers/com.foreverlm"*
    "$L/Group Containers/"*.com.foreverlm*
    "$L/Logs/ForeverLM"*
    "$L/Preferences/com.foreverlm"*.plist
)
if [[ $include_icloud -eq 1 ]]; then
    # Never the personal team's retired container, iCloud~com~foreverlm: the
    # apps on the company team (since 2026-10-09) still read the learner's files
    # from it by path, and it is never removed by a script. A throwaway account
    # that once ran a personal-team build keeps that folder; delete it by hand
    # there if a run must not see it. The current container's folder is listed
    # only when this account has one.
    if [[ -d "$L/Mobile Documents/iCloud~com~foreverlm~knowledge" ]]; then
        targets+=("$L/Mobile Documents/iCloud~com~foreverlm~knowledge")
    fi
    targets+=("$L/Mobile Documents/com~apple~CloudDocs/Documents/ForeverLM")
fi
keychain_dirs=()
for dir in "$L/Keychains/"*-*-*-*-*; do
    [[ -d "$dir" ]] && keychain_dirs+=("$dir")
done

echo "Account: $(id -un) ($HOME)"
echo
echo "Will remove:"
for t in "${targets[@]}"; do echo "  $t"; done
for k in "${keychain_dirs[@]}"; do echo "  $k  (local-items keychain)"; done
echo "Will also: quit ForeverLM, delete the com.foreverlm settings, reset its privacy permissions,"
echo "           and delete its items from the login keychain."
if [[ $include_icloud -eq 0 ]]; then
    echo "Keeping this account's ForeverLM iCloud Drive folder (pass --icloud to empty it)."
fi

if [[ $dry_run -eq 1 ]]; then
    echo
    echo "Dry run: nothing was changed."
    exit 0
fi

if [[ -t 0 ]]; then
    echo
    read -r -p "Type reset to continue: " answer
    [[ "$answer" == "reset" ]] || { echo "Cancelled."; exit 1; }
fi

osascript -e 'tell application id "com.foreverlm" to quit' >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -u "$(id -u)" -x ForeverLM >/dev/null || break
    sleep 1
done
pkill -u "$(id -u)" -x ForeverLM 2>/dev/null
pkill -u "$(id -u)" -f PodcastTokenHelper 2>/dev/null

# cfprefsd caches the domain, so delete through defaults before the plist goes.
defaults delete com.foreverlm >/dev/null 2>&1
defaults delete com.foreverlm.podcasttokenhelper >/dev/null 2>&1

for t in "${targets[@]}"; do
    rm -rf "$t"
done

tccutil reset All com.foreverlm >/dev/null 2>&1
tccutil reset All com.foreverlm.podcasttokenhelper >/dev/null 2>&1

while security delete-generic-password -s com.foreverlm >/dev/null 2>&1; do :; done

for k in "${keychain_dirs[@]}"; do
    rm -rf "$k"
done

echo
echo "Reset done. Logging out so the keychain rebuilds; log back in, then download the DMG again."
osascript -e 'tell application "System Events" to log out' >/dev/null 2>&1 \
    || echo "Log out from the Apple menu to finish."
