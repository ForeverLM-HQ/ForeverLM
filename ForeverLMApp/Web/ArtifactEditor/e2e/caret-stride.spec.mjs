// Writing down a page moves the page in strides, not a line at a time: each
// wrapped line used to nudge the whole page up by one line, so the text crept
// upward under the writer's eyes. Arrow keys keep their short step.
import { expect, test } from '@playwright/test'
import { caretIn, openEditor } from './editor-page.mjs'

const paragraph = (index) => Array.from({ length: 6 }, (_, line) => `Sentence ${index}.${line} about the cell membrane potential and respiration gradient.`).join(' ')
const markdown = `# Title\n\n${Array.from({ length: 30 }, (_, index) => paragraph(index)).join('\n\n')}\n`

const scrollOf = (page) => page.evaluate(() => Math.round(window.scrollY))

test('typing past the foot of the window scrolls in strides', async ({ page }) => {
  await openEditor(page, markdown)
  await caretIn(page, 'Sentence 29.0')
  await page.keyboard.press('End')
  await page.evaluate(() => { const view = window.__editorTest.view(); view.dispatch(view.state.tr.scrollIntoView()) })
  await page.keyboard.type(' ')
  const steps = []
  let last = await scrollOf(page)
  const words = ' a lot of words that wrap over several lines of the page as a writer types them one key at a time'.repeat(14)
  for (const key of words) {
    await page.keyboard.type(key)
    const now = await scrollOf(page)
    if (now !== last) steps.push(now - last)
    last = now
  }
  // Eight wrapped paragraphs' worth of lines moved the page, but in a few
  // strides of several lines each, never one line (about 25 points) at a time.
  expect(steps.length).toBeGreaterThan(0)
  for (const step of steps) expect(step).toBeGreaterThan(60)
})

test('arrow keys down a page keep the short step', async ({ page }) => {
  await openEditor(page, markdown)
  await caretIn(page, 'Sentence 3.0')
  await page.evaluate(() => { const view = window.__editorTest.view(); view.dispatch(view.state.tr.scrollIntoView()) })
  const steps = []
  let last = await scrollOf(page)
  for (let press = 0; press < 40; press += 1) {
    await page.keyboard.press('ArrowDown')
    const now = await scrollOf(page)
    if (now !== last) steps.push(now - last)
    last = now
  }
  expect(steps.length).toBeGreaterThan(0)
  for (const step of steps) expect(step).toBeLessThan(60)
})
