#!/bin/bash
# Reads build-time infrastructure secrets from ../.env and generates
# Shared/Secrets.generated.swift.
#
# User API keys are intentionally not read from .env. They must be entered in
# Settings and stored in the macOS Keychain.
# Run as an Xcode Build Phase script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ENV_FILE="${SRCROOT}/../.env"
OUTPUT_FILE="${SRCROOT}/Shared/Utilities/Secrets.generated.swift"
# The repo lives in iCloud Drive, where a gitignored file can vanish without
# anyone touching it — three times so far, the last (2026-08-19) failing a
# release at the archive step because .env was simply gone. Mirror a populated
# .env outside the synced tree, and restore from that mirror when the original
# is missing, so the loss costs a warning instead of a rotation.
BACKUP_FILE="${HOME}/Library/Application Support/ForeverLM/build-secrets.env"

# CI and local release tooling may inject these through the process environment.
# A repo-root .env, when present, remains authoritative and overrides them below.
YOUTUBE_OAUTH_CLIENT_ID="${YOUTUBE_OAUTH_CLIENT_ID:-}"
YOUTUBE_OAUTH_CLIENT_SECRET="${YOUTUBE_OAUTH_CLIENT_SECRET:-}"
DRIVE_OAUTH_CLIENT_ID="${DRIVE_OAUTH_CLIENT_ID:-}"
DRIVE_OAUTH_CLIENT_SECRET="${DRIVE_OAUTH_CLIENT_SECRET:-}"
CALENDAR_OAUTH_CLIENT_ID="${CALENDAR_OAUTH_CLIENT_ID:-}"
CALENDAR_OAUTH_CLIENT_SECRET="${CALENDAR_OAUTH_CLIENT_SECRET:-}"

if [ ! -f "$ENV_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    if cp "$BACKUP_FILE" "$ENV_FILE" 2>/dev/null; then
        chmod 600 "$ENV_FILE" 2>/dev/null
        echo "[generate_secrets] Warning: $ENV_FILE was missing; restored it from $BACKUP_FILE"
    fi
fi

if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        case "$key" in
            YOUTUBE_OAUTH_CLIENT_ID) YOUTUBE_OAUTH_CLIENT_ID="$value" ;;
            YOUTUBE_OAUTH_CLIENT_SECRET) YOUTUBE_OAUTH_CLIENT_SECRET="$value" ;;
            DRIVE_OAUTH_CLIENT_ID) DRIVE_OAUTH_CLIENT_ID="$value" ;;
            DRIVE_OAUTH_CLIENT_SECRET) DRIVE_OAUTH_CLIENT_SECRET="$value" ;;
            CALENDAR_OAUTH_CLIENT_ID) CALENDAR_OAUTH_CLIENT_ID="$value" ;;
            CALENDAR_OAUTH_CLIENT_SECRET) CALENDAR_OAUTH_CLIENT_SECRET="$value" ;;
        esac
    done < "$ENV_FILE"
    echo "[generate_secrets] Read build-time infrastructure secrets from $ENV_FILE"
    if [ -n "${YOUTUBE_OAUTH_CLIENT_ID}${YOUTUBE_OAUTH_CLIENT_SECRET}${DRIVE_OAUTH_CLIENT_ID}${DRIVE_OAUTH_CLIENT_SECRET}" ] \
       && ! cmp -s "$ENV_FILE" "$BACKUP_FILE"; then
        if mkdir -p "$(dirname "$BACKUP_FILE")" 2>/dev/null && cp "$ENV_FILE" "$BACKUP_FILE" 2>/dev/null; then
            chmod 600 "$BACKUP_FILE" 2>/dev/null
            echo "[generate_secrets] Mirrored build secrets to $BACKUP_FILE"
        fi
    fi
else
    echo "[generate_secrets] Warning: $ENV_FILE not found, generating empty secrets"
fi

case "${CONFIGURATION:-Debug}" in
    Debug|*Debug)
        REQUIRE_SHIPPING_SECRETS=false
        ;;
    *)
        REQUIRE_SHIPPING_SECRETS=true
        ;;
esac

# MCP_BEARER_TOKEN is gone (2026-09-29). It was one provisioning secret baked
# into every release binary, so anyone holding the app held it too; the tunnel
# provisioner now authorizes the learner's own Sign in with Apple session
# instead (workers/tunnel-provisioner). A value left in an old .env is ignored.

# The YouTube plugin authenticates against a ForeverLM-owned OAuth client so
# users never paste their own credentials. A release build without it would
# silently fall back to the bring-your-own-client path, which is exactly
# the confusing behaviour this client replaces — so fail the build instead.
if [ "$REQUIRE_SHIPPING_SECRETS" = true ] && { [ -z "$YOUTUBE_OAUTH_CLIENT_ID" ] || [ -z "$YOUTUBE_OAUTH_CLIENT_SECRET" ]; }; then
    echo "[generate_secrets] Error: YOUTUBE_OAUTH_CLIENT_ID and YOUTUBE_OAUTH_CLIENT_SECRET are required for ${CONFIGURATION} builds." >&2
    echo "[generate_secrets] Copy them from the 'ForeverLM YouTube (Desktop)' OAuth client in the ForeverLM Google Cloud project into the repo root .env — see docs/google-cloud-plugins.md." >&2
    exit 1
fi

GENERATED_CONTENT=$(cat << EOF
// Auto-generated from build-time infrastructure secrets — DO NOT EDIT
// This file is gitignored
import Foundation

enum Secrets {
    /// The ForeverLM-owned Google OAuth client for the YouTube plugin. Empty
    /// in Debug builds without a populated .env, which leaves the plugin on
    /// the user-supplied credentials path.
    ///
    /// This is a Google "Desktop app" client: Google documents such a secret as
    /// non-confidential, and the flow is protected by PKCE, so shipping it in
    /// the binary is expected rather than a leak.
    static let youtubeOAuthClientID = "$YOUTUBE_OAUTH_CLIENT_ID"
    static let youtubeOAuthClientSecret = "$YOUTUBE_OAUTH_CLIENT_SECRET"

    /// Optional Google Drive-specific desktop client. When empty, Drive uses
    /// the YouTube desktop client above in a separate read-only Drive flow.
    static let driveOAuthClientID = "$DRIVE_OAUTH_CLIENT_ID"
    static let driveOAuthClientSecret = "$DRIVE_OAUTH_CLIENT_SECRET"

    /// Optional Google Calendar-specific desktop client. When empty, the
    /// Planner calendar import uses the YouTube desktop client above in a
    /// separate read-only Calendar flow.
    static let calendarOAuthClientID = "$CALENDAR_OAUTH_CLIENT_ID"
    static let calendarOAuthClientSecret = "$CALENDAR_OAUTH_CLIENT_SECRET"
}
EOF
)

# A Debug build with no secrets available used to blank a populated generated
# file, which is how the only surviving copy of these values was destroyed. An
# empty result never overwrites a populated one; Release builds have already
# failed above when a required secret is missing.
if [ -z "${YOUTUBE_OAUTH_CLIENT_ID}${YOUTUBE_OAUTH_CLIENT_SECRET}${DRIVE_OAUTH_CLIENT_ID}${DRIVE_OAUTH_CLIENT_SECRET}" ] \
   && [ -f "$OUTPUT_FILE" ] && grep -qE '= "[^"]+"' "$OUTPUT_FILE"; then
    echo "[generate_secrets] Warning: no secrets available; keeping the populated $OUTPUT_FILE rather than blanking it" >&2
    exit 0
fi

if [ -f "$OUTPUT_FILE" ] && printf "%s\n" "$GENERATED_CONTENT" | cmp -s "$OUTPUT_FILE" -; then
    echo "[generate_secrets] Unchanged $OUTPUT_FILE"
else
    printf "%s\n" "$GENERATED_CONTENT" > "$OUTPUT_FILE"
    echo "[generate_secrets] Generated $OUTPUT_FILE"
fi
