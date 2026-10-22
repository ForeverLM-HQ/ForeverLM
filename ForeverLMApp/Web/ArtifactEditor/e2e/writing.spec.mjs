// Writing in a page with the keyboard, as a writer does: every keystroke goes
// through WebKit's own events, so input rules, key handlers and the browser's
// editing run for real.
import { expect, test } from '@playwright/test'
import { blocks, caretIn, clearMessages, lastReport, load, messages, onePixelPNG, openEditor, paste, selectBlock, settle, stored, text } from './editor-page.mjs'

test('typed words land in the page and reach the host after the pause', async ({ page }) => {
  const errors = await openEditor(page, '# Title\n\nFirst line.\n')
  await caretIn(page, 'First line')
  await page.keyboard.type(' More words, typed one key at a time.')
  await expect.poll(async () => (await lastReport(page))?.markdown).toContain('First line. More words, typed one key at a time.')
  expect((await lastReport(page)).key).toBe('page-1')
  expect(errors).toEqual([])
})

test('Markdown shortcuts make their blocks as they are typed', async ({ page }) => {
  await openEditor(page, 'Start.\n')
  await caretIn(page, 'Start')
  for (const line of ['## A heading', '> A quote']) {
    await page.keyboard.press('Enter')
    if (line.startsWith('>')) await page.keyboard.press('Enter')
    await page.keyboard.type(line)
  }
  await page.keyboard.press('Enter')
  await page.keyboard.press('Enter')
  await page.keyboard.type('- one')
  await page.keyboard.press('Enter')
  await page.keyboard.type('two')
  await page.keyboard.press('Enter')
  await page.keyboard.press('Enter')
  await page.keyboard.type('1. first')
  await page.keyboard.press('Enter')
  await page.keyboard.press('Enter')
  await page.keyboard.type('[ ] a task')
  await page.keyboard.press('Enter')
  await page.keyboard.press('Enter')
  await page.keyboard.type('Some **bold** and `code` here.')
  const markdown = await stored(page)
  expect(markdown).toContain('## A heading')
  expect(markdown).toContain('> A quote')
  expect(markdown).toMatch(/[*-] one\n[*-] two\n/)
  expect(markdown).toContain('1. first')
  expect(markdown).toMatch(/[*-] \[ \] a task/)
  expect(markdown).toContain('Some **bold** and `code` here.')
})

test('typing straight after Return in a list keeps every letter in its place', async ({ page }) => {
  // Milkdown's list item put the caret back a frame after a new item mounted,
  // over the letters typed in between (build-patches.mjs).
  await openEditor(page, '* one two\n')
  await caretIn(page, 'one two')
  for (const word of ['three', 'four', 'five']) {
    await page.keyboard.press('Enter')
    await page.keyboard.type(word)
  }
  expect((await stored(page)).trimEnd()).toBe('* one two\n* three\n* four\n* five')
})

test('Backspace at the start of a heading makes it a paragraph first', async ({ page }) => {
  await openEditor(page, '# Page\n\n## Heading two\n')
  await caretIn(page, 'Heading two', 0)
  await page.keyboard.press('Backspace')
  expect(await stored(page)).toMatch(/\n\nHeading two\n/)
})

test('Tab nests a list item and does nothing in a paragraph', async ({ page }) => {
  await openEditor(page, '* one\n* two\n\nA paragraph.\n')
  await caretIn(page, 'two', 0)
  await page.keyboard.press('Tab')
  expect(await stored(page)).toMatch(/\* one\n\s+\* two/)
  await caretIn(page, 'A paragraph', 2)
  await page.keyboard.press('Tab')
  expect(await stored(page)).toContain('\nA paragraph.\n')
})

test('⌘Z never brings back another page', async ({ page }) => {
  await openEditor(page, '# Page A\n\nAlpha.\n', { key: 'a' })
  await caretIn(page, 'Alpha')
  await page.keyboard.type(' typed on A')
  await load(page, '# Page B\n\nBeta.\n', 'b')
  await caretIn(page, 'Beta')
  await page.keyboard.type(' typed on B')
  for (let press = 0; press < 8; press += 1) await page.keyboard.press('Meta+z')
  expect(await text(page)).toMatch(/^Page B/)
})

test('a ⌘ shortcut right after typing reports the words at once', async ({ page }) => {
  await openEditor(page, '# Leave\n\nLast words.\n')
  await caretIn(page, 'Last words')
  await page.keyboard.type(' and one more')
  await clearMessages(page)
  await page.keyboard.press('Meta+w')
  const reports = await messages(page, 'markdownChanged')
  expect(reports.at(-1)?.markdown).toContain('Last words. and one more')
})

test('an untouched page is never reported', async ({ page }) => {
  await openEditor(page, 'Title\n=====\n\nWords with a footnote.[^1]\n\n[^1]: The note.\n')
  await clearMessages(page)
  await page.locator('.ProseMirror').click()
  await page.keyboard.press('Meta+c')
  await page.evaluate(() => document.activeElement?.blur())
  await page.waitForTimeout(400)
  expect(await messages(page, 'markdownChanged')).toEqual([])
  expect(await page.evaluate(() => window.foreverLMArtifactEditor.unsentMarkdown())).toBeNull()
})

test('empty lines are kept, and stored as blank lines', async ({ page }) => {
  await openEditor(page, 'First.\n\n\n\nSecond.\n')
  expect(await blocks(page)).toEqual(['paragraph', 'empty', 'empty', 'paragraph'])
  await caretIn(page, 'Second')
  await page.keyboard.type(' Edited.')
  await page.keyboard.press('Meta+s')
  const markdown = (await lastReport(page)).markdown
  expect(markdown).toBe('First.\n\n\n\nSecond. Edited.\n')
  expect(markdown).not.toContain('<br')
})

test('a pasted heading keeps a line of its own, a pasted phrase its spaces', async ({ page }) => {
  await openEditor(page, '# P\n\nStart here.\n')
  await caretIn(page, 'Start here')
  await paste(page, { 'text/html': '<h2>Results</h2><p>Rose.</p>', 'text/plain': 'Results\nRose.' })
  expect(await stored(page)).toMatch(/Start here\.\n\n## Results/)
  await load(page, '# P\n\nStart here.\n', 'p2')
  await caretIn(page, 'Start here')
  await paste(page, { 'text/plain': ' and more' })
  expect(await stored(page)).toContain('Start here. and more')
})

test('a pasted picture goes to a host that keeps pictures, and nowhere on one that does not', async ({ page }) => {
  await openEditor(page, 'Text.\n')
  await caretIn(page, 'Text')
  await clearMessages(page)
  await paste(page, {}, [onePixelPNG])
  await expect.poll(async () => (await messages(page, 'imagesPasted')).length).toBe(1)
  await page.evaluate(() => window.foreverLMArtifactEditor.setSlashFeatures({ images: false }))
  await clearMessages(page)
  await paste(page, { 'text/plain': ' words copied with it' }, [onePixelPNG])
  expect(await stored(page)).toBe('Text. words copied with it\n')
  expect(await messages(page, 'imagesPasted')).toEqual([])
})

test('Edit with AI sends the passage alone, writes the answer into the page, and ⌘↩ then ⌘Z go back', async ({ page }) => {
  const source = 'foreverlm://grounding/src_8fcdf69cde54199827fc0d9c0487955011b277304017b849b034c0528b2c8616'
  await openEditor(page, `# A\n\nBody.[^1]\n\n[^1]: [one](${source})\\\n  [two](${source})\n`)
  await selectBlock(page, 'one')
  await clearMessages(page)
  await page.evaluate(() => window.foreverLMArtifactEditor.openAIEdit())
  await page.locator('.artifact-ai-edit [data-role=instruction]').fill('join the lines')
  await page.keyboard.press('Enter')
  const request = (await messages(page, 'aiEditRequested'))[0]
  expect(request.passage).not.toContain('[^1]')
  expect(request.passage).toContain('foreverlm://grounding/1')
  expect(request.passage).not.toContain('src_8fcdf')
  await page.evaluate((id) => window.foreverLMArtifactEditor.completeAIEdit(id, { markdown: '[one two](foreverlm://grounding/1)' }), request.requestID)
  // Joining the lines changes no word: the edit is written, and nothing in it
  // is marked new.
  await expect(page.locator('.artifact-ai-review')).toBeVisible()
  await expect(page.locator('.artifact-ai-insertion, .artifact-ai-removed')).toHaveCount(0)
  expect(await stored(page)).toContain(`[one two](${source})`)
  await page.keyboard.press('Meta+Enter')
  await settle(page)
  await expect(page.locator('.artifact-ai-review')).toHaveCount(0)
  expect(await stored(page)).toContain(`[one two](${source})`)
  await page.locator('.ProseMirror').focus()
  await page.keyboard.press('Meta+z')
  expect(await stored(page)).not.toContain('[one two]')
})

test('a click between two lines puts the caret on the nearer one, where it was clicked', async ({ page }) => {
  // WebKit gave the gap between two paragraphs to the start of the line below:
  // a click a little low at the end of a line started the next one instead.
  await openEditor(page, 'The first line of the page\n\nThe second line\n\n\nAfter an empty line\n')
  const lines = await page.evaluate(() => [...window.__editorTest.view().dom.children].map((element) => {
    const rect = element.getBoundingClientRect()
    return { text: element.textContent, top: rect.top, bottom: rect.bottom, left: rect.left, right: rect.right }
  }))
  const caret = () => page.evaluate(() => {
    const { $head } = window.__editorTest.view().state.selection
    return { line: $head.parent.textContent, offset: $head.parentOffset, size: $head.parent.content.size }
  })
  const [first, second, empty, last] = lines
  // A beat between clicks, as a hand gives: WebKit's selection change from one
  // click must not land on the next.
  const click = async (x, y) => {
    await page.mouse.click(x, y)
    await settle(page)
  }
  // Just under the end of the first line: its end, not the second line's start.
  await click(first.right - 10, first.bottom + 2)
  expect(await caret()).toEqual({ line: 'The first line of the page', offset: 26, size: 26 })
  // Just above the second line, near its start: on it, at the column clicked.
  await click(second.left + 30, second.top - 2)
  const onSecond = await caret()
  expect(onSecond.line).toBe('The second line')
  expect(onSecond.offset).toBeGreaterThan(0)
  expect(onSecond.offset).toBeLessThan(onSecond.size)
  // Just above the empty line: on it.
  await click(empty.left + 200, empty.top - 2)
  expect(await caret()).toEqual({ line: '', offset: 0, size: 0 })
  // Right of a line, on it: its end, as before.
  await click(last.right - 10, (last.top + last.bottom) / 2)
  expect(await caret()).toEqual({ line: 'After an empty line', offset: 19, size: 19 })
  // A drag that starts in a gap still selects.
  await page.mouse.move(first.right - 10, first.bottom + 2)
  await page.mouse.down()
  await page.mouse.move(last.left + 40, (last.top + last.bottom) / 2, { steps: 6 })
  await page.mouse.up()
  expect(await page.evaluate(() => window.__editorTest.view().state.selection.empty)).toBe(false)
  expect(await blocks(page)).toEqual(['paragraph', 'paragraph', 'empty', 'paragraph'])
})

test('a drag that ends or starts between two lines selects up to the nearer one', async ({ page }) => {
  // WebKit put a drag's end in the gap under a line at the start of the line
  // below: the highlight took in the line break and the next line's start, and
  // flicked back and forth as the pointer crossed each gap.
  await openEditor(page, 'The first line of the page\n\nThe second line, a little longer\n\nThe third line\n')
  const [first, second, third] = await page.evaluate(() => [...window.__editorTest.view().dom.children].map((element) => {
    const rect = element.getBoundingClientRect()
    const range = document.createRange()
    range.selectNodeContents(element)
    return { top: rect.top, bottom: rect.bottom, left: rect.left, textRight: range.getBoundingClientRect().right }
  }))
  const middle = (line) => (line.top + line.bottom) / 2
  const selected = () => page.evaluate(() => {
    const { state } = window.__editorTest.view()
    return state.doc.textBetween(state.selection.from, state.selection.to, '¶')
  })
  const drag = async (from, to) => {
    await page.mouse.click(5, 5)
    await settle(page)
    await page.mouse.move(...from)
    await page.mouse.down()
    await page.mouse.move(...to, { steps: 5 })
    await settle(page)
    const during = await selected()
    await page.mouse.up()
    await settle(page)
    expect(await selected()).toBe(during)
    return during
  }
  // Ends just under the end of the second line: up to its end, no line break.
  expect(await drag([first.left + 4, middle(first)], [second.textRight + 30, second.bottom + 2]))
    .toBe('The first line of the page¶The second line, a little longer')
  // Starts just under the end of the first line: from its end.
  expect(await drag([first.textRight - 2, first.bottom + 2], [third.textRight, middle(third)]))
    .toBe('¶The second line, a little longer¶The third line')
  // Back up into the gap above the line it started on: the column there.
  expect(await drag([third.textRight, middle(third)], [third.left + 30, third.top - 2])).not.toContain('¶')
  // Down across every gap, slowly, right of the words: the selection only ever
  // grows, a line at a time.
  await page.mouse.click(5, 5)
  await settle(page)
  await page.mouse.move(first.left + 4, middle(first))
  await page.mouse.down()
  const lengths = []
  for (let y = middle(first); y <= middle(third); y += 3) {
    await page.mouse.move(second.textRight + 40, y)
    await settle(page, 0)
    lengths.push((await selected()).length)
  }
  await page.mouse.up()
  for (let index = 1; index < lengths.length; index += 1) expect(lengths[index]).toBeGreaterThanOrEqual(lengths[index - 1])
})
