// A page cites with footnotes, and pointing at a number shows the sources its
// note names; nothing stands beside the prose. A table stands in the column of
// the writing, as Confluence draws one.
import { expect, test } from '@playwright/test'
import { caretIn, messages, openEditor, settle } from './editor-page.mjs'

const paperURL = 'https://doi.org/10.1371/journal.pgen.1003794'
const page = [
  '# Thesis',
  '',
  'Oxidised deoxyguanosine yields C>A transversions, and those are rare in aging human brain.[^1] What accumulates is heavy-strand-biased C>T.[^2]',
  '',
  `A sentence that links [a paper](${paperURL}) in its words.`,
  '',
  '| Tissue | s_log2FC | 95% CI | Clonal expansion when mutagenesis halted |',
  '| --- | --- | --- | --- |',
  '| Spleen | 0.365 | 0.300 to 0.409 | halted |',
  '| Liver | -0.039 | -0.068 to -0.0091 | continued |',
  '',
  `[^1]: [Ultra-sensitive sequencing reveals an age-related increase in somatic mitochondrial mutations](${paperURL}) — Kennedy et al., PLoS Genet, 2013`,
  '',
  '[^2]: [Origins and functional consequences of somatic mitochondrial DNA mutations](foreverlm://source/src_ju) and [The multi-tissue landscape](foreverlm://source/src_sc)',
  '',
].join('\n')

test('a cited paragraph has nothing beside it, and the host still hears every address', async ({ page: browser }) => {
  const errors = await openEditor(browser, page)
  await settle(browser, 250)
  expect(await browser.locator('.milkdown .editor .artifact-cited-source').count()).toBe(0)
  expect(await browser.locator('.artifact-margin-cards').count()).toBe(0)
  const reported = (await messages(browser, 'referencesChanged')).at(-1)
  expect(reported.hrefs).toEqual(expect.arrayContaining([paperURL, 'foreverlm://source/src_ju', 'foreverlm://source/src_sc']))
  expect(reported).not.toHaveProperty('marginColumn')
  expect(errors).toEqual([])
})

test('pointing at a number shows a row for each source its note names, and a row opens its source', async ({ page: browser }) => {
  const errors = await openEditor(browser, page)
  await browser.evaluate((url) => window.foreverLMArtifactEditor.setReferenceStatuses({
    [url]: { state: 'inLibrary', sourceID: 'src_kennedy', title: 'Ultra-Sensitive Sequencing Reveals an Age-Related Increase', detail: 'Scott R. Kennedy et al. · PLoS Genet · 2013' },
    'foreverlm://source/src_ju': { state: 'inLibrary', sourceID: 'src_ju', title: 'Origins and functional consequences', detail: 'Young Seok Ju et al. · eLife · 2014' },
  }), paperURL)
  await settle(browser)

  // Note 1 is one link and a byline: the card is that source's row alone.
  await browser.locator('sup.artifact-footnote-ref').first().hover()
  const card = browser.locator('.artifact-footnote-card')
  await expect(card).toBeVisible()
  await expect(card.locator('.artifact-cited-source')).toHaveCount(1)
  await expect(card.locator('.artifact-cited-source-title')).toHaveText('Ultra-Sensitive Sequencing Reveals an Age-Related Increase')
  await expect(card.locator('.artifact-footnote-card-words')).toHaveCount(0)
  await browser.screenshot({ path: test.info().outputPath('card.png') })

  // Note 2 names two library sources (the editor joins the two into one
  // grounded run): a row each, the library's title on the one it answered.
  await browser.locator('sup.artifact-footnote-ref').nth(1).hover()
  await expect(card.locator('.artifact-cited-source')).toHaveCount(2)
  await expect(card.locator('.artifact-cited-source-title').first()).toHaveText('Origins and functional consequences')

  // The pointer crosses into the card, and the card stays to be pressed.
  const row = card.locator('.artifact-cited-source').first()
  await row.hover()
  await browser.waitForTimeout(400)
  await expect(card).toBeVisible()
  await row.click()
  const opened = (await messages(browser, 'openSourceRequested')).at(-1)
  expect(opened.sourceID).toBe('src_ju')
  expect(errors).toEqual([])
})

test('pointing at an inline link already in the library shows the source instead of the raw URL', async ({ page: browser }) => {
  const errors = await openEditor(browser, page)
  await browser.evaluate((url) => window.foreverLMArtifactEditor.setReferenceStatuses({
    [url]: { state: 'inLibrary', sourceID: 'src_kennedy', title: 'Ultra-Sensitive Sequencing Reveals an Age-Related Increase', detail: 'Scott R. Kennedy et al. · PLoS Genet · 2013' },
  }), paperURL)
  await caretIn(browser, 'A sentence that links')
  await browser.locator('.ProseMirror a', { hasText: 'a paper' }).hover()

  const tooltip = browser.locator('.artifact-library-link-tooltip')
  await expect(tooltip).toBeVisible()
  await expect(tooltip.locator('.artifact-cited-source-title')).toHaveText('Ultra-Sensitive Sequencing Reveals an Age-Related Increase')
  await expect(tooltip).not.toContainText(paperURL)
  await expect(browser.locator('.milkdown-link-preview')).toHaveAttribute('data-show', 'false')

  await tooltip.locator('.artifact-cited-source').click()
  expect((await messages(browser, 'openSourceRequested')).at(-1).sourceID).toBe('src_kennedy')
  expect(errors).toEqual([])
})

test('pointing at an inline link absent from the library keeps the ordinary URL preview', async ({ page: browser }) => {
  const errors = await openEditor(browser, page)
  await browser.evaluate((url) => window.foreverLMArtifactEditor.setReferenceStatuses({
    [url]: { state: 'absent' },
  }), paperURL)
  await caretIn(browser, 'A sentence that links')
  await browser.locator('.ProseMirror a', { hasText: 'a paper' }).hover()

  await expect(browser.locator('.artifact-library-link-tooltip')).toBeHidden()
  await expect(browser.locator('.milkdown-link-preview')).toHaveAttribute('data-show', 'true')
  expect(errors).toEqual([])
})

test('a wide table stands in the column of the writing', async ({ page: browser }) => {
  await browser.setViewportSize({ width: 1600, height: 900 })
  const errors = await openEditor(browser, page)
  const prose = await browser.locator('.milkdown .editor > p').first().boundingBox()
  const table = await browser.locator('.milkdown .editor .milkdown-table-block table.children').boundingBox()
  expect(table.x).toBeGreaterThanOrEqual(prose.x - 1)
  expect(table.x + table.width).toBeLessThanOrEqual(prose.x + prose.width + 1)
  // A row is one line of its words, not two.
  const cell = await browser.locator('.milkdown .editor td').first().boundingBox()
  expect(cell.height).toBeLessThan(44)
  await browser.screenshot({ path: test.info().outputPath('page.png'), fullPage: true })
  expect(errors).toEqual([])
})

test('the notes are not drawn on the page; a press on a number opens its card, and Edit Note opens the note', async ({ page: browser }) => {
  const errors = await openEditor(browser, page)
  const note = browser.locator('.milkdown .editor .artifact-footnote').first()
  await expect(note).toBeHidden()

  // A press keeps the card open after the pointer leaves the number.
  await browser.locator('sup.artifact-footnote-ref').first().click()
  const card = browser.locator('.artifact-footnote-card')
  await expect(card).toBeVisible()
  await browser.mouse.move(5, 5)
  await browser.waitForTimeout(400)
  await expect(card).toBeVisible()

  // Edit Note draws the notes with the caret in this one; leaving it hides them again.
  await card.locator('.artifact-footnote-card-edit').click()
  await expect(card).toBeHidden()
  await expect(note).toBeVisible()
  await caretIn(browser, 'A sentence that links')
  await expect(note).toBeHidden()

  // A press elsewhere closes a pinned card.
  await browser.locator('sup.artifact-footnote-ref').nth(1).click()
  await expect(card).toBeVisible()
  await browser.locator('.milkdown .editor h1').click()
  await expect(card).toBeHidden()
  expect(errors).toEqual([])
})
