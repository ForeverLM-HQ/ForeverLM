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

# Only KeychainService.resolveConfig picks a task's model (KeychainService and
# its KeychainService+<Topic>.swift extension files). The other four
# build a config for a model that was already chosen and never pick one:
# AIModelQualification and FreeModelsSetup test a named model,
# AIBackgroundRetry backs a task up with a model the learner listed, and
# ArtifactSharingService drains podcast cleanup on its catalogued model.
CONSTRUCTORS=$(grep -rnE 'AITaskConfig\(' "$ROOT" \
  --include='*.swift' \
  --exclude-dir='.build' --exclude-dir='.derived*' --exclude-dir='build' \
  --exclude-dir='UnitTests' --exclude-dir='iOSUITests' --exclude-dir='node_modules' || true)
if [ -n "$CONSTRUCTORS" ]; then
  OUTSIDE=$(printf '%s\n' "$CONSTRUCTORS" | grep -vE '/(Shared/Services/Storage/KeychainService(\+[A-Za-z]+)?|App/AIModelQualification|App/FreeModelsSetup|Shared/Services/AI/AIBackgroundRetry|App/ArtifactSharingService)\.swift:' || true)
  [ -z "$OUTSIDE" ] || fail "AITaskConfig may only be built by KeychainService.resolveConfig:\n$OUTSIDE"
fi

LITERALS=$(grep -rnE '(static let|let|var) (model|modelID|anthropicModel)[[:space:]]*=[[:space:]]*"[^"\\]*(gpt|claude|gemini|grok|muse|deepseek|qwen|llama|nemotron|whisper|transcribe|tts)' \
  "$ROOT/App" "$ROOT/Shared" "$ROOT/iOS" --include='*.swift' \
  --exclude='AIModelDefaults*.swift' --exclude='KeychainService*.swift' \
  --exclude='*Catalog.swift' --exclude='*Rates.swift' --exclude='*Tests.swift' \
  --exclude='MobileReviewFoundationBrain.swift' || true)
[ -z "$LITERALS" ] || fail "Model literals must live in defaults/catalogs and flow through task resolution:\n$LITERALS"

# Any string literal shaped like an OpenRouter slug (`maker/model`, optionally
# `:variant`) is a model id and belongs in AIModelDefaults (or a *Catalog.swift /
# *Rates.swift table). The makers are the ones AIModelDefaults names.
# AIRoutingModels.swift is exempt by name: it is a display-name table keyed by
# model id, a catalogue by content. Comment lines are not code and are skipped.
SLUGS=$(grep -rnE '"(anthropic|deepseek|google|meta|meta-llama|mistralai|moonshotai|nvidia|openai|openrouter|qwen|thinkingmachines|x-ai|z-ai)/[A-Za-z0-9._-]+(:[a-z]+)?"' \
  "$ROOT/App" "$ROOT/Shared" "$ROOT/MCP" "$ROOT/iOS" --include='*.swift' \
  --exclude='AIModelDefaults*.swift' --exclude='KeychainService*.swift' \
  --exclude='*Catalog.swift' --exclude='*Rates.swift' --exclude='*Tests.swift' \
  --exclude='MobileReviewFoundationBrain.swift' --exclude='AIRoutingModels.swift' \
  | grep -vE '^[^:]*:[0-9]+:[[:space:]]*//' || true)

# Known, to be moved into AIModelDefaults: a file's count of slug lines may only
# go down. A file not listed here may have none. Lower a number as a file is
# cleaned, and delete its line at zero.
KNOWN_SLUG_FILES='App/SettingsChatModels.swift 1
Shared/Services/AI/AIDataPolicy.swift 4
Shared/Services/AI/AIService+ContextBudget.swift 8
Shared/Services/AI/AIUsageReporting.swift 4
Shared/Services/AI/ManagedAI.swift 2
Shared/Services/AI/ManagedTranscriptionClient.swift 21'
if [ -n "$SLUGS" ]; then
  # The lines of every file that holds more slug lines than its allowance.
  OVER=$(printf '%s\n' "$SLUGS" | KNOWN="$KNOWN_SLUG_FILES" awk -F: -v root="$ROOT/" '
    BEGIN {
      n = split(ENVIRON["KNOWN"], rows, "\n")
      for (i = 1; i <= n; i++) { split(rows[i], f, " "); allowed[f[1]] = f[2] }
    }
    { file = $1; sub("^" root, "", file); count[file]++; line[NR] = $0; owner[NR] = file }
    END {
      for (i = 1; i <= NR; i++) {
        file = owner[i]
        if (count[file] > (file in allowed ? allowed[file] : 0)) print line[i]
      }
    }')
  [ -z "$OVER" ] || fail "Model ids (OpenRouter slugs) must live in AIModelDefaults or a *Catalog.swift table and flow through task resolution:\n$OVER"
fi

if grep -nE 'ArticleSpeechCatalog\.fallbackModelIDs|fallBackToOnDevice' \
  "$ROOT/Shared/Services/AI/CloudArticleTTS.swift" "$ROOT/iOS/MobileComposerDictation.swift" >/dev/null; then
  fail "Silent speech or dictation model fallbacks are forbidden."
fi

# The iPhone's layout rule (docs/iphone-duo.md) lives in its own script and is
# run here so the one build phase carries it.
sh "$ROOT/scripts/check_ios_adaptive_layout.sh"
