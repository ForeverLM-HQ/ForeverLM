// A run of text keeps its escapes when bold or italic follows it. Run with `npm test`.

import assert from 'node:assert/strict'
import test from 'node:test'
import { toMarkdown } from 'mdast-util-to-markdown'
import { textWithItsEscapes } from '../src/markdown-text.js'

const write = (...children) => toMarkdown(
  { type: 'root', children: [{ type: 'paragraph', children }] },
  { handlers: { text: textWithItsEscapes } },
)
const text = (value) => ({ type: 'text', value })
const strong = (value) => ({ type: 'strong', children: [text(value)] })
const emphasis = (value) => ({ type: 'emphasis', children: [text(value)] })

test('a paragraph that starts like a list, a heading or a quote stays a paragraph', () => {
  assert.equal(write(text('- a point '), strong('in bold')), '\\- a point **in bold**\n')
  assert.equal(write(text('1. First, '), emphasis('then')), '1\\. First, *then*\n')
  assert.equal(write(text('# not a heading '), strong('x')), '\\# not a heading **x**\n')
  assert.equal(write(text('> not a quote '), strong('x')), '\\> not a quote **x**\n')
})

test('the space before a mark is written as a space', () => {
  assert.equal(write(text('Some words '), strong('bold'), text(' after.')), 'Some words **bold** after.\n')
  assert.equal(write(strong('one'), text(' '), emphasis('two')), '**one** *two*\n')
})

test('other text is escaped as remark escapes it', () => {
  assert.equal(write(text('a * b and [c]')), 'a \\* b and \\[c]\n')
  assert.equal(write(text('- plain')), '\\- plain\n')
})
