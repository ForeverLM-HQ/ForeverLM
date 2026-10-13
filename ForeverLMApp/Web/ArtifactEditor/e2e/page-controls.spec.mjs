// The controls around the writing, as Codex's Pages has them: the selection
// bar over selected words.
import { expect, test } from '@playwright/test'
import { openEditor, selectBlock, settle } from './editor-page.mjs'

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
