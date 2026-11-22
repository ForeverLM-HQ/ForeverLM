# Sourced by the schema scripts after they set ROOT. `signing_team` prints the
# Apple team that owns the CloudKit container, for cktool's --team-id:
# FOREVERLM_TEAM_ID when it is set, otherwise the DEVELOPMENT_TEAM the apps sign
# with, from ForeverLMApp/Signing.local.xcconfig. That file is not kept in the
# repository; ForeverLMApp/Config/Signing.xcconfig says what goes in it.
signing_team() {
  local config="$ROOT/ForeverLMApp/Signing.local.xcconfig" team="${FOREVERLM_TEAM_ID:-}"
  if [ -z "$team" ] && [ -f "$config" ]; then
    team="$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ { sub(/\/\/.*/, "", $2); gsub(/[[:space:]]/, "", $2); print $2; exit }' "$config")"
  fi
  if [ -z "$team" ]; then
    echo "No Apple team: set FOREVERLM_TEAM_ID, or DEVELOPMENT_TEAM in ForeverLMApp/Signing.local.xcconfig." >&2
    return 1
  fi
  printf '%s\n' "$team"
}
