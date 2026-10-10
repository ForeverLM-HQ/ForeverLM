// A block's properties, as the page's Markdown holds them
// (docs/docs-design.md, "Block properties").
//
// ChatGPT's Pages have properties Markdown has no word for: a table's width and
// how its columns fit, a highlight's colour. They are stored in the page text
// itself, as a one-line HTML comment on the line after the block it belongs to:
//
//     | a | b |
//     | - | - |
//     | 1 | 2 |
//
//     <!--fl {"width":"full","fit":"even"}-->
//
// Every Markdown renderer hides a comment, Chat and the MCP tools read it as
// text, and it travels with the page through sync, export and sharing. An
// editor that ignores it loses nothing. The rules:
//
// - one `fl` comment per block, directly after it, alone on one line;
// - JSON, an object, with only the keys the block takes (`properties` below)
//   and a known value for each; anything else is an ordinary comment and is
//   left exactly as it was written;
// - a block at its defaults has no comment: the editor writes none, and reads
//   one that spells out the defaults as the plain block it is.
//
// The editor keeps the properties as attributes of the block (`width` and
// `fit` on a table, `color` on a highlight) and nothing of the comment is text
// there, so it is never drawn and never typed over. `readBlockProperties` and
// `propertyComment` are the two halves; `attachBlockProperties` is the pass
// over a parsed page (artifact-editor.js) that hands each block the comment
// after it.

/// What each kind of block takes: its keys, the values each allows (the first
/// is the default, the one that writes no comment), in the order they are
/// written.
export const properties = {
  table: {
    width: ['normal', 'flexible', 'full'],
    fit: ['readability', 'even'],
  },
  highlight: {
    color: ['yellow', 'red', 'orange', 'green', 'blue', 'purple', 'gray'],
  },
}

/// A property comment on its one line: `<!--fl {…}-->`, with or without
/// spaces around the parts. What is between the braces is checked as JSON.
const propertyCommentPattern = /^<!--[ \t]*fl[ \t]+(\{[^\n]*\})[ \t]*-->$/

/// The colours of a highlight as the page draws them (the stylesheet's
/// `--artifact-highlight-*`, and a published copy's own rules).
export const highlightHex = {
  yellow: '#e0a800',
  red: '#e5484d',
  orange: '#f76b15',
  green: '#30a46c',
  blue: '#3b82f6',
  purple: '#8e4ec6',
  gray: '#8b8d98',
}

/// The defaults of a kind: `{ width: 'normal', fit: 'readability' }`.
export function defaultProperties(kind) {
  const keys = properties[kind] ?? {}
  return Object.fromEntries(Object.entries(keys).map(([key, values]) => [key, values[0]]))
}

/// The properties a comment line gives a block of `kind`, every key filled in
/// (the rest from the defaults); null when the line is not a property comment
/// for that kind: other text, a comment that is not valid JSON, an object
/// that is empty or holds a key or a value the kind does not take.
export function readBlockProperties(kind, line) {
  const keys = properties[kind]
  if (!keys) return null
  const match = propertyCommentPattern.exec(String(line ?? '').trim())
  if (!match) return null
  let given
  try {
    given = JSON.parse(match[1])
  } catch {
    return null
  }
  if (!given || typeof given !== 'object' || Array.isArray(given)) return null
  const names = Object.keys(given)
  if (names.length === 0) return null
  const result = defaultProperties(kind)
  for (const name of names) {
    if (!Object.prototype.hasOwnProperty.call(keys, name)) return null
    if (typeof given[name] !== 'string' || !keys[name].includes(given[name])) return null
    result[name] = given[name]
  }
  return result
}

/// The comment line for a block's properties, or null when every one is at its
/// default. Keys are written in the table's order, whatever order they were
/// set in, so the same properties always make the same text.
export function propertyComment(kind, values) {
  const keys = properties[kind]
  if (!keys) return null
  const written = {}
  for (const [name, allowed] of Object.entries(keys)) {
    const value = values?.[name]
    if (typeof value === 'string' && value !== allowed[0] && allowed.includes(value)) written[name] = value
  }
  return Object.keys(written).length ? `<!--fl ${JSON.stringify(written)}-->` : null
}

/// Whether a parsed block is a highlight: a quote whose first line is the bold
/// word "Highlight" (the same test as the editor's `calloutKind`, on Markdown's
/// own tree).
function isHighlightQuote(node) {
  if (node.type !== 'blockquote') return false
  const first = node.children?.[0]
  if (first?.type !== 'paragraph' || first.children?.length !== 1) return false
  const strong = first.children[0]
  if (strong.type !== 'strong' || strong.children?.length !== 1) return false
  const text = strong.children[0]
  return text.type === 'text' && String(text.value).trim() === 'Highlight'
}

function propertyKind(node) {
  if (node.type === 'table') return 'table'
  if (isHighlightQuote(node)) return 'highlight'
  return null
}

/// The line a node is, if it is nothing but one HTML comment: the node itself
/// (HTML in the page's flow) or a paragraph holding only that (what the editor's
/// HTML transformer makes of it). Null for anything else.
function commentLine(node) {
  if (node?.type === 'html') return String(node.value ?? '')
  if (node?.type === 'paragraph' && node.children?.length === 1 && node.children[0].type === 'html') {
    return String(node.children[0].value ?? '')
  }
  return null
}

/// The pass over a parsed page: each table and highlight whose next sibling is
/// a property comment it takes gets `properties` (every key filled in) and the
/// comment leaves the tree, so the page the editor builds has no trace of it.
/// Only the page's own top-level blocks take properties; a block inside a list
/// or a quote does not. A second comment in a row is not the block's, and stays
/// where it is.
export function attachBlockProperties(tree) {
  const children = tree?.type === 'root' ? tree.children : null
  if (!Array.isArray(children)) return tree
  for (let index = 0; index < children.length - 1; index += 1) {
    const kind = propertyKind(children[index])
    if (!kind) continue
    const line = commentLine(children[index + 1])
    if (line == null) continue
    const values = readBlockProperties(kind, line)
    if (!values) continue
    children[index].flProperties = values
    children.splice(index + 1, 1)
  }
  return tree
}
