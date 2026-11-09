// The page's edges: a host that keeps the width as the reader's setting lets
// the column's edges be dragged, and hears each width as `pageWidthChanged`.
import { test, expect } from '@playwright/test'
import { openEditor, messages, settle } from './editor-page.mjs'

const columnWidth = (page) => page.evaluate(() => document.querySelector('.milkdown .editor').getBoundingClientRect().width)
const edges = (page) => page.locator('.artifact-page-edge')

test('a host that does not keep the width shows no edges', async ({ page }) => {
  await openEditor(page, 'Some words on the page.')
  await page.evaluate(() => window.foreverLMArtifactEditor.setPageWidth(760))
  await settle(page)
  await expect(edges(page)).toHaveCount(0)
  expect(await columnWidth(page)).toBe(760)
})

test('dragging an edge widens the centred page, and only the last width is kept', async ({ page }) => {
  const errors = await openEditor(page, 'Some words on the page.')
  await page.evaluate(() => window.foreverLMArtifactEditor.setPageWidth(600, true))
  await settle(page)
  const trailing = edges(page).nth(1)
  await expect(trailing).toBeVisible()
  // The viewport is 1000 wide: a 600 column ends at 800.
  const box = await trailing.boundingBox()
  expect(Math.round(box.x + box.width)).toBe(802)

  await page.mouse.move(box.x + box.width / 2, 300)
  await page.mouse.down()
  await page.mouse.move(850, 300, { steps: 4 })
  await expect(page.locator('.artifact-page-width-label')).toHaveText('700 pt')
  await page.mouse.up()
  await settle(page)

  expect(await columnWidth(page)).toBe(700)
  const reports = await messages(page, 'pageWidthChanged')
  expect(reports.at(-1)).toMatchObject({ width: 700, done: true })
  expect(reports.filter((report) => report.done)).toHaveLength(1)
  await expect(page.locator('.artifact-page-width-label')).toBeHidden()

  // The leading edge moves with it, on the column's other border.
  const leading = await edges(page).nth(0).boundingBox()
  expect(Math.round(leading.x)).toBe(148)
  expect(errors).toEqual([])
})

test('dragged to the pane\'s edge the page fills it, and a double-click goes back to standard', async ({ page }) => {
  await openEditor(page, 'Some words on the page.')
  await page.evaluate(() => window.foreverLMArtifactEditor.setPageWidth(760, true))
  await settle(page)
  const leading = await edges(page).nth(0).boundingBox()
  await page.mouse.move(leading.x + leading.width / 2, 300)
  await page.mouse.down()
  await page.mouse.move(3, 300, { steps: 4 })
  await expect(page.locator('.artifact-page-width-label')).toHaveText('Full Width')
  await page.mouse.up()
  await settle(page)
  expect((await messages(page, 'pageWidthChanged')).at(-1)).toMatchObject({ width: null, done: true })
  expect(await columnWidth(page)).toBe(1000)

  // Narrowing never goes under the floor.
  const trailing = await edges(page).nth(1).boundingBox()
  await page.mouse.move(trailing.x + trailing.width / 2, 300)
  await page.mouse.down()
  await page.mouse.move(510, 300, { steps: 6 })
  await page.mouse.up()
  await settle(page)
  expect(await columnWidth(page)).toBe(400)

  await edges(page).nth(1).dblclick()
  await settle(page)
  expect(await columnWidth(page)).toBe(760)
  expect((await messages(page, 'pageWidthChanged')).at(-1)).toMatchObject({ width: 760, done: true })
})
