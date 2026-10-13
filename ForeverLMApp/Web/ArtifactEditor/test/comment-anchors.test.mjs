// Where a comment's passage is now. Run with `npm test` in this directory.

import assert from 'node:assert/strict'
import test from 'node:test'
import { Schema } from 'prosemirror-model'
import { findQuote, normalizedText, resolveAnchor, textIndex } from '../src/comment-anchors.js'

const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { content: 'inline*', group: 'block' },
    heading: { content: 'inline*', group: 'block', attrs: { level: { default: 2 } } },
    text: { group: 'inline' },
    hardbreak: { inline: true, group: 'inline' },
  },
  marks: { strong: {} },
})

const p = (...content) => schema.node('paragraph', null, content.map((item) => (typeof item === 'string' ? schema.text(item) : item)))
const doc = (...blocks) => schema.node('doc', null, blocks)
const strong = (words) => schema.text(words, [schema.marks.strong.create()])
const textOf = (node) => (from, to) => node.textBetween(from, to, '\n', '\n')

test('whitespace runs read as one space and the ends are trimmed', () => {
  const read = normalizedText('  one \n\n two  ')
  assert.equal(read.text, 'one two')
  assert.deepEqual(read.map, [2, 3, 4, 5, 9, 10, 11])
})

test('the stored place is kept while it still holds the words', () => {
  const page = doc(p('The cell makes energy.'), p('Mitochondria fuse and divide.'))
  const from = 1 + 'The cell makes '.length
  const anchor = { from, to: from + 'energy'.length, quote: 'energy' }
  assert.deepEqual(resolveAnchor(page, anchor, textOf(page)), { from: anchor.from, to: anchor.to })
})

test('words moved by an edit before them are found again', () => {
  const page = doc(p('A new opening line.'), p('The cell makes energy.'))
  const anchor = { from: 16, to: 22, quote: 'energy' }
  const found = resolveAnchor(page, anchor, textOf(page))
  assert.equal(page.textBetween(found.from, found.to), 'energy')
})

test('the occurrence nearest the old place wins', () => {
  const page = doc(p('energy first.'), p('Then more words here.'), p('energy second.'))
  const last = page.content.size - ' second.'.length - 1 - 'energy'.length
  const found = findQuote(textIndex(page), 'energy', last)
  assert.equal(found.from, last)
  const first = findQuote(textIndex(page), 'energy', 0)
  assert.equal(first.from, 1)
})

test('a quote across two paragraphs and across marks is found', () => {
  const page = doc(p('Before. The ', strong('cell'), ' makes'), p('energy now.'))
  const found = resolveAnchor(page, { from: 0, to: 0, quote: 'The cell makes\nenergy' }, textOf(page))
  assert.equal(page.textBetween(found.from, found.to, '\n', '\n'), 'The cell makes\nenergy')
})

test('a line break inside a paragraph parts the words as the selection read them', () => {
  const page = doc(p('one', schema.node('hardbreak'), 'two'))
  const found = resolveAnchor(page, { from: 99, to: 120, quote: 'one\ntwo' }, textOf(page))
  assert.deepEqual(found, { from: 1, to: 1 + 3 + 1 + 3 })
})

test('words no longer in the page leave the comment detached', () => {
  const page = doc(p('Entirely rewritten.'))
  assert.equal(resolveAnchor(page, { from: 1, to: 5, quote: 'energy' }, textOf(page)), null)
})

test('a comment with no words keeps a place that still fits the page', () => {
  const page = doc(p('Short.'))
  assert.deepEqual(resolveAnchor(page, { from: 1, to: 3, quote: '' }, textOf(page)), { from: 1, to: 3 })
  assert.equal(resolveAnchor(page, { from: 1, to: 99, quote: '' }, textOf(page)), null)
})
