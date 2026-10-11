#!/usr/bin/env node
// Regenerates public/llms-full.txt by concatenating the docs-site Markdown
// pages in sidebar order. Run after editing any docs-site page:
//
//   node docs-site/generate-llms-full.mjs
//
// Page order comes from the sidebar in .vitepress/config.mjs, so a page that
// is in the sidebar can never be missing from llms-full.txt.

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { sidebarSource } from './sidebar-source.mjs'

const root = dirname(fileURLToPath(import.meta.url))

// Extract sidebar page links from the VitePress config without importing it.
const config = readFileSync(join(root, '.vitepress/config.mjs'), 'utf8')
const sidebar = sidebarSource(config) ?? ''
const pages = [...sidebar.matchAll(/link:\s*['"]\/([^'"]+)['"]/g)].map((m) =>
  m[1].endsWith('/') ? `${m[1]}index.md` : `${m[1]}.md`,
)

if (pages.length === 0) {
  throw new Error('No sidebar links found in .vitepress/config.mjs — update the parser in this script.')
}

const sections = pages.map((page) => {
  const raw = readFileSync(join(root, page), 'utf8')
  const body = raw.replace(/^---\n[\s\S]*?\n---\n/, '').trim()
  return `\n---\n\n<!-- Source: docs-site/${page} -->\n\n${body}\n`
})

const header =
  '# ForeverLM - Complete Documentation\n\n' +
  '> Generated from the docs-site Markdown source files. Public docs: https://docs.foreverlm.com\n\n\n'

writeFileSync(join(root, 'public/llms-full.txt'), header + sections.join(''))
console.log(`Wrote public/llms-full.txt (${pages.length} pages)`)
