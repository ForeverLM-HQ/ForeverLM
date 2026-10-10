#!/usr/bin/env node

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const docsRoot = dirname(fileURLToPath(import.meta.url))
const repoRoot = dirname(docsRoot)

function fail(message) {
  console.error(`Docs audit failed: ${message}`)
  process.exitCode = 1
}

function walkFiles(root, predicate) {
  const files = []
  for (const entry of readdirSync(root)) {
    if (entry === 'node_modules' || entry === '.vitepress' || entry === 'public') continue
    const path = join(root, entry)
    const stats = statSync(path)
    if (stats.isDirectory()) files.push(...walkFiles(path, predicate))
    else if (predicate(path)) files.push(path)
  }
  return files
}

function normalizedPage(path) {
  const value = path.replace(/^\/+|\/+$/g, '')
  return value || 'index'
}

const config = readFileSync(join(docsRoot, '.vitepress/config.mjs'), 'utf8')
const sidebarStart = config.indexOf('sidebar:')
const sidebarEnd = config.indexOf('socialLinks:')
if (sidebarStart < 0 || sidebarEnd < 0 || sidebarEnd <= sidebarStart) {
  fail('could not locate the sidebar in .vitepress/config.mjs')
}

const sidebar = config.slice(sidebarStart, sidebarEnd)
const sidebarPageList = [...sidebar.matchAll(/link:\s*['"]\/([^'"]*)['"]/g)].map((match) =>
  normalizedPage(match[1]),
)
const sidebarPages = new Set(sidebarPageList)
if (sidebarPages.size === 0) fail('the VitePress sidebar contains no page links')
if (sidebarPages.size !== sidebarPageList.length) fail('the VitePress sidebar contains a duplicate page link')

const llmsIndex = readFileSync(join(docsRoot, 'public/llms.txt'), 'utf8')
const indexedPageList = [...llmsIndex.matchAll(/https:\/\/docs\.foreverlm\.com\/([^\s)#]*)/g)]
  .map((match) => match[1])
  .filter((path) => path !== 'llms-full.txt')
  .map(normalizedPage)
const indexedPages = new Set(indexedPageList)
if (indexedPages.size !== indexedPageList.length) {
  fail('public/llms.txt contains a duplicate docs page URL')
}

for (const page of [...sidebarPages].sort()) {
  if (!indexedPages.has(page)) fail(`public/llms.txt is missing sidebar page /${page}`)
}
for (const page of [...indexedPages].sort()) {
  if (!sidebarPages.has(page)) fail(`public/llms.txt indexes non-sidebar page /${page}`)
}

const manifestPath = join(docsRoot, 'screenshots.json')
let manifest
try {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
} catch (error) {
  fail(`screenshots.json is not valid JSON (${error.message})`)
  manifest = { assets: [], coverage_targets: [] }
}

const manifestAssets = new Map()
for (const asset of manifest.assets ?? []) {
  if (!asset.path?.startsWith('/screenshots/')) {
    fail(`screenshot manifest path must start with /screenshots/: ${asset.path ?? '<missing>'}`)
    continue
  }
  if (manifestAssets.has(asset.path)) fail(`duplicate screenshot manifest entry ${asset.path}`)
  manifestAssets.set(asset.path, asset)

  const diskPath = join(docsRoot, 'public', asset.path)
  if (!existsSync(diskPath)) fail(`manifest asset does not exist: ${asset.path}`)
  if (!asset.captured_at_version) fail(`manifest asset lacks captured_at_version: ${asset.path}`)
  if (!Array.isArray(asset.pages) || asset.pages.length === 0) {
    fail(`manifest asset must name at least one docs page: ${asset.path}`)
  }
}

const screenshotRoot = join(docsRoot, 'public/screenshots')
if (existsSync(screenshotRoot)) {
  for (const name of readdirSync(screenshotRoot)) {
    const assetPath = `/screenshots/${name}`
    if (!manifestAssets.has(assetPath)) fail(`public screenshot lacks a manifest entry: ${assetPath}`)
  }
}

const markdownFiles = walkFiles(docsRoot, (path) => path.endsWith('.md'))
const referencedScreenshots = new Set()
for (const file of markdownFiles) {
  const body = readFileSync(file, 'utf8')
  for (const match of body.matchAll(/(?:src=["']|\]\()(?<path>\/screenshots\/[^"')\s>]+)/g)) {
    const assetPath = match.groups.path
    referencedScreenshots.add(assetPath)
    if (!existsSync(join(docsRoot, 'public', assetPath))) {
      fail(`${relative(repoRoot, file)} references missing ${assetPath}`)
    }
    if (!manifestAssets.has(assetPath)) {
      fail(`${relative(repoRoot, file)} references unmanifested ${assetPath}`)
    }
  }
}

for (const [assetPath, asset] of manifestAssets) {
  for (const page of asset.pages) {
    const normalized = normalizedPage(page)
    if (!sidebarPages.has(normalized)) {
      fail(`${assetPath} names non-sidebar docs page /${normalized}`)
    }
  }
  if (!referencedScreenshots.has(assetPath)) {
    fail(`manifest asset is not referenced by a Markdown page: ${assetPath}`)
  }
}

const projectYAML = readFileSync(join(repoRoot, 'ForeverLMApp/project.yml'), 'utf8')
const macTarget = projectYAML.slice(projectYAML.indexOf('ForeverLM_macOS:'))
const currentVersion = macTarget.match(/MARKETING_VERSION:\s*["']([^"']+)["']/)?.[1]
if (!currentVersion) {
  fail('could not read the macOS MARKETING_VERSION from ForeverLMApp/project.yml')
} else {
  for (const asset of manifestAssets.values()) {
    if (asset.captured_at_version !== currentVersion) {
      fail(`${asset.path} was captured for ${asset.captured_at_version}, not release ${currentVersion}; recapture it before release`)
    }
  }
}

for (const target of manifest.coverage_targets ?? []) {
  if (!target.page || !sidebarPages.has(normalizedPage(target.page))) {
    fail(`invalid screenshot coverage target page: ${target.page ?? '<missing>'}`)
  }
}

if (!process.exitCode) {
  console.log(`Docs structure OK: ${sidebarPages.size} indexed pages, ${manifestAssets.size} screenshot asset(s), ${markdownFiles.length} Markdown file(s).`)
}
