// Lines pasted from a PDF, as the page holds them: which paragraphs a paste
// wrote, the printed lines they hold, and the joins the Pasted Line Joining
// model says they need (PastedLineJoining.swift). The editor asks and applies
// (artifact-editor.js); this only reads and changes a ProseMirror document, so
// a test can run it without a browser (test/pasted-lines.test.mjs).

/// As the host reads them (`PastedLineJoining`): a few printed lines, never a
/// book's worth, and none longer than a printed line.
export const pastedLineLimits = { minimumLines: 3, maximumLines: 400, maximumLineLength: 200 }

const lineEndHyphens = new Set(['-', '‐', '‑', '­'])
const lineBreakKinds = new Set(['space', 'paragraph', 'hyphen_split', 'hyphen_kept', 'join'])

/// The span of the new document a transaction wrote, or null when it wrote
/// nothing.
export function writtenSpan(tr) {
  let from = Infinity
  let to = -Infinity
  tr.mapping.maps.forEach((map, index) => {
    const after = tr.mapping.slice(index + 1)
    map.forEach((_oldStart, _oldEnd, newStart, newEnd) => {
      from = Math.min(from, after.map(newStart, -1))
      to = Math.max(to, after.map(newEnd, 1))
    })
  })
  return from <= to ? { from, to } : null
}

/// The lines of the paragraphs a span touches, and where each break between
/// two of them stands: the boundary of two paragraphs, a line feed in the
/// text, or a hard break. Null unless they are paragraphs of plain text side by
/// side in one container: a heading, a list the paste made, a picture or a
/// footnote was not printed lines.
export function pastedLines(doc, from, to) {
  const blocks = []
  let plain = true
  doc.nodesBetween(Math.max(0, from), Math.min(to, doc.content.size), (node, pos) => {
    if (!plain) return false
    if (!node.isTextblock) return true
    if (node.type.name === 'paragraph') blocks.push({ node, pos })
    else plain = false
    return false
  })
  if (!plain || blocks.length === 0) return null
  const $first = doc.resolve(blocks[0].pos)
  const besideOneAnother = blocks.every(({ pos }, index) => {
    const $pos = doc.resolve(pos)
    return $pos.parent === $first.parent && $pos.index() === $first.index() + index
  })
  if (!besideOneAnother) return null

  const lines = ['']
  const breaks = []
  blocks.forEach(({ node, pos }, blockIndex) => {
    if (blockIndex > 0) {
      breaks.push({ kind: 'block', at: pos })
      lines.push('')
    }
    node.forEach((child, offset) => {
      if (!plain) return
      let cursor = pos + 1 + offset
      if (child.isText) {
        child.text.split('\n').forEach((part, index) => {
          if (index > 0) {
            breaks.push({ kind: 'newline', at: cursor })
            cursor += 1
            lines.push('')
          }
          lines[lines.length - 1] += part
          cursor += part.length
        })
      } else if (child.type.name === 'hardbreak') {
        breaks.push({ kind: 'hardbreak', at: cursor })
        lines.push('')
      } else {
        plain = false
      }
    })
  })
  if (!plain) return null
  const last = blocks[blocks.length - 1]
  return { from: blocks[0].pos, to: last.pos + last.node.nodeSize, lines, breaks }
}

/// Whether a paste is worth a question: enough lines with words, none longer
/// than a printed line. Anything else stays as pasted without asking.
export function mayBePrintedLines(lines) {
  const { minimumLines, maximumLines, maximumLineLength } = pastedLineLimits
  return lines.length <= maximumLines
    && lines.filter((line) => line.trim()).length >= minimumLines
    && lines.every((line) => line.length <= maximumLineLength)
}

/// Whether `breaks` is an answer for `lines`: one known break for each pair,
/// a hyphen's break only after a line ending in one, and nothing joined onto
/// an empty line. The host checks the same (`PastedLineJoining.breaks`).
export function breaksFit(lines, breaks) {
  if (!Array.isArray(breaks) || breaks.length !== Math.max(lines.length - 1, 0)) return false
  return breaks.every((kind, index) => {
    if (!lineBreakKinds.has(kind)) return false
    if (kind === 'paragraph') return true
    const before = lines[index].trimEnd()
    if (!before || !lines[index + 1].trim()) return false
    return !(kind === 'hyphen_split' || kind === 'hyphen_kept') || lineEndHyphens.has(before.at(-1))
  })
}

/// Join the lines a span holds as `breaks` says, into `tr`, and say whether it
/// did. Nothing changes unless the span still holds exactly `lines`, the lines
/// that were sent, and the breaks fit them. Breaks are applied last to first,
/// so each one's place is still where it was read.
export function joinPastedLines(tr, span, lines, breaks) {
  const passage = pastedLines(tr.doc, span.from, span.to)
  if (!passage || passage.lines.length !== lines.length) return false
  if (passage.lines.some((line, index) => line !== lines[index])) return false
  if (!breaksFit(lines, breaks)) return false
  for (let index = breaks.length - 1; index >= 0; index -= 1) {
    const kind = breaks[index]
    const { kind: place, at } = passage.breaks[index]
    if (kind === 'paragraph') {
      if (place === 'block') continue
      // A break inside a paragraph that ended one: the paragraph splits there.
      tr.delete(at, at + 1)
      tr.split(at)
      continue
    }
    let junction = at
    if (place === 'block') {
      tr.join(at)
      junction = at - 1
    } else {
      tr.delete(at, at + 1)
    }
    // The spaces the copy left at the line's end and the next one's start.
    const trailing = lines[index].length - lines[index].trimEnd().length
    const leading = lines[index + 1].length - lines[index + 1].trimStart().length
    if (kind === 'space') {
      tr.insertText(' ', junction - trailing, junction + leading)
    } else if (kind === 'hyphen_split') {
      tr.delete(junction - trailing - 1, junction + leading)
    } else if (trailing + leading > 0) {
      tr.delete(junction - trailing, junction + leading)
    }
  }
  return tr.docChanged
}
