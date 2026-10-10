#!/bin/bash
set -euo pipefail

# ─── Why this exists ──────────────────────────────────────────────────────────
# A Dev build produced with CODE_SIGNING_ALLOWED=NO is ad-hoc, linker-signed, and
# carries no entitlements at all — `codesign -dvvv` reports "Signature=adhoc" and
# "TeamIdentifier=not set". AppleSignInSupport reads com.apple.developer.applesignin
# off the running process before it will present Apple's sheet, finds nothing, and
# walls the whole app behind "can’t use Sign in with Apple". Nothing downstream of
# an account works in that build: no managed AI, no MCP tunnel identity, and no
# iCloud sync either, because the same missing signature drops the CloudKit
# entitlement. The build looks fine; it just cannot be signed in to.
#
# Signing the Debug configuration needs the team's Mac Development profile for
# com.foreverlm.dev, and plain automatic signing cannot fetch it here: this Mac has
# no Apple ID in Xcode's Accounts settings, so xcodebuild fails with "No Accounts".
# That is what the CODE_SIGNING_ALLOWED=NO habit was working around.
#
# The App Store Connect API key already in the repo-root .env stands in for that
# account. -allowProvisioningUpdates with -authenticationKey* lets xcodebuild pull
# the profile straight from the portal, no sign-in and no password. Portal *writes*
# with that key still return 403 (see docs/releasing.md), so this only works while
# the profile and its App ID already exist on the team — they do, and the profile
# renews on read.
#
# Signing the build is only half of it. Test runs and verification builds keep
# writing ad-hoc "DevLM.app" bundles into one DerivedData directory or
# another, all registered with LaunchServices under com.foreverlm.dev, and Spotlight
# or `open -b` will happily pick one of those — which is how a freshly signed build
# still ends at the "ad-hoc signed" wall an hour later. So the verified product is
# installed at ~/Applications/DevLM.app, a path nothing else writes, and
# that is the copy to launch, put in the Dock, and hand to LaunchServices. The app
# knows the path too: an ad-hoc Dev copy offers to open the installed one.
#
# Usage:
#   ./scripts/build_dev.sh                     # build, verify, install to ~/Applications
#   ./scripts/build_dev.sh --launch            # ...quit running Dev copies, open the installed one
#   ./scripts/build_dev.sh --no-install        # leave the product in DerivedData
#   ./scripts/build_dev.sh --derived-data DIR  # keep a worktree out of the shared cache
#   ./scripts/build_dev.sh --first-run         # the First Run app instead (see below)
#   ./scripts/build_dev.sh --first-run --launch  # ...reset it to never-opened, then open it
#
# The First Run app (FirstRunDebug configuration, com.foreverlm.dev.firstrun) is
# a second Dev app that opens as a stranger's first launch: its own library,
# settings, keychain, privacy permissions and a green NEW badge, and CloudKit
# sync off so it never downloads the seeded Dev library. It installs at
# ~/Applications/FirstRunLM.app. Installing a new build keeps whatever
# onboarding is in progress; --launch, or scripts/reset_first_run_app.sh on its
# own, wipes it back to a first launch.
# ──────────────────────────────────────────────────────────────────────────────

LAUNCH=false
INSTALL=true
DERIVED_DATA=""
FIRST_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --launch)       LAUNCH=true; shift ;;
        --no-install)   INSTALL=false; shift ;;
        --derived-data) DERIVED_DATA="${2:-}"; shift 2 ;;
        --first-run)    FIRST_RUN=true; shift ;;
        *) echo "usage: $0 [--first-run] [--launch] [--no-install] [--derived-data DIR]" >&2; exit 1 ;;
    esac
done

if [ "${FIRST_RUN}" = true ]; then
    CONFIGURATION=FirstRunDebug
    APP_NAME="FirstRunLM"
    RENAMED_FROM="ForeverLM First Run"
    BUNDLE_ID=com.foreverlm.dev.firstrun
else
    CONFIGURATION=Debug
    APP_NAME="DevLM"
    RENAMED_FROM="ForeverLM Dev"
    BUNDLE_ID=com.foreverlm.dev
fi

INSTALL_DIR="${HOME}/Applications"
INSTALLED_APP="${INSTALL_DIR}/${APP_NAME}.app"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/.." && pwd)"
SCHEME="ForeverLM (macOS)"

info() { echo "▸ $*"; }
pass() { echo "  ✓ $*"; }
die()  { echo "  ✗ $*" >&2; exit 1; }

# ─── Toolchain ────────────────────────────────────────────────────────────────
# `xcode-select` can point at the Command Line Tools, which have no xcodebuild at
# all. Switching it back needs an admin password this account does not have, so
# find a real Xcode instead of failing with a message about developer directories.
if ! xcodebuild -version >/dev/null 2>&1; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -x "${candidate}/Contents/Developer/usr/bin/xcodebuild" ]; then
            export DEVELOPER_DIR="${candidate}/Contents/Developer"
            break
        fi
    done
    xcodebuild -version >/dev/null 2>&1 \
        || die "no usable Xcode: xcode-select points at $(xcode-select -p) and no Xcode.app was found"
    info "using ${DEVELOPER_DIR}"
fi

# ─── App Store Connect key ────────────────────────────────────────────────────
if [ -z "${APPLE_API_KEY_ID:-}" ] && [ -f "${REPO_ROOT}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/.env"
    set +a
fi

AUTH=()
if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
    [ -f "${APPLE_API_KEY_PATH}" ] || die "APPLE_API_KEY_PATH does not exist"
    AUTH=(
        -authenticationKeyPath "${APPLE_API_KEY_PATH}"
        -authenticationKeyID "${APPLE_API_KEY_ID}"
        -authenticationKeyIssuerID "${APPLE_API_ISSUER_ID}"
    )
else
    # An Xcode account, if one is ever added, covers the same ground on its own.
    info "no App Store Connect key in the environment or .env — relying on Xcode's own account"
fi

"${PROJECT_DIR}/scripts/sync_project.sh"

BUILD_ARGS=(
    -project "${PROJECT_DIR}/ForeverLM.xcodeproj"
    -scheme "${SCHEME}"
    -configuration "${CONFIGURATION}"
    -destination 'platform=macOS,arch=arm64'
    -allowProvisioningUpdates
    -allowProvisioningDeviceRegistration
)
[ -n "${DERIVED_DATA}" ] && BUILD_ARGS+=(-derivedDataPath "${DERIVED_DATA}")

info "building ${SCHEME} (${CONFIGURATION}), signed"
bash "${PROJECT_DIR}/scripts/xcb.sh" "${BUILD_ARGS[@]}" ${AUTH[@]+"${AUTH[@]}"} build

PRODUCT_DIR=$(bash "${PROJECT_DIR}/scripts/xcb.sh" "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
PRODUCT_NAME=$(bash "${PROJECT_DIR}/scripts/xcb.sh" "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ FULL_PRODUCT_NAME = /{print $2; exit}')
APP="${PRODUCT_DIR}/${PRODUCT_NAME}"
[ -d "${APP}" ] || die "built product not found at ${APP}"

# ─── The check that is the whole point ────────────────────────────────────────
# A build that silently lost its signature is exactly the failure this script
# exists to prevent, so refuse to hand one over as if it were fine.
ENTITLEMENTS=$(codesign -d --entitlements - --xml "${APP}" 2>/dev/null | plutil -p - 2>/dev/null || true)
grep -q "com.apple.developer.applesignin" <<<"${ENTITLEMENTS}" \
    || die "${APP} has no Sign in with Apple entitlement — it still cannot sign in"
grep -q "com.apple.developer.team-identifier" <<<"${ENTITLEMENTS}" \
    || die "${APP} is not signed by the team — it still cannot sign in"
pass "signed with Sign in with Apple and iCloud entitlements"
codesign -dvvv "${APP}" 2>&1 | sed -n 's/^\(Authority=Apple Development.*\)/  \1/p'
echo "  ${APP}"

# ─── Install ──────────────────────────────────────────────────────────────────
# Stage next to the destination and swap directories, so a copy that is running
# from the installed path keeps its own bundle until it quits instead of having
# files replaced underneath it, and a failed copy never leaves a half-written app.
if [ "${INSTALL}" = true ]; then
    info "installing to ${INSTALLED_APP}"
    mkdir -p "${INSTALL_DIR}"
    STAGING="${INSTALL_DIR}/.${APP_NAME}.app.staging.$$"
    RETIRED="${INSTALL_DIR}/.${APP_NAME}.app.retired.$$"
    rm -rf "${STAGING}" "${RETIRED}"
    ditto "${APP}" "${STAGING}"
    [ -d "${INSTALLED_APP}" ] && mv "${INSTALLED_APP}" "${RETIRED}"
    mv "${STAGING}" "${INSTALLED_APP}"
    rm -rf "${RETIRED}"
    # The app was installed as "${RENAMED_FROM}.app" before it got its short name
    # (2026-10-06). A copy left under the old name would keep appearing in app
    # pickers and in LaunchServices beside this one, so it goes. Delete this step
    # once every Mac has installed a build under the new name.
    rm -rf "${INSTALL_DIR}/${RENAMED_FROM}.app"
    codesign --verify --deep --strict "${INSTALLED_APP}" 2>/dev/null \
        || die "${INSTALLED_APP} did not survive the copy with a valid signature"
    pass "installed; launch this copy, not the one in DerivedData"
    echo "  ${INSTALLED_APP}"
    APP="${INSTALLED_APP}"
fi

if [ "${LAUNCH}" = true ]; then
    # Quit whatever Dev copies are already running first — the previous installed
    # build, a DerivedData product a test run left behind, a worktree's build. `open`
    # on a bundle whose identifier is already running only brings that old instance
    # forward, so without this step the new build never actually starts, and every
    # verification run adds one more Dev app to the Dock. The helper sends each
    # instance the same quit Apple Event the Dock does, so windows close normally
    # instead of being restored en masse on the next launch; only a copy that
    # ignores Quit is force-terminated. `swift` cannot interpret the script (its JIT
    # fails to load AppKit), so compile it; that takes well under a second.
    QUIT_HELPER="$(mktemp -d)/quit_dev_instances"
    xcrun swiftc -O -framework AppKit "${PROJECT_DIR}/scripts/quit_dev_instances.swift" -o "${QUIT_HELPER}" \
        || die "could not build scripts/quit_dev_instances.swift"
    info "quitting running ${APP_NAME} instances"
    "${QUIT_HELPER}" "${BUNDLE_ID}" 15 || die "a running ${APP_NAME} instance would not quit"
    rm -rf "$(dirname "${QUIT_HELPER}")"

    # Launching the First Run app means walking through a first launch, so it
    # starts from nothing every time: an onboarding left half done by the last
    # walk-through would show a screen no new learner ever sees.
    if [ "${FIRST_RUN}" = true ]; then
        bash "${PROJECT_DIR}/scripts/reset_first_run_app.sh" --yes \
            || die "could not reset the First Run app"
    fi

    # Launch by path. `open -b com.foreverlm.dev` hands LaunchServices the choice
    # between every Dev copy this Mac has ever seen, which is how a stale bundle
    # ends up in front of you with Full Disk Access it no longer has.
    # A launch from here is a verification run, not the learner sitting down: the
    # windows it opens must not become the arrangement the next launch puts back.
    # On 2026-09-06 a Dev library quit with seven windows that driving sessions
    # had opened, and every launch the next morning restored six of them. With
    # the variable set the app neither restores nor saves the last session; a
    # Dock launch, which has no such variable, behaves as it does for the learner.
    info "launching ${APP}"
    open -a "${APP}" --env FOREVERLM_LAST_SESSION=0
fi
