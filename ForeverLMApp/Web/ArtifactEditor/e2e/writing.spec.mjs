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

test('a press in the margin beside the prose goes to that line, as on paper', async ({ page }) => {
  // Either side of the prose column is the page's background, and a press
  // there left the caret where it was.
  await openEditor(page, '# Title\n\nA first line\n\n\n\n## A heading\n\n- item one\n- item two\n\nPlain line.\n')
  const box = await page.evaluate(() => window.__editorTest.view().dom.getBoundingClientRect().toJSON())
  const middleOf = (prefix) => page.evaluate((start) => {
    const view = window.__editorTest.view()
    let found = null
    view.state.doc.descendants((node, pos) => {
      if (!found && node.isTextblock && node.textContent.startsWith(start)) found = view.nodeDOM(pos).getBoundingClientRect()
    })
    return (found.top + found.bottom) / 2
  }, prefix)
  const caret = () => page.evaluate(() => {
    const { state } = window.__editorTest.view()
    const { $head, from, to } = state.selection
    return { line: $head.parent.textContent, offset: $head.parentOffset, selected: state.doc.textBetween(from, to, '¶') }
  })
  const press = async (x, y) => {
    await page.mouse.click(x, y)
    await settle(page)
  }
  await press(box.left - 40, await middleOf('A first'))
  expect(await caret()).toEqual({ line: 'A first line', offset: 0, selected: '' })
  await press(box.right + 40, await middleOf('A first'))
  expect(await caret()).toEqual({ line: 'A first line', offset: 12, selected: '' })
  await press(box.right + 40, await middleOf('A heading'))
  expect(await caret()).toEqual({ line: 'A heading', offset: 9, selected: '' })
  await press(box.left - 40, await middleOf('item two'))
  expect(await caret()).toEqual({ line: 'item two', offset: 0, selected: '' })
  // Shift extends to the line pressed beside.
  await page.keyboard.down('Shift')
  await press(box.right + 40, await middleOf('Plain'))
  await page.keyboard.up('Shift')
  expect((await caret()).selected).toBe('item two¶Plain line.')
  // A drag down the margin selects line by line.
  await page.mouse.move(box.left - 40, await middleOf('A first'))
  await page.mouse.down()
  await page.mouse.move(box.left - 40, await middleOf('item one'), { steps: 6 })
  await page.mouse.up()
  await settle(page)
  expect((await caret()).selected).toBe('A first line¶¶¶A heading')
})

test('a click is checked once the caret has settled: a plain one says nothing, one that meets a replacement is reported', async ({ page }) => {
  await openEditor(page, 'The first line of the page\n\nThe second line, a little longer\n\nThe third line\n')
  const middleOf = (prefix) => page.evaluate((start) => {
    const view = window.__editorTest.view()
    let found = null
    view.state.doc.descendants((node, pos) => {
      if (!found && node.isTextblock && node.textContent.startsWith(start)) {
        const rect = view.nodeDOM(pos).getBoundingClientRect()
        found = { x: rect.left + 40, y: (rect.top + rect.bottom) / 2 }
      }
    })
    return found
  }, prefix)
  const diagnostics = () => messages(page, 'clickDiagnostic')
  await clearMessages(page)
  const second = await middleOf('The second')
  await page.mouse.click(second.x, second.y)
  await page.waitForTimeout(400)
  expect(await diagnostics()).toEqual([])
  // The page handed back a moment after the press, as a save can be.
  const third = await middleOf('The third')
  await page.mouse.move(third.x, third.y)
  await page.mouse.down()
  await page.evaluate(() => {
    const live = window.foreverLMArtifactEditor.serializedMarkdown()
    window.foreverLMArtifactEditor.setMarkdown(live.replace('The third line', 'The third line!'), { key: 'page-1', folds: '[]' })
  })
  await page.mouse.up()
  await page.waitForTimeout(400)
  const reported = await diagnostics()
  expect(reported).toHaveLength(1)
  expect(reported[0].reason).toBe('replaced')
  expect(reported[0].click.x).toBeCloseTo(third.x, 0)
  expect(JSON.stringify(reported[0])).not.toContain('third')
})
