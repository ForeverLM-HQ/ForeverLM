// An empty line left on a page is writing space, and the page keeps it. Milkdown
// writes one as a paragraph holding `<br />`, so a draft with room between its
// thoughts was stored as dozens of `<br />` lines (95 on one daily note), which
// every reader of the Markdown met as markup: the model given the page as
// context, a Google Doc made from it, a published page, MCP.
//
// The stored page writes an empty line as what it is, one more blank line
// between two blocks, and the editor reads each blank line past the first as an
// empty line again. Plain Markdown readers fold the blank lines away. Two string
// passes at the editor's edge, so Milkdown's own handling of `<br />` (and every
// page stored that way before) is unchanged:
//
// - `emptyLinesAsBlankLines`, on the way out (`markdownForStorage`);
// - `blankLinesAsEmptyLines`, on the way in (`markdownForEditor`).
//
// Only lines at the page's top level, outside fenced code, are touched. Between
// a list and the list item or indented line after it, the `<br />` stays: blank
// lines alone do not end a list, so two lists with an empty line between them
// would read back as one, and an indented line after a list would join it.
// Pure strings, so a test runs it without an editor
// (test/empty-lines.test.mjs).

const breakLine = /^<br\s*\/?>[ \t]*$/i
const listItem = /^(?:[*+-]|\d{1,9}[.)])(?:[ \t]|$)/
const fenceOpen = /^ {0,3}(`{3,}|~{3,})/
const mathFence = /^ {0,3}\$\$[ \t]*$/

function isBlank(line) {
  return line !== undefined && line.trim() === ''
}

/// A line of a list: an item, or an indented line inside one.
function inList(line) {
  return line !== undefined && (/^[ \t]/.test(line) || listItem.test(line))
}

/// Empty lines between `previous` and `next` (the content lines around them)
/// can be blank lines: nothing after them would join a list before them.
function blankLinesHold(previous, next) {
  if (next === undefined) return true
  if (/^[ \t]/.test(next)) return false
  return !listItem.test(next) || !inList(previous)
}

function closesFence(line, marker) {
  if (marker === '$$') return mathFence.test(line)
  const match = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(line)
  return Boolean(match) && match[1][0] === marker[0] && match[1].length >= marker.length
}

/// Lines outside fenced code and `$$` math blocks, as a predicate on their
/// index.
function outsideCode(lines) {
  const inside = new Array(lines.length).fill(false)
  let marker = null
  lines.forEach((line, index) => {
    if (marker) {
      inside[index] = true
      if (closesFence(line, marker)) marker = null
      return
    }
    const open = fenceOpen.exec(line)
    if (open) marker = open[1]
    else if (mathFence.test(line)) marker = '$$'
  })
  return (index) => !inside[index]
}

/// `<br />` paragraphs at the top level become blank lines.
export function emptyLinesAsBlankLines(markdown) {
  const lines = String(markdown ?? '').split('\n')
  const free = outsideCode(lines)
  const kept = []
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]
    const empty = free(index) && breakLine.test(line)
      && (index === 0 || isBlank(lines[index - 1]))
      && (index === lines.length - 1 || isBlank(lines[index + 1]))
    if (empty) {
      let next = index + 1
      while (next < lines.length && (isBlank(lines[next]) || breakLine.test(lines[next]))) next += 1
      let previous = kept.length - 1
      while (previous >= 0 && (isBlank(kept[previous]) || breakLine.test(kept[previous]))) previous -= 1
      if (blankLinesHold(kept[previous], lines[next])) continue
    }
    kept.push(line)
  }
  return kept.join('\n')
}

/// Each blank line past the first between two top-level blocks, and each one
/// before the first block, becomes an empty line (`<br />`) for the editor.
export function blankLinesAsEmptyLines(markdown) {
  const lines = String(markdown ?? '').split('\n')
  const free = outsideCode(lines)
  const out = []
  let index = 0
  while (index < lines.length) {
    if (!isBlank(lines[index]) || !free(index)) {
      out.push(lines[index])
      index += 1
      continue
    }
    let end = index
    while (end < lines.length && isBlank(lines[end])) end += 1
    const run = end - index
    const atStart = out.length === 0
    const extra = atStart ? run : run - 1
    let previous = out.length - 1
    while (previous >= 0 && isBlank(out[previous])) previous -= 1
    if (end < lines.length && extra > 0 && blankLinesHold(out[previous], lines[end])) {
      if (!atStart) out.push('')
      for (let count = 0; count < extra; count += 1) out.push('<br />', '')
    } else {
      out.push(...lines.slice(index, end))
    }
    index = end
  }
  return out.join('\n')
}
