// A source link carries where the source came from on the web
// (`foreverlm://source/<id>?url=<address>`). A reader whose library does not
// hold the source — a teammate on a shared page — gets that address instead:
// a web card, Add to Sources, and a press that opens the page.
import { expect, test } from '@playwright/test'
import { messages, openEditor, settle, stored } from './editor-page.mjs'

const origin = 'https://example.org/paper-1'
const page1 = `[Paper title](foreverlm://source/paper1?url=${encodeURIComponent(origin)})\n`

const answer = (page, statuses) => page.evaluate((value) => window.foreverLMArtifactEditor.setReferenceStatuses(value), statuses)
const asked = async (page) => (await messages(page, 'referencesChanged')).at(-1)?.hrefs ?? []

test('the host is asked about the source and where it came from', async ({ page }) => {
  const errors = await openEditor(page, page1)
  await settle(page, 300)
  expect(new Set(await asked(page))).toEqual(new Set(['foreverlm://source/paper1', origin]))
  expect(errors).toEqual([])
})

test('a source the library holds stays the source card', async ({ page }) => {
  const errors = await openEditor(page, page1)
  await settle(page, 300)
  await answer(page, { 'foreverlm://source/paper1': { state: 'inLibrary', sourceID: 'paper1' }, [origin]: { state: 'inLibrary', sourceID: 'paper1' } })
  await settle(page)
  const card = page.locator('p.artifact-reference', { hasText: 'Paper title' })
  await expect(card).toHaveClass(/artifact-source-card/)
  await card.locator('a').click()
  expect((await messages(page, 'openSourceRequested')).map((m) => m.sourceID)).toEqual(['paper1'])
  expect(await stored(page)).toBe(page1)
  expect(errors).toEqual([])
})

test('a source the library lacks falls back to its web address, and a press opens it', async ({ page }) => {
  const errors = await openEditor(page, page1)
  await settle(page, 300)
  await answer(page, { 'foreverlm://source/paper1': { state: 'absent' }, [origin]: { state: 'absent' } })
  await settle(page, 300)
  const card = page.locator('p.artifact-reference', { hasText: 'Paper title' })
  await expect(card).not.toHaveClass(/artifact-source-card/)
  await expect(card).toHaveAttribute('data-reference-fallback', 'true')
  await expect(card.locator('.artifact-reference-control button')).toHaveCount(1)
  // Both answers are still asked for, so the card does not flip back.
  expect(new Set(await asked(page))).toEqual(new Set(['foreverlm://source/paper1', origin]))
  await card.locator('.artifact-reference-thumbnail').click()
  expect((await messages(page, 'openLinkRequested')).map((m) => m.href)).toEqual([origin])
  expect(await stored(page)).toBe(page1)
  expect(errors).toEqual([])
})

test('a source link with no web address keeps saying the library lacks it', async ({ page }) => {
  const plain = '[Notes title](foreverlm://source/notes1)\n'
  const errors = await openEditor(page, plain)
  await settle(page, 300)
  await answer(page, { 'foreverlm://source/notes1': { state: 'absent' } })
  await settle(page)
  const card = page.locator('p.artifact-reference', { hasText: 'Notes title' })
  await expect(card).toHaveClass(/artifact-source-card/)
  await card.locator('.artifact-reference-thumbnail').click()
  expect(await messages(page, 'openLinkRequested')).toEqual([])
  expect(errors).toEqual([])
})
