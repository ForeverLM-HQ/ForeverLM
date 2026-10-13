// How long a key takes on a long page: `npm run e2e:budget`. The time from
// the key going down to the editor having handled it, measured in the page for
// each of 120 keys typed into the middle of a 6,500-word page. A frame is
// 16 ms; past it, typing visibly trails the fingers. The budget is for
// headless WebKit; the Mac app's web view measured the same editor at a
// median of 5 ms and a 90th percentile of 12 ms on a long daily note.
import { expect, test } from '@playwright/test'
import { caretIn, openEditor } from './editor-page.mjs'

const budget = { median: 8, p90: 16, max: 50 }

/// A long working page, made up: sections of paragraphs, lists, links,
/// grounded passages, a quote, a table and a footnote, about 6,500 words.
function longPage() {
  let seed = 11
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647
  const words = 'cell energy membrane potential respiration gradient proton synthase mitochondria fusion fission transport signal pathway cost living budget complex oxidative'.split(' ')
  const sentence = (count) => {
    const picked = Array.from({ length: count }, () => words[Math.floor(random() * words.length)])
    return `${picked[0][0].toUpperCase()}${picked.join(' ').slice(1)}.`
  }
  const paragraph = () => Array.from({ length: 6 }, () => sentence(10 + Math.floor(random() * 8))).join(' ')
  const sections = []
  for (let index = 1; index <= 27; index += 1) {
    sections.push(
      `## Section ${index}`,
      `[${sentence(9)}](foreverlm://grounding/src_${index}) ${paragraph()}`,
      paragraph(),
      Array.from({ length: 4 }, () => `* ${sentence(9)}`).join('\n'),
      `> ${sentence(14)}`,
      `See [the note](https://example.org/${index}) and ${sentence(8)}`,
    )
    if (index % 6 === 0) sections.push('| Measure | Value |\n| - | - |\n| Membrane potential | High |\n| Respiration | Low |')
  }
  return `# Long working page\n\n${sections.join('\n\n')}\n\nA closing line.[^1]\n\n[^1]: ${sentence(12)}\n`
}

test('a key on a long page is handled within a frame', async ({ page }) => {
  const markdown = longPage()
  expect(markdown.split(/\s+/).length).toBeGreaterThan(6000)
  await openEditor(page, markdown)
  await caretIn(page, 'Section 12')
  await page.keyboard.press('ArrowDown')
  await page.keyboard.press('End')
  await page.evaluate(() => {
    window.keyTimes = []
    let down = 0
    document.addEventListener('keydown', () => { down = performance.now() }, true)
    document.addEventListener('input', () => {
      const started = down
      setTimeout(() => window.keyTimes.push(performance.now() - started), 0)
    }, true)
  })
  await page.keyboard.type(' typing at the end of a long paragraph in the middle of a long page, as a writer does, one key at a time', { delay: 35 })
  await page.waitForTimeout(300)
  const times = (await page.evaluate(() => window.keyTimes)).sort((left, right) => left - right)
  const at = (fraction) => times[Math.min(times.length - 1, Math.floor(fraction * times.length))]
  const result = { keys: times.length, median: +at(0.5).toFixed(1), p90: +at(0.9).toFixed(1), max: +times.at(-1).toFixed(1) }
  console.log(`typing on a ${markdown.split(/\s+/).length}-word page: ${JSON.stringify(result)} (budget ${JSON.stringify(budget)})`)
  expect(result.keys).toBeGreaterThan(100)
  expect(result.median).toBeLessThanOrEqual(budget.median)
  expect(result.p90).toBeLessThanOrEqual(budget.p90)
  expect(result.max).toBeLessThanOrEqual(budget.max)
})
