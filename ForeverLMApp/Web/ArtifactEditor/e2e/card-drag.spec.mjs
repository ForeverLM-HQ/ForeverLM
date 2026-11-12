// A card on a line of its own is moved by its picture or its metadata line:
// a line marks the gap it would go to, letting go moves the paragraph there as
// one edit, and Escape or a press without a drag leaves the page alone.
import { expect, test } from '@playwright/test'
import { clearMessages, lastReport, openEditor, settle, stored } from './editor-page.mjs'

const card = (name) => `[${name} title](foreverlm://source/${name.toLowerCase()})`
const page3 = `${card('Alpha')}\n\n${card('Beta')}\n\n${card('Gamma')}\n`

const box = (page, name, part = '.artifact-reference-thumbnail') => {
  const whole = page.locator('p.artifact-reference', { hasText: `${name} title` })
  return (part ? whole.locator(part) : whole).boundingBox()
}

async function drag(page, from, toY, { release = true } = {}) {
  const x = from.x + from.width / 2
  const y = from.y + from.height / 2
  await page.mouse.move(x, y)
  await page.mouse.down()
  await page.mouse.move(x + 3, y + (toY - y) / 2, { steps: 4 })
  await page.mouse.move(x + 3, toY, { steps: 4 })
  await settle(page, 0)
  if (release) {
    await page.mouse.up()
    await settle(page)
  }
}

test('a card dragged by its picture below the last card goes last', async ({ page }) => {
  const errors = await openEditor(page, page3)
  const gamma = await box(page, 'Gamma', '')
  await drag(page, await box(page, 'Alpha'), gamma.y + gamma.height + 20, { release: false })
  await expect(page.locator('.artifact-card-drop-line')).toHaveCount(1)
  await clearMessages(page)
  await page.mouse.up()
  await settle(page, 400)
  const moved = `${card('Beta')}\n\n${card('Gamma')}\n\n${card('Alpha')}\n`
  expect(await stored(page)).toBe(moved)
  // The host is told, so the move is saved.
  expect((await lastReport(page))?.markdown).toBe(moved)
  await expect(page.locator('.artifact-card-drop-line')).toHaveCount(0)
  // One edit: one undo puts the card back.
  await page.keyboard.press('Meta+z')
  await settle(page)
  expect(await stored(page)).toBe(page3)
  expect(errors).toEqual([])
})

test('a card dragged by its metadata line above the first card goes first', async ({ page }) => {
  const errors = await openEditor(page, page3)
  await page.evaluate(() => window.foreverLMArtifactEditor.setReferenceStatuses({
    'foreverlm://source/gamma': { state: 'inLibrary', sourceID: 'gamma', kind: 'paper', detail: 'A. Writer · Journal · 2020' },
  }))
  await settle(page)
  const alpha = await box(page, 'Alpha', '')
  await drag(page, await box(page, 'Gamma', '.artifact-reference-meta'), alpha.y + 4)
  expect(await stored(page)).toBe(`${card('Gamma')}\n\n${card('Alpha')}\n\n${card('Beta')}\n`)
  expect(errors).toEqual([])
})

test('a card goes above a paragraph of prose', async ({ page }) => {
  const errors = await openEditor(page, `Opening words.\n\n${card('Alpha')}\n\n${card('Beta')}\n`)
  const words = await page.locator('p', { hasText: 'Opening words.' }).boundingBox()
  await drag(page, await box(page, 'Beta'), words.y + 2)
  expect(await stored(page)).toBe(`${card('Beta')}\n\nOpening words.\n\n${card('Alpha')}\n`)
  expect(errors).toEqual([])
})

test('Escape, a drop where the card already is, and a press without a drag change nothing', async ({ page }) => {
  const errors = await openEditor(page, page3)
  const gamma = await box(page, 'Gamma', '')
  await drag(page, await box(page, 'Alpha'), gamma.y + gamma.height + 20, { release: false })
  await page.keyboard.press('Escape')
  await page.mouse.up()
  await settle(page)
  expect(await stored(page)).toBe(page3)
  await expect(page.locator('.artifact-card-drop-line')).toHaveCount(0)

  const beta = await box(page, 'Beta', '')
  await drag(page, await box(page, 'Alpha'), beta.y + 2)
  expect(await stored(page)).toBe(page3)

  const alpha = await box(page, 'Alpha')
  await page.mouse.click(alpha.x + alpha.width / 2, alpha.y + alpha.height / 2)
  await settle(page)
  expect(await stored(page)).toBe(page3)
  expect(errors).toEqual([])
})

test('a page that is only read does not move its cards', async ({ page }) => {
  const errors = await openEditor(page, page3)
  await page.evaluate(() => window.foreverLMArtifactEditor.setEditable(false))
  await settle(page)
  const gamma = await box(page, 'Gamma', '')
  await drag(page, await box(page, 'Alpha'), gamma.y + gamma.height + 20)
  expect(await stored(page)).toBe(page3)
  expect(errors).toEqual([])
})
