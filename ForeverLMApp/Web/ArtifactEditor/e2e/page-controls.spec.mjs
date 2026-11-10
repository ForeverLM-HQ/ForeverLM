// The controls around the writing, as Codex's Pages has them: the selection
// bar over selected words, the block menu's Copy link and the key that
// opens that menu from the caret.
import { expect, test } from '@playwright/test'
import { caretIn, clearMessages, messages, openEditor, selectBlock, settle, stored } from './editor-page.mjs'

/// What the page put on the clipboard, read from a stand-in for it.
async function catchCopies(page) {
  await page.evaluate(() => {
    window.copied = []
    navigator.clipboard.writeText = async (text) => { window.copied.push(text) }
  })
}

async function openBlockMenu(page, words) {
  await caretIn(page, words)
  await page.keyboard.press('Alt+Meta+Slash')
  await expect(page.locator('.artifact-block-menu')).toBeVisible()
}

const menuRows = (page) => page.evaluate(() => [...document.querySelectorAll('.artifact-block-menu > button')].map((row) => row.textContent.trim()))

test('Copy link gives the block an id and copies the page address with it as the anchor', async ({ page }) => {
  await openEditor(page, '# Notes\n\nFirst paragraph.\n\nSecond paragraph.\n')
  await catchCopies(page)
  await openBlockMenu(page, 'Second paragraph')
  const rows = await menuRows(page)
  expect(rows.slice(rows.indexOf('Insert below'), rows.indexOf('Insert below') + 4)).toEqual(['Insert below', 'Copy link', 'Copy as Markdown', 'Duplicate'])
  await page.locator('.artifact-block-menu button', { hasText: 'Copy link' }).click()
  const copied = await page.evaluate(() => window.copied)
  expect(copied).toHaveLength(1)
  const [, blockID] = /^foreverlm:\/\/doc\/page-1#([a-z0-9]{9})$/.exec(copied[0]) ?? []
  expect(blockID).toBeTruthy()
  expect(await stored(page)).toContain(`Second paragraph. ^${blockID}`)
})

test('⌥⌘/ opens the menu of the block at the caret, the keys move through it, Escape returns to the caret', async ({ page }) => {
  await openEditor(page, '# Notes\n\n* one\n* two\n\nAfter.\n')
  await caretIn(page, 'two')
  await page.keyboard.press('Alt+Meta+Slash')
  await expect(page.locator('.artifact-block-menu')).toBeVisible()
  const focused = () => page.evaluate(() => document.activeElement?.textContent?.trim() ?? '')
  expect(await focused()).toBe('Turn into')
  await page.keyboard.press('ArrowDown')
  expect(await focused()).toBe('Insert below')
  await page.keyboard.press('Escape')
  await expect(page.locator('.artifact-block-menu')).toBeHidden()
  await page.keyboard.type(' three')
  expect(await stored(page)).toMatch(/[*-] two three\n/)
})

test('⌥⌘/ then Return on Delete removes the list item the caret is in', async ({ page }) => {
  await openEditor(page, '# Notes\n\n* one\n* two\n* three\n')
  await caretIn(page, 'two')
  await page.keyboard.press('Alt+Meta+Slash')
  await page.keyboard.press('End')
  await page.keyboard.press('Enter')
  expect((await stored(page)).trimEnd()).toMatch(/^# Notes\n\n[*-] one\n[*-] three$/)
})

test('a block link to this page shows the block; one to another page goes to the host with its anchor', async ({ page }) => {
  await openEditor(page, '# Notes\n\nSee [the claim](foreverlm://doc/page-1#a1b2c3d4e) and [elsewhere](foreverlm://doc/page-2#b2c3d4e5f).\n\nThe claim itself. ^a1b2c3d4e\n')
  await clearMessages(page)
  // Milkdown shows a link's preview only while the page has the focus.
  await caretIn(page, 'The claim itself')
  await page.locator('.ProseMirror a', { hasText: 'the claim' }).hover()
  await page.locator('.artifact-inapp-link-tooltip [data-role=open]').click()
  await expect(page.locator('.artifact-block-flash')).toContainText('The claim itself.')
  expect(await messages(page, 'openLinkRequested')).toEqual([])
  await page.mouse.move(5, 5)
  await caretIn(page, 'The claim itself')
  await page.locator('.ProseMirror a', { hasText: 'elsewhere' }).hover()
  await page.locator('.artifact-inapp-link-tooltip [data-role=open]').click()
  expect((await messages(page, 'openLinkRequested')).map((message) => message.href)).toEqual(['foreverlm://doc/page-2#b2c3d4e5f'])
})

/// The bar's visible buttons, group by group: `[['Ask for change', 'Comment'], …]`.
const selectionBar = (page) => page.evaluate(() => [...document.querySelectorAll('.artifact-selection-assistant > .artifact-selection-group')]
  .filter((group) => !group.hidden)
  .map((group) => [...group.querySelectorAll('button')]
    .filter((button) => !button.hidden)
    .map((button) => button.getAttribute('aria-label') || button.textContent.trim())))

test('the selection bar reads in Codex\'s order, ForeverLM\'s own after a divider', async ({ page }) => {
  const errors = await openEditor(page, '# Notes\n\nA sentence to select.\n')
  await selectBlock(page, 'A sentence')
  await settle(page)
  expect(await selectionBar(page)).toEqual([
    ['Ask for change', 'Comment'],
    ['Bold', 'Italic', 'Strikethrough', 'Inline code', 'Link'],
    ['Text'],
    ['Add sources', 'Chat'],
  ])
  expect(await page.locator('.artifact-selection-assistant button[data-role=block]').getAttribute('title')).toBe('Text styles')
  expect(errors).toEqual([])
})

test('on a page that reads only, the bar keeps Comment and the passage\'s own', async ({ page }) => {
  await openEditor(page, '# Notes\n\nA sentence to select.\n')
  await page.evaluate(() => window.foreverLMArtifactEditor.setEditable(false))
  await selectBlock(page, 'A sentence')
  await settle(page)
  expect(await selectionBar(page)).toEqual([['Comment'], ['Add sources', 'Chat']])
})

// ─── Page contents ──────────────────────────────────────────────────────────

const filler = (words) => Array.from({ length: 14 }, (_, index) => `${words} paragraph ${index + 1} has a few sentences of made-up working notes in it.`).join('\n\n')
const sectionedPage = `# Membranes\n\n${filler('Opening')}\n\n## Gradients\n\n${filler('Gradient')}\n\n### Proton leak\n\n${filler('Leak')}\n\n## Synthase\n\n${filler('Synthase')}\n`
const contentsTitles = (page) => page.evaluate(() => [...document.querySelectorAll('.artifact-contents button')].map((button) => button.textContent.trim()))
const contentsMode = (page) => page.evaluate(() => document.querySelector('.artifact-contents')?.dataset.mode ?? '')

test('the page contents list the headings once the writing pauses, and a page with one heading has none', async ({ page }) => {
  await openEditor(page, sectionedPage)
  await expect(page.locator('.artifact-contents')).toBeVisible()
  expect(await contentsTitles(page)).toEqual(['Membranes', 'Gradients', 'Proton leak', 'Synthase'])
  expect(await contentsMode(page)).toBe('ticks')
  // Typing a heading changes nothing until the writing has paused.
  await caretIn(page, 'Synthase paragraph 14')
  await page.keyboard.press('End')
  await page.keyboard.press('Enter')
  await page.keyboard.type('## Summary')
  expect(await contentsTitles(page)).toHaveLength(4)
  await expect.poll(() => contentsTitles(page)).toEqual(['Membranes', 'Gradients', 'Proton leak', 'Synthase', 'Summary'])

  await openEditor(page, '# Only one\n\nA short note.\n')
  await page.waitForTimeout(500)
  await expect(page.locator('.artifact-contents')).toBeHidden()
})

test('resting on the ticks shows the titles, and a title scrolls its heading into view with the caret left in the page', async ({ page }) => {
  await openEditor(page, sectionedPage)
  await expect(page.locator('.artifact-contents')).toBeVisible()
  await caretIn(page, 'Opening paragraph 2')
  const title = page.locator('.artifact-contents-title', { hasText: 'Synthase' })
  await expect(title).toBeHidden()
  await page.locator('.artifact-contents').hover()
  await expect(title).toBeVisible()
  const before = await page.evaluate(() => window.scrollY)
  await title.click()
  await expect.poll(async () => page.evaluate(() => {
    const heading = [...document.querySelectorAll('.ProseMirror h2')].find((element) => element.textContent.trim() === 'Synthase')
    return Math.round(heading.getBoundingClientRect().top)
  })).toBeLessThan(120)
  expect(await page.evaluate(() => window.scrollY)).toBeGreaterThan(before)
  expect(await page.evaluate(() => document.activeElement?.closest('.ProseMirror') !== null)).toBe(true)
  await expect(page.locator('.artifact-contents button[aria-current]')).toHaveText('Synthase')
})

test('a window with room beside the writing lists the titles there instead of ticks', async ({ page }) => {
  await page.setViewportSize({ width: 1500, height: 800 })
  await openEditor(page, sectionedPage)
  await expect(page.locator('.artifact-contents')).toBeVisible()
  await expect.poll(() => contentsMode(page)).toBe('titles')
  await expect(page.locator('.artifact-contents-title', { hasText: 'Gradients' })).toBeVisible()
  const [textRight, railLeft] = await page.evaluate(() => [
    document.querySelector('.ProseMirror').getBoundingClientRect().right,
    document.querySelector('.artifact-contents').getBoundingClientRect().left,
  ])
  expect(railLeft).toBeGreaterThan(textRight - 80)
  await page.setViewportSize({ width: 1000, height: 800 })
  await expect.poll(() => contentsMode(page)).toBe('ticks')
})
