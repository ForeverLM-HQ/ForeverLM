// The `/` list as Codex's Pages has it: its groups in Codex's order with
// ForeverLM's own rows after them, the typed words as a prompt when they name
// no row, Visualize's four starters, and Mentioned rows that open the `@`
// list showing one kind.
import { expect, test } from '@playwright/test'
import { caretIn, clearMessages, messages, openEditor, settle, stored } from './editor-page.mjs'

const groups = (page) => page.locator('.artifact-link-picker .artifact-link-picker-group').allTextContents()
const titles = (page) => page.locator('.artifact-link-picker .artifact-link-picker-row .artifact-link-picker-title').allTextContents()

const targets = [
  { kind: 'doc', id: 'page-a', title: 'Mitochondria notes' },
  { kind: 'doc', id: 'page-b', title: 'Reading list' },
  { kind: 'chat', id: 'chat-a', title: 'Chat about membranes' },
]

async function typeSlash(page, words) {
  await page.keyboard.type('/')
  for (const character of words) await page.keyboard.type(character)
  await settle(page, 0)
}

test('the bare list keeps Codex\'s groups in Codex\'s order, ForeverLM\'s after them', async ({ page }) => {
  const errors = await openEditor(page, 'Start.\n\n')
  await page.evaluate((list) => window.foreverLMArtifactEditor.setLinkTargets(list), targets)
  await caretIn(page, 'Start')
  await page.keyboard.press('Enter')
  await typeSlash(page, '')
  expect(await groups(page)).toEqual(['Generate', 'Create', 'Media', 'Basic', 'Mentioned', 'More'])
  const shown = await titles(page)
  expect(shown.slice(0, 2)).toEqual(['Generate', 'Visualize'])
  // The starters are found by typing, not listed bare.
  expect(shown).not.toContain('Visualize (Draw a diagram)')
  // Pages and Chats have something to mention; this page has no files.
  expect(shown).toContain('Pages')
  expect(shown).toContain('Chats')
  expect(shown).not.toContain('Files')
  expect(shown).toContain('Math')
  expect(shown).not.toContain('Equation')
  expect(shown.indexOf('Chat')).toBeGreaterThan(shown.indexOf('Pages'))
  expect(errors).toEqual([])
})

test('words that name no row are a prompt: Generate runs with them at once', async ({ page }) => {
  await openEditor(page, 'Start.\n\n')
  await caretIn(page, 'Start')
  await page.keyboard.press('Enter')
  await typeSlash(page, 'a summary of the cell cycle')
  expect(await groups(page)).toEqual(['Use your prompt'])
  expect(await titles(page)).toEqual(['Generate — a summary of the cell cycle', 'Visualize — a summary of the cell cycle'])
  await clearMessages(page)
  await page.keyboard.press('Enter')
  const request = (await messages(page, 'aiEditRequested'))[0]
  expect(request.instruction).toBe('a summary of the cell cycle')
  expect(request.scope).toBe('generate')
  // The typing is gone from the page; nothing is written until Insert.
  expect((await stored(page)).trim()).toBe('Start.')
})

test('/visualize words asks for Visualize alone', async ({ page }) => {
  await openEditor(page, 'Start.\n\n')
  await caretIn(page, 'Start')
  await page.keyboard.press('Enter')
  await typeSlash(page, 'visualize a sine wave')
  expect(await titles(page)).toEqual(['Visualize — a sine wave'])
  await clearMessages(page)
  await page.keyboard.press('Enter')
  const request = (await messages(page, 'aiEditRequested'))[0]
  expect(request.instruction).toBe('a sine wave')
  expect(request.scope).toBe('visualize')
})

test('a Visualize starter fills the panel and asks nothing yet', async ({ page }) => {
  await openEditor(page, 'Start.\n\n')
  await caretIn(page, 'Start')
  await page.keyboard.press('Enter')
  await typeSlash(page, 'diagram')
  expect(await titles(page)).toContain('Visualize (Draw a diagram)')
  await clearMessages(page)
  await page.locator('.artifact-link-picker-row', { hasText: 'Visualize (Draw a diagram)' }).click()
  await expect(page.locator('.artifact-ai-edit [data-role=instruction]')).toHaveValue('Draw a diagram that explains ')
  expect(await messages(page, 'aiEditRequested')).toEqual([])
})

test('a path at the start of a line is writing, and Return makes a new line', async ({ page }) => {
  await openEditor(page, 'Start.\n\n')
  await caretIn(page, 'Start')
  await page.keyboard.press('Enter')
  await typeSlash(page, 'usr/local')
  await expect(page.locator('.artifact-link-picker')).toBeHidden()
  await page.keyboard.press('Enter')
  await page.keyboard.type('next')
  expect(await stored(page)).toContain('/usr/local\n\nnext')
})

test('Mentioned › Pages writes an @ whose list shows only pages', async ({ page }) => {
  await openEditor(page, 'Start.\n\n')
  await page.evaluate((list) => window.foreverLMArtifactEditor.setLinkTargets(list), targets)
  await caretIn(page, 'Start')
  await page.keyboard.press('Enter')
  await typeSlash(page, 'pages')
  await page.keyboard.press('Enter')
  await settle(page, 0)
  expect(await groups(page)).toEqual(['Pages'])
  expect(await titles(page)).toEqual(['Mitochondria notes', 'Reading list'])
  await page.keyboard.type('read')
  await settle(page, 0)
  expect(await titles(page)).toEqual(['Reading list'])
  await page.keyboard.press('Enter')
  expect(await stored(page)).toContain('[Reading list](foreverlm://doc/page-b)')
})

test('Mentioned › Files lists the files this page holds and links one again', async ({ page }) => {
  await openEditor(page, 'See [protocol.pdf](foreverlm://attachment/tok-1) here.\n\nStart.\n')
  await caretIn(page, 'Start')
  await page.keyboard.press('Enter')
  await typeSlash(page, 'files')
  expect(await titles(page)).toEqual(['Files'])
  await page.keyboard.press('Enter')
  await settle(page, 0)
  expect(await titles(page)).toEqual(['protocol.pdf'])
  await page.keyboard.press('Enter')
  const markdown = await stored(page)
  expect(markdown.match(/\[protocol\.pdf\]\(foreverlm:\/\/attachment\/tok-1\)/g)).toHaveLength(2)
})
