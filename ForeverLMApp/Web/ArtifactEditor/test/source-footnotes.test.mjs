// A source linked to a passage, as a footnote: which sources are new to the
// passage and what each one's note says. Run with `npm test` in this directory.

import assert from 'node:assert/strict'
import test from 'node:test'
import { freshSources, sourceFootnote, sourceToken } from '../src/footnotes.js'

const paper = { sourceID: 'src_a1', title: 'Mitochondrial gene expression' }
const chapter = { sourceID: 'src_c1', title: 'Cell biology', bookID: 'book_9' }

test('a book row stands as its book, anything else as its source', () => {
  assert.equal(sourceToken(paper), 'src_a1')
  assert.equal(sourceToken(chapter), 'book:book_9')
  assert.equal(sourceToken({ sourceID: ' src_a1 ', bookID: '  ' }), 'src_a1')
  assert.equal(sourceToken({}), '')
})

test('only the sources the passage did not stand on get a footnote, once each', () => {
  assert.deepEqual(freshSources([paper, chapter], ['src_a1', 'book:book_9']), [paper, chapter])
  // The passage already stood on the paper.
  assert.deepEqual(freshSources([paper, chapter], ['book:book_9']), [chapter])
  assert.deepEqual(freshSources([paper], []), [])
  // The same source dropped twice in one gesture is one footnote.
  assert.deepEqual(freshSources([paper, { ...paper, title: 'Again' }], ['src_a1']), [paper])
  assert.deepEqual(freshSources(null, ['src_a1']), [])
})

test('the note is the source title linked to the source', () => {
  const href = 'https://foreverlm.invalid/source/src_a1'
  assert.deepEqual(sourceFootnote({ title: ' Mitochondrial\n gene   expression ', href }), [{
    type: 'paragraph',
    content: [{ type: 'text', text: 'Mitochondrial gene expression', marks: [{ type: 'link', attrs: { href } }] }],
  }])
  // A source the host could not title is still a link a reader can follow.
  assert.equal(sourceFootnote({ title: '', href })[0].content[0].text, 'Source')
})
