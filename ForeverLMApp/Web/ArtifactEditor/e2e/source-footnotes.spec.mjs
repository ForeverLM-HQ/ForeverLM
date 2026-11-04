// A library source linked to a passage is a footnote after it: the number in the
// sentence, the source's title linked to the source in the note at the foot, the
// passage's sources attached as before. Both ways a source is linked go through
// the same footnote: a drop on the words, and the passage's sources picker.
import { expect, test } from '@playwright/test'
import { caretIn, openEditor, selectBlock, settle, stored } from './editor-page.mjs'

const paper = { sourceID: 'src_a1', title: 'Mitochondrial gene expression' }
const second = { sourceID: 'src_b2', title: 'Heteroplasmy in ageing' }
const book = { sourceID: 'src_c3', title: 'Cell biology', bookID: 'book_9' }

const link = (citation) => `[${citation.title}](foreverlm://source/${citation.sourceID})`

test('a source dropped on the highlighted words becomes a footnote after them', async ({ page }) => {
  await openEditor(page, '# Notes\n\nMitochondria keep their own genome.\n\nA second paragraph.\n')
  await selectBlock(page, 'Mitochondria keep')
  await page.evaluate((citations) => window.foreverLMArtifactEditor.attachSourcesToSelection(citations), [paper])
  await settle(page)
  const markdown = await stored(page)
  // The sentence still stands on the source for Chat, and a number follows it.
  expect(markdown).toContain('[Mitochondria keep their own genome.](foreverlm://grounding/src_a1)[^1]')
  expect(markdown).toMatch(new RegExp(`\\n\\[\\^1\\]: ${link(paper).replace(/[[\]()]/g, '\\$&')}\\n?$`))
  expect(markdown).toContain('A second paragraph.')
})

test('two sources are two numbers, in the order they were dropped, and book rows link their chapter', async ({ page }) => {
  await openEditor(page, '# Notes\n\nMitochondria keep their own genome.\n')
  await selectBlock(page, 'Mitochondria keep')
  await page.evaluate((citations) => window.foreverLMArtifactEditor.attachSourcesToSelection(citations), [paper, book])
  await settle(page)
  const markdown = await stored(page)
  expect(markdown).toContain('genome.](foreverlm://grounding/src_a1,book%3Abook_9)[^1][^2]')
  expect(markdown).toContain(`[^1]: ${link(paper)}`)
  expect(markdown).toContain(`[^2]: ${link(book)}`)
})

test('a second source after the first numbers on from the first, and a source already attached gets no second note', async ({ page }) => {
  await openEditor(page, '# Notes\n\nMitochondria keep their own genome.\n')
  await selectBlock(page, 'Mitochondria keep')
  await page.evaluate((citations) => window.foreverLMArtifactEditor.attachSourcesToSelection(citations), [paper])
  await settle(page)
  await selectBlock(page, 'Mitochondria keep')
  await page.evaluate((citations) => window.foreverLMArtifactEditor.attachSourcesToSelection(citations), [paper, second])
  await settle(page)
  const markdown = await stored(page)
  expect(markdown.match(/\[\^\d+\]:/g)).toHaveLength(2)
  expect(markdown).toContain(`[^1]: ${link(paper)}`)
  expect(markdown).toContain(`[^2]: ${link(second)}`)
  expect(markdown).toContain('src_a1,src_b2)[^1][^2]')
})

test('the sources picker links its new sources as footnotes too, and detaching leaves the notes alone', async ({ page }) => {
  await openEditor(page, '# Notes\n\nMitochondria keep their own genome.\n')
  await selectBlock(page, 'Mitochondria keep')
  await page.evaluate(([ids, citations]) => window.foreverLMArtifactEditor.attachSources(ids, citations), [['src_a1', 'book:book_9'], [paper, book]])
  await settle(page)
  let markdown = await stored(page)
  expect(markdown).toContain('genome.](foreverlm://grounding/src_a1,book%3Abook_9)[^1][^2]')
  expect(markdown).toContain(`[^1]: ${link(paper)}`)
  expect(markdown).toContain(`[^2]: ${link(book)}`)
  // The picker answers with the whole list: the paper stays, the book goes, nothing is added.
  await selectBlock(page, 'Mitochondria keep')
  await page.evaluate(([ids, citations]) => window.foreverLMArtifactEditor.attachSources(ids, citations), [['src_a1'], [paper]])
  await settle(page)
  markdown = await stored(page)
  expect(markdown).toContain('genome.](foreverlm://grounding/src_a1)[^1][^2]')
  expect(markdown.match(/\[\^\d+\]:/g)).toHaveLength(2)
})

test('a source the host sent without its title is attached and has no note', async ({ page }) => {
  await openEditor(page, '# Notes\n\nMitochondria keep their own genome.\n')
  await selectBlock(page, 'Mitochondria keep')
  await page.evaluate(() => window.foreverLMArtifactEditor.attachSources(['src_a1']))
  await settle(page)
  const markdown = await stored(page)
  expect(markdown).toContain('[Mitochondria keep their own genome.](foreverlm://grounding/src_a1)')
  expect(markdown).not.toContain('[^')
})

test('one undo takes the footnote and the attachment together', async ({ page }) => {
  await openEditor(page, '# Notes\n\nMitochondria keep their own genome.\n')
  await selectBlock(page, 'Mitochondria keep')
  await page.evaluate((citations) => window.foreverLMArtifactEditor.attachSourcesToSelection(citations), [paper])
  await settle(page)
  expect(await stored(page)).toContain('[^1]')
  await caretIn(page, 'Mitochondria keep')
  await page.keyboard.press('Meta+z')
  await settle(page)
  const markdown = await stored(page)
  expect(markdown).not.toContain('[^')
  expect(markdown).not.toContain('grounding')
})

test('inside a note the source is attached without a number', async ({ page }) => {
  await openEditor(page, '# Notes\n\nA claim.[^1]\n\n[^1]: Words of the note.\n')
  await selectBlock(page, 'Words of the note')
  await page.evaluate((citations) => window.foreverLMArtifactEditor.attachSourcesToSelection(citations), [paper])
  await settle(page)
  const markdown = await stored(page)
  expect(markdown.match(/\[\^\d+\]:/g)).toHaveLength(1)
  expect(markdown).toContain('foreverlm://grounding/src_a1')
})
