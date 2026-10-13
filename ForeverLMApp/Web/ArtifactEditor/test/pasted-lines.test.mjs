// Lines pasted from a PDF: what a paste holds, and how the model's answer
// joins them. Run with `npm test` in this directory.

import assert from 'node:assert/strict'
import test from 'node:test'
import { Schema } from 'prosemirror-model'
import { EditorState } from 'prosemirror-state'
import { breaksFit, joinPastedLines, mayBePrintedLines, pastedLines, writtenSpan } from '../src/pasted-lines.js'

// The node names the page's schema uses (Milkdown's commonmark preset).
const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { content: 'inline*', group: 'block', attrs: { blockID: { default: '' } } },
    heading: { content: 'inline*', group: 'block', attrs: { level: { default: 2 } } },
    blockquote: { content: 'block+', group: 'block' },
    bullet_list: { content: 'list_item+', group: 'block' },
    list_item: { content: 'paragraph block*' },
    text: { group: 'inline' },
    hardbreak: { inline: true, group: 'inline' },
    image: { inline: true, group: 'inline', attrs: { src: { default: '' } } },
  },
  marks: { emphasis: {} },
})

const p = (...content) => schema.node('paragraph', null, content.filter((item) => item !== '').map((item) => (typeof item === 'string' ? schema.text(item) : item)))
const doc = (...blocks) => schema.node('doc', null, blocks)
const quote = (...blocks) => schema.node('blockquote', null, blocks)
const texts = (node) => {
  const found = []
  node.descendants((child) => {
    if (child.type.name === 'paragraph') {
      found.push(child.textContent)
      return false
    }
    return true
  })
  return found
}

/// The PDF quotation from the bug: one paragraph per printed line, in a quote.
const printed = [
  'To judge from all the efforts life scientists make to',
  'gather immense data sets, you might suppose that',
  'their discipline is hampered by lack of information.',
  'Huge international projects exist (and have existed) to',
]

function apply(state, span, lines, breaks) {
  const tr = state.tr
  const joined = joinPastedLines(tr, span, lines, breaks)
  return { joined, doc: tr.doc }
}

test('a paste of one paragraph per printed line reads as its lines and its paragraph boundaries', () => {
  const page = doc(p('Before.'), quote(...printed.map((line) => p(line))), p('After.'))
  const passage = pastedLines(page, 0, page.content.size)
  // Two containers: the page's own paragraphs and the quote's. Not a paste.
  assert.equal(passage, null)

  const inQuote = pastedLines(page, 10, page.content.size - 9)
  assert.deepEqual(inQuote.lines, printed)
  assert.deepEqual(inQuote.breaks.map((place) => place.kind), ['block', 'block', 'block'])
})

test('lines the model says run on join with one space, and a new paragraph stays apart', () => {
  const page = doc(quote(...printed.map((line) => p(line))))
  const state = EditorState.create({ doc: page })
  const span = pastedLines(page, 0, page.content.size)
  const { joined, doc: after } = apply(state, span, printed, ['space', 'space', 'paragraph'])
  assert.equal(joined, true)
  assert.deepEqual(texts(after), [
    'To judge from all the efforts life scientists make to gather immense data sets, you might suppose that their discipline is hampered by lack of information.',
    'Huge international projects exist (and have existed) to',
  ])
  assert.equal(after.firstChild.type.name, 'blockquote')
})

test('a plain-text paste, one paragraph broken by line feeds, joins and splits the same way', () => {
  const page = doc(p(printed.join('\n')))
  const state = EditorState.create({ doc: page })
  const span = pastedLines(page, 0, page.content.size)
  assert.deepEqual(span.lines, printed)
  assert.deepEqual(span.breaks.map((place) => place.kind), ['newline', 'newline', 'newline'])
  const { doc: after } = apply(state, span, printed, ['space', 'space', 'paragraph'])
  assert.deepEqual(texts(after), [
    'To judge from all the efforts life scientists make to gather immense data sets, you might suppose that their discipline is hampered by lack of information.',
    'Huge international projects exist (and have existed) to',
  ])
})

test('a hyphen that split a word goes; one that belongs to the words stays; spaces the copy left are dropped', () => {
  const lines = ['Another person was a fifty-six-', 'year-old man whose informa- ', '  tion was complete', 'in every way.']
  const page = doc(...lines.map((line) => p(line)))
  const state = EditorState.create({ doc: page })
  const span = pastedLines(page, 0, page.content.size)
  const { doc: after } = apply(state, span, lines, ['hyphen_kept', 'hyphen_split', 'space'])
  assert.deepEqual(texts(after), ['Another person was a fifty-six-year-old man whose information was complete in every way.'])
})

test('hard breaks are line breaks too, and marks stay on their words', () => {
  const page = doc(p(
    schema.text('A line that runs', [schema.marks.emphasis.create()]),
    schema.node('hardbreak'),
    'on to the next',
    schema.node('hardbreak'),
    'and the next.',
  ))
  const state = EditorState.create({ doc: page })
  const span = pastedLines(page, 0, page.content.size)
  assert.deepEqual(span.lines, ['A line that runs', 'on to the next', 'and the next.'])
  const { doc: after } = apply(state, span, span.lines, ['space', 'space'])
  assert.deepEqual(texts(after), ['A line that runs on to the next and the next.'])
  const runs = []
  after.firstChild.forEach((child) => runs.push({ text: child.text, emphasis: child.marks.length > 0 }))
  assert.ok(runs.some((run) => run.emphasis && run.text.startsWith('A line that runs')))
  assert.ok(runs.some((run) => !run.emphasis && run.text.startsWith('on to the next')))
})

test('nothing changes when the lines are no longer as they were sent', () => {
  const page = doc(...printed.map((line) => p(line)))
  const state = EditorState.create({ doc: page })
  const span = pastedLines(page, 0, page.content.size)
  const edited = [...printed]
  edited[1] = 'gather immense data sets, you might suppose'
  const { joined, doc: after } = apply(state, span, edited, ['space', 'space', 'space'])
  assert.equal(joined, false)
  assert.ok(after.eq(page))
})

test('an answer that does not fit the lines changes nothing', () => {
  const page = doc(...printed.map((line) => p(line)))
  const state = EditorState.create({ doc: page })
  const span = pastedLines(page, 0, page.content.size)
  for (const breaks of [
    ['space', 'space'],
    ['space', 'space', 'space', 'space'],
    ['space', 'sideways', 'space'],
    // Line 1 ends in "to", not a hyphen.
    ['hyphen_split', 'space', 'space'],
  ]) {
    const { joined, doc: after } = apply(state, span, printed, breaks)
    assert.equal(joined, false, JSON.stringify(breaks))
    assert.ok(after.eq(page))
  }
  assert.equal(breaksFit(['a', '', 'b'], ['space', 'paragraph']), false)
  assert.equal(breaksFit(['a', '', 'b'], ['paragraph', 'paragraph']), true)
})

test('a heading, a list the paste made, or a picture is not printed lines', () => {
  const withHeading = doc(p('One line'), schema.node('heading', null, [schema.text('A heading')]), p('Another line'))
  assert.equal(pastedLines(withHeading, 0, withHeading.content.size), null)

  const list = schema.node('bullet_list', null, [
    schema.node('list_item', null, [p('First item')]),
    schema.node('list_item', null, [p('Second item')]),
  ])
  const withList = doc(list)
  assert.equal(pastedLines(withList, 0, withList.content.size), null)

  const withPicture = doc(p('A line', schema.node('image')), p('Another'))
  assert.equal(pastedLines(withPicture, 0, withPicture.content.size), null)
})

test('only a few short lines are worth asking about', () => {
  assert.equal(mayBePrintedLines(printed), true)
  assert.equal(mayBePrintedLines(printed.slice(0, 2)), false)
  assert.equal(mayBePrintedLines(['One', '', 'Two', '']), false)
  assert.equal(mayBePrintedLines([...printed, 'x'.repeat(201)]), false)
  assert.equal(mayBePrintedLines(Array.from({ length: 401 }, () => 'a printed line')), false)
})

test('the span a paste wrote is found from its transaction', () => {
  const page = doc(p('Before.'), p(''), p('After.'))
  const state = EditorState.create({ doc: page })
  const emptyParagraph = page.child(0).nodeSize
  const tr = state.tr.replaceWith(emptyParagraph, emptyParagraph + 2, printed.map((line) => p(line)))
  const span = writtenSpan(tr)
  const passage = pastedLines(tr.doc, span.from, span.to)
  assert.deepEqual(passage.lines, printed)
})
