// Comments on the passage, as Codex's Pages has them: the host's threads are
// marked in the page, the marks follow the words as the writer types, a click
// on marked words opens the thread, and the host's choice of thread shows its
// passage. Nothing of it reaches the stored page or its undo.
import { expect, test } from '@playwright/test'
import { caretIn, clearMessages, load, messages, openEditor, settle, stored } from './editor-page.mjs'

const page1 = '# Notes\n\nThe cell makes energy from food.\n\nMitochondria fuse and divide.\n'

/// The place `words` stand in the page now, as the editor's selection reports it.
async function placeOf(page, words) {
  return page.evaluate((wanted) => {
    const view = window.__editorTest.view()
    let found = null
    view.state.doc.descendants((node, pos) => {
      if (found || !node.isText) return true
      const at = node.text.indexOf(wanted)
      if (at >= 0) found = { from: pos + at, to: pos + at + wanted.length }
      return true
    })
    return found
  }, words)
}

const marks = (page) => page.evaluate(() => [...document.querySelectorAll('.artifact-comment-anchor')].map((mark) => ({
  id: mark.dataset.commentId,
  text: mark.textContent,
  active: mark.classList.contains('is-active'),
})))

async function setThreads(page, threads) {
  await page.evaluate((list) => window.foreverLMArtifactEditor.setCommentAnchors(list), threads)
  await settle(page)
}

test('a thread marks its passage, and the marks follow the words as the writer types before them', async ({ page }) => {
  await openEditor(page, page1)
  const place = await placeOf(page, 'energy')
  await setThreads(page, [{ id: 'c1', ...place, resolved: false, quote: 'energy' }])
  expect(await marks(page)).toEqual([{ id: 'c1', text: 'energy', active: false }])
  await caretIn(page, 'The cell', 0)
  await page.keyboard.type('Today ')
  await settle(page)
  expect(await marks(page)).toEqual([{ id: 'c1', text: 'energy', active: false }])
  // Sending the threads again keeps the place the edit carried them to.
  await setThreads(page, [{ id: 'c1', ...place, resolved: false, quote: 'energy' }])
  expect(await marks(page)).toEqual([{ id: 'c1', text: 'energy', active: false }])
  expect(await stored(page)).toBe('# Notes\n\nToday The cell makes energy from food.\n\nMitochondria fuse and divide.\n')
})

test('a stale place is found again by its words, and gone words are reported detached', async ({ page }) => {
  await openEditor(page, page1)
  await clearMessages(page)
  await setThreads(page, [
    { id: 'moved', from: 2, to: 6, resolved: false, quote: 'fuse and divide' },
    { id: 'gone', from: 3, to: 9, resolved: false, quote: 'words no longer here' },
  ])
  expect(await marks(page)).toEqual([{ id: 'moved', text: 'fuse and divide', active: false }])
  expect((await messages(page, 'commentAnchorsResolved')).at(-1).detached).toEqual(['gone'])
})

test('a resolved thread is marked only while it is the open one', async ({ page }) => {
  await openEditor(page, page1)
  const place = await placeOf(page, 'Mitochondria')
  await setThreads(page, [{ id: 'done', ...place, resolved: true, quote: 'Mitochondria' }])
  expect(await marks(page)).toEqual([])
  await page.evaluate(() => window.foreverLMArtifactEditor.setActiveComment('done', { reveal: true }))
  await settle(page)
  expect(await marks(page)).toEqual([{ id: 'done', text: 'Mitochondria', active: true }])
  await page.evaluate(() => window.foreverLMArtifactEditor.setActiveComment(null))
  await settle(page)
  expect(await marks(page)).toEqual([])
})

test('a click on marked words opens the thread and leaves the caret there', async ({ page }) => {
  await openEditor(page, page1)
  const place = await placeOf(page, 'energy')
  await setThreads(page, [{ id: 'c1', ...place, resolved: false, quote: 'energy' }])
  await clearMessages(page)
  await page.locator('.artifact-comment-anchor').click()
  await settle(page)
  expect((await messages(page, 'commentAnchorClicked')).map((message) => message.id)).toEqual(['c1'])
  expect(await marks(page)).toEqual([{ id: 'c1', text: 'energy', active: true }])
  const caret = await page.evaluate(() => window.__editorTest.view().state.selection.from)
  expect(caret).toBeGreaterThanOrEqual(place.from)
  expect(caret).toBeLessThanOrEqual(place.to)
})

test('the marks never enter the stored page, the undo, or a published copy', async ({ page }) => {
  await openEditor(page, page1)
  const place = await placeOf(page, 'energy')
  await setThreads(page, [{ id: 'c1', ...place, resolved: false, quote: 'energy' }])
  await caretIn(page, 'Mitochondria')
  await page.keyboard.type(' Often.')
  await settle(page, 300)
  await page.keyboard.press('Meta+z')
  await settle(page)
  expect(await stored(page)).toBe(page1)
  expect(await marks(page)).toEqual([{ id: 'c1', text: 'energy', active: false }])
  const html = await page.evaluate(() => window.foreverLMArtifactEditor.publicationHTML('Notes'))
  expect(html).not.toContain('artifact-comment-anchor')
  expect(html).toContain('makes energy from')
})

test('another page opens without the last page\'s marks', async ({ page }) => {
  await openEditor(page, page1)
  const place = await placeOf(page, 'energy')
  await setThreads(page, [{ id: 'c1', ...place, resolved: false, quote: 'energy' }])
  await load(page, '# Other\n\nThe cell makes energy too.\n', 'page-2')
  expect(await marks(page)).toEqual([])
})
