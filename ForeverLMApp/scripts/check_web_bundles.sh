#!/bin/bash
# Checks that the web bundles committed under ForeverLMApp/App/*Resources are
# what their sources build today, and that every duplicate copy of a bundle
# matches.
#
# Each bundle's own build script (ForeverLMApp/Web/<Name>/build.mjs) writes into
# the tree. This script never does: it copies the sources into a temporary tree
# with the same layout, runs the real build scripts there, and compares the
# result with the committed files. The temporary tree is removed on exit.
#
#   ForeverLMApp/scripts/check_web_bundles.sh
#
# Checked, when its inputs exist in this checkout:
#   ArtifactEditor  App/ArtifactEditorResources            and docs-site/website/library/artifact-editor
#   ChatRenderer    App/ChatRendererResources              and docs-site/website/library/chat-renderer
#                   (+ the KaTeX copies in docs-site/website/library/vendor/katex)
#   PublishedPage   App/PublishedPageResources             (built from docs-site/website/publishing)
#   KnowledgeMap    App/KnowledgeMapResources              (a copy of Web/KnowledgeMap)
#
# The website folders are not part of this repository; a copy of them that is
# missing is reported as skipped, not as a failure. A bundle whose
# node_modules is missing is installed from its lockfile inside the temporary
# tree (`npm ci`, which needs the network); if that fails the bundle is skipped.
#
# Exit status: 0 when every checked bundle matches, 1 when any differs or fails
# to build. Skipped bundles are listed at the end and do not fail the run.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check_web_bundles.XXXXXX")" || exit 1
trap 'rm -rf "${TMP}"' EXIT

failed=0
checked=()
skipped=()

# The temporary tree mirrors the repository layout the build scripts expect.
mkdir -p "${TMP}/ForeverLMApp/Web" "${TMP}/ForeverLMApp/App"

fail() { echo "FAIL  $1"; failed=1; }
ok() { echo "ok    $1"; }
skip() { echo "skip  $1"; skipped+=("$1"); }

# stage <Name>: copies Web/<Name> without node_modules and links or installs them.
stage() {
  local name="$1" source="${ROOT}/ForeverLMApp/Web/$1" target="${TMP}/ForeverLMApp/Web/$1"
  rsync -a --exclude node_modules --exclude e2e --exclude test "${source}/" "${target}/" || return 1
  if [ -f "${source}/package-lock.json" ]; then
    if [ -d "${source}/node_modules" ]; then
      ln -s "${source}/node_modules" "${target}/node_modules"
    elif ! (cd "${target}" && npm ci --ignore-scripts --no-audit --no-fund >/dev/null 2>&1); then
      return 1
    fi
  fi
  return 0
}

# compare <label> <committed> <fresh>: byte-for-byte, files and folders.
compare() {
  local label="$1" committed="$2" fresh="$3"
  if [ ! -e "${committed}" ]; then
    skip "${label}: ${committed#${ROOT}/} is not in this checkout"
    return
  fi
  if diff -rq "${committed}" "${fresh}" >"${TMP}/diff.out" 2>&1; then
    ok "${label}"
  else
    fail "${label} differs from a fresh build"
    sed 's/^/        /' "${TMP}/diff.out" | head -20
  fi
}

# build <Name>: runs the bundle's own build in the temporary tree.
build() {
  (cd "${TMP}/ForeverLMApp/Web/$1" && node build.mjs >"${TMP}/build-$1.log" 2>&1)
}

command -v node >/dev/null || { echo "node is not installed"; exit 1; }

SITE="${ROOT}/docs-site/website"
mkdir -p "${TMP}/docs-site/website/library/vendor/katex" \
         "${TMP}/docs-site/website/library/artifact-editor" \
         "${TMP}/docs-site/website/library/chat-renderer"

# ArtifactEditor: also writes a copy for the website.
name=ArtifactEditor
if ! stage "${name}"; then
  skip "${name}: node_modules missing and npm ci failed"
elif ! build "${name}"; then
  fail "${name}: build failed"; sed 's/^/        /' "${TMP}/build-${name}.log" | tail -10
else
  checked+=("${name}")
  compare "${name} -> App/ArtifactEditorResources" \
    "${ROOT}/ForeverLMApp/App/ArtifactEditorResources" "${TMP}/ForeverLMApp/App/ArtifactEditorResources"
  compare "${name} -> website copy" \
    "${SITE}/library/artifact-editor" "${TMP}/docs-site/website/library/artifact-editor"
fi

# ChatRenderer: needs the website's picture-reference parser as a source.
name=ChatRenderer
if [ ! -f "${SITE}/library/library-source-images.js" ]; then
  skip "${name}: docs-site/website/library/library-source-images.js is not in this checkout"
elif ! stage "${name}"; then
  skip "${name}: node_modules missing and npm ci failed"
else
  cp "${SITE}/library/library-source-images.js" "${TMP}/docs-site/website/library/"
  if ! build "${name}"; then
    fail "${name}: build failed"; sed 's/^/        /' "${TMP}/build-${name}.log" | tail -10
  else
    checked+=("${name}")
    compare "${name} -> App/ChatRendererResources" \
      "${ROOT}/ForeverLMApp/App/ChatRendererResources" "${TMP}/ForeverLMApp/App/ChatRendererResources"
    compare "${name} -> website copy" \
      "${SITE}/library/chat-renderer" "${TMP}/docs-site/website/library/chat-renderer"
    compare "${name} -> website KaTeX copy" \
      "${SITE}/library/vendor/katex" "${TMP}/docs-site/website/library/vendor/katex"
  fi
fi

# PublishedPage: built from the website's publishing sources.
name=PublishedPage
if [ ! -d "${SITE}/publishing" ]; then
  skip "${name}: docs-site/website/publishing is not in this checkout"
elif ! stage "${name}"; then
  skip "${name}: node_modules missing and npm ci failed"
else
  rsync -a "${SITE}/publishing/" "${TMP}/docs-site/website/publishing/"
  # esbuild reads the website's tsconfig.json (strict mode adds "use strict"), so
  # the temporary tree needs it where the real build finds it.
  for config in tsconfig.json package.json; do
    [ -f "${SITE}/${config}" ] && cp "${SITE}/${config}" "${TMP}/docs-site/website/${config}"
  done
  if ! build "${name}"; then
    fail "${name}: build failed"; sed 's/^/        /' "${TMP}/build-${name}.log" | tail -10
  else
    checked+=("${name}")
    compare "${name} -> App/PublishedPageResources" \
      "${ROOT}/ForeverLMApp/App/PublishedPageResources" "${TMP}/ForeverLMApp/App/PublishedPageResources"
  fi
fi

# KnowledgeMap: a plain copy of Web/KnowledgeMap/src, no dependencies.
name=KnowledgeMap
if ! stage "${name}"; then
  skip "${name}: could not stage"
elif ! build "${name}"; then
  fail "${name}: build failed"; sed 's/^/        /' "${TMP}/build-${name}.log" | tail -10
else
  checked+=("${name}")
  compare "${name} -> App/KnowledgeMapResources" \
    "${ROOT}/ForeverLMApp/App/KnowledgeMapResources" "${TMP}/ForeverLMApp/App/KnowledgeMapResources"
  # The sources themselves must match the copies, not only the build's output.
  for pair in "knowledge-map.js:src/knowledge-map.js" "knowledge-map.css:src/knowledge-map.css" \
              "mac-host.js:src/mac-host.js" "knowledge-map.html:knowledge-map.html"; do
    committed="${pair%%:*}"; sourcePath="${pair#*:}"
    if cmp -s "${ROOT}/ForeverLMApp/App/KnowledgeMapResources/${committed}" \
              "${ROOT}/ForeverLMApp/Web/KnowledgeMap/${sourcePath}"; then
      ok "KnowledgeMap duplicate ${committed}"
    else
      fail "KnowledgeMap: App/KnowledgeMapResources/${committed} differs from Web/KnowledgeMap/${sourcePath}"
    fi
  done
fi

echo
echo "built and compared: ${checked[*]:-none}"
if [ "${#skipped[@]}" -gt 0 ]; then
  echo "skipped: ${#skipped[@]}"
fi
if [ "${failed}" -ne 0 ]; then
  echo "RESULT: committed bundles are out of date or do not build"
  exit 1
fi
echo "RESULT: every checked bundle matches a fresh build"
