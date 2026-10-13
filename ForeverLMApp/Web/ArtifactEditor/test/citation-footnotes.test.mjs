// Citation numbers pasted from an article: each is a footnote whose note is
// the reference the page gave the number. Run with `npm test` in this
// directory.

import assert from 'node:assert/strict'
import test from 'node:test'
import { citationFootnote } from '../src/footnotes.js'

const article = 'https://www.example.org/articles/acme-2025-0001'

test('a number with its reference in the title is a note holding that reference', () => {
  const footnote = citationFootnote({
    words: '32',
    href: `${article}#ref-CR32`,
    address: `${article}#ref-CR32`,
    title: 'Holt, Z. &  Reyes, A. Mitochondrial gene expression.\n Cells 9, 17 (2019).',
    ariaLabel: 'Reference 32',
  })
  assert.deepEqual(footnote, {
    label: '32',
    note: [{ type: 'paragraph', content: [{ type: 'text', text: 'Holt, Z. & Reyes, A. Mitochondrial gene expression. Cells 9, 17 (2019).' }] }],
  })
})

test('a number with no reference given links to where it pointed', () => {
  const withLabel = citationFootnote({ words: '33', href: `${article}#ref-CR33`, address: `${article}#ref-CR33`, title: null, ariaLabel: 'Reference 33' })
  assert.deepEqual(withLabel.note, [{
    type: 'paragraph',
    content: [{ type: 'text', text: 'Reference 33', marks: [{ type: 'link', attrs: { href: `${article}#ref-CR33` } }] }],
  }])
  const bracketed = citationFootnote({ words: '[ 3 ]', href: 'https://en.example.org/wiki/Mitochondrion#cite_note-3', address: 'https://en.example.org/wiki/Mitochondrion#cite_note-3', title: '', ariaLabel: null })
  assert.equal(bracketed.label, '3')
  assert.equal(bracketed.note[0].content[0].text, 'https://en.example.org/wiki/Mitochondrion#cite_note-3')
})

test('a title that is only the number is no reference', () => {
  const footnote = citationFootnote({ words: '7', href: `${article}#ref-CR7`, address: `${article}#ref-CR7`, title: '7', ariaLabel: null })
  assert.equal(footnote.note[0].content[0].marks[0].attrs.href, `${article}#ref-CR7`)
})

test('a number pointing into a page the browser did not resolve keeps an empty note', () => {
  assert.deepEqual(citationFootnote({ words: '12', href: '#ref-CR12', address: null, title: null, ariaLabel: null }), {
    label: '12',
    note: [{ type: 'paragraph' }],
  })
})

test('words that are not a number, and numbers linking elsewhere, are links', () => {
  assert.equal(citationFootnote({ words: 'citation needed', href: `${article}#x`, address: `${article}#x`, title: null, ariaLabel: null }), null)
  assert.equal(citationFootnote({ words: '2a', href: `${article}#Fig2`, address: `${article}#Fig2`, title: null, ariaLabel: null }), null)
  assert.equal(citationFootnote({ words: '4', href: 'foreverlm://source/abc', address: null, title: null, ariaLabel: null }), null)
  assert.equal(citationFootnote({ words: '5', href: 'mailto:zara@example.org', address: null, title: null, ariaLabel: null }), null)
})
