// The editor and its host talk by messages that arrive late and out of order:
// the host answers a report with the text it was told, a save lands after more
// typing, a page opens while a report is on its way. These tests stand in a
// host that does that on purpose and check that nothing typed is lost or lands
// in the wrong page.
import { expect, test } from '@playwright/test'
import { caretIn, clearMessages, load, messages, openEditor, settle, stored, text } from './editor-page.mjs'

test('a host that echoes old text back at random never takes typing back', async ({ page }) => {
  await openEditor(page, '# Echo\n\nStart.\n')
  // As the Mac pane does, only slower and less orderly: every report comes back
  // as setMarkdown 0 to 400 ms later, and one in three hands back the report
  // before it instead.
  await page.evaluate(() => {
    let seed = 7
    const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647
    const told = []
    window.onHostMessage = (message) => {
      if (message.type !== 'markdownChanged') return
      told.push(message.markdown)
      const answer = random() < 0.33 && told.length > 1 ? told[told.length - 2] : message.markdown
      setTimeout(() => window.foreverLMArtifactEditor.setMarkdown(answer), random() * 400)
    }
  })
  await caretIn(page, 'Start')
  const typed = ' The quick brown fox jumps over the lazy dog, again and again, while the host answers late.'
  await page.keyboard.type(typed, { delay: 25 })
  await page.waitForTimeout(800)
  expect(await text(page)).toBe(`EchoStart.${typed}`)
})

test('a report sent on leaving a page names that page', async ({ page }) => {
  await openEditor(page, '# A\n\nAlpha.\n', { key: 'a' })
  await caretIn(page, 'Alpha')
  await page.keyboard.type(' typed')
  await clearMessages(page)
  await page.evaluate(() => document.activeElement?.blur())
  await load(page, '# B\n\nBeta.\n', 'b')
  await caretIn(page, 'Beta')
  await page.keyboard.type(' more')
  await page.keyboard.press('Meta+s')
  const reports = await messages(page, 'markdownChanged')
  expect(reports[0]).toMatchObject({ key: 'a' })
  expect(reports[0].markdown).toContain('Alpha. typed')
  expect(reports.at(-1)).toMatchObject({ key: 'b' })
  expect(reports.at(-1).markdown).toContain('Beta. more')
})

test('a page opened inside the pause after typing never shows the words typed before', async ({ page }) => {
  await openEditor(page, '', { key: 'first-empty' })
  await page.locator('.ProseMirror').click()
  await page.keyboard.type('Typed into the first empty page')
  await load(page, '', 'second-empty')
  expect(await text(page)).toBe('')
  for (let press = 0; press < 4; press += 1) await page.keyboard.press('Meta+z')
  expect(await text(page)).toBe('')
})

test('a teammate edit elsewhere keeps the caret, and typing goes on where it was', async ({ page }) => {
  await openEditor(page, '# Doc\n\nFirst para.\n\n## Mid\n\nCaret here.\n')
  await caretIn(page, 'Caret', 5)
  await page.evaluate(() => window.foreverLMArtifactEditor.setMarkdown('# Doc\n\nFirst para, changed by a teammate.\n\n## Mid\n\nCaret here.\n'))
  await settle(page)
  await page.keyboard.type('X')
  expect(await stored(page)).toContain('CaretX here.')
  expect(await stored(page)).toContain('changed by a teammate')
})

test('a save handed back after a click keeps the caret where the click put it, below empty lines', async ({ page }) => {
  // The caret was carried as a character count that empty lines and line
  // breaks threw off: the save the Mac hands back a moment after typing put it
  // lines away, back where the writer had typed instead of where they clicked.
  await openEditor(page, '# Notes\n\nA line with a break\\\nin it\n\ndid NMN have some toxicity\n\n\n\n## Etienne Hebert\n\nMitochondrial signaling\n')
  await caretIn(page, 'did NMN')
  await page.keyboard.type('x')
  await caretIn(page, 'Etienne Hebert')
  const caret = () => page.evaluate(() => {
    const { $head } = window.__editorTest.view().state.selection
    return [$head.parent.textContent, $head.parentOffset]
  })
  expect(await caret()).toEqual(['Etienne Hebert', 14])
  const typed = await stored(page)
  for (const handedBack of [typed, `${typed}\n`, typed.replace('Mitochondrial', 'Mitochondrial cell')]) {
    await page.evaluate((markdown) => window.foreverLMArtifactEditor.setMarkdown(markdown), handedBack)
    await settle(page)
    expect(await caret()).toEqual(['Etienne Hebert', 14])
  }
  // A change above the caret moves it with its words.
  await page.evaluate((markdown) => window.foreverLMArtifactEditor.setMarkdown(markdown.replace('# Notes', '# Notes\n\nA new first line')), await stored(page))
  await settle(page)
  expect(await caret()).toEqual(['Etienne Hebert', 14])
  await page.keyboard.type('!')
  expect(await stored(page)).toContain('## Etienne Hebert!')
})

test('unsentMarkdown hands over typing once, and nothing for a page left alone', async ({ page }) => {
  await openEditor(page, '# U\n\nWords.\n')
  expect(await page.evaluate(() => window.foreverLMArtifactEditor.unsentMarkdown())).toBeNull()
  await caretIn(page, 'Words')
  await page.keyboard.type(' new')
  const unsent = await page.evaluate(() => window.foreverLMArtifactEditor.unsentMarkdown())
  expect(unsent).toContain('Words. new')
  expect(await page.evaluate(() => window.foreverLMArtifactEditor.unsentMarkdown())).toBeNull()
})
