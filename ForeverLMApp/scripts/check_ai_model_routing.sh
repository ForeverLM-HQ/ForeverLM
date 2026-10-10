#!/bin/sh
set -eu

# Runs as a build phase of the Mac and iPhone targets. Plain grep, not rg:
# rg is not installed on the build Mac, and with `|| true` every rule here
# silently passed until 2026-10-01.

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

fail() {
  printf 'error: %b\n' "$1" >&2
  exit 1
}

# Only KeychainService.resolveConfig picks a task's model. The other four
# build a config for a model that was already chosen and never pick one:
# AIModelQualification and FreeModelsSetup test a named model,
# AIBackgroundRetry backs a task up with a model the learner listed, and
# ArtifactSharingService drains podcast cleanup on its catalogued model.
CONSTRUCTORS=$(grep -rnE 'AITaskConfig\(' "$ROOT" \
  --include='*.swift' \
  --exclude-dir='.build' --exclude-dir='.derived*' --exclude-dir='build' \
  --exclude-dir='UnitTests' --exclude-dir='iOSUITests' --exclude-dir='node_modules' || true)
if [ -n "$CONSTRUCTORS" ]; then
  OUTSIDE=$(printf '%s\n' "$CONSTRUCTORS" | grep -vE '/(Shared/Services/Storage/KeychainService|App/AIModelQualification|App/FreeModelsSetup|Shared/Services/AI/AIBackgroundRetry|App/ArtifactSharingService)\.swift:' || true)
  [ -z "$OUTSIDE" ] || fail "AITaskConfig may only be built by KeychainService.resolveConfig:\n$OUTSIDE"
fi

LITERALS=$(grep -rnE '(static let|let|var) (model|modelID|anthropicModel)[[:space:]]*=[[:space:]]*"[^"\\]*(gpt|claude|gemini|grok|muse|deepseek|qwen|llama|nemotron|whisper|transcribe|tts)' \
  "$ROOT/App" "$ROOT/Shared" "$ROOT/iOS" --include='*.swift' \
  --exclude='AIModelDefaults*.swift' --exclude='KeychainService.swift' \
  --exclude='*Catalog.swift' --exclude='*Rates.swift' --exclude='*Tests.swift' \
  --exclude='MobileReviewFoundationBrain.swift' || true)
[ -z "$LITERALS" ] || fail "Model literals must live in defaults/catalogs and flow through task resolution:\n$LITERALS"

if grep -nE 'ArticleSpeechCatalog\.fallbackModelIDs|fallBackToOnDevice' \
  "$ROOT/Shared/Services/AI/CloudArticleTTS.swift" "$ROOT/iOS/MobileComposerDictation.swift" >/dev/null; then
  fail "Silent speech or dictation model fallbacks are forbidden."
fi

# The iPhone's layout rule (docs/iphone-duo.md) lives in its own script and is
# run here so the one build phase carries it.
sh "$ROOT/scripts/check_ios_adaptive_layout.sh"
