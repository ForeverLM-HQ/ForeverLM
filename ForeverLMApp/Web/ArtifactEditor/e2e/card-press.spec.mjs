// A card whose source the library holds opens it when pressed anywhere, and
// pointing at its title shows no second copy of the card to press.
import { expect, test } from '@playwright/test'
import { messages, openEditor, settle, stored } from './editor-page.mjs'

const card = (name) => `[${name} title](foreverlm://source/${name.toLowerCase()})`
const page2 = `${card('Alpha')}\n\n${card('Beta')}\n`

const held = (page) => page.evaluate(() => window.foreverLMArtifactEditor.setReferenceStatuses({
  'foreverlm://source/alpha': { state: 'inLibrary', sourceID: 'alpha', kind: 'paper', detail: 'A. Writer · Journal · 2020' },
}))

const opened = async (page) => (await messages(page, 'openSourceRequested')).map((message) => message.sourceID)

test('a press on the title, the picture, the line under it or the room beside them opens the source', async ({ page }) => {
  const errors = await openEditor(page, page2)
  await held(page)
  await settle(page)
  const alpha = page.locator('p.artifact-reference', { hasText: 'Alpha title' })
  await alpha.locator('a').click()
  await alpha.locator('.artifact-reference-thumbnail').click()
  await alpha.locator('.artifact-reference-meta').click()
  const box = await alpha.boundingBox()
  await page.mouse.click(box.x + box.width * 0.7, box.y + box.height / 2)
  expect(await opened(page)).toEqual(['alpha', 'alpha', 'alpha', 'alpha'])
  // The check at the trailing edge opens it once, not twice.
  await alpha.locator('.artifact-reference-control button').click()
  expect(await opened(page)).toHaveLength(5)
  expect(await stored(page)).toBe(page2)
  expect(errors).toEqual([])
})

test('a card the library does not hold, a drag across a title and a press with a modifier open nothing', async ({ page }) => {
  const errors = await openEditor(page, page2)
  await held(page)
  await settle(page)
  await page.locator('p.artifact-reference', { hasText: 'Beta title' }).locator('a').click()
  const title = await page.locator('p.artifact-reference', { hasText: 'Alpha title' }).locator('a').boundingBox()
  await page.mouse.move(title.x + 2, title.y + title.height / 2)
  await page.mouse.down()
  await page.mouse.move(title.x + title.width - 2, title.y + title.height / 2, { steps: 4 })
  await page.mouse.up()
  await page.mouse.click(title.x + 10, title.y + title.height / 2, { modifiers: ['Alt'] })
  expect(await opened(page)).toEqual([])
  expect(errors).toEqual([])
})

test('pointing at a card\'s title shows no second copy of the card', async ({ page }) => {
  const errors = await openEditor(page, page2)
  await held(page)
  await settle(page)
  // The caret is in the page, as it is for a writer at work in it.
  await page.locator('p.artifact-reference', { hasText: 'Beta title' }).locator('a').click()
  await page.locator('p.artifact-reference', { hasText: 'Alpha title' }).locator('a').hover()
  await page.waitForTimeout(700)
  await expect(page.locator('.artifact-library-link-tooltip')).toBeHidden()
  expect(errors).toEqual([])
})
