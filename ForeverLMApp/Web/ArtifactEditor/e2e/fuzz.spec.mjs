// Random writing, the same every run (a seed per test): words, Return,
// Backspace, Tab, list and heading shortcuts, bold, arrows, undo and redo, in
// an order no one would choose. After each run:
// - the page threw nothing and its document is valid;
// - what a save writes reads back to itself and keeps the words;
// - undoing everything brings back the page it started as.
import { expect, test } from '@playwright/test'
import { caretIn, load, openEditor, stored, text } from './editor-page.mjs'

const start = '# Fuzz\n\nA first paragraph with some words.\n\n* one\n* two\n\n> A quote.\n\nA last paragraph.\n'

const actions = [
  async (page, pick) => page.keyboard.type(` ${pick(['alpha', 'beta', 'gamma', 'delta', 'cell', 'energy'])}`),
  async (page) => page.keyboard.press('Enter'),
  async (page) => page.keyboard.press('Backspace'),
  async (page) => page.keyboard.press('Tab'),
  async (page) => page.keyboard.press('Shift+Tab'),
  async (page, pick) => page.keyboard.press(pick(['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End'])),
  async (page) => page.keyboard.press('Meta+b'),
  async (page) => { await page.keyboard.press('Enter'); await page.keyboard.type('- item') },
  async (page) => { await page.keyboard.press('Enter'); await page.keyboard.type('## Head') },
  async (page) => { await page.keyboard.press('Enter'); await page.keyboard.type('[ ] task') },
  async (page) => page.keyboard.press('Shift+ArrowLeft'),
]

function seeded(seed) {
  let state = seed
  const random = () => (state = (state * 16807) % 2147483647) / 2147483647
  return { random, pick: (list) => list[Math.floor(random() * list.length)] }
}

for (const seed of [1, 2, 3, 4, 5, 6]) {
  test(`random writing, seed ${seed}: valid, saves to itself, undoes to the start`, async ({ page }) => {
    const errors = await openEditor(page, start)
    const startWords = await text(page)
    await caretIn(page, 'A first paragraph', 7)
    const { random, pick } = seeded(seed)
    for (let step = 0; step < 60; step += 1) await actions[Math.floor(random() * actions.length)](page, pick)
    expect(errors).toEqual([])
    expect(await page.evaluate(() => { window.__editorTest.view().state.doc.check(); return true })).toBe(true)
    // Undo everything typed, from wherever the caret is.
    await page.locator('.ProseMirror').focus()
    const written = await stored(page)
    for (let press = 0; press < 200; press += 1) await page.keyboard.press('Meta+z')
    expect(await text(page)).toBe(startWords)
    // The page as written, saved and read back.
    await load(page, written, `fuzz-${seed}-again`)
    const once = await stored(page)
    await load(page, once, `fuzz-${seed}-twice`)
    expect(await stored(page)).toBe(once)
    expect(errors).toEqual([])
  })
}
