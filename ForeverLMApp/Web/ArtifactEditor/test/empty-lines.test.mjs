// A page's empty lines are stored as blank lines, not `<br />`. Run with `npm test`.

import assert from 'node:assert/strict'
import test from 'node:test'
import { blankLinesAsEmptyLines, emptyLinesAsBlankLines } from '../src/empty-lines.js'

const milkdown = (...blocks) => blocks.join('\n\n') + '\n'

test('an empty line between two blocks is one more blank line', () => {
  assert.equal(emptyLinesAsBlankLines(milkdown('A', '<br />', 'B')), 'A\n\n\nB\n')
  assert.equal(emptyLinesAsBlankLines(milkdown('A', '<br />', '<br />', '<br />', '## B')), 'A\n\n\n\n\n## B\n')
})

test('empty lines before the first block are blank lines too', () => {
  assert.equal(emptyLinesAsBlankLines(milkdown('<br />', '<br />', '### Title')), '\n\n### Title\n')
})

test('each way undoes the other', () => {
  const pages = [
    milkdown('A', '<br />', 'B'),
    milkdown('<br />', '<br />', '<br />', '### My personal journey', '<br />', 'I started.'),
    milkdown('A', 'B', '<br />', '<br />', '> quoted', '<br />', '| a | b |\n| - | - |\n| 1 | 2 |', 'end'),
    milkdown('Para', '<br />', '[^1]: The note.'),
  ]
  for (const page of pages) {
    assert.equal(blankLinesAsEmptyLines(emptyLinesAsBlankLines(page)), page)
  }
})

test('an empty line before a list item or an indented line keeps its <br />', () => {
  // Blank lines alone do not end a list: two lists would read back as one.
  const lists = milkdown('* one', '<br />', '* two')
  assert.equal(emptyLinesAsBlankLines(lists), lists)
  const ordered = milkdown('1. one', '<br />', '2. two')
  assert.equal(emptyLinesAsBlankLines(ordered), ordered)
  const indented = milkdown('* one', '<br />', '  more')
  assert.equal(emptyLinesAsBlankLines(indented), indented)
  // And blank lines between two lists are never read as empty lines.
  assert.equal(blankLinesAsEmptyLines('* one\n\n\n* two\n'), '* one\n\n\n* two\n')
  assert.equal(blankLinesAsEmptyLines('* one\n  * sub\n\n\n* two\n'), '* one\n  * sub\n\n\n* two\n')
})

test('an empty line before a list that follows prose is a blank line', () => {
  const page = milkdown('Some words.', '<br />', '* a point', '* another')
  assert.equal(emptyLinesAsBlankLines(page), 'Some words.\n\n\n* a point\n\n* another\n')
  assert.equal(blankLinesAsEmptyLines(emptyLinesAsBlankLines(page)), page)
  const heading = milkdown('### Heading', '<br />', '<br />', '1. first')
  assert.equal(blankLinesAsEmptyLines(emptyLinesAsBlankLines(heading)), heading)
})

test('code and math keep their lines as written', () => {
  const code = milkdown('A', '```\n<br />\n\n\n\nx\n```', 'B')
  assert.equal(emptyLinesAsBlankLines(code), code)
  assert.equal(blankLinesAsEmptyLines(code), code)
  const math = milkdown('A', '$$\nx\n\n\ny\n$$', 'B')
  assert.equal(blankLinesAsEmptyLines(math), math)
})

test('a <br /> that is part of a paragraph or a list item stays', () => {
  assert.equal(emptyLinesAsBlankLines('Line one\n<br />\n'), 'Line one\n<br />\n')
  assert.equal(emptyLinesAsBlankLines(milkdown('* <br />', 'B')), milkdown('* <br />', 'B'))
})

test('a single blank line between blocks is just a break', () => {
  assert.equal(blankLinesAsEmptyLines('A\n\nB\n'), 'A\n\nB\n')
  assert.equal(emptyLinesAsBlankLines('A\n\nB\n'), 'A\n\nB\n')
})

test('pages stored with <br /> read the same as before', () => {
  const old = milkdown('A', '<br />', 'B')
  assert.equal(blankLinesAsEmptyLines(old), old)
})

test('an empty table cell is stored empty, not as <br />', () => {
  assert.equal(emptyLinesAsBlankLines('| A | B |\n| - | - |\n| x | <br /> |\n| <br/> | y |\n'), '| A | B |\n| - | - |\n| x | |\n| | y |\n')
  // A cell that says something around a break, an escaped pipe, and code keep theirs.
  assert.equal(emptyLinesAsBlankLines('| a <br /> b | c |\n'), '| a <br /> b | c |\n')
  assert.equal(emptyLinesAsBlankLines('| a \\| <br /> | c |\n'), '| a \\| <br /> | c |\n')
  assert.equal(emptyLinesAsBlankLines('```\n| x | <br /> |\n```\n'), '```\n| x | <br /> |\n```\n')
})
