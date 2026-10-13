// A small Markdown-to-HTML renderer for what the notes graph shows outside
// the writing: a referenced block's text, an embed's block and what is nested
// under it, the page foot's Linked References, Unlinked References and
// earlier days. It reads the subset a Doc is written in (headings,
// paragraphs, nested and task lists, quotes, code, tables, emphasis, links)
// and the notes grammar (`((id))`, `{{embed: ((id))}}`, `[[Title]]`, `#tag`,
// ` ^id`), and it escapes every character it does not itself write, so a
// snippet can never carry markup of its own into the page.
//
// Links are drawn as anchors the page foot's click handler follows: an in-app
// address by `data-href`, a library source by `data-source-id`, a page named
// by title by `data-title`, a web address by `href`. Grounding, the invisible
// sources a passage stands on, is drawn as the words alone.

import { singleDollarSpanIsMoney } from './dollar-math.js'
import { embeddedBlockID, takeBlockIDMarker, unescapedTitle } from './notes-graph-syntax.js'

const entities = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }

export function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>"']/g, (character) => entities[character])
}

// A caller may wrap a stretch of the source in these two private-use
// characters to have it drawn highlighted (an Unlinked Reference's words).
export const highlightStart = '\uE000'
export const highlightEnd = '\uE001'

function textHTML(value) {
  return escapeHTML(value).replace(/\uE000/g, '<mark>').replace(/\uE001/g, '</mark>')
}

function attributeText(value) {
  return escapeHTML(String(value ?? '').replace(/[\uE000\uE001]/g, ''))
}

const asciiPunctuation = /[!-/:-@[-`{-~]/
const referenceAt = /\(\(([a-z0-9]{9})\)\)/y
const titleLinkAt = /\\?\[\\?\[((?:[^[\]\\\n]|\\[^\n])+?)\\?\]\\?\]/y
const tagAt = /\\?#(?:\\?\[\\?\[((?:[^[\]\\\n]|\\[^\n])+?)\\?\]\\?\]|([\p{L}\p{N}_\-/]*[\p{L}\p{N}_][\p{L}\p{N}_\-/]*))/uy
const autolinkAt = /<((?:https?:\/\/|mailto:)[^\s<>]+)>/y
const mathAt = /(\$\$?)([^$\n]+)\1/y

function stickyMatch(pattern, text, index) {
  pattern.lastIndex = index
  return pattern.exec(text)
}

/// The grammar token that starts exactly at `index`, or null.
function grammarAt(text, index) {
  const character = text[index]
  if (character === '(') {
    const match = stickyMatch(referenceAt, text, index)
    if (match) return { type: 'ref', blockID: match[1], end: index + match[0].length, raw: match[0] }
    return null
  }
  if (character === '#' || (character === '\\' && text[index + 1] === '#')) {
    const before = index === 0 ? '' : text[index - 1]
    if (before && !/[\s(]/.test(before)) return null
    const match = stickyMatch(tagAt, text, index)
    if (!match) return null
    const title = match[1] != null ? unescapedTitle(match[1]) : match[2]
    if (!title) return null
    return { type: 'tag', title, bracketed: match[1] != null, end: index + match[0].length }
  }
  if (character === '[' || (character === '\\' && text[index + 1] === '[')) {
    const match = stickyMatch(titleLinkAt, text, index)
    if (!match) return null
    const title = unescapedTitle(match[1])
    if (!title) return null
    return { type: 'page', title, end: index + match[0].length }
  }
  return null
}

/// A run of backticks at `index`, closed by a run of the same length: the
/// code span's text and where it ends, or null.
function codeSpanAt(text, index) {
  let length = 0
  while (text[index + length] === '`') length += 1
  let search = index + length
  while (search < text.length) {
    const next = text.indexOf('`'.repeat(length), search)
    if (next < 0) return null
    let run = 0
    while (text[next + run] === '`') run += 1
    if (run === length) {
      let inner = text.slice(index + length, next).replace(/\n/g, ' ')
      if (/^ .* $/.test(inner) && inner.trim()) inner = inner.slice(1, -1)
      return { code: inner, end: next + length }
    }
    search = next + run
  }
  return null
}

/// `[label](destination "title")` at `index`: the label's source, the
/// destination, and where the link ends; null when the text there is not a
/// link.
function linkAt(text, index) {
  if (text[index] !== '[') return null
  let depth = 0
  let close = -1
  for (let position = index; position < text.length; position += 1) {
    const character = text[position]
    if (character === '\\') {
      position += 1
      continue
    }
    if (character === '`') {
      const span = codeSpanAt(text, position)
      if (span) position = span.end - 1
      continue
    }
    if (character === '[') depth += 1
    else if (character === ']') {
      depth -= 1
      if (depth === 0) {
        close = position
        break
      }
    } else if (character === '\n' && text[position + 1] === '\n') {
      return null
    }
  }
  if (close < 0 || text[close + 1] !== '(') return null
  let position = close + 2
  while (text[position] === ' ') position += 1
  let destination = ''
  if (text[position] === '<') {
    const end = text.indexOf('>', position)
    if (end < 0) return null
    destination = text.slice(position + 1, end)
    position = end + 1
  } else {
    let parens = 0
    const start = position
    while (position < text.length) {
      const character = text[position]
      if (character === '\\') {
        position += 2
        continue
      }
      if (/\s/.test(character)) break
      if (character === '(') parens += 1
      if (character === ')') {
        if (parens === 0) break
        parens -= 1
      }
      position += 1
    }
    destination = text.slice(start, position)
  }
  while (text[position] === ' ') position += 1
  if (text[position] === '"' || text[position] === "'") {
    const quote = text[position]
    const end = text.indexOf(quote, position + 1)
    if (end < 0) return null
    position = end + 1
    while (text[position] === ' ') position += 1
  }
  if (text[position] !== ')') return null
  return { label: text.slice(index + 1, close), href: destination.replace(/\\(.)/g, '$1'), end: position + 1 }
}

function isWordCharacter(character) {
  return Boolean(character) && /[\p{L}\p{N}]/u.test(character)
}

/// Emphasis, strong emphasis or strikethrough opening at `index`: the tag,
/// the inner source and where it ends, or null. Intraword underscores are
/// never emphasis, as in CommonMark.
function emphasisAt(text, index) {
  const character = text[index]
  let length = 0
  while (text[index + length] === character) length += 1
  if (character === '~') {
    if (length !== 2) return null
  } else if (length > 3) {
    return null
  }
  const after = text[index + length]
  if (!after || /\s/.test(after)) return null
  if (character === '_' && isWordCharacter(text[index - 1])) return null
  const delimiter = character.repeat(length)
  let search = index + length
  while (search < text.length) {
    const found = text.indexOf(delimiter, search)
    if (found < 0) return null
    let run = 0
    while (text[found + run] === character) run += 1
    const before = text[found - 1]
    const following = text[found + run]
    const closes = run === length
      && before && !/\s/.test(before)
      && found > index + length
      && !(character === '_' && isWordCharacter(following))
    if (closes) {
      const tag = character === '~' ? 's' : length === 1 ? 'em' : length === 2 ? 'strong' : 'strong'
      const inner = text.slice(index + length, found)
      return { tag, inner: length === 3 ? `*${inner}*` : inner, end: found + run }
    }
    search = found + run
  }
  return null
}

/// The in-app kinds a link may name, and what follows them.
const inAppKinds = new Set(['doc', 'notebook', 'project', 'idea', 'chat', 'quiz'])

function linkHTML(labelHTML, href) {
  const address = String(href ?? '').trim()
  const lower = address.toLowerCase()
  if (lower.startsWith('foreverlm://grounding/') || lower.startsWith('https://foreverlm.invalid/grounding/')) {
    return labelHTML
  }
  const inApp = /^(?:foreverlm:\/\/|https:\/\/foreverlm\.invalid\/)([a-z-]+)\/([^/?#\s]+)/i.exec(address)
  if (inApp) {
    const kind = inApp[1].toLowerCase()
    if (kind === 'source') {
      let id = inApp[2]
      try { id = decodeURIComponent(id) } catch {}
      return `<a class="artifact-snippet-link" data-source-id="${attributeText(id)}">${labelHTML}</a>`
    }
    if (inAppKinds.has(kind)) {
      const stored = `foreverlm://${kind === 'project' ? 'notebook' : kind}/${inApp[2]}`
      return `<a class="artifact-snippet-link" data-href="${attributeText(stored)}">${labelHTML}</a>`
    }
    return labelHTML
  }
  if (/^(https?:\/\/|mailto:)/i.test(address)) {
    return `<a class="artifact-snippet-link" href="${attributeText(address)}" data-web="true">${labelHTML}</a>`
  }
  return labelHTML
}

function pageLinkHTML(token, options) {
  const exists = options.pageExists?.(token.title)
  const quiet = exists === false ? ' is-new' : ''
  const title = attributeText(token.title)
  if (token.type === 'tag') {
    return `<a class="artifact-snippet-page artifact-snippet-tag${quiet}" data-title="${title}">#${textHTML(token.title)}</a>`
  }
  return `<a class="artifact-snippet-page${quiet}" data-title="${title}">${textHTML(token.title)}</a>`
}

function referenceHTML(token, options, depth) {
  const block = options.block?.(token.blockID)
  if (block === undefined) {
    options.onUnknownBlock?.(token.blockID)
    return `<span class="artifact-snippet-ref is-pending" data-block-id="${token.blockID}">${textHTML(token.raw)}</span>`
  }
  if (!block) {
    return `<span class="artifact-snippet-ref is-missing" data-block-id="${token.blockID}">((missing block))</span>`
  }
  const inner = depth < 1
    ? renderInline(block.markdown ?? '', options, depth + 1)
    : textHTML(block.plainText ?? block.markdown ?? '')
  return `<span class="artifact-snippet-ref" data-block-id="${token.blockID}">${inner}</span>`
}

/// One line or paragraph of inline Markdown as HTML. `depth` counts how many
/// references deep this text is: a reference inside a referenced block reads
/// as plain text rather than resolving again, so two blocks that reference
/// each other cannot loop.
export function renderInline(source, options = {}, depth = 0) {
  const text = String(source ?? '')
  let html = ''
  let plain = ''
  const flush = () => {
    if (plain) html += textHTML(plain)
    plain = ''
  }
  let index = 0
  while (index < text.length) {
    const grammar = grammarAt(text, index)
    if (grammar) {
      flush()
      html += grammar.type === 'ref' ? referenceHTML(grammar, options, depth) : pageLinkHTML(grammar, options)
      index = grammar.end
      continue
    }
    const character = text[index]
    if (character === '\\') {
      const next = text[index + 1]
      if (next === '\n') {
        flush()
        html += '<br>'
        index += 2
        continue
      }
      if (next && asciiPunctuation.test(next)) {
        plain += next
        index += 2
        continue
      }
    }
    if (character === '`') {
      const span = codeSpanAt(text, index)
      if (span) {
        flush()
        html += `<code>${textHTML(span.code)}</code>`
        index = span.end
        continue
      }
      let run = 0
      while (text[index + run] === '`') run += 1
      plain += text.slice(index, index + run)
      index += run
      continue
    }
    if (character === '!' && text[index + 1] === '[') {
      const image = linkAt(text, index + 1)
      if (image) {
        flush()
        html += `<span class="artifact-snippet-image">${textHTML(image.label.replace(/\\(.)/g, '$1') || 'Image')}</span>`
        index = image.end
        continue
      }
    }
    if (character === '[') {
      const link = linkAt(text, index)
      if (link) {
        flush()
        html += linkHTML(renderInline(link.label, options, depth), link.href)
        index = link.end
        continue
      }
    }
    if (character === '<') {
      const autolink = stickyMatch(autolinkAt, text, index)
      if (autolink) {
        flush()
        html += linkHTML(textHTML(autolink[1]), autolink[1])
        index += autolink[0].length
        continue
      }
    }
    if (character === '*' || character === '_' || character === '~') {
      const emphasis = emphasisAt(text, index)
      if (emphasis) {
        flush()
        html += `<${emphasis.tag}>${renderInline(emphasis.inner, options, depth)}</${emphasis.tag}>`
        index = emphasis.end
        continue
      }
      let run = 0
      while (text[index + run] === character) run += 1
      plain += text.slice(index, index + run)
      index += run
      continue
    }
    if (character === '$') {
      // Math by the editor's own line (dollar-math.js): `$$x$$` always, `$x$`
      // unless it reads as money, as "$20 and $30" does.
      const math = stickyMatch(mathAt, text, index)
      const money = math && math[1] === '$'
        && singleDollarSpanIsMoney(math[2][0], math[2][math[2].length - 1], text[index + math[0].length] ?? '')
      if (math && !money) {
        flush()
        html += `<span class="artifact-snippet-math">${textHTML(math[2])}</span>`
        index += math[0].length
        continue
      }
    }
    if (character === '\n') {
      plain += ' '
      index += 1
      continue
    }
    plain += character
    index += 1
  }
  flush()
  return html
}

/// The text of a line without its trailing block id marker.
function withoutMarker(text) {
  return takeBlockIDMarker(text)?.text ?? text
}

function indentOf(line) {
  let width = 0
  for (const character of line) {
    if (character === ' ') width += 1
    else if (character === '\t') width += 4 - (width % 4)
    else break
  }
  return width
}

function stripIndent(line, width) {
  let removed = 0
  let index = 0
  while (index < line.length && removed < width) {
    const character = line[index]
    if (character === ' ') removed += 1
    else if (character === '\t') removed += 4 - (removed % 4)
    else break
    index += 1
  }
  return line.slice(index)
}

const listItemLine = /^(\s*)([-*+]|\d{1,9}[.)])(?:[ \t]+(.*))?$/
const fenceLine = /^(\s*)(`{3,}|~{3,})(.*)$/
const headingLine = /^\s{0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/
const ruleLine = /^\s{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/
const quoteLine = /^\s{0,3}>/
const tableSeparator = /^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$/
const blankLine = /^\s*$/
const preservedEmptyLine = /^\s*<br\s*\/?>\s*$/i

function splitTableRow(line) {
  let row = line.trim()
  if (row.startsWith('|')) row = row.slice(1)
  if (row.endsWith('|') && !row.endsWith('\\|')) row = row.slice(0, -1)
  const cells = []
  let current = ''
  for (let index = 0; index < row.length; index += 1) {
    if (row[index] === '\\' && row[index + 1] === '|') {
      current += '|'
      index += 1
    } else if (row[index] === '|') {
      cells.push(current.trim())
      current = ''
    } else {
      current += row[index]
    }
  }
  cells.push(current.trim())
  return cells
}

function embedHTML(blockID, options, depth) {
  const block = depth < 1 ? options.block?.(blockID) : null
  if (block === undefined) options.onUnknownBlock?.(blockID)
  if (!block) {
    const words = block === undefined ? `{{embed: ((${blockID}))}}` : '((missing block))'
    return `<div class="artifact-snippet-embed is-missing">${textHTML(words)}</div>`
  }
  const title = block.docTitle
    ? `<div class="artifact-snippet-embed-title">${textHTML(block.docTitle)}</div>`
    : ''
  const nested = { ...options, depth: depth + 1 }
  const children = block.childrenMarkdown ? renderBlocks(block.childrenMarkdown, nested, 1) : ''
  return `<div class="artifact-snippet-embed" data-block-id="${blockID}">${title}<div class="artifact-snippet-embed-body"><p>${renderInline(block.markdown ?? '', options, depth + 1)}</p>${children}</div></div>`
}

function paragraphHTML(lines, options) {
  const depth = options.depth ?? 0
  const joined = lines.join('\n')
  const embedded = embeddedBlockID(joined)
  if (embedded) return embedHTML(embedded, options, depth)
  const last = lines.length - 1
  const parts = lines.map((line, index) => {
    const own = index === last ? withoutMarker(line) : line
    const hard = index < last && (/ {2,}$/.test(own) || /\\$/.test(own))
    const words = hard ? own.replace(/(?: {2,}|\\)$/, '') : own.replace(/^\s+/, '')
    return { words, hard }
  })
  let source = ''
  for (const [index, part] of parts.entries()) {
    source += part.words
    if (index < last) source += part.hard ? '\\\n' : '\n'
  }
  return `<p>${renderInline(source.trim(), options, depth)}</p>`
}

/// A list's items, each `{ ordered, start, checked, text, lines }`, from the
/// lines that begin at `index`, and the index after the list.
function parseList(lines, index) {
  const first = listItemLine.exec(lines[index])
  const baseIndent = indentOf(first[1])
  const items = []
  let position = index
  while (position < lines.length) {
    const line = lines[position]
    const match = listItemLine.exec(line)
    if (match && indentOf(match[1]) <= baseIndent + 1 && !ruleLine.test(line)) {
      const marker = match[2]
      const ordered = /\d/.test(marker)
      let text = match[3] ?? ''
      let checked = null
      const task = /^\[([ xX])\][ \t]+(.*)$/.exec(text) ?? /^\[([ xX])\]$/.exec(text)
      if (task) {
        checked = task[1] !== ' '
        text = task[2] ?? ''
      }
      const contentIndent = indentOf(match[1]) + marker.length + 1
      items.push({ ordered, start: ordered ? Number.parseInt(marker, 10) : 1, checked, text, lines: [], contentIndent })
      position += 1
      continue
    }
    if (blankLine.test(line) || preservedEmptyLine.test(line)) {
      // A blank line ends the list unless what follows belongs to it.
      let next = position + 1
      while (next < lines.length && blankLine.test(lines[next])) next += 1
      if (next >= lines.length) break
      const following = lines[next]
      const continues = indentOf(following) > baseIndent || (listItemLine.test(following) && indentOf(following) <= baseIndent + 1)
      if (!continues) break
      items.at(-1)?.lines.push('')
      position += 1
      continue
    }
    if (indentOf(line) > baseIndent && items.length) {
      const item = items.at(-1)
      item.lines.push(stripIndent(line, Math.min(item.contentIndent, indentOf(line))))
      position += 1
      continue
    }
    // An unindented line straight under an item continues its text (a lazy
    // continuation); anything else ends the list.
    if (items.length && !quoteLine.test(line) && !headingLine.test(line) && !fenceLine.test(line) && items.at(-1).lines.length === 0) {
      items.at(-1).text += `\n${line.trim()}`
      position += 1
      continue
    }
    break
  }
  return { items, end: position }
}

function listHTML(items, options, listDepth) {
  const depth = options.depth ?? 0
  const foldDepth = options.foldListsDeeperThan ?? Infinity
  let html = ''
  let index = 0
  while (index < items.length) {
    const ordered = items[index].ordered
    const run = []
    while (index < items.length && items[index].ordered === ordered) run.push(items[index++])
    const tag = ordered ? 'ol' : 'ul'
    const start = ordered && run[0].start !== 1 ? ` start="${run[0].start}"` : ''
    html += `<${tag} class="artifact-snippet-list"${start}>`
    for (const item of run) {
      const task = item.checked == null
        ? ''
        : `<span class="artifact-snippet-task${item.checked ? ' is-checked' : ''}" aria-hidden="true"></span>`
      const own = withoutMarker(item.text)
      const embedded = embeddedBlockID(own)
      const words = embedded ? embedHTML(embedded, options, depth) : renderInline(own, options, depth)
      let nested = ''
      const childLines = item.lines
      if (childLines.some((line) => !blankLine.test(line))) {
        const inner = renderLines(childLines, options, listDepth + 1)
        nested = listDepth + 1 > foldDepth
          ? `<details class="artifact-snippet-more"><summary>More</summary>${inner}</details>`
          : inner
      }
      html += `<li${item.checked == null ? '' : ' class="artifact-snippet-task-item"'}>${task}<div class="artifact-snippet-item">${words}</div>${nested}</li>`
    }
    html += `</${tag}>`
  }
  return html
}

function renderLines(lines, options, listDepth) {
  const depth = options.depth ?? 0
  let html = ''
  let paragraph = []
  const flushParagraph = () => {
    if (paragraph.length) html += paragraphHTML(paragraph, options)
    paragraph = []
  }
  let index = 0
  while (index < lines.length) {
    const line = lines[index]
    if (blankLine.test(line) || preservedEmptyLine.test(line)) {
      flushParagraph()
      index += 1
      continue
    }
    const fence = fenceLine.exec(line)
    if (fence) {
      flushParagraph()
      const marker = fence[2]
      const body = []
      index += 1
      while (index < lines.length && !lines[index].trim().startsWith(marker)) body.push(lines[index++])
      index += 1
      html += `<pre class="artifact-snippet-code"><code>${textHTML(body.join('\n'))}</code></pre>`
      continue
    }
    const heading = headingLine.exec(line)
    if (heading) {
      flushParagraph()
      // A snippet's headings sit under the page's own: two levels down.
      const level = Math.min(6, heading[1].length + 2)
      html += `<h${level} class="artifact-snippet-heading">${renderInline(withoutMarker(heading[2] ?? ''), options, depth)}</h${level}>`
      index += 1
      continue
    }
    if (ruleLine.test(line)) {
      flushParagraph()
      html += '<hr>'
      index += 1
      continue
    }
    if (quoteLine.test(line)) {
      flushParagraph()
      const inner = []
      while (index < lines.length && quoteLine.test(lines[index])) {
        inner.push(lines[index].replace(/^\s{0,3}> ?/, ''))
        index += 1
      }
      html += `<blockquote>${renderLines(inner, options, listDepth)}</blockquote>`
      continue
    }
    if (listItemLine.test(line)) {
      flushParagraph()
      const list = parseList(lines, index)
      html += listHTML(list.items, options, listDepth)
      index = list.end
      continue
    }
    if (line.trim().startsWith('|') && index + 1 < lines.length && tableSeparator.test(lines[index + 1])) {
      flushParagraph()
      const header = splitTableRow(line)
      index += 2
      const rows = []
      while (index < lines.length && lines[index].trim().startsWith('|')) rows.push(splitTableRow(lines[index++]))
      const cells = (row, tag) => row.map((cell) => `<${tag}>${renderInline(cell, options, depth)}</${tag}>`).join('')
      html += `<table class="artifact-snippet-table"><thead><tr>${cells(header, 'th')}</tr></thead><tbody>${rows.map((row) => `<tr>${cells(row, 'td')}</tr>`).join('')}</tbody></table>`
      continue
    }
    paragraph.push(line)
    index += 1
  }
  flushParagraph()
  return html
}

/// A stretch of Markdown as HTML: every block it holds, lists nested.
/// `options.block(id)` answers a reference (a block, `null` when the graph
/// has none, `undefined` while it is not known), `options.pageExists(title)`
/// says whether a title names a page, `options.onUnknownBlock(id)` hears of a
/// reference nobody has answered, and `options.foldListsDeeperThan` folds
/// lists nested deeper than that under a More disclosure.
export function renderMarkdown(markdown, options = {}) {
  const lines = String(markdown ?? '').replace(/\r\n?/g, '\n').split('\n')
  return renderLines(lines, options, 0)
}

function renderBlocks(markdown, options, listDepth) {
  const lines = String(markdown ?? '').replace(/\r\n?/g, '\n').split('\n')
  return renderLines(lines, options, listDepth)
}
