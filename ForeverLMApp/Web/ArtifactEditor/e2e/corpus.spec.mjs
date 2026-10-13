// Every page stored on this Mac, opened and saved back in the editor, read
// only: `npm run e2e:corpus`. Pages are read from the app's library
// (~/Library/Application Support/ForeverLM/Content/Artifacts/<id>/document.md),
// or from FOREVERLM_PAGES (a folder of those folders, or of .md files). No page
// text is printed, only page ids and what went wrong.
//
// For each page:
// - opening it tells the host nothing (an untouched page is never saved),
//   unless it holds retired source chips, which the editor turns into the
//   passage's sources once and saves (`convertSourceChipsToGrounding`);
// - what a save would write reads back to itself (a second save changes
//   nothing more);
// - and keeps the page: the same words and the same blocks, empty lines
//   included.
import { expect, test } from '@playwright/test'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { blocks, clearMessages, load, messages, openEditor, stored, text } from './editor-page.mjs'

const folder = process.env.FOREVERLM_PAGES ?? join(homedir(), 'Library/Application Support/ForeverLM/Content/Artifacts')

function pages() {
  if (!existsSync(folder)) return []
  return readdirSync(folder).flatMap((name) => {
    const path = join(folder, name)
    if (name.endsWith('.md')) return [{ id: name, markdown: readFileSync(path, 'utf8') }]
    const document = join(path, 'document.md')
    if (!statSync(path).isDirectory() || !existsSync(document)) return []
    return [{ id: name, markdown: readFileSync(document, 'utf8') }]
  })
}

const all = pages()

/// What a save changes in a page, by kind, for the log: no page text.
function changeKinds(before, after) {
  const kinds = new Set()
  const old = before.trimEnd().split('\n')
  const now = after.trimEnd().split('\n')
  if (old.some((line) => /^<br\s*\/?>\s*$/.test(line)) && !now.some((line) => /^<br\s*\/?>\s*$/.test(line))) kinds.add('empty lines')
  const plain = (lines) => lines
    .filter((line) => !/^<br\s*\/?>\s*$/.test(line) && line.trim() !== '')
    .map((line) => line.replace(/^(\s*)[-+*](\s)/, '$1*$2').replace(/\\(.)/g, '$1').replace(/\s+$/, ''))
    // A table row's padding and its delimiter row's dashes are spelling.
    .map((line) => (/^\s*\|/.test(line) ? line.replace(/:?-+:?/g, (cell) => (/^:?-+:?$/.test(cell) ? '-' : cell)).replace(/\s+/g, ' ') : line))
  const a = plain(old)
  const b = plain(now)
  if (a.join('\n') !== b.join('\n')) kinds.add('other')
  else if (old.join('\n').replace(/\s+$/gm, '') !== now.join('\n').replace(/\s+$/gm, '')) kinds.add('marks and escapes')
  return kinds
}

test('every stored page opens unchanged, saves to itself, and keeps its words', async ({ page }) => {
  test.skip(all.length === 0, `no pages in ${folder}`)
  test.setTimeout(30_000 + all.length * 2_000)
  const errors = await openEditor(page, '', { key: 'corpus-start' })
  const problems = []
  const kinds = {}
  const other = []
  for (const [index, { id, markdown }] of all.entries()) {
    await clearMessages(page)
    await load(page, markdown, `${id}#open`)
    const told = (await messages(page)).filter((message) => message.type === 'markdownChanged' || message.type === 'saveRequested')
    if (told.length && !markdown.includes('foreverlm://source/')) problems.push(`${id}: opening it reported the page to the host`)
    const firstWords = await text(page)
    const firstBlocks = await blocks(page)
    const once = await stored(page)
    for (const kind of changeKinds(markdown, once)) {
      kinds[kind] = (kinds[kind] ?? 0) + 1
      if (kind === 'other') other.push(id)
    }
    await load(page, once, `${id}#again-${index}`)
    const twice = await stored(page)
    if (twice !== once) problems.push(`${id}: a second save changes it again`)
    if ((await text(page)) !== firstWords) problems.push(`${id}: a save changes its words`)
    if (JSON.stringify(await blocks(page)) !== JSON.stringify(firstBlocks)) problems.push(`${id}: a save changes its blocks`)
  }
  console.log(`${all.length} pages; a next save would change, by kind: ${JSON.stringify(kinds)}; ${problems.length} problems`)
  if (other.length) console.log(`changed in other ways: ${other.join(', ')}`)
  expect(errors).toEqual([])
  expect(problems).toEqual([])
})
