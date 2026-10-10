#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

export FOREVERLM_LIVE_API_TESTS=1

echo "Running billable ForeverLM live API integration tests..."
echo "Authentication: signed-in Debug app Keychain session or FOREVERLM_MANAGED_SESSION_TOKEN"
if [[ "${FOREVERLM_LIVE_IMAGE_TESTS:-0}" == "1" ]]; then
  echo "Cloud image generation is enabled and may cost more than the default smoke suite."
else
  echo "Cloud image generation is disabled; set FOREVERLM_LIVE_IMAGE_TESTS=1 to include it."
fi

bash "${SCRIPT_DIR}/xcb.sh" test \
  -project "${APP_DIR}/ForeverLM.xcodeproj" \
  -scheme "ForeverLM (macOS)" \
  -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:ForeverLMMacUnitTests/LiveAPIIntegrationTests
