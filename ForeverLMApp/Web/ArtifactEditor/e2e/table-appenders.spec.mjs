// Codex's table appenders: Add row under a table and Add column at its right
// edge, shown while the pointer is over the table.
import { expect, test } from '@playwright/test'
import { openEditor, settle, stored } from './editor-page.mjs'

const page1 = '# Data\n\n| Measure | Value |\n| :- | -: |\n| Potential | High |\n\nAfter.\n'

async function hoverTable(page) {
  const box = await page.locator('.milkdown-table-block table.children').boundingBox()
  await page.mouse.move(box.x + 10, box.y + box.height / 2)
  await page.mouse.move(box.x + 12, box.y + box.height / 2)
  await settle(page)
  return box
}

test('the bars show over a table and go when the pointer leaves', async ({ page }) => {
  await openEditor(page, page1)
  await expect(page.locator('.artifact-table-appender')).toHaveCount(0)
  const box = await hoverTable(page)
  const row = page.locator('.artifact-table-appender[data-axis="row"]')
  const column = page.locator('.artifact-table-appender[data-axis="column"]')
  await expect(row).toBeVisible()
  await expect(column).toBeVisible()
  const rowBox = await row.boundingBox()
  expect(Math.abs(rowBox.width - box.width)).toBeLessThan(2)
  expect(rowBox.y).toBeGreaterThan(box.y + box.height - 1)
  await page.mouse.move(box.x + 10, box.y + box.height + 200)
  await settle(page)
  await expect(row).toBeHidden()
})

test('Add row adds an empty row at the bottom with the columns\' alignment, caret in it', async ({ page }) => {
  await openEditor(page, page1)
  await hoverTable(page)
  await page.locator('.artifact-table-appender[data-axis="row"]').click()
  await settle(page)
  await page.keyboard.type('Cost')
  await settle(page, 300)
  expect(await stored(page)).toBe('# Data\n\n| Measure | Value |\n| :- | -: |\n| Potential | High |\n| Cost | |\n\nAfter.\n')
})

test('Add column adds an empty column at the right, caret in its header', async ({ page }) => {
  await openEditor(page, page1)
  await hoverTable(page)
  await page.locator('.artifact-table-appender[data-axis="column"]').click()
  await settle(page)
  await page.keyboard.type('Unit')
  await settle(page, 300)
  expect(await stored(page)).toBe('# Data\n\n| Measure | Value | Unit |\n| :- | -: | - |\n| Potential | High | |\n\nAfter.\n')
})

test('a read-only page shows no bars', async ({ page }) => {
  await openEditor(page, page1)
  await page.evaluate(() => window.foreverLMArtifactEditor.setEditable(false))
  await hoverTable(page)
  await expect(page.locator('.artifact-table-appender:visible')).toHaveCount(0)
})
