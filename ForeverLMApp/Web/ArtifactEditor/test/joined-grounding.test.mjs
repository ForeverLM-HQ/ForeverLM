// A quote grounded line by line reads as one passage. Run with `npm test`.

import assert from 'node:assert/strict'
import test from 'node:test'
import remarkParse from 'remark-parse'
import remarkStringify from 'remark-stringify'
import { unified } from 'unified'
import { remarkJoinedGrounding } from '../src/joined-grounding.js'

const processor = unified().use(remarkParse).use(remarkJoinedGrounding).use(remarkStringify)
const read = (markdown) => processor.stringify(processor.runSync(processor.parse(markdown))).trim()
const source = 'foreverlm://grounding/src_8fcdf69cde54'

test('lines of one quote, grounded one by one across hard breaks, are one passage', () => {
  const page = `[To judge from all](${source})\\\n[their discipline is](${source})\\\n[hampered.](${source})`
  assert.equal(read(page), `[To judge from all\\\ntheir discipline is\\\nhampered.](${source})`)
})

test('links of one source parted by a space or a soft line join', () => {
  assert.equal(read(`[one](${source}) [two](${source})\n[three](${source})`), `[one two\nthree](${source})`)
})

test('the editor form of the address joins too', () => {
  const address = 'https://foreverlm.invalid/grounding/src_a,src_b'
  assert.equal(read(`[a](${address})\\\n[b](${address})`), `[a\\\nb](${address})`)
})

test('different sources, words between, and web links stay apart', () => {
  assert.equal(read(`[a](${source}) [b](foreverlm://grounding/src_other)`), `[a](${source}) [b](foreverlm://grounding/src_other)`)
  assert.equal(read(`[a](${source}) and [b](${source})`), `[a](${source}) and [b](${source})`)
  assert.equal(read('[a](https://example.org) [b](https://example.org)'), '[a](https://example.org) [b](https://example.org)')
})

test('a passage inside a list item or a heading joins as well', () => {
  assert.equal(read(`* [a](${source})\\\n  [b](${source})`), `* [a\\\n  b](${source})`)
  assert.equal(read(`## [a](${source}) [b](${source})`), `## [a b](${source})`)
})
