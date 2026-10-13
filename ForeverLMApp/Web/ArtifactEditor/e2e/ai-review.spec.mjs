// Ask for change and Generate as Codex has them: the answer is written into
// the page as a tracked change (new words washed, replaced ones struck
// through) under Accept · Undo · Ask for change.
import { expect, test } from '@playwright/test'
import { caretIn, clearMessages, messages, openEditor, selectBlock, settle, stored } from './editor-page.mjs'

/// Ask the open panel and answer as the host would.
async function askAndAnswer(page, instruction, markdown) {
  await clearMessages(page)
  await page.locator('.artifact-ai-edit [data-role=instruction]').fill(instruction)
  await page.keyboard.press('Enter')
  const request = (await messages(page, 'aiEditRequested')).at(-1)
  await page.evaluate(([id, text]) => window.foreverLMArtifactEditor.completeAIEdit(id, { markdown: text }), [request.requestID, markdown])
  await settle(page)
  return request
}

const actions = (page) => page.evaluate(() => [...document.querySelectorAll('.artifact-ai-edit-actions button')]
  .filter((button) => getComputedStyle(button).display !== 'none')
  .map((button) => button.textContent))

test('an edit is written into the page as a tracked change, and Undo puts the passage back', async ({ page }) => {
  const page1 = '# Notes\n\nThe cell makes a lot of energy from food.\n\nAfter.\n'
  await openEditor(page, page1)
  await selectBlock(page, 'The cell')
  await page.evaluate(() => window.foreverLMArtifactEditor.openAIEdit())
  await askAndAnswer(page, 'tighten', 'Cells make energy from food.')
  expect(await stored(page)).toBe('# Notes\n\nCells make energy from food.\n\nAfter.\n')
  // Most of the words stayed: only the new ones are washed, and the ones
  // taken out stand struck through where they were.
  expect(await page.locator('.artifact-ai-insertion').allTextContents()).toEqual(['Cells', 'make'])
  expect((await page.locator('.artifact-ai-removed').allTextContents()).map((words) => words.trim())).toEqual(['The cell makes a lot of'])
  expect(await actions(page)).toEqual(['Accept', 'Undo', 'Ask for change'])
  expect((await messages(page, 'aiEditWritten')).length).toBe(1)
  const html = await page.evaluate(() => window.foreverLMArtifactEditor.publicationHTML('Notes'))
  expect(html).not.toContain('a lot of energy')
  expect(html).not.toContain('artifact-ai-insertion')
  await page.locator('.artifact-ai-edit-actions button', { hasText: 'Undo' }).click()
  await settle(page)
  expect(await stored(page)).toBe(page1)
  await expect(page.locator('.artifact-ai-insertion, .artifact-ai-removed')).toHaveCount(0)
  await expect(page.locator('.artifact-ai-edit')).toBeHidden()
})

test('Ask for change rewrites the written words, and Undo still brings back the first passage', async ({ page }) => {
  const page1 = 'Intro.\n\nThe membrane holds a gradient across it.\n'
  await openEditor(page, page1)
  await selectBlock(page, 'The membrane')
  await page.evaluate(() => window.foreverLMArtifactEditor.openAIEdit())
  await askAndAnswer(page, 'simpler', 'The membrane keeps a gradient.')
  await page.locator('.artifact-ai-edit-actions button', { hasText: 'Ask for change' }).click()
  const followUp = await askAndAnswer(page, 'shorter', 'A gradient.')
  expect(followUp.passage).toBe('The membrane keeps a gradient.')
  expect(await stored(page)).toBe('Intro.\n\nA gradient.\n')
  // Rewritten past recognition: washed whole, the first passage struck before it.
  await expect(page.locator('.artifact-ai-insertion')).toHaveText('A gradient.')
  await expect(page.locator('.artifact-ai-removed')).toHaveText('The membrane holds a gradient across it.')
  await page.locator('.artifact-ai-edit-actions button', { hasText: 'Undo' }).click()
  await settle(page)
  expect(await stored(page)).toBe(page1)
})

test('Accept keeps the edit and takes the marks away; nothing else changed', async ({ page }) => {
  await openEditor(page, 'One.\n\nTwo words here.\n')
  await selectBlock(page, 'Two')
  await page.evaluate(() => window.foreverLMArtifactEditor.openAIEdit())
  await askAndAnswer(page, 'polish', 'Two polished words.')
  await page.locator('.artifact-ai-edit-actions button', { hasText: 'Accept' }).click()
  await settle(page)
  expect(await stored(page)).toBe('One.\n\nTwo polished words.\n')
  await expect(page.locator('.artifact-ai-insertion, .artifact-ai-removed')).toHaveCount(0)
  await expect(page.locator('.artifact-ai-edit')).toBeHidden()
})

test('Generate writes at the caret\'s empty line, and Undo gives the line back', async ({ page }) => {
  await openEditor(page, 'Start.\n\n')
  await caretIn(page, 'Start')
  await page.keyboard.press('Enter')
  const before = await stored(page)
  await page.evaluate(() => window.foreverLMArtifactEditor.openAIGenerate({ prompt: 'a line on cells' }))
  const request = await askAndAnswer(page, 'a line on cells', 'Cells are small.')
  expect(request.scope).toBe('generate')
  expect(await stored(page)).toBe('Start.\n\nCells are small.\n')
  await expect(page.locator('.artifact-ai-insertion')).toHaveText('Cells are small.')
  await expect(page.locator('.artifact-ai-removed')).toHaveCount(0)
  await page.locator('.artifact-ai-edit-actions button', { hasText: 'Undo' }).click()
  await settle(page)
  expect(await stored(page)).toBe(before)
})

test('a visualization is still proposed in the panel and written with Insert', async ({ page }) => {
  await openEditor(page, 'Start.\n\n')
  await caretIn(page, 'Start')
  await page.keyboard.press('Enter')
  await page.evaluate(() => window.foreverLMArtifactEditor.openAIGenerate({ visualize: true, prompt: 'a dial' }))
  await askAndAnswer(page, 'a dial', '<div>dial</div>')
  expect(await actions(page)).toEqual(['Insert', 'Try again', 'Discard'])
  expect(await stored(page)).not.toContain('dial')
})
