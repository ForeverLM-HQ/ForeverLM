// A drag over the page never shows Crepe's own drop indicator, the gray bar
// that stayed on the page after a drop the app took itself; and a source card
// whose source this Mac does not hold says nothing about any library.
import { expect, test } from '@playwright/test'
import { openEditor, settle } from './editor-page.mjs'

const card = (name) => `[${name} title](foreverlm://source/${name.toLowerCase()})`

test('a drag over the page draws no gray bar', async ({ page }) => {
  const errors = await openEditor(page, `${card('Alpha')}\n\n${card('Beta')}\n`)
  const beta = await page.locator('p.artifact-reference', { hasText: 'Beta title' }).boundingBox()
  await page.evaluate(([x, y]) => {
    const dataTransfer = new DataTransfer()
    dataTransfer.setData('text/plain', 'dragged words')
    const target = document.elementFromPoint(x, y)
    for (const type of ['dragenter', 'dragover', 'dragover']) {
      target.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, dataTransfer }))
    }
  }, [beta.x + 40, beta.y + beta.height + 6])
  await settle(page, 300)
  const indicator = page.locator('.milkdown-drop-indicator')
  await expect(indicator).toHaveCount(1)
  // Crepe did try to show it: the bar is hidden by the page, not by luck.
  expect(await indicator.evaluate((element) => element.style.display)).not.toBe('none')
  await expect(indicator).toBeHidden()
  expect(errors).toEqual([])
})

test('a source card the library does not answer for shows no library label', async ({ page }) => {
  const errors = await openEditor(page, `${card('Alpha')}\n\n${card('Beta')}\n`)
  await page.evaluate(() => window.foreverLMArtifactEditor.setReferenceStatuses({
    'foreverlm://source/alpha': { state: 'absent' },
    'foreverlm://source/beta': { state: 'inLibrary', sourceID: 'beta', kind: 'paper', detail: 'A. Writer · Journal · 2020' },
  }))
  await settle(page)
  const alpha = page.locator('p.artifact-reference', { hasText: 'Alpha title' })
  await expect(alpha.locator('.artifact-reference-control')).toHaveText('')
  await expect(page.locator('p.artifact-reference', { hasText: 'Beta title' }).locator('button[data-role="open"]')).toHaveCount(1)
  expect(await page.locator('.ProseMirror').innerText()).not.toContain('Not in this library')
  expect(errors).toEqual([])
})
