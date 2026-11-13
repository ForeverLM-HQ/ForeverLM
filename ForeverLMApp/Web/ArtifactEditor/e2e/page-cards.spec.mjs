// A line that is nothing but a link to a page (a notebook, an Idea, a chat) is
// that page's card, in the source card's frame, and a page dragged onto the
// page lands as its card on a line of its own.
import { expect, test } from '@playwright/test'
import { blocks, messages, openEditor, settle, stored } from './editor-page.mjs'

const sourceCard = '[Alpha title](foreverlm://source/alpha)'
const pageLink = '[Do mutations drive aging?](foreverlm://doc/page-2)'

const targets = (page) => page.evaluate(() => window.foreverLMArtifactEditor.setLinkTargets([
  { kind: 'doc', id: 'page-2', title: 'Do mutations drive aging?', detail: 'Lab notebook' },
  { kind: 'doc', id: 'page-3', title: 'Second page', detail: 'Draft' },
  { kind: 'notebook', id: 'nb-1', title: 'Lab notebook', detail: 'Notebook' },
]))

test('a line that is a page link alone is the page\'s card, with what it is and where it is filed', async ({ page }) => {
  const markdown = `${sourceCard}\n\n${pageLink}\n\n[The lab](foreverlm://notebook/nb-1)\n`
  const errors = await openEditor(page, markdown)
  await targets(page)
  await settle(page)
  const card = page.locator('p.artifact-reference', { hasText: 'Do mutations drive aging?' })
  await expect(card).toHaveAttribute('data-reference-state', 'inApp')
  await expect(card).toHaveClass(/artifact-source-card/)
  await expect(card.locator('.artifact-reference-thumbnail')).toHaveAttribute('data-kind', 'app-doc')
  await expect(card.locator('.artifact-reference-thumbnail .artifact-app-card-sheet')).toHaveCount(1)
  await expect(card.locator('.artifact-reference-meta')).toHaveText('Page · Lab notebook')
  const notebook = page.locator('p.artifact-reference', { hasText: 'The lab' })
  await expect(notebook.locator('.artifact-reference-thumbnail')).toHaveAttribute('data-kind', 'app-notebook')
  await expect(notebook.locator('.artifact-reference-meta')).toHaveText('Notebook')
  // A card for one of the app's own things is not a question for the library.
  await settle(page, 250)
  const asked = (await messages(page, 'referencesChanged')).flatMap((message) => message.hrefs)
  expect(asked).toContain('foreverlm://source/alpha')
  expect(asked.some((href) => href.startsWith('foreverlm://doc/') || href.startsWith('foreverlm://notebook/'))).toBe(false)
  // The card is drawn; the Markdown is the link it was.
  expect(await stored(page)).toBe(markdown)
  expect(errors).toEqual([])
})

test('a page link in a sentence, in a list or to one block stays a link', async ({ page }) => {
  const markdown = `See ${pageLink} for more.\n\n- ${pageLink}\n\n[A block](foreverlm://doc/page-2#a1b2c3d4e)\n\n[A heading](foreverlm://doc/page-2#methods)\n`
  const errors = await openEditor(page, markdown)
  await targets(page)
  await settle(page)
  await expect(page.locator('p.artifact-reference')).toHaveCount(0)
  expect(errors).toEqual([])
})

test('a press anywhere on a page card opens the page, with no Open pill under the pointer', async ({ page }) => {
  const markdown = `Intro words.\n\n${pageLink}\n`
  const errors = await openEditor(page, markdown)
  await targets(page)
  await settle(page)
  const card = page.locator('p.artifact-reference', { hasText: 'Do mutations drive aging?' })
  await card.locator('a').hover()
  await page.waitForTimeout(700)
  await expect(page.locator('.artifact-inapp-link-tooltip')).toBeHidden()
  await card.locator('a').click()
  await card.locator('.artifact-reference-thumbnail').click()
  const box = await card.boundingBox()
  await page.mouse.click(box.x + box.width * 0.7, box.y + box.height / 2)
  const opened = (await messages(page, 'openLinkRequested')).map((message) => message.href)
  expect(opened).toEqual(['foreverlm://doc/page-2', 'foreverlm://doc/page-2', 'foreverlm://doc/page-2'])
  expect(await stored(page)).toBe(markdown)
  expect(errors).toEqual([])
})

test('a page dropped over a line of words lands as its card beside it, not inside the sentence', async ({ page }) => {
  const errors = await openEditor(page, 'First paragraph of words.\n\nSecond paragraph of words.\n')
  await targets(page)
  const first = await page.locator('.ProseMirror p', { hasText: 'First paragraph' }).boundingBox()
  // The lower half of the first paragraph: the gap after it.
  const point = [first.x + 30, first.y + first.height * 0.75]
  await page.evaluate(([x, y]) => window.foreverLMArtifactEditor.previewLinkDrop(x, y), point)
  await expect(page.locator('.artifact-card-drop-line')).toHaveCount(1)
  await page.evaluate(([x, y]) => window.foreverLMArtifactEditor.insertLinksAt([
    { title: 'Second page', href: 'foreverlm://doc/page-3' },
    { title: 'Lab notebook', href: 'foreverlm://notebook/nb-1' },
  ], x, y), point)
  await settle(page)
  await expect(page.locator('.artifact-card-drop-line')).toHaveCount(0)
  expect(await stored(page)).toBe(
    'First paragraph of words.\n\n[Second page](foreverlm://doc/page-3)\n\n[Lab notebook](foreverlm://notebook/nb-1)\n\nSecond paragraph of words.\n'
  )
  await expect(page.locator('p.artifact-reference', { hasText: 'Second page' }).locator('.artifact-reference-meta')).toHaveText('Page · Draft')
  expect(errors).toEqual([])
})

test('a page dropped on an empty line takes the line', async ({ page }) => {
  const errors = await openEditor(page, '## Reading\n\n\nAfter.\n')
  await targets(page)
  await page.evaluate(() => {
    const view = window.__editorTest.view()
    let blank = null
    view.state.doc.forEach((node, offset) => {
      if (!blank && node.type.name === 'paragraph' && node.childCount === 0) blank = offset
    })
    const rect = view.nodeDOM(blank).getBoundingClientRect()
    window.foreverLMArtifactEditor.insertLinksAt([{ title: 'Second page', href: 'foreverlm://doc/page-3' }], rect.left + 20, rect.top + rect.height / 2)
  })
  await settle(page)
  expect(await blocks(page)).not.toContain('empty')
  expect(await stored(page)).toContain('## Reading\n\n[Second page](foreverlm://doc/page-3)\n\nAfter.')
  expect(errors).toEqual([])
})
