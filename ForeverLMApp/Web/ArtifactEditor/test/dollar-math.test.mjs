// Dollar signs on a Page: a price stays text, math stays math, and math the
// page writes reads back as math. Run with `npm test` in this directory.

import assert from 'node:assert/strict'
import test from 'node:test'
import remarkMath from 'remark-math'
import remarkParse from 'remark-parse'
import remarkStringify from 'remark-stringify'
import { unified } from 'unified'
import { remarkMoneyIsNotMath } from '../src/dollar-math.js'
import { renderInline } from '../src/notes-markdown.js'

const processor = unified().use(remarkParse).use(remarkStringify).use(remarkMath).use(remarkMoneyIsNotMath)

function nodesOf(tree, type) {
  const found = []
  const walk = (node) => {
    if (node.type === type) found.push(node)
    for (const child of node.children ?? []) walk(child)
  }
  walk(tree)
  return found
}

function mathRead(markdown) {
  return nodesOf(processor.runSync(processor.parse(markdown)), 'inlineMath').map((node) => node.value)
}

function written(children) {
  return processor.stringify({ type: 'root', children: [{ type: 'paragraph', children }] }).trim()
}

test('prices between single dollar signs stay text', () => {
  assert.deepEqual(mathRead('Sending out a few $20 copies of this book to the folks steering the $1.8'), [])
  assert.deepEqual(mathRead('$20 and $30'), [])
  assert.deepEqual(mathRead('between $5-$10 a month'), [])
  assert.deepEqual(mathRead('a $ x$ b'), [])
})

test('math between dollar signs stays math', () => {
  assert.deepEqual(mathRead('Energy is $E=mc^2$ here'), ['E=mc^2'])
  assert.deepEqual(mathRead('take $2x$ of it'), ['2x'])
  assert.deepEqual(mathRead('It costs $5. The formula is $x^2$.'), ['x^2'])
  assert.deepEqual(mathRead('Energy is $$E=mc^2$$ here'), ['E=mc^2'])
})

test('a refused span leaves the words after it read as Markdown', () => {
  const tree = processor.runSync(processor.parse('$20 for *this* book and $5'))
  assert.equal(nodesOf(tree, 'emphasis').length, 1)
  assert.equal(nodesOf(tree, 'inlineMath').length, 0)
})

test('math the page writes reads back as math', () => {
  const cases = [
    { children: [{ type: 'inlineMath', value: 'x^2' }], markdown: '$x^2$', math: ['x^2'] },
    { children: [{ type: 'inlineMath', value: 'x ' }], markdown: '$$x $$', math: ['x '] },
    { children: [{ type: 'inlineMath', value: ' x ' }], markdown: '$$  x  $$', math: [' x '] },
    { children: [{ type: 'inlineMath', value: 'x' }, { type: 'text', value: '2 more' }], markdown: '$$x$$2 more', math: ['x'] },
    { children: [{ type: 'inlineMath', value: 'a$b' }], markdown: '$$a$b$$', math: ['a$b'] },
  ]
  for (const { children, markdown, math } of cases) {
    assert.equal(written(children), markdown)
    assert.deepEqual(mathRead(markdown), math)
  }
})

test('Milkdown writes text ending in a space unescaped, and it still reads as money', () => {
  // Milkdown's text writer returns such a run as is, so "$5" before math is
  // saved without its backslash.
  assert.deepEqual(mathRead('cost the $5. Math: $x^2$ done'), ['x^2'])
})

test('snippets draw the same line', () => {
  assert.equal(renderInline('a few $20 copies, the $1.8 million'), 'a few $20 copies, the $1.8 million')
  assert.match(renderInline('Energy $E=mc^2$ here'), /<span class="artifact-snippet-math">E=mc\^2<\/span>/)
  assert.match(renderInline('inline $$x^2$$ too'), /^inline <span class="artifact-snippet-math">x\^2<\/span> too$/)
})
