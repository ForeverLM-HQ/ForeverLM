// Comments sit on the passage they were made on, as Codex's do: the words a
// thread is about are marked in the page (artifact-editor.js, "Comment
// anchors"). A comment keeps the passage's place when it was made (from, to)
// and its words (quote). The page changes after that, so the place is a hint
// and the words decide: the stored place is taken while it still holds the
// words, and otherwise the words are looked for, the occurrence nearest the
// old place winning. Words that are no longer anywhere in the page leave the
// comment detached ("Original text unavailable"). Pure work on a document's
// shape, so a test runs it without an editor (test/comment-anchors.test.mjs).

/// Whitespace runs read as one space, at either end trimmed: a quote taken
/// across two paragraphs has a line break where the page's text has the
/// paragraphs' boundary, and a run of spaces is one gap either way.
/// `map[i]` is the index in the original text of normalized character `i`.
export function normalizedText(text) {
  const source = String(text ?? '')
  let out = ''
  const map = []
  let pendingSpace = -1
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index]
    if (/\s/.test(character)) {
      if (out.length > 0 && pendingSpace < 0) pendingSpace = index
      continue
    }
    if (pendingSpace >= 0) {
      out += ' '
      map.push(pendingSpace)
      pendingSpace = -1
    }
    out += character
    map.push(index)
  }
  return { text: out, map }
}

/// The document's words in reading order, a line break between text blocks,
/// with where each run of text starts in the document: `segments` holds
/// `{ start, end, pos }`, a run of the flat text from `start` to `end` that
/// begins at document position `pos`. Atoms (a picture, a math node) add no
/// words, as in `textBetween`.
export function textIndex(doc) {
  let text = ''
  const segments = []
  let lastBlock = null
  doc.descendants((node, pos, parent) => {
    if (node.isText) {
      if (lastBlock !== parent && text.length > 0) text += '\n'
      lastBlock = parent
      segments.push({ start: text.length, end: text.length + node.text.length, pos })
      text += node.text
      return false
    }
    // A line break or a picture inside a paragraph parts the words around it,
    // as the selection's text read it.
    if (node.isLeaf && node.isInline && text.length > 0) text += '\n'
    return true
  })
  return { text, segments }
}

/// The document position of flat offset `offset` (`textIndex`): inside a run,
/// or at the end of the run before a gap when `atEnd`.
function positionOf(segments, offset, atEnd) {
  for (const segment of segments) {
    if (offset >= segment.start && offset < segment.end) return segment.pos + (offset - segment.start)
    if (atEnd && offset === segment.end) return segment.pos + (offset - segment.start)
  }
  return null
}

/// The flat offset of document position `pos`, or the nearest run's start.
function offsetOf(segments, pos) {
  let best = 0
  let bestDistance = Infinity
  for (const segment of segments) {
    const length = segment.end - segment.start
    if (pos >= segment.pos && pos <= segment.pos + length) return segment.start + (pos - segment.pos)
    const distance = Math.abs(segment.pos - pos)
    if (distance < bestDistance) {
      bestDistance = distance
      best = segment.start
    }
  }
  return best
}

/// Where `quote` stands in the document, the occurrence nearest position
/// `near` winning, as `{ from, to }` document positions; null when the words
/// are not in it.
export function findQuote(index, quote, near = 0) {
  const wanted = normalizedText(quote).text
  if (!wanted) return null
  const haystack = normalizedText(index.text)
  const target = offsetOf(index.segments, near)
  let best = null
  let bestDistance = Infinity
  let at = haystack.text.indexOf(wanted)
  while (at >= 0) {
    const start = haystack.map[at]
    const end = haystack.map[at + wanted.length - 1] + 1
    const distance = Math.abs(start - target)
    if (distance < bestDistance) {
      const from = positionOf(index.segments, start, false)
      const to = positionOf(index.segments, end, true)
      if (from != null && to != null && to > from) {
        best = { from, to }
        bestDistance = distance
      }
    }
    at = haystack.text.indexOf(wanted, at + 1)
  }
  return best
}

/// The passage a comment is on now, or null when its words are gone. `text`
/// reads a stretch of the document the way the editor read the selection
/// the comment was made on (`textBetween` with line breaks between blocks).
export function resolveAnchor(doc, anchor, text, index = null) {
  const quote = String(anchor?.quote ?? '')
  const from = Number(anchor?.from)
  const to = Number(anchor?.to)
  const size = doc.content.size
  const placeIsValid = Number.isInteger(from) && Number.isInteger(to) && from >= 0 && to > from && to <= size
  if (!normalizedText(quote).text) return placeIsValid ? { from, to } : null
  if (placeIsValid) {
    try {
      if (normalizedText(text(from, to)).text === normalizedText(quote).text) return { from, to }
    } catch {
      // A place inside a node's markup: look for the words instead.
    }
  }
  return findQuote(index ?? textIndex(doc), quote, placeIsValid ? from : 0)
}
